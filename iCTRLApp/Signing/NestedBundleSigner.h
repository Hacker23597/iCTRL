#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Signs the parts of an app bundle that ldid's own recursion skips.
///
/// `ldid::Sign` walks a bundle and recurses into nested bundles, but only two
/// kinds — its rule is literally:
///
///     ^(Frameworks/[^/]*\.framework|PlugIns/[^/]*\.appex(()|/[^/]*.app))/…Info\.plist$
///
/// A `.xctest` plugin does not match that, and neither does a bare `.dylib` in
/// `Frameworks/` (the rule wants a `.framework` *directory*). Both still get
/// hashed into the parent's CodeResources, so the app verifies and installs —
/// but neither carries a CodeDirectory of its own.
///
/// That distinction is invisible until launch. An XCUITest runner needs its
/// `.xctest` to be independently signed, because testmanagerd validates the
/// plugin's own signature before loading it; and an unsigned dylib makes dyld
/// abort with "mapped file has no cdhash", which reads like anything except a
/// signing problem. iCTRL's Makefile already signs both separately with
/// `codesign` — this is the same work, done on-device where `codesign` doesn't
/// exist.
///
/// Call this AFTER the main `ALTSigner` pass: signing a nested bundle changes
/// its bytes, so the parent has to be sealed last or its resource hashes go
/// stale.
@interface NestedBundleSigner : NSObject

/// Signs `.xctest` plugins and loose dylibs inside `appURL`, innermost first.
///
/// `p12Data`/`password` are the same identity the main signing pass used —
/// mixing identities across one bundle produces a package the device rejects.
///
/// Returns YES when every nested binary ended up signed. On NO, `error`
/// explains which one failed: a partially signed bundle is worse than an
/// unsigned one, because it installs and then dies at launch.
+ (BOOL)signNestedBundlesAt:(NSURL *)appURL
                    p12Data:(NSData *)p12Data
                   password:(nullable NSString *)password
                      error:(NSError **)error;

/// Lists what would be signed, for logging and for the verification pass.
+ (NSArray<NSURL *> *)nestedBinariesAt:(NSURL *)appURL;

/// Checks every nested binary carries a signature.
///
/// Run after signing: this is the on-device equivalent of the Makefile's
/// "Verifying every embedded binary is signed" step, which exists because the
/// failure it catches is otherwise diagnosed from a crash log.
+ (BOOL)verifySignedAt:(NSURL *)appURL error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
