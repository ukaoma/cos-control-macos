# Work redesign 0.1.6 — qualification record

2026-09-27. Candidate build 7. Native baseline `be3bb89`; server baseline `a7195f3`. Installed COS Control 0.5.239, server 6.55.0 and glasses 6.9.555 are preserved.

## What changed

Work uses the existing native Activity shell and COS theme with domain navigation, active/attention/completed scopes, full-text search and persistent detail. Existing task IDs and completion remain canonical. Agent destination selection lives in the detail pane. Unsent prompt/destination drafts persist per source revision. Suggestions require explicit selection; prior exact handoff associations outrank topic matches. These are heuristic suggestions, not semantic retrieval.

Meetings and Work share a saved-meeting review entry. Review requests use the canonical saved record, source revision and durable job identity. Reopening a revision reuses its review. Corrections supersede prior results; source outages preserve terminal evidence and require exact source revalidation before readiness returns. Agent handoff revalidates the reviewed context before sending. Task associations are proposals only. Reviews currently appear in the existing COS conversation as well as Work.

Task editing has a fixed Close header, window-scoped Escape, backdrop dismissal and Save/Discard/Cancel. An edit does not disappear when a close is canceled. Isolated preview uses the same workspace with fixture data and no provider transport.

## Qualification ledger

- Full pre-change native suite passed; baseline server 349 files / 5,290 passed / 2 skipped.
- Compiled helper loopback checks: complete 65-row board, full task text/finish line/source, separate checked/agent state, exact meeting descriptor, bounded payload, private token/symlink checks and production-port exclusion passed.
- Native handoff suite: 14 groups passed. Actual separate-process lock test; v1-to-v2 journal migration; actual baseline reader refuses v2 without transport or journal mutation; persistent revision drafts and concurrent edit rejection.
- Native workspace/review contracts: passed uncapped inventory, domain-qualified identity, task/agent completion distinction, source revisions, replayed-review selection, capability failure, wrong-source response refusal and stale review handoff preflight.
- Server focused review/legacy-meeting suites: 40 passed. TypeScript passed.
- Server mutation gate: 6/6 killed (revision dedup, provider qualification, source checks, terminal revision fence, expired-job terminal recovery, optional-backend failure containment).
- Live synthetic Ollama canary: review completed with confirmed provider ownership, job/session identity and 940 characters of output. Re-review reused the exact job. Gateway process restart retained the exact review/output with no duplicate. No real meeting was submitted during this canary; its task reference list was empty.
- Native visual QA: domain selection; task detail; agent destination; focused-editor Escape; dirty Cancel retaining text; Discard; backdrop dismissal; older-meeting picker; Meetings detail → Work intake. No production task changes or real meeting review submission were made.
- Final source server run: 5,311 passed / 2 skipped / 1 pre-existing hook script subprocess failure (`status=null`, stdin-cap check). Focused hook rerun: 19/19 passed with no code change. Final clean full rerun passed: **351 files / 5,312 passed / 2 pre-existing skips**. The earlier failure is retained in this ledger.
- Native full suite exposed a stale source-layout assertion after extracting the Activity body. The invariant was repointed at the extracted content without removing the clipping check. The final complete native suite passed, including helper self-tests, secret boundaries, mutation checks and macOS 14 builds.
- Native final candidate compiles/signature verifies/ZIP integrity passes: 0.1.6/build7. Artifact is locally ad-hoc signed, not notarized for public distribution.
- Final dark/native compact QA at 763pt width: adaptive list/detail navigation, prompt retention, explicit sample handoff, result/session/backlink and unchanged task completion passed. Synthetic provider transport only. Actual app restart retained prompt, destination, result and session backlink.

## QA fixes before delivery

Cross-review found and fixed stale review readiness, wrong-meeting response selection, same-ID review reopening, capture draft loss, journal admission validation, optional-feature startup failures and source-outage recovery after query-job expiration. Existing compiler deprecation warnings are unchanged.

## Rollback and rollout

This is a local QA candidate. The candidate is ready for Miles’s QA. Public distribution still needs the normal signing/notarization/release train. Review capability is enabled explicitly by `COS_WORK_REVIEWS_ENABLED=1` on the candidate server. Default installed behavior stays off. The development launcher can qualify the real review runtime on a private loopback service with Ollama while leaving the installed server unchanged; it is not a portable public installer.

Journal v2 preserves receipts and adds drafts. An old binary refuses it safely. Do not automatically restore a pre-upgrade journal after sending new work: that would erase receipt/duplicate fences. Preserve and reconcile newer history before a downgrade. Baseline release and tag `cos-control2-baseline-2026-09-27` remain available.

Automatic post-sync review/preparation, semantic context retrieval across memories/threads, verified approval-to-publication, and broad live provider-tier qualification remain separate gates. This candidate does not claim them.
