import Foundation
import CryptoKit

/// End-to-end encryption + authentication for iCTRL, modeled on Android ADB's
/// key-pair pairing but adapted to HTTP JSON-RPC and built entirely on CryptoKit
/// (no third-party crypto). Design:
///
///  - Each side has a Curve25519 key pair. The server's is persistent.
///  - PAIRING (once, like ADB "Allow USB debugging"): the client sends its public
///    key; the server shows the key FINGERPRINT in a confirm notification; on
///    approval it stores the client key and returns its own public key.
///  - SESSION KEY: both sides do X25519 ECDH(own private, peer public) → HKDF →
///    a 256-bit AES key. Never transmitted.
///  - TRANSPORT: each request/response body is an encrypted envelope (AES-GCM)
///    carrying a 12-byte nonce + a millisecond timestamp; the server rejects
///    stale timestamps (±window) and replayed nonces.
///
/// The plaintext Bearer path (/auth, /rpc) stays for backward compatibility; this
/// adds /pair and /rpc/secure.
final class SecureChannel {
    static let shared = SecureChannel()

    // Anti-replay: reject timestamps outside this window, and remember recent
    // nonces to catch replays inside it.
    private static let timestampWindowMs: Int64 = 60_000   // ±60s
    private static let maxRememberedNonces = 4096

    private let lock = NSLock()

    // Server's persistent identity key pair.
    private var serverPrivateKey: Curve25519.KeyAgreement.PrivateKey
    var serverPublicKeyBase64: String {
        serverPrivateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    // pairing_id → paired client
    private var pairings: [String: Pairing] = [:]
    // recently-seen nonces (base64) for replay protection, FIFO-capped
    private var seenNonces: [String] = []
    private var seenNonceSet: Set<String> = []

    // MARK: - Model

    struct Pairing: Codable {
        let pairingId: String
        let clientName: String
        let clientPublicKey: Data      // Curve25519 raw (32 bytes)
        let fingerprint: String        // human-readable, shown at pairing time
        let pairedAt: Date
        var lastActiveAt: Date
    }

    private init() {
        // Load or create the server key pair (persisted in the sandbox file store).
        if let raw = SecureKeyStore.loadServerPrivateKey(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            serverPrivateKey = key
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            SecureKeyStore.saveServerPrivateKey(key.rawRepresentation)
            serverPrivateKey = key
        }
        loadPairings()
    }

    // MARK: - Fingerprint

    /// Human-readable fingerprint of a public key: SHA-256, first 8 bytes as
    /// colon-separated hex (like an SSH/ADB key fingerprint).
    static func fingerprint(of publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - Pairing

    /// Register a client public key and return a new pairing. Caller must have
    /// obtained user approval first (the fingerprint is what the user confirmed).
    func createPairing(clientName: String, clientPublicKey: Data) -> Pairing {
        let p = Pairing(
            pairingId: UUID().uuidString,
            clientName: clientName,
            clientPublicKey: clientPublicKey,
            fingerprint: Self.fingerprint(of: clientPublicKey),
            pairedAt: Date(),
            lastActiveAt: Date()
        )
        lock.lock()
        pairings[p.pairingId] = p
        persistLocked()
        lock.unlock()
        return p
    }

    func pairing(for id: String) -> Pairing? {
        lock.lock(); defer { lock.unlock() }
        return pairings[id]
    }

    func removePairing(id: String) {
        lock.lock(); pairings.removeValue(forKey: id); persistLocked(); lock.unlock()
    }

    func allPairings() -> [Pairing] {
        lock.lock(); defer { lock.unlock() }
        return Array(pairings.values).sorted { $0.pairedAt > $1.pairedAt }
    }

    // MARK: - Session key (ECDH → HKDF)

    private func sessionKey(for pairing: Pairing) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pairing.clientPublicKey)
        let shared = try serverPrivateKey.sharedSecretFromKeyAgreement(with: peer)
        // Derive a stable 256-bit key. Salt/info bind it to this protocol.
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("iCTRL-x25519".utf8),
            sharedInfo: Data("ictrl.secure.v1".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Envelope open/seal

    struct Envelope: Codable {
        let nonce: String        // base64, 12 bytes (AES-GCM nonce)
        let ts: Int64            // client unix ms
        let ciphertext: String   // base64 (AES-GCM combined: ct||tag)
    }

    enum SecureError: Error { case unknownPairing, staleTimestamp, replayed, badEnvelope, cryptoFailed }

    /// Decrypt an incoming envelope into plaintext (the JSON-RPC request bytes).
    /// Enforces timestamp window + nonce replay protection. `nowMs` is injectable
    /// for testing; defaults to the current time.
    func open(envelope: Envelope, pairingId: String, nowMs: Int64) throws -> Data {
        guard let pairing = pairing(for: pairingId) else { throw SecureError.unknownPairing }

        // Anti-replay: timestamp window.
        if abs(nowMs - envelope.ts) > Self.timestampWindowMs { throw SecureError.staleTimestamp }
        // Anti-replay: nonce not seen before.
        try rememberNonceOrThrow(envelope.nonce)

        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let ct = Data(base64Encoded: envelope.ciphertext),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw SecureError.badEnvelope
        }
        let key = try sessionKey(for: pairing)
        // ciphertext is the AES-GCM "combined" form minus the nonce we carry
        // separately: reconstruct a SealedBox from nonce + (ct||tag).
        guard let box = try? AES.GCM.SealedBox(combined: nonceData + ct) else {
            throw SecureError.badEnvelope
        }
        guard let plaintext = try? AES.GCM.open(box, using: key) else {
            throw SecureError.cryptoFailed
        }
        _ = nonce  // (validated above)
        touch(pairingId: pairingId)
        return plaintext
    }

    /// Encrypt plaintext (the JSON-RPC response bytes) into an envelope to send
    /// back to the client.
    func seal(plaintext: Data, pairingId: String, nowMs: Int64) throws -> Envelope {
        guard let pairing = pairing(for: pairingId) else { throw SecureError.unknownPairing }
        let key = try sessionKey(for: pairing)
        let nonce = AES.GCM.Nonce()  // random 12 bytes
        guard let box = try? AES.GCM.seal(plaintext, using: key, nonce: nonce) else {
            throw SecureError.cryptoFailed
        }
        let nonceData = Data(nonce)
        // Envelope carries nonce separately; ciphertext = combined minus nonce.
        let ctAndTag = box.combined!.dropFirst(nonceData.count)
        return Envelope(nonce: nonceData.base64EncodedString(),
                        ts: nowMs,
                        ciphertext: Data(ctAndTag).base64EncodedString())
    }

    // MARK: - Replay bookkeeping

    private func rememberNonceOrThrow(_ nonce: String) throws {
        lock.lock(); defer { lock.unlock() }
        if seenNonceSet.contains(nonce) { throw SecureError.replayed }
        seenNonces.append(nonce)
        seenNonceSet.insert(nonce)
        if seenNonces.count > Self.maxRememberedNonces {
            let drop = seenNonces.removeFirst()
            seenNonceSet.remove(drop)
        }
    }

    private func touch(pairingId: String) {
        lock.lock()
        if var p = pairings[pairingId] { p.lastActiveAt = Date(); pairings[pairingId] = p }
        persistLocked()
        lock.unlock()
    }

    // MARK: - Persistence

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(Array(pairings.values)) {
            SecureKeyStore.savePairings(data)
        }
    }

    private func loadPairings() {
        guard let data = SecureKeyStore.loadPairings(),
              let list = try? JSONDecoder().decode([Pairing].self, from: data) else { return }
        lock.lock()
        pairings = Dictionary(uniqueKeysWithValues: list.map { ($0.pairingId, $0) })
        lock.unlock()
    }
}

/// Sandbox-file storage for the server key pair and pairings, backup-excluded.
enum SecureKeyStore {
    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("iCTRL", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func write(_ data: Data, _ name: String) {
        guard var url = dir?.appendingPathComponent(name) else { return }
        try? data.write(to: url)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? url.setResourceValues(rv)
    }
    private static func read(_ name: String) -> Data? {
        guard let url = dir?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }
    static func saveServerPrivateKey(_ d: Data) { write(d, "server_x25519.key") }
    static func loadServerPrivateKey() -> Data? { read("server_x25519.key") }
    static func savePairings(_ d: Data) { write(d, "pairings.json") }
    static func loadPairings() -> Data? { read("pairings.json") }
}
