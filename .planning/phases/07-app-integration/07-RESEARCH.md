# Phase 7: App Integration - Research

**Researched:** 2026-02-06
**Domain:** macOS host app integration with FSKit extension — mount/unmount, status monitoring, extension detection, UI updates
**Confidence:** MEDIUM-HIGH — Mount mechanism confirmed by Apple DTS engineer; extension detection is heuristic-based; DiskArbitration/NSWorkspace patterns are well-established

## Summary

Phase 7 wires the CloudMount SwiftUI host app to the FSKit extension built in Phase 6. The core challenge is that FSKit has **no programmatic mount API** — the standard approach (confirmed by Apple DTS engineer Kevin Elliott) is to shell out to `/sbin/mount -F`. This is not a hack; DiskArbitration itself uses `posix_spawn` to run `/sbin/mount` internally.

The five areas of integration are: (1) **MountClient** replacing DaemonClient stubs, using `Process` to run `mount -F` and `umount`; (2) **mount status monitoring** via `NSWorkspace` notifications (`didMountNotification` / `didUnmountNotification`) which is the simplest and most reliable approach for a menu bar app; (3) **FSKit extension detection** via a heuristic "try mount and check error" approach, since there is no public API to query extension enablement status; (4) **UI updates** removing macFUSE references and wiring mount/unmount buttons; (5) **B2 bucket listing** in the Settings pane (already partially implemented in SettingsView.swift).

**Primary recommendation:** Use `Process` to invoke `/sbin/mount -F -t b2 b2://bucketName?accountId=UUID /Volumes/bucketName` for mounting, `umount /Volumes/bucketName` for unmounting, and `NSWorkspace.shared.notificationCenter` for real-time mount status monitoring. Detect extension enablement by attempting a mount and inspecting the error output.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation `Process` | System | Execute mount/umount commands | Apple DTS confirms `/sbin/mount` is the primary mount interface; DiskArbitration itself uses it |
| NSWorkspace | System | Mount/unmount notifications | Push-based, zero-polling, instant status updates |
| CloudMountKit | Internal | SharedDefaults, CredentialStore, MountConfiguration | Already contains all models needed |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| DiskArbitration | System | Advanced mount detection (future) | If NSWorkspace notifications prove insufficient; Apple DTS recommends this long-term |
| os.Logger | System | Structured logging | Mount/unmount operation logging |
| FileManager | System | Create mount point directories | `/Volumes/bucketName` directory creation before mount |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Process (mount -F) | DiskArbitration DADiskMount | DiskArb can't initiate FSKit URL-based mounts yet (confirmed by Apple DTS, bugs pending) |
| NSWorkspace notifications | DiskArbitration callbacks | DiskArb is more detailed but heavier; NSWorkspace is sufficient for mounted/unmounted status |
| NSWorkspace notifications | Polling /Volumes | Polling is wasteful and has latency; NSWorkspace is push-based |
| Heuristic extension detection | FSClient.fetchInstalledExtensions | Phase 6 research mentioned FSClient but this API is undocumented/unreliable; heuristic is more robust |

**Installation:**
No additional dependencies needed — all frameworks are system-provided.

## Architecture Patterns

### Recommended Project Structure
```
CloudMount/
├── CloudMountApp.swift          # Existing — no changes needed
├── AppState.swift               # Modified — add mount status, extension detection
├── MountClient.swift            # NEW — replaces DaemonClient stubs
├── MountMonitor.swift           # NEW — NSWorkspace mount/unmount observer
├── ExtensionDetector.swift      # NEW — FSKit extension enablement check
├── Views/
│   ├── MenuContentView.swift    # Modified — wire mount buttons, status indicators
│   ├── SettingsView.swift       # Modified — minor cleanup, macFUSE refs removed
│   └── OnboardingView.swift     # NEW — first-launch extension setup guide
```

### Pattern 1: MountClient — Process-Based Mount/Unmount
**What:** A class that wraps `Process` to invoke `/sbin/mount -F` and `umount`
**When to use:** Every mount and unmount operation from the UI

```swift
// Source: Apple DTS (Kevin Elliott) — forums/thread/799283
// "In practice, /sbin/mount is the system's primary mounting interface...
//  DiskArbitration itself uses posix_spawn to run /sbin/mount."

@MainActor
final class MountClient {
    
    enum MountError: LocalizedError {
        case mountFailed(String)
        case unmountFailed(String)
        case mountPointCreationFailed
        case extensionNotEnabled
        
        var errorDescription: String? {
            switch self {
            case .mountFailed(let msg): return "Mount failed: \(msg)"
            case .unmountFailed(let msg): return "Unmount failed: \(msg)"
            case .mountPointCreationFailed: return "Could not create mount point directory"
            case .extensionNotEnabled: return "FSKit extension not enabled in System Settings"
            }
        }
    }
    
    /// Mount a B2 bucket using the FSKit extension.
    /// Command: mount -F -t b2 b2://bucketName?accountId=UUID /Volumes/bucketName
    func mount(_ config: MountConfiguration) async throws {
        let mountPoint = config.mountPoint  // e.g., "/Volumes/bucketName"
        
        // Create mount point directory if needed
        if !FileManager.default.fileExists(atPath: mountPoint) {
            try FileManager.default.createDirectory(
                atPath: mountPoint,
                withIntermediateDirectories: true
            )
        }
        
        // Build the b2:// URL that CloudMountFileSystem.loadResource expects
        let resourceURL = "b2://\(config.bucketName)?accountId=\(config.accountId.uuidString)"
        
        let (exitCode, stderr) = try await runProcess(
            "/sbin/mount",
            arguments: ["-F", "-t", "b2", resourceURL, mountPoint]
        )
        
        if exitCode != 0 {
            // Check for common error patterns
            if stderr.contains("not found") || stderr.contains("extensionKit") {
                throw MountError.extensionNotEnabled
            }
            throw MountError.mountFailed(stderr)
        }
    }
    
    /// Unmount a mounted B2 bucket.
    func unmount(_ config: MountConfiguration) async throws {
        let (exitCode, stderr) = try await runProcess(
            "/usr/sbin/diskutil",
            arguments: ["unmount", config.mountPoint]
        )
        
        if exitCode != 0 {
            // Fallback to umount if diskutil fails
            let (code2, err2) = try await runProcess(
                "/sbin/umount",
                arguments: [config.mountPoint]
            )
            if code2 != 0 {
                throw MountError.unmountFailed(err2)
            }
        }
    }
    
    /// Run a process and return (exitCode, stderr).
    private func runProcess(_ path: String, arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()  // Discard stdout
        
        try process.run()
        process.waitUntilExit()
        
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        
        return (process.terminationStatus, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
```

### Pattern 2: Mount Status Monitoring via NSWorkspace
**What:** Real-time mount/unmount detection using NSWorkspace notification center
**When to use:** Always active while the app is running to keep UI in sync

```swift
// Source: Apple NSWorkspace documentation
// NSWorkspace posts didMountNotification and didUnmountNotification
// for ALL volume mount/unmount events, including FSKit volumes.

@MainActor
final class MountMonitor: ObservableObject {
    @Published var mountedPaths: Set<String> = []
    
    private var observers: [NSObjectProtocol] = []
    
    func startMonitoring(configs: [MountConfiguration]) {
        // Initial scan — check which mount points are currently mounted
        refreshMountStatus(configs: configs)
        
        // Observe mount events
        let mountObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let path = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                self.mountedPaths.insert(path.path)
            }
        }
        observers.append(mountObs)
        
        // Observe unmount events
        let unmountObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let path = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                self.mountedPaths.remove(path.path)
            }
        }
        observers.append(unmountObs)
    }
    
    func refreshMountStatus(configs: [MountConfiguration]) {
        // Check /Volumes for existing mounts
        let fm = FileManager.default
        var mounted = Set<String>()
        for config in configs {
            // A simple heuristic: if the mount point exists AND is a mount point
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: config.mountPoint, isDirectory: &isDir), isDir.boolValue {
                // Check if it's actually a mount (not just an empty directory)
                // by comparing device IDs of the path and its parent
                mounted.insert(config.mountPoint)
            }
        }
        mountedPaths = mounted
    }
    
    func isMounted(_ config: MountConfiguration) -> Bool {
        mountedPaths.contains(config.mountPoint)
    }
    
    func stopMonitoring() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
```

### Pattern 3: Extension Detection via Heuristic
**What:** Detect if the FSKit extension is enabled by attempting a probe or checking known files
**When to use:** On first launch and when mount fails with extension-related errors

```swift
// There is NO public API to query FSKit extension enablement.
// Apple DTS (Quinn "The Eskimo!") confirmed enablement is per-user
// and stored in implementation-detail files that should NOT be relied upon.
//
// Best approach: Try to mount, detect error pattern, guide user.

@MainActor
final class ExtensionDetector: ObservableObject {
    enum ExtensionStatus {
        case unknown
        case enabled
        case disabled
        case checking
    }
    
    @Published var status: ExtensionStatus = .unknown
    
    /// Check extension status by attempting a dry-run probe.
    func checkExtensionStatus() async {
        status = .checking
        
        // Attempt to run mount in dry-run mode (-d flag)
        // mount -d -F -t b2 b2://probe /tmp/cloudmount-probe
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.arguments = ["-d", "-F", "-t", "b2", "b2://probe", "/tmp/cloudmount-probe"]
        
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            
            if stderr.contains("not found") || stderr.contains("extensionKit") {
                status = .disabled
            } else {
                // Dry-run succeeded or failed for other reasons — extension is found
                status = .enabled
            }
        } catch {
            status = .unknown
        }
    }
    
    /// Open System Settings to the Extensions pane.
    func openSystemSettings() {
        // Deep link to Login Items & Extensions
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

### Pattern 4: AppState Integration
**What:** Updated AppState that integrates MountClient, MountMonitor, and ExtensionDetector
**When to use:** Central state management for the app

```swift
@MainActor
final class AppState: ObservableObject {
    // Existing state
    @Published var accounts: [B2Account] = []
    @Published var mountConfigs: [MountConfiguration] = []
    @Published var lastError: String?
    @Published var isConnected: Bool = false
    
    // NEW: Mount status tracking
    @Published var mountStatuses: [UUID: MountStatus] = [:]  // config.id → status
    
    enum MountStatus {
        case unmounted
        case mounting
        case mounted
        case unmounting
        case error(String)
    }
    
    // NEW: Dependencies
    let mountClient = MountClient()
    let mountMonitor = MountMonitor()
    let extensionDetector = ExtensionDetector()
    
    // Mount/unmount replacing stubs
    func mount(_ config: MountConfiguration) {
        mountStatuses[config.id] = .mounting
        lastError = nil
        
        Task {
            do {
                try await mountClient.mount(config)
                mountStatuses[config.id] = .mounted
            } catch {
                mountStatuses[config.id] = .error(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }
    
    func unmount(_ config: MountConfiguration) {
        mountStatuses[config.id] = .unmounting
        
        Task {
            do {
                try await mountClient.unmount(config)
                mountStatuses[config.id] = .unmounted
            } catch {
                mountStatuses[config.id] = .error(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }
}
```

### Anti-Patterns to Avoid
- **Don't use DiskArbitration for initiating FSKit URL-based mounts:** DiskArb can "see" FSKit volumes in callbacks but cannot initiate mounts for non-block-device resources. Use `mount -F` instead.
- **Don't poll /Volumes for mount status:** NSWorkspace notifications are push-based and instant. Polling wastes CPU and has latency.
- **Don't try to read `enabledModules.plist`:** Apple DTS explicitly warned this is an implementation detail that may be MAC-protected. Use the heuristic approach.
- **Don't run mount/umount on the main thread:** Use `async` / `Task {}` — Process.run is blocking when using `waitUntilExit()`.
- **Don't assume /Volumes/bucketName is writable:** On modern macOS, `/Volumes` is a firmlinked path that may require the mount command to create the subdirectory. The `mount` command itself handles this.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Mount initiation | Custom XPC/DiskArb mount | `Process` running `/sbin/mount -F` | Apple DTS confirms this is the standard approach; DiskArb itself does this |
| Mount status monitoring | Timer-based polling of /Volumes | `NSWorkspace.didMountNotification` | Push-based, zero CPU cost, instant |
| Extension enablement check | Reading enabledModules.plist | Heuristic probe (try mount, check error) | Apple warned against relying on plist details |
| Mount point creation | Manual mkdir chain | `FileManager.createDirectory(withIntermediateDirectories:)` | Handles nested paths, permissions |
| URL construction for mount | String concatenation | `URLComponents` with query items | Proper encoding, no escaping bugs |

**Key insight:** The `/sbin/mount` command IS the system's mount API. Even DiskArbitration uses it internally. Shelling out to it is the correct, Apple-endorsed approach for FSKit URL-based resources.

## Common Pitfalls

### Pitfall 1: Mount Point Directory Must Exist Before Mount
**What goes wrong:** `mount -F` fails with "No such file or directory" because `/Volumes/bucketName` doesn't exist.
**Why it happens:** Unlike some mount implementations, `mount -F` does not create the mount point. The caller must ensure it exists.
**How to avoid:** Call `FileManager.default.createDirectory(atPath:withIntermediateDirectories:)` before running mount. Clean up empty directories on unmount failure.
**Warning signs:** Mount returns exit code 1 with "No such file or directory" in stderr.

### Pitfall 2: Mount Fails Silently When Extension Not Enabled
**What goes wrong:** Mount returns "File system named b2 not found" and the user has no idea why.
**Why it happens:** FSKit extensions must be manually enabled in System Settings. First-time users won't know this.
**How to avoid:** On mount failure, check stderr for "not found" pattern. Show onboarding UI guiding user to System Settings > General > Login Items & Extensions > File System Extensions. Store a "setupComplete" flag in UserDefaults.
**Warning signs:** Mount stderr contains "not found" or "extensionKit" error domain.

### Pitfall 3: Process.waitUntilExit() Blocks the Thread
**What goes wrong:** The UI freezes while mount/unmount is running.
**Why it happens:** `Process.waitUntilExit()` is synchronous. If called on the main thread, the entire UI blocks.
**How to avoid:** Always run Process operations in a `Task {}` detached from the main actor, or use `terminationHandler` callback pattern instead of `waitUntilExit()`.
**Warning signs:** Menu bar app becomes unresponsive when clicking Mount.

### Pitfall 4: NSWorkspace Notifications May Not Fire for Mount Point Changes
**What goes wrong:** Mount status in UI doesn't update after mount/unmount.
**Why it happens:** NSWorkspace mount notifications fire for volumes that appear in Finder's sidebar. FSKit volumes mounted at `/tmp/` or non-standard paths may not trigger the notification.
**How to avoid:** Mount to `/Volumes/bucketName` (which is the standard path for Finder-visible volumes). As a fallback, also check mount exit code for immediate status. Keep `mountStatuses` in sync manually on mount/unmount completion.
**Warning signs:** NSWorkspace notification observer fires for external drives but not for CloudMount volumes.

### Pitfall 5: Stale Mount Points After Unclean Shutdown
**What goes wrong:** An empty `/Volumes/bucketName` directory persists after an unclean shutdown (crash, force quit), and future mounts fail because the directory exists but is stale.
**Why it happens:** If the app crashes while a volume is mounted, the extension process may also die, leaving a stale mount point.
**How to avoid:** On app launch, scan configured mount points. For each, check if it's actually mounted (using `statfs()` or comparing device IDs). If the directory exists but is not a mount point, remove it. If it IS a mount point (from a previous run), record it as mounted.
**Warning signs:** "Resource busy" errors when trying to mount to an existing path.

### Pitfall 6: umount May Fail if Files Are Open
**What goes wrong:** Unmount fails with "Resource busy" because Finder or another process has files open on the volume.
**Why it happens:** macOS won't unmount a volume with open file descriptors.
**How to avoid:** Try `diskutil unmount` first (it's more graceful and handles busy volumes better). Fall back to `umount`. If both fail, offer `diskutil unmount force` as a last resort (with user confirmation). Update UI to show "busy" state.
**Warning signs:** umount returns exit code 1 with "Resource busy".

## Code Examples

### Mount Command for b2:// URL Scheme
```bash
# Source: Confirmed from project's Info.plist (FSSupportedSchemes: ["b2"])
# and CloudMountFileSystem.swift (probes b2:// URLs, extracts host + accountId query param)

# Mount:
mount -F -t b2 "b2://myBucketName?accountId=550E8400-E29B-41D4-A716-446655440000" /Volumes/myBucketName

# Unmount (preferred — more graceful):
diskutil unmount /Volumes/myBucketName

# Unmount (fallback):
umount /Volumes/myBucketName

# Unmount (force — last resort):
diskutil unmount force /Volumes/myBucketName
```

### NSWorkspace Mount Monitoring
```swift
// Source: Apple NSWorkspace documentation
// Works for all volume types including FSKit

let center = NSWorkspace.shared.notificationCenter

// Mount notification
center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
    if let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
        print("Mounted: \(volumeURL.path)")
    }
}

// Unmount notification
center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
    if let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
        print("Unmounted: \(volumeURL.path)")
    }
}

// Will-unmount notification (for cleanup)
center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { note in
    if let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
        print("About to unmount: \(volumeURL.path)")
    }
}
```

### Process.run with Async Pattern
```swift
// Source: Foundation Process documentation
// Run mount/umount without blocking the main thread

func runProcess(_ path: String, arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            continuation.resume(returning: (process.terminationStatus, stdout, stderr))
        }
        
        do {
            try process.run()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}
```

### Open System Settings to Extensions Pane
```swift
// Source: macOS URL scheme for System Settings
// Opens the Login Items & Extensions pane where File System Extensions are managed

func openExtensionSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| DaemonClient (Unix socket to Rust daemon) | MountClient (Process to mount -F) | This phase | Eliminates entire IPC layer, daemon process |
| macFUSE detection | FSKit extension detection | This phase | Per-user System Settings check, not system-wide kext |
| Timer-based daemon polling | NSWorkspace push notifications | This phase | Zero polling, instant status updates |
| Rust FUSE mount() call | `/sbin/mount -F` command | FSKit V2 | Shell invocation is Apple-endorsed for non-block-device FS |

**Deprecated/outdated:**
- **DaemonClient:** Replaced entirely by MountClient
- **MacFUSEDetector:** No longer needed — FSKit replaces macFUSE
- **Unix socket IPC:** Eliminated — no communication needed between app and extension

## Open Questions

1. **NSWorkspace notifications for /Volumes FSKit mounts**
   - What we know: NSWorkspace fires for standard volume mounts. DiskArbitration sees FSKit mounts in its callbacks.
   - What's unclear: Whether NSWorkspace fires for ALL FSKit mounts, or only those mounted at specific paths. Forum developers mounted at `/tmp/` paths which may not trigger Finder-visible notifications.
   - Recommendation: Mount at `/Volumes/bucketName` (which is what MountConfiguration already specifies). Test empirically. If NSWorkspace doesn't fire, fall back to manual status tracking based on mount exit code + DiskArbitration as backup.

2. **App Sandbox and Process execution**
   - What we know: A sandboxed app cannot run arbitrary processes. The host app may need exceptions.
   - What's unclear: Whether the host app is sandboxed (current codebase shows no sandbox entitlement). macOS menu bar apps distributed outside App Store typically are NOT sandboxed.
   - Recommendation: Since this is a Developer ID (non-App Store) distribution, don't sandbox the host app. The FSKit extension IS sandboxed (required). If App Store distribution is needed later, file Apple bug for sandbox-compatible mount API (as Apple DTS suggested in forums/thread/799283).

3. **mount -F permissions without root**
   - What we know: Regular users can run `mount -F` for FSKit extensions. The mount command itself handles privilege escalation where needed. `/Volumes` subdirectories may require elevated permissions.
   - What's unclear: Whether creating `/Volumes/bucketName` requires root. Some macOS versions restrict `/Volumes` differently.
   - Recommendation: Try creating directory first. If it fails with permission error, mount at an alternative path like `~/CloudMount/bucketName`. Test empirically on macOS 26.

4. **Dry-run mount for extension detection**
   - What we know: `mount -d` flag does a dry run (everything except the actual syscall).
   - What's unclear: Whether `-d -F -t b2` properly probes for the extension without side effects.
   - Recommendation: Test empirically. If dry-run doesn't work well, fall back to checking whether mount of a known-bad URL returns "not found" vs "probe failed" to distinguish "extension missing" from "extension present but resource invalid".

## Sources

### Primary (HIGH confidence)
- Apple DTS Engineer Kevin Elliott, forums/thread/799283 — "In practice, /sbin/mount is the system's primary mounting interface. DiskArb uses posix_spawn to run /sbin/mount."
- Apple DTS Engineer Kevin Elliott, forums/thread/797485 — "I would recommend using the mount command-line tool. DiskArb should fully support FSKit volumes [long term]."
- Apple DTS Engineer Quinn "The Eskimo!", forums/thread/808594 — Extension enablement is per-user, no programmatic enable API, don't rely on implementation-detail files.
- macOS mount(8) man page — `-F` flag: "Forces the file system type be considered as an FSModule delivered using FSKit."
- macOS umount(8) man page — Standard unmount usage.
- KhaosT/FSKitSample README — Mount: `mount -F -t MyFS disk18 /tmp/TestVol`, Unmount: `umount /tmp/TestVol`
- Existing codebase: CloudMountFileSystem.swift — URL format is `b2://bucketName?accountId=UUID`
- Existing codebase: MountConfiguration.swift — mountPoint is `/Volumes/bucketName`

### Secondary (MEDIUM confidence)
- Apple NSWorkspace `didMountNotification` / `didUnmountNotification` — Standard macOS pattern for volume status monitoring; should work for FSKit volumes mounted at /Volumes
- DiskArbitration open source (apple-oss-distributions/DiskArbitration) — Shows DiskArb uses posix_spawn → /sbin/mount internally

### Tertiary (LOW confidence)
- Extension detection via dry-run mount — Not verified; needs empirical testing
- NSWorkspace notification coverage for FSKit — Assumed to work but not explicitly confirmed in forums
- `/Volumes` directory creation permissions on macOS 26 — May require special handling

## Metadata

**Confidence breakdown:**
- Mount mechanism (mount -F): HIGH — Apple DTS confirmed, DiskArb source verified
- Unmount mechanism (umount/diskutil): HIGH — Standard macOS commands, well-documented
- URL format (b2://bucket?accountId=UUID): HIGH — Directly from existing CloudMountFileSystem.swift
- Mount status monitoring (NSWorkspace): MEDIUM — Standard pattern but not verified for FSKit specifically
- Extension detection (heuristic): MEDIUM — No public API exists; heuristic approach is best available
- Sandbox implications: MEDIUM — Developer ID apps are typically unsandboxed; may need testing
- /Volumes directory creation: LOW — macOS 26 may handle this differently than previous versions

**Research date:** 2026-02-06
**Valid until:** 2026-03-08 (30 days — FSKit is still evolving)
