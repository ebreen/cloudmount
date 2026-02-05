# CloudMount — Mount cloud storage as native macOS drives.

macOS 12+ menu bar app that mounts Backblaze B2 buckets as local FUSE volumes in Finder. Browse, read, write, and delete files as if they were on a local disk. Native SwiftUI interface, Rust FUSE daemon, no Electron. Free and open source alternative to Mountain Duck.

<!-- <img src="screenshot.png" alt="CloudMount menu bar screenshot" width="520" /> -->

## Install

### Requirements
- macOS 12+ (Monterey)
- [macFUSE](https://osxfuse.github.io/) (CloudMount will guide you through installation on first launch)

### Build from source

**Swift UI app:**
```bash
swift build
```

**Rust FUSE daemon:**
```bash
cd Daemon/CloudMountDaemon
cargo build --release
```

### First run
- Launch CloudMount — it appears in your menu bar (no Dock icon).
- If macFUSE isn't installed, you'll see a guided installation dialog.
- Open Settings → Credentials and add your Backblaze B2 application key ID + key.
- Add a bucket in Settings → Buckets with name and mount point.
- Click Mount from the menu bar. Your bucket appears in Finder under `/Volumes/`.

## Features
- Mount B2 buckets as native macOS volumes visible in Finder.
- Browse directories, open files, drag-and-drop — it's just a folder.
- Write files locally, upload to B2 on close (write-on-close strategy).
- Delete files and create directories through Finder.
- Metadata caching with Moka reduces B2 API calls by 80%+.
- Secure credential storage in macOS Keychain — never in config files.
- Bucket configuration persists between restarts (`~/Library/Application Support/CloudMount/`).
- Retry with exponential backoff for transient network failures.
- macOS metadata file suppression (`.DS_Store`, `._*`) to minimize API calls.
- No Dock icon, minimal UI, lives entirely in the menu bar.

## Architecture

CloudMount is a dual-process architecture:

```
┌─────────────────────┐         Unix Socket         ┌──────────────────────┐
│   Swift/SwiftUI     │ ◄──── JSON Protocol ────►   │   Rust Daemon        │
│                     │    /tmp/cloudmount.sock      │                      │
│  • Menu bar UI      │                              │  • FUSE filesystem   │
│  • Settings window  │                              │  • B2 API client     │
│  • Credential mgmt  │                              │  • Metadata cache    │
│  • Daemon client    │                              │  • Mount manager     │
└─────────────────────┘                              └──────────────────────┘
```

- **Swift app** (`Sources/CloudMount/`) — SwiftUI MenuBarExtra, settings, Keychain access, daemon communication via actor-based `DaemonClient`.
- **Rust daemon** (`Daemon/CloudMountDaemon/`) — fuser-based FUSE filesystem, B2 API client with reqwest, Moka metadata cache, Unix socket IPC server.
- **IPC** — JSON protocol over Unix domain socket. Commands: `Mount`, `Unmount`, `GetStatus`. 2-second polling for status updates.

## How it works

1. Swift app sends `Mount` command via Unix socket with bucket name, credentials, and mount point.
2. Rust daemon authenticates with B2 API (`b2_authorize_account`).
3. Daemon creates a FUSE filesystem and mounts it at the requested path.
4. Finder sees the mount as a native volume.
5. File operations (read/write/delete) are handled by FUSE callbacks that proxy to B2 API calls.
6. Metadata is cached (10min for attrs, 5min for directories) to keep Finder responsive.

## File operations

| Operation | Strategy | Notes |
|-----------|----------|-------|
| Read | Download + local cache | Cached for performance |
| Write | Buffer locally, upload on close | Avoids partial uploads |
| Delete | Permanent delete | B2 versioning ignored for MVP |
| Mkdir | Create empty `.bzEmpty` marker | B2 has no real directories |
| Rename | Server-side copy + delete | B2 has no rename API |
| Dir rename | Not supported | Returns `ENOSYS` (MVP limitation) |

## Project structure

```
Sources/CloudMount/
├── CloudMountApp.swift      # Main app, BucketConfigStore, persistence
├── DaemonClient.swift       # Actor-based IPC client
├── CredentialStore.swift    # Keychain storage
├── MacFUSEDetector.swift    # macFUSE installation detection
├── MenuContentView.swift    # Menu bar with mount controls
└── SettingsView.swift       # Credentials + Buckets tabs

Daemon/CloudMountDaemon/src/
├── main.rs                  # Daemon entry point
├── b2/
│   ├── client.rs            # B2 API client (auth, list, upload, delete)
│   └── types.rs             # B2 API types with serde
├── cache/
│   └── metadata.rs          # Moka-based metadata cache
├── fs/
│   ├── b2fs.rs              # FUSE filesystem implementation
│   └── inode.rs             # Stable path-to-inode mapping
├── ipc/
│   ├── protocol.rs          # JSON protocol definitions
│   └── server.rs            # Unix socket IPC server
└── mount/
    └── manager.rs           # Mount lifecycle management
```

## Known limitations (v1.0)
- **Backblaze B2 only** — generic S3 support planned for v2.
- **Disk usage shows N/A** — B2 has no bucket size API; protocol is wired for when computation is added.
- **Directory rename not supported** — complex operation deferred.
- **Single-bucket mount** — multi-bucket simultaneous mount planned for v2.
- **No auto-mount** — manual mount from menu bar required each session.

## Roadmap
- **v1.1** — Multi-bucket support, auto-mount on startup, connection status indicators.
- **v2.0** — Generic S3 provider support (AWS S3, Wasabi, DigitalOcean Spaces), custom endpoints.

## Tech stack
- **Swift/SwiftUI** — Native menu bar app, Keychain integration
- **Rust** — FUSE daemon, async I/O with Tokio
- **fuser 0.16** — FUSE filesystem trait implementation
- **reqwest** — HTTP client for B2 API
- **moka** — High-performance concurrent cache (sync mode for FUSE compatibility)
- **serde** — JSON serialization for IPC protocol and B2 API types
- **tracing** — Structured logging

## Related
- [Mountain Duck](https://mountainduck.io/) — Commercial alternative ($39) that inspired this project.
- [macFUSE](https://osxfuse.github.io/) — Required kernel extension for userspace filesystems on macOS.
- [rclone](https://rclone.org/) — CLI tool for cloud storage (different approach — sync, not mount).

## License
MIT — Eirik Breen ([ebreen](https://github.com/ebreen))
