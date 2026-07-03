#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Obj-C @try/@catch so an NSException thrown by XCTest
/// (e.g. XCUIElement.tap on a stale/non-hittable element) can be caught — Swift's
/// do/catch cannot catch NSExceptions, and an uncaught one aborts the runner.
/// Returns the caught exception's reason, or nil if the block completed cleanly.
@interface ObjCException : NSObject
+ (nullable NSString *)catching:(void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
