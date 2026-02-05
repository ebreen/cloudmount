import SwiftUI

/// Bucket configuration with mount status
struct BucketConfig: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    var mountpoint: String
    var isMounted: Bool = false
    /// Disk usage in bytes (not persisted)
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
    @Published var storedBuckets: [String] = []
    @Published var bucketConfigs: [BucketConfig] = []
    @Published var lastError: String?
    
    init() {
        bucketConfigs = BucketConfigStore.load()
    }
    
    // MARK: - Bucket Management (stubs — rewired in Plan 05)
    
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
