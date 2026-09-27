# Work session handoffs — implementation contract

This slice adds an operator-directed handoff to the shared COS Activity window. It is not the autonomous Work-run coordinator from the broader Control 2 plan.

## Interaction

Choose a task or meeting work item. Work ranks discovered session titles, summaries and workspace labels against its source context and recommends candidates with an explanation. Relevance is not authorization: the user chooses the exact provider/native-session identity. Review the editable context package, then Continue, Fork, or start New.

Continue reuses authenticated attachability → queue or attach → send. A busy session is queued only when the existing server allows it. Native revision and ownership refusals are preserved; Work never acknowledges changed context automatically. Fork uses the existing source-preserving Claude/Codex route. Cursor continuation is supported by its existing transport; unsupported fork choices are disabled. New uses durable query jobs and server-configured workspace/permissions, with Cursor ask posture. It does not impersonate the restricted task dispatcher or modify canonical task completion.

OpenAI execution uses the configured Codex adapter. Discovery/dispatch into arbitrary ChatGPT browser conversations is not implemented. Model labels come from the connected catalog where available. Claude tier aliases are explicitly configured-runtime evidence, not proof each tier has completed a canary. Missing models (including any requested name absent from the server catalog) are not invented or silently substituted. Ollama New uses its configured local model and returns a COS job/result; it does not claim a native desktop thread.

## Receipt and authority

Before any delivery attempt, Work writes a private atomic, synchronized journal with source snapshot revision, work identity, selected provider/model/session, exact reviewed prompt, and immutable client UUID. A process lock serializes writers. Binding ID/epoch and queue identity remain distinct from job/provider-session IDs. Work does not guess joins by title. New jobs bind a provider conversation only after confirmed ownership evidence.

A timeout or lost response leaves an unknown receipt that blocks another handoff for the same work. Refresh only reads original identities; it never resubmits. Fork has no durable server idempotency token, so an unknown fork is fenced and cannot be retried automatically. A delivery receipt is not task completion. Explicitly confirming that a delivered session was reviewed allows the next handoff, without checking off the task.

Results/errors are retained in the local receipt. A missing or expired server receipt is shown as unavailable/unknown. This local journal is not a shared server execution ledger, and no claim is made that it captures every future external turn or survives deletion of local app data. Managed ownership, automatic meeting extraction/dispatch, server-side receipt retention/export, multi-agent roles/budgets, and revision-safe canonical task migration remain separate build slices.

## Test workspace

The isolated Work preview shares one Work/Session store across navigation. Synthetic tasks, exact session identities, continue/fork/new receipts, progress, failure, results and backlinks are testable without provider calls. Sample task checkbox state lasts for the window; handoff receipts and sample sessions persist in the disposable home. Test controls explicitly advance receipts; elapsed time is never interpreted as completion.

Live handoff helpers refuse `COS_CONTROL_TEST_HOME`. The preview never switches itself onto live transport. Production Control and the glasses package remain unchanged until a separately qualified rollout.

## Checks

- Swift 6 strict compile of actual shipping types and shared Activity shell.
- Injected transport tests exercise real store state transitions, durable restart fences, exact destinations, queue receipts, fork identity, provider ownership and write-before-send failures.
- Helper catalog and UUID contract; isolation refusal before auth/network.
- Full existing native regression; actual UI navigation and package parity.
- Real provider runs remain separately evidenced; configured model availability is not an execution canary.

## Connected operator test window

`start-work-connected.command` opens this same shared Activity shell against the existing configured server, separately from the installed menu-bar app. It enables Activity reads without starting background status/update/pet loops. It refuses a test-home environment and does not start, stop, repair or upgrade the server. Real delivery requires the explicit Work button. New jobs use the current message era and let the existing coordinator allocate conversation identity; the client UUID/generation remains the recovery key.

The connected candidate begins on real Tasks. Select a task to review its destination/context. The synthetic meeting Foundation pane remains a separate lab surface; automatic meeting ingestion/extraction and managed task execution are not enabled by this launcher. Close the isolated preview before opening the connected candidate to avoid confusing two windows of the same test bundle.
