# Technology Stack: CloudMount v2.0 — FSKit Pivot & Distribution

**Domain:** Native macOS filesystem extension with cloud storage backend
**Researched:** 2026-02-05
**Confidence:** HIGH (FSKit API verified from local SDK headers, Xcode 26.2 / macOS 26.1)

## Executive Summary

The v2.0 pivot replaces the entire Rust layer (fuser + reqwest + tokio + moka) with pure Swift using Apple's FSKit framework. The critical finding is that FSKit ships two resource types: `FSBlockDeviceResource` (V1, macOS 15.4+) for disk-based filesystems, and `FSGenericURLResource` (V2, macOS 26+) for URL/network-based filesystems. Since CloudMount is a network filesystem backed by Backblaze B2 URLs, **the project should target `FSGenericURLResource` on macOS 26+** rather than trying to shoehorn a network filesystem into the block device model.

This also means the minimum deployment target changes from macOS 14 to macOS 26 (Tahoe). This is a reasonable tradeoff: FSKit V2 is purpose-built for this exact use case, and macOS 26 is the current release.

## Recommended Stack

### Core Framework — FSKit

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| FSKit | V2 (macOS 26+) | User-space filesystem framework | Apple's native replacement for FUSE. Eliminates macFUSE dependency entirely. V2 adds `FSGenericURLResource` for URL-based/network filesystems — exactly what CloudMount needs. Runs as an app extension within the app bundle. |
| `FSUnaryFileSystem` | V1+ | Base filesystem class | Simplified single-volume filesystem model. Subclass this and implement `FSUnaryFileSystemOperations` protocol (probe, load, unload). |
| `FSGenericURLResource` | V2 (macOS 26+) | URL-based resource | Network filesystem resource. Accepts arbitrary URL schemes. CloudMount registers a custom `b2://` scheme. This is the **critical piece** that makes FSKit viable for cloud storage without block device emulation. |
| `FSVolume` subclass | V1+ | Volume implementation | Subclass `FSVolume` and conform to `FSVolume.Operations`, `FSVolume.PathConfOperations`, `FSVolume.ReadWriteOperations`, `FSVolume.OpenCloseOperations`. This is where all filesystem logic lives. |

**Confidence:** HIGH — Verified from SDK headers at `/Applications/Xcode.app/.../FSKit.framework/Versions/A/Headers/`. `FSKIT_API_AVAILABILITY_V1` = `API_AVAILABLE(macos(15.4))`, `FSKIT_API_AVAILABILITY_V2` = `API_AVAILABLE(macos(26.0))`.

### FSKit Protocols to Implement

The following protocols define the filesystem's capabilities. All are from `FSVolume.h`:

| Protocol | Required? | Purpose | Notes |
|----------|-----------|---------|-------|
| `FSUnaryFileSystemOperations` | **Yes** | Probe, load, unload resource | Core lifecycle. Entry point for the filesystem extension. |
| `FSVolume.Operations` (extends `FSVolume.PathConfOperations`) | **Yes** | Mount, unmount, activate, deactivate, lookup, create, remove, rename, enumerate, get/set attributes, readSymbolicLink, createSymbolicLink, createLink, reclaimItem, synchronize | The primary filesystem operations protocol. ~15 required methods. |
| `FSVolume.PathConfOperations` | **Yes** (via Operations) | maximumLinkCount, maximumNameLength, etc. | Filesystem limits. |
| `FSVolume.ReadWriteOperations` | **Yes** | read(from:at:length:into:), write(contents:to:at:) | Data I/O via extension process (not kernel offloaded). Appropriate for network filesystems where data flows through the extension. |
| `FSVolume.OpenCloseOperations` | Recommended | openItem, closeItem | Enables tracking open file handles for write-on-close strategy. |
| `FSVolume.XattrOperations` | Optional | Extended attributes | Can inhibit if not needed. CloudMount should implement limited xattrs to support Finder metadata. |
| `FSVolume.AccessCheckOperations` | Optional | Access control | Can inhibit. Default POSIX checks sufficient. |
| `FSVolume.RenameOperations` | No | Volume renaming | Not applicable — volume name is the bucket name. |
| `FSVolume.PreallocateOperations` | No | Space preallocation | Not applicable — cloud storage has no block allocation. |

### HTTP Client — URLSession

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `URLSession` | Foundation (built-in) | HTTP client for B2 API | Zero dependencies. Native async/await support. Automatic HTTP/2, connection pooling, background session support. Replaces Rust `reqwest`. |
| Swift `async`/`await` | Swift 6+ | Concurrency model | Natural fit for FSKit callback-based API (methods bridge to async). Structured concurrency with `Task`, `TaskGroup` for parallel operations. |

**Do NOT add:**
- **Alamofire**: URLSession is sufficient for B2's REST API. Alamofire adds complexity without meaningful benefit for server-to-server HTTP calls.
- **AsyncHTTPClient (SwiftNIO)**: Server-side library. URLSession is the right choice for a macOS app.
- **Any third-party Swift B2 client**: None exist with quality/maintenance worth depending on. B2's API is simple enough for direct URLSession calls.

### Caching

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `NSCache` | Foundation (built-in) | In-memory metadata cache | Replaces Rust `moka::sync::Cache`. Thread-safe, automatic eviction under memory pressure. No dependencies. |
| `FileManager` + temp directory | Foundation (built-in) | Read cache for file data | Cache downloaded file data on disk to avoid re-fetching. Use `NSTemporaryDirectory()` with LRU eviction logic. |

### Existing Stack (Retained)

| Technology | Version | Purpose | Status |
|------------|---------|---------|--------|
| SwiftUI | macOS 26+ | Menu bar app UI | **Keep** — Already validated. |
| KeychainAccess | 4.2.2 | Credential storage | **Keep** — Already integrated in Package.swift. |
| JSON file persistence | N/A | Bucket config storage | **Keep** — Simple, works. |

### What Gets Removed

| Technology | Reason for Removal |
|------------|-------------------|
| Rust daemon (fuser 0.16) | Replaced by FSKit extension |
| reqwest (Rust HTTP) | Replaced by URLSession |
| moka (Rust cache) | Replaced by NSCache |
| tokio (Rust async) | Replaced by Swift async/await |
| serde/serde_json (Rust) | Replaced by Swift Codable |
| Unix domain socket IPC | Eliminated — single-process architecture |
| macFUSE dependency | Eliminated — FSKit is built into macOS |
| Entire Cargo.toml | No more Rust |

## App Packaging & Distribution

### Build System — Xcode Project Required

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Xcode project (.xcodeproj) | Xcode 26+ | Build system | **Swift Package Manager cannot build FSKit extensions.** App extensions require an Xcode project with proper target configuration, entitlements, provisioning profiles, and Info.plist for both the host app and the extension. Migrate from `Package.swift` to `.xcodeproj`. |
| Swift Package Manager | 5.9+ | Dependency management only | Keep using SPM for third-party dependencies (KeychainAccess). Add as package dependency in Xcode project, not as the build system. |

**Why Xcode project, not Package.swift?** FSKit extensions are app extensions (like Notification Service Extensions or File Provider Extensions). They require:
1. A separate extension target with its own bundle identifier
2. An `NSExtension` dictionary in the extension's `Info.plist`
3. `EXAppExtensionAttributes` with `FSPersonalities`, `FSShortName`, `FSSupportedSchemes`
4. Code signing with provisioning profiles for both app and extension
5. The extension embedded in the app bundle at `CloudMount.app/Contents/Extensions/CloudMountFS.appex`

None of this is expressible in `Package.swift`.

### App Bundle Structure

```
CloudMount.app/
├── Contents/
│   ├── Info.plist                    (host app)
│   ├── MacOS/
│   │   └── CloudMount                (main executable)
│   ├── Resources/
│   │   └── Assets.car
│   ├── Extensions/
│   │   └── CloudMountFS.appex/       (FSKit extension)
│   │       ├── Contents/
│   │       │   ├── Info.plist        (extension with FSKit config)
│   │       │   ├── MacOS/
│   │       │   │   └── CloudMountFS  (extension executable)
│   │       │   └── Resources/
│   ├── Frameworks/                    (if needed for shared code)
│   └── _CodeSignature/
```

### Extension Info.plist Keys

The FSKit extension's `Info.plist` must include (from SDK documentation in `FSResource.h`):

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.fskit.filesystem</string>
    <key>NSExtensionPrincipalClass</key>
    <string>CloudMountFS.CloudMountFileSystem</string>
    <key>EXAppExtensionAttributes</key>
    <dict>
        <key>FSShortName</key>
        <string>cloudmount</string>
        <key>FSSupportedSchemes</key>
        <array>
            <string>b2</string>
        </array>
        <key>FSPersonalities</key>
        <dict>
            <key>CloudMount_B2</key>
            <dict>
                <key>FSPersistentIdentifierBasis</key>
                <string>resource-dependent</string>
            </dict>
        </dict>
    </dict>
</dict>
```

### Code Signing & Notarization

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Developer ID Application certificate | N/A | Code signing for outside App Store | Required for notarization. Developer already has Apple Developer account. Sign both the host app and the FSKit extension. |
| `codesign` | Built-in | Code sign binaries | Sign with `--options runtime` for hardened runtime (required for notarization). |
| `notarytool` | Xcode 26+ | Submit for notarization | Replaces deprecated `altool`. Use `xcrun notarytool submit --wait`. Store credentials with `xcrun notarytool store-credentials`. |
| Hardened Runtime | N/A | Security requirement | **Required** for notarization. Enable in Xcode target settings. May need entitlements for network access. |

**Notarization flow (verified from Apple developer docs):**
```bash
# 1. Archive and export
xcodebuild archive -scheme CloudMount -archivePath build/CloudMount.xcarchive
xcodebuild -exportArchive -archivePath build/CloudMount.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist

# 2. Create ZIP for notarization
ditto -c -k --keepParent "build/export/CloudMount.app" "build/CloudMount.zip"

# 3. Submit
xcrun notarytool submit build/CloudMount.zip \
  --keychain-profile "notarytool-password" --wait

# 4. Staple
xcrun stapler staple "build/export/CloudMount.app"
```

### DMG Creation

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| create-dmg | 1.2.3 | Create fancy DMG installer | Shell script, 2.5k GitHub stars, MIT license. Supports background images, icon positioning, Applications drop link. Install via `brew install create-dmg`. Latest release Nov 2025. |

**Usage:**
```bash
create-dmg \
  --volname "CloudMount" \
  --volicon "icon.icns" \
  --background "dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "CloudMount.app" 180 190 \
  --hide-extension "CloudMount.app" \
  --app-drop-link 480 190 \
  "CloudMount.dmg" \
  "build/export/"
```

### Homebrew Cask Distribution

| Technology | Purpose | Notes |
|------------|---------|-------|
| Homebrew Cask | `brew install --cask cloudmount` | Submit to homebrew-cask tap. Requires notarized `.dmg` hosted on GitHub Releases. |

**Cask formula** (to submit to `homebrew/homebrew-cask`):
```ruby
cask "cloudmount" do
  version "2.0.0"
  sha256 "abc123..."

  url "https://github.com/OWNER/cloudmount/releases/download/v#{version}/CloudMount-#{version}.dmg"
  name "CloudMount"
  desc "Mount Backblaze B2 buckets as local volumes"
  homepage "https://github.com/OWNER/cloudmount"

  depends_on macos: ">= :tahoe"   # macOS 26+ for FSKit V2

  app "CloudMount.app"

  zap trash: [
    "~/Library/Application Support/CloudMount",
    "~/Library/Preferences/com.cloudmount.app.plist",
  ]
end
```

**Key requirement:** `depends_on macos: ">= :tahoe"` because FSKit `FSGenericURLResource` requires macOS 26.

## CI/CD — GitHub Actions

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| GitHub Actions | N/A | CI/CD pipeline | Free for open-source repos. Native macOS runners available. |
| `macos-latest` runner | macOS 15+ (arm64) | Build environment | Apple Silicon runners. Use `macos-15` or later for Xcode 26 support. May need `macos-26` runner when available. |
| `actions/checkout@v5` | v5 | Repository checkout | Standard. |
| `softprops/action-gh-release` | latest | Create GitHub releases | Upload DMG as release asset on tag push. |

**Workflow structure:**

1. **PR Check** (`on: pull_request`): Build + test (no signing)
2. **Release** (`on: push tags v*`): Build → sign → notarize → create DMG → upload to GitHub Release → update Homebrew Cask

**Code signing in CI** (verified from GitHub Actions docs):
```yaml
- name: Install certificate
  env:
    BUILD_CERTIFICATE_BASE64: ${{ secrets.BUILD_CERTIFICATE_BASE64 }}
    P12_PASSWORD: ${{ secrets.P12_PASSWORD }}
    KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
  run: |
    CERTIFICATE_PATH=$RUNNER_TEMP/build_certificate.p12
    KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db
    echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o $CERTIFICATE_PATH
    security create-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
    security set-keychain-settings -lut 21600 $KEYCHAIN_PATH
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
    security import $CERTIFICATE_PATH -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k $KEYCHAIN_PATH
    security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
    security list-keychain -d user -s $KEYCHAIN_PATH
```

**Secrets required:**
- `BUILD_CERTIFICATE_BASE64` — Developer ID Application certificate (.p12), base64-encoded
- `P12_PASSWORD` — Password for the .p12 file
- `KEYCHAIN_PASSWORD` — Arbitrary password for the temporary keychain
- `APPLE_ID` — Apple ID for notarization
- `APPLE_TEAM_ID` — Developer Team ID
- `NOTARIZATION_PASSWORD` — App-specific password for notarization

**Runner concern:** GitHub's `macos-latest` currently maps to macOS 15. Building for macOS 26 SDK requires Xcode 26, which may not be available on GitHub-hosted runners yet (as of Feb 2026). **Fallback:** Use a self-hosted runner or Xcode Cloud until GitHub updates their macOS runner images.

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Filesystem framework | FSKit V2 | macFUSE 5.x + fuser | macFUSE requires third-party kernel extension or user enables it. FSKit is built-in, no user setup. FSKit V2's `FSGenericURLResource` is purpose-built for network filesystems. |
| Filesystem framework | FSKit V2 | FileProvider (NSFileProviderReplicatedExtension) | FileProvider is for iCloud-style syncing, not mounting volumes. Doesn't appear as a mounted volume in Finder sidebar. Wrong abstraction for "mount bucket as drive." |
| FSKit resource type | `FSGenericURLResource` (V2) | `FSBlockDeviceResource` (V1) | Block device resource requires emulating a block device for a network filesystem — wrong abstraction. Would need a RAM disk or sparse image as intermediary. Fragile and wasteful. |
| Deployment target | macOS 26 (Tahoe) | macOS 15.4 (Sequoia) | macOS 15.4 only has `FSBlockDeviceResource`. `FSGenericURLResource` for URL/network filesystems requires V2 (macOS 26). The cost of supporting 15.4 is massive architectural complexity. |
| HTTP client | URLSession | swift-http-client, Alamofire | URLSession is built-in, async/await native, zero dependencies. B2's API is simple REST — no need for a wrapper library. |
| Build system | Xcode project | Swift Package Manager | SPM cannot build app extensions. FSKit extensions require Xcode project targets with Info.plist, entitlements, and embedded extension bundles. |
| DMG tool | create-dmg | hdiutil directly | create-dmg wraps hdiutil with nice defaults (background image, icon positioning, Applications shortcut). Saves boilerplate. |
| CI/CD | GitHub Actions | Xcode Cloud | GitHub Actions is free for open-source, more flexible, supports custom scripts. Xcode Cloud has limitations with non-App Store distribution. |

## What NOT to Add

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| SwiftNIO / async-http-client | Server-side networking stack. Massive dependency for a simple REST client. | URLSession (built-in) |
| Alamofire | Abstraction over URLSession that adds no value for B2's simple API. Adds dependency. | URLSession (built-in) |
| GRDB / SQLite | Over-engineered for metadata caching. | NSCache (in-memory) + JSON files |
| Swift Crypto | Not needed. URLSession handles HTTPS. B2 auth is via API tokens, not custom crypto. | Foundation (built-in) |
| Combine | Legacy reactive framework. Swift concurrency (async/await) supersedes it for new code. | Swift async/await |
| Any Rust code | The entire point of v2.0 is eliminating the Rust layer. | Pure Swift |
| macFUSE | The entire point of v2.0 is eliminating this dependency. | FSKit |
| CocoaPods / Carthage | SPM is the standard. Xcode has native SPM integration. | Swift Package Manager (for deps) |

## Version Compatibility Matrix

| Component | Minimum | Recommended | Notes |
|-----------|---------|-------------|-------|
| macOS | 26.0 (Tahoe) | 26.0+ | Required for FSKit V2 (`FSGenericURLResource`) |
| Xcode | 26.0 | 26.2+ | Required for macOS 26 SDK with FSKit V2 |
| Swift | 6.0 | 6.0+ | Ships with Xcode 26 |
| Swift tools version | 5.9+ | 6.0 | For Package.swift (SPM dependencies only) |
| KeychainAccess | 4.2.2 | 4.2.2 | Already pinned, no change needed |

## Migration Path: Package.swift → Xcode Project

The current project uses `Package.swift` as the build system. The migration to Xcode project should:

1. **Create new Xcode project** with two targets:
   - `CloudMount` (macOS App) — host app with menu bar UI
   - `CloudMountFS` (FSKit Extension) — filesystem extension
2. **Add SPM dependency** for KeychainAccess in Xcode project settings
3. **Move existing Swift files** into the app target
4. **Create shared framework** (optional) for code shared between app and extension (e.g., B2 API client, config models)
5. **Configure signing** for both targets with the same team
6. **Remove** `Package.swift`, `Cargo.toml`, `Cargo.lock`, and all Rust source files

## Critical Architecture Note: FSKit Extension Lifecycle

FSKit extensions run **out-of-process** from the host app. The extension is a separate binary that the system's `fskitd` daemon manages. Key implications:

- The **host app** (menu bar UI) and the **extension** (filesystem) are separate processes
- They share the same app bundle but have separate address spaces
- Communication between app and extension uses **`FSClient`** API, NOT direct function calls
- The extension is activated by the system when a filesystem operation is requested
- This is similar to how File Provider extensions work

This means:
- Shared code (B2 API client, config models) should live in a **shared framework** target
- The app uses `FSClient.shared` to discover and interact with the extension
- State synchronization between app and extension needs explicit design (App Groups, UserDefaults suite, etc.)

## Sources

- **FSKit headers** — `/Applications/Xcode.app/.../FSKit.framework/Versions/A/Headers/` — Direct SDK inspection on Xcode 26.2, macOS 26.1. **HIGH confidence.**
- **FSKit availability macros** — `FSKitDefines.h`: V1 = `macos(15.4)`, V2 = `macos(26.0)`. **HIGH confidence.**
- **`FSGenericURLResource`** — `FSResource.h` line 389: `FSKIT_API_AVAILABILITY_V2`. Supports custom URL schemes via `FSSupportedSchemes`. **HIGH confidence.**
- **`FSUnaryFileSystem`** — `FSUnaryFileSystem.h`: Simplified single-volume model with probe/load/unload. **HIGH confidence.**
- **`FSVolume.Operations`** — `FSVolume.h`: ~15 required methods for full filesystem. **HIGH confidence.**
- **Notarization workflow** — Apple Developer Documentation via Context7 (`/websites/developer_apple`): notarytool, codesign, hardened runtime requirements. **HIGH confidence.**
- **GitHub Actions macOS signing** — GitHub Actions docs via Context7 (`/websites/github_en_actions`): Certificate import, keychain setup, provisioning profiles. **HIGH confidence.**
- **create-dmg** — GitHub repo (https://github.com/create-dmg/create-dmg): v1.2.3, MIT license, 2.5k stars. **HIGH confidence.**
- **Homebrew Cask cookbook** — Official Homebrew docs (https://docs.brew.sh/Cask-Cookbook): Cask format, depends_on, stanza order. **HIGH confidence.**

---
*Stack research for: CloudMount v2.0 — FSKit Pivot & Distribution*
*Researched: 2026-02-05*
*Supersedes: v1.0 stack research (2026-02-02)*
