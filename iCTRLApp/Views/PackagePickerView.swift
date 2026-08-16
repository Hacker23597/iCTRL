import SwiftUI

/// Chooses which package the installer acts on.
///
/// The default is the runner shipped inside this app, which is what almost
/// everyone wants; this exists for the cases where it isn't — testing a build
/// from somewhere else, or picking up a newer runner than the app carries.
struct PackagePickerView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the chosen package. The caller owns whatever it does next.
    let onPick: (SelectedPackage) -> Void

    @State private var showFileImporter = false
    @State private var releases: ReleaseListState = .idle
    @State private var downloading: String?

    private enum ReleaseListState {
        case idle
        case loading
        case loaded(RunnerRelease.Release)
        case none
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                bundledSection
                filesSection
                releasesSection
            }
            .navigationTitle("Choose a package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadReleases() }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    onPick(.file(url))
                    dismiss()
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var bundledSection: some View {
        if BundledRunner.isAvailable, let url = BundledRunner.url {
            Section {
                Button {
                    onPick(.bundled(url))
                    dismiss()
                } label: {
                    row(title: BundledRunner.displayName,
                        subtitle: [BundledRunner.formattedSize, "Ships with this app"]
                            .compactMap { $0 }.joined(separator: " · "),
                        systemImage: "shippingbox.fill")
                }
            } header: {
                Text("Bundled")
            } footer: {
                Text("The runner built alongside this app, so the two always match.")
            }
        }
    }

    private var filesSection: some View {
        Section {
            Button {
                showFileImporter = true
            } label: {
                row(title: "Choose from Files…",
                    subtitle: "Any .ipa on this device or in iCloud Drive",
                    systemImage: "folder")
            }
        } header: {
            Text("Files")
        }
    }

    @ViewBuilder
    private var releasesSection: some View {
        Section {
            switch releases {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking GitHub…").font(.footnote).foregroundColor(.secondary)
                }
            case .loaded(let release):
                Button {
                    Task { await download(release) }
                } label: {
                    row(title: release.tag,
                        subtitle: downloading == release.tag
                            ? "Downloading…"
                            : [release.assetName,
                               ByteCountFormatter.string(fromByteCount: Int64(release.sizeBytes), countStyle: .file)]
                                .joined(separator: " · "),
                        systemImage: "arrow.down.circle")
                }
                .disabled(downloading != nil)
            case .none:
                Text("No releases published yet.")
                    .font(.footnote).foregroundColor(.secondary)
            case .failed(let why):
                Text(why).font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text("GitHub Releases")
        } footer: {
            Text("Downloads the latest runner published to \(RunnerRelease.owner)/\(RunnerRelease.repo).")
        }
    }

    private func row(title: String, subtitle: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    // MARK: - Loading

    private func loadReleases() async {
        releases = .loading
        do {
            if let release = try await RunnerRelease.latestRelease() {
                releases = .loaded(release)
            } else {
                releases = .none
            }
        } catch {
            releases = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func download(_ release: RunnerRelease.Release) async {
        downloading = release.tag
        defer { downloading = nil }
        do {
            let url = try await RunnerRelease.download(release) { _ in }
            onPick(.downloaded(url, tag: release.tag))
            dismiss()
        } catch {
            releases = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

/// Where a package came from — kept so the UI can name it and so the caller
/// knows whether it needs a security scope to read it.
enum SelectedPackage: Equatable {
    case bundled(URL)
    case file(URL)
    case downloaded(URL, tag: String)

    var url: URL {
        switch self {
        case .bundled(let url), .file(let url), .downloaded(let url, _): return url
        }
    }

    var displayName: String {
        switch self {
        case .bundled:               return BundledRunner.displayName
        case .file(let url):         return url.lastPathComponent
        case .downloaded(_, let tag): return "\(tag) — \(url.lastPathComponent)"
        }
    }

    /// Only a file the user picked lives outside our container.
    var needsSecurityScope: Bool {
        if case .file = self { return true }
        return false
    }
}
