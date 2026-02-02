# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-02)

**Core value:** Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.
**Current focus:** Phase 2 - Core Mount & Browse

## Current Position

Phase: 2 of 4 (Core Mount & Browse)
Plan: 4 of 4 in current phase
Status: **CHECKPOINT - Bug fix needed before verification**
Last activity: 2026-02-02 — All 4 plans executed, fixing B2 API bug

Progress: [███████░░░] 45%

## Active Bug (Must Fix)

**B2 API parsing error in `list_all_buckets`**
- Error: "failed to parse b2 auth response"
- Location: `Daemon/CloudMountDaemon/src/b2/client.rs` in `list_all_buckets()` function
- Cause: B2 API response structure doesn't match our AuthorizeAccountResponse struct
- Fix: Check actual B2 API docs for `b2_authorize_account` response format

## What's Complete

- [x] 02-01: FUSE filesystem trait with getattr/readdir
- [x] 02-02: B2 API client and mount manager
- [x] 02-03: Metadata caching with Moka
- [x] 02-04: IPC server (Rust) + DaemonClient (Swift) + UI integration
- [x] Fix: Settings window text input (switched to Window from Settings scene)
- [x] Fix: B2 credential workflow (global creds, then list buckets)

## What's Left

1. **Fix B2 API parsing bug** - The `list_all_buckets` function fails to parse B2 response
2. **Human verification checkpoint** - Test mount/unmount flow end-to-end
3. **Phase verification** - Run verifier after checkpoint passes

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

### Blockers/Concerns

- B2 API response parsing needs fixing
- macFUSE kernel extension may require Recovery Mode on some macOS versions

## Session Continuity

Last session: 2026-02-02
Stopped at: B2 API parsing bug in listBuckets
Resume command: See below

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
- `Daemon/CloudMountDaemon/src/b2/client.rs` - B2 API client (**BUG HERE**)
- `Daemon/CloudMountDaemon/src/fs/b2fs.rs` - FUSE filesystem with cache
- `Daemon/CloudMountDaemon/src/cache/metadata.rs` - Moka cache
- `Daemon/CloudMountDaemon/src/mount/manager.rs` - Mount lifecycle
