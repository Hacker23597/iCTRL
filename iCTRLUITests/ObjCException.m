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
                         quality:(double)quality
                        diagnosis:(NSString * _Nullable * _Nullable)diagnosis {
    SEL sel = NSSelectorFromString(@"initWithUniformTypeIdentifier:compressionQuality:");
    if (![encodingClass instancesRespondToSelector:sel]) {
        if (diagnosis) { *diagnosis = @"selector missing"; }
        return nil;
    }

    // Read the real signature instead of assuming one. The quality argument is
    // NOT double on every OS — guessing wrong means the value arrives as
    // garbage and the initializer quietly returns nil, which is exactly how
    // this failed before. objc_msgSend is called through a cast matching what
    // the runtime reports, and stays outside ARC so the +1 from alloc/init can
    // be handed back with a single __bridge_transfer.
    NSMethodSignature *sig = [encodingClass instanceMethodSignatureForSelector:sel];
    if (!sig) { return nil; }
    const char *qType = [sig getArgumentTypeAtIndex:3];

    void *(*msgAlloc)(Class, SEL) = (void *(*)(Class, SEL))objc_msgSend;
    void *allocated = msgAlloc(encodingClass, @selector(alloc));
    if (!allocated) { return nil; }

    if (diagnosis) {
        *diagnosis = [NSString stringWithFormat:@"sig='%s' argc=%lu qType='%s'",
                      sig.methodReturnType ?: "?", (unsigned long)sig.numberOfArguments,
                      qType ?: "(null)"];
    }
    void *created = NULL;
    if (qType && strcmp(qType, @encode(float)) == 0) {
        void *(*msgInitF)(void *, SEL, void *, float) =
            (void *(*)(void *, SEL, void *, float))objc_msgSend;
        created = msgInitF(allocated, sel, (__bridge void *)uti, (float)quality);
    } else if (qType && strcmp(qType, @encode(double)) == 0) {
        void *(*msgInitD)(void *, SEL, void *, double) =
            (void *(*)(void *, SEL, void *, double))objc_msgSend;
        created = msgInitD(allocated, sel, (__bridge void *)uti, quality);
    } else {
        return nil;
    }
    if (!created) { return nil; }
    return (__bridge_transfer id)created;
}



@end
