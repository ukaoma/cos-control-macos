# Control 2 Foundation Lab

Opt-in native SwiftUI interface for the disposable meeting-to-work foundation. The regular COS Control menu exposes **Open Control 2 Foundation Lab** only when `COS_CONTROL2_FOUNDATION=1`. Normal launches are unchanged.

The separate lab application uses the same view and helper but never initializes the production controller, runtime updater, session pet or hotkey. Its bundle ID is `com.gotcos.COSControl.FoundationLab`.

## Build and verify

```sh
scripts/build-foundation-lab.sh
Tests/run-control2-foundation-contract.sh
python3 Tests/control2-foundation-transport.py "$HOME/Library/Caches/COS Control Foundation Lab/COS Control Foundation Lab.app/Contents/Resources/cos-control-helper"
```

The runnable app is kept under `~/Library/Caches/COS Control Foundation Lab/` to avoid FileProvider adding Finder metadata during signing. A signed app ZIP is exported to `dist/control2-foundation/COS-Control-Foundation-Lab.zip`. This is local ad-hoc QA, not a notarized release or installation.

## Connect to a disposable server

The server launcher supplies:

- `COS_CONTROL2_FOUNDATION=1`
- `COS_CONTROL_TEST_HOME=/tmp/<private-disposable-directory>`
- `COS_CONTROL_TEST_API_PORT=3147` (or another port above 1023 excluding 3141 and 3143)
- `$COS_CONTROL_TEST_HOME/.cos-glasses/.env`, mode 0600, containing `COS_API_TOKEN=<disposable-token>`

Launch `.../COS Control Foundation Lab.app/Contents/MacOS/COS Control Foundation Lab` directly with these environment variables. The helper validates that the test home resolves within `/tmp` and refuses invalid settings before reading credentials or making a request. Its token reader uses descriptor-relative no-follow opens for the scratch home, token directory and file; outside symlinks are refused. It uses `X-COS-Token`, refuses redirects and caps responses at 2 MiB. It never falls back to the live service for foundation commands.

## Manual checks

1. Start the isolated backend and launch the lab. Read the currently blocked gates.
2. Replay sample. A synthetic meeting produces a review packet in the durable queue.
3. Replay the same sample. Confirm no additional work is created for an unchanged revision.
4. Replay correction. Inspect the revision change and superseded record.
5. Restart the isolated backend and Refresh. The queue should survive.
6. Stop the backend and Refresh. A transport error clears old packet state; replay is disabled.

The view displays source excerpts, operator-provided criteria, optional fixture preview path/hash and actual check results. When the isolated backend explicitly advertises `manualDraft`, Prepare text preview requests a bounded no-tool text draft for the selected current work. It is not a website coding agent. Open checked preview verifies the HTML file remains within the scratch home and matches its recorded SHA-256 before opening. It does not invent an AI-generated diff. Publication and automatic execution are unavailable. Any response advertising those capabilities or an unsupported schema/status is refused. End-to-end durability and revision behavior depend on the server and must be tested against it separately; the transport fixture does not prove those features.


## One-command local test

Double-click `scripts/start-foundation-lab.command` (also included beside the app in the ZIP). On this Mac it finds the sibling server checkout and the final candidate app in `~/Library/Caches/COS Control Foundation Lab Candidate/`. An extracted launcher first uses the app beside it.

Override `COS_FOUNDATION_SERVER_ROOT`, `COS_FOUNDATION_APP_PATH` or `COS_FOUNDATION_PORT` when needed. The launcher creates a new private `/tmp` home, starts its own backend, waits for readiness, and launches the lab app with matching credentials. Quit the app to stop that backend. Scratch evidence remains available at the printed path. An occupied port fails without stopping any process. `COS_CONTROL2_DRAFT_ENABLED=0` disables the optional manual text draft.

Approved foundation error codes are shown alongside HTTP status (including exhausted draft budget or oversized criteria). Arbitrary server/provider error text is never displayed.
