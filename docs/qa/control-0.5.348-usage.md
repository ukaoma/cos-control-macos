# Control 0.5.348 / build 402 release QA

Status: IN PROGRESS. Not signed, installed, or published.

## Scope

Sessions Usage over the 0.5.345 dictation QA baseline (4570a8d), with the tested pet compatibility commit990ef13. Approved illustrated artwork and the stock-pack upgrade are integrated from588fb1b (local796a5e4); the owner passed focused upgrade/39offscreen-render checks, and this candidate still requires its complete suite. No server code changes, recording activity, transcription/cue flag changes, or keyboard automation. Server6.92.0 is already published and installed by its release owner.

Control0.5.345 is live and installed; its owner released the appcast/site. Shared coordination reserves348/build402 for Usage. This candidate must pass its own gates before promotion.

## Review findings and fixes

- BLOCKER resolved in source; focused regression passed: a pass budget ending before a row newline marked the source as waiting for append. A complete but unchanged file then never imported. A budget cutoff now stays pending and retries from the row start.
- BLOCKER resolved in source; focused regression passed: a row larger than8MiB blocked every later record. The importer now skips the oversized row incrementally, persists its skip state across restarts, and reports a coverage gap. It never stores the row text.
- Version integration: WaveA pins assumed345 would always be current. They now require matching current plist/notes/changelog, a nonregressing version/build, preserved345 release notes and server pairing. All24 source mutants passed after the adaptation.
- Historical view: All history selects lifetime available totals and model ranking; monthly history charts show the trend. Earliest/latest evidence dates, partial backfill and unknown-cost records are visible.
- Privacy: fixture checks inspect both SQLite and WAL for the prompt sentinel; production import stores counts/identities/checkpoints only. Source session files are read-only.
- Persistence: optional large-row checkpoint state preserves prior checkpoints. Same-size rewritten files are rescanned; event identities deduplicate repeat imports. Deleted source logs leave the ledger intact.
- Attribution: Codex rows without provider metadata remain Unknown provider instead of being assumed to be OpenAI.
- BLOCKER found by the oversized-row restart test: SQLite's REAL-to-text conversion rounded modification timestamps, so unchanged files could repeatedly reset their cursors. Reading REAL columns through sqlite3_column_double preserves comparison precision. Focused fixtures pass after this correction; the large-row fixture pins a fractional modification timestamp to prevent recurrence.

## Gates

- Original345 baseline: fullsuite3 exit0,2213s at4570a8d. This is inherited evidence, not a substitute for the merged full suite.
- Registry692: downloaded package integrity matches npm metadata and bytes equal the release candidate (4,682,265bytes).
- Source desktop-safety scan: passed; no native input/window automation.
- Desktop-safety mutation self-test: passed (35 disallowed forms rejected, six allowed forms accepted).
- Pricing: standard API rates rechecked against official Anthropic and OpenAI documentation on October25; this remains a snapshot estimate, not actual billing.
- Usage fixtures: passed after the timestamp correction (compile.vKje8z); complete suite repeats the final fixture.
- Complete Tests/run.sh attempt1 stopped at the chart compiler complexity limit; typed accumulation loops corrected it (0b684cb). Attempt2 compiled app/helper and passed the preceding native lanes, then stopped at six illustrated-pack appearance checks (three transparency and three edge-frame findings). The pet owner supplied bounded effect metadata and pixel evidence in f595b0c (local602a0a0); attempt3 passed all41 strips and protected upgrade checks. It then stopped at the shared-control guard: Usage introduced six stock pickers and an unstyled tracking toggle. These now use COSDropdown, COSViewSwitch and COSCheckStyle. The isolated guard and15 banned-form mutations pass; the offscreen harness also applies the same root theme as Activity. A complete rerun remains required.
- Native offscreen month/history renders at800/1200points in light/dark: all eight generated successfully (compile.l7vASb); narrow/light and narrow/dark plus wide/light reviewed for legibility and no clipped controls. No windows were ordered or activated.
- Bounded real-log canary: two passes advanced checkpoints and added usage events without parse/read failures in the sampled files. Backfill remains partial and is labeled as such. Detailed aggregate evidence stays in the private candidate directory; source logs were read-only and the ledger was disposable. Packaged-helper private-home contract remains pending final signed artifact.
- DeveloperID signing, notarization, extracted artifact and served-byte checks: pending.

## Limits to preserve in release copy

This is local recorded usage, not provider-account billing or subscription-limit reporting. Claude Code and Codex local logs are supported; Cursor, browser-only chats, other Macs and unrecorded calls are not. Missing historical logs cannot be reconstructed. Large rows skipped during bounded import create visible gaps. Model prices use the verified October25 snapshot across all dates, with unknown models left unpriced. No clean physical second-Mac test or interactive typing test is claimed. Tests stay terminal/offscreen because the user reported duplicated keystrokes from Computer Use.
