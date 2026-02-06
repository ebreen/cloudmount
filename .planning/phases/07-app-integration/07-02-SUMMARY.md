---
phase: 07-app-integration
plan: 02
subsystem: ui
tags: [swiftui, appstate, mount-orchestration, onboarding, fskit, menu-bar]

# Dependency graph
requires:
  - phase: 07-app-integration/01
    provides: MountClient, MountMonitor, ExtensionDetector infrastructure
  - phase: 06-fskit-filesystem
    provides: FSKit extension with b2:// URL scheme
  - phase: 05-build-system
    provides: CloudMountKit framework, MountConfiguration model, Keychain credential store
provides:
  - AppState mount/unmount orchestration via MountClient with real-time MountStatus tracking
  - MenuContentView with live mount/unmount buttons and per-mount status indicators
  - OnboardingView for guided FSKit extension setup with System Settings deep link
  - MountMonitor lifecycle in CloudMountApp for push-based status updates
affects: [08-distribution]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "MountStatus enum on AppState for per-config mount state tracking"
    - "Combine sink on MountMonitor.$mountedPaths for external mount/unmount detection"
    - "OnboardingView sheet triggered by extensionDetector.needsSetup"

key-files:
  created:
    - CloudMount/Views/OnboardingView.swift
  modified:
    - CloudMount/AppState.swift
    - CloudMount/Views/MenuContentView.swift
    - CloudMount/CloudMountApp.swift

key-decisions:
  - "Per-config MountStatus enum on AppState — keyed by UUID, enables per-mount status indicators"
  - "Combine sink on MountMonitor.$mountedPaths — detects external unmounts (Finder eject, diskutil) without polling"
  - "Onboarding triggered by extensionDetector.needsSetup — auto-detect on first launch, also triggered by .extensionNotEnabled mount error"

patterns-established:
  - "MountStatus state machine pattern: unmounted → mounting → mounted / error"
  - "Sheet-based onboarding from MenuBarExtra with .window style"

# Metrics
duration: ~10min (across checkpoint interaction)
completed: 2026-02-06
---

# Phase 7 Plan 2: UI Integration Summary

**AppState mount orchestration with MountClient, live mount/unmount buttons in MenuContentView, and OnboardingView for guided FSKit extension setup — UI code builds and works, but end-to-end mount blocked by FSKit V2 runtime issue**

## Performance

- **Duration:** ~10 min (including checkpoint interaction)
- **Tasks:** 2/2 auto tasks completed + 1 checkpoint (issues found)
- **Files modified:** 10 (across 3 commits including orchestrator fix commit)

## Accomplishments
- AppState fully rewired: mount/unmount methods call MountClient, MountStatus enum tracks per-config state, MountMonitor Combine subscription detects external mount/unmount events
- MenuContentView mount buttons are live with dynamic labels (Mount/Unmount/Mounting…/Unmounting…), status-dependent icons, and per-mount inline error display
- OnboardingView created with step-by-step extension setup guide, System Settings deep link, and live extension status indicator
- CloudMountApp starts mount monitoring on first menu bar popover appear with single-fire guard
- All "Phase 7 stub" references removed from codebase

## Task Commits

Each task was committed atomically:

1. **Task 1: Rewire AppState with mount orchestration and update MenuContentView** - `bba2de1` (feat)
2. **Task 2: Create OnboardingView and update CloudMountApp lifecycle** - `2a7ca05` (feat)

**Orchestrator fix commit:**
- **FSKit V2 Info.plist, entitlements, mount point handling** - `f66b515` (fix) — discovered during checkpoint testing

## Files Created/Modified
- `CloudMount/AppState.swift` - Mount orchestration with MountClient, MountStatus enum, MountMonitor Combine subscription, ExtensionDetector startup check
- `CloudMount/Views/MenuContentView.swift` - Live mount/unmount buttons with status-dependent icons, labels, and per-mount error display
- `CloudMount/Views/OnboardingView.swift` - Extension setup guide with numbered steps, System Settings deep link, live status indicator
- `CloudMount/CloudMountApp.swift` - MountMonitor lifecycle with single-fire onAppear guard
- `CloudMount/MountClient.swift` - Mount point handling fix (orchestrator commit)
- `CloudMount/ExtensionDetector.swift` - Minor adjustment (orchestrator commit)
- `CloudMountExtension/Info.plist` - FSKit V2 EXAppExtensionAttributes fix (orchestrator commit)
- `CloudMountExtension/CloudMountExtension.entitlements` - Added required entitlements (orchestrator commit)
- `CloudMount.xcodeproj/project.pbxproj` - OnboardingView added to project

## Decisions Made
- Per-config MountStatus enum keyed by UUID — enables independent status tracking per bucket
- Combine sink on MountMonitor.$mountedPaths — reconciles mountStatuses when external tools (Finder, diskutil) mount/unmount volumes
- Onboarding auto-triggers via extensionDetector.needsSetup and also via .extensionNotEnabled MountError — covers both first-launch and failed-mount scenarios

## Deviations from Plan

### Auto-fixed Issues (Orchestrator)

**1. [Rule 3 - Blocking] FSKit V2 Info.plist and entitlements fixes**
- **Found during:** Checkpoint testing (human-verify)
- **Issue:** Extension found by fskitd but mount failed — Info.plist needed correct EXAppExtensionAttributes structure, entitlements needed com.apple.fskit.*, mount point handling needed adjustment
- **Fix:** Updated Info.plist to FSKit V2 format, added required entitlements, fixed mount point path construction in MountClient
- **Files modified:** CloudMountExtension/Info.plist, CloudMountExtension/CloudMountExtension.entitlements, CloudMount/MountClient.swift
- **Committed in:** f66b515

---

**Total deviations:** 1 auto-fixed (blocking)
**Impact on plan:** Fix was necessary for extension to be loadable by fskitd. Does not fully resolve the runtime issue (see Issues below).

## Issues Encountered

### FSKit V2 Runtime: "does not support operation mount"

**Severity:** Blocking for end-to-end mount functionality
**Scope:** Phase 6 extension issue, NOT a Phase 7 UI issue

During checkpoint human-verify testing:
- The CloudMount app UI works correctly: mount buttons are enabled, status indicators update, onboarding appears and detects extension state
- The extension is discovered by fskitd and appears in System Settings
- Extension is registered in enabledModules.plist
- BUT: `mount -F -t b2 b2://...` returns "does not support operation mount"
- fskitd finds the extension but cannot invoke the mount operation on it

**Root cause analysis:** FSKit V2's `FSUnaryFileSystemOperations` protocol registration under `EXAppExtensionAttributes` may have additional requirements not yet documented by Apple. The extension entry point, protocol conformance, and volume operations were implemented per WWDC25 sessions and FSKit headers, but the runtime dispatch from fskitd to the extension's `loadFileSystem` is not connecting.

**Resolution path:** This is a Phase 6 (FSKit Filesystem) issue requiring investigation into:
1. FSKit V2 extension point registration format
2. Whether `FSUnaryFileSystemOperations` requires additional entitlements or capabilities
3. Possible need for `FSEntityOperations` or different protocol conformance
4. Apple Developer Forums / Feedback Assistant for FSKit V2 runtime behavior

**Impact on Phase 7:** The UI integration code is complete and correct. All Phase 7 success criteria that are within UI control are met. The mount operation failure is an extension-layer issue.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 7 UI integration is complete — all code builds and UI is functional
- **Blocker for Phase 8 (Distribution):** FSKit V2 runtime mount issue must be resolved before distributing the app. The app can be signed, notarized, and packaged, but end-to-end mount won't work until the extension runtime issue is fixed
- Recommend: File Apple Feedback Assistant report for FSKit V2 `FSUnaryFileSystemOperations` mount dispatch, investigate alternative extension registration approaches
- Phase 8 planning can proceed for CI/CD and packaging work that doesn't depend on runtime mount

---
*Phase: 07-app-integration*
*Completed: 2026-02-06*
