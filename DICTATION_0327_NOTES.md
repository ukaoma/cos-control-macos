# 0.5.327 dictation start: notes to merge

Branch `claude/dictation-start-0327` (base d12f5f5, 0.5.326). No version bump here: merge the CHANGELOG section and
the What's New sentence below into 0.5.327 (build 380) alongside `claude/cue-verdicts-0327`.

## CHANGELOG section (paste under 0.5.327)

### Dictation listens when it says it does

Miles, 2026-10-19: "when I click the dictation, the sound immediately happens, which makes me think it's starting to
record at that time. But if I look at the pet, it doesn't really start listening until like a second or so in. So the
first second or two ... is getting cut off."

- Cause: the press played the start sound and showed LISTENING at once, but the microphone's first buffer came later.
  Before the microphone opened, the press played the sound, built the mute (a process tap plus a private aggregate
  device, started on the main actor), read the whole microphone list and built a new AVAudioEngine. Measured on
  Miles's Mac (AT2020USB+, 2026-10-19, under build load): a new engine and its input node took 88 to 707 ms (about 3 s
  the first time in a process), starting it 40 to 100 ms, the first buffer about 100 ms after that, the list read 2 to
  80 ms, and the mute's aggregate device alone 38 to 630 ms. Audio is captured only from the first buffer, so words said
  after the sound and before it were lost.
- STARTING: the pill now shows STARTING (an open ring, no bars, no clock) from the press until the microphone's first
  buffer arrives. Only then does it say LISTENING and play the start sound, so both tell the truth. If no buffer comes
  within 3 seconds, or the microphone fails while starting, the microphone is closed and the card says so.
- Shorter gap: the press no longer reads the microphone list when no microphone is chosen (the system default opens
  directly). A chosen microphone opens from its cached id after one property read confirms the id still belongs to it;
  only otherwise is the list read. The list is refreshed off the main actor after listening begins.
- The mute is built after the first buffer, right after the start sound is scheduled, so building it never delays the
  first words. Starting the mute's aggregate device under a running microphone caused no engine configuration change
  in three runs on Miles's Mac (a private aggregate on his output, without the tap, which needs his permission).
- A spare engine: after each dictation (and 5 s after launch) COS builds the next dictation's engine and input node,
  never prepared or started, so the press only starts it. The microphone is never running while it waits (checked with
  the process's own input-running flag, the one behind the orange indicator). It is used only when the input device, the
  microphone choice and the device's sample rate are unchanged, it is under 30 minutes old, and the input is not
  Bluetooth (no spare is ever built for a Bluetooth input, so a headset is never switched to its call profile while
  idle). A spare that will not start gives way to a fresh engine on the same press.
- The start sound is still not trimmed. It now sits at the very start of the recording, before the speech it invites.
  Through the real engine (Parakeet Ultra), the pinned voice sample with each of the nine bundled start sounds (and
  Miles's own) mixed in at its front, at 60% and at full volume, heard the same 22 of 22 words with nothing extra
  before them, both after the sound and talking over it.
- Timing, numbers and codes only, on the existing dictation-timing.jsonl line: pressToTaskMs, permissionMs,
  refreshMicsMs, micListRead, warmEngine, engineStartMs, pressToFirstBufferMs (the audio side's own stamp), pressToSoundMs,
  quietMs, and failReason on a failed dictation (mic_denied, mic_missing, engine_start, no_first_buffer, mic_failed,
  too_short, not_connected, helper_timeout, helper_failed:<kind>, refused:<server reason code>, no_speech,
  engine_switch). A start that fails before capturing anything now writes its own line. A helper failure also records
  how long it ran (transcribeMs). Context: Miles's 9:19 dictation (10.7 s, failed) and a 0.6 s one at 10:16 have no
  engine and no transcribeMs, which on 0.5.326 means the helper call threw or the server was not connected; the
  failReason now says which.
- Release tail (0.5.326) unchanged.
- Tests: MacDictationChecks (truthful start: device choice, first-audio stamp, STARTING, spare rules, codes, the timing
  line; 19 mutants, each killed by a named check), Tests/dictation-start-pins.py (wiring; 14 mutants, each caught),
  Tests/run-dictation-start-canary.sh (by hand, real microphone: press to first buffer three ways, microphone off while a
  spare waits and after each stop), Tests/dictation-start-sound-canary.py (by hand, real engine: the start sound at the
  front of the recording costs no words; a speech-like "sound" makes it fail), Tests/dictation-start-timing.py (prints
  the start numbers from the timing file).

## What's New sentence (prepend to 0.5.327's summary)

Dictation now listens when it says it does: the pill says STARTING until your microphone is actually hearing you, then
LISTENING and the start sound come together, and the microphone opens faster, so your first words are no longer cut off.
