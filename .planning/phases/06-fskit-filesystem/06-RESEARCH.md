# Phase 6: FSKit Filesystem - Research

**Researched:** 2026-02-05
**Domain:** FSKit V2 filesystem extension (macOS 26+), mapping POSIX operations to B2 cloud storage
**Confidence:** MEDIUM — FSKit V2 is new (macOS 26), some API behaviors can only be verified at runtime

## Summary

FSKit is Apple's user-space filesystem framework, available since macOS 15.4 (V1) with significant additions in macOS 26 (V2). The framework provides `FSUnaryFileSystem` as the base class for a "one resource → one volume" filesystem, which is exactly what CloudMount needs — one B2 bucket maps to one Finder volume.

The architecture requires three classes: (1) a `@main` entry point struct conforming to `UnaryFileSystemExtension`, (2) an `FSUnaryFileSystem` subclass implementing `FSUnaryFileSystemOperations` for lifecycle (probe/load/unload), and (3) an `FSVolume` subclass conforming to `FSVolume.Operations`, `FSVolume.PathConfOperations`, `FSVolume.OpenCloseOperations`, and `FSVolume.ReadWriteOperations`. The volume manages a tree of `FSItem` objects and handles all POSIX-like operations (lookup, enumerate, create, remove, rename, read, write, get/set attributes).

For a cloud filesystem like CloudMount, `FSGenericURLResource` (new in macOS 26) is the correct resource type — it represents an abstract URL whose interpretation is entirely up to the implementation. The extension receives this URL in `loadResource()` and uses it to identify which B2 bucket to mount.

**Primary recommendation:** Implement a three-class architecture — `CloudMountExtensionMain` (@main entry), `CloudMountFileSystem` (FSUnaryFileSystem subclass), `B2Volume` (FSVolume subclass) — with FSItem subclassing for per-item B2 metadata tracking. Use callback-based API pattern (replyHandlers, not async/await) since FSKit protocols are Objective-C-bridged.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| FSKit | macOS 26 (V2) | Filesystem extension framework | Only way to implement user-space FS on macOS |
| CloudMountKit | Internal | B2Client, FileCache, MetadataCache, credentials | Already built in Phase 5 |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| os.Logger | System | Structured logging within extension | All FSKit operations need logging for debugging |
| Foundation | System | FileManager for temp files, URL handling | Cache management, temp staging files |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| FSUnaryFileSystem | FSFileSystem | FSFileSystem supports multi-volume/multi-resource, but is more complex and FSKit docs note "current version supports only FSUnaryFileSystem" |
| FSGenericURLResource | FSPathURLResource | PathURL represents a local path; GenericURL is correct for network/cloud resources |
| ReadWriteOperations | KernelOffloadedIOOperations | KernelOffloadedIO gives better perf via kernel bypass, but requires block-device-like semantics incompatible with cloud storage |

**Installation:**
No additional dependencies — FSKit is a system framework. CloudMountKit is already linked to the extension target.

## Architecture Patterns

### Recommended Project Structure
```
CloudMountExtension/
├── CloudMountExtension.swift          # @main entry point (UnaryFileSystemExtension)
├── CloudMountFileSystem.swift         # FSUnaryFileSystem + FSUnaryFileSystemOperations
├── B2Volume.swift                     # FSVolume subclass + Operations + R/W + Open/Close
├── B2VolumeOperations.swift           # FSVolume.Operations methods (large file)
├── B2VolumeReadWrite.swift            # ReadWriteOperations + OpenCloseOperations
├── B2Item.swift                       # FSItem subclass with B2 metadata
├── B2ItemAttributes.swift             # Attribute mapping (B2FileInfo → FSItem.Attributes)
├── MetadataBlocklist.swift            # macOS metadata suppression logic
├── StagingManager.swift               # Write staging (temp files + upload on close)
└── Info.plist                         # NSExtension + FSSupportedSchemes
```

### Pattern 1: Extension Entry Point
**What:** `@main` struct conforming to `UnaryFileSystemExtension` that creates the filesystem delegate
**When to use:** Always — this is the required entry pattern for FSKit extensions

```swift
// Source: Apple FSKit official documentation
import FSKit

@main
struct CloudMountExtensionMain: UnaryFileSystemExtension {
    let fileSystem = CloudMountFileSystem()
}
```

### Pattern 2: Filesystem Lifecycle (FSUnaryFileSystemOperations)
**What:** Three required methods — `probeResource`, `loadResource`, `unloadResource` — manage the resource-to-volume lifecycle
**When to use:** The filesystem subclass must implement these

```swift
class CloudMountFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    
    func probeResource(resource: FSResource, replyHandler: (FSProbeResult?, (any Error)?) -> Void) {
        // Check if we can handle this resource
        guard let urlResource = resource as? FSGenericURLResource else {
            let result = FSProbeResult(result: .notRecognized, name: nil)
            replyHandler(result, nil)
            return
        }
        // Validate the URL scheme (e.g., "b2://bucket-name")
        let result = FSProbeResult(result: .recognized, name: urlResource.url.host)
        replyHandler(result, nil)
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions, 
                      replyHandler: (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSGenericURLResource else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        // Parse URL to get bucket info, create B2Client, return volume
        let volume = B2Volume(/* ... */)
        replyHandler(volume, nil)
    }
    
    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: ((any Error)?) -> Void) {
        // Flush caches, close connections
        replyHandler(nil)
    }
    
    func didFinishLoading() {
        // Optional: post-load setup
    }
}
```

### Pattern 3: Callback-Based API (NOT async/await)
**What:** All FSKit protocol methods use replyHandler callbacks, not Swift async/await
**When to use:** All FSVolume.Operations, ReadWriteOperations, OpenCloseOperations methods
**Critical note:** FSKit protocols are Objective-C bridged (`@objc`). The replyHandler pattern must be followed exactly. You can use `Task {}` inside the callback to bridge to async CloudMountKit code, but the FSKit method signatures use closures.

```swift
// CORRECT: Use replyHandler pattern, bridge to async internally
func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                replyHandler: (FSItem?, FSItem.Attributes?, (any Error)?) -> Void) {
    Task {
        do {
            let item = try await self.performLookup(name: name, directory: directory)
            replyHandler(item, item.attributes, nil)
        } catch {
            replyHandler(nil, nil, error)
        }
    }
}
```

### Pattern 4: FSItem Subclass for B2 Metadata
**What:** Custom FSItem subclass storing B2-specific data (fileId, bucketId, B2 path, isDirectory)
**When to use:** Every item returned from lookup/create/enumerate

```swift
class B2Item: FSItem {
    let b2Path: String           // Full B2 key path (e.g., "photos/vacation/img.jpg")
    let bucketId: String
    var b2FileId: String?        // nil for directories inferred from delimiter
    var b2FileInfo: B2FileInfo?  // Cached B2 metadata
    var localStagingURL: URL?    // Non-nil when file has uncommitted writes
    var isDirty: Bool = false    // True when writes pending upload
}
```

### Pattern 5: Directory Enumeration with Packer
**What:** `enumerateDirectory` receives an `FSDirectoryEntryPacker` to pack entries one at a time
**When to use:** The readdir/enumerate operation

```swift
func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                        verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest,
                        packer: FSDirectoryEntryPacker, 
                        replyHandler: (FSDirectoryVerifier, (any Error)?) -> Void) {
    Task {
        let entries = try await listB2Directory(directory)
        for (index, entry) in entries.enumerated() {
            let item = makeItem(from: entry)
            let entryAttrs = makeAttributes(from: entry)
            // Pack returns false when buffer is full
            if !packer.packEntry(name: entry.name, itemID: item.id, 
                                 cookie: FSDirectoryCookie(index + 1),
                                 attributes: entryAttrs) {
                break
            }
        }
        replyHandler(verifier, nil)
    }
}
```

### Anti-Patterns to Avoid
- **Don't use async/await in FSKit protocol signatures:** The protocols are ObjC-bridged and require replyHandler closures. Bridge internally with `Task {}`.
- **Don't create FSItem from scratch each lookup:** Cache FSItem instances keyed by B2 path. The kernel maintains vnodes that reference your FSItem objects — returning different FSItem instances for the same path causes issues.
- **Don't block the replyHandler thread:** FSKit operations are dispatched serially per-volume. Long-running B2 API calls must run in a Task to avoid blocking other operations.
- **Don't ignore replyHandler errors:** Always call replyHandler exactly once, even on error paths. Use `fs_errorForPOSIXError()` to convert errno values.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| POSIX error conversion | Custom NSError creation | `fs_errorForPOSIXError(errno)` | FSKit provides this helper; errors must be in FSKit's expected format |
| File identifier management | Manual UInt64 counters | `FSItem.Identifier` enum cases | FSKit has `.number(UInt64)` and `.unresolved` built in |
| Volume statistics | Custom struct | `FSStatFSResult` | The `volumeStatistics` property returns this FSKit-provided type |
| Attribute validation | Manual flag tracking | `FSItem.Attributes.isValid(_:)` / `GetAttributesRequest.wantedAttributes` | FSKit tracks which attributes are valid/requested |
| Directory entry packing | Manual buffer management | `FSDirectoryEntryPacker` | Provided by enumerate callback; handles buffer sizing |
| File data buffers | Raw Data copying | `FSMutableFileDataBuffer` | Provided to read operations; copy data into it |

**Key insight:** FSKit is an Objective-C framework with Swift overlays. Many patterns (replyHandlers, NSObject subclassing) feel more ObjC than Swift. Don't fight the framework — use its types and patterns, bridging to async Swift internally.

## Common Pitfalls

### Pitfall 1: removeItem May Not Fire (Known FSKit V2 Bug)
**What goes wrong:** The `removeItem(_:named:fromDirectory:replyHandler:)` delegate method may not be called by the kernel in some cases.
**Why it happens:** Known bug in early FSKit V2 (macOS 26 beta). The kernel may handle removal at the VFS layer without notifying the extension.
**How to avoid:** Implement `removeItem` but also handle stale items gracefully. When a `lookupItem` finds an item that no longer exists on B2, return `ENOENT`. Use `reclaimItem` as the fallback cleanup path — this IS reliably called when the kernel drops its reference to an FSItem.
**Warning signs:** Files appear to delete in Finder but remain on B2; or deleted items reappear after a directory re-enumeration.

### Pitfall 2: No Kernel Caching (~121µs per syscall)
**What goes wrong:** Every filesystem operation (stat, readdir, read) round-trips through XPC to the extension process, causing ~121µs overhead per syscall.
**Why it happens:** FSKit V2 doesn't yet support kernel-level caching of metadata or data. Every `stat()` call goes through to your extension.
**How to avoid:** Aggressive in-memory caching in the extension. Cache FSItem instances, directory listings, and file attributes. For reads, serve from the local file cache (already in CloudMountKit's FileCache). Minimize round-trips to B2 by using the MetadataCache TTL.
**Warning signs:** Finder feels sluggish when browsing directories; `ls -la` takes seconds.

### Pitfall 3: Extension Must Be Manually Enabled
**What goes wrong:** After installation, the FSKit extension doesn't appear or mount requests fail.
**Why it happens:** macOS requires users to explicitly enable filesystem extensions in System Settings > General > Login Items & Extensions > File System Extensions.
**How to avoid:** Document this in the app's onboarding flow. The host app should detect whether the extension is enabled (via `FSClient.shared.fetchInstalledExtensions`) and guide users to System Settings if not found.
**Warning signs:** `FSClient.fetchInstalledExtensions` returns empty array or doesn't include your extension.

### Pitfall 4: Swift Concurrency vs ObjC Callbacks
**What goes wrong:** Data races or crashes when mixing Swift actors (B2Client is an actor) with FSKit's ObjC callback pattern.
**Why it happens:** FSKit methods are called on an internal dispatch queue. `Task {}` creates a new concurrent task. Actor isolation of B2Client means calls are serialized on the actor's executor.
**How to avoid:** Use `Task { @MainActor in }` or explicit `Task { }` blocks inside replyHandler implementations. Ensure the replyHandler is called exactly once, on any thread (FSKit handles the dispatch). Be careful with `@Sendable` closures when capturing FSItem references.
**Warning signs:** Crashes in XPC serialization; EXC_BAD_ACCESS on FSItem access from wrong thread.

### Pitfall 5: FSFileName is Not String
**What goes wrong:** Trying to use `FSFileName` as a String directly, or constructing it incorrectly.
**Why it happens:** `FSFileName` is a data buffer class, not a Swift String. It represents a file name as raw bytes.
**How to avoid:** Use `FSFileName(string:)` constructor and access `.string` property for conversion. Handle encoding carefully — B2 file names are UTF-8.
**Warning signs:** Garbled file names in Finder; lookup failures for files with non-ASCII names.

### Pitfall 6: Write-on-Close Upload Failures
**What goes wrong:** File close returns an error because B2 upload failed, but the calling app doesn't handle the error gracefully.
**Why it happens:** B2 uploads can fail (network issues, auth expiry). The `closeItem` callback must report this error, but many apps don't check close() return values.
**How to avoid:** On upload failure in `closeItem`: (1) return the error via replyHandler, (2) keep the staged file for retry, (3) mark the item as dirty. Consider a background retry mechanism. Log prominently.
**Warning signs:** Files appear saved locally but don't appear on B2; data loss if cache is evicted before retry.

## Code Examples

### Extension Entry Point
```swift
// Source: Apple FSKit documentation (UnaryFileSystemExtension)
import FSKit

@main
struct CloudMountExtensionMain: UnaryFileSystemExtension {
    let fileSystem = CloudMountFileSystem()
}
```

### FSUnaryFileSystem Subclass
```swift
import FSKit
import CloudMountKit

class CloudMountFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    
    func probeResource(resource: FSResource, 
                       replyHandler: (FSProbeResult?, (any Error)?) -> Void) {
        guard resource is FSGenericURLResource else {
            replyHandler(FSProbeResult(result: .notRecognized, name: nil), nil)
            return
        }
        replyHandler(FSProbeResult(result: .recognized, name: nil), nil)
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSGenericURLResource else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        
        // Parse URL: b2://bucketName?keyId=...&accountId=...
        let url = urlResource.url
        Task {
            do {
                // Create B2Client from credentials in URL/shared config
                let client = try await B2Client(/* from shared config */)
                let volumeID = FSVolume.Identifier(/* unique per bucket */)
                let volumeName = FSFileName(string: url.host ?? "B2 Bucket")
                let volume = B2Volume(volumeID: volumeID, volumeName: volumeName,
                                      b2Client: client, bucketId: "...", bucketName: "...")
                replyHandler(volume, nil)
            } catch {
                replyHandler(nil, error)
            }
        }
    }
    
    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: ((any Error)?) -> Void) {
        // Flush dirty files, clean up staging
        replyHandler(nil)
    }
    
    func didFinishLoading() { }
}
```

### FSVolume Subclass (Core Operations)
```swift
import FSKit
import CloudMountKit

class B2Volume: FSVolume, FSVolume.Operations, FSVolume.PathConfOperations,
                FSVolume.OpenCloseOperations, FSVolume.ReadWriteOperations {
    
    let b2Client: B2Client
    let bucketId: String
    let bucketName: String
    private var itemCache: [String: B2Item] = [:]  // B2 path → FSItem
    private let rootItem: B2Item
    
    init(volumeID: FSVolume.Identifier, volumeName: FSFileName,
         b2Client: B2Client, bucketId: String, bucketName: String) {
        self.b2Client = b2Client
        self.bucketId = bucketId
        self.bucketName = bucketName
        self.rootItem = B2Item(/* root directory */)
        super.init(volumeID: volumeID, volumeName: volumeName)
    }
    
    // MARK: - FSVolume.Operations
    
    func mount(options: FSTaskOptions, replyHandler: (FSItem, FSItem.Attributes, (any Error)?) -> Void) {
        // Return root item and its attributes
        let attrs = FSItem.Attributes()
        attrs.type = .directory
        attrs.mode = 0o755
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.size = 0
        attrs.linkCount = 2
        // Set times to now
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        attrs.birthTime = now
        attrs.modifyTime = now
        replyHandler(rootItem, attrs, nil)
    }
    
    func unmount(replyHandler: ((any Error)?) -> Void) {
        // Flush pending writes, clean up
        replyHandler(nil)
    }
    
    func activate(options: FSTaskOptions, replyHandler: ((any Error)?) -> Void) {
        replyHandler(nil)
    }
    
    func deactivate(options: FSDeactivateOptions, replyHandler: ((any Error)?) -> Void) {
        replyHandler(nil)
    }
    
    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult()
        // B2 has no fixed capacity — report large values
        result.blockSize = 4096
        result.totalBlocks = UInt64(10 * 1024 * 1024 * 1024) / 4096  // 10TB
        result.availableBlocks = result.totalBlocks
        result.freeBlocks = result.totalBlocks
        result.usedBlocks = 0
        result.totalFiles = UInt64.max
        result.freeFiles = UInt64.max - 1
        return result
    }
    
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        // Return capabilities appropriate for a network filesystem
        // Note: details of SupportedCapabilities to be determined at implementation time
        return FSVolume.SupportedCapabilities()
    }
    
    var isOpenCloseInhibited: Bool { false }  // We want open/close calls
    
    // PathConfOperations - return reasonable defaults
    var maxLinkCount: Int { 1 }
    var maxNameLength: Int { 1024 }  // B2 supports up to 1024 byte file names
    var chownRestricted: Bool { true }
    var truncateSupported: Bool { false }  // No truncate in B2
}
```

### Metadata Suppression Pattern
```swift
struct MetadataBlocklist {
    static let blockedPrefixes: Set<String> = [
        ".DS_Store",
        "._",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".VolumeIcon.icns",
    ]
    
    static func isSuppressed(_ name: String) -> Bool {
        for prefix in blockedPrefixes {
            if name == prefix || name.hasPrefix(prefix + "/") || name.hasPrefix("._") {
                return true
            }
        }
        return false
    }
    
    static func isSuppressedPath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.contains { isSuppressed(String($0)) }
    }
}
```

### Read/Write Operations Pattern
```swift
// ReadWriteOperations
func read(from item: FSItem, at offset: off_t, length: Int,
          into buffer: FSMutableFileDataBuffer,
          replyHandler: (Int, (any Error)?) -> Void) {
    guard let b2Item = item as? B2Item else {
        replyHandler(0, fs_errorForPOSIXError(EINVAL))
        return
    }
    Task {
        do {
            // Read from local cache file (downloaded on open)
            let data = try readFromLocalCache(b2Item, offset: offset, length: length)
            buffer.copyBytes(from: data)
            replyHandler(data.count, nil)
        } catch {
            replyHandler(0, error)
        }
    }
}

func write(contents data: Data, to item: FSItem, at offset: off_t,
           replyHandler: (Int, (any Error)?) -> Void) {
    guard let b2Item = item as? B2Item else {
        replyHandler(0, fs_errorForPOSIXError(EINVAL))
        return
    }
    Task {
        do {
            // Write to local staging file
            try writeToStagingFile(b2Item, data: data, offset: offset)
            b2Item.isDirty = true
            replyHandler(data.count, nil)
        } catch {
            replyHandler(0, error)
        }
    }
}

// OpenCloseOperations
func openItem(_ item: FSItem, modes: FSVolume.OpenModes,
              replyHandler: ((any Error)?) -> Void) {
    guard let b2Item = item as? B2Item else {
        replyHandler(fs_errorForPOSIXError(EINVAL))
        return
    }
    Task {
        do {
            // Download file from B2 to local cache on open
            if !b2Item.isDirectory {
                try await downloadToLocalCache(b2Item)
            }
            replyHandler(nil)
        } catch {
            replyHandler(error)
        }
    }
}

func closeItem(_ item: FSItem, modes: FSVolume.OpenModes,
               replyHandler: ((any Error)?) -> Void) {
    guard let b2Item = item as? B2Item else {
        replyHandler(fs_errorForPOSIXError(EINVAL))
        return
    }
    
    // modes parameter: indicates which modes are being RETAINED (kept open)
    // When modes is empty (no retained modes), file is fully closed
    guard modes.isEmpty, b2Item.isDirty else {
        replyHandler(nil)
        return
    }
    
    Task {
        do {
            // Upload dirty file to B2
            try await uploadStagedFile(b2Item)
            b2Item.isDirty = false
            replyHandler(nil)
        } catch {
            // Keep staged file for retry, report error
            replyHandler(error)
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| FUSE/macFUSE | FSKit | macOS 15.4 (V1), macOS 26 (V2) | Native Apple framework, App Store compatible, no kernel extension needed |
| FSBlockDeviceResource only | FSGenericURLResource | macOS 26 (V2) | Network/cloud filesystems can now use URL-based resources instead of faking block devices |
| Kernel extensions (kexts) | FSKit app extensions | macOS 15.4+ | Kexts deprecated; FSKit runs in user space with full sandbox support |

**Deprecated/outdated:**
- **macFUSE/OSXFUSE:** Third-party, requires kernel extension, not App Store compatible, increasingly broken by macOS security updates
- **FSKit V1 (macOS 15.4):** Limited to block device resources only; V2 adds FSGenericURLResource for network filesystems
- **File Provider Extension:** Different purpose (cloud files with offline/online states), not a true filesystem mount

## Open Questions

1. **FSDirectoryEntryPacker API details**
   - What we know: It's passed to `enumerateDirectory` and has a pack method
   - What's unclear: Exact method signature for packing entries; whether it accepts FSItem.Attributes directly or requires a specific format
   - Recommendation: Implement enumerate first, test with minimal entries, iterate on packer usage

2. **FSStatFSResult field requirements**
   - What we know: The `volumeStatistics` property returns this type
   - What's unclear: Which fields are required vs optional; what Finder does with block counts for network volumes
   - Recommendation: Start with large fake values (10TB total, 10TB free), adjust based on Finder behavior

3. **FSVolume.SupportedCapabilities**
   - What we know: Required property on Operations protocol
   - What's unclear: Which capability flags exist and which to set for a cloud filesystem
   - Recommendation: Start with minimal capabilities, add as needed. Check Xcode header for flag options.

4. **URL scheme for FSGenericURLResource**
   - What we know: `FSSupportedSchemes` in Info.plist declares supported schemes; resource arrives with a URL
   - What's unclear: How the host app triggers a mount with a specific URL; whether `mount(8)` command or FSClient API is used
   - Recommendation: Define a custom `b2://` scheme. Host app will use system APIs (likely `mount(8)` equivalent or FSClient) to request mount with `b2://bucketname` URL.

5. **FSItem lifecycle and caching**
   - What we know: FSItem is the equivalent of a kernel vnode; items should be cached
   - What's unclear: When exactly `reclaimItem` is called; whether we can safely hold strong references indefinitely
   - Recommendation: Cache items in a dictionary keyed by B2 path. Clean up in `reclaimItem`. Use weak references if memory pressure is a concern.

6. **closeItem `modes` parameter semantics**
   - What we know: `modes` indicates which open modes to RETAIN (keep open), not which to close
   - What's unclear: Exactly when an empty `modes` means "fully closed" vs intermediate close
   - Recommendation: Upload on close only when `modes` is empty (all modes released). This matches the "file is fully closed when the kernel layer issues a close call with no retained open modes" documentation.

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation JSON API for FSKit framework (`/tutorials/data/documentation/fskit.json`) — Full API surface, class hierarchy, protocol methods
- Apple Developer Documentation for FSUnaryFileSystem (`fsunaryfilesystem.json`) — Lifecycle pattern
- Apple Developer Documentation for FSVolume (`fsvolume.json`) — Volume protocol hierarchy
- Apple Developer Documentation for FSVolume.Operations (`fsvolume/operations.json`) — All required methods
- Apple Developer Documentation for FSUnaryFileSystemOperations — probe/load/unload signatures
- Apple Developer Documentation for FSVolume.OpenCloseOperations — open/close signatures
- Apple Developer Documentation for FSVolume.ReadWriteOperations — read/write signatures
- Apple Developer Documentation for FSGenericURLResource — URL-based resource (macOS 26+)
- Apple Developer Documentation for FSItem.Attributes — Full attribute list
- Apple Developer Documentation for UnaryFileSystemExtension — @main entry pattern
- Apple Developer Documentation for FSClient — Discovery/management API

### Secondary (MEDIUM confidence)
- Existing CloudMount codebase analysis (B2Client, FileCache, MetadataCache APIs)
- FSKit V2 known issues from context (removeItem bug, ~121µs syscall overhead, no kernel caching)

### Tertiary (LOW confidence)
- FSDirectoryEntryPacker exact usage pattern (not fully documented in available JSON docs)
- FSStatFSResult exact fields and Finder behavior with network volume values
- FSVolume.SupportedCapabilities flag values and defaults

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — FSKit is the only option; API surface confirmed from official docs
- Architecture: HIGH — UnaryFileSystemExtension → FSUnaryFileSystem → FSVolume pattern is documented
- Protocol methods: HIGH — All method signatures confirmed from Apple's documentation JSON
- FSGenericURLResource: HIGH — Confirmed as macOS 26 addition for URL-based resources
- Implementation patterns: MEDIUM — Callback bridging to async, item caching strategy based on docs + inference
- Pitfalls: MEDIUM — Known issues from context; some may be resolved in release macOS 26
- Directory enumeration details: LOW — FSDirectoryEntryPacker usage needs runtime verification
- Volume statistics: LOW — Need to test actual Finder behavior with cloud volume values

**Research date:** 2026-02-05
**Valid until:** 2026-03-07 (30 days — FSKit V2 is new, APIs may change in macOS 26 betas)
