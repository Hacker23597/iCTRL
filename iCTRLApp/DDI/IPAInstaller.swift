import Foundation
import IDevice

/// Installs an .ipa onto this device over the same RSD tunnel the DDI mounter
/// uses.
///
/// This is the last stage of the self-signing pipeline and deliberately the
/// first one built: everything upstream (Apple ID auth, certificate issuance,
/// re-signing) is worthless if the device won't accept an install over this
/// transport at all. It takes an already-signed .ipa so that question is
/// answered on its own, before any of that machinery exists.
///
/// The path is: AFC uploads the package into the installation staging area,
/// then installation_proxy is pointed at it *by its path inside the AFC jail* —
/// not a filesystem path, which is why the upload can't be skipped.
enum IPAInstaller {

    enum Phase: Equatable {
        case idle
        case connecting
        case uploading(Double)      // 0...1
        case installing(Double)     // 0...1, as reported by installation_proxy
        case done(String)           // bundle id, when we could read it
        case failed(String)
    }

    enum InstallError: LocalizedError {
        case tunnelUnavailable(String)
        case ffi(String, String)
        case badPackage(String)

        var errorDescription: String? {
            switch self {
            case .tunnelUnavailable(let why):
                return "Can't reach the device: \(why). Is LocalDevVPN connected?"
            case .ffi(let op, let msg):
                return "\(op) failed: \(msg)"
            case .badPackage(let why):
                return "This file can't be installed: \(why)"
            }
        }
    }

    /// Where AFC expects packages awaiting installation. installation_proxy
    /// resolves `package_path` relative to the AFC jail, so this prefix is part
    /// of the contract between the two services rather than a choice.
    private static let stagingDir = "PublicStaging"

    // MARK: - Entry point

    /// Installs `ipaURL`, reporting progress on the main actor.
    ///
    /// `pairingPath` and the tunnel address come from the same store the DDI
    /// mounter uses — an install and a mount are the same connection with a
    /// different service on top.
    static func install(ipaURL: URL,
                        pairingPath: String,
                        report: @escaping @MainActor (Phase) -> Void) async {
        let name = ipaURL.lastPathComponent
        ictrlLog("IPA install starting — \(name)")

        await report(.connecting)
        do {
            let data = try Data(contentsOf: ipaURL)
            guard data.count > 4, Array(data.prefix(2)) == [0x50, 0x4B] else {
                // "PK" — an .ipa is a zip. Catching this here turns a confusing
                // mid-install failure into an answerable one.
                throw InstallError.badPackage("not a zip archive (an .ipa should start with PK)")
            }
            ictrlLog("IPA install — package is \(data.count)B")

            let bundleId = try await performInstall(pairingPath: pairingPath,
                                                    fileName: name,
                                                    package: data,
                                                    report: report)
            ictrlLog("✅ IPA install finished — \(bundleId ?? "unknown bundle id")")
            await report(.done(bundleId ?? name))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            ictrlLog("❌ IPA install failed: \(message)")
            await report(.failed(message))
        }
    }

    // MARK: - Tunnel + services

    private static func performInstall(pairingPath: String,
                                       fileName: String,
                                       package: Data,
                                       report: @escaping @MainActor (Phase) -> Void) async throws -> String? {
        // Same crypto-provider priming the mounter needs: the FFI builds reqwest
        // with rustls-no-provider, and a missing process default aborts inside
        // Client::new() rather than returning an error.
        DDIMounter.primeCryptoProvider()

        guard LocalDevVPN.isTunnelUp() else {
            throw InstallError.tunnelUnavailable("the local tunnel isn't up")
        }

        var pairing: OpaquePointer?
        try check("Reading pairing file") { rp_pairing_file_read(pairingPath, &pairing) }
        defer { if let pairing { rp_pairing_file_free(pairing) } }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = DDIMounter.tunnelPort.bigEndian
        guard DDIMounter.tunnelAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw InstallError.tunnelUnavailable("bad tunnel address")
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
            throw InstallError.tunnelUnavailable("tunnel returned no handles")
        }

        let remotePath = "\(stagingDir)/\(sanitized(fileName))"
        try uploadViaAFC(adapter: adapter, handshake: handshake,
                         package: package, remotePath: remotePath, report: report)
        try installStagedPackage(adapter: adapter, handshake: handshake,
                                 remotePath: remotePath, report: report)
        return nil   // installation_proxy doesn't hand back the bundle id here
    }

    // MARK: - AFC upload

    private static func uploadViaAFC(adapter: OpaquePointer, handshake: OpaquePointer,
                                     package: Data, remotePath: String,
                                     report: @escaping @MainActor (Phase) -> Void) throws {
        var afc: OpaquePointer?
        try check("Opening the file service") { afc_client_connect_rsd(adapter, handshake, &afc) }
        defer { if let afc { afc_client_free(afc) } }
        guard let afc else { throw InstallError.ffi("Opening the file service", "no client") }

        // Already-exists is the normal case and not an error worth failing on.
        if let err = afc_make_directory(afc, stagingDir) { idevice_error_free(err) }

        var file: OpaquePointer?
        try check("Creating \(remotePath)") {
            afc_file_open(afc, remotePath, AfcWrOnly, &file)
        }
        guard let file else { throw InstallError.ffi("Creating \(remotePath)", "no handle") }
        var closed = false
        defer { if !closed, let e = afc_file_close(file) { idevice_error_free(e) } }

        // Chunked so the UI can show progress and so a large package doesn't sit
        // in one enormous FFI call.
        let chunkSize = 1 << 20   // 1 MiB
        var offset = 0
        while offset < package.count {
            let end = min(offset + chunkSize, package.count)
            let chunk = package[offset..<end]
            try chunk.withUnsafeBytes { raw -> Void in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                try check("Writing to \(remotePath)") {
                    afc_file_write(file, base, raw.count)
                }
            }
            offset = end
            let fraction = Double(offset) / Double(package.count)
            Task { @MainActor in report(.uploading(fraction)) }
        }

        try check("Finishing \(remotePath)") { afc_file_close(file) }
        closed = true
        ictrlLog("IPA install — uploaded \(package.count)B to \(remotePath)")
    }

    // MARK: - installation_proxy

    /// Boxed so the C progress callback — which only carries a void* — can reach
    /// back into Swift without capturing anything.
    private final class ProgressBox {
        let report: @MainActor (Phase) -> Void
        init(_ report: @escaping @MainActor (Phase) -> Void) { self.report = report }
    }

    private static func installStagedPackage(adapter: OpaquePointer, handshake: OpaquePointer,
                                             remotePath: String,
                                             report: @escaping @MainActor (Phase) -> Void) throws {
        var client: OpaquePointer?
        try check("Opening the installer") {
            installation_proxy_connect_rsd(adapter, handshake, &client)
        }
        defer { if let client { installation_proxy_client_free(client) } }
        guard let client else { throw InstallError.ffi("Opening the installer", "no client") }

        Task { @MainActor in report(.installing(0)) }

        let box = ProgressBox(report)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }

        try check("Installing the package") {
            installation_proxy_install_with_callback(client, remotePath, nil, { progress, context in
                guard let context else { return }
                let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
                let fraction = min(1.0, Double(progress) / 100.0)
                Task { @MainActor in box.report(.installing(fraction)) }
            }, ctx)
        }
    }

    // MARK: - Helpers

    /// AFC paths are flat here; strip anything that could escape the staging
    /// directory or confuse the service.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return cleaned.isEmpty ? "package.ipa" : cleaned
    }

    private static func check(_ operation: String, _ body: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let err = body() else { return }
        let code = err.pointee.code
        let message = err.pointee.message.map { String(cString: $0) } ?? "unknown"
        idevice_error_free(err)
        ictrlLog("❌ \(operation): \(message) (code \(code))")
        throw InstallError.ffi(operation, "\(message) (code \(code))")
    }
}
