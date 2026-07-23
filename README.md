# COS Control for macOS

COS Control is the native menu bar controller for the local COS Glasses server.
It starts, stops, updates, diagnoses, and safely rolls back the public
`@gotcos/glasses-server` runtime without replacing the existing CLI workflow.

## Requirements

- macOS 14 or newer
- Apple Silicon
- Node.js 20.11 or newer
- Claude Code or Codex CLI

## Build

```bash
./scripts/build-release.sh
```

The app is ad-hoc signed for the open-source MVP. On first launch, right-click
the app, choose Open, then confirm Open. The controller stores immutable npm
server generations under `~/Library/Application Support/COS Control` and uses
one LaunchAgent, `com.cos.glasses-server`, as the sole server owner.

Existing data remains under the standard COS Glasses locations. The existing
`npx @gotcos/glasses-server` foreground workflow remains supported.
