# Roadmap: CloudMount

## Overview

Build CloudMount from foundation to functional product: start with app shell and macFUSE detection, implement core mount/unmount with directory browsing, add file read/write operations, and finish with configuration UI and polish. Each phase delivers observable capabilities that build toward the complete experience of mounting cloud storage as native macOS volumes.

## Phases

- [ ] **Phase 1: Foundation** - App shell, macFUSE detection, secure configuration storage
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
- [ ] 01-01: Initialize Tauri menu bar app with system tray icon
- [ ] 01-02: Implement macFUSE detection with installation guidance
- [ ] 01-03: Create secure credential storage using macOS Keychain
- [ ] 01-04: Build settings window skeleton

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
**Plans**: TBD

Plans:
- [ ] 02-01: Implement FUSE filesystem trait with getattr and readdir
- [ ] 02-02: Build mount manager for mount/unmount lifecycle
- [ ] 02-03: Add metadata caching layer for directory performance
- [ ] 02-04: Integrate mount status with status bar menu

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
- [ ] 03-01: Implement file read with S3 range requests
- [ ] 03-02: Implement file write with multipart upload
- [ ] 03-03: Implement file delete operation
- [ ] 03-04: Add error handling for network and S3 failures

### Phase 4: Configuration & Polish
**Goal**: Users can configure buckets through the UI and see complete status information
**Depends on**: Phase 3
**Requirements**: CONFIG-01, CONFIG-02, UI-03, UI-05
**Success Criteria** (what must be TRUE):
  1. User can add Backblaze B2 credentials (application key ID + key) through settings
  2. User can configure bucket name and mount point through settings
  3. Status bar menu shows disk usage for each mounted bucket
  4. Settings window provides complete configuration management
**Plans**: TBD

Plans:
- [ ] 04-01: Build credentials configuration form in settings
- [ ] 04-02: Implement bucket and mount point configuration
- [ ] 04-03: Add disk usage calculation and display in menu
- [ ] 04-04: Polish UI interactions and error feedback

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 0/4 | Not started | - |
| 2. Core Mount & Browse | 0/4 | Not started | - |
| 3. File I/O | 0/4 | Not started | - |
| 4. Configuration & Polish | 0/4 | Not started | - |

---
*Roadmap created: 2026-02-02*
*Requirements coverage: 18/18 v1 requirements mapped*
