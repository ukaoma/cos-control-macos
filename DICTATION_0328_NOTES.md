# 0.5.328 dictation smooth start: notes to merge

Branch `claude/dictation-smooth-0328` (from origin/release/0.5.327). No version bump: merge the CHANGELOG section and the
What's New sentence below into 0.5.328.

## CHANGELOG section

### The pet keeps moving while dictation starts

Miles, 2026-10-19 on 0.5.327: "the animation stops as the new listening pill comes in."

- Cause: building the mute, starting the microphone engine and starting the start sound all ran on the main actor,
  which also draws the pet (a TimelineView) and the pill. Miles's timing lines: quietMs 1,103 to 2,173 ms, engineStartMs
  132 to 326 ms, the start sound 44 to 258 ms after the first buffer, so the pet froze for over a second right as
  LISTENING appeared. One press waited 1,052 ms before its own task ran: the main thread was already busy.
- Now: the mute (process tap, private aggregate device, start) and both sounds run in order on one serial output queue.
  Opening the microphone engine and building the spare run on a serial input queue. LISTENING is published before the
  sound and the mute are queued, and nothing on the main actor waits on them. The mute's fallback note and the times come
  back afterwards. Quit waits for the queued unmute or volume restore before exit.
- The pill's placement reads the focused app's window through Accessibility off the main thread. Learn from my edits
  now polls the other app off the main actor; its reads (several Accessibility calls, up to 0.25 s each when that app is
  busy, every 500 ms for up to three minutes) used to run on the main actor. That is the likeliest cause of the 1,052 ms
  press. The new editWatchAtPress and placementMs fields will confirm or rule it out.
- Unchanged: STARTING until the first buffer, then LISTENING and the start sound (no first words lost). The 0.5.326
  release tail and how the microphone closes are unchanged; stopping the engine stays where it was.
- If a press is released while its engine is still opening, the engine that opened is closed off the main actor, never
  left running.
- Timing line, numbers only: mainThreadStallMs (the longest gap in a 16 ms main-run-loop heartbeat from the press until
  three seconds after LISTENING, or until the microphone closes), quietBuildMs and quietStartMs (the mute's build and its
  AudioDeviceStart), placementMs, soundMs, editWatchAtPress, deliverMs (typing or copying the text, still on the main
  actor). pressToSoundMs is now when the sound was queued.
- Canary on Miles's Mac (Tests/run-dictation-start-canary.sh, real microphone): the main thread's longest stall while a
  dictation started, with the engine and a mute-like aggregate device on the main thread (the 0.5.327 way), median 589
  to 658 ms and up to 1,912 ms. With them on the queues (0.5.328): median 19 to 24 ms, at most 24 ms, against 16 ms when
  smooth. The stand-in has no tap, which needs System Audio Recording and would silence the Mac, so the field quietMs of
  1.1 to 2.2 s is worse than the stand-in.
- Tests: MacDictationChecks (stall meter, queue order, perform, the line; 7 mutants killed), Tests/dictation-smooth-pins.py
  (no Core Audio or engine setup on the main actor, placement and edit watch off main, heartbeat on every path, a census
  of the new off-main sites, no pet resize for the pill; 15 mutants killed). Existing pins updated where code moved
  (sound runtime check drives the player on its queue).

### A dictation with no speech no longer reads as a helper failure

Miles, 2026-10-19 19:02:06 UTC: a 4.1 s dictation failed with failReason helper_failed:command_failed.

- Cause: the COS server dropped that capture as empty. The server log has two "/transcribe: DROPPED (hallucination or
  empty): 0 chars" lines between his 50.2 s and 27.2 s dictations (matched by byte size), and the timing line shows
  finalDBFS -74 and tailDBFS -75, so the end of the capture was silent. The press had waited 1,052 ms for the main thread
  and 1,477 ms for the first buffer, so his first words were probably said before COS could hear. The helper answered
  correctly (exit 0, ok false, noSpeech). But HelperClient.run, since the MVP, turns every ok-false answer into
  commandFailed(message) and drops its details, so the dictation's refusal handling (noSpeech, the server's reason, the
  card's action) never ran. Control showed a failure card with Retry, which re-sent the same silent audio; the second
  DROPPED line fits that.
- Now: the dictation bridge asks the helper client for refusals (`answers: true`). A refusal comes back with its
  details: no speech is recorded as no_speech with no Retry, and any other refusal names the server's own reason code on
  the timing line as refused:<reason> (codes only, whitelisted). A helper that exits non-zero still throws. Every other
  helper caller is unchanged. AI polish has the same pattern and is left as it was.
- Tests: the helper transport contract adds a refusal fixture (thrown without answers, returned whole with them) and a
  non-zero exit (always thrown); 3 mutants of the guard each killed by a named check. Two pin mutants (the bridge, the
  forwarding) are killed by Tests/dictation-smooth-pins.py.

## What's New sentence

Your pet keeps moving while dictation starts: COS now sets up the microphone, the start sound and Mute other apps in
the background, so the pet and the listening pill stay smooth from the moment you press. A dictation that caught no
speech now says so, instead of reporting an error and offering a Retry that cannot help.
