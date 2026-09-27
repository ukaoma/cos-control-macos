# Control 2 Foundation Lab

Opt-in native SwiftUI interface for the disposable meeting-to-work foundation. The regular COS Control menu exposes **Open Work** and Activity replaces the **Tasks** peer with **Work** only when `COS_CONTROL2_FOUNDATION=1`. Normal launches retain the existing Tasks tab. Old Tasks entry points open Work → Tasks under the opt-in; this subview reuses the existing task controls and APIs.

The isolated QA application renders the actual COS Control Activity window, navigation rail, shared brand resources and Work pane. It initializes ControllerModel with background work disabled and never starts the runtime updater, session pet or hotkey. Peer sections remain visible but display an explanatory placeholder instead of mounting live panes or making production calls. Its bundle ID is `com.gotcos.COSControl.FoundationLab`.

## Build and verify

```sh
scripts/build-foundation-lab.sh
Tests/run-control2-foundation-contract.sh
python3 Tests/control2-foundation-transport.py "$HOME/Library/Caches/COS Control Work Preview/COS Control Foundation Lab.app/Contents/Resources/cos-control-helper"
```

The runnable app is kept under `~/Library/Caches/COS Control Work Preview/` to avoid FileProvider adding Finder metadata during signing. A signed app ZIP is exported to `dist/control2-foundation/COS-Control-Foundation-Lab.zip`. This is local ad-hoc QA, not a notarized release or installation.

## Connect to a disposable server

The server launcher supplies:

- `COS_CONTROL2_FOUNDATION=1`
- `COS_CONTROL_TEST_HOME=/tmp/<private-disposable-directory>`
- `COS_CONTROL_TEST_API_PORT=3147` (or another port above 1023 excluding 3141 and 3143)
- `$COS_CONTROL_TEST_HOME/.cos-glasses/.env`, mode 0600, containing `COS_API_TOKEN=<disposable-token>`

Launch `.../COS Control Foundation Lab.app/Contents/MacOS/COS Control Foundation Lab` directly with these environment variables. The helper validates that the test home resolves within `/tmp` and refuses invalid settings before reading credentials or making a request. Its token reader uses descriptor-relative no-follow opens for the scratch home, token directory and file; outside symlinks are refused. It uses `X-COS-Token`, refuses redirects and caps responses at 2 MiB. It never falls back to the live service for foundation commands.

## Manual checks

1. Start the isolated backend and launch the lab. Exercise All work, Tasks, Meeting follow-up, and Completed using blank/padded row space as well as text. Complete and reopen a sample task.
2. Open another section and return to Work: synthetic task state resets, as the UI says. Meeting history belongs to the backend journal and can survive a resumed launch.
3. Select Meeting follow-up and expand Test controls.
4. Replay sample. A synthetic meeting produces a review packet in the durable queue.
5. Replay the same sample. Confirm no additional work is created for an unchanged revision.
6. Replay correction. Inspect the revision change and superseded record.
7. Restart the isolated backend and Refresh. The queue should survive.
8. Stop the backend and Refresh. A transport error clears old packet state; replay is disabled.

The view displays source excerpts, operator-provided criteria, optional fixture preview path/hash and actual check results. When the isolated backend explicitly advertises `manualDraft`, Prepare text preview requests a bounded no-tool text draft for the selected current work. There is one draft attempt per backend process. If its budget is exhausted, quit and relaunch the preview; use COS_FOUNDATION_TEST_HOME to retain meeting history. It is not a website coding agent. Open checked preview verifies the HTML file remains within the scratch home and matches its recorded SHA-256 before opening. It does not invent an AI-generated diff. Publication and automatic execution are unavailable. Any response advertising those capabilities or an unsupported schema/status is refused. End-to-end durability and revision behavior depend on the server and must be tested against it separately; the transport fixture does not prove those features.


## One-command local test

Double-click `scripts/start-foundation-lab.command` (also included beside the app in the ZIP). On this Mac it finds the sibling server checkout and the final candidate app in `~/Library/Caches/COS Control Work Preview/`. An extracted launcher first uses the app beside it.

Override `COS_FOUNDATION_SERVER_ROOT`, `COS_FOUNDATION_APP_PATH` or `COS_FOUNDATION_PORT` when needed. Set `COS_FOUNDATION_TEST_HOME` to resume an existing private disposable home and preserve its review history; the backend validates it before writes, and the launcher does not change its permissions. When no resume home is supplied, the launcher creates a new private `/tmp` home. It starts its own backend, waits for readiness, and launches the lab app with matching credentials. Quit the app to stop that backend. Scratch evidence and independently created private log files remain available at the printed paths. Logs are never redirected into an unvalidated resume home. An occupied port fails without stopping any process. `COS_CONTROL2_DRAFT_ENABLED=0` disables the optional manual text draft.

Approved foundation error codes are shown alongside HTTP status (including exhausted draft budget or oversized criteria). Arbitrary server/provider error text is never displayed.


Visual QA may set `COS_CONTROL_TEST_APPEARANCE=light` or `dark`, and `COS_CONTROL_TEST_WIDTH`/`COS_CONTROL_TEST_HEIGHT` (minimum 760×560). These affect only the preview process; they never change system appearance. Candidate version 0.1.5/build 6 includes full-row hit targets and accurate preview-verification copy. The default distribution ZIP and cached app must agree on this version. Production app metadata is unchanged.

Historical evidence: native 0.1.3 blank/padded-area clicks passed for all four filters plus task and meeting cards in light mode at the default size. Fresh QA results and remaining visual limits are recorded in the September27 QA report. A process startup probe is not a visual pass. The Work→run→session orchestration plan is not implemented in this preview; Sessions displays the isolated-placeholder explanation.

Synthetic task completion lives only in this view and resets when leaving Work or restarting. It never edits real tasks. The meeting journal persists under the disposable home; use COS_FOUNDATION_TEST_HOME to resume it. The preview remains isolated and never writes a production task or publishes a page.


## Work → Sessions handoff preview (0.1.5)

Each sample task/current meeting work item now has **Choose where to work**. Continue selects a suggested existing conversation, Fork creates a separate sample conversation, and New selects a provider/model example. Inspect/edit the context first. These buttons simulate delivery inside the isolated preview and never call a provider.

After sending, use Show running, Show failure or Show result to exercise history. Open session shows the exact linked sample conversation and Back to work restores its source. Sample checkbox state now survives Work/Sessions navigation in the shared window store; it resets on application restart. Handoff history/sample sessions persist in the same disposable home. An unknown outcome blocks another handoff; a delivered live receipt can be explicitly marked reviewed without completing its task.

The source implementation also wires ordinary opted-in COS tasks to real existing session transports and a dynamic new-session catalog. That source path is separate from this disposable launcher. Read `design/work-session-handoffs.md` for supported provider actions, permission boundaries and remaining managed-execution work. Do not report the sample chooser as live orchestration.

For real-task testing, quit the isolated preview and run `scripts/start-work-connected.command`. The window is explicitly labeled **Connected Work candidate**. It reads real tasks and session summaries; Send/Fork/New deliver real instructions using the selected provider's existing permissions. The installed app and server binaries remain unchanged. This optional window has no background updater or pet loop and never turns test examples into real tasks.
