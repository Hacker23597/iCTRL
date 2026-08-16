import Foundation

/// Asks whether this device can produce its own anisette data.
///
/// Anisette is a set of headers proving to Apple's authentication servers that
/// a request comes from a real, provisioned Apple device. It is required to log
/// into an Apple ID programmatically, which is the first step of issuing a
/// developer certificate — so without it there is no self-signing.
///
/// SideStore solves this by asking a remote server to generate anisette while
/// pretending to be a Mac. That means trusting a third party with the
/// fingerprint your account logs in under, and shared fingerprints have gotten
/// accounts locked before, so it was worth checking whether this device could
/// just answer for itself: iOS generates real anisette every time someone signs
/// into Apple ID, and that machinery is already here.
///
/// Inspecting iOS 27's framework tree settled it. There is no `CoreADI` and no
/// `libadi.dylib` on iOS at all — the ADI library that macOS exposes as a
/// linkable dylib has no iOS counterpart. What exists instead is `AuthKit`,
/// which does not implement anisette either; it proxies to another process over
/// the Mach service `com.apple.ak.anisette.xpc` (see `_AKAnisetteProviderProxy`,
/// whose every method is a completion-handler round trip). Anisette on iOS is a
/// daemon service, not a library call.
///
/// That matters more than an ordinary "private API" obstacle. There is no
/// symbol to `dlopen`, so this cannot be solved by finding the right path or
/// tolerating API drift — a sandboxed app would need the entitlement that lets
/// it talk to that XPC endpoint, and entitlements come from Apple. The
/// remote-anisette dependency isn't a shortcut SideStore took; it's forced.
///
/// This probe stays in the tree because the conclusion is version-specific and
/// worth re-checking on future releases: if a linkable ADI ever appears, or the
/// XPC service stops being entitlement-gated, the whole third-party dependency
/// goes away. Nothing here signs anyone in or contacts Apple.
enum AnisetteProbe {

    struct Report {
        var lines: [String] = []
        var linkableADI = false
        var authKitPresent = false
        var xpcOnly = false

        var summary: String {
            if linkableADI { return "✅ A linkable ADI library exists — on-device anisette may be possible" }
            if xpcOnly { return "❌ Anisette is XPC-only here — needs an Apple-granted entitlement" }
            return "⚠️ Inconclusive — see the log"
        }
    }

    /// Every place a linkable ADI has been known to live, across macOS and the
    /// iOS spellings people have guessed at. All of these are expected to fail
    /// on iOS; the point is to prove that rather than assume it, and to notice
    /// immediately if a future release changes the answer.
    private static let adiPaths = [
        "/System/Library/PrivateFrameworks/CoreADI.framework/CoreADI",
        "/usr/lib/libadi.dylib",
        "/usr/lib/libCoreADI.dylib",
        "/System/Library/PrivateFrameworks/AppleAccount.framework/AppleAccount",
    ]

    /// The provisioning surface, if it were ever reachable directly.
    private static let adiSymbols = [
        "ADILoadLibraryWithPath", "ADIProvisioningStart", "ADIProvisioningEnd",
        "ADIGetLoginCode", "ADIOTPRequest", "ADIDispose",
    ]

    // MARK: - Running

    static func run() -> Report {
        var report = Report()
        func note(_ s: String) {
            report.lines.append(s)
            ictrlLog("[anisette] \(s)")
        }

        note("Checking how anisette is reachable on this OS")

        // 1. Is there anything to link against?
        for path in adiPaths {
            guard let handle = dlopen(path, RTLD_LAZY) else {
                let reason = dlerror().map { String(cString: $0) } ?? "unknown"
                note("dlopen \(URL(fileURLWithPath: path).lastPathComponent): \(reason)")
                continue
            }
            defer { dlclose(handle) }
            let found = adiSymbols.filter { dlsym(handle, $0) != nil }
            if found.isEmpty {
                note("Opened \(path) but it exports no ADI provisioning symbols")
            } else {
                report.linkableADI = true
                note("Opened \(path) exporting: \(found.joined(separator: ", "))")
            }
        }

        // 2. AuthKit is present on every iOS, but only as a proxy. Its presence
        //    alongside a missing ADI is the signature of the XPC-only design.
        if let handle = dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY) {
            defer { dlclose(handle) }
            report.authKitPresent = NSClassFromString("AKAnisetteData") != nil
                || dlsym(handle, "OBJC_CLASS_$_AKAnisetteData") != nil
            note("AuthKit loaded; anisette classes \(report.authKitPresent ? "present" : "absent")")
        } else {
            note("AuthKit did not load")
        }

        report.xpcOnly = !report.linkableADI && report.authKitPresent
        if report.xpcOnly {
            note("Anisette here is behind com.apple.ak.anisette.xpc — an entitled "
                 + "daemon, with no library entry point to call. On-device "
                 + "generation is not available to a sandboxed app.")
        }
        note(report.summary)
        return report
    }
}
