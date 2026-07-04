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
    private var onDenied: (() -> Void)?
    private var deniedReported = false

    /// Kick off a one-shot local-network probe. `log` receives short status
    /// lines for the persisted log so the permission state stays observable.
    /// `onLikelyDenied` fires (once) when the probe can't reach the LAN, which
    /// most often means Local Network permission is denied/undecided — the caller
    /// can surface a notification telling the user to enable it in Settings.
    func prime(log: @escaping (String) -> Void, onLikelyDenied: (() -> Void)? = nil) {
        onEvent = log
        onDenied = onLikelyDenied

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
                // .waiting (e.g. "Network is down", POSIX 50) means the probe
                // can't send to the LAN — Local Network access is denied/undecided.
                self?.onEvent?("🌐 LAN probe waiting: \(err) — Local Network likely not granted")
                self?.reportDenied()
                self?.stopSoon()
            case .failed(let err):
                self?.onEvent?("🌐 LAN probe failed: \(err)")
                self?.reportDenied()
                self?.stop()
            default:
                break
            }
        }
        conn.start(queue: queue)
        log("🌐 Priming Local Network permission…")

        // Safety net: if the probe never reaches .ready within a few seconds
        // (some denials leave it stuck in .preparing), treat that as likely denied.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.connection != nil, !self.deniedReported else { return }
            self.onEvent?("🌐 LAN probe never became ready — Local Network likely not granted")
            self.reportDenied()
        }
    }

    /// Fire the denied callback at most once.
    private func reportDenied() {
        guard !deniedReported else { return }
        deniedReported = true
        onDenied?()
    }

    private func stopSoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.stop() }
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }
}
