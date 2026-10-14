import Foundation

/// State behind the runner's client list and live log, shared by both screens.
///
/// Everything comes from the runner over `RunnerClient`: `config` lists and
/// revokes sessions, `logs` returns the recent log. Errors are kept as a short
/// user-facing notice instead of being thrown at the views.
@MainActor
final class RunnerAdmin: ObservableObject {
    struct Client: Identifiable, Equatable {
        let id: String
        let name: String
        let grantedAt: Date?
        let lastActiveAt: Date?
    }

    @Published private(set) var isPaired: Bool
    @Published private(set) var pairing = false
    /// Why the last operation failed, in the user's language; nil when fine.
    @Published private(set) var notice: String?
    @Published private(set) var clients: [Client] = []
    @Published private(set) var clientsLoaded = false
    @Published private(set) var logLines: [String] = []
    @Published private(set) var logsLoaded = false

    private let client: RunnerClient
    /// The runner keeps 500 lines at most per `logs` call.
    static let logLineLimit = 500

    init(port: Int) {
        client = RunnerClient(port: port)
        isPaired = client.isPaired
    }

    var ownSessionID: String? { client.sessionID }
    var otherClients: [Client] { clients.filter { $0.id != ownSessionID } }

    // MARK: - Pairing

    func connect() async {
        guard !pairing else { return }
        pairing = true
        notice = nil
        defer { pairing = false }
        do {
            try await client.pair()
            isPaired = true
            ictrlLog("Runner admin: paired as \(client.sessionID ?? "?")")
            await loadClients()
        } catch {
            handle(error)
        }
    }

    // MARK: - Clients

    func loadClients() async {
        guard client.isPaired else { isPaired = false; return }
        do {
            let result = try await client.call("config")
            clients = Self.parseClients(result["sessions"])
            clientsLoaded = true
            notice = nil
        } catch {
            handle(error)
        }
    }

    func revoke(_ id: String) async {
        do {
            let result = try await client.call("config", ["revoke_session_id": id])
            clients = Self.parseClients(result["sessions"])
            ictrlLog("Runner admin: revoked session \(id)")
        } catch {
            handle(error)
        }
    }

    /// Revoke every client except this app, one by one: the runner's
    /// `clear_sessions` would cut this app off too.
    func revokeOthers() async {
        for other in otherClients {
            await revoke(other.id)
            if !isPaired { return }
        }
    }

    /// Revoke this app's own key on the runner, then forget it here.
    func disconnect() async {
        if let own = ownSessionID {
            _ = try? await client.call("config", ["revoke_session_id": own])
        }
        client.forget()
        isPaired = false
        clients = []
        clientsLoaded = false
        logLines = []
        logsLoaded = false
        ictrlLog("Runner admin: disconnected")
    }

    // MARK: - Logs

    func loadLogs() async {
        guard client.isPaired else { isPaired = false; return }
        do {
            let result = try await client.call("logs", ["max_elements": Self.logLineLimit])
            let lines = result["lines"] as? [String] ?? []
            if lines != logLines { logLines = lines }
            logsLoaded = true
            notice = nil
        } catch {
            handle(error)
        }
    }

    // MARK: - Helpers

    private func handle(_ error: Error) {
        switch error as? RunnerClient.Failure {
        case .notRunning:
            notice = L10n.t(.runnerNotRunningHint)
        case .notPaired:
            isPaired = false
        case .keyRejected:
            isPaired = false
            clients = []
            notice = L10n.t(.keyRejectedHint)
        case .pairDenied:
            notice = L10n.t(.pairDeniedHint)
        case .pairUnavailable(let seconds, _):
            notice = String(format: L10n.t(.retryInSeconds), seconds)
        case .server(let message):
            notice = message
        case nil:
            notice = error.localizedDescription
        }
        ictrlLog("Runner admin: \(error)")
    }

    private static let iso = ISO8601DateFormatter()

    private static func parseClients(_ value: Any?) -> [Client] {
        let rows = value as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["session_id"] as? String else { return nil }
            return Client(id: id,
                          name: row["client_name"] as? String ?? id,
                          grantedAt: (row["granted_at"] as? String).flatMap(iso.date(from:)),
                          lastActiveAt: (row["last_active_at"] as? String).flatMap(iso.date(from:)))
        }
        .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }
}
