import Foundation

/// Remembers an authenticated Apple ID session so signing doesn't need a fresh
/// login every time.
///
/// SideStore keeps four things for this: the email, the password, and the
/// `adsid`/`xcodeToken` pair that identifies an already-authenticated session.
/// Its `AuthenticationOperation` tries them in that order — token first, then a
/// silent re-login with the stored password — which is why its users rarely see
/// a login prompt.
///
/// iCTRL deliberately stops one step short: it stores the **token pair and the
/// email, never the password**. The token expires and can be revoked from
/// appleid.apple.com; a stored password cannot, and it opens the whole account
/// rather than one signing session. The cost is honest — when the token stops
/// working, the user types their password again instead of it happening
/// silently — and that is the intended trade, not an omission.
///
/// Stored in a file rather than the Keychain, following `TokenFileStore`. A
/// keychain item is scoped by the team prefix, and re-signing changes it; a
/// tool that re-signs apps would be putting its credentials in the one place
/// its own operation invalidates.
enum AppleIDSession {

    struct Stored: Codable, Equatable {
        var appleID: String
        /// Apple's session identifier, returned by GSA after a successful login.
        var adsid: String
        /// The token Xcode-style clients present instead of re-authenticating.
        var xcodeToken: String
        var savedAt: Date

        /// Apple doesn't state a lifetime, and guessing one would either expire
        /// a working session or keep a dead one. This is used only to show the
        /// user how old the session is — whether it still works is decided by
        /// Apple rejecting it, not by us.
        var age: TimeInterval { Date().timeIntervalSince(savedAt) }
    }

    /// <sandbox>/Library/Application Support/iCTRL/appleid_session.json
    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("iCTRL", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("appleid_session.json")
    }

    static var exists: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func save(appleID: String, adsid: String, xcodeToken: String) {
        guard let url = fileURL else { return }
        let stored = Stored(appleID: appleID, adsid: adsid, xcodeToken: xcodeToken, savedAt: Date())
        guard let data = try? JSONEncoder().encode(stored) else { return }

        try? data.write(to: url, options: .atomic)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)

        ictrlLog("Stored Apple ID session for \(appleID)")
    }

    static func load() -> Stored? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            clear()
            return nil
        }
        return stored
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        ictrlLog("Cleared the stored Apple ID session")
    }
}
