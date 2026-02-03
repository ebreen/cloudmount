# Phase 3: File I/O - Context

**Gathered:** 2026-02-03
**Status:** Ready for planning

<domain>
## Phase Boundary

Users can read, write, and delete files through the mounted FUSE volume. This phase implements the FUSE file operations (read, write, create, delete, rename) that translate to B2 API calls. Connection failures show clear error messages and network interruptions are handled gracefully. Upload progress and operation status are surfaced through the status bar.

</domain>

<decisions>
## Implementation Decisions

### File read & caching
- Read strategy (stream vs full download, caching approach): OpenCode's discretion based on research
- Must support any file size — no artificial limits
- Staleness handling (what happens when remote changes while file is open): OpenCode's discretion
- Local caching policy (expiry, eviction): OpenCode's discretion

### Write & save behavior
- New file creation: fully supported — users can create files directly on the mount
- Folder creation: fully supported — users can mkdir on the mount (B2 prefix-based folders)
- Rename/move: fully supported — implement via copy + delete on B2
- Copy/paste into mount: fully supported — Finder drag & drop uploads to B2
- Write model: write locally, upload asynchronously — saves return immediately, upload happens in background
- Upload activity: show in status bar (e.g., "Uploading file.txt...")
- Upload timing (on close vs on save): OpenCode's discretion
- Failed upload recovery: OpenCode's discretion

### Delete & trash behavior
- Delete semantics (permanent vs Trash): OpenCode's discretion
- Recursive folder deletion: supported — deleting non-empty folders removes all contents
- B2 versioning: ignore entirely — always work with latest version, delete hides the file
- Delete activity: show in status bar, consistent with upload feedback

### Error feedback to user
- Error channel: both Finder error dialog (immediate) AND status bar history of recent errors
- Network loss behavior: keep mount alive, fail individual operations with errors, auto-reconnect when network returns
- Connection health indicator: status bar icon changes color or shows warning badge when B2 is unreachable
- Error tone: technical but clear (e.g., "Upload failed: connection timeout after 30s. File saved locally.")

### OpenCode's Discretion
- File read strategy (streaming vs download, caching approach and eviction)
- Upload timing trigger (on file close vs on each save)
- Failed upload recovery strategy (retry, keep local, notify)
- Staleness handling for cached files
- Delete semantics (permanent delete vs macOS Trash support)
- Exact status bar UI for operation feedback
- Temp file management during writes

</decisions>

<specifics>
## Specific Ideas

- Async writes are preferred over blocking — user should not wait for B2 upload to complete on save
- Status bar should show activity for both uploads and deletes — user always knows what's happening
- Error messages should be informative and developer-friendly, not dumbed down
- Connection health should be visible at a glance from the status bar icon

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 03-file-io*
*Context gathered: 2026-02-03*
