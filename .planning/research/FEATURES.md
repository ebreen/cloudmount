# Feature Landscape: FSKit Pivot & Distribution

**Domain:** FSKit filesystem extension, macOS app distribution, Homebrew Cask delivery
**Researched:** February 5, 2026
**Milestone:** v2.0 — FSKit Pivot & Distribution
**Overall confidence:** MEDIUM (FSKit is new with sparse docs; distribution patterns are well-established)

## 1. FSKit Filesystem Extension Features

### Table Stakes — FSKit Operations

Features the filesystem extension MUST implement for Finder to work correctly with mounted volumes. Derived from the existing v1.0 FUSE operations and the FSKit `FSVolume.Operations` protocol (verified against KhaosT/FSKitSample and Apple Developer Forums).

| Feature | FSKit Protocol | FUSE Equivalent | Complexity | Depends On |
|---------|---------------|-----------------|------------|------------|
| **Volume activate/deactivate** | `FSVolume.Operations` | mount/unmount | MEDIUM | FSKit extension setup |
| **Volume statistics (statfs)** | `FSVolume.Operations` (`volumeStatistics`) | `statfs` | LOW | B2 API client |
| **Lookup item by name** | `FSVolume.Operations` (`lookupItem`) | `lookup` | MEDIUM | Inode/path mapping |
| **Get item attributes** | `FSVolume.Operations` (`attributes`) | `getattr` | LOW | Metadata cache |
| **Set item attributes** | `FSVolume.Operations` (`setAttributes`) | `setattr` | LOW | Metadata cache |
| **Enumerate directory** | `FSVolume.Operations` (`enumerateDirectory`) | `readdir` | MEDIUM | B2 list API, metadata cache |
| **Create item (file/dir)** | `FSVolume.Operations` (`createItem`) | `create`/`mkdir` | MEDIUM | B2 upload/folder API |
| **Remove item** | `FSVolume.Operations` (`removeItem`) | `unlink`/`rmdir` | MEDIUM | B2 delete API |
| **Rename item** | `FSVolume.Operations` (`renameItem`) | `rename` | HIGH | B2 copy+delete (no native rename) |
| **Reclaim item** | `FSVolume.Operations` (`reclaimItem`) | FUSE `forget` | LOW | Memory management |
| **Synchronize (flush)** | `FSVolume.Operations` (`synchronize`) | `fsync` | LOW | Upload dirty files |
| **Open/close file** | `FSVolume.OpenCloseOperations` | `open`/`release` | MEDIUM | File handle tracking |
| **Read file data** | `FSVolume.ReadWriteOperations` (`read`) | `read` | MEDIUM | B2 download, local cache |
| **Write file data** | `FSVolume.ReadWriteOperations` (`write`) | `write` | MEDIUM | Local temp file, upload on close |
| **Volume capabilities** | `FSVolume.Operations` (`supportedVolumeCapabilities`) | N/A | LOW | Configuration only |
| **PathConf operations** | `FSVolume.PathConfOperations` | `statfs` limits | LOW | Configuration only |

**Confidence:** MEDIUM — FSKit API verified against sample code and forum posts. Apple's official docs are JS-rendered and couldn't be fetched directly. Protocol names confirmed from KhaosT/FSKitSample source code.

### Table Stakes — FSKit Extension Infrastructure

| Feature | Why Required | Complexity | Depends On |
|---------|-------------|------------|------------|
| **FSUnaryFileSystem subclass** | Entry point for the file system extension; handles probe/load/unload lifecycle | MEDIUM | Xcode project setup |
| **FSItem subclass** | Represents files/directories in the filesystem tree; holds attributes, children, data | MEDIUM | — |
| **Probe resource** | System calls this to check if extension can handle a resource; must return `.usable` | LOW | FSUnaryFileSystemOperations |
| **Load resource** | System calls this to create a volume; returns FSVolume instance | LOW | Volume implementation |
| **Extension Info.plist** | Must declare FSName, FSShortName, FSKit Module capability | LOW | Project configuration |
| **System Settings enablement** | Users must enable extension in System Settings > Login Items & Extensions > File System Extensions | LOW | Extension signing |
| **macOS metadata suppression** | Suppress .DS_Store, .Spotlight-V100, ._files to reduce B2 API calls | LOW | Already built in v1.0 (port logic) |
| **Negative caching** | Cache "file not found" results to prevent repeated B2 lookups | LOW | Already built in v1.0 (port logic) |

### Table Stakes — Swift B2 API Client

Port from Rust `reqwest` to Swift `URLSession`/`async-await`.

| Feature | Why Required | Complexity | Depends On |
|---------|-------------|------------|------------|
| **Authorize account** | Initial auth to get API URL and auth token | LOW | URLSession |
| **List file names** | Directory listing (with prefix/delimiter for virtual dirs) | LOW | Auth |
| **Get file info** | File metadata lookup by name | LOW | Auth |
| **Download file by name** | Read file content from B2 | MEDIUM | Auth, local caching |
| **Upload file** | Write file content to B2 (small files) | MEDIUM | Auth, get upload URL |
| **Delete file version** | Delete a specific file version | LOW | Auth |
| **Hide file** | Mark file as hidden (B2 versioning alternative to delete) | LOW | Auth |
| **Copy file** | Server-side copy (used for rename) | LOW | Auth |
| **Create folder marker** | Upload zero-byte file with trailing `/` for directory creation | LOW | Auth |
| **Auth token refresh** | Re-authorize when token expires (24h expiry) | LOW | Auth |

**Confidence:** HIGH — These are direct ports from the existing Rust implementation which is working.

### Differentiators — FSKit-Specific

| Feature | Value Proposition | Complexity | Depends On |
|---------|-------------------|------------|------------|
| **No macFUSE required** | Users don't need to install third-party kernel extensions or trust unsigned kexts | N/A | FSKit implementation |
| **Pure Swift architecture** | Single language, single process, no IPC overhead | N/A | FSKit + URLSession |
| **Sandboxed extension** | FSKit extensions run sandboxed (better security than FUSE) | LOW | Extension entitlements |
| **System-integrated mounting** | Volume appears in `/Volumes/` via proper system integration (eventually via Disk Arbitration) | MEDIUM | FSKit maturity |
| **Async/await everywhere** | FSKit operations are async; natural fit for network filesystem | N/A | Swift concurrency |

### Anti-Features — FSKit Things to NOT Build

| Anti-Feature | Why Tempting | Why Avoid | What to Do Instead |
|--------------|-------------|-----------|-------------------|
| **Extended attributes (xattr)** | Full POSIX compliance | macOS sends many xattr queries; each would hit B2 API; massive performance cost | Return empty/ENODATA for all xattr queries (same as v1.0) |
| **Symbolic links** | FSKit supports them | B2 has no concept of symlinks; would need to be emulated; adds complexity | Throw ENOSYS; document limitation |
| **Hard links** | FSKit supports them | B2 is object storage; hard links are meaningless | Throw ENOSYS; document limitation |
| **Directory rename** | Users expect it | B2 has no atomic rename; directory rename requires recursive copy+delete of all children; extremely expensive | Return ENOSYS (same as v1.0); document limitation |
| **Process attribution** | Know which process is accessing files | FSKit explicitly does not support this (confirmed by Apple engineer on Developer Forums, Feb 2025) | Not possible; don't attempt |
| **Kernel metadata caching** | FUSE has entry_timeout/attr_timeout for kernel-level caching | FSKit does not currently expose kernel caching APIs (confirmed by forum discussion, Jul 2025). Performance overhead ~100us per syscall | Implement userspace metadata cache (already have this from v1.0) |
| **Read-only mode flag** | Expose volume as read-only to Finder | FSKit read-only support is buggy; Finder still offers write operations even when mounted read-only (confirmed Dec 2025 forum post) | Not needed for CloudMount (we want read-write); avoid relying on this FSKit feature |
| **Programmatic mounting** | Mount from within the app via DiskArbitration | DiskArbitration + FSKit integration is incomplete; programmatic mounting with FSPathURLResource is unreliable (confirmed Aug 2025 forum) | Use `mount -F -t CloudMount` command; wrap in Process() call from app |

**Confidence:** HIGH for anti-features — These are confirmed by multiple Apple Developer Forums posts with Apple engineer responses.

## 2. macOS .app Distribution Features

### Table Stakes — DMG Distribution

Features users expect when downloading a macOS .app from GitHub Releases.

| Feature | Why Expected | Complexity | Depends On |
|---------|-------------|------------|------------|
| **Code-signed .app bundle** | Gatekeeper blocks unsigned apps; users get scary "damaged" warnings | MEDIUM | Apple Developer Account, signing certificate |
| **Notarized .app** | macOS 10.15+ requires notarization; without it, users must right-click > Open | MEDIUM | Code signing, `xcrun notarytool` |
| **.dmg disk image** | Standard macOS distribution format; users drag .app to /Applications | LOW | `hdiutil create` |
| **DMG with Applications symlink** | Visual hint to drag app into Applications folder | LOW | DMG creation script |
| **Universal binary (arm64 + x86_64)** | Support both Apple Silicon and Intel Macs | LOW | Xcode build settings (but FSKit is macOS 15.4+ so most users are arm64) |
| **Proper bundle identifier** | com.yourname.CloudMount format; required for code signing and Keychain | LOW | Info.plist |
| **App icon** | Looks professional in Finder, Dock, Launchpad | LOW | Asset catalog |
| **Version number in Info.plist** | Users can check About > Version; Homebrew/Sparkle need it | LOW | Build settings |
| **Min deployment target macOS 15.4** | FSKit requires Sequoia 15.4+; set in project | LOW | Xcode build settings |

**Confidence:** HIGH — Standard macOS distribution practices, well-documented.

### Table Stakes — First Launch Experience

| Feature | Why Expected | Complexity | Depends On |
|---------|-------------|------------|------------|
| **"Move to Applications?" dialog** | User downloads to ~/Downloads; should prompt to move to /Applications | LOW | Check bundle path on launch |
| **Enable FSKit extension prompt** | User must enable extension in System Settings; guide them there | MEDIUM | Detect extension state, show instructions |
| **Credential entry on first launch** | Obvious onboarding: enter B2 keys, configure bucket | LOW | Already built (v1.0 SettingsView) |
| **Graceful Gatekeeper handling** | If notarization fails or user has strict settings, provide clear instructions | LOW | Documentation/README |

### Differentiators — Distribution

| Feature | Value Proposition | Complexity | Depends On |
|---------|-------------------|------------|------------|
| **Sparkle auto-update** | Users get updates automatically without re-downloading DMG | MEDIUM | Sparkle framework, appcast hosting on GitHub |
| **Update notification in menu bar** | Status bar shows "Update available" badge | LOW | Sparkle integration |
| **GitHub Releases as update source** | No separate server needed; GitHub is the single source of truth | LOW | Sparkle appcast pointing to GitHub |

### Anti-Features — Distribution

| Anti-Feature | Why Tempting | Why Avoid | What to Do Instead |
|--------------|-------------|-----------|-------------------|
| **Mac App Store distribution** | Wider reach, auto-updates built in | FSKit extensions in App Store have update issues (unmounts volumes without warning during updates — confirmed Dec 2025 forum post); App Store review process adds friction for open-source project | Distribute via GitHub Releases + Homebrew Cask |
| **Installer .pkg** | Can install to /Applications automatically | Overkill for a simple .app; DMG drag-to-install is the macOS convention; pkg requires complex uninstall stanza in Homebrew | Use .dmg with Applications symlink |
| **Electron/web wrapper** | Cross-platform | Already have native SwiftUI; adds 200MB+ to app size | Keep pure Swift |
| **TestFlight for beta** | Easy beta distribution | Requires App Store Connect setup; FSKit has the same unmount-on-update issues | Use GitHub pre-releases for beta testing |

## 3. Homebrew Cask Features

### Table Stakes — Cask Formula

Features expected in a well-formed Homebrew Cask.

| Feature | Why Expected | Complexity | Depends On |
|---------|-------------|------------|------------|
| **`brew install --cask cloudmount`** | Standard install command users expect | LOW | Cask formula in tap |
| **Version tracking** | `brew upgrade` detects new versions | LOW | Version in cask matches GitHub Release tag |
| **SHA256 verification** | Homebrew verifies download integrity | LOW | Generate sha256 of .dmg |
| **Proper `app` stanza** | Moves .app to /Applications | LOW | .dmg contains .app at top level |
| **`zap` stanza** | Complete cleanup of user data on `brew zap` | LOW | List paths: ~/Library/Preferences, ~/Library/Application Support, Keychain items |
| **`depends_on macos:` constraint** | Prevent install on macOS < 15.4 | LOW | `depends_on macos: ">= :sequoia"` |
| **`livecheck` stanza** | Homebrew can detect new releases automatically | LOW | Point to GitHub releases page |
| **`homepage` and `desc`** | Required stanzas for searchability | LOW | Project metadata |
| **`caveats` for FSKit extension** | Inform user they must enable extension in System Settings | LOW | caveats block with instructions |

**Confidence:** HIGH — Verified against Homebrew Cask Cookbook documentation (fetched directly).

### Table Stakes — Cask User Experience

| Feature | Why Expected | Complexity | Depends On |
|---------|-------------|------------|------------|
| **Clean install flow** | `brew install --cask cloudmount` just works | LOW | Properly structured .dmg |
| **Clean upgrade flow** | `brew upgrade --cask cloudmount` replaces app cleanly | LOW | Version bumps in cask |
| **Clean uninstall** | `brew uninstall --cask cloudmount` removes app from /Applications | LOW | Standard `app` stanza handling |
| **No `sudo` required** | Homebrew operates without root for casks using `app` stanza | LOW | Don't use `pkg` stanza |
| **`auto_updates true`** | Tell Homebrew the app handles its own updates (if using Sparkle) | LOW | Sparkle integration |

### Differentiators — Homebrew Distribution

| Feature | Value Proposition | Complexity | Depends On |
|---------|-------------------|------------|------------|
| **Homebrew tap (own repo)** | Faster iteration than submitting to homebrew-cask core | LOW | Create `homebrew-cloudmount` repo |
| **Submit to homebrew-cask core** | Maximum discoverability; `brew search cloudmount` finds it | MEDIUM | Meet Homebrew quality requirements, 30+ GitHub stars |
| **Binary CLI companion** | `cloudmount mount mybucket` from terminal | MEDIUM | CLI tool in app bundle, `binary` stanza in cask |

### Anti-Features — Homebrew

| Anti-Feature | Why Tempting | Why Avoid | What to Do Instead |
|--------------|-------------|-----------|-------------------|
| **Formula instead of Cask** | Build from source | CloudMount is a .app not a CLI tool; formulae are for CLI tools | Use Cask |
| **Complex postflight scripts** | Auto-enable FSKit extension | Extension enablement is a security boundary; shouldn't be automated | Use `caveats` to tell user how to enable |
| **pkg installer via Homebrew** | More control over installation | Requires complex `uninstall` stanza; pkg is overkill for single .app | Distribute .dmg, use `app` stanza |

## 4. CI/CD Release Pipeline Features

### Table Stakes — GitHub Actions

| Feature | Why Expected | Complexity | Depends On |
|---------|-------------|------------|------------|
| **PR checks (build + test)** | Catch build failures before merge | MEDIUM | macOS runner, Xcode build |
| **Tag-triggered release builds** | Push `v2.0.0` tag → release appears on GitHub | MEDIUM | GitHub Actions workflow |
| **Code signing in CI** | .app must be signed for distribution | HIGH | Certificate + provisioning profile as secrets |
| **Notarization in CI** | Notarize as part of release pipeline | HIGH | App-specific password, `xcrun notarytool` |
| **DMG creation in CI** | Produce distributable artifact automatically | MEDIUM | `hdiutil` + `create-dmg` tool |
| **GitHub Release creation** | Upload .dmg to GitHub Releases with changelog | LOW | `gh release create` or `softprops/action-gh-release` |
| **Xcode version pinning** | Reproducible builds | LOW | `xcode-select` in workflow |

### Differentiators — CI/CD

| Feature | Value Proposition | Complexity | Depends On |
|---------|-------------------|------------|------------|
| **Automated Homebrew Cask bump** | After release, auto-PR to update cask formula with new version + sha256 | MEDIUM | Script to compute sha256 and update cask |
| **Sparkle appcast generation** | Auto-generate appcast.xml from GitHub Release | MEDIUM | Sparkle `generate_appcast` tool in CI |
| **Release notes from git log** | Auto-populate release notes from conventional commits | LOW | `git log --oneline` formatting |

### Anti-Features — CI/CD

| Anti-Feature | Why Tempting | Why Avoid | What to Do Instead |
|--------------|-------------|-----------|-------------------|
| **Xcode Cloud** | Apple's native CI | Less flexible than GitHub Actions; harder to debug; lock-in | Use GitHub Actions with macOS runners |
| **Self-hosted runners** | Faster builds, no queue | Maintenance burden; security risk with signing certs | Use GitHub-hosted macOS runners |
| **Building from Xcode project** | Xcode is the "right" way | Swift Package Manager builds are simpler for CI; but FSKit extension requires Xcode project | Use `xcodebuild` in GitHub Actions |

## 5. Feature Dependencies (v2.0)

```
[FSKit Extension Setup]
    ├── requires → [Xcode Project Migration] (SPM → Xcode workspace for extension target)
    ├── requires → [FSUnaryFileSystem subclass]
    ├── requires → [FSVolume + Operations]
    │                 ├── requires → [FSItem subclass]
    │                 ├── requires → [Swift B2 API Client]
    │                 │                 └── requires → [URLSession + async/await]
    │                 ├── requires → [Metadata Cache] (port from Rust moka → Swift Dictionary+timer)
    │                 └── requires → [Local File Cache] (port from Rust tempfile → Swift FileManager)
    └── requires → [Extension Entitlements + Info.plist]

[macOS Distribution]
    ├── requires → [Code Signing] (Apple Developer certificate)
    ├── requires → [Notarization] (xcrun notarytool)
    ├── requires → [DMG Creation] (hdiutil)
    └── optional → [Sparkle Auto-Update]
                      └── requires → [EdDSA keys, appcast.xml on GitHub]

[Homebrew Cask]
    ├── requires → [DMG on GitHub Releases]
    ├── requires → [Cask formula in tap]
    └── requires → [SHA256 of .dmg]

[CI/CD Pipeline]
    ├── requires → [GitHub Actions macOS runner]
    ├── requires → [Code signing secrets in GitHub]
    ├── requires → [Notarization secrets in GitHub]
    └── optional → [Automated cask bump script]
```

## 6. Porting Map: v1.0 FUSE → v2.0 FSKit

Critical context: every v1.0 FUSE operation maps to an FSKit equivalent. This is NOT a greenfield build — it's a port.

| v1.0 Rust FUSE (`impl Filesystem`) | v2.0 Swift FSKit | Porting Notes |
|-------------------------------------|-------------------|---------------|
| `getattr` → `ReplyAttr` | `attributes(_:of:)` → `FSItem.Attributes` | Return FSItem.Attributes instead of FileAttr |
| `lookup` → `ReplyEntry` | `lookupItem(named:inDirectory:)` → `(FSItem, FSFileName)` | Return FSItem tuple instead of reply with entry |
| `readdir` → `ReplyDirectory` | `enumerateDirectory(_:startingAt:verifier:attributes:packer:)` | Use FSDirectoryEntryPacker instead of reply.add() |
| `opendir` / `releasedir` | Handled by FSKit automatically | No explicit implementation needed |
| `open` → `ReplyOpen` | `openItem(_:modes:)` | FSKit tracks open state; return void |
| `release` → upload on close | `closeItem(_:modes:)` → upload dirty files | Same write-on-close strategy |
| `read` → `ReplyData` | `read(from:at:length:into:)` → `Int` | Write into FSMutableFileDataBuffer |
| `write` → `ReplyWrite` | `write(contents:to:at:)` → `Int` | Receive Data instead of &[u8] |
| `create` → `ReplyCreate` | `createItem(named:type:inDirectory:attributes:)` | Return FSItem instead of ReplyCreate |
| `unlink` → `ReplyEmpty` | `removeItem(_:named:fromDirectory:)` | Throws instead of reply.error() |
| `rmdir` → `ReplyEmpty` | `removeItem(_:named:fromDirectory:)` | Same as unlink in FSKit (unified) |
| `mkdir` → `ReplyEntry` | `createItem(named:type:.directory:...)` | Type parameter distinguishes file/dir |
| `rename` → `ReplyEmpty` | `renameItem(_:inDirectory:named:to:inDirectory:overItem:)` | Still copy+delete under the hood |
| `setattr` → `ReplyAttr` | `setAttributes(_:on:)` | FSItem.SetAttributesRequest replaces Option params |
| `flush` / `fsync` → `ReplyEmpty` | `synchronize(flags:)` | Called for volume-wide sync |
| `statfs` → `ReplyStatfs` | `volumeStatistics` (computed property) | Return FSStatFSResult |
| `getxattr` / `listxattr` → suppress | Not implemented (throw ENODATA) | Same suppression strategy as v1.0 |

## 7. MVP Recommendation for v2.0

### Must Ship (Phase 1 — FSKit Core)

1. FSKit extension with all FSVolume.Operations (lookup, enumerate, create, remove, rename)
2. FSVolume.ReadWriteOperations (read, write with local caching)
3. FSVolume.OpenCloseOperations (open, close with write-on-close upload)
4. Swift B2 API client (port all endpoints from Rust)
5. Metadata cache (port from moka to Swift in-memory cache)
6. Local file cache for downloads (port from Rust tempfile to Swift)
7. macOS metadata suppression (port suppression list from v1.0)

### Must Ship (Phase 2 — Distribution)

1. Code-signed .app bundle
2. Notarized .app
3. .dmg with Applications symlink
4. GitHub Release with .dmg artifact
5. Homebrew Cask formula in own tap

### Must Ship (Phase 3 — CI/CD)

1. GitHub Actions PR check (build + test)
2. Tag-triggered release workflow (build → sign → notarize → dmg → release)
3. Automated SHA256 computation for Cask

### Defer to Post-v2.0

- Sparkle auto-update (add after manual distribution is stable)
- Submit to homebrew-cask core (need traction/stars first)
- Binary CLI companion
- Multi-bucket support (was planned for v1.1, still deferred)
- Auto-mount on startup

## 8. Known FSKit Risks & Open Questions

Issues discovered during research that affect feature planning:

| Risk | Source | Impact | Mitigation |
|------|--------|--------|------------|
| **`removeItem` not being called** | Apple Developer Forums (Nov 2025, Dec 2025) — two separate reports | File deletion may silently fail | May be an FSKit bug; test thoroughly on target macOS version; file FB if needed |
| **Volume mounting requires `mount -F` command** | KhaosT/FSKitSample README, multiple forum posts | No clean programmatic mount from SwiftUI app | Wrap `mount -F -t CloudMount` in `Process()` call; provide UX guidance |
| **Extension must be manually enabled** | System Settings > Login Items & Extensions > File System Extensions | First-launch friction; users may not know how | Build onboarding flow that detects extension state and links to System Settings |
| **FSKit sandbox restrictions** | Forum post (Apr 2025) — extension can't access external files | May limit file caching paths | Use app container paths; test cache directory access |
| **Performance overhead ~100us per syscall** | Forum post (Jul 2025) with benchmarks | Slower than FUSE for high-throughput operations | Acceptable for cloud storage (network latency dominates); optimize metadata caching |
| **No kernel-level caching** | Forum post (Jul 2025) — confirmed no kernel cache APIs | Every operation goes through userspace | Implement aggressive userspace caching (already have this pattern from v1.0) |
| **App updates unmount volumes** | Forum post (Dec 2025) — volumes unmount without warning during app updates | Data loss risk if writing during update | Don't auto-update while mounted; warn user |
| **FSKit is macOS 15.4+ only** | Apple documentation | Limits user base to Sequoia users | Acceptable trade-off; document minimum macOS requirement |

**Confidence:** HIGH for risks — These are from developers actively building FSKit extensions and reporting issues on Apple Developer Forums with specific macOS version numbers.

## Sources

### HIGH Confidence
- KhaosT/FSKitSample GitHub repository (FSKit sample code): https://github.com/KhaosT/FSKitSample
- Apple Developer Forums FSKit tag (23 posts, multiple Apple engineer responses): https://forums.developer.apple.com/forums/tags/fskit
- Homebrew Cask Cookbook (official documentation): https://docs.brew.sh/Cask-Cookbook
- Sparkle documentation (Context7): https://sparkle-project.org/documentation/
- Existing v1.0 CloudMount source code (Rust FUSE implementation)

### MEDIUM Confidence
- Apple FSKit documentation (could not render JS-only pages; protocol names inferred from sample code)
- Apple Developer Forums individual posts (community reports, not official Apple docs)

### LOW Confidence
- FSKit performance characteristics (single benchmark from one developer)
- FSKit kernel caching roadmap (no official Apple statement on plans)

---
*Feature research for: CloudMount v2.0 — FSKit Pivot & Distribution*
*Researched: February 5, 2026*
