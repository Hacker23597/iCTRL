import Foundation
import UniformTypeIdentifiers

/// Where the device pairing record lives.
///
/// The pairing file is what `idevicepair pair` writes on a Mac: a plist holding
/// the host certificate and keys that let a client authenticate to this device's
/// `lockdownd`. Mounting a DDI needs one because the mount goes through the same
/// trusted channel Xcode would use.
///
/// Only its *path* matters to the mounting code — the plist is parsed by the
/// idevice library, never here.
enum PairingFileStore {

    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.propertyList, .xml, .data]
        // The extensions Apple's tooling and the community write. Declared as
        // conforming to .data so the picker accepts them even though the system
        // has no UTI registered for them.
        for ext in ["mobiledevicepairing", "mobiledevicepair", "plist"] {
            if let t = UTType(filenameExtension: ext, conformingTo: .data) {
                types.append(t)
            }
        }
        return types
    }()

    /// Application Support/Pairing/pairingFile.plist — outside Documents so it
    /// isn't casually deleted from the Files app, since losing it means
    /// re-pairing from a Mac.
    static var storedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Pairing/pairingFile.plist")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: storedURL.path)
    }

    /// When the current file was imported — shown in the UI so a stale pairing
    /// file (a common cause of confusing mount failures) is at least visible.
    static var importedAt: Date? {
        try? FileManager.default.attributesOfItem(atPath: storedURL.path)[.modificationDate] as? Date
    }

    /// Copy a user-picked file into place.
    ///
    /// The picker hands back a security-scoped URL that is only readable inside
    /// a start/stop pair, so the bytes are copied out immediately rather than
    /// holding the URL.
    static func importFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        try validate(data)

        let dest = storedURL
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 0600 from the start: this file authenticates as a trusted host to the
        // device, so it deserves the same care as a private key.
        try data.write(to: dest, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dest.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: storedURL)
    }

    /// Reject anything that clearly isn't a pairing record, so the failure lands
    /// at import time with a clear message instead of surfacing later as an
    /// opaque error from deep inside the mount.
    private static func validate(_ data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            throw DDIError.invalidPairingFile("Not a property list. Expected the file "
                + "`idevicepair pair` writes (a .plist / .mobiledevicepairing).")
        }
        // These are the fields a lockdown pairing record always carries.
        let required = ["HostID", "HostCertificate", "HostPrivateKey"]
        let missing = required.filter { plist[$0] == nil }
        guard missing.isEmpty else {
            throw DDIError.invalidPairingFile(
                "Missing \(missing.joined(separator: ", ")). This looks like a "
                + "property list but not a pairing record — re-export it with "
                + "`idevicepair pair` (libimobiledevice) or pymobiledevice3.")
        }
    }
}
