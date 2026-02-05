---
phase: 05-build-system-b2-client
plan: 04
subsystem: b2-client
tags: [b2, auth, cache, actor, swift-concurrency, cryptokit]

requires:
  - plan: 05-02
    provides: CredentialStore, B2Account, MountConfiguration, CacheSettings, SharedDefaults
  - plan: 05-03
    provides: B2Types, B2Error, B2HTTPClient
provides:
  - B2AuthManager actor with transparent token refresh
  - MetadataCache actor with TTL-based directory/file caching
  - FileCache actor with on-disk LRU eviction
  - B2Client actor with 8 high-level operations
affects: [05-05 UI rewiring, 06 FSKit extension]

tech-stack:
  added: [CryptoKit]
  patterns: [actor isolation, withAutoRefresh retry, LRU cache, TTL cache]

key-files:
  created:
    - CloudMountKit/B2/B2AuthManager.swift
    - CloudMountKit/B2/B2Client.swift
    - CloudMountKit/Cache/MetadataCache.swift
    - CloudMountKit/Cache/FileCache.swift

key-decisions:
  - "B2AuthManager uses actors for thread-safe token management"
  - "withAutoRefresh captures AuthContext snapshot to avoid mutable var in Sendable closure"
  - "FileCache uses SHA-256 hashing for safe disk file names"
  - "MetadataCache invalidation cascades to parent directory"

duration: 4min
completed: 2026-02-05
---

# Phase 5 Plan 4: B2AuthManager + B2Client + Caches Summary

**Completed the CloudMountKit B2 client stack with auth manager, metadata cache, file cache, and high-level client actor**

## Performance

- **Duration:** 4 min
- **Tasks:** 2
- **Files created:** 4

## Accomplishments
- B2AuthManager actor: authenticates on init, provides refresh() for 401 recovery
- MetadataCache actor: in-memory TTL cache (default 5min) for directory listings and file metadata, with parent-cascading invalidation
- FileCache actor: on-disk LRU cache at ~/Library/Caches/CloudMount/ with SHA-256 file naming and configurable max size (default 1GB)
- B2Client actor: 8 high-level operations (listBuckets, listDirectory, downloadFile, uploadFile, deleteFile, copyFile, createFolder, rename) with transparent auth refresh and cache integration
- Upload uses SHA-1 via CryptoKit's Insecure.SHA1 (B2 requirement)
- All write operations invalidate relevant cache entries

## Task Commits

1. **Task 1: B2AuthManager + MetadataCache + FileCache** - `305c62f` (feat)
2. **Task 2: B2Client actor** - `f55ec50` (feat)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Auto-fix] Swift 6 concurrency: captured mutable var in Sendable closure**
- **Issue:** `nextFileName` var captured in `withAutoRefresh` closure violated Swift 6 strict concurrency
- **Fix:** Captured to local `let startName` before passing to closure
- **Impact:** None — standard Swift 6 pattern

---

*Phase: 05-build-system-b2-client*
*Completed: 2026-02-05*
