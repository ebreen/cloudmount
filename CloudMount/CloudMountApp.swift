import SwiftUI
import CloudMountKit

@main
struct CloudMountApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    @State private var hasStartedMonitoring = false
    
    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
                .onAppear {
                    guard !hasStartedMonitoring else { return }
                    hasStartedMonitoring = true
                    appState.startMonitoring()
                }
        } label: {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
        
        // Use Window instead of Settings to fix text field focus bug
        Window("CloudMount Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
