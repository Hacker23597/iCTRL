import SwiftUI

/// A file the user picked, wrapped so `.sheet(item:)` can key off it.
///
/// `URL` isn't `Identifiable`, and presenting the sheet from a plain boolean
/// races the picker: the sheet can appear before the URL is set.
struct PickedIPA: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Signs an `.ipa` and installs it.
///
/// Three ways to get a signature, differing in what they cost:
///
///   - **An imported certificate** contacts nobody. It re-signs using the
///     provisioning profile already in the package, which is why it can renew a
///     package but not provision a new one.
///   - **A saved session** skips the password prompt but still needs anisette —
///     a session is presented alongside a fingerprint, not instead of one.
///   - **Signing in** is the fallback that always works and always costs the
///     most: password, anisette server, and Apple's rate limits.
///
/// The view picks the cheapest one available rather than making the user learn
/// the distinction, but shows which it chose and lets them override it.
struct SignAndInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var signer = AppSigner()

    let ipaURL: URL

    /// How to obtain the signature. Ordered cheapest-first for the picker.
    enum Method: String, CaseIterable, Identifiable {
        case importedCertificate
        case savedSession
        case appleID
        var id: String { rawValue }

        var title: String {
            switch self {
            case .importedCertificate: return "Imported certificate"
            case .savedSession:        return "Saved sign-in"
            case .appleID:             return "Apple ID"
            }
        }
    }

    @State private var method: Method = .appleID
    @State private var appleID = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var anisetteServer = AnisetteClient.configuredServer?.absoluteString
        ?? AnisetteClient.fallbackServer.address
    @State private var anisetteServers: [AnisetteClient.Server] = [AnisetteClient.fallbackServer]
    @State private var installPhase: IPAInstaller.Phase = .idle
    @State private var busy = false
    @State private var errorMessage: String?

    @State private var importedCertificate = ImportedCertificate.load()
    @State private var savedSession = AppleIDSession.load()
    @State private var showCertificateImporter = false
    @State private var pendingCertificateURL: URL?
    @State private var certificatePassword = ""
    @State private var showCertificatePasswordPrompt = false

    var body: some View {
        NavigationStack {
            Form {
                packageSection
                methodSection

                switch method {
                case .importedCertificate:
                    certificateSection
                case .savedSession:
                    savedSessionSection
                    anisetteSection
                case .appleID:
                    anisetteSection
                    accountSection
                }

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
            .onAppear { method = defaultMethod }
            .fileImporter(isPresented: $showCertificateImporter,
                          allowedContentTypes: [.pkcs12],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    pendingCertificateURL = url
                    certificatePassword = ""
                    showCertificatePasswordPrompt = true
                }
            }
            .alert("Certificate password", isPresented: $showCertificatePasswordPrompt) {
                SecureField("Password", text: $certificatePassword)
                Button("Import") { importCertificate() }
                Button("Cancel", role: .cancel) { pendingCertificateURL = nil }
            } message: {
                Text("A .p12 exported from Keychain Access uses the password you set. Some sideloaders use the machine ID. An empty password is also valid.")
            }
        }
    }

    /// Prefers whichever method costs the user least, without hiding the choice.
    private var defaultMethod: Method {
        if let cert = importedCertificate, !cert.isExpired { return .importedCertificate }
        if savedSession != nil { return .savedSession }
        return .appleID
    }

    // MARK: - Sections

    private var packageSection: some View {
        Section {
            LabeledContent("Package", value: ipaURL.lastPathComponent)
        } footer: {
            Text("The app is re-signed with your own certificate, then installed. The original file isn't modified.")
        }
    }

    private var methodSection: some View {
        Section {
            Picker("Sign with", selection: $method) {
                ForEach(Method.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            switch method {
            case .importedCertificate:
                Text("Signs entirely on this device — no Apple ID, no password, no anisette server. It reuses the provisioning profile already in the package, so it can renew a package but can't provision one that has never been signed.")
            case .savedSession:
                Text("Skips the password prompt. Still contacts the anisette server and Apple, because a saved session is presented alongside a device fingerprint rather than instead of one.")
            case .appleID:
                Text("Works in every case, and costs the most: your password, an anisette server, and Apple's limits on how many app identifiers a free account may register each week.")
            }
        }
    }

    @ViewBuilder
    private var certificateSection: some View {
        Section {
            if let cert = importedCertificate {
                LabeledContent("Certificate", value: cert.commonName)
                if let team = cert.teamID {
                    LabeledContent("Team", value: team)
                }
                if let expiry = cert.expiresAt {
                    LabeledContent("Expires") {
                        Text(expiry, style: .date)
                            .foregroundColor(cert.isExpired ? .red : .secondary)
                    }
                }
                Button("Replace…") { showCertificateImporter = true }
                Button("Remove", role: .destructive) {
                    ImportedCertificate.clear()
                    importedCertificate = nil
                    method = defaultMethod
                }
            } else {
                Button {
                    showCertificateImporter = true
                } label: {
                    Label("Import a .p12…", systemImage: "doc.badge.plus")
                }
            }
        } header: {
            Text("Certificate")
        } footer: {
            if importedCertificate == nil {
                Text("Export one from Keychain Access on a Mac, or take the .p12 a sideloader wrote alongside the app it installed. A paid developer certificate lasts a year; a free one lasts a week.")
            }
        }
    }

    @ViewBuilder
    private var savedSessionSection: some View {
        Section {
            if let session = savedSession {
                LabeledContent("Apple ID", value: session.appleID)
                LabeledContent("Saved") {
                    Text(session.savedAt, style: .relative) + Text(" ago")
                }
                Button("Forget", role: .destructive) {
                    AppleIDSession.clear()
                    savedSession = nil
                    method = defaultMethod
                }
            } else {
                Text("No saved sign-in yet — sign in once and it'll be offered here.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Saved sign-in")
        } footer: {
            Text("Only the session token is stored, never your password. If Apple stops accepting it you'll be asked to sign in again.")
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
        guard !busy, !signer.phase.isBusy else { return false }
        switch method {
        case .importedCertificate:
            guard let cert = importedCertificate else { return false }
            return !cert.isExpired
        case .savedSession:
            return savedSession != nil && anisetteServerIsValid
        case .appleID:
            return !appleID.isEmpty && !password.isEmpty && anisetteServerIsValid
        }
    }

    private var anisetteServerIsValid: Bool {
        URL(string: anisetteServer)?.scheme?.hasPrefix("http") == true
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

    // MARK: - Importing a certificate

    private func importCertificate() {
        guard let url = pendingCertificateURL else { return }
        pendingCertificateURL = nil
        do {
            importedCertificate = try ImportedCertificate.importCertificate(from: url,
                                                                            password: certificatePassword)
            method = .importedCertificate
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        certificatePassword = ""
    }

    // MARK: - Running

    private func run() async {
        busy = true
        errorMessage = nil
        defer { busy = false }

        // Only remember the server when it is actually going to be used —
        // signing with an imported certificate never contacts one.
        if method != .importedCertificate {
            AnisetteClient.configuredServer = URL(string: anisetteServer)
        }

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

            switch method {
            case .importedCertificate:
                try await signer.resignWithImportedCertificate(at: package.appURL)

            case .savedSession:
                do {
                    try await signer.signAppWithStoredSession(at: package.appURL)
                } catch {
                    // The token is gone; say so in terms of what to do next
                    // rather than leaving a dead option selected.
                    savedSession = nil
                    method = .appleID
                    throw AppSigner.SigningError.local(
                        "That saved sign-in is no longer accepted. Sign in with your Apple ID again.")
                }

            case .appleID:
                try await signer.signApp(at: package.appURL, appleID: appleID, password: password)
                savedSession = AppleIDSession.load()
            }

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
