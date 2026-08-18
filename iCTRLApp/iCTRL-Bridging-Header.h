//
//  iCTRL-Bridging-Header.h
//
//  Exposes AltSign (Objective-C) to the app's Swift code.
//
//  AltSign is compiled from source into this target rather than linked as a
//  package — upstream ships only a podspec, so there is no module to import.
//  See NOTICE.md for why this repository uses the upstream rather than the
//  SideStore fork.
//

#import "AltSign.h"

// AltSign's model objects have no public initialisers — they are built from
// Apple's JSON. Reconstructing a session from stored credentials, or naming the
// team a provisioning profile already identifies, needs to make one without a
// network round trip, so this pulls in the internal initialiser. Private to
// AltSign's umbrella, but we compile it from source, so it is ours to import.
#import "ALTModel+Internal.h"

// Set by AppSigner so GSA rejections reach the exportable log. Apple funnels
// every leg of the handshake through one error path, so without this the log
// can't say which request was refused.
extern void (^ALTAuthDiagnosticHandler)(NSString *);

// Signs the `.xctest` plugin and loose dylibs that ldid's own bundle recursion
// skips — the difference between a runner that installs and one that launches.
#import "NestedBundleSigner.h"
