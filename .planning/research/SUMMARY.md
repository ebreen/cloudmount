# Project Research Summary

**Project:** CloudMount
**Domain:** FUSE-based cloud storage filesystem on macOS
**Researched:** 2026-02-02
**Confidence:** HIGH

## Executive Summary

CloudMount is a FUSE-based filesystem that mounts S3-compatible cloud storage (AWS S3, Backblaze B2) as native macOS volumes. Based on research of production implementations like s3fs-fuse, gcsfuse, and Mountain Duck, the recommended approach uses **macFUSE** as the kernel extension, **fuser** (Rust) for the FUSE userspace library, **Tauri** for the menu bar UI, and **aws-sdk-s3** for cloud storage operations. This stack provides native macOS integration with a modern, memory-safe Rust backend.

The key insight from research is that FUSE filesystems have well-established patterns but require careful attention to **asynchronous operations**, **metadata caching**, and **resource management**. The biggest risks are synchronous uploads blocking the filesystem (causing Finder beachballs), directory listing performance death spirals with large buckets, and macFUSE kernel extension installation friction. These are all solvable with proper architecture but must be addressed from the start.

For a single-day MVP, the recommended strategy is to build an **online-only filesystem** (no local caching) with basic read/write operations, accepting that large file uploads will block. This validates the core FUSE integration and S3 connectivity. Smart synchronization, offline mode, and background uploads should be deferred to post-MVP phases.

## Key Findings

### Recommended Stack

The stack is well-established for this domain with mature, production-tested components. **macFUSE 5.1.3** is the only production-ready FUSE implementation for macOS, supporting both the legacy kernel backend (best performance, requires Recovery Mode setup) and the new FSKit backend (macOS 15.4+, no kernel extension). **fuser 0.16.0** provides the standard Rust FUSE interface with `spawn_mount2()` for background mounting. **Tauri 2.9** enables native-feeling menu bar apps using system WKWebView (no bundled Chromium). **aws-sdk-s3 1.121.0** provides full S3 API support including multipart uploads and works with any S3-compatible storage via endpoint configuration.

**Core technologies:**
- **macFUSE 5.1.3**: FUSE kernel extension for macOS — only production-ready option, supports both kernel and FSKit backends
- **fuser 0.16.0**: Rust FUSE userspace library — standard low-level interface, leverages Rust ownership model
- **Tauri 2.9**: Desktop app framework — native menu bar apps with Rust backend, small binary size
- **aws-sdk-s3 1.121.0**: S3 API client — official AWS SDK, works with B2/MinIO via endpoint config
- **Tokio 1.43+**: Async runtime — required for AWS SDK and async filesystem operations

### Expected Features

Research of competitors (Mountain Duck, ExpanDrive, s3fs-fuse) reveals clear feature tiers. Users expect basic mounting and file operations; differentiators like smart sync and offline mode are complex and should be deferred.

**Must have (table stakes):**
- Status bar menu — core interaction pattern for macOS menu bar apps
- Mount/unmount buckets — fundamental capability, requires macFUSE integration
- Basic file operations — read, write, list, delete via FUSE callbacks
- S3 credential management — secure storage in macOS Keychain
- Connection status indicator — visual feedback on mount state
- Finder integration — files appear in /Volumes/ like local volumes

**Should have (competitive):**
- Multiple bucket support — power users have multiple buckets
- Auto-mount on startup — convenience feature
- Quick mount/unmount — one-click toggle from menu
- Disk usage display — show bucket size in menu

**Defer (v2+):**
- Smart synchronization — local cache + background sync (HIGH complexity)
- Offline mode — requires smart sync foundation
- Sync status badges — visual indicators in Finder
- Client-side encryption — Cryptomator integration

### Architecture Approach

The architecture follows a layered pattern with clear separation: Tauri provides the UI layer (menu bar, settings), the Rust backend handles orchestration and IPC, and a FUSE bridge implements the filesystem operations. This mirrors successful implementations like gcsfuse and s3fs-fuse.

**Major components:**
1. **Tauri Application (Rust)** — Orchestration layer, IPC handling, native macOS integration
2. **Mount Manager** — Mount/unmount lifecycle, health checks, FUSE process management
3. **Config Store** — Secure credential storage using macOS Keychain
4. **FUSE Filesystem (Rust/fuser)** — FUSE trait implementation, metadata caching
5. **S3 Client** — AWS SDK integration, streaming operations, multipart uploads

Key patterns to follow: implement TTL-based metadata caching (critical for directory performance), use streaming for file operations (never buffer entire files), and use async/await throughout to avoid blocking FUSE handlers.

### Critical Pitfalls

Research of s3fs-fuse GitHub issues and macFUSE documentation revealed eight critical pitfalls that have caused production issues:

1. **Synchronous upload on close blocking all operations** — When a file is closed after writing, uploading synchronously before returning blocks the entire filesystem. **Avoid:** Implement async upload with local staging cache; for MVP, accept limitation and document it.

2. **Directory listing performance death spiral** — Listing directories with thousands of files becomes orders of magnitude slower than direct S3 API calls due to required stat calls. **Avoid:** Implement aggressive metadata caching with TTL; add `nobrowse` mount option to exclude from Spotlight.

3. **Cache coherency and stale data corruption** — FUSE filesystems cache content locally with no invalidation when S3 objects change externally. **Avoid:** Implement short cache TTLs (5-30 seconds); check ETag on open; document that external modifications require remount.

4. **macFUSE kernel extension installation hell** — macOS actively resists loading kernel extensions, requiring user approval and sometimes Recovery Mode. **Avoid:** Use macFUSE 4.x/5.x with clear installation instructions; implement pre-flight checks with helpful error messages.

5. **Memory explosion and OOM kills** — Writing large files causes unbounded memory growth when content is buffered before upload. **Avoid:** Implement streaming upload with multipart; set maximum cache size with LRU eviction.

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Foundation & Setup
**Rationale:** Must establish Tauri app shell and verify macFUSE is properly installed before any filesystem work can begin. This phase has the highest user friction risk (kext installation).
**Delivers:** Basic Tauri menu bar app, macFUSE detection and setup guidance, configuration storage schema
**Addresses:** Status bar menu (table stakes), credential settings (table stakes)
**Avoids:** macFUSE installation hell (pitfall #4)

### Phase 2: Core FUSE Integration
**Rationale:** The hardest technical challenge is FUSE filesystem implementation. Must get basic mount/unmount and metadata operations working before file I/O.
**Delivers:** FUSE mount/unmount to /Volumes/, getattr and readdir implementations, metadata caching layer
**Uses:** fuser 0.16.0, macFUSE 5.1.3
**Implements:** FUSE Filesystem trait, Mount Manager
**Avoids:** Directory listing performance death spiral (pitfall #2), cache coherency issues (pitfall #3), file descriptor exhaustion (pitfall #5)

### Phase 3: S3 Integration & File Operations
**Rationale:** Once FUSE framework is working, add S3 connectivity and basic file I/O. This validates end-to-end data flow.
**Delivers:** S3 client configuration, file read with range requests, file write with multipart upload, error handling
**Uses:** aws-sdk-s3 1.121.0, Tokio 1.43+
**Implements:** S3 Client component
**Avoids:** S3 API quirks with B2 (pitfall #6), memory explosion (pitfall #7)

### Phase 4: UI Polish & Experience
**Rationale:** With core functionality working, add user-facing features that make the app feel complete.
**Delivers:** Settings window for credentials, connection status indicators, mount/unmount controls, error reporting
**Addresses:** Connection status (table stakes), multiple buckets (should-have), quick mount/unmount (should-have)
**Avoids:** UX pitfalls (silent failures, no progress indication)

### Phase 5: Reliability & Edge Cases
**Rationale:** Production readiness requires handling network failures, sleep/wake cycles, and recovery scenarios.
**Delivers:** Auto-reconnect on network failure, sleep/wake handling, health checks, graceful error recovery
**Avoids:** Transport endpoint disconnection (pitfall #8)

### Phase 6: Performance (Post-MVP)
**Rationale:** Smart sync and background uploads are complex features that should only be attempted after core stability is proven.
**Delivers:** Local file caching, background upload queue, sync status in menu
**Addresses:** Smart synchronization (differentiator), background uploads (differentiator)
**Avoids:** Synchronous upload blocking (pitfall #1)

### Phase Ordering Rationale

- **Foundation before FUSE:** Cannot implement filesystem without working app shell and macFUSE verification
- **FUSE before S3:** Must have FUSE framework working before adding cloud storage operations
- **S3 before UI polish:** Core data flow must work before investing in UI features
- **Reliability before performance:** Must handle errors gracefully before optimizing for speed
- **Online-only first:** Caching and offline mode add significant complexity; validate core FUSE integration first

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2 (Core FUSE):** Complex integration between fuser crate and macFUSE; may need specific API research for spawn_mount2() and trait implementation
- **Phase 3 (S3 Integration):** Backblaze B2 has subtle API differences from AWS S3; needs endpoint and authentication research
- **Phase 6 (Performance):** Smart synchronization patterns vary widely; needs research on cache invalidation strategies

Phases with standard patterns (skip research-phase):
- **Phase 1 (Foundation):** Tauri setup is well-documented with established patterns
- **Phase 4 (UI Polish):** Standard Tauri IPC and menu bar patterns

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All components are mature, production-tested with official documentation. macFUSE is the only viable FUSE option for macOS. |
| Features | HIGH | Clear differentiation between table stakes and differentiators based on competitor analysis (Mountain Duck, ExpanDrive, s3fs-fuse). |
| Architecture | HIGH | Well-established patterns from gcsfuse, s3fs-fuse, and goofys. Tauri IPC is documented and stable. |
| Pitfalls | MEDIUM-HIGH | Issues are well-documented in s3fs-fuse GitHub issues and macFUSE wiki. Specific mitigations may need validation during implementation. |

**Overall confidence:** HIGH

### Gaps to Address

- **Write buffering strategy:** Research didn't resolve optimal buffer size before upload (affects consistency vs performance tradeoff)
- **Cache invalidation:** No clear pattern for detecting external S3 changes; may need polling or manual flush
- **Multi-bucket architecture:** Simultaneous mounts need design decisions on resource sharing
- **B2-specific quirks:** While S3-compatible, B2 has subtle differences that need testing

## Sources

### Primary (HIGH confidence)
- **macFUSE 5.1.3** — GitHub releases (Dec 23, 2025) — Verified current version with FSKit backend support
- **fuser 0.16.0** — docs.rs and Context7 (/websites/rs_fuser) — Verified API stability, spawn_mount2() recommended
- **Tauri 2.9** — Context7 (/tauri-apps/tauri) and official docs — Verified tray-icon and native-tls features
- **aws-sdk-s3 1.121.0** — docs.rs and Context7 (/awslabs/aws-sdk-rust) — Verified S3 client usage patterns
- **gcsfuse** — https://github.com/googlecloudplatform/gcsfuse — Architecture patterns, caching strategies
- **s3fs-fuse** — https://github.com/s3fs-fuse/s3fs-fuse — POSIX compatibility, multipart upload, known issues

### Secondary (MEDIUM confidence)
- **Mountain Duck documentation** — https://docs.mountainduck.io/ — Feature comparison, connect modes
- **goofys** — https://github.com/kahing/goofys — Performance optimizations
- **easy_fuser** — Context7 (/websites/rs_easy_fuser) — Evaluated as alternative to fuser

### Tertiary (LOW confidence)
- **FUSE-T** — Alternative to macFUSE (no kext) — Less mature, different tradeoffs, needs validation
- **FSKit (macOS 15.4+)** — Apple's new user-space filesystem — Limited documentation, narrow version support

---
*Research completed: 2026-02-02*
*Ready for roadmap: yes*
