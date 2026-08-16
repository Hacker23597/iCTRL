import Foundation

/// The runner package shipped inside this app.
///
/// The runner is the half of iCTRL that actually drives XCUITest, and it
/// installs separately. Carrying a copy makes the common case — install the
/// runner that matches this app — a single tap with nothing to find, download,
/// or keep in sync.
///
/// It is copied into the app bundle by `make ipa` after the runner is packaged,
/// not declared as a project resource: one xcodebuild invocation produces both
/// apps, so the runner `.ipa` does not exist when the project is generated.
/// A development build made straight from Xcode therefore won't have it, which
/// is why `isAvailable` exists rather than this being assumed present.
enum BundledRunner {

    /// Matches the name `make ipa` copies in.
    private static let fileName = "iCTRLUITests-Runner.ipa"

    static var url: URL? {
        Bundle.main.url(forResource: "iCTRLUITests-Runner", withExtension: "ipa")
    }

    static var isAvailable: Bool { url != nil }

    /// What to call it in the UI.
    static var displayName: String { fileName }

    /// Size on disk, for showing alongside the name.
    static var sizeBytes: Int? {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        else { return nil }
        return values.fileSize
    }

    static var formattedSize: String? {
        guard let sizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}
