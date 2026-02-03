# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-02)

**Core value:** Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.
**Current focus:** Phase 3 - File I/O

## Current Position

Phase: 3 of 4 (File I/O)
Plan: 0 of 4 in current phase
Status: **PLANNED — READY TO EXECUTE**
Last activity: 2026-02-03 — Phase 3 researched and planned (4 plans in 3 waves)

Progress: [████████░░] 50%

## Phase 3 Plans

Wave 1:
- [ ] 03-01: File Read with Local Caching & API Minimization

Wave 2 (parallel):
- [ ] 03-02: File Write with Upload on Close
- [ ] 03-03: File Delete, Mkdir, and Rename Operations

Wave 3:
- [ ] 03-04: Error Handling, Retry Logic, and Connection Health

## Bug Fixed (Verified)

**B2 API parsing error in `list_all_buckets`** — RESOLVED & VERIFIED
- Root cause: API version mismatch (v2 flat response vs v3 nested struct)
- Fix: Changed API URL from v2 to v3 in `client.rs`
- See: `.planning/debug/b2-api-parsing.md`
- Human verified: 2026-02-02

## What's Complete

- [x] 02-01: FUSE filesystem trait with getattr/readdir
- [x] 02-02: B2 API client and mount manager
- [x] 02-03: Metadata caching with Moka
- [x] 02-04: IPC server (Rust) + DaemonClient (Swift) + UI integration
- [x] Fix: Settings window text input (switched to Window from Settings scene)
- [x] Fix: B2 credential workflow (global creds, then list buckets)

## What's Left

1. **Execute Phase 3 plans** (03-01 through 03-04)
2. Phase 3 verification
3. Phase 4 planning and execution

## Performance Metrics

**Velocity:**
- Total plans completed: 8 (Phase 1: 4, Phase 2: 4)
- Average duration: ~15 min
- Total execution time: ~2 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-foundation | 4/4 | ~60 min | ~15 min |
| 02-core-mount | 4/4 | ~60 min | ~15 min |

## Accumulated Context

### Decisions

- **PIVOT: Tauri/React → Native Swift/SwiftUI** (mid-Phase 1)
- Phase 2: Rust daemon for FUSE, Swift for UI, Unix socket IPC
- Phase 2: Global B2 credentials (not per-bucket) - authenticate once, list all buckets
- Phase 2: Window scene instead of Settings scene (fixes text field focus bug)
- Phase 2: moka::sync::Cache for FUSE callback compatibility (not async)
- Phase 3: Write locally, upload sync on close (MVP). Async upload deferred.
- Phase 3: Suppress macOS metadata files (.DS_Store, ._*, Spotlight, Trashes) in FUSE lookup
- Phase 3: Permanent delete (ignore B2 versioning)
- Phase 3: Rename via server-side copy + delete (not atomic, acceptable for MVP)
- Phase 3: New crates: sha1, tempfile, urlencoding, dirs

### Blockers/Concerns

- ~~B2 API response parsing needs fixing~~ — FIXED
- ~~macFUSE kernel extension may require Recovery Mode~~ — RESOLVED
- **API call budget**: 7,320 Class C transactions/day from browse-only testing (free tier: 2,500/day). Phase 3 adds reads (Class B) and writes (Class A, free). Metadata suppression in 03-01 is critical.

## Session Continuity

Last session: 2026-02-03
Stopped at: Phase 3 planning complete
Resume: Execute 03-01 first, then 03-02 + 03-03 in parallel, then 03-04

## Tech Stack

**Swift/SwiftUI (UI Layer):**
- `Sources/CloudMount/CloudMountApp.swift` - Main app with Window scene
- `Sources/CloudMount/DaemonClient.swift` - IPC client for daemon
- `Sources/CloudMount/CredentialStore.swift` - Keychain storage (global B2 creds)
- `Sources/CloudMount/MenuContentView.swift` - Menu bar with mount controls
- `Sources/CloudMount/SettingsView.swift` - Credentials + Buckets tabs

**Rust Daemon (FUSE Layer):**
- `Daemon/CloudMountDaemon/src/main.rs` - Daemon with IPC server
- `Daemon/CloudMountDaemon/src/ipc/server.rs` - Unix socket IPC
- `Daemon/CloudMountDaemon/src/ipc/protocol.rs` - JSON protocol
- `Daemon/CloudMountDaemon/src/b2/client.rs` - B2 API client
- `Daemon/CloudMountDaemon/src/fs/b2fs.rs` - FUSE filesystem with cache
- `Daemon/CloudMountDaemon/src/cache/metadata.rs` - Moka cache
- `Daemon/CloudMountDaemon/src/mount/manager.rs` - Mount lifecycle
