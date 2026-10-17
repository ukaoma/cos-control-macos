# COS Control 0.5.317: dictation for everyone (Control side)

Branch `feat/dictation-everyone`, based on `release/0.5.317` (speedup 2532117, slot lock 14a242d). Pairs with glasses
server 6.74.0. Old servers (6.73.14) keep the 0.5.316 Parakeet-only path. Nothing was published, pushed to main,
notarized or installed.

## What changed

| Area | Change |
|---|---|
| Gate | `DictationBridge` (HelperSources/ProviderStatusCore.swift). `requiredEngine=local` only when `desktopDictationVersions` contains 2. `desktopDictationVersion` must still be 1, because the 0.5.316 helper requires exactly 1. A boolean or string 2 does not count. |
| Dictation | Any local engine (`parakeet-ultra`, `whisper`) is accepted; the hard `engine == "parakeet-ultra"` check is gone from Sources/MacDictation.swift. `engine` and `fallbackReason` are stored with each dictation and shown in the history detail. Old history files load unchanged. |
| Errors | One action per failure (`DictationFailureAction`): Install Parakeet (654 MB), Use Whisper, Retry (only with held audio and `retryable` true), Open Transcription settings (COS's own card, never macOS Privacy). The server's one-line sentence is shown when it sends one. |
| Settings | A Dictation engine dropdown (Automatic, Parakeet Ultra, Whisper), shown only on 6.74.0. The Parakeet row always gives a reason and an action: install, progress with Cancel (DELETE), Check again (untrusted tool, low disk), Use Whisper (Parakeet chosen but not installable), or the server's note. A Licenses link opens About. |
| Install | One store, offered in Settings, the menu bar panel, the failure card and the setup guide. The bundled tool's path goes on stdin with `allowDownload`. Free disk is checked against 1.5 GB before the POST. 507 and 422 answers say why. The tool is registered once per launch (POST .../parakeet/cli). |
| Bundled CLI | `scripts/build-fluidaudio-cli.sh` builds FluidAudio v0.17.4 (commit 21493f8d, Apache-2.0) and links an Info.plist (`com.gotcos.control.fluidaudiocli`, 0.17.4, commit). Pinned in `Resources/fluidaudio-cli.json` (SHA 9ffe468a…, 22,040,592 bytes). `build-release.sh`: refuses other bytes, places it in Contents/Helpers, signs it standalone (hardened runtime, timestamp, identifier) before the app, refuses a Developer ID release without it, and verifies a COPY outside the extracted app (strict, Info.plist bound, runtime, team NV3X46LLCR). It carries no entitlements (checked). Licenses: Resources/ThirdParty/FluidAudio, THIRD_PARTY_NOTICES.md, Resources/Credits.html (Parakeet Ultra model credit, CC BY 4.0). |
| Onboarding | A Dictation engine step after Voice: the recommendation (Parakeet on Apple silicon unless memory under 8 GB or the test says otherwise), a dropdown pick (no pill tabs), install in the background, and Test on this Mac (server benchmark route; speed, words wrong out of 58, Parakeet memory, its first start as a one-time cost). It says it is one sample, not a full accuracy test. |
| Voice row | Green only with proof: a dictation that transcribed on this server version, or `dictation-check` (the pinned sample through the same `dictate()` path as a dictation). Until then it shows Checking, muted, while one background check runs: once per server version, never during a recording, never on a timer. A failed check is amber with its reason and Test again. A proven row is byte-identical to before. |
| Accuracy | `Resources/VoiceBenchmark/speech-30s.txt`, 58 words, SHA pinned. It is jfk.wav twice plus its first 8.000 s, cut in a pause. Turbo transcribed it exactly; a human listen is still pending. WER: lowercase, punctuation stripped, on both sides. The voice-setup Whisper test also records `wordErrorRate`. |

## Proof (all run on this Mac, one compile at a time)

| Lane | Result |
|---|---|
| run-dictation-everyone.sh (helper core, CLI checker self-test, entitlement self-test, pins) | PASS, 64 checks |
| run-transcription-settings.sh | PASS, 108 checks |
| run-provider-connect.sh | PASS, 508 checks + provider-status 101 + pins |
| run-mac-dictation.sh (includes the lane above) | PASS, 418 checks + sound runtime + quiet typecheck + isolation pins + dictation-wispr 282 |
| Helper (one compile): mac-dictation 43, dictation-everyone 48, transcription-settings 43, self-test 821, provider-status, dictionary 94 | PASS |
| Render, light and dark (run-transcription-settings-render.sh) | 18 new states, 36 PNGs in /Users/ukaoma/cos-release-candidates/control-0.5.317/renders/. Four defects from my review fixed, then the main session's review: engine results as one row per engine in two columns, Test again as a real button, Licenses as an aligned link, Automatic on Whisper neutral. |
| Mutation: Tests/mutate-dictation-everyone.py, 53 mutants, 7 lanes, green baseline first | 53 of 53 killed by the named check (49 of 50 in the full run; one was killed by an earlier check that also pins allowDownload, then renamed and re-run alone; after the render review the connect lane was re-run: 12 of 12, including 4 new mutants for the result rows and the calm status) |
| No-compile mutants (pins, release self-tests) | included in the 50 |
| fluidaudiocli build (step 8) | PASS, 150 s, plist PASS |
| fluidaudiocli comparison (step 9) | help, usage and exit codes identical to the local 0.17.4 build; the transcript and word timings on an 8 s WAV are identical. Peak RSS: cold 677 MB, warm 86 MB. |

Not run: the full suite (main session), a signed and notarized build, a real fresh-Mac onboarding, and a real dictation
against server 6.74.0 on this Mac.

## Found along the way

- **Old Control breaks on a v2 capability:** the 0.5.316 helper requires `desktopDictationVersion == 1`, so the server kept 1 and added the list.
- **fluidaudiocli has no version command:** `--version` exits 1 with "Unknown command". Hence the embedded Info.plist.
- **zsh history modifier:** the build script's `$VERSION:` was read as a `:r` modifier. It is braced now.
- **Two pre-existing bugs in base MacDictationChecks** (from dictation-fix):
  - `english` was declared twice in one scope, so the file did not compile.
  - The day-29 and day-30 dismissal clauses stamped their suggestions at day 0, which the 7-day prune removes. Day 30 failed, and day 29 could not fail. Both are fixed in the test only. The new `mutate-mac-dictation-core.py` mutant "dismissal lasts 29 days" survives the old test and is killed by the fixed one (both run by hand).
- **Render findings, all fixed:**
  - "Automatic (recommended)" was truncated in Settings; the face there now reads Automatic.
  - The engine step drew Install twice.
  - The Voice row showed the tier tabs while only dictation's proof was pending.
  - An untested (not installed) Parakeet read as "did not run".
- **Helper accepted `cliPath: 7`:** a non-string cliPath silently dropped the path. It is now refused before the network.
- **Compile overlap:** once, one swift-frontend from another process was running when I started provider-connect. The compile guard's lock serialized them. After that, every compile waited for an idle compiler first.

## Files

The Sources, HelperSources, Tests and scripts named above, plus Resources (WhatsNew.json "Dictation for everyone"
section, VoiceBenchmark reference, fluidaudio-cli.json, ThirdParty/FluidAudio, Credits.html), CHANGELOG.md and
THIRD_PARTY_NOTICES.md. The built CLI is at dist/fluidaudio-cli/ (untracked; the release build reads it there or from
COS_FLUIDAUDIO_CLI).
