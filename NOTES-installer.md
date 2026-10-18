# Release notes for the installer escalation (branch claude/control-installer-escalation)

For the release that merges this branch with claude/control-live-cues-toggle (0.5.322). Nothing here bumps the version
or edits Info.plist, CHANGELOG.md or Resources/WhatsNew.json; the release copies the text below into them.

## CHANGELOG.md (under the release's heading)

The in-app update can no longer strand COS Control on Installing, whatever blocks its quit (Miles, 2026-10-17: field
users found the stuck Installing window a very bad experience). 0.5.320 fixed the known cause; this makes any future
quit blocker recoverable without Force Quit.

- The detached swap (`apply-app-update --swap`) waits 20 s for Control to quit normally. If Control is still running, it
  reads the Mac recording state Control writes, `~/Library/Application Support/COS Control/mac-capture-state.json`
  (phase, PID, time; written at launch and on every phase change, atomically, owner only, class C file protection).
  When that record names the one live process and a quiet phase (idle, saved, pending, recovering), the swap sends
  SIGTERM to exactly the live bundle's processes, waits up to 10 s, sends SIGKILL to any survivor, waits up to 5 s, then
  installs and reopens the new build as before. success.json records `forcedQuit` (and `forcedSignals`, `forcedPids`).
- Only the live bundle's own processes are ever signalled: `lsof -t` on its executable, kept only when the process's own
  executable is that file (proc_pidpath, same device and inode). A process that merely has the file open is ignored,
  and every signal re-checks the PID's start time and executable first, so a reused PID is never signalled.
- A Mac recording that is starting, recording or stopping is never killed: the swap writes last-failure.json with reason
  `recording`, reopens nothing (Control is still open) and Control shows "A Mac recording is running, so nothing was
  installed. Finish the Mac recording, then choose Try again." A record that is missing, unreadable or names another
  process signals nothing: the swap waits the old minute and gives up with `quitTimeout`. After giving up it watches
  10 s more: if Control finishes quitting by itself, it installs rather than leave Control closed.
- Control ends the install at once when the swap records `recording` or `quitTimeout` (instead of at the 75 s deadline,
  which stays as the fallback). While applying, the banner and the What's New footer say "Closing COS Control…" (or
  that the Mac recording saves first); then Control is gone and the new build opens.
- At launch, when updates/pending.json names a newer staged build that passes the swap's checks (signature, bundle id,
  version, build) and the last install stopped on `quitTimeout` or `recording` in the last 30 minutes, with no
  successful install since, the banner offers "Finish installing <version>" with Install: one click applies the staged
  build through the same apply path, with no download. A feed that cannot be read, or that still offers that build,
  keeps the offer; a newer build or no update replaces it. The helper's new read-only `staged-app-update` reports the
  facts; `app-update-quit-safety` reports what the swap would decide now.
- The escalation runs in the swapper copied from the running build, so it applies to updates installed FROM this build
  on. The hop to this build still runs the previous build's swap (60 s, no forced quit); 0.5.320 already removed the
  quit stall it was waiting on.
- Tests: Tests/app-update-escalation-checks.py (real helper, dummy signed apps, a disposable home per case; a live
  stand-in, Tests/fixtures/app-update/live-app.c, that never quits): ignoring its quit and SIGTERM it is ended by
  SIGKILL after SIGTERM, dying on SIGTERM it is replaced without SIGKILL, each recording phase blocks every signal and
  records `recording`, an unreadable state signals nothing, a copy of the binary elsewhere, a process holding the live
  executable open and an unrelated sleep are asserted alive and unsignalled by PID, the linger installs a late quit, and
  `staged-app-update` is read only and checks the stage. Tests/run-app-update-finish.sh (the whole app as a bundle's own
  executable): the launch offer, one click with no download, the install ending on the swap's record (never on busy or an
  older record), and the state this process writes read by the real helper. Pure checks in AppUpdateBadgeChecks and
  MacRecordingChecks; the helper self-test pins the production timings (20, 10, 5, 60, 10 s) and the signal re-check.
  Tests/mutate-app-update-escalation.py mutates each new guard on a green baseline.

## Resources/WhatsNew.json

Summary sentence (lead the release summary with it, or append it):

Updates can no longer get stuck on Installing. If COS Control does not close by itself, the update closes it for you and
reopens the new version, except while a Mac recording runs: then it says so, and you choose Try again when the recording
is done. If an update was interrupted, COS Control offers to finish installing it, with nothing to download again.

Section items:

- If COS Control does not close for an update within 20 seconds, the update closes it and reopens the new version. You no longer need Force Quit.
- A Mac recording is never cut off: the update stops, says "Finish the Mac recording, then choose Try again", and installs nothing until you do.
- While it installs, the window says "Closing COS Control…", then the new version opens.
- If an update could not close COS Control, the next launch offers Finish installing, with nothing to download again.
