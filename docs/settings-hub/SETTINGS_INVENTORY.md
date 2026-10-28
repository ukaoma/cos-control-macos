# COS Control Settings Inventory

Parity spec for the categorized Settings view. Source: branch `claude/control-settings-hub` at `2dbadec` (0.5.352). Read-only pass; no Swift was changed.

## How to read this

- File paths are relative to `Sources/` unless they start with `HelperSources/`.
- One row per setting, action or status a person can see or use. Row IDs (H-01, ST-04, ...) are stable; the layout, checklist and grep reconciliation all point at them.
- **Backing** names the UserDefaults key, the helper verb (`perform("x")` and `runHelper(["x"])` both run `COS Control Helper x`), or "in memory".
- **Restarts server**: every `set-*` helper verb that changes the managed server (tier, background jobs, folders, sessions, Ollama, video, Metal, audio cleanup) goes through `applyManagedProviderEnvironment` or `applyManagedWorkDirectory` (`HelperSources/main.swift`), which unloads the LaunchAgent, rewrites it and waits for health under a `server_restart` maintenance lease. Treat each as "interrupts work".
- **Apply pattern**: the toggle or picker is a local draft (`@State selected*`) seeded from `model.status`; nothing changes until Apply. Each draft has its own `onChange` sync on purpose (`Views.swift:597`).
- Where it renders today: "Panel" is `ControlPanel.mainPanel` (`Views.swift:1890`). The same view is hosted three ways: the menu-bar panel, the Settings window (`SettingsWindowPresenter`, `ProviderConnectViews.swift:1154`, `hostedInWindow`), and Activity's Settings route (`ActivityWindow.swift:769`, `hostedInActivity`). Activity's host drops the header (H-01, H-04) and the Activity launcher (H-11).
- Scroll anchors used by openers today: `settings` (`Views.swift:1982`), `transcription` (`Views.swift:1987`), `decision-models` (`Views.swift:2862`), `setup-guide` (`Views.swift:1972`), `key-lanes` (`KeyLanesViews.swift:78`). The new view must route each one to the matching category.

## Counts

| Measure | Count |
| --- | --- |
| Inventory rows (section 1) | 253 |
| Orphans and reachability gaps (section 2) | 12 |
| Duplicate groups (section 2) | 23 |
| Grep hits that define "done" (`@AppStorage` 23, `Toggle(` 59, `Picker(` 11, `perform("set-` 12) | 105 |
| Of those, mapped to a row | 79 |
| Of those, excluded with a reason (appendix A; one goes to orphan O-02) | 26 |
| Other searches run (counted in appendix B): `Stepper(`/`COSStepper(` 4, `Slider(` 5, `TextField(` 40, `SecureField(` 3, `COSDropdown(` 45, `COSViewSwitch(` 15, `UserDefaults.standard` 117 | |

Category counts for the proposed layout are in section 3.

---

## 1. Inventory

### 1.1 Header, banners and top of panel (H)

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| H-01 | `v{version}` stamp | Views.swift:1323 | versionStamp | status | Info.plist via `ControllerModel.currentVersion` | Header only; not drawn when hosted in Activity | No | Panel and Settings window header |
| H-02 | Refresh status and check for updates (arrow icon, help text) | Views.swift:1334 | refreshAndCheckButton | action | `model.refreshAndCheckForUpdates()`: status refresh plus appcast check | None | No | Panel header; Activity Settings header (Views.swift:1909) |
| H-03 | "Your local glasses server" / Checking for updates… / Up to date / Couldn't check for updates | Views.swift:1345 | updateStatusLine | status | `HeaderUpdateStatus` | None. Activity host shows "Manage your Mac companion, voice, connected AI and preferences." | No | Header subtitle in all hosts |
| H-04 | "Archive live messages and start numbering at #1" (archivebox icon), confirm "Reset live message count?" / "Reset count" | Views.swift:1314, 792 | header, confirmResetMessageCount | action | `perform("reset-message-era")` | Disabled while busy. Not drawn when hosted in Activity | Yes: renumbers live messages; on COS Glasses older than 6.8.423 it clears the phone's chat list | Panel and Settings window header only |
| H-05 | Update banner: "Update available" / Update; "Finish installing X" / Install; "Downloading update"; "Installing update"; "Update did not install" / Try again; "Unstuck" | Views.swift:2966, 137; Models.swift:4345 | updateBanner, AppUpdateBanner | action, status | appcast; `model.appUpdateFlow`; `presentWhatsNew()` / `finishStagedAppUpdate()` | Only when the appcast offers a newer build or an update is in flight | Yes: Install quits and relaunches COS Control | Top of every host |
| H-06 | What's New window: Download and install, Cancel, Done | Views.swift:328 | WhatsNewView, WhatsNewWindowPresenter | action | `installAppUpdate` (stage, SHA check, swap) | Opened from H-05, or once after an update | Yes: relaunches | Own window |
| H-07 | Publisher notice (title, body, dismiss x) | Views.swift:2933 | noticeBanner | status, action | appcast notice; UserDefaults `dismissedNoticeIds` | Only when an undismissed notice exists | No | Top of every host |
| H-08 | "COS Control is in the Dock now." Menu bar only / Keep | ProviderConnectViews.swift:1192 | DockNoticeLine | action | `cos.dock.mode`, `cos.dock.noticeSeen` | Once, upgraders only | No | Top of every host |
| H-09 | Get started with COS | Views.swift:1953 | mainPanel | action | `model.openSetup` (Welcome window) | `status.needsFirstRun` | No | Top of every host |
| H-10 | Recording card: `{n} recording`, reminder, View live transcript, Stop and save (confirm "Stop and save this glasses meeting?"), "Enable live transcripts in Settings to view the recording." | Views.swift:1912, 1923, 1927, 819 | mainPanel recording card | status, action | helper `meeting-stop-request` | `recordingCount > 0`; Stop only with exactly one live glasses meeting; View only with MT-01 on | Yes: Stop ends a live glasses recording | Top of every host |
| H-11 | Activity · "Browse without losing your place" · Open, plus section chips | Views.swift:2016 | activityLauncher | action (navigation) | `openActivity` | Not drawn when hosted in Activity | No | Panel and Settings window |
| H-12 | Your move · `{n}` | Views.swift:1958 | mainPanel | action (navigation) | `openActivity(.work)` | `workYourMoveAvailable` and non-empty | No | Every host |

### 1.2 Server status card (ST)

`statusCard`, `Views.swift:1356`. Every row is read-only unless the Kind says action.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ST-01 | Server | Views.swift:1358 | statusRow, runtimeLabel | status | `status.runtimeState` | None | No | Status card |
| ST-02 | Ownership | Views.swift:1359 | ownershipLabel | status | `status.ownershipVerified` | None | No | Status card |
| ST-03 | Recovery (Scheduled / Needs repair) | Views.swift:1360 | statusRow | status | `status.recoveryLoaded` | None | No | Status card |
| ST-04 | Local transcription; Selected live preview; Selected saved meetings; "Your selected engines are kept. Check Transcription settings before recording." | Views.swift:1361-1368 | statusRow | status | helper `voice-status` (`voiceGuide.voice`) | Only when Parakeet is in use | No | Status card |
| ST-05 | Local Whisper, plus Whisper error line | Views.swift:1370, 1430 | whisperLabel | status | `status.whisperReady`, `whisperError` | When Parakeet is not in use | No | Status card |
| ST-06 | Memory & Threads; hint; Root / Looked in; dormant Python bridge note | Views.swift:1372-1387, 1797 | contextBrowserLabel, contextBrowserHint, contextDetail | status | `status.memoryAvailable`, `threadsAvailable`, `contextResolvedRoot` | `status.contextBrowserSupported` | No | Status card |
| ST-07 | Background jobs (Allowed / Off) | Views.swift:1388 | statusRow | status | `status.backgroundJobsEnabled` | `backgroundJobsSupported` | No | Status card |
| ST-08 | Meeting preview | Views.swift:1391 | statusRow | status | `status.meetingPreviewEnabled` | `meetingPreviewSupported` | No | Status card |
| ST-09 | Continue threads | Views.swift:1394 | statusRow | status | `status.threadAttachEnabled`, providers | `threadAttachSupported` | No | Status card |
| ST-10 | Video uploads; "Sideload or a killed upload can sit here for 4 hours and block Repair."; completed receipts await acknowledgment | Views.swift:1401-1420 | statusRow | status | `status.videoUploadV2*` | `videoUploadV2Supported` | No (its Clear stranded button is UT-10) | Status card |
| ST-11 | Idle Metal HQ (On · preemptible / Force CPU / Off · CPU) | Views.swift:1422 | statusRow | status | `status.idleMetalHqEnabled` | `idleMetalHqSupported` | No | Status card |
| ST-12 | Audio cleanup (Adaptive replay / Raw replay) | Views.swift:1426 | statusRow | status | `status.adaptiveAudioCleanupEnabled` | `adaptiveAudioCleanupSupported` | No | Status card |
| ST-13 | Transcription tier; Preview, while dictating; Commit, live meeting; Polish, on save; degraded reason; "Add names and specialist terms in the setup wizard to improve accuracy." | Views.swift:1438-1482 | transcriptionTierLabel, transcriptionModelLabel | status | `status.transcription*`, `livePreviewModel`, `liveCommitModel`, `hqPolishModel` | Not Parakeet, and the server reports models | No | Status card |
| ST-14 | Per live meeting audio row and caption | Views.swift:1484 | meetingAudio | status | `model.meetingAudio` | One row per live meeting | No | Status card |
| ST-15 | Meeting alerts "Off for COS Control" + Notification settings | Views.swift:1493-1499 | statusRow | status, action | `model.openNotificationSettings()` (System Settings) | Alerts off and a meeting is live | No | Status card |
| ST-16 | Meeting sync, up to 4 meeting rows, "+N more", meeting-work caption | Views.swift:1501-1532 | displayedMeetingSync, meetingSyncMeetings | status | `status.displayedMeetingSync` | None | No | Status card |
| ST-17 | Run sync now | Views.swift:1523 | statusCard | action | `perform("meeting-sync-now")` | Disabled while busy or meeting work blocks restart | No | Status card |
| ST-18 | Early meeting sync (Off / Ready / Claiming / Final sync pending / verified / Workspace update required) | Views.swift:1533-1563 | statusRow | status | `status.earlyMeetingSync*` | Only when the server reports it | No | Status card |
| ST-19 | HQ prefill, CPU guardrail line, unavailable line | Views.swift:1565-1586 | statusRow | status | `status.progressiveHq*` | Only when the server reports it | No | Status card |
| ST-20 | Finalization recovery / Library save (Repair required, N retrying, N pending) | Views.swift:1588-1606 | statusRow | status | `status.meetingFinalization*` | Pending or malformed > 0 | No | Status card |
| ST-21 | Retained captures, caption, "A retained server session does not mean..." | Views.swift:1611-1660 | unsavedCapturesLabel | status | `status.unsavedCaptures`, `recoverableOrphans`, `strandedCaptures` | Any retained capture | No | Status card |
| ST-22 | Recover all (confirm "Recover all unsaved captures?") and Recover per capture | Views.swift:1637, 1647, 801 | statusCard | action | `meeting-orphan-recover-all`, `meeting-orphan-recover --session` | Recover all only with more than one | No (makes meetings; files kept) | Status card |
| ST-23 | Save all (confirm "Save still-live captures as meetings?") and Save per capture | Views.swift:1663, 1674, 810 | statusCard | action | `meeting-stranded-save-all`, `meeting-stranded-save --session`; Mac captures re-deliver chunks | Save all only with more than one savable | Yes: finalizes a still-live G2 capture | Status card |
| ST-24 | Agent CLIs (Claude ✓ · Codex ✓ · Cursor ✓) + detail line | Views.swift:1688; ProviderConnectViews.swift:664 | agentCliSummary, AgentCliDetailLine | status | `status.claudeCliReady`, `codexCliReady`, helper `provider-status` | None | No | Status card |
| ST-25 | Cursor CLI | Views.swift:1692 | cursorLabel | status | `status.cursorState` | None | No | Status card |
| ST-26 | Ollama `{model}` | Views.swift:1696 | statusRow | status | `status.ollamaModel` | Only when Ollama is ready | No | Status card |
| ST-27 | Version (server) | Views.swift:1699 | statusRow | status | `status.version` / `installedVersion` | None | No | Status card |
| ST-28 | Work folder path; "Saved to LaunchAgent · pending a safe server restart" | Views.swift:1701-1710 | statusCard | status | `status.workDirectory`, `workDirectoryPending` | None | No | Status card |
| ST-29 | Meetings library path, layout and count; library warning | Views.swift:1711-1728 | statusCard | status | `status.operationsDirectory`, `meetingLibrary*` | None | No | Status card |
| ST-30 | "{n} job(s), {m} recording(s) active. Restart is locked." | Views.swift:1729 | statusCard | status | `status.activeJobs`, `activeTranscriptionSessions` | Any active work | No | Status card |
| ST-31 | "Server change in progress · recovery is armed" / "An interrupted server change needs Repair." | Views.swift:1733-1740 | statusCard | status | `status.transactionPending` | Pending transaction | No | Status card |

### 1.3 Server controls (C)

`controls`, `Views.swift:1819`. The whole row is disabled while `model.busy`.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C-01 | Restart; confirm "Restart this self-managed server?" / Restart now | Views.swift:1823, 745 | controls | action | `perform("restart")` | managedHealthy or managedInPlace; disabled with active jobs, recordings, a pending transaction or blocking meeting work; confirm only for self-managed without proof of idle | Yes: restarts the server | Under status card |
| C-02 | Stop | Views.swift:1833 | controls | action | `perform("stop")` | managedHealthy or managedInPlace; disabled when self-managed and not safe | Yes: stops the server | Under status card |
| C-03 | Start | Views.swift:1837 | controls | action | `perform("start")` | runtimeState stopped | No | Under status card |
| C-04 | Update Server | Views.swift:1841 | controls | action | `perform("update")` | installed, managed contract, ownership verified; disabled when meeting work blocks restart | Yes: replaces and restarts the server | Under status card; also ProviderConnectViews.swift:484, ActivityMeetings.swift:1149 and 1568, ActivityWindow.swift:2803 |
| C-05 | Install Server | Views.swift:1844 | controls | action | `installCurrentRelease()` = `perform("install", --version)` | notInstalled | No | Under status card |
| C-06 | Adopt Safely | Views.swift:1856 | controls | action | `perform("adopt", --version)` | legacyStopped | Yes: replaces the legacy LaunchAgent | Under status card |
| C-07 | Manage in place | Views.swift:1864 | controls | action | `perform("adopt-in-place")` | legacyService | No | Under status card |
| C-08 | Install managed server; confirm "Install the latest managed server?" / Stop legacy and install | Views.swift:1866, 754 | controls | action | `installLatestManagedFromLegacy()` = `perform("adopt")` | legacyService; disabled with active work | Yes: stops the checkout LaunchAgent | Under status card |
| C-09 | Foreground-server warning, ownership conflict, operation progress, green notice | Views.swift:1848-1883 | controls | status | `status.runtimeState`, `ownerConflict`, `operationProgress`, `notice` | Conditional | No | Under status card |

### 1.4 Setup guide (SG)

The panel shows one "Setup guide" line (`PanelConnectAIRow`) that opens `ProviderConnectCard` in place, which draws `SetupGuideView`. The same `SetupGuideView` is the Welcome window's guide step (`ControlSetup.swift:167`).

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SG-01 | Setup guide · `{summary}` row; card header "Setup guide" + Done | ProviderConnectViews.swift:345, 314, 326 | PanelConnectAIRow, ProviderConnectCard | action (navigation), status | `guide.panelRouteActive` | None | No | Panel line; Welcome window |
| SG-02 | Your devices: Just my Mac / My Mac and glasses | ProviderConnectViews.swift:997, 1237; ProviderConnectModel.swift:1218 | SetupDeviceChoice | picker | `cos.setupGuide.devicePath` | None | No (changes the guide only) | Setup guide |
| SG-03 | Your AI rows (Claude Code, Codex, Cursor Agent): Get X, Copy, Sign in, Open Terminal again, Stop waiting, Check again, Skip for now / Set up now, Pass to X | ProviderConnectViews.swift:118, 164-205, 1001, 1004 | ProviderRowView | action, status | helper `provider-status`; `cos.connectAI.skipped` | Polls only while on screen | No (opens Terminal or the app) | Setup guide |
| SG-04 | Ollama row: Get Ollama / open Ollama, Skip for now | ProviderConnectViews.swift:745, 851 | SetupRowView | action, status | Ollama app or download page; `cos.setupGuide.skipped` | None | No | Setup guide, "On this Mac" |
| SG-05 | Voice (local transcription) row: tier action, Voice switch Automatic / Balanced / Max, Or run it in Terminal, Test this Mac again, Transcription settings, Cancel, Skip for now | ProviderConnectViews.swift:798-838, 855-857 | SetupRowView.voiceControls | action, picker | helper `voice-setup`, `voice-apply-recommendation`, `set-transcription-tier` | Tier controls only when not Parakeet | Yes: applying a tier restarts the server | Setup guide, "On this Mac" |
| SG-06 | Dictation engine row: Dictation engine (Automatic / Parakeet Ultra / Whisper), Test on this Mac / Test again / Test, Parakeet progress and Cancel | ProviderConnectViews.swift:875, 907, 927, 943 | DictationEngineControls | picker, action | `set-stt-settings` dictation; `install-parakeet` | Server 6.74.0 (`dictationSelected`); Test disabled while recording | No | Setup guide, "On this Mac" |
| SG-07 | Show your AI sessions row (Turn on) | ProviderConnectModel.swift:971; ProviderConnectViews.swift:861 | SetupRowView | action | `setClaudeSessionsEnabled(true)` = `set-claude-sessions on` | None | Yes: restarts server | Setup guide, "Settings for your AI" |
| SG-08 | Continue agent threads row (Turn on) | ProviderConnectModel.swift:981; ProviderConnectViews.swift:862 | SetupRowView | action | `set-thread-attach on` | `threadAttachSupported` | Yes: restarts server | Setup guide, "Settings for your AI" |
| SG-09 | Work suggestions row (opens Decision models, Check) | ProviderConnectModel.swift:1000; ProviderConnectViews.swift:863-864 | SetupRowView | action, status | `showDecisionKeySettings`; `workKeys.checkNow()` | Server running | No | Setup guide, "Settings for your AI" |
| SG-10 | Permissions row (opens Permissions) | ProviderConnectModel.swift:988; ProviderConnectViews.swift:865 | SetupRowView | action, status | `permissionGuide.openInPanel()` | None | No | Setup guide, "Settings for your AI" |
| SG-11 | Glasses: Tailscale on this Mac (Get Tailscale / Open Tailscale), Tailscale on your iPhone (QR), Connect your glasses (pairing QR, code, Show a new code, Try again, Pair another phone, Allow, Deny, Update Server) | ProviderConnectViews.swift:432-562 | GlassesSetupRows | action, status | helper `tailscale-status`, `tailscale-whois`, `pairing-code`, `pairing-status`, `pairing-decision` | Device path is glasses; server 6.67.0 `pairingSupported`; polls only on screen | Allow gives that phone full access to COS on this Mac | Setup guide, "Glasses" |
| SG-12 | Allow pairing on this Wi-Fi (home only) | ProviderConnectViews.swift:530 | GlassesSetupRows.lanToggle | toggle | `pairing-code --allow-lan` (10 minutes) | Code or no-hosts stage | Security: lets a phone on this Wi-Fi pair without Tailscale | Setup guide, "Glasses" |
| SG-13 | The COS app for your glasses | ProviderConnectViews.swift:1031 | SetupGuideView | action (web) | `GuideExtras.glassesWizardURL` | Device path is glasses | No | Setup guide |
| SG-14 | Hide setup guide / Show Finish setup at the top again | ProviderConnectViews.swift:1036-1040 | SetupGuideView | toggle | `cos.setupGuide.hidden` | None | No | Setup guide footer |
| SG-15 | Finish setup · N of M, progress bar, Next line, Continue setup, Hide | ProviderConnectViews.swift:1067-1108 | FinishSetupCard | status, action | `cos.setupGuide.hidden` | Until every row is done or skipped | No | Top of every host |

### 1.5 Permissions (PM)

`PanelPermissionsRow` opens `PermissionGuideCard` in place. Rows come from `PermissionGuideModel.swift:256-401`.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| PM-01 | Permissions · `{summary}`; card "Each one switches on a feature. COS works without any of them." + Done | PermissionGuideViews.swift:168, 143 | PanelPermissionsRow, PermissionGuideCard | action (navigation), status | `guide.panelRouteActive` | None | No | Panel line; Welcome window step |
| PM-02 | Accessibility (action, "Already on? Reset and add again") | PermissionGuideModel.swift:256; PermissionGuideViews.swift:62, 68 | PermissionRowView | action, status | System Settings Accessibility; drag flow; TCC reset | None | Reset removes this build's Accessibility row and asks again | Permissions card |
| PM-03 | Notifications (Allow) | PermissionGuideModel.swift:272 | PermissionRowView | action, status | UNUserNotificationCenter; System Settings | None | No | Permissions card |
| PM-04 | Open at login (Turn on / open Login Items) | PermissionGuideModel.swift:293 | PermissionRowView | action, status | SMAppService | None | No | Permissions card |
| PM-05 | Background jobs (name) / Glasses server (name) | PermissionGuideModel.swift:326 | PermissionRowView | action, status | Login Items approval | Per registered agent | No | Permissions card |
| PM-06 | Automation: Claude / Cursor / Terminal (Test) | PermissionGuideModel.swift:374 | PermissionRowView | action, status | Apple Events consent | None | No | Permissions card |
| PM-07 | Calendar (CalendarFetch) (Fix) | PermissionGuideModel.swift:401 | PermissionRowView | action, status | launches CalendarFetch.app | None | No | Permissions card |
| PM-08 | Clean up old COS test builds; per build Reset | PermissionGuideViews.swift:101-130 | StaleBuildsSection | action | TCC reset per bundle ID | Found only when asked | Yes: removes that build's Accessibility row | Permissions card |

### 1.6 Morning brief (MB)

`morningBriefCard`, `Views.swift:2396`. Gate for the card: `status.morningBriefSupported` (server 6.43.0). Edits a draft; Apply saves it in one PUT.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MB-01 | MORNING BRIEF status line (Next …, Off while Background jobs are off, Paused for maintenance, Daily at …, Off) | Views.swift:2423, 2432 | morningBriefHeader | status | `morning-brief`; `status.morningBriefGate` | Card gate | No | Morning brief card |
| MB-02 | Brief every | Views.swift:2459 | morningBriefSchedule | toggle (Apply) | draft `enabled` | Card gate | No | Morning brief card |
| MB-03 | Time field (07:00) + time zone | Views.swift:2465 | morningBriefSchedule | field (Apply) | draft `time` | Card gate | No | Morning brief card |
| MB-04 | Weekday chips M T W T F S S | Views.swift:2489 | morningBriefWeekdays | toggle set (Apply) | draft `days` | Card gate | No | Morning brief card |
| MB-05 | Sources · N on; one checkbox per source with description and coverage | Views.swift:2507, 2526 | morningBriefSources, morningBriefSourceRow | toggle list (Apply) | draft `sources[].enabled`; server-supplied spec | Card gate; list comes from the server | No | Morning brief card, disclosure |
| MB-06 | Per-source options (boolean checkbox, integer stepper, text field) | Views.swift:2563-2587 | morningBriefOption | mixed (Apply) | draft `sources[].options` | Source on and the server lists options | No | Morning brief card, disclosure |
| MB-07 | Apply | Views.swift:2592 | morningBriefActions | action | `set-morning-brief` (stdin JSON) | Disabled while busy | No | Morning brief card |
| MB-08 | Run Now | Views.swift:2596 | morningBriefActions | action | `run-morning-brief` | Background jobs on and server managedHealthy; five a day | No (spends a brief) | Morning brief card |
| MB-09 | Last brief line; Retry; Loading the schedule… | Views.swift:2605, 2444-2453 | morningBriefRunLabel, morningBriefPlaceholder | status, action | `morningBrief.runs` | Card gate | No | Morning brief card |

### 1.7 Domains (DM), fenced threads (FN), Doctor (DR)

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DM-01 | Domains: one "domain" field per name; empty-state line | Views.swift:2317, 2330 | domainsCard | field list (Save) | `domains` read; local draft | `status.tasksGate != nil` | No | Domains card |
| DM-02 | Move up, Remove (per row) | Views.swift:2336, 2342 | domainsCard | action (draft) | local draft | Card gate | No (unlists only; folder stays) | Domains card |
| DM-03 | Add, Save, Reset | Views.swift:2350-2353 | domainsCard, saveDomainsDraft | action | `set-domains --name …` (writes `.cos-profile.json`) | Card gate | No | Domains card |
| FN-01 | Fenced threads · N, explanation, degraded warning, Refresh | Views.swift:2116-2147 | fencesCard | status, action | `model.loadFences()` | Only when a fence exists | No | Fenced threads card |
| FN-02 | Release (per fence); confirm "Release this fence?" / Release | Views.swift:2151, 736 | fencesCard, fenceConfirmActions | action | `releaseFence(confirm: true)` | Card gate | Yes: COS writes to the thread again; a lost turn can land twice | Fenced threads card |
| DR-01 | DOCTOR results (name, detail, state per check) | Views.swift:2638 | doctorCard | status | `model.doctorChecks` from `perform("doctor")` | Only after Run Doctor (UT-01) returns checks | No | Doctor card |

### 1.8 Meeting assistant and live cues (MA)

`MeetingAskSettings`, `MeetingAsk.swift:516` (anchor `settings`).

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MA-01 | Meeting assistant · Model | MeetingAsk.swift:525, 998 | MeetingAskModelControl | picker | helper `meeting-ask` op `configure` | Locked while a change is pending, the server is offline, or on another protocol | No | Meeting assistant card; also the Live COS Ask panel (compact) |
| MA-02 | "Public web lookup uses …" / "Public web lookup unavailable: …" | MeetingAsk.swift:528 | MeetingAskSettings | status | `config.web` | Server answered | No | Meeting assistant card |
| MA-03 | Unavailable models (N) | MeetingAsk.swift:531, 953 | MeetingAskModelDetails | status (disclosure) | `config.models` | Any unavailable model | No | Meeting assistant card |
| MA-04 | Refresh connected models | MeetingAsk.swift:534 | MeetingAskSettings | action | `refreshConfig`, `home-area` | None | No | Meeting assistant card |
| MA-05 | Home city field (Austin, TX) + Save; effective line; refusal | MeetingAsk.swift:547, 558, 563 | HomeCitySettings | field | `home-area` / `set-home-area` | Server 6.71.13 (hidden on 404 or before an answer) | No | Meeting assistant card |
| MA-06 | Live cues switch, state line, note | MeetingAsk.swift:600 | LiveCuesSettingsRow | toggle | `live-cues-settings --set on/off` | Drawn when the server answered; disabled when set in server env | No (spends model calls when on) | Meeting assistant card |
| MA-07 | Add a Jev or SubQ key / Check again | MeetingAsk.swift:621, 624 | LiveCuesSettingsRow | action | scrolls to `decision-models`; reload | Depends on cue state | No | Meeting assistant card |
| MA-08 | Bar slider (More cues / Fewer cues) | MeetingAsk.swift:682-707 | LiveCuesLimitsRows.bar | slider | `live-cues-settings --gate` (debounced) | Server 6.79.2; locked "Set in .env" | No | Meeting assistant card |
| MA-09 | Max cues per meeting | MeetingAsk.swift:720-729 | LiveCuesLimitsRows.stepper | stepper | `--max-cues` | Server 6.79.2; env lock | No | Meeting assistant card |
| MA-10 | Minimum gap between cues | MeetingAsk.swift:720-729 | LiveCuesLimitsRows.stepper | stepper | `--cooldown-seconds` | Server 6.79.2; env lock | No | Meeting assistant card |
| MA-11 | Daily writer limit | MeetingAsk.swift:720-729 | LiveCuesLimitsRows.stepper | stepper | `--daily-writer-calls` | Server 6.79.2; env lock | No | Meeting assistant card |
| MA-12 | Saving… line, limits note, today's usage line | MeetingAsk.swift:658-666 | LiveCuesLimitsRows | status | `limits.usage` | Server 6.79.2 | No | Meeting assistant card |
| MA-13 | "Cues also need Live Cues on in the glasses app." | MeetingAsk.swift:634 | LiveCuesSettingsRow | status | static | None | No | Meeting assistant card |

### 1.9 Transcription (TR)

`TranscriptionSettingsCard`, `MeetingAsk.swift:738` (anchor `transcription`). Hidden on a server without the route (404) and until it answers (server 6.72.0). Every change is one PUT through `set-stt-settings`; refusals show in the server's words. Controls lock while a change is pending.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| TR-01 | Dictation engine, plus its line | MeetingAsk.swift:822-836 | dictationPicker | picker | `set-stt-settings` key `dictation` | Server 6.74.0, else one line says Parakeet only | No | Transcription card |
| TR-02 | Preview model, plus its line | MeetingAsk.swift:758 | picker | picker | key `preview` | Card gate | No | Transcription card |
| TR-03 | HQ model, plus its line | MeetingAsk.swift:760 | picker | picker | key `hq` | Card gate | No | Transcription card |
| TR-04 | Second opinion, plus its line | MeetingAsk.swift:762 | picker | picker | key `secondOpinion` | Card gate | No | Transcription card |
| TR-05 | When-it-applies line; server refusal | MeetingAsk.swift:764-770 | card | status | `Transcription.appliesLine` | Card gate | No | Transcription card |
| TR-06 | Refine with second opinion, plus inactive line | MeetingAsk.swift:771, 778 | card | toggle | key `resolver` | Card gate | No | Transcription card |
| TR-07 | Parakeet row: Install Parakeet (654 MB), Cancel, Check again, Use Whisper; Licenses | MeetingAsk.swift:842-853, 905-939, 889 | parakeetRow, ParakeetRowView, LicensesLink | action, status | `install-parakeet`, `cancel-parakeet-install`; `openLicenses()` | Never offered while recording | No (large download) | Transcription card |
| TR-08 | Advanced · Front end | MeetingAsk.swift:782 | picker | picker | key `frontEnd` | Card gate | No | Transcription card, Advanced disclosure |
| TR-09 | Advanced · Quiet detection | MeetingAsk.swift:783 | picker | picker | key `quietGate` | Card gate | No | Transcription card, Advanced disclosure |
| TR-10 | Panel line "Dictation" with the Parakeet row | MeetingAsk.swift:859 | PanelParakeetRow | action, status | same as TR-07 | Dictation on and Parakeet not installed or installing | No | Panel |

### 1.10 Key lanes (KL)

`KeyLanesSettingsRow`, `KeyLanesViews.swift:21` (anchor `key-lanes`). Drawn only for a server 6.80.0 or later, when lanes are on, when keys are saved on this Mac, or while an install is blocked. Every call is helper `key-lanes <verb>`.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| KL-01 | Answer with your own key, plus on/off line | KeyLanesViews.swift:35, 42 | KeyLanesSettingsRow | toggle | `key-lanes enable` / `disable` | Server 6.80.0 or lanes already on | No | Key lanes card |
| KL-02 | Downgrade line + Remove saved keys and continue (confirm) | KeyLanesViews.swift:47-52 | KeyLanesSettingsRow | action | `remove-saved-keys`, then the blocked install | An install below 6.80.0 is waiting | Yes: deletes saved keys | Key lanes card |
| KL-03 | Saved keys line + Remove saved keys (confirm) | KeyLanesViews.swift:56-61 | KeyLanesSettingsRow | action | `remove-saved-keys` | Lanes off and keys saved | Yes: deletes saved keys | Key lanes card |
| KL-04 | Per key: key line, cap line, no-provider-limit line, local-first line, glasses hint | KeyLanesViews.swift:113-120, 147-152 | KeyLanesSetupPanel.keyRow | status | `key-lanes status` | Lanes on | No | Key lanes card |
| KL-05 | Reset pause | KeyLanesViews.swift:159 | keyRow | action | `reset-breaker --ref` | Breaker open | No | Key lanes card |
| KL-06 | Model (per key) | KeyLanesViews.swift:164 | keyRow | picker | `save-profile` | A usable model exists | No | Key lanes card |
| KL-07 | Use for answers | KeyLanesViews.swift:173 | keyRow | toggle | `save-profile` enabled | Profile exists | No | Key lanes card |
| KL-08 | Daily cap (USD) + Set cap | KeyLanesViews.swift:178, 182 | keyRow | field, action | `set-cap --ref --cap` ($0.01 to $1000) | Lanes on | No | Key lanes card |
| KL-09 | Remove (per key); confirm "Remove this key?" | KeyLanesViews.swift:188-196 | keyRow | action | `remove-key --force`, `delete-profile` | Lanes on | Yes: deletes the key and its profile | Key lanes card |
| KL-10 | Key from | KeyLanesViews.swift:205 | addKey | picker | in memory | Lanes on and an engine is installed | No | Key lanes card |
| KL-11 | Paste key | KeyLanesViews.swift:208 | addKey | action | clipboard read, then cleared | Lanes on | No | Key lanes card |
| KL-12 | Cap $ field | KeyLanesViews.swift:218 | addKey | field | in memory | Lanes on | No | Key lanes card |
| KL-13 | Save key | KeyLanesViews.swift:219 | addKey | action | `save-key` (stdin) | A key was pasted | No | Key lanes card |
| KL-14 | Remove all keys (confirm) | KeyLanesViews.swift:134-138 | KeyLanesSetupPanel | action | `remove-all` (optionally `--export-ledger`) | A key is saved | Yes: deletes every key | Key lanes card |
| KL-15 | Save the spend ledger to Downloads first | KeyLanesViews.swift:141 | KeyLanesSetupPanel | toggle | in memory (default on) | A key is saved | No | Key lanes card |

### 1.11 Tools (UT)

`utilities`, `Views.swift:2668`, headed TOOLS. The whole block is disabled while `model.busy`. "Installed" below means `status.installed || runtimeState == managedInPlace`.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| UT-01 | Run Doctor | Views.swift:2672 | utilities | action | `perform("doctor")` | None | No | Tools |
| UT-02 | Guided Setup; confirm "Choose transcription setup" Balanced (Recommended) / Max | Views.swift:2673, 767; ControllerModel.swift:2358 | utilities, runGuidedSetup | action | opens Terminal with the server's setup command | None | No (opens Terminal) | Tools |
| UT-03 | Transcription Balanced / Max + Apply; "Update Server to 6.21.0 or newer…" | Views.swift:2677, 2680, 2688 | utilities | picker (Apply) | `set-transcription-tier` | Server 6.21.0 (`transcriptionRequestedTier` present); installed | Yes: restarts server | Tools |
| UT-04 | Background jobs + Apply | Views.swift:2694, 2696 | utilities | toggle (Apply) | `set-background-jobs on/off` | `backgroundJobsSupported`; installed; no active work | Yes: restarts server; machine-wide | Tools |
| UT-05 | Meeting Turbo preview + Apply | Views.swift:2707, 2709 | utilities | toggle (Apply) | `set-meeting-preview` | `meetingPreviewSupported`; installed; no active work | Yes: restarts server | Tools |
| UT-06 | Show Claude sessions + Apply | Views.swift:2719, 2721 | utilities | toggle (Apply) | `set-claude-sessions` | Installed (value seeds from status, server 6.36.22) | Yes: restarts server. Privacy: serves session names over the local network | Tools |
| UT-07 | Continue agent threads + Apply | Views.swift:2730, 2732 | utilities | toggle (Apply) | `set-thread-attach` | `threadAttachSupported` (6.37); installed; no active work | Yes: restarts server | Tools |
| UT-08 | Local model + Apply (Automatic (newest pull) / pulled tags / pin "not pulled") | Views.swift:2743, 2744, 2660 | utilities, ollamaModelOptions | picker (Apply) | `set-ollama-model`; `ollama-tags` | Ollama ready, pinned or tags found; installed | Yes: restarts server | Tools |
| UT-09 | Reliable video uploads (beta) + Apply | Views.swift:2757, 2759 | utilities | toggle (Apply) | `set-video-upload-v2` | `videoUploadV2Supported`; installed; no upload in progress | Yes: restarts server | Tools |
| UT-10 | Clear stranded; confirm "Clear stranded video uploads?" | Views.swift:2764, 1412, 783 | utilities, statusCard | action | `clear-stranded-video-uploads` | A draft is receiving | Yes: cancels drafts idle 60 s | Tools and status card |
| UT-11 | Idle Metal HQ + Apply | Views.swift:2774, 2776 | utilities | toggle (Apply) | `set-idle-metal-hq` | `idleMetalHqSupported`; installed; no active work | Yes: restarts server | Tools |
| UT-12 | Adaptive audio cleanup + Apply | Views.swift:2787, 2789 | utilities | toggle (Apply) | `set-adaptive-audio-cleanup` | `adaptiveAudioCleanupSupported`; installed; no active work | Yes: restarts server | Tools |
| UT-13 | Repair Managed Runtime | Views.swift:2799 | utilities | action | `perform("repair")` | Installed, no owner conflict, not legacyForeground | Yes: repairs and restarts | Tools |
| UT-14 | Repair Whisper | Views.swift:2802 | utilities | action | `perform("restart-whisper")` | Managed and owned, Whisper not ready or circuit open | Yes: restarts Whisper | Tools |
| UT-15 | Work Folder | Views.swift:2807; ControllerModel.swift:2001 | selectWorkFolder | action (folder) | `set-workdir <path>` | Installed | Yes: restarts server (or waits for a safe restart) | Tools |
| UT-16 | Meetings Library; guidance confirm "Meetings Library" Choose Again / View Examples / Skip for Now | Views.swift:2812, 715; ControllerModel.swift:2013 | selectOperationsFolder | action (folder) | `set-operations-dir <path>` | Installed | Yes: restarts server | Tools |
| UT-17 | COS Data | Views.swift:2817; ControllerModel.swift:2028 | selectContextFolder | action (folder) | `set-context-dir <path>` | Installed | Yes: restarts server | Tools |
| UT-18 | Create Folders | Views.swift:2827 | utilities | action | `perform("create-context-folders")` | No store resolved; installed | No | Tools |
| UT-19 | Bridge: / Notes: path | Views.swift:2832-2838 | utilities | status | `status.contextScriptsDirectory`, `contextFilesDirectory` | One of them set | No | Tools |
| UT-20 | Open Cursor | Views.swift:2841 | openCursor | action | opens Cursor on the work folder | None | No | Tools |
| UT-21 | Copy Pairing Token | Views.swift:2842 | utilities | action | `perform("token")` | managedHealthy | Security: puts the pairing token on the clipboard | Tools |
| UT-22 | Copy Report | Views.swift:2846 | utilities | action | `perform("report")` | None | No | Tools |
| UT-23 | Open Logs | Views.swift:2847 | openLogs | action | `~/Library/Logs/COS Glasses` | None | No | Tools |
| UT-24 | Health | Views.swift:2848 | openHealth | action | opens `http://127.0.0.1:3141/api/health` | None | No | Tools |
| UT-25 | Advanced · Clock (12-hour / 24-hour) | Views.swift:2904 | utilities | picker | `cos.clockStyle` | None | No | Tools, Advanced disclosure |
| UT-26 | Advanced · Rollback Server | Views.swift:2913 | utilities | action | `perform("rollback")` | None (no confirm today) | Yes: swaps the server back a version | Tools, Advanced disclosure |
| UT-27 | Advanced · Reconcile Change | Views.swift:2914 | utilities | action | `perform("reconcile")` | None | Yes: finishes or rolls back a pending server change | Tools, Advanced disclosure |
| UT-28 | Advanced · Setup Guide | Views.swift:2915; ControllerModel.swift:2046 | openSetupGuide | action (web) | opens `https://gotcos.com/control/` | None | No | Tools, Advanced disclosure |

### 1.12 General app options (G)

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| G-01 | Launch COS Control at login | Views.swift:2851; ControllerModel.swift:2383 | setLaunchAtLogin | toggle | `SMAppService.mainApp` | None | No | Tools |
| G-02 | Show in menu bar only | Views.swift:2854; ControllerModel.swift:935 | setShowInDock | toggle | `cos.dock.mode` | None | No | Tools |
| G-03 | Open Activity with `{chord}` · Record / Cancel · Off | Views.swift:4673; ControllerModel.swift:2374 | HotKeyRecorderRow | shortcut | `activityHotKey.enabled`, `.keyCode`, `.modifiers` | Refuses a chord dictation uses | No | Tools |
| G-04 | Quit | Views.swift:2995 | footer | action | `AppQuit.request()` | None | Yes: quits COS Control (recordings and dictation stop) | Footer |
| G-05 | Controller X • Server Y (npm latest) / self-managed / not installed | Views.swift:2986, 3003 | footerLabel | status | Info.plist; `status.version` | None | No | Footer |

### 1.13 Dictation (DI)

`MacDictationSettings`, `MacDictation.swift:4090`. It renders twice: inside Tools in the panel (`Views.swift:2858`) and as Activity › Dictation › Settings (`DictationSettingsPane`, `MacDictation.swift:5322`, route `dictationSettingsRouteActive`). Rows DI-02 to DI-31 draw only while DI-01 is on. All local keys are UserDefaults on this Mac.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DI-01 | Dictate into Mac apps, plus explainer | MacDictation.swift:4113 | MacDictationSettings | toggle | `dictation.enabled` | Disabled while dictating | No | Tools; Dictation settings pane |
| DI-02 | Microphone (System default / devices / "Selected microphone disconnected") | MacDictation.swift:4117 | microphoneOptions | picker | `dictation.microphoneUID` | DI-01 on | No | Same two places |
| DI-03 | Refresh microphones | MacDictation.swift:4118 | MacDictationSettings | action | CoreAudio device list | DI-01 on | No | Same two places |
| DI-04 | If the microphone fails, try another one; note; "Last time …" | MacDictation.swift:4120-4123 | MacDictationSettings | toggle | `dictation.micFallback` | Enabled only with System default | No | Same two places |
| DI-05 | Push to talk · Change / Cancel · Off | MacDictation.swift:4124, 4250 | DictationShortcutRow (.hold) | shortcut | `dictation.hold.enabled/.kind/.key/.modifiers` | Must differ from the others and Open Activity | No | Same two places |
| DI-06 | Start / stop · Change / Cancel · Off | MacDictation.swift:4125 | DictationShortcutRow (.toggle) | shortcut | `dictation.toggle.*` | Same | No | Same two places |
| DI-07 | Fix last dictation · Change / Cancel · Off | MacDictation.swift:4126 | DictationShortcutRow (.fix) | shortcut | `dictation.fix.*` | Same | No | Same two places |
| DI-08 | Allow insertion into other apps… | MacDictation.swift:4127 | requestInsertionPermission | action | Accessibility prompt | DI-01 on | No | Same two places |
| DI-09 | Sound · Start (Pet's sound / library / Your file / Your own file…) + Preview | MacDictation.swift:6328, 6329 | DictationSoundSettings | picker, action | `dictation.sound.start` | DI-01 on | No | Same two places |
| DI-10 | Sound · Stop + Preview | MacDictation.swift:6328, 6329 | DictationSoundSettings | picker, action | `dictation.sound.stop` | DI-01 on | No | Same two places |
| DI-11 | Import panel: Preview, Save, Cancel; Use the end of this file | MacDictation.swift:6296-6308, 6301 | importPanel | action, toggle | `dictation-sounds` folder | After "Your own file…"; the toggle only for Stop | No | Same two places |
| DI-12 | Volume (Off at 0) | MacDictation.swift:6335 | DictationSoundSettings | slider | `dictation.sound.volume` | DI-01 on | No | Same two places |
| DI-13 | Pitch (semitones) | MacDictation.swift:6340 | DictationSoundSettings | slider | `dictation.sound.pitch` | DI-01 on | No | Same two places |
| DI-14 | "Sounds paused after an audio error." + Play sounds again | MacDictation.swift:4130-4133 | MacDictationSettings | status, action | sound breaker | Breaker tripped | No | Same two places |
| DI-15 | While dictating (Mute other apps / Lower other audio / Off) | MacDictation.swift:4221 | DictationQuietSettings | picker | `dictation.quiet` | DI-01 on | No | Same two places |
| DI-16 | Allow System Audio Recording… / Check System Audio Recording… / Mute again; muting notes | MacDictation.swift:4224-4245 | DictationQuietSettings | action, status | System Audio Recording TCC; mute breaker | Mute chosen and not permitted, paused, or noted | No | Same two places |
| DI-17 | Restore my clipboard after pasting | MacDictation.swift:4135 | MacDictationSettings | toggle | `dictation.restoreClipboard` | DI-01 on | No | Same two places |
| DI-18 | Learn from my edits (Save automatically / Suggest only / Off) + note | MacDictation.swift:4137 | MacDictationSettings | picker | `dictation.learnMode` | DI-01 on | No | Same two places |
| DI-19 | Spell words the way the text box has them + note | MacDictation.swift:4141-4144 | MacDictationSettings | toggle | `dictation.fieldContext` | DI-01 on | No (reads nearby text, never saved) | Same two places |
| DI-20 | Format spoken lists | MacDictation.swift:4145 | MacDictationSettings | toggle | `dictation.formatLists` | DI-01 on | No | Same two places |
| DI-21 | Remove filler sounds (um, uh) before typing + note | MacDictation.swift:4148 | MacDictationSettings | toggle | `dictation.removeFillers` | DI-01 on | No | Same two places |
| DI-22 | Capitalize the start of a sentence + note | MacDictation.swift:4150 | MacDictationSettings | toggle | `dictation.capitalizeStart` | DI-01 on | No | Same two places |
| DI-23 | AI polish (Off / Claude Haiku / Claude Sonnet), model line, note, pause line | MacDictation.swift:4153-4167 | MacDictationSettings | picker | `dictation.polishModel`; helper `dictation-polish` | DI-01 on | No (spends model calls) | Same two places |
| DI-24 | Paste right away, then polish in place + note | MacDictation.swift:4169 | MacDictationSettings | toggle | `dictation.pasteThenPolish` | Disabled when polish is Off | No | Same two places |
| DI-25 | Wait for ⌘ or ⌃ to be released before swapping in polish + note | MacDictation.swift:4174 | MacDictationSettings | toggle | `dictation.swapWaitForKeys` | Disabled unless polish on and DI-24 on | No | Same two places |
| DI-26 | Your polish instructions: editor, counter, Clear, Save, "See the built-in rules", Try again | MacDictation.swift:5560-5645 | DictationPolishInstructionsCard | field, action | helper `dictation-polish-instructions` (stdin) | Server 6.85.0 advertises it | No | Same two places |
| DI-27 | Your style · Learn my style from edits, status lines | MacDictation.swift:5779-5785 | DictationStyleCard | toggle | `dictation-style.json`; helper `dictation-learned-style` | Server 6.91.0 for the push | No | Same two places |
| DI-28 | Style rules: Active (Remove), Suggested (Add, Dismiss), Pending | MacDictation.swift:5786-5805 | DictationStyleCard.section | action | same | Any rule | No | Same two places |
| DI-29 | Add a rule (Choose a rule) + Add | MacDictation.swift:5807-5815 | DictationStyleCard | picker, action | same | Templates from the server allowlist | No | Same two places |
| DI-30 | Reset learned style (confirm) | MacDictation.swift:5817, 5837 | DictationStyleCard | action | same | Any rule | Yes: deletes every style rule here and on the server | Same two places |
| DI-31 | Previous polish (v3) + note / set on server | MacDictation.swift:5820-5825 | DictationStyleCard | toggle | helper `dictation-polish-options` `promptVersion` | Server reports a prompt version; locked by server env | No | Same two places |
| DI-32 | Keep dictations for (7 days / 30 days / 90 days / Forever / Don't keep); confirm "Stop keeping dictations?" | MacDictation.swift:4186, 4194 | retentionChoice | picker | `dictation.history.retention` | Disabled while dictating | Yes: Don't keep deletes kept history | Same two places |
| DI-33 | Clear dictation history (confirm) | MacDictation.swift:4189, 4203 | MacDictationSettings | action | history file | Some history exists | Yes: deletes all kept dictations | Same two places |
| DI-34 | Shortcut and paste explainer; amber message line | MacDictation.swift:4181-4183 | MacDictationSettings | status | static, `store.message` | DI-01 on | No | Same two places |
| DI-35 | Dictation settings pane: title + Close; openers "Settings" and "Turn it on in Dictation settings" in the Dictation tab | MacDictation.swift:5322-5331, 5362, 5366 | DictationSettingsPane, DictationActivityPane | action (navigation) | `openDictationSettings()` / `closeDictationSettings()` | None | No | Activity › Dictation |

### 1.14 Session pet (PT)

`sessionPetSettings`, `Views.swift:1184`, a disclosure in Tools. Rows PT-02 to PT-13 draw only while the pet is on.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| PT-01 | Session pet disclosure (On · size · % size · % speed · motion / Off) + Session pet switch | Views.swift:1185-1191, 1275 | sessionPetSettings, setPetEnabled | toggle | `cos.sessionPetEnabled` | None | No | Tools |
| PT-02 | Jump to session needs Accessibility; Grant; Reset and add again | Views.swift:1196-1217 | sessionPetSettings | action, status | Accessibility TCC | Pet on and jump not trusted | Reset removes the old Accessibility entry | Tools |
| PT-03 | Pet size (presets incl. Custom) | Views.swift:4852 | PetSizeControls | picker | `cos.sessionPetSize` | Pet on | No | Tools |
| PT-04 | Custom pixels field + stepper (px) | Views.swift:4858, 4866 | PetSizeControls | field, stepper | `cos.sessionPetSizePixels` | Preset Custom | No | Tools |
| PT-05 | Character size slider | Views.swift:4885 | PetSizeControls | slider | `cos.sessionPetCharacterPercent` | Pet on | No | Tools |
| PT-06 | Character speed slider | Views.swift:4907 | PetSizeControls | slider | `cos.sessionPetAnimationSpeedPercent` | Pet on | No | Tools |
| PT-07 | Motion (Full / Calm / None) | Views.swift:4925 | PetSizeControls | picker | `cos.sessionPetCalmMotion`, `cos.sessionPetNoMotion` | Pet on | No | Tools; also the pet's right-click menu (PT-15) |
| PT-08 | State sprites (N states): per state frames stepper + Choose; More states | Views.swift:1224, 4772-4825 | PetSpriteStateControls | stepper, action | sprite kit on disk | Pet on; stepper only with a preview | No | Tools, disclosure |
| PT-09 | Characters (N, N ADVANCED): search, Try again, bundled tiles (confirm "Use X?", click only) and community tiles (confirm "Use X as the session pet figure?") | Views.swift:1236, 990-1056, 836, 850 | petGalleryCard | action | `PetSpriteStore`; openpets.dev catalog | Pet on | Yes: replaces the installed sprites and state map | Tools, disclosure |
| PT-10 | Use Cloud Puff | Views.swift:1256 | sessionPetSettings | action | `restoreDefaultCharacter()` | Pet on | Yes: replaces the current pack | Tools |
| PT-11 | Install sprite pack | Views.swift:1259 | sessionPetSettings | action (folder) | `choosePetSpritePack()` | Pet on | Yes: replaces sprites | Tools |
| PT-12 | Choose sprite / Replace sprite | Views.swift:1263 | sessionPetSettings | action (file) | `choosePetSprite()` | Pet on | No | Tools |
| PT-13 | Use COS figure | Views.swift:1268 | sessionPetSettings | action | `resetPetSprite()` | A custom sprite exists | Yes: drops custom sprites | Tools |
| PT-14 | Pet intro: Keep / Calm / Hide | ProviderConnectViews.swift:638-654 | PetIntroLine | action | `cos.petIntro.seen`; calm or pet off | Once | No | Panel line |
| PT-15 | Pet right-click: Full motion / Calm motion / No motion, Hide pet, Settings…, Setup guide… | SessionPet.swift:1340-1353 | spriteMenu | toggle, action | same as PT-07 and PT-01 | Pet visible | No | On the pet |

### 1.15 Decision models (JV)

`jevSettings`, `Views.swift:1075` (anchor `decision-models`). Opening the disclosure loads `decision-provider-status`, `jev-status`, `subq-status`.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| JV-01 | Decision models (provider summary) | Views.swift:1076, 1114 | jevSettings | disclosure, status | `decisionSettings.provider` | None | No | Tools |
| JV-02 | Default (Server default / Jev / SubQ) | Views.swift:1131, 1176 | decisionProviderPicker | picker | `decision-provider-set` | Server has decision settings, else "needs a newer COS server" | No | Decision models |
| JV-03 | Session suggestions (Use default / Jev / SubQ) + effective line + needs-key line | Views.swift:1134-1140 | decisionProviderPicker | picker | `decision-provider-set` workflow `session` | Same | No | Decision models |
| JV-04 | Completion checks | Views.swift:1134-1140 | decisionProviderPicker | picker | workflow `completion` | Same | No | Decision models |
| JV-05 | Work search | Views.swift:1134-1140 | decisionProviderPicker | picker | workflow `search` | Same | No | Decision models |
| JV-06 | Refresh decision settings | Views.swift:1149 | decisionProviderControls | action | reload | None | No | Decision models |
| JV-07 | SubQ preview and retention text + SubQ data retention link | Views.swift:1150-1152 | decisionProviderControls | status, link | static | None | No | Decision models |
| JV-08 | SubQ key status, field (SubQ API key / Replace SubQ key), Save key, note | Views.swift:1153-1167 | decisionProviderControls | field, action | `subq-key-set` (validated, stored on the server) | `decisionSettingsAvailable == true` | No | Decision models |
| JV-09 | Remove saved SubQ key | Views.swift:1169 | decisionProviderControls | action | `subq-key-clear` | Key source is config | Yes: deletes the key | Decision models |
| JV-10 | Jev key status, problem, "Paused after repeated errors until …" | Views.swift:1080-1093 | jevSettings | status | `jev-status` | None | No | Decision models |
| JV-11 | Jev key field (TypeSafe API key / Replace key) + Save, typesafe.ai note | Views.swift:1094-1110 | jevSettings | field, action | `jev-key-set` (16+ characters) | `jevStatus.available != false` | No | Decision models |
| JV-12 | Remove saved key | Views.swift:1104 | jevSettings | action | `jev-key-clear` | Key source is config | Yes: deletes the key | Decision models |

### 1.16 Work, Today and meetings options (WK, MT)

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| WK-01 | Work intake · Expire old asks from other people + note | Views.swift:1062-1072 | workExpirySettings | toggle | `work-loop set-settings expiryEnabled` | Server answers the settings read | No (expired asks restorable 30 days) | Tools |
| WK-02 | Work notifications | Views.swift:2865 | workNotificationsEnabled | toggle | `cos.workNotifications` | None | No | Tools |
| WK-03 | Open new sessions in the app | Views.swift:2869 | workOpensTabs | toggle | `cos.workOpensTabs` | None | No | Tools |
| WK-04 | Send plans without review | Views.swift:2873 | workChatSendWithoutReview | toggle | `cos.workChatSendWithoutReview` (default for each card's Auto-send) | None | No | Tools |
| WK-05 | When earlier work is still open (Queue it / Ask each time) | Views.swift:2878 | workChatWhenHeld | picker | `cos.workChatWhenEarlierOpen` | None | No | Tools |
| WK-06 | New Today home | Views.swift:2888 | todayHomeEnabled | toggle | `activityTodayHomeEnabled` | None (opt-in candidate) | No | Tools |
| WK-07 | Quiet hours on Today | Views.swift:2892 | todayQuietHours | toggle | `activityTodayQuietHours` | WK-06 on | No | Tools |
| WK-08 | Start Work runs from Today | Views.swift:2895 | todayWorkRuns | toggle | `activityTodayStartsWorkRuns` | WK-06 on; 20 runs a day | No | Tools |
| MT-01 | Show live meeting transcript | Views.swift:2883 | showLiveTranscript | toggle | `cos.liveTranscriptEnabled`; `liveTranscriptSettingChanged()` | None | No | Tools |
| MT-02 | Show the recording notice again | MacRecording.swift:1596 | MeetingSuggestSettings | action | `macRecording.noticeAcknowledged` | Disabled until acknowledged | No | Tools |
| MT-03 | Suggest recording when a meeting starts | MacRecording.swift:1602 | MeetingSuggestSettings | toggle | `meetingSuggest.enabled` | None | No | Tools |
| MT-04 | Zoom / Microsoft Teams / Google Meet | MacRecording.swift:1607 | MeetingSuggestSettings | toggle (x3) | `meetingSuggest.app.zoom/.teams/.meet` | MT-03 on | No | Tools |
| MT-05 | Google Meet needs Accessibility note | MacRecording.swift:1610-1613 | MeetingSuggestSettings | status | `browserNeedsAccessibility` | MT-03 on | No | Tools |
| MT-06 | Never for `{app}` + Remove | MacRecording.swift:1615-1618 | MeetingSuggestSettings | action | `meetingSuggest.never` | Any never entry | No | Tools |

### 1.17 Menus, Dock and other entry points (MN)

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MN-01 | App menu · Setup guide… | COSControlApp.swift:234 | commands | action | Welcome window | Dock mode | No | App menu |
| MN-02 | App menu · Settings… (⌘,) | COSControlApp.swift:255 | commands | action | `SettingsOpener.open` | Dock mode | No | App menu |
| MN-03 | Meetings · Record on Mac…, Stop Mac recording and save (⇧⌘R), View live transcript (⇧⌘L) | COSControlApp.swift:236-245 | commands | action | `macRecording`, `showRecordingTranscript` | Stop only while recording; View only with MT-01 | Stop ends a recording | Meetings menu |
| MN-04 | Dictation · Stop dictation, Cancel dictation, Dictionary…, History…, Settings… | COSControlApp.swift:247-253 | commands | action | `model.dictation`; Activity routes | None | Cancel drops the dictation | Dictation menu |
| MN-05 | Help · Setup guide…, COS Control help | COSControlApp.swift:257-260 | commands | action | Welcome window; gotcos.com/control | None | No | Help menu |
| MN-06 | Dock menu · View live transcript, Open Activity, Setup guide…, Settings… | ProviderConnectViews.swift:1216-1233 | makeDockMenu | action | delegates | View only while recording with MT-01 | No | Dock icon menu |
| MN-07 | Menu-bar icon (eyeglasses / eyeglasses.slash, red dot, gold update) | COSControlApp.swift:215-228 | MenuBarIcon | status | running, recording, update phase | None | No | Menu bar |
| MN-08 | Menu-bar Mac recording strip: View live transcript, Stop and save | COSControlApp.swift:202-209 | MenuBarExtra | action | `macRecording.stop()` | Mac recording active | Stop ends a recording | Above the panel |
| MN-09 | Activity: Settings (rail and toolbar), Setup guide, Settings…; Welcome window "Open settings" | ActivityWindow.swift:1073, 1444-1445, 8398; ControlSetup.swift:192 | openActivitySettings | action (navigation) | `showingSettings` | None | No | Activity window; Welcome window |

### 1.18 Settings that live outside Settings today (OUT)

Configuration a person changes in a working view today. Parity means the new Settings either holds these or links to them.

| ID | Current label (verbatim) | file:line | Symbol | Kind | Backing | Gate | Destructive or interrupts? | Renders today |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| OUT-01 | FIREFLIES: key summary, "Paste your Fireflies API key" + Save, Check, Remove key (confirm "Remove the Fireflies key?") | ActivityMeetings.swift:1176-1239 | connectCard | field, action | `fireflies-key-set` (stdin), `-check`, `-delete`, `-status` | `FIREFLIES_API_KEY` in env wins and is named | Remove stops Fireflies imports | Activity › Meetings import |
| OUT-02 | BRING THEM IN: How far back, Plan, Import now, plan line | ActivityMeetings.swift:1255-1267 | runCard | picker, action | `meeting-import-settings --plan-cap`; `meeting-import-run --window` | Fireflies key configured | No | Activity › Meetings import |
| OUT-03 | Keep bringing in new meetings + budget line | ActivityMeetings.swift:1271 | runCard | toggle | `meeting-import-settings` keepImporting | Fireflies key configured | No | Activity › Meetings import |
| OUT-04 | Track session usage on this Mac | SessionUsageView.swift:208 | SessionUsageView | checkbox | `sessionUsagePaused` (inverted) | None | No | Activity › Sessions › Usage |
| OUT-05 | Plan with (per-Mac default planner) | WorkTaskChat.swift:1516, 1556 | WorkChatSendControls | picker | `cos.workChatPlanner` (default opus) | Server advertises planners | No | Work chat footer |
| OUT-06 | Effort (per-Mac default) | WorkTaskChat.swift:1518, 1561 | WorkChatSendControls | picker | `cos.workChatEffort` (default high) | Server advertises efforts | No | Work chat footer |
| OUT-07 | Meaning (search messages by meaning; also "Turn it on") | ActivityWindow.swift:3168, 5794 | setSemanticSearchEnabled | checkbox | `cos.archiveSemanticSearch` | None | No (spends model tokens per search) | Activity › Messages search |

---

## 2. Duplicates and orphans

### 2.1 Settings reachable in more than one place

The new view should keep one home for each setting and turn the others into links to it, unless the second place is in-context on purpose (the pet menu, the setup guide).

| # | Setting | Places today | Keep as |
| --- | --- | --- | --- |
| D-01 | Session pet on/off | PT-01 switch; PT-14 Hide; PT-15 Hide pet | Home: Pet. Intro and pet menu stay as shortcuts |
| D-02 | Pet motion | PT-07; PT-14 Calm; PT-15 motion items | Home: Pet. Pet menu stays |
| D-03 | Dock or menu bar | G-02; H-08 | Home: General. H-08 stays a one-time line |
| D-04 | Open at login | G-01 Launch COS Control at login; PM-04 Open at login | Same SMAppService. Home: General; PM-04 shows status and links |
| D-05 | Every dictation setting | Panel Tools (Views.swift:2858) and Activity › Dictation › Settings (DI-35); Dictation menu Settings… | One Dictation category. DI-35 opens it |
| D-06 | Dictation engine | TR-01; SG-06; TR-07 Use Whisper; TR-10 Use Whisper | Home: Dictation |
| D-07 | Install Parakeet | TR-07; TR-10; SG-06 engine step | Home: Transcription and voice |
| D-08 | Transcription tier | UT-03 Apply; UT-02 Guided Setup dialog; SG-05 voice row | Home: Transcription and voice |
| D-09 | Show Claude sessions | UT-06; SG-07 Turn on; Today home Turn on (ActivityWindow.swift:8827) | Home: Work and agents |
| D-10 | Continue agent threads | UT-07; SG-08 | Home: Work and agents |
| D-11 | Jev and SubQ keys | JV-08, JV-11; SG-09 opens them; MA-07 opens them | Home: AI and accounts |
| D-12 | Accessibility | PM-02; PT-02 Grant and Reset and add again; DI-08; MT-05 note; ControllerModel.swift:6209 copy points at PT-02 | Home: Privacy and permissions. Others link |
| D-13 | Notifications | PM-03; ST-15 Notification settings | Home: Privacy and permissions |
| D-14 | Clear stranded video uploads | Status card (Views.swift:1412) and Tools (Views.swift:2764) | One action, UT-10 |
| D-15 | Update Server | C-04; SG-11 (ProviderConnectViews.swift:484); ActivityMeetings.swift:1149, 1568; ActivityWindow.swift:2803 | Home: System and updates |
| D-16 | Refresh and check for updates | H-02 in the panel header and in Activity's Settings header | Home: System and updates |
| D-17 | Open the setup guide; hide it | SG-01, MN-01, MN-05, MN-06, PT-15, ActivityWindow.swift:1444; hide in SG-14 and SG-15 | Home: General |
| D-18 | Open Settings | MN-02, MN-06, PT-15, MN-09, ControlSetup.swift:192 | Entry points, not settings |
| D-19 | Live meeting transcript | MT-01; H-10 tells you to turn it on | Home: Meetings |
| D-20 | Meeting assistant model | MA-01 in Settings and in the Live COS Ask panel | Home: Meetings. Ask panel stays |
| D-21 | Search by meaning | OUT-07 checkbox and "Turn it on" (ActivityWindow.swift:5794) | Home: AI and accounts, plus the in-place checkbox |
| D-22 | Stop a Mac recording | MN-03, MN-08, Record on Mac panel, H-10 | Not a setting |
| D-23 | Guided Setup | UT-02 and the orphaned speaker card (O-01) | Home: Transcription and voice |

### 2.2 Orphans and reachability gaps

| # | What | Evidence | Recommendation |
| --- | --- | --- | --- |
| O-01 | "Named speakers are off" / "Voiceprint model failed to load" warning with Run Guided Setup | Only in `reviewableMeetingsCard` (Views.swift:2191), which no view mounts (`grep reviewableMeetingsCard` finds the definition and two comments) | Show it under Transcription and voice when `status.speakerIdNeedsSetup` |
| O-02 | First-use confirmation for Plan and send | `cos.workChatSendWithoutReviewAcknowledged` (WorkTaskChat.swift:1521); no control resets it | Optional: "Ask before the first auto-send" reset under Work, Advanced |
| O-03 | Pet intro seen | `cos.petIntro.seen` (ControllerModel.swift:925) | None needed; note only |
| O-04 | Dock notice seen | `cos.dock.noticeSeen` | None needed |
| O-05 | Dismissed publisher notices | `dismissedNoticeIds` (ControllerModel.swift:324) | None needed |
| O-06 | Key lanes setup step skipped | `cos.keyLanes.setupSkipped`; the step lives only in the Welcome window (KeyLanesViews.swift:240) | KL-01 covers it |
| O-07 | Early meeting sync | ST-18 shows state; no control in COS Control (server environment) | Status only. Say "set on the server" |
| O-08 | HQ prefill | ST-19 shows state; no control | Status only |
| O-09 | Values set in the server's `.env` | Live cue limits show "Set in .env" (MA-08 to MA-11); Live cues switch locks (MA-06); Fireflies env key (OUT-01); Previous polish env lock (DI-31) | Keep the locked look and the reason |
| O-10 | Reset live message count in Activity's Settings | H-04 sits in `header`, which `mainPanel` replaces when `hostedInActivity` (Views.swift:1898-1911) | Put it in Glasses and iPhone so every host has it |
| O-11 | Today quiet hours and Work runs | WK-07, WK-08 vanish while WK-06 is off; Today copy still points at them (ActivityWindow.swift:8030, 8972) | Keep the gate; show them disabled with a reason |
| O-12 | Two different "setup guide" buttons | UT-28 "Setup Guide" opens gotcos.com/control; MN-01 and SG-01 "Setup guide…" open the in-app guide | Rename UT-28 "Online help" |

---

## 3. Proposed layout

A left list of categories. Each category holds groups (cards). Rarely used or technical items sit in an Advanced accordion at the bottom of their group. Every inventory row appears exactly once below or in 3.11 (stays outside Settings).

**Rules that carry over unchanged:** every gate in a row's Gate column; every confirmation; the Apply pattern (a server setting changes only on Apply, and Apply says it restarts the server); "set in .env" locks; hiding a card on an older server (404) rather than showing an error.

The starting categories held up against the code with three changes:

- **Activity home** joins General. The Today switches change how Activity opens, not Work.
- **Morning brief, domains and fenced threads** join Work and agents. They are scheduled or task-level behavior.
- **Status rows move to the category they describe.** The server card (ST-*) is split: server health to System and updates, transcription rows to Transcription and voice, meeting rows to Meetings.

| Category | Rows | In Advanced |
| --- | --- | --- |
| 3.1 General | 16 | 0 |
| 3.2 AI and accounts | 35 | 9 |
| 3.3 Glasses and iPhone | 9 | 5 |
| 3.4 Meetings | 35 | 10 |
| 3.5 Dictation | 37 | 6 |
| 3.6 Transcription and voice | 20 | 9 |
| 3.7 Work and agents | 33 | 6 |
| 3.8 Privacy and permissions | 8 | 1 |
| 3.9 Pet and appearance | 14 | 4 |
| 3.10 System and updates | 32 | 6 |
| 3.11 Stays outside Settings | 14 | n/a |
| **Total** | **253** | **56** |

Notes column: **Apply** = draft then Apply; **Restart** = restarts the server; **Confirm** = keep the inline confirmation; a version = the server it needs.

### 3.1 General

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **App** | | | | |
| G-01 | Open at login | Start COS Control when you log in. | | |
| G-02 | Menu bar only | Hide COS Control from the Dock. The menu bar icon stays. | | |
| H-08 | Dock notice | One-time note after an upgrade: keep the Dock icon or go menu bar only. | | Once |
| G-03 | Activity shortcut | A key combination that opens Activity from any app. | | Refuses dictation keys |
| UT-25 | Time format | Show meeting times in 12-hour or 24-hour format. | | |
| H-09 | Get started | Opens first-time setup. Shows until COS is set up. | | needsFirstRun |
| **Activity home** | | | | |
| WK-06 | Today home | Activity opens on Today: what needs you, what is running, what is next. | | |
| WK-07 | Quiet hours | Evenings and weekends, Today folds items that can wait. | | Needs WK-06 |
| WK-08 | Work runs from Today | Prep me and the Ask box start Work runs, up to 20 a day. | | Needs WK-06 |
| **Setup guide** | | | | |
| SG-01 | Setup guide | Step-by-step setup for your AI, voice, glasses and permissions. | | |
| SG-15 | Finish setup card | A progress card at the top until every step is done or skipped. | | |
| SG-14 | Show setup card | Show or hide the Finish setup card. | | |
| SG-07 | Sessions step | The guide step that turns on Show AI sessions. | | Restart |
| SG-08 | Continue step | The guide step that turns on Continue threads. | | Restart; 6.37 |
| SG-09 | Work suggestions step | The guide step that checks your Jev or SubQ key. | | |
| SG-10 | Permissions step | The guide step that opens Permissions. | | |

### 3.2 AI and accounts

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **Your AI apps** | | | | |
| SG-03 | Claude, Codex, Cursor | Install and sign in to the AI apps COS works through. | | Polls on screen |
| ST-24 | AI app status | Shows whether Claude, Codex and Cursor are ready. | | |
| ST-25 | Cursor status | Shows whether Cursor is installed and signed in. | | |
| UT-20 | Open Cursor | Opens Cursor on your work folder. | | |
| **Local model** | | | | |
| SG-04 | Ollama | Get or open Ollama to run a model on this Mac. | | |
| ST-26 | Ollama status | Shows the local model in use. | | Ready only |
| UT-08 | Local model | Pick the Ollama model, or follow the newest one. | | Apply; Restart |
| **Decision models** | | | | |
| JV-01 | Decision models | The service behind Work suggestions, done checks and Work search. | | |
| JV-02 | Default provider | The provider every Work decision uses unless you pick another. | | Newer server |
| JV-08 | SubQ key | Save a SubQ key on the server. Saving it does not select SubQ. | | |
| JV-09 | Remove SubQ key | Delete the saved SubQ key from the server. | | |
| JV-10 | Jev key status | Shows whether the Jev key works, and any pause after errors. | | |
| JV-11 | Jev key | Save a TypeSafe key for Jev. Get one at typesafe.ai. | | |
| JV-12 | Remove Jev key | Delete the saved Jev key from the server. | | |
| JV-03 | Session suggestions | The provider that suggests Continue, Fork or New. | Yes | |
| JV-04 | Done checks | The provider that checks whether a reply finished the task. | Yes | |
| JV-05 | Work search | The provider that searches Work by meaning. | Yes | |
| JV-06 | Refresh providers | Read the provider settings from the server again. | Yes | |
| JV-07 | SubQ data retention | SubQ is a public preview. Read how long it keeps your data. | Yes | |
| **Your own key** | | | | 6.80.0 |
| KL-01 | Use your own key | Answer with your own API key under a daily cap. Off uses your AI plan. | | |
| KL-04 | Key details | Each key's cap, spend and limits. | | |
| KL-06 | Key model | The model this key answers with. | | |
| KL-07 | Use for answers | Send your answers to this key. | | |
| KL-08 | Daily cap | The most this key can spend in a day, from $0.01 to $1000. | | |
| KL-05 | Resume key | Clear the pause after repeated errors. | | Breaker open |
| KL-09 | Remove key | Delete this key and its profile from this Mac. | | Confirm |
| KL-10 | Key provider | Where the new key comes from: OpenRouter, Anthropic or OpenAI. | | |
| KL-11 | Paste key | Paste a key from the clipboard. COS clears the clipboard. | | |
| KL-12 | New key cap | The daily cap for the key you are adding. | | |
| KL-13 | Save key | Check and save the pasted key. | | |
| KL-14 | Remove all keys | Delete every saved key from this Mac. | Yes | Confirm |
| KL-15 | Save spend ledger | Save the spend ledger to Downloads before keys are removed. | Yes | |
| KL-03 | Remove saved keys | Delete keys left on this Mac while your own key is off. | Yes | Confirm |
| KL-02 | Remove keys to downgrade | An older server cannot use saved keys. Remove them to install it. | Yes | Confirm |
| **Search** | | | | |
| OUT-07 | Search by meaning | Find messages by meaning. Each search uses model tokens. | | New to Settings; keep the in-place checkbox |

### 3.3 Glasses and iPhone

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **Devices** | | | | |
| SG-02 | Your devices | Choose Just my Mac, or My Mac and glasses. | | |
| SG-11 | Connect glasses | Set up Tailscale on both devices, then pair with a code. | | 6.67.0; polls on screen |
| SG-12 | Pair on home Wi-Fi | Let a phone on this Wi-Fi pair for 10 minutes. Use it at home only. | | |
| SG-13 | Glasses app | Get the COS app for your glasses. | | |
| UT-21 | Copy pairing token | Copy the pairing token to the clipboard. Keep it private. | Yes | managedHealthy |
| H-04 | Reset message count | Start live messages again at #1. History stays in Archive. | Yes | Confirm; phone 6.8.423 |
| **Video uploads** | | | | |
| UT-09 | Reliable video uploads | Send videos in chunks that pick up again after a restart. Beta. | Yes | Apply; Restart |
| ST-10 | Upload status | Uploads in progress and receipts waiting on the phone. | Yes | |
| UT-10 | Clear stuck uploads | Cancel uploads that stopped sending. Uploads in progress stay. | Yes | Confirm |

### 3.4 Meetings

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **Recording** | | | | |
| MT-01 | Live transcript | Show a recording meeting at the top of Meetings as it happens. | | |
| MT-03 | Suggest recording | Offer to record when Zoom, Teams or Meet uses the microphone. | | |
| MT-04 | Apps to watch | Choose which meeting apps get the suggestion. | | Needs MT-03 |
| MT-05 | Google Meet access | Google Meet in a browser needs Accessibility to be noticed. | | |
| MT-06 | Never suggest for | Apps you told COS to stop suggesting. Remove one to undo. | | |
| MT-02 | Recording notice | Show the notice about what COS records before the next recording. | | |
| ST-14 | Live meeting audio | Shows whether each live meeting's audio is reaching COS. | | |
| ST-15 | Meeting alerts | Alerts are off for COS Control. Open Notification settings to fix. | | |
| **Meeting assistant** | | | | |
| MA-01 | Assistant model | The model that answers when you ask during a meeting. | | Locks offline |
| MA-02 | Web lookup | Shows whether the assistant can search the public web. | | |
| MA-05 | Home city | Where fact checks start. City and state, no street. | | 6.71.13 |
| MA-03 | Unavailable models | Models you cannot pick right now, and why. | Yes | |
| MA-04 | Refresh models | Check again which models are connected. | Yes | |
| **Live cues** | | | | |
| MA-06 | Live cues | Short prompts during a meeting. Needs a Jev or SubQ key. | | Env lock |
| MA-07 | Add cue key | Go to the Jev and SubQ keys, or check again. | | |
| MA-13 | Glasses switch | Cues also need Live Cues on in the glasses app. | | |
| MA-08 | Cue bar | Lower gives more cues. Higher gives fewer. | Yes | 6.79.2; env lock |
| MA-09 | Cues per meeting | The most cues one meeting can get. | Yes | 6.79.2; env lock |
| MA-10 | Gap between cues | The shortest time between two cues. | Yes | 6.79.2; env lock |
| MA-11 | Daily cue limit | The most cue writer calls in one day. | Yes | 6.79.2; env lock |
| MA-12 | Cue usage | Today's cue use and save progress. | Yes | 6.79.2 |
| **Library and sync** | | | | |
| UT-16 | Meetings folder | The folder that holds your meetings. | | Restart; Confirm guidance |
| ST-29 | Library status | Where your meetings are and how many COS found. | | |
| ST-16 | Meeting sync | Where each meeting is in sync right now. | | |
| ST-17 | Sync now | Run meeting sync now. | | Blocked by meeting work |
| ST-20 | Save status | Meetings waiting to save, or retrying. | | |
| ST-21 | Kept captures | Captures on this Mac that never became meetings. | | |
| ST-22 | Recover captures | Turn kept audio into meetings. The files stay. | | Confirm for all |
| ST-23 | Save captures | Save live captures that already have a transcript. | | Confirm for all |
| ST-18 | Early sync status | Early sync state. This is set on the server. | Yes | |
| UT-05 | Fast preview | Show quick meeting text first, then the final transcript. | Yes | Apply; Restart |
| ST-08 | Fast preview status | Shows whether fast preview is on. | Yes | |
| **Fireflies import** | | | | New to Settings |
| OUT-01 | Fireflies key | Save, check or remove your Fireflies API key. | | Env key wins; Confirm remove |
| OUT-02 | Import meetings | Bring in past Fireflies meetings by date range and plan. | | Needs key |
| OUT-03 | Keep importing | Bring in new Fireflies meetings as they arrive. | | Needs key |

### 3.5 Dictation

One category replaces both copies of `MacDictationSettings` (D-05). Rows below DI-01 keep the "only while dictation is on" gate.

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **Dictation** | | | | |
| DI-01 | Dictate into apps | Type by voice into any Mac app. | | |
| TR-01 | Dictation engine | Parakeet Ultra, Whisper or Automatic. Saved on the server. | | 6.74.0 |
| SG-06 | Test engines | Dictate a 30-second sample with each engine and compare. | | Not while recording |
| DI-35 | Dictation tab link | Open these settings from the Dictation tab. | | |
| **Microphone** | | | | |
| DI-02 | Microphone | The microphone dictation uses. | | |
| DI-03 | Refresh microphones | Look for newly connected microphones. | | |
| DI-04 | Microphone fallback | If the microphone fails, use one that worked before. | | System default only |
| **Shortcuts** | | | | |
| DI-05 | Push to talk | Hold the shortcut to dictate. | | Unique keys |
| DI-06 | Start and stop | Press once to start and again to stop. | | Unique keys |
| DI-07 | Fix last dictation | Correct a word in your last dictation. | | Unique keys |
| DI-08 | Typing permission | Let COS type into other apps. | | |
| DI-34 | How shortcuts work | Which keys work and how COS pastes your text. | | |
| **Sounds and audio** | | | | |
| DI-09 | Start sound | The sound when dictation starts. | | |
| DI-10 | Stop sound | The sound when dictation stops. | | |
| DI-11 | Your own sound | Import a sound file, preview it, then save it. | | |
| DI-12 | Volume | Sound volume. Zero turns sounds off. | | |
| DI-13 | Pitch | Raise or lower the sounds. | | |
| DI-14 | Resume sounds | Turn sounds back on after an audio error. | | Breaker |
| DI-15 | Other audio | Mute or lower other apps while you dictate. | | |
| DI-16 | System audio access | Muting other apps needs System Audio Recording. | | |
| **Text** | | | | |
| DI-17 | Restore clipboard | Put back what you had copied after COS pastes. | | |
| DI-18 | Learn from edits | Save or suggest the corrections you make. | | |
| DI-19 | Match nearby spelling | Spell names the way the text box already has them. | | |
| DI-20 | Spoken lists | Turn spoken list items into numbered or bulleted lists. | | |
| DI-21 | Remove fillers | Drop um and uh before COS types. | | |
| DI-22 | Capitalize sentences | Start each sentence with a capital letter. | | |
| **AI polish** | | | | |
| DI-23 | AI polish | Clean up dictation with Claude Haiku or Sonnet. Uses model calls. | | |
| DI-24 | Paste then polish | Paste right away, then swap in the polished text. | | Needs polish |
| DI-27 | Learn my style | Learn how you write from the edits you make. | | 6.91.0 |
| DI-25 | Wait for keys | Wait until you release ⌘ or ⌃ before swapping. | Yes | Needs DI-24 |
| DI-26 | Polish instructions | Your own rules for polish, added after the built-in rules. | Yes | 6.85.0 |
| DI-28 | Style rules | Rules COS learned or you added. Keep or remove each one. | Yes | |
| DI-29 | Add a style rule | Add a rule from a short list. | Yes | |
| DI-30 | Reset style | Delete every style rule on this Mac and on the server. | Yes | Confirm |
| DI-31 | Previous polish | Use the earlier polish prompt, version 3. | Yes | Env lock |
| **History** | | | | |
| DI-32 | Keep dictations | How long dictations stay on this Mac. | | Confirm on Don't keep |
| DI-33 | Clear history | Delete every dictation kept on this Mac. | | Confirm |

### 3.6 Transcription and voice

Add O-01 (the voiceprint warning with Guided setup) to the top of this category when `status.speakerIdNeedsSetup`.

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **Voice setup** | | | | |
| SG-05 | Voice setup | Download local transcription and test this Mac. | | Restart on apply |
| UT-03 | Quality tier | Balanced suits most Macs. Max needs a powerful Mac. | | 6.21.0; Apply; Restart |
| TR-07 | Parakeet engine | Install the Parakeet Ultra engine, a 654 MB download. | | Not while recording |
| ST-04 | Engine status | Parakeet readiness and the engines in use. | | Parakeet only |
| ST-05 | Whisper status | Whisper readiness and any error. | | Whisper only |
| UT-14 | Repair Whisper | Restart Whisper when it stops working. | | Owned server |
| UT-02 | Guided setup | Run voice setup in Terminal, Balanced or Max. | Yes | Confirm (tier choice) |
| ST-13 | Model status | The tier and the models for preview, live and save. | Yes | |
| **Models** | | | | 6.72.0 |
| TR-02 | Preview model | The model for the fast live preview. | | |
| TR-03 | Final model | The model for the saved meeting transcript. | | |
| TR-04 | Second opinion | A second model that checks the first. | | |
| TR-06 | Refine with second | Let the second opinion correct the transcript. | | |
| TR-05 | When changes apply | When a model change takes effect. | | |
| TR-08 | Front end | How audio is prepared before transcription. | Yes | |
| TR-09 | Quiet detection | How COS skips silence. | Yes | |
| **Performance** | | | | |
| UT-11 | Idle Metal HQ | Use the GPU for final transcripts while the Mac is idle. | Yes | Apply; Restart |
| ST-11 | GPU status | Shows whether the GPU path is on. | Yes | |
| UT-12 | Audio cleanup | Clean saved audio when you play it. The original stays. | Yes | Apply; Restart |
| ST-12 | Cleanup status | Adaptive or raw playback. | Yes | |
| ST-19 | HQ prefill status | Early final-quality text. This is set on the server. | Yes | |

### 3.7 Work and agents

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **Sessions** | | | | |
| UT-06 | Show AI sessions | List Claude, Codex and Cursor sessions in Activity. | | Apply; Restart; local network |
| UT-07 | Continue threads | Let a reply continue a real Claude or Codex session. | | 6.37; Apply; Restart |
| ST-09 | Continue status | Shows which apps can be continued. | | |
| WK-03 | Open in app | Open a new session in its app after the first reply. | | |
| WK-02 | Work notifications | Tell me when a session gets Work, finishes, or needs me. | | |
| OUT-04 | Track usage | Count session tokens on this Mac. Nothing is uploaded. | | New to Settings |
| **Work chat** | | | | |
| WK-04 | Send without review | Plan and send in one step. Each card can override it. | | |
| WK-05 | When work is open | Queue a new send behind open work, or ask each time. | | |
| WK-01 | Expire old asks | Drop old asks from other people. Restore them for 30 days. | | Server answers |
| OUT-05 | Default planner | The model that plans Work. | Yes | Server lists planners |
| OUT-06 | Planning effort | How hard the planner thinks. Higher costs more. | Yes | Server lists efforts |
| **Background** | | | | |
| UT-04 | Background jobs | Keep replies running after the phone app closes. | | Apply; Restart; no active work |
| ST-07 | Background status | Shows whether background jobs are allowed. | | |
| **Folders and notes** | | | | |
| UT-15 | Work folder | The folder your AI apps work in. | | Restart |
| ST-28 | Work folder status | The current work folder, and any restart it waits for. | | |
| UT-17 | Notes folder | The folder of memory and thread notes. | | Restart |
| UT-18 | Create folders | Make the memory and threads folders for you. | | No store yet |
| ST-06 | Memory and threads | How many memories and threads COS can read. | | |
| UT-19 | Notes source | Where notes are read from: plain files or the bridge. | Yes | |
| **Morning brief** | | | | 6.43.0; Apply |
| MB-02 | Morning brief | A daily brief that lands in your inbox. | | |
| MB-01 | Brief status | When the next brief arrives, or why it will not. | | |
| MB-03 | Brief time | The time the brief arrives. | | |
| MB-04 | Brief days | The days the brief runs. | | |
| MB-05 | Brief sources | What the brief includes. | | |
| MB-07 | Save brief | Save the schedule and the sources. | | |
| MB-08 | Brief now | Send a brief now. Up to five a day. | | Background jobs on |
| MB-09 | Last brief | How the last brief went. | | |
| MB-06 | Source options | Settings for each source. | Yes | |
| **Domains** | | | | tasksGate |
| DM-01 | Domains | The areas your tasks are grouped by. | | |
| DM-02 | Order and remove | Reorder or unlist a domain. Its folder stays. | | |
| DM-03 | Save domains | Add, save or reset the list. | | |
| **Paused threads** | | | | Only when one exists |
| FN-01 | Paused threads | Threads COS stopped writing to after a reply went missing. | Yes | |
| FN-02 | Release thread | Let COS write to the thread again. Check it first. | Yes | Confirm |

### 3.8 Privacy and permissions

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| PM-01 | Permissions | What COS can use on this Mac, with one click to allow each. | | |
| PM-02 | Accessibility | Lets COS type for you, jump to sessions and see Meet tabs. | | Reset and add again |
| PM-03 | Notifications | Lets COS send meeting and Work alerts. | | |
| PM-04 | Open at login | Login item status. The switch lives in General. | | |
| PM-05 | Background items | Lets the COS server keep running in the background. | | |
| PM-06 | Automation | Lets COS control Claude, Cursor and Terminal. | | |
| PM-07 | Calendar | Lets COS read your calendar. | | |
| PM-08 | Old test builds | Remove permission entries left by old COS builds. | Yes | |

### 3.9 Pet and appearance

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| PT-01 | Session pet | A small character that shows what your AI sessions are doing. | | |
| PT-02 | Jump access | Clicking the pet to jump to a session needs Accessibility. | | Pet on, not trusted |
| PT-03 | Pet size | Small, medium, large or a custom size. | | |
| PT-04 | Custom size | The pet's size in pixels. | | Custom only |
| PT-05 | Figure size | Scale the character only. Buttons and text keep their size. | | |
| PT-06 | Animation speed | How fast the character moves. | | |
| PT-07 | Motion | Full, calm or no motion. | | Also on the pet's menu |
| PT-09 | Characters | Pick a character from COS or the community gallery. | | Confirm, click only |
| PT-10 | Default character | Go back to Cloud Puff. | | |
| PT-14 | Pet intro | One-time intro: keep, calm or hide the pet. | | Once |
| PT-08 | State sprites | Set the image and frame count for each state. | Yes | |
| PT-11 | Install sprite pack | Install a folder of character sprites. | Yes | |
| PT-12 | Choose sprite | Use one image for every state. | Yes | |
| PT-13 | Use COS figure | Remove your own sprites. | Yes | Custom only |

### 3.10 System and updates

| ID | New label | Description | Adv | Notes |
| --- | --- | --- | --- | --- |
| **Server** | | | | |
| ST-01 | Server status | Whether the COS server is running and healthy. | | |
| ST-02 | Ownership | Whether COS Control manages this server. | | |
| ST-03 | Recovery | Whether automatic recovery is set up. | | |
| ST-27 | Server version | The COS server version. | | |
| ST-30 | Work in progress | Active jobs and recordings. Restart waits for them. | | |
| ST-31 | Pending change | A server change in progress, or one that needs Repair. | | |
| C-09 | Server messages | Warnings and progress for server changes. | | |
| C-01 | Restart | Restart the server. Waits until no work is running. | | Confirm when self-managed |
| C-02 | Stop | Stop the server. | | |
| C-03 | Start | Start the server. | | Stopped only |
| C-04 | Update server | Install the newest server and restart it. | | Managed and owned |
| C-05 | Install server | Install the COS server. | | Not installed |
| C-06 | Adopt server | Take over a stopped older server safely. | Yes | legacyStopped |
| C-07 | Manage in place | Manage your running server without replacing it. | Yes | legacyService |
| C-08 | Replace server | Stop the older server and install the managed one. | Yes | Confirm |
| **App updates** | | | | |
| H-01 | App version | The COS Control version. | | |
| H-02 | Check for updates | Refresh status and look for a new version. | | |
| H-03 | Update status | Whether the last check found an update. | | |
| H-05 | Update banner | Download and install a new version. | | Only with an update |
| H-06 | What's new | Notes for the new version, then install. | | |
| H-07 | Announcements | News from the COS team. Dismiss to hide. | | |
| G-05 | Versions | App and server versions side by side. | | |
| **Troubleshooting** | | | | |
| UT-01 | Run checks | Check the setup and list any problems. | | |
| DR-01 | Check results | Results of the last check. | | After UT-01 |
| UT-13 | Repair | Fix the managed server setup. | | Installed, no conflict |
| UT-22 | Copy report | Copy a support report to the clipboard. | | |
| UT-23 | Open logs | Open the log folder. | | |
| UT-28 | Online help | Open COS Control help on gotcos.com. | | Renamed (O-12) |
| G-04 | Quit | Quit COS Control. | | |
| UT-24 | Health page | Open the server health page in your browser. | Yes | |
| UT-26 | Roll back server | Go back to the previous server version. | Yes | Add a confirm |
| UT-27 | Finish server change | Finish or undo an interrupted server change. | Yes | |

### 3.11 Stays outside Settings

These are live-work surfaces or entry points. Settings links to them where useful; it does not copy them.

| ID | What | Why it stays |
| --- | --- | --- |
| H-10 | Recording card | Live work, not configuration |
| H-11 | Activity launcher | Navigation for the menu-bar panel |
| H-12 | Your move | Navigation to Work |
| TR-10 | Panel Parakeet line | A just-in-time prompt in the menu-bar panel; TR-07 is the setting |
| PT-15 | Pet right-click menu | In-place shortcuts on the pet |
| MN-01 | App menu Setup guide… | Entry point |
| MN-02 | App menu Settings… | Entry point; must open the new view |
| MN-03 | Meetings menu | Live recording commands |
| MN-04 | Dictation menu | Live dictation commands; Settings… must open 3.5 |
| MN-05 | Help menu | Entry point |
| MN-06 | Dock menu | Entry point |
| MN-07 | Menu-bar icon | Status |
| MN-08 | Menu-bar recording strip | Live work |
| MN-09 | Activity and Welcome Settings buttons | Entry points; must open the new view |

---

## 4. Parity checklist

Tick a row when the new view has it in its category with its gate, its confirmation and its backing unchanged. Rows in "Stays outside Settings" are ticked when they still work and, where noted, open the new view.

- [ ] H-01 App version (System and updates)
- [ ] H-02 Check for updates (System and updates)
- [ ] H-03 Update status (System and updates)
- [ ] H-04 Reset message count (Glasses and iPhone)
- [ ] H-05 Update banner (System and updates)
- [ ] H-06 What's new (System and updates)
- [ ] H-07 Announcements (System and updates)
- [ ] H-08 Dock notice (General)
- [ ] H-09 Get started (General)
- [ ] H-10 Recording card (Stays outside Settings)
- [ ] H-11 Activity launcher (Stays outside Settings)
- [ ] H-12 Your move (Stays outside Settings)
- [ ] ST-01 Server status (System and updates)
- [ ] ST-02 Ownership (System and updates)
- [ ] ST-03 Recovery (System and updates)
- [ ] ST-04 Engine status (Transcription and voice)
- [ ] ST-05 Whisper status (Transcription and voice)
- [ ] ST-06 Memory and threads (Work and agents)
- [ ] ST-07 Background status (Work and agents)
- [ ] ST-08 Fast preview status (Meetings)
- [ ] ST-09 Continue status (Work and agents)
- [ ] ST-10 Upload status (Glasses and iPhone)
- [ ] ST-11 GPU status (Transcription and voice)
- [ ] ST-12 Cleanup status (Transcription and voice)
- [ ] ST-13 Model status (Transcription and voice)
- [ ] ST-14 Live meeting audio (Meetings)
- [ ] ST-15 Meeting alerts (Meetings)
- [ ] ST-16 Meeting sync (Meetings)
- [ ] ST-17 Sync now (Meetings)
- [ ] ST-18 Early sync status (Meetings)
- [ ] ST-19 HQ prefill status (Transcription and voice)
- [ ] ST-20 Save status (Meetings)
- [ ] ST-21 Kept captures (Meetings)
- [ ] ST-22 Recover captures (Meetings)
- [ ] ST-23 Save captures (Meetings)
- [ ] ST-24 AI app status (AI and accounts)
- [ ] ST-25 Cursor status (AI and accounts)
- [ ] ST-26 Ollama status (AI and accounts)
- [ ] ST-27 Server version (System and updates)
- [ ] ST-28 Work folder status (Work and agents)
- [ ] ST-29 Library status (Meetings)
- [ ] ST-30 Work in progress (System and updates)
- [ ] ST-31 Pending change (System and updates)
- [ ] C-01 Restart (System and updates)
- [ ] C-02 Stop (System and updates)
- [ ] C-03 Start (System and updates)
- [ ] C-04 Update server (System and updates)
- [ ] C-05 Install server (System and updates)
- [ ] C-06 Adopt server (System and updates)
- [ ] C-07 Manage in place (System and updates)
- [ ] C-08 Replace server (System and updates)
- [ ] C-09 Server messages (System and updates)
- [ ] SG-01 Setup guide (General)
- [ ] SG-02 Your devices (Glasses and iPhone)
- [ ] SG-03 Claude, Codex, Cursor (AI and accounts)
- [ ] SG-04 Ollama (AI and accounts)
- [ ] SG-05 Voice setup (Transcription and voice)
- [ ] SG-06 Test engines (Dictation)
- [ ] SG-07 Sessions step (General)
- [ ] SG-08 Continue step (General)
- [ ] SG-09 Work suggestions step (General)
- [ ] SG-10 Permissions step (General)
- [ ] SG-11 Connect glasses (Glasses and iPhone)
- [ ] SG-12 Pair on home Wi-Fi (Glasses and iPhone)
- [ ] SG-13 Glasses app (Glasses and iPhone)
- [ ] SG-14 Show setup card (General)
- [ ] SG-15 Finish setup card (General)
- [ ] PM-01 Permissions (Privacy and permissions)
- [ ] PM-02 Accessibility (Privacy and permissions)
- [ ] PM-03 Notifications (Privacy and permissions)
- [ ] PM-04 Open at login (Privacy and permissions)
- [ ] PM-05 Background items (Privacy and permissions)
- [ ] PM-06 Automation (Privacy and permissions)
- [ ] PM-07 Calendar (Privacy and permissions)
- [ ] PM-08 Old test builds (Privacy and permissions)
- [ ] MB-01 Brief status (Work and agents)
- [ ] MB-02 Morning brief (Work and agents)
- [ ] MB-03 Brief time (Work and agents)
- [ ] MB-04 Brief days (Work and agents)
- [ ] MB-05 Brief sources (Work and agents)
- [ ] MB-06 Source options (Work and agents)
- [ ] MB-07 Save brief (Work and agents)
- [ ] MB-08 Brief now (Work and agents)
- [ ] MB-09 Last brief (Work and agents)
- [ ] DM-01 Domains (Work and agents)
- [ ] DM-02 Order and remove (Work and agents)
- [ ] DM-03 Save domains (Work and agents)
- [ ] FN-01 Paused threads (Work and agents)
- [ ] FN-02 Release thread (Work and agents)
- [ ] DR-01 Check results (System and updates)
- [ ] MA-01 Assistant model (Meetings)
- [ ] MA-02 Web lookup (Meetings)
- [ ] MA-03 Unavailable models (Meetings)
- [ ] MA-04 Refresh models (Meetings)
- [ ] MA-05 Home city (Meetings)
- [ ] MA-06 Live cues (Meetings)
- [ ] MA-07 Add cue key (Meetings)
- [ ] MA-08 Cue bar (Meetings)
- [ ] MA-09 Cues per meeting (Meetings)
- [ ] MA-10 Gap between cues (Meetings)
- [ ] MA-11 Daily cue limit (Meetings)
- [ ] MA-12 Cue usage (Meetings)
- [ ] MA-13 Glasses switch (Meetings)
- [ ] TR-01 Dictation engine (Dictation)
- [ ] TR-02 Preview model (Transcription and voice)
- [ ] TR-03 Final model (Transcription and voice)
- [ ] TR-04 Second opinion (Transcription and voice)
- [ ] TR-05 When changes apply (Transcription and voice)
- [ ] TR-06 Refine with second (Transcription and voice)
- [ ] TR-07 Parakeet engine (Transcription and voice)
- [ ] TR-08 Front end (Transcription and voice)
- [ ] TR-09 Quiet detection (Transcription and voice)
- [ ] TR-10 Panel Parakeet line (Stays outside Settings)
- [ ] KL-01 Use your own key (AI and accounts)
- [ ] KL-02 Remove keys to downgrade (AI and accounts)
- [ ] KL-03 Remove saved keys (AI and accounts)
- [ ] KL-04 Key details (AI and accounts)
- [ ] KL-05 Resume key (AI and accounts)
- [ ] KL-06 Key model (AI and accounts)
- [ ] KL-07 Use for answers (AI and accounts)
- [ ] KL-08 Daily cap (AI and accounts)
- [ ] KL-09 Remove key (AI and accounts)
- [ ] KL-10 Key provider (AI and accounts)
- [ ] KL-11 Paste key (AI and accounts)
- [ ] KL-12 New key cap (AI and accounts)
- [ ] KL-13 Save key (AI and accounts)
- [ ] KL-14 Remove all keys (AI and accounts)
- [ ] KL-15 Save spend ledger (AI and accounts)
- [ ] UT-01 Run checks (System and updates)
- [ ] UT-02 Guided setup (Transcription and voice)
- [ ] UT-03 Quality tier (Transcription and voice)
- [ ] UT-04 Background jobs (Work and agents)
- [ ] UT-05 Fast preview (Meetings)
- [ ] UT-06 Show AI sessions (Work and agents)
- [ ] UT-07 Continue threads (Work and agents)
- [ ] UT-08 Local model (AI and accounts)
- [ ] UT-09 Reliable video uploads (Glasses and iPhone)
- [ ] UT-10 Clear stuck uploads (Glasses and iPhone)
- [ ] UT-11 Idle Metal HQ (Transcription and voice)
- [ ] UT-12 Audio cleanup (Transcription and voice)
- [ ] UT-13 Repair (System and updates)
- [ ] UT-14 Repair Whisper (Transcription and voice)
- [ ] UT-15 Work folder (Work and agents)
- [ ] UT-16 Meetings folder (Meetings)
- [ ] UT-17 Notes folder (Work and agents)
- [ ] UT-18 Create folders (Work and agents)
- [ ] UT-19 Notes source (Work and agents)
- [ ] UT-20 Open Cursor (AI and accounts)
- [ ] UT-21 Copy pairing token (Glasses and iPhone)
- [ ] UT-22 Copy report (System and updates)
- [ ] UT-23 Open logs (System and updates)
- [ ] UT-24 Health page (System and updates)
- [ ] UT-25 Time format (General)
- [ ] UT-26 Roll back server (System and updates)
- [ ] UT-27 Finish server change (System and updates)
- [ ] UT-28 Online help (System and updates)
- [ ] G-01 Open at login (General)
- [ ] G-02 Menu bar only (General)
- [ ] G-03 Activity shortcut (General)
- [ ] G-04 Quit (System and updates)
- [ ] G-05 Versions (System and updates)
- [ ] DI-01 Dictate into apps (Dictation)
- [ ] DI-02 Microphone (Dictation)
- [ ] DI-03 Refresh microphones (Dictation)
- [ ] DI-04 Microphone fallback (Dictation)
- [ ] DI-05 Push to talk (Dictation)
- [ ] DI-06 Start and stop (Dictation)
- [ ] DI-07 Fix last dictation (Dictation)
- [ ] DI-08 Typing permission (Dictation)
- [ ] DI-09 Start sound (Dictation)
- [ ] DI-10 Stop sound (Dictation)
- [ ] DI-11 Your own sound (Dictation)
- [ ] DI-12 Volume (Dictation)
- [ ] DI-13 Pitch (Dictation)
- [ ] DI-14 Resume sounds (Dictation)
- [ ] DI-15 Other audio (Dictation)
- [ ] DI-16 System audio access (Dictation)
- [ ] DI-17 Restore clipboard (Dictation)
- [ ] DI-18 Learn from edits (Dictation)
- [ ] DI-19 Match nearby spelling (Dictation)
- [ ] DI-20 Spoken lists (Dictation)
- [ ] DI-21 Remove fillers (Dictation)
- [ ] DI-22 Capitalize sentences (Dictation)
- [ ] DI-23 AI polish (Dictation)
- [ ] DI-24 Paste then polish (Dictation)
- [ ] DI-25 Wait for keys (Dictation)
- [ ] DI-26 Polish instructions (Dictation)
- [ ] DI-27 Learn my style (Dictation)
- [ ] DI-28 Style rules (Dictation)
- [ ] DI-29 Add a style rule (Dictation)
- [ ] DI-30 Reset style (Dictation)
- [ ] DI-31 Previous polish (Dictation)
- [ ] DI-32 Keep dictations (Dictation)
- [ ] DI-33 Clear history (Dictation)
- [ ] DI-34 How shortcuts work (Dictation)
- [ ] DI-35 Dictation tab link (Dictation)
- [ ] PT-01 Session pet (Pet and appearance)
- [ ] PT-02 Jump access (Pet and appearance)
- [ ] PT-03 Pet size (Pet and appearance)
- [ ] PT-04 Custom size (Pet and appearance)
- [ ] PT-05 Figure size (Pet and appearance)
- [ ] PT-06 Animation speed (Pet and appearance)
- [ ] PT-07 Motion (Pet and appearance)
- [ ] PT-08 State sprites (Pet and appearance)
- [ ] PT-09 Characters (Pet and appearance)
- [ ] PT-10 Default character (Pet and appearance)
- [ ] PT-11 Install sprite pack (Pet and appearance)
- [ ] PT-12 Choose sprite (Pet and appearance)
- [ ] PT-13 Use COS figure (Pet and appearance)
- [ ] PT-14 Pet intro (Pet and appearance)
- [ ] PT-15 Pet right-click menu (Stays outside Settings)
- [ ] JV-01 Decision models (AI and accounts)
- [ ] JV-02 Default provider (AI and accounts)
- [ ] JV-03 Session suggestions (AI and accounts)
- [ ] JV-04 Done checks (AI and accounts)
- [ ] JV-05 Work search (AI and accounts)
- [ ] JV-06 Refresh providers (AI and accounts)
- [ ] JV-07 SubQ data retention (AI and accounts)
- [ ] JV-08 SubQ key (AI and accounts)
- [ ] JV-09 Remove SubQ key (AI and accounts)
- [ ] JV-10 Jev key status (AI and accounts)
- [ ] JV-11 Jev key (AI and accounts)
- [ ] JV-12 Remove Jev key (AI and accounts)
- [ ] WK-01 Expire old asks (Work and agents)
- [ ] WK-02 Work notifications (Work and agents)
- [ ] WK-03 Open in app (Work and agents)
- [ ] WK-04 Send without review (Work and agents)
- [ ] WK-05 When work is open (Work and agents)
- [ ] WK-06 Today home (General)
- [ ] WK-07 Quiet hours (General)
- [ ] WK-08 Work runs from Today (General)
- [ ] MT-01 Live transcript (Meetings)
- [ ] MT-02 Recording notice (Meetings)
- [ ] MT-03 Suggest recording (Meetings)
- [ ] MT-04 Apps to watch (Meetings)
- [ ] MT-05 Google Meet access (Meetings)
- [ ] MT-06 Never suggest for (Meetings)
- [ ] MN-01 App menu Setup guide… (Stays outside Settings)
- [ ] MN-02 App menu Settings… (Stays outside Settings)
- [ ] MN-03 Meetings menu (Stays outside Settings)
- [ ] MN-04 Dictation menu (Stays outside Settings)
- [ ] MN-05 Help menu (Stays outside Settings)
- [ ] MN-06 Dock menu (Stays outside Settings)
- [ ] MN-07 Menu-bar icon (Stays outside Settings)
- [ ] MN-08 Menu-bar recording strip (Stays outside Settings)
- [ ] MN-09 Activity and Welcome Settings buttons (Stays outside Settings)
- [ ] OUT-01 Fireflies key (Meetings)
- [ ] OUT-02 Import meetings (Meetings)
- [ ] OUT-03 Keep importing (Meetings)
- [ ] OUT-04 Track usage (Work and agents)
- [ ] OUT-05 Default planner (Work and agents)
- [ ] OUT-06 Planning effort (Work and agents)
- [ ] OUT-07 Search by meaning (AI and accounts)

Decisions from section 2:

- [ ] O-01 Voiceprint warning shown under Transcription and voice
- [ ] O-02 Decide on a reset for the first auto-send confirmation
- [ ] O-07 Early sync shown as status, set on the server
- [ ] O-08 HQ prefill shown as status, set on the server
- [ ] O-09 Every .env lock keeps its locked look and reason
- [ ] O-10 Reset message count reachable from every host
- [ ] O-11 Today options show disabled with a reason while Today is off
- [ ] O-12 Web help button renamed Online help

---

## 5. Notes for Anand

**What the prototype needs to show to reach parity**

1. **Ten categories in the left list** (3.1 to 3.10), in that order or close to it. General first, System and updates last.
2. **Server-backed settings restart the server.** Twelve settings restart the COS server when they change (UT-03 to UT-09, UT-11, UT-12, UT-15 to UT-17); the setup guide's tier action and Turn on buttons (SG-05, SG-07, SG-08) do too. Nine of them use a draft and an Apply button today (UT-03 to UT-09, UT-11, UT-12); the three folder pickers apply on choose. Each needs one line that says "Applying restarts the server." While work is running these are disabled, and the card should say why (ST-30).
3. **Locked and hidden states.** Many cards appear only on a newer server (Transcription 6.72.0, Live cue limits 6.79.2, Your own key 6.80.0, Polish instructions 6.85.0, Your style 6.91.0, Morning brief 6.43.0, Home city 6.71.13). Show the card when supported, and nothing (or a one-line "Update the server to use this") when not. Some values are set in the server's `.env`; those show the value, a lock and "Set on the server."
4. **Confirmations stay inline.** Every row marked Confirm in section 3 carries a confirmation today. Keep them in the card, not as system alerts. PT-09's character confirm is click-only on purpose: Return must not accept it.
5. **Dictation is one category.** Today the same settings render in two places. The Dictation tab's Settings button and the Dictation menu's Settings… should open this category.
6. **The setup guide stays a guided flow.** Settings needs one row that opens it (SG-01) and a show or hide switch for the Finish setup card. Its unique steps (AI sign-in, Ollama, voice download, engine test, glasses pairing) are placed in their categories in section 3; the guide can keep showing them in its own order.
7. **Long lists scroll inside their card.** Morning brief sources (11 or more), the character gallery, the meeting sync list and the unavailable model list all need a capped, scrolling area.
8. **Your option-card pattern fits pickers with two to four choices**: Your devices (SG-02), Pet size (PT-03), Motion (PT-07), Quality tier (UT-03), Time format (UT-25), While dictating (DI-15), Learn from edits (DI-18), AI polish (DI-23), When work is open (WK-05). Model and provider pickers (TR-02 to TR-04, JV-02 to JV-05, KL-06, MA-01, UT-08) come from the server and can be long, so they stay dropdowns.
9. **Keys and secrets are never shown again** after saving (Jev, SubQ, Fireflies, your own key). The field is a paste box with a Save, then a status line.

**Items that are status, not settings**

Show these as read-only lines inside the matching card, never as controls: ST-01 to ST-31 except the actions ST-15, ST-17, ST-22 and ST-23; H-01, H-03, G-05, C-09, DR-01, MA-02, MA-03, MA-12, MA-13, TR-05, KL-04, JV-07, JV-10, UT-19, MB-01, MB-09, MT-05, DI-34. Server health belongs at the top of System and updates. A short health summary (Server, Version, Recovery) could also sit at the top of General.

**Copy that names today's labels**

These strings point people to a setting by its current name. Renaming a label means updating them in the same change:

| String | Where |
| --- | --- |
| "Enable live transcripts in Settings to view the recording." | Views.swift:1936 |
| "Turn the pet off. Settings, under Session pet, brings it back" | ProviderConnectViews.swift:652 |
| "Already on? Use Reset and add again in COS Control Settings, under Session pet." | ControllerModel.swift:6209 |
| "Prep me is off: Settings, Start Work runs from Today" and "Starting Work runs from Today is off in Settings." | ActivityWindow.swift:8972, 8030 |
| "Continue agent threads is off in Settings." | ControllerModel.swift:7220, 7591, 7640, 8134, 8168 |
| "Its default is Settings › Work › Send plans without review." | WorkTaskChat.swift:1552 |
| "(Settings, Transcription)" | MacDictation.swift:4114 |
| "Check Transcription settings before recording." | Views.swift:1366 |
| "Open Transcription settings" | COSControlApp.swift:154, MacDictation.swift:3464, MacDictationCore.swift:6210 |
| "Choose COS Data in the menu-bar panel…", "Open Logs from the menu-bar panel…" | ActivityWindow.swift:4790, 6088 |
| "Choose a Work Folder or Meetings Library first, then Create Folders." and other contextBrowserHint lines | Views.swift:1771-1783 |
| "…use Update Server." / "Update the server in Settings." | ControllerModel.swift:10569, 10724; Models.swift:6453; MeetingAskCore.swift:977, 980, 1067, 1071, 1390, 1394, 1463 |
| "Live cues is off in Settings, so this meeting has no cues." | MeetingAskCore.swift:1598 |
| "…needs an API key in Settings." (decision provider) | Models.swift:2307, 2308, 2314 |
| "Session access and Continue are optional in Settings." | ControlSetup.swift:200 |

**For the builder**

- Tests pin today's labels, anchors and order. At least these read `Sources/Views.swift` or the settings views directly: `Tests/run.sh`, `app-update-badge-pins.py`, `dictation-parity-pins.py`, `hardening-337-pins.py`, `key-lanes-pins.py`, `live-cues-pins.py`, `permission-guide-pins.py`, `provider-connect-pins.py`, `refresh-check-pins.py`, `mutate-dictation-everyone.py`, `mutate-live-cues.py`, `mutate-provider-connect.py`, `LiveCuesChecks.swift`, `LiveCuesRender.swift`, `MeetingAskChecks.swift`, `TranscriptionSettingsChecks.swift`, `TranscriptionSettingsRender.swift`, `ProviderConnectRender.swift`, `MarkdownContract.swift`, `run-work-session-hub.sh`.
- Every opener that sets `model.panelScrollTarget` (`settings`, `transcription`, `decision-models`, `setup-guide`, `key-lanes`) must land on the matching category.
- `ControlPanel` hosts are three: menu-bar panel, Settings window, Activity. Whatever the new view is, each host must still reach H-04 (see O-10) and the update check.

---

## Appendix A. Grep reconciliation

Searched `Sources/*.swift` with `grep -n -F`. Each hit maps to a row or is excluded with a reason.

### `@AppStorage` (23)

| Hit | Maps to |
| --- | --- |
| ActivityMeetings.swift:15 | MT-01 (reader) |
| ActivityMeetings.swift:2255 | Excluded: `meetingAskPanelWidth`, remembered panel width |
| ActivityWindow.swift:514 | MT-01 (reader) |
| ActivityWindow.swift:583 | WK-06 (reader) |
| MacRecording.swift:977 | Excluded: `macRecording.optionsExpanded`, remembered disclosure |
| MacRecording.swift:981 | MT-02 (reader) |
| MacRecording.swift:1590 | MT-02 |
| WorkChatQueue.swift:201 | WK-05 (reader) |
| WorkContextMeter.swift:355 | Excluded: `cos.workContextExpanded`, remembered disclosure |
| WorkTaskChat.swift:1516 | OUT-05 |
| WorkTaskChat.swift:1518 | OUT-06 |
| WorkTaskChat.swift:1520 | WK-04 (reader) |
| WorkTaskChat.swift:1521 | Excluded from the table: orphan O-02 |
| WorkTaskChat.swift:1524 | Excluded: `cos.workChatAutoSendCards`, per-card Auto-send overrides (default is WK-04) |
| WorkWorkspaceView.swift:1338 | Excluded: `cos.workLayout`, remembered layout |
| WorkWorkspaceView.swift:1339 | Excluded: `cos.workSessionsRowCollapsed`, remembered collapse |
| WorkWorkspaceView.swift:3285 | WK-06 (reader) |
| Views.swift:534 | MT-01 |
| Views.swift:536 | WK-06 |
| Views.swift:537 | WK-07 |
| Views.swift:538 | WK-08 |
| Views.swift:540 | WK-04 |
| Views.swift:542 | WK-05 |

### `Toggle(` (59)

| Hit | Maps to |
| --- | --- |
| ActivityMeetings.swift:1271 | OUT-03 |
| ActivityMeetings.swift:1977 | Excluded: "Include completed tasks", a filter in the link-a-task search |
| ActivityWindow.swift:3168 | OUT-07 |
| ActivityWindow.swift:3271 | Excluded: "Hide reviewed", a Speakers list filter |
| ActivityWindow.swift:5503 | Excluded: "Only matches", an archive search filter |
| ActivityWindow.swift:7306 | Excluded: voice-naming confirmation checkbox |
| ActivityWindow.swift:7312 | Excluded: voice-naming confirmation checkbox |
| COSBrand.swift:1176 | Excluded: COSSwitchStyle definition |
| COSBrand.swift:1236 | Excluded: COSCheckStyle definition |
| COSBrand.swift:1298 | Excluded: COSChipToggleStyle definition |
| KeyLanesViews.swift:35 | KL-01 |
| KeyLanesViews.swift:141 | KL-15 |
| KeyLanesViews.swift:173 | KL-07 |
| MacDictation.swift:4113 | DI-01 |
| MacDictation.swift:4120 | DI-04 |
| MacDictation.swift:4135 | DI-17 |
| MacDictation.swift:4141 | DI-19 |
| MacDictation.swift:4145 | DI-20 |
| MacDictation.swift:4148 | DI-21 |
| MacDictation.swift:4150 | DI-22 |
| MacDictation.swift:4169 | DI-24 |
| MacDictation.swift:4174 | DI-25 |
| MacDictation.swift:5780 | DI-27 |
| MacDictation.swift:5821 | DI-31 |
| MacDictation.swift:6301 | DI-11 |
| MacRecording.swift:1602 | MT-03 |
| MacRecording.swift:1607 | MT-04 |
| MeetingAsk.swift:600 | MA-06 |
| MeetingAsk.swift:771 | TR-06 |
| ProviderConnectViews.swift:530 | SG-12 |
| SessionUsageView.swift:208 | OUT-04 |
| SessionUsageView.swift:238 | Excluded: "Exclude cache reads", a usage chart filter |
| SessionPet.swift:1342 | PT-15 |
| WorkContextMeter.swift:511 | Excluded: not a Toggle; the match is `onToggle()` inside a Button |
| WorkTaskChat.swift:1550 | Excluded: per-card "Auto-send" override; its default is WK-04 |
| Views.swift:1067 | WK-01 |
| Views.swift:1187 | PT-01 |
| Views.swift:2459 | MB-02 |
| Views.swift:2489 | MB-04 |
| Views.swift:2526 | MB-05 |
| Views.swift:2566 | MB-06 |
| Views.swift:2694 | UT-04 |
| Views.swift:2707 | UT-05 |
| Views.swift:2719 | UT-06 |
| Views.swift:2730 | UT-07 |
| Views.swift:2757 | UT-09 |
| Views.swift:2774 | UT-11 |
| Views.swift:2787 | UT-12 |
| Views.swift:2851 | G-01 |
| Views.swift:2854 | G-02 |
| Views.swift:2865 | WK-02 |
| Views.swift:2869 | WK-03 |
| Views.swift:2873 | WK-04 |
| Views.swift:2883 | MT-01 |
| Views.swift:2888 | WK-06 |
| Views.swift:2892 | WK-07 |
| Views.swift:2895 | WK-08 |
| Views.swift:4296 | Excluded: "Include related knowledge", a Copy context option in a learning detail |
| WorkWorkspaceView.swift:1701 | Excluded: Intake chip, a Work view toggle |

### `Picker(` (11)

| Hit | Maps to |
| --- | --- |
| ActivityWindow.swift:149 | Excluded: DatePicker "Schedule for", one task run |
| ActivityWindow.swift:2513 | Excluded: DatePicker "Schedule for", one task run |
| MeetingAsk.swift:757 | TR-01 (call site) |
| MeetingAsk.swift:822 | TR-01 (definition) |
| SessionUsageView.swift:282 | Excluded: DatePicker "From", a usage range filter |
| SessionUsageView.swift:283 | Excluded: DatePicker "Through", a usage range filter |
| Views.swift:1131 | JV-02 |
| Views.swift:1134 | JV-03, JV-04, JV-05 (one call per workflow) |
| Views.swift:1176 | JV-02 to JV-05 (definition) |
| WorkWorkspaceView.swift:3523 | Excluded: DatePicker "Check in", one Work item |
| WorkWorkspaceView.swift:3570 | Excluded: DatePicker "Next check-in", one Work item |

### `perform("set-` (12, all in ControllerModel.swift)

| Hit | Maps to |
| --- | --- |
| :2010 `set-workdir` | UT-15 |
| :2025 `set-operations-dir` | UT-16 |
| :2037 `set-context-dir` | UT-17 |
| :2055 `set-transcription-tier` | UT-03 (also SG-05) |
| :2059 `set-background-jobs` | UT-04 |
| :2063 `set-meeting-preview` | UT-05 |
| :2149 `set-thread-attach` | UT-07 (also SG-08) |
| :2174 `set-ollama-model` | UT-08 |
| :2178 `set-video-upload-v2` | UT-09 |
| :2188 `set-claude-sessions` | UT-06 (also SG-07, Today Turn on) |
| :2351 `set-idle-metal-hq` | UT-11 |
| :2355 `set-adaptive-audio-cleanup` | UT-12 |

Totals: 79 mapped (16 + 46 + 5 + 12), 26 excluded (7 + 13 + 6 + 0). 79 + 26 = 105.

## Appendix B. Other searches

| Search | Hits | Accounted for |
| --- | --- | --- |
| `Slider(` | 5 | DI-12, DI-13, MA-08, PT-05, PT-06 |
| `Stepper(` / `COSStepper(` | 4 | MA-09 to MA-11 (one call), MB-06, PT-08, PT-04 |
| `SecureField(` | 3 | OUT-01, JV-11, JV-08 |
| `TextField(` | 40 | In rows: KL-08, KL-12, MA-05, DM-01, MB-03, MB-06, PT-04, PT-09 (search). The other 32 are search boxes, composers, task and naming fields, dictionary entry, recording title and cue notes in working views, not settings |
| `COSDropdown(` | 45 | Settings ones: KL-06, KL-10, DI-02, DI-18, DI-23, DI-32, DI-15, DI-29, DI-09/DI-10, TR-02 to TR-04, TR-08, TR-09 (shared `picker`), TR-01, MA-01, SG-06, JV-02 to JV-05, UT-08, WK-05, UT-25, OUT-02 (two), OUT-05, OUT-06. The rest are view filters, sort orders and per-item pickers (domain, scope, order, review model, fork target, audio source for one recording, voice identity for one meeting) |
| `COSViewSwitch(` | 15 | UT-03, SG-05, PT-03, PT-07. The rest switch views inside Activity tabs |
| `UserDefaults.standard` | 117 | Each settings key is named in a row's Backing column. The remaining keys are state, not settings: setup and onboarding progress, seen and dismissed markers (O-03 to O-05), run counters (`activityTodayRun*`), remembered sorts and disclosures, pet internal generations and ledgers, queued prompts, What's New last build, dictation pending and proof markers |

Searched and found nothing outside the rows above: a SwiftUI `Settings {` scene (none; `CommandGroup(replacing: .appSettings)` is MN-02).
