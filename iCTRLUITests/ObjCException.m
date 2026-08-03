#import "ObjCException.h"

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
    id obj = [encodingClass alloc];
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) { return nil; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj;
    inv.selector = sel;
    [inv setArgument:&uti atIndex:2];
    [inv setArgument:&quality atIndex:3];
    [inv invoke];
    // The initializer returns a +1 object; transfer that reference to ARC so it
    // is neither leaked nor over-released.
    void *result = NULL;
    [inv getReturnValue:&result];
    return (__bridge_transfer id)result;
}

@end
