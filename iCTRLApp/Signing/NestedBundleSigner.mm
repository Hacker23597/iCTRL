#import "NestedBundleSigner.h"

#import <AltSign/AltSign.h>

#include <string>
#include "ldid.hpp"

/// Defined in AltSign's ALTSigner.mm. Converts a certificate into the PEM blob
/// ldid wants as its key, with Apple's intermediates appended — declared here
/// rather than reimplemented so both signing passes derive the key identically.
/// A mismatch between passes yields a bundle whose parts disagree about who
/// signed them, which the device rejects at install with nothing useful to say.
std::string CertificatesContent(ALTCertificate *altCertificate);

static NSString *const NestedBundleSignerErrorDomain = @"com.openminis.ictrl.NestedBundleSigner";

@implementation NestedBundleSigner

+ (NSArray<NSURL *> *)nestedBinariesAt:(NSURL *)appURL {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *found = [NSMutableArray array];

    // .xctest plugins. ldid's nested-bundle rule matches only .appex under
    // PlugIns/, so these are invisible to it.
    NSURL *plugins = [appURL URLByAppendingPathComponent:@"PlugIns" isDirectory:YES];
    for (NSURL *entry in [fm contentsOfDirectoryAtURL:plugins
                           includingPropertiesForKeys:nil
                                              options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                                error:nil]) {
        if ([entry.pathExtension.lowercaseString isEqualToString:@"xctest"]) {
            [found addObject:entry];
        }
    }

    // Loose dylibs. The rule wants a `.framework` directory, so a bare dylib
    // dropped into Frameworks/ — which is exactly how the compat shim ships —
    // is treated as a plain resource.
    NSURL *frameworks = [appURL URLByAppendingPathComponent:@"Frameworks" isDirectory:YES];
    for (NSURL *entry in [fm contentsOfDirectoryAtURL:frameworks
                           includingPropertiesForKeys:nil
                                              options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                                error:nil]) {
        if ([entry.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
            [found addObject:entry];
        }
    }

    return found;
}

+ (BOOL)signNestedBundlesAt:(NSURL *)appURL
                    p12Data:(NSData *)p12Data
                   password:(NSString *)password
                      error:(NSError **)error {
    ALTCertificate *certificate = [[ALTCertificate alloc] initWithP12Data:p12Data password:password];
    if (certificate == nil) {
        if (error) {
            *error = [NSError errorWithDomain:NestedBundleSignerErrorDomain code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Couldn't read the signing certificate."
            }];
        }
        return NO;
    }

    std::string key = CertificatesContent(certificate);
    if (key.empty()) {
        if (error) {
            *error = [NSError errorWithDomain:NestedBundleSignerErrorDomain code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"The certificate has no usable private key."
            }];
        }
        return NO;
    }

    for (NSURL *target in [self nestedBinariesAt:appURL]) {
        BOOL isBundle = [target.pathExtension.lowercaseString isEqualToString:@"xctest"];
        NSError *signError = nil;
        BOOL ok = isBundle
            ? [self signBundleAt:target key:key error:&signError]
            : [self signMachOAt:target key:key error:&signError];

        if (!ok) {
            if (error) { *error = signError; }
            return NO;
        }
        NSLog(@"iCTRL: signed nested %@", target.lastPathComponent);
    }

    return YES;
}

/// Signs a nested bundle by pointing ldid at it as its own root, which is what
/// gives it a CodeDirectory instead of just a resource hash in its parent.
+ (BOOL)signBundleAt:(NSURL *)bundleURL key:(const std::string &)key error:(NSError **)error {
    try {
        ldid::DiskFolder folder(bundleURL.fileSystemRepresentation);
        // Entitlements are inherited from the embedded profile the main pass
        // already wrote; returning them unchanged keeps this pass from widening
        // or narrowing what the plugin is allowed to do.
        ldid::Sign("", folder, key, "",
                   ldid::fun([](const std::string &, const std::string &entitlements) -> std::string {
                       return entitlements;
                   }),
                   ldid::fun([](const std::string &) {}),
                   ldid::fun([](double) {}));
        return YES;
    } catch (const std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:NestedBundleSignerErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't sign %@: %s",
                                            bundleURL.lastPathComponent, e.what()]
            }];
        }
        return NO;
    }
}

/// Signs a standalone Mach-O in place. A dylib has no bundle to walk, so this
/// uses ldid's single-binary entry point and writes the result back.
+ (BOOL)signMachOAt:(NSURL *)fileURL key:(const std::string &)key error:(NSError **)error {
    NSData *input = [NSData dataWithContentsOfURL:fileURL];
    if (input == nil) {
        if (error) {
            *error = [NSError errorWithDomain:NestedBundleSignerErrorDomain code:4 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't read %@", fileURL.lastPathComponent]
            }];
        }
        return NO;
    }

    try {
        std::stringbuf output;
        // The identifier defaults to the file's own name, matching what
        // codesign would infer for a loose dylib.
        std::string identifier(fileURL.lastPathComponent.stringByDeletingPathExtension.UTF8String);
        ldid::Slots slots;
        ldid::Sign(input.bytes, (size_t)input.length, output, identifier,
                   "", "", key, slots, ldid::fun([](double) {}));

        std::string signed_ = output.str();
        NSData *result = [NSData dataWithBytes:signed_.data() length:signed_.size()];
        NSError *writeError = nil;
        if (![result writeToURL:fileURL options:NSDataWritingAtomic error:&writeError]) {
            if (error) { *error = writeError; }
            return NO;
        }
        return YES;
    } catch (const std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:NestedBundleSignerErrorDomain code:5 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't sign %@: %s",
                                            fileURL.lastPathComponent, e.what()]
            }];
        }
        return NO;
    }
}

+ (BOOL)verifySignedAt:(NSURL *)appURL error:(NSError **)error {
    for (NSURL *target in [self nestedBinariesAt:appURL]) {
        NSURL *machO = target;
        if ([target.pathExtension.lowercaseString isEqualToString:@"xctest"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
                                  [target URLByAppendingPathComponent:@"Info.plist"]];
            NSString *executable = info[@"CFBundleExecutable"];
            if (executable == nil) { continue; }
            machO = [target URLByAppendingPathComponent:executable];
        }

        if (![self hasCodeSignature:machO]) {
            if (error) {
                *error = [NSError errorWithDomain:NestedBundleSignerErrorDomain code:6 userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"%@ ended up unsigned. Installing it would produce a runner that "
                        @"dies at launch with \"mapped file has no cdhash\".",
                        target.lastPathComponent]
                }];
            }
            return NO;
        }
    }
    return YES;
}

/// Looks for LC_CODE_SIGNATURE rather than validating the signature itself:
/// the question here is "did we forget to sign this", and a present-but-invalid
/// signature is a different failure that the device reports clearly.
+ (BOOL)hasCodeSignature:(NSURL *)machOURL {
    NSData *data = [NSData dataWithContentsOfURL:machOURL options:NSDataReadingMappedIfSafe error:nil];
    if (data.length < sizeof(uint32_t) * 8) { return NO; }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint32_t magic = *(const uint32_t *)bytes;

    // Only 64-bit little-endian Mach-O ships on the devices iCTRL targets; a fat
    // binary or anything else is left to the device to judge.
    if (magic != 0xFEEDFACF) { return NO; }

    uint32_t ncmds = *(const uint32_t *)(bytes + 16);
    size_t offset = 32;   // sizeof(mach_header_64)
    for (uint32_t i = 0; i < ncmds; i++) {
        if (offset + 8 > data.length) { return NO; }
        uint32_t cmd = *(const uint32_t *)(bytes + offset);
        uint32_t cmdsize = *(const uint32_t *)(bytes + offset + 4);
        if (cmd == 0x1D) { return YES; }   // LC_CODE_SIGNATURE
        if (cmdsize == 0) { return NO; }
        offset += cmdsize;
    }
    return NO;
}

@end
