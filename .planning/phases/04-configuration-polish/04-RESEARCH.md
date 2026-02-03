# Phase 4: Configuration & Polish - Research

**Researched:** 2026-02-03
**Domain:** SwiftUI config persistence, B2 disk usage, IPC protocol extension
**Confidence:** HIGH

## Summary

Phase 4 is primarily about connecting existing pieces and adding one new feature: disk usage display. The codebase is mature — CredentialsPane, BucketsPane, GeneralPane, MenuContentView, CredentialStore, and DaemonClient all exist and work. The three gaps are:

1. **Disk usage display (UI-03)** — No mechanism to get bucket size. B2 has no "get bucket size" API. The daemon must sum `contentLength` from files it already lists. This requires an IPC protocol extension and a new daemon command.
2. **Bucket config persistence** — `BucketConfig` array is in-memory only (AppState). On restart, bucket names/mount points are lost (credentials survive in Keychain). Needs simple JSON file or UserDefaults persistence.
3. **Settings polish** — Minor: mount point validation, ensuring the settings window is complete.

**Primary recommendation:** Add a `GetUsage` IPC command that triggers the daemon to sum file sizes from its metadata cache (or a shallow B2 listing), and persist bucket configs to a JSON file in Application Support.

## Standard Stack

### Core (Already in Use)
| Library | Purpose | Status |
|---------|---------|--------|
| SwiftUI (macOS 14+) | Menu bar app UI | Already integrated |
| KeychainAccess | Credential storage | Already integrated |
| fuser (Rust) | FUSE filesystem | Already integrated |
| serde/serde_json (Rust) | IPC protocol | Already integrated |
| moka (Rust) | Metadata cache | Already integrated |

### New for Phase 4
| Component | Purpose | Why |
|-----------|---------|-----|
| `FileManager` + `JSONEncoder` | Persist bucket configs | Simple, no new dependencies needed |
| `ByteCountFormatter` | Format disk usage (e.g., "2.4 GB") | Built into Foundation, zero effort |

### No New Dependencies Needed
This phase adds no new Swift or Rust dependencies. Everything needed is already in Foundation/SwiftUI or the existing Rust crate dependencies.

## Architecture Patterns

### Pattern 1: Disk Usage via Daemon IPC

**What:** Add a `GetUsage` command to the IPC protocol. The daemon sums `contentLength` from B2 file listings (which it already performs for FUSE `readdir`) and returns total bytes per mounted bucket.

**Why this approach (not alternatives):**
- B2 has NO "get bucket size" API endpoint (verified via official API docs)
- `b2_list_file_names` returns `contentLength` per file — summing is straightforward
- The daemon already calls `list_file_names` for directory browsing — data is partially cached
- Avoid full bucket scan on every poll — use cached metadata when available, lazy update

**Implementation approach:**
1. Add `total_bytes_used: Option<u64>` to `MountInfo` in the IPC protocol (Rust side)
2. When the daemon processes `GetStatus`, compute usage from the metadata cache or trigger a background scan
3. Swift side: add `totalBytesUsed` to `DaemonMountInfo`, display in `MenuContentView`

**Important: Two-tier approach for usage calculation:**
- **Fast path**: Sum sizes from already-cached metadata (inodes with known sizes). Returns instantly but may be incomplete.
- **Full path**: Background task does a full `b2_list_file_names` with no delimiter (flat listing, sums all `contentLength`). Cache the result. Only run periodically (e.g., every 5 minutes) or on explicit refresh.

```rust
// Add to MountInfo in protocol.rs
pub struct MountInfo {
    pub bucket_id: String,
    pub bucket_name: String,
    pub mountpoint: String,
    pub pending_uploads: u32,
    pub last_error: Option<String>,
    pub total_bytes_used: Option<u64>,  // NEW: None = not yet calculated
}
```

```swift
// Add to DaemonMountInfo in DaemonClient.swift
struct DaemonMountInfo: Codable {
    let bucketId: String
    let bucketName: String
    let mountpoint: String
    let pendingUploads: Int?
    let lastError: String?
    let totalBytesUsed: Int64?  // NEW
}
```

### Pattern 2: Bucket Config Persistence

**What:** Persist `[BucketConfig]` to a JSON file in Application Support directory.

**Why JSON file (not UserDefaults/AppStorage):**
- `@AppStorage` only supports primitive types (String, Int, Bool, Data, URL). Cannot store `[BucketConfig]` directly.
- UserDefaults CAN store Data (encoded JSON), but Application Support JSON file is more idiomatic for structured app data on macOS.
- JSON file is human-readable and debuggable.
- Follow the pattern from Apple's own SwiftUI documentation for persisting Codable arrays.

**Implementation:**

```swift
// Make BucketConfig Codable
struct BucketConfig: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    var mountpoint: String
    var isMounted: Bool = false  // transient, not persisted
    
    enum CodingKeys: String, CodingKey {
        case id, name, mountpoint
        // isMounted is NOT encoded — it's runtime state
    }
}

// Persistence helper
struct BucketConfigStore {
    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CloudMount")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("buckets.json")
    }
    
    static func save(_ configs: [BucketConfig]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(configs) else { return }
        try? data.write(to: fileURL)
    }
    
    static func load() -> [BucketConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([BucketConfig].self, from: data)) ?? []
    }
}
```

**Integration with AppState:**
- Load on `AppState.init()`
- Save on every `addBucket()` / `removeBucket()` call
- Use `didSet` on `bucketConfigs` to auto-save

### Pattern 3: Formatted Disk Usage Display

**What:** Use `ByteCountFormatter` to display human-readable sizes in the menu bar.

```swift
// In MenuContentView bucket row
if let bytes = bucket.totalBytesUsed {
    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

**UI placement:** Add disk usage as a secondary label under each bucket name in the menu, right next to the mountpoint path. Show "Calculating..." when `totalBytesUsed` is nil.

### Anti-Patterns to Avoid
- **Don't scan bucket on every status poll**: Full `b2_list_file_names` with no delimiter lists ALL files. For large buckets this is thousands of API calls. Cache the result and update lazily.
- **Don't use `@AppStorage` for complex types**: It only supports primitives. Encoding to Data and storing in UserDefaults works but is messy. Use a JSON file.
- **Don't block the UI for usage calculation**: Usage should be fetched async and displayed when available. Show placeholder while loading.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Byte formatting | String formatting for "2.4 GB" | `ByteCountFormatter` | Handles KB/MB/GB/TB, localization, edge cases |
| JSON file persistence | Custom file I/O | `JSONEncoder`/`JSONDecoder` + `Codable` | Standard Swift pattern, type-safe |
| Application Support path | Hardcoded paths | `FileManager.default.urls(for: .applicationSupportDirectory)` | Correct on all macOS versions |

## Common Pitfalls

### Pitfall 1: Expensive B2 Usage Calculation
**What goes wrong:** Calling `b2_list_file_names` with no prefix/delimiter lists every file in the bucket. For buckets with thousands of files, this means multiple paginated API calls (1000 files per call), each a billable Class C transaction.
**Why it happens:** B2 charges per 1000 files returned. A bucket with 50,000 files = 50 API calls just to calculate size.
**How to avoid:** Cache the usage result. Recalculate at most every 5 minutes. Use a dedicated background task in the daemon. Return `None` while calculating.
**Warning signs:** High B2 API bill, slow status responses.

### Pitfall 2: isMounted State in Persisted Config
**What goes wrong:** If `isMounted` is persisted to JSON, the app could load stale "mounted" state on restart when buckets aren't actually mounted.
**Why it happens:** Mount status is runtime state from the daemon, not persistent config.
**How to avoid:** Exclude `isMounted` from `Codable` encoding using `CodingKeys`. Always derive mount status from daemon status polling (which already happens every 2 seconds).

### Pitfall 3: Application Support Directory Creation
**What goes wrong:** Writing to `~/Library/Application Support/CloudMount/` fails if the directory doesn't exist.
**Why it happens:** The subdirectory doesn't exist on first launch.
**How to avoid:** Always `createDirectory(withIntermediateDirectories: true)` before writing.

### Pitfall 4: Race Condition on Config Save
**What goes wrong:** Multiple rapid bucket add/remove operations could race on file writes.
**Why it happens:** `didSet` triggers save on every mutation.
**How to avoid:** `AppState` is `@MainActor` isolated, so mutations are serialized. No race condition in practice. Save is synchronous and fast (tiny JSON file).

### Pitfall 5: Daemon IPC Protocol Version Compatibility
**What goes wrong:** Adding `totalBytesUsed` to `MountInfo` breaks old Swift clients that don't expect it.
**Why it happens:** JSON deserialization fails on unknown fields.
**How to avoid:** The field is `Option<u64>` with `#[serde(default)]` — it deserializes as `null`/`nil` when missing. Swift side uses optional (`Int64?`). No breaking change.

## Code Examples

### Disk Usage in Menu (SwiftUI)
```swift
// In bucketsSection of MenuContentView
ForEach(appState.bucketConfigs) { bucket in
    HStack {
        Image(systemName: bucket.isMounted ? "externaldrive.fill" : "folder.fill")
            .foregroundStyle(bucket.isMounted ? .green : .blue)
        VStack(alignment: .leading, spacing: 1) {
            Text(bucket.name)
                .font(.subheadline)
            if bucket.isMounted {
                HStack(spacing: 4) {
                    Text(bucket.mountpoint)
                    if let bytes = bucket.totalBytesUsed {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        Spacer()
        // mount/unmount button...
    }
}
```

### Daemon Usage Calculation (Rust)
```rust
// In the daemon — calculate total usage for a mounted bucket
async fn calculate_bucket_usage(b2_client: &B2Client) -> Result<u64> {
    let mut total_bytes: u64 = 0;
    let files = b2_client.list_file_names(None, None).await?;
    for file in &files {
        if file.action == "upload" {
            total_bytes += file.content_length;
        }
    }
    Ok(total_bytes)
}
```

### BucketConfig Persistence
```swift
// In AppState init
init() {
    // Load persisted bucket configs
    bucketConfigs = BucketConfigStore.load()
    checkMacFUSE()
    startStatusPolling()
}

// Auto-save on changes (add to addBucket/removeBucket)
func addBucket(name: String, mountpoint: String) {
    let config = BucketConfig(name: name, mountpoint: mountpoint)
    if !bucketConfigs.contains(where: { $0.name == name }) {
        bucketConfigs.append(config)
        storedBuckets.append(name)
        BucketConfigStore.save(bucketConfigs)
    }
}
```

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| `@AppStorage` for complex data | JSON file in Application Support | `@AppStorage` is primitives-only; JSON file is standard for structured data |
| Polling for all data | Polling status + lazy usage calculation | Prevents expensive API calls every 2 seconds |

## Open Questions

1. **Usage calculation frequency**
   - What we know: Full bucket listing is expensive (billable API calls, potentially slow for large buckets)
   - What's unclear: Optimal refresh interval. 5 minutes seems reasonable but may need user testing.
   - Recommendation: Start with 5-minute interval, add manual refresh button. Show last-updated timestamp.

2. **Mount point validation**
   - What we know: Mount points must be in `/Volumes/` for macFUSE
   - What's unclear: Should we validate the path exists? macFUSE creates it automatically.
   - Recommendation: Validate format (starts with `/Volumes/`), let macFUSE handle creation. Show error if mount fails.

3. **BucketConfig.totalBytesUsed storage**
   - What we know: This is runtime data from the daemon, not persistent config
   - Recommendation: Store as a separate dictionary `[String: Int64]` in AppState, populated from daemon status. Don't persist it.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: All Swift files (CloudMountApp.swift, SettingsView.swift, MenuContentView.swift, DaemonClient.swift, CredentialStore.swift)
- Codebase analysis: Rust daemon (protocol.rs, server.rs, client.rs, b2fs.rs, metadata.rs, types.rs, manager.rs)
- B2 API docs (https://www.backblaze.com/apidocs/b2-list-file-names) — confirms `contentLength` per file, no bucket-size API
- Context7 SwiftUI docs — AppStorage limitations, Codable persistence patterns

### Secondary (MEDIUM confidence)
- B2 API introduction (https://www.backblaze.com/apidocs/introduction-to-the-b2-native-api) — current API version is v4

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries already in use, no new deps
- Architecture: HIGH — patterns verified against codebase and B2 API docs
- Pitfalls: HIGH — derived from direct codebase analysis and B2 billing docs
- Disk usage approach: HIGH — confirmed B2 has no bucket-size API; list-and-sum is the only option

**Research date:** 2026-02-03
**Valid until:** 2026-03-03 (stable — no fast-moving dependencies)
