import Foundation

/// The three files a personalized DDI mount needs, kept on disk.
///
/// Not bundled in the app: `Image.dmg` alone is ~100MB, it changes with Xcode
/// releases, and most users mounting a DDI already have network. Downloaded once
/// and reused — the mount itself is what needs to be repeated after a reboot,
/// not the download.
@MainActor
final class DeveloperDiskImageStore: ObservableObject {

    /// Personalized (iOS 17+) DDI components, mirrored by the pymobiledevice3
    /// author. Apple does not publish these for direct download; the same
    /// content ships inside Xcode, so a user with a Mac can supply their own
    /// copy instead (see `importComponent`).
    private static let baseURL =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized"

    enum Component: String, CaseIterable {
        case buildManifest = "BuildManifest.plist"
        case image = "Image.dmg"
        case trustCache = "Image.dmg.trustcache"

        var remoteURL: URL { URL(string: "\(baseURL)/\(rawValue)")! }
    }

    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage: String?

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("DDI")
    }

    static func url(for component: Component) -> URL {
        directory.appendingPathComponent(component.rawValue)
    }

    /// True when all three files are present. Deliberately does not validate
    /// their contents — a corrupt image surfaces as a mount error, and guessing
    /// at validity here would just add a second place to be wrong.
    static var isComplete: Bool {
        Component.allCases.allSatisfy {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }
    }

    static var totalBytesOnDisk: Int64 {
        Component.allCases.reduce(0) { sum, c in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: c).path)
            return sum + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    func download() async throws {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        defer { isDownloading = false }

        try FileManager.default.createDirectory(at: Self.directory,
                                                withIntermediateDirectories: true)

        // Weight by size so the bar reflects reality: the image dwarfs the other
        // two, and an evenly-weighted bar would sit at 66% for the whole download.
        let weights: [Component: Double] = [.buildManifest: 0.02, .image: 0.95, .trustCache: 0.03]
        var completed = 0.0

        for component in Component.allCases {
            let dest = Self.url(for: component)
            if FileManager.default.fileExists(atPath: dest.path) {
                completed += weights[component] ?? 0
                progress = completed
                continue
            }
            statusMessage = "Downloading \(component.rawValue)…"
            let weight = weights[component] ?? 0
            try await download(component, to: dest) { [weak self] frac in
                Task { @MainActor in self?.progress = completed + frac * weight }
            }
            completed += weight
            progress = completed
        }
        statusMessage = nil
    }

    private func download(_ component: Component, to dest: URL,
                          onProgress: @escaping (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: component.remoteURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DDIError.downloadFailed(component.rawValue,
                (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "no response")
        }
        let expected = response.expectedContentLength
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }

        var lastReport = 0.0
        for try await byte in bytes {
            data.append(byte)
            if expected > 0 {
                let frac = Double(data.count) / Double(expected)
                // Reporting every byte would flood the main actor; 1% is plenty
                // for a progress bar.
                if frac - lastReport >= 0.01 {
                    lastReport = frac
                    onProgress(frac)
                }
            }
        }
        try data.write(to: dest, options: .atomic)
        onProgress(1.0)
    }

    /// Accept a user-supplied copy, for people who'd rather pull the files out
    /// of their own Xcode than trust a third-party mirror.
    static func importComponent(_ component: Component, from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url)
        try data.write(to: self.url(for: component), options: .atomic)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
