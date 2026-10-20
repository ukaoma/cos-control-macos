# 0.5.329 AI polish started at the key press: notes to merge

Branch `claude/polish-prewarm-0329` (from origin/release/0.5.328 fbda6ae). No version bump. Needs server 6.79.2
(`cos-glasses-server` claude/polish-speed); an older server answers 404 and nothing changes.

## CHANGELOG section

### AI polish starts when you press

Polish was 1.8 to 4.1 s with Haiku, most of it Claude starting up. With AI polish on, COS now asks the server to start
that process the moment the dictation key goes down. When the text arrives, the polish names it and the server uses it.
Measured server-side on Miles's Mac: about 0.9 s off a Haiku polish whose process started 3 s or more before the text.

- Fire and forget, off the main thread: a detached task calls the helper's new `dictation-polish-prewarm` command
  (token file only, 2 s deadline, `{"model"}` in, never any text). Nothing waits on it at the press or at LISTENING.
- The polish takes the token if this press's start has answered (waiting at most 150 ms more), and sends it with the
  text as `prewarmToken`. A token for another model (the setting changed mid-hold) or one that answered late is
  discarded, never reused.
- Every way a dictation ends without polishing (cancel, a failure, no speech, too short, AI polish off) discards its token
  through the helper (`DELETE`), off the main thread; the server's 150 s limit cleans up anything else. finish() never
  discards, so a new press during delivery keeps its own token.
- An older server (404) is not asked again until its version changes. A 409 (disabled, model, breaker open, daily cap, no
  CLI), a timeout or no server changes nothing: the polish runs cold exactly as before.
- Timing line: `polishPrewarm` (used, missed, discarded, or none when no token went with the polish) and `prewarmMs` (how
  long the start took). `clean` is a polish skip code now (server 6.79.2).
- Tests: helper core (token parse and drop, finalize body, the prewarm outcome, start, refusals, discard), the compiled
  helper against a loopback server (start, 409 reasons, 404 unsupported, the 2 s deadline, DELETE, bad input never sent),
  Control core (when to start, read, outcome, request, the line), wiring pins, and the start canary's early-polish stall
  round.

## What's New sentence

With AI polish on, Claude starts getting ready the moment you press the dictation key, so polished text lands about a
second sooner.
