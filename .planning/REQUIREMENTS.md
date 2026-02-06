# Requirements: CloudMount v2.0

**Defined:** 2026-02-05
**Core Value:** Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.

## v2.0 Requirements

Requirements for FSKit pivot and distribution. Each maps to roadmap phases.

### Build System

- [x] **BUILD-01**: Project uses Xcode project with app target and FSKit extension target (replacing Package.swift)
- [x] **BUILD-02**: Shared framework target contains code used by both app and extension (B2 types, config models, credential access)
- [x] **BUILD-03**: App Group configured for Keychain sharing between app and extension processes
- [x] **BUILD-04**: Rust daemon, Cargo.toml, Cargo.lock, and all Rust source files removed from project
- [x] **BUILD-05**: macFUSE detection code and references removed from app

### FSKit Filesystem

- [x] **FSKIT-01**: FSUnaryFileSystem subclass handles probe/load/unload lifecycle for B2 bucket resources
- [x] **FSKIT-02**: FSVolume subclass implements lookup, enumerate directory, create item, remove item, rename item, get/set attributes, reclaim, and synchronize
- [x] **FSKIT-03**: FSVolume.ReadWriteOperations implemented — read downloads from B2 (with local cache), write buffers locally
- [x] **FSKIT-04**: FSVolume.OpenCloseOperations implemented — write-on-close uploads dirty files to B2
- [x] **FSKIT-05**: Volume statistics (statfs) returns meaningful values for mounted bucket
- [x] **FSKIT-06**: macOS metadata files suppressed (.DS_Store, .Spotlight-V100, ._ files) to reduce B2 API calls
- [x] **FSKIT-07**: User can mount a B2 bucket via the app and browse it in Finder as a local volume

### B2 API Client (Swift)

- [x] **B2-01**: Swift B2 client authenticates with Backblaze (authorize_account) and retrieves API URL + auth token
- [x] **B2-02**: Client lists file names with prefix/delimiter support for virtual directory navigation
- [x] **B2-03**: Client downloads files by name with support for range requests
- [x] **B2-04**: Client uploads files (get_upload_url + upload_file flow)
- [x] **B2-05**: Client deletes file versions
- [x] **B2-06**: Client copies files server-side (used for rename: copy + delete)
- [x] **B2-07**: Client creates folder markers (zero-byte files with trailing /)
- [x] **B2-08**: Auth token refreshes automatically on expiry (24h)
- [x] **B2-09**: In-memory metadata cache with TTL-based expiration reduces B2 API calls
- [x] **B2-10**: Local file read cache stores downloaded files on disk to avoid re-fetching

### App Integration

- [ ] **APP-01**: MountClient replaces DaemonClient — invokes mount -F / umount for mount/unmount operations
- [ ] **APP-02**: App detects mount status (mounted/unmounted) and reflects it in the status bar UI
- [ ] **APP-03**: First-launch onboarding detects if FSKit extension is enabled and guides user to System Settings if not
- [ ] **APP-04**: Menu bar UI updated — macFUSE references removed, status indicators updated for FSKit
- [ ] **APP-05**: App-side B2Client for bucket listing during credential setup in Settings

### Packaging

- [ ] **PKG-01**: App bundle is code-signed with Developer ID Application certificate and hardened runtime
- [ ] **PKG-02**: App bundle is notarized via xcrun notarytool and stapled
- [ ] **PKG-03**: .dmg disk image created with Applications symlink for drag-to-install
- [ ] **PKG-04**: App has proper bundle identifier, version number in Info.plist, and app icon
- [ ] **PKG-05**: Sparkle auto-update framework integrated — checks GitHub Releases for updates

### Homebrew

- [ ] **BREW-01**: Homebrew Cask formula in own tap (homebrew-cloudmount) with version, sha256, app stanza
- [ ] **BREW-02**: Cask includes depends_on macos constraint, caveats about FSKit extension enablement, and zap stanza
- [ ] **BREW-03**: Cask includes livecheck stanza pointing to GitHub Releases for auto-detection of new versions

### CI/CD

- [ ] **CI-01**: GitHub Actions workflow runs build + test on every pull request
- [ ] **CI-02**: Tag-triggered release workflow: build → sign → notarize → create DMG → upload to GitHub Release
- [ ] **CI-03**: Code signing in CI uses imported certificate from GitHub Secrets (dedicated keychain, proper partition list)
- [ ] **CI-04**: Automated Homebrew Cask version bump after successful release (update sha256 + version in tap)

## Future Requirements

Deferred to post-v2.0. Tracked but not in current roadmap.

### Multi-Bucket & Providers

- **MULTI-01**: User can mount multiple B2 buckets simultaneously
- **MULTI-02**: User can configure auto-mount on startup for selected buckets
- **S3-01**: User can mount generic S3-compatible storage (AWS, MinIO, etc.)

### App Store

- **STORE-01**: Submit to Mac App Store for broader distribution

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Extended attributes (xattr) | macOS sends many xattr queries; each would hit B2 API; massive performance cost |
| Symbolic links | B2 has no concept of symlinks; would need emulation |
| Hard links | B2 is object storage; hard links are meaningless |
| Directory rename | B2 has no atomic rename; requires recursive copy+delete of all children |
| Windows/Linux support | macOS-only for v2 |
| Mac App Store distribution | FSKit extensions have update issues in App Store (unmounts volumes without warning); defer |
| Submit to homebrew-cask core | Need traction/stars first; start with own tap |
| Real-time sync/collaboration | Simple mount/unmount only |
| Encryption at rest | Defer to later version |
| Read-only volume mode | FSKit read-only support is buggy (Finder still offers write operations) |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUILD-01 | Phase 5 | Complete |
| BUILD-02 | Phase 5 | Complete |
| BUILD-03 | Phase 5 | Complete |
| BUILD-04 | Phase 5 | Complete |
| BUILD-05 | Phase 5 | Complete |
| B2-01 | Phase 5 | Complete |
| B2-02 | Phase 5 | Complete |
| B2-03 | Phase 5 | Complete |
| B2-04 | Phase 5 | Complete |
| B2-05 | Phase 5 | Complete |
| B2-06 | Phase 5 | Complete |
| B2-07 | Phase 5 | Complete |
| B2-08 | Phase 5 | Complete |
| B2-09 | Phase 5 | Complete |
| B2-10 | Phase 5 | Complete |
| FSKIT-01 | Phase 6 | Complete |
| FSKIT-02 | Phase 6 | Complete |
| FSKIT-03 | Phase 6 | Complete |
| FSKIT-04 | Phase 6 | Complete |
| FSKIT-05 | Phase 6 | Complete |
| FSKIT-06 | Phase 6 | Complete |
| FSKIT-07 | Phase 6 | Complete |
| APP-01 | Phase 7 | Pending |
| APP-02 | Phase 7 | Pending |
| APP-03 | Phase 7 | Pending |
| APP-04 | Phase 7 | Pending |
| APP-05 | Phase 7 | Pending |
| PKG-01 | Phase 8 | Pending |
| PKG-02 | Phase 8 | Pending |
| PKG-03 | Phase 8 | Pending |
| PKG-04 | Phase 8 | Pending |
| PKG-05 | Phase 8 | Pending |
| BREW-01 | Phase 8 | Pending |
| BREW-02 | Phase 8 | Pending |
| BREW-03 | Phase 8 | Pending |
| CI-01 | Phase 8 | Pending |
| CI-02 | Phase 8 | Pending |
| CI-03 | Phase 8 | Pending |
| CI-04 | Phase 8 | Pending |

**Coverage:**
- v2.0 requirements: 39 total
- Mapped to phases: 39 ✓
- Unmapped: 0

---
*Requirements defined: 2026-02-05*
*Last updated: 2026-02-06 after Phase 6 completion*
