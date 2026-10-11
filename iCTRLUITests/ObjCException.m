#import "ObjCException.h"
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>

// performSelector on a runtime-resolved selector: ARC cannot see the
// ownership convention, and these all follow the standard one.
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

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


+ (nullable id)screenshotOf:(id)screen encoding:(id)encoding {
    @try {
        NSError *err = nil;
        SEL three = NSSelectorFromString(@"screenshotWithPreferredEncoding:rect:error:");
        if ([screen respondsToSelector:three]) {
            id (*fn)(id, SEL, id, CGRect, NSError **) = (id (*)(id, SEL, id, CGRect, NSError **))objc_msgSend;
            return fn(screen, three, encoding, CGRectNull, &err);
        }
        SEL four = NSSelectorFromString(@"screenshotWithPreferredEncoding:rect:options:error:");
        if ([screen respondsToSelector:four]) {
            id (*fn)(id, SEL, id, CGRect, id, NSError **) = (id (*)(id, SEL, id, CGRect, id, NSError **))objc_msgSend;
            return fn(screen, four, encoding, CGRectNull, nil, &err);
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

+ (nullable id)makeImageEncoding:(Class)encodingClass
                             uti:(NSString *)uti
                         quality:(double)quality
                        diagnosis:(NSString * _Nullable * _Nullable)diagnosis {
    // Three ways in, cheapest and most reliable first. Hand-rolling
    // objc_msgSend against a private initializer is the fragile one, so it is
    // the last resort rather than the first attempt.
    NSMutableArray<NSString *> *tried = [NSMutableArray array];

    // 1. Dictionary init — plain object types, no calling-convention guesswork.
    SEL dictSel = NSSelectorFromString(@"initWithDictionary:");
    if ([encodingClass instancesRespondToSelector:dictSel]) {
        NSDictionary *spec = @{
            @"uniformTypeIdentifier": uti,
            @"compressionQuality": @(quality),
        };
        id obj = [[encodingClass alloc] performSelector:dictSel withObject:spec];
        // Xcode 27 renamed the keys: the object comes back with a nil type
        // and quality 0, which encodes nothing. Only keep it if it took.
        BOOL took = NO;
        @try { took = [obj valueForKey:@"uniformTypeIdentifier"] != nil; } @catch (__unused NSException *e) {}
        if (obj && took) {
            if (diagnosis) { *diagnosis = @"via initWithDictionary:"; }
            return obj;
        }
        [tried addObject:obj ? @"initWithDictionary:->empty" : @"initWithDictionary:->nil"];
    }

    // 2. The class's own factory. No arguments, so nothing can be mis-marshalled;
    //    it fixes the quality rather than taking ours, which is fine — the point
    //    is a compressed capture, not one specific ratio.
    SEL maxSel = NSSelectorFromString(@"maximumCompression");
    if ([encodingClass respondsToSelector:maxSel]) {
        id obj = [encodingClass performSelector:maxSel];
        if (obj) {
            if (diagnosis) { *diagnosis = @"via +maximumCompression"; }
            return obj;
        }
        [tried addObject:@"+maximumCompression->nil"];
    }

    // 3. Designated initializer through objc_msgSend, typed from the runtime's
    //    own signature (the quality argument is not double on every OS).
    SEL sel = NSSelectorFromString(@"initWithUniformTypeIdentifier:compressionQuality:");
    if ([encodingClass instancesRespondToSelector:sel]) {
        NSMethodSignature *sig = [encodingClass instanceMethodSignatureForSelector:sel];
        const char *qType = sig ? [sig getArgumentTypeAtIndex:3] : NULL;
        void *(*msgAlloc)(Class, SEL) = (void *(*)(Class, SEL))objc_msgSend;
        void *allocated = msgAlloc(encodingClass, @selector(alloc));
        void *created = NULL;
        if (allocated && qType && strcmp(qType, @encode(float)) == 0) {
            void *(*f)(void *, SEL, void *, float) = (void *(*)(void *, SEL, void *, float))objc_msgSend;
            created = f(allocated, sel, (__bridge void *)uti, (float)quality);
        } else if (allocated && qType && strcmp(qType, @encode(double)) == 0) {
            void *(*f)(void *, SEL, void *, double) = (void *(*)(void *, SEL, void *, double))objc_msgSend;
            created = f(allocated, sel, (__bridge void *)uti, quality);
        }
        if (created) {
            if (diagnosis) { *diagnosis = @"via initWithUniformTypeIdentifier:"; }
            return (__bridge_transfer id)created;
        }
        [tried addObject:[NSString stringWithFormat:@"init(uti:quality)->nil qType='%s'", qType ?: "?"]];
    }

    if (diagnosis) { *diagnosis = [tried componentsJoinedByString:@", "] ?: @"no path available"; }
    return nil;
}




@end
