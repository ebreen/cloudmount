# Phase 8: Distribution - Research

**Researched:** 2026-02-06
**Domain:** macOS app distribution — code signing, notarization, DMG packaging, Homebrew Cask, Sparkle auto-update, CI/CD
**Confidence:** HIGH

## Summary

Phase 8 covers the full distribution pipeline for CloudMount: code signing with Developer ID, notarization, DMG creation, Homebrew Cask in an own tap, Sparkle auto-update integration, and CI/CD via GitHub Actions.

The standard approach is: `xcodebuild archive` → `xcodebuild -exportArchive` (Developer ID) → `xcrun notarytool submit --wait` → `xcrun stapler staple` → `create-dmg` for DMG packaging → upload to GitHub Releases → Sparkle `generate_appcast` for the appcast.xml → Homebrew Cask in `homebrew-cloudmount` tap with `livecheck` pointing to GitHub Releases.

Critical discovery: GitHub Actions now offers `macos-26` as a **public preview** ARM64 runner, which means the macOS 26 SDK concern is resolved — no self-hosted runner needed. The build-sign-notarize-release pipeline can run entirely on GitHub-hosted infrastructure.

**Primary recommendation:** Use `macos-26` GitHub Actions runner with xcodegen → xcodebuild archive → Developer ID export → notarytool → create-dmg → GitHub Release → Sparkle appcast → Homebrew Cask tap bump.

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| xcodebuild | Xcode 26 | Archive & export app for Developer ID distribution | Apple's official build tool, required for code signing + hardened runtime |
| xcrun notarytool | Xcode 14+ (ships with Xcode 26) | Notarize app bundle with Apple | Replaced altool (deprecated), faster async submission |
| xcrun stapler | System tool | Staple notarization ticket to DMG | Enables offline Gatekeeper validation |
| create-dmg | 1.2.3 | Build DMG with Applications symlink | 2.5k stars, Homebrew installable, handles hdiutil complexity |
| Sparkle | 2.x (latest stable) | Auto-update framework for macOS | De-facto standard for non-App-Store macOS auto-updates |
| GitHub Actions | N/A | CI/CD pipeline | Standard for GitHub-hosted projects, `macos-26` runner available |

### Supporting

| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| xcodegen | Current | Generate Xcode project from project.yml | Already in project — use for CI builds |
| gh CLI | Latest | Create GitHub Releases, manage artifacts | Uploading release assets, creating releases |
| shasum | System | Generate SHA-256 checksums | Create checksum files for DMG verification |
| codesign | System | Verify code signatures | Validation step in pipeline |
| spctl | System | Gatekeeper assessment | Verify notarized app passes Gatekeeper |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| create-dmg | hdiutil directly | create-dmg abstracts hdiutil complexity, handles icon positions and Applications symlink in one command |
| create-dmg | dmgbuild (Python) | dmgbuild requires Python dependency; create-dmg is shell-only, Homebrew installable |
| notarytool | altool | altool is deprecated by Apple; notarytool is the replacement |
| Sparkle via SPM | Sparkle manual embed | SPM is cleanest integration path with xcodegen; manual embed works but more setup |

**Installation (CI):**
```bash
brew install create-dmg xcodegen
```

## Architecture Patterns

### Recommended Project Structure Additions
```
.github/
├── workflows/
│   ├── ci.yml                    # PR build + test
│   └── release.yml               # Tag-triggered release pipeline
scripts/
├── export-options.plist          # ExportOptions for Developer ID distribution
├── create-dmg.sh                 # DMG creation script
└── bump-cask.sh                  # Homebrew Cask version bump script
```

### Pattern 1: Archive → Export → Sign → Notarize → DMG Pipeline

**What:** The canonical macOS Developer ID distribution flow
**When to use:** Every release build
**Example:**
```bash
# Source: Apple Developer Documentation + GitHub Actions docs

# Step 1: Generate Xcode project
xcodegen generate

# Step 2: Archive
xcodebuild archive \
  -project CloudMount.xcodeproj \
  -scheme CloudMount \
  -archivePath "$RUNNER_TEMP/CloudMount.xcarchive" \
  -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" \
  DEVELOPMENT_TEAM="TEAM_ID" \
  CODE_SIGN_STYLE=Manual

# Step 3: Export (Developer ID distribution)
xcodebuild -exportArchive \
  -archivePath "$RUNNER_TEMP/CloudMount.xcarchive" \
  -exportPath "$RUNNER_TEMP/export" \
  -exportOptionsPlist scripts/export-options.plist

# Step 4: Notarize
xcrun notarytool submit "$RUNNER_TEMP/export/CloudMount.app" \
  --apple-id "$APPLE_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

# Step 5: Staple (staple the DMG, not the .app, after DMG creation)
# Note: staple the DMG after creating it, OR staple the .app before putting it in the DMG

# Step 6: Create DMG
create-dmg \
  --volname "CloudMount" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "CloudMount.app" 150 190 \
  --app-drop-link 450 190 \
  --hide-extension "CloudMount.app" \
  "CloudMount-${VERSION}.dmg" \
  "$RUNNER_TEMP/export/"

# Step 7: Notarize the DMG (recommended: notarize DMG not just the .app)
xcrun notarytool submit "CloudMount-${VERSION}.dmg" \
  --apple-id "$APPLE_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

# Step 8: Staple the DMG
xcrun stapler staple "CloudMount-${VERSION}.dmg"

# Step 9: Generate checksum
shasum -a 256 "CloudMount-${VERSION}.dmg" > "CloudMount-${VERSION}.dmg.sha256"
```

### Pattern 2: ExportOptions.plist for Developer ID Distribution

**What:** Configuration file for `xcodebuild -exportArchive`
**When to use:** Required for non-App Store distribution
**Example:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
```

### Pattern 3: Certificate Import in GitHub Actions

**What:** Import Developer ID certificate from GitHub Secrets into a temporary keychain
**When to use:** CI release builds
**Example:**
```yaml
# Source: https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
- name: Install Apple certificate
  env:
    BUILD_CERTIFICATE_BASE64: ${{ secrets.BUILD_CERTIFICATE_BASE64 }}
    P12_PASSWORD: ${{ secrets.P12_PASSWORD }}
    KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
  run: |
    CERTIFICATE_PATH=$RUNNER_TEMP/build_certificate.p12
    KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db

    echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o $CERTIFICATE_PATH

    security create-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
    security set-keychain-settings -lut 21600 $KEYCHAIN_PATH
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH

    security import $CERTIFICATE_PATH -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k $KEYCHAIN_PATH
    security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
    security list-keychain -d user -s $KEYCHAIN_PATH
```

### Pattern 4: Sparkle Integration via SPM

**What:** Add Sparkle auto-update framework to the host app
**When to use:** PKG-05 requirement
**Example (in project.yml):**
```yaml
# Add to CloudMount target's packages
targets:
  CloudMount:
    # ... existing config ...
    dependencies:
      - target: CloudMountKit
      - target: CloudMountExtension
      - package: Sparkle
    packages:
      Sparkle:
        url: https://github.com/sparkle-project/Sparkle
        from: "2.0.0"
```

**SwiftUI Integration:**
```swift
// Source: https://sparkle-project.org/documentation/programmatic-setup/
import Sparkle

@main
struct CloudMountApp: App {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        // ... existing scenes ...
        Settings {
            // settings content
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}
```

**Info.plist additions:**
```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/OWNER/cloudmount/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>YOUR_EDDSA_PUBLIC_KEY</string>
```

### Pattern 5: Homebrew Cask in Own Tap

**What:** Cask formula in `homebrew-cloudmount` repository
**When to use:** BREW-01, BREW-02, BREW-03
**Example (`Casks/cloudmount.rb`):**
```ruby
cask "cloudmount" do
  version "1.0.0"
  sha256 "COMPUTED_SHA256_OF_DMG"

  url "https://github.com/OWNER/cloudmount/releases/download/v#{version}/CloudMount-#{version}.dmg"
  name "CloudMount"
  desc "Mount cloud storage as native macOS volumes via FSKit"
  homepage "https://github.com/OWNER/cloudmount"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "CloudMount.app"

  zap trash: [
    "~/Library/Application Support/com.cloudmount.app",
    "~/Library/Caches/com.cloudmount.app",
    "~/Library/HTTPStorages/com.cloudmount.app",
    "~/Library/Preferences/com.cloudmount.app.plist",
    "~/Library/Saved Application State/com.cloudmount.app.savedState",
  ]

  caveats <<~EOS
    CloudMount requires macOS 26 (Tahoe) or later.

    After installation, enable the FSKit extension:
      System Settings → General → Login Items & Extensions → CloudMount

    Mount a volume:  mount -t b2 b2://bucket-name /mount/point
    Unmount:          umount /mount/point

    For help: https://github.com/OWNER/cloudmount
  EOS
end
```

### Pattern 6: GitHub Actions Release Workflow with Manual Approval

**What:** Tag-triggered release pipeline with environment protection
**When to use:** CI-02 requirement
**Example:**
```yaml
name: Release
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'

jobs:
  build-and-sign:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v5
      - name: Install tools
        run: brew install create-dmg xcodegen
      - name: Import certificate
        # ... certificate import steps ...
      - name: Build, sign, notarize
        # ... build pipeline ...
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: release-assets
          path: |
            CloudMount-*.dmg
            CloudMount-*.dmg.sha256

  publish:
    needs: build-and-sign
    runs-on: ubuntu-latest
    environment: production  # <-- manual approval gate
    steps:
      - name: Download artifacts
        uses: actions/download-artifact@v4
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            release-assets/CloudMount-*.dmg
            release-assets/CloudMount-*.dmg.sha256
          generate_release_notes: false
          body_path: RELEASE_NOTES.md
          draft: false
          prerelease: false

  bump-cask:
    needs: publish
    runs-on: ubuntu-latest
    steps:
      - name: Bump Homebrew Cask
        # ... update version + sha256 in tap repo ...
```

### Anti-Patterns to Avoid

- **Notarizing only the .app, not the DMG:** Notarize the DMG itself — this ensures the complete download passes Gatekeeper. Staple the ticket to the DMG.
- **Using altool for notarization:** `altool` is deprecated. Use `xcrun notarytool` exclusively.
- **Hardcoding signing identity in project.yml:** Use `CODE_SIGN_STYLE: Automatic` for development, switch to Manual via `xcodebuild` CLI flags in CI.
- **Skipping partition-list in keychain setup:** Without `security set-key-partition-list -S apple-tool:,apple:`, codesign cannot access the imported certificate in CI.
- **Committing signing keys or certificates:** All signing material must be in GitHub Secrets (base64-encoded).
- **Using `version :latest` in Cask:** Always use explicit version + sha256 for reproducibility and security.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| DMG creation with layout | Custom hdiutil scripts with AppleScript | `create-dmg` | Handles volume creation, icon positioning, background, Applications symlink, and hdiutil quirks |
| Appcast/update feed generation | Custom XML generation | Sparkle's `generate_appcast` | Handles EdDSA signing, delta updates, version detection |
| Code signing in CI | Manual openssl + security chains | GitHub's documented keychain pattern | Battle-tested, handles edge cases like partition lists |
| Notarization polling | Custom polling loop with notarytool | `notarytool submit --wait` | Built-in polling with proper timeout handling |
| Release note generation | Custom changelog parser | `softprops/action-gh-release` with structured body | Handles GitHub Release creation, asset upload atomically |
| Cask version bumping | Custom Ruby script to edit cask files | `sed` or templated cask + gh CLI push to tap | Simple string replacement is sufficient |

**Key insight:** The macOS distribution pipeline has many moving parts (signing, notarization, DMG, appcast, Cask), but each step has a well-established tool. The complexity is in orchestrating them correctly, not in any individual step.

## Common Pitfalls

### Pitfall 1: Keychain Partition List Not Set
**What goes wrong:** `codesign` fails with "resource fork, Finder information, or similar detritus not allowed" or silent failures in CI
**Why it happens:** The imported certificate is in the keychain but the `codesign` tool doesn't have ACL permission to access it
**How to avoid:** Always run `security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH` after importing the certificate
**Warning signs:** Build succeeds but code signing step fails with cryptic error

### Pitfall 2: Notarizing .app Instead of .dmg
**What goes wrong:** The .app is notarized but the DMG doesn't have a stapled ticket; users downloading the DMG may still see Gatekeeper warnings
**Why it happens:** Developers notarize the .app first, then create the DMG, but don't notarize the DMG
**How to avoid:** Create the DMG first, then notarize and staple the DMG. Alternatively, notarize the .app, staple it, then create the DMG (both approaches work, but notarizing the DMG is cleaner)
**Warning signs:** `spctl --assess --type open --context context:primary-signature CloudMount.dmg` fails

### Pitfall 3: App Extension Not Signed with Same Team
**What goes wrong:** The embedded extension's signature doesn't chain to the same certificate as the host app, causing Gatekeeper rejection
**Why it happens:** Extensions must be signed with the same Developer ID certificate as their host app
**How to avoid:** Ensure `DEVELOPMENT_TEAM` is set consistently across all targets in `xcodebuild archive`. The archive+export flow handles this automatically when ExportOptions.plist specifies `developer-id` method.
**Warning signs:** `codesign --verify --deep --strict CloudMount.app` fails

### Pitfall 4: Hardened Runtime Blocking Extension Entitlements
**What goes wrong:** FSKit extension entitlements are stripped or rejected during export
**Why it happens:** Hardened runtime is required for notarization, and some entitlements need explicit approval
**How to avoid:** The `com.apple.developer.fskit.fsmodule` entitlement should be preserved through the archive/export flow. Verify with `codesign -d --entitlements :- CloudMount.app/Contents/PlugIns/CloudMountExtension.appex`
**Warning signs:** Extension loads but FSKit rejects it at runtime

### Pitfall 5: Sparkle EdDSA Key Not in CI Environment
**What goes wrong:** `generate_appcast` can't sign the appcast because the private key isn't available in CI
**Why it happens:** EdDSA private key is stored in macOS Keychain, which isn't available in CI
**How to avoid:** Export the EdDSA private key with `generate_keys -x private-key-file`, store as GitHub Secret, import at CI time via `generate_keys -f private-key-file`
**Warning signs:** Appcast generated without signatures; Sparkle clients reject updates

### Pitfall 6: CFBundleVersion Not Incrementing
**What goes wrong:** Sparkle doesn't detect new versions or presents downgrades
**Why it happens:** `CFBundleVersion` stays at "1" across releases because it wasn't updated
**How to avoid:** Automate version bumping — set `CFBundleVersion` as a build number (integer, auto-incrementing) and `CFBundleShortVersionString` as the human-readable SemVer. Update both in Info.plist or via build settings before archiving.
**Warning signs:** Sparkle shows "You're up to date" even after new release

### Pitfall 7: macOS Codename for depends_on
**What goes wrong:** Cask rejected or install blocked because the macOS version symbol doesn't exist in Homebrew
**Why it happens:** macOS 26 (Tahoe) is very new; the symbol `:tahoe` may not be in all Homebrew versions yet
**How to avoid:** Check the Homebrew `MacOSVersion` class documentation for the correct symbol. If `:tahoe` isn't available yet, use `depends_on macos: ">= :sequoia"` as a conservative minimum, then update when Homebrew supports `:tahoe`
**Warning signs:** `brew audit` fails on the cask

### Pitfall 8: Cleanup Step Not Running in CI
**What goes wrong:** Keychain with certificates persists on self-hosted runners (security risk). On GitHub-hosted runners this is less critical since VMs are ephemeral.
**Why it happens:** Cleanup step doesn't use `if: ${{ always() }}`
**How to avoid:** Always use `if: ${{ always() }}` on cleanup steps:
```yaml
- name: Clean up keychain
  if: ${{ always() }}
  run: security delete-keychain $RUNNER_TEMP/app-signing.keychain-db
```

## Code Examples

### Notarization with notarytool (App Store Connect API Key — preferred for CI)
```bash
# Source: Apple Developer Documentation
# Using API Key is preferred over Apple ID in CI — no 2FA issues

# Store API key as GitHub Secret (base64-encoded .p8 file)
echo -n "$APP_STORE_CONNECT_KEY_BASE64" | base64 --decode -o "$RUNNER_TEMP/AuthKey.p8"

xcrun notarytool submit "CloudMount-${VERSION}.dmg" \
  --key "$RUNNER_TEMP/AuthKey.p8" \
  --key-id "$API_KEY_ID" \
  --issuer "$API_ISSUER_ID" \
  --wait \
  --timeout 30m

xcrun stapler staple "CloudMount-${VERSION}.dmg"
```

### Verification Commands
```bash
# Verify code signature (deep verifies embedded extensions + frameworks)
codesign --verify --deep --strict --verbose=2 CloudMount.app

# Verify entitlements preserved
codesign -d --entitlements :- CloudMount.app
codesign -d --entitlements :- CloudMount.app/Contents/PlugIns/CloudMountExtension.appex

# Gatekeeper assessment
spctl --assess --type execute CloudMount.app
spctl --assess --type open --context context:primary-signature CloudMount.dmg

# Verify notarization status
xcrun stapler validate CloudMount.dmg
```

### Sparkle generate_appcast for GitHub Releases
```bash
# Source: https://sparkle-project.org/documentation/publishing/
# The appcast can be generated from a folder of release DMGs

# Download Sparkle tools (in CI)
SPARKLE_VERSION="2.7.5"  # Use latest stable
curl -L "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
  | tar xJ -C "$RUNNER_TEMP/sparkle"

# Import EdDSA signing key
echo -n "$SPARKLE_EDDSA_KEY_BASE64" | base64 --decode > "$RUNNER_TEMP/sparkle_key"
"$RUNNER_TEMP/sparkle/bin/generate_keys" -f "$RUNNER_TEMP/sparkle_key"

# Generate appcast from release archives folder
"$RUNNER_TEMP/sparkle/bin/generate_appcast" \
  --download-url-prefix "https://github.com/OWNER/cloudmount/releases/download/v${VERSION}/" \
  ./release-archives/
```

### Homebrew Tap Repository Structure
```
homebrew-cloudmount/
├── Casks/
│   └── cloudmount.rb
└── README.md
```

Users install with: `brew install OWNER/cloudmount/cloudmount` or `brew tap OWNER/cloudmount && brew install --cask cloudmount`

### CI Workflow: PR Checks
```yaml
# Source: GitHub Actions docs
name: CI
on:
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v5
      - name: Install xcodegen
        run: brew install xcodegen
      - name: Generate Xcode project
        run: xcodegen generate
      - name: Build
        run: |
          xcodebuild build \
            -project CloudMount.xcodeproj \
            -scheme CloudMount \
            -configuration Debug \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_ALLOWED=NO
      - name: Test
        run: |
          xcodebuild test \
            -project CloudMount.xcodeproj \
            -scheme CloudMount \
            -configuration Debug \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_ALLOWED=NO
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `altool` for notarization | `xcrun notarytool` | Xcode 14 (2022) | altool deprecated; notarytool is faster, supports `--wait` |
| DSA signatures in Sparkle | EdDSA (Ed25519) signatures | Sparkle 2.0 | DSA deprecated; EdDSA is required for new projects |
| `SUUpdater` (Sparkle 1.x) | `SPUStandardUpdaterController` (Sparkle 2.x) | Sparkle 2.0 | New API with better Swift support |
| Manual Xcode project | xcodegen (project.yml) | Already adopted | Reproducible project generation in CI |
| `macos-13` runner (Intel) | `macos-26` runner (ARM64, public preview) | 2025/2026 | macOS 26 SDK available on GitHub Actions |
| kext-based filesystems | FSKit extensions | macOS 26 (Tahoe) | No kext stanza needed in Cask — FSKit extensions are app-embedded |

**Deprecated/outdated:**
- `altool`: Deprecated by Apple. Do not use. Use `notarytool` exclusively.
- `SUUpdater`: Deprecated Sparkle 1.x class. Use `SPUStandardUpdaterController` for new projects.
- DSA signatures: Deprecated in Sparkle 2.x. Use EdDSA (Ed25519) exclusively.
- `kext` stanza in Cask: Not applicable — CloudMount uses FSKit, not kernel extensions.

## Open Questions

### 1. macOS 26 (Tahoe) Homebrew Symbol
- **What we know:** Homebrew uses symbols like `:sequoia`, `:sonoma` for `depends_on macos:`. macOS 26 is Tahoe.
- **What's unclear:** Whether `:tahoe` is already in Homebrew's `MacOSVersion` class as of Feb 2026. It should be, given Tahoe was announced at WWDC 2025.
- **Recommendation:** Use `depends_on macos: ">= :tahoe"`. If `brew audit` rejects it, fall back to a string comparison with the macOS version number. **Confidence: MEDIUM** — likely available but needs validation at implementation time.

### 2. App Store Connect API Key vs Apple ID for Notarization in CI
- **What we know:** Both approaches work. API Key (`--key`) avoids 2FA complications. Apple ID (`--apple-id` + `--password`) requires app-specific password.
- **What's unclear:** Whether the team has an API Key set up already.
- **Recommendation:** Use App Store Connect API Key for CI. It's more reliable and avoids 2FA issues. Store the `.p8` key file as a base64-encoded GitHub Secret.

### 3. Sparkle Appcast Hosting
- **What we know:** Sparkle reads `SUFeedURL` from Info.plist. The appcast.xml can be hosted anywhere (GitHub Pages, raw GitHub, custom server).
- **What's unclear:** Best hosting approach for a GitHub-based open-source project.
- **Recommendation:** Host `appcast.xml` in the main repo (committed to `main` branch) and reference it via raw.githubusercontent.com URL. Alternatively, use GitHub Pages. The release workflow updates this file after each release.

### 4. Sparkle XPC Services in Non-Sandboxed App
- **What we know:** The host app (`CloudMount.app`) does not have `com.apple.security.app-sandbox` in its entitlements (only the extension is sandboxed). Sparkle recommends removing XPC services for non-sandboxed apps to save space.
- **What's unclear:** Whether the app should be sandboxed or not for distribution. Non-sandboxed is simpler for Developer ID distribution.
- **Recommendation:** If the host app remains non-sandboxed, Sparkle's XPC services can be removed per their documentation. Keep the default for now and address if needed.

### 5. `macos-26` Runner Stability
- **What we know:** The `macos-26` runner is listed as "public preview" on GitHub Actions as of Feb 2026.
- **What's unclear:** Whether it's stable enough for production release pipelines, and what Xcode version it ships with.
- **Recommendation:** Use `macos-26` for releases. If instability is encountered, fall back to `macos-15` with Xcode 26 installed via `xcodes` or `xcode-install` action. Have a fallback plan documented.

## Sources

### Primary (HIGH confidence)
- GitHub Actions Docs — [Sign Xcode applications](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) — Certificate import, keychain setup
- GitHub Actions Docs — [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) — `macos-26` runner confirmed in public preview
- Sparkle Project — [Documentation](https://sparkle-project.org/documentation/) — SPM setup, EdDSA keys, programmatic setup
- Sparkle Project — [Publishing an update](https://sparkle-project.org/documentation/publishing/) — Appcast format, generate_appcast usage
- Homebrew Docs — [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) — Complete Cask DSL reference
- Homebrew Docs — [brew livecheck](https://docs.brew.sh/Brew-Livecheck) — Livecheck strategies including `:github_latest`
- create-dmg — [GitHub](https://github.com/create-dmg/create-dmg) — DMG creation tool, v1.2.3

### Secondary (MEDIUM confidence)
- Apple Developer Documentation — Notarization workflow (page requires JS, verified via training data cross-referenced with notarytool --help)
- Project files — `project.yml`, entitlements, Info.plist examined directly

### Tertiary (LOW confidence)
- macOS 26 "Tahoe" Homebrew symbol availability — needs validation at implementation time

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all tools are well-documented, official Apple tools + established open-source tools
- Architecture: HIGH — archive/export/notarize/DMG flow is canonical Apple workflow
- CI/CD patterns: HIGH — GitHub Actions docs provide exact code for certificate import; `macos-26` runner confirmed
- Sparkle integration: HIGH — official documentation is comprehensive, SPM path is well-documented
- Homebrew Cask: HIGH — Cask Cookbook provides complete DSL reference
- Pitfalls: HIGH — sourced from official docs warnings and known community issues
- macOS 26 runner stability: MEDIUM — listed as "public preview", may have rough edges
- Homebrew `:tahoe` symbol: MEDIUM — logically should exist but not explicitly confirmed

**Research date:** 2026-02-06
**Valid until:** 2026-03-06 (30 days — tooling is stable; runner availability may change)
