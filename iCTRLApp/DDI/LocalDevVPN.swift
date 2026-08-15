import Foundation
import UIKit

/// Talking to LocalDevVPN, the app that makes this device's debug service
/// routable so the DDI mount can reach it.
///
/// It registers `localdevvpn://` and takes a callback scheme, so we can send the
/// user straight into "connect" and get them back — rather than telling them to
/// go find an app and return on their own.
enum LocalDevVPN {

    /// Bare scheme, used only as a `canOpenURL:` probe. The app's handler falls
    /// through to `default: break` for it, so probing can't cause side effects.
    static let probeURL = URL(string: "localdevvpn://")!

    /// Starts the tunnel, then returns to `ictrl-app://`.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=ictrl-app")!

    static let appStoreURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    /// Whether LocalDevVPN is installed.
    ///
    /// Requires `localdevvpn` in this app's `LSApplicationQueriesSchemes` —
    /// without it iOS answers `false` no matter what is installed, which would
    /// silently send every user to the App Store.
    @MainActor
    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(probeURL)
    }

    /// Whether the tunnel is actually up.
    ///
    /// Installed is not the same as connected, and this is the difference the
    /// user cares about — a mount fails identically either way. There is no API
    /// to ask another app's `NEVPNStatus`, so this looks for the address the
    /// tunnel assigns: if 10.7.0.x is on a local interface, it's up.
    static func isTunnelUp(targetAddress: String = DDIMounter.tunnelAddress) -> Bool {
        // Compare on the /24 rather than the exact host: the device's own end of
        // the tunnel is a neighbour of the target, not the target itself.
        let prefix = targetAddress.split(separator: ".").prefix(3).joined(separator: ".") + "."

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let addr = ptr.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip == targetAddress || ip.hasPrefix(prefix) { return true }
        }
        return false
    }
}
