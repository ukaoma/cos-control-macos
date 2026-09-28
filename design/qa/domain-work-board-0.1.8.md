# Domain Work board — 0.1.8 qualification

Local candidate. The installed Control app, installed server and glasses package remain unchanged.

## User test path

1. Open the 0.1.8 connected launcher. In Work, choose a domain. Verify Mentioned, Planned, Draft, Built, QA and Complete; scroll horizontally for later columns on a small window. Search should filter cards within that domain.
2. Open a card. Confirm its goal, source, activity and existing Continue/Fork/New session controls. Return to the domain board using Back. The card stage menu makes an explicit task change; it does not dispatch an agent.
3. Use a disposable task to move through phases. Complete must check the original task; moving back to another phase must reopen it. Refresh/relaunch and verify persistence. Existing glasses stage remains planning/active/review.
4. Choose Link a meeting on that task. Select the exact saved meeting. Open the meeting from the card; its related Work section should show the same task/stage. Open the task again from there. The fixed footer also offers Review follow-up in Work.
5. If the task or meeting review has a recorded handoff, inspect its associated session and return to the correct Work item. Agent output remains separate from task completion. An unavailable session or source should show an honest status rather than open a similarly named item.
6. In the isolated preview, choose Website for six sample lanes and use source links to test the shared Meeting view without live calls. Sample stage moves reset when the preview closes.

## Evidence

- Canonical Python targeted suite: 79 passed; 13 historical live-corpus snapshot checks excluded. Their fixed counts/fixture assumptions predate this change. An independent old/new parser comparison on an unchanged disposable copy of the current corpus preserved all 313 task rows' IDs, text, checks and legacy stages.
- Old reader/writer canary: four source layouts, 28 baseline writes. Metadata and legacy identity preserved; canonical rename preserves stable Work identity.
- Actual HTTP → canonical Python writer canary: 12 checks passed. Six phases, atomic completion/reopen, stale-write refusal, exact meeting resolution, wrong-meeting refusal, rename continuity and restart durability. All mutations targeted scratch task/profile/data/lock roots.
- Full server suite: 352 files passed; 5,321 tests passed, two existing skips. Typecheck and compiled helper transport fixtures passed.
- Config packager export/import checks passed. Its one-hop dependency audit still reports nine unrelated missing imports; the identical list was reproduced against baseline 6117b014. The new metadata module is included in the export manifest.
- Native focused Work suite passed. The full native runner compiled both helper and app and passed its regression prefix; its route assertion was updated to follow the extracted, still-gated Meeting detail surface. Re-running the complete remaining source-contract tail passed.
- Actual native UI verified at 1800px and 760px: six lanes, explicit stage change, source meeting round-trip, simulated running session, Meeting → Session → originating Work navigation, and horizontal access to QA/Complete.
- Connected candidate read 202 current board tasks with capability version 1 and writes enabled. Sprocket Rocket displayed 95 cards (9 Planned, 86 Complete). Meeting linking picker and cancel worked; no real task or agent was changed. The launcher pins the qualified canonical scripts path because the installed environment does not declare it.

## Deliberate limits

Legacy source labels are not silently matched to meeting titles. Use explicit linking; current review suggestions remain suggestions. Existing session associations require actual receipts. This build does not implement automatic confidence-based preparation or replace Threads. No glasses EHPK change is needed for these additive Mac capabilities.

Rollback preserves task data and IDs. Old clients can express only the three legacy stages; a same-bucket round trip through an old writer can retain its earlier fine phase. Older writers also cannot seed stable Work identity before a first rename. No board phase confers execution or publication authority.

## QA findings resolved

- Healthy helper responses emitted an empty error string and disabled all stage actions: omit absent errors and normalize empty values; regression fixture added.
- Task renames detached session history: persist original Work identity while retaining canonical task hashes.
- Board → meeting had no return selection: preserve domain-board origin separately from an optional selected card.
- Meeting → session could retain another task's backlink: carry both recorded session and Work identity.
- Reads overlapping mutations could leave stale cards: forced, fenced post-write inventory refresh.
- Freeform capture/text could inject Source or Done-when structure: reserve those delimiters and metadata syntax in the canonical writer.
