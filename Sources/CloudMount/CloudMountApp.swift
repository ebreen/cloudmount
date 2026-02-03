import SwiftUI

@main
struct CloudMountApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
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

/// Bucket configuration with mount status
struct BucketConfig: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    var mountpoint: String
    var isMounted: Bool = false
    /// Disk usage in bytes, populated from daemon status (not persisted)
    var totalBytesUsed: Int64?
    
    enum CodingKeys: String, CodingKey {
        case id, name, mountpoint
        // isMounted and totalBytesUsed are runtime state — not persisted
    }
    
    static func == (lhs: BucketConfig, rhs: BucketConfig) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.mountpoint == rhs.mountpoint && lhs.isMounted == rhs.isMounted
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(mountpoint)
        hasher.combine(isMounted)
        // Exclude totalBytesUsed from hash — it's transient runtime data
    }
    
    init(name: String, mountpoint: String = "") {
        self.id = name
        self.name = name
        self.mountpoint = mountpoint.isEmpty ? "/Volumes/\(name)" : mountpoint
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mountpoint = try container.decode(String.self, forKey: .mountpoint)
        isMounted = false
        totalBytesUsed = nil
    }
}

/// Persistence store for bucket configurations
struct BucketConfigStore {
    /// File URL for persisted bucket configs
    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CloudMount")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("buckets.json")
    }
    
    /// Save bucket configs to disk
    static func save(_ configs: [BucketConfig]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(configs).write(to: fileURL)
    }
    
    /// Load bucket configs from disk
    static func load() -> [BucketConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([BucketConfig].self, from: data)) ?? []
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
    @Published var connectionHealth: String = "healthy"
    @Published var recentErrors: [DaemonErrorInfo] = []
    
    private var statusTimer: Timer?
    
    init() {
        bucketConfigs = BucketConfigStore.load()
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
            let (healthy, mounts, health, errors) = try await DaemonClient.shared.getStatus()
            isDaemonRunning = healthy
            mountedBuckets = mounts
            connectionHealth = health
            recentErrors = errors
            
            // Update bucket configs with mount status and usage data
            for i in bucketConfigs.indices {
                if let mount = mounts.first(where: { $0.bucketName == bucketConfigs[i].name }) {
                    bucketConfigs[i].isMounted = true
                    // totalBytesUsed populated from daemon when available
                    bucketConfigs[i].totalBytesUsed = mount.totalBytesUsed
                } else {
                    bucketConfigs[i].isMounted = false
                    bucketConfigs[i].totalBytesUsed = nil
                }
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
            BucketConfigStore.save(bucketConfigs)
        }
    }
    
    /// Remove a bucket configuration
    func removeBucket(_ bucket: BucketConfig) {
        bucketConfigs.removeAll { $0.id == bucket.id }
        storedBuckets.removeAll { $0 == bucket.name }
        BucketConfigStore.save(bucketConfigs)
    }
    
    /// Clear all bucket configurations (used by disconnect flow)
    func clearAllBuckets() {
        bucketConfigs = []
        storedBuckets = []
        BucketConfigStore.save([])
    }
}
