# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-02)

**Core value:** Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.
**Current focus:** Phase 2 - Core Mount & Browse

## Current Position

Phase: 2 of 4 (Core Mount & Browse)
Plan: 1 of 4 in current phase
Status: In progress
Last activity: 2026-02-02 — Completed 02-01-PLAN.md (Rust daemon foundation)

Progress: [████░░░░░░] 30%

## Performance Metrics

**Velocity:**
- Total plans completed: 4 (Phase 1 complete)
- Average duration: ~15 min
- Total execution time: ~1 hour

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-foundation | 4/4 | ~60 min | ~15 min |

**Recent Trend:**
- Phase 1 completed with mid-phase tech stack pivot
- Trend: Pivot added time but achieved better native UX

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **PIVOT: Tauri/React → Native Swift/SwiftUI** (mid-Phase 1)
  - Reason: User feedback that Tauri UI looked non-native
  - Inspired by CodexBar (https://github.com/steipete/CodexBar)
  - Result: True native macOS look and feel
- Phase 1: macFUSE installation will be user-responsibility with clear detection and guidance
- Swift: Using MenuBarExtra for status bar (macOS 13+)
- Swift: Using KeychainAccess library for credential storage
- Swift: FileManager.default.fileExists for macFUSE detection
- Swift: Settings window with native TabView (Buckets/Credentials/General tabs)
- Architecture: Swift app handles UI, Rust daemon will handle FUSE (Phase 2)
- Phase 2-1: ROOT_INO = 1 per FUSE convention, inodes never recycled for mount lifetime
- Phase 2-1: Tokio Handle used for async B2 calls within sync FUSE trait methods
- Phase 2-1: Stub implementation returns directory attrs for unknown inodes (allows navigation before B2 integration)

### Pending Todos

None yet.

### Blockers/Concerns

- macFUSE kernel extension installation may require Recovery Mode on some macOS versions
- Synchronous upload on file close will block filesystem (acceptable for MVP, document limitation)
- Phase 2 will need Rust daemon for FUSE mounting (Swift cannot directly use fuser crate)

## Session Continuity

Last session: 2026-02-02
Stopped at: Completed 02-01-PLAN.md (Rust daemon foundation with FUSE filesystem)
Resume file: None

## Tech Stack (Post-Pivot)

**Swift/SwiftUI (UI Layer):**
- `Package.swift` - Swift Package Manager config
- `Sources/CloudMount/CloudMountApp.swift` - Main app with MenuBarExtra
- `Sources/CloudMount/MacFUSEDetector.swift` - macFUSE detection
- `Sources/CloudMount/CredentialStore.swift` - Keychain storage
- `Sources/CloudMount/MenuContentView.swift` - Menu bar dropdown
- `Sources/CloudMount/SettingsView.swift` - Settings window

**Dependencies:**
- KeychainAccess (credential storage)

**Rust Daemon (FUSE Layer):**
- `Daemon/CloudMountDaemon/Cargo.toml` - Rust dependencies
- `Daemon/CloudMountDaemon/src/main.rs` - Daemon entry point
- `Daemon/CloudMountDaemon/src/fs/b2fs.rs` - FUSE filesystem implementation
- `Daemon/CloudMountDaemon/src/fs/inode.rs` - Inode table for path mapping
- `Daemon/CloudMountDaemon/src/b2/types.rs` - B2 API types and conversions

**Preserved but unused:**
- `src-tauri/` - Original Tauri backend (preserved for reference)
- `src/` - Original React frontend (preserved for reference)
