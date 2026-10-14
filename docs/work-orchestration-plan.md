# Task chat and orchestration candidate

Source: Control f211e46 (installed 0.5.291/build344), server 10c032b (6.73.3). Separate codex/work-orchestration worktrees. Installed apps, source work, task stages and transcription/cue settings are untouched.

## User journey

The task's main column gains Work chat, retaining Connections and Agent workspace on the right. A user message produces a descriptive answer and at most three independent assignments to exact explicitly connected sessions. Each assignment names its destination, request and delivery receipt. The original user message is authorization for the bounded assignments it requests; read-only questions produce no dispatch. External publication, messages to other people and destructive actions still require explicit authorization in the destination session.

A tools-off Sonnet planner receives fresh task context, confirmed session links, recent bounded session evidence and prior task-chat turns. Its output is data, never a shell command or a task mutation. Validate all IDs against the captured connection set. The first candidate splits independent work only: overlapping writes and dependent steps ask for clarification rather than racing collaborators. Cursor is represented honestly as a manual handoff until exact existing-chat delivery is qualified; it is never replaced by a new Cursor chat.

Execution reuses WorkHandoffStore's exact-native attach, queue, epochs, delivery journals and progress tracker. An explicit orchestration run permits multiple confirmed receipts on distinct targets within that run; any unknown admission or foreign active receipt stops subsequent assignments. Link/task changes after planning stop execution. Saving the intent precedes each send. Crash recovery never resends automatically. A second click cannot duplicate the run. User status summaries retain per-session provenance, unfinished work, questions and limitations. Agent output never changes the shared task's stage or original source.

## Surfaces and persistence

Control: WorkWorkspaceView.swift, WorkHandoffStore.swift, WorkSessionLinks.swift, HelperSources/main.swift. Server: new work-chat route and pure request/answer validation module; reuse meeting-ask-runner.ts's isolated tools-off process with explicit model and token audit. Local task-chat records use private locked atomic files per canonical task/server, separate from handoff journal and task sources. Store bounded history, draft, plan, run, receipts and reported updates. Retain names across stale live checks; stale metadata never claims fresh liveness.

## Validation and promotion gates

1. Disposable route tests: auth, malformed/oversized input, unlinked IDs, duplicate targets, manual Cursor, tools-off planner, bounded output, errors/abort and concurrent planning cap.
2. Core canaries: private storage/CAS, plan changes, unknown delivery fence, duplicate send, mixed failures, per-session results, restart, task changes, link moves, busy targets, no automatic Complete/source overwrite.
3. Native integrated COS preview: chat, Connections and Agent workspace together; resize, draft/restart, keyboard submit/cancel/navigation, empty/error states. Sample preview makes no provider calls or task writes.
4. Bounded tools-off live planner canary in a scratch workspace. Actual delivery to fresh disposable native sessions is a separate gate; fixture transport never proves it. Live IT Retail chats receive no test messages.
5. Connected read-only qualification against real task IDs and links, then explicit release/install authorization and matched-package checks. Stable installation remains rollback until qualified. No public promotion in this task.

Architecture validation: metadata expiry and existing app-owned/manual provider paths are load-bearing risks, not ignored. Installed /claude-sessions --fresh succeeds and discovers all three providers. Native automatic app delivery still requires disposable qualification. Architecture drift detector reports pre-existing documentation/LaunchAgent/git-hygiene drift; no cleanup is part of this feature.

## Candidate evidence — 2026-10-14

- Server: typecheck and 18 focused tests pass (four suites). New endpoint sits behind existing API-token middleware and maintenance admissions.
- Live tools-off Sonnet canaries pass: a two-destination independent plan (4.66 seconds on final run), a partial-result summary that preserves the navigation blocker, and a read-only question with zero assignments. These are planner/summarizer tests; actual dispatches: zero.
- Native integrated checks pass with bounded compile receipt `compile.8hBJmc`: private CAS/symlink refusal, durable chat/exact receipts, two distinct simulated targets under one run, duplicate/foreign active-run fences, all-round result provenance, double-send/navigation/task-revision changes. Existing session hub, activity, board-cache and 22 context assertions also pass. Rendering covers light/dark and compact layouts.
- Visible native preview check: Work chat, Connections and Agent workspace coexist. Return adds a newline, Command-Return submits one sample plan, the sample adds two delivery receipts, and a simulated Codex result returns under that assignment. The shared task remains Draft.
- Real task qualification is read-only: `task:quilt:be90b103fdce` resolves to the three exact saved Claude/Codex/Cursor links. Claude and Codex attachability both report ready to continue in the original thread, ownerCount 1. No IT Retail session received a test message.
- Identity now uses a separate private cache; discovery does not rewrite drafts or delivery journals. Live state still expires after 45 seconds. Chat reads all round receipts every 15 seconds while visible; a new terminal result/input request may generate one summary per material evidence change. A failed summary is not retried by polling; Refresh updates can retry it.

## Preview test steps and remaining delivery gate

The local preview uses disposable sample data and a fixed sample plan. It does not talk to providers. Open IT Retail website launch. In Work chat type: “Review the copy and implementation independently. Report findings here without publishing.” Return must add a line; Command-Return must create exactly two queued sample assignments. Connections and Agent workspace remain visible. Select Codex View progress, press Show result, then Refresh updates; that result must appear only beneath Codex's assignment. Navigate back and reopen the task; the conversation must survive. The task's stage stays Draft.

Before installing a connected release, qualify actual new orchestration delivery in disposable native Claude/Codex sessions: route distinct read-only checks, verify each exact transcript/receipt once, independently exercise busy/unknown/refused targets and a partial result, and confirm that the result summary retains each session's provenance. Fixture transports and readiness reads do not clear this gate. App-owned sessions retain the existing manual app continuation; Cursor retains manual sending in its existing app. Dependent or ambiguous work produces a question/sequence, not concurrent overlapping assignments.

The server feature remains unversioned source on `codex/work-orchestration`, based on 6.73.3. It is not a new published 6.73.3 artifact. Choose an unused next version and build matched packages only after delivery qualification. Installed Control 0.5.291/build344 and the managed 6.73.3 server stay unchanged. No transcription or cue setting was edited; live cue and auto-cue flags remain 0.
