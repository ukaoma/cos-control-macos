# PermissionFlow (vendored)

- Upstream: https://github.com/jaywcjlove/PermissionFlow
- Author: jaywcjlove (小弟调调)
- License: MIT (LICENSE in this folder, copied unchanged)
- Pinned commit: cb96db4b (2026-09-26)

## What COS Control uses

`Sources/PermissionFlowVendored.swift` holds adapted copies of three upstream files:

| Upstream file | In COS Control | Changes |
|---|---|---|
| `Sources/PermissionFlow/Tracking/SettingsWindowTracker.swift` | `SettingsWindowTracker` | Swift 6 strict concurrency (AX callback re-enters with `MainActor.assumeIsolated`), polls at 15 Hz instead of 30, never prompts for Accessibility itself |
| `Sources/PermissionFlow/UI/FloatingDropPanel.swift` | `COSFloatingHelperPanel` | Hosts any SwiftUI view instead of `PermissionFlowController`; no fly-in launch animation; width capped |
| `Sources/PermissionFlow/UI/AppDropArea.swift` | `COSAppDragSourceView`, `COSFilePasteboardWriter` | Card look supplied by COS (`PermissionGuideViews.swift`); pasteboard payload unchanged |

Everything else upstream (the controller, panel view, status providers, localizations, SystemSettingsKit, the
example app) is not included. The vendored code makes no network calls and collects no analytics.

To update: fetch the same three files at a new commit with
`gh api repos/jaywcjlove/PermissionFlow/contents/<path>?ref=<commit>`, re-apply the changes above, and update the
pinned commit here, in the header of `Sources/PermissionFlowVendored.swift` and in `THIRD_PARTY_NOTICES.md`.
