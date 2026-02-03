# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-02)

**Core value:** Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.
**Current focus:** Phase 4 in progress — Configuration & Polish

## Current Position

Phase: 4 of 4 (Configuration & Polish)
Plan: 1 of 2 in current phase
Status: In progress
Last activity: 2026-02-03 — Completed 04-01-PLAN.md

Progress: [█████████████░] 93%

## What's Complete

- [x] Phase 1: Foundation (4/4 plans)
- [x] Phase 2: Core Mount & Browse (4/4 plans)
- [x] Phase 3: File I/O (4/4 plans)
- [x] Phase 4 Plan 1: Bucket config persistence & disk usage IPC

## What's Left

- [ ] 04-02: Disk usage display in menu and settings polish

## Accumulated Context

### Decisions

- **PIVOT: Tauri/React → Native Swift/SwiftUI** (mid-Phase 1)
- Phase 2: Rust daemon for FUSE, Swift for UI, Unix socket IPC
- Phase 2: Global B2 credentials (not per-bucket)
- Phase 2: Window scene instead of Settings scene (fixes text field focus bug)
- Phase 2: moka::sync::Cache for FUSE callback compatibility (not async)
- Phase 3: Write locally, upload sync on close (MVP)
- Phase 3: Suppress macOS metadata files in FUSE lookup
- Phase 3: Permanent delete (ignore B2 versioning)
- Phase 3: Rename via server-side copy + delete
- Phase 3: B2Client uses Arc<RwLock<AuthState>> for token refresh
- Phase 3: Retry wrapper with exponential backoff (500ms, 1s, 2s, 3 retries)
- Phase 3: Directory rename returns ENOSYS (not supported for MVP)
- Phase 4: totalBytesUsed sends None for MVP — B2 has no bucket size API, computation deferred
- Phase 4: CodingKeys exclude isMounted and totalBytesUsed (runtime state, not persisted)

### Blockers/Concerns

- **Pre-existing test failure**: `cache::metadata::tests::test_cache_clear` (moka cache timing) — not blocking, cosmetic
- **API call budget**: Metadata suppression should reduce Class C calls significantly

## Session Continuity

Last session: 2026-02-03T14:39:22Z
Stopped at: Completed 04-01-PLAN.md
Resume: Execute 04-02-PLAN.md (disk usage display, settings polish)

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
