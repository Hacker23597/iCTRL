import SwiftUI

@main
struct iCTRLApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permission = NetworkPermission()
    /// Clients and log of the runner on this device; shared by Settings and Logs.
    @StateObject private var runnerAdmin = RunnerAdmin(port: 8200)
    @State private var showPermissionAlert = false

    init() {
        // Touch the logger during init so every run produces a file, even one
        // that crashes before the user does anything.
        ictrlLog("App launched")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
            }
            .environmentObject(appState)
            .environmentObject(runnerAdmin)
            .sheet(item: $appState.pendingAuthRequest) { request in
                AuthRequestView(request: request)
                    .environmentObject(appState)
            }
            // On a fresh install this raises the system prompts; afterwards it
            // only reads them back, and a denial is said once per launch.
            .task { permission.probe() }
            .onReceive(permission.$networkData.combineLatest(permission.$localNetwork)) { _ in
                if !permission.denied.isEmpty { showPermissionAlert = true }
            }
            .alert(L10n.t(.networkPermissionTitle), isPresented: $showPermissionAlert) {
                Button(L10n.t(.openSettings)) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                Button(L10n.t(.laterButton), role: .cancel) {}
            } message: {
                Text(String(format: L10n.t(.networkPermissionBody), permission.denied.joined(separator: ", ")))
            }
        }
    }
}
