# FSKit Extension Toggle Bug -- Investigation Summary

**Date**: 2026-02-06
**Status**: UNRESOLVED -- the FSKit extension cannot be enabled via System Settings toggle

## The Problem

CloudMount's FSKit extension appears in System Settings > General > Login Items & Extensions under "FSKit Modules", but clicking the toggle to enable it does nothing. No authentication prompt, no error, no log output. The toggle simply doesn't respond.

## What We Fixed (These Were Real Bugs, Now Resolved)

### 1. Wrong XcodeGen product type (FIXED in project.yml)
- **Was**: `type: app-extension` → produces `com.apple.product-type.app-extension`
- **Now**: `type: extensionkit-extension` → produces `com.apple.product-type.extensionkit-extension`
- **Impact**: The old type triggered Xcode's legacy `NSExtension` plist processing which **stripped all FSKit keys** (`FSSupportedSchemes`, `FSShortName`, `FSPersonalities`, `EXExtensionPointIdentifier`, `EXExtensionPrincipalClass`) and replaced `EXAppExtensionAttributes` with `NSExtension`. macOS had no idea this was an FSKit extension.

### 2. GENERATE_INFOPLIST_FILE was false (FIXED in project.yml)
- **Was**: `GENERATE_INFOPLIST_FILE: false`
- **Now**: `GENERATE_INFOPLIST_FILE: true`
- **Impact**: Apple's own FSKit sample (PassthroughFS) uses `true`. With `true`, Xcode merges the manual Info.plist keys on top of auto-generated ones, preserving `EXAppExtensionAttributes` intact.

### 3. Wrong certificate in CI (FIXED in release.yml + secrets)
- `BUILD_CERTIFICATE_BASE64` contained an Apple Development cert, not Developer ID Application
- Now two certs imported: `DEV_CERTIFICATE_BASE64` (Apple Development for archive) and `BUILD_CERTIFICATE_BASE64` (Developer ID Application for export)

### 4. Hardened runtime missing (FIXED in project.yml)
- Added `ENABLE_HARDENED_RUNTIME: true` to global settings -- required for notarization

### 5. Extension path in CI verify step (FIXED in release.yml)
- Was checking `Contents/PlugIns/` but ExtensionKit extensions live at `Contents/Extensions/`

## Current State After Fixes

### The built plist is now CORRECT
Verified by inspecting the built artifact:
```
build/DerivedData/Build/Products/Debug/CloudMount.app/Contents/Extensions/CloudMountExtension.appex/Contents/Info.plist
```
Contains:
- `EXAppExtensionAttributes` (NOT `NSExtension`) ✓
- `EXExtensionPointIdentifier` = `com.apple.fskit.fsmodule` ✓
- `EXExtensionPrincipalClass` = `CloudMountExtension.CloudMountExtensionMain` ✓
- `FSSupportedSchemes` = `["b2"]` ✓
- `FSShortName` = `b2` ✓
- `FSSupportsGenericURLResources` = `true` ✓
- `FSPersonalities` with B2 entry ✓

### The extension IS registered with the system
```bash
$ pluginkit -mAvvv -p com.apple.fskit.fsmodule
+    com.cloudmount.app.extension(1)
            Path = /Applications/CloudMount.app/Contents/Extensions/CloudMountExtension.appex
            UUID = ...
            SDK = com.apple.fskit.fsmodule
            Display Name = CloudMount Extension
```
The `+` prefix means "third-party" (macFUSE also shows `+`), NOT "disabled."

### The system partially recognizes the filesystem
```bash
$ /sbin/mount -t b2
# Exit 0 -- recognizes b2 as a valid type

$ /sbin/mount -t b2 b2://test /tmp/test
# "Filesystem b2 does not support operation mount" (exit 69)
# Then falls back to looking for /Library/Filesystems/b2.fs/Contents/Resources/mount_b2

$ /sbin/mount -F -t b2 b2://test /tmp/test
# "invalid file system" (exit 66) -- the -F flag takes a different code path
```

### The app is signed and notarized (v2.0.1)
```
Authority=Developer ID Application: EIRIK BREEN (66X2XJM3HW)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
```
v2.0.1 was notarized and stapled via CI. Gatekeeper should be satisfied.

### But the toggle still doesn't work
- Shows in System Settings under "FSKit Modules"
- Sometimes shows as duplicate entries (stale registrations from old builds)
- Clicking the toggle does NOTHING -- no auth prompt, no error, no log output
- `log stream` shows zero output when clicking the toggle
- `pluginkit -e use -i com.cloudmount.app.extension` returns exit 0 but doesn't actually enable it

## What We Tried (Exhaustive List)

1. **Changed product type** from `app-extension` to `extensionkit-extension` ✓
2. **Changed GENERATE_INFOPLIST_FILE** from `false` to `true` ✓
3. **Verified built plist** contains all FSKit keys ✓
4. **Built with proper signing** (Developer ID Application) ✓
5. **Installed to /Applications** (not running from build dir) ✓
6. **Removed all duplicate copies** from DerivedData, build dirs, Homebrew ✓
7. **Removed quarantine xattrs** (`xattr -cr`) ✓
8. **Rebooted the Mac** ✓
9. **Tried pluginkit -e use** to enable programmatically -- no effect ✓
10. **Notarized via CI** (v2.0.1 release) and installed ✓
11. **Checked system logs** during toggle click -- completely silent ✓
12. **Compared with macFUSE** (working third-party FSKit extension) -- our plist structure matches ✓

## Key Comparison: CloudMount vs macFUSE (Working)

### macFUSE extension plist has additional keys we don't:
- `FSActivateOptionSyntax` with `shortOptions`
- `FSCheckOptionSyntax` with `shortOptions`
- `FSFormatOptionSyntax` with `shortOptions`
- `FSMediaTypes` (empty dict)
- `FSRequiresSecurityScopedPathURLResources` (false for macFUSE, absent for us)
- `FSSupportedSchemes` (macFUSE has this too)

### macFUSE parent app lives in:
```
/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/
```
Not in `/Applications/`. The parent app is inside a `.fs` bundle in `/Library/Filesystems/`.

### macFUSE has a .fs bundle:
```
/Library/Filesystems/macfuse.fs/
  Contents/
    Info.plist (CFBundlePackageType: "fs  ")
    Resources/
      mount_macfuse (setuid binary!)
      macfuse.app/
        Contents/Extensions/
          io.macfuse.app.fsmodule.macfuse.appex
```
CloudMount does NOT have a `.fs` bundle. This may or may not matter.

### Apple's system FSKit extensions (exfat, msdos, ftp) also have .fs bundles:
```
/System/Library/Filesystems/exfat.fs/
/System/Library/Filesystems/msdos.fs/
/System/Library/Filesystems/ftp.fs/
```
Each contains a `mount_<type>` helper binary.

### But Apple's sample (PassthroughFS) does NOT have a .fs bundle
Apple's docs say `mount -t passthrough ~/Documents ~/passthrough-fs` should work after enabling the extension in System Settings. No `.fs` bundle is mentioned.

## Remaining Hypotheses (Untested)

### H1: Missing FSKit plist keys
macFUSE includes `FSActivateOptionSyntax`, `FSCheckOptionSyntax`, `FSFormatOptionSyntax`, `FSMediaTypes`, and `FSRequiresSecurityScopedPathURLResources`. We might need some or all of these for the system to consider the extension valid enough to enable.

### H2: The System Settings UI is buggy for FSKit extensions
The toggle might require a specific interaction (e.g., clicking the (i) button first, or using a specific macOS version). The fact that `log stream` shows zero output suggests the UI might not be connecting to the extension management service.

### H3: Need to download and study Apple's PassthroughFS sample more closely
We downloaded it to `/tmp/PassthroughFS/` during this session. The sample project was built with native Xcode (not XcodeGen). We should:
- Build the PassthroughFS sample
- See if ITS toggle works in System Settings
- If yes, diff every config detail between it and CloudMount

### H4: The extension might need a .fs bundle as a bridge
Even though Apple's docs don't mention it for the passthrough sample, the `mount` command on macOS 26 still looks for `/Library/Filesystems/<type>.fs/`. All working FSKit filesystems (including macFUSE) have one. We might need to create `/Library/Filesystems/b2.fs/` with at minimum an Info.plist and potentially a `mount_b2` helper.

### H5: Stale extension database
Despite rebooting, the system's extension database might have corrupted entries from all the builds we did. The database location is unknown (not in obvious places like TCC.db or defaults). A clean macOS user account test would rule this out.

### H6: Provisioning profile / entitlement mismatch
The Developer ID provisioning profiles might not include the `com.apple.developer.fskit.fsmodule` entitlement. The entitlement IS in the built binary (verified via `codesign -d --entitlements`), but the provisioning profile might need to explicitly list it for the system to trust it.

## Recommended Next Steps (Priority Order)

1. **Build and test Apple's PassthroughFS sample** -- this is the control test. If passthrough's toggle works, we know the system is functional and the bug is in our config. If it doesn't work either, it's a macOS/Xcode bug.

2. **Add missing FSKit plist keys** from macFUSE (`FSActivateOptionSyntax`, `FSMediaTypes`, `FSRequiresSecurityScopedPathURLResources`, etc.) -- cheap to try.

3. **Create a new macOS user account** and test there -- rules out corrupted extension database.

4. **Check provisioning profile contents** -- decode the .provisionprofile and verify `com.apple.developer.fskit.fsmodule` is in the entitlements list.

5. **Try creating a `/Library/Filesystems/b2.fs/` bundle** with a minimal Info.plist as a bridge.

## File Locations

- **project.yml**: XcodeGen config (already fixed)
- **CloudMountExtension/Info.plist**: Extension plist with FSKit keys
- **CloudMountExtension/CloudMountExtension.entitlements**: Extension entitlements
- **.github/workflows/release.yml**: CI/CD pipeline (already fixed)
- **Apple's PassthroughFS sample**: Downloaded to `/tmp/PassthroughFS/` (may not survive reboot)
  - Download URL: `https://docs-assets.developer.apple.com/published/0b4283600908/BuildingAPassthroughFileSystem.zip`
- **AGENTS.md**: Comprehensive project context for AI agents

## Environment

- macOS 26.2 (Tahoe), Xcode 26.2
- Apple Team ID: 66X2XJM3HW
- Mac has macFUSE installed (also shows as FSKit Modules, also shows `+` in pluginkit)
- Mac has Cisco AnyConnect, Microsoft Defender, Tailscale (network extensions)
