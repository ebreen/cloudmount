# Architecture Patterns: FSKit Migration

**Domain:** macOS filesystem extension (FSKit) + cloud storage client
**Researched:** 2026-02-05
**Overall confidence:** MEDIUM — FSKit is new (macOS 15.4+), documentation is sparse, no official Apple sample code exists. Findings are synthesized from Apple Developer Forums (Apple DTS engineers), KhaosT/FSKitSample (community), and Apple open-source msdos FS reimplementation. FSKit API is still evolving and has known limitations.

## Critical Context: FSKit's Current State

**FSKit only supports `FSUnaryFileSystem` today.** Per Apple DTS Engineer (Quinn "The Eskimo!") in the Apple Developer Forums (March 2025):

> "[FSUnaryFileSystem] works with one FSResource and presents it as one FSVolume. This is intended to support traditional file systems, that is, ones that present a volume that's mounted on a disk (or a partition of a disk). Think FAT, HFS, and so on."

**Network file systems are NOT natively supported by FSKit.** When asked about network FS support, the same Apple DTS engineer stated:

> "Network file systems don't mount on /dev nodes and thus aren't supported by FSKit... I can assure you that the FSKit team is well aware of the demand for this particular feature."

**CloudMount is a cloud/network filesystem.** This means we CANNOT use the standard FSKit block-device-backed workflow. However, there IS a workaround: FSKit supports `FSPathURLResource` and `FSGenericURLResource` resource types, which allow mounting filesystems backed by URLs or paths rather than block devices. The mount command with `-F` flag works with these resource types. A community developer successfully shipped a virtual FS using `FSPathURLResource` (mcrawfs project).

**Confidence: MEDIUM** — The path-URL resource approach works per forum reports, but it's less documented than block device support and has known sandbox/mount API issues.

---

## Recommended Architecture

### Overview: From Dual-Process to App + Extension

```
CURRENT (v1.0):
┌──────────────────┐     Unix Socket      ┌──────────────────────────┐
│  Swift UI App    │ ──── JSON IPC ─────► │  Rust FUSE Daemon        │
│  (menu bar)      │                       │  ├─ B2 API Client       │
│  ├─ AppState     │                       │  ├─ FUSE fs (fuser)     │
│  ├─ DaemonClient │                       │  ├─ Metadata Cache      │
│  └─ CredStore    │                       │  └─ Mount Manager       │
└──────────────────┘                       └──────────────────────────┘

NEW (v2.0):
┌──────────────────┐       ExtensionKit       ┌──────────────────────────┐
│  Swift UI App    │ ──── (automatic IPC) ──► │  FSKit Extension (.appex)│
│  (menu bar)      │                           │  ├─ FSUnaryFileSystem    │
│  ├─ AppState     │  ◄─── NSXPCConnection ── │  ├─ FSVolume subclass    │
│  ├─ MountClient  │       (custom comms)      │  ├─ B2Client (Swift)    │
│  ├─ CredStore    │                           │  ├─ Metadata Cache      │
│  └─ UI Views     │                           │  └─ FSItem tree         │
└──────────────────┘                           └──────────────────────────┘
```

### Key Architecture Decision: App Extension, Not System Extension

FSKit modules are **App Extensions** (`.appex`) using modern ExtensionFoundation/ExtensionKit technology, NOT System Extensions. This is confirmed by Apple DTS:

> "Your module's main entry point must be in Swift [due to the fact that FSKit is based on modern appex technology, that is, ExtensionFoundation / ExtensionKit]."

**Implications:**
- The FSKit module is an **Xcode target** embedded within the main `.app` bundle
- It runs as a **separate process** managed by the system (not your app)
- The system launches it on demand when mounting is requested
- Users must enable it in **System Settings → General → Login Items & Extensions → File System Extensions**
- It is sandboxed by default

**Confidence: HIGH** — Directly confirmed by Apple DTS engineer and FSKitSample project structure.

---

## Component Architecture

### Component 1: Main App (existing, modified)

**Responsibility:** UI, credential management, mount orchestration
**What changes:** DaemonClient becomes MountClient, MacFUSEDetector removed, mount/unmount logic changes

| File | Status | Change |
|------|--------|--------|
| `CloudMountApp.swift` | **Modified** | Remove MacFUSEDetector refs, update AppState |
| `AppState` (in CloudMountApp.swift) | **Modified** | Replace daemon polling with mount status checks, remove `macFUSEInstalled`, `isDaemonRunning` |
| `DaemonClient.swift` | **Replaced** | New `MountClient.swift` — invokes `/sbin/mount -F` to mount, `umount` to unmount |
| `CredentialStore.swift` | **Kept as-is** | Keychain storage works unchanged; extension reads via App Group |
| `MacFUSEDetector.swift` | **Deleted** | No longer needed |
| `MenuContentView.swift` | **Modified** | Remove macFUSE warning section, update status indicators |
| `SettingsView.swift` | **Modified** | Remove daemon-related error messaging, B2 bucket listing moves to Swift |
| `Package.swift` | **Replaced** | Must migrate to Xcode project (see Build System section) |

### Component 2: FSKit Extension (NEW — `.appex` target)

**Responsibility:** Filesystem operations, B2 API communication, caching
**Entry point:** Swift `@main` struct conforming to `UnaryFilesystemExtension`

| File | Status | Purpose |
|------|--------|---------|
| `CloudMountFSExtension.swift` | **New** | `@main` entry point, `UnaryFilesystemExtension` conformance |
| `CloudMountFS.swift` | **New** | `FSUnaryFileSystem` subclass, `FSUnaryFileSystemOperations` — probe, load, unload |
| `CloudMountVolume.swift` | **New** | `FSVolume` subclass, `FSVolume.Operations` — activate, deactivate, mount, unmount, directory enumeration, file operations |
| `CloudMountItem.swift` | **New** | `FSItem` subclass — represents files/directories, holds B2 metadata |
| `B2Client.swift` | **New** | B2 API client (URLSession + async/await), ported from Rust |
| `B2Types.swift` | **New** | B2 API response/request types |
| `MetadataCache.swift` | **New** | In-memory metadata cache (replaces Rust moka) |
| `FileDataCache.swift` | **New** | Read cache + write staging (replaces Rust local file cache) |
| `Info.plist` | **New** | FSKit extension configuration (FSName, FSShortName, resource types) |
| `Entitlements` | **New** | Sandbox entitlements, App Group for Keychain sharing |

### Component 3: Shared Code (NEW — shared Swift package/framework)

**Responsibility:** Types and utilities shared between app and extension

| File | Status | Purpose |
|------|--------|---------|
| `BucketConfig.swift` | **Extracted** | Bucket configuration model (from CloudMountApp.swift) |
| `CredentialStore.swift` | **Shared** | Keychain access (needs App Group for cross-process access) |
| `SharedTypes.swift` | **New** | Mount status types, error types |

---

## Data Flow: How Does UI Talk to Filesystem?

### Current Flow (v1.0)
```
User clicks "Mount" → AppState.mountBucket() → DaemonClient.mount()
  → Unix socket write → Rust daemon reads JSON
  → Daemon calls FUSE mount → macFUSE kernel module mounts volume
  → Daemon sends JSON response → DaemonClient reads response → UI updates
```

### New Flow (v2.0)

**Mount flow:**
```
User clicks "Mount" → AppState.mountBucket() → MountClient.mount()
  → Process.run("/sbin/mount", ["-F", "-t", "CloudMountFS", resource, mountpoint])
  → System launches FSKit extension (.appex) process
  → Extension's probeResource() called → returns .usable
  → Extension's loadResource() called → returns CloudMountVolume instance
  → Volume.activate() called → B2Client authenticates, returns root FSItem
  → macOS mounts volume at mountpoint → Finder sees volume
  → MountClient detects mount success (via mount exit code or DiskArbitration callback)
  → UI updates
```

**File read flow:**
```
Finder opens file → VFS → FSKit kernel bridge
  → CloudMountVolume.lookupItem(named:inDirectory:) — find FSItem
  → CloudMountVolume.read(from:at:length:into:) called
  → Check FileDataCache → cache miss → B2Client.downloadFile()
  → URLSession async download → write to FSMutableFileDataBuffer
  → Return bytes to VFS → Finder displays file
```

**Status polling replacement:**
```
CURRENT: Timer polls daemon every 2s via Unix socket
NEW: Use DiskArbitration framework to observe mount/unmount events
  — OR — check mount table (/sbin/mount output) periodically
  — OR — use FSKit's containerStatus property
```

### IPC Between App and Extension

The Unix socket IPC is **completely eliminated**. FSKit extensions are managed by the system — the app doesn't directly communicate with the extension process.

**What replaces it:**

| Communication Need | v1.0 Solution | v2.0 Solution |
|-------------------|---------------|---------------|
| Mount request | Unix socket JSON "mount" command | `/sbin/mount -F` command |
| Unmount request | Unix socket JSON "unmount" command | `umount` command or `DiskArbitration` |
| Mount status | Unix socket JSON "getStatus" poll | DiskArbitration callbacks or mount table |
| Credentials | Sent in mount JSON command | Shared Keychain via App Group |
| B2 bucket listing | Unix socket JSON "listBuckets" command | Direct B2Client in main app (new) |
| Error reporting | Daemon returns errors in JSON | os_log from extension + app-side error detection |

**Critical change:** The main app needs its OWN B2 API client for operations like listing buckets during credential setup. The extension has its own B2 client for filesystem operations. They share credentials via Keychain App Group.

**Confidence: MEDIUM** — Mount via `/sbin/mount` is confirmed by Apple DTS as the standard approach. App-to-extension communication via shared Keychain is standard App Group pattern. The exact mechanism for passing credentials to the extension at mount time needs further investigation (possibly via mount options or FSTaskOptions).

---

## Build System: Xcode Project Required

### SPM Cannot Build FSKit Extensions

**The current `Package.swift` must be replaced with an Xcode project.** FSKit extensions require:

1. **App Extension target** — SPM doesn't support `.appex` extension targets
2. **Info.plist configuration** — FSKit requires specific plist keys (`FSName`, `FSShortName`, `FSSupportsBlockResources`, `FSActivateOptionSyntax`)
3. **Entitlements** — Sandbox entitlements, App Group, FSKit Module capability
4. **Embedding** — The `.appex` must be embedded in the `.app` bundle's `Contents/Extensions/` directory
5. **Code signing** — Both app and extension need signing

**Confidence: HIGH** — The Xcode File System Extension template (added in Xcode 16.3) generates the proper project structure. Both FSKitSample and the Apple msdos implementation use Xcode projects. Apple DTS explicitly directs developers to use this template.

### Recommended Project Structure

```
CloudMount.xcodeproj
├── CloudMount/                        (Main app target)
│   ├── CloudMountApp.swift
│   ├── AppState.swift
│   ├── MountClient.swift              (replaces DaemonClient)
│   ├── B2Client.swift                 (app-side, for bucket listing)
│   ├── CredentialStore.swift
│   ├── MenuContentView.swift
│   ├── SettingsView.swift
│   ├── Info.plist
│   └── CloudMount.entitlements
│
├── CloudMountFS/                      (FSKit extension target - .appex)
│   ├── CloudMountFSExtension.swift    (@main entry, UnaryFilesystemExtension)
│   ├── CloudMountFS.swift             (FSUnaryFileSystem subclass)
│   ├── CloudMountVolume.swift         (FSVolume subclass + Operations)
│   ├── CloudMountItem.swift           (FSItem subclass)
│   ├── B2Client.swift                 (extension-side, for file I/O)
│   ├── B2Types.swift
│   ├── MetadataCache.swift
│   ├── FileDataCache.swift
│   ├── Info.plist                     (FSKit keys)
│   └── CloudMountFS.entitlements
│
├── Shared/                            (Shared framework or files)
│   ├── BucketConfig.swift
│   ├── CredentialStore.swift          (shared Keychain access)
│   └── SharedTypes.swift
│
└── Tests/
    ├── B2ClientTests/
    └── CacheTests/
```

### Info.plist for FSKit Extension

Based on the Xcode 16.3 template and FSKitSample:

```xml
<key>FSName</key>
<string>CloudMountFS</string>
<key>FSShortName</key>
<string>CloudMountFS</string>
<key>FSSupportsBlockResources</key>
<false/>                          <!-- We're NOT block-device based -->
<key>FSActivateOptionSyntax</key>
<dict>
    <key>shortOptions</key>
    <string>b:k:m:</string>       <!-- bucket, keyId, mountpoint options -->
    <key>pathOptions</key>
    <dict/>
</dict>
<key>EXExtensionPointIdentifier</key>
<string>com.apple.fskit.module</string>
```

**Confidence: MEDIUM** — FSSupportsBlockResources=false is correct for our use case but less tested. The option syntax for passing credentials needs experimentation.

---

## Extension Architecture Detail

### Entry Point Pattern

```swift
import FSKit

@main
struct CloudMountFSExtension: UnaryFilesystemExtension {
    // System instantiates this. Must return your FSUnaryFileSystem subclass.
    func createFileSystem() -> FSUnaryFileSystem {
        return CloudMountFS()
    }
}
```

### FSUnaryFileSystem Subclass

```swift
final class CloudMountFS: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, Error?) -> Void) {
        // Called by system to check if we can mount this resource
        // For CloudMount: always return .usable since we're a virtual FS
        replyHandler(.usable(name: "B2Bucket", containerID: FSContainerIdentifier(uuid: ...)), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, Error?) -> Void) {
        // Extract B2 credentials from mount options or shared Keychain
        // Create and return volume
        let volume = CloudMountVolume(bucketName: ..., credentials: ...)
        replyHandler(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) {
        replyHandler(nil)
    }
}
```

### FSVolume Subclass (Core Operations)

The volume must conform to these protocols:

| Protocol | Purpose | Priority |
|----------|---------|----------|
| `FSVolume.Operations` | Core: activate, deactivate, lookup, enumerate, create, remove, rename | **Required** |
| `FSVolume.ReadWriteOperations` | File read/write | **Required** |
| `FSVolume.OpenCloseOperations` | File open/close lifecycle | **Required** |
| `FSVolume.PathConfOperations` | Path configuration (max name length, etc.) | Required |
| `FSVolume.XattrOperations` | Extended attributes | Nice-to-have |
| `FSVolume.RenameOperations` | Rename operations | Nice-to-have |

**Key operations to implement (mapped from Rust FUSE):**

| Rust FUSE (fuser trait) | FSKit Volume Protocol | Notes |
|------------------------|----------------------|-------|
| `lookup` | `lookupItem(named:inDirectory:)` | Returns `(FSItem, FSFileName)` |
| `readdir` | `enumerateDirectory(...)` | Uses `FSDirectoryEntryPacker` |
| `read` | `read(from:at:length:into:)` | Writes to `FSMutableFileDataBuffer` |
| `write` | `write(contents:to:at:)` | Returns bytes written |
| `create` | `createItem(named:type:inDirectory:attributes:)` | Returns `(FSItem, FSFileName)` |
| `mkdir` | Same as create with `.directory` type | — |
| `unlink`/`rmdir` | `removeItem(_:named:fromDirectory:)` | — |
| `rename` | `renameItem(...)` | — |
| `getattr` | `attributes(_:of:)` | Returns `FSItem.Attributes` |
| `setattr` | `setAttributes(_:on:)` | Returns updated attributes |
| `open` | `openItem(_:modes:)` | — |
| `release` | `closeItem(_:modes:)` | — |
| `forget` | `reclaimItem(_:)` | FSKit equivalent of FUSE forget |
| `statfs` | `volumeStatistics` property | Returns `FSStatFSResult` |

**Confidence: HIGH** — FSVolume protocol conformance is well-documented in FSKitSample and Apple headers.

---

## Credential Sharing Strategy

### Problem
The main app stores B2 credentials in Keychain. The FSKit extension (separate process) needs those credentials to authenticate with B2.

### Solution: App Group + Keychain Sharing

1. Both app and extension join the same App Group (e.g., `group.com.cloudmount`)
2. CredentialStore uses `kSecAttrAccessGroup` to store in the shared Keychain group
3. Extension reads credentials from shared Keychain at mount time

**Impact on CredentialStore.swift:**
```swift
// Current (single-app)
private let keychain = Keychain(service: "com.cloudmount.credentials")
    .accessibility(.whenUnlocked)

// New (shared via App Group)
private let keychain = Keychain(service: "com.cloudmount.credentials")
    .accessibility(.whenUnlocked)
    .accessGroup("group.com.cloudmount")  // <-- shared access group
```

**Alternative:** Pass credentials via mount command options. The `FSTaskOptions` can carry key-value pairs, but this is less secure (credentials visible in process listing). Shared Keychain is the recommended approach.

**Confidence: MEDIUM** — App Group Keychain sharing is a well-established iOS/macOS pattern, but KeychainAccess library support with App Groups needs verification. May need to switch to raw Security framework calls.

---

## Known Limitations and Workarounds

### 1. No Native Network FS Support

**Problem:** FSKit's `FSUnaryFileSystem` is designed for block-device-backed filesystems.
**Workaround:** Use `FSGenericURLResource` or `FSPathURLResource` as the resource type. Mount with `mount -F -t CloudMountFS <resource-specifier> <mountpoint>`. The resource specifier can be a dummy value since our FS is entirely virtual (backed by B2 API, not local storage).

**Confidence: MEDIUM** — Community projects have made this work but it's not the primary FSKit use case.

### 2. Volumes Don't Auto-Appear in Finder Sidebar

**Problem:** FSKit-mounted volumes at custom mount points (not `/Volumes/`) don't appear in Finder's sidebar.
**Workaround:** Mount to `/tmp/` or another writable location, OR use DiskArbitration to properly announce the volume. This is a known pain point per Apple Developer Forums.

**Note:** `/Volumes/` is protected on modern macOS. You may need to create the mount point directory in `/tmp/` or use another writable path.

**Confidence: LOW** — This is an active area of FSKit development. Finder integration may improve in future macOS versions.

### 3. Performance Overhead

**Problem:** FSKit's `FSVolumeReadWriteOperations` path has higher overhead than FUSE. One developer reported 100-150% CPU vs 40% with macFUSE for the same operations. Apple DTS acknowledged: "We haven't done much to optimize the FSVolumeReadWriteOperations path."

**Workaround:** Aggressive caching, batch prefetching, minimize round-trips to B2 API.

**Confidence: HIGH** — Directly stated by Apple DTS engineer (Sep 2025).

### 4. No Kernel-Level Caching

**Problem:** FSKit lacks FUSE's entry_timeout, attr_timeout, and readdir caching. Every operation goes through userspace. A developer measured 121μs average per getdirentries syscall even with hardcoded data.

**Workaround:** Implement aggressive application-level caching in the extension. Cache directory listings, file metadata, and file contents with configurable TTLs.

**Confidence: HIGH** — Confirmed by developer benchmarks and Apple acknowledgment that kernel caching is not yet available.

### 5. Read-Only Mode Not Fully Supported

**Problem:** Even with FSKit, marking a volume as read-only doesn't fully propagate to Finder — users may see options to trash items even though operations fail.

**Workaround:** Not critical for CloudMount (we support read-write), but worth noting if read-only B2 buckets are supported later.

**Confidence: MEDIUM** — Reported by multiple developers.

### 6. Extension Must Be Manually Enabled

**Problem:** Users must go to System Settings → General → Login Items & Extensions → File System Extensions and enable the extension before first mount.

**Workaround:** Detect when extension is not enabled and guide user through the process in the UI. Consider first-run onboarding flow.

**Confidence: HIGH** — Confirmed by Apple DTS, demonstrated in FSKitSample.

### 7. Sandbox Restrictions

**Problem:** FSKit extensions are sandboxed. Accessing files outside the sandbox requires security-scoped bookmarks or mount options.

**Workaround:** Since CloudMount's extension only talks to B2 API (network access), sandbox restrictions on local file access are less of a concern. Network access needs `com.apple.security.network.client` entitlement.

**Confidence: MEDIUM** — Network-only extensions should be simpler than local-file-backed ones, but this needs testing.

---

## Migration Path: Suggested Build Order

### Phase 1: Build System Migration
1. Create Xcode project with File System Extension template
2. Move existing Swift sources into main app target
3. Verify existing UI builds and runs (without daemon)
4. Set up App Group for Keychain sharing

### Phase 2: FSKit Extension Skeleton
1. Create extension target using Xcode template
2. Implement `UnaryFilesystemExtension` entry point
3. Implement `FSUnaryFileSystem` with hardcoded probe/load
4. Implement `FSVolume` with in-memory filesystem (no B2)
5. Test: mount, list root directory, unmount

### Phase 3: B2 Client in Swift
1. Port B2 authorize/authenticate from Rust to Swift/URLSession
2. Port B2 file listing (b2_list_file_names)
3. Port B2 file download (b2_download_file_by_name)
4. Port B2 file upload (b2_upload_file)
5. Port B2 file delete (b2_delete_file_version)
6. Add B2 client to both app (for bucket listing) and extension (for file I/O)

### Phase 4: Wire B2 to FSKit
1. Connect `CloudMountVolume.lookupItem` → B2 listing
2. Connect `CloudMountVolume.enumerateDirectory` → B2 listing
3. Connect `CloudMountVolume.read` → B2 download
4. Add metadata cache (Swift actor, replaces Rust moka)
5. Add file data cache (local temp files, replaces Rust file cache)
6. Connect `CloudMountVolume.write` → B2 upload on close
7. Connect `CloudMountVolume.removeItem` → B2 delete

### Phase 5: App Integration
1. Replace `DaemonClient` with `MountClient` (invokes mount/umount)
2. Update `AppState` — remove daemon polling, add mount detection
3. Add B2Client to main app for bucket listing
4. Update UI — remove macFUSE references, update status indicators
5. Wire Keychain sharing via App Group
6. Add first-run extension enablement guidance

### Phase 6: Polish and Distribution
1. Code signing and notarization
2. DMG packaging
3. Homebrew Cask formula
4. GitHub Actions CI/CD

---

## Patterns to Follow

### Pattern 1: Actor-Based B2 Client
**What:** Use Swift actor for the B2 API client to ensure thread safety
**Why:** FSKit can call volume operations concurrently. The B2 client must handle concurrent requests safely.
```swift
actor B2Client {
    private var authToken: String?
    private var apiUrl: String?

    func authorize(keyId: String, applicationKey: String) async throws { ... }
    func listFileNames(bucketId: String, prefix: String?) async throws -> [B2File] { ... }
    func downloadFile(bucketName: String, fileName: String) async throws -> Data { ... }
}
```

### Pattern 2: FSItem Subclass with B2 Metadata
**What:** Custom FSItem subclass that holds B2-specific metadata
**Why:** FSKit manages FSItem lifecycle but you need to attach your domain data
```swift
final class CloudMountItem: FSItem {
    let b2FileId: String?
    let b2FileName: String
    var cachedAttributes: FSItem.Attributes
    var children: [FSFileName: CloudMountItem]  // for directories
}
```

### Pattern 3: Write-on-Close Semantics
**What:** Buffer writes in a local temp file, upload to B2 when file is closed
**Why:** B2 requires knowing file size upfront; partial writes aren't supported. This matches v1.0 behavior.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Direct Extension Communication
**What:** Trying to establish direct XPC/socket communication between app and extension
**Why bad:** FSKit extensions are system-managed processes. You don't control their lifecycle. Use shared state (Keychain, App Group UserDefaults) instead.

### Anti-Pattern 2: Blocking in FSVolume Operations
**What:** Making synchronous B2 API calls in volume operation callbacks
**Why bad:** FSKit operations are `async` — use Swift concurrency properly. Don't block threads.

### Anti-Pattern 3: Storing Extension State in Memory Only
**What:** Keeping all mount state only in the extension process
**Why bad:** The extension process can be killed at any time by the system. Persist important state via App Group.

### Anti-Pattern 4: Using SPM for the Build
**What:** Trying to keep Package.swift and avoid Xcode project
**Why bad:** FSKit extensions require Xcode project features (extension targets, Info.plist, entitlements, embedding). SPM doesn't support this.

---

## Scalability Considerations

| Concern | Small (10 files) | Medium (10K files) | Large (100K+ files) |
|---------|-------------------|---------------------|---------------------|
| Metadata cache | In-memory dict | In-memory with LRU eviction | TTL-based eviction, lazy loading |
| File data cache | All in memory | Temp file backed | Temp file with disk budget |
| Directory listing | Single B2 API call | Paginated (B2 returns max 10K per call) | Paginated with cursor caching |
| FSItem memory | Negligible | ~10MB (item objects) | Must implement lazy loading + reclaimItem |

---

## Sources

| Source | Type | Confidence |
|--------|------|------------|
| [Apple Developer Forums — FSKit tag (23 posts)](https://forums.developer.apple.com/forums/tags/fskit) | Apple DTS Engineer responses | HIGH |
| [KhaosT/FSKitSample](https://github.com/KhaosT/FSKitSample) | Community sample project (97 stars) | MEDIUM |
| [Apple DTS on FSUnaryFileSystem limitation](https://forums.developer.apple.com/forums/thread/776322) | DTS Engineer Quinn | HIGH |
| [Apple DTS on network FS not supported](https://forums.developer.apple.com/forums/thread/776322) | DTS Engineer Quinn | HIGH |
| [Apple DTS on mount via /sbin/mount](https://forums.developer.apple.com/forums/thread/799283) | DTS Engineer Kevin Elliott | HIGH |
| [Apple DTS on FSKit performance](https://forums.developer.apple.com/forums/thread/799283) | DTS Engineer Kevin Elliott | HIGH |
| [Apple DTS on FSKit read-only](https://forums.developer.apple.com/forums/thread/807771) | Forum thread | MEDIUM |
| [Apple DTS on FSItem reclaim](https://forums.developer.apple.com/forums/thread/799809) | DTS Engineer Kevin Elliott | HIGH |
| [FSKit sandbox discussion](https://forums.developer.apple.com/forums/thread/808246) | Forum thread | MEDIUM |
| [FSKit performance/caching](https://forums.developer.apple.com/forums/thread/793013) | Forum thread | MEDIUM |
| [EdenFS/Meta FSKit interest](https://forums.developer.apple.com/forums/thread/766793) | Forum thread (Meta engineers) | MEDIUM |
| Apple open-source msdos FSKit implementation | Apple internal reference | LOW (won't build externally) |
| Training data (FSKit framework API) | Pre-existing knowledge | LOW |

---

## Open Questions Requiring Phase-Specific Research

1. **How exactly to pass B2 bucket name + credentials at mount time?** Options: mount command options via `FSActivateOptionSyntax` in Info.plist, shared Keychain via App Group, or mount options embedded in resource specifier. Needs hands-on experimentation.

2. **What resource type for CloudMount?** `FSGenericURLResource` with a B2 bucket URL? Or `FSBlockDeviceResource` with a dummy device? Or `FSPathURLResource` with a dummy path? The mount command requires a resource specifier — need to determine what works for a fully virtual FS.

3. **Finder sidebar integration:** How to make volumes appear in Finder sidebar? DiskArbitration integration? This is under-documented for FSKit.

4. **KeychainAccess library compatibility with App Groups:** May need to replace KeychainAccess with direct Security framework calls for Keychain sharing between app and extension.

5. **Extension enablement detection:** How does the main app detect if the FSKit extension is enabled? Is there a programmatic check, or must we try to mount and detect failure?

6. **Update safety:** Forum reports indicate that app updates while a volume is mounted can cause unmount without warning and potentially system-wide mount freezes. Need a strategy for safe updates.
