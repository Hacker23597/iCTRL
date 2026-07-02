import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isServerRunning ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(appState.isServerRunning ? "Running" : "Stopped")
                            .foregroundColor(.secondary)
                    }
                }

                if appState.isServerRunning {
                    HStack {
                        Text("Address")
                        Spacer()
                        Text(appState.serverAddress)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text("Port")
                    Spacer()
                    Text(verbatim: "\(appState.serverPort)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("iCTRL Server")
            }

            Section {
                Toggle("Auto-start on launch", isOn: $appState.autoStartServer)
                Toggle("Allow remote access", isOn: $appState.allowRemoteAccess)
            } header: {
                Text("Preferences")
            } footer: {
                Text("When remote access is off, only this device can connect to the server.")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Protocol")
                    Spacer()
                    Text("JSON-RPC 2.0")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }
}
