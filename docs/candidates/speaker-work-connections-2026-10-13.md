# Speaker and Work connection candidate — 2026-10-13

Status: isolated code candidate; not installed or published. New Work copy/context/headless roundtrip is being integrated separately. Runtime transcription and cue flags are unchanged.

## Existing candidate

Control worktree: `/Users/ukaoma/cos-worktrees/ctl-speaker-context-links`, baseline `bcb6d69`.
Server worktree: `/Users/ukaoma/cos-worktrees/server-meeting-speaker-policy`, baseline `275e316`, commits `4082ad6`, `6548fec`.
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

- Server: 180 tests across 13 files, typecheck; focused independent review cleared the asynchronous policy race fix.
- Compiled Control helper: 821 deterministic self-tests and 62 Work model/admission checks.
- Compiled helper against isolated authenticated loopback: policy GET/guarded POST, corrupt-store response, stale/older server, auth refusal; selected record/revision recovery; recent replies and completion reads.
- Native confirmation canary: actual Return, disabled guard, Escape, background shortcut isolation and multiline newline. WhatsNew pins passed.
- Full Control Work progress suite: terminal-after-semantic-done, opening exact child, retry without another prompt, failure preserves result and legacy tracking compatibility.

## Acceptance gates after candidate build

1. Open the IBM recording in Speakers. Confirm zero named segments. Select Anonymous/video for an external recording; new audio must not enroll or attribute speakers. Change modes while audio is processing: the accepted strict chunk stays strict; the next chunk follows the new mode.
2. Verify Speakers shows Quilt Growth System Evolution. Open it, return to the recording, link a second disposable task, and confirm both task references persist after refresh/restart. An Already linked picker row must still offer Open task.
3. In Work, Refresh people after source correction. Verify old false chips disappear. Use Correct people in source meeting to reach the canonical recording.
4. In a disposable source voice correction, Return confirms enabled Save; Escape cancels. Disabled Save cannot execute; multiline text continues to accept newline.
5. Start/fork a disposable Codex Work session. Confirm the child opens when its first run completes, Control stops showing Running, and Open in Codex retry opens the same child. Verify the full result and artifacts in Codex, not only the Work status excerpt.

Physical app navigation and device acceptance remain required. No claim of public-release readiness follows from synthetic canaries alone.
