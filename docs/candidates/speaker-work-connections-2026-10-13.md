# Speaker and Work connection candidate — 2026-10-13

Status: combined isolated candidate; not installed or published. Work copy/context and headless roundtrip are integrated. The matching server corrections are merged and qualified by isolated canaries; physical acceptance remains pending. Runtime transcription and cue flags are unchanged.

## Existing candidate

Control worktree: `/Users/ukaoma/cos-worktrees/ctl-speaker-context-links`, baseline `bcb6d69`.
Server worktree: `/Users/ukaoma/cos-worktrees/server-meeting-speaker-policy`, baseline `275e316`, commits `4082ad6`, `6548fec`, `bc39aa1` (the exact-child identity correction originated as `62fe312`).
Evidence: `/Users/ukaoma/cos-release-candidates/speaker-context-links-2026-10-13`.

- Per-recording Standard, High-confidence and Anonymous/video identity modes. Policy is captured before asynchronous audio work and follows the chunk through live labels, persistence and finalization. Existing names are corrected explicitly; anonymous mode does not delete global profiles.
- Canonical meeting-to-task links shown from Speakers, including multiple tasks, Open task and Link another task. Agent source context carries the same canonical meeting references.
- Task people refresh replaces cached evidence and rejects older reads. Correction navigation opens the source meeting; there is no separate task-level People exclusion store.
- Confirmation Return/Escape handling, with disabled guards and preserved multiline editing. The intentional Return-does-not-install update panel remains unchanged.
- Codex semantic completion and process completion are reconciled separately. The exact completed child opens after terminal confirmation; explicit retry does not create another run. Dispatch acknowledgment is not proof that the app rendered the chat.

## Data correction already performed

Meeting `meeting_1791942284607_qvx0yz`, IBM Organic Growth Systems Playbook (G2), now has zero asserted named segments. The remaining eight MU segments were deattributed with training preserved. Forty global MU samples were retained; global speaker profiles were not removed. Original files and correction receipts are in the evidence folder.

The existing Codex child `01a1384c-a7a3-7281-98e2-a4715c46cfd9` was recovered and navigated to using the Codex app tool. Its review brief is saved at `operations/quilt/wk42_2026/growth-system-evolution/REVIEW_BRIEF.md` in the COS workspace. No second model run was started.

## Completed verification

- Combined server: 270 tests across 16 files and typecheck. Independent review cleared both asynchronous policy pinning and canonical child identity. The compiled staged Control helper also passed against the actual server detail route with inherited parent metadata; the old-overwrite negative control failed as intended.
- Compiled Control helper: 821 deterministic self-tests and 62 Work model/admission checks.
- Compiled helper against isolated authenticated loopback: policy GET/guarded POST, corrupt-store response, stale/older server, auth refusal; selected record/revision recovery; recent replies and completion reads.
- WhatsNew shortcut pins passed. The initial native keyboard fixture passed behavior checks but constructed synthetic events, which the repo forbids. It was removed from the release gate; its historical receipt is not release qualification. Enter/Escape and multiline routing require manual candidate acceptance.
- Full Control Work progress suite: terminal-after-semantic-done, opening exact child, retry without another prompt, failure preserves result and legacy tracking compatibility.

## Acceptance gates after candidate build

1. Open the IBM recording in Speakers. Confirm zero named segments. Select Anonymous/video for an external recording; new audio must not enroll or attribute speakers. Change modes while audio is processing: the accepted strict chunk stays strict; the next chunk follows the new mode.
2. Verify Speakers shows Quilt Growth System Evolution. Open it, return to the recording, link a second disposable task, and confirm both task references persist after refresh/restart. An Already linked picker row must still offer Open task.
3. In Work, Refresh people after source correction. Verify old false chips disappear. Use Correct people in source meeting to reach the canonical recording.
4. In a disposable source voice correction, Return confirms enabled Save; Escape cancels. Disabled Save cannot execute; multiline text continues to accept newline.
5. Start/fork a disposable Codex Work session. Confirm the child opens when its first run completes, Control stops showing Running, and Open in Codex retry opens the same child. Verify the full result and artifacts in Codex, not only the Work status excerpt.

Physical app navigation and device acceptance remain required. No claim of public-release readiness follows from synthetic canaries alone.

## Work clipboard and headless roundtrip

The separate Control worktrees are `ctl-work-context-roundtrip` and `ctl-work-roundtrip-backend`. The combined candidate adds:

- Board-card context menu and task-detail actions for Copy task ID and Copy context.
- Canonical key `task:<domain>:<workIdentity>`, full task text/finish line/stage and confirmed source meeting references. Snapshot hashes and writer revisions are labeled separately.
- Bundled helper contracts `work-context`, `work-link-session`, and named-option `work-set-stage`. The existing GUI stdin update form is preserved.
- Fresh canonical reads before mutations; the same authenticated CAS stage writer used by the GUI. Conflicts require review and a fresh read, not an automatic overwrite.
- Explicit registration of an exact verified native Claude/Codex session, using the existing session-card map. Registration creates no prompt, job, receipt or completion. Multiple sessions may work on one task.
- One shared locked read/merge/write path for Control and headless registrations. Corrupt maps remain intact on disk, cached links are cleared, and independent session discovery continues.

The clipboard itself never creates a chat or association. The receiving agent follows the copied instructions to resolve fresh context and register its exact existing session. If its native identity or the helper support is unavailable, it must report that limitation.

### Roundtrip acceptance after candidate install

Use a disposable task for board writes.

1. Copy task ID from the board. Open its detail and Copy context. Confirm full text, source references and the same canonical key are present.
2. Paste into a separate existing Codex or Claude chat. Ask: "Resolve this task's current context and link this exact session to it. Do not start another session or change its stage."
3. Refresh Work/Sessions in Control; confirm the exact session is linked. Restart candidate Control and confirm the association remains.
4. Ask that agent: "Move this disposable task to Draft using the canonical Work helper." Refresh the GUI; confirm Draft. Drag it to Built in Control; ask the agent to re-read and confirm Built.
5. Obtain a revision, then change the task in the GUI. Attempt an update using the older revision. Confirm it refuses and the newer stage remains.
6. Link a second existing chat to the same task and confirm both persist. Reassigning either chat to another task requires its current link revision and explicit user direction.
7. Copying or linking must create no provider run and leave stage/completion unchanged.

The helper HTTP/process canaries passed against an isolated authenticated server: fresh task reads, stage CAS/races/auth refusal, exact existing native-session checks, idempotent association and restart, 12 concurrent merges, same-session one-winner conflicts, and corrupt/symlink/FIFO refusal. The legacy stdin stage fixture also passed. These create no model calls or phantom handoffs.

The integrated native fixtures passed: Work handoff/store (including external reload, corruption, restart and stale GUI intent), Work progress, 22 clipboard assertions including bundled-helper selection/broken-app refusal, and canonical meeting/task links/cache/render checks. The app and helper compiled under bounded machine-wide guards; the staged app passed signature verification. The final staged helper also passed both policy and roundtrip loopback canaries. Physical GUI/headless roundtrip remains an acceptance gate.

### Exact fork identity dependency

QA found that cloned Codex rollout metadata can contain the parent's ID. The existing server detail route returns that metadata ID even when reading the child's exact file, so the headless helper correctly refuses the mismatch. The matching server now returns the canonical child filename identity and preserves legacy metadata fallback only when no filename identity exists. The real cloned-rollout route plus compiled-helper fixture passed, linking only the child and refusing an unknown UUID. Restoring the old overwrite made the canary fail. Strict mismatch refusal remains in the helper.

### Candidate operator notes

Copied context resolves this app's bundled helper, so a staged candidate never silently invokes an older installed Control. Missing bundled helpers fail explicitly. The candidate app is an opt-in Work preview with a distinct bundle identity; it is not a public release or a replacement for installed Control. Its connected launcher uses real tasks only when the operator explicitly runs it. Use disposable tasks for stage/link acceptance. Speaker mode acceptance additionally requires the staged server policy changes; installed server behavior is unchanged.


## Staged artifacts and gate disposition

- Private Work app: `/Users/ukaoma/cos-release-candidates/speaker-context-links-2026-10-13/candidate/COS Control Foundation Lab.app`.
- Zip: `/Users/ukaoma/cos-release-candidates/speaker-context-links-2026-10-13/candidate/COS-Control-Foundation-Lab.zip`.
- Explicit connected Work launcher: `start-work-connected.command` beside the app. Nothing has been launched automatically. This is a Work-only private preview; it does not replace Control or start/update the server.
- Operator notes and full canary evidence: `/Users/ukaoma/cos-release-candidates/speaker-context-links-2026-10-13/candidate/README.md` and the parent evidence folder.

Remaining manual gates: exact child/result visible in Codex, linked-task navigation/return, actual clipboard-to-Claude/Codex linkage and board updates in both directions, speaker-mode device acceptance, and Return/Escape/multiline confirmation behavior. The matching server and full Control candidate must be installed before claiming those features are available in the running product. This task stages source and evidence; it does not install, restart, publish or promote a release.
