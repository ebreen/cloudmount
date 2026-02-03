# Roadmap: CloudMount

## Overview

Build CloudMount from foundation to functional product: start with app shell and macFUSE detection, implement core mount/unmount with directory browsing, add file read/write operations, and finish with configuration UI and polish. Each phase delivers observable capabilities that build toward the complete experience of mounting cloud storage as native macOS volumes.

## Phases

- [x] **Phase 1: Foundation** - App shell, macFUSE detection, secure configuration storage *(Completed with Swift pivot)*
- [ ] **Phase 2: Core Mount & Browse** - Mount/unmount buckets, browse directories, see metadata in Finder
- [ ] **Phase 3: File I/O** - Read, write, and delete files through FUSE
- [ ] **Phase 4: Configuration & Polish** - Settings window, disk usage display, complete status bar experience

## Phase Details

### Phase 1: Foundation
**Goal**: Users can launch the app, verify macFUSE is installed, and have credentials securely stored
**Depends on**: Nothing (first phase)
**Requirements**: MOUNT-04, CONFIG-03, CONFIG-04, UI-01, ERROR-03
**Success Criteria** (what must be TRUE):
  1. User sees status bar icon immediately on app launch
  2. App detects if macFUSE is installed and shows clear guidance if missing
  3. Credentials are stored securely in macOS Keychain and persist between restarts
  4. Settings window can be opened from the status bar menu
**Plans**: TBD

Plans:
- [x] 01-01: Initialize menu bar app with system tray icon *(Swift/SwiftUI MenuBarExtra)*
- [x] 01-02: Implement macFUSE detection with installation guidance *(FileManager-based)*
- [x] 01-03: Create secure credential storage using macOS Keychain *(KeychainAccess library)*
- [x] 01-04: Build settings window skeleton *(Native SwiftUI TabView)*

**Note:** Phase 1 pivoted from Tauri/React to native Swift/SwiftUI mid-execution for better native UX.

### Phase 2: Core Mount & Browse
**Goal**: Users can mount buckets as local volumes and browse directories in Finder
**Depends on**: Phase 1
**Requirements**: MOUNT-01, MOUNT-02, MOUNT-03, FILE-01, FILE-05, UI-02, UI-04
**Success Criteria** (what must be TRUE):
  1. User can mount a Backblaze B2 bucket that appears in /Volumes/ like a native drive
  2. User can browse directories in the mounted bucket through Finder
  3. File metadata (size, modification time) displays correctly in Finder
  4. User can unmount the bucket from the status bar menu with one click
  5. Status bar menu shows list of configured buckets with mount status
**Plans**: 4 plans in 2 waves

Plans:
- [ ] 02-01-PLAN.md — Implement FUSE filesystem trait with getattr and readdir
- [ ] 02-02-PLAN.md — Build mount manager for mount/unmount lifecycle
- [ ] 02-03-PLAN.md — Add metadata caching layer for directory performance
- [ ] 02-04-PLAN.md — Integrate mount status with status bar menu

### Phase 3: File I/O
**Goal**: Users can read, write, and delete files through the mounted volume
**Depends on**: Phase 2
**Requirements**: FILE-02, FILE-03, FILE-04, ERROR-01, ERROR-02
**Success Criteria** (what must be TRUE):
  1. User can open and read files from the mounted bucket
  2. User can write files to the mounted bucket (accepting sync upload limitation for MVP)
  3. User can delete files from the mounted bucket
  4. Connection failures show clear, user-friendly error messages
  5. Network interruptions are handled gracefully without crashing the app
**Plans**: TBD

Plans:
- [ ] 03-01: File Read with Local Caching & API Minimization (Wave 1)
- [ ] 03-02: File Write with Upload on Close (Wave 2)
- [ ] 03-03: File Delete, Mkdir, and Rename Operations (Wave 2)
- [ ] 03-04: Error Handling, Retry Logic, and Connection Health (Wave 3)

### Phase 4: Configuration & Polish
**Goal**: Users can configure buckets through the UI and see complete status information
**Depends on**: Phase 3
**Requirements**: CONFIG-01, CONFIG-02, UI-03, UI-05
**Success Criteria** (what must be TRUE):
  1. User can add Backblaze B2 credentials (application key ID + key) through settings
  2. User can configure bucket name and mount point through settings
  3. Status bar menu shows disk usage for each mounted bucket
  4. Settings window provides complete configuration management
**Plans**: 2 plans in 2 waves

Plans:
- [ ] 04-01-PLAN.md — Bucket config persistence and disk usage IPC protocol
- [ ] 04-02-PLAN.md — Disk usage display in menu and settings polish

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 4/4 | Complete | 2026-02-02 |
| 2. Core Mount & Browse | 0/4 | Planned | - |
| 3. File I/O | 0/4 | Planned | - |
| 4. Configuration & Polish | 0/2 | Planned | - |

---
*Roadmap created: 2026-02-02*
*Phase 1 completed: 2026-02-02 (pivoted to Swift/SwiftUI)*
*Requirements coverage: 18/18 v1 requirements mapped*
