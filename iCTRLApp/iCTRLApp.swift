import SwiftUI

@main
struct iCTRLApp: App {
    @StateObject private var appState = AppState()

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
            .sheet(item: $appState.pendingAuthRequest) { request in
                AuthRequestView(request: request)
                    .environmentObject(appState)
            }
        }
    }
}
