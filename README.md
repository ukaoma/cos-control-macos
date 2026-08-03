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
COS_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
COS_NOTARY_PROFILE="cos-control-notary" \
./scripts/build-release.sh
```

Signed builds fail closed unless Developer ID signing and notarization are both
configured, and the script then verifies the extracted ZIP with codesign,
stapler, and Gatekeeper. Those post-checks run on the signed path only.

**Current release state:** Developer ID enrollment is not in place yet, so
published releases (0.2.3 onward) are built with `COS_ALLOW_ADHOC=1` and ship
ad-hoc signed and unnotarized. Gatekeeper rejects them on first open, which is
why the download page walks users through `xattr -dr com.apple.quarantine` and
"Open Anyway". Drop the ad-hoc path and delete this note once Developer ID is
available.

The controller stores immutable npm
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

## 0.3.5 transcription tiers and Cursor diagnostics

- The status card identifies the effective transcription tier and all three
  lanes: preview while dictating, authoritative live-meeting commit, and polish
  on save.
- Balanced is recommended. Max is an explicit opt-in for powerful Macs and
  reuses the existing Large-v3 process; it does not add a third Whisper worker.
- Apply is a transactional server restart. A failed activation restores the
  prior LaunchAgent environment and verifies the old server before returning.
- Guided Setup provisions Balanced or Max explicitly. Install or Update Server
  follows when needed; Apply then activates the choice, keeping the model
  download separate from the lifecycle transaction.
- Agent CLI diagnostics use the local Cursor `agent about` version when server
  health cannot parse a real Cursor build number.
- QA target: `@gotcos/glasses-server` 6.21.0.

## 0.3.4 update-proof and mixed-version hardening

- Provider and Kokoro transactional checks retain their individual bounded
  timeouts instead of sharing the candidate server's 60-second startup budget.
- Live transcription rows render only when the server reports that lane; a
  6.19.x server with HQ support no longer displays misleading “Unreported”
  preview and commit rows.
- QA target: `@gotcos/glasses-server` 6.20.1.

## 0.3.3 adaptive transcription setup

- Guided Setup provisions three separate local transcription lanes: Small.en
  for provisional lens text, Large-v3-Turbo for committed live text, and
  Large-v3 for HQ polish. A preview failure falls back to Turbo without
  changing the committed transcript or recovery ledger.
- The status card reports all three effective models from live server health.
  Older servers omit the rows instead of being mislabeled.
- Empty transcription vocabulary is visible so users are prompted to add their
  actual names and specialist terminology instead of living with factory bias.
- QA target: `@gotcos/glasses-server` 6.20.0.

## 0.2.8 live server version in the footer

- The footer reads the **live** managed server version from status
  (`status.version`, falling back to `installedVersion`), not a compile-time
  "verified 6.16.x" constant that drifted behind Update Server.
- Controller version in the footer comes from `Info.plist` via `currentVersion`.
- `releaseServerVersion` is now release-notes metadata only. Install, Adopt, and
  Update Server have always resolved npm `@latest` and still do.
- QA'd against `@gotcos/glasses-server` 6.16.9. Note that 6.15.4 and
  6.16.6–6.16.8 exist in git but were never published to npm; their changes are
  folded into 6.16.9, so 6.16.9 is the version to name in any instruction.

## 0.2.7 folder pickers

- Separate **Work Folder** (agent workspace) from **Meetings Library** (the COS
  `operations/` tree used for G2 Review Meetings), each on its own tool row.

## 0.2.6 meetings library

- **Meetings Folder** sets `COS_OPERATIONS_DIR` to each user's COS `operations/`
  tree for G2 Review Meetings. Unset keeps standalone local recordings.
- Server also accepts `COS_MEETINGS_ROOT` (alias) or infers from
  `COS_SCRIPTS_DIR/..`. Do not hardcode one user's COS path as a product default.
- Verified baseline server target: 6.16.2 (Install/Update still use npm `latest`).

## 0.2.5 truthful HQ target

- The bundled server target is 6.16.0, published on npm before this source pin.
- The existing HQ-default/Fast-mode preference remains companion-owned; Control
  installs the server capability metadata and truthful fallback reporting it uses.

## 0.2.4 local-service recovery

- Server 6.15.4+ starts Whisper and Kokoro while a replacement remains behind
  the maintenance gate, then starts durable/background work once admissions are
  released.
- Managed verification waits for local Whisper when its persistent
  whisper-server/model prerequisites are installed. Repair Whisper cannot
  report success until the persistent
  server is ready.
- Drain progress identifies the active work class and remaining deadline.
- The bundled server target for that release was 6.15.5.

## 0.2.3 workspace activation

- Choose Folder now applies to managed and explicitly adopted self-managed
  LaunchAgents; unadopted and unknown services are never rewritten.
- Workspace changes drain active work when the server supports the lifecycle
  contract, reload launchd from the rewritten plist, require a replacement
  process with verified ownership, and restore the prior plist/runtime on
  failure. Older adopted servers save the selection without interruption; a
  confirmation-gated manual Restart uses bootout/bootstrap to activate it.
- `COS_WORKDIR` is authoritative for Claude, Codex, and Cursor. Pipeline scripts
  remain configured separately by `COS_SCRIPTS_DIR`.
- Server `WorkingDirectory` and `COS_GLASSES_APP_DIR` stay on the server package;
  they never change to the selected agent workspace.
- The bundled server target is 6.15.3.

## 0.2.2 transactional verification

- Install, update, restart, repair, and rollback now prove one real no-tool
  turn through every managed Claude/Codex provider before reporting success.
- If Kokoro is ready, Control prepares local speech and fetches the native
  capability URL without an API header, catching playback-only 401 failures.
- Managed launches preserve the COS work folder, MCP selectors/config, local
  Python overrides, and user-local provider paths.
- Migrated pairing tokens of 16 characters or longer remain valid.
- The bundled server target is 6.15.2.

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
