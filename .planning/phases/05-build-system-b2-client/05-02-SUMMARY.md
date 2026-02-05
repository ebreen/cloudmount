---
phase: 05-build-system-b2-client
plan: 02
subsystem: credentials
tags: [keychain, security-framework, userdefaults, app-group, b2, multi-account]

# Dependency graph
requires:
  - phase: 05-01
    provides: Xcode project with CloudMountKit framework target
provides:
  - Native Keychain credential store (Security.framework)
  - B2Account model with Codable, UUID, multi-account support
  - MountConfiguration model with per-account mount settings
  - SharedDefaults App Group UserDefaults wrapper
affects: [05-03, 05-04, 05-05, 06, 07]

# Tech tracking
tech-stack:
  added: [Security.framework (native)]
  patterns: [Keychain shared access group, App Group UserDefaults, delete-then-add keychain pattern, JSON-in-UserDefaults for Codable arrays]

key-files:
  created:
    - CloudMountKit/Credentials/CredentialStore.swift
    - CloudMountKit/Credentials/AccountConfig.swift
    - CloudMountKit/Credentials/MountConfig.swift
    - CloudMountKit/Config/SharedDefaults.swift
  modified:
    - CloudMount.xcodeproj/project.pbxproj

key-decisions:
  - "Native Security.framework over KeychainAccess SPM — eliminates third-party dependency"
  - "nonisolated(unsafe) for KeychainHelper.accessGroup — Swift 6 concurrency, set-once-at-startup pattern"
  - "Secrets only in Keychain, metadata in UserDefaults — clean separation of sensitive vs non-sensitive data"
  - "B2Account.keyId in model (non-secret username-like ID), applicationKey only in Keychain"

patterns-established:
  - "Keychain CRUD: delete-then-add pattern for save, SecItemCopyMatching for load/list"
  - "Cross-process sharing: keychain-access-groups + App Group UserDefaults"
  - "All CloudMountKit types: public, Codable, Hashable, Sendable"

# Metrics
duration: 4min
completed: 2026-02-05
---

# Phase 5 Plan 2: Credential Store & Config Models Summary

**Native Keychain credential store via Security.framework with B2Account, MountConfiguration, and CacheSettings models backed by App Group UserDefaults**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-05T22:05:39Z
- **Completed:** 2026-02-05T22:09:59Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- KeychainHelper with low-level SecItem CRUD and configurable shared access group
- CredentialStore for B2 account secrets keyed by UUID
- B2Account, MountConfiguration, CacheSettings models with multi-account/multi-mount support
- SharedDefaults App Group UserDefaults wrapper for cross-process config sharing

## Task Commits

Each task was committed atomically:

1. **Task 1: Native Keychain credential store** - `4069ea1` (feat)
2. **Task 2: Account config, mount config, shared defaults** - `80fd640` (feat)

## Files Created/Modified
- `CloudMountKit/Credentials/CredentialStore.swift` — KeychainHelper + CredentialStore + KeychainError
- `CloudMountKit/Credentials/AccountConfig.swift` — B2Account model (Identifiable, Codable, Hashable, Sendable)
- `CloudMountKit/Credentials/MountConfig.swift` — MountConfiguration + CacheSettings models
- `CloudMountKit/Config/SharedDefaults.swift` — App Group UserDefaults wrapper
- `CloudMount.xcodeproj/project.pbxproj` — Added 4 files to CloudMountKit target with Credentials/Config groups

## Decisions Made
- Used `nonisolated(unsafe)` for `KeychainHelper.accessGroup` static var to satisfy Swift 6 strict concurrency (mutable global set once at startup)
- B2Account includes `keyId` in model for display but `applicationKey` stored only in Keychain — clean secret/non-secret separation
- `CredentialStore.saveAccount` takes `applicationKey` as separate parameter rather than embedding it in B2Account

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Included AccountConfig.swift in Task 1 commit**
- **Found during:** Task 1 (CredentialStore compilation)
- **Issue:** CredentialStore.swift references B2Account from AccountConfig.swift — cannot compile without it
- **Fix:** Included AccountConfig.swift in Task 1 commit alongside CredentialStore.swift
- **Files modified:** CloudMountKit/Credentials/AccountConfig.swift
- **Verification:** BUILD SUCCEEDED with both files
- **Committed in:** 4069ea1

**2. [Rule 1 - Bug] Fixed Swift 6 concurrency error on static mutable property**
- **Found during:** Task 1 (first build attempt)
- **Issue:** `static var accessGroup: String?` flagged as "not concurrency-safe because it is nonisolated global shared mutable state"
- **Fix:** Changed to `nonisolated(unsafe) static var accessGroup: String?` — appropriate for set-once-at-startup configuration
- **Files modified:** CloudMountKit/Credentials/CredentialStore.swift
- **Verification:** BUILD SUCCEEDED after fix
- **Committed in:** 4069ea1

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug)
**Impact on plan:** Both fixes necessary for compilation under Swift 6 strict concurrency. No scope creep.

## Issues Encountered
None

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- Credential store and config models ready for B2 client (Plan 05-03)
- SharedDefaults ready for UI layer (Plan 05-05)
- All models support multi-account/multi-mount from the start
- No blockers

---
*Phase: 05-build-system-b2-client*
*Completed: 2026-02-05*
