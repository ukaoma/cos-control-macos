# Ask COS as setup and repair help: wiring plan

Miles, 2026-10-27: "turn this into the setup widget that can run the commands necessary to get things running on
everybody's device and also troubleshoot ... I can repair X, Y or Z or set up X, Y or Z."

Built on `claude/control-settings-hub` (base 2dbadec, 0.5.352):

| Piece | Where | State |
| --- | --- | --- |
| Engine: snapshot, ranking, actions, gates, confirm copy, knowledge base, troubleshoot prompt | `Sources/SetupAssistant.swift` | Done. Foundation only, no views. |
| Checks against fictional fixtures | `Tests/SetupAssistantChecks.swift`, `Tests/run-setup-assistant.sh` | Done. In `Tests/run.sh`. |
| Pins the checks cannot see | `Tests/setup-assistant-pins.py` | Done. Run by the lane. |
| Mutation lane (hand-run) | `Tests/mutate-setup-assistant.py` | Done. |
| Layout mock, A and B, light and dark | `design/ask-cos-setup-mock.html` | For Miles to pick. |
| Views and wiring | this plan | Not started. Waits for the pick. |

Nothing in the app calls the engine yet. It is compiled into every app build (it is in every explicit compile list), so
the views can be added without touching a build script.

## Which layout

- **A. A list under the Ask box.** One overlay view. Today does not move. Feels like Spotlight. Progress of a long
  repair is visible only while the list is open; when it closes, the existing `today.runNote` line under the box can
  carry the helper's progress line.
- **B. A panel under Today's header.** A second column for the chosen item's answer, confirm and progress. It stays open
  until closed. More code: its own open state, its own layout at narrow widths.

My recommendation is A for the first build: it is smaller, it keeps Today as it is, and every state in the mock fits in
the box's width. B is the better home if repairs grow longer than a minute or two.

## The snapshot

One `@MainActor` builder, for example `ControllerModel.setupSnapshot(today:) -> SetupAssistant.Snapshot`, in a new file
next to the views. It reads published state only, so it is cheap to rebuild in `body`.

| Snapshot field | From |
| --- | --- |
| `serverReachable` | `status.running` (`/api/health` answered 200) |
| `runtimeState`, `installed`, `needsFirstRun`, `setupProviderInstalled`, `managedContract`, `ownershipVerified`, `ownerConflict`, `transactionPending`, `desiredState`, `safeToRestart`, `whisperReady`, `whisperCircuitOpen`, `meetingWorkBlockingRestart` | `status.*` (ServerStatus, Sources/Models.swift) |
| `activeJobs`, `activeTranscriptionSessions` | `status.activeJobs ?? 0`, `status.activeTranscriptionSessions ?? 0` |
| `macRecordingActive` | `recordingCount > 0` |
| `helperBusy` | `busy` |
| `checks` | `doctorChecks.map { .init(name: $0.name, state: $0.state, detail: $0.detail) }` (empty until Run Doctor) |
| `appUpdate` | `currentVersion: Self.currentVersion`, `latestVersion: appUpdate.latestVersion`, `available: appUpdate.updateAvailable`, `downloadFailed: appUpdateFlow.offersUnstuck`, `installing: appUpdateFlow.installing` |
| `setup` | `SetupGuideRules.rows(setupFacts(provider: providerGuide, guide: setupGuide), skipped: setupGuide.skipped)` mapped to `SetupItem(id: row.id.rawValue, title:, status:, unlocks:, done:, skipped:, counted:, afterSetup:, awaitsServer:)` |
| `dictationEnabled` | `dictation.enabled` |
| `accessibilityTrusted` | `petJumpTrusted` (AXIsProcessTrusted). Call `refreshPetJumpTrust()` when the list opens: the value is only refreshed at certain moments. |
| `microphoneAllowed` | `AVCaptureDevice.authorizationStatus(for: .audio)`: authorized is true, denied or restricted is false, not determined is nil |
| `workRunsOn` | `TodayHome.workRunsOn(.standard)` |

`board(_:)` gives at most four suggestions, broken things first, then setup, then extras, and `allClear`. `answer(_:_:)`
gives the knowledge-base answer for the typed words, with at most two offers, each ready or held with its reason.

## Actions

Each `SetupAssistant.Action` maps to one call that already exists. Nothing typed reaches any of them.

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
| `openUnstuck` | `NSWorkspace.shared.open(AppUpdateFlow.unstuckURL)` |
| `openSetupGuide` | `model.showSetupGuide?()` |
| `openPermissions` | `model.permissionGuide.openInPanel()` |
| `openSettings` | `model.showSettings?()` |
| `openDictationSettings` | `model.openActivity?(.dictation)`, then the Dictation tab's Settings view (needs a route flag; see Risks) |
| `openMicrophoneSettings` | `model.dictation.openMicrophoneSettings()` |
| `openTailscale` | `GlassesWindowHolder.openTailscaleApp()`, else `model.providerGuide.openURL(GlassesRules.tailscaleDownload)` |
| `troubleshoot` | see below |

A change (`action.changesSomething`) never runs on the first Return or click. It opens the inline confirm from
`SetupAssistant.confirmation(action, snapshot)`: the question, one consequence line, the confirm button and Cancel. On
confirm, rebuild the snapshot and run only if `gate(action, fresh) == .ready`; a recording can start between the two.
If it is held now, show the held line instead and run nothing. There is no force path: a held action has no button.

## Ask COS to troubleshoot

Offered only when `gate(.troubleshoot, snapshot) == .ready` (the server answers and Start Work runs from Today is on). It
goes through Today's own run path, so the cap of 20 a day, the breaker and the one-run-per-target check all apply.

```swift
// Not model.perform("report"): perform copies the report to the clipboard. Call the helper directly, bounded.
let report = try? await helper.run(["report", "--current-version", ControllerModel.currentVersion,
                                    "--current-build", String(ControllerModel.currentBuild)], timeout: 90).details["report"]?.string
guard let run = SetupAssistant.troubleshoot(question: text, snapshot, report: report,
                                            id: UUID().uuidString.lowercased(), asked: TodayHome.headerDate(Date())) else { return }
await today.startRun(target: run.target, title: run.title, prompt: run.prompt, context: run.context, handoff: handoffStore)
```

`helper` is private on ControllerModel today, so this needs a small model method (for example
`func redactedReport() async -> String?`). The report runs Doctor, which includes a real provider question
(Query + playback proof, up to 60 s), so the row says "Gathering the Doctor report…" while it runs. The prompt tells the
agent to diagnose and propose, never to use sudo, pkill or killall, never to restart while work runs, and to ask before
it changes anything. The person's words go in quoted. The packet is capped at 12,000 characters and any `/Users/<name>`
left in it becomes `~`.

## Keyboard

The box keeps its focus the whole time; the list never takes it.

| Key | With nothing highlighted | With a row highlighted | With a confirm open |
| --- | --- | --- | --- |
| Down | Highlight the first row | Next row (stops at the last) | Nothing |
| Up | Nothing | Previous row; from the first, back to no highlight | Nothing |
| Return | Today's behavior: `todaySubmitAsk(file: false)`, one Work run, or the inbox when runs are off | Run the row: an opener runs at once, a change opens its confirm | Confirm (after the fresh gate check) |
| Option-Return | `todaySubmitAsk(file: true)`, files to the Work inbox | Same: Option-Return always files | Same |
| Esc | Close the list (A) or the panel (B) | Clear the highlight | Cancel the confirm |
| ⌘K | Focus the box (exists: the hidden button in ActivityWindow) and open the list | | |

Rows, in order: the answer's offers, then the board's suggestions, then "Ask COS to troubleshoot" when it is offered.
Typing never highlights anything on its own, so a knowledge-base match can never take over Return. Arrow keys go
through `.onKeyPress` on the TextField (the file already uses `.onKeyPress`); Return stays on `.onSubmit`, which reads
the highlight first.

## Progress and the result line

- While a helper action runs: `model.busy` is true and `model.operationProgress` streams the helper's own lines
  ("Draining active work safely…", "Verifying local Whisper…", "Proving Claude…"). The running row shows that line under a
  progress bar. Every other change is held with "COS Control is finishing another task".
- When `busy` turns false: `model.error` set means failed, shown in the helper's own words; otherwise `model.notice` is
  the result ("COS server restarted and verified"). Record the action when it starts and read the two fields at that
  moment, because `perform` clears both when it starts and later refreshes can set them.
- After a result, `perform` has already refreshed the status, so the board below is rebuilt from the new state. A
  failure is followed by whatever the board now offers, and by "Ask COS to troubleshoot" when the server is up.
- The app update reports through `appUpdateFlow` and its banner, not `notice`. Reset and add again sets `notice` from its
  own task.
- Troubleshoot reports through `today.runNote` ("Started. It shows in Running." or the refusal).

## Tests to add with the views

- Pins in the activity-today style: `todaySubmitAsk(file:)` still runs on Return with no highlight and on Option-Return
  always; Esc clears in the order above; the confirm path rebuilds the snapshot and checks the gate; every
  `Action` has a dispatch case.
- Extend `Tests/mutate-setup-assistant.py` with those pins.
- A render check against the picked mock, like the other `*Render.swift` harnesses.

## Risks

1. **A drain that times out closes admissions.** The helper waits up to 90 s for work to drain, then fails with the
   operation "closed and persisted for Repair" (HelperSources/main.swift `waitForRestartProof`). The gates keep the
   assistant from starting a restart while work runs, but work that starts between the click and the drain can still
   hit this. The fresh gate check at confirm narrows the window; it cannot close it.
2. **Stale facts.** Accessibility trust, the microphone and Doctor results are read at moments, not live. Refresh trust
   when the list opens; say when Doctor last ran.
3. **Doctor costs a real question.** Run Doctor and troubleshoot both run Doctor's provider proof. Both are explicit
   buttons; nothing runs Doctor on its own.
4. **Knowledge-base drift.** The answers quote the COS Control guide (cos-starter at 7879f48). When the guide changes,
   the entries must change too. The pins check that cited code files exist, not that the docs still say the same.
5. **The documented Accessibility fix is not the toggle.** The guide says switching COS Control off and on "is often not
   enough" and gives remove-and-add-again (Reset and add again). The engine follows the guide.
6. **Dictation settings route.** "Activity, Dictation, Settings" is a sub-view; opening it from elsewhere needs a route
   flag the opener writes, the same shape as the other panes.
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
