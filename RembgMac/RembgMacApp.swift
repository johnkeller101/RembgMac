import SwiftUI
import ServiceManagement

@main
struct RembgMacApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("launchAtLogin") private var launchAtLogin = true

    init() {
        // Sync launch-at-login preference on startup
        let enabled = UserDefaults.standard.bool(forKey: "launchAtLogin")
        if enabled {
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            Image(systemName: "circle.fill")
                .foregroundStyle(appState.statusColor)
        }
        .menuBarExtraStyle(.menu)

        Window("rembg Logs", id: "log-window") {
            LogWindowView(appState: appState)
        }
        .defaultSize(width: 700, height: 400)
    }
}

struct MenuContent: View {
    @ObservedObject var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Text(appState.statusText)
            .font(.headline)

        Divider()

        switch appState.status {
        case .running, .unhealthy, .starting, .downloadingModel:
            Button("Stop Server") {
                appState.stopServer()
            }
        case .stopped:
            if appState.venvExists {
                Button("Start Server") {
                    appState.startServer()
                }
            }
        case .settingUp, .updating:
            // No start/stop while setup/update is in progress
            EmptyView()
        }

        if appState.requestCount > 0 {
            Text("Processed: \(appState.requestCount.formatted()) images")
        }

        if appState.startTime != nil {
            Text("Uptime: \(appState.uptimeText)")
        }

        Divider()

        if !appState.venvExists {
            Button("Setup") {
                Task { await appState.runSetup() }
            }
            .disabled({
                if case .settingUp = appState.status { return true }
                return false
            }())
        }

        Button("Update rembg") {
            Task { await appState.runUpgrade() }
        }
        .disabled(!appState.venvExists || {
            switch appState.status {
            case .settingUp, .updating: return true
            default: return false
            }
        }())

        Button("View Logs") {
            openWindow(id: "log-window")
        }

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { newValue in
                if newValue {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }

        Divider()

        Button("Quit") {
            appState.flushRequestCount()
            appState.stopServer()
            NSApplication.shared.terminate(nil)
        }
    }
}
