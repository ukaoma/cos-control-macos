# Changelog

## 0.5.11 (build 49)

- **Adaptive audio cleanup is visible and reversible.** Server 6.21.32 adds a
  default-off, retained-playback-only canary. Control exposes one plain toggle,
  reports `Adaptive replay` versus `Raw replay`, and transactionally restarts
  the managed or adopted LaunchAgent with an explicit `1` or `0`.
- **Activation proves the real server contract.** Apply succeeds only when
  health reports the selected value, `retained_replay_only` scope, and raw WAV
  preservation. A failed activation restores and verifies the prior server.
- **Stop and rollback win timing races.** Closing review or pressing Stop now
  cancels a pending first-play fetch, and adopted-server verification retains
  its rollback transaction until the health proof passes. The server's raw
  fallback deadline is shorter than Control's bounded media request.
- **The label states the boundary.** Cleanup runs only after a reviewer presses
  Play. It does not enter live preview, canonical transcription, speaker
  attribution, save, HQ polish, or meeting sync. Off immediately restores raw
  replay after the normal safe restart.

  Requires glasses-server 6.21.32. The previously shipped 0.5.10 binary remains
  build 48; this different binary is build 49 so the updater never confuses the
  two artifacts.

## 0.5.10 (build 48)

- **The Meetings Library picker no longer requires you to be Miles.** The
  validator hardcoded `["quilt","sprocket_rocket","hermit_crabs","personal"]` —
  one user's business domains — directly beneath a comment reading "Each COS
  layout can differ". Queen set up her own COS and every folder she chose was
  rejected with a message telling her to supply a `quilt/meetings` tree she has no
  reason to own. Domains are now discovered: any subfolder holding a `meetings/`
  folder counts, whatever it is named, spaces included.

- **The rejection message says what is actually wrong.** It was a dead end. Now it
  distinguishes the three real cases: you picked a `meetings/` folder itself, so
  choose its parent; the folder has no subfolders; or none of the subfolders hold a
  `meetings/` folder, and here are the ones it found. The picker's own instructions
  stopped naming someone else's domains too.

  Requires glasses-server 6.21.31, which discovers domains the same way. The picker
  and the server had to move together, or the picker would validate a shape the
  server then refuses to list.


## 0.5.9 (build 47)

- **A name you removed is called out above the write-up.** De-attribution rewrites
  the sidecar, the attendee list and the transcript labels, but deliberately leaves
  narrative prose alone, so a person you removed can still be named in the LLM
  summary shown right below the voice rows.

  2026-08-07: "Clem Ukaoma" was removed from a personal call that was only Miles
  and Queen — his father's voice had matched a similar profile. All 8 label sites
  were rewritten correctly and the panel still read "Miles, Queen, and Clem talk
  through the fallout", with nothing to indicate the removal had taken. The panel
  now shows, in orange above the write-up: *"You removed "Clem Ukaoma" from this
  meeting. The write-up below was written before that and still uses the name."*

  Needs glasses-server 6.21.30, which publishes `removedNames`. Older servers omit
  the field and the panel simply shows no warning.


## 0.5.8 (build 46)

Second adversarial-review pass before this ever shipped. gotcos.com still
advertises 0.5.6, so neither 0.5.7 nor 0.5.8 has reached anyone; build 45 exists
only as a local install here, which is why this is build 46 rather than a second
binary wearing the same number.

- **The panel drew per-voice shares with no coverage gate at all.** The clipboard
  has always suppressed shares below 60% coverage, and this file's own comment
  claimed the panel did too — "Say the coverage instead of drawing shares", above
  code that drew them unconditionally. The only `0.6` comparison in the app
  changed a caption's colour. Measured across 355 real reviews, the panel showed a
  share the clipboard refused on **170** of them. The floor now lives inside
  `shareOfIdentified`, so a future row cannot forget it, and it fails CLOSED on
  unknown coverage exactly as the server does — an `if let` would have shown a
  share on the one path where we know least.

- **"Full (1 KB)" on a 54 KB clipboard.** `fullChars ?? 0` labelled every button
  1 KB against published server 6.21.28, which serves `/content` without the size
  fields; real payloads measured 54,451 / 43,815 / 39,334 characters, and the
  confirmation then read "Copied full meeting (1 KB)". Both counts now fall back
  to the length of the string actually received.

- **The inline write-up is bounded.** It renders inside the sheet's own
  ScrollView, so it cannot have a bounded scroll view of its own without the two
  fighting for one gesture — the text is capped instead, at a word boundary, with
  the remainder stated rather than hidden. A 5,000-character write-up measured
  ~1,448pt and the worst real one ~2,700pt inside a 640pt pane.

- Panel seconds are rounded, matching the server, so the two no longer differ by
  a second on 456 voice rows; `2**3` and `**/blog` survive the markdown softener
  (18 real occurrences); and the sections list is keyed by position, because one
  real scribe repeats three of its own headings and recovered extras made that
  reachable.

- The pass-through of the clipboard strings is now asserted by EXECUTION rather
  than by grepping for an assignment's exact spelling. That grep broke on a
  refactor that changed nothing about the behaviour, which is how a shape test
  teaches you to edit the test instead of the code.

### Originally in build 45

- **The write-up now sits BELOW the voice rows.** Measured with AppKit at the
  real 358pt content width, placing it above pushed the rows this sheet exists
  for one to two full screens down on 7 of 8 of one day's meetings, worst case
  5.3 screens.
- **An older server is told so instead of hiding the feature.** A 404 from
  `/content` is classified as "server too old" and names the version needed; any
  other failure says it could not load. Previously both rendered as silence.
- Markdown markers are softened for the popover, since `Text(_: String)` does not
  parse markdown and rendered `###`, `- [ ]` and `**` literally.
- Both copy labels are sized from the SAME string the server measured. The button
  and the confirmation previously quoted different numbers on 81% of meetings.
- Unrecognised scribe sections appear in the panel rather than being dropped.
- The copy confirmation clears when the review reloads, so it can no longer
  assert a clipboard that a relabel has invalidated.
- Guards: the previous four pinned that code existed, and /qa proved two
  feature-killing mutations kept the suite green. The message decision is now a
  pure function covered by execution in ModelsContract, and the wiring greps are
  anchored to line start so a commented-out call cannot satisfy them.
- Requires glasses-server 6.21.28+.

## 0.5.7 (build 44)

- **Review the whole meeting, not just its voices.** The speaker sheet now shows
  the write-up — summary, topics, decisions, action items — above the speaker
  rows. Empty sections are omitted rather than rendered as bare headings, and a
  meeting with no write-up on disk says so instead of leaving blank panel.
- **Two copy buttons.** Summary for pasting into Slack or email; Full for pasting
  the whole meeting including the transcript into a model. The button shows the
  full size (measured 28 KB on a 26-minute meeting) so you know what you are
  putting on the clipboard.
- Both strings come from the server with the display floor already applied to
  the attendee list. The scribe's own `## Attendees` applies none — one real
  26-minute meeting lists 15 people, including a name already confirmed absent —
  so copying it verbatim would carry a guess into whatever you paste it into.
  Only named voices appear; the rest collapse into one honest line.
- Requires glasses-server 6.21.28+. Older servers omit the write-up and the copy
  buttons; the speaker rows are unaffected.

## 0.5.6 (build 43)

- **Talk time per voice in the speaker sheet.** Minutes and share of voice
  beside each row, shown ONLY for a voice the panel actually names — minutes
  next to an unnamed row would assert an identity by the back door, which is
  exactly what the display floor exists to prevent.
- Shares are a share of NAMED speech and total 100%. The denominator is the sum
  of named voices, not the server's `attributedSpeakingMs`: that field is a
  union with crosstalk counted once, and dividing by it rendered "MU 66% ·
  Edward Addo 39%" on a real meeting.
- Below 60% identified, the header says so instead of drawing shares.
  Corpus-wide 44.8% of speaking time is unattributed and 17% of meetings name
  nobody; a percentage there invites reading the missing majority as a person.
- Requires glasses-server 6.21.27+. Older servers omit the numbers rather than
  showing zeros.

## 0.5.5 (build 42)

- **The speaker sheet now says how much of the meeting carries a name.** The
  header showed only "N segments · M voices", and the server's only coverage
  signal was a boolean that goes false at 100% unidentified — so a meeting where
  295 of 299 chunks matched nobody rendered as though it were normally
  attributed. Measured across 14 retained sessions, unidentified share ran from
  24% to 100%, all of it collapsing onto that one boolean.
- The number counts segments whose voice row is actually shown with a name, not
  chunks carrying a person-shaped label. Those diverge: on one real session the
  label count is 287 of 379 while only 177 are displayed as names, so a header
  built on labels would claim high coverage above rows reading "Unidentified
  voice".
- Requires glasses-server 6.21.26+. Against an older server the line is omitted
  rather than shown as zero.

## 0.5.4 (build 41)

- **You can now finish naming a voice.** Typing a name and picking a scope had
  no Save — the commit action was clicking a suggested profile, and in the most
  common case no suggestion could ever appear. Two dead ends are closed:
  - **"Yes, this is <name>"** on a row the system demoted. When the identifier
    proposes a name it is not confident enough to show, that name IS the row's
    label, so renaming it to itself is impossible. This vouches for it instead
    and rewrites nothing.
  - **"Use '<name>'"** when what you typed is not an enrolled profile. Before,
    a voice could only be named after someone already enrolled, so a new person
    could not be named at all.
- A confirmed voice keeps its caveats. If it swaps with another speaker, the
  panel still says so — the name is asserted, the evidence is not hidden.

Requires server 6.21.25 for the confirm action. Older servers keep working and
simply never show it.

## 0.5.3 (build 40)

- **The meeting list shows 15 and scrolls.** It showed 12 before — and asking
  the server for 15 would have returned 10 to 12, varying by day, because rows
  without a G2 session are filtered out after the limit is applied. The helper
  now over-requests so 15 actually render, and the header states the count so
  hidden rows are stated rather than implied.
- **Each row shows what is in the meeting**: topics, decisions, actions and
  attendees, on their own line. The server was already sending these counts and
  the helper was discarding them, so this costs no extra request. Zero counts
  are omitted, and a meeting with none falls back to how it was captured.
- The list only scrolls once it is long enough to need to. Height follows
  content up to a cap, so a light day reserves no empty space.

## 0.5.2 (build 39)

- **You can now name an unidentified voice.** The row said "This voice was
  never named. Give it one from the list above" and then offered no control to
  do it — the panel instructed an action it refused to perform. The server
  always supported this; `canRename` simply excluded unattributed rows. Naming
  one now opens the same scope picker and confirm preview as every other
  correction.
- The confirm card says what a name assignment actually does. An unattributed
  row is a cluster the identifier could NOT match, so nothing established it is
  one person, and a large cluster on a G2 microphone is frequently several.
  Saving labels every one of its segments, and the card now states the count
  and that caveat before the click rather than after.
- The wearer still cannot be renamed. That guard is the reason the check
  existed; only the unattributed half was wrong.

## 0.5.1 (build 38)

- Add an **Idle Metal HQ** control for powerful Macs running glasses-server
  6.21.20 or newer. It only enables Metal for sealed post-meeting HQ work when
  the server is idle; live and progressive transcription keep their existing
  protected paths.
- Turning the setting off writes both `COS_BATCH_HQ_METAL=0` and the explicit
  `COS_BATCH_HQ_FORCE_CPU=1` rollback. Turning it on clears that override. Both
  values are applied through Control's safe drain, restart, verification, and
  rollback transaction instead of by editing a LaunchAgent by hand.
- Show the active policy in the status card as `On · preemptible`, `Force CPU`,
  or `Off · CPU`. Public installs remain CPU-first unless the user opts in.

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
