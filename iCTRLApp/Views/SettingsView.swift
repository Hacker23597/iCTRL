import SwiftUI
import UIKit

/// The app's home screen.
///
/// Note what this app is NOT: automation runs in the XCUITest runner, a separate
/// process. This app can't serve RPC itself, so it doesn't try — it reports
/// whether the runner is able to launch (the DDI check) and offers a button that
/// launches it via `ictrl://start`.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    /// Re-probed whenever the view appears rather than held in AppState: the DDI
    /// can be unmounted while the app sits in the background, so a value cached
    /// at launch goes stale silently.
    @State private var ddi = DeveloperDiskImage.status()
    @State private var launchFailed = false
    @State private var showMountSheet = false

    /// The runner registers this scheme; opening it starts the automation server.
    private static let runnerURL = URL(string: "ictrl://start")!

    /// Provides the local loopback tunnel StikDebug needs to reach lockdownd.
    /// Deliberately an App Store link and not a deep link: neither LocalDevVPN
    /// nor its predecessor StosVPN registers a URL scheme, so any
    /// `localdevvpn://` we invented would fail silently. StosVPN has also been
    /// pulled from the App Store, which is why LocalDevVPN is the one named here.
    private static let localDevVPNURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    /// StikDebug mounts the DDI on-device. It registers both `stikdebug://` and
    /// the legacy `stikjit://`; bare scheme just opens the app.
    private static let stikDebugURL = URL(string: "stikdebug://")!
    /// Used when StikDebug isn't installed — it's sideload-only, never on the
    /// App Store, so the fallback is its distribution site.
    private static let stikDebugSiteURL = URL(string: "https://stikdebug.xyz")!

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Developer Disk Image")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ddi.isMounted ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(ddi.summary)
                            .foregroundColor(.secondary)
                    }
                }

                if let layout = ddi.layout {
                    HStack {
                        Text("Mount")
                        Spacer()
                        Text(layout.rawValue)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                // Offer the on-device mount whenever there's nothing mounted.
                // This is the only path that doesn't need a Mac, so it belongs
                // next to the status that reports the problem.
                if !ddi.isMounted {
                    Button {
                        showMountSheet = true
                    } label: {
                        Label("Mount without a Mac…", systemImage: "externaldrive.badge.plus")
                    }
                }
            } header: {
                Text("Automation")
            } footer: {
                // Without a DDI the runner can't launch at all — it dies in dyld
                // before any of our code runs. Say so here rather than leaving the
                // user to discover it as a crash after tapping Start.
                Text(ddi.advice ?? "The automation runner can launch on this device. Tap Start to run it.")
            }

            // Fallback only. The in-app mount above does the same job without
            // leaving iCTRL; StikDebug stays listed because it is the
            // battle-tested implementation this port is based on, and is worth
            // trying if our mount fails on a device we haven't seen.
            if !ddi.isMounted {
                Section {
                    HelperRow(
                        index: 1,
                        title: "LocalDevVPN",
                        detail: "Required either way — it makes this device's debug service reachable.",
                        actionTitle: "App Store",
                        url: Self.localDevVPNURL
                    )
                    HelperRow(
                        index: 2,
                        title: "StikDebug",
                        detail: "An alternative mounter, if the in-app one fails. Sideload from stikdebug.xyz — it isn't on the App Store.",
                        actionTitle: "Open",
                        url: Self.stikDebugURL,
                        fallbackURL: Self.stikDebugSiteURL
                    )
                } header: {
                    Text("Alternative")
                } footer: {
                    Text("The Developer Disk Image doesn't survive a reboot, so mounting has to be repeated after each restart — by either route.")
                }
            }

            if launchFailed {
                Section {
                    Label {
                        Text("Couldn't open the runner. Install iCTRLUITests-Runner on this device, then try again.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    Text(verbatim: "\(appState.serverPort)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Protocol")
                    Spacer()
                    Text("JSON-RPC 2.0")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("iCTRL")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Start") { startRunner() }
                    // A DDI-less device can't run the runner; leaving the button
                    // live would just hand the user a silent no-op.
                    .disabled(!ddi.isMounted)
            }
        }
        .onAppear { ddi = DeveloperDiskImage.status() }
        .sheet(isPresented: $showMountSheet, onDismiss: {
            // Re-probe: a successful mount changes what the status row should say.
            ddi = DeveloperDiskImage.status()
        }) {
            DDIMountView()
        }
    }

    private func startRunner() {
        launchFailed = false
        UIApplication.shared.open(Self.runnerURL) { ok in
            // The usual cause is the runner simply not being installed — the two
            // IPAs ship separately, so having this app is no guarantee.
            launchFailed = !ok
        }
    }
}

/// One numbered step in the "mount without a Mac" recovery flow.
private struct HelperRow: View {
    let index: Int
    let title: String
    let detail: String
    /// `nil` for a step the user performs here rather than in another app.
    let actionTitle: String?
    let url: URL?
    /// Opened when `url` uses a custom scheme and the app isn't installed.
    var fallbackURL: URL? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(index)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let url {
                Button(actionTitle) { open(url) }
                    .font(.caption.weight(.semibold))
                    // Rows sit in a List; .borderless keeps the tap on the button
                    // instead of letting the whole row swallow it.
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func open(_ url: URL) {
        UIApplication.shared.open(url) { ok in
            // A custom-scheme open fails when that app isn't installed; falling
            // back to its download page turns a dead tap into a way forward.
            guard !ok, let fallbackURL else { return }
            UIApplication.shared.open(fallbackURL)
        }
    }
}
