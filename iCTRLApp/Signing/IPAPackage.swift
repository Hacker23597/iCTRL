import Foundation

/// Unpacks and repacks `.ipa` files around signing.
///
/// Signing works on an unpacked `.app` bundle, but what users have — and what
/// `IPAInstaller` sends to the device — is an `.ipa`. This bridges the two.
///
/// The zip work is AltSign's `NSFileManager+Apps`, which already knows the one
/// detail that matters: an `.ipa` holds its bundle under `Payload/`, and
/// installation_proxy rejects an archive whose bundle sits at the root. Using
/// its implementation rather than a general-purpose zip keeps that convention
/// in one place.
enum IPAPackage {

    enum PackageError: LocalizedError {
        case notAnIPA(String)
        case noPayload
        case unpackFailed(String)
        case repackFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAnIPA(let why):
                return "This doesn't look like an .ipa: \(why)"
            case .noPayload:
                return "The archive has no app inside it to sign."
            case .unpackFailed(let why):
                return "Couldn't unpack the .ipa: \(why)"
            case .repackFailed(let why):
                return "Couldn't repack the .ipa: \(why)"
            }
        }
    }

    /// An unpacked package. Call `cleanUp` when finished.
    struct Unpacked {
        /// Temporary directory that everything lives under.
        let root: URL
        /// The `.app` bundle — what the signer operates on.
        let appURL: URL
    }

    /// Unpacks `ipaURL` into a fresh temporary directory.
    static func unpack(_ ipaURL: URL) throws -> Unpacked {
        // Cheap structural check first: a non-zip fails deep inside minizip
        // with an error that says nothing useful.
        let handle = try? FileHandle(forReadingFrom: ipaURL)
        let magic = try? handle?.read(upToCount: 2)
        try? handle?.close()
        guard magic == Data([0x50, 0x4B]) else {
            throw PackageError.notAnIPA("it isn't a zip archive")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            let appURL = try FileManager.default.unzipAppBundle(at: ipaURL, toDirectory: root)
            ictrlLog("Unpacked \(ipaURL.lastPathComponent) → \(appURL.lastPathComponent)")
            return Unpacked(root: root, appURL: appURL)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw PackageError.unpackFailed(error.localizedDescription)
        }
    }

    /// Repacks a signed bundle into a new `.ipa`.
    ///
    /// The result goes to a new file rather than over the original: the source
    /// is usually a security-scoped file the user picked from somewhere else,
    /// and overwriting their input on the way to installing it isn't a
    /// recoverable mistake if signing produced something broken.
    static func repack(_ unpacked: Unpacked) throws -> URL {
        do {
            let ipaURL = try FileManager.default.zipAppBundle(at: unpacked.appURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path))?[.size] as? Int ?? 0
            ictrlLog("Repacked → \(ipaURL.lastPathComponent) (\(size)B)")
            return ipaURL
        } catch {
            throw PackageError.repackFailed(error.localizedDescription)
        }
    }

    static func cleanUp(_ unpacked: Unpacked) {
        try? FileManager.default.removeItem(at: unpacked.root)
    }
}
