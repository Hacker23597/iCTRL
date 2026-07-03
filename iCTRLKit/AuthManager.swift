import Foundation

protocol AuthManagerDelegate: AnyObject {
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String, completion: @escaping (Bool) -> Void)
}

class AuthManager {
    static let shared = AuthManager()

    /// Default session lifetime: 30 days.
    static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60

    weak var delegate: AuthManagerDelegate?

    private var sessions: [String: AuthSession] = [:]
    private let lock = NSLock()
    private var autoApprove = false

    private init() {
        loadFromKeychain()
        pruneExpired()  // clean up on startup
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

    func requestAuth(clientName: String, completion: @escaping (AuthSession?) -> Void) {
        if autoApprove {
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

    func validateToken(_ token: String) -> Bool {
        pruneExpired()

        lock.lock()
        defer { lock.unlock() }

        guard var session = sessions.values.first(where: { $0.token == token }) else {
            return false
        }
        // Double-check expiry (pruneExpired already removed expired ones, but be safe).
        guard !session.isExpired else {
            sessions.removeValue(forKey: session.id)
            persistLocked()
            return false
        }

        session.lastActiveAt = Date()
        sessions[session.id] = session
        persistLocked()
        return true
    }

    func revokeSession(id: String) {
        lock.lock()
        sessions.removeValue(forKey: id)
        persistLocked()
        lock.unlock()
    }

    func revokeAll() {
        lock.lock()
        sessions.removeAll()
        persistLocked()
        lock.unlock()
    }

    /// Max tokens to keep; beyond this, the least-recently-active are dropped.
    static let maxSessions = 100
    /// Drop tokens not used within this window (independent of the 30-day TTL).
    static let inactivityWindow: TimeInterval = 30 * 24 * 60 * 60  // 1 month

    /// Remove expired / long-inactive sessions and cap the count. Safe to call often.
    @discardableResult
    func pruneExpired() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = sessions.count
        let now = Date()

        // 1) Drop hard-expired tokens (past expiresAt) and tokens not accessed in
        //    the inactivity window (last_active_at older than 1 month).
        sessions = sessions.filter { _, s in
            !s.isExpired && now.timeIntervalSince(s.lastActiveAt) < Self.inactivityWindow
        }

        // 2) Cap the count: if still over the limit, drop the least-recently-active.
        if sessions.count > Self.maxSessions {
            let keep = sessions.values
                .sorted { $0.lastActiveAt > $1.lastActiveAt }   // most recent first
                .prefix(Self.maxSessions)
            sessions = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }

        let removed = before - sessions.count
        if removed > 0 {
            persistLocked()
        }
        return removed
    }

    private func createSession(clientName: String) -> AuthSession {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let session = AuthSession(
            id: UUID().uuidString,
            token: UUID().uuidString,
            clientName: clientName,
            grantedAt: now,
            lastActiveAt: now,
            expiresAt: now.addingTimeInterval(Self.defaultTTL)
        )
        sessions[session.id] = session
        persistLocked()
        return session
    }

    // MARK: - Persistence (Keychain)

    /// Caller must hold `lock`.
    private func persistLocked() {
        let list = Array(sessions.values)
        if let data = try? JSONEncoder.iso.encode(list) {
            TokenFileStore.save(data)
        }
    }

    private func loadFromKeychain() {
        // (Kept name for call sites.) Loads from the sandbox file now; also
        // migrates any legacy Keychain blob once so existing users don't get
        // logged out on upgrade.
        var data = TokenFileStore.load()
        if data == nil, let legacy = KeychainStore.load() {
            data = legacy
            if let legacy = data { TokenFileStore.save(legacy) }  // migrate forward
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

// MARK: - ISO8601 JSON coders (stable date encoding for Keychain blob)

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
