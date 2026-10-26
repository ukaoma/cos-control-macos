# Control 0.5.348 / build 402 release QA

Status: IN PROGRESS. Not signed, installed, or published.

## Scope

Sessions Usage over the 0.5.345 dictation QA baseline (4570a8d), with the tested pet compatibility commit990ef13 only. No artwork changes, server code changes, recording activity, transcription/cue flag changes, or keyboard automation. Server6.92.0 is already published and installed by its release owner.

The current0.5.345 release proceeds separately. Shared release coordination reserves348/build402 for Usage. This branch must not publish until the current release owner releases the appcast/site and this candidate passes its own gates.

## Review findings and fixes

- BLOCKER resolved in source; regression execution pending: a pass budget ending before a row newline marked the source as waiting for append. A complete but unchanged file then never imported. A budget cutoff now stays pending and retries from the row start.
- BLOCKER resolved in source; regression execution pending: a row larger than8MiB blocked every later record. The importer now skips the oversized row incrementally, persists its skip state across restarts, and reports a coverage gap. It never stores the row text.
- Version integration: WaveA pins assumed345 would always be current. They now require matching current plist/notes/changelog, a nonregressing version/build, preserved345 release notes and server pairing. All24 source mutants passed after the adaptation.
- Historical view: All history selects lifetime available totals and model ranking; monthly history charts show the trend. Earliest/latest evidence dates, partial backfill and unknown-cost records are visible.
- Privacy: fixture checks inspect both SQLite and WAL for the prompt sentinel; production import stores counts/identities/checkpoints only. Source session files are read-only.
- Persistence: optional large-row checkpoint state preserves prior checkpoints. Same-size rewritten files are rescanned; event identities deduplicate repeat imports. Deleted source logs leave the ledger intact.

## Gates

- Original345 baseline: fullsuite3 exit0,2213s at4570a8d. This is inherited evidence, not a substitute for the merged full suite.
- Registry692: downloaded package integrity matches npm metadata and bytes equal the release candidate (4,682,265bytes).
- Source desktop-safety scan: passed; no native input/window automation.
- Usage fixtures: pending on final candidate.
- Complete Tests/run.sh, including run-mac-dictation, run-voice-style and run-dictation-parity: pending compiler handoff.
- Native offscreen month/history renders at800/1200points in light/dark: pending final candidate.
- Bounded real-log canary and packaged-helper private-home contract: pending final candidate.
- DeveloperID signing, notarization, extracted artifact and served-byte checks: pending.

## Limits to preserve in release copy

This is local recorded usage, not provider-account billing or subscription-limit reporting. Claude Code and Codex local logs are supported; Cursor, browser-only chats, other Macs and unrecorded calls are not. Missing historical logs cannot be reconstructed. Large rows skipped during bounded import create visible gaps. Model prices use the verified October25 snapshot across all dates, with unknown models left unpriced. No clean physical second-Mac test or interactive typing test is claimed. Tests stay terminal/offscreen because the user reported duplicated keystrokes from Computer Use.
