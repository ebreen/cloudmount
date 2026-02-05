# CloudMount

## What This Is

A macOS menu bar app that mounts Backblaze B2 cloud storage buckets as local FUSE volumes in Finder. A free, open-source alternative to Mountain Duck with a native SwiftUI interface and a Rust FUSE daemon for file operations.

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

(None — next milestone will define new requirements via `/gsd-new-milestone`)

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

- **Platform**: macOS 12+ only (Monterey or later)
- **Tech Stack**: Swift/SwiftUI (UI) + Rust (FUSE daemon)
- **Dependencies**: User must install macFUSE separately
- **Provider Priority**: Backblaze B2 only (generic S3 planned for v2)

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

---
*Last updated: 2026-02-05 after v1.0 milestone*
