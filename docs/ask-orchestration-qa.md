# Ask COS orchestration integration gates

This is a follow-on candidate based on Control `cdb3d74` and the server's committed 6.99.16 baseline. It is not part of the frozen 0.5.374 release. This checklist is not a test receipt.

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

As of November 6 at 06:30 CST the 0.5.374 owner reserved the shared Swift compile slot for its signed build. That build may proceed after its own bounded wait, so an apparently idle compiler is not permission to start a concurrent compile. Hold native compilation until the signed build completes or Miles explicitly schedules this candidate first. Server and source-only checks can continue.

Release remains gated on compiled native behavioral checks, helper contract tests, and the real Ask → Work review → explicit Send → receipt journey. Static source checks alone do not establish release readiness. No live dispatch should be performed merely to satisfy a test without an authorized test target.

## Source preparation receipt — November 6

- Server integration: `4845002` on `codex/ask-cos-orchestration-20261105`, rebased onto the committed 6.99.16 baseline. Its snapshot-only upload is authenticated, bound to server identity and canonical task revision, and does not refresh usage or run discovery/inference. Ask discovery advertises `controlSnapshot: 1`.
- Native behavior fixtures: `9f7e441` on `codex/ask-orchestration-20261106`. They exercise the real Work stores through a closed fake transport and private test files, including cancellation, competing-writer CAS, stable assignment identities, repeated import, stale context, and no dispatch despite Auto-send being enabled. They have **not been compiled or executed**.
- Native source review: root independently reviewed the proposal decoder/sheet, preparation/import, context proof, CAS behavior and helper transport; no blocking source defect was identified.
- Permitted checks: 37 Ask source pins, 717 Drop it pins, 811 setup-assistant pins and existing Work orchestrator pins pass. Changed shell scripts pass syntax checking; `git diff --check` passes. These are source checks only.
- The shared Swift compile slot remains reserved for the 0.5.374 signed release. No Swift compiler, native fixture binary, helper binary, UI automation, live provider call, install, restart or publication was run for this native candidate.

The entry point is **Plan for Work** in the existing COS chat composer. It requires explicit card selection. Proposals are stored on this Mac in the existing server/card Work history, with original/revalidated server evidence and the real COS conversation ID when available. They are not written into the server conversation transcript. The command-center Ask path and normal COS-thread continuation are unchanged. New-session proposals remain disabled by the server contract. Local context is captured for later review/sending, not supplied to this first server planner.

The helper's existing `requireLiveWorkTransport()` deliberately rejects test homes. No test-only bypass was added to exercise HTTP routing against the user's live state. Compiled native behavior, a safely isolated helper HTTP contract test and visual/end-to-end verification remain outstanding gates.

The native behavior runner is `Tests/run-ask-work-plan.sh`. It compiles all application sources except `COSControlApp.swift` through the bounded shared kit and compile guard; it still requires explicit ownership of the shared Swift compile lane. Do not run it during the 0.5.374 signed build. The full native compile/check suite, native helper HTTP contract gate, visual review and authorized end-to-end receipt check are also pending.
