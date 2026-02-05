# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Users can mount cloud storage buckets as local drives and access them seamlessly in Finder with a beautiful status bar interface for management.
**Current focus:** Phase 6 in progress — FSKit Filesystem extension

## Current Position

Phase: 6 of 8 (FSKit Filesystem)
Plan: 2 of 4 in current phase
Status: In progress
Last activity: 2026-02-06 — Completed 06-02-PLAN.md

Progress: [██████████████░░░░░░] 70% (21/~30 plans — v1.0 complete, v2.0 in progress)

## What's Complete

### v1.0 MVP (Shipped 2026-02-05)
- [x] Phase 1: Foundation (4/4 plans)
- [x] Phase 2: Core Mount & Browse (4/4 plans)
- [x] Phase 3: File I/O (4/4 plans)
- [x] Phase 4: Configuration & Polish (2/2 plans)

### v2.0 FSKit Pivot (In Progress)
- [x] Phase 5 Plan 1: Build system migration (Xcode project with 3 targets)
- [x] Phase 5 Plan 2: Credential store + config models (Keychain + SharedDefaults)
- [x] Phase 5 Plan 3: B2 API types + HTTP client
- [x] Phase 5 Plan 4: B2AuthManager + B2Client + caches
- [x] Phase 5 Plan 5: App state rewiring
- [x] Phase 6 Plan 1: B2Item + MetadataBlocklist + StagingManager (foundation types)
- [x] Phase 6 Plan 2: Extension entry point + FileSystem lifecycle + B2Volume shell

See: .planning/milestones/v1.0-ROADMAP.md

## Performance Metrics

**Velocity:**
- Total plans completed: 21
- Average duration: —
- Total execution time: —

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1. Foundation | 4 | — | — |
| 2. Core Mount & Browse | 4 | — | — |
| 3. File I/O | 4 | — | — |
| 4. Configuration & Polish | 2 | — | — |
| 5. Build System & B2 Client | 5/5 | 20min | 4.0min |
| 6. FSKit Filesystem | 2/4 | 29min | 14.5min |

*Updated after each plan completion*

## Accumulated Context

### Decisions

Archived to PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Rust/macFUSE → Swift/FSKit: FSKit V2 eliminates macFUSE; pure Swift simplifies build
- macOS 26+ minimum: FSKit V2 (FSGenericURLResource) requires Tahoe
- SPM → Xcode project: FSKit extensions need .appex targets, Info.plist, entitlements
- xcodegen for reproducible project generation from project.yml
- Native Security.framework over KeychainAccess SPM — no third-party keychain dependency
- nonisolated(unsafe) for KeychainHelper.accessGroup — Swift 6 concurrency, set-once pattern
- Secrets in Keychain only, metadata in UserDefaults — clean separation
- FlexibleInt64 for B2's inconsistent numeric encoding (Int64, String, null)
- B2HTTPClient as stateless struct (not actor) — no mutable state, fully Sendable
- B2AuthManager, MetadataCache, FileCache, B2Client all use actor isolation for Swift 6 concurrency
- withAutoRefresh uses AuthContext snapshot to avoid mutable captures in Sendable closures
- B2Client instantiated per-validation in views rather than held on AppState — avoids actor isolation complexity in SwiftUI
- SHA-256 hash for staging file names — avoids filesystem issues with long B2 paths
- Actor isolation for StagingManager — matches FSKit's concurrent callback pattern
- UncheckedSendableBox for FSKit ObjC reply handlers — Swift 6 concurrency bridge pattern
- FSVolume nested Swift types (FSVolume.Operations, FSItem.Attributes) — ObjC types renamed in Swift

### Blockers/Concerns

- FSKit V2 is immature — `removeItem` may not fire (known bug), no kernel caching (~121us/syscall)
- Extension must be manually enabled by users in System Settings (no programmatic API)
- GitHub Actions runner may not have macOS 26 SDK yet — may need self-hosted or Xcode Cloud

### Pending Todos

None.

## Session Continuity

Last session: 2026-02-05T23:34:37Z
Stopped at: Completed 06-02-PLAN.md
Resume file: None
