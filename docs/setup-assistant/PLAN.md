# Ask COS: the ⌘K command center and setup help

Miles, 2026-10-27: "turn this into the setup widget that can run the commands necessary to get things running on
everybody's device and also troubleshoot ... I can repair X, Y or Z or set up X, Y or Z."

Miles, 2026-10-31: "this should become kind of a main operation center rather than just as it is today a task creation
system." His jobs: start a recording, open running sessions that are waiting on him, ask how to set up Parakeet, and
troubleshoot other issues. Plan and validation: `operations/personal/wk44_2026/PLAN_command_center_cmdK_2026-10-31.md` in the
COS repo, Revision 2.

Available only with the Today home on (`activityTodayHomeEnabled`, default off), so nothing changes for anyone else until
Miles says.

| Piece | Where | State |
| --- | --- | --- |
| Engine: snapshot, ranking, actions, gates, confirm copy, knowledge base, troubleshoot prompt | `Sources/SetupAssistant.swift` | Done. Foundation only, no views. |
| Command center logic: closed command list, rows, Return, Esc, highlight, recording holds, Ask COS, result line | `SetupAssistant.Center`, same file | Done. Foundation only. |
| Panel, dispatch, snapshot, key monitor | `Sources/ActivityWindow.swift`: the `Command center` extension, `CommandCenterPanel`, `CommandCenterKeyMonitor` | Done. |
| Checks against fictional fixtures | `Tests/SetupAssistantChecks.swift`, `Tests/run-setup-assistant.sh` | Done. In `Tests/run.sh`. |
| Pins the checks cannot see | `Tests/setup-assistant-pins.py`, plus `activity-today-pins`, `meeting-detect-pins` | Done. Run by their lanes. |
| Mutation lane (hand-run) | `Tests/mutate-setup-assistant.py` | Done. |
| Render harness, every state, 1200 and 760, light and dark (hand-run) | `Tests/CommandCenterRender.swift`, `Tests/run-command-center-render.sh` | Done. |
| Layout | Layout A of `design/ask-cos-setup-mock.html`: a panel under the box, over the page | Picked and built. |

Zero compile-list edits: the logic is nested in a file every explicit list already names, and the view is in a file they all
compile.

## Layout

A list that floats at frame level, inside the Today frame's TimelineView closure, above the clipped content, reading that
tick's `TodayHome.Frame`. Today's box is a button that opens it, same look. ⌘K opens it from any tab and never navigates.
Its width is at most 520 pt and the list scrolls inside a capped height, so it never pushes the page. Its words, highlight
and confirm are its own state, so typing never composes the window.

## What is recording (Miles, 2026-10-31)

"Those should be the top items above 'running' ... a dedicated section near TODAY." `ActivityWindow.todayRecordings()` is the one
list, and `TodayHome.compose` moves those rows from Running into `Frame.recordings`:

- **Today:** `TodayRecordingSection`, directly under the header and above the brief, Needs you and Running. Nothing at all when
  nothing records. One row per recording with its title, where and how long, Live view, and how it stops. A Mac recording has Stop
  and save with an inline confirm; a glasses meeting says it stops on the glasses. The mark is `COSPalette.live`, with no motion.
- **Keys:** the Mac capture keys on its own store (`isRecording` or starting, then Saving… until it has saved); glasses key on the
  server's live sessions. `recordingCount` decides neither.
- **Counts:** a recording is not in Running, so Running's count is what Running lists. `Counts.recordings` counts them. The brief no
  longer mentions a recording, because the section sits right above it. It used to say "the glasses are recording" even for a Mac
  recording.
- **Rail:** Today's line says "1 recording" first, then what needs you, and drops the running count so it stays on one line.
- **⌘K:** the same rows first on an empty box, above Waiting and Running, each opening its live view, with Stop and save under the
  Mac's.

## What it lists

An empty box: what is recording, then up to 3 things waiting on you (tier 1 first, through the quiet-hours fold), up to 3 running,
then Start recording and Run Doctor, then up to 2 of the board's repairs when something is broken. With the server down the repairs
come straight after what is recording. A list that has not loaded says "not loaded", never "nothing waiting".

Typing: commands from the closed list, sessions whose titles match, the saved answer with its offers, then always last Ask
COS, Ask COS to troubleshoot (when its gate is ready) and File to Work. A saved answer is labelled as saved with its entry
title, and a miss says "No saved answer for this."

The closed command list: Start recording, Stop and save, Open Sessions, Meetings, Work, Speakers, Dictation, Memories,
Settings, Run Doctor. Copy report and Open Tailscale were cut as commands, and so was a classifier for words that read as a
problem, so Ask COS to troubleshoot is offered whenever words are typed and its gate is ready. The board and the knowledge
base still offer those two actions where they apply.

## The snapshot

`ActivityWindow.commandSnapshot()`, in the Command center extension. It reads published state only, so it is cheap to rebuild
each frame.

| Snapshot field | From |
| --- | --- |
| `serverReachable` | `status.running` (`/api/health` answered 200) |
| `runtimeState`, `installed`, `needsFirstRun`, `setupProviderInstalled`, `managedContract`, `ownershipVerified`, `ownerConflict`, `transactionPending`, `desiredState`, `safeToRestart`, `whisperReady`, `whisperCircuitOpen`, `meetingWorkBlockingRestart` | `status.*` (ServerStatus, Sources/Models.swift) |
| `activeJobs`, `activeTranscriptionSessions` | `status.activeJobs ?? 0`, `status.activeTranscriptionSessions ?? 0` |
| `macRecordingActive` | `model.macRecordingActive` (starting, recording or stopping) |
| `helperBusy` | `busy` |
| `checks` | `doctorChecks.map { .init(name: $0.name, state: $0.state, detail: $0.detail) }` (empty until Run Doctor) |
| `appUpdate` | `currentVersion: ControllerModel.currentVersion`, `latestVersion: appUpdate.latestVersion`, `available: appUpdate.updateAvailable`, `downloadFailed`: `appUpdateFlow.phase` is `.failed`, `installing`: `.staging` or `.applying` |
| `setup` | Left empty. The panel's Fix rows are repairs only, and setup stays with Finish setup and the setup guide. The engine's rules for setup rows are still executed in its checks. `awaitsServer` has no source in `SetupRow` today; `SetupGuideRules.voiceProofPending` is the closest if a later build shows these rows. |
| `dictationEnabled` | `dictation.enabled` |
| `accessibilityTrusted` | `petJumpTrusted` (AXIsProcessTrusted). `openCommandCenter` calls `refreshPetJumpTrust()`: the value is only refreshed at certain moments. |
| `microphoneAllowed` | `AVCaptureDevice.authorizationStatus(for: .audio)`: authorized is true, denied or restricted is false, not determined is nil |
| `workRunsOn` | `TodayHome.workRunsOn(.standard)` |

`board(_:)` gives at most four suggestions, broken things first, then setup, then extras, and `allClear`. `answer(_:_:)`
gives the knowledge-base answer for the typed words, with at most two offers, each ready or held with its reason.

## Actions

Each `SetupAssistant.Action` maps to one call that already exists (`commandRun(_:words:)`, a switch with no default). Nothing
typed reaches any of them.

| Action | Call |
| --- | --- |
| `runDoctor` | `model.perform("doctor")` |
| `copyReport` | `model.perform("report")` (copies the redacted report; notice "Redacted report copied") |
| `setUp` | `model.perform("setup")` |
| `startServer` | `model.perform("start")` |
| `restartServer` | `model.perform("restart")` |
| `repairRuntime` | `model.perform("repair")` |
| `repairWhisper` | `model.perform("restart-whisper")` |
| `updateServer` | `model.perform("update")` |
| `retryAppUpdate` | `model.installAppUpdate()` |
| `resetAccessibility` | `model.resetAccessibilityAndAddAgain()` |
| `openUnstuck` | `NSWorkspace.shared.open(CommandCenterPanel.unstuckURL)`, gotcos.com/control/#unstuck |
| `openSetupGuide` | `model.showSetupGuide?()` |
| `openPermissions` | Settings hub target `hub.privacy.permissions`; classic Settings: `model.permissionGuide.openInPanel()` |
| `openSettings` | `openActivitySettings()` |
| `openDictationSettings` | Settings hub target `hub.dictation.dictation`; classic Settings: `model.openDictationSettingsInActivity()` |
| `openMicrophoneSettings` | `model.dictation.openMicrophoneSettings()` |
| `openTailscale` | `GlassesWindowHolder.openTailscaleApp()`, else `model.providerGuide.openURL(GlassesRules.tailscaleDownload)` |
| `openTranscriptionSettings` | Settings hub target `transcription` (Transcription and voice, Models: Install Parakeet) |
| `openMeetings`, `openSpeakers` | `select(.meetings)`, `select(.speakers)` |
| `troubleshoot` | see below |

A change (`action.changesSomething`) never runs on the first Return or click. It opens the inline confirm from
`SetupAssistant.confirmation(action, snapshot)`: the question, one consequence line, the confirm button and Cancel. Run Doctor
and Copy report change nothing, but each spends a real provider question, so `Center.confirmation` confirms them too, and Stop
and save has its own. On confirm, `Center.recheck` reads fresh state and runs only if it is still ready; a recording can start
between the two. If it is held now, the row says why and nothing runs. There is no force path: a held row has no action.

## Recording

`MacRecordingNotice.step` first. Not acknowledged: `MacRecordingNoticeCard` inline in the panel; its Record is a click, and
Return never accepts it. Then `store.record(title:, sourceID: MacAudioSource.allMacAudioID, bridge: model.macRecordingBridge)`
with the automatic title, never the typed words, and an in-flight flag (`today.recordInFlight`). Nil: the result line says
`store.error` and Meetings opens, as the meeting card does. A refused System Audio prompt still records, as it does from
Meetings.

Start recording is held by `MeetingDetectedCard.recordingBusy`, the same rule the meeting card uses, which counts a glasses
meeting, so one is never captured twice. It is also held under macOS 14.2 and while the server does not answer. Stop and save
shows only while `isRecording` or starting, never from `recordingCount`, and has an inline confirm. A glasses meeting says to
stop it on the glasses.

## Ask COS and Ask COS to troubleshoot

Both go through `today.startRun`, Today's own run path, so the cap of 20 a day, the breaker and the one-run-per-target check all
apply. Both are offered only while the server answers and Start Work runs from Today is on; Ask COS shows held with the reason
otherwise, and File to Work stays.

**Ask COS** (`Center.askRun`) carries the person's words quoted, the saved answer when there is one, a short snapshot and the
same rules as troubleshoot (`SetupAssistant.runRules`: no sudo, pkill or killall, ask before changing anything). No Doctor. It
never takes a session title. The reply stays in Running in v1: the run comes first in the Running rows, and that row opens it.

**Ask COS to troubleshoot** (`commandTroubleshoot`) confirms first, then in this order: the gate, one at a time
(`today.gatheringReport`), the run guard's read-only check (`today.runRefusal`), then Doctor, then the run:

```swift
// Not model.perform("report"): perform copies the report to the clipboard.
let report = try? await model.runHelper(["report", "--current-version", ControllerModel.currentVersion, "--current-build", String(ControllerModel.currentBuild)],
                                        timeout: 90).details["report"]?.string
guard let run = SetupAssistant.troubleshoot(question: words, commandSnapshot(), report: report, id: id, asked: TodayHome.headerDate(Date())) else { ... }
commandStartRun(run)
```

The report runs Doctor, which includes a real provider question (Query + playback proof, up to 60 s), so the result line says
"Gathering the Doctor report…" while it runs. The guard goes first so a run the cap would refuse never spends that question.
The prompt tells the agent to diagnose and propose, never to use sudo, pkill or killall, never to restart while work runs, and
to ask before it changes anything. The person's words go in quoted. The packet is capped at 12,000 characters and any
`/Users/<name>` left in it becomes `~`.

## Sessions

Titles are untrusted. `Center.clean` makes them one line with control and direction characters gone and bounded, the panel draws
them with `Text(verbatim:)`, they open only their own row, they are never matched for dispatch (a match only filters the list and
never highlights) and they never go into a prompt. A question's own words (`NeedRow.quote`) never reach the panel. A row is looked
up again at open, so a session that went away flashes a line instead of opening stale, and `todayOpenNeed` keeps the Cursor
fallback.

## Keyboard

The field keeps its focus the whole time; the list never takes it. Up and Down reach the list through a local monitor like the
Esc one, mounted only with the panel. Esc reaches the panel first in `handleActivityEscape`. A click outside closes it, and
unsent words wait for the next open. All of these are rules in `SetupAssistant.Center`, executed in the checks.

| Key | With nothing highlighted | With a row highlighted | With a confirm open |
| --- | --- | --- | --- |
| Down | Highlight the first row | Next row (stops at the last) | Nothing |
| Up | Nothing | Previous row; from the first, back to no highlight | Nothing |
| Return | Where the words point first: a command listed at the top (Stop, Doctor, "go to se", a phrase inside a sentence) moves to that command's row, and a title that matches a session moves to the first session row. A second Return runs it, and its own confirm still applies. Otherwise one Work run, through the Ask row with the snapshot and the rules, only for 3 or more words with no answer or command match. A saved answer, a near-command or a short text moves to the Ask row, and a second Return runs it. Start Work off: files, unless the words are an answer or close to a command | Run the row: an opener runs at once, a change opens its confirm | Confirm (after the fresh check) |
| Option-Return | Files to the Work inbox | Same: Option-Return always files | Same |
| Esc | Clears the words, then closes | Clears the highlight | Cancels the confirm |
| ⌘K | Opens over the current tab, and closes when open. It never navigates, and it does not open under a task being edited or a naming review | | |

A row is highlighted on its own only when the whole text is an exact phrase of an opener or Start recording, and only when that
row can run. Never Stop, Doctor or anything in `changesSomething`. So "start recording" runs on Return, and "stop recording the
demo" does not: while a recording runs, Return moves to Stop and save, and Stop asks before it stops.

A row that ran has used its words up. `perform` empties the box, the highlight and the draft for every row but Ask COS, File to
Work and troubleshoot (`Center.sendsWords`), which keep theirs until the run or the filing is accepted. A run, a filing or a recording
under way also empties the draft directly (`CommandCenterKeys.clearDraft`), because a panel closed by a click outside has no
`clearWords` left to call. Without that, the next ⌘K brought "open work" back armed and one Return fired it twice.

VoiceOver hears the highlight and what Return will do, and the foot of the panel says the same. Nothing moves in the panel, so
Reduce Motion has nothing to stop. Breadcrumbs name a kind of row, never a title or anything typed.

## Progress and the result line

One line under the field (`Center.result`): a failure first, then what is running now, then the last result. It reads
`model.error`, a failed recording start, Doctor's report being gathered, `model.operationProgress` while the helper runs, a run or
a filing on its way, `today.runNote`, `today.notice`, `model.platformOpenNotice`, and `model.notice` only for something this panel
ran, because it stays set long after.

- While a helper action runs: `model.busy` is true and `model.operationProgress` streams the helper's own lines
  ("Draining active work safely…", "Verifying local Whisper…", "Proving Claude…"). Every other helper action is held with "COS
  Control is finishing another task".
- A failure shows in place: the window's alert stays out of the way while the panel is open, so the field keeps its focus. Closing
  the panel clears a failure this panel caused; any other failure shows its alert then.
- After a result, `perform` has already refreshed the status, so the rows are rebuilt from the new state.
- The app update reports through `appUpdateFlow` and its banner, not `notice`. Reset and add again sets `notice` from its
  own task.
- Ask COS and troubleshoot report through `today.runNote` ("Started. It shows in Running." or the refusal).

## Render states

`Tests/run-command-center-render.sh <folder>` draws each of these on a fixture: Start Work off, server down, Sessions off, no
sessions, overview not loaded, helper busy, notice not acknowledged, recording, saving, G2 recording, macOS under 14.2, plus the
typed answers, a confirm, a failure, hostile titles, the panel over Work and over Settings, the smallest window, and the recording
states (`rec-mac`, `rec-glasses`, `rec-both`, `rec-saving`, `rec-none`), each on Today and in ⌘K. Focus, the
arrow keys and a real recording start cannot be proved there; they are for the candidate install.

## Risks

1. **A drain that times out closes admissions.** The helper waits up to 90 s for work to drain, then fails with the
   operation "closed and persisted for Repair" (HelperSources/main.swift `waitForRestartProof`). The gates keep the
   assistant from starting a restart while work runs, but work that starts between the click and the drain can still
   hit this. The fresh gate check at confirm narrows the window; it cannot close it.
2. **Stale facts.** Accessibility trust, the microphone and Doctor results are read at moments, not live. Refresh trust
   when the list opens; say when Doctor last ran.
3. **Doctor costs a real question.** Run Doctor, Copy report and troubleshoot all run Doctor's provider proof. Each confirms
   first; nothing runs Doctor on its own. Ask COS does not run it.
4. **Knowledge-base drift.** The answers quote the COS Control guide (cos-starter at 7879f48). When the guide changes,
   the entries must change too. The pins check that cited code files exist, not that the docs still say the same.
5. **The documented Accessibility fix is not the toggle.** The guide says switching COS Control off and on "is often not
   enough" and gives remove-and-add-again (Reset and add again). The engine follows the guide.
6. **Dictation settings route.** "Activity, Dictation, Settings" is a sub-view; `openDictationSettingsInActivity` is the route
   flag its opener writes. The Parakeet install and the engine live in the Settings hub, so `openTranscriptionSettings` lands there.
7. **Repair while the server is down and a Mac recording spools.** Held on purpose; the person stops and saves first.
8. **The anchor case cannot be reached from the old app.** A 0.5.273 copy never gets this assistant. Those people are
   reached by the appcast notice and gotcos.com/control/#unstuck, which the engine also points to.

## Problems the app can see but has no action to fix

- **Runtime integrity failed:** Repair verifies the active generation first and stops there. The engine offers Update
  Server, which stages a fresh, integrity-checked generation; that path is read from the code, not from the guide.
- **Query + playback proof failed:** no action; Copy report only.
- **Node.js or npm missing:** Doctor reports it; nothing in the app reinstalls them outside an install.
- **Whisper CLI or ffmpeg not installed** (warnings): the guide says `brew install`; there is no in-app installer.
- **Dictation slow from a Parakeet cold-compile loop** (2026-10-25): the fix is one decode with no timeout and clearing
  stale `.tmp` model bundles. No helper command does either; the engine can only explain and offer troubleshoot.
- **Private config warning** (pairing token): Copy Pairing Token exists, but the fix is pasting it on the phone.
- **Memory and Threads not connected:** COS Data is a folder picker; the engine does not offer it yet.
- **Stranded video uploads and unsaved meeting captures:** `clear-stranded-video-uploads` and
  `meeting-orphan-recover-all` exist; the engine does not offer them yet (each needs its own confirm copy).
- **Ownership conflict:** nothing, by design. COS Control never stops a process it did not start.
