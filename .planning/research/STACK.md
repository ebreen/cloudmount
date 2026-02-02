# Technology Stack: CloudMount

**Domain:** FUSE-based cloud storage filesystem on macOS
**Researched:** 2026-02-02
**Confidence:** HIGH

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| macFUSE | 5.1.3 | FUSE kernel extension for macOS | The only production-ready FUSE implementation for macOS. Provides two backends: FSKit (macOS 15.4+, user-space only, no kernel extension required) and Kernel Backend (best performance, requires Recovery Mode setup). Version 5.1.3 is the latest stable release (Dec 2025) with macOS 26 SDK support and FSKit improvements. |
| fuser | 0.16.0 | Rust FUSE userspace library | The standard Rust FUSE library. Low-level interface that fully leverages Rust's ownership model. Provides `spawn_mount2()` for background mounting and `Filesystem` trait for implementing custom filesystems. Actively maintained, 700+ code snippets in Context7. |
| Tauri | 2.9 | Desktop app framework with web frontend | Native-feeling macOS menu bar apps with Rust backend. Uses system WKWebView (no bundled Chromium), resulting in small binary sizes. Supports system tray icons, native menus, and shell commands. Version 2.9 is current stable with full macOS support. |
| aws-sdk-s3 | 1.121.0 | S3 API client for Rust | Official AWS SDK for Rust. Full S3 API support including presigned URLs, multipart uploads, and async operations. Works with any S3-compatible storage (Backblaze B2, MinIO, etc.) via endpoint configuration. |
| Tokio | 1.43+ | Async runtime | Required for aws-sdk-s3 and async filesystem operations. Use `features = ["full"]` for comprehensive async support. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| aws-config | 1.8.12+ | AWS configuration loading | Required companion to aws-sdk-s3. Loads credentials from environment, ~/.aws/credentials, or IAM roles. Use `features = ["behavior-version-latest"]` |
| serde + serde_json | 1.0+ | Configuration serialization | For storing user preferences (mount points, credentials) in JSON format |
| directories | 5.0+ | XDG directory paths | For storing config in appropriate macOS locations (`~/Library/Application Support/`) |
| thiserror | 2.0+ | Error handling | For defining custom error types with minimal boilerplate |
| tracing | 0.1+ | Structured logging | For debug output and operational visibility |
| tauri-plugin-shell | 2.x | Shell command execution | For mounting/unmounting FUSE filesystems from Tauri frontend |
| tauri-plugin-store | 2.x | Persistent storage | For saving user settings between app restarts |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Xcode / Xcode Command Line Tools | macOS development | Required for Tauri. Install via `xcode-select --install` if only building for desktop |
| cargo-tauri | Tauri CLI | Install with `cargo install tauri-cli` |
| rustup | Rust toolchain management | Install from https://rustup.rs |

## Installation

### Prerequisites

```bash
# Install macFUSE (download from https://macfuse.io or GitHub releases)
# For Apple Silicon Macs: Requires enabling kernel extensions in Recovery Mode
# For macOS 15.4+: Can use FSKit backend without kernel extension

# Install Rust
curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | sh

# Install Xcode Command Line Tools
xcode-select --install

# Install cargo-tauri
cargo install tauri-cli
```

### Cargo.toml Dependencies

```toml
[dependencies]
# FUSE filesystem
fuser = "0.16.0"

# AWS S3 SDK
aws-config = { version = "1.8.12", features = ["behavior-version-latest"] }
aws-sdk-s3 = "1.121.0"

# Async runtime
tokio = { version = "1.43", features = ["full"] }

# Serialization
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

# Configuration storage
directories = "5.0"

# Error handling
thiserror = "2.0"

# Logging
tracing = "0.1"

# Tauri (for the menu bar app)
tauri = { version = "2.9", features = ["tray-icon", "native-tls"] }

[build-dependencies]
tauri-build = { version = "2.9", features = [] }

[profile.release]
panic = "abort"
codegen-units = 1
lto = true
opt-level = "s"
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| fuser 0.16.0 | easy_fuser | Use easy_fuser if you want a higher-level, more ergonomic API with built-in templates like `MirrorFsReadOnly`. However, for a cloud storage filesystem with custom caching needs, fuser's low-level control is preferred. |
| Tauri 2.9 | SwiftUI + AppKit | Use SwiftUI if you want a 100% native macOS app with no web technologies. However, Tauri's Rust backend integration and rapid development make it ideal for a single-day build. |
| aws-sdk-s3 | rust-s3 crate | rust-s3 is simpler but less actively maintained. Use aws-sdk-s3 for production reliability and full S3 API coverage. |
| macFUSE | FSKit (native macOS 15.4+) | FSKit is Apple's new user-space filesystem framework. However, macFUSE provides broader macOS version support (12+) and mature ecosystem. Consider FSKit-only for macOS 15.4+ only deployments. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| osxfuse (legacy) | Deprecated, renamed to macFUSE. Old versions incompatible with modern macOS. | macFUSE 5.x |
| fuse-rs (archived) | No longer maintained, lacks modern Rust patterns. | fuser |
| s3fs-fuse (directly) | C++ implementation, not a library. Good reference but not embeddable. | Build custom with fuser + aws-sdk-s3 |
| Electron | Massive bundle size, memory hungry. Overkill for a menu bar app. | Tauri (uses system WebView) |
| blocking AWS SDK calls | Will freeze the UI thread. | Always use async with Tokio |

## Stack Patterns by Variant

**If targeting macOS 15.4+ only:**
- Use macFUSE's FSKit backend (`-o backend=fskit`)
- No Recovery Mode setup required for users
- Slightly different performance characteristics (user-space only)

**If supporting macOS 12-15.3:**
- Use macFUSE's Kernel Backend
- Users must enable kernel extensions in Recovery Mode (one-time)
- Best performance and full feature support

**If rapid prototyping:**
- Use easy_fuser instead of fuser for simpler trait implementation
- Provides `DefaultFuseHandler` and templates to reduce boilerplate

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| fuser 0.16.0 | macFUSE 4.x - 5.x | Requires macFUSE installed on system |
| aws-sdk-s3 1.121.0 | aws-config 1.8.x | Keep versions in sync from same SDK release |
| Tauri 2.9 | Rust 1.70+ | Requires recent Rust toolchain |
| Tokio 1.43 | aws-sdk-s3 1.x | Full compatibility with AWS SDK async runtime |

## Architecture Integration

```
┌─────────────────────────────────────────────────────────────┐
│                     Tauri App (Menu Bar)                     │
│  ┌─────────────────┐        ┌─────────────────────────────┐ │
│  │  Frontend (JS)  │◄──────►│  Rust Backend (Tauri cmds)  │ │
│  │  - Menu UI      │        │  - Config management        │ │
│  │  - Settings     │        │  - FUSE spawn/kill          │ │
│  └─────────────────┘        └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    FUSE Filesystem (Rust)                    │
│  ┌─────────────────┐        ┌─────────────────────────────┐ │
│  │  fuser trait    │◄──────►│  S3 Client (aws-sdk-s3)     │ │
│  │  implementation │        │  - List objects             │ │
│  │  - Directory    │        │  - Download                 │ │
│  │  - File ops     │        │  - Upload                   │ │
│  └─────────────────┘        └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │   macFUSE        │
                    │   (Kernel/FSKit) │
                    └──────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │   Finder/macOS   │
                    └──────────────────┘
```

## Key Implementation Notes

1. **FUSE Implementation Pattern**: Implement the `Filesystem` trait from fuser. Key methods:
   - `lookup()` - Resolve paths to file attributes
   - `readdir()` - List directory contents
   - `read()` - Read file data (fetch from S3)
   - `write()` - Write file data (upload to S3)
   - `getattr()` - Get file metadata

2. **S3-Compatible Storage**: Both AWS S3 and Backblaze B2 work with aws-sdk-s3. For B2:
   ```rust
   let config = aws_config::from_env()
       .endpoint_url("https://s3.us-west-002.backblazeb2.com")
       .load()
       .await;
   ```

3. **Background Mounting**: Use `spawn_mount2()` to run FUSE in a background thread, allowing the Tauri app to remain responsive.

4. **Menu Bar Integration**: Use Tauri's `tray-icon` feature for the status bar menu.

## Sources

- **macFUSE 5.1.3** — GitHub releases (Dec 23, 2025) — Verified current version with FSKit backend support
- **fuser 0.16.0** — docs.rs and Context7 (/websites/rs_fuser) — Verified API stability, `spawn_mount2()` recommended
- **easy_fuser** — Context7 (/websites/rs_easy_fuser) — Evaluated as alternative, 1531 code snippets
- **Tauri 2.9** — Context7 (/tauri-apps/tauri) and official docs — Verified tray-icon and native-tls features
- **aws-sdk-s3 1.121.0** — docs.rs and Context7 (/awslabs/aws-sdk-rust) — Verified S3 client usage patterns
- **Backblaze B2 S3-Compatible API** — Official docs — Verified S3 API compatibility and endpoint configuration

---
*Stack research for: CloudMount — FUSE-based cloud storage filesystem on macOS*
*Researched: 2026-02-02*
