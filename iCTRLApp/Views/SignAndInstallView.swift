import SwiftUI

/// A file the user picked, wrapped so `.sheet(item:)` can key off it.
///
/// `URL` isn't `Identifiable`, and presenting the sheet from a plain boolean
/// races the picker: the sheet can appear before the URL is set.
struct PickedIPA: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Signs an `.ipa` with the user's own Apple ID and installs it.
///
/// The flow is deliberately explicit about what it costs the user, because two
/// of the costs are invisible until they bite:
///
///   - The anisette server sees the fingerprint their Apple ID logs in under.
///     No server is chosen by default; picking one is a trust decision that
///     belongs to them.
///   - A free account holds one certificate. Issuing a new one revokes the old
///     and stops every app already signed with it from launching — so when
///     that is about to happen, this says so first.
struct SignAndInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var signer = AppSigner()

    let ipaURL: URL

    @State private var appleID = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var anisetteServer = AnisetteClient.configuredServer?.absoluteString
        ?? AnisetteClient.fallbackServer.address
    @State private var anisetteServers: [AnisetteClient.Server] = [AnisetteClient.fallbackServer]
    @State private var installPhase: IPAInstaller.Phase = .idle
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                packageSection
                anisetteSection
                accountSection
                if signer.phase == .needsVerificationCode { verificationSection }
                statusSection
                actionSection
            }
            .navigationTitle("Sign & Install")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
            }
        }
    }

    // MARK: - Sections

    private var packageSection: some View {
        Section {
            LabeledContent("Package", value: ipaURL.lastPathComponent)
        } footer: {
            Text("The app is re-signed with your own certificate, then installed. The original file isn't modified.")
        }
    }

    private var anisetteSection: some View {
        Section {
            Picker("Server", selection: $anisetteServer) {
                ForEach(anisetteServers) { server in
                    Text(server.name).tag(server.address)
                }
                // Keeps a hand-typed address selectable instead of silently
                // reverting to a listed one.
                if !anisetteServers.contains(where: { $0.address == anisetteServer }) {
                    Text("Custom").tag(anisetteServer)
                }
            }
            .pickerStyle(.menu)

            DisclosureGroup("Use a different server") {
                TextField("https://…", text: $anisetteServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.footnote)
            }
        } header: {
            Text("Anisette server")
        } footer: {
            Text("Apple requires a device fingerprint to accept a sign-in, and iOS can't generate one — so it comes from a server. This list is the one SideStore publishes; most entries are run by individuals, and whichever you pick sees the fingerprint your Apple ID logs in under. Point it at your own if you'd rather.")
        }
        .task {
            anisetteServers = await AnisetteClient.fetchServerList()
        }
    }

    private var accountSection: some View {
        Section {
            TextField("Apple ID", text: $appleID)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            SecureField("Password", text: $password)
                .textContentType(.password)
        } header: {
            Text("Apple ID")
        } footer: {
            Text("Sent to Apple to request a signing certificate. The password isn't stored — only the certificate Apple issues is kept, so you won't be asked again until it expires.")
        }
    }

    private var verificationSection: some View {
        Section {
            TextField("Verification code", text: $verificationCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("Submit code") {
                signer.submitVerificationCode(verificationCode)
                verificationCode = ""
            }
            .disabled(verificationCode.count < 6)
        } header: {
            Text("Two-factor authentication")
        } footer: {
            Text("Apple sent a code to your other devices.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let identity = signer.identity {
            Section {
                LabeledContent("Team", value: identity.teamName)
                LabeledContent("Certificate", value: identity.certificateName)
                if let expiry = identity.likelyExpiry {
                    LabeledContent("Expires") {
                        Text(expiry, style: .date)
                            .foregroundColor(identity.isProbablyExpired ? .red : .secondary)
                    }
                }
            } header: {
                Text("Signing identity")
            } footer: {
                if identity.isFreeAccount {
                    Text("Free accounts get one certificate and seven-day apps. Signing in from another tool revokes this certificate and stops apps signed with it from launching.")
                }
            }
        }

        if signer.phase.isBusy || busy || errorMessage != nil {
            Section {
                if let errorMessage {
                    Label {
                        Text(errorMessage).font(.footnote)
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(statusText).font(.footnote)
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await run() }
            } label: {
                Label("Sign and install", systemImage: "signature")
            }
            .disabled(!canStart)
        }
    }

    // MARK: - State

    private var canStart: Bool {
        !busy
            && !signer.phase.isBusy
            && !appleID.isEmpty
            && !password.isEmpty
            && URL(string: anisetteServer)?.scheme?.hasPrefix("http") == true
    }

    private var statusText: String {
        switch installPhase {
        case .uploading(let f):  return "Uploading — \(Int(f * 100))%"
        case .installing(let f): return "Installing — \(Int(f * 100))%"
        case .connecting:        return "Connecting to the device…"
        default: break
        }
        switch signer.phase {
        case .authenticating:        return "Signing in to Apple…"
        case .needsVerificationCode: return "Waiting for your verification code…"
        case .fetchingTeam:          return "Reading your team…"
        case .registeringDevice:     return "Registering this device…"
        case .preparingCertificate:  return "Getting a signing certificate…"
        case .preparingProfile:      return "Getting a provisioning profile…"
        case .signing:               return "Signing the app…"
        case .done:                  return "Signed."
        default:                     return "Working…"
        }
    }

    // MARK: - Running

    private func run() async {
        busy = true
        errorMessage = nil
        defer { busy = false }

        AnisetteClient.configuredServer = URL(string: anisetteServer)

        // The picked file lives outside our container; without the security
        // scope the read fails with a permissions error that doesn't look like
        // one.
        let scoped = ipaURL.startAccessingSecurityScopedResource()
        defer { if scoped { ipaURL.stopAccessingSecurityScopedResource() } }

        var unpacked: IPAPackage.Unpacked?
        defer { if let unpacked { IPAPackage.cleanUp(unpacked) } }

        do {
            let package = try IPAPackage.unpack(ipaURL)
            unpacked = package

            try await signer.signApp(at: package.appURL, appleID: appleID, password: password)
            let signedIPA = try IPAPackage.repack(package)

            // The password has done its job; don't leave it in memory or in the
            // field for the next person to pick up the device.
            password = ""

            await IPAInstaller.install(ipaURL: signedIPA,
                                       pairingPath: PairingFileStore.storedURL.path) { phase in
                installPhase = phase
            }

            if case .failed(let why) = installPhase {
                errorMessage = why
            } else {
                dismiss()
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
