# Phase 6: FSKit Filesystem - Context

**Gathered:** 2026-02-05
**Status:** Ready for planning

<domain>
## Phase Boundary

FSKit extension that mounts a B2 bucket as a local volume in Finder. Users can browse directories, read/write files, and delete items. macOS metadata noise is suppressed. Phase 7 handles the host app UI integration (mount/unmount controls, status display). This phase delivers the filesystem extension itself.

</domain>

<decisions>
## Implementation Decisions

### Caching & read behavior
- Download file content on open, cache to a local temp directory (per-mount cache folder)
- Cache keyed by B2 file ID + version — if remote file changes, re-download on next open
- Directory listings cached with a short TTL (metadata cache from Phase 5's B2Client); stat calls served from cache when fresh
- Large files: download fully on open (no partial/range reads for v1) — simplicity over optimization
- Cache eviction: LRU with a configurable max size (default 1GB); evict when cache exceeds limit
- On open, if cached version matches remote (same fileId): serve from cache without re-downloading

### Write behavior & sync
- Write-on-close semantics: buffer writes locally, upload to B2 when file handle is closed
- Writes go to a temp staging file; on close, upload the complete file to B2 (B2 requires complete uploads anyway)
- If upload fails on close: return I/O error to the calling process, keep the staged file for retry
- No conflict detection in v1 — last writer wins (B2's natural behavior); file versioning in B2 preserves history
- New file creation: create a local placeholder immediately, upload on close
- Directory creation: upload a zero-byte `.bzEmpty` marker object (B2 convention for empty directories)

### Finder presentation
- Volume name: the bucket name (e.g., "my-bucket") as displayed in Finder sidebar
- Volume icon: use a cloud drive icon to distinguish from local volumes (SF Symbol or custom asset)
- File sizes: report actual B2 content length; directories show 0 bytes
- Timestamps: use B2's `uploadTimestamp` for modification date; creation date = modification date (B2 doesn't track creation separately)
- B2 flat namespace mapped to directories: split on `/` delimiter to present folder hierarchy
- Hidden files (dotfiles): show them normally — Finder hides them by default anyway

### macOS metadata suppression
- Suppress `.DS_Store` files — intercept create/write and return success without uploading to B2
- Suppress `._` AppleDouble resource fork files — same approach, silent no-op
- Suppress `.Spotlight-V100` and any Spotlight indexing — return ENOTSUP or block at the directory level
- Suppress `.Trashes` and Trash operations — return EPERM for trash moves; users delete directly
- Suppress `.fseventsd` — no-op for FSEvents metadata
- General pattern: maintain an in-memory blocklist of macOS metadata path prefixes; any matching create/write/mkdir silently succeeds without B2 API calls

### OpenCode's Discretion
- Exact cache directory location and naming scheme (likely ~/Library/Caches/CloudMount/ or app container)
- FSKit delegate method organization and internal class structure
- Error retry logic details (retry count, backoff strategy for uploads)
- Temp file naming and cleanup strategy
- How to report filesystem capacity/free space to Finder (B2 buckets have no fixed size)
- Thread/actor isolation model within the FSKit extension

</decisions>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. User delegated all decisions to OpenCode.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 06-fskit-filesystem*
*Context gathered: 2026-02-05*
