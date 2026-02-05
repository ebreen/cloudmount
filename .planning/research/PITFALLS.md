# Domain Pitfalls: FSKit Migration & macOS Distribution

**Domain:** FSKit filesystem extension pivot, macOS app packaging, code signing, and CI/CD distribution
**Researched:** 2026-02-05
**Confidence:** MEDIUM (FSKit is new with sparse documentation; code signing/CI patterns are well-established but complex)

---

## Critical Pitfalls

Mistakes that cause rewrites, blocked releases, or major architectural issues.

---

### Pitfall 1: FSKit Extension Must Be Explicitly Enabled by Users in System Settings

**What goes wrong:**
After installing the app, the FSKit filesystem extension does not work. Mount attempts fail with "File system named MyFS not found" or "Permission denied". The extension exists in the bundle but the system refuses to load it.

**Why it happens:**
- FSKit modules must be manually enabled by each user in System Settings > General > Login Items & Extensions > File System Extensions
- This is a per-user setting — it does not persist across user accounts (Apple Developer Forums thread on enabling FSKit globally pre-login)
- There is no programmatic way to enable the extension; it requires user interaction with System Settings
- First-time users will have no idea this step is required unless explicitly guided

**Consequences:**
- App appears completely broken on first launch
- Users give up before ever successfully mounting
- Support burden increases dramatically

**Prevention:**
- Implement first-launch onboarding flow that detects if the extension is enabled
- Show clear step-by-step instructions with screenshots directing users to System Settings
- Use `pluginkit` to check extension registration status and guide the user
- Add a "Setup Required" state to the menu bar UI that persists until the extension is confirmed active
- Consider a deep-link to the relevant System Settings pane if possible

**Detection (warning signs):**
- Mount command returns "File system not found" errors
- `extensionkitservice` logs show "Failed to find extension" in Console.app
- Users report "nothing happens" after install

**Phase to address:** Phase 1 (FSKit Foundation) — first-launch extension detection and onboarding UX

**Confidence:** HIGH — Multiple Apple Developer Forums posts confirm this behavior (threads: 798328, 776322, 786270)

---

### Pitfall 2: FSKit Has No Kernel-Level Caching — Every Operation Hits User Space

**What goes wrong:**
Directory listings and file attribute lookups are 10-100x slower than expected. Even trivial operations like `ls` on a directory with hardcoded items take >100μs per syscall due to FSKit ↔ kernel round-trip overhead.

**Why it happens:**
- Unlike FUSE (which supports `entry_timeout`, `attr_timeout`, `cache_readdir`, and `keep_cache`), FSKit currently has NO kernel-level caching mechanism
- Every `getdirentries` syscall crosses the kernel ↔ user-space boundary via XPC
- FSKit doesn't support caching lookups, negative lookups, attributes, or readdir results at the kernel level
- Each FSItem lookup/attribute fetch incurs full XPC serialization overhead (~121μs per call measured in practice)
- Apple has not documented any plans to add kernel caching to FSKit

**Consequences:**
- Directory listings with hundreds of files become noticeably slow
- Finder feels sluggish when browsing mounted volumes
- Network filesystem implementations (like ours) compound the problem: XPC overhead + HTTP latency
- Users perceive the app as "laggy" compared to macFUSE-based alternatives

**Prevention:**
- Implement aggressive user-space metadata caching with configurable TTL
- Cache entire directory listings, not just individual items
- Prefetch metadata in batches when a directory is first opened
- Design the FSItem implementation to minimize XPC round-trips (cache all attributes locally)
- Set realistic expectations: FSKit performance ceiling is lower than FUSE for metadata-heavy workloads
- Monitor `getdirentries` latency and report in debug logs

**Detection (warning signs):**
- `ls` takes >1 second on directories with 100+ files
- Finder preview pane causes visible delays when selecting files
- Console.app shows rapid-fire FSKit XPC messages

**Phase to address:** Phase 2 (B2 Client) and Phase 3 (FSKit Filesystem) — design caching strategy from day one

**Confidence:** MEDIUM-HIGH — Apple Developer Forums thread on FSKit caching and performance (thread 793013) provides measured overhead data. No contradicting official documentation found.

---

### Pitfall 3: FSKit removeItem/Delete Operations Silently Fail

**What goes wrong:**
Files can be created, read, and written, but deletion via Finder or `rm` silently fails. The `removeItem(_:named:fromDirectory:)` callback is never invoked by the system.

**Why it happens:**
- This appears to be a known FSKit bug/limitation as of macOS 15.x
- Multiple developers have reported the same issue (Apple Developer Forums threads 808369, 808370)
- The FSVolume.Operations protocol requires `removeItem` but the system may not dispatch to it correctly in all cases
- The interaction between FSKit and Finder's trash mechanism adds complexity
- Volume capabilities configuration may affect which operations are dispatched

**Consequences:**
- Users cannot delete files from mounted volumes
- Finder shows confusing "trash" behavior that doesn't actually work
- Core filesystem functionality is broken

**Prevention:**
- Test delete operations early in FSKit development (don't assume protocol conformance = working dispatch)
- File Apple Feedback Assistant reports for any missing callbacks
- Implement and test all `FSVolume.*Operations` protocols systematically
- Have integration tests that verify each POSIX operation actually invokes the corresponding FSKit callback
- Be prepared to work around FSKit bugs by checking each macOS point release for fixes

**Detection (warning signs):**
- No log output from removeItem when files are deleted
- `rm -rf` returns without error but files persist
- Finder "Move to Trash" fails silently

**Phase to address:** Phase 3 (FSKit Filesystem) — test every filesystem operation individually before integration

**Confidence:** HIGH — Two separate Apple Developer Forums threads (808369, 808370) report identical behavior from different developers. No official Apple response or workaround found.

---

### Pitfall 4: Read-Only Volume Support Broken in FSKit

**What goes wrong:**
Mounting a filesystem as read-only doesn't actually prevent write operations in Finder. Users can create folders, and write operations either fail silently, succeed temporarily then disappear, or produce confusing errors.

**Why it happens:**
- FSKit does not properly communicate read-only status to Finder/the VFS layer
- Even Apple's own msdos FSKit implementation exhibits this behavior
- The `-r` / `-o rdonly` mount flags are not properly forwarded to FSKit extensions
- There's no documented way to mark an FSKit volume as read-only at the VFS level
- FSKit's read-only state appears to only be available in the `activate` call options, not at the VFS mount level

**Consequences:**
- For CloudMount this is less critical (we support writes), but if a user's B2 key is read-only, the UX will be confusing
- Operations that should be rejected at the Finder level will instead be rejected at the B2 API level with poor error messages

**Prevention:**
- Implement proper POSIX error returns (EROFS) for all write operations when B2 credentials are read-only
- Don't rely on FSKit to communicate read-only status to Finder — handle it in your own code
- Consider showing a visual indicator (read-only badge) in the menu bar when mounted with limited permissions

**Detection (warning signs):**
- Finder allows "New Folder" on read-only mounts
- Drag-and-drop appears to work but files vanish after a moment

**Phase to address:** Phase 3 (FSKit Filesystem) — implement explicit write-permission checking

**Confidence:** HIGH — Apple Developer Forums thread (807771) with detailed reproduction. Apple's own msdos extension has the same issue.

---

### Pitfall 5: Code Signing Extensions Requires Separate Signing of Each Component

**What goes wrong:**
The notarization step fails with cryptic errors. The app runs locally but Gatekeeper blocks it on other machines. Users see "app is damaged and can't be opened" or the app simply doesn't launch.

**Why it happens:**
- An .app bundle containing an extension has MULTIPLE signable components: the app, the extension, any frameworks, and any helper tools
- Each component must be signed individually, from the inside out (deepest nested component first)
- The `--deep` flag for codesign is unreliable and not recommended by Apple
- The extension must be signed with the same team ID but its own signing identity
- Hardened Runtime (`--options runtime`) must be enabled for notarization but may break certain behaviors
- If any single nested component is unsigned or incorrectly signed, notarization fails

**Consequences:**
- Notarization fails with "The signature of the binary is invalid" for nested components
- App works in dev but fails on any other machine
- CI builds produce broken artifacts that can't be distributed
- Debugging signing issues is time-consuming (logs are opaque)

**Prevention:**
- Sign components explicitly from inside out: extension → app → .dmg
- Use `codesign --force -s "Developer ID Application: ..." --options runtime --timestamp` for each component
- After signing, verify with `codesign --verify --deep --strict --verbose=2 YourApp.app`
- Use `spctl --assess --type exec -v YourApp.app` to check Gatekeeper acceptance
- In CI, create a dedicated keychain and import the .p12 certificate (see CI section below)
- Test the signed .dmg on a DIFFERENT Mac before publishing releases

**Detection (warning signs):**
- `codesign -vvv` shows "invalid signature" for nested components
- `spctl --assess` returns "rejected"
- Notarytool returns "Invalid" status

**Phase to address:** Phase 4 (Packaging & Distribution) — signing must be correct before any distribution

**Confidence:** HIGH — Well-documented in Apple developer docs and verified via Federico Terzi's CI signing guide (https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/)

---

### Pitfall 6: Notarization Fails for Apps with File System Extensions Due to Missing Entitlements

**What goes wrong:**
Code signing succeeds locally, but notarization returns "Invalid" with no clear explanation. The log reveals entitlement mismatches or missing capabilities.

**Why it happens:**
- FSKit extensions require the `com.apple.developer.fskit.user-access` entitlement
- The extension needs its own entitlements file separate from the host app
- Sandbox entitlement (`com.apple.security.app-sandbox`) is required for FSKit extensions but conflicts with certain filesystem operations
- If you remove the sandbox entitlement, the extension can't be loaded via `pluginkit`
- Provisioning profiles must cover both the app and the extension with correct entitlements
- Developer ID distribution requires entitlements that differ from App Store distribution

**Consequences:**
- Notarization silently rejects the binary
- Extension loads in development but fails when distributed
- Weeks of debugging entitlement combinations

**Prevention:**
- Create separate entitlement files for the host app and the FSKit extension
- Ensure the FSKit extension has: `com.apple.security.app-sandbox`, `com.apple.developer.fskit.user-access`
- Use Xcode's automatic signing during development, but understand what it generates
- For CI/distribution: export provisioning profiles and entitlements explicitly
- Test notarized builds on a clean machine BEFORE publishing
- Use `xcrun notarytool log <id> --keychain-profile "profile"` to see detailed rejection reasons

**Detection (warning signs):**
- Notarytool returns status "Invalid"
- Extension works in Xcode debug builds but not archived/exported builds
- Console.app shows "Sandbox restriction" errors from the extension

**Phase to address:** Phase 4 (Packaging & Distribution) — resolve entitlements before CI setup

**Confidence:** MEDIUM — FSKit entitlement requirements are poorly documented. Apple Developer Forums thread (808246) on sandbox restrictions confirms the conflict. Specific entitlement combinations need experimentation.

---

### Pitfall 7: GitHub Actions macOS Code Signing Creates UI Dialogs That Block CI

**What goes wrong:**
The CI build hangs indefinitely during the code signing step. No output, no error — just a timeout after N minutes.

**Why it happens:**
- When importing a certificate into a keychain on macOS, the system may prompt a UI dialog asking for the certificate password
- In a headless CI environment (GitHub Actions), no one can click "Allow"
- The `security` command requires specific flags to avoid prompts:
  - `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" build.keychain`
- Failing to unlock the keychain or set the partition list causes `codesign` to hang waiting for user input
- The default keychain may interfere if not explicitly overridden

**Consequences:**
- CI jobs time out (10+ minutes of silence)
- Intermittent failures that are hard to reproduce locally
- Wasted CI minutes and blocked releases

**Prevention:**
- Follow this exact sequence in CI:
  1. Decode base64 certificate to .p12 file
  2. Create a NEW keychain: `security create-keychain -p "$PWD" build.keychain`
  3. Set it as default: `security default-keychain -s build.keychain`
  4. Unlock it: `security unlock-keychain -p "$PWD" build.keychain`
  5. Import certificate: `security import cert.p12 -k build.keychain -P "$CERT_PWD" -T /usr/bin/codesign`
  6. Set partition list: `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PWD" build.keychain`
- Store the .p12 certificate as a base64-encoded GitHub Actions secret
- Use a randomly generated keychain password (stored as secret)
- Add timeout to the signing step so failures are caught quickly

**Detection (warning signs):**
- CI step hangs with no output
- Works locally but fails in CI
- Intermittent "User interaction is not allowed" errors

**Phase to address:** Phase 5 (CI/CD) — implement signing workflow

**Confidence:** HIGH — Well-documented pattern. Verified via Federico Terzi's guide and multiple open-source projects (Espanso, etc.)

---

## Moderate Pitfalls

Mistakes that cause delays, rework, or degraded user experience.

---

### Pitfall 8: FSKit Extension Process Lifecycle Is Managed by the System, Not Your App

**What goes wrong:**
The FSKit extension process starts and stops unexpectedly. The extension is terminated while a volume is mounted, causing the mount to become inaccessible. System-wide disk operations freeze.

**Why it happens:**
- FSKit extensions run as separate processes managed by `extensionkitservice` and `fskitd`
- The host app does NOT control the extension's lifecycle — the system does
- If the host app is updated (e.g., via App Store or Homebrew), the extension process may be terminated without a clean unmount
- Killing or crashing the FSModule process while a volume is mounted can freeze ALL disk-related actions system-wide until reboot
- The extension gets a new UUID each time it's re-registered by `lsd`, and `extensionkitservice` may reference a stale UUID

**Consequences:**
- Mounted volumes become inaccessible mid-use
- Disk Utility freezes on "Loading disks"
- `mount(8)` command hangs
- System requires reboot to recover
- Update mechanism can corrupt active mounts

**Prevention:**
- Implement clean unmount in the host app BEFORE any update/quit sequence
- Persist mount state so the app can detect and recover orphaned mounts on launch
- Handle `synchronize()` and other cleanup callbacks to flush dirty data
- Don't store any critical state only in the extension process — persist to the host app's container
- Add watchdog logic in the host app that detects when the extension process dies
- For development: always unmount before rebuilding in Xcode

**Detection (warning signs):**
- Console.app shows "Failed to find extension: <UUID>" from extensionkitservice
- `mount` command hangs after rebuild
- Disk Utility shows "Loading disks" spinner indefinitely

**Phase to address:** Phase 3 (FSKit Filesystem) — design for extension process instability from day one

**Confidence:** HIGH — Apple Developer Forums threads (809747, 804432) document this behavior in detail.

---

### Pitfall 9: FSKit Mounting Is Currently Limited — No Programmatic Mount API

**What goes wrong:**
You can't mount the filesystem programmatically from your SwiftUI host app. The only reliable way to mount is via the `mount -F` terminal command.

**Why it happens:**
- FSKit is not yet fully integrated with DiskArbitration
- There is no public Swift API for `mount -F` equivalent
- The `DiskArbitration` framework works with `FSBlockDeviceResource` but not with `FSGenericURLResource` or `FSPathURLResource` programmatically
- For network filesystems (like B2), there's no block device — the resource is a URL
- Multiple forum posts ask about this with no official Apple solution

**Consequences:**
- The host app may need to shell out to `mount -F` command, which feels hacky
- App sandbox restrictions may prevent executing `mount`
- User experience is degraded if mounting requires terminal interaction
- Automounting on launch becomes complex

**Prevention:**
- Design the mount flow to use `Process()` to invoke `mount -F -t CloudMountFS <resource> <mountpoint>`
- Request necessary sandbox exceptions for subprocess execution
- Alternatively, investigate if the host app can use private/semi-documented DiskArbitration APIs
- Implement a robust mount-state machine that handles mount/unmount through the system command
- Provide a fallback "Copy mount command" button for users if programmatic mounting fails
- Monitor Apple's FSKit updates — programmatic mounting API may come in a future macOS release

**Detection (warning signs):**
- `DiskArbitration` calls fail for non-block-device resources
- App sandbox prevents `mount` execution

**Phase to address:** Phase 3 (FSKit Filesystem) — determine mount mechanism early in design

**Confidence:** MEDIUM-HIGH — Apple Developer Forums threads (797485, 799283) confirm this limitation. No official programmatic API found.

---

### Pitfall 10: Swift Concurrency Sendable Violations When Porting From Rust

**What goes wrong:**
The Swift compiler produces hundreds of `Sendable` warnings and errors when the B2 client and caching code is ported from Rust. Data races that Rust's borrow checker prevented must now be manually addressed in Swift.

**Why it happens:**
- Rust's ownership model automatically prevents data races at compile time
- Swift 6's strict concurrency checking requires explicit `Sendable` conformance for types that cross isolation boundaries
- URLSession delegates and completion handlers cross actor boundaries
- Shared mutable state (caches, connection pools) must be protected with actors or locks
- FSKit callbacks run on arbitrary threads — any shared state accessed from those callbacks must be `Sendable`

**Consequences:**
- Compiler errors block progress
- Rushed `@unchecked Sendable` workarounds hide real thread-safety bugs
- Data races that were impossible in Rust become possible in Swift

**Prevention:**
- Use Swift 6 language mode from the start (`swift-tools-version: 6.0`)
- Design the B2 client as an `actor` from the beginning
- Use `AsyncStream` and `AsyncThrowingStream` for response handling
- Make all data types used across boundaries value types (`struct`) or `Sendable` classes
- Avoid `@unchecked Sendable` — if you need it, something is wrong
- Use `@preconcurrency import` only for genuinely unmigrated dependencies
- Structure FSKit callbacks to dispatch to a single actor that owns all mutable state

**Detection (warning signs):**
- Compiler warnings about "Sendable" in every file
- Runtime crashes with "data race detected" in debug builds
- Intermittent incorrect results from cache lookups

**Phase to address:** Phase 2 (B2 Client Port) — establish concurrency patterns before building on them

**Confidence:** HIGH — Swift migration guide (Context7 /swiftlang/swift-migration-guide) documents these patterns extensively.

---

### Pitfall 11: Homebrew Cask Requires Specific .dmg Structure and Metadata

**What goes wrong:**
The Homebrew Cask PR is rejected by maintainers, or `brew install --cask cloudmount` installs the app but the FSKit extension isn't properly registered.

**Why it happens:**
- Homebrew Cask expects a specific artifact layout: `.dmg` containing a `.app` bundle
- The Cask formula must declare `depends_on macos: ">= :sequoia"` (macOS 15.4+) since FSKit requires it
- Extensions embedded in the .app bundle need the app to be in /Applications for the extension to register
- The `livecheck` stanza must be configured to auto-detect new releases from GitHub
- `zap` stanza must clean up all app-specific files (preferences, caches, keychain items)
- SHA-256 hash must match the downloaded artifact exactly
- The Cask won't be accepted to homebrew-cask main tap without proper `uninstall` handling

**Consequences:**
- Cask PR bounced by Homebrew maintainers
- Users install via Homebrew but extension doesn't load
- Upgrades break because old extension isn't properly uninstalled

**Prevention:**
- Structure the DMG to contain exactly one .app bundle at the root
- Cask formula pattern:
  ```ruby
  cask "cloudmount" do
    version "2.0.0"
    sha256 "..."
    url "https://github.com/.../releases/download/v#{version}/CloudMount-#{version}.dmg"
    name "CloudMount"
    desc "Mount Backblaze B2 cloud storage as local drives"
    homepage "https://github.com/..."
    depends_on macos: ">= :sequoia"
    app "CloudMount.app"
    # Extension registration handled by macOS on app install to /Applications
    zap trash: [
      "~/Library/Preferences/com.cloudmount.*",
      "~/Library/Caches/com.cloudmount.*",
    ]
  end
  ```
- Start with a self-hosted tap (`homebrew-cloudmount`) before submitting to the main `homebrew-cask` tap
- Test the Cask formula locally: `brew install --cask ./cloudmount.rb`
- Consider adding `caveats` about enabling the File System Extension in System Settings

**Detection (warning signs):**
- `brew audit --cask cloudmount` reports errors
- Extension not visible in System Settings after Cask install
- `brew upgrade` fails to properly re-register the extension

**Phase to address:** Phase 4 (Packaging & Distribution) — create and test Cask formula alongside DMG creation

**Confidence:** HIGH — Homebrew Cask Cookbook documentation is comprehensive and verified via webfetch.

---

### Pitfall 12: FSKit Sandbox Restrictions Block Network Access

**What goes wrong:**
The FSKit extension can't make HTTP requests to the B2 API. Network calls fail with sandbox violations.

**Why it happens:**
- FSKit extensions run in a sandboxed environment
- The `com.apple.security.app-sandbox` entitlement is required but restricts network access by default
- You must explicitly add `com.apple.security.network.client` entitlement to the extension
- File access from within the extension is also restricted — you can only access the resource provided to you
- Accessing files outside the sandbox (e.g., reading a config file from the host app's container) requires additional entitlements or IPC

**Consequences:**
- B2 API calls fail silently or with cryptic errors
- Extension loads but can't do anything useful
- Debugging is difficult because sandbox violations appear in Console.app, not your app's logs

**Prevention:**
- Add `com.apple.security.network.client` to the extension's entitlements
- Use App Groups to share data between the host app and the extension
- Design the extension to receive all configuration (credentials, endpoints) through the mount options or via a shared App Group container
- Test the extension in release/archive mode, not just debug (debug builds may have relaxed sandbox)
- Monitor Console.app for `sandboxd` violations during development

**Detection (warning signs):**
- URLSession errors with domain "NSPOSIXErrorDomain" in the extension
- Console.app shows "deny(1) network-outbound" from the extension process
- Works in debug builds but not archived builds

**Phase to address:** Phase 3 (FSKit Filesystem) — verify network access early when integrating B2 client

**Confidence:** MEDIUM — Apple Developer Forums thread (808246, 779672) confirms sandbox issues. Specific entitlement combinations for network FSKit extensions are not well-documented.

---

## Minor Pitfalls

Mistakes that cause annoyance, polish issues, or are easily fixable.

---

### Pitfall 13: DMG Creation on GitHub Actions Requires hdiutil Workarounds

**What goes wrong:**
`hdiutil create` fails intermittently on GitHub Actions macOS runners, or produces a DMG that doesn't open correctly on user machines.

**Why it happens:**
- `hdiutil` on CI runners can be flaky due to resource constraints
- The DMG needs to be properly structured with a background image and icon placement for professional appearance
- `hdiutil attach` may require `-mountpoint` flag to avoid conflicts
- Disk image creation requires sufficient free space on the runner

**Prevention:**
- Use `create-dmg` npm package or `create-dmg` shell script for reliable DMG creation
- Add retry logic around `hdiutil` commands
- Verify DMG by mounting it in the CI step after creation
- Keep DMG creation simple initially (just the .app, no custom background)

**Phase to address:** Phase 4 (Packaging) or Phase 5 (CI/CD)

**Confidence:** MEDIUM — Based on common CI/CD patterns for macOS app distribution.

---

### Pitfall 14: GitHub Actions macOS Runners Have Outdated Xcode/SDK

**What goes wrong:**
The CI build fails because the runner doesn't have macOS 15.4 SDK (required for FSKit).

**Why it happens:**
- GitHub Actions macOS runners lag behind the latest macOS releases
- FSKit requires macOS 15.4+ SDK to compile
- The runner image may have an older Xcode that doesn't include the required SDK

**Prevention:**
- Explicitly select the Xcode version in CI: `xcodes select 16.x` or `xcode-select -s /Applications/Xcode_16.x.app`
- Check GitHub Actions runner image release notes for available Xcode versions
- If needed, use `macos-15` runner image (when available) instead of `macos-14`
- Consider Xcode Cloud as a fallback if GitHub runners don't support the required SDK

**Phase to address:** Phase 5 (CI/CD) — verify runner capabilities before building workflow

**Confidence:** MEDIUM — GitHub Actions runner images are updated regularly but FSKit SDK requirement is specific.

---

### Pitfall 15: Porting Rust reqwest HTTP Client Patterns to Swift URLSession

**What goes wrong:**
The B2 API client port seems straightforward but subtle differences between reqwest and URLSession cause auth failures, incorrect streaming, or timeout issues.

**Why it happens:**
- Rust's `reqwest` uses explicit `.body()` with `Bytes`; Swift's `URLSession` uses `Data` or `InputStream`
- Connection pooling is automatic in both but configured differently
- Retry logic in Rust (manual) must be reimplemented in Swift
- B2's auth token refresh flow must handle concurrent requests (Rust's `Arc<Mutex<>>` → Swift's `actor`)
- Upload/download progress tracking uses different patterns
- Error types are completely different (reqwest::Error vs URLError)

**Prevention:**
- Map Rust B2 client functions 1:1 to Swift protocols first (interface before implementation)
- Use `URLSession.shared` for connection pooling (it handles keep-alive automatically)
- Implement an `actor B2Client` to manage auth token state
- Use `AsyncBytes` for streaming downloads, `URLSession.upload(for:from:)` for uploads
- Implement exponential backoff retry as middleware
- Port the test suite alongside the implementation

**Phase to address:** Phase 2 (B2 Client Port) — design the Swift B2 client API before implementing

**Confidence:** HIGH — URLSession and async/await patterns are well-documented via Context7/Swift docs.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Severity | Mitigation |
|-------------|---------------|----------|------------|
| FSKit Foundation | Extension not enabled by user | CRITICAL | Onboarding flow with extension detection |
| FSKit Foundation | No kernel caching available | CRITICAL | Design aggressive user-space caching from start |
| B2 Client Port | Sendable violations everywhere | MODERATE | Use actors, design for concurrency from day one |
| B2 Client Port | Auth token race conditions | MODERATE | Actor-based token management |
| FSKit Filesystem | removeItem not being called | CRITICAL | Test each operation individually, file Apple bugs |
| FSKit Filesystem | Programmatic mount not available | MODERATE | Shell out to `mount -F`, design for future API |
| FSKit Filesystem | Extension process killed during mount | MODERATE | Persist state in host app, implement recovery |
| FSKit Filesystem | Sandbox blocks network access | MODERATE | Add network entitlement, test in release mode |
| Packaging & Distribution | Signing nested components incorrectly | CRITICAL | Sign inside-out, verify each component |
| Packaging & Distribution | Notarization fails for extension entitlements | CRITICAL | Separate entitlements files, test on clean Mac |
| Packaging & Distribution | Homebrew Cask structure wrong | MODERATE | Test locally, start with self-hosted tap |
| CI/CD | Keychain UI dialogs block CI | CRITICAL | Follow exact keychain setup sequence |
| CI/CD | Runner missing macOS 15.4 SDK | MODERATE | Pin Xcode version, verify runner image |
| CI/CD | DMG creation flaky | MINOR | Use create-dmg tool, add retry logic |

## Technical Debt Patterns (v2.0 Specific)

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Shell out to `mount -F` | Working mount mechanism | Brittle, sandbox concerns | Until Apple adds programmatic mount API |
| `@unchecked Sendable` on types | Silence compiler warnings | Hidden data races | NEVER — use actors instead |
| Hardcoded entitlements | Gets builds working | Breaks on distribution | Development only — must formalize for release |
| Skip notarization in dev | Faster iteration | Can't test real UX | Local dev only — must notarize for any distribution |
| No extension health monitoring | Simpler architecture | Silent mount failures | MVP only — add watchdog before release |
| Single-key keychain storage | Quick credential sharing | Security concerns | MVP — move to App Group shared container |

## Integration Gotchas (v2.0 Specific)

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| FSKit + Sandbox | Forgetting network entitlement | Add `com.apple.security.network.client` to extension |
| FSKit + B2 API | Passing credentials via mount options | Use App Group shared container or Keychain group |
| FSKit + Finder | Assuming read-only propagates | Handle EROFS explicitly in all write callbacks |
| Code Signing + Extension | Using `--deep` flag | Sign each component individually, inside-out |
| Notarization + CI | Using interactive notarytool | Use `store-credentials` + `--keychain-profile` |
| Homebrew Cask + Extension | Assuming extension auto-registers | Add caveats about System Settings enablement |
| GitHub Actions + Signing | Default keychain | Create dedicated build keychain with partition list |
| Swift 6 + FSKit callbacks | Forgetting isolation | FSKit callbacks cross isolation; use actor to protect state |

## "Looks Done But Isn't" Checklist (v2.0)

- [ ] **Extension enabled:** Verify extension appears in System Settings and is toggled ON
- [ ] **Mount works:** `mount -F -t CloudMountFS` succeeds and volume appears in Finder
- [ ] **CRUD complete:** Create, read, update, AND delete files — test delete specifically (Pitfall 3)
- [ ] **Signed correctly:** `codesign --verify --deep --strict` passes for app AND extension
- [ ] **Notarized:** `spctl --assess --type exec` returns "accepted" on a DIFFERENT Mac
- [ ] **DMG valid:** .dmg opens, drag-to-Applications works, extension registers
- [ ] **Homebrew works:** `brew install --cask cloudmount` from scratch succeeds
- [ ] **CI produces working artifact:** Download artifact from CI, verify it works on clean machine
- [ ] **First-launch UX:** Test on machine that has never seen CloudMount — extension enablement flow works
- [ ] **Sleep/wake:** Mount survives macOS sleep cycle
- [ ] **Extension crash recovery:** Kill the extension process, verify host app detects and recovers

## Recovery Strategies (v2.0 Specific)

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Extension not enabled | LOW | Guide user to System Settings, no data loss |
| Extension process killed | MEDIUM | Relaunch app, remount — risk of unflushed writes |
| System-wide disk freeze | HIGH | Reboot required. File Apple bug. |
| Notarization rejected | LOW | Check logs (`notarytool log`), fix entitlements, re-submit |
| Signing CI hang | LOW | Add timeout, verify keychain setup sequence |
| Cask rejected by Homebrew | LOW | Fix audit issues, re-submit PR |
| Sendable violations | MEDIUM | Refactor to use actors — may require significant code changes |
| B2 auth race condition | MEDIUM | Serialize auth refreshes through actor |

## Sources

**Apple Developer Forums (FSKit):**
- Thread 809747: FSKit module update safety, unclean unmounts — https://forums.developer.apple.com/forums/thread/809747
- Thread 807771: Read-only filesystem support broken — https://forums.developer.apple.com/forums/thread/807771
- Thread 808369/808370: removeItem not being called — https://forums.developer.apple.com/forums/thread/808369
- Thread 808246: Sandbox restrictions and testing — https://forums.developer.apple.com/forums/thread/808246
- Thread 793013: FSKit caching and performance overhead — https://forums.developer.apple.com/forums/thread/793013
- Thread 798328: Permission denied on physical disks — https://forums.developer.apple.com/forums/thread/798328
- Thread 786270: Probing and mounting issues — https://forums.developer.apple.com/forums/thread/786270
- Thread 799283: Programmatic mounting limitations — https://forums.developer.apple.com/forums/thread/799283
- Thread 779672: Accessing external files from FSKit module — https://forums.developer.apple.com/forums/thread/779672
- Thread 804432: Intermittent mount failures during development — https://forums.developer.apple.com/forums/thread/804432
- Thread 766793: FSKit questions from EdenFS team (Meta) — https://forums.developer.apple.com/forums/thread/766793
- Thread 776322: FSKit documentation/sample availability — https://forums.developer.apple.com/forums/thread/776322

**FSKit Sample Project:**
- KhaosT/FSKitSample: https://github.com/KhaosT/FSKitSample — Community-maintained sample, only reference implementation available

**Code Signing & Notarization:**
- Federico Terzi: Automatic code signing and notarization with GitHub Actions — https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/
- Apple: Notarizing macOS software before distribution — https://developer.apple.com/documentation/xcode/notarizing_macos_software_before_distribution

**Homebrew Cask:**
- Cask Cookbook: https://docs.brew.sh/Cask-Cookbook — verified via webfetch

**Swift Concurrency:**
- Swift Migration Guide (Context7 /swiftlang/swift-migration-guide) — Sendable patterns, actor isolation

**Confidence Assessment:**
- FSKit pitfalls: MEDIUM — Framework is new (GA in macOS 15.4, March 2025), documentation sparse, community experience limited. Forum posts are the best source.
- Code signing pitfalls: HIGH — Well-established patterns, multiple verified guides.
- Homebrew Cask pitfalls: HIGH — Official documentation is comprehensive.
- Swift concurrency pitfalls: HIGH — Context7-verified documentation.

---
*Pitfalls research for: CloudMount v2.0 — FSKit Pivot & Distribution*
*Researched: 2026-02-05*
