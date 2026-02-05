# Phase 5: Build System & B2 Client - Context

**Gathered:** 2026-02-05
**Status:** Ready for planning

<domain>
## Phase Boundary

Project builds as an Xcode multi-target app (host app + FSKit extension + shared framework) with a complete Swift B2 API client ready for FSKit integration. Rust daemon, Cargo files, and all macFUSE detection code are removed from the repository. App Group is configured and credentials stored via Keychain are accessible from both host app and extension targets.

</domain>

<decisions>
## Implementation Decisions

### B2 client API surface
- Layered architecture: low-level HTTP layer mapping 1:1 to B2 API endpoints + high-level domain API with convenience methods (listFiles, download, upload)
- B2 client lives in the shared framework — accessible to both host app and FSKit extension
- Host app needs direct B2 access for credential validation, bucket listing, and potentially storage usage display

### Caching & token strategy
- Metadata cache with ~5 minute TTL for directory listings and bucket info
- Immediate cache invalidation on local writes (user's own changes reflected instantly)
- Token refresh, cache persistence (memory vs disk), and cache layer architecture are at OpenCode's discretion

### Credential sharing model
- Keychain with shared access group for secrets (B2 application key ID, application key)
- App Group UserDefaults for non-secret config (selected bucket, mount point, cache settings)
- No migration from v1.0 credentials — clean slate, users re-enter credentials in v2.0
- Support multiple B2 accounts/key pairs stored simultaneously
- Support multiple simultaneous mounts — each bucket appears as its own Finder volume
- Credential and config model must be designed for multi-account, multi-mount from the start

### Rust removal approach
- Remove Rust/Cargo files and macFUSE detection code first (plan 1), establishing a clean foundation
- Remove ALL macFUSE references from the codebase in this phase, including UI detection code — not deferred to Phase 7
- Swift B2 client is a fresh start on behavior — use Rust code from git history as loose reference for edge cases, but redesign interaction patterns from scratch
- Write idiomatic Swift, not a line-by-line translation of Rust

### OpenCode's Discretion
- Large file (multi-part) upload: include in Phase 5 or defer to Phase 6
- Async concurrency pattern (async/await only vs also providing completion handlers)
- Token refresh strategy (transparent auto-refresh vs fail-and-notify)
- Cache persistence: in-memory only vs persisted to disk
- Cache architecture: built into B2 client vs separate cache layer
- Compression algorithm and temp file handling

</decisions>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. User wants a clean, modern Swift codebase with no legacy Rust artifacts.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 05-build-system-b2-client*
*Context gathered: 2026-02-05*
