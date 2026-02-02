# Phase 2: Core Mount & Browse - Research

**Researched:** 2026-02-02
**Domain:** FUSE filesystems on macOS, Rust daemon development, Backblaze B2 API
**Confidence:** HIGH

## Summary

This research covers implementing a FUSE-based filesystem on macOS using Rust to mount Backblaze B2 buckets as local volumes. The core architecture involves a Rust daemon implementing the FUSE filesystem trait, communicating with a Swift UI via IPC, and integrating with the Backblaze B2 API for cloud storage operations.

**Key findings:**
1. **fuser crate (v0.16.0)** is the standard Rust library for FUSE filesystems, actively maintained with 1.1k+ stars
2. **macFUSE 5.1.3** is the required system dependency on macOS (kernel extension or FSKit on macOS 26+)
3. **Moka cache** provides high-performance metadata caching with TTL support
4. **Unix domain sockets** are the recommended IPC mechanism between Swift and Rust
5. **Direct HTTP/reqwest** is preferred over the outdated backblaze-b2 crate for B2 API access

**Primary recommendation:** Use fuser crate with Tokio async runtime, implement custom B2 API client with reqwest, use Moka for metadata caching, and Unix sockets for IPC.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| fuser | 0.16.0 | FUSE filesystem implementation | Most popular Rust FUSE library, actively maintained, 1.1k+ stars, supports macOS |
| tokio | 1.40+ | Async runtime for daemon | Industry standard for Rust async, required for concurrent B2 API calls |
| macFUSE | 5.1.3 | macOS FUSE kernel support | Official FUSE implementation for macOS, required system dependency |
| moka | 0.12.13 | Metadata caching | High-performance concurrent cache, TTL support, inspired by Java Caffeine |
| reqwest | 0.12+ | HTTP client for B2 API | Modern async HTTP client, built on hyper, supports rustls |
| serde | 1.0+ | JSON serialization | Standard for Rust, required for B2 API responses |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| tracing | 0.1+ | Structured logging | For daemon observability and debugging |
| anyhow | 1.0+ | Error handling | Simplifies error propagation in daemon |
| libc | 0.2+ | System calls | Required by fuser for mount operations |
| nix | 0.29+ | Unix APIs | For Unix socket IPC implementation |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| fuser | easy_fuser | Higher-level wrapper, but less control and newer/less mature |
| moka | dashmap | Dashmap is faster but lacks TTL and size-based eviction |
| reqwest | hyper | Hyper is lower-level; reqwest provides better ergonomics |
| Unix sockets | XPC | XPC is macOS-native but more complex; Unix sockets are simpler for Rust interop |

**Installation:**
```bash
# macFUSE system dependency (must be installed by user)
brew install macfuse pkgconf

# Rust dependencies (Cargo.toml)
[dependencies]
fuser = "0.16"
tokio = { version = "1.40", features = ["rt-multi-thread", "macros", "net"] }
moka = { version = "0.12", features = ["future"] }
reqwest = { version = "0.12", features = ["json", "rustls-tls"] }
serde = { version = "1.0", features = ["derive"] }
tracing = "0.1"
anyhow = "1.0"
nix = { version = "0.29", features = ["net"] }
```

## Architecture Patterns

### Recommended Project Structure
```
CloudMount/
├── Sources/
│   └── CloudMount/           # Swift UI app (Phase 1 complete)
├── Daemon/
│   └── CloudMountDaemon/     # Rust daemon
│       ├── Cargo.toml
│       └── src/
│           ├── main.rs       # Daemon entry point
│           ├── fs/           # FUSE filesystem implementation
│           │   ├── mod.rs
│           │   ├── b2fs.rs   # Main filesystem struct
│           │   └── inode.rs  # Inode management
│           ├── b2/           # Backblaze B2 API client
│           │   ├── mod.rs
│           │   ├── client.rs
│           │   └── types.rs
│           ├── cache/        # Metadata caching
│           │   ├── mod.rs
│           │   └── metadata.rs
│           ├── ipc/          # IPC server for Swift communication
│           │   ├── mod.rs
│           │   └── server.rs
│           └── mount/        # Mount lifecycle management
│               ├── mod.rs
│               └── manager.rs
└── .planning/
```

### Pattern 1: FUSE Filesystem Implementation
**What:** Implement the `fuser::Filesystem` trait for B2 bucket access
**When to use:** Core pattern for all FUSE operations

**Key trait methods to implement:**
```rust
// Source: https://docs.rs/fuser/latest/fuser/trait.Filesystem.html
use fuser::{Filesystem, Request, ReplyEntry, ReplyAttr, ReplyDirectory, FileType, FileAttr};
use std::time::SystemTime;

pub struct B2Filesystem {
    b2_client: B2Client,
    inode_table: InodeTable,
    metadata_cache: MetadataCache,
}

impl Filesystem for B2Filesystem {
    // Get file attributes (required for Finder to display metadata)
    fn getattr(&mut self, _req: &Request, ino: u64, _fh: Option<u64>, reply: ReplyAttr) {
        // Check cache first
        if let Some(attr) = self.metadata_cache.get(ino) {
            reply.attr(&std::time::Duration::from_secs(1), &attr);
            return;
        }
        // Fetch from B2 and populate cache
        // ...
    }

    // Read directory contents (required for browsing)
    fn readdir(
        &mut self,
        _req: &Request,
        ino: u64,
        _fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        // Use B2 list_file_names with prefix/delimiter
        // Populate directory entries
        // ...
    }

    // Lookup file by name (required for path resolution)
    fn lookup(
        &mut self,
        _req: &Request,
        parent: u64,
        name: &std::ffi::OsStr,
        reply: ReplyEntry,
    ) {
        // Resolve path to B2 file
        // ...
    }
}
```

### Pattern 2: Inode Management
**What:** Map B2 file paths to FUSE inode numbers
**When to use:** All filesystem operations require inode translation

```rust
// Source: Pattern derived from fuser examples
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub struct InodeTable {
    next_ino: u64,
    path_to_ino: HashMap<String, u64>,
    ino_to_path: HashMap<u64, String>,
}

impl InodeTable {
    const ROOT_INO: u64 = 1;

    pub fn new() -> Self {
        let mut table = Self {
            next_ino: 2, // 1 is reserved for root
            path_to_ino: HashMap::new(),
            ino_to_path: HashMap::new(),
        };
        table.path_to_ino.insert("".to_string(), Self::ROOT_INO);
        table.ino_to_path.insert(Self::ROOT_INO, "".to_string());
        table
    }

    pub fn lookup_or_create(&mut self, path: &str) -> u64 {
        if let Some(&ino) = self.path_to_ino.get(path) {
            return ino;
        }
        let ino = self.next_ino;
        self.next_ino += 1;
        self.path_to_ino.insert(path.to_string(), ino);
        self.ino_to_path.insert(ino, path.to_string());
        ino
    }

    pub fn get_path(&self, ino: u64) -> Option<&str> {
        self.ino_to_path.get(&ino).map(|s| s.as_str())
    }
}
```

### Pattern 3: Metadata Caching with TTL
**What:** Cache file attributes to reduce B2 API calls
**When to use:** Critical for performance - B2 API has latency and rate limits

```rust
// Source: https://docs.rs/moka/latest/moka/
use moka::future::Cache;
use std::time::Duration;
use fuser::FileAttr;

pub struct MetadataCache {
    cache: Cache<u64, FileAttr>,
}

impl MetadataCache {
    pub fn new() -> Self {
        Self {
            cache: Cache::builder()
                // Max 10,000 entries (B2 list returns max 10k)
                .max_capacity(10000)
                // TTL: 5 minutes for directory listings
                .time_to_live(Duration::from_secs(300))
                // TTI: 1 minute of inactivity
                .time_to_idle(Duration::from_secs(60))
                .build(),
        }
    }

    pub async fn get(&self, ino: u64) -> Option<FileAttr> {
        self.cache.get(&ino).await
    }

    pub async fn insert(&self, ino: u64, attr: FileAttr) {
        self.cache.insert(ino, attr).await;
    }

    pub async fn invalidate(&self, ino: u64) {
        self.cache.invalidate(&ino).await;
    }
}
```

### Pattern 4: IPC with Unix Domain Sockets
**What:** Swift UI communicates with Rust daemon via Unix sockets
**When to use:** All UI-to-daemon commands (mount, unmount, status)

```rust
// Source: https://docs.rs/tokio/latest/tokio/net/struct.UnixListener.html
use tokio::net::{UnixListener, UnixStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use std::path::Path;

pub struct IpcServer {
    socket_path: String,
}

impl IpcServer {
    pub async fn run(&self) -> anyhow::Result<()> {
        // Remove old socket if exists
        let _ = std::fs::remove_file(&self.socket_path);
        
        let listener = UnixListener::bind(&self.socket_path)?;
        println!("IPC server listening on {}", self.socket_path);

        loop {
            let (stream, _) = listener.accept().await?;
            tokio::spawn(handle_connection(stream));
        }
    }
}

async fn handle_connection(mut stream: UnixStream) -> anyhow::Result<()> {
    let mut buf = [0u8; 1024];
    let n = stream.read(&mut buf).await?;
    
    // Parse command from Swift
    let command = parse_command(&buf[..n]);
    
    // Execute and respond
    let response = execute_command(command).await;
    stream.write_all(&serialize_response(response)).await?;
    
    Ok(())
}
```

### Pattern 5: B2 API Directory Listing
**What:** Use b2_list_file_names with delimiter for directory simulation
**When to use:** readdir operations

```rust
// Source: https://www.backblaze.com/apidocs/b2-list-file-names
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
struct ListFilesRequest {
    bucket_id: String,
    prefix: String,        // Path prefix (e.g., "photos/")
    delimiter: String,     // "/" for folder simulation
    max_file_count: i32,   // 100-10000
    start_file_name: Option<String>,
}

#[derive(Deserialize)]
struct ListFilesResponse {
    files: Vec<FileInfo>,
    next_file_name: Option<String>,
}

#[derive(Deserialize)]
struct FileInfo {
    file_name: String,
    content_length: u64,
    upload_timestamp: u64, // milliseconds since epoch
    action: String,        // "upload", "folder", etc.
}

// Directory listing logic
pub async fn list_directory(&self, prefix: &str) -> Result<Vec<DirEntry>> {
    let mut entries = Vec::new();
    let mut start_file_name: Option<String> = None;

    loop {
        let request = ListFilesRequest {
            bucket_id: self.bucket_id.clone(),
            prefix: prefix.to_string(),
            delimiter: "/".to_string(),
            max_file_count: 1000,
            start_file_name: start_file_name.clone(),
        };

        let response: ListFilesResponse = self
            .client
            .get("https://api.backblazeb2.com/b2api/v2/b2_list_file_names")
            .header("Authorization", &self.auth_token)
            .query(&request)
            .send()
            .await?
            .json()
            .await?;

        for file in response.files {
            entries.push(DirEntry {
                name: file.file_name.strip_prefix(prefix).unwrap_or(&file.file_name).to_string(),
                size: file.content_length,
                modified: Duration::from_millis(file.upload_timestamp),
                is_dir: file.action == "folder",
            });
        }

        start_file_name = response.next_file_name;
        if start_file_name.is_none() {
            break;
        }
    }

    Ok(entries)
}
```

### Anti-Patterns to Avoid

1. **Blocking in FUSE callbacks:** FUSE callbacks run on the main thread. Use `spawn_mount` for async or delegate to a thread pool.

2. **No inode reuse:** Inodes must be stable for the lifetime of the mount. Don't recycle inodes without careful reference counting.

3. **Synchronous B2 API calls:** B2 has 100-500ms latency. Always use async/await to prevent blocking the FUSE thread.

4. **Caching without TTL:** B2 bucket contents can change. Use TTL to ensure stale data is refreshed.

5. **Ignoring FUSE mount options:** Use `AllowOther` for /Volumes mounting, `FSName` for proper volume naming in Finder.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| FUSE protocol implementation | Custom FUSE bindings | fuser crate | Complex kernel protocol, ABI versioning, macOS differences |
| Inode reference counting | Manual Arc<Mutex> | fuser's built-in forget tracking | Kernel forget calls are complex, race conditions likely |
| HTTP client for B2 | Raw sockets | reqwest | TLS, redirects, retries, connection pooling all handled |
| JSON parsing | Manual string parsing | serde | Type safety, performance, maintainability |
| Cache eviction policy | HashMap with manual cleanup | Moka | TinyLFU algorithm, concurrent access, TTL support |
| Unix socket framing | Manual length-prefixing | tokio's LengthDelimitedCodec | Handles edge cases, backpressure |
| Async runtime | Custom thread pool | Tokio | Battle-tested, ecosystem compatibility |

**Key insight:** FUSE filesystems have many edge cases around inode lifetimes, concurrent access, and kernel interaction. The fuser crate handles these; custom implementations are error-prone.

## Common Pitfalls

### Pitfall 1: macFUSE Installation Requirements
**What goes wrong:** FUSE mount fails with "No such device" or permission errors
**Why it happens:** macFUSE kernel extension not loaded or not approved in System Preferences
**How to avoid:** 
- Check for macFUSE installation at app startup
- Provide user instructions for Security & Privacy approval
- On Apple Silicon, ensure "Reduced Security" is enabled for third-party kexts
**Warning signs:** Mount call returns EBUSY or ENOENT despite valid mountpoint

### Pitfall 2: Inode Number Stability
**What goes wrong:** Files appear to change identity in Finder, or "file not found" errors
**Why it happens:** Inode numbers change between lookups for the same path
**How to avoid:** Maintain persistent inode table for the mount lifetime, map paths to stable inodes
**Warning signs:** Finder shows incorrect icons, files appear duplicated

### Pitfall 3: B2 API Rate Limiting
**What goes wrong:** 429 Too Many Requests errors, degraded performance
**Why it happens:** B2 limits API calls per account; listing large buckets generates many requests
**How to avoid:** 
- Implement aggressive caching (Moka with 5min TTL)
- Use pagination efficiently (max 1000 files per request)
- Implement exponential backoff on 429 errors
**Warning signs:** Slow directory listings, intermittent errors in logs

### Pitfall 4: Permission Denied on /Volumes
**What goes wrong:** Mount succeeds but volume not visible in Finder
**Why it happens:** macOS requires root or specific entitlements to mount in /Volumes
**How to avoid:** 
- Use `AllowOther` mount option
- Consider mounting in ~/CloudMount instead
- May need to run daemon with elevated privileges
**Warning signs:** Mount appears in `mount` output but not in Finder sidebar

### Pitfall 5: Swift-Rust IPC Serialization
**What goes wrong:** Commands fail silently or parse incorrectly
**Why it happens:** Mismatched serialization format between Swift and Rust
**How to avoid:** 
- Use a well-defined binary protocol or JSON
- Version the protocol for future compatibility
- Validate message length before parsing
**Warning signs:** Commands work sometimes, fail other times; partial data reads

## Code Examples

### Complete FUSE Filesystem Mount
```rust
// Source: Adapted from https://github.com/cberner/fuser examples
use fuser::{mount2, Filesystem, MountOption};
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let fs = B2Filesystem::new(
        bucket_id,
        auth_token,
        cache_config,
    )?;

    let mountpoint = Path::new("/Volumes/MyBucket");
    
    // Create mountpoint if needed
    std::fs::create_dir_all(mountpoint)?;

    let options = vec![
        MountOption::FSName("cloudmount".to_string()),
        MountOption::AllowOther,  // Required for /Volumes
        MountOption::NoAtime,     // Don't update access time (performance)
        MountOption::AutoUnmount, // Unmount on process exit
    ];

    // Blocks until unmounted
    mount2(fs, mountpoint, &options)?;
    
    Ok(())
}
```

### FileAttr Construction for B2 Files
```rust
// Source: https://docs.rs/fuser/latest/fuser/struct.FileAttr.html
use fuser::{FileAttr, FileType};
use std::time::{SystemTime, Duration, UNIX_EPOCH};

fn b2_file_to_attr(ino: u64, file_info: &B2FileInfo) -> FileAttr {
    let modified = UNIX_EPOCH + Duration::from_millis(file_info.upload_timestamp);
    
    FileAttr {
        ino,
        size: file_info.content_length,
        blocks: (file_info.content_length + 511) / 512, // 512-byte blocks
        atime: modified,  // B2 doesn't track access time
        mtime: modified,
        ctime: modified,
        crtime: modified,
        kind: if file_info.is_folder {
            FileType::Directory
        } else {
            FileType::RegularFile
        },
        perm: if file_info.is_folder { 0o755 } else { 0o644 },
        nlink: 1,
        uid: 501,  // Current user (adjust as needed)
        gid: 20,   // staff group
        rdev: 0,
        blksize: 4096,
        flags: 0,  // macOS-specific flags
    }
}
```

### Async Mount Manager
```rust
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;

pub struct MountManager {
    mounts: Arc<RwLock<HashMap<String, MountHandle>>>,
}

struct MountHandle {
    mountpoint: PathBuf,
    task: JoinHandle<()>,
    unmount_tx: tokio::sync::oneshot::Sender<()>,
}

impl MountManager {
    pub async fn mount(&self, bucket_id: String, mountpoint: PathBuf) -> anyhow::Result<()> {
        let (unmount_tx, unmount_rx) = tokio::sync::oneshot::channel();
        
        let fs = B2Filesystem::new(bucket_id.clone()).await?;
        
        let task = tokio::task::spawn_blocking(move || {
            let options = vec![
                MountOption::FSName(format!("cloudmount-{}", bucket_id)),
                MountOption::AllowOther,
            ];
            
            // Run mount in blocking thread
            mount2(fs, &mountpoint, &options).ok();
        });

        let handle = MountHandle {
            mountpoint: mountpoint.clone(),
            task,
            unmount_tx,
        };

        self.mounts.write().await.insert(bucket_id, handle);
        Ok(())
    }

    pub async fn unmount(&self, bucket_id: &str) -> anyhow::Result<()> {
        if let Some(handle) = self.mounts.write().await.remove(bucket_id) {
            // Signal unmount
            let _ = handle.unmount_tx.send(());
            
            // Also try system unmount as fallback
            let _ = std::process::Command::new("umount")
                .arg(&handle.mountpoint)
                .output();
                
            // Wait for task to complete
            let _ = tokio::time::timeout(Duration::from_secs(5), handle.task).await;
        }
        Ok(())
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| fuse crate | fuser crate | 2020 | fuser is actively maintained, supports newer FUSE ABIs |
| libfuse2 | libfuse3/macFUSE 5.x | 2023 | Better macOS support, performance improvements |
| sync I/O | async/await with Tokio | 2020 | Better concurrency, essential for network filesystems |
| Custom caching | Moka cache | 2022 | Production-ready, high-performance caching |
| XPC for IPC | Unix sockets + JSON | 2024 | Simpler Rust interop, no complex XPC bindings |

**Deprecated/outdated:**
- **backblaze-b2 crate:** Last updated 2017, uses deprecated hyper 0.10. Use direct HTTP with reqwest instead.
- **blocking FUSE mounts:** Use `spawn_mount` or run in `spawn_blocking` for async compatibility.
- **memcached/redis for metadata:** Moka provides better latency for local caching.

## Open Questions

1. **macOS FSKit vs macFUSE kernel extension**
   - What we know: macFUSE 5.x supports FSKit on macOS 26+ for user-space-only operation
   - What's unclear: Whether FSKit provides better performance or reliability
   - Recommendation: Start with macFUSE kernel extension (works on all supported macOS versions), evaluate FSKit later

2. **Swift-to-Rust IPC protocol**
   - What we know: Unix sockets work well; need to choose serialization format
   - What's unclear: Whether to use JSON (human-readable) or binary (performance)
   - Recommendation: Use JSON for v1 (simpler debugging), consider bincode for v2 if performance becomes issue

3. **Inode number allocation strategy**
   - What we know: Simple incrementing counter works for small buckets
   - What's unclear: Performance with millions of files, memory usage of inode table
   - Recommendation: Start with HashMap-based inode table, profile before optimizing

4. **B2 API authentication lifecycle**
   - What we know: Auth tokens expire after 24 hours
   - What's unclear: Best strategy for token refresh without disrupting active mounts
   - Recommendation: Implement background token refresh at 20-hour intervals

## Sources

### Primary (HIGH confidence)
- `/websites/rs_fuser` (Context7) - FUSE filesystem trait, mount options, FileAttr structure
- `/websites/rs_tokio` (Context7) - Async runtime, Unix socket support
- `/websites/rs_easy_fuser` (Context7) - High-level FUSE patterns
- https://docs.rs/fuser/0.16.0/fuser/ - Official fuser documentation
- https://macfuse.github.io/ - macFUSE official site
- https://www.backblaze.com/apidocs/b2-list-file-names - B2 API documentation

### Secondary (MEDIUM confidence)
- https://docs.rs/moka/0.12.13/moka/ - Moka cache documentation
- https://github.com/cberner/fuser - fuser repository, examples
- https://github.com/Darksonn/backblaze-b2-rs - B2 crate (deprecated but shows API patterns)

### Tertiary (LOW confidence)
- Web search results for "macOS FUSE filesystem best practices 2025"
- Community discussions on r/rust and Stack Overflow (unverified)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All libraries verified with Context7 and official docs
- Architecture: HIGH - Based on fuser examples and established patterns
- Pitfalls: MEDIUM - Some derived from general FUSE experience, not all verified on macOS

**Research date:** 2026-02-02
**Valid until:** 2026-05-02 (90 days for stable FUSE ecosystem)
