# Project Research Summary

**Project:** CloudMount v2.0 — FSKit Pivot & Distribution
**Domain:** Native macOS filesystem extension with cloud storage (Backblaze B2) backend
**Researched:** 2026-02-05
**Confidence:** MEDIUM

## Executive Summary

CloudMount v2.0 is a complete architectural pivot: replacing the Rust/macFUSE dual-process filesystem daemon with a pure Swift FSKit app extension. FSKit is Apple's user-space filesystem framework, and the critical discovery is that **FSKit V2 (macOS 26+) introduces `FSGenericURLResource`** — purpose-built for URL/network-backed filesystems like CloudMount. This eliminates the need for macFUSE entirely and removes the requirement for users to install third-party kernel extensions. The tradeoff is a minimum deployment target of macOS 26 (Tahoe), which is acceptable since it's the current release. The entire Rust layer (fuser, reqwest, tokio, moka) is replaced by native Swift equivalents (FSKit, URLSession, async/await, NSCache), resulting in a single-language, single-build-system project.

The recommended approach is a phased migration: first establish the Xcode project structure (required — SPM cannot build app extensions), then port the B2 API client to Swift, then build the FSKit filesystem extension wiring B2 operations to FSKit protocol methods, then integrate the host app UI, and finally tackle distribution (code signing, notarization, DMG, Homebrew Cask, CI/CD). This is explicitly a **port, not a greenfield build** — every v1.0 FUSE operation maps 1:1 to an FSKit equivalent, and the existing business logic (metadata suppression, write-on-close, negative caching) carries over directly.

The key risks are: (1) FSKit is immature — `removeItem` callbacks may not fire (confirmed bug), no kernel-level caching exists (~121us per syscall overhead), and programmatic mounting requires shelling out to `mount -F`; (2) the host app and FSKit extension are separate processes, requiring App Group Keychain sharing for credentials and careful lifecycle management; (3) code signing with embedded extensions is notoriously finicky, requiring inside-out signing of each component separately and FSKit-specific entitlements (`com.apple.developer.fskit.user-access`). All three risks are manageable with the mitigations identified in research.

## Key Findings

### Recommended Stack

The v2.0 stack is radically simpler than v1.0: zero third-party dependencies for core functionality. FSKit V2 provides the filesystem framework, URLSession handles HTTP, NSCache replaces moka, and Swift async/await replaces tokio. The only retained dependency is KeychainAccess (already integrated). The build system must migrate from Package.swift to an Xcode project because SPM cannot build app extension targets.

**Core technologies:**
- **FSKit V2 (`FSGenericURLResource`, macOS 26+):** User-space filesystem framework — purpose-built for URL/network-backed filesystems; eliminates macFUSE dependency entirely
- **URLSession + Swift async/await:** HTTP client and concurrency — zero-dependency replacement for Rust reqwest + tokio; native connection pooling and HTTP/2
- **NSCache + FileManager temp directory:** Caching layer — replaces Rust moka for metadata and local file caching; thread-safe, automatic memory pressure eviction
- **Xcode project (not SPM):** Build system — required for app extension targets, Info.plist configuration, entitlements, and embedded extension bundles
- **create-dmg + notarytool:** Distribution tooling — DMG creation and Apple notarization for outside-App-Store distribution
- **GitHub Actions:** CI/CD — free for open-source, macOS runners for build/sign/notarize/release pipeline

**Critical version requirements:**
- macOS 26.0+ (Tahoe) — required for FSKit V2 `FSGenericURLResource`
- Xcode 26.0+ — required for macOS 26 SDK
- Swift 6.0+ — ships with Xcode 26, enables strict concurrency checking

### Expected Features

This is a port, so the feature set maps directly from v1.0 FUSE operations to FSKit protocol methods. The feature landscape spans four domains: FSKit filesystem operations, distribution packaging, Homebrew Cask delivery, and CI/CD automation.

**Must have (table stakes):**
- All `FSVolume.Operations` (lookup, enumerate, create, remove, rename, get/set attributes, volume statistics)
- `FSVolume.ReadWriteOperations` (read/write with local caching and write-on-close upload)
- `FSVolume.OpenCloseOperations` (file handle tracking)
- Swift B2 API client (auth, list, download, upload, delete, copy, folder creation, token refresh)
- Metadata cache and local file data cache (ported from Rust)
- macOS metadata suppression (.DS_Store, .Spotlight-V100, ._files)
- Code-signed, notarized .app bundle in .dmg with Applications symlink
- First-launch onboarding: FSKit extension enablement guidance
- Homebrew Cask formula (`brew install --cask cloudmount`)

**Should have (differentiators):**
- No macFUSE required — zero user setup for filesystem functionality
- Pure Swift single-language architecture — simpler maintenance, no IPC overhead
- Sparkle auto-update framework (post-v2.0 but high value)
- Automated Homebrew Cask version bumping in CI

**Defer (post-v2.0):**
- Sparkle auto-update (add after manual distribution is stable)
- Submit to homebrew-cask core tap (need GitHub stars first)
- Binary CLI companion (`cloudmount mount mybucket`)
- Multi-bucket simultaneous mounting
- Auto-mount on startup
- Extended attributes (xattr) — suppress as in v1.0
- Symbolic/hard links — not applicable to B2 object storage
- Directory rename — requires recursive copy+delete, extremely expensive on B2

### Architecture Approach

The architecture shifts from a dual-process model (Swift UI app + Rust FUSE daemon communicating over Unix socket JSON IPC) to an app + embedded extension model (Swift UI app + FSKit `.appex` extension). The extension is a separate process managed by the system's `fskitd` daemon, not by the host app. Communication between app and extension happens through shared state (App Group Keychain for credentials, UserDefaults for config) rather than direct IPC. The host app orchestrates mounts via `mount -F` shell command and monitors mount state via DiskArbitration or mount table polling.

**Major components:**
1. **Main App (modified)** — Menu bar UI, credential management, mount orchestration via `MountClient` (replaces `DaemonClient`), its own B2Client for bucket listing during setup
2. **FSKit Extension (.appex, new)** — `FSUnaryFileSystem` subclass with probe/load/unload, `FSVolume` subclass implementing all Operations protocols, B2Client for file I/O, metadata and file data caches
3. **Shared Framework (new)** — `BucketConfig`, `CredentialStore` (with App Group Keychain access), shared types used by both app and extension

### Critical Pitfalls

1. **FSKit extension must be manually enabled by users** — No programmatic way to enable; users must navigate System Settings > Login Items & Extensions > File System Extensions. Build an onboarding flow that detects extension state and guides users with clear instructions. Address in Phase 1.

2. **No kernel-level caching — every FSKit operation crosses user-space boundary** — ~121us per syscall vs. near-zero with FUSE's kernel cache. Implement aggressive user-space metadata caching with batch prefetching from day one. Design cache strategy in Phase 2, implement in Phase 3.

3. **`removeItem` may not be called (FSKit bug)** — Two separate forum reports confirm file deletion callbacks silently fail. Test every filesystem operation individually and be prepared to file Apple Feedback. Address in Phase 3.

4. **Code signing with embedded extensions is complex** — Must sign each component individually (extension first, then app), inside-out. `--deep` flag is unreliable. FSKit extensions need `com.apple.developer.fskit.user-access` and `com.apple.security.network.client` entitlements, plus separate entitlements files for app vs. extension. Address in Phase 5.

5. **GitHub Actions CI code signing hangs without proper keychain setup** — Must create dedicated keychain, set partition list, and use exact security command sequence to avoid UI dialogs that block headless CI. Address in Phase 6.

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Project Foundation & Build System Migration
**Rationale:** Everything depends on the Xcode project structure. SPM cannot build FSKit extensions. Must establish the multi-target project (app + extension + shared framework) before any FSKit work can begin.
**Delivers:** Working Xcode project with host app target, FSKit extension target, shared framework target. Existing SwiftUI menu bar app builds and runs (without daemon). App Group configured for Keychain sharing.
**Addresses:** Xcode project migration (STACK.md), extension Info.plist and entitlements setup (ARCHITECTURE.md), removal of Rust/macFUSE code
**Avoids:** Pitfall about SPM inability to build extensions; establishes correct project structure from the start

### Phase 2: Swift B2 API Client
**Rationale:** The B2 client is a dependency for both the FSKit extension (file I/O) and the host app (bucket listing). It's a pure port from Rust with well-understood interfaces — low risk, high value.
**Delivers:** Complete async/await B2 API client using URLSession. Actor-based for thread safety. Covers: authorize, list files, download, upload, delete, copy, folder creation, token refresh. Shared between app and extension via shared framework.
**Addresses:** All B2 API features from FEATURES.md table stakes
**Avoids:** Pitfall 10 (Sendable violations) — by using actors from day one; Pitfall 15 (reqwest-to-URLSession port) — by mapping interfaces 1:1 before implementing

### Phase 3: FSKit Filesystem Extension
**Rationale:** Core product functionality. Depends on Phase 1 (project structure) and Phase 2 (B2 client). This is the highest-risk phase due to FSKit immaturity.
**Delivers:** Fully functional FSKit extension: FSUnaryFileSystem with probe/load/unload, FSVolume with all Operations, ReadWriteOperations, OpenCloseOperations. Metadata cache, file data cache, write-on-close semantics, macOS metadata suppression.
**Addresses:** All FSKit filesystem features from FEATURES.md, architecture patterns from ARCHITECTURE.md
**Avoids:** Pitfall 2 (no kernel caching) — aggressive user-space caching; Pitfall 3 (removeItem bug) — test each operation individually; Pitfall 8 (extension lifecycle) — persist state via App Group; Pitfall 9 (no programmatic mount) — use `mount -F` via Process(); Pitfall 12 (sandbox network) — add network.client entitlement

### Phase 4: Host App Integration
**Rationale:** With the filesystem working, integrate it with the existing SwiftUI menu bar app. Replace daemon-related code with mount-based code.
**Delivers:** MountClient (replaces DaemonClient), mount/unmount orchestration via `mount -F`, mount status detection, B2 bucket listing in app (for setup), updated UI removing macFUSE references, first-launch extension enablement onboarding flow.
**Addresses:** App integration features from FEATURES.md, IPC replacement from ARCHITECTURE.md
**Avoids:** Pitfall 1 (extension not enabled) — onboarding flow with extension detection

### Phase 5: Packaging & Distribution
**Rationale:** With a working product, make it distributable. Code signing and notarization are prerequisites for everything else.
**Delivers:** Code-signed and notarized .app bundle, DMG with Applications symlink, GitHub Release with .dmg artifact, Homebrew Cask formula in self-hosted tap.
**Addresses:** All distribution features from FEATURES.md, DMG/Cask from STACK.md
**Avoids:** Pitfall 5 (nested component signing) — sign inside-out; Pitfall 6 (extension entitlements) — separate entitlements files; Pitfall 11 (Cask structure) — test locally first

### Phase 6: CI/CD Pipeline
**Rationale:** Automate the distribution pipeline. Depends on Phase 5 (signing/notarization workflow being proven manually first).
**Delivers:** GitHub Actions PR checks (build + test), tag-triggered release workflow (build, sign, notarize, DMG, GitHub Release), automated SHA256 for Cask.
**Addresses:** CI/CD features from FEATURES.md
**Avoids:** Pitfall 7 (CI keychain dialogs) — exact keychain setup sequence; Pitfall 13 (DMG flakiness) — use create-dmg tool; Pitfall 14 (outdated SDK) — pin Xcode version

### Phase Ordering Rationale

- **Phases 1, 2, 3 are strictly sequential by dependency:** Project structure then B2 client then FSKit extension. No parallelism possible.
- **Phase 4 depends on Phase 3:** Can't integrate the UI with a filesystem that doesn't exist yet.
- **Phase 5 depends on Phase 4:** Need a complete working app before packaging for distribution.
- **Phase 6 depends on Phase 5:** Must prove signing/notarization manually before automating in CI.
- **This order front-loads the highest-risk work (FSKit, Phases 1-3)** and back-loads the well-documented work (distribution/CI, Phases 5-6).
- **The port-not-greenfield nature** means Phases 2-3 have clear specifications from the existing Rust implementation — the risk is FSKit behavior, not feature ambiguity.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 1:** Needs research on Xcode File System Extension template specifics, App Group configuration for KeychainAccess library compatibility (may need to replace with raw Security framework calls)
- **Phase 3:** **High research need.** FSKit is poorly documented. Must research: exact resource type for `mount -F` (FSGenericURLResource vs FSPathURLResource), credential passing at mount time (FSTaskOptions vs Keychain), removeItem bug workarounds, Finder sidebar integration, extension enablement detection API
- **Phase 5:** Needs research on exact FSKit extension entitlement combinations for notarization (poorly documented, requires experimentation)

Phases with standard patterns (skip research-phase):
- **Phase 2:** Well-documented URLSession + async/await patterns. B2 API is simple REST. Direct port from working Rust code.
- **Phase 4:** Standard SwiftUI app development patterns. Mount orchestration via Process() is straightforward.
- **Phase 6:** GitHub Actions macOS signing/notarization is well-documented with multiple verified guides.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | FSKit API verified from local SDK headers (Xcode 26.2). URLSession, NSCache, async/await are mature. Build system requirement (Xcode project) is unambiguous. |
| Features | MEDIUM | FSKit protocol names confirmed from KhaosT/FSKitSample and forum posts. Apple's official docs are JS-rendered and couldn't be fetched. Feature mapping from FUSE to FSKit is clear but FSKit operational completeness is uncertain (removeItem bug). |
| Architecture | MEDIUM | App + extension architecture pattern is confirmed by Apple DTS. IPC replacement (shared Keychain) is standard iOS/macOS pattern. Mount mechanism (`mount -F`) is confirmed but feels fragile. Credential passing to extension at mount time needs hands-on experimentation. |
| Pitfalls | MEDIUM-HIGH | FSKit pitfalls sourced from 12+ Apple Developer Forums threads with Apple engineer responses. Code signing/CI pitfalls are well-established. The main uncertainty is whether FSKit bugs (removeItem, read-only) are fixed in macOS 26 vs. being researched on macOS 15.4. |

**Overall confidence:** MEDIUM — The stack and distribution pipeline are HIGH confidence. FSKit itself is the wild card: it's a young framework with known bugs, sparse documentation, and no official Apple sample code. The mitigation is that this is a port with clear specifications, so we know exactly what behavior to test for.

### Gaps to Address

- **Credential passing to FSKit extension at mount time:** Three potential approaches (mount options via FSTaskOptions, shared Keychain via App Group, resource specifier encoding) — needs hands-on experimentation in Phase 3
- **FSGenericURLResource vs FSPathURLResource:** Which resource type to use for `mount -F` on a virtual network filesystem. The mount command requires a resource specifier — unclear what works best for a fully virtual FS
- **KeychainAccess library with App Groups:** May not support `kSecAttrAccessGroup` natively — may need to switch to raw Security framework calls in shared code
- **Finder sidebar integration:** FSKit-mounted volumes may not appear in Finder sidebar. DiskArbitration integration is under-documented for non-block-device FSKit volumes
- **Extension enablement detection:** No documented API to programmatically check if the FSKit extension is enabled. May need to attempt mount and detect failure
- **FSKit bugs on macOS 26 vs 15.4:** Research was largely based on macOS 15.x forum posts. FSKit V2 (macOS 26) may have fixes. Need to verify on target OS
- **GitHub Actions runner availability for macOS 26 SDK:** `macos-latest` currently maps to macOS 15. May need self-hosted runner or Xcode Cloud until GitHub updates runner images

## Sources

### Primary (HIGH confidence)
- FSKit SDK headers — `/Applications/Xcode.app/.../FSKit.framework/Versions/A/Headers/` — API availability, protocol definitions, V1/V2 macros
- Apple Developer Forums FSKit tag (23 posts, Apple DTS engineer responses) — FSKit behavior, limitations, workarounds
- Apple Developer Documentation (Context7 `/websites/developer_apple`) — Notarization workflow, codesign, hardened runtime
- GitHub Actions docs (Context7 `/websites/github_en_actions`) — macOS CI signing, keychain setup
- Homebrew Cask Cookbook (https://docs.brew.sh/Cask-Cookbook) — Cask formula format, stanzas, constraints
- KhaosT/FSKitSample (https://github.com/KhaosT/FSKitSample) — Community FSKit sample project, protocol conformance patterns

### Secondary (MEDIUM confidence)
- Apple Developer Forums individual posts — Community reports on FSKit bugs (removeItem, read-only, sandbox)
- Federico Terzi's macOS code signing CI guide — GitHub Actions signing workflow
- Sparkle project documentation — Auto-update framework for macOS
- Existing v1.0 CloudMount Rust source code — FUSE operation mapping, B2 API interface

### Tertiary (LOW confidence)
- FSKit performance benchmarks (single developer, single forum post) — ~121us per syscall, needs validation on macOS 26
- FSKit kernel caching roadmap — No official Apple statement on plans
- Apple open-source msdos FSKit implementation — Reference only, won't build externally

---
*Research completed: 2026-02-05*
*Supersedes: v1.0 research summary (2026-02-02)*
*Ready for roadmap: yes*
