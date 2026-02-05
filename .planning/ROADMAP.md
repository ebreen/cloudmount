# Roadmap: CloudMount

## Milestones

- ✅ **v1.0 MVP** - Phases 1-4 (shipped 2026-02-05)
- 🚧 **v2.0 FSKit Pivot & Distribution** - Phases 5-8 (in progress)

## Phases

<details>
<summary>✅ v1.0 MVP (Phases 1-4) - SHIPPED 2026-02-05</summary>

See: .planning/milestones/v1.0-ROADMAP.md for full details.

- [x] Phase 1: Foundation (4/4 plans)
- [x] Phase 2: Core Mount & Browse (4/4 plans)
- [x] Phase 3: File I/O (4/4 plans)
- [x] Phase 4: Configuration & Polish (2/2 plans)

</details>

### 🚧 v2.0 FSKit Pivot & Distribution (In Progress)

**Milestone Goal:** Replace Rust FUSE daemon with Apple's FSKit framework for a pure-Swift architecture, then package and distribute via GitHub Releases and Homebrew with CI/CD automation.

**Phase Numbering:**
- Integer phases (5, 6, 7, 8): Planned milestone work
- Decimal phases (5.1, 6.1): Urgent insertions (marked with INSERTED)

- [ ] **Phase 5: Build System & B2 Client** - Xcode project migration + Swift B2 API client
- [ ] **Phase 6: FSKit Filesystem** - FSKit extension with full volume operations wired to B2
- [ ] **Phase 7: App Integration** - Replace daemon with mount orchestration and update UI
- [ ] **Phase 8: Distribution** - Code signing, notarization, DMG, Homebrew Cask, CI/CD pipeline

## Phase Details

### Phase 5: Build System & B2 Client
**Goal**: Project builds as an Xcode multi-target app (host + extension + shared framework) with a complete Swift B2 API client ready for FSKit integration
**Depends on**: Phase 4 (v1.0 complete)
**Requirements**: BUILD-01, BUILD-02, BUILD-03, BUILD-04, BUILD-05, B2-01, B2-02, B2-03, B2-04, B2-05, B2-06, B2-07, B2-08, B2-09, B2-10
**Success Criteria** (what must be TRUE):
  1. Xcode project builds with three targets (host app, FSKit extension, shared framework) and runs the existing menu bar UI
  2. Rust daemon source, Cargo files, and all macFUSE detection code are removed from the repository
  3. App Group is configured and credentials stored via Keychain are accessible from both host app and extension targets
  4. Swift B2 client can authenticate, list files, download, upload, delete, copy, and create folders against a real B2 bucket
  5. B2 auth tokens refresh automatically without user intervention, and metadata cache reduces redundant API calls
**Plans:** 5 plans

Plans:
- [x] 05-01-PLAN.md — Remove Rust/macFUSE/SPM + create Xcode project with 3 targets
- [x] 05-02-PLAN.md — Native Keychain credential store + account/mount config models
- [ ] 05-03-PLAN.md — B2 API types, error types, and HTTP client (low-level)
- [ ] 05-04-PLAN.md — B2AuthManager + B2Client actor + metadata/file caches
- [ ] 05-05-PLAN.md — Rewire host app UI to CloudMountKit stack

### Phase 6: FSKit Filesystem
**Goal**: Users can mount a B2 bucket via the FSKit extension and browse, read, write, and delete files in Finder as if it were a local volume
**Depends on**: Phase 5
**Requirements**: FSKIT-01, FSKIT-02, FSKIT-03, FSKIT-04, FSKIT-05, FSKIT-06, FSKIT-07
**Success Criteria** (what must be TRUE):
  1. FSKit extension loads via `mount -F` and appears as a mounted volume in Finder
  2. User can browse directories and see files with correct names, sizes, and timestamps
  3. User can open/read files from the mounted volume (downloads from B2 with local caching) and create/write new files (uploads to B2 on close)
  4. User can delete files and create/remove directories through Finder
  5. macOS metadata files (.DS_Store, .Spotlight-V100, ._ files) are suppressed and don't generate B2 API calls
**Plans**: TBD

Plans:
- [ ] 06-01: TBD
- [ ] 06-02: TBD
- [ ] 06-03: TBD

### Phase 7: App Integration
**Goal**: Users can mount/unmount B2 buckets from the menu bar UI with clear status feedback and guided setup for the FSKit extension
**Depends on**: Phase 6
**Requirements**: APP-01, APP-02, APP-03, APP-04, APP-05
**Success Criteria** (what must be TRUE):
  1. User can mount and unmount B2 buckets from the status bar menu (MountClient replaces DaemonClient)
  2. Menu bar UI accurately reflects mount status (mounted/unmounted) in real time
  3. First launch detects whether FSKit extension is enabled and guides user to System Settings if not
  4. All macFUSE references are gone from the UI, and bucket listing works in Settings for credential setup
**Plans**: TBD

Plans:
- [ ] 07-01: TBD
- [ ] 07-02: TBD

### Phase 8: Distribution
**Goal**: Users can install CloudMount via DMG download or `brew install --cask cloudmount`, with releases automated through CI/CD
**Depends on**: Phase 7
**Requirements**: PKG-01, PKG-02, PKG-03, PKG-04, PKG-05, BREW-01, BREW-02, BREW-03, CI-01, CI-02, CI-03, CI-04
**Success Criteria** (what must be TRUE):
  1. App is code-signed with Developer ID, notarized, and stapled — launches without Gatekeeper warnings on a clean Mac
  2. DMG with Applications symlink provides drag-to-install experience and is downloadable from GitHub Releases
  3. `brew install --cask cloudmount` from the project's tap installs the app with correct macos constraint, caveats, and zap stanza
  4. Pushing a version tag triggers automated build → sign → notarize → DMG → GitHub Release → Cask bump pipeline
  5. Pull requests run build + test checks automatically
**Plans**: TBD

Plans:
- [ ] 08-01: TBD
- [ ] 08-02: TBD
- [ ] 08-03: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 5 → 6 → 7 → 8

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation | v1.0 | 4/4 | Complete | 2026-02-02 |
| 2. Core Mount & Browse | v1.0 | 4/4 | Complete | 2026-02-03 |
| 3. File I/O | v1.0 | 4/4 | Complete | 2026-02-03 |
| 4. Configuration & Polish | v1.0 | 2/2 | Complete | 2026-02-03 |
| 5. Build System & B2 Client | v2.0 | 2/5 | In progress | - |
| 6. FSKit Filesystem | v2.0 | 0/TBD | Not started | - |
| 7. App Integration | v2.0 | 0/TBD | Not started | - |
| 8. Distribution | v2.0 | 0/TBD | Not started | - |
