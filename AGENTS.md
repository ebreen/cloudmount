# AGENTS.md -- AI Agent Context for CloudMount

This file contains critical context for AI coding agents working on the CloudMount codebase. Read this before making changes.

## Project Overview

CloudMount is a native macOS 26+ menu bar app that mounts Backblaze B2 buckets as local Finder volumes using Apple's FSKit framework. Pure Swift, no FUSE, no Rust, no Electron.

- **Owner**: Eirik Breen ([ebreen](https://github.com/ebreen))
- **Repo**: `ebreen/cloudmount`
- **License**: MIT
- **Apple Team ID**: `66X2XJM3HW`

## Architecture

Three-target XcodeGen project (`project.yml` generates `CloudMount.xcodeproj`):

| Target | Type | Bundle ID | Purpose |
|--------|------|-----------|---------|
| CloudMount | application | com.cloudmount.app | SwiftUI menu bar app (LSUIElement) |
| CloudMountExtension | extensionkit-extension | com.cloudmount.app.extension | FSKit filesystem extension (XPC) |
| CloudMountKit | framework | com.cloudmount.kit | Shared code: B2 API client, caching, credentials |

The extension runs as an XPC service managed by macOS. When a user mounts a `b2://` URL, the kernel routes filesystem operations to the extension. The main app manages accounts, settings, and mount/unmount via `Process` calls to `mount`/`diskutil`.

### Key technical details

- **Swift 6.0** with strict concurrency (actors, Sendable, @MainActor)
- **macOS 26.0** (Tahoe) minimum -- FSKit is new in macOS 26
- **Hardened Runtime** enabled globally (`ENABLE_HARDENED_RUNTIME: true`)
- **Sparkle** for auto-updates (only external dependency)
- **Backblaze B2 Native API v4** (not S3-compatible API)

## Critical: FSKit Extension Configuration

The FSKit extension MUST use the correct product type or it will silently break.

### What goes wrong

If `type: app-extension` is used in project.yml, Xcode generates `com.apple.product-type.app-extension`, which triggers legacy `NSExtension` plist processing. This **strips all FSKit keys** (`FSSupportedSchemes`, `FSShortName`, `FSPersonalities`, etc.) and rewrites the principal class name incorrectly. The extension will build and install but macOS will never route `b2://` URLs to it.

### What is correct

```yaml
CloudMountExtension:
  type: extensionkit-extension     # NOT app-extension
  settings:
    base:
      GENERATE_INFOPLIST_FILE: true  # NOT false -- required for EXAppExtensionAttributes preservation
```

This produces `com.apple.product-type.extensionkit-extension`, which preserves `EXAppExtensionAttributes` and all `FS*` keys in the built plist.

### How to verify

After building, inspect the built extension plist:

```bash
cat build/DerivedData/Build/Products/Debug/CloudMount.app/Contents/Extensions/CloudMountExtension.appex/Contents/Info.plist
```

It MUST contain:
- `EXAppExtensionAttributes` (NOT `NSExtension`)
- `EXExtensionPointIdentifier` = `com.apple.fskit.fsmodule`
- `EXExtensionPrincipalClass` = `CloudMountExtension.CloudMountExtensionMain`
- `FSSupportedSchemes` = `["b2"]`
- `FSShortName` = `b2`

The extension lives at `Contents/Extensions/` (not `Contents/PlugIns/`).

### Enabling the extension

After installing CloudMount, users must manually enable the FSKit extension:
System Settings -> General -> Login Items & Extensions -> File System Extensions -> CloudMount

The app has an `ExtensionDetector` that uses a dry-run mount probe (`mount -d -F -t b2 b2://probe /tmp/cloudmount-probe`) to detect enablement status and shows an onboarding flow if needed.

## Code Signing & Certificates

### Two certificates required

| Certificate | Type | Used By | GitHub Secret |
|-------------|------|---------|---------------|
| Apple Development: breeneirik@gmail.com | Development | Archive (automatic signing via cloud) | `DEV_CERTIFICATE_BASE64` |
| Developer ID Application: EIRIK BREEN (66X2XJM3HW) | Distribution | Export (manual signing for developer-id) | `BUILD_CERTIFICATE_BASE64` |

Both are imported into the same temporary keychain during CI. The archive step uses automatic/cloud signing with the Apple Development cert. The export step uses manual signing with the Developer ID Application cert.

### Why two certs?

- The archive uses `CODE_SIGN_STYLE: Automatic` (from project.yml) with `-allowProvisioningUpdates` and App Store Connect API key authentication. This triggers Apple's cloud signing service, which needs an Apple Development cert in the keychain.
- The export uses `method: developer-id` with `signingStyle: manual`. This re-signs the archive locally for distribution outside the App Store, requiring the Developer ID Application cert.
- Cloud signing for Developer ID export fails because the team doesn't have API permission to auto-create Developer ID provisioning profiles.

### Provisioning profiles

Two manually-created Developer ID provisioning profiles:

| Profile Name | Bundle ID | GitHub Secret |
|---|---|---|
| CloudMount Developer ID | com.cloudmount.app | `APP_PROVISION_PROFILE_BASE64` |
| CloudMount Extension Developer ID | com.cloudmount.app.extension | `EXT_PROVISION_PROFILE_BASE64` |

These are installed to `~/Library/MobileDevice/Provisioning Profiles/` during CI.

### Entitlements

**Main app** (not sandboxed):
- `keychain-access-groups`: `$(AppIdentifierPrefix)com.cloudmount.shared`
- `com.apple.security.application-groups`: `$(TeamIdentifierPrefix)com.cloudmount.app`

**Extension** (sandboxed):
- `com.apple.developer.fskit.fsmodule`: true
- `com.apple.security.app-sandbox`: true
- `com.apple.security.network.client`: true (outbound for B2 API)
- `keychain-access-groups`: same shared group
- `com.apple.security.application-groups`: same shared group

The shared keychain group and app group allow the main app to store credentials and mount configs that the extension reads.

## GitHub Secrets (12 total)

| Secret | Purpose |
|--------|---------|
| `DEV_CERTIFICATE_BASE64` | Apple Development cert .p12 (base64) |
| `DEV_P12_PASSWORD` | Password for dev cert .p12 |
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application cert .p12 (base64) |
| `P12_PASSWORD` | Password for Developer ID .p12 |
| `KEYCHAIN_PASSWORD` | Temp CI keychain password (arbitrary) |
| `APPLE_TEAM_ID` | `66X2XJM3HW` |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: EIRIK BREEN (66X2XJM3HW)` |
| `APP_STORE_CONNECT_KEY_BASE64` | App Store Connect API key .p8 (base64) |
| `API_KEY_ID` | `3C7HQ8Q9L9` |
| `API_ISSUER_ID` | App Store Connect API Issuer ID |
| `APP_PROVISION_PROFILE_BASE64` | App provisioning profile (base64) |
| `EXT_PROVISION_PROFILE_BASE64` | Extension provisioning profile (base64) |
| `TAP_GITHUB_TOKEN` | PAT with push to `ebreen/homebrew-cloudmount` |

## Release Pipeline

Triggered by pushing a tag matching `v[0-9]+.[0-9]+.[0-9]+`.

### Job 1: `build-sign-notarize` (macos-26)

1. Install tools (`create-dmg`, `xcodegen`)
2. Import both certificates into temporary keychain
3. Install provisioning profiles
4. `xcodegen generate`
5. Set version in Info.plist from tag (CFBundleShortVersionString = tag, CFBundleVersion = github.run_number)
6. Archive with automatic signing + API key auth
7. Export with `method: developer-id`, `signingStyle: manual`
8. Verify codesign
9. Create DMG via `scripts/create-dmg.sh`
10. Notarize DMG via `notarytool` (fetches log on failure)
11. Staple notarization ticket
12. Generate SHA-256 checksum
13. Upload artifact

### Job 2: `publish` (ubuntu-latest, `production` environment with required reviewer)

Creates GitHub Release with DMG + checksum.

### Job 3: `bump-cask` (ubuntu-latest)

Clones `ebreen/homebrew-cloudmount`, rewrites `Casks/cloudmount.rb` with new version and SHA-256, commits and pushes.

### Releasing a new version

```bash
git tag v2.1.0
git push origin v2.1.0
```

Then approve the `publish` job in the `production` environment gate on GitHub Actions.

### Common release failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| "No certificate for team" during export | Wrong cert type in `BUILD_CERTIFICATE_BASE64` | Must be Developer ID Application, not Apple Development |
| "No signing certificate Mac Development found" during archive | Dev cert missing from keychain | Check `DEV_CERTIFICATE_BASE64` contains Apple Development cert |
| "hardened runtime not enabled" during notarization | `ENABLE_HARDENED_RUNTIME` not set | Must be `true` in project.yml global settings |
| Notarization "Invalid" | Various -- check the log | Workflow fetches `notarytool log` automatically on failure |
| Export plist errors | Plist indentation | YAML `run: |` blocks strip leading indent; the heredoc content is fine |

## Sparkle Auto-Updates

- **Feed URL**: `https://raw.githubusercontent.com/ebreen/cloudmount/main/appcast.xml`
- **EdDSA Public Key**: `3GOokFls9E4GPEG00NfECK7JYQsjdIdRrPvq5kxQgfU=` (in `CloudMount/Info.plist`)
- **EdDSA Private Key**: Stored in Eirik's macOS Keychain (generated by Sparkle's `generate_keys` tool)
- **Current state**: `appcast.xml` is a placeholder with no `<item>` entries. Sparkle auto-update publishing is NOT yet automated in the release workflow.

### To automate Sparkle updates in CI

The release workflow needs a step that:
1. Exports the Sparkle EdDSA private key as a GitHub secret
2. Uses `sign_update` (from Sparkle's bin/) to sign the DMG
3. Adds an `<item>` to `appcast.xml` with the signed DMG URL, version, EdDSA signature, and file size
4. Commits the updated `appcast.xml` back to main

This is not yet implemented. For now, Sparkle will check but find no updates.

## Shared State Between App and Extension

The main app and extension communicate via two mechanisms:

| Mechanism | Key/Group | What's Stored |
|-----------|-----------|---------------|
| Keychain | `$(AppIdentifierPrefix)com.cloudmount.shared` | B2 credentials (key ID + application key) as JSON |
| App Group UserDefaults | `$(TeamIdentifierPrefix)com.cloudmount.app` | Mount configurations (bucket name, mount point, account UUID, cache settings) |

The extension reads these at mount time in `CloudMountFileSystem.loadResource()`.

## B2 API Integration

- Uses B2 Native API v4 (NOT S3-compatible)
- `B2HTTPClient` is a stateless, Sendable struct with 1:1 method-to-endpoint mapping
- `B2AuthManager` (actor) handles `b2_authorize_account` and transparent token refresh
- `B2Client` (actor) is the high-level interface with `withAutoRefresh` retry wrapper
- Upload flow: `b2_get_upload_url` -> `b2_upload_file` (retry with fresh URL on failure)
- Rename: server-side `b2_copy_file` + `b2_delete_file_version` (no native rename)
- Directory rename: not supported (returns ENOTSUP)

## File I/O Strategy

- **Read**: Download entire file to staging on `open()`, read from local file
- **Write**: Write to local staging file, upload to B2 on `close()` (write-on-close)
- **Staging**: `StagingManager` actor, temp files with SHA-256 hashed names
- **File cache**: On-disk LRU cache in `~/Library/Caches/CloudMount/`, default 1 GB limit
- **Metadata cache**: In-memory TTL cache, default 5 min
- **Metadata suppression**: `.DS_Store`, `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, etc. are blocked from hitting B2

## Build & Development

### Prerequisites

```bash
brew install xcodegen create-dmg
```

### Generate and build

```bash
xcodegen generate
xcodebuild build -project CloudMount.xcodeproj -scheme CloudMount -configuration Debug \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=66X2XJM3HW
```

### Build without signing (for CI/testing)

```bash
xcodebuild build -project CloudMount.xcodeproj -scheme CloudMount -configuration Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### Run the debug build

```bash
open build/DerivedData/Build/Products/Debug/CloudMount.app
```

## Source File Map

```
CloudMount/                          # Main app (SwiftUI menu bar)
  CloudMountApp.swift                # @main, Sparkle updater init, MenuBarExtra
  AppState.swift                     # Observable state: accounts, mounts, monitoring
  MountClient.swift                  # Mount/unmount via Process (mount -F -t b2 / diskutil)
  MountMonitor.swift                 # NSWorkspace didMount/didUnmount notifications
  ExtensionDetector.swift            # Dry-run probe to detect FSKit extension enablement
  Views/
    MenuContentView.swift            # Menu bar popup content
    SettingsView.swift               # Settings window (Credentials, Buckets, General tabs)
    OnboardingView.swift             # First-run extension setup guide
    CheckForUpdatesView.swift        # Sparkle "Check for Updates" menu command

CloudMountExtension/                 # FSKit filesystem extension
  CloudMountExtension.swift          # @main entry point (UnaryFileSystemExtension)
  CloudMountFileSystem.swift         # FSUnaryFileSystem subclass: probe, load, unload
  B2Volume.swift                     # FSVolume subclass: volume identity and state
  B2VolumeOperations.swift           # FSVolume.Operations: mount, unmount, lookup, enumerate, create, remove, rename, attributes
  B2VolumeReadWrite.swift            # FSVolume.ReadWriteOperations + OpenCloseOperations
  B2Item.swift                       # FSItem subclass for B2 objects
  B2ItemAttributes.swift             # FSItem attribute mapping
  StagingManager.swift               # Local temp file management for read/write
  MetadataBlocklist.swift            # Suppresses macOS metadata files from B2

CloudMountKit/                       # Shared framework
  B2/
    B2Client.swift                   # High-level B2 API client (actor)
    B2AuthManager.swift              # Token lifecycle and refresh (actor)
    B2HTTPClient.swift               # Stateless HTTP client, 1:1 endpoint mapping
    B2Error.swift                    # Typed error enum with retryable classification
    B2Types.swift                    # Codable models for B2 API responses
  Cache/
    FileCache.swift                  # On-disk LRU file cache (actor)
    MetadataCache.swift              # In-memory TTL metadata cache (actor)
  Credentials/
    CredentialStore.swift            # Keychain read/write for B2 credentials
    MountConfig.swift                # MountConfiguration model
    AccountConfig.swift              # B2Account model
  Config/
    SharedDefaults.swift             # App Group UserDefaults wrapper
```

## Homebrew Distribution

- **Tap repo**: `ebreen/homebrew-cloudmount`
- **Cask path**: `Casks/cloudmount.rb`
- **Install**: `brew install ebreen/cloudmount/cloudmount`
- Auto-bumped by the `bump-cask` CI job on each release
- `auto_updates true` in the cask (Sparkle handles in-app updates)
- `depends_on macos: ">= :tahoe"`

## CI

- `.github/workflows/ci.yml` runs on PRs to main
- Builds in Debug with signing disabled
- Test step is soft-fail (warning only)
- Uses `macos-26` runner

## Things Not Yet Done

- [ ] Sparkle appcast auto-publishing in release workflow
- [ ] Automated tests (test step is a no-op currently)
- [ ] S3-compatible provider support (only B2 for now)
- [ ] Cache settings UI (configurable in code but not exposed in Settings)
- [ ] `autoMount` feature (flag exists in MountConfiguration but not wired up)
