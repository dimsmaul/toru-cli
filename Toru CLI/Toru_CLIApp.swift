import SwiftUI

@main
struct Toru_CLIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessions = SessionStore()
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessions)
                .environmentObject(themeManager)
                .environmentObject(settings)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear {
                    DispatchQueue.main.async {
                        themeManager.select(name: settings.themeName)
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            TorMenuCommands(
                sessions: sessions,
                onIncreaseFont: { settings.fontSize = min(settings.fontSize + 1, 24) },
                onDecreaseFont: { settings.fontSize = max(settings.fontSize - 1, 9) },
                onClearBuffer: { /* TorTerminalView handles via super; hooked v1.1 */ }
            )
        }

        Settings {
            SettingsView()
        }
    }
}
