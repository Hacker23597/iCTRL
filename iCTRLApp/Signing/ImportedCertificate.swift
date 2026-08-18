import Foundation

/// A signing certificate the user supplied, rather than one iCTRL requested.
///
/// This exists mainly for paid developer accounts, where it is strictly better
/// than signing in: a paid certificate lasts a year instead of a week, and
/// importing it skips Apple ID authentication entirely — which means skipping
/// the anisette server, the only part of the pipeline that depends on a third
/// party seeing the fingerprint your account logs in under.
///
/// It is not a general replacement for signing in. A certificate proves who is
/// signing; it does not register a bundle identifier or produce a provisioning
/// profile, and iOS refuses an app whose profile doesn't cover its bundle ID and
/// this device. So an imported certificate is enough to **re-sign a package that
/// already carries a valid profile** — notably iCTRL's own runner — and not
/// enough to sign an arbitrary app for the first time. `AppSigner` decides which
/// case it is rather than letting the user discover it at install time.
///
/// Sources that produce a usable .p12:
///   - Keychain Access, exporting an "Apple Development"/"Apple Distribution"
///     identity from a paid account
///   - a sideloader that writes one out (iLoader emits `ALTCertificate.p12`
///     with the machine ID as its password)
enum ImportedCertificate {

    struct Stored: Codable, Equatable {
        var p12Data: Data
        /// Kept because the .p12 cannot be opened without it. Empty string is a
        /// real, common value — SideStore stores its own certificate that way.
        var password: String
        var commonName: String
        var teamID: String?
        var expiresAt: Date?
        var importedAt: Date

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt
        }
    }

    enum ImportError: LocalizedError {
        case unreadable
        case wrongPassword
        case noIdentity
        case expired(Date)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't a PKCS#12 certificate."
            case .wrongPassword:
                return "Wrong password for this .p12."
            case .noIdentity:
                return "That .p12 has no signing identity — it may hold only a certificate, without its private key."
            case .expired(let date):
                let f = DateFormatter()
                f.dateStyle = .medium
                return "That certificate expired on \(f.string(from: date))."
            }
        }
    }

    /// <sandbox>/Library/Application Support/iCTRL/imported_certificate.json
    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("iCTRL", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("imported_certificate.json")
    }

    static var exists: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Importing

    /// Validates a .p12 and stores it.
    ///
    /// Validation happens here rather than at signing time so a bad file is
    /// rejected while the user is still looking at the file picker, instead of
    /// failing later inside a signing pass that reports it as something else.
    static func importCertificate(from url: URL, password: String) throws -> Stored {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }

        // SecPKCS12Import is the authority on whether the file and password go
        // together — parsing it ourselves would accept things the system won't.
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData,
                                     [kSecImportExportPassphrase as String: password] as CFDictionary,
                                     &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure: throw ImportError.wrongPassword
        default: throw ImportError.unreadable
        }

        guard let entries = items as? [[String: Any]], let first = entries.first,
              let identity = first[kSecImportItemIdentity as String]
        else {
            throw ImportError.noIdentity
        }

        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity as! SecIdentity, &certificate)
        guard let certificate else { throw ImportError.noIdentity }

        let commonName = copyCommonName(certificate) ?? "Imported certificate"
        let expiry = copyExpiry(certificate)
        if let expiry, expiry < Date() { throw ImportError.expired(expiry) }

        let stored = Stored(p12Data: data,
                            password: password,
                            commonName: commonName,
                            teamID: copyTeamID(certificate),
                            expiresAt: expiry,
                            importedAt: Date())
        save(stored)
        ictrlLog("Imported certificate \(commonName)\(expiry.map { " (expires \($0))" } ?? "")")
        return stored
    }

    // MARK: - Reading certificate fields

    private static func copyCommonName(_ certificate: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    /// The team ID, taken from the parenthesised suffix Apple puts in the
    /// certificate's common name ("Apple Development: Name (TEAMID)").
    ///
    /// Read from the name rather than the subject's OU field because
    /// `SecCertificateCopyValues` — the API that exposes individual X.509
    /// fields — is macOS-only. Nothing on iOS reads them without parsing DER by
    /// hand, and the team ID is not worth that.
    private static func copyTeamID(_ certificate: SecCertificate) -> String? {
        guard let name = copyCommonName(certificate),
              let open = name.lastIndex(of: "("),
              let close = name.lastIndex(of: ")"),
              open < close
        else { return nil }
        let id = name[name.index(after: open)..<close]
        return id.isEmpty ? nil : String(id)
    }

    /// Expiry, via a trust evaluation rather than by reading the field.
    ///
    /// iOS offers no API for notAfter, but it will tell us whether a
    /// certificate is valid *at a given date* — so this asks about a sequence of
    /// dates and reports when validity ends. Coarse by design: the value is
    /// shown to the user and used for an "is it expired" check, and a day's
    /// precision is enough for both.
    private static func copyExpiry(_ certificate: SecCertificate) -> Date? {
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trust else { return nil }

        // Apple development certificates last a week (free) or a year (paid);
        // probing out to ~14 months covers both with room to spare.
        guard isValid(trust, at: Date()) else { return Date() }
        var low = 0, high = 430
        while low < high {
            let mid = (low + high + 1) / 2
            let date = Calendar.current.date(byAdding: .day, value: mid, to: Date()) ?? Date()
            if isValid(trust, at: date) { low = mid } else { high = mid - 1 }
        }
        return Calendar.current.date(byAdding: .day, value: low, to: Date())
    }

    private static func isValid(_ trust: SecTrust, at date: Date) -> Bool {
        SecTrustSetVerifyDate(trust, date as CFDate)
        var error: CFError?
        // Trust evaluation also fails for an untrusted chain, which a
        // self-signed or unusual certificate may hit — but the date is the only
        // thing changing across these calls, so the boundary it finds is the
        // validity boundary.
        return SecTrustEvaluateWithError(trust, &error)
    }

    // MARK: - Persistence

    static func save(_ stored: Stored) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
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
    }
}
