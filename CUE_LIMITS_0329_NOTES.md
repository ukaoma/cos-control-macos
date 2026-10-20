# Live cue limits, notes for 0.5.329

## CHANGELOG section

### Live cue limits in Settings

Miles, 2026-10-19: cap live cue spend from COS Control. Needs COS server 6.79.2; an older server shows the Live cues
switch only, as before.

- Settings, Meeting assistant, under the Live cues switch:
  - Bar: a slider from 0.50 to 0.95 in steps of 0.05. Lower gives more cues, higher fewer.
  - Max cues per meeting: 1 to 25.
  - Minimum gap between cues: 20 seconds to 15 minutes, in stops such as 45 s and 1.5 min.
  - Daily writer limit: 1 to 500 writer calls a day.
  - "Today: N cues, N writer calls, ~NK tokens", the server's own count for the day.
- Each control uses the server's own minimum and maximum. A limit set in the server's .env shows its value with "Set in
  .env" and cannot be changed here.
- A change is sent 600 ms after the last move (a new move restarts the wait), all waiting changes in one call. The row
  says Saving until the server answers, then shows the values the server sent back, never the ones asked for. A change
  waits for a read in progress, and a move made while a save is out goes in its own call.
- When the server refuses a value, the row says why in the server's terms, such as "The server takes 1 to 25 there.", or
  that the limit is set in .env.
- Helper: `live-cues-settings` reads `GET /api/live-cues/v2/settings?v=2`; `--gate`, `--max-cues`, `--cooldown-seconds`
  and `--daily-writer-calls` post `{"v":2,...}` with the checked values, and `--set on|off` now posts
  `{"v":2,"enabled":...}` (accepted by every server since 6.76.2) so the limits stay on screen after the switch moves.
  Only the contract's keys cross back.
- Tests: live cues pins 80, checks 153, helper loopback checks 40 (one per 6.79.2 response shape), helper self-test 945,
  the Settings card drawn at 390 pt in light and dark (124 checks; the widest limit row is 288 of 334 pt). 53 live cue
  mutants, each killed by a named check.

## What's New sentence

Set how many live cues you get from Settings, Meeting assistant: the bar (lower for more cues, higher for fewer), the
most cues in a meeting, the shortest gap between two cues and a daily limit, with today's usage shown underneath; it
needs COS server 6.79.2.
