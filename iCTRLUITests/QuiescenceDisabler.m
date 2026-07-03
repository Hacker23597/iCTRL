//
//  QuiescenceDisabler.m
//  Disables XCUITest's "wait for quiescence" so interactions don't block for
//  up to 60s on animation-heavy apps (ads, carousels, live cards). Same approach
//  as WebDriverAgent: swizzle -[XCUIApplicationProcess waitForQuiescenceIncludingAnimationsIdle:]
//  to a no-op. This is loaded automatically via +load at test startup.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Private XCTest globals that bound how long internal idle/state waits can run.
// XCUIElement.tap()/isHittable/etc. wait for the app to reach an idle state via
// this timeout; XCTest's default can be very long, which is how an element tap
// that navigates blocked ~4-8s. WebDriverAgent bounds it the same way
// (_XCTSetApplicationStateTimeout, see XCUIApplicationProcess+FBQuiescence).
extern void _XCTSetApplicationStateTimeout(NSTimeInterval timeout) __attribute__((weak_import));
extern NSTimeInterval _XCTApplicationStateTimeout(void) __attribute__((weak_import));

@interface QuiescenceDisabler : NSObject
@end

@implementation QuiescenceDisabler

// A no-op replacement — return immediately, never wait for the UI to settle.
static void noopQuiescence(id self, SEL _cmd, BOOL includingAnimations) {}
static void noopQuiescencePreEvent(id self, SEL _cmd, BOOL includingAnimations, BOOL isPreEvent) {}

+ (void)load {
    // Bound XCTest's internal idle/state wait so XCUIElement.tap()/isHittable/etc.
    // can't block for many seconds when a tap navigates (observed ~4-8s, which
    // coincided with the test being torn down). WDA sets this to seconds; we use a
    // tight 2s cap. Safe if the symbol is missing (weak import).
    if (_XCTSetApplicationStateTimeout != NULL) {
        _XCTSetApplicationStateTimeout(2.0);
        NSLog(@"iCTRL: XCTest application-state timeout capped at 2s");
    }

    Class cls = NSClassFromString(@"XCUIApplicationProcess");
    if (!cls) { return; }

    // Newer XCTest: waitForQuiescenceIncludingAnimationsIdle:
    SEL sel1 = NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:");
    Method m1 = class_getInstanceMethod(cls, sel1);
    if (m1) {
        method_setImplementation(m1, (IMP)noopQuiescence);
        NSLog(@"iCTRL: quiescence wait disabled (waitForQuiescenceIncludingAnimationsIdle:)");
        return;
    }

    // Some XCTest builds: waitForQuiescenceIncludingAnimationsIdle:isPreEvent:
    SEL sel2 = NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:");
    Method m2 = class_getInstanceMethod(cls, sel2);
    if (m2) {
        method_setImplementation(m2, (IMP)noopQuiescencePreEvent);
        NSLog(@"iCTRL: quiescence wait disabled (…:isPreEvent:)");
        return;
    }

    NSLog(@"iCTRL: could not find quiescence method to disable");
}

@end
