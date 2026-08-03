#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Obj-C @try/@catch so an NSException thrown by XCTest
/// (e.g. XCUIElement.tap on a stale/non-hittable element) can be caught — Swift's
/// do/catch cannot catch NSExceptions, and an uncaught one aborts the runner.
/// Returns the caught exception's reason, or nil if the block completed cleanly.
@interface ObjCException : NSObject
+ (nullable NSString *)catching:(void (^)(void))block;

/// Instantiate XCTest's private XCTImageEncoding by class + selector.
///
/// Lives here because the class ships in a private framework we do not link:
/// naming its type in Swift would leave the linker hunting for a symbol that
/// isn't there, so it has to be built through the runtime. Returns nil if the
/// class or initializer is missing on this OS.
+ (nullable id)makeImageEncoding:(Class)encodingClass
                             uti:(NSString *)uti
                         quality:(double)quality;
@end

NS_ASSUME_NONNULL_END
