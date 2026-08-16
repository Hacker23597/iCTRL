import Foundation

/// Persists the signing identity issued by Apple: the certificate, its private
/// key, and the team it belongs to.
///
/// This is worth storing rather than re-fetching because a free Apple developer
/// account may hold exactly one certificate at a time. Requesting a second one
/// revokes the first, which silently breaks every app already signed with it —
/// so the identity has to survive relaunches, and losing it has a real cost to
/// the user rather than just meaning "log in again".
///
/// Stored as a file rather than in the Keychain, following `TokenFileStore`.
/// The reason is sharper here than it was there: signing changes the team
/// prefix, and a keychain item is scoped by that prefix. A tool whose whole job
/// is re-signing apps would be storing its identity in the one place its own
/// operation invalidates.
///
/// The Apple ID password is deliberately *not* stored. It is used once during
/// authentication and then discarded; what persists is the certificate, which
/// is what later signing actually needs.
enum SigningIdentityStore {

    /// What Apple issued us, and the account context needed to use it again.
    struct Identity: Codable, Equatable {
        var teamID: String
        var teamName: String
        var isFreeAccount: Bool

        /// PKCS#12 blob holding the certificate and its private key.
        var p12Data: Data
        /// Passphrase for `p12Data`. Generated locally; stored beside the blob
        /// because it protects nothing on its own — the file is the secret.
        var p12Password: String

        var certificateName: String
        var issuedAt: Date

        /// Apple ID this was issued for, kept so the UI can say whose identity
        /// this is and notice when a different account signs in.
        var appleID: String

        /// Free-account certificates are short-lived. Apple doesn't state the
        /// lifetime in the issuance response, so this is derived from the
        /// well-known 7-day free-account limit and used only to warn — never to
        /// refuse a signing attempt, since the real authority is Apple.
        var likelyExpiry: Date? {
            isFreeAccount ? Calendar.current.date(byAdding: .day, value: 7, to: issuedAt) : nil
        }

        var isProbablyExpired: Bool {
            guard let likelyExpiry else { return false }
            return Date() >= likelyExpiry
        }
    }

    /// <sandbox>/Library/Application Support/iCTRL/signing_identity.json
    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("iCTRL", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signing_identity.json")
    }

    static var exists: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func save(_ identity: Identity) {
        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder().encode(identity) else {
            ictrlLog("❌ Couldn't encode the signing identity")
            return
        }
        try? data.write(to: url, options: .atomic)

        // Device-local secret: keeping it out of iCloud backups stops a
        // certificate from being restored onto a device it wasn't issued for.
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)

        ictrlLog("Stored signing identity for team \(identity.teamID) (\(identity.certificateName))")
    }

    static func load() -> Identity? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        guard let identity = try? JSONDecoder().decode(Identity.self, from: data) else {
            // A shape change between versions shouldn't strand the user with an
            // unreadable file and no way forward.
            ictrlLog("⚠️ Stored signing identity couldn't be read; discarding it")
            clear()
            return nil
        }
        return identity
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
