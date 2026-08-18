import Foundation

/// Signs an app with the user's own Apple ID.
///
/// The pipeline, in order: authenticate against Apple's GSA servers → pick a
/// team → register this device → obtain a certificate → create an App ID →
/// fetch a provisioning profile → re-sign the bundle. Only the last step is
/// local; everything before it is Apple's to grant, which is why almost every
/// failure here needs to be reported in Apple's terms rather than ours.
///
/// AltSign does the protocol work. What this type owns is the sequencing, the
/// decisions AltSign leaves open (which team, whether to reuse a certificate),
/// and turning failures into something a person can act on.
///
/// Two constraints shape the design, both from free Apple accounts:
///
///   - **One certificate at a time.** Requesting a second revokes the first,
///     silently breaking every app already signed with it — including,
///     potentially, iCTRL itself. So a stored identity is reused whenever it
///     can be, and issuing a new one is treated as a destructive act.
///   - **Seven-day profiles.** Signed apps stop launching after a week. Nothing
///     here can change that; the UI's job is to make it predictable rather than
///     a surprise.
@MainActor
final class AppSigner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case authenticating
        case needsVerificationCode        // two-factor; waiting on the user
        case fetchingTeam
        case registeringDevice
        case preparingCertificate
        case preparingProfile
        case signing
        case done(String)                 // bundle id
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .done, .failed, .needsVerificationCode: return false
            default: return true
            }
        }
    }

    enum SigningError: LocalizedError {
        case noAnisetteServer
        case noTeam
        case cancelled
        case apple(String)
        case local(String)

        var errorDescription: String? {
            switch self {
            case .noAnisetteServer:
                return "Choose an anisette server first — signing in to an Apple ID needs one."
            case .noTeam:
                return "This Apple ID has no development team. Even a free account should have one; try signing in again."
            case .cancelled:
                return "Cancelled."
            case .apple(let message):
                return message
            case .local(let message):
                return message
            }
        }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { ictrlLog("Signing phase → \(phase)") }
    }

    /// Set while `phase == .needsVerificationCode`; calling it resumes the
    /// login. Held rather than passed along because the code arrives from the
    /// UI long after the call that asked for it.
    private var verificationContinuation: ((String?) -> Void)?

    /// The identity in use, if we have one.
    @Published private(set) var identity: SigningIdentityStore.Identity? = SigningIdentityStore.load()

    // MARK: - Two-factor

    /// Supplies the code Apple sent to the user's other devices.
    func submitVerificationCode(_ code: String) {
        guard let resume = verificationContinuation else { return }
        verificationContinuation = nil
        resume(code)
    }

    func cancelVerification() {
        guard let resume = verificationContinuation else { return }
        verificationContinuation = nil
        resume(nil)
    }

    // MARK: - Signing

    /// Signs the app at `appURL` (an unpacked `.app`) in place.
    ///
    /// `appleID` and `password` are used for this call and then dropped — the
    /// password is never stored. What persists is the certificate, which is
    /// what later signing actually needs.
    func signApp(at appURL: URL, appleID: String, password: String) async throws {
        do {
            let anisette = try await AnisetteClient.fetchFromConfiguredServer()

            phase = .authenticating
            let (account, session) = try await authenticate(appleID: appleID,
                                                            password: password,
                                                            anisette: anisette)

            phase = .fetchingTeam
            let team = try await fetchPreferredTeam(account: account, session: session)

            phase = .registeringDevice
            let device = try await registerThisDevice(team: team, session: session)

            phase = .preparingCertificate
            let certificate = try await obtainCertificate(team: team, session: session, appleID: appleID)

            phase = .preparingProfile
            let bundleID = try bundleIdentifier(of: appURL)
            let profile = try await obtainProfile(bundleID: bundleID,
                                                  appName: appURL.deletingPathExtension().lastPathComponent,
                                                  team: team,
                                                  device: device,
                                                  session: session)

            phase = .signing
            try await sign(appURL: appURL, team: team, certificate: certificate, profile: profile)

            phase = .done(bundleID)
            ictrlLog("✅ Signed \(bundleID) with team \(team.identifier)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            ictrlLog("❌ Signing failed: \(message)")
            phase = .failed(message)
            throw error
        }
    }

    // MARK: - Steps

    private func authenticate(appleID: String,
                              password: String,
                              anisette: ALTAnisetteData) async throws -> (ALTAccount, ALTAppleAPISession) {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.authenticate(
                appleID: appleID,
                password: password,
                anisetteData: anisette,
                verificationHandler: { [weak self] completion in
                    // Apple wants a 2FA code. Park the continuation and let the
                    // UI collect it; nothing proceeds until it arrives.
                    Task { @MainActor in
                        guard let self else { return completion(nil) }
                        self.verificationContinuation = completion
                        self.phase = .needsVerificationCode
                    }
                },
                completionHandler: { account, session, error in
                    if let account, let session {
                        continuation.resume(returning: (account, session))
                    } else {
                        continuation.resume(throwing: Self.wrap(error, fallback: "Apple rejected the sign-in."))
                    }
                }
            )
        }
    }

    /// Picks the team to sign under.
    ///
    /// Most accounts have exactly one. When there are several, a paid team is
    /// preferred over a free one — it produces certificates that last a year
    /// instead of a week, which is what the user would pick if asked.
    private func fetchPreferredTeam(account: ALTAccount,
                                    session: ALTAppleAPISession) async throws -> ALTTeam {
        let teams: [ALTTeam] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchTeams(for: account, session: session) { teams, error in
                if let teams {
                    continuation.resume(returning: teams)
                } else {
                    continuation.resume(throwing: Self.wrap(error, fallback: "Couldn't read this account's teams."))
                }
            }
        }

        guard !teams.isEmpty else { throw SigningError.noTeam }
        if let paid = teams.first(where: { $0.type != .free }) { return paid }
        guard let team = teams.first else { throw SigningError.noTeam }
        return team
    }

    /// Registers this device with the team, which a profile can't include
    /// otherwise. Already-registered is success, not an error.
    private func registerThisDevice(team: ALTTeam,
                                    session: ALTAppleAPISession) async throws -> ALTDevice {
        let udid = try deviceUDID()
        let name = await UIDeviceName.current()

        let existing: [ALTDevice] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchDevices(for: team, session: session) { devices, error in
                if let devices {
                    continuation.resume(returning: devices)
                } else {
                    continuation.resume(throwing: Self.wrap(error, fallback: "Couldn't list the team's devices."))
                }
            }
        }
        if let already = existing.first(where: { $0.identifier.caseInsensitiveCompare(udid) == .orderedSame }) {
            ictrlLog("Device already registered with the team")
            return already
        }

        return try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.registerDevice(name: name, identifier: udid, team: team, session: session) { device, error in
                if let device {
                    continuation.resume(returning: device)
                } else {
                    continuation.resume(throwing: Self.wrap(error, fallback: "Apple wouldn't register this device."))
                }
            }
        }
    }

    /// Returns a usable certificate, reusing the stored one when possible.
    ///
    /// Issuing a new certificate revokes the old one, so this only does that
    /// when there is genuinely nothing to reuse. On a free account that means
    /// every app previously signed with the old certificate stops launching —
    /// a consequence worth avoiding rather than a routine step.
    private func obtainCertificate(team: ALTTeam,
                                   session: ALTAppleAPISession,
                                   appleID: String) async throws -> ALTCertificate {
        if let stored = identity,
           stored.teamID == team.identifier,
           !stored.isProbablyExpired,
           let certificate = ALTCertificate(p12Data: stored.p12Data, password: stored.p12Password) {
            ictrlLog("Reusing the stored certificate (issued \(stored.issuedAt))")
            return certificate
        }

        let machineName = "iCTRL — \(await UIDeviceName.current())"
        let certificate: ALTCertificate = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.addCertificate(machineName: machineName, to: team, session: session) { certificate, error in
                if let certificate {
                    continuation.resume(returning: certificate)
                } else {
                    continuation.resume(throwing: Self.wrap(error, fallback: "Apple wouldn't issue a signing certificate."))
                }
            }
        }

        // Persist it: on a free account this is the only certificate the
        // account has, and losing track of it means revoking it to get another.
        let password = UUID().uuidString
        if let p12 = certificate.p12Data(), let data = p12 as Data? {
            let stored = SigningIdentityStore.Identity(
                teamID: team.identifier,
                teamName: team.name,
                isFreeAccount: team.type == .free,
                p12Data: data,
                p12Password: password,
                certificateName: certificate.name,
                issuedAt: Date(),
                appleID: appleID
            )
            SigningIdentityStore.save(stored)
            identity = stored
        } else {
            ictrlLog("⚠️ Certificate issued but couldn't be exported; it won't survive a relaunch")
        }

        return certificate
    }

    /// Registers the App ID and returns a profile covering it.
    private func obtainProfile(bundleID: String,
                               appName: String,
                               team: ALTTeam,
                               device: ALTDevice,
                               session: ALTAppleAPISession) async throws -> ALTProvisioningProfile {
        let appIDs: [ALTAppID] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchAppIDs(for: team, session: session) { appIDs, error in
                if let appIDs {
                    continuation.resume(returning: appIDs)
                } else {
                    continuation.resume(throwing: Self.wrap(error, fallback: "Couldn't read the team's App IDs."))
                }
            }
        }

        let appID: ALTAppID
        if let existing = appIDs.first(where: { $0.bundleIdentifier == bundleID }) {
            appID = existing
        } else {
            appID = try await withCheckedThrowingContinuation { continuation in
                ALTAppleAPI.shared.addAppID(withName: appName, bundleIdentifier: bundleID, team: team, session: session) { appID, error in
                    if let appID {
                        continuation.resume(returning: appID)
                    } else {
                        // Free accounts cap App IDs at 10 per week, and the
                        // limit resets on its own — worth saying so.
                        continuation.resume(throwing: Self.wrap(error, fallback: "Apple wouldn't register this app's identifier. Free accounts allow 10 per week."))
                    }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchProvisioningProfile(for: appID, team: team, session: session) { profile, error in
                if let profile {
                    continuation.resume(returning: profile)
                } else {
                    continuation.resume(throwing: Self.wrap(error, fallback: "Apple wouldn't issue a provisioning profile."))
                }
            }
        }
    }

    private func sign(appURL: URL,
                      team: ALTTeam,
                      certificate: ALTCertificate,
                      profile: ALTProvisioningProfile) async throws {
        let signer = ALTSigner(team: team, certificate: certificate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            signer.signApp(at: appURL, provisioningProfiles: [profile]) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Self.wrap(error, fallback: "Couldn't write the signature."))
                }
            }
        }

        // ldid recurses into `.framework` and `.appex` bundles only, so a
        // `.xctest` plugin and a loose dylib come out hashed into the parent's
        // CodeResources but without signatures of their own. The app installs
        // either way; an XCUITest runner built that way dies at launch, because
        // testmanagerd validates the plugin's own signature and dyld refuses a
        // dylib with no cdhash. This is the same work the Makefile does with
        // two extra `codesign` calls, on a device where codesign doesn't exist.
        let nested = NestedBundleSigner.nestedBinaries(at: appURL)
        guard !nested.isEmpty else { return }

        ictrlLog("Signing \(nested.count) nested binaries ldid skipped")
        guard let p12 = certificate.p12Data() else {
            throw SigningError.local("The certificate couldn't be exported to sign the runner's plugin.")
        }
        try NestedBundleSigner.signNestedBundles(at: appURL, p12Data: p12, password: nil)

        // Verify rather than assume: a half-signed bundle installs cleanly and
        // then fails at launch, where the error names none of this.
        try NestedBundleSigner.verifySigned(at: appURL)
    }

    // MARK: - Helpers

    private func bundleIdentifier(of appURL: URL) throws -> String {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String
        else {
            throw SigningError.local("Couldn't read the app's bundle identifier — is this a valid .app?")
        }
        return bundleID
    }

    /// The device's UDID, which the profile has to name.
    ///
    /// Read from the pairing file rather than asked of the system: iOS gives
    /// apps no API for the real UDID, and `identifierForVendor` is a different
    /// number that Apple's portal will not accept.
    private func deviceUDID() throws -> String {
        guard let data = try? Data(contentsOf: PairingFileStore.storedURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let udid = plist["UDID"] as? String ?? plist["SystemBUID"] as? String
        else {
            throw SigningError.local("Couldn't read this device's UDID from the pairing file. Import it in Settings first.")
        }
        return udid
    }

    /// Turns an AltSign/Apple error into something worth showing.
    private static func wrap(_ error: Error?, fallback: String) -> Error {
        guard let error else { return SigningError.apple(fallback) }
        let message = (error as NSError).localizedDescription
        return SigningError.apple(message.isEmpty ? fallback : message)
    }
}

/// The device's display name, for the certificate and device registration.
private enum UIDeviceName {
    @MainActor static func current() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iOS device"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
