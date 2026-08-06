# Changelog

## 0.5.0 (build 37)

- Hotfix: the speaking timeline drew an empty bar on a server older than
  6.21.18, under a heading, with "Hover the bar to see who is speaking"
  underneath — for a bar that was not there. The block is now hidden entirely,
  replaced by a line saying the timeline needs a newer server and to use Update
  Server.

## 0.5.0 (build 36)

- **Renaming a voice now corrects one meeting, not your whole history.** Until
  now the panel only ever called the global merge, so fixing one call rewrote
  every meeting that person appears in. A scope control sits above the name, set
  to "Just this meeting" by default, with "Every meeting" as an explicit choice.
- **Remove a voice that was not in the room.** There was no way to undo a wrong
  name — only to replace it with another. "Not in this meeting" un-attributes the
  voice and also retracts the training samples that meeting contributed to that
  person's profile, so the mistake stops reinforcing itself. It reports what it
  cannot reach: samples recorded before meeting-level provenance existed.
- **A name has to be earned before it is shown as a name.** The identifier
  accepts a match at 0.55, so a single segment could arrive wearing somebody's
  full name. Rows below the floor now read "Unidentified voice" with the closest
  match and the reason it did not qualify — 1 segment, or similarity 0.58, or it
  swaps with another voice every few segments.
- **Play the voice.** A speaker button plays what the stored profile sounds like,
  which settles an identity question faster than any score. Meeting audio is kept
  for a week, so a segment can be played back during review; after that the panel
  says the audio is no longer held rather than looking broken.
- **Play the line you are looking at.** Each quoted phrase gets a play button
  that plays that exact segment of the meeting, so you hear the voice before
  deciding who it was. The button appears only where the server still holds the
  audio, so a click never fails; after the seven-day window the row simply has no
  button. An earlier build played a stored profile sample instead, which does not
  exist for 71 of 77 profiles because training audio is deleted once enrolled.
- **You are no longer labelled "Unidentified voice" in your own meetings.** The
  wearer is verified at exactly the confidence floor, so any confusion between two
  voices flipped you below it — measured on four of nine recent meetings, one with
  285 of your own segments. The confusion warning still shows.
- **Removing several wrong names keeps those voices apart.** They become
  "Unidentified 1", "Unidentified 2" and so on rather than merging into one row,
  so you can still tell them apart and play each one back.
- **Saving now reports what actually happened.** A refused correction said
  "Removed X from this meeting" while the server changed nothing. If an earlier
  correction on that meeting never finished, there is now an "Apply anyway"
  button instead of a dead end.
- **The ribbon is a real timeline.** It used to draw one rectangle per voice sized
  by share of segments while labelled "who spoke, in order" — there was no
  ordering in it, and a voice that spoke twice appeared once. It now reads the
  server's spans, so widths are durations, a voice can appear more than once, and
  hovering says who is speaking at that point. Added a legend mapping each colour
  to a speaker, and hovering a legend entry finds that speaker on the bar. The bar
  aggregates into fixed columns so a long meeting fits: drawn one-rectangle-per-turn
  it needed three times the panel width, and the later half of every long meeting
  was simply clipped off.

## 0.4.2 (build 34)

- Fix a suggested name doing nothing when clicked. When two voices are too far
  apart to be the same person the server declines and explains why, and that
  explanation was being treated as a failure and discarded — so the click had no
  visible effect at all.
- Show the outcome instead: the measured voice similarity, the threshold it fell
  under, and a plain statement that nothing was applied.
- Add a Save button, and show progress while a name is being checked, so it is
  clear the click was received.
- Say what saving actually does. Applying a name folds one profile into another
  across every meeting, not just the one on screen.

## 0.4.1 (build 33)

- Fix the panel closing itself when an overlay opened. Speaker review and the
  photo preview were presented as sheets, and a sheet makes a new window key —
  which a menu-bar panel treats as a signal to dismiss. The panel disappeared
  mid-interaction, so controls stopped responding as they were clicked.
- Both now open in place inside the panel with a Back button, so nothing ever
  leaves the panel's own window.
- Fix a stale route condition: the speaker review's visibility depended on a
  value the view could not observe, so it could read the wrong answer and fail
  to redraw.

## 0.4.0 (build 32)

- Review who spoke in a saved meeting. Recent Glasses gains a Review speakers
  card; opening a meeting shows each voice with two to three of its own verbatim
  lines, timestamped. The lines are the point: a similarity score cannot tell you
  who someone is, and a sentence you remember can.
- Show the shape of the conversation before any name. The ribbon draws each
  voice's share in order, so a voice that swaps labels every few segments reads as
  fine stripes rather than a block.
- Mark a voice unreliable when it swaps with another every few segments. Two
  labels that trade the floor that fast are one identifier oscillating mid-turn,
  which means those profiles cannot be told apart and a name applied to either
  would be a guess. A high confidence score does not override this.
- Correct a voice by folding it into the right person. The merge is always shown
  as a preview first, with the measured voice similarity, and the server refuses
  a pair that is too far apart to be the same person.
- Never offer to absorb your own profile, and say plainly when an unidentified
  voice cannot be named because its audio is no longer held.

Requires server 6.21.13 or newer.

## 0.3.9 (build 31)

- Show Early meeting sync, tier-aware HQ prefill progress, and durable
  finalization recovery reported by server 6.21.8.
- Preserve the private canary flags across managed updates without enabling them
  for public users. Balanced caps progressive HQ at two CPU threads for M1/M2
  Air-class hardware; Max defaults to six on stronger Macs.
- Keep Early Sync available to both tiers because it performs stable-identity
  handoff rather than transcription compute.

## 0.3.8 (build 30)

- Add a machine-wide Meeting Turbo preview control for server 6.21.7+. It
  persists `COS_WHISPER_MEETING_PREVIEW` through Control's managed provider
  environment instead of relying on a hand-edited LaunchAgent.
- Apply uses the existing drain, bootout/bootstrap, lifecycle proof, and
  rollback transaction. Control verifies the replacement launchd process
  loaded the requested setting before reporting success.
- Show the active meeting-preview policy in the health card. Turbo provisional
  text remains cosmetic; Large-v3 stays canonical and speaker-attributed.

## 0.3.7 (build 29)

- Add a machine-wide Background jobs control. It writes the existing
  `COS_DURABLE_QUERY_JOBS` policy through Control's transactional provider-env
  path, drains active work, restarts under launchd, verifies authenticated
  capability truth, and rolls back automatically if proof fails.
- Show Background jobs status in the main health card. On is the server 6.21.6
  default; Off remains the immediate machine-wide rollback for new prompts.
- Keep one policy owner: COS Control changes the server capability, and every
  companion follows that authenticated result. No per-device opt-out can drift
  between phones; accepted jobs remain recoverable and cancellable.

## 0.3.6 (build 28)

- **Photo-aware Recent Glasses.** Turns now show bounded thumbnails for user
  photos and answer images. Select one for a larger local preview without
  exposing the pairing token or server storage paths to the app.
- **Explicit media handoff.** “Copy + images” creates a private local bundle
  with the turn text and up to five images so Cursor, Codex, or Claude can
  inspect the original visual context. Bundles older than 24 hours are pruned
  on the next Control launch or image export. “Copy turn” remains text-only.
- **Fail-closed media transport.** Helper downloads are authenticated, capped,
  MIME/signature checked, written with private permissions, and cleaned up.
  Missing or expired media stays visibly unavailable without breaking the row.
- Verified against `@gotcos/glasses-server` 6.21.4.

## 0.3.5 (build 27)

- **Fast, truthful Claude readiness.** Server 6.21.1 uses Haiku for the
  no-tool transactional proof and returns within a 45-second bound instead of
  inheriting a potentially heavyweight user default such as Opus.
- **Correct timeout errors.** Provider timeout/close races no longer surface as
  the misleading “provider process exited before launch.”
- **Truthful transaction state.** While Control itself owns a live change, the
  panel says the change is in progress and recovery is armed. “Interrupted” is
  reserved for persisted transactions with no active helper.
- Same public Control version, higher build number, so existing 0.3.5 build 26
  installs can discover this replacement through the appcast.
- Verified against `@gotcos/glasses-server` 6.21.1.

## 0.3.5 (build 26)

- **Balanced and Max transcription presets.** Control owns one machine-wide
  setting instead of asking users to hand-edit three environment variables.
  Balanced keeps Small.en preview, Turbo live commit, and Large-v3 polish. Max
  reuses Large-v3 for preview and commit; it never creates a third worker.
- **Transactional tier changes.** Managed and adopted in-place LaunchAgents are
  restarted with bootout/bootstrap, authenticated health is checked, and the
  prior environment is restored if the requested policy is not reported.
- **Truthful tier status.** The panel shows requested/effective policy and a
  visible Turbo fallback when Max weights are missing. Older servers hide the
  controls and direct the user to update instead of guessing.
- **Independent safety diagnostics.** A missing Turbo recovery model warns on
  Max without falsely labeling its active Large-v3 preview as a fallback.
- **Tier-aware Guided Setup.** Users choose Balanced (recommended) or Max before
  provisioning. The setup command downloads the matching models, then Control
  performs the verified activation.
- **Cursor version for support.** The Agent CLIs caption now uses Control's
  local Cursor probe, so it can show Cursor's real build even when server
  health only returns “About Cursor CLI.”
- Verified against `@gotcos/glasses-server` 6.21.0.

## 0.3.4 (build 25)

- **No false update rollback on healthy providers.** Candidate startup keeps its
  60-second ownership/health deadline, but real Claude, Codex, and Kokoro
  transactions now use their own existing bounded timeouts. A normal 38-second
  Codex proof can no longer inherit only the seconds left after startup and
  Claude, then falsely reject an otherwise healthy server update.
- **Mixed-version status stays truthful.** A server that reports HQ capability
  but predates the 6.20 live-model fields shows only HQ. Control no longer
  renders “Unreported” Live Preview and Live Commit rows on server 6.19.0.
- Verified against `@gotcos/glasses-server` 6.20.1.

## 0.3.3 (build 24)

- **Adaptive transcription status.** Control now shows the effective model and
  readiness for all three server 6.20.0 transcription lanes: Small.en live
  preview, Large-v3-Turbo live commit, and Large-v3 HQ polish. Preview fallback
  is labeled instead of being presented as healthy Small.en.
- **Accuracy setup.** Guided Setup provisions the adaptive local models and
  warns when the transcription profile has no real names or specialist terms.
  Existing servers that do not publish the 6.20.0 health contract keep the new
  rows hidden rather than receiving guessed labels.
- Verified against `@gotcos/glasses-server` 6.20.0.

## 0.3.2 (build 23)

- **Agent CLI row.** One quick-glance line for all three backends COS routes
  to: `Claude ✓ · Codex ✓ · Cursor ✓`. Previously only Cursor had a row, so a
  signed-out Claude or Codex CLI was invisible until a query failed on the
  glasses. Ready state comes from the server's own per-binary probe
  (`features.claude` / `features.codex`); a server too old to publish it shows
  `?` rather than a confident cross. When all three are ready the caption
  shows their versions; when one is not it names the exact login command
  instead. CLI version strings are parsed for a real version token, because
  the Cursor probe reports "About Cursor CLI" rather than a number.
- Cursor keeps its own detailed row: the helper probes it locally and can
  distinguish sign-in-required from not-installed, which health cannot.

## 0.3.1 (build 22)

- **Unsaved captures row.** Server 6.19.0 quarantines meeting audio whose save
  never landed instead of deleting it, and reports it on health as
  `unsaved_captures`. Control now surfaces that count in the status card with a
  recovery hint (open COS on the phone to let a deferred save land, or drive
  `/api/meeting/orphans/:id/recover`). The row hides at zero and on older
  servers, where the key is simply absent. Display only — Control never drives
  recovery itself.
- The retained-batch state ("Idle · 1 retained batch") flows through the
  existing Meeting sync label automatically; no change was needed for it.

## 0.3.0 (build 21)

- **Meeting sync status.** The status card now shows **Meeting sync** — Idle, or
  HQ polish progress with a percent when the server publishes it (glasses-server
  6.18.4+). On older servers Control falls back to scanning
  `~/.cos-glasses/data/pending-batch`, so a long post-meeting Whisper polish no
  longer looks like a mysterious "degraded" hang while Update waits to drain.
  Active sync captions that Update / Restart stay blocked until polish finishes.

## 0.2.9 (build 20)

- **A failed install no longer strands in-place mode.** `install()` deleted the
  in-place ownership marker before four throw sites (pending transaction,
  unadoptable ownership, npm unreachable, staging failure) and never restored
  it, so a transient npm outage permanently turned `inPlaceActive()` off — and
  with it the per-minute in-place recovery watchdog — while otherwise appearing
  to fail safely. The marker is now captured up front, dropped only at the point
  of no return, and written back if the switch rolls back.
- **Doctor and Copy Report name the Control build.** The report carried no app
  version at all, so a support report could not identify which build produced
  it — worse given that 0.2.7 shipped as two different binaries. The app passes
  its identity the same way it already does for the update check, because the
  stable helper copy has no sibling `Info.plist` to read.
- **Restored a version-touchpoint assertion.** Making the footer dynamic in
  0.2.8 removed the only test that could catch a wrong `Info.plist`. The suite
  now pins `Info.plist` to the CHANGELOG heading rather than to a UI string.

## 0.2.8 (build 19)

- Footer shows the **live** managed server version from status (e.g. 6.16.9),
  not a compile-time "verified 6.16.x" pin that lagged behind Update Server.
- Controller version in the footer comes from `Info.plist` (`currentVersion`).
- Verified baseline for this cut: `@gotcos/glasses-server` **6.16.9** (message
  era + per-exchange model stamps). Install/Update still resolve npm `latest`.

## 0.2.7 (build 18)

- Clarify folder pickers: **Work Folder** (agent workspace) vs **Meetings
  Library** (COS `operations/` for G2 Review Meetings). Own tool row so labels
  no longer truncate to ambiguous "Choose…" / "Meeting…".

## 0.2.6 (build 17)

- Add **Meetings Folder** so each install can point G2 Review Meetings at its
  own COS `operations/` tree (`COS_OPERATIONS_DIR`). Status shows the active
  meetings library; unset keeps standalone local recordings.
- Allowlist `COS_OPERATIONS_DIR` / `COS_MEETINGS_ROOT` on the managed
  LaunchAgent. Server fallback remains `COS_SCRIPTS_DIR/..` when set.
- Verified baseline server: `@gotcos/glasses-server` **6.16.2** (Update Server
  still resolves npm `latest`).

## 0.2.5 (build 16)

- Target the verified public `@gotcos/glasses-server` **6.16.1** release, which
  keeps truthful HQ transcription and adds managed Cursor Agent slots
  (Composer 2.5 / Grok 4.5) plus Silero VAD weights in the npm tarball.
- Install / Adopt / Update Server resolve npm `@gotcos/glasses-server@latest`,
  so the same UI path picks up 6.16.2+ without a Control rebuild. The footer
  still shows the verified baseline (6.16.1).
- From a running recognized legacy LaunchAgent, offer **Install managed
  server** (stop when idle, then adopt/install latest) alongside Manage in
  place. Repair commits an already-healthy candidate instead of rolling back
  when an interrupted update left the new generation live.
- Preserve the existing companion-owned HQ-default/Fast-mode preference; this
  release does not introduce a conflicting Control-side preference.
- Keep public packaging fail-closed for Developer ID builds: notarization is
  required when `COS_SIGN_IDENTITY` is set. Until notarization is enrolled,
  public site ZIPs may continue the existing ad-hoc ship path used by 0.2.3.

## 0.2.4 (build 15)

- Target server 6.15.5 and require an installed local Whisper runtime to report
  ready before a managed candidate is accepted. Repair Whisper now releases the
  maintenance gate before its final readiness check, so a failed optional audio
  repair never strands the otherwise healthy server offline.
- Show Whisper preflight/loading/failure state instead of a generic unavailable
  label and include the bounded startup error in diagnostics.
- Report the actual maintenance work classes and countdown while draining,
  replacing the indefinite-looking “Draining active work” message.
- Bound candidate verification, provider queries, and Kokoro playback to one
  monotonic operation deadline with explicit proof-phase progress.
- Add boundary coverage for migrated pairing tokens and prove both stale PID
  text and a SIGKILLed lock-holder process cannot block a later helper.
- Gate persistent Whisper readiness on whisper-server/model prerequisites, not
  batch-only whisper-cli, and show the bounded startup error in the main status
  card, Doctor, and Copy Report.
- Public packaging now fails closed without Developer ID signing and
  notarization, then validates the extracted ZIP with codesign, stapler, and
  Gatekeeper. Ad-hoc output requires an explicit local-QA override.

## 0.2.3 (build 14)

- Fix Choose Folder for adopted self-managed LaunchAgents. The selected
  workspace is written to both neutral and legacy provider keys, safely
  reloaded through the maintenance gate, and rolled back if activation fails.
- Apply managed workspace changes immediately through a full plist reload;
  status no longer reports a folder that launchd has not loaded.
- Keep server `WorkingDirectory` and `COS_GLASSES_APP_DIR` on the verified
  server package while Claude, Codex, and Cursor use the selected workspace.
- Tighten rewritten LaunchAgent plists to mode 0600, require exact adopted
  ownership, and preserve pending recovery state. Older adopted servers never
  auto-restart; an explicit, confirmation-gated Restart performs a full
  bootout/bootstrap so launchd actually loads the new environment.
- Preserve custom Cursor paths and target public server 6.15.3.

## 0.2.2 (build 13)

- Require a real, authenticated provider turn before a 6.15.2+ managed
  install, update, restart, repair, or rollback is reported as verified.
- When Kokoro reports ready, prepare speech and fetch the short-lived playback
  URL without an API header, matching the native phone audio path.
- Preserve the managed COS work folder, MCP selectors/config, compatible
  Kokoro Python overrides, and provider binary paths across runtime changes.
- Accept migrated pairing tokens with at least 16 characters and explain the
  generated 64-character format for shorter invalid values.
- Keep lifecycle locking kernel-owned and clear normal-operation PID metadata
  on unlock; a dead helper cannot leave a held lock.
- Target public server 6.15.2.

## 0.2.1 (build 12)

- Preserve discovered Claude, Codex, and Cursor executable directories in the
  canonical managed LaunchAgent PATH, including user-local CLI installs.
- Replace HTTP-200-only update, restart, and in-place gates with provider
  capability verification. A missing provider bridge now fails the candidate
  switch and restores the previous runtime instead of reporting false-green.
- Target `@gotcos/glasses-server` 6.15.1 for the Kokoro Python compatibility
  fix.

## 0.2.0 (build 11)

- Add the check-only in-app update banner and signed appcast parser.
