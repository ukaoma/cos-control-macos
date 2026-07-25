# COS Control for macOS

COS Control is the native menu bar controller for the local COS Glasses server.
It starts, stops, updates, diagnoses, and safely rolls back the public
`@gotcos/glasses-server` runtime without replacing the existing CLI workflow.

## Requirements

- macOS 14 or newer
- Apple Silicon
- Node.js 20.11 or newer
- Claude Code, Codex CLI, or Cursor Agent (`agent`)

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

## Lifecycle safety

COS Control stages and verifies an immutable npm generation before touching the
running service. Updates, restarts, stops, repairs, and rollbacks use the
authenticated rev4 maintenance gate. The controller persists a private local
operation credential, authorizes only exact successor and rollback generation
IDs, and never expiry-opens a committed cross-boot gate. A successor must adopt
the gate before the controller verifies launchd listener ownership, version,
generation, boot identity, and health; only then does it release admissions.

Stop intentionally leaves that gate committed. The next authorized Start adopts
and releases it. Recognized legacy LaunchAgents can be adopted only while
stopped; running legacy and unknown owners are refused because they cannot offer
an exact transactional rollback. Pairing tokens are copied by the helper without
crossing helper output or app state and are cleared after 60 seconds only when
the pasteboard still contains the matching token.

An unknown foreground process, mismatched listener PID, incompatible maintenance
contract, or interrupted transaction is shown as a conflict instead of being
silently replaced. Doctor and Copy Report redact pairing credentials, process
IDs, and the selected workspace path.

## 0.2.1 reliability fixes

- Managed LaunchAgents retain discovered Claude, Codex, and Cursor CLI bin
  directories, including `~/.local/bin`, across install, update, rollback, and
  repair.
- Managed updates, restarts, and in-place adoption are not accepted as healthy
  from HTTP 200 alone. COS Control verifies the provider capability payload and
  marks the runtime degraded when an installed provider is unavailable inside
  the service environment.
- The bundled server target is 6.15.1, which provisions Kokoro with a compatible
  Python 3.11 or 3.12 runtime.
