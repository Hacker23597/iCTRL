//
//  EarlyURLHook.m
//  Installs the ictrl:// URL capture hooks as early as possible — at bundle
//  load, BEFORE XCTest's setUp runs. This matters on a COLD start: iOS calls
//  the runner's application:didFinishLaunchingWithOptions: (carrying the launch
//  URL) before our Swift setUp executes, so a Swift-side install in setUp would
//  miss it. Here we capture the launch URL and any early openURL into a shared
//  store that the Swift URLSchemeHandler drains once the server is up.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Thread-safe stash of early-captured URLs. URLSchemeHandler (Swift) reads these
// via +[EarlyURLHook drainURLs] and merges them into its pending queue.
static NSMutableArray<NSURL *> *sEarlyURLs;
static NSMutableArray<NSString *> *sEarlyLogs;   // events captured before Swift log is ready
static NSLock *sEarlyLock;

// Set to YES by Swift (via +[EarlyURLHook markTestStarted]) once testStartServer
// actually begins. The bootstrap watchdog uses this to decide whether to re-kick
// runTestsInBackground: — the passcode prompt on first launch can interrupt the
// XCTest bootstrap so the test method never runs and the server never comes up.
static BOOL sTestStarted = NO;

@interface EarlyURLHook : NSObject
+ (NSArray<NSURL *> *)drainURLs;
+ (NSArray<NSString *> *)drainLogs;
+ (void)hookDelegateInstance:(id<UIApplicationDelegate>)delegate;
+ (void)tryInstall;
+ (void)hookClass:(Class)cls;
+ (void)markTestStarted;
+ (void)scheduleBootstrapWatchdogForDelegate:(id)delegate;
@end

/// Record an event both to the console AND to a buffer the Swift LogBuffer drains
/// into the persisted log file (these +load-era events run before Swift logging).
static void earlyLog(NSString *msg) {
    NSLog(@"%@", msg);
    [sEarlyLock lock];
    if (sEarlyLogs) { [sEarlyLogs addObject:msg]; }
    [sEarlyLock unlock];
}

static void stashURL(NSURL *url) {
    if (![[url.scheme lowercaseString] isEqualToString:@"ictrl"]) { return; }
    [sEarlyLock lock];
    [sEarlyURLs addObject:url];
    [sEarlyLock unlock];
    earlyLog([NSString stringWithFormat:@"🔗 early-captured URL %@://%@", url.scheme, url.host ?: @""]);
}

// Replacement for application:didFinishLaunchingWithOptions: — reads launch URL,
// then CHAINS to the original impl (via the exchanged tmp selector) so XCTest's
// own boot logic still runs. If there was no original (we added, not exchanged),
// the tmp selector won't respond and we just return YES.
static BOOL hookedDidFinishLaunching(id self, SEL _cmd, id application, NSDictionary *options) {
    NSURL *url = options[UIApplicationLaunchOptionsURLKey];
    earlyLog([NSString stringWithFormat:@"🔎 didFinishLaunching fired; launchURL=%@; optionKeys=%@",
              url ? url.absoluteString : @"(none)", options.allKeys]);
    if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
    // Arm the bootstrap watchdog in case the passcode prompt interrupts the test
    // kickoff (self is the _XCTRunnerAppDelegate).
    [EarlyURLHook scheduleBootstrapWatchdogForDelegate:self];
    SEL orig = NSSelectorFromString(@"ictrlearly_application:didFinishLaunchingWithOptions:");
    if ([self respondsToSelector:orig]) {
        BOOL (*imp)(id, SEL, id, NSDictionary *) = (BOOL (*)(id, SEL, id, NSDictionary *))
            [self methodForSelector:orig];
        return imp(self, orig, application, options);
    }
    return YES;
}

// Replacement for application:openURL:options: — reads warm-path URLs, then
// chains to the original if present.
static BOOL hookedOpenURL(id self, SEL _cmd, id application, NSURL *url, NSDictionary *options) {
    earlyLog([NSString stringWithFormat:@"🔎 openURL fired; url=%@", url ? url.absoluteString : @"(none)"]);
    if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
    SEL orig = NSSelectorFromString(@"ictrlearly_application:openURL:options:");
    if ([self respondsToSelector:orig]) {
        BOOL (*imp)(id, SEL, id, NSURL *, NSDictionary *) = (BOOL (*)(id, SEL, id, NSURL *, NSDictionary *))
            [self methodForSelector:orig];
        return imp(self, orig, application, url, options);
    }
    return YES;
}

// The runner uses a SCENE-based lifecycle: warm-path URLs arrive via
// -scene:openURLContexts: (a Set<UIOpenURLContext>). Extract each context's URL.
static void hookedSceneOpenURLContexts(id self, SEL _cmd, id scene, NSSet *contexts) {
    earlyLog([NSString stringWithFormat:@"🔎 scene:openURLContexts fired; count=%lu",
              (unsigned long)contexts.count]);
    for (id ctx in contexts) {
        if ([ctx respondsToSelector:@selector(URL)]) {
            NSURL *url = [ctx performSelector:@selector(URL)];
            if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
        }
    }
    SEL orig = NSSelectorFromString(@"ictrlearly_scene:openURLContexts:");
    if ([self respondsToSelector:orig]) {
        void (*imp)(id, SEL, id, NSSet *) = (void (*)(id, SEL, id, NSSet *))[self methodForSelector:orig];
        imp(self, orig, scene, contexts);
    }
}

// COLD-path for scene lifecycle: -scene:willConnectToSession:options: carries a
// UISceneConnectionOptions whose .URLContexts holds the launch URL(s).
static void hookedSceneWillConnect(id self, SEL _cmd, id scene, id session, id connectionOptions) {
    NSSet *urlContexts = nil;
    if ([connectionOptions respondsToSelector:@selector(URLContexts)]) {
        urlContexts = [connectionOptions performSelector:@selector(URLContexts)];
    }
    earlyLog([NSString stringWithFormat:@"🔎 scene:willConnect fired; urlContexts=%lu",
              (unsigned long)urlContexts.count]);
    for (id ctx in urlContexts) {
        if ([ctx respondsToSelector:@selector(URL)]) {
            NSURL *url = [ctx performSelector:@selector(URL)];
            if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
        }
    }
    // Arm the bootstrap watchdog on the actual app delegate (which owns
    // runTestsInBackground:), in case the passcode prompt interrupted kickoff.
    [EarlyURLHook scheduleBootstrapWatchdogForDelegate:[UIApplication sharedApplication].delegate];
    SEL orig = NSSelectorFromString(@"ictrlearly_scene:willConnectToSession:options:");
    if ([self respondsToSelector:orig]) {
        void (*imp)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))[self methodForSelector:orig];
        imp(self, orig, scene, session, connectionOptions);
    }
}

// Swizzled -[UIApplication setDelegate:] — fires the instant the runner installs
// its app delegate, which is GUARANTEED to be before UIApplicationMain calls
// application:didFinishLaunchingWithOptions:. That's the only reliable window to
// hook the delegate early enough to catch the cold-start launch URL.
static void (*original_setDelegate)(id, SEL, id<UIApplicationDelegate>);
static void swizzled_setDelegate(id self, SEL _cmd, id<UIApplicationDelegate> delegate) {
    if (delegate) {
        earlyLog([NSString stringWithFormat:@"🔎 UIApplication delegate set: %@",
                  NSStringFromClass(object_getClass(delegate))]);
        [EarlyURLHook hookDelegateInstance:delegate];
    }
    if (original_setDelegate) { original_setDelegate(self, _cmd, delegate); }
}

@implementation EarlyURLHook

+ (void)load {
    sEarlyURLs = [NSMutableArray array];
    sEarlyLogs = [NSMutableArray array];
    sEarlyLock = [[NSLock alloc] init];

    // Swizzle UIApplication setDelegate: so we hook the delegate the moment it's
    // set (before didFinishLaunching). Fall back to a direct class hook too.
    Method m = class_getInstanceMethod([UIApplication class], @selector(setDelegate:));
    if (m) {
        original_setDelegate = (void (*)(id, SEL, id<UIApplicationDelegate>))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_setDelegate);
    }

    // Also try the class-based hook now and on the main queue, as a backstop.
    [self tryInstall];
    dispatch_async(dispatch_get_main_queue(), ^{ [EarlyURLHook tryInstall]; });
}

/// Hook a concrete delegate INSTANCE's class (covers cases where the runner's
/// delegate is a subclass we didn't know the name of).
+ (void)hookDelegateInstance:(id<UIApplicationDelegate>)delegate {
    Class cls = object_getClass(delegate);
    if (!cls) { return; }
    [self hookClass:cls];
}

static BOOL sInstalled = NO;

+ (void)tryInstall {
    if (sInstalled) { return; }
    Class cls = NSClassFromString(@"_XCTRunnerAppDelegate");
    if (!cls) { return; }
    [self hookClass:cls];
}

+ (void)hookClass:(Class)cls {
    if (sInstalled) { return; }
    sInstalled = YES;

    // application:didFinishLaunchingWithOptions:  (cold path)
    SEL dfl = NSSelectorFromString(@"application:didFinishLaunchingWithOptions:");
    if (!class_addMethod(cls, dfl, (IMP)hookedDidFinishLaunching, "B@:@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_application:didFinishLaunchingWithOptions:");
        if (class_addMethod(cls, tmp, (IMP)hookedDidFinishLaunching, "B@:@@")) {
            Method a = class_getInstanceMethod(cls, dfl);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    // application:openURL:options:  (warm path, app-delegate lifecycle)
    SEL ou = NSSelectorFromString(@"application:openURL:options:");
    if (!class_addMethod(cls, ou, (IMP)hookedOpenURL, "B@:@@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_application:openURL:options:");
        if (class_addMethod(cls, tmp, (IMP)hookedOpenURL, "B@:@@@")) {
            Method a = class_getInstanceMethod(cls, ou);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    // scene:openURLContexts:  (warm path, SCENE lifecycle — what the runner uses)
    SEL sou = NSSelectorFromString(@"scene:openURLContexts:");
    if (!class_addMethod(cls, sou, (IMP)hookedSceneOpenURLContexts, "v@:@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_scene:openURLContexts:");
        if (class_addMethod(cls, tmp, (IMP)hookedSceneOpenURLContexts, "v@:@@")) {
            Method a = class_getInstanceMethod(cls, sou);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    // scene:willConnectToSession:options:  (COLD path, SCENE lifecycle)
    SEL swc = NSSelectorFromString(@"scene:willConnectToSession:options:");
    if (!class_addMethod(cls, swc, (IMP)hookedSceneWillConnect, "v@:@@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_scene:willConnectToSession:options:");
        if (class_addMethod(cls, tmp, (IMP)hookedSceneWillConnect, "v@:@@@")) {
            Method a = class_getInstanceMethod(cls, swc);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    earlyLog(@"🔗 early URL hooks installed (app + scene lifecycle)");
}

+ (void)markTestStarted {
    sTestStarted = YES;
    earlyLog(@"✅ testStartServer began — bootstrap OK");
}

// Bootstrap watchdog — DIAGNOSTIC ONLY. It does NOT re-invoke
// runTestsInBackground: anymore.
//
// History: this used to re-kick runTestsInBackground: if the test hadn't begun a
// few seconds after launch, to recover from the first-launch passcode prompt
// interrupting the bootstrap. But re-invoking runTestsInBackground: RE-ENTERS
// XCTest in the same process, which crashes with
//   "Attempted to register a shared symbolication service instance when one was
//    already set" (NSInternalInconsistencyException)
// — observed on a fresh install: the re-kick fought a bootstrap that was already
// underway (slowed only by first-launch notification/network permission prompts),
// so the app crash-looped several times before one launch happened to win the
// race. The real cause of the original "server ready then dies" was setUp calling
// app.activate() behind the lock screen, which is now removed. So the re-kick is
// no longer needed and was doing net harm.
//
// We keep the watchdog purely to LOG if the test is slow to start, so a genuine
// bootstrap stall is still visible without risking the re-entrancy crash.
+ (void)scheduleBootstrapWatchdogForDelegate:(id)delegate {
    if (!delegate) { return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sTestStarted) { return; }
        earlyLog(@"⚠️ bootstrap watchdog: test still not started 10s after launch "
                 @"(NOT re-kicking — re-entering XCTest crashes). If the server never "
                 @"comes up, relaunch the runner.");
    });
}

+ (NSArray<NSURL *> *)drainURLs {
    [sEarlyLock lock];
    NSArray *urls = [sEarlyURLs copy];
    [sEarlyURLs removeAllObjects];
    [sEarlyLock unlock];
    return urls;
}

+ (NSArray<NSString *> *)drainLogs {
    [sEarlyLock lock];
    NSArray *logs = [sEarlyLogs copy];
    [sEarlyLogs removeAllObjects];
    [sEarlyLock unlock];
    return logs;
}

@end
