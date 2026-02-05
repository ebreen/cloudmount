# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.
**Current focus:** v2.0 FSKit Pivot & Distribution

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-02-05 — Milestone v2.0 started

## What's Complete

### v1.0 MVP (Shipped 2026-02-05)
- [x] Phase 1: Foundation (4/4 plans)
- [x] Phase 2: Core Mount & Browse (4/4 plans)
- [x] Phase 3: File I/O (4/4 plans)
- [x] Phase 4: Configuration & Polish (2/2 plans)

See: .planning/milestones/v1.0-ROADMAP.md for full details

## What's Left

### v2.0 FSKit Pivot & Distribution
- [ ] Rewrite filesystem layer: Rust/FUSE → Swift/FSKit
- [ ] Port B2 API client: Rust → Swift
- [ ] Remove Rust daemon and macFUSE dependency
- [ ] Package as .app bundle
- [ ] GitHub Releases with .dmg
- [ ] Homebrew Cask
- [ ] CI/CD workflow (PR checks + tag releases)

## Accumulated Context

### Decisions

Archived to PROJECT.md Key Decisions table. See .planning/milestones/v1.0-ROADMAP.md for full milestone decision log.

### Blockers/Concerns

- Pre-existing test failure: `cache::metadata::tests::test_cache_clear` (moka cache timing) — cosmetic, not blocking

## Session Continuity

Last session: 2026-02-05
Stopped at: v1.0 milestone archived
Resume file: None

## Tech Stack

**Swift/SwiftUI (UI Layer):**
- `Sources/CloudMount/CloudMountApp.swift` - Main app, BucketConfigStore, persistence
- `Sources/CloudMount/DaemonClient.swift` - IPC client (with totalBytesUsed)
- `Sources/CloudMount/CredentialStore.swift` - Keychain storage
- `Sources/CloudMount/MenuContentView.swift` - Menu bar with mount controls
- `Sources/CloudMount/SettingsView.swift` - Credentials + Buckets tabs

**Rust Daemon (FUSE Layer):**
- `Daemon/CloudMountDaemon/src/ipc/protocol.rs` - JSON protocol (with total_bytes_used)
- `Daemon/CloudMountDaemon/src/ipc/server.rs` - Unix socket IPC
- `Daemon/CloudMountDaemon/src/b2/client.rs` - B2 API client
- `Daemon/CloudMountDaemon/src/fs/b2fs.rs` - FUSE filesystem
- `Daemon/CloudMountDaemon/src/mount/manager.rs` - Mount lifecycle
