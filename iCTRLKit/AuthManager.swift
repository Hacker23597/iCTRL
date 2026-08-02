import CryptoKit
import Foundation

protocol AuthManagerDelegate: AnyObject {
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String, completion: @escaping (Bool) -> Void)
}

/// Pairing + encrypted-envelope authentication (protocol v1).
///
/// Wire-compatible with MinisApp's debug server. There is no plaintext token
/// path: every `/rpc` and `/logs*` request must arrive as a sealed envelope, and
/// the only secret a client holds is the 32-byte key K handed out at pairing.
///
/// Streaming is the one exception — `<video>` can't sign its own requests — so
/// `/stream` is authorized by a short-lived single-use ticket that the client
/// obtains over the encrypted channel. See `issueStreamTicket`.
class AuthManager {
    static let shared = AuthManager()

    /// A session expires only after this long with no successful use. Every
    /// authenticated request slides the window forward.
    static let inactivityWindow: TimeInterval = 30 * 24 * 60 * 60  // 30 days
    /// Max sessions to keep; beyond this the least-recently-active are dropped.
    static let maxSessions = 100
    /// Hard cap on remembered nonces PER SESSION — a backstop against a client
    /// that floods, not the expiry mechanism. Replay protection is time-based
    /// (see `seenNonces`), so this only needs to exceed the number of requests
    /// one client can make inside the timestamp window.
    private static let nonceCapacityPerSession = 20_000
    /// Re-pair from the same client within this window skips the approval alert.
    private static let trustTTL: TimeInterval = 600
    /// How often a sliding `lastActiveAt` is flushed to disk.
    private static let persistUseInterval: TimeInterval = 3600
    /// Stream tickets are single-use and die quickly.
    private static let streamTicketTTL: TimeInterval = 60

    weak var delegate: AuthManagerDelegate?

    private var sessions: [String: AuthSession] = [:]
    private let lock = NSLock()
    private var autoApprove = false
    /// One-shot pairing bypass (see `armSingleAutoApproval`). Never persisted.
    private var autoApproveOnce = false

    /// Replay cache, per session: nonce -> the request timestamp it arrived with.
    ///
    /// Time-based rather than a fixed-size LRU, and scoped per token so one
    /// client can never evict another's entries. A nonce only has to be
    /// remembered as long as a replay of it could still pass the ±120s
    /// timestamp check; past that the timestamp itself rejects the replay, so
    /// the entry is dropped. This is also what upholds the nonce-uniqueness
    /// invariant the stream cipher depends on: reusing a nonce inside the
    /// window is refused rather than silently XORing two plaintexts under one
    /// keystream.
    private var seenNonces: [String: [String: Int]] = [:]
    private var lastPersistedUse: [String: Date] = [:]
    private var trustWindow: [String: Date] = [:]
    /// ticket -> (session id, expiry). Consumed on first use.
    private var streamTickets: [String: (sessionId: String, expires: Date)] = [:]

    private init() {
        loadFromKeychain()
        pruneExpired()
    }

    var activeSessions: [AuthSession] {
        pruneExpired()
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values).sorted { $0.grantedAt > $1.grantedAt }
    }

    func setAutoApprove(_ enabled: Bool) {
        autoApprove = enabled
    }

    /// Arm a ONE-SHOT auto-approval for the next pairing request.
    ///
    /// Enabled by launching the runner with `ICTRL_ALLOW_AUTH_ONCE=1` (e.g. from
    /// an Xcode scheme's environment variables). It exists so a dev run can
    /// re-pair headlessly after the key store is wiped, without someone having
    /// to tap Allow on the device.
    ///
    /// Deliberately single-use and process-scoped: it is consumed by the first
    /// pairing and never rearms, so a forgotten flag degrades to "one free pair
    /// per cold start" rather than a standing bypass. It is NOT persisted.
    func armSingleAutoApproval() {
        lock.lock()
        autoApproveOnce = true
        lock.unlock()
    }

    /// Consume the one-shot grant, if armed. Returns whether it applied.
    private func takeSingleAutoApproval() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard autoApproveOnce else { return false }
        autoApproveOnce = false
        return true
    }

    // MARK: - Pairing

    /// Ask the user to approve a new client, then mint a 32-byte key.
    /// Auto-approves if the same client paired within the trust window.
    func requestAuth(clientName: String, completion: @escaping (AuthSession?) -> Void) {
        lock.lock()
        let trusted = trustWindow[clientName].map { Date().timeIntervalSince($0) < Self.trustTTL } ?? false
        lock.unlock()

        if autoApprove || trusted || takeSingleAutoApproval() {
            completion(createSession(clientName: clientName))
            return
        }
        guard let delegate = delegate else {
            completion(createSession(clientName: clientName))
            return
        }
        delegate.authManager(self, didReceiveAuthRequest: clientName) { [weak self] approved in
            guard approved, let self = self else {
                completion(nil)
                return
            }
            completion(self.createSession(clientName: clientName))
        }
    }

    private func createSession(clientName: String) -> AuthSession? {
        guard let key = SecureEnvelope.randomBytes(32) else { return nil }
        let now = Date()
        let session = AuthSession(
            id: SecureEnvelope.tokenId(for: key),
            keyHex: key.hexString,
            clientName: clientName,
            grantedAt: now,
            lastActiveAt: now
        )
        lock.lock()
        sessions[session.id] = session
        trustWindow[clientName] = now
        lock.unlock()
        persist()
        return session
    }

    // MARK: - Envelope verification

    /// Verifies and decrypts a request envelope. On success returns the plaintext
    /// JSON-RPC body plus a sealer that encrypts the reply under the same nonce.
    ///
    /// Order matters: the MAC is checked BEFORE the replay cache is touched, so
    /// an unauthenticated caller can never perturb a legitimate client's state.
    /// Returns the VERIFIED token id so callers that mint credentials bind them
    /// to the identity this envelope actually proved, not to unverified input.
    func openEnvelope(_ obj: [String: Any]) throws -> (tokId: String, plaintext: String, seal: (String) -> String) {
        let p = try SecureEnvelope.parse(obj)

        lock.lock()
        let record = sessions[p.tokId]
        lock.unlock()

        guard var session = record else {
            // Deliberately the SAME code/message as every other pre-MAC
            // rejection: distinct codes here would let an unauthenticated
            // caller enumerate which token ids exist and which are live.
            throw SecureEnvelope.Failure(code: "auth_failed", message: "Authentication failed")
        }
        let now = Date()
        if now.timeIntervalSince(session.lastActiveAt) > Self.inactivityWindow {
            lock.lock()
            sessions.removeValue(forKey: p.tokId)
            seenNonces.removeValue(forKey: p.tokId)
            lock.unlock()
            persist()
            throw SecureEnvelope.Failure(code: "auth_failed", message: "Authentication failed")
        }
        guard abs(now.timeIntervalSince1970 - Double(p.ts)) <= SecureEnvelope.timestampWindow else {
            // Kept distinct: a client with a skewed clock must be told to fix
            // its clock, not to re-pair — and this reveals nothing about
            // whether the token exists (it is thrown before the key is used).
            throw SecureEnvelope.Failure(code: "ts_skew", message: "Timestamp outside ±120s window")
        }
        guard let key = session.key else {
            throw SecureEnvelope.Failure(code: "auth_failed", message: "Authentication failed")
        }

        let plaintext = try SecureEnvelope.open(p, key: key)

        // Authentic — now consume a replay slot and slide the idle window.
        lock.lock()
        var seen = seenNonces[p.tokId] ?? [:]
        // Drop entries too old to be replayable: once a nonce's timestamp falls
        // outside the window, the ts check above rejects any replay of it.
        let cutoff = Int(now.timeIntervalSince1970 - SecureEnvelope.timestampWindow)
        if seen.count > 64 { seen = seen.filter { $0.value >= cutoff } }
        if seen[p.nonceHex] != nil {
            lock.unlock()
            throw SecureEnvelope.Failure(code: "nonce_replayed", message: "Duplicate nonce")
        }
        if seen.count >= Self.nonceCapacityPerSession {
            lock.unlock()
            throw SecureEnvelope.Failure(code: "nonce_flood",
                                         message: "Too many in-flight nonces; slow down")
        }
        seen[p.nonceHex] = p.ts
        seenNonces[p.tokId] = seen
        session.lastActiveAt = now
        sessions[p.tokId] = session
        let needsPersist = lastPersistedUse[p.tokId].map {
            now.timeIntervalSince($0) > Self.persistUseInterval
        } ?? true
        if needsPersist { lastPersistedUse[p.tokId] = now }
        lock.unlock()
        if needsPersist { persist() }

        let seal: (String) -> String = { responseJSON in
            SecureEnvelope.seal(responseJSON: responseJSON, key: key,
                                nonce: p.nonce, nonceHex: p.nonceHex)
        }
        return (p.tokId, plaintext, seal)
    }

    // MARK: - Stream tickets

    /// Mint a single-use, short-lived ticket for `GET /stream`. Callable only
    /// from an already-authenticated (enveloped) RPC, so the ticket inherits
    /// that request's proof of key possession. `<video src>` can't sign its own
    /// request, so this is what stands in for an envelope there.
    func issueStreamTicket(forTokenId tokId: String) -> (ticket: String, expiresIn: Int)? {
        guard let raw = SecureEnvelope.randomBytes(24) else { return nil }
        let ticket = raw.hexString
        lock.lock()
        guard sessions[tokId] != nil else {
            lock.unlock()
            return nil
        }
        streamTickets = streamTickets.filter { $0.value.expires > Date() }   // opportunistic sweep
        streamTickets[ticket] = (tokId, Date().addingTimeInterval(Self.streamTicketTTL))
        lock.unlock()
        return (ticket, Int(Self.streamTicketTTL))
    }

    /// Redeem a stream ticket. Single use: a valid ticket is removed as it is
    /// accepted, so a leaked URL can't be replayed.
    func consumeStreamTicket(_ ticket: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = streamTickets.removeValue(forKey: ticket) else { return false }
        guard entry.expires > Date(), sessions[entry.sessionId] != nil else { return false }
        return true
    }

    // MARK: - Management

    func revokeSession(id: String) {
        lock.lock()
        sessions.removeValue(forKey: id)
        seenNonces.removeValue(forKey: id)
        streamTickets = streamTickets.filter { $0.value.sessionId != id }
        lock.unlock()
        persist()
    }

    func revokeAll() {
        lock.lock()
        sessions.removeAll()
        seenNonces.removeAll()
        trustWindow.removeAll()
        streamTickets.removeAll()
        lock.unlock()
        persist()
    }

    /// Remove long-idle sessions and cap the count. Safe to call often.
    @discardableResult
    func pruneExpired() -> Int {
        lock.lock()
        let before = sessions.count
        let now = Date()
        sessions = sessions.filter { _, s in
            now.timeIntervalSince(s.lastActiveAt) < Self.inactivityWindow
        }
        if sessions.count > Self.maxSessions {
            let keep = sessions.values
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
                .prefix(Self.maxSessions)
            sessions = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
        seenNonces = seenNonces.filter { sessions[$0.key] != nil }
        let removed = before - sessions.count
        lock.unlock()
        if removed > 0 { persist() }
        return removed
    }

    // MARK: - Persistence

    /// Callers must NOT hold `lock`.
    private func persist() {
        lock.lock()
        let list = Array(sessions.values)
        lock.unlock()
        if let data = try? JSONEncoder.iso.encode(list) {
            TokenFileStore.save(data)
        }
    }

    private func loadFromKeychain() {
        // (Name kept for call sites.) Loads from the sandbox file; also migrates a
        // legacy Keychain blob once. Records from the pre-v1 plaintext-token era
        // decode to nothing (no `key` field) and are simply dropped — those
        // clients must re-pair, which is intended: their UUID tokens carried no
        // key material and cannot drive the encrypted channel.
        var data = TokenFileStore.load()
        if data == nil, let legacy = KeychainStore.load() {
            data = legacy
            if let legacy = data { TokenFileStore.save(legacy) }
        }
        guard let data = data,
              let list = try? JSONDecoder.iso.decode([AuthSession].self, from: data) else {
            return
        }
        lock.lock()
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        lock.unlock()
    }
}

// MARK: - ISO8601 JSON coders (stable date encoding for the token blob)

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
