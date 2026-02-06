---
phase: 08-distribution
plan: 02
subsystem: infra
tags: [github-actions, ci, release, notarization, dmg, homebrew]

# Dependency graph
requires:
  - phase: 08-distribution-01
    provides: Sparkle and export-options plumbing used by release workflow
  - phase: 07-app-integration
    provides: Buildable app/extension targets needed for CI build and archive
provides:
  - Pull request CI workflow for build and test validation
  - Tag-triggered release workflow with signing, notarization, DMG packaging, and release publish gate
  - Reusable DMG creation helper script with Applications drop link
affects: [phase-08-finalization, github-releases, homebrew-tap-automation]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GitHub Actions split into build-sign-notarize -> publish (manual gate) -> bump-cask jobs"
    - "Release signing inputs sourced from GitHub Secrets and injected at runtime"

key-files:
  created:
    - .github/workflows/ci.yml
    - .github/workflows/release.yml
    - scripts/create-dmg.sh
  modified:
    - .github/workflows/release.yml

key-decisions:
  - "Use macos-26 runners for both CI and release workflows to match FSKit/macOS 26 SDK requirements"
  - "Manual release approval is enforced with environment: production before publishing assets"

patterns-established:
  - "Temporary keychain import + partition list setup for Developer ID certificate in CI"
  - "Notarize and staple DMG artifacts, then publish checksum alongside the installer"

# Metrics
duration: 2 min
completed: 2026-02-06
---

# Phase 8 Plan 02: CI/CD Release Automation Summary

**GitHub Actions CI and release automation that builds/tests PRs and turns SemVer tags into signed, notarized DMG releases with checksum publishing and cask bumping.**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-06T14:09:04Z
- **Completed:** 2026-02-06T14:11:51Z
- **Tasks:** 2/2
- **Files modified:** 3

## Accomplishments
- Added `.github/workflows/ci.yml` for pull-request build/test checks on `macos-26` with signing disabled for CI
- Added `.github/workflows/release.yml` with `build-sign-notarize`, `publish` (manual gate), and `bump-cask` jobs
- Implemented certificate import into a temporary keychain including `security set-key-partition-list` for codesign access
- Added DMG notarization/stapling and checksum generation before upload to GitHub Release
- Added `scripts/create-dmg.sh` helper that builds installer DMGs with an Applications symlink via `--app-drop-link`

## Task Commits

Each task was committed atomically:

1. **Task 1: Create PR build+test CI workflow** - `6e19bad` (feat)
2. **Task 2: Create release workflow and DMG script** - `ccef4b5` (feat)

Additional verification-driven fix:

- **Post-task fix: secret-driven signing identity** - `6e62f9e` (fix)

## Files Created/Modified
- `.github/workflows/ci.yml` - Pull-request CI build/test workflow with concurrency cancellation and non-signing build flags
- `.github/workflows/release.yml` - End-to-end release pipeline including archive/export/sign/notarize/staple/checksum/publish/cask bump
- `scripts/create-dmg.sh` - Executable helper script for deterministic DMG creation with drag-to-Applications UX

## Decisions Made
- Kept release pipeline fail-closed with no `continue-on-error` in signing/notarization/publish paths.
- Used `environment: production` as the explicit manual approval gate before GitHub Release publication.
- Sourced both `APPLE_TEAM_ID` and `APPLE_SIGNING_IDENTITY` from secrets to avoid hardcoded signing metadata.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Removed hardcoded signing identity from release workflow**
- **Found during:** Overall verification after Task 2
- **Issue:** Workflow originally used a hardcoded `CODE_SIGN_IDENTITY`, conflicting with the requirement that signing values come from secrets/env vars
- **Fix:** Added `APPLE_SIGNING_IDENTITY` secret usage for archive signing and runtime export plist injection
- **Files modified:** `.github/workflows/release.yml`
- **Verification:** YAML validated and secret references confirmed in signing/export steps
- **Committed in:** `6e62f9e`

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Kept behavior aligned with release goals while improving secret hygiene and requirement compliance.

## Authentication Gates

None.

## Issues Encountered
None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Ready for final phase wrap-up and verification tasks after CI/CD wiring
- Release jobs now reference all required signing/notarization secrets and produce DMG + checksum artifacts

---
*Phase: 08-distribution*
*Completed: 2026-02-06*
