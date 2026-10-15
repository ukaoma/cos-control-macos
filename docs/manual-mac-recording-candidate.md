# Manual Mac recording and Work delivery recovery

Task: `task:personal:ce1f04b2f016`.

Implementation branches:
- Control: `codex/manual-mac-recording-20261014`, based on `df2ad0d`.
- Server: `codex/mac-capture-contract-20261014`, based on `b8d37d5` (6.73.5).

This is an isolated, uninstalled candidate. Preserve the current COS theme and navigation. Targeted Voice status corrections now display the selected/effective Parakeet engines instead of the old Whisper tier installer. Other onboarding work is untouched. Automatic detection, microphone recording, publishing, and existing transcription/cue feature-flag changes are outside this slice. Glasses pairing is not required.

## Validation decision

Three independent source reviews found the design feasible with prerequisites: atomic strict speaker policy before audio, durable Mac provenance throughout save/recovery/context, and an independent Mac transport that does not enable the iPhone candidate flag. The implementation addresses those prerequisites. Native process-tap API signatures compile against this Mac's SDK and the existing macOS 14.0 deployment target; runtime tap use is availability-guarded to 14.2. Apple describes process taps in [Capturing system audio](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

Compile-only validation does not prove macOS recording permission or audio quality. Signed-host permission, actual process playback, route changes, and full lifecycle checks below remain promotion gates. Full two-sided meeting recording requires microphone capture, clock alignment and echo/double-talk qualification in a later slice.

## Recording contract

Meetings → Record on Mac → Set up recording. Select an app currently playing audio, enter a title, and click Start recording. A confirmation explains scope and participant awareness; only then may the native host create its private unmuted tap. No system output device is replaced. Browser process selection may include audio unrelated to a meeting in that selected process; it is not tab-specific.

The server registers `mac_<uuid>` with immutable `mac_system_audio` provenance and high-confidence speaker policy before accepting audio. Identity uses the existing 0.88 similarity floor and minimum isolated speech requirements; it is not a calibrated probability. Strict capture skips automatic voice training. The selected transcription model follows existing meeting settings.

The native callback copies into bounded memory. A utility queue converts mono Float32 audio to canonical mono PCM16/16 kHz WAV, in six-second chunks. The pilot stops on overflow, unsupported format, no audio buffers, low disk space, sleep/session switch, setup cancellation or the two-hour bound. Stop drains local audio before saving; quit defers for local flush rather than network/ASR.

Audio and journals are private local files in `~/cos-data/mac-recordings/<captureId>/`. Original chunks remain after acknowledgement and save during this pilot; automatic retention cleanup is not implemented. Restart exposes retained recordings for explicit upload recovery, never resumes the tap. Uploads and save are pinned to the original server instance; a changed instance requires investigation rather than silently transferring audio to another process. Damaged journals and orphan WAVs are retained and surfaced for inspection.

## Work recovery contract

The screenshot's diagnosis assignment was locally `Not sent`: the existing task-wide fence blocked it before a delivery receipt was created. The original onboarding receipt said provider accepted, waiting for receipt. That state is not proof that the requested instruction was delivered.

Read-only diagnosis found that original provider process timed out and was reaped after approximately 21 minutes. Its recorded delivery outcome is now unknown/ambiguous. The exact native onboarding chat reports verified idle and contains recent productive build/test replies, but these do not establish receipt of this particular instruction. No real request was retried or cleared during this implementation.

Choose another destination opens the existing Agent workspace editor. Choose another linked session, Fork, or New session; review the exact context/files/model/destination, then Confirm and send. Earlier pending receipts remain intact. Same-target ambiguous/in-flight Continue stays fenced. The new receipt records recovery lineage, and admission rechecks source revision and receipt snapshots under the journal lock. Native provider delivery checks still run. Claude's unavailable status does not imply idle or inability to accept a message. Nothing automatically forks or resends.

## Manual promotion gates

1. Build a matched signed candidate without replacing `/Applications/COS Control.app` or restarting the stable server. Start its server against disposable data/port with the existing transcription/cue flags off. Keep the candidate separate and return by quitting it; do not run two hosts against the same production recording.
2. Fresh and upgraded signed-host TCC: opening Meetings and Refresh apps requests no capture permission. Cancel Start produces no tap/audio. Deny permission produces an actionable error and no false saved receipt. Allow captures only the selected output app; microphone and glasses remain unused. Test macOS 14.0/14.1 graceful unavailability.
3. Play a known short speech fixture from the selected app. Check persistent red recording indicator and Stop from the menu panel. Stop during setup, normal playback, silence, permission revocation, app exit, audio-device change, sleep, user switch, lock and normal quit. No capture may restart after Stop or relaunch. Check retained partial audio and interruption wording.
4. Confirm one Mac-source saved meeting, exact transcript/context key, review audio, Ask/history, dropped meeting attachments, create/link task, and Work context. Existing G2/Fireflies identity, playback, recovery and merge behavior must pass. Mac is excluded from automatic G2/Fireflies merging for this pilot.
5. During a disposable recording, interrupt upload/save response and server availability. Retry must preserve sequence and exact immutable chunk bytes, reject gaps/conflicts and incomplete tails, and yield one canonical saved meeting. Test crash after WAV creation/journal update and after canonical commit/before finalization-job creation. Changed server-instance recovery remains deliberately held.
6. Work: a known local Not sent assignment opens recovery; Cancel creates no child/message. Confirm another linked Claude session and confirm an exact existing chat. Confirm Fork and verify one child and lineage. Lost child-first-turn response retains child instead of creating another. Same-target busy/unknown, changed context/files/revision, double-click and restart must produce no duplicate delivery. Use disposable sessions; do not resend the real onboarding request to test.
7. Observe actual preview/canonical word latency from audio start, speaker-name false positives, gaps and errors. The 30-second target is unproven for this new source until measured on the matched signed candidate. Leave existing feature flags disabled throughout.

No signed capture, real-session dispatch, installation or publication is implied by passing synthetic tests.

## Candidate verification

- Server commit `0ff5a23`: TypeScript typecheck and 247 tests across 12 files passed. Coverage includes HTTP registration/chunk/save/status/replay; completed ASR versus raw receipt; silence, gaps and missing tails; source restoration; strict speaker policy; G2/Fireflies store/merge/client-referee regressions. ASR/diarization are mocked.
- Control: full macOS 14-target Swift 6 typecheck passed. The native APIs are guarded to macOS 14.2. Existing unrelated compiler warnings remain.
- `Tests/run-mac-recording.sh`: 38 fixture checks passed, including shared Stop/quit flush, exact frame journal, restart, interruption, private storage and rejected links. No tap, microphone or permissions are accessed.
- `Tests/mac-recording-helper-checks.py`: 77 isolated helper/loopback checks passed.
- `Tests/run-meeting-ask.sh`: 150 checks passed, including Mac history/context and legacy key preservation.
- `Tests/run-work-session-hub.sh`: fake-provider recovery and session-hub canaries passed; native context typing measured 4.967 ms p95, zero workspace redraws and zero burst journal writes. Rendering was offscreen; no provider/app was contacted.
- `Tests/run-work-card-files.sh`: attachment, meeting-context, copy/drop, continuation/fork and file-boundary regressions passed.
- Desktop-safety checks, card-files wiring pins, plist validation and whitespace checks passed.

The new core and helper checks are included in the standard test runner, which was not rerun wholesale. Targeted suites above were run separately under the machine-wide bounded compile guard.

Final read-only live-health comparison: stable server remains 6.73.5, same server instance, `features.iphoneAsrCandidates=false`, `features.liveCues=false`, and cue capability is unavailable because the master flag is off. Only the existing `/Applications/COS Control.app` host was running. No candidate was installed or launched.

Known pilot limits: system playback only; no microphone/AEC or automatic detection; raw audio retained without automatic cleanup; all-silence save keeps the server's existing `nothing_to_save` response. A changed server-instance ID deliberately holds pending audio rather than rebinding automatically; recovery after a server restart needs an explicit reconciliation design before general release. Actual speech-to-text latency, including the prior 30-second target, is unmeasured for this source.


## October 14 signed-canary follow-up (supersedes earlier candidate status)

- Server `d3a38e2` keeps Mac canonical transcription on the stored HQ selection (Parakeet Ultra here), with typed retryable errors and retained chunks instead of a silent Whisper/cloud substitution. Full regression completed: 452 files, 6,935 tests passed, two skipped; TypeScript typecheck passed.
- Isolated real-ASR HTTP qualification passed three generated-speech chunks through Parakeet Ultra, with `server-parakeet` / `fluidaudio-coreml` receipts and one Mac-source save. This is transport/ASR evidence, not native process-tap evidence.
- Signed Control 0.5.300 passed notarization/Gatekeeper and showed the corrected Voice setup row, but native recording failed before capture. Both user-selected sources returned HTTP 400 `invalid_mac_capture`: the native timestamp contained fractional milliseconds while the server required a safe integer. The earlier generic retained-recording message was therefore wrong for a rejected start. No tap or spool was created.
- Control 0.5.301/build 354 rounds the native timestamp down and normalizes older clients' valid timestamps in the helper. Nonfinite/Boolean/out-of-range timestamps remain rejected. Rejected registration now explicitly reports that no audio was captured. Regression tests cover fractional timestamps, bounds, and the no-audio error.
- Modern Voice status now observes refreshes in the menu panel, distinguishes selected from effective preview, keeps Nemotron readiness independent of Whisper, and preserves bounded per-lane failure reasons from the helper. Independent read-only review found no further blocker in these fixes.
- Final Control full suite is running on frozen source. 0.5.301 has not yet been packaged or installed. Actual signed process-tap capture, permission behavior, and matched installation remain gates. Do not install superseded 0.5.299/0.5.300 artifacts.
- Private canary uses disposable data on loopback port 13141. The stable 6.73.5 server has not been replaced. Both `COS_IOS_ASR_CANDIDATES` and `COS_LIVE_CUES` stay disabled. No public publication or pet recording notification is included.
