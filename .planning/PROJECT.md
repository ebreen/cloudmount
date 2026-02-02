# CloudMount

## What This Is

A macOS menu bar app that mounts S3-compatible cloud storage (Backblaze B2, AWS S3, etc.) as local filesystems in Finder using FUSE. A free, open-source alternative to Mountain Duck with a modern, native-feeling macOS interface.

## Core Value

Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Mount S3-compatible buckets as local drives in Finder
- [ ] Support Backblaze B2 as primary provider (S3-compatible API)
- [ ] Basic file operations: read, write, list, delete
- [ ] Status bar menu showing mounted buckets, status, and disk usage
- [ ] Modern settings UI for credentials and configuration
- [ ] Open source with documentation for GitHub release

### Out of Scope

- Windows/Linux support — macOS-only for v1
- Real-time sync/collaboration — simple mount/unmount only
- Encryption at rest — defer to v2
- Mobile app — desktop only
- Commercial licensing — open source only

## Context

Building a free alternative to Mountain Duck ($39) for developers and power users who need occasional cloud storage mounting. Target audience is technical macOS users comfortable with FUSE and S3 APIs.

Key technical considerations:
- Requires macFUSE to be installed by user (brew install --cask macfuse)
- FUSE operations need to be non-blocking for good Finder UX
- Metadata caching essential for performance
- Status bar UI should feel native to macOS

## Constraints

- **Timeline**: Single day build — prioritize core functionality over polish
- **Platform**: macOS 12+ only (Monterey or later)
- **Tech Stack**: Node.js + TypeScript + fuse-native + Tauri (lighter than Electron)
- **Dependencies**: User must install macFUSE separately
- **Provider Priority**: Backblaze B2 first, generic S3 second

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Tauri over Electron | Lighter weight, better macOS native feel, Rust-based backend | — Pending |
| Backblaze B2 first | Personal use case, simpler than full S3 feature set | — Pending |
| Status bar only UI | No main window — menu bar app pattern for system tools | — Pending |
| Open source release | Community contribution, no commercial licensing complexity | — Pending |

---
*Last updated: 2025-02-02 after initialization*
