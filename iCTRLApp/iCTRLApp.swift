import SwiftUI

@main
struct iCTRLApp: App {
    @StateObject private var appState = AppState()

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
