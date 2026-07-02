import SwiftUI

@main
struct iCTRLApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
        }
    }
}
