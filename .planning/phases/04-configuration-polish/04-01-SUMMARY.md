---
phase: 04-configuration-polish
plan: 01
subsystem: config
tags: [codable, persistence, json, ipc, serde, disk-usage]

# Dependency graph
requires:
  - phase: 03-file-io
    provides: "FUSE filesystem, IPC protocol, B2Client, daemon status polling"
provides:
  - "BucketConfigStore with JSON persistence for bucket configs"
  - "totalBytesUsed field in IPC protocol (Rust + Swift)"
  - "clearAllBuckets() method on AppState"
affects: [04-02-PLAN.md]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "BucketConfigStore static struct with save/load for JSON persistence"
    - "CodingKeys excluding runtime-only state from persistence"

key-files:
  created: []
  modified:
    - "Sources/CloudMount/CloudMountApp.swift"
    - "Sources/CloudMount/DaemonClient.swift"
    - "Sources/CloudMount/SettingsView.swift"
    - "Daemon/CloudMountDaemon/src/ipc/protocol.rs"
    - "Daemon/CloudMountDaemon/src/ipc/server.rs"

key-decisions:
  - "totalBytesUsed: None for MVP — B2 has no bucket size API, computation deferred"
  - "CodingKeys explicitly exclude isMounted and totalBytesUsed (runtime state)"
  - "DaemonMountInfo.totalBytesUsed added in Task 1 to unblock Swift compilation"

patterns-established:
  - "BucketConfigStore: static save/load to ~/Library/Application Support/CloudMount/buckets.json"

# Metrics
duration: 3min
completed: 2026-02-03
---

# Phase 4 Plan 1: Bucket Config Persistence & Disk Usage IPC Summary

**BucketConfigStore persisting to JSON with Codable, totalBytesUsed flowing end-to-end through IPC protocol**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-03T14:35:55Z
- **Completed:** 2026-02-03T14:39:22Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- BucketConfig gains Codable conformance with CodingKeys that exclude runtime state (isMounted, totalBytesUsed)
- BucketConfigStore persists configs to ~/Library/Application Support/CloudMount/buckets.json
- AppState loads on init, saves on add/remove, clearAllBuckets() for disconnect
- IPC protocol MountInfo extended with total_bytes_used: Option<u64>
- DaemonMountInfo in Swift gains totalBytesUsed: Int64? for end-to-end data flow

## Task Commits

Each task was committed atomically:

1. **Task 1: Bucket config persistence with BucketConfigStore** - `b0869f2` (feat)
2. **Task 2: Add disk usage to IPC protocol and daemon status** - `cc8e358` (feat)

## Files Created/Modified
- `Sources/CloudMount/CloudMountApp.swift` - BucketConfig Codable, BucketConfigStore, AppState persistence wiring
- `Sources/CloudMount/DaemonClient.swift` - totalBytesUsed on DaemonMountInfo
- `Sources/CloudMount/SettingsView.swift` - disconnect() uses clearAllBuckets()
- `Daemon/CloudMountDaemon/src/ipc/protocol.rs` - total_bytes_used on MountInfo, new test
- `Daemon/CloudMountDaemon/src/ipc/server.rs` - total_bytes_used: None in GetStatus

## Decisions Made
- **totalBytesUsed: None for MVP** — B2 has no "get bucket size" API; computing it requires listing all files. The protocol field is wired end-to-end but sends None. Actual calculation deferred to enhancement.
- **DaemonMountInfo.totalBytesUsed added in Task 1** — Task 1 needed the Swift field for updateDaemonStatus() to compile. Added as part of Task 1 rather than waiting for Task 2.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added totalBytesUsed to DaemonMountInfo in Task 1**
- **Found during:** Task 1 (Bucket config persistence)
- **Issue:** Task 1's updateDaemonStatus() references mount.totalBytesUsed but DaemonMountInfo didn't have the field yet (planned for Task 2)
- **Fix:** Added totalBytesUsed: Int64? to DaemonMountInfo as part of Task 1
- **Files modified:** Sources/CloudMount/DaemonClient.swift
- **Verification:** Swift build succeeds
- **Committed in:** b0869f2 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Minor reordering — Swift-side DaemonMountInfo field moved from Task 2 to Task 1 for compilation. No scope creep.

## Issues Encountered
- Pre-existing test failure in `cache::metadata::tests::test_cache_clear` (moka cache timing issue from Phase 3). Not related to this plan's changes. Protocol tests all pass.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Bucket config persistence complete and wired
- totalBytesUsed protocol pipe ready end-to-end
- Ready for 04-02-PLAN.md (disk usage display in menu and settings polish)

---
*Phase: 04-configuration-polish*
*Completed: 2026-02-03*
