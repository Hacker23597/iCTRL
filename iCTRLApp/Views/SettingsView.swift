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
    @StateObject private var runner = RunnerStatus(port: 8200)

    /// The runner registers this scheme; opening it starts the automation server.
    ///
    /// `callback` asks the runner to bounce back to us once it has decided
    /// whether the server came up, appending `status` and `address`. Without it
    /// the user is left in the runner — a blank XCTest app with nothing to show
    /// — wondering whether anything happened.
    private static let runnerURL = URL(string: "ictrl://start?callback=ictrl-app://started")!

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

            serverSection

            Section {
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
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ddi = DeveloperDiskImage.status()
            runner.startPolling()
        }
        .onDisappear { runner.stopPolling() }
        .onOpenURL { url in
            // The runner bounced back: ictrl-app://started?status=…&address=…
            guard url.scheme == "ictrl-app" else { return }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let status = items.first { $0.name == "status" }?.value
            launchFailed = (status == "failed")
            // Trust the probe over the reported status — by the time we're back,
            // asking the server directly is both cheap and authoritative.
            Task { await runner.check() }
        }
        .sheet(isPresented: $showMountSheet, onDismiss: {
            // Re-probe: a successful mount changes what the status row should say.
            ddi = DeveloperDiskImage.status()
        }) {
            DDIMountView()
        }
    }

    /// Live state of the automation server.
    ///
    /// The server runs inside the XCUITest runner, a separate process, so this
    /// reports what an HTTP probe of it says rather than anything this app
    /// knows locally — the runner can be started or killed without the app
    /// being involved at all.
    private var serverSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                switch runner.state {
                case .unknown, .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundColor(.secondary)
                    }
                case .running:
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Running").foregroundColor(.secondary)
                    }
                case .stopped:
                    HStack(spacing: 6) {
                        Circle().fill(.secondary).frame(width: 8, height: 8)
                        Text("Stopped").foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                Text("Address")
                Spacer()
                Text(verbatim: "127.0.0.1:\(appState.serverPort)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if case .running(let info) = runner.state {
                if let version = info.serverVersion {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(verbatim: version)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                if let proto = info.protocolVersion {
                    HStack {
                        Text("Protocol")
                        Spacer()
                        Text(verbatim: "v\(proto)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                if let methods = info.methodCount {
                    HStack {
                        Text("Methods")
                        Spacer()
                        Text(verbatim: "\(methods)")
                            .foregroundColor(.secondary)
                    }
                }
                if !info.capabilities.isEmpty {
                    NavigationLink {
                        CapabilityListView(capabilities: info.capabilities)
                    } label: {
                        HStack {
                            Text("Capabilities")
                            Spacer()
                            Text(verbatim: "\(info.capabilities.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                // Start lives here rather than in the toolbar: it belongs beside
                // the state it changes, and this is where the reason it might be
                // disabled is already on screen.
                Button {
                    startRunner()
                } label: {
                    Label("Start Server", systemImage: "play.fill")
                }
                .disabled(!ddi.isMounted)
            }
        } header: {
            Text("iCTRL Local Server")
        } footer: {
            if case .running = runner.state {
                Text("Serving on port \(appState.serverPort). Automation clients connect here; "
                   + "every request is encrypted.")
            } else if !ddi.isMounted {
                Text("Mount the Developer Disk Image first — without it the runner can't launch.")
            } else {
                Text("The server runs inside the automation runner. Starting it opens that app.")
            }
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

/// The capability tags the running server advertises.
///
/// A flat list rather than a summary: these are what a client feature-detects
/// against, so the useful question is "is X there", which a searchable list
/// answers and a count does not.
private struct CapabilityListView: View {
    let capabilities: [String]

    var body: some View {
        List(capabilities.sorted(), id: \.self) { tag in
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text(verbatim: tag)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .navigationTitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
    }
}
