# Pitfalls Research: FUSE Cloud Storage Filesystems

**Domain:** FUSE-based cloud storage filesystem (macOS)
**Researched:** 2026-02-02
**Confidence:** MEDIUM-HIGH (based on s3fs-fuse/libfuse GitHub issues, macFUSE wiki, and community experience)

## Critical Pitfalls

### Pitfall 1: Synchronous Upload on Close Blocking All File Operations

**What goes wrong:**
When a file is closed after writing, s3fs uploads the entire file synchronously before returning from the close() call. During this upload, the file entry lock (`fent lock`) is held, blocking other threads from accessing ANY files. This causes the entire filesystem to freeze during uploads.

**Why it happens:**
- FUSE's `flush` operation is synchronous and must complete before close() returns
- s3fs holds a global file entry lock during upload to prevent race conditions
- Network latency (100-500ms) multiplied by file size creates multi-second blocks
- Concurrent IO performance degrades heavily as all threads serialize on the lock

**How to avoid:**
- Implement async upload with local staging cache
- Use multipart upload with background completion
- Implement file-level locking, not global locking
- Consider `direct_io` flag to bypass kernel page cache (tradeoff: no read caching)
- For MVP: accept the limitation, document it, implement async upload post-MVP

**Warning signs:**
- Finder beachball when saving large files
- All filesystem operations freeze during uploads
- High latency on unrelated file operations during writes

**Phase to address:**
Phase 2 (Core FUSE Integration) — implement proper locking strategy; Phase 4 (Performance) — implement async upload

---

### Pitfall 2: Directory Listing Performance Death Spiral

**What goes wrong:**
Listing directories with thousands of files becomes orders of magnitude slower than direct S3 API calls. A directory with 300k files that takes 36 seconds via direct S3 API can take 40+ minutes via FUSE.

**Why it happens:**
- FUSE requires `readdir` to return complete file attributes (stat info)
- Each file requires a separate `HeadObject` S3 API call to get metadata
- No batch stat operation in S3 API
- macOS Finder aggressively stats files when displaying directories
- `updatedb` and Spotlight indexing trigger massive recursive listings

**How to avoid:**
- Implement aggressive stat caching with configurable TTL
- Use S3 ListObjectsV2 with `fetch-owner` and metadata in single call (if supported by provider)
- Limit directory listing size or implement pagination
- Add mount option to exclude from Spotlight (`nobrowse` on macOS)
- Document that directories with >10k files are not recommended

**Warning signs:**
- Finder takes minutes to open large directories
- High S3 API costs from ListBucket/HeadObject calls
- CPU spikes from `updatedb` or Spotlight

**Phase to address:**
Phase 2 (Core FUSE Integration) — implement stat caching; Phase 3 (S3 Integration) — optimize listing strategy

---

### Pitfall 3: Cache Coherency and Stale Data Corruption

**What goes wrong:**
When a file is open and its content is overwritten externally (e.g., via S3 console or another client), the FUSE filesystem continues to serve stale cached data. This leads to data corruption and confusion.

**Why it happens:**
- FUSE filesystems cache file content and metadata locally
- No cache invalidation mechanism when S3 objects change externally
- File handles maintain references to cached data
- S3 has no notification mechanism for object changes

**How to avoid:**
- Implement short cache TTLs (5-30 seconds for metadata)
- Provide manual cache flush option in menu bar
- Check ETag/Last-Modified on open and re-read if changed
- Document that external modifications require remount
- For MVP: disable write caching, implement read-only or single-writer mode

**Warning signs:**
- File content doesn't match what's in S3 console
- Applications report corrupted files
- File sizes or modification times inconsistent

**Phase to address:**
Phase 2 (Core FUSE Integration) — implement cache invalidation; Phase 5 (Reliability) — add consistency checks

---

### Pitfall 4: macFUSE Kernel Extension Installation Hell

**What goes wrong:**
macFUSE requires a kernel extension (kext) that macOS actively resists loading. Users see "System Extension Blocked" errors and the filesystem fails to mount.

**Why it happens:**
- macOS requires kexts to be notarized and signed
- Apple Silicon Macs require "Reduced Security" mode or specific entitlements
- macOS 10.13+ requires user approval in System Preferences/Settings
- Each macOS update can break kext compatibility
- macFUSE 4.x requires explicit user action to enable

**How to avoid:**
- Use macFUSE 4.x (current) with proper documentation
- Provide clear installation instructions with screenshots
- Implement pre-flight checks that verify macFUSE is loaded
- Show helpful error messages with links to macFUSE troubleshooting
- Consider FUSE-T as alternative (no kext, but different tradeoffs)

**Warning signs:**
- Mount fails with "fuse: device not found"
- Console logs show kext load failures
- Users report "it worked before macOS update"

**Phase to address:**
Phase 1 (Setup & macFUSE) — implement proper error handling and user guidance

---

### Pitfall 5: File Descriptor Exhaustion

**What goes wrong:**
The FUSE filesystem runs out of file descriptors when handling many concurrent operations, causing "No file descriptors available" (ENFILE) errors.

**Why it happens:**
- Each open file in FUSE requires multiple FDs (kernel, libfuse, application)
- Default ulimit (256-1024) is easily exceeded with Finder thumbnails, previews
- `find`, `git status`, or recursive directory traversal opens many files
- File descriptors not properly released on error paths

**How to avoid:**
- Set high FD limit at startup (`ulimit -n 65536`)
- Implement FD pooling and reuse
- Use `O_CLOEXEC` flag on internal FDs
- Implement lazy file opening (don't open until actually needed)
- Add monitoring for FD usage

**Warning signs:**
- "Too many open files" errors in logs
- Operations fail with ENOFILE
- System becomes unstable under load

**Phase to address:**
Phase 2 (Core FUSE Integration) — implement FD management

---

### Pitfall 6: S3 API Quirks and Incompatibilities

**What goes wrong:**
S3-compatible services (Backblaze B2, MinIO, etc.) have subtle API differences that cause failures: authentication errors, wrong endpoint formats, SSL certificate issues with dotted bucket names.

**Why it happens:**
- Different services use different URL formats (virtual-hosted vs path-style)
- SSL certificates don't cover dotted bucket names (e.g., `my.bucket.s3.amazonaws.com`)
- Authentication signatures vary between implementations
- Some services don't support all S3 features (multipart, versioning)
- Regional endpoint requirements differ

**How to avoid:**
- Support both virtual-hosted and path-style URLs (`use_path_request_style`)
- Allow custom endpoint configuration
- Implement provider-specific presets (B2, MinIO, etc.)
- Handle SSL certificate validation carefully
- Test with actual Backblaze B2, not just AWS S3

**Warning signs:**
- "AuthorizationHeaderMalformed" errors
- SSL certificate errors with dotted bucket names
- Works with AWS but fails with B2

**Phase to address:**
Phase 3 (S3 Integration) — implement provider abstraction; Phase 6 (Testing) — test with multiple providers

---

### Pitfall 7: Memory Explosion and OOM Kills

**What goes wrong:**
Writing large files (10GB+) causes memory usage to grow unbounded, eventually triggering OOM killer or system instability.

**Why it happens:**
- File content is buffered in memory before upload
- No backpressure mechanism for slow network uploads
- Cache grows without bounds (`use_cache` option)
- Multiple concurrent large writes multiply memory usage

**How to avoid:**
- Implement streaming upload (don't buffer entire file)
- Use multipart upload with fixed-size parts (5-100MB)
- Set maximum cache size with LRU eviction
- Monitor memory usage and throttle writes when high
- Use `O_DIRECT` for large files (bypasses page cache)

**Warning signs:**
- Memory usage grows linearly with file size
- System swap usage increases
- OOM killer terminates the filesystem process

**Phase to address:**
Phase 2 (Core FUSE Integration) — implement streaming writes; Phase 4 (Performance) — add resource limits

---

### Pitfall 8: Transport Endpoint Disconnection

**What goes wrong:**
The FUSE mount suddenly becomes inaccessible with "Transport endpoint is not connected" errors. All file operations fail until remount.

**Why it happens:**
- FUSE daemon crashes or is killed
- Network timeout causes S3 operations to hang
- Kernel unmounts due to inactivity or error
- DNS resolution fails and doesn't recover
- macOS sleep/wake cycle breaks connection

**How to avoid:**
- Implement health checks and automatic reconnect
- Set aggressive timeouts on S3 operations
- Handle DNS failures gracefully with retry
- Implement watchdog that remounts if needed
- Provide user-visible "Reconnect" button in menu bar

**Warning signs:**
- "Transport endpoint is not connected" errors
- All operations return EIO (Input/Output error)
- Mount point exists but is inaccessible

**Phase to address:**
Phase 2 (Core FUSE Integration) — implement error handling; Phase 5 (Reliability) — add auto-recovery

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Synchronous upload | Simple implementation, guaranteed consistency | UI freezes, poor performance | MVP only — must fix before beta |
| No stat caching | Always fresh data, simple code | Abysmal directory listing performance | Never for directories >100 files |
| Unlimited cache | Fast reads, simple eviction | Memory explosion, OOM kills | Never — always implement cache limits |
| Single global lock | Thread safety guaranteed | Concurrent operations serialize | MVP only — implement fine-grained locking |
| No retry logic | Simple error handling | Transient failures become permanent errors | Never — S3 requires retry |
| Hardcoded AWS endpoints | Quick setup | Breaks with B2, MinIO, other providers | Never — always support custom endpoints |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Backblaze B2 | Using AWS S3 endpoints | Use `s3.us-west-002.backblazeb2.com` with path-style URLs |
| AWS S3 | Virtual-hosted URLs with dotted bucket names | Use path-style or bucket names without dots |
| macFUSE | Not checking kext is loaded | Verify kext status before mount, show setup instructions |
| Finder | Expecting immediate file appearance | Document upload delay, show sync status in menu bar |
| Spotlight | Allowing indexing of mount | Add `nobrowse` mount option, document exclusion |
| Keychain | Storing credentials in plaintext | Use macOS Keychain or secure enclave |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Synchronous close() | UI freezes on save | Async upload with staging | Any file >1MB |
| No stat caching | 40min directory listings | Aggressive metadata caching | Directories >1k files |
| Unlimited cache | OOM kills | LRU cache with size limits | Files >available RAM |
| Global file locks | Concurrent ops slow to serial | Per-file locking | Any concurrent access |
| No connection pooling | High latency, connection errors | HTTP keep-alive, connection reuse | Any sustained load |
| Blocking DNS | Hangs on network issues | Async DNS with timeout | Any DNS hiccup |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Credentials in config file | Credential theft, unauthorized access | Use macOS Keychain, never write secrets to disk |
| No request signing validation | Replay attacks, credential compromise | Validate AWS signature V4 correctly |
| HTTP instead of HTTPS | Man-in-the-middle attacks | Enforce HTTPS, validate certificates |
| World-readable mount | Other users access your cloud files | Default to user-only, explicit `allow_other` |
| No credential rotation | Long-lived credentials | Support temporary credentials, STS |
| Logging credentials | Secrets in logs | Redact credentials from all logging |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| No upload progress | User thinks app is frozen | Show upload status in menu bar |
| Silent failures | User doesn't know something went wrong | Clear error messages with recovery steps |
| Mount disappears on sleep | User confusion, data loss risk | Auto-reconnect on wake, notify user |
| Finder beachball | Perceived as app crash | Async operations, progress indicators |
| No offline indication | User tries to access unavailable files | Show connection status, gray out unavailable files |
| Complex setup | User gives up before using | One-click setup wizard, sensible defaults |

## "Looks Done But Isn't" Checklist

- [ ] **Mount succeeds:** Verify actual file operations work, not just mount command
- [ ] **File read:** Test with files >100MB, verify streaming not buffering
- [ ] **File write:** Test with files >100MB, verify progress indication
- [ ] **Directory listing:** Test with directories containing >1000 files
- [ ] **Concurrent access:** Open multiple files simultaneously from different apps
- [ ] **Error handling:** Disconnect network mid-operation, verify graceful failure
- [ ] **macOS sleep:** Put Mac to sleep, wake, verify mount still works
- [ ] **Credentials:** Verify credentials aren't written to logs or temp files
- [ ] **Uninstall:** Verify clean unmount and removal of all components
- [ ] **B2 compatibility:** Test with actual Backblaze B2, not just AWS S3

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Transport endpoint disconnected | LOW | Unmount (`umount -f`), remount, retry operation |
| Stale cache data | LOW | Remount filesystem or use cache flush option |
| OOM kill | MEDIUM | Increase memory limits, reduce cache size, restart |
| Corrupted upload | MEDIUM | Check S3 console, delete partial upload, retry |
| Kext not loading | MEDIUM | Reinstall macFUSE, approve in System Settings, reboot |
| Credential expiration | LOW | Refresh credentials from keychain, remount |
| File descriptor exhaustion | LOW | Close applications, increase ulimit, restart filesystem |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Synchronous upload blocking | Phase 2 (Core FUSE) + Phase 4 (Performance) | Write 100MB file, verify UI responsive |
| Directory listing performance | Phase 2 (Core FUSE) + Phase 3 (S3) | List 10k file directory in <10 seconds |
| Cache coherency | Phase 2 (Core FUSE) | Modify file externally, verify refresh |
| macFUSE installation | Phase 1 (Setup) | Clean macOS VM, verify setup flow works |
| File descriptor exhaustion | Phase 2 (Core FUSE) | Run `find` on large tree, verify no ENFILE |
| S3 API quirks | Phase 3 (S3 Integration) | Test with B2, MinIO, not just AWS |
| Memory explosion | Phase 2 (Core FUSE) + Phase 4 (Performance) | Write 1GB file, monitor memory usage |
| Transport disconnection | Phase 2 (Core FUSE) + Phase 5 (Reliability) | Disconnect network, verify graceful handling |

## Sources

- s3fs-fuse GitHub Issues: https://github.com/s3fs-fuse/s3fs-fuse/issues
  - #2193: Directory listing performance issues
  - #2413: Cache coherency problems
  - #2617: Concurrent IO performance degradation
  - #2156: OOM killer issues
  - #2176: Transport endpoint disconnection
  - FAQ: Common configuration mistakes

- libfuse GitHub Issues: https://github.com/libfuse/libfuse/issues
  - #1131: File descriptor exhaustion
  - #1230: Thread-safety concerns
  - #1192: direct_io behavior issues

- macFUSE Wiki: https://github.com/macfuse/macfuse/wiki
  - Getting Started (Developer)
  - Frequently Asked Questions

- Confidence: MEDIUM-HIGH — These issues are well-documented in production FUSE filesystems. Specifics may vary based on implementation language (Node.js vs C++).

---
*Pitfalls research for: FUSE-based cloud storage filesystem (CloudMount)*
*Researched: 2026-02-02*
