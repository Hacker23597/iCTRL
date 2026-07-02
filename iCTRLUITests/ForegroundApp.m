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
@interface XCTRunnerDaemonSession : NSObject
+ (instancetype)sharedSession;
@end

// Private MobileCoreServices API listing/opening installed applications.
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleId;  // non-blocking launch
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
