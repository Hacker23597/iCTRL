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
#import <QuartzCore/QuartzCore.h>   // CACurrentMediaTime
#import <objc/runtime.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>

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
static BOOL sEarlyBackgroundArmed = NO;

// Set to YES by Swift (via +[EarlyURLHook markSetUpEntered]) the moment
// setUpWithError runs. This distinguishes the two failure modes:
//   - setUp NEVER entered  → XCTest bootstrap never ran (passcode interrupted
//     runTestsInBackground:). Safe to re-kick — nothing is running to re-enter.
//   - setUp entered but test not "started" → the test IS running, just slow to
//     mark itself. Re-kicking here re-enters XCTest → the symbolication abort
//     crash. So we must NOT re-kick in this case.
static BOOL sSetUpEntered = NO;

// Bootstrap recovery: KEEP retrying runTestsInBackground: until the test starts
// or a total deadline elapses. The passcode ("Enable UI Automation") prompt can
// stay up for MINUTES, and each interrupted launch dies before setUp — so a
// once-only or short-window re-kick misses it entirely (confirmed on-device:
// 6+ minutes of passcode, +load fired repeatedly, but no re-kick could bridge
// it and the user had to tap the icon manually).
//
// Two things make continuous retry safe (avoiding the "symbolication service
// already set" double-bootstrap crash that killed the old aggressive watchdog):
//   1. The guard: only re-kick when NEITHER setUp NOR the test has begun. If a
//      bootstrap actually reached setUp, we never re-kick.
//   2. Serialization: at most one re-kick in flight at a time (sReKickInFlight),
//      cleared on a short delay, so we never stack concurrent runTestsInBackground:.
static double sBootstrapDeadline = 0.0;    // CACurrentMediaTime() past which we give up
static int    sReKickAttempts    = 0;      // diagnostics: how many re-kicks fired
static BOOL   sReKickInFlight     = NO;     // don't overlap re-kicks
static BOOL   sPollArmed          = NO;     // ensure the poll loop is armed once

// Diagnostic observation window (5 min — covers a slow passcode entry).
static const double kBootstrapMaxWindow = 300.0;

@interface EarlyURLHook : NSObject
+ (NSArray<NSURL *> *)drainURLs;
+ (NSArray<NSString *> *)drainLogs;
+ (void)hookDelegateInstance:(id<UIApplicationDelegate>)delegate;
+ (void)tryInstall;
+ (void)hookClass:(Class)cls;
+ (void)markTestStarted;
+ (void)markSetUpEntered;
+ (void)scheduleBootstrapWatchdogForDelegate:(id)delegate;
+ (void)armAbsoluteBootstrapFallback;
+ (void)reKickIfNeeded:(id)delegate;
+ (void)armBootstrapRetryLoop;
+ (void)pollBootstrapOnce;
@end

/// Append one +load-era line DIRECTLY to today's persisted log file. These lines
/// run before Swift logging exists and are normally only flushed when setUp/URL
/// handling drains the buffer — but if the first-launch passcode interrupts
/// bootstrap, setUp never runs and those lines (incl. the bootstrap watchdog /
/// fallback activity) are lost, creating an observability black hole. So we also
/// write straight to the file here, so the recovery path is always traceable.
static void earlyLogWriteToFile(NSString *msg) {
    @try {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        if (dirs.count == 0) { return; }
        NSString *dir = [dirs[0] stringByAppendingPathComponent:@"Logs/iCTRL"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd"; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSString *day = [df stringFromDate:[NSDate date]];
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"ictrl-%@.log", day]];
        NSDateFormatter *tf = [[NSDateFormatter alloc] init]; tf.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [tf stringFromDate:[NSDate date]], msg];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) { write(fd, line.UTF8String, strlen(line.UTF8String)); close(fd); }
    } @catch (__unused NSException *e) {}
}

/// Record an event to the console, the drain buffer (for the in-memory log), AND
/// straight to the persisted file (so it survives a bootstrap that never reaches
/// setUp — see earlyLogWriteToFile).
static void earlyLog(NSString *msg) {
    NSLog(@"%@", msg);
    [sEarlyLock lock];
    if (sEarlyLogs) { [sEarlyLogs addObject:msg]; }
    [sEarlyLock unlock];
    earlyLogWriteToFile(msg);
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

/// Private XCTest API: the sanctioned way for a runner to open a URL.
@interface XCTRunnerDaemonSession : NSObject
+ (instancetype)sharedSession;
- (void)openDefaultApplicationForURL:(NSURL *)url
                          completion:(void (^)(BOOL result, NSError *error))completion;
@end

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

    earlyLog(@"🟩 +load reached — early hooks + bootstrap fallback arming");

    // DIAGNOSTIC-ONLY bootstrap observer. We do NOT re-kick runTestsInBackground:
    // any more.
    //
    // Why re-kick was removed (crash 2026-07-17-220237, SIGABRT):
    // The crash backtrace showed the ORIGINAL bootstrap was alive and blocked
    // inside `-[XCUIDevice enableAutomationMode:]` (an XCTWaiter waiting on the
    // "Enable UI Automation" authorization) — it hadn't reached setUp, so our
    // `!sSetUpEntered` guard let the re-kick through. Re-invoking
    // runTestsInBackground: then ran a SECOND `_XCTestMain` →
    // `registerSharedServiceWithConfiguration:` → "shared symbolication service
    // already set" → abort(). This is exactly the double-bootstrap crash a9c60da
    // removed the watchdog for.
    //
    // From inside the process there is NO reliable way to tell "bootstrap is
    // BLOCKED on the passcode (alive)" from "bootstrap DIED" — didBecomeActive
    // fires in BOTH cases (the alert appearing/dismissing toggles active). So any
    // in-process re-kick risks re-entering a live bootstrap → crash. We therefore
    // only OBSERVE and log; recovery of a truly-dead bootstrap needs an external
    // relaunch (see notes in the repo).
    [self armBootstrapObserver];
    [self armEarlyBackgrounding];
}

/// Diagnostic observer: logs the bootstrap-relevant lifecycle events (retry
/// window + didBecomeActive) so a passcode repro is fully traceable, but never
/// calls runTestsInBackground:. Idempotent.
/// Get the runner out of the foreground BEFORE XCTest's bootstrap needs it.
///
/// Observed on iOS 26: after the icon is tapped, +load runs and the scene
/// connects, then nothing happens — setUpWithError is never reached — until the
/// user manually backgrounds the app, at which point bootstrap completes in
/// under a second. Whatever XCTest waits on resolves once the runner stops
/// being frontmost.
///
/// That wait sits BEFORE setUp, so backgrounding from inside the test method is
/// too late: the code never runs. It has to happen here.
///
/// Runs on a short timer rather than inline. XCTest is not initialised at +load
/// — calling into it there is what previously aborted the runner — and
/// XCDeviceEvent is an XCTest class, so it needs a moment to exist. Two seconds
/// is late enough for that and well inside the observed ~10s stall.
+ (void)armEarlyBackgrounding {
    if (sEarlyBackgroundArmed) { return; }
    sEarlyBackgroundArmed = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Bootstrap already moved on? Leave the foreground alone — the test is
        // running and something else may legitimately own the screen.
        if (sSetUpEntered || sTestStarted) {
            earlyLog(@"🏠 early-background skipped — bootstrap already progressed");
            return;
        }
        @try {
            // Leave the foreground by OPENING ANOTHER APP, not by pressing Home.
            //
            // IOHID Menu was tried first and is a dead end here: the call returns
            // YES and the log said "pressed", but bootstrap still stalled the
            // full 11s until the user intervened — so the event either never
            // landed or backgrounding isn't what releases it. Either way,
            // synthesised button events are not a mechanism to rely on (the same
            // silent-success failure Appium documented in WDA PR #1171).
            //
            // XCTRunnerDaemonSession is different: it's the sanctioned way for a
            // runner to open a URL, it is already how the ictrl:// callback
            // returns to the host app, and it is observed to work on this OS.
            // Opening the host app both removes the runner from the foreground
            // and puts something useful there.
            Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
            if (!sessionClass) {
                earlyLog(@"🏠 early-background unavailable — XCTRunnerDaemonSession missing");
                return;
            }
            id session = [sessionClass performSelector:@selector(sharedSession)];
            SEL sel = NSSelectorFromString(@"openDefaultApplicationForURL:completion:");
            if (!session || ![session respondsToSelector:sel]) {
                earlyLog(@"🏠 early-background unavailable — daemon session can't open URLs yet");
                return;
            }

            // Private suspend APIs first. This build is developer-distributed and
            // never goes near App Review, so a private call is fair game — and
            // asking UIKit to suspend us is far more direct than opening some
            // other app and hoping that displaces us.
            //
            // Which of these exists varies by iOS version, so probe rather than
            // assume: the log names what was found and what worked, which is the
            // information needed if this ever breaks again.
            UIApplication *app = UIApplication.sharedApplication;
            NSArray<NSString *> *suspendSelectors = @[
                @"suspend",                    // classic, long-lived
                @"_suspend",
                @"suspendWithCompletion:",     // newer variants
                @"_suspendWithCompletion:",
            ];
            // Record which of these the OS still has, so a future failure starts
            // from fact rather than another round of guessing.
            NSMutableArray<NSString *> *available = [NSMutableArray array];
            for (NSString *n in suspendSelectors) {
                if ([app respondsToSelector:NSSelectorFromString(n)]) { [available addObject:n]; }
            }
            earlyLog([NSString stringWithFormat:@"🏠 suspend selectors present: %@",
                      available.count ? [available componentsJoinedByString:@", "] : @"(none)"]);
            for (NSString *name in suspendSelectors) {
                SEL sus = NSSelectorFromString(name);
                if (![app respondsToSelector:sus]) { continue; }
                earlyLog([NSString stringWithFormat:@"🏠 early-background: trying -[UIApplication %@]", name]);
                @try {
                    if ([name hasSuffix:@":"]) {
                        // Takes a completion block; pass an empty one.
                        void (^done)(void) = ^{};
                        NSMethodSignature *ssig = [app methodSignatureForSelector:sus];
                        NSInvocation *sinv = [NSInvocation invocationWithMethodSignature:ssig];
                        sinv.target = app;
                        sinv.selector = sus;
                        [sinv setArgument:&done atIndex:2];
                        [sinv invoke];
                    } else {
                        ((void (*)(id, SEL))objc_msgSend)(app, sus);
                    }
                    // Give UIKit a moment, then see whether it took.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        UIApplicationState st = UIApplication.sharedApplication.applicationState;
                        earlyLog(st == UIApplicationStateActive
                                 ? [NSString stringWithFormat:@"🏠 %@ returned but the runner is STILL ACTIVE", name]
                                 : [NSString stringWithFormat:@"🏠 early-background confirmed via -[UIApplication %@]", name]);
                    });
                    return;
                } @catch (NSException *e) {
                    earlyLog([NSString stringWithFormat:@"🏠 %@ raised: %@", name, e.reason]);
                }
            }
            earlyLog(@"🏠 early-background: no usable suspend selector — falling back to opening an app");

            // Settings first: it ships with iOS, so it is always there. The host
            // app registers ictrl-app:// but the two IPAs install separately —
            // the runner can be present without it, and opening a scheme nobody
            // handles would leave us in the foreground.
            NSArray<NSString *> *candidates = @[@"App-prefs:", @"ictrl-app://runner-starting"];
            BOOL opened = NO;
            for (NSString *candidate in candidates) {
                NSURL *url = [NSURL URLWithString:candidate];
                if (!url) { continue; }
                __block BOOL ok = NO;
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                [session openDefaultApplicationForURL:url completion:^(BOOL result, NSError *err) {
                    ok = result && (err == nil);
                    dispatch_semaphore_signal(sem);
                }];
                // Bounded: this runs on the main queue and must not wedge it.
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
                if (ok) {
                    earlyLog([NSString stringWithFormat:@"🏠 early-background: opened %@ (pre-setUp)", candidate]);
                    opened = YES;
                    break;
                }
                earlyLog([NSString stringWithFormat:@"🏠 early-background: %@ did not open", candidate]);
            }
            if (!opened) {
                earlyLog(@"🏠 early-background: no URL opened — runner stays in front");
                return;
            }

            // Confirm the foreground actually moved. Every previous attempt here
            // reported success from an API return value and was wrong — the IOHID
            // press logged "pressed" while bootstrap stalled anyway. UIApplication
            // state is a first-party signal and needs no XCTest.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIApplicationState state = UIApplication.sharedApplication.applicationState;
                earlyLog(state == UIApplicationStateActive
                         ? @"🏠 early-background: STILL ACTIVE — the open did not take the foreground"
                         : @"🏠 early-background confirmed — runner is no longer active");
            });
        } @catch (NSException *e) {
            earlyLog([NSString stringWithFormat:@"🏠 early-background raised: %@", e.reason]);
        }
    });
}

+ (void)armBootstrapObserver {
    if (sPollArmed) { return; }
    sPollArmed = YES;
    sBootstrapDeadline = CACurrentMediaTime() + kBootstrapMaxWindow;
    earlyLog(@"👀 bootstrap observer armed (diagnostic-only, no re-kick)");

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        if (sTestStarted || sSetUpEntered) { return; }
        earlyLog(@"🟢 didBecomeActive — bootstrap not yet at setUp (observing, NOT re-kicking)");
    }];
}

/// Kept for source compatibility — the delegate callbacks still call this. Now a
/// no-op-ish arming of the diagnostic observer.
+ (void)armAbsoluteBootstrapFallback {
    [self armBootstrapObserver];
}
+ (void)armBootstrapRetryLoop {
    [self armBootstrapObserver];
}
+ (void)pollBootstrapOnce { /* removed — no in-process re-kick */ }

/// Retained as a guarded no-op so any caller that still references it can't
/// accidentally re-introduce the double-bootstrap crash. Intentionally does
/// NOT call runTestsInBackground:.
+ (void)reKickIfNeeded:(id)delegate {
    (void)delegate;
    // Deliberately does nothing. In-process re-kick of runTestsInBackground: was
    // removed after it re-entered a live (passcode-blocked) bootstrap and
    // abort()ed on "shared symbolication service already set". Kept as a symbol
    // so existing call sites compile.
    (void)sReKickInFlight; (void)sReKickAttempts;   // silence unused-static warnings
    earlyLog(@"🔁 re-kick suppressed — in-process re-kick removed (double-bootstrap crash risk)");
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

+ (void)markSetUpEntered {
    sSetUpEntered = YES;
}

// Bootstrap watchdog — recovers from the first-launch passcode prompt
// interrupting XCTest bootstrap (so runTestsInBackground: never ran and the test
// method never executes → silent, no setUp, no crash), WITHOUT reintroducing the
// symbolication re-entrancy crash.
//
// The crash happened when we re-kicked while the test was ALREADY running (just
// slow to mark itself started) — re-entering XCTest aborts with "shared
// symbolication service ... already set". The fix is to only re-kick when the
// test truly never began: setUp has NOT entered AND the test has NOT started. In
// the passcode-interrupted case neither ever fires (bootstrap never reached the
// test), so a single re-kick is safe; in the "running but slow" case sSetUpEntered
// is YES, so we DON'T re-kick and can't crash. Re-kick at most once, after a long
// delay (well past a normal cold start), guarded by @try.
+ (void)scheduleBootstrapWatchdogForDelegate:(id)delegate {
    if (!delegate) { return; }
    if (![delegate respondsToSelector:NSSelectorFromString(@"runTestsInBackground:")]) { return; }
    // The delegate callbacks (didFinishLaunching / scene:willConnect) just make
    // sure the continuous retry loop is armed — the loop itself owns re-kicking.
    [EarlyURLHook armBootstrapRetryLoop];
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
