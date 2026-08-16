import Foundation

/// Finds and downloads the Runner .ipa published on GitHub Releases.
///
/// The runner is the half of iCTRL that actually drives XCUITest, and it ships
/// separately from this app — so keeping it current is a real chore for users
/// who sideload. This checks what's published, compares it with what's running,
/// and fetches the package for `IPAInstaller`.
///
/// Everything here treats "no release yet" as a normal answer rather than an
/// error: the repository may legitimately have none, and a caller that can't
/// tell that apart from a network failure will show the wrong thing.
enum RunnerRelease {

    /// Where releases are published. Owner/repo rather than a full URL so the
    /// API and the human-facing page can't drift apart.
    static let owner = "OpenMinis"
    static let repo = "iCTRL"

    /// A published runner build.
    struct Release: Equatable {
        let tag: String             // e.g. "v1.17.0"
        let version: String         // tag without a leading "v"
        let assetName: String
        let downloadURL: URL
        let sizeBytes: Int
        let publishedAt: Date?
        let notes: String?
    }

    enum Availability: Equatable {
        case unknown                    // not checked yet
        case checking
        case none                       // repository has no releases
        case upToDate(String)           // installed == latest
        case updateAvailable(Release)
        case newerThanPublished(String) // running a dev build ahead of any release
        case failed(String)
    }

    enum ReleaseError: LocalizedError {
        case http(Int)
        case malformed(String)
        case noRunnerAsset(String)

        var errorDescription: String? {
            switch self {
            case .http(let code):
                // 403 here is almost always the unauthenticated rate limit, which
                // is worth naming — it looks like a permissions problem otherwise.
                return code == 403
                    ? "GitHub refused the request (rate limited — try again in a while)"
                    : "GitHub returned HTTP \(code)"
            case .malformed(let what):
                return "Couldn't read GitHub's response: \(what)"
            case .noRunnerAsset(let tag):
                return "Release \(tag) has no runner .ipa attached"
            }
        }
    }

    // MARK: - Checking

    /// Asks GitHub for the latest release and compares it with `installedVersion`.
    ///
    /// `installedVersion` is what the running server reports; nil when the runner
    /// isn't up, in which case any release counts as an update.
    static func check(installedVersion: String?) async -> Availability {
        do {
            guard let release = try await latestRelease() else { return .none }
            guard let installed = installedVersion else { return .updateAvailable(release) }

            switch compareVersions(installed, release.version) {
            case .orderedAscending:  return .updateAvailable(release)
            case .orderedSame:       return .upToDate(installed)
            case .orderedDescending: return .newerThanPublished(installed)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            ictrlLog("Runner release check failed: \(message)")
            return .failed(message)
        }
    }

    /// Returns the newest release carrying a runner .ipa, or nil when the
    /// repository has published none.
    static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=10")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iCTRL", forHTTPHeaderField: "User-Agent")   // GitHub rejects requests without one
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReleaseError.malformed("no HTTP response")
        }
        // An empty repository answers 404 for /releases/latest but 200 + [] here,
        // which is why this asks for the list rather than the latest.
        guard (200..<300).contains(http.statusCode) else {
            throw ReleaseError.http(http.statusCode)
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ReleaseError.malformed("expected a list of releases")
        }
        if items.isEmpty { return nil }

        // Newest first is GitHub's order; take the first one that actually has a
        // runner package. A release with only source archives is not installable.
        for item in items {
            guard let tag = item["tag_name"] as? String else { continue }
            if (item["draft"] as? Bool) == true { continue }
            guard let assets = item["assets"] as? [[String: Any]] else { continue }
            guard let asset = pickRunnerAsset(assets) else { continue }
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { continue }

            return Release(
                tag: tag,
                version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                assetName: name,
                downloadURL: url,
                sizeBytes: asset["size"] as? Int ?? 0,
                publishedAt: (item["published_at"] as? String).flatMap(parseISO8601),
                notes: item["body"] as? String
            )
        }
        return nil
    }

    /// Picks the runner package out of a release's assets.
    ///
    /// A release carries both halves of iCTRL, so name matching has to exclude
    /// the app: "iCTRL.ipa" would otherwise match a naive `.ipa` search and
    /// install this app over itself.
    private static func pickRunnerAsset(_ assets: [[String: Any]]) -> [String: Any]? {
        let ipas = assets.filter { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        if let runner = ipas.first(where: {
            let n = ($0["name"] as? String)?.lowercased() ?? ""
            return n.contains("runner") || n.contains("uitests")
        }) { return runner }
        // Only one .ipa and it isn't named like a runner: don't guess.
        return nil
    }

    // MARK: - Downloading

    /// Downloads `release` to a temporary file and returns its URL.
    ///
    /// Downloaded rather than streamed straight into AFC so a partial transfer
    /// can never reach installation_proxy — a truncated .ipa fails deep inside
    /// the installer with an error that says nothing about the download.
    static func download(_ release: Release,
                         progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        ictrlLog("Downloading runner \(release.tag) — \(release.assetName), \(release.sizeBytes)B")

        var request = URLRequest(url: release.downloadURL)
        request.setValue("iCTRL", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ReleaseError.http(http.statusCode)
        }

        // Content-Length is more trustworthy than the API's size field for the
        // actual transfer (redirects to a CDN can change it).
        let expected = response.expectedContentLength > 0
            ? Int(response.expectedContentLength)
            : release.sizeBytes

        var data = Data()
        data.reserveCapacity(max(expected, 1 << 20))
        var lastReported = 0.0
        for try await byte in bytes {
            data.append(byte)
            if expected > 0 {
                let fraction = Double(data.count) / Double(expected)
                // Reporting every byte would flood the main actor.
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    await progress(min(fraction, 1.0))
                }
            }
        }
        await progress(1.0)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-releases", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(release.assetName)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)

        ictrlLog("Downloaded runner \(release.tag) to \(dest.lastPathComponent) (\(data.count)B)")
        return dest
    }

    // MARK: - Helpers

    /// Semver-ish comparison that treats "1.16.0" and "1.16" as equal and never
    /// throws on junk — a malformed tag should not break the update check.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        return f.date(from: s)
    }
}
