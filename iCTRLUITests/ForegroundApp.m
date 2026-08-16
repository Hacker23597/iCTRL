#import "ForegroundApp.h"
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <objc/runtime.h>

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

#pragma mark - Snapshot cost probe

/// Counts nodes in a snapshot tree by walking `children`, so we can tell a
/// server-side depth limit (fewer nodes) from a no-op (identical node count).
static NSUInteger ICTRLCountSnapshotNodes(id snapshot, NSUInteger depth) {
    if (!snapshot || depth > 200) { return 0; }
    NSUInteger n = 1;
    @try {
        SEL childrenSel = NSSelectorFromString(@"children");
        if ([snapshot respondsToSelector:childrenSel]) {
            id kids = [snapshot performSelector:childrenSel];
            if ([kids isKindOfClass:[NSArray class]]) {
                for (id k in (NSArray *)kids) {
                    n += ICTRLCountSnapshotNodes(k, depth + 1);
                }
            }
        }
    } @catch (__unused NSException *e) {}
    return n;
}

/// Counts nodes carrying a non-empty label — the part a caller actually reads.
static NSUInteger ICTRLCountLabelledNodes(id snapshot, NSUInteger depth) {
    if (!snapshot || depth > 200) { return 0; }
    NSUInteger n = 0;
    @try {
        SEL labelSel = NSSelectorFromString(@"label");
        if ([snapshot respondsToSelector:labelSel]) {
            id label = [snapshot performSelector:labelSel];
            if ([label isKindOfClass:[NSString class]] && [(NSString *)label length] > 0) { n = 1; }
        }
        SEL childrenSel = NSSelectorFromString(@"children");
        if ([snapshot respondsToSelector:childrenSel]) {
            id kids = [snapshot performSelector:childrenSel];
            if ([kids isKindOfClass:[NSArray class]]) {
                for (id k in (NSArray *)kids) { n += ICTRLCountLabelledNodes(k, depth + 1); }
            }
        }
    } @catch (__unused NSException *e) {}
    return n;
}

/// Gathers every non-empty label in a snapshot tree, for sampling what content
/// a bounded fetch actually returned.
static void ICTRLCollectLabels(id snapshot, NSUInteger depth, NSMutableArray *into) {
    if (!snapshot || depth > 200) { return; }
    @try {
        SEL labelSel = NSSelectorFromString(@"label");
        if ([snapshot respondsToSelector:labelSel]) {
            id label = [snapshot performSelector:labelSel];
            if ([label isKindOfClass:[NSString class]] && [(NSString *)label length] > 0) {
                [into addObject:label];
            }
        }
        SEL childrenSel = NSSelectorFromString(@"children");
        if ([snapshot respondsToSelector:childrenSel]) {
            id kids = [snapshot performSelector:childrenSel];
            if ([kids isKindOfClass:[NSArray class]]) {
                for (id k in (NSArray *)kids) { ICTRLCollectLabels(k, depth + 1, into); }
            }
        }
    } @catch (__unused NSException *e) {}
}

/// Finds the node carrying the longest label — on a feed that is a content row
/// rather than a layout container, so probing it says something about whether
/// the fetch returned real text.
static id ICTRLDeepestLabelledNode(id snapshot, NSUInteger depth) {
    if (!snapshot || depth > 200) { return nil; }
    id best = nil;
    NSUInteger bestLen = 0;
    @try {
        SEL labelSel = NSSelectorFromString(@"label");
        if ([snapshot respondsToSelector:labelSel]) {
            id label = [snapshot performSelector:labelSel];
            if ([label isKindOfClass:[NSString class]] && [(NSString *)label length] > 0) {
                best = snapshot;
                bestLen = [(NSString *)label length];
            }
        }
        SEL childrenSel = NSSelectorFromString(@"children");
        if ([snapshot respondsToSelector:childrenSel]) {
            id kids = [snapshot performSelector:childrenSel];
            if ([kids isKindOfClass:[NSArray class]]) {
                for (id k in (NSArray *)kids) {
                    id sub = ICTRLDeepestLabelledNode(k, depth + 1);
                    if (!sub) { continue; }
                    id subLabel = [sub performSelector:NSSelectorFromString(@"label")];
                    NSUInteger len = [subLabel isKindOfClass:[NSString class]] ? [(NSString *)subLabel length] : 0;
                    if (len > bestLen) { best = sub; bestLen = len; }
                }
            }
        }
    } @catch (__unused NSException *e) {}
    return best;
}

+ (nullable id)safeSnapshotOfElement:(id)element {
    if (!element) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(@"snapshotWithError:");
        if (![element respondsToSelector:sel]) { return nil; }
        NSError *err = nil;
        id (*fn)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
        id snap = fn(element, sel, &err);
        if (err) {
            NSLog(@"iCTRL: safeSnapshot error: %@", err.localizedDescription);
            return nil;
        }
        return snap;
    } @catch (NSException *e) {
        NSLog(@"iCTRL: safeSnapshot caught exception: %@", e.reason);
        return nil;
    }
}

+ (BOOL)safeBoolProperty:(NSString *)name ofElement:(id)element fallback:(BOOL)fallback {
    if (!element) { return fallback; }
    @try {
        SEL sel = NSSelectorFromString(name);
        if (![element respondsToSelector:sel]) { return fallback; }
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        return fn(element, sel);
    } @catch (NSException *e) {
        // Answering "no" is the safe reading: a query XCTest can't resolve is
        // not one the caller should act on.
        NSLog(@"iCTRL: safeBoolProperty(%@) caught exception: %@", name, e.reason);
        return fallback;
    }
}

+ (nullable id)boundedSnapshotForBundleID:(NSString *)bundleId
                                 maxDepth:(NSInteger)maxDepth
                              maxChildren:(NSInteger)maxChildren {
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return nil; }
        id app = [[appClass alloc] performSelector:NSSelectorFromString(@"initWithBundleIdentifier:")
                                        withObject:bundleId];
        if (!app) { return nil; }

        // The request takes the app's XCAccessibilityElement, not the XCUIElement.
        id axElement = nil;
        for (NSString *sel in @[@"accessibilityElement", @"element"]) {
            SEL s = NSSelectorFromString(sel);
            if ([app respondsToSelector:s]) {
                axElement = [app performSelector:s];
                if (axElement) { break; }
            }
        }
        if (!axElement) { return nil; }

        // Reached via XCUIDevice — XCAXClient_iOS has no class methods on iOS 26,
        // so +sharedClient throws "unrecognized selector".
        id client = nil;
        Class deviceClass = NSClassFromString(@"XCUIDevice");
        id device = [deviceClass performSelector:NSSelectorFromString(@"sharedDevice")];
        SEL ifaceSel = NSSelectorFromString(@"accessibilityInterface");
        if ([device respondsToSelector:ifaceSel]) { client = [device performSelector:ifaceSel]; }
        if (!client) { return nil; }

        SEL reqSel = NSSelectorFromString(@"requestSnapshotForElement:attributes:parameters:error:");
        if (![client respondsToSelector:reqSel]) { return nil; }

        // Must be an NSArray: the sanitizer's first act is +[NSSet setWithArray:],
        // which throws on a set. +standardAttributeNames returns a set.
        id attrs = nil;
        Class elemClass = NSClassFromString(@"XCUIElement");
        SEL attrSel = NSSelectorFromString(@"standardAttributeNames");
        if ([elemClass respondsToSelector:attrSel]) { attrs = [elemClass performSelector:attrSel]; }
        if ([attrs isKindOfClass:[NSSet class]]) { attrs = [(NSSet *)attrs allObjects]; }
        if (![attrs isKindOfClass:[NSArray class]]) { return nil; }
        // standardAttributeNames alone fetches STRUCTURE ONLY through this raw
        // request. Its entries are snapshot-domain names ("label", "frame");
        // snapshotWithError converts them to AX wire keys before sending
        // (axAttributesForSnapshotAttributes:), but this request skips that step,
        // the far side silently ignores names it doesn't know, and the tree comes
        // back with every label empty and every frame zero — 472 nodes of shape
        // with no content, which is worse than useless for a caller who taps by
        // frame. Appending the wire-format keys is what flipped snapshot_bench's
        // labelled count from 0 to 116, with cells carrying full tweet text.
        NSMutableArray *wanted = [NSMutableArray arrayWithArray:(NSArray *)attrs];
        for (NSString *key in @[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeValue",
                                @"XC_kAXXCAttributeIdentifier",
                                @"XC_kAXXCAttributePlaceholderValue",
                                @"XC_kAXXCAttributeFrame"]) {
            if (![wanted containsObject:key]) { [wanted addObject:key]; }
        }
        attrs = wanted;

        NSError *err = nil;
        id (*fn)(id, SEL, id, id, id, NSError **) = (id (*)(id, SEL, id, id, id, NSError **))objc_msgSend;
        id result = fn(client, reqSel, axElement, attrs,
                       @{ @"maxDepth": @(maxDepth),
                          @"maxChildren": @(maxChildren),
                          @"maxArrayCount": @(maxChildren) }, &err);
        if (err || !result) { return nil; }

        // The call returns a request-result wrapper, not the snapshot itself.
        SEL rootSel = NSSelectorFromString(@"rootElementSnapshot");
        if (![result respondsToSelector:rootSel]) { return nil; }
        return [result performSelector:rootSel];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

/// Human-readable element type name. Values are XCUIElementType's REAL raw
/// values, verified against live trees — an earlier guessed mapping rendered
/// X's 156 cells as "Switch" and every Other as "Application", which broke any
/// caller grepping for "Cell, label:". Names mirror the Swift renderer exactly
/// so the bounded and full paths are indistinguishable to a parser.
static NSString *ICTRLTypeName(NSInteger t) {
    switch (t) {
        case 0: return @"Any";           case 1: return @"Other";
        case 2: return @"Application";   case 3: return @"Group";
        case 4: return @"Window";        case 5: return @"Sheet";
        case 7: return @"Alert";         case 9: return @"Button";
        case 19: return @"Keyboard";     case 20: return @"Key";
        case 21: return @"NavigationBar"; case 22: return @"TabBar";
        case 24: return @"Toolbar";      case 26: return @"Table";
        case 32: return @"CollectionView"; case 33: return @"Slider";
        case 36: return @"ActivityIndicator"; case 37: return @"SegmentedControl";
        case 38: return @"Picker";       case 39: return @"PickerWheel";
        case 40: return @"Switch";       case 42: return @"Link";
        case 43: return @"Image";        case 44: return @"Icon";
        case 45: return @"SearchField";  case 46: return @"ScrollView";
        case 48: return @"StaticText";   case 49: return @"TextField";
        case 50: return @"SecureTextField"; case 52: return @"TextView";
        case 57: return @"Map";          case 58: return @"WebView";
        case 75: return @"Cell";
        default: return [NSString stringWithFormat:@"Type%ld", (long)t];
    }
}

static void ICTRLRenderNode(id node, NSInteger depth, NSInteger maxDepth,
                            NSInteger maxElements, NSMutableArray *lines,
                            NSInteger *count, BOOL *truncated) {
    if (!node || *count >= maxElements) { if (*count >= maxElements) { *truncated = YES; } return; }
    @try {
        NSString *label = nil, *ident = nil, *value = nil;
        SEL s;
        s = NSSelectorFromString(@"label");
        if ([node respondsToSelector:s]) { id v = [node performSelector:s]; if ([v isKindOfClass:[NSString class]]) label = v; }
        s = NSSelectorFromString(@"identifier");
        if ([node respondsToSelector:s]) { id v = [node performSelector:s]; if ([v isKindOfClass:[NSString class]]) ident = v; }
        s = NSSelectorFromString(@"value");
        if ([node respondsToSelector:s]) { id v = [node performSelector:s]; if ([v isKindOfClass:[NSString class]]) value = v; }

        NSInteger type = 0;
        s = NSSelectorFromString(@"elementType");
        if ([node respondsToSelector:s]) {
            NSMethodSignature *sig = [node methodSignatureForSelector:s];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = s; [inv invokeWithTarget:node];
            NSUInteger raw = 0; [inv getReturnValue:&raw]; type = (NSInteger)raw;
        }

        CGRect frame = CGRectZero;
        s = NSSelectorFromString(@"frame");
        if ([node respondsToSelector:s]) {
            NSMethodSignature *sig = [node methodSignatureForSelector:s];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = s; [inv invokeWithTarget:node];
            [inv getReturnValue:&frame];
        }

        NSMutableString *line = [NSMutableString string];
        for (NSInteger i = 0; i < depth; i++) { [line appendString:@"  "]; }
        [line appendString:ICTRLTypeName(type)];
        if (label.length) { [line appendFormat:@", label: '%@'", label]; }
        if (value.length) { [line appendFormat:@", value: '%@'", value]; }
        if (ident.length) { [line appendFormat:@", id: '%@'", ident]; }
        [line appendFormat:@", {{%d, %d}, {%d, %d}}",
            (int)frame.origin.x, (int)frame.origin.y, (int)frame.size.width, (int)frame.size.height];
        [lines addObject:line];
        (*count)++;

        if (depth >= maxDepth) { return; }
        s = NSSelectorFromString(@"children");
        if ([node respondsToSelector:s]) {
            id kids = [node performSelector:s];
            if ([kids isKindOfClass:[NSArray class]]) {
                for (id k in (NSArray *)kids) {
                    if (*count >= maxElements) { *truncated = YES; break; }
                    ICTRLRenderNode(k, depth + 1, maxDepth, maxElements, lines, count, truncated);
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

+ (nullable NSString *)renderBoundedSnapshot:(id)root
                                    maxDepth:(NSInteger)maxDepth
                                 maxElements:(NSInteger)maxElements
                                 nodesWritten:(NSInteger *)outCount
                                    truncated:(BOOL *)outTruncated {
    if (!root) { return nil; }
    NSMutableArray *lines = [NSMutableArray array];
    NSInteger count = 0; BOOL trunc = NO;
    ICTRLRenderNode(root, 0, maxDepth, maxElements, lines, &count, &trunc);
    if (outCount) { *outCount = count; }
    if (outTruncated) { *outTruncated = trunc; }
    return [lines componentsJoinedByString:@"\n"];
}

/// Which single property `snapshot_bench` should read off a sample node.
/// Set per call; reading undocumented getters can hard-crash the runner, so only
/// one is attempted at a time (see probe_selector in the result).
static NSString *ICTRLProbeSelectorName = nil;

+ (void)setProbeSelectorName:(nullable NSString *)name {
    ICTRLProbeSelectorName = [name copy];
}

+ (nullable NSDictionary *)benchmarkSnapshotForBundleID:(NSString *)bundleId
                                               maxDepth:(NSInteger)maxDepth {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return nil; }
        id app = [[appClass alloc] performSelector:NSSelectorFromString(@"initWithBundleIdentifier:")
                                        withObject:bundleId];
        if (!app) { return nil; }

        // --- Variant A: the path page_source uses today (no server-side limit).
        // Skippable: on a deep tree it costs seconds and would blow the RPC
        // watchdog before the cheap variant is even measured, which is what a
        // depth sweep needs to isolate.
        if (maxDepth >= 0) {
            NSDate *t0 = [NSDate date];
            id snapA = nil;
            @try {
                SEL snapSel = NSSelectorFromString(@"snapshotWithError:");
                if ([app respondsToSelector:snapSel]) {
                    NSError *err = nil;
                    id (*fn)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
                    snapA = fn(app, snapSel, &err);
                    if (err) { out[@"default_error"] = err.localizedDescription ?: @"?"; }
                }
            } @catch (NSException *e) { out[@"default_exception"] = e.reason ?: @"?"; }
            out[@"default_ms"] = @((NSInteger)([[NSDate date] timeIntervalSinceDate:t0] * 1000));
            out[@"default_nodes"] = @(ICTRLCountSnapshotNodes(snapA, 0));
        }
        // A negative max_depth means "skip the baseline"; use its magnitude.
        if (maxDepth < 0) { maxDepth = -maxDepth; }

        // --- Variant B: same fetch, but ask the AX server to bound the walk.
        // Resolve the app's accessibility element, which is what the low-level
        // request takes (it does not accept an XCUIElement).
        id axElement = nil;
        for (NSString *sel in @[@"accessibilityElement", @"element"]) {
            SEL s = NSSelectorFromString(sel);
            if ([app respondsToSelector:s]) {
                axElement = [app performSelector:s];
                if (axElement) { break; }
            }
        }
        if (!axElement) {
            out[@"param_skipped"] = @"could not resolve accessibilityElement";
            return out;
        }

        // The AX client is reached through XCUIDevice, not a shared singleton:
        // on iOS 26 XCAXClient_iOS exposes no class methods at all, so
        // +sharedClient throws "unrecognized selector". XCUIElementQuery's own
        // snapshot path goes device -> accessibilityInterface, so mirror that.
        id client = nil;
        @try {
            Class deviceClass = NSClassFromString(@"XCUIDevice");
            id device = [deviceClass performSelector:NSSelectorFromString(@"sharedDevice")];
            SEL ifaceSel = NSSelectorFromString(@"accessibilityInterface");
            if ([device respondsToSelector:ifaceSel]) {
                client = [device performSelector:ifaceSel];
            }
        } @catch (NSException *e) { out[@"client_exception"] = e.reason ?: @"?"; }
        if (!client) { out[@"param_skipped"] = @"no accessibilityInterface"; return out; }
        out[@"client_class"] = NSStringFromClass([client class]);
        SEL reqSel = NSSelectorFromString(@"requestSnapshotForElement:attributes:parameters:error:");
        if (![client respondsToSelector:reqSel]) {
            out[@"param_skipped"] = @"no requestSnapshotForElement:...";
            return out;
        }

        // Standard attribute set, so the two variants return comparable nodes.
        // +standardAttributeNames lives on XCUIElement (XCElementSnapshot is gone
        // in this XCTest version — the snapshot class is XCUIElementSnapshot).
        // `attributes:` is an NSSet, not an NSArray: +standardAttributeNames is
        // built with +setWithObjects:, and passing an array throws
        // "-[NSSet initWithArray:range:copyItems:]: array argument is not an NSArray"
        // from inside the request. Normalise whatever we get to a set.
        id attrs = nil;
        @try {
            for (NSString *cls in @[@"XCUIElement", @"XCElementSnapshot"]) {
                Class c = NSClassFromString(cls);
                SEL attrSel = NSSelectorFromString(@"standardAttributeNames");
                if ([c respondsToSelector:attrSel]) {
                    attrs = [c performSelector:attrSel];
                    if (attrs) { out[@"attrs_from"] = cls; break; }
                }
            }
        } @catch (__unused NSException *e) {}
        // `attributes:` must be an NSArray. The sanitizer's first act is
        // +[NSSet setWithArray:attrs], which throws
        // "array argument is not an NSArray" when handed a set — so
        // +standardAttributeNames returning a set has to be flattened back to an
        // array before the call.
        if ([attrs isKindOfClass:[NSSet class]]) {
            attrs = [(NSSet *)attrs allObjects];
        }
        if (![attrs isKindOfClass:[NSArray class]]) {
            attrs = @[@"XC_kAXXCAttributeIdentifier", @"XC_kAXXCAttributeValue",
                      @"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeFrame",
                      @"XC_kAXXCAttributeElementType", @"XC_kAXXCAttributeChildren"];
            out[@"attrs_from"] = @"fallback";
        }
        out[@"attrs_count"] = @([attrs count]);
        out[@"attrs_class"] = NSStringFromClass([attrs class]);
        // Which attributes we actually asked for. A snapshot fetched without
        // XC_kAXXCAttributeLabel comes back correctly shaped but with empty
        // labels — indistinguishable from "the app exposes nothing" unless the
        // requested set is visible here.
        out[@"attrs_list"] = [[attrs valueForKey:@"description"] componentsJoinedByString:@","] ?: @"?";
        out[@"ax_class"] = NSStringFromClass([axElement class]);
        // Sanity-check the attribute set the same way the request will, so a bad
        // element vs. a bad attribute set are distinguishable in the result.
        @try {
            Class snapClass = NSClassFromString(@"XCElementSnapshot");
            SEL sanSel = NSSelectorFromString(@"sanitizedElementSnapshotHierarchyAttributesForAttributes:isMacOS:");
            if ([snapClass respondsToSelector:sanSel]) {
                id (*fn)(id, SEL, id, BOOL) = (id (*)(id, SEL, id, BOOL))objc_msgSend;
                id sanitized = fn(snapClass, sanSel, attrs, NO);
                out[@"attrs_sanitized_ok"] = @([sanitized count]);
                // XCTest expands the requested set (14 -> 20 here). Record what
                // it added: those are attributes the snapshot always carries, so
                // asking for them explicitly is redundant, while anything absent
                // from this list is genuinely not fetched.
                @try {
                    NSArray *all = [sanitized respondsToSelector:@selector(allObjects)]
                        ? [sanitized allObjects] : (NSArray *)sanitized;
                    out[@"attrs_sanitized_list"] = [all componentsJoinedByString:@","];
                } @catch (__unused NSException *e) {}
            } else {
                out[@"attrs_sanitized_ok"] = @"selector missing";
            }
        } @catch (NSException *e) { out[@"attrs_sanitize_exception"] = e.reason ?: @"?"; }

        // Explicitly include the text-bearing attributes. +standardAttributeNames
        // is what the default path uses, but the depth-limited request appears to
        // return structure only — if that is because label was never requested,
        // naming it here fixes it; if labels are still empty, the AX server does
        // not populate them in bounded mode and this route is unusable.
        NSMutableArray *wanted = [NSMutableArray arrayWithArray:(NSArray *)attrs];
        for (NSString *key in @[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeValue",
                                @"XC_kAXXCAttributeIdentifier",
                                @"XC_kAXXCAttributePlaceholderValue"]) {
            // Asking for more than this is pointless: the AX server returns a
            // fixed set (label, title, identifier, frame, elementType, enabled,
            // selected, hasFocus, children, displayID, windowContextID, and the
            // two size classes) no matter what is requested. traits, value,
            // visiblePoint and truncatedValue were all requested and none came
            // back, while the extra keys measurably slowed the call.
            if (![wanted containsObject:key]) { [wanted addObject:key]; }
        }
        attrs = wanted;
        out[@"attrs_count_final"] = @(wanted.count);

        NSDictionary *params = @{ @"maxDepth": @(maxDepth),
                                  @"maxChildren": @(100),
                                  @"maxArrayCount": @(100) };

        NSDate *t1 = [NSDate date];
        id snapB = nil;
        @try {
            NSError *err = nil;
            id (*fn)(id, SEL, id, id, id, NSError **) =
                (id (*)(id, SEL, id, id, id, NSError **))objc_msgSend;
            snapB = fn(client, reqSel, axElement, attrs, params, &err);
            if (err) { out[@"param_error"] = err.localizedDescription ?: @"?"; }
        } @catch (NSException *e) { out[@"param_exception"] = e.reason ?: @"?"; }
        out[@"param_ms"] = @((NSInteger)([[NSDate date] timeIntervalSinceDate:t1] * 1000));
        out[@"param_nodes"] = @(ICTRLCountSnapshotNodes(snapB, 0));
        out[@"param_max_depth"] = @(maxDepth);
        // The request returns a wrapper, not the snapshot itself: counting
        // `children` on it yields 1 regardless of maxDepth. Record what we
        // actually got so the node count can be read against the right object.
        out[@"param_class"] = snapB ? NSStringFromClass([snapB class]) : @"nil";
        // Node count alone does not prove the tree is usable: a snapshot fetched
        // with the wrong attribute set still has the right shape but empty
        // labels, which is worthless to a caller. Count labelled nodes too.
        @try {
            SEL rootSel = NSSelectorFromString(@"rootElementSnapshot");
            if ([snapB respondsToSelector:rootSel]) {
                id root = [snapB performSelector:rootSel];
                out[@"param_labelled"] = @(ICTRLCountLabelledNodes(root, 0));
                // Node counts don't prove usefulness: sample the longest labels
                // so we can see whether real content (feed rows) came through or
                // only chrome like tab titles.
                NSMutableArray *samples = [NSMutableArray array];
                ICTRLCollectLabels(root, 0, samples);
                [samples sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                    return b.length > a.length ? NSOrderedAscending : NSOrderedDescending;
                }];
                NSMutableArray *top = [NSMutableArray array];
                for (NSUInteger i = 0; i < MIN(3u, samples.count); i++) {
                    NSString *s = samples[i];
                    [top addObject:s.length > 120 ? [s substringToIndex:120] : s];
                }
                out[@"param_label_samples"] = [top componentsJoinedByString:@" ⏐ "];

                // Runtime dump of one real node instead of guessing which
                // attribute carries the text. XCElementSnapshot loads properties
                // lazily (see -_isFaultedIn:/faultedInProperties), so a value can
                // be absent simply because it was never faulted in — which looks
                // identical to "the app exposes nothing".
                // Sample a node that actually carries text. Walking down the
                // first child each time lands on a layout container, whose empty
                // label says nothing about whether the fetch returned content —
                // the earlier run reported 116 labelled nodes while this probe
                // read blanks. Pick the longest-labelled node instead: on a feed
                // that is a real row, which is what we need to inspect.
                id probe = ICTRLDeepestLabelledNode(root, 0);
                out[@"probe_found_labelled"] = @(probe != nil);
                if (!probe) { probe = root; }
                // Read ONE property per call, named by the caller. Reading a set
                // of undocumented getters in a loop killed the runner with SIGBUS
                // (not an NSException — @catch cannot stop it), and a batch dump
                // gives no clue which getter did it. One at a time means a crash
                // identifies its own culprit, and the safe ones stay usable.
                NSString *probeSel = ICTRLProbeSelectorName ?: @"label";
                out[@"probe_selector"] = probeSel;
                // -faultedInProperties reads the lazy-loading bookkeeping itself
                // and killed the runner with SIGBUS on iOS 26. @catch cannot stop
                // that, so the only safe handling is never to call it.
                static NSSet *banned;
                static dispatch_once_t once;
                dispatch_once(&once, ^{ banned = [NSSet setWithObjects:@"faultedInProperties", nil]; });
                if ([banned containsObject:probeSel]) {
                    out[@"probe_value"] = @"<refused: crashes the runner (SIGBUS)>";
                    probeSel = nil;
                }
                if (probeSel) @try {
                    SEL s = NSSelectorFromString(probeSel);
                    if (![probe respondsToSelector:s]) {
                        out[@"probe_value"] = @"<no-sel>";
                    } else {
                        id v = [probe performSelector:s];
                        NSString *desc = v ? [NSString stringWithFormat:@"%@", v] : @"nil";
                        if (desc.length > 200) { desc = [[desc substringToIndex:200] stringByAppendingString:@"…"]; }
                        out[@"probe_value"] = desc;
                    }
                } @catch (NSException *e) {
                    out[@"probe_value"] = [NSString stringWithFormat:@"<throws:%@>", e.name];
                }
                out[@"probe_class"] = NSStringFromClass([probe class]);
                // What the returned snapshot actually holds, as opposed to what
                // we asked for. -dictionaryRepresentation is the snapshot's own
                // serialisation, so its keys are the definitive answer to "which
                // attributes came back" — a requested attribute missing here was
                // dropped, and a key here we never requested came for free.
                @try {
                    SEL dictSel = NSSelectorFromString(@"dictionaryRepresentation");
                    if ([probe respondsToSelector:dictSel]) {
                        id dict = [probe performSelector:dictSel];
                        if ([dict isKindOfClass:[NSDictionary class]]) {
                            NSArray *keys = [[(NSDictionary *)dict allKeys]
                                sortedArrayUsingSelector:@selector(compare:)];
                            out[@"returned_keys"] = [keys componentsJoinedByString:@","];
                            out[@"returned_key_count"] = @(keys.count);
                        } else {
                            out[@"returned_keys"] = dict ? NSStringFromClass([dict class]) : @"nil";
                        }
                    } else {
                        out[@"returned_keys"] = @"<no dictionaryRepresentation>";
                    }
                } @catch (NSException *e) {
                    out[@"returned_keys"] = [NSString stringWithFormat:@"<throws:%@>", e.name];
                }

                // Enumerate what this class really has on THIS iOS build — the
                // Mac-side framework we disassembled may not match the device's.
                @try {
                    unsigned int n = 0;
                    objc_property_t *props = class_copyPropertyList([probe class], &n);
                    NSMutableArray *names = [NSMutableArray array];
                    for (unsigned int i = 0; i < n && i < 60; i++) {
                        [names addObject:@(property_getName(props[i]))];
                    }
                    if (props) { free(props); }
                    out[@"probe_properties"] = [names componentsJoinedByString:@","];
                } @catch (__unused NSException *e) {}
                // Second-pass probe: if the bounded tree carries no text, can a
                // node be re-hydrated on its own? A snapshot node exposes the
                // accessibility element it came from, so re-requesting just that
                // subtree would let us fetch structure cheaply and fill in text
                // only where needed.
                id deepest = root;
                for (int i = 0; i < 6; i++) {
                    SEL kidsSel = NSSelectorFromString(@"children");
                    if (![deepest respondsToSelector:kidsSel]) { break; }
                    NSArray *kids = [deepest performSelector:kidsSel];
                    if (![kids isKindOfClass:[NSArray class]] || kids.count == 0) { break; }
                    deepest = kids.firstObject;
                }
                for (NSString *sel in @[@"accessibilityElement", @"element"]) {
                    SEL s = NSSelectorFromString(sel);
                    if ([deepest respondsToSelector:s]) {
                        id leafAX = [deepest performSelector:s];
                        if (!leafAX) { continue; }
                        out[@"rehydrate_ax_class"] = NSStringFromClass([leafAX class]);
                        NSError *e2 = nil;
                        id (*fn2)(id, SEL, id, id, id, NSError **) =
                            (id (*)(id, SEL, id, id, id, NSError **))objc_msgSend;
                        id one = fn2(client, reqSel, leafAX, attrs,
                                     @{@"maxDepth": @(1)}, &e2);
                        SEL rs = NSSelectorFromString(@"rootElementSnapshot");
                        id oneRoot = [one respondsToSelector:rs] ? [one performSelector:rs] : nil;
                        out[@"rehydrate_labelled"] = @(ICTRLCountLabelledNodes(oneRoot, 0));
                        break;
                    }
                }
            }
        } @catch (NSException *e) { out[@"rehydrate_exception"] = e.reason ?: @"?"; }
        @try {
            for (NSString *sel in @[@"rootElementSnapshot", @"snapshot", @"value"]) {
                SEL s = NSSelectorFromString(sel);
                if ([snapB respondsToSelector:s]) {
                    id inner = [snapB performSelector:s];
                    if (inner) {
                        out[[@"unwrap_" stringByAppendingString:sel]] =
                            [NSString stringWithFormat:@"%@:%lu",
                             NSStringFromClass([inner class]),
                             (unsigned long)ICTRLCountSnapshotNodes(inner, 0)];
                    }
                }
            }
        } @catch (NSException *e) { out[@"unwrap_exception"] = e.reason ?: @"?"; }
    } @catch (NSException *e) {
        out[@"fatal"] = e.reason ?: @"?";
    }
    return out;
}

@end
