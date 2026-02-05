# CloudMount

## What This Is

A macOS menu bar app that mounts Backblaze B2 cloud storage buckets as local volumes in Finder. A free, open-source alternative to Mountain Duck with a native SwiftUI interface. v1.0 used a Rust FUSE daemon; v2.0 pivots to Apple's FSKit framework for a pure-Swift, single-process architecture.

## Core Value

Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.

## Requirements

### Validated

- Mount B2 buckets as local drives in Finder — v1.0
- Full file operations: read, write, list, delete — v1.0
- Status bar menu with mount controls and disk usage — v1.0
- Modern SwiftUI settings for credentials and configuration — v1.0
- Secure Keychain credential storage — v1.0
- macFUSE detection with installation guidance — v1.0

### Active

<!-- v2.0 FSKit Pivot & Distribution -->
- [ ] Rewrite filesystem layer from Rust/FUSE to Swift/FSKit
- [ ] Port B2 API client from Rust to Swift
- [ ] Remove Rust daemon and macFUSE dependency
- [ ] Package as a proper macOS .app bundle
- [ ] Distribute via GitHub Releases (.dmg)
- [ ] Distribute via Homebrew (Cask)
- [ ] CI/CD workflow for automated build, sign, and release

### Out of Scope

- Windows/Linux support — macOS-only for v1
- Real-time sync/collaboration — simple mount/unmount only
- Encryption at rest — defer to v2
- Mobile app — desktop only
- Commercial licensing — open source only

## Context

Shipped v1.0 MVP with ~6,042 LOC (1,333 Swift + 4,709 Rust).

**Tech stack:**
- Swift/SwiftUI: Menu bar app, settings window, credential management
- Rust: FUSE daemon (fuser 0.16), B2 API client (reqwest), metadata cache (moka)
- IPC: Unix domain socket with JSON protocol
- Storage: macOS Keychain (credentials), JSON file (bucket configs)

**Architecture:** Dual-process — Swift UI app communicates with Rust FUSE daemon via Unix socket at `/tmp/cloudmount.sock`. Daemon handles all B2 API calls and FUSE operations.

**Known technical debt:**
- Disk usage always shows None (B2 has no bucket size API)
- Directory rename not supported (returns ENOSYS)
- Auth token refresh is basic (24h expiry, simple re-auth)
- Pre-existing test failure in moka cache timing test (cosmetic)

## Constraints

- **Platform**: macOS 26+ (Tahoe — required for FSKit V2 / FSGenericURLResource)
- **Tech Stack**: Pure Swift/SwiftUI (UI + filesystem via FSKit)
- **Dependencies**: None (FSKit is built into macOS, no macFUSE needed)
- **Provider Priority**: Backblaze B2 only (generic S3 planned for later)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Tauri → Native Swift/SwiftUI | Tauri had text field focus bugs, SwiftUI gives better native UX | Good |
| Rust daemon for FUSE | FUSE requires C-compatible callbacks, Rust is ideal | Good |
| Unix socket IPC (JSON) | Human-readable debugging, fast local communication | Good |
| Backblaze B2 first | Personal use case, simpler than full S3 feature set | Good |
| Status bar only UI | Menu bar app pattern fits system tools | Good |
| Write locally, upload on close | MVP simplicity, avoids partial uploads | Good |
| moka::sync::Cache | FUSE callbacks are synchronous, can't use async cache | Good |
| Suppress macOS metadata files | Reduces B2 API calls significantly | Good |
| Permanent delete (ignore versioning) | MVP simplicity | Good |
| Open source release | Community contribution, no licensing complexity | Pending |
| Rust/macFUSE → Swift/FSKit | FSKit eliminates macFUSE dependency; pure Swift simplifies build; FSKit V2 is purpose-built for network FS | Pending |
| macOS 26+ minimum | FSKit V2 (FSGenericURLResource) requires macOS 26; V1 only supports block devices | Pending |
| SPM → Xcode project | FSKit extensions require Xcode targets, Info.plist, entitlements; SPM can't build .appex | Pending |

## Current Milestone: v2.0 FSKit Pivot & Distribution

**Goal:** Replace the Rust FUSE daemon with Apple's FSKit framework for a pure-Swift architecture, then package and distribute via GitHub Releases and Homebrew with CI/CD automation.

**Target features:**
- FSKit-based filesystem module replacing Rust FUSE daemon
- Swift B2 API client (porting from Rust reqwest to Swift URLSession/async-await)
- No external dependencies (no macFUSE installation required)
- Code-signed and notarized .app/.dmg for GitHub Releases
- Homebrew Cask formula for `brew install cloudmount`
- GitHub Actions workflow: PR checks (build + test) and tag-triggered releases

---
*Last updated: 2026-02-05 after v2.0 milestone start*
