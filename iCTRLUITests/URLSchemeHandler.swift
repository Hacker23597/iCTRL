import UIKit
import ObjectiveC.runtime

/// Captures `ictrl://` URLs delivered to the XCUITest runner.
///
/// The runner is hosted by Apple's private `_XCTRunnerAppDelegate`, so we can't
/// implement `application(_:open:options:)` the normal way. We add that method
/// to the delegate class at startup; it forwards the URL to this singleton.
/// The test body polls `takePendingURL()` after the server is up.
final class URLSchemeHandler {
    static let shared = URLSchemeHandler()

    static let scheme = "ictrl"

    private let lock = NSLock()
    private var pendingURL: URL?

    private init() {}

    func record(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return }
        lock.lock()
        pendingURL = url
        lock.unlock()
        iCTRLUITests.logBuffer.append("🔗 Received URL: \(url.scheme ?? "")://\(url.host ?? "")")
    }

    /// Returns and clears any pending URL.
    func takePendingURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let u = pendingURL
        pendingURL = nil
        return u
    }

    // MARK: - Delegate hook install

    /// Adds `application:openURL:options:` to the runner's app delegate class so
    /// incoming ictrl:// URLs reach us. Called once at test startup.
    static func installURLHandler() {
        guard let delegateClass = NSClassFromString("_XCTRunnerAppDelegate") else {
            iCTRLUITests.logBuffer.append("⚠️ _XCTRunnerAppDelegate not found; URL scheme disabled")
            return
        }

        let sel = NSSelectorFromString("application:openURL:options:")

        // The IMP: block invoked as (self, _cmd, app, url, options) -> Bool.
        let block: @convention(block) (AnyObject, UIApplication, URL, [AnyHashable: Any]) -> Bool = { _, _, url, _ in
            URLSchemeHandler.shared.record(url)
            return true
        }
        let imp = imp_implementationWithBlock(block)
        // Type encoding: BOOL, self, _cmd, id, id, id  → "B@:@@@"
        let types = "B@:@@@"

        if class_getInstanceMethod(delegateClass, sel) != nil {
            // Already implemented — swap ours in via a fresh method + exchange.
            let tmpSel = NSSelectorFromString("ictrl_application:openURL:options:")
            class_addMethod(delegateClass, tmpSel, imp, types)
            if let m1 = class_getInstanceMethod(delegateClass, sel),
               let m2 = class_getInstanceMethod(delegateClass, tmpSel) {
                method_exchangeImplementations(m1, m2)
            }
        } else {
            class_addMethod(delegateClass, sel, imp, types)
        }
        iCTRLUITests.logBuffer.append("🔗 ictrl:// URL handler installed")
    }
}
