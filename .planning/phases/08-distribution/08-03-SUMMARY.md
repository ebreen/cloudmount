---
phase: 08-distribution
plan: 03
subsystem: infra
tags: [homebrew, cask, sparkle, appcast, distribution]

# Dependency graph
requires:
  - phase: 07-app-integration
    provides: Mounted-volume UX and extension guidance that distribution artifacts reference
provides:
  - Homebrew Cask template for CloudMount tap bootstrap and release automation
  - Sparkle appcast feed placeholder at repository root
affects: [phase-08-release-automation, homebrew-tap, sparkle-updates]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Distribution artifacts are source-controlled templates consumed by CI release jobs
    - Homebrew Cask caveats stay concise and operationally focused

key-files:
  created:
    - homebrew/cloudmount.rb
    - appcast.xml
  modified: []

key-decisions:
  - "Use github_latest livecheck and auto_updates true in cask template for release-driven updates"
  - "Keep zap conservative and exclude credential data removal"

patterns-established:
  - "Distribution metadata is tracked in-repo and validated via syntax checks"

# Metrics
duration: 2 min
completed: 2026-02-06
---

# Phase 8 Plan 03: Homebrew Cask and Appcast Summary

**Homebrew Cask distribution template with Tahoe targeting plus Sparkle RSS appcast placeholder for CI-driven release updates.**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-06T14:09:02Z
- **Completed:** 2026-02-06T14:11:07Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Added `homebrew/cloudmount.rb` with full cask structure: version, sha256 placeholder, URL, livecheck, auto-updates, Tahoe requirement, app stanza, zap, and caveats
- Added conservative uninstall cleanup targets while preserving credential-bearing data paths
- Created `appcast.xml` with Sparkle namespace and empty release channel ready for `generate_appcast` population in CI

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Homebrew Cask formula template** - `d9f4a66` (feat)
2. **Task 2: Create Sparkle appcast.xml placeholder** - `b41a2c9` (feat)

## Files Created/Modified
- `homebrew/cloudmount.rb` - Canonical cask template used as tap reference and release bump baseline
- `appcast.xml` - Sparkle-compatible RSS feed placeholder for release entries

## Decisions Made
- Standardized cask caveats to include only the minimum install/run guidance users need post-install
- Used `diskutil unmount` in caveats for safer macOS unmount behavior guidance

## Deviations from Plan

None - plan executed exactly as written.

## Authentication Gates

None.

## Issues Encountered
None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Distribution artifacts for Homebrew and Sparkle are in place for release automation wiring
- Remaining Phase 8 plans should connect CI release jobs to publish and update these artifacts

---
*Phase: 08-distribution*
*Completed: 2026-02-06*
