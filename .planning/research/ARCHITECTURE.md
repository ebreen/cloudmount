# Architecture Patterns: FUSE Cloud Storage Filesystem

**Domain:** FUSE-based cloud storage filesystem (CloudMount)
**Researched:** February 2026
**Overall Confidence:** HIGH

## Recommended Architecture

CloudMount follows a layered architecture with clear separation between the UI, filesystem bridge, and cloud storage integration layers. The architecture is designed around Tauri's IPC model, where the Rust backend serves as the orchestration layer coordinating between the web frontend and the Node.js FUSE filesystem process.

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         macOS User                               │
├─────────────────────────────────────────────────────────────────┤
│  Finder        │  Status Bar Menu  │  Settings Window          │
│  (Native)      │  (Tauri Tray)     │  (Tauri WebView)          │
└───────┬────────┴─────────┬─────────┴────────────┬────────────────┘
        │                  │                      │
        │ FUSE Operations  │  IPC Events          │  IPC Commands
        │                  │                      │
┌───────▼──────────────────▼──────────────────────▼────────────────┐
│                    Tauri Application (Rust)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ Mount Manager│  │ Config Store │  │ S3 Bridge (Node.js)  │   │
│  │ - Lifecycle  │  │ - Credentials│  │ - FUSE Handlers      │   │
│  │ - Health     │  │ - Settings   │  │ - S3 Operations      │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
        │                                        │
        │ macFUSE Kernel Extension               │ AWS SDK
        │                                        │
┌───────▼────────────────────────────────────────▼────────────────┐
│                    Cloud Storage (S3/B2)                         │
│                    ┌──────────────┐                              │
│                    │ Buckets      │                              │
│                    │ Objects      │                              │
│                    │ Metadata     │                              │
│                    └──────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

### Component Boundaries

| Component | Responsibility | Communicates With | Technology |
|-----------|---------------|-------------------|------------|
| **Menu Bar UI** | Display mount status, trigger actions | Tauri Backend | Tauri Tray API + WebView |
| **Settings UI** | Configure credentials, buckets, preferences | Tauri Backend | Tauri WebView (React/Vue) |
| **Tauri Backend (Rust)** | Orchestration, IPC, native integration | All components | Tauri Framework |
| **Mount Manager** | Mount/unmount lifecycle, health checks | FUSE Process, UI | Rust (Tauri Command) |
| **Config Store** | Secure credential storage, settings | Tauri Backend | macOS Keychain |
| **FUSE Bridge (Node.js)** | FUSE syscall implementation | macFUSE, S3 SDK | fuse-native + AWS SDK |
| **S3 Client** | Cloud storage operations | FUSE Bridge | AWS SDK v3 |
| **Cache Layer** | Metadata caching, write buffering | FUSE Bridge | In-memory + optional disk |

## Data Flow

### Read Operation Flow

```
1. User opens file in Finder
   │
   ▼
2. macFUSE kernel extension receives VFS call
   │
   ▼
3. fuse-native dispatches to Node.js handler
   │
   ▼
4. FUSE Bridge checks local cache
   │ (cache hit: return immediately)
   │ (cache miss: continue)
   ▼
5. S3 Client issues GetObject request
   │
   ▼
6. Stream response back through FUSE → Kernel → Finder
```

### Write Operation Flow

```
1. User saves file in Finder
   │
   ▼
2. FUSE Bridge receives write() calls (buffered)
   │
   ▼
3. On fsync() or close(), upload to S3
   │
   ▼
4. S3 Client uses multipart upload for large files
   │
   ▼
5. Update local metadata cache
   │
   ▼
6. Confirm completion to Finder
```

### UI → Backend Communication

```
Frontend (TypeScript)          Backend (Rust)
─────────────────────────────────────────────────
invoke('mount_bucket', {       → Command handler
  bucket: 'my-bucket',            validates input
  mountPoint: '/Volumes/X'        spawns FUSE process
})                             ← Returns mount handle

listen('mount_status', (e) =>  ← Event from backend
  console.log(e.payload)          FUSE process status
)                                  health updates
```

## Patterns to Follow

### Pattern 1: FUSE Filesystem Trait Implementation

Implement the core FUSE operations using `fuse-native` handlers. This is the standard pattern used by gcsfuse, s3fs-fuse, and goofys.

**What:** Implement handlers for `getattr`, `readdir`, `open`, `read`, `write`, `release`
**When:** All FUSE filesystem operations
**Example:**
```typescript
// src/fuse/handlers.ts
const handlers = {
  getattr: async (path: string, cb: Function) => {
    const attr = await metadataCache.get(path);
    if (attr) return cb(0, attr);
    
    // Fetch from S3 if not cached
    const head = await s3Client.headObject({ Bucket, Key: path });
    const stat = convertS3ToStat(head);
    metadataCache.set(path, stat);
    cb(0, stat);
  },
  
  readdir: async (path: string, cb: Function) => {
    const objects = await s3Client.listObjectsV2({
      Bucket,
      Prefix: path,
      Delimiter: '/'
    });
    const entries = objects.Contents?.map(o => parseKey(o.Key)) || [];
    cb(0, entries);
  },
  
  read: async (path: string, fd: number, buf: Buffer, 
               len: number, pos: number, cb: Function) => {
    const range = `bytes=${pos}-${pos + len - 1}`;
    const response = await s3Client.getObject({
      Bucket, Key: path, Range: range
    });
    const data = await response.Body?.transformToByteArray();
    if (data) {
      buf.set(data);
      cb(data.length);
    }
  }
};
```

### Pattern 2: Metadata Caching with TTL

Cache directory listings and file attributes to reduce S3 API calls. This is critical for performance as directory operations in S3 are expensive.

**What:** In-memory cache with configurable TTL for metadata
**When:** All metadata operations (getattr, readdir)
**Implementation:**
```typescript
// src/cache/metadata.ts
class MetadataCache {
  private cache = new Map<string, CacheEntry>();
  private ttlMs: number;
  
  get(path: string): Stat | null {
    const entry = this.cache.get(path);
    if (!entry) return null;
    if (Date.now() - entry.timestamp > this.ttlMs) {
      this.cache.delete(path);
      return null;
    }
    return entry.data;
  }
  
  set(path: string, data: Stat): void {
    this.cache.set(path, { data, timestamp: Date.now() });
  }
  
  invalidate(path: string): void {
    // Invalidate path and all children
    for (const key of this.cache.keys()) {
      if (key.startsWith(path)) this.cache.delete(key);
    }
  }
}
```

### Pattern 3: Streaming Read/Write

Use streaming for file operations to handle large files without loading entirely into memory.

**What:** Stream data between FUSE and S3
**When:** File read/write operations
**Implementation:**
```typescript
// src/fuse/operations.ts
async function readFile(
  path: string, 
  buffer: Buffer, 
  offset: number, 
  length: number
): Promise<number> {
  // Use range requests for partial reads
  const range = `bytes=${offset}-${offset + length - 1}`;
  const response = await s3.send(new GetObjectCommand({
    Bucket: config.bucket,
    Key: path,
    Range: range
  }));
  
  // Transform stream to buffer
  const bytes = await response.Body!.transformToByteArray();
  buffer.set(bytes);
  return bytes.length;
}

async function writeFile(
  path: string,
  buffer: Buffer,
  offset: number
): Promise<void> {
  // Buffer writes locally, upload on close/fsync
  const tempPath = getTempPath(path);
  await fs.write(tempPath, buffer, 0, buffer.length, offset);
}
```

### Pattern 4: Tauri IPC Bridge

Use Tauri's command/event system for UI-backend communication.

**What:** Commands for actions, events for status updates
**When:** All UI-backend communication
**Implementation:**
```rust
// src-tauri/src/commands.rs
#[tauri::command]
async fn mount_bucket(
    bucket: String,
    mount_point: String,
    state: State<'_, MountManager>,
) -> Result<MountHandle, String> {
    let handle = state.mount(bucket, mount_point).await?;
    Ok(handle)
}

#[tauri::command]
async fn unmount_bucket(
    handle: MountHandle,
    state: State<'_, MountManager>,
) -> Result<(), String> {
    state.unmount(handle).await?;
    Ok(())
}
```

```typescript
// src/App.tsx
import { invoke, listen } from '@tauri-apps/api';

async function mount() {
  const handle = await invoke('mount_bucket', {
    bucket: 'my-bucket',
    mountPoint: '/Volumes/MyBucket'
  });
  
  const unlisten = await listen('mount_status', (event) => {
    updateUI(event.payload);
  });
}
```

### Pattern 5: Credential Security

Store credentials securely using macOS Keychain via Tauri APIs.

**What:** Keychain-backed credential storage
**When:** Storing S3 credentials
**Implementation:**
```rust
// src-tauri/src/credentials.rs
use keychain::{Entry, Error};

pub struct CredentialStore;

impl CredentialStore {
    pub fn save(bucket: &str, access_key: &str, secret_key: &str) -> Result<(), Error> {
        let entry = Entry::new("cloudmount", bucket)?;
        entry.set_password(&format!("{}:{}", access_key, secret_key))?;
        Ok(())
    }
    
    pub fn get(bucket: &str) -> Result<(String, String), Error> {
        let entry = Entry::new("cloudmount", bucket)?;
        let creds = entry.get_password()?;
        let parts: Vec<&str> = creds.split(':').collect();
        Ok((parts[0].to_string(), parts[1].to_string()))
    }
}
```

## Anti-Patterns to Avoid

### Anti-Pattern 1: Synchronous S3 Operations in FUSE Handlers

**What:** Blocking on S3 API calls within FUSE handlers
**Why bad:** Blocks the entire FUSE event loop, freezing Finder
**Instead:** Use async/await with proper callback handling

```typescript
// BAD - blocks FUSE
read: (path, fd, buf, len, pos, cb) => {
  const data = s3.getObjectSync({ Key: path }); // DON'T
  cb(data.length);
}

// GOOD - async
read: async (path, fd, buf, len, pos, cb) => {
  const data = await s3.getObject({ Key: path });
  cb(data.length);
}
```

### Anti-Pattern 2: No Metadata Caching

**What:** Fetching file attributes from S3 on every `getattr` call
**Why bad:** Finder calls `getattr` frequently; each is an S3 API call = slow + expensive
**Instead:** Implement TTL-based metadata cache

### Anti-Pattern 3: Full File Buffering

**What:** Loading entire files into memory for read/write
**Why bad:** Memory exhaustion with large files (S3 objects can be TBs)
**Instead:** Use range requests for reads, multipart upload for writes

### Anti-Pattern 4: Direct Kernel Extension Management

**What:** Trying to load/unload macFUSE kernel extension directly
**Why bad:** Requires root, complex permission handling
**Instead:** Use `fuse-native` which embeds and manages the shared library

### Anti-Pattern 5: Blocking UI on Mount Operations

**What:** Synchronous mount/unmount that freezes the UI
**Why bad:** Poor user experience, macOS may flag app as unresponsive
**Instead:** Use Tauri async commands with progress events

## Build Order Recommendations

Based on component dependencies, build in this order:

### Phase 1: Foundation (Core Infrastructure)
1. **Tauri project setup** - Basic app shell, tray icon
2. **Configuration storage** - Settings schema, keychain integration
3. **S3 client wrapper** - AWS SDK configuration, basic operations

### Phase 2: FUSE Core (Filesystem)
1. **FUSE mount/unmount** - Basic fuse-native integration
2. **Metadata operations** - getattr, readdir with caching
3. **Directory listing** - ListObjectsV2 integration

### Phase 3: File Operations (Data Flow)
1. **File read** - Range request implementation
2. **File write** - Buffered writes with multipart upload
3. **Error handling** - Proper FUSE error codes

### Phase 4: UI Polish (User Experience)
1. **Settings window** - Credential configuration
2. **Status indicators** - Mount state in menu bar
3. **Error reporting** - User-friendly error messages

### Phase 5: Integration (End-to-End)
1. **E2E testing** - Full read/write workflows
2. **Performance tuning** - Cache optimization
3. **Edge cases** - Network failures, large files

## Scalability Considerations

| Concern | Single User | Multiple Buckets | Heavy Usage |
|---------|-------------|------------------|-------------|
| **Metadata Cache** | In-memory Map | LRU with size limit | Redis/external |
| **File Cache** | None | Local disk cache | Distributed cache |
| **Connections** | Single S3 client | Connection pool | Multiple pools |
| **Uploads** | Single-part | Multipart > 100MB | Parallel multipart |

## macOS-Specific Considerations

1. **macFUSE Dependency**: Users must install macFUSE separately (kernel extension requirement)
2. **Volume Naming**: Use `displayFolder` option in fuse-native for Finder sidebar integration
3. **Spotlight**: Consider disabling Spotlight indexing on mount points (`.metadata_never_index`)
4. **Extended Attributes**: Implement `getxattr`/`setxattr` for macOS metadata support

## Sources

- **gcsfuse** (Google Cloud Storage FUSE): https://github.com/googlecloudplatform/gcsfuse - Architecture patterns, caching strategies
- **s3fs-fuse**: https://github.com/s3fs-fuse/s3fs-fuse - POSIX compatibility approaches, multipart upload
- **goofys**: https://github.com/kahing/goofys - Performance optimizations, "filey" vs "file" system design
- **macFUSE**: https://github.com/macfuse/macfuse - macOS FUSE implementation details
- **fuse-native**: https://www.npmjs.com/package/fuse-native - Node.js FUSE bindings API
- **Tauri Documentation**: Context7 /tauri-apps/tauri - IPC patterns, command system
- **AWS SDK v3**: Context7 /aws/aws-sdk-js-v3 - S3 streaming operations
- **fuser crate**: Context7 /websites/rs_fuser - Rust FUSE trait patterns (for reference)

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| FUSE Architecture | HIGH | Based on multiple production implementations (gcsfuse, s3fs, goofys) |
| Tauri Integration | HIGH | Context7 documentation and official patterns |
| AWS SDK Patterns | HIGH | Context7 verified examples |
| macOS FUSE | MEDIUM | macFUSE is closed-source since v4, but API is stable |
| Node.js FUSE | MEDIUM | fuse-native is mature but less documented than Rust alternatives |

## Open Questions

1. **Write buffering strategy**: How much to buffer before uploading? (affects consistency vs performance)
2. **Cache invalidation**: How to detect external changes to S3 bucket?
3. **Multi-bucket support**: Architecture for mounting multiple buckets simultaneously
4. **Offline handling**: Behavior when network is unavailable
