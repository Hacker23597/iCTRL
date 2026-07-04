import Foundation
import Network

/// Proactively triggers iOS's "Local Network" permission prompt at startup.
///
/// The server's NWListener alone does NOT reliably prompt for local-network
/// access — the prompt fires when the app actively SENDS to the LAN. If the user
/// hasn't granted it, the listener binds but LAN clients can't reach it, which
/// looks exactly like a dead service ("port open on device but unreachable /
/// won't wake in background"). We provoke the prompt as early as possible so the
/// user grants it up front, instead of hitting it later as a mysterious
/// connection failure.
///
/// Trigger mechanism: send a UDP datagram to the mDNS multicast group
/// (224.0.0.251:5353). Sending to a local multicast address is local-network
/// activity, so iOS raises the prompt — and unlike Bonjour browsing this needs
/// no `NSBonjourServices` Info.plist declaration. The connection is torn down
/// immediately; its only purpose is to make the OS ask.
final class LocalNetworkPrimer {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.openminis.ictrl.lan-primer")
    private var onEvent: ((String) -> Void)?

    /// Kick off a one-shot local-network probe. `log` receives short status
    /// lines for the persisted log so the permission state stays observable.
    func prime(log: @escaping (String) -> Void) {
        onEvent = log

        // mDNS multicast group — a well-known link-local address. Sending here
        // counts as local-network access and raises the permission dialog.
        let host = NWEndpoint.Host("224.0.0.251")
        let port = NWEndpoint.Port(rawValue: 5353)!
        let conn = NWConnection(host: host, port: port, using: .udp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Send one throwaway byte to actually touch the LAN.
                conn.send(content: Data([0]), completion: .contentProcessed { _ in })
                self?.onEvent?("🌐 LAN permission probe sent — grant 'Local Network' if prompted")
                self?.stopSoon()
            case .waiting(let err):
                // .waiting on a permission error means access is denied/undecided.
                self?.onEvent?("🌐 LAN probe waiting: \(err) — if unreachable later, enable Settings › iCTRL › Local Network")
                self?.stopSoon()
            case .failed(let err):
                self?.onEvent?("🌐 LAN probe failed: \(err)")
                self?.stop()
            default:
                break
            }
        }
        conn.start(queue: queue)
        log("🌐 Priming Local Network permission…")
    }

    private func stopSoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.stop() }
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }
}
