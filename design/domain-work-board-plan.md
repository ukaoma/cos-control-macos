# Domain work board and meeting connections

2026-09-27. Extends the existing connected Work candidate. Installed Control 0.5.239, server 6.55.0 and glasses 6.9.555 remain the rollback baseline.

## User result

Choosing a domain opens a full-width board: Mentioned, Planned, Draft, Built, QA, Complete. QA precedes completion. Cards open existing Work detail; Back returns to the same domain. All Work retains its cross-domain list. Cream and raised cream surfaces match Memories. Stages describe explicit user decisions, not guesses from session status.

Each task shows confirmed source meetings and linked session activity. Users can attach a saved meeting to a legacy task. A meeting detail shows its confirmed tasks, their board stages, its review records and the sessions actually associated by handoff receipts. Links use canonical meeting record IDs plus domain/month/filename, and provider-qualified session IDs. Similar names are not evidence. Threads remain available.

## Compatibility contract

Canonical tasks.md remains authoritative; no duplicate task database. Retain the existing planning/active/review stage vocabulary for the glasses. Add workStage and meetingRefs to the API. Unmarked existing tasks start Planned, checked tasks Complete. Mentioned/Planned project to planning; Draft/Built to active; QA to review. Complete changes the canonical checkbox and retains the previous phase for reopening. Explicitly moving a completed card reopens it in one locked write.

Canary-validated storage: a bounded versioned metadata link inside the existing Source field. The old parser excludes Source from task identity and old writers preserve raw Source; this allows the older application to remain usable without new stage syntax. The new reader extracts metadata for display. A conflicting legacy stage invalidates the refinement. Writers reject user-injected reserved metadata and preserve the raw Source through text edits, schedules and checkbox writes. Malformed metadata must never fabricate links or execution authority. Confirmed refs are validated against the saved meeting before admission. No fuzzy backfill.

## Implementation ownership

1. Canonical Python: operations/scripts/task_rows.py, task_write.py, cos_api_bridge.py and their targeted tests. Atomic work-stage and link commands, capability version, metadata validation, old-reader/writer canaries.
2. Server: server/lib/task-store.ts, a bounded work-board route, route registration and server/scripts/work-review-candidate.ts. Expose additive projection and explicit mutations through existing Python writer. Candidate gateway operates alongside installed server; no production restart. Native HelperSources/main.swift uses candidate transport only for new Work commands, retaining the installed legacy task routes.
3. Native connection layer: Sources/Models.swift, ControllerModel.swift, ActivityMeetings.swift, ActivityWindow.swift. Typed metadata, helper methods, exact cross-tab callbacks, related task/session panel and persistent footer action in Meetings. Session receipts remain the sole evidence of an agent association.
4. Native board: Sources/WorkWorkspaceView.swift. Domain board, stage action menu, explicit linking through the existing saved-meeting picker, source buttons and isolated fixtures for every lane. Stage and link changes refresh canonical data; failures do not paint success. No drag/drop required for this slice.

## Validation and delivery

Before implementation: three read-only validators plus live read-only inventory (202 tasks observed; all currently planning, 150 plain-text sources) and disposable baseline-parser/writer compatibility tests. The baseline 6117b014 reader preserved identity for four source layouts; 28 baseline writer operations preserved the metadata link. Evidence: /tmp/cos-work-metadata-compat.json. Three validators required exact descriptor checks, revision fences and receipt continuity; these are included below.

After implementation: parser/writer/bridge roundtrips, restart durability, completion/reopen, malformed/reserved metadata, cross-domain duplicate IDs, split meeting pieces, duplicate titles, historical months, link admission failure, server route/old-bridge fallback, native projection and exact navigation checks. Run focused Work and full native regressions; relevant server suites and Python checks. Four adversarial QA angles, then build a separately versioned candidate, exercise actual UI at normal/compact sizes, commit/push source and evidence. No public publication, installed service replacement or EHPK upgrade is implicit in this candidate build.

Confidence-based preparation, automatic agent runs and publication are unchanged by this board slice. Moving a card does not start an agent, approve a draft or publish an asset.

## Validator corrections adopted

- New writes require both the current task description and a task-file revision digest, checked against the exact task ID under the canonical file lock. No ordinal, fuzzy text or title fallback. A changed task file produces a conflict and refresh requirement.
- Metadata retains the original work identity across canonical text edits; the existing hash task ID remains unchanged in format. Handoff source IDs use this stable work identity, preserving receipt history when the title changes through the new writer.
- Meeting opening checks response success and exact record identity, including historical months. Incomplete task/review inventory is visible in the related-work panel.
- Malformed/duplicate/unknown metadata is preserved, reported and cannot be overwritten by board actions. Ordinary task entry cannot inject the reserved metadata protocol.
- Legacy stage edits made through the upgraded writer reset the refinement to the corresponding coarse stage. A truly old writer can only express planning/active/review: returning to a previously matching bucket can restore its retained fine phase. Rollback preserves tasks and IDs but cannot express all six stages; stage movement never authorizes execution or publication.
- Candidate stage/link canaries must use a disposable COS_TASK_ROOT. No QA writes to real tasks.

## Next phase: Work in the EHPK glasses HUD

**Requested by Miles on 2026-09-27, after the Control candidate delivery.** Begin this phase after COS Control completion and acceptance; a test-ready Mac candidate does not close that dependency. This records the follow-up scope, not a claim that the glasses implementation has shipped.

- Extend the existing glasses Tasks experience with Work using the same canonical tasks, stable Work identities and six stages. Preserve task capture, completion and legacy-client compatibility; do not introduce a separate glasses task store.
- Design a glanceable domain/stage list and Work detail suited to the HUD. Include source meeting associations and recorded session activity/errors, with return navigation to the originating item. Validate which controls fit on the lens and which belong in the phone/Hub or Control detail.
- Reuse the existing session handoff contracts wherever actions are exposed. A stage or session status must not silently dispatch an agent, complete a task or approve publication. Preserve Continue within thread behavior and explicit destination choice.
- Build an opt-in candidate through the actual glasses and phone/Hub shell. Read G2_DISPLAY_CONSTRAINTS.md, verify current manufacturer contracts and test the real SDK event/render path. Use disposable write targets, old-server/old-client compatibility canaries, reconnect/restart checks and on-lens acceptance evidence; the phone mirror alone is not lens proof.
- Preserve the current EHPK and Hub distribution as rollback artifacts. The recorded glasses baseline is 6.9.555; recheck the actual device and release branches before choosing the next version. Update the EHPK and associated Hub distribution together when that phase is qualified for release.
