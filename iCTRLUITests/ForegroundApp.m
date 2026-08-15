#import "ForegroundApp.h"
#import <XCTest/XCTest.h>
#import <objc/message.h>

// Private XCTest accessibility client (present in the XCTest framework loaded
// from the device's /Developer at runtime). We declare only what we call.
@interface XCAXClient_iOS : NSObject
+ (instancetype)sharedClient;
// Returns an array of XCAccessibilityElement for running apps; the first is
// typically the frontmost/active application.
- (id)activeApplications;
- (id)systemApplication;
@end

// XCAccessibilityElement exposes the process id of an app element.
@interface XCAccessibilityElement : NSObject
@property (nonatomic, readonly) pid_t processIdentifier;
@end

// Bridge from pid → bundle id via the device info service used by XCTest.
// Also exposes openDefaultApplicationForURL:completion: — the XCTest-sanctioned
// way to open a URL from the runner process (iOS 16.4+), which UIApplication and
// LSApplicationWorkspace both refuse to do from inside XCTest.
@interface XCTRunnerDaemonSession : NSObject
+ (instancetype)sharedSession;
- (void)openDefaultApplicationForURL:(NSURL *)url completion:(void (^)(BOOL result, NSError *error))completion;
@end

// Private MobileCoreServices API listing/opening installed applications.
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleId;  // non-blocking launch
- (BOOL)openURL:(id)url;
- (BOOL)openURL:(id)url withOptions:(id)options;
- (BOOL)openSensitiveURL:(id)url withOptions:(id)options;
@end

// LSApplicationProxy exposes bundle id / display name / type.
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;   // bundle id
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;          // "User" / "System"
@end

@implementation ForegroundApp

+ (nullable NSString *)currentBundleID {
    @try {
        Class clientClass = NSClassFromString(@"XCAXClient_iOS");
        if (!clientClass) { return nil; }

        id client = [clientClass performSelector:@selector(sharedClient)];
        if (!client) { return nil; }

        // activeApplications: first element is the frontmost app.
        SEL sel = NSSelectorFromString(@"activeApplications");
        if (![client respondsToSelector:sel]) { return nil; }

        NSArray *apps = [client performSelector:sel];
        if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) { return nil; }

        for (id element in apps) {
            NSString *bid = [self bundleIDForElement:element];
            if (bid.length > 0 &&
                ![bid isEqualToString:@"com.apple.springboard"]) {
                return bid;
            }
        }
        // Fallback: return whatever the first element resolves to.
        return [self bundleIDForElement:apps.firstObject];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (nullable NSString *)bundleIDForElement:(id)element {
    @try {
        // Try a direct bundleID-ish selector first.
        for (NSString *name in @[@"bundleIdentifier", @"bundleID"]) {
            SEL s = NSSelectorFromString(name);
            if ([element respondsToSelector:s]) {
                id v = [element performSelector:s];
                if ([v isKindOfClass:[NSString class]]) { return v; }
            }
        }
        // Otherwise resolve via process identifier.
        SEL pidSel = NSSelectorFromString(@"processIdentifier");
        if ([element respondsToSelector:pidSel]) {
            NSMethodSignature *sig = [element methodSignatureForSelector:pidSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = pidSel;
            [inv invokeWithTarget:element];
            pid_t pid = 0;
            [inv getReturnValue:&pid];
            if (pid > 0) {
                return [self bundleIDForPID:pid];
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

+ (nullable NSString *)bundleIDForPID:(pid_t)pid {
    @try {
        // XCUIApplication can be constructed by pid via a private initializer in
        // some XCTest versions; if unavailable, we can't resolve here.
        Class appClass = NSClassFromString(@"XCUIApplication");
        SEL initSel = NSSelectorFromString(@"initWithProcessID:");
        if (appClass && [appClass instancesRespondToSelector:initSel]) {
            id app = [appClass alloc];
            NSMethodSignature *sig = [app methodSignatureForSelector:initSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = initSel;
            [inv setArgument:&pid atIndex:2];
            [inv invokeWithTarget:app];
            void *result = NULL;
            [inv getReturnValue:&result];
            id appInstance = (__bridge id)result;
            if ([appInstance respondsToSelector:NSSelectorFromString(@"bundleID")]) {
                id bid = [appInstance performSelector:NSSelectorFromString(@"bundleID")];
                if ([bid isKindOfClass:[NSString class]]) { return bid; }
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

+ (nullable NSArray<NSDictionary *> *)installedAppsUserOnly:(BOOL)userOnly {
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) { return nil; }
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        if (!ws) { return nil; }

        NSArray *apps = nil;
        // WDA uses allApplications; try it first, fall back to allInstalledApplications.
        if ([ws respondsToSelector:@selector(allApplications)]) {
            apps = [ws performSelector:@selector(allApplications)];
        }
        if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) {
            if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
                apps = [ws performSelector:@selector(allInstalledApplications)];
            }
        }
        if (![apps isKindOfClass:[NSArray class]]) { return nil; }

        NSMutableArray *out = [NSMutableArray array];
        for (id proxy in apps) {
            @try {
                NSString *bid = nil, *name = nil, *type = nil;
                if ([proxy respondsToSelector:@selector(applicationIdentifier)]) {
                    bid = [proxy performSelector:@selector(applicationIdentifier)];
                }
                if ([proxy respondsToSelector:@selector(localizedName)]) {
                    name = [proxy performSelector:@selector(localizedName)];
                }
                if ([proxy respondsToSelector:@selector(applicationType)]) {
                    type = [proxy performSelector:@selector(applicationType)];
                }
                if (bid.length == 0) { continue; }
                if (userOnly && type && ![type isEqualToString:@"User"]) { continue; }
                [out addObject:@{
                    @"bundle_id": bid ?: @"",
                    @"name": name ?: @"",
                    @"type": type ?: @"",
                }];
            } @catch (__unused NSException *e) {}
        }
        // Sort by name for stable, readable output.
        [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        return out;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (BOOL)activateOrLaunchBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return NO; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app) { return NO; }
        // `running` distinguishes the two cases; activate does nothing to a
        // process that hasn't started, and launch on a running app restarts it.
        BOOL running = NO;
        if ([app respondsToSelector:@selector(running)]) {
            BOOL (*runningFn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            running = runningFn(app, @selector(running));
        }
        SEL sel = running ? @selector(activate) : @selector(launch);
        if ([app respondsToSelector:sel]) {
            [app performSelector:sel];
            return YES;
        }
        return NO;
    } @catch (NSException *e) {
        NSLog(@"iCTRL: activateOrLaunch caught exception for %@: %@", bundleId, e.reason);
        return NO;
    }
}

+ (BOOL)safeActivateBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return NO; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        // -[XCUIApplication initWithBundleIdentifier:]
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app) { return NO; }
        // -[XCUIApplication activate] can throw an XCTest NSException (e.g. the app
        // isn't installed / can't be brought up). Swallow it here so it never
        // reaches the XCTest terminate handler and aborts the runner.
        if ([app respondsToSelector:@selector(activate)]) {
            [app performSelector:@selector(activate)];
        }
        return YES;
    } @catch (NSException *e) {
        NSLog(@"iCTRL: safeActivate caught exception for %@: %@", bundleId, e.reason);
        return NO;
    }
}

+ (BOOL)safeTerminateBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return NO; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app) { return NO; }
        if ([app respondsToSelector:@selector(terminate)]) {
            [app performSelector:@selector(terminate)];
        }
        return YES;
    } @catch (NSException *e) {
        NSLog(@"iCTRL: safeTerminate caught exception for %@: %@", bundleId, e.reason);
        return NO;
    }
}

+ (NSInteger)appStateForBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return 0; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return 0; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app || ![app respondsToSelector:@selector(state)]) { return 0; }
        NSInteger (*stateFn)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
        return stateFn(app, @selector(state));
    } @catch (__unused NSException *e) {
        return 0;
    }
}

+ (BOOL)hasSystemAlert {
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        // -[XCUIApplication springboardApplication] / systemApplication varies by
        // OS; construct SpringBoard directly and look for an alert element.
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id sb = initFn([appClass alloc], @selector(initWithBundleIdentifier:), @"com.apple.springboard");
        if (!sb) { return NO; }
        // sb.alerts.count > 0  → a system alert is present.
        id alerts = [sb performSelector:@selector(alerts)];
        if (alerts && [alerts respondsToSelector:@selector(count)]) {
            NSUInteger (*countFn)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
            return countFn(alerts, @selector(count)) > 0;
        }
        return NO;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (BOOL)openURL:(NSURL *)url {
    // 1) XCTest daemon session — the sanctioned path from a runner (iOS 16.4+).
    //    This is what WebDriverAgent uses; UIApplication/LSApplicationWorkspace
    //    both refuse to open URLs from inside XCTest.
    @try {
        Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
        if (sessionClass) {
            id session = [sessionClass performSelector:@selector(sharedSession)];
            SEL sel = @selector(openDefaultApplicationForURL:completion:);
            if (session && [session respondsToSelector:sel]) {
                __block BOOL ok = NO;
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                [session openDefaultApplicationForURL:url completion:^(BOOL result, NSError *err) {
                    ok = result && (err == nil);
                    dispatch_semaphore_signal(sem);
                }];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
                if (ok) { return YES; }
            }
        }
    } @catch (__unused NSException *e) {}

    // 2) Fallback: LSApplicationWorkspace (works on some OS versions).
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) { return NO; }
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        if (!ws) { return NO; }
        if ([ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
            BOOL (*fn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
            if (fn(ws, @selector(openSensitiveURL:withOptions:), url, nil)) { return YES; }
        }
        if ([ws respondsToSelector:@selector(openURL:)]) {
            BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
            return fn(ws, @selector(openURL:), url);
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

+ (BOOL)openBundleID:(NSString *)bundleId {
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) { return NO; }
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        if (![ws respondsToSelector:@selector(openApplicationWithBundleID:)]) { return NO; }
        // Non-blocking: returns immediately with success/failure.
        BOOL (*openFn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
        return openFn(ws, @selector(openApplicationWithBundleID:), bundleId);
    } @catch (__unused NSException *e) {
        return NO;
    }
}

@end
