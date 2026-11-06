# Ask COS orchestration integration gates

This is the Control 0.5.375/build 429 candidate, based on Control `cdb3d74` and the server's committed 6.99.16 baseline. It is not part of the frozen 0.5.374 release. Completed receipts and outstanding gates are distinguished below.

## User journey

1. Open the existing Ask conversation and enter a work request.
2. Choose Plan for Work and explicitly select an existing, open canonical task.
3. Generate a proposal. Task metadata, confirmed meeting references and eligible session evidence are available to this planner; local attachments and Work history are not.
4. Add the proposal to Work review. Verify the task and context are unchanged. Preserve assignment identifiers through redraws, retries and reopening.
5. Inspect/edit assignments and context using existing Work controls. Send explicitly through the existing handoff owner.
6. Verify delivery receipts separately from proposal creation and separately from session completion.

## Required checks

| Case | Expected result |
| --- | --- |
| Older server or capability absent | Explain unavailable proposals; ordinary Ask remains usable. |
| Missing, ambiguous, completed or stale task | Refuse planning/import; do not silently select another task or revision. |
| Server connection changes | Refuse cross-server import or sending. |
| Links, attachments or local context change | Require another proposal/review; no silent context rebasing. |
| Missing/stale usage or execution evidence | Do not invent available agents; snapshot refresh launches no usage probe. |
| App-owned, busy or guarded session | Follow existing Continue/Fork eligibility and handoff checks. |
| Generate/import twice, reopen app | No duplicate assignment receipt identity and no automatic dispatch. |
| Cancel/close during inference | No send or imported proposal; server retains lifecycle ownership until model settles. |
| Concurrent Work history edit | Compare-and-swap refuses stale overwrite and preserves the other edit. |
| Model returns invalid assignment or protocol | Fail closed without mutating task, receipts or stage. |
| Import valid answer without assignments | Preserve answer; do not invent assignments. |
| Normal Ask reply after a proposal | Persistent conversation/session continuity remains unchanged. |
| Light/dark and narrow available space | Readable review, visible actions, scrollable content, no theme replacement. |

## Compile coordination

On November 6 at 06:50 CST the 0.5.374 owner allocated the first Swift slot to this candidate's native QA. Its signed builder now waits up to 90 minutes for a live `~/cos-release-candidates/swift-lane.owner` or Swift frontend, then exits without compiling. This QA acquired that owner atomically under supervisor PID 30605 and retains it across checks and fixes. Every compiler uses the bounded, single-frontend guard. The full suite also holds one global lightweight release-lane slot. A subsequent build must acquire the lane again; an idle frontend does not override a live owner.

Private installation requires the full native suite, isolated helper contract checks, a matched server, signed/notarized artifact verification, and the active-work swap gate. The real native stores' Ask → review → explicit Send → durable receipt journey is tested with a closed fake transport. That is not live provider or visual acceptance. Public/customer qualification still needs visual review and an authorized live target; no live dispatch should be performed merely to satisfy a test.

## Source preparation receipt — November 6

- Server integration: `4845002` on `codex/ask-cos-orchestration-20261105`, rebased onto the committed 6.99.16 baseline. Its snapshot-only upload is authenticated, bound to server identity and canonical task revision, and does not refresh usage or run discovery/inference. Ask discovery advertises `controlSnapshot: 1`.
- Native behavior fixtures originated in `9f7e441` and were expanded through `e565834` on `codex/ask-orchestration-20261106`. They now compile and pass against real Work stores, a closed fake transport and private test files. Coverage includes cancellation, competing-writer CAS, stable assignment identities, repeated import, stale context, and no dispatch despite Auto-send being enabled. A reference-bearing proposal reopens in a second Work store, imports, explicitly sends through the existing sender, persists a delivery receipt with the reviewed UUID, and refuses a duplicate Send.
- Native source review: root independently reviewed the proposal decoder/sheet, preparation/import, context proof, CAS behavior and helper transport; no blocking source defect was identified.
- Permitted checks: 37 Ask source pins, 717 Drop it pins, 811 setup-assistant pins and existing Work orchestrator pins pass. Changed shell scripts pass syntax checking; `git diff --check` passes. These are source checks only.
- Independent QA found a reference-capability initialization mismatch. `f6c6cf6` loads the actual Work capability state before both preparation and import, with cancellation and failed-discovery guards. The second-store regression passes; independent source review confirms the fix.
- Compiled Ask receipts: `~/cos-release-candidates/release-0.5.375/native-qa/ask-lane-reference-fix.json` and `ask-lane-explicit-send.json` both report exit 0. `compile.CsooTy` built the 63-source app kit in 319.9 seconds, one frontend, peak owned RSS 1.29 GB, minimum available 20.86 GB, zero swap growth. `compile.cgCDVG` compiled the explicit-Send harness against the exact reused kit. The earlier deliberately stopped compile is retained as `compile.awV8zb`, infrastructure exit 70, not a pass.
- The first full-suite preflight detected bundled notes still labeled 0.5.374. Its failed receipt/log are retained separately. `457c0a1` updates the notes to 0.5.375; the What's New source gate passes. The final full suite and helper HTTP execution are still pending at this document revision.
- No UI automation, live provider dispatch, signing, install, restart or publication has run for this native candidate.

The entry point is **Plan for Work** in the existing COS chat composer. It requires explicit card selection. Proposals are stored on this Mac in the existing server/card Work history, with original/revalidated server evidence and the real COS conversation ID when available. They are not written into the server conversation transcript. The command-center Ask path and normal COS-thread continuation are unchanged. New-session proposals remain disabled by the server contract. Local context is captured for later review/sending, not supplied to this first server planner.

The helper's existing `requireLiveWorkTransport()` still rejects test homes. The three new Ask reads/posts now use the existing secure connected-candidate transport, matching canonical board reads: a private non-live port and owned, mode-0600, no-follow token file. The HTTP fixture (`1358170`) tests that route without the installed server or credentials. It is included in `Tests/run.sh`; its execution receipt remains pending.

The native behavior runner is `Tests/run-ask-work-plan.sh`. It compiles all application sources except `COSControlApp.swift` through the bounded shared kit and compile guard; it requires explicit ownership of the shared Swift compile lane. Its separate passing receipt is required because the full suite does not invoke this runner. The full native suite, helper HTTP execution, visual review and authorized live journey remain distinct gates.
