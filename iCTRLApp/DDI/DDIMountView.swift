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

    private var canMount: Bool { hasPairingFile && imagesReady && !mounter.isRunning }

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

    // ① The tunnel — supplied by another app, so this step can only instruct.
    private var tunnelSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Start LocalDevVPN")
                    Text("Open it and connect. It makes this device's debug service reachable "
                       + "at \(DDIMounter.tunnelAddress) — iCTRL talks to it the same way Xcode "
                       + "on a Mac would.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                stepNumber(1)
            }
            Link("Get LocalDevVPN on the App Store",
                 destination: URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!)
                .font(.footnote)
        } header: {
            Text("Prerequisite")
        } footer: {
            // Stated plainly because it is the one step iCTRL cannot verify or
            // perform, and its absence shows up as a confusing connection error.
            Text("iCTRL can't start the VPN for you, and can't tell whether it's running — "
               + "if mounting fails to connect, check it first.")
        }
    }

    // ② The pairing file — proves to lockdownd that we're a trusted host.
    private var pairingSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import a pairing file")
                    Text(hasPairingFile
                         ? "Imported\(PairingFileStore.importedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")"
                         : "Generate it on a Mac with `idevicepair pair`, then send it here "
                         + "(AirDrop, Files, iCloud).")
                        .font(.caption)
                        .foregroundColor(hasPairingFile ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                stepNumber(2, done: hasPairingFile)
            }

            Button(hasPairingFile ? "Replace pairing file…" : "Choose pairing file…") {
                showPairingPicker = true
            }
            .font(.footnote)

            if hasPairingFile {
                Button("Remove pairing file", role: .destructive) {
                    PairingFileStore.remove()
                    hasPairingFile = false
                }
                .font(.footnote)
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
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Developer Disk Image")
                    Text(imagesReady
                         ? "Downloaded · \(ByteCountFormatter.string(fromByteCount: DeveloperDiskImageStore.totalBytesOnDisk, countStyle: .file))"
                         : "About 100 MB. Downloaded once and reused — only the mount has to be "
                         + "repeated after a reboot.")
                        .font(.caption)
                        .foregroundColor(imagesReady ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                stepNumber(3, done: imagesReady)
            }

            if images.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: images.progress)
                    if let msg = images.statusMessage {
                        Text(msg).font(.caption2).foregroundColor(.secondary)
                    }
                }
            } else if !imagesReady {
                Button("Download image files") {
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
                .font(.footnote)
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

    private func stepNumber(_ n: Int, done: Bool = false) -> some View {
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
