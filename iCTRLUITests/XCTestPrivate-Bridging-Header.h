#ifndef XCTestPrivate_Bridging_Header_h
#define XCTestPrivate_Bridging_Header_h

#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#import "LockStateMonitor.h"
#import "ForegroundApp.h"
#import "ObjCException.h"

@interface EarlyURLHook : NSObject
+ (NSArray<NSURL *> *)drainURLs;
+ (NSArray<NSString *> *)drainLogs;
+ (void)markTestStarted;
+ (void)markSetUpEntered;
@end

NS_ASSUME_NONNULL_BEGIN

@class XCPointerEventPath;

@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name;
- (void)addPointerEventPath:(XCPointerEventPath *)eventPath;
- (BOOL)synthesizeWithError:(NSError * _Nullable * _Nullable)error;
@end

@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset;
- (void)pressDownAtOffset:(NSTimeInterval)offset;
- (void)liftUpAtOffset:(NSTimeInterval)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (instancetype)initForTextInput;
- (void)typeText:(NSString *)text
        atOffset:(NSTimeInterval)offset
     typingSpeed:(NSUInteger)typingSpeed
    shouldRedact:(BOOL)shouldRedact;
@end

@interface XCUIDevice (FBPrivate)
- (void)pressLockButton;
@end

NS_ASSUME_NONNULL_END

#endif
