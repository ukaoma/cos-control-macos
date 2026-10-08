# COS Control 0.5.273 release qualification

Control 0.5.273 (326), source c9fc636; paired server 6.66.0, source d836219.

## Artifact and installed upgrade

- Final ZIP: 117,112,881 bytes; SHA-256 `fd378e6fc1973ee2e81c70b1e942b0c2dcab58e295c7be4d56625ab5676fbb70`.
- Apple Accepted submission `f483d0a6-7e22-4341-b915-3c4989f24411`. Ticket stapled. Extracted archive and installed app pass deep/strict signing verification and Gatekeeper as Notarized Developer ID, Miles Ukaoma (NV3X46LLCR).
- Managed updater downloaded and verified the public HTTPS archive and replaced installed 0.5.270 (323) with 0.5.273 (326). Previous bundle retained for rollback.
- First updater handoff timed out while native UI automation reacquired/relaunched the old process. Retried through normal Quit without reacquiring; success receipt confirms build 326.
- Server PID 3478 stayed running through the app-only upgrade. Requested/effective tier remained Max, not degraded; no active server jobs or transcription sessions.

## Regression evidence

- Full server suite: 401 files, 6,220 passing tests, two existing skipped tests. Publication runner independently repeats the gates.
- Task editor: 200 edits, zero Activity/Work body evaluations and zero projections; p95 12.8 ms. Close protection, busy protection, failed-save retention and refresh isolation pass.
- Work resize: 71 steps, zero projection rebuilds; two body/board evaluations. Data changes each rebuild once.
- Packaged Node/npm: Finder PATH, isolated home, idempotent retry and relocated helper pass. Release entitlements pass; frozen helper self-test passes.
- Exact packaged helper: signed runtime first/repeat installation, no Homebrew dylibs, interrupted snapshot restores Max, benchmark preserves Max, cancel stops process group, corrupt archive refused before extraction.
- Real server package with bundled Node: new-user voice preparation, managed binary resolution and live/preview imports pass; signed whisper-server returns actual text for a 30-second WAV over the HTTP inference contract.
- M3 Ultra, 96 GiB: 1.103 seconds Whisper engine / 1.334 seconds wall for the 30-second Turbo sample; RTF 0.0368; recommends Max. This is a speed workload, not a transcription quality evaluation or smaller-Mac calibration.
- Website: 39 version-checker unit tests and four Node contract suites pass. Mobile Control installation page has width 390 at viewport 390 with no horizontal overflow. Mac-first wizard and desktop installation layout reviewed.

## Limits and separate follow-up

A disposable-home package canary is not a physical clean-Mac/clean-account test, nor does it exercise all privacy prompts. The smaller-Mac recommendation threshold remains provisional. G2 619 physical acceptance and the missing Memory-alignment reproduction remain separate. No blanket claim of zero regressions.

Full local logs and machine-readable receipt: `dist/public-273/qa-logs/` and `dist/public-273/release-receipt.json`.
