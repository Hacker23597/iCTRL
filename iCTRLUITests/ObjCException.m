#import "ObjCException.h"
#import <objc/message.h>

@implementation ObjCException

+ (nullable NSString *)catching:(void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        NSString *reason = e.reason ?: e.name ?: @"unknown Obj-C exception";
        NSLog(@"iCTRL: caught Obj-C exception: %@", reason);
        return reason;
    }
}


+ (nullable id)makeImageEncoding:(Class)encodingClass
                             uti:(NSString *)uti
                         quality:(double)quality {
    SEL sel = NSSelectorFromString(@"initWithUniformTypeIdentifier:compressionQuality:");
    if (![encodingClass instancesRespondToSelector:sel]) { return nil; }

    // Send alloc/init through objc_msgSend directly rather than NSInvocation.
    // NSInvocation retains its target and ARC also owns the `id` holding the
    // alloc'd object, so combining them with a __bridge_transfer of the init
    // result over-releases the same object — an EXC_BAD_ACCESS on the next use.
    // Casting objc_msgSend to the exact signature keeps ARC out of it entirely;
    // the +1 from alloc/init is handed back via a __bridge_transfer of a
    // deliberately un-owned pointer.
    void *(*msgAlloc)(Class, SEL) = (void *(*)(Class, SEL))objc_msgSend;
    void *allocated = msgAlloc(encodingClass, @selector(alloc));
    if (!allocated) { return nil; }

    void *(*msgInit)(void *, SEL, void *, double) =
        (void *(*)(void *, SEL, void *, double))objc_msgSend;
    void *created = msgInit(allocated, sel, (__bridge void *)uti, quality);
    if (!created) { return nil; }
    return (__bridge_transfer id)created;
}


@end
