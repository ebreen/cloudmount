import SwiftUI

@main
struct CloudMountApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
        } label: {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var macFUSEInstalled: Bool = false
    @Published var isCheckingMacFUSE: Bool = false
    @Published var storedBuckets: [String] = []
    
    init() {
        checkMacFUSE()
    }
    
    func checkMacFUSE() {
        isCheckingMacFUSE = true
        macFUSEInstalled = MacFUSEDetector.isInstalled()
        isCheckingMacFUSE = false
    }
}
