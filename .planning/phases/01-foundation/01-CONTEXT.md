# Phase 1: Foundation - Context

**Gathered:** 2026-02-02
**Status:** Ready for planning

<domain>
## Phase Boundary

Users can launch the app, verify macFUSE is installed, and have credentials securely stored. This phase delivers the app shell: status bar icon with menu, macFUSE detection with installation guidance, secure credential storage in macOS Keychain, and a settings window. Actual mounting and file operations are in later phases.

</domain>

<decisions>
## Implementation Decisions

### Status bar icon & menu behavior
- **Icon style:** Bucket combined with cloud (unique to this app)
- **Icon states:** Different icons for different states (no buckets vs mounted)
- **Menu trigger:** Dropdown menu on click (standard macOS pattern)
- **Menu height:** Fixed max height with scroll for many buckets
- **Empty state:** "Add your first bucket" with quick setup guidance
- **Menu items:** Settings, Add bucket, About, Quit (always present)
- **Keyboard shortcut:** No global shortcut needed
- **First launch:** Just show icon quietly (no auto-open menu)

### macFUSE detection & guidance
- **Detection timing:** Check at app launch
- **If missing:** Modal dialog with instructions (blocking until resolved)
- **Installation guidance:** Link to macFUSE website (not step-by-step in app)
- **Re-checking:** Auto-check periodically to detect when installed

### Settings window design
- **Window type:** Single form view (not sidebar-based)
- **Window size:** Small (400x300)
- **Tab navigation:** Top tabs for sections
- **Sections:** Buckets, Credentials, General
- **Modal behavior:** OpenCode's discretion
- **Opening settings:** Only from status bar menu (not Cmd+, shortcut)
- **Save behavior:** Auto-save on change
- **Validation:** Inline with fields (not popup alerts)

### Credential storage UX
- **Entry flow:** In the full settings window (not status bar menu popup)
- **Credential fields:** Application Key ID and Application Key
- **Bucket handling:** After credentials entered, bucket name auto-populates from B2 API
- **Bucket name:** Defaults to actual bucket name, but users can change display name
- **Multiple credentials:** Support multiple B2 accounts
- **Credential editing:** Can edit existing credentials
- **Confirmation:** Subtle checkmark when saved
- **Security visibility:** Masked by default (password dots with reveal toggle)

### OpenCode's Discretion
- Icon design details (bucket + cloud visual treatment)
- Exact icon state variations
- Modal vs modeless settings window choice
- Auto-check interval for macFUSE detection
- B2 API integration details for bucket fetching (requires research)
- Form field styling and layout
- Error message copy
- Animation/transition details

</decisions>

<specifics>
## Specific Ideas

- "I want the icon to be a bucket combined with a cloud" — unique app identity
- Menu should feel like native macOS status bar apps
- Settings window should be compact and focused
- Auto-populate bucket names from B2 API after credentials entered

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-foundation*
*Context gathered: 2026-02-02*
