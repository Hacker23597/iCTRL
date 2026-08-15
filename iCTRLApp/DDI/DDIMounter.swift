import Foundation
import IDevice

enum DDIError: LocalizedError {
    case invalidPairingFile(String)
    case missingPairingFile
    case missingImage
    case tunnelUnavailable(String)
    case ffi(String, String)          // operation, message
    case downloadFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidPairingFile(let why):
            return "Pairing file rejected: \(why)"
        case .missingPairingFile:
            return "No pairing file imported yet."
        case .missingImage:
            return "Developer Disk Image files are missing — download them first."
        case .tunnelUnavailable(let why):
            return "Can't reach the device's debug service: \(why)"
        case .ffi(let op, let msg):
            return "\(op) failed: \(msg)"
        case .downloadFailed(let file, let why):
            return "Couldn't download \(file): \(why)"
        }
    }
}

/// Mounts the Developer Disk Image on this device, from this device.
///
/// The trick — and it is StikDebug's, ported here — is that no privileged
/// entitlement is involved. A local VPN app (LocalDevVPN / StosVPN) makes the
/// device's own `remoted` service routable at 10.7.0.1:49152, and this code then
/// talks to it as an ordinary network client, exactly as Xcode on a Mac would.
/// The pairing file is what authenticates that conversation.
///
/// All of the real work happens in the `idevice` Rust library (MIT); this is the
/// Swift side that sequences it.
@MainActor
final class DDIMounter: ObservableObject {

    /// Where LocalDevVPN/StosVPN publishes this device. Both use the same
    /// address, and it is not configurable in either app.
    static let tunnelAddress = "10.7.0.1"
    /// `remoted` — the RemotePairing service the tunnel exposes.
    static let tunnelPort: UInt16 = 49152

    enum Phase: Equatable {
        case idle
        case connecting
        case queryingDevice
        case uploading(Double)      // 0…1
        case finalizing
        case mounted
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isRunning: Bool {
        switch phase {
        case .idle, .mounted, .failed: return false
        default: return true
        }
    }

    /// Mount the image. Long-running and blocking at the FFI layer, so the whole
    /// sequence runs off the main actor and only publishes back to it.
    func mount() async {
        guard !isRunning else { return }
        phase = .connecting

        do {
            guard PairingFileStore.exists else { throw DDIError.missingPairingFile }
            guard DeveloperDiskImageStore.isComplete else { throw DDIError.missingImage }

            let pairingPath = PairingFileStore.storedURL.path
            let image = try Data(contentsOf: DeveloperDiskImageStore.url(for: .image))
            let trustCache = try Data(contentsOf: DeveloperDiskImageStore.url(for: .trustCache))
            let manifest = try Data(contentsOf: DeveloperDiskImageStore.url(for: .buildManifest))

            // A dedicated Thread with an explicit stack, not a Task.
            //
            // The TSS request builds a reqwest client, whose TLS setup needs far
            // more stack than a Swift concurrency worker provides — it aborted
            // there (SIGABRT, panic inside ClientBuilder::build) on the first
            // real mount. StikDebug runs the same call on a plain Thread for the
            // same reason; 4MB is generous enough not to have to think about it.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let thread = Thread {
                    do {
                        try Self.performMount(pairingPath: pairingPath,
                                              image: image, trustCache: trustCache,
                                              manifest: manifest) { phase in
                            Task { @MainActor in self.phase = phase }
                        }
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                thread.stackSize = 4 * 1024 * 1024
                thread.name = "ictrl.ddi.mount"
                thread.qualityOfService = .userInitiated
                thread.start()
            }

            phase = .mounted
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - FFI

    nonisolated private static func performMount(pairingPath: String, image: Data, trustCache: Data,
                                     manifest: Data,
                                     report: @escaping (Phase) -> Void) throws {
        var pairing: OpaquePointer?
        try check("Reading pairing file") { rp_pairing_file_read(pairingPath, &pairing) }
        defer { if let pairing { rp_pairing_file_free(pairing) } }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = tunnelPort.bigEndian
        guard tunnelAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw DDIError.tunnelUnavailable("bad tunnel address")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { sa in
                try check("Connecting to the device") {
                    tunnel_create_rppairing(sa, idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                                            "iCTRL", pairing, nil, nil, &adapter, &handshake)
                }
            }
        }
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        guard let adapter, let handshake else {
            throw DDIError.tunnelUnavailable("tunnel returned no handles")
        }

        report(.queryingDevice)

        // The ECID identifies this specific device to Apple's signing service.
        // A personalized image is signed for one device and one nonce, which is
        // why this can't be pre-baked.
        let ecid = try uniqueChipID(adapter: adapter, handshake: handshake)

        var client: OpaquePointer?
        try check("Opening the image mounter") {
            image_mounter_connect_rsd(adapter, handshake, &client)
        }
        defer { if let client { image_mounter_free(client) } }
        guard let client else { throw DDIError.ffi("Opening the image mounter", "no client") }

        report(.uploading(0))

        // Progress arrives on a Rust thread; the context carries the callback so
        // no global state is involved.
        final class ProgressBox { let report: (Phase) -> Void; init(_ r: @escaping (Phase) -> Void) { report = r } }
        let box = Unmanaged.passRetained(ProgressBox(report))
        defer { box.release() }

        try image.withUnsafeBytes { img in
            try trustCache.withUnsafeBytes { tc in
                try manifest.withUnsafeBytes { mf in
                    try check("Mounting the image") {
                        image_mounter_mount_personalized_with_callback_rsd(
                            client, adapter, handshake,
                            img.bindMemory(to: UInt8.self).baseAddress, image.count,
                            tc.bindMemory(to: UInt8.self).baseAddress, trustCache.count,
                            mf.bindMemory(to: UInt8.self).baseAddress, manifest.count,
                            nil,
                            ecid,
                            { progress, total, context in
                                guard let context, total > 0 else { return }
                                let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
                                box.report(.uploading(Double(progress) / Double(total)))
                            },
                            box.toOpaque())
                    }
                }
            }
        }
        report(.finalizing)
    }

    /// Read `UniqueChipID` (ECID) from lockdownd.
    nonisolated private static func uniqueChipID(adapter: OpaquePointer, handshake: OpaquePointer) throws -> UInt64 {
        var client: OpaquePointer?
        try check("Connecting to lockdownd") {
            lockdownd_connect_rsd(adapter, handshake, &client)
        }
        defer { if let client { lockdownd_client_free(client) } }
        guard let client else { throw DDIError.ffi("Connecting to lockdownd", "no client") }

        // No start_session here. A lockdownd client reached over the RSD tunnel
        // is already authenticated by the RemotePairing handshake, so opening a
        // second session on it is rejected — that is the InvalidConnection
        // (code 15) this used to fail with. WebDriverAgent's equivalent (and
        // StikDebug's) reads the value straight off the connected client.
        var value: plist_t?
        try check("Reading UniqueChipID") {
            lockdownd_get_value(client, "UniqueChipID", nil, &value)
        }
        defer { if let value { plist_free(value) } }
        guard let value else { throw DDIError.ffi("Reading UniqueChipID", "no value") }

        var ecid: UInt64 = 0
        plist_get_uint_val(value, &ecid)
        guard ecid != 0 else { throw DDIError.ffi("Reading UniqueChipID", "device returned 0") }
        return ecid
    }

    /// Turn an `IdeviceFfiError*` into a Swift error, freeing it either way.
    ///
    /// The FFI reports failure by returning a pointer that the caller owns —
    /// ignoring it leaks, and reading `.message` after freeing is a use-after-free,
    /// so the message is copied out before the free.
    @discardableResult
    nonisolated private static func check(_ operation: String,
                              _ call: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws -> Bool {
        guard let err = call() else { return true }
        let message = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
        let code = err.pointee.code
        idevice_error_free(err)
        throw DDIError.ffi(operation, "\(message) (code \(code))")
    }
}
