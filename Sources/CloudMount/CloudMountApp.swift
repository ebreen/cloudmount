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
                .onAppear {
                    // Bring settings window to front and make it key
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // Find and make the settings window key
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        for window in NSApplication.shared.windows {
                            if window.title.contains("Settings") || window.identifier?.rawValue.contains("settings") == true {
                                window.makeKeyAndOrderFront(nil)
                                break
                            }
                        }
                    }
                }
        }
    }
}

/// Bucket configuration with mount status
struct BucketConfig: Identifiable, Hashable {
    let id: String
    let name: String
    var mountpoint: String
    var isMounted: Bool = false
    
    init(name: String, mountpoint: String = "") {
        self.id = name
        self.name = name
        self.mountpoint = mountpoint.isEmpty ? "/Volumes/\(name)" : mountpoint
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var macFUSEInstalled: Bool = false
    @Published var isCheckingMacFUSE: Bool = false
    @Published var storedBuckets: [String] = []
    @Published var bucketConfigs: [BucketConfig] = []
    @Published var isDaemonRunning: Bool = false
    @Published var mountedBuckets: [DaemonMountInfo] = []
    @Published var lastError: String?
    
    private var statusTimer: Timer?
    
    init() {
        checkMacFUSE()
        startStatusPolling()
    }
    
    deinit {
        statusTimer?.invalidate()
    }
    
    func checkMacFUSE() {
        isCheckingMacFUSE = true
        macFUSEInstalled = MacFUSEDetector.isInstalled()
        isCheckingMacFUSE = false
    }
    
    /// Start polling daemon for status updates
    func startStatusPolling() {
        // Poll every 2 seconds
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateDaemonStatus()
            }
        }
        // Also check immediately
        Task {
            await updateDaemonStatus()
        }
    }
    
    /// Update daemon status and mount information
    func updateDaemonStatus() async {
        do {
            let (healthy, mounts) = try await DaemonClient.shared.getStatus()
            isDaemonRunning = healthy
            mountedBuckets = mounts
            
            // Update bucket configs with mount status
            for i in bucketConfigs.indices {
                bucketConfigs[i].isMounted = mounts.contains { $0.bucketName == bucketConfigs[i].name }
            }
            
            lastError = nil
        } catch {
            isDaemonRunning = false
            mountedBuckets = []
            // Don't set lastError for connection failures (daemon just not running)
            if case DaemonError.daemonNotRunning = error {
                // Expected when daemon isn't running
            } else {
                lastError = error.localizedDescription
            }
        }
    }
    
    /// Mount a bucket
    func mountBucket(_ bucket: BucketConfig) async {
        guard macFUSEInstalled else {
            lastError = "macFUSE is not installed"
            return
        }
        
        guard isDaemonRunning else {
            lastError = "Daemon is not running"
            return
        }
        
        // Get credentials from keychain
        guard let credentials = try? CredentialStore.shared.get(bucket: bucket.name) else {
            lastError = "No credentials found for bucket '\(bucket.name)'"
            return
        }
        
        do {
            try await DaemonClient.shared.mount(
                bucketName: bucket.name,
                mountpoint: bucket.mountpoint,
                keyId: credentials.keyId,
                key: credentials.applicationKey
            )
            await updateDaemonStatus()
        } catch {
            lastError = "Mount failed: \(error.localizedDescription)"
        }
    }
    
    /// Unmount a bucket
    func unmountBucket(_ bucket: BucketConfig) async {
        guard let mounted = mountedBuckets.first(where: { $0.bucketName == bucket.name }) else {
            lastError = "Bucket is not mounted"
            return
        }
        
        do {
            try await DaemonClient.shared.unmount(bucketId: mounted.bucketId)
            await updateDaemonStatus()
        } catch {
            lastError = "Unmount failed: \(error.localizedDescription)"
        }
    }
    
    /// Add a new bucket configuration
    func addBucket(name: String, mountpoint: String) {
        let config = BucketConfig(name: name, mountpoint: mountpoint)
        if !bucketConfigs.contains(where: { $0.name == name }) {
            bucketConfigs.append(config)
            storedBuckets.append(name)
        }
    }
    
    /// Remove a bucket configuration
    func removeBucket(_ bucket: BucketConfig) {
        bucketConfigs.removeAll { $0.id == bucket.id }
        storedBuckets.removeAll { $0 == bucket.name }
    }
}
