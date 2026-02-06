---
phase: 08-distribution
plan: 01
subsystem: infra
tags: [sparkle, xcodegen, distribution, developer-id, swiftui]

# Dependency graph
requires:
  - phase: 07-app-integration
    provides: CloudMount app target and menu bar lifecycle to integrate updater commands
  - phase: 05-build-system
    provides: xcodegen-driven project.yml build configuration
provides:
  - Sparkle SPM dependency wired into CloudMount target
  - App-level Sparkle updater initialization with Check for Updates menu command
  - Distribution metadata in Info.plist (version, feed URL, public key placeholder)
  - Developer ID export options plist for release pipeline
affects: [08-02, 08-03, release-ci, appcast]

# Tech tracking
tech-stack:
  added: [Sparkle]
  patterns:
    - "Programmatic Sparkle setup via SPUStandardUpdaterController in SwiftUI App entry point"
    - "Distribution signing options managed in scripts/export-options.plist without hardcoded team ID"

key-files:
  created:
    - CloudMount/Views/CheckForUpdatesView.swift
    - scripts/export-options.plist
  modified:
    - project.yml
    - CloudMount/Info.plist
    - CloudMount/CloudMountApp.swift

key-decisions:
  - "Use Sparkle via SPM in xcodegen project.yml to keep dependency management declarative"
  - "Keep SUPublicEDKey empty and omit teamID in export options so CI/user secrets stay external"

patterns-established:
  - "SwiftUI command injection pattern: CommandGroup(after: .appInfo) for updater actions"

# Metrics
duration: 2 min
completed: 2026-02-06
---

# Phase 8 Plan 1: Sparkle + Distribution Config Summary

**Sparkle 2.x updater wiring with app menu update checks, release feed metadata in Info.plist, and Developer ID export options for CI distribution builds.**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-06T14:08:55Z
- **Completed:** 2026-02-06T14:11:08Z
- **Tasks:** 2/2
- **Files modified:** 5

## Accomplishments
- Added Sparkle package declaration in `project.yml` and linked it to the `CloudMount` target dependency list
- Updated `CloudMount/Info.plist` to `CFBundleShortVersionString=2.0.0` and added `SUFeedURL` plus `SUPublicEDKey` placeholder
- Added `CloudMount/Views/CheckForUpdatesView.swift` with `SPUUpdater` binding and enabled state via `canCheckForUpdates`
- Updated `CloudMount/CloudMountApp.swift` to initialize `SPUStandardUpdaterController` and expose "Check for Updates..." in app commands
- Created `scripts/export-options.plist` with `developer-id`, `manual` signing style, and `Developer ID Application` certificate selector

## Task Commits

Each task was committed atomically:

1. **Task 1: Add Sparkle SPM dependency and update Info.plist** - `7ef37ed` (chore)
2. **Task 2: Integrate updater and create export options plist** - `a2f2d89` (feat)

## Files Created/Modified
- `project.yml` - Added top-level Sparkle package and CloudMount target package dependency
- `CloudMount/Info.plist` - Set release version to 2.0.0 and added Sparkle feed/public-key keys
- `CloudMount/CloudMountApp.swift` - Added Sparkle import, updater controller setup, and app command integration
- `CloudMount/Views/CheckForUpdatesView.swift` - Added Sparkle update check command view and view model
- `scripts/export-options.plist` - Added Developer ID export configuration for `xcodebuild -exportArchive`

## Decisions Made
- Used `SPUStandardUpdaterController` for programmatic Sparkle startup at app launch so updater state is available for command UI.
- Kept signing/team-specific values out of committed distribution config (`SUPublicEDKey` placeholder, no `teamID` in export options) so CI/user secrets remain external.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Ready for `08-02-PLAN.md` (CI/CD release and PR workflows).
- Sparkle dependency, app wiring, and export options prerequisites are in place for release automation.

---
*Phase: 08-distribution*
*Completed: 2026-02-06*
