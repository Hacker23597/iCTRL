import SwiftUI
import UniformTypeIdentifiers

/// The on-device DDI mounting flow.
///
/// Presented from the Automation section when no image is mounted. Deliberately
/// laid out as ordered prerequisites rather than a single button: the mount has
/// three preconditions the user must satisfy in order, and a button that just
/// says "failed" would leave them guessing which one was missing.
struct DDIMountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mounter = DDIMounter()
    @StateObject private var images = DeveloperDiskImageStore()

    @State private var showPairingPicker = false
    @State private var pairingError: String?
    @State private var hasPairingFile = PairingFileStore.exists
    @State private var imagesReady = DeveloperDiskImageStore.isComplete
    @State private var downloadError: String?
    @State private var vpnInstalled = false
    @State private var tunnelUp = false

    /// All three prerequisites, in the order the steps present them. The tunnel
    /// is included because it drops on every reboot — leaving it out let the
    /// mount fail with a socket error naming nothing the user could act on.
    private var canMount: Bool { tunnelUp && hasPairingFile && imagesReady && !mounter.isRunning }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Mount the Developer Disk Image without a Mac. iOS needs it before "
                       + "the automation runner can launch, and it does not survive a reboot.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                tunnelSection
                pairingSection
                imageSection
                mountSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Mount DDI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { refreshVPNState() }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in refreshVPNState() }
            .onOpenURL { _ in refreshVPNState() }   // LocalDevVPN bounced us back
            .fileImporter(isPresented: $showPairingPicker,
                          allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
                switch result {
                case .success(let url):
                    do {
                        try PairingFileStore.importFile(from: url)
                        hasPairingFile = true
                        pairingError = nil
                    } catch {
                        pairingError = error.localizedDescription
                    }
                case .failure(let error):
                    pairingError = error.localizedDescription
                }
            }
        }
    }

    /// Names the first unmet prerequisite, so a disabled button explains itself.
    private var missingPrerequisite: String {
        if !tunnelUp {
            return vpnInstalled ? "LocalDevVPN isn't connected" : "LocalDevVPN isn't installed"
        }
        if !hasPairingFile { return "no pairing file imported" }
        if !imagesReady { return "the image files aren't downloaded" }
        return "something is missing"
    }

    private func refreshVPNState() {
        vpnInstalled = LocalDevVPN.isInstalled
        tunnelUp = LocalDevVPN.isTunnelUp()
    }

    // ① The tunnel. LocalDevVPN exposes localdevvpn://enable?scheme=…, so this
    //    can send the user straight into connecting and get them back, instead
    //    of just naming an app and hoping.
    private var tunnelSection: some View {
        Section {
            stepRow(1, done: tunnelUp,
                    title: "Start LocalDevVPN",
                    detail: tunnelUp
                        ? "Tunnel is up — this device's debug service is reachable at \(DDIMounter.tunnelAddress)."
                        : vpnInstalled
                          ? "Installed. Connect it so this device's debug service becomes reachable at \(DDIMounter.tunnelAddress)."
                          : "Not installed. It makes this device's debug service reachable — iCTRL then talks to it the same way Xcode on a Mac would.")

            if !tunnelUp {
                actionButton(vpnInstalled ? "Open LocalDevVPN & connect" : "Get LocalDevVPN on the App Store") {
                    // enable? starts the tunnel and bounces back to us; the bare
                    // App Store link is the fallback when it isn't installed.
                    UIApplication.shared.open(vpnInstalled ? LocalDevVPN.enableURL
                                                           : LocalDevVPN.appStoreURL)
                }
            }
        } header: {
            Text("Prerequisite")
        } footer: {
            if tunnelUp {
                Text("Detected by the tunnel's address being present on this device.")
            } else {
                Text("iCTRL can't connect the VPN for you — tapping above opens it to do that. "
                   + "If mounting still fails to connect, check it there first.")
            }
        }
    }

    // ② The pairing file — proves to lockdownd that we're a trusted host.
    private var pairingSection: some View {
        Section {
            stepRow(2, done: hasPairingFile,
                    title: "Import a pairing file",
                    detail: hasPairingFile
                        ? "Imported\(PairingFileStore.importedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")"
                        : "Generate it on a Mac with `idevicepair pair`, then send it here (AirDrop, Files, iCloud).")

            actionButton(hasPairingFile ? "Replace pairing file…" : "Choose pairing file…") {
                showPairingPicker = true
            }

            if hasPairingFile {
                actionButton("Remove pairing file", role: .destructive) {
                    PairingFileStore.remove()
                    hasPairingFile = false
                }
            }

            if let pairingError {
                Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // ③ The image itself.
    private var imageSection: some View {
        Section {
            stepRow(3, done: imagesReady,
                    title: "Developer Disk Image",
                    detail: imagesReady
                        ? "Downloaded · \(ByteCountFormatter.string(fromByteCount: DeveloperDiskImageStore.totalBytesOnDisk, countStyle: .file))"
                        : "About 100 MB. Downloaded once and reused — only the mount has to be repeated after a reboot.")

            if images.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: images.progress)
                    if let msg = images.statusMessage {
                        Text(msg).font(.caption2).foregroundColor(.secondary)
                    }
                }
            } else if !imagesReady {
                actionButton("Download image files") {
                    Task {
                        do {
                            try await images.download()
                            imagesReady = DeveloperDiskImageStore.isComplete
                            downloadError = nil
                        } catch {
                            downloadError = error.localizedDescription
                        }
                    }
                }
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } footer: {
            Text("Fetched from the DeveloperDiskImage mirror maintained by the pymobiledevice3 "
               + "author. Apple doesn't publish these for direct download; the same files ship "
               + "inside Xcode.")
        }
    }

    private var mountSection: some View {
        Section {
            switch mounter.phase {
            case .idle, .failed:
                Button {
                    Task { await mounter.mount() }
                } label: {
                    Label("Mount Developer Disk Image", systemImage: "externaldrive.badge.plus")
                }
                .disabled(!canMount)

            case .connecting, .queryingDevice, .finalizing:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(phaseLabel).foregroundColor(.secondary)
                }

            case .uploading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                    Text("Uploading image… \(Int(fraction * 100))%")
                        .font(.caption).foregroundColor(.secondary)
                }

            case .mounted:
                Label("Mounted — the automation runner can launch now",
                      systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }

            if case .failed(let message) = mounter.phase {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Mount failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if case .mounted = mounter.phase {
                Text("The image is not persistent — after a reboot, run this again. "
                   + "The pairing file and downloaded image are kept, so it's one tap.")
            } else if !canMount, !mounter.isRunning {
                Text("Finish the steps above first — \(missingPrerequisite).")
            } else {
                Text("The first mount asks Apple's signing service for a ticket unique to this "
                   + "device, so it needs internet access.")
            }
        }
    }

    private var phaseLabel: String {
        switch mounter.phase {
        case .connecting:     return "Connecting through the tunnel…"
        case .queryingDevice: return "Reading device identity…"
        case .finalizing:     return "Finalizing…"
        default:              return ""
        }
    }

    /// One numbered step: badge, title, explanation.
    ///
    /// The badge is the row's `Label` icon, so SwiftUI indents the text to a
    /// consistent leading edge — and `actionButton` pads to match, which is what
    /// keeps a step's button aligned with its own text instead of the card edge.
    private func stepRow(_ n: Int, done: Bool, title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(done ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            stepBadge(n, done: done)
        }
    }

    /// A step's action, indented to line up with that step's text.
    ///
    /// `.body` rather than `.footnote`: these are the things the user is meant
    /// to tap, and at caption size they read as annotations instead of actions.
    private func actionButton(_ title: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        // Built as a Label with an INVISIBLE badge rather than a guessed
        // padding: the real indent is the badge width plus whatever spacing
        // Label uses, which varies with Dynamic Type. Reusing the same layout
        // makes the text land exactly under the step title by construction.
        Button(role: role, action: action) {
            Label {
                Text(title)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                stepBadge(0, done: false).hidden()
            }
        }
    }

    private func stepBadge(_ n: Int, done: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : Color.accentColor)
                .frame(width: 22, height: 22)
            if done {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            } else {
                Text(verbatim: "\(n)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }
        }
    }
}
