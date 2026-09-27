# Work redesign — connected user journey

Status: implemented and qualified as local QA candidate 0.1.6/build7. Full native/server regression suites passed. Public rollout and automatic preparation remain gated as recorded in design/qa/work-redesign-0.1.6.md. Baseline native be3bb89; server a7195f3. Preserve installed Control 0.5.239 and glasses 6.9.555 until qualified rollout.

## Product contract

Work has structural navigation for All work, Needs attention, In progress, Completed, and server-defined domains. A persistent work detail replaces the task modal on the Work route. It shows the full task text, source, finish line, relevant sessions, attempts and results. Task editing/scheduling remain secondary; legacy Tasks behavior and canonical IDs stay compatible. Use existing COS typography/palette and Memories-style list/detail hierarchy. Keep selected work and unsent context across navigation; changing source revision never silently reuses stale authority.

Meetings gains Review follow-up, with a shared Work meeting picker for older meetings. Review uses canonical saved meeting content, durable server jobs and stable meeting/revision identity. Same revision reopens its review; changed revisions retain history and need a new review. Existing task associations are proposals, never silent task creation or completion. A review can be sent to an existing session or fork/new using established exact-identity handoff paths. Display provider availability honestly. Automatic after-sync policy must invoke the same review path, and never represent a disabled or unwired capability as active.

## Ownership / boundaries

Native workspace: new WorkWorkspaceView.swift plus ActivityWindow.swift/ActivityMeetings.swift integration. Keep task mutation methods in existing ControllerModel. Reuse WorkHandoffView for agent actions in the full detail; remove it from legacy edit overlay. Persistent close/back controls, Escape and backdrop behavior, focus recovery and unsaved-draft behavior are required.

Handoff model: WorkHandoffStore.swift/WorkHandoffView.swift draft persistence, evidence-based suggestions, no generic-word default recipient. Previous exact links rank first. Store chosen provider/model/session and prompt per source/revision, independent of mounted view. Preserve unknown-outcome duplicate fences.

Meeting review: server-owned durable review record keyed by canonical meeting identity and source revision. Narrow routes must reuse authoritative meeting detail and durable query job runtime, with auth and bounded inputs. Review extraction and preparation states must not depend on keeping a window open. Source corrections supersede rather than overwrite history. Native client projects records; no fake sample route in connected mode.

Root owns native helper/client glue, build lists, packaging, integration, evidence and release gates. Server and native changes are staged candidates; public publication requires passing the complete qualification ledger.

## Qualification

Begin from green full native/server baselines. Focused tests cover domain/task identity, view parity, source revisions, re-review dedup, unavailable source, stale suggestions, durable drafts, exact handoff joins and unknown receipts. Actual native QA at normal/narrow sizes and light/dark appearance must exercise Work and Meetings, Escape and backdrop with field/editor/button focus, navigation and restart, and no lab diagnostics on connected routes. Live provider canaries use synthetic text/disposable targets; injected tests never count as provider execution. Full regression and applicable mutation gates run on final source. Separate adversarial QA follows implementation, with fixes re-reviewed. Record failed and unrun gates explicitly. Preserve rollback files and commit/push only owned changes.
