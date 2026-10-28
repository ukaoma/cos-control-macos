# COS Control Settings copy deck

The words for the Settings hub. It supersedes the inventory's proposed labels and descriptions where they differ (`design/settings-hub/SPEC.md`). Base: `claude/control-settings-copy` at `0a47e7e` (shipped 0.5.351 plus the hub docs). Line numbers are from that base, so grep by the current text if your file has moved.

## How to read this

- One row per string. **Current** is the source literal, verbatim (`\(…)` is interpolation). **Proposed** is the new text, or `keep`.
- **Pinned by** is every test file that contains the current text (an automatic search, so a hit can be a different string with the same words; check before editing). **Quoted on gotcos.com** is the same search over `cos-starter`. Rows marked `none` had no hit.
- **Owner** is by file. `hub-builder`: `Views.swift`, `ActivityWindow.swift`, new hub rows, and the strings in `Models.swift`, `ControllerModel.swift`, `WorkChatQueue.swift`, `WorkTaskChat.swift` that feed those views. `copy-pass`: `MeetingAsk.swift`, `MacDictation.swift`, `MacRecording.swift`, `KeyLanesViews.swift`, `ProviderConnectViews.swift`, `PermissionGuideViews.swift`, `SessionPet.swift`, and the copy enums that feed them in `MeetingAskCore.swift`, `MacDictationCore.swift`, `KeyLanes.swift`, `PermissionGuideModel.swift`, `ProviderConnectModel.swift`.
- `file: new (hub chrome)` rows have no current string. The builder places them.
- Any inventory row not listed here keeps its current text. Server and helper text (refusals, notes the server sends) is out of scope.
- Kinds in the generator: label, description, help (tooltip), button, option, confirm title, confirm message, confirm action, status, empty state. Labels are 4 words or fewer; descriptions and help 90 characters or fewer. Exceptions are listed at the end.

## Terms

| Use | Not |
| --- | --- |
| the COS server; "the server" once the context is set | glasses server, glasses-server, managed server, managed runtime, legacy LaunchAgent, COS (for the server) |
| older server | legacy server, self-managed checkout (in user copy) |
| AI apps (Claude Code, Codex, Cursor Agent) | agent CLIs |
| session (a Claude, Codex or Cursor conversation) | agent thread (for those) |
| thread (a COS thread) | fence, fenced |
| Work run | run, job (for a Today run) |
| meeting (saved, in the library); recording (being captured, or kept unsaved) | capture, retained capture, session file |
| dictation | insertion |
| voice profile; voiceprint model (the model that matches them) | speaker embedding |
| key (Jev key, SubQ key, your own key) | key lane, API secret |
| the glasses; the glasses app (COS on the phone) | G2, companion (in user copy) |
| meetings folder, work folder, notes folder | Meetings Library, Work Folder, COS Data |
| Set on the server. | Set in .env, Turned on in the server's environment |
| Applying restarts the server. | Applying restarts the COS server, may restart |
| menu bar, menu bar icon | menu-bar |
| sentence case for every label and button | Title Case (Update Server, Run Doctor, Open Logs) |

## Notes for the builder

1. **Restart rows.** Every Apply row ends its description with `Applying restarts the server.` (HUB-07). Folder pickers apply on choose and say `Changing it restarts the server.` When Apply is disabled by running work, show HUB-08.
2. **Renames that other strings point at.** When you rename these, change the pointer in the same commit: WK-08 (two Today lines in `ActivityWindow.swift`), UT-07 (`Continue agent threads is off in Settings.`, five places in `ControllerModel.swift`), MT-01 (H-10), UT-17 and UT-23 (two `ActivityWindow.swift` lines), C-04z (`ControllerModel.swift`, two places), PT-02x (`ControllerModel.swift:6176`), WK-04x (`WorkTaskChat.swift:1552`).
3. **Sentence case renames are quoted on gotcos.com** (Run Doctor, Work Folder, Guided Setup, COS Data, Meetings Library and others). Update Server and Create Folders stay as they are (test churn rule, below). The release updates the site from the "Quoted on gotcos.com" column.
4. **UT-22d** ("Keys and tokens are left out") comes from the board. Confirm the report redacts them before shipping that sentence; otherwise use "Copy a report for the COS team."
5. **Kept rules (lead, 2026-10-28).** A string that something outside Settings also shows (the Welcome window, Today, the HUD, the lens, a string the helper compares) is "Shared, kept". A string with more than about 10 test locations is kept unless it misleads. Both lists are at the end.
6. **Category and group rows** (HUB-C…) give `Name: description`. The 90-character limit applies to the description after the colon.

## 0. Hub chrome

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
Category names come from the reviewed boards. The one-line description shows under the category title. Group descriptions are optional card subtitles or rail tooltips.

### 0.1 Shell

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HUB-01 | `new (hub chrome)` | (none) | Settings | Title, as on the boards | none | none | hub-builder |
| HUB-02 | `new (hub chrome)` | (none) | Today | Back control, as on the boards | none | none | hub-builder |
| HUB-03 | `new (hub chrome)` | (none) | Search settings | The board said "Search 253 settings"; a count goes stale | none | none | hub-builder |
| HUB-04 | `new (hub chrome)` | (none) | No settings match "{query}". | Search empty state | none | none | hub-builder |
| HUB-05 | `new (hub chrome)` | (none) | On this page | Rail title, as on board B | none | none | hub-builder |
| HUB-06 | `new (hub chrome)` | (none) | Advanced | Disclosure title; the count shows beside it | none | none | hub-builder |
| HUB-07 | `new (hub chrome)` | (none) | Applying restarts the server. | One sentence for every Apply row; see section 0.3 | none | none | hub-builder |
| HUB-08 | `new (hub chrome)` | (none) | Restart waits until running work finishes. | Why Apply is disabled while work runs (ST-30) | none | none | hub-builder |
| HUB-09 | `new (hub chrome)` | (none) | Set on the server. | Every .env lock (O-09); replaces "Set in .env" and "Set on the server" | none | none | hub-builder |
| HUB-10 | `new (hub chrome)` | (none) | Update the server to use this. | A card hidden on an older server, when one line is shown | none | none | hub-builder |

### 0.2 Categories and groups

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HUB-C01 | `new (hub chrome)` | (none) | General: How COS Control opens, its shortcut, Today and the setup guide. | Category description | none | none | hub-builder |
| HUB-C01a | `new (hub chrome)` | (none) | App: Login, Dock, shortcut and time format. | Group | none | none | hub-builder |
| HUB-C01b | `new (hub chrome)` | (none) | Activity home: How Activity opens and what Today does. | Group | none | none | hub-builder |
| HUB-C01c | `new (hub chrome)` | (none) | Setup guide: Step-by-step setup and the Finish setup card. | Group | none | none | hub-builder |
| HUB-C02 | `new (hub chrome)` | (none) | AI and accounts: The AI apps COS works through, your keys and the models behind Work. | Category description | none | none | hub-builder |
| HUB-C02a | `new (hub chrome)` | (none) | Your AI apps: Claude Code, Codex and Cursor on this Mac. | Group | none | none | hub-builder |
| HUB-C02b | `new (hub chrome)` | (none) | Local model: An Ollama model that runs on this Mac. | Group | none | none | hub-builder |
| HUB-C02c | `new (hub chrome)` | (none) | Decision models: Jev or SubQ, for Work suggestions, done checks and Work search. | Group | none | none | hub-builder |
| HUB-C02d | `new (hub chrome)` | (none) | Your own key: Answer on your own API key, under a daily cap. | Group | none | none | hub-builder |
| HUB-C02e | `new (hub chrome)` | (none) | Search: Find messages by meaning. | Group | none | none | hub-builder |
| HUB-C03 | `new (hub chrome)` | (none) | Glasses and iPhone: Pair your glasses and phone, and how videos reach this Mac. | Category description | none | none | hub-builder |
| HUB-C03a | `new (hub chrome)` | (none) | Devices: Tailscale, pairing and the glasses app. | Group | none | none | hub-builder |
| HUB-C03b | `new (hub chrome)` | (none) | Video uploads: Videos sent from the phone to this Mac. | Group | none | none | hub-builder |
| HUB-C04 | `new (hub chrome)` | (none) | Meetings: Recording, the meeting assistant, live cues and your meeting library. | Board text, keep | none | none | hub-builder |
| HUB-C04a | `new (hub chrome)` | (none) | Recording: Live transcript, record suggestions and the recording notice. | Group | none | none | hub-builder |
| HUB-C04b | `new (hub chrome)` | (none) | Meeting assistant: The model that answers when you ask during a meeting. | Group | none | none | hub-builder |
| HUB-C04c | `new (hub chrome)` | (none) | Live cues: Short prompts on the glasses during a meeting, and their limits. | Group | none | none | hub-builder |
| HUB-C04d | `new (hub chrome)` | (none) | Library and sync: Where meetings are kept, sync and unsaved recordings. | Group | none | none | hub-builder |
| HUB-C04e | `new (hub chrome)` | (none) | Fireflies import: Bring Fireflies meetings into your library. | Group | none | none | hub-builder |
| HUB-C05 | `new (hub chrome)` | (none) | Dictation: Type by voice into any Mac app: shortcuts, sounds, text and AI polish. | Category description | none | none | hub-builder |
| HUB-C05a | `new (hub chrome)` | (none) | Dictation: Turn dictation on and choose its engine. | Group | none | none | hub-builder |
| HUB-C05b | `new (hub chrome)` | (none) | Microphone: The microphone dictation uses. | Group | none | none | hub-builder |
| HUB-C05c | `new (hub chrome)` | (none) | Shortcuts: The keys that start, stop and fix a dictation. | Group | none | none | hub-builder |
| HUB-C05d | `new (hub chrome)` | (none) | Sounds and audio: Start and stop sounds, and other apps' audio. | Group | none | none | hub-builder |
| HUB-C05e | `new (hub chrome)` | (none) | Text: How COS writes what you say. | Group | none | none | hub-builder |
| HUB-C05f | `new (hub chrome)` | (none) | AI polish: Claude cleans up a dictation before or after it lands. | Group | none | none | hub-builder |
| HUB-C05g | `new (hub chrome)` | (none) | History: How long dictations stay on this Mac. | Group | none | none | hub-builder |
| HUB-C06 | `new (hub chrome)` | (none) | Transcription and voice: The engines and models that turn speech into text on this Mac. | Category description | none | none | hub-builder |
| HUB-C06a | `new (hub chrome)` | (none) | Voice setup: Local transcription and how much your Mac can run. | Group | none | none | hub-builder |
| HUB-C06b | `new (hub chrome)` | (none) | Models: The models for live preview, saved meetings and checks. | Group | none | none | hub-builder |
| HUB-C06c | `new (hub chrome)` | (none) | Performance: GPU use and playback cleanup. | Group | none | none | hub-builder |
| HUB-C07 | `new (hub chrome)` | (none) | Work and agents: Sessions, Work chat, background jobs, folders and the morning brief. | Category description | none | none | hub-builder |
| HUB-C07a | `new (hub chrome)` | (none) | Sessions: Your Claude, Codex and Cursor sessions in Activity. | Group | none | none | hub-builder |
| HUB-C07b | `new (hub chrome)` | (none) | Work chat: How Work plans and sends. | Group | none | none | hub-builder |
| HUB-C07c | `new (hub chrome)` | (none) | Background: Replies that keep running after the phone app closes. | Group | none | none | hub-builder |
| HUB-C07d | `new (hub chrome)` | (none) | Folders and notes: Where your AI apps work and where COS reads notes. | Group | none | none | hub-builder |
| HUB-C07e | `new (hub chrome)` | (none) | Morning brief: A daily brief in your inbox. | Group | none | none | hub-builder |
| HUB-C07f | `new (hub chrome)` | (none) | Domains: The areas your tasks are grouped by. | Group | none | none | hub-builder |
| HUB-C07g | `new (hub chrome)` | (none) | Paused threads: Threads COS stopped writing to. Shows only when one exists. | Group | none | none | hub-builder |
| HUB-C08 | `new (hub chrome)` | (none) | Privacy and permissions: What COS can use on this Mac. Each permission turns on one feature. | Category description | none | none | hub-builder |
| HUB-C09 | `new (hub chrome)` | (none) | Pet and appearance: The session pet: its character, size and motion. | Category description | none | none | hub-builder |
| HUB-C09a | `new (hub chrome)` | (none) | Session pet: Turn the pet on, and its size and motion. | Group | none | none | hub-builder |
| HUB-C09b | `new (hub chrome)` | (none) | Characters: Pick a character or install your own. | Group | none | none | hub-builder |
| HUB-C10 | `new (hub chrome)` | (none) | System and updates: The COS server on this Mac, app updates, and checks when something is off. | Board text, keep | none | none | hub-builder |
| HUB-C10a | `new (hub chrome)` | (none) | Server: Status, restart and updates for the COS server. | Group | none | none | hub-builder |
| HUB-C10b | `new (hub chrome)` | (none) | App updates: COS Control's version and updates. | Group | none | none | hub-builder |
| HUB-C10c | `new (hub chrome)` | (none) | Troubleshooting: Checks, repair, logs and the support report. | Group | none | none | hub-builder |

Category descriptions are 90 characters or fewer counting only the text after the colon.

## 3.1 General

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### App

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G-01 | `Views.swift:2836` | Launch COS Control at login | Open at login | Same name as the Permissions row | none | control/docs/index.html:552, control/docs/index.html:1105 | hub-builder |
| G-01d | `new (hub chrome)` | (none) | Start COS Control when you log in. | New description | none | none | hub-builder |
| G-02 | `Views.swift:2839` | Show in menu bar only | Menu bar only | 4 words, same as the Dock notice | Tests/mutate-provider-connect.py:106, Tests/ProviderConnectRender.swift:109, Tests/provider-connect-pins.py:99 | control/docs/index.html:611, control/docs/index.html:1105 | hub-builder |
| G-02h | `Views.swift:2841` | Hide COS Control from the Dock. The menu-bar icon stays, and opening COS Control from Finder opens Activity | Hides the Dock icon. The menu bar icon stays; opening the app shows Activity. | 90 chars; one spelling of menu bar | none | none | hub-builder |
| H-08 | `ProviderConnectViews.swift:1195` | COS Control is in the Dock now. | keep | Clear | none | none | copy-pass |
| H-08a | `ProviderConnectViews.swift:1197` | Menu bar only | keep | Matches G-02 | none | none | copy-pass |
| H-08b | `ProviderConnectViews.swift:1198` | Keep | Keep in Dock | Says what it keeps | none | none | copy-pass |
| G-03 | `Views.swift:4655` | Open Activity with | Activity shortcut | Names the setting, not a sentence fragment | none | control/docs/index.html:612, control/docs/index.html:1105 | hub-builder |
| G-03d | `new (hub chrome)` | (none) | Opens Activity from any app. | New description | none | none | hub-builder |
| G-03a | `Views.swift:4669` | Press keys… | keep | Clear | none | none | hub-builder |
| G-03b | `Views.swift:4704` | Add Command, Control or Option to the key. | keep | Clear | none | none | hub-builder |
| UT-25 | `Views.swift:2889` | Clock | Time format | Says what changes | Tests/run.sh:5099 | control/docs/index.html:696, control/docs/index.html:1010 | hub-builder |
| UT-25d | `Views.swift:2894` | How meeting times read in Meetings and Speakers. | How times show in Meetings and Speakers. | Shorter | none | none | hub-builder |
| UT-25o | `Models.swift:5357` | 12-hour (1:02 PM) | keep | Clear | none | none | hub-builder |
| UT-25p | `Models.swift:5358` | 24-hour (13:02) | keep | Clear | none | none | hub-builder |
| H-09 | `Views.swift:1938` | Get started with COS | keep | Clear | none | none | hub-builder |

### Activity home

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| WK-06 | `Views.swift:2873` | New Today home | Today home | Drops "New" from a setting name | Tests/activity-today-pins.py:197 | docs/index.html:2127, control/appcast.json:144, control/docs/index.html:1279 | hub-builder |
| WK-06h | `Views.swift:2875` | Activity opens on Today: what needs you, what is running, what is next, and today's meeting suggestions, with the section rail on every tab. Off: the earlier home and the tab strip | Activity opens on Today: what needs you, what is running and what is next. | 90 chars; Off is implied | none | none | hub-builder |
| WK-07 | `Views.swift:2877` | Quiet hours on Today | Quiet hours | Group already says Today | Tests/activity-today-pins.py:197 | none | hub-builder |
| WK-07h | `Views.swift:2879` | After 6 PM, before 6 AM and on weekends, Needs you folds everything below agent questions under For tomorrow. Running and session questions never fold | From 6 PM to 6 AM and on weekends, Today folds what can wait under For tomorrow. | 90 chars; keeps the hours | none | none | hub-builder |
| WK-08 | `Views.swift:2880` | Start Work runs from Today | Work runs from Today | 4 words; update the two Today lines (ActivityWindow) that name it | Tests/activity-today-pins.py:197, Tests/hardening-337-pins.py:164 | none | hub-builder |
| WK-08h | `Views.swift:2882` | Prep me and Return in the Ask box each start one Work run, at most 20 a day, paused for 15 minutes after 3 failed starts. Off: no Prep me, and Return files your words to the Work inbox | Prep me and Ask start Work runs, up to 20 a day. Off: Ask files to the Work inbox. | 90 chars; keeps the daily cap | none | none | hub-builder |
| WK-07g | `new (hub chrome)` | (none) | Turn on Today home to use this. | O-11: shown disabled with a reason | none | none | hub-builder |
| WK-08x | `ActivityWindow.swift:8972` | Prep me is off: Settings, Start Work runs from Today | Prep me is off: Settings, Work runs from Today | Follows the WK-08 rename | Tests/hardening-337-pins.py:164 | none | hub-builder |
| WK-08y | `ActivityWindow.swift:8030` | Starting Work runs from Today is off in Settings. | Work runs from Today is off in Settings. | Follows the WK-08 rename | none | none | hub-builder |

### Setup guide

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SG-01 | `ProviderConnectViews.swift:356` | Setup guide | keep | Clear | Tests/mutate-provider-connect.py:76, Tests/key-lanes-pins.py:61, Tests/ProviderConnectRender.swift:210, Tests/provider-connect-pins.py:132 (+3 more) | wizard/index.html:400, wizard/index.html:680, docs/index.html:2156, control/docs/index.html:498 (+6 more) | copy-pass |
| SG-01d | `ProviderConnectViews.swift:370` | Your AI apps, local voice and their settings, each with one click to set up | Set up your AI, voice, glasses and permissions, one step at a time. | Names all four steps | none | none | copy-pass |
| SG-01c | `ProviderConnectViews.swift:328` | Each AI you sign in to can run your sessions. Skip anything for now and come back here. COS checks again on its own while this is open. | Each AI you sign in to can run your sessions. Skip any step and come back later. | 90 chars | none | none | copy-pass |
| SG-01e | `ProviderConnectViews.swift:326` | Done | keep | Clear | Tests/WhatsNewChecks.swift:252, Tests/run.sh:1906, Tests/run.sh:1961, Tests/SessionLiveFeedContract.swift:83 | index.html:843, assets/ring-lessons.js:43, assets/docs-control.js:19, control/docs/index.html:1012 | copy-pass |
| SG-14 | `ProviderConnectViews.swift:1035` | Hide setup guide | keep | Shared, kept: also shown in the setup guide (Welcome window) | Tests/ProviderConnectChecks.swift:459, Tests/provider-connect-pins.py:131 | none | copy-pass |
| SG-14h | `ProviderConnectViews.swift:1036` | Removes the Finish setup card. The guide stays in the Dock menu, the Help menu, the panel and the pet's menu | keep | Shared, kept: also shown in the setup guide (Welcome window) | none | none | copy-pass |
| SG-14b | `ProviderConnectViews.swift:1033` | Show Finish setup at the top again | keep | Shared, kept: also shown in the setup guide (Welcome window) | none | none | copy-pass |
| SG-15 | `ProviderConnectViews.swift:1103` | Continue setup | keep | Clear | none | control/docs/index.html:506 | copy-pass |
| SG-15a | `ProviderConnectViews.swift:1089` | Hide | keep | Clear in the card | Tests/provider-connect-pins.py:131 | none | copy-pass |
| SG-15h | `ProviderConnectViews.swift:1090` | Hide the setup guide. Reopen it from the Dock menu, Help, the panel or the pet | keep | Shared, kept: also shown in Today (Activity home) | none | none | copy-pass |
| SG-15n | `ProviderConnectViews.swift:1100` | Next: \(next.title). \(next.unlocks) | keep | Clear | Tests/mutate-activity-home.py:87, Tests/MeetingAskChecks.swift:258, Tests/MeetingAskChecks.swift:270, Tests/ModelsContract.swift:249 (+2 more) | none | copy-pass |
| SG-07 | `ProviderConnectModel.swift:964` | Show your AI sessions | keep | Shared, kept: also shown in the setup guide (Welcome window) | Tests/SetupAssistantChecks.swift:480, Tests/SetupAssistantChecks.swift:491 | control/docs/index.html:510, control/docs/index.html:1005 | copy-pass |
| SG-07a | `ProviderConnectModel.swift:970` | Show your AI sessions | keep | Shared, kept: also shown in the setup guide (Welcome window) | Tests/SetupAssistantChecks.swift:480, Tests/SetupAssistantChecks.swift:491 | control/docs/index.html:510, control/docs/index.html:1005 | copy-pass |
| SG-07u | `ProviderConnectModel.swift:965` | Lists your Claude, Codex and Cursor sessions in Activity and on the pet, so you can follow and continue them. | keep | Guide row, reads well | none | none | copy-pass |
| SG-07d | `ProviderConnectModel.swift:966` | It reads names, folders and times (not what was said) and serves them on your local network. Leave it off on an untrusted network. | keep | Privacy fact; already plain | none | none | copy-pass |
| SG-07b | `ProviderConnectModel.swift:968` | Turn on | keep | Clear | Tests/ProviderConnectChecks.swift:490, Tests/ProviderConnectChecks.swift:828, Tests/PermissionGuideChecks.swift:93, Tests/mutate-activity-today.py:42 (+1 more) | wizard/index.html:479, docs/index.html:1108, docs/index.html:1415, docs/index.html:2045 (+3 more) | copy-pass |
| SG-08 | `ProviderConnectModel.swift:974` | Continue agent threads | keep | Shared, kept: also shown in the setup guide (Welcome window) | Tests/run.sh:1769 | docs/index.html:1186, control/docs/index.html:510, control/docs/index.html:1020, control/docs/index.html:1210 | copy-pass |
| SG-08u | `ProviderConnectModel.swift:975` | A reply from COS writes into your real Claude or Codex session instead of starting a new thread. | keep | Clear | none | none | copy-pass |
| SG-09 | `ProviderConnectModel.swift:981` | Jev (TypeSafe) | keep | Guide row name, as on typesafe.ai | Tests/mutate-work-search.py:162 | docs/index.html:2218, control/docs/index.html:510 | copy-pass |
| SG-09d | `ProviderConnectModel.swift:983` | Optional. Keys come from typesafe.ai; paste one in Settings, under Jev (TypeSafe). | keep | Shared, kept: also shown in the setup guide (Welcome window) | none | none | copy-pass |
| SG-09b | `ProviderConnectModel.swift:984` | Add a key | keep | Clear | none | none | copy-pass |
| SG-10 | `ProviderConnectModel.swift:991` | Permissions | keep | Clear | Tests/SetupAssistantChecks.swift:42 | harness/index.html:374, control/docs/index.html:426, control/docs/index.html:464, control/docs/index.html:499 (+2 more) | copy-pass |
| SG-10u | `ProviderConnectModel.swift:992` | Jump to a session from the pet, meeting alerts, open at login. | keep | Clear | none | none | copy-pass |
| SG-10b | `ProviderConnectModel.swift:994` | Review | keep | Clear | Tests/WorkMeetingConnectionsChecks.swift:53, Tests/WorkWorkspaceProjectionChecks.swift:50, Tests/WorkCardFilesChecks.swift:1734, Tests/WorkCardFilesChecks.swift:1758 (+2 more) | docs/index.html:1746 | copy-pass |

## 3.2 AI and accounts

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Your AI apps

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ST-24 | `Views.swift:1673` | Agent CLIs | AI apps | Users know the apps, not CLIs | Tests/ProviderConnectChecks.swift:5, Tests/provider-connect-pins.py:94 | docs/index.html:1069, control/index.html:884 | hub-builder |
| ST-24d | `ProviderConnectViews.swift:689` | Unreported by this server: | keep | Clear | none | none | copy-pass |
| ST-25 | `Views.swift:1677` | Cursor CLI | Cursor Agent | The setup guide's name for it | Tests/KeyLanesSnapshotStatus.swift:39, Tests/ProviderStatusChecks.swift:45, Tests/ProviderStatusChecks.swift:53, Tests/provider-status-helper-checks.py:43 | llms.txt:42, CHANGELOG.md:167, wizard/index.html:610, docs/index.html:979 (+8 more) | hub-builder |
| UT-20 | `Views.swift:2826` | Open Cursor | keep | Clear | none | docs/index.html:1053, docs/index.html:1071, control/index.html:889 | hub-builder |
| UT-20d | `new (hub chrome)` | (none) | Opens Cursor on your work folder. | New description | none | none | hub-builder |
| SG-03a | `ProviderConnectViews.swift:155` | Install it in Terminal, no administrator password needed: | keep | Clear | none | none | copy-pass |
| SG-03b | `ProviderConnectViews.swift:159` | Codex comes with the ChatGPT app for Mac. Install or update the app, then come back. | keep | Clear | none | none | copy-pass |
| SG-03c | `ProviderConnectViews.swift:177` | Sign in so Sessions and Continue work. In Terminal, run: | keep | Clear | none | none | copy-pass |
| SG-03d | `ProviderConnectViews.swift:185` | Open Terminal again | keep | Clear | none | none | copy-pass |
| SG-03e | `ProviderConnectViews.swift:186` | Stop waiting | keep | Clear | Tests/ProviderConnectChecks.swift:394 | none | copy-pass |
| SG-03f | `ProviderConnectViews.swift:190` | Skip for now | keep | Clear | Tests/ProviderConnectChecks.swift:235, Tests/provider-connect-pins.py:74 | wizard/index.html:591, control/docs/index.html:494, control/docs/index.html:506 | copy-pass |
| SG-03g | `ProviderConnectViews.swift:210` | Opens a new \(app.appName) chat with COS's setup steps filled in. Nothing is sent until you press Send there. | keep | Says what is sent | none | none | copy-pass |

### Local model

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ST-26 | `Views.swift:1682` | Ollama | keep | Clear | Tests/ControlsContract.swift:40, Tests/run.sh:1075, Tests/WorkCardFilesChecks.swift:833, Tests/WorkProgressChecks.swift:820 (+1 more) | ai-adoption/index.html:984, wizard/index.html:528, docs/index.html:1859, docs/index.html:1862 (+3 more) | hub-builder |
| UT-08 | `Views.swift:2728` | Local model | keep | Clear | Tests/ProviderConnectChecks.swift:492, Tests/ProviderConnectChecks.swift:494, Tests/run.sh:3699 | index.html:812, docs/index.html:1858, docs/index.html:1868, skills/cos-glasses.md:66 (+2 more) | hub-builder |
| UT-08o | `Views.swift:2646` | Automatic (newest pull) | Newest pulled model | Plain words, 3 | Tests/run.sh:3722 | none | hub-builder |
| UT-08p | `Views.swift:2648` | not pulled | keep | Clear | Tests/ControlsContract.swift:203, Tests/run.sh:3721 | none | hub-builder |
| UT-08a | `Views.swift:2735` | Ollama is not running, so the list may be stale. A pin still applies once the daemon is back. | Ollama is not running, so this list is out of date. A chosen model applies when it starts. | No hedge, no "daemon" | none | none | hub-builder |
| UT-08b | `Views.swift:2736` | Automatic follows the newest pulled model, which silently changes when anything is pulled. Pin one to make it deterministic. Applying restarts the server. | Newest changes when you pull a model. Pick one to keep it. Applying restarts the server. | 90 chars; keeps the restart | none | none | hub-builder |

### Decision models

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| JV-01 | `Views.swift:1101` | Decision models | keep | Clear | Tests/mutate-live-cues.py:99, Tests/mutate-live-cues.py:101, Tests/LiveCuesRender.swift:14, Tests/LiveCuesRender.swift:157 (+9 more) | control/appcast.json:283, control/docs/index.html:993 | hub-builder |
| JV-01d | `Views.swift:1116` | Used for session suggestions, completion checks and Work search. Jev remains the default; errors never switch providers automatically. | Session suggestions, completion checks and Work search. Errors never switch the provider. | 90 chars | none | none | hub-builder |
| JV-02 | `Views.swift:1118` | Default | Default provider | Says what the default is for | none | docs/index.html:1918, control/docs/index.html:738, control/docs/index.html:740, control/docs/index.html:741 (+1 more) | hub-builder |
| JV-02o | `Views.swift:1164` | Server default | keep | Clear | none | none | hub-builder |
| JV-02p | `Views.swift:1164` | Use default | keep | Clear | none | none | hub-builder |
| JV-03 | `Views.swift:1121` | Session suggestions | keep | Clear | none | none | hub-builder |
| JV-04 | `Views.swift:1121` | Completion checks | keep | Clear | none | none | hub-builder |
| JV-05 | `Views.swift:1121` | Work search | keep | Clear | Tests/run-work-search.sh:2, Tests/run-work-search.sh:31, Tests/run-work-search.sh:34, Tests/ActivityHomeRender.swift:126 (+11 more) | docs/index.html:2192, control/appcast.json:544 | hub-builder |
| JV-03n | `Views.swift:1125` | needs a key. This workflow will be unavailable until configured. | needs a key. This stays off until you add one. | Shorter; no "configured" | none | none | hub-builder |
| JV-02u | `Views.swift:1131` | Choosing a decision provider needs a newer COS server. Existing Jev settings still work. | Picking a provider needs a newer COS server. Your Jev key still works. | Shorter | none | none | hub-builder |
| JV-02c | `Views.swift:1133` | Checking decision settings… | keep | Clear | none | none | hub-builder |
| JV-02x | `Views.swift:1133` | Decision settings unavailable. | keep | Clear | none | none | hub-builder |
| JV-06 | `Views.swift:1136` | Refresh decision settings | Refresh providers | 2 words | none | none | hub-builder |
| JV-07 | `Views.swift:1137` | SubQ is an optional public preview. Selected workflows send their context to SubQ. Provider retention applies; the default organization retention is indefinite. | SubQ is a public preview. Steps on SubQ send it their context, kept forever by default. | 90 chars; keeps the retention fact | none | none | hub-builder |
| JV-07l | `Views.swift:1139` | SubQ data retention | keep | Clear | none | none | hub-builder |
| JV-08 | `Views.swift:1140` | SubQ key | keep | Clear | Tests/LiveCuesRender.swift:10, Tests/LiveCuesRender.swift:14, Tests/LiveCuesRender.swift:179, Tests/LiveCuesRender.swift:180 (+9 more) | docs/index.html:2140, control/appcast.json:283, control/appcast.json:472, control/docs/index.html:1290 | hub-builder |
| JV-08s | `Views.swift:1141` | SubQ key status unavailable. | keep | Clear | none | none | hub-builder |
| JV-08p | `Views.swift:1144` | Replace SubQ key | keep | Placeholder | none | none | hub-builder |
| JV-08q | `Views.swift:1144` | SubQ API key | keep | Placeholder | Tests/live-cues-pins.py:98 | none | hub-builder |
| JV-08b | `Views.swift:1146` | Save key | keep | Clear | Tests/key-lanes-pins.py:113 | none | hub-builder |
| JV-08d | `Views.swift:1151` | Validated against SubQ’s model list, then saved privately on the server. Saving a key does not select SubQ. | COS checks the key with SubQ, then saves it on the server. Saving does not turn SubQ on. | Active voice | none | none | hub-builder |
| JV-09 | `Views.swift:1154` | Remove saved SubQ key | Remove SubQ key | 3 words | none | none | hub-builder |
| JV-10 | `Views.swift:1068` | Jev key | keep | Clear | Tests/WorkIntakeChecks.swift:91, Tests/WorkIntakeChecks.swift:137, Tests/WorkIntakeChecks.swift:205, Tests/LiveCuesRender.swift:14 (+5 more) | docs/index.html:2221, control/index.html:639, control/docs/index.html:993 | hub-builder |
| JV-10d | `Views.swift:1069` | Key status is separate from the provider choices above. | keep | Clear | none | none | hub-builder |
| JV-10s | `Views.swift:1071` | Status unavailable. | keep | Clear | none | none | hub-builder |
| JV-10p | `Views.swift:1078` | Paused after repeated errors until | keep | Clear | none | none | hub-builder |
| JV-11p | `Views.swift:1083` | Replace key | Replace Jev key | Matches the SubQ field | none | none | hub-builder |
| JV-11q | `Views.swift:1083` | TypeSafe API key | keep | Placeholder | Tests/live-cues-pins.py:98 | none | hub-builder |
| JV-11b | `Views.swift:1085` | Save | Save key | Matches the SubQ button | Tests/dictation-wispr-pins.py:258 | control/docs/index.html:919 | hub-builder |
| JV-11d | `Views.swift:1096` | TypeSafe keys come from typesafe.ai. Meeting intake still uses Jev; the provider choices above apply to session suggestions, completion checks and Work search. | Get a key at typesafe.ai. Meeting intake always uses Jev, whatever you pick above. | 90 chars; keeps the intake fact | none | none | hub-builder |
| JV-12 | `Views.swift:1091` | Remove saved key | Remove Jev key | Names which key | Tests/mutate-key-lanes.py:104, Tests/KeyLanesHelperChecks.swift:93, Tests/key-lanes-pins.py:117, Tests/key-lanes-pins.py:133 (+5 more) | docs/index.html:2133, control/docs/index.html:1119, control/docs/index.html:1285 | hub-builder |

### Your own key

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| KL-01 | `KeyLanes.swift:33` | Answer with your own key | Use your own key | 4 words | Tests/KeyLanesOneRowRender.swift:6 | docs/index.html:1833, docs/index.html:2133, docs/index.html:2134, control/index.html:854 (+5 more) | copy-pass |
| KL-01a | `KeyLanes.swift:34` | Off. Answers use the AI you connected and its plan. | keep | Clear | none | none | copy-pass |
| KL-01b | `KeyLanes.swift:35` | On. Answers you send to a key profile run on your key, under its daily cap. | keep | Clear | none | none | copy-pass |
| KL-02 | `KeyLanes.swift:58` | Remove your saved keys first. | keep | Matched against the helper refusal word for word (key-lanes-pins.py:142) | Tests/KeyLanesHelperChecks.swift:105, Tests/key-lanes-pins.py:142, Tests/KeyLanesChecks.swift:325, Tests/KeyLanesChecks.swift:332 | none | copy-pass |
| KL-02b | `KeyLanes.swift:59` | Remove saved keys and continue | Remove keys and continue | 4 words; it continues an install or a rollback | none | none | copy-pass |
| KL-02v | `KeyLanesViews.swift:49` | Text(KeyLanes.downgradeBlockedLine + | Text(KeyLanes.downgradeLine) (shows "Remove your keys first. Older COS cannot see them.") | The pair read "Remove your saved keys first. Remove your keys first. ..."; show the second only | none | none | copy-pass |
| KL-03 | `KeyLanes.swift:53` | Key lanes are off. Your saved keys are still on this Mac. | Your own key is off. Your saved keys are still on this Mac. | "Key lanes" is the internal name | none | none | copy-pass |
| KL-03o | `KeyLanes.swift:52` | Keys saved for COS 6.80 or later are still on this Mac. This COS cannot use them. | Keys saved for server 6.80 or later are still on this Mac. This server cannot use them. | Names the server | none | none | copy-pass |
| KL-03b | `KeyLanes.swift:51` | Remove saved keys | keep | Clear; also the confirm title | Tests/mutate-key-lanes.py:104, Tests/KeyLanesHelperChecks.swift:93, Tests/key-lanes-pins.py:117, Tests/key-lanes-pins.py:133 (+5 more) | docs/index.html:2133, control/docs/index.html:1119, control/docs/index.html:1285 | copy-pass |
| KL-03m | `KeyLanes.swift:54` | COS deletes the saved keys, key profiles and spend ledger from this Mac. Sessions that ran on a key stay refused for Continue and Fork. | Deletes the saved keys, key profiles and spend ledger from this Mac. Sessions that ran on a key still cannot be continued or forked. | Plain words; same facts | none | none | copy-pass |
| KL-03r | `KeyLanes.swift:55` | Saved keys removed from this Mac. | keep | Clear | none | none | copy-pass |
| KL-04 | `KeyLanes.swift:139` | key ending | keep | Clear | Tests/KeyLanesChecks.swift:118, Tests/KeyLanesChecks.swift:120 | none | copy-pass |
| KL-04c | `KeyLanes.swift:145` | Cap \(usd(key.capUsd)) a day. \(usd(key.spentTodayUsd)) spent today. | keep | Clear | Tests/KeyLanesChecks.swift:149 | none | copy-pass |
| KL-04p | `KeyLanes.swift:45` | Anthropic and OpenAI keys have no provider-side limit; the cap here is the only stop. | keep | The decision fact, 84 chars | none | none | copy-pass |
| KL-04l | `KeyLanes.swift:131` | You already have Claude. A key is optional. | keep | Clear | Tests/KeyLanesChecks.swift:139 | none | copy-pass |
| KL-04g | `KeyLanes.swift:47` | On the glasses: Model, then Key: \(label). | keep | Clear | Tests/KeyLanesChecks.swift:200 | none | copy-pass |
| KL-05 | `KeyLanes.swift:25` | Key paused 1 hour after 3 failures. | keep | Clear | Tests/key-lanes-pins.py:53 | none | copy-pass |
| KL-05b | `KeyLanes.swift:48` | Reset pause | keep | Shared, kept: also shown in the Welcome window key step (KeyLanesSetupPanel) | Tests/mutate-key-lanes.py:54, Tests/KeyLanesHelperChecks.swift:88, Tests/KeyLanesHelperChecks.swift:89, Tests/KeyLanesChecks.swift:207 (+3 more) | docs/index.html:2133, control/appcast.json:209, control/docs/index.html:1117, control/docs/index.html:1285 | copy-pass |
| KL-06 | `KeyLanes.swift:75` | Model | keep | Clear | Tests/live-transcript-pins.py:224 | wizard/index.html:474, wizard/index.html:623, docs/index.html:2170, harness/index.html:412 (+4 more) | copy-pass |
| KL-06p | `KeyLanesViews.swift:167` | Choose a model | keep | Clear | none | docs/index.html:962, harness/index.html:362 | copy-pass |
| KL-06n | `KeyLanes.swift:76` | Pick a model for this key in a later COS. The key is saved. | keep | Shared, kept: also shown in the Welcome window key step | none | none | copy-pass |
| KL-06e | `KeyLanes.swift:44` | Answering on your own key runs Claude Code on this Mac. Install it in Connect your AI first. | keep | Shared, kept: also shown in the Welcome window key step | none | none | copy-pass |
| KL-07 | `KeyLanes.swift:49` | Use for answers | keep | Clear | Tests/mutate-key-lanes.py:55, Tests/KeyLanesChecks.swift:212 | docs/index.html:2133, control/appcast.json:209, control/docs/index.html:1117, control/docs/index.html:1285 | copy-pass |
| KL-08 | `KeyLanes.swift:74` | Daily cap (USD) | keep | Clear | none | none | copy-pass |
| KL-08b | `KeyLanesViews.swift:182` | Set cap | keep | Clear | none | none | copy-pass |
| KL-08e | `KeyLanesViews.swift:183` | A daily cap is between $0.01 and $1000. | keep | Clear | none | none | copy-pass |
| KL-09 | `KeyLanes.swift:64` | Remove | keep | Clear in the key row | none | philosophy/cos-philosophy-diagram.html:3004, philosophy/cos-philosophy-diagram.html:3070, control/docs/index.html:845, control/docs/index.html:1117 | copy-pass |
| KL-09c | `KeyLanesViews.swift:191` | Remove this key? | keep | Clear | none | none | copy-pass |
| KL-09m | `KeyLanesViews.swift:192` | and its key profile are deleted from this Mac. | keep | Clear | none | none | copy-pass |
| KL-10 | `KeyLanesViews.swift:205` | Key from | keep | Shared, kept: also shown in the Welcome window key step | none | none | copy-pass |
| KL-11 | `KeyLanes.swift:62` | Paste key | keep | Clear | none | control/docs/index.html:1113 | copy-pass |
| KL-11h | `KeyLanes.swift:68` | Copy the key, then press Paste key. COS never shows it again. | keep | Clear | none | none | copy-pass |
| KL-11e | `KeyLanes.swift:69` | The clipboard has no text. Copy the key, then press Paste key. | keep | Clear | none | none | copy-pass |
| KL-11r | `KeyLanes.swift:141` | Ready to save: | keep | Clear | Tests/mutate-key-lanes.py:35, Tests/KeyLanesChecks.swift:118 | none | copy-pass |
| KL-12 | `KeyLanesViews.swift:217` | Cap $ | keep | Clear | Tests/KeyLanesChecks.swift:149 | none | copy-pass |
| KL-13 | `KeyLanes.swift:63` | Save key | keep | Clear | Tests/key-lanes-pins.py:113 | none | copy-pass |
| KL-13d | `KeyLanes.swift:23` | Your key is saved on this Mac. Apps and agents that run on this Mac as you can read it. Your provider's spending limit is the real stop. | keep | Server parity: must equal KEY_LANE_SAME_MAC_COPY (key-lanes-pins.py) | none | none | copy-pass |
| KL-14 | `KeyLanes.swift:65` | Remove all keys | keep | Clear | Tests/mutate-key-lanes.py:78, Tests/key-lanes-pins.py:117, Tests/KeyLanesChecks.swift:240, Tests/KeyLanesChecks.swift:241 (+2 more) | docs/index.html:2133, control/index.html:854, control/appcast.json:209, control/docs/index.html:1117 (+1 more) | copy-pass |
| KL-14m | `KeyLanes.swift:66` | Every key, key profile and the spend ledger are deleted from this Mac, and key lanes turn off. Sessions that ran on a key stay refused for Continue and Fork. | keep | Shared, kept: also shown in the Welcome window key step | none | none | copy-pass |
| KL-14a | `KeyLanes.swift:72` | Going back to a COS older than 6.80.0? | keep | Sits over KL-14b, which must say "Older COS" | none | none | copy-pass |
| KL-14b | `KeyLanes.swift:20` | Remove your keys first. Older COS cannot see them. | keep | Server parity: must equal the server catalog (key-lanes-pins.py:47) | Tests/key-lanes-pins.py:47 | none | copy-pass |
| KL-15 | `KeyLanes.swift:67` | Save the spend ledger to Downloads first | keep | Shared, kept: also shown in the Welcome window key step | none | none | copy-pass |

### Search

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OUT-07 | `new (hub chrome)` | (none) | Search by meaning | New Settings row; keep the in-place Meaning checkbox | none | none | hub-builder |
| OUT-07d | `new (hub chrome)` | (none) | Find messages by meaning. Each search uses model tokens. | New description | none | none | hub-builder |

## 3.3 Glasses and iPhone

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Devices

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SG-02 | `ProviderConnectViews.swift:992` | Your devices | keep | Clear | none | control/docs/index.html:508 | copy-pass |
| SG-11a | `ProviderConnectViews.swift:445` | Get Tailscale | keep | Clear | Tests/ProviderConnectChecks.swift:806 | none | copy-pass |
| SG-11b | `ProviderConnectViews.swift:447` | Open Tailscale | keep | Clear | Tests/ProviderConnectChecks.swift:809 | wizard/index.html:701, docs/index.html:2162 | copy-pass |
| SG-11c | `ProviderConnectViews.swift:455` | Point your iPhone Camera here to open Tailscale in the App Store. | keep | Clear | none | none | copy-pass |
| SG-11d | `ProviderConnectViews.swift:484` | Update Server | keep | Kept for test churn: 25 test locations; not misleading | Tests/WorkIntakeChecks.swift:412, Tests/WorkIntakeChecks.swift:430, Tests/WorkIntakeChecks.swift:432, Tests/SetupAssistantChecks.swift:169 (+21 more) | docs/index.html:1037, docs/index.html:1674, docs/index.html:1863, docs/index.html:2235 (+9 more) | copy-pass |
| SG-11e | `ProviderConnectViews.swift:489` | Show a new code | keep | Clear | Tests/ProviderConnectChecks.swift:1090, Tests/ProviderConnectChecks.swift:1108 | none | copy-pass |
| SG-11f | `ProviderConnectViews.swift:502` | Pair another phone | keep | Clear | none | none | copy-pass |
| SG-11g | `ProviderConnectViews.swift:511` | Hold your phone so the code fills the screen | keep | Clear | Tests/provider-connect-pins.py:124 | none | copy-pass |
| SG-11h | `ProviderConnectViews.swift:520` | Works once, until | keep | Clear | none | none | copy-pass |
| SG-11i | `ProviderConnectViews.swift:548` | Allow only if this is your phone. It gets full access to COS on this Mac. | keep | The security fact, plainly | none | none | copy-pass |
| SG-12 | `ProviderConnectViews.swift:530` | Allow pairing on this Wi-Fi (home only) | keep | Shared, kept: also shown in glasses pairing in the Welcome window | Tests/provider-connect-pins.py:124 | control/docs/index.html:500 | copy-pass |
| SG-12d | `ProviderConnectViews.swift:534` | Lets a phone on this Wi-Fi pair without Tailscale for the next 10 minutes. Use it only at home. | keep | Shared, kept: also shown in glasses pairing in the Welcome window | none | none | copy-pass |
| SG-13 | `ProviderConnectViews.swift:1027` | The COS app for your glasses | keep | Shared, kept: also shown in the setup guide (Welcome window) | none | none | copy-pass |
| SG-13h | `ProviderConnectViews.swift:1029` | Install COS on your phone from the Even app, then scan the code above | keep | Clear | none | none | copy-pass |
| UT-21 | `Views.swift:2827` | Copy Pairing Token | Copy pairing token | Sentence case | none | wizard/index.html:465, wizard/index.html:468, wizard/index.html:691, wizard/index.html:715 (+4 more) | hub-builder |
| UT-21d | `new (hub chrome)` | (none) | Copies the pairing token. Anyone with it can reach COS on this Mac. | New description; keeps the security fact | none | none | hub-builder |
| H-04 | `Views.swift:1302` | Archive live messages and start numbering at #1 | Reset message count | Names the action; now a row, not an icon | Tests/run.sh:548 | none | hub-builder |
| H-04d | `new (hub chrome)` | (none) | Live messages start again at #1. History stays in Archive. | New description | none | none | hub-builder |
| H-04c | `Views.swift:781` | Reset live message count? | keep | Clear | none | none | hub-builder |
| H-04m | `Views.swift:783` | The next message is #1. Older cards keep their own numbers, and history stays in ARCHIVE and Message History. Needs COS Glasses 6.8.423 or newer on the phone — on an older build this clears the phone's chat list. | The next message is #1. Older cards keep their numbers and history stays in Archive. On a glasses app older than 6.8.423, this clears the phone's chat list. | No em dash; keeps the old-build warning | none | none | hub-builder |
| H-04a | `Views.swift:785` | Reset count | keep | Clear | none | none | hub-builder |

### Video uploads

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| UT-09 | `Views.swift:2742` | Reliable video uploads (beta) | Reliable video uploads | "Beta" moves to the description | none | none | hub-builder |
| UT-09h | `Views.swift:2753` | Private canary. Sends every MP4/MOV in restart-safe chunks and resumes from server-confirmed bytes. Phone frame extraction remains off until device benchmarks prove it is faster. Disable for immediate transport rollback. | Beta. Sends videos in chunks that resume after a restart. Applying restarts the server. | 90 chars; drops build notes | none | none | hub-builder |
| ST-10 | `Views.swift:1391` | Video uploads | keep | Clear | none | CHANGELOG.md:122 | hub-builder |
| ST-10a | `Views.swift:1394` | Sideload or a killed upload can sit here for 4 hours and block Repair. | A stopped upload can wait here for 4 hours and block Repair. | Plain words; same facts | none | none | hub-builder |
| ST-10b | `Views.swift:1402` | completed video receipt(s) await companion acknowledgment. | finished upload(s) waiting for the phone to confirm. | Plain words | none | none | hub-builder |
| UT-10 | `Views.swift:2749` | Clear stranded | Clear stuck uploads | Users know "stuck" | Tests/run.sh:384, Tests/run.sh:545 | docs/index.html:1411 | hub-builder |
| UT-10s | `Views.swift:1397` | Clear stranded | Clear stuck uploads | Same button in the status card | Tests/run.sh:384, Tests/run.sh:545 | docs/index.html:1411 | hub-builder |
| UT-10c | `Views.swift:772` | Clear stranded video uploads? | Clear stuck video uploads? | Same term | none | none | hub-builder |
| UT-10m | `Views.swift:774` | Cancels drafts that have not received bytes for 60 seconds. Uploads still in progress and videos being compressed are left alone. Repair does not do this — stranded drafts block Repair. | Cancels uploads that received nothing for 60 seconds. Uploads still sending or compressing stay. Stuck uploads block Repair. | No em dash; same three facts | none | none | hub-builder |
| UT-10a | `Views.swift:772` | Clear stranded | Clear stuck uploads | Confirm action, same term | Tests/run.sh:384, Tests/run.sh:545 | docs/index.html:1411 | hub-builder |

## 3.4 Meetings

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Recording

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MT-01 | `Views.swift:2868` | Show live meeting transcript | Live transcript | 2 words, as on the board | Tests/mutate-live-transcript.py:126, Tests/live-transcript-pins.py:191 | docs/index.html:2152, control/index.html:598, control/docs/index.html:907, control/docs/index.html:1300 | hub-builder |
| MT-01h | `Views.swift:2870` | While a glasses meeting records, show it at the top of Meetings with the text so far. The transcript opens only when you click it. Off: no live row, no live dots, and nothing is read | Shows a glasses meeting at the top of Meetings while it records. Off reads nothing. | 90 chars; keeps the privacy fact | none | none | hub-builder |
| H-10 | `Views.swift:1921` | Enable live transcripts in Settings to view the recording. | Turn on Live transcript in Settings to view this recording. | Names the renamed setting | none | none | hub-builder |
| MT-03 | `MacRecording.swift:1602` | Suggest recording when a meeting starts | Suggest recording | 2 words, as on the board | Tests/meeting-detect-pins.py:202 | control/appcast.json:392, control/docs/index.html:897 | copy-pass |
| MT-03h | `MacRecording.swift:1604` | When Zoom, Microsoft Teams or Google Meet has used the microphone for 10 seconds, the pet offers Record on Mac with live transcript. COS never starts or stops a recording on its own | The pet offers to record when Zoom, Teams or Meet uses the mic. COS never starts it. | 90 chars; keeps "never starts on its own" | none | none | copy-pass |
| MT-04 | `new (hub chrome)` | (none) | Apps to watch | New label over the three app switches | none | none | hub-builder |
| MT-05 | `MacRecording.swift:1611` | Google Meet in a browser needs Accessibility (the same permission dictation uses) to see the Meet tab's title. Until then COS watches Zoom and Teams only. | Google Meet in a browser needs Accessibility. Until then COS watches Zoom and Teams only. | 90 chars | none | none | copy-pass |
| MT-06 | `MacRecording.swift:1616` | Never for \(store.never[owner] ?? owner) | keep | Clear | Tests/MacRecordingChecks.swift:346 | control/docs/index.html:896 | copy-pass |
| MT-06b | `MacRecording.swift:1617` | Remove | keep | Clear | none | philosophy/cos-philosophy-diagram.html:3004, philosophy/cos-philosophy-diagram.html:3070, control/docs/index.html:845, control/docs/index.html:1117 | copy-pass |
| MT-02 | `MacRecording.swift:1596` | Show the recording notice again | Show notice again | 3 words | Tests/meeting-detect-pins.py:128 | control/appcast.json:392, control/docs/index.html:897 | copy-pass |
| MT-02h | `MacRecording.swift:1601` | The next Mac recording shows what COS records and asks once more before it starts | The next Mac recording shows what COS records and asks once more. | Shorter | none | none | copy-pass |
| ST-15 | `Views.swift:1479` | Meeting alerts | keep | Clear | Tests/PermissionGuideChecks.swift:351, Tests/mutate-permission-guide.py:54, Tests/permission-guide-pins.py:48, Tests/permission-guide-pins.py:49 | none | hub-builder |
| ST-15a | `Views.swift:1479` | Off for COS Control | keep | Clear | none | none | hub-builder |
| ST-15b | `Views.swift:1482` | Notification settings | keep | Clear | none | none | hub-builder |

### Meeting assistant

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MA-00 | `MeetingAsk.swift:522` | Meeting assistant | keep | Clear | Tests/mutate-live-cues.py:108, Tests/LiveCuesRender.swift:9, Tests/LiveCuesRender.swift:133, Tests/run-live-cues.sh:8 (+7 more) | llms.txt:32, RELEASE_637_67113_288.md:3, docs/index.html:1146, docs/index.html:2132 (+13 more) | copy-pass |
| MA-00d | `MeetingAsk.swift:523` | Used only when you ask during a meeting. Defaults to Sonnet; other chats keep their own models. | Answers when you ask during a meeting. Sonnet by default; other chats keep their models. | 90 chars | none | none | copy-pass |
| MA-01 | `MeetingAsk.swift:998` | Model | keep | Card title gives the context | Tests/live-transcript-pins.py:224 | wizard/index.html:474, wizard/index.html:623, docs/index.html:2170, harness/index.html:412 (+4 more) | copy-pass |
| MA-02 | `MeetingAsk.swift:528` | Public web lookup uses | keep | Clear | none | none | copy-pass |
| MA-02b | `MeetingAsk.swift:528` | Public web lookup unavailable: | keep | Clear | none | none | copy-pass |
| MA-03 | `MeetingAsk.swift:953` | Unavailable models (\(options.count)) | keep | Clear | none | none | copy-pass |
| MA-04 | `MeetingAsk.swift:534` | Refresh connected models | Refresh models | 2 words | none | control/docs/index.html:1065 | copy-pass |
| MA-05 | `MeetingAsk.swift:556` | Home city | keep | Clear | Tests/run-home-area.sh:2, Tests/run.sh:142, Tests/run.sh:229, Tests/HomeAreaChecks.swift:3 (+7 more) | RELEASE_639_6720_289.md:7, RELEASE_637_67113_288.md:3, RELEASE_637_67113_288.md:7, docs/index.html:2167 (+4 more) | copy-pass |
| MA-05d | `MeetingAskCore.swift:646` | Used only when a fact check needs a starting point. City and state, no street address. Leave blank to use your phone's area. | Where fact checks start. City and state, no street. Blank uses your phone's area. | 90 chars; same facts | none | none | copy-pass |
| MA-05e | `MeetingAskCore.swift:656` | No starting point is set yet. | keep | Clear | Tests/HomeAreaChecks.swift:66 | none | copy-pass |
| MA-05f | `MeetingAskCore.swift:658` | Fact checks start from \(effective.text) | keep | Clear | Tests/HomeAreaChecks.swift:48 | none | copy-pass |
| MA-05g | `MeetingAskCore.swift:659` | Fact checks use your phone's area: \(effective.text) | keep | Clear | Tests/HomeAreaChecks.swift:38 | none | copy-pass |
| MA-05b | `MeetingAsk.swift:563` | Save | keep | Clear | Tests/dictation-wispr-pins.py:258 | control/docs/index.html:919 | copy-pass |

### Live cues

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MA-06 | `MeetingAskCore.swift:808` | Live cues | keep | Clear | Tests/mutate-live-cues.py:2, Tests/mutate-live-cues.py:43, Tests/mutate-hardening-337.py:55, Tests/LiveCuesRender.swift:5 (+20 more) | docs/index.html:2135, docs/index.html:2140, control/appcast.json:120, control/appcast.json:137 (+2 more) | copy-pass |
| MA-06a | `MeetingAskCore.swift:817` | Off. Turn it on to see cues on the glasses during a meeting. | keep | Clear | Tests/LiveCuesChecks.swift:79 | none | copy-pass |
| MA-06b | `MeetingAskCore.swift:816` | Turned on in the server's environment, so it cannot be turned off here. | Turned on on the server, so it cannot be turned off here. | Same term as HUB-09 | none | none | copy-pass |
| MA-07 | `MeetingAskCore.swift:812` | Add a Jev or SubQ key | keep | Clear | Tests/LiveCuesRender.swift:10, Tests/LiveCuesChecks.swift:158, Tests/live-cues-pins.py:66 | control/appcast.json:283 | copy-pass |
| MA-13 | `MeetingAskCore.swift:814` | Cues also need Live Cues on in the glasses app. | keep | Clear | Tests/LiveCuesChecks.swift:127 | control/appcast.json:285 | copy-pass |
| MA-08 | `MeetingAskCore.swift:869` | Bar | Cue bar | Says what bar | none | none | copy-pass |
| MA-08a | `MeetingAskCore.swift:870` | More cues | keep | Clear | none | none | copy-pass |
| MA-08b | `MeetingAskCore.swift:871` | Fewer cues | keep | Clear | none | none | copy-pass |
| MA-09 | `MeetingAskCore.swift:872` | Max cues per meeting | Cues per meeting | 3 words | none | none | copy-pass |
| MA-10 | `MeetingAskCore.swift:873` | Minimum gap between cues | Gap between cues | 3 words | none | none | copy-pass |
| MA-11 | `MeetingAskCore.swift:874` | Daily writer limit | Daily writer calls | Matches the usage line | none | none | copy-pass |
| MA-12 | `MeetingAskCore.swift:875` | Set in .env | Set on the server | One phrase for every server lock | Tests/live-cues-pins.py:78 | docs/index.html:2132, control/docs/index.html:1284 | copy-pass |
| MA-12a | `MeetingAskCore.swift:876` | Saving… | keep | Clear | Tests/MacRecordingChecks.swift:103, Tests/MacRecordingChecks.swift:104, Tests/MacRecordingChecks.swift:886, Tests/MacRecordingChecks.swift:888 (+4 more) | none | copy-pass |
| MA-12b | `MeetingAskCore.swift:977` | Limits need server 6.79.2. Update the server in Settings. | keep | Clear | Tests/LiveCuesChecks.swift:293, Tests/LiveCuesChecks.swift:298 | none | copy-pass |

### Library and sync

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| UT-16 | `Views.swift:2797` | Meetings Library | Meetings folder | Plain name, sentence case | Tests/run.sh:480 | wizard/index.html:460, wizard/index.html:483, docs/index.html:1143, docs/index.html:1190 (+3 more) | hub-builder |
| UT-16h | `Views.swift:2799` | Choose your existing meetings folder. COS also recognizes a parent containing several custom-named meeting folders. | Choose your meetings folder, or one that holds several. Changing it restarts the server. | 90 chars; adds the restart fact | none | none | hub-builder |
| UT-16c | `Views.swift:704` | Meetings Library | Meetings folder | Same name | Tests/run.sh:480 | wizard/index.html:460, wizard/index.html:483, docs/index.html:1143, docs/index.html:1190 (+3 more) | hub-builder |
| UT-16a | `Views.swift:711` | Choose Again | Choose again | Sentence case | none | docs/index.html:1638 | hub-builder |
| UT-16b | `Views.swift:715` | View Examples | View examples | Sentence case | none | none | hub-builder |
| UT-16x | `Views.swift:719` | Skip for Now | Skip for now | Sentence case | none | docs/index.html:1638 | hub-builder |
| ST-29 | `Views.swift:1697` | Meetings library | Meetings folder | Same name as UT-16 | none | docs/index.html:2264, control/docs/index.html:1088 | hub-builder |
| ST-29a | `Views.swift:1700` | Not set (standalone recordings) | keep | Clear | none | none | hub-builder |
| ST-16 | `Views.swift:1486` | Meeting sync | keep | Clear | Tests/run.sh:748, Tests/run.sh:7198 | docs/index.html:1068, docs/index.html:2237, docs/index.html:2271, docs/index.html:2355 (+3 more) | hub-builder |
| ST-17 | `Views.swift:1508` | Run sync now | Sync now | 2 words | Tests/run.sh:527 | none | hub-builder |
| ST-20 | `Views.swift:1577` | Finalization recovery | Save retries | Plain words | none | none | hub-builder |
| ST-20b | `Views.swift:1577` | Library save | Saving meetings | Plain words | none | none | hub-builder |
| ST-20c | `Views.swift:1579` | Repair required | keep | Clear | Tests/SetupAssistantChecks.swift:175 | none | hub-builder |
| ST-21 | `Views.swift:1598` | Retained captures | Unsaved recordings | Users know recordings, not captures | none | none | hub-builder |
| ST-21d | `Views.swift:1602` | Retained captures on this Mac. Save available transcripts or recover quarantined audio before retention expires. | Recordings that never became meetings. Save or recover them before they expire. | 90 chars; keeps the expiry | none | none | hub-builder |
| ST-21e | `Views.swift:1642` | A retained server session does not mean the phone has a pending meeting. Save is available only when a transcript exists. | These do not mean the phone has a meeting waiting. Save needs a transcript. | 90 chars | none | none | hub-builder |
| ST-22 | `Views.swift:1622` | Recover all | keep | Clear | Tests/run.sh:532, Tests/run.sh:533, Tests/run.sh:1115 | control/docs/index.html:919 | hub-builder |
| ST-22c | `Views.swift:790` | Recover all unsaved captures? | Recover all unsaved recordings? | Same term | none | none | hub-builder |
| ST-22m | `Views.swift:792` | Turns each unsaved capture into a meeting, one at a time. Already-recovering captures wait their turn. Session files are not deleted. | Turns each unsaved recording into a meeting, one at a time. The files are kept. | Shorter; keeps "files are kept" | none | none | hub-builder |
| ST-23 | `Views.swift:1648` | Save all | keep | Clear | none | none | hub-builder |
| ST-23c | `Views.swift:799` | Save still-live captures as meetings? | Save live recordings as meetings? | Same term | none | none | hub-builder |
| ST-23m | `Views.swift:801` | Finalizes each still-live G2 capture through the same save path as Stop on the phone. Session files become meetings; they are not deleted. | Ends each live glasses recording and saves it, like Stop on the phone. The files are kept. | Says it ends the recording | none | none | hub-builder |
| ST-18 | `Views.swift:1538` | Early meeting sync | Early sync | 2 words | Tests/run.sh:753 | control/index.html:882 | hub-builder |
| ST-18d | `new (hub chrome)` | (none) | Set on the server. | O-07; status only | none | none | hub-builder |
| UT-05 | `Views.swift:2692` | Meeting Turbo preview | Fast preview | Plain name | Tests/run.sh:494 | docs/index.html:1053, control/index.html:839, control/docs/index.html:1056 | hub-builder |
| UT-05h | `Views.swift:2699` | Shows fast provisional meeting text, then replaces it with the canonical speaker-attributed transcript. Disable for immediate rollback. | Quick meeting text first, then the final transcript. Applying restarts the server. | Board text; keeps the restart | none | none | hub-builder |
| ST-08 | `Views.swift:1377` | Meeting preview | Fast preview | Same name as UT-05 | none | wizard/index.html:694, docs/index.html:1062, docs/index.html:1738, docs/index.html:1779 (+1 more) | hub-builder |

### Fireflies import

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OUT-01 | `new (hub chrome)` | (none) | Fireflies key | New Settings row | none | none | hub-builder |
| OUT-01d | `new (hub chrome)` | (none) | Save, check or remove your Fireflies API key. | New description | none | none | hub-builder |
| OUT-02 | `new (hub chrome)` | (none) | Import past meetings | New Settings row, as on the board | none | none | hub-builder |
| OUT-02d | `new (hub chrome)` | (none) | Bring in past Fireflies meetings by date range. | New description | none | none | hub-builder |
| OUT-03 | `new (hub chrome)` | (none) | Keep importing | New Settings row | none | none | hub-builder |
| OUT-03d | `new (hub chrome)` | (none) | Bring in new Fireflies meetings as they arrive. | New description | none | none | hub-builder |

## 3.5 Dictation

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Dictation

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DI-01 | `MacDictation.swift:4113` | Dictate into Mac apps | keep | Clear, 4 words | none | control/appcast.json:443, control/docs/index.html:735, control/docs/index.html:1186 | copy-pass |
| DI-01d | `MacDictation.swift:4114` | Transcribed on this Mac with your COS dictionary, by Parakeet Ultra or Whisper (Settings, Transcription). Glasses are optional. Dictation uses your microphone; Record on Mac captures meeting playback. | Type by voice into any Mac app. Transcribed on this Mac with your dictionary. | 90 chars; the engine now sits beside it | none | none | copy-pass |
| TR-01 | `MeetingAsk.swift:824` | Dictation engine | keep | Clear | Tests/TranscriptionSettingsChecks.swift:207, Tests/ProviderConnectChecks.swift:466, Tests/transcription-settings-helper-checks.py:104, Tests/TranscriptionSettingsRender.swift:120 (+1 more) | docs/index.html:2146, control/appcast.json:329, control/appcast.json:332, control/docs/index.html:509 (+4 more) | copy-pass |
| TR-01d | `MeetingAskCore.swift:2003` | Automatic uses Parakeet Ultra when it is installed and ready, and Whisper on this Mac otherwise. Dictation never uses the cloud. | Automatic uses Parakeet Ultra when it is ready, and Whisper otherwise. Never the cloud. | 90 chars; keeps "never the cloud" | none | control/appcast.json:329 | copy-pass |
| TR-01o | `MeetingAskCore.swift:2004` | This COS server dictates with Parakeet Ultra only. Update the server to dictate with Whisper. | keep | Clear | Tests/ProviderConnectChecks.swift:1240 | none | copy-pass |
| SG-06 | `ProviderConnectViews.swift:903` | Dictation engine | keep | Clear | Tests/TranscriptionSettingsChecks.swift:207, Tests/ProviderConnectChecks.swift:466, Tests/transcription-settings-helper-checks.py:104, Tests/TranscriptionSettingsRender.swift:120 (+1 more) | docs/index.html:2146, control/appcast.json:329, control/appcast.json:332, control/docs/index.html:509 (+4 more) | copy-pass |
| SG-06a | `ProviderConnectViews.swift:908` | Install first | keep | Clear | none | none | copy-pass |
| SG-06b | `ProviderConnectViews.swift:939` | Test on this Mac | keep | Clear | none | control/appcast.json:332, control/docs/index.html:516 | copy-pass |
| SG-06c | `ProviderConnectViews.swift:942` | Dictates COS's 30-second sample with each installed engine. A quick check, not a full accuracy test. | keep | Shared, kept: also shown in the setup guide engine step | none | none | copy-pass |
| DI-35 | `MacDictation.swift:5329` | Dictation settings | keep | Clear | none | docs/index.html:2133, control/appcast.json:212, control/docs/index.html:1285 | copy-pass |
| DI-35a | `MacDictation.swift:5366` | Turn it on in Dictation settings | keep | Clear | none | none | copy-pass |

### Microphone

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DI-02 | `MacDictation.swift:4117` | Microphone | keep | Clear | none | control/docs/index.html:547, control/docs/index.html:735 | copy-pass |
| DI-02a | `MacDictation.swift:1947` | System default | keep | Clear | Tests/dictation-start-pins.py:125, Tests/dictation-start-pins.py:130 | docs/index.html:2120, control/appcast.json:24, control/docs/index.html:735, control/docs/index.html:800 (+1 more) | copy-pass |
| DI-02b | `MacDictation.swift:4107` | Selected microphone disconnected | keep | Clear | none | none | copy-pass |
| DI-03 | `MacDictation.swift:132` | Refresh microphones | keep | Clear | none | control/docs/index.html:735 | copy-pass |
| DI-04 | `MacDictationCore.swift:6102` | If the microphone fails, try another one | Microphone fallback | 2 words | none | control/docs/index.html:800 | copy-pass |
| DI-04d | `MacDictationCore.swift:6103` | With System default, COS tries a microphone that worked before (never Bluetooth or an iPhone) and says which it used. | With System default, COS tries a microphone that worked before, never Bluetooth or iPhone. | 90 chars | none | none | copy-pass |
| DI-04n | `MacDictation.swift:4123` | Last time  | keep | Clear | none | control/docs/index.html:800 | copy-pass |

### Shortcuts

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DI-05 | `MacDictationCore.swift:1813` | Push to talk | keep | Clear | none | control/appcast.json:443, control/docs/index.html:740, control/docs/index.html:749, control/docs/index.html:1186 | copy-pass |
| DI-06 | `MacDictationCore.swift:1814` | Start / stop | Start and stop | No slash | none | control/appcast.json:238, control/appcast.json:443, control/docs/index.html:741, control/docs/index.html:1186 | copy-pass |
| DI-07 | `MacDictationCore.swift:1815` | Fix last dictation | keep | Clear | Tests/MacDictationChecks.swift:509, Tests/dictation-wispr-pins.py:548, Tests/dictation-wispr-pins.py:551 | control/docs/index.html:742 | copy-pass |
| DI-05a | `MacDictation.swift:4262` | Press shortcut… | keep | Clear | none | none | copy-pass |
| DI-05b | `MacDictation.swift:4263` | Change | keep | Clear | Tests/CueVerdictsRender.swift:85 | control/docs/index.html:747 | copy-pass |
| DI-05c | `MacDictation.swift:4284` | Add Command, Control or Option, use a function key, or press one modifier key such as Fn by itself. | keep | Says every way out | none | none | copy-pass |
| DI-08 | `MacDictation.swift:4127` | Allow insertion into other apps… | Allow typing in apps… | Users know "typing" | none | control/docs/index.html:546, control/docs/index.html:735 | copy-pass |
| DI-34 | `MacDictation.swift:4181` | Any shortcut: a modifier plus a key, a function key, or one modifier key by itself such as Fn 🌐 or Right ⌘. Fn and single-key shortcuts use Accessibility. Finished text drops into the text box that has the cursor; with no text box it is copied, and the pet shows it with a Copy button. Some apps, such as terminals and Electron editors, get ⌘V; COS shows Pasted when it can't confirm, then puts your clipboard back. COS never presses Send or Return. | Use a combo, a function key or Fn alone (needs Accessibility). COS never presses Return. | 90 chars; keeps the permission and "never Return" | none | none | copy-pass |

### Sounds and audio

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DI-09 | `MacDictation.swift:6325` | Sound | keep | Clear | none | control/docs/index.html:862 | copy-pass |
| DI-09a | `MacDictation.swift:6287` | Pet's sound (\(store.petSoundName)) | keep | Clear | none | none | copy-pass |
| DI-09b | `MacDictation.swift:3548` | Your own file… | keep | Clear | Tests/dictation-wispr-pins.py:249 | control/docs/index.html:866 | copy-pass |
| DI-11 | `MacDictation.swift:6301` | Use the end of this file | keep | Clear | Tests/dictation-wispr-pins.py:258 | none | copy-pass |
| DI-12 | `MacDictation.swift:6334` | Volume | keep | Clear | none | control/docs/index.html:867 | copy-pass |
| DI-13 | `MacDictation.swift:6339` | Pitch | keep | Clear | none | control/docs/index.html:867 | copy-pass |
| DI-13n | `MacDictation.swift:6344` | Unstable saber is mostly bass: use headphones or real speakers, laptop speakers reproduce little of it. Sounds never play while a COS recording is capturing. | Unstable saber is mostly bass, so laptop speakers barely play it. Silent while recording. | 90 chars | none | none | copy-pass |
| DI-14 | `MacDictationCore.swift:6064` | Sounds paused after an audio error. | keep | Clear | none | none | copy-pass |
| DI-14b | `MacDictationCore.swift:6050` | Play sounds again | keep | Clear | Tests/dictation-parity-pins.py:83 | llms.txt:32, docs/index.html:2120, control/appcast.json:24, control/docs/index.html:869 (+1 more) | copy-pass |
| DI-15 | `MacDictation.swift:4221` | While dictating | keep | Clear with its options | Tests/dictation-wispr-pins.py:493, Tests/dictation-wispr-pins.py:498 | control/appcast.json:362, control/appcast.json:363, control/appcast.json:382, control/docs/index.html:855 (+1 more) | copy-pass |
| DI-15o | `MacDictationCore.swift:5325` | Mute other apps | keep | Clear | Tests/MacDictationChecks.swift:807, Tests/PermissionGuideChecks.swift:305, Tests/PermissionGuideChecks.swift:306, Tests/PermissionGuideChecks.swift:308 (+5 more) | docs/index.html:1969, docs/index.html:2144, docs/index.html:2147, control/appcast.json:219 (+7 more) | copy-pass |
| DI-16 | `MacDictation.swift:4225` | Muting other apps needs System Audio Recording for COS Control. Until it's allowed, COS lowers your Mac's volume while you dictate and puts it back after. | Muting needs System Audio Recording. Until you allow it, COS lowers the volume instead. | 90 chars | none | none | copy-pass |
| DI-16a | `MacDictation.swift:4228` | Allow System Audio Recording… | keep | Names the macOS setting | none | control/docs/index.html:856 | copy-pass |
| DI-16b | `MacDictation.swift:4239` | Check System Audio Recording… | keep | Clear | none | none | copy-pass |
| DI-16c | `MacDictationCore.swift:6066` | Muting paused after an audio error. COS lowers the volume instead for now. | keep | Clear | none | none | copy-pass |
| DI-16d | `MacDictationCore.swift:6067` | Mute again | keep | Clear | Tests/dictation-parity-pins.py:83, Tests/dictation-parity-pins.py:193 | llms.txt:32, docs/index.html:2120, control/appcast.json:24, control/docs/index.html:857 (+1 more) | copy-pass |
| DI-16e | `MacDictation.swift:4244` | Never during a Mac recording. Music and video stay muted, not paused: COS can't tell what's playing, so it never presses Play/Pause. | Never during a Mac recording. Music and video are muted, never paused. | Shorter; same behavior | none | none | copy-pass |

### Text

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DI-17 | `MacDictation.swift:4135` | Restore my clipboard after pasting | Restore clipboard | 2 words | Tests/dictation-wispr-pins.py:98 | control/docs/index.html:771 | copy-pass |
| DI-17h | `MacDictation.swift:4136` | When COS pastes with ⌘V, it puts back whatever you had copied once the app has the text. | keep | 88 chars, clear | none | none | copy-pass |
| DI-18 | `MacDictation.swift:4137` | Learn from my edits | keep | 4 words; other lines name it | Tests/mutate-mac-dictation-core.py:179, Tests/mutate-mac-dictation-core.py:287, Tests/mutate-mac-dictation-core.py:606, Tests/mutate-mac-dictation-core.py:657 (+16 more) | llms.txt:32, docs/index.html:2121, docs/index.html:2123, docs/index.html:2124 (+24 more) | copy-pass |
| DI-18o | `MacDictationCore.swift:2252` | Save automatically | keep | Clear | Tests/MacDictationChecks.swift:658, Tests/MacDictationChecks.swift:659, Tests/MacDictationChecks.swift:660, Tests/MacDictationChecks.swift:748 (+3 more) | control/appcast.json:349, control/docs/index.html:828, control/docs/index.html:850 | copy-pass |
| DI-18d | `MacDictationCore.swift:3118` | When you fix a word COS just typed, in that same field, COS can learn it: | When you fix a word COS just typed, COS learns it, reading that field for up to three minutes. It learns names and terms, never plain English words, and with AI polish on, a few style habits (Your style). Works in native apps, {proven}. Not available yet in {notYet}, or text boxes in Chrome and Comet. Suggest only keeps them a week in Activity, Dictation. Never in terminals or password fields. | No hedge; keeps the pinned phrases (MacDictationChecks.swift:1833); over 90, see the end | none | none | copy-pass |
| DI-19 | `MacDictation.swift:4141` | Spell words the way the text box has them | Match nearby spelling | 3 words | Tests/dictation-wispr-pins.py:713 | docs/index.html:2139, control/appcast.json:271, control/docs/index.html:1289 | copy-pass |
| DI-19h | `MacDictation.swift:4142` | Before COS types, it reads the words already in the text box, on this Mac only, so a name or term written there comes out spelled the same way. | Spells names the way the text box already has them. | 90 chars | none | none | copy-pass |
| DI-19d | `MacDictation.swift:4143` | COS reads the text around the cursor before it types, keeps it only for that dictation and never saves or sends it. When you fix a word to a spelling that text already has, Learn from my edits takes it even if it sounds less alike. Never in terminals or password fields. | Reads text by the cursor, never saved or sent. Never in terminals or password fields. | 90 chars; keeps the privacy facts and the pinned last sentence | none | none | copy-pass |
| DI-20 | `MacDictation.swift:4145` | Format spoken lists | keep | 3 words, clear | Tests/MacDictationChecks.swift:632, Tests/dictation-wispr-pins.py:528 | control/appcast.json:348, control/docs/index.html:772 | copy-pass |
| DI-20h | `MacDictation.swift:4146` | Say “number one, … number two, …” or “bullet, … next bullet, …” and COS writes a numbered or bulleted list, one item per line. | Say “number one…” or “bullet…” and COS writes a numbered or bulleted list. | 90 chars | none | none | copy-pass |
| DI-21 | `MacDictationCore.swift:5469` | Remove filler sounds (um, uh) before typing | Remove um and uh | 4 words | none | llms.txt:32, docs/index.html:2120, control/docs/index.html:806, control/docs/index.html:1272 | copy-pass |
| DI-21d | `MacDictationCore.swift:5470` | COS leaves out um, uh, er and hmm on their own before it types, also with AI polish off. Text in another language, file names and handles keep them. | Drops um, uh, er and hmm before COS types, even with AI polish off. | 90 chars | none | none | copy-pass |
| DI-22 | `MacDictationCore.swift:5637` | Capitalize the start of a sentence | Capitalize sentences | 2 words | none | llms.txt:32, docs/index.html:2120, control/appcast.json:20, control/docs/index.html:807 (+1 more) | copy-pass |
| DI-22d | `MacDictationCore.swift:5638` | When COS can read the text box, a dictation at the start of it or after a full stop starts with a capital. Never in terminals, and never for iPhone, @handles, paths or a lowercase dictionary term. | Capitalizes a new sentence when COS can read the text box. Never in terminals or paths. | 90 chars | none | none | copy-pass |

### AI polish

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DI-23 | `MacDictation.swift:4153` | AI polish | keep | Clear | Tests/mutate-mac-dictation-core.py:377, Tests/mutate-mac-dictation-core.py:478, Tests/DictationEveryoneChecks.swift:144, Tests/MacDictationChecks.swift:1082 (+25 more) | llms.txt:32, docs/index.html:798, docs/index.html:2120, docs/index.html:2121 (+37 more) | copy-pass |
| DI-23o | `MacDictationCore.swift:2279` | Claude Haiku | keep | Clear | Tests/KeyLanesRender.swift:50, Tests/MacDictationChecks.swift:1090, Tests/LiveCuesChecks.swift:63, Tests/KeyLanesChecks.swift:46 | CHANGELOG.md:164, docs/index.html:2133, docs/index.html:2137, control/index.html:854 (+6 more) | copy-pass |
| DI-23a | `MacDictationCore.swift:2420` | Off: COS pastes what it heard. Haiku or Sonnet sends each dictation to Claude to clean up first. | Off: COS pastes what it heard. Haiku or Sonnet sends each dictation to Claude first. | 90 chars | none | none | copy-pass |
| DI-23b | `MacDictationCore.swift:2422` | Claude cleans filler, punctuation and dictionary spellings before COS pastes. It does not reliably fix misheard words. Uses your Claude plan. If it takes longer than \(Int(budget)) seconds, COS pastes what it heard. | keep | "Does not reliably fix" is a fact the tests guard as honesty (mutate-mac-dictation-core.py:401) | none | none | copy-pass |
| DI-23c | `MacDictationCore.swift:2428` | COS types what it heard right away, then swaps in Claude's version if you haven't moved on. It does not reliably fix misheard words. Uses your Claude plan. If it takes longer than \(Int(budget)) seconds, COS keeps what it typed. | keep | Same caveat, pinned (DictationParityChecks.swift:370) | none | none | copy-pass |
| DI-23d | `MacDictationCore.swift:2493` | AI polish reached the server's daily limit. COS pastes what it heard until the limit resets tomorrow. | keep | Clear | none | none | copy-pass |
| DI-23e | `MacDictationCore.swift:5941` | Glasses dictation has its own polish setting (Haiku by default). | keep | Clear | none | none | copy-pass |
| DI-24 | `MacDictation.swift:4169` | Paste right away, then polish in place | Paste then polish | 3 words | Tests/run.sh:37, Tests/dictation-swap-pins.py:78 | docs/index.html:2131, control/appcast.json:193, control/docs/index.html:1283 | copy-pass |
| DI-24d | `MacDictationCore.swift:2899` | COS types what it heard right away. When Claude's version is ready, COS swaps it in at the same spot. If you moved on or changed the text, COS leaves it and keeps the polished version in Activity, Dictation until COS Control quits. | Swaps in Claude's version. If you moved on, it waits in Activity, Dictation until quit. | Shorter; keeps where it goes | none | none | copy-pass |
| DI-24e | `MacDictationCore.swift:2898` | Works with AI polish on. | keep | Clear | none | none | copy-pass |
| DI-25 | `MacDictationCore.swift:5982` | Wait for ⌘ or ⌃ to be released before swapping in polish | Wait for held keys | 4 words | none | none | copy-pass |
| DI-25d | `MacDictationCore.swift:5983` | A shortcut you are still holding no longer cancels the swap: COS waits up to 1.2 seconds, then a moment of no typing. | If you still hold ⌘ or ⌃, COS waits up to 1.2 seconds before it swaps. | 90 chars | none | none | copy-pass |
| DI-26 | `MacDictationCore.swift:2561` | Your polish instructions | keep | 3 words | Tests/mutate-mac-dictation-core.py:624, Tests/MacDictationChecks.swift:1746, Tests/run.sh:121, Tests/dictation-polish-instructions-pins.py:2 (+2 more) | docs/index.html:2127, control/appcast.json:149, control/docs/index.html:1279 | copy-pass |
| DI-26d | `MacDictationCore.swift:2563` | Extra direction for AI polish, used after COS's built-in rules. The built-in rules still win: your instructions never change what you meant, and never change links, paths, numbers or names you said. Used for Mac and glasses dictation, not meeting transcripts. | Runs after the built-in rules, which still win. Mac and glasses dictation, not meetings. | 90 chars | none | none | copy-pass |
| DI-26e | `MacDictationCore.swift:2564` | Mac dictation uses these when AI polish is on. Glasses dictation uses them whenever it polishes. | keep | Clear | none | none | copy-pass |
| DI-26f | `MacDictation.swift:5575` | Your polish instructions could not be read. | keep | Clear | none | none | copy-pass |
| DI-26g | `MacDictation.swift:5611` | See the built-in rules | keep | Clear | Tests/dictation-polish-instructions-pins.py:71 | none | copy-pass |
| DI-27 | `MacDictationCore.swift:4834` | Your style | keep | Clear | Tests/MacDictationChecks.swift:1835, Tests/run-voice-style.sh:2, Tests/VoiceStyleRender.swift:4, Tests/VoiceStyleRender.swift:99 (+13 more) | llms.txt:32, llms.txt:42, wizard/index.html:610, docs/index.html:1747 (+12 more) | copy-pass |
| DI-27s | `MacDictationCore.swift:4282` | Learn my style from edits | Learn my style | 3 words | Tests/VoiceStyleChecks.swift:117 | docs/index.html:2121, control/docs/index.html:844, control/docs/index.html:1273 | copy-pass |
| DI-27a | `MacDictationCore.swift:4836` | Learning needs Learn from my edits set to Save automatically or Suggest only. | keep | Clear | none | none | copy-pass |
| DI-27b | `MacDictationCore.swift:4839` | No style rules yet. COS adds one after you make the same change in two dictations. | keep | Clear empty state | none | none | copy-pass |
| DI-27c | `MacDictationCore.swift:4853` | Your COS server adds your style rules (never your text) to each Sonnet polish, on G2 too when it polishes with Sonnet. | Your COS server adds your style rules (never your text) to each Sonnet polish, on the glasses too when it polishes with Sonnet. | "glasses", not G2; the condition stays (VoiceStyleChecks.swift:380) | Tests/mutate-voice-style.py:155 | control/appcast.json:41 | copy-pass |
| DI-27d | `MacDictationCore.swift:4854` | While COS watches your edit, it notices Return, clicks and other key presses in the app it typed into, as counts only. It never records which keys. | keep | Privacy fact, plainly | none | control/appcast.json:33 | copy-pass |
| DI-28 | `MacDictationCore.swift:4840` | Active | keep | Clear | Tests/fixtures/pairing/tailscale-status-running.json:13, Tests/fixtures/pairing/tailscale-status-running.json:30, Tests/fixtures/pairing/tailscale-status-running.json:48 | none | copy-pass |
| DI-28a | `MacDictationCore.swift:4842` | Not active yet | keep | Clear | Tests/mutate-voice-style.py:154, Tests/VoiceStyleChecks.swift:368 | none | copy-pass |
| DI-28p | `MacDictationCore.swift:4845` | Learning is off, so these rules are not applied, on this Mac or on G2. | Learning is off, so these rules are not used here or on the glasses. | "glasses", not G2 | Tests/mutate-voice-style.py:157 | none | copy-pass |
| DI-29 | `MacDictationCore.swift:4846` | Add a rule | keep | Clear | Tests/VoiceStyleChecks.swift:166, Tests/VoiceStyleChecks.swift:233 | docs/index.html:2121, control/docs/index.html:846, control/docs/index.html:1273 | copy-pass |
| DI-30 | `MacDictationCore.swift:4847` | Reset learned style | keep | Clear | none | docs/index.html:2121, control/docs/index.html:847, control/docs/index.html:1273 | copy-pass |
| DI-30c | `MacDictation.swift:5838` | Reset learned style? | keep | Clear | none | none | copy-pass |
| DI-30m | `MacDictation.swift:5840` | Every style rule COS learned or you added goes, on this Mac and on the server. The switch and your dictation history stay. | Deletes every style rule, learned or added, here and on the server. The switch and history stay. | Active voice | none | none | copy-pass |
| DI-31 | `MacDictationCore.swift:4849` | Previous polish (v3) | keep | Clear | none | llms.txt:32, docs/index.html:2121, control/appcast.json:37, control/docs/index.html:848 (+1 more) | copy-pass |
| DI-31d | `MacDictationCore.swift:4850` | Sonnet now uses the new polish (v4). This goes back to the earlier prompt on every model, and your style rules apply only with the new one. | Use the earlier polish prompt on every model. Your style rules work only with the newest. | 90 chars | none | none | copy-pass |
| DI-31s | `MacDictationCore.swift:4851` | Set on the server | keep | The standard lock phrase | none | none | copy-pass |

### History

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DI-32 | `MacDictation.swift:2015` | Keep dictations for | keep | Clear | Tests/mutate-mac-dictation-core.py:261, Tests/dictation-wispr-pins.py:208, Tests/dictation-wispr-pins.py:211, Tests/dictation-polish-instructions-pins.py:57 | control/appcast.json:416, control/docs/index.html:875 | copy-pass |
| DI-32o | `MacDictationCore.swift:1185` | Don't keep | keep | Clear | Tests/mutate-mac-dictation-core.py:261, Tests/mutate-mac-dictation-core.py:272, Tests/mutate-mac-dictation-core.py:273, Tests/MacDictationChecks.swift:306 (+4 more) | control/docs/index.html:875 | copy-pass |
| DI-32c | `MacDictation.swift:4195` | Stop keeping dictations? | keep | Clear | none | none | copy-pass |
| DI-32m | `MacDictation.swift:4197` | COS deletes the dictations kept on this Mac and saves none from now on. The pet still shows this session's. | keep | Clear | none | none | copy-pass |
| DI-32a | `MacDictation.swift:4199` | Delete and stop keeping | keep | Says it deletes | none | none | copy-pass |
| DI-33 | `MacDictation.swift:3642` | Clear dictation history | keep | Clear outside the Dictation pane too | Tests/dictation-wispr-pins.py:206, Tests/dictation-wispr-pins.py:207, Tests/voice-style-pins.py:109 | control/appcast.json:416, control/docs/index.html:850, control/docs/index.html:875 | copy-pass |
| DI-33c | `MacDictation.swift:4204` | Clear dictation history? | keep | Clear | none | none | copy-pass |
| DI-33m | `MacDictation.swift:4206` | Every dictation kept on this Mac is deleted. Your dictionary stays as it is. | keep | Clear | none | none | copy-pass |

## 3.6 Transcription and voice

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Voice setup

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SG-05 | `ProviderConnectViews.swift:806` | Initial recommendation: \(VoiceTier.title(recommendation)). Based on speech processing speed; calibration on smaller Macs is still in progress. | keep | Shared, kept: also shown in the setup guide voice step | none | none | copy-pass |
| SG-05a | `ProviderConnectViews.swift:816` | Test this Mac and recommend a tier. An existing voice choice is always kept. | keep | Clear | none | none | copy-pass |
| SG-05b | `ProviderConnectViews.swift:810` | Test this Mac again | keep | Clear | none | none | copy-pass |
| SG-05c | `ProviderConnectViews.swift:819` | Or run it in Terminal | keep | Clear | none | none | copy-pass |
| SG-05d | `ProviderConnectViews.swift:831` | Runs the same setup in Terminal (COS Control's helper, the installed server's own setup), for when you want to watch it | keep | Shared, kept: also shown in the setup guide voice step | none | none | copy-pass |
| SG-05e | `ProviderConnectViews.swift:797` | Transcription settings | keep | Clear | Tests/TranscriptionSettingsChecks.swift:338, Tests/run-transcription-settings-render.sh:2, Tests/ProviderConnectChecks.swift:1204, Tests/DictationEveryoneChecks.swift:52 (+5 more) | control/appcast.json:331, control/docs/index.html:433, control/docs/index.html:471, control/docs/index.html:797 (+2 more) | copy-pass |
| UT-03 | `Views.swift:2662` | Transcription | Quality tier | Names the choice | Tests/TranscriptionSettingsChecks.swift:3, Tests/TranscriptionSettingsChecks.swift:13, Tests/TranscriptionSettingsChecks.swift:14, Tests/TranscriptionSettingsChecks.swift:17 (+180 more) | RELEASE_639_6720_289.md:3, wizard/index.html:732, docs/index.html:1064, docs/index.html:1779 (+21 more) | hub-builder |
| UT-03d | `Views.swift:2669` | Balanced is recommended. Max keeps Large-v3 resident for live commit and may use substantially more memory. | Balanced suits most Macs. Max uses much more memory. Applying restarts the server. | No hedge; adds the restart | none | none | hub-builder |
| UT-03u | `Views.swift:2673` | Update Server to 6.21.0 or newer to enable transcription tier controls. | Update the server to 6.21.0 or newer to change the tier. | Shorter | none | none | hub-builder |
| UT-02 | `Views.swift:2658` | Guided Setup | Guided setup | Sentence case | Tests/mutate-provider-connect.py:77, Tests/check-release-entitlements.py:5, Tests/run.sh:720, Tests/run.sh:1102 | CHANGELOG.md:166, ONBOARDING_RELEASE_0263.md:23, wizard/index.html:473, wizard/index.html:630 (+6 more) | hub-builder |
| UT-02c | `Views.swift:756` | Choose transcription setup | keep | Clear | none | none | hub-builder |
| UT-02m | `Views.swift:758` | Balanced uses fast Small.en previews, Turbo commits, and Large-v3 polish. Max uses Large-v3 for live preview and commit too; choose it only on a powerful Mac. | keep | The model facts the choice needs | none | none | hub-builder |
| UT-02a | `Views.swift:760` | Balanced (Recommended) | Balanced (recommended) | Sentence case | none | none | hub-builder |
| TR-07 | `MeetingAskCore.swift:2000` | Install Parakeet (654 MB) | keep | Says the size | Tests/TranscriptionSettingsChecks.swift:237, Tests/TranscriptionSettingsChecks.swift:238, Tests/TranscriptionSettingsChecks.swift:251, Tests/ProviderConnectChecks.swift:1224 (+1 more) | control/index.html:649, control/appcast.json:330, control/docs/index.html:761, control/docs/index.html:794 (+1 more) | copy-pass |
| TR-07d | `MeetingAskCore.swift:1986` | Parakeet Ultra runs on this Mac, for dictation and as the second opinion. Every file is checked before it is installed, and dictation keeps working with Whisper meanwhile. | Parakeet Ultra runs on this Mac. Each file is checked, and Whisper works meanwhile. | 90 chars | none | none | copy-pass |
| TR-07a | `MeetingAskCore.swift:1987` | Install Parakeet after the recording ends. | keep | Clear | none | none | copy-pass |
| TR-07b | `MeetingAsk.swift:894` | Licenses | keep | Clear | none | control/docs/index.html:1045 | copy-pass |
| ST-04 | `Views.swift:1347` | Local transcription | keep | Clear | none | none | hub-builder |
| ST-04a | `Views.swift:1351` | Your selected engines are kept. Check Transcription settings before recording. | keep | Clear | none | none | hub-builder |
| ST-05 | `Views.swift:1355` | Local Whisper | keep | Clear | none | docs/index.html:1060, docs/index.html:2005, control/index.html:871, control/docs/index.html:1239 (+1 more) | hub-builder |
| UT-14 | `Views.swift:2787` | Repair Whisper | keep | Lead: Repair restarts the whole COS server, so "Restart Whisper" understates it | Tests/SetupAssistantChecks.swift:127, Tests/SetupAssistantChecks.swift:130, Tests/SetupAssistantChecks.swift:182, Tests/SetupAssistantChecks.swift:381 (+7 more) | control/docs/index.html:1059, control/docs/index.html:1101 | hub-builder |
| ST-13 | `Views.swift:1426` | Transcription tier | keep | Clear | none | docs/index.html:1064, control/index.html:877 | hub-builder |
| ST-13a | `Views.swift:1463` | Add names and specialist terms in the setup wizard to improve accuracy. | Add names and terms in the setup wizard for better accuracy. | Shorter | none | none | hub-builder |
| O-01 | `Views.swift:2208` | Named speakers are off | keep | Clear | none | none | hub-builder |
| O-01a | `Views.swift:2214` | Every voice shows as Me or Ext until the voiceprint model is installed. Guided Setup fetches it (about 26 MB). | Every voice shows as Me or Ext until guided setup installs the voiceprint model (26 MB). | Sentence case | none | none | hub-builder |
| O-01b | `Views.swift:2218` | Run Guided Setup | Run guided setup | Sentence case | none | none | hub-builder |

### Models

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TR-00 | `MeetingAsk.swift:756` | Transcription | keep | Card title | Tests/TranscriptionSettingsChecks.swift:3, Tests/TranscriptionSettingsChecks.swift:13, Tests/TranscriptionSettingsChecks.swift:14, Tests/TranscriptionSettingsChecks.swift:17 (+180 more) | RELEASE_639_6720_289.md:3, wizard/index.html:732, docs/index.html:1064, docs/index.html:1779 (+21 more) | copy-pass |
| TR-02 | `MeetingAsk.swift:758` | Preview model | keep | Clear | none | control/docs/index.html:1042 | copy-pass |
| TR-03 | `MeetingAsk.swift:760` | HQ model | keep | The server labels and notes say HQ; a rename here splits the term | none | RELEASE_639_6720_289.md:3, wizard/index.html:450, docs/index.html:2285, control/index.html:598 (+1 more) | copy-pass |
| TR-05 | `MeetingAskCore.swift:1934` | Preview changes apply to the \(preview). HQ changes apply to the \(hq). | keep | Follows TR-03 | Tests/TranscriptionSettingsChecks.swift:65 | RELEASE_639_6720_289.md:3 | copy-pass |
| TR-04 | `MeetingAsk.swift:762` | Second opinion | keep | Clear | Tests/TranscriptionSettingsChecks.swift:64, Tests/TranscriptionSettingsChecks.swift:140 | control/docs/index.html:1044, control/docs/index.html:1050 | copy-pass |
| TR-06 | `MeetingAsk.swift:771` | Refine with second opinion | keep | 4 words, clear | none | control/docs/index.html:1044 | copy-pass |
| TR-06a | `MeetingAskCore.swift:1964` | Not refining: Second opinion is off. | keep | Clear | Tests/TranscriptionSettingsChecks.swift:140 | none | copy-pass |
| TR-08 | `MeetingAsk.swift:782` | Front end | keep | Clear in Advanced | none | control/docs/index.html:1046 | copy-pass |
| TR-09 | `MeetingAsk.swift:783` | Quiet detection | keep | Clear | none | control/docs/index.html:1046 | copy-pass |

### Performance

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| UT-11 | `Views.swift:2759` | Idle Metal HQ | GPU when idle | Plain words | Tests/run.sh:499 | docs/index.html:1659, control/index.html:875, control/docs/index.html:1058 | hub-builder |
| UT-11h | `Views.swift:2766` | Powerful Macs only. Uses Metal for sealed post-meeting HQ when idle. Live and progressive transcription stay protected; Off forces CPU rollback. | Powerful Macs only. Final transcripts use the GPU when idle. Applying restarts the server. | 90 chars; adds the restart | none | none | hub-builder |
| ST-11 | `Views.swift:1409` | Idle Metal HQ | GPU when idle | Same name as UT-11 | Tests/run.sh:499 | docs/index.html:1659, control/index.html:875, control/docs/index.html:1058 | hub-builder |
| ST-11a | `Views.swift:1408` | On · preemptible | On · pauses for live work | Plain words | none | none | hub-builder |
| UT-12 | `Views.swift:2772` | Adaptive audio cleanup | Playback cleanup | Says what it changes | Tests/run.sh:554 | control/docs/index.html:1057 | hub-builder |
| UT-12h | `Views.swift:2779` | Default off. Cleans retained audio only when you press Play. Raw WAV stays untouched; live transcription, speaker attribution, save, HQ, and sync do not change. Off restores raw replay. | Cleans audio when you press Play. The original stays as is. Applying restarts the server. | 90 chars; keeps "original untouched" | none | none | hub-builder |
| ST-12 | `Views.swift:1413` | Audio cleanup | Playback cleanup | Same name as UT-12 | none | none | hub-builder |
| ST-12a | `Views.swift:1413` | Adaptive replay | Cleaned | Plain word | none | docs/index.html:1053, docs/index.html:1063, docs/index.html:1142, docs/index.html:2049 (+2 more) | hub-builder |
| ST-12b | `Views.swift:1412` | Raw replay | Original | Plain word | none | none | hub-builder |
| ST-19 | `Views.swift:1555` | HQ prefill | keep | Advanced status, set on the server | Tests/run.sh:754 | docs/index.html:2237, docs/index.html:2355, control/index.html:883 | hub-builder |

## 3.7 Work and agents

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Sessions

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| UT-06 | `Views.swift:2704` | Show Claude sessions | Show AI sessions | Covers Claude, Codex and Cursor | Tests/panel-toggle-source.py:8 | control/docs/index.html:1005, control/docs/index.html:1210 | hub-builder |
| UT-06h | `Views.swift:2710` | Lists Claude, Codex and Cursor sessions from this Mac in the Activity window. Off by default: it reads another product's private state directory and serves names, workspaces and timestamps — not conversation content — over your local network. Leave it off on an untrusted network. | Shares session names, not chats, on your local network. Applying restarts the server. | Keeps the privacy fact and the restart; no em dash | none | none | hub-builder |
| UT-07 | `Views.swift:2715` | Continue agent threads | Continue sessions | Users know sessions; "thread" is a COS thread | Tests/run.sh:1769 | docs/index.html:1186, control/docs/index.html:510, control/docs/index.html:1020, control/docs/index.html:1210 | hub-builder |
| UT-07h | `Views.swift:2722` | On by default since server 6.37. Lets a reply write into a real Claude or Codex session on this Mac instead of starting a new thread. Off writes an explicit 0, so the write routes stay dark on every server era. | Replies go into your real Claude or Codex session. Applying restarts the server. | 90 chars; drops build notes | none | none | hub-builder |
| UT-07x | `ControllerModel.swift:7187` | Continue agent threads is off in Settings. | Continue sessions is off in Settings. | Follows the UT-07 rename (5 places in this file) | none | none | hub-builder |
| ST-09 | `Views.swift:1384` | Continue threads | Continue sessions | Same name as UT-07 | none | none | hub-builder |
| WK-03 | `Views.swift:2854` | Open new sessions in the app | Open new sessions | 3 words | Tests/WorkIntakeChecks.swift:362, Tests/WorkHandoffTests.swift:351, Tests/run.sh:1288 | docs/index.html:2222, docs/index.html:2307, control/docs/index.html:992 | hub-builder |
| WK-03h | `Views.swift:2856` | Start Claude and Codex work in the background, then open it in their app when the first reply is done. Off: it stays in the background on this Mac. Cursor always opens its own window with the handoff filled in, for you to send | Claude and Codex sessions open in their app after the first reply. Off: background only. | 90 chars | none | none | hub-builder |
| WK-02 | `Views.swift:2850` | Work notifications | keep | Clear | Tests/run.sh:1262 | control/docs/index.html:991 | hub-builder |
| WK-02h | `Views.swift:2852` | Notify me when a session receives Work, reports it done, or needs my input | Alerts when a session gets Work, finishes it, or needs you. | Shorter | none | none | hub-builder |
| OUT-04 | `new (hub chrome)` | (none) | Track session usage | New Settings row; keep the checkbox in Usage | none | none | hub-builder |
| OUT-04d | `new (hub chrome)` | (none) | Count session tokens on this Mac. | New description | none | none | hub-builder |

### Work chat

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| WK-04 | `Views.swift:2858` | Send plans without review | keep | 4 words, clear | Tests/run-work-session-hub.sh:40, Tests/run-work-session-hub.sh:42, Tests/run-work-session-hub.sh:45, Tests/WorkOrchestrationChecks.swift:597 (+1 more) | control/appcast.json:406, control/docs/index.html:975 | hub-builder |
| WK-04h | `Views.swift:2860` | The default for every card's Auto-send switch (0.5.333). On: Work chat's main button becomes Plan and send, assignments go to their sessions as soon as they are planned, and each has a Stop. A card's own switch overrides this. Plan, with review, stays available | Work chat plans and sends in one step, each with a Stop. Each card can override it. | 90 chars; no version number | none | none | hub-builder |
| WK-04x | `WorkTaskChat.swift:1552` | Its default is Settings › Work › Send plans without review. | Its default is in Settings, Work and agents. | Points at the new home; no arrows | none | none | hub-builder |
| WK-05 | `Views.swift:2863` | When earlier work is still open | When work is open | 4 words | Tests/run-work-session-hub.sh:80, Tests/WorkOrchestrationChecks.swift:1049, Tests/mutate-work-chat-queue.py:85 | control/appcast.json:341, control/docs/index.html:979, control/docs/index.html:980 | hub-builder |
| WK-05o | `WorkChatQueue.swift:27` | Queue it | keep | Clear | Tests/run-work-session-hub.sh:68, Tests/run-work-session-hub.sh:81, Tests/run-work-session-hub.sh:98, Tests/WorkOrchestrationChecks.swift:977 (+11 more) | docs/index.html:2146, control/appcast.json:341, control/docs/index.html:980, control/docs/index.html:1294 | hub-builder |
| WK-05h | `WorkChatQueue.swift:38` | Queue it: a send that earlier work would hold waits, then sends by itself once that work is resolved, after the same checks. Ask each time: choose Queue it, Send in parallel or Check first. | Queue it sends once earlier work resolves, while COS Control is open. Ask lets you pick. | 90 chars; drop the appended whileClosed sentence here | none | none | hub-builder |
| WK-01 | `Views.swift:1054` | Work intake | keep | Clear | Tests/WorkIntakeChecks.swift:79, Tests/work-intake-helper-checks.py:2, Tests/ActivityTodayRender.swift:154 | control/appcast.json:544 | hub-builder |
| WK-01t | `Views.swift:1055` | Expire old asks from other people | Expire old asks | 3 words | none | none | hub-builder |
| WK-01h | `Views.swift:1057` | Your own items and uncertain owners stay for Keep or Drop. Restore expired asks from Sort for 30 days. | Expires other people's old asks; yours stay. Restore them from Sort for 30 days. | Says what expires | none | none | hub-builder |
| OUT-05 | `new (hub chrome)` | (none) | Default planner | New Settings row | none | none | hub-builder |
| OUT-05d | `new (hub chrome)` | (none) | The model that plans Work on this Mac. | New description | none | none | hub-builder |
| OUT-06 | `new (hub chrome)` | (none) | Planning effort | New Settings row | none | none | hub-builder |
| OUT-06d | `new (hub chrome)` | (none) | How hard the planner thinks. Higher uses more tokens. | New description | none | none | hub-builder |

### Background

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| UT-04 | `Views.swift:2679` | Background jobs | keep | Clear | Tests/PermissionGuideChecks.swift:95, Tests/PermissionGuideChecks.swift:353, Tests/PermissionGuideChecks.swift:374 | docs/index.html:1061, docs/index.html:1109, control/index.html:838, control/index.html:872 (+2 more) | hub-builder |
| UT-04h | `Views.swift:2686` | On by default. Replies keep running when the companion closes or you browse elsewhere. Existing work must finish before this machine-wide setting changes. | Replies keep running when the phone app closes. Applying restarts the server. | 90 chars; HUB-08 says why it waits | none | none | hub-builder |

### Folders and notes

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| UT-15 | `Views.swift:2792` | Work Folder | Work folder | Sentence case | Tests/ControlsContract.swift:311, Tests/PanelLabelsRender.swift:37, Tests/PanelLabelsRender.swift:109, Tests/run.sh:479 | wizard/index.html:460, wizard/index.html:482, challenge/index.html:483, control/index.html:560 (+2 more) | hub-builder |
| UT-15h | `Views.swift:2795` | COS workspace for Claude, Codex, and Cursor (Work folder above) | The folder Claude, Codex and Cursor work in. Changing it restarts the server. | Adds the restart | none | none | hub-builder |
| UT-15i | `Views.swift:2796` | Install the managed server or choose Manage in place first | Install the server or choose Manage in place first | One term for the server | none | none | hub-builder |
| ST-28 | `Views.swift:1687` | Work folder | keep | Clear | none | docs/index.html:1070, control/index.html:885, control/docs/index.html:1088 | hub-builder |
| ST-28a | `Views.swift:1693` | Saved to LaunchAgent · pending a safe server restart | Saved. Applies at the next safe restart. | Plain words | none | none | hub-builder |
| UT-17 | `Views.swift:2802` | COS Data | Notes folder | Says what it holds | Tests/build-up-pins.py:72, Tests/PanelLabelsRender.swift:42, Tests/PanelLabelsRender.swift:48, Tests/PanelLabelsRender.swift:49 | wizard/index.html:553, wizard/index.html:1170, wizard/index.html:1173, docs/index.html:1159 (+6 more) | hub-builder |
| UT-17h | `Views.swift:2804` | Choose a folder of markdown notes (memory/ or threads/), or a COS workspace with the Python bridge. This does not change the Work Folder or Meetings Library. | Notes in memory/ or threads/, or a COS workspace. Changing it restarts the server. | 90 chars; adds the restart | none | none | hub-builder |
| UT-17x | `ActivityWindow.swift:4790` | Choose COS Data in the menu-bar panel to connect this library. | Choose a notes folder in Settings to connect this library. | Follows the rename and the new home | Tests/build-up-pins.py:72 | none | hub-builder |
| UT-18 | `Views.swift:2812` | Create Folders | keep | Kept for test churn: 10 test locations, and the helper message says "Use Create Folders." | Tests/ControlsContract.swift:116, Tests/ControlsContract.swift:309, Tests/ControlsContract.swift:319, Tests/PanelLabelsRender.swift:8 (+6 more) | wizard/index.html:1165, control/index.html:852, control/docs/index.html:708, control/docs/index.html:1102 | hub-builder |
| UT-18h | `Views.swift:1767` | Choose a Work Folder or Meetings Library first | Choose a work folder or meetings folder first | Follows the renames | none | none | hub-builder |
| ST-06 | `Views.swift:1360` | Memory & Threads | Memory and threads | No ampersand | none | assets/docs-control.js:23 | hub-builder |
| ST-06a | `Views.swift:1758` | Update your COS workspace, then choose COS Data again. | Update your COS workspace, then choose the notes folder again. | Follows the rename | none | none | hub-builder |
| ST-06b | `Views.swift:1759` | The workspace bridge failed. Open Logs, then choose COS Data again. | The workspace bridge failed. Open logs, then choose the notes folder again. | Follows the renames | none | none | hub-builder |
| ST-06c | `Views.swift:1765` | No memory/ or threads/ folder yet. Create Folders makes them in | keep | Names Create Folders, kept | none | none | hub-builder |
| ST-06d | `Views.swift:1767` | Choose a Work Folder or Meetings Library first, then Create Folders. | Choose a work folder or meetings folder first, then Create Folders. | Follows the folder renames; Create Folders kept | none | none | hub-builder |
| ST-06e | `Views.swift:1797` | Choose COS Data to switch to it, which replaces the file tier. | Choose it as the notes folder to use it instead of plain files. | Plain words | none | none | hub-builder |
| UT-19 | `Views.swift:2818` | Bridge: \(path) | keep | Clear | none | none | hub-builder |

### Morning brief

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MB-01 | `Views.swift:2410` | MORNING BRIEF | keep | Card header style | none | none | hub-builder |
| MB-02 | `Views.swift:2444` | Brief every | keep | Reads with the time and days | none | none | hub-builder |
| MB-02d | `Views.swift:2461` | Lands in the inbox as a numbered reply before you open COS. One run a day; a Mac asleep at the slot still fires within three hours. | Lands in your inbox once a day. If the Mac is asleep, it runs within 3 hours. | 90 chars | none | none | hub-builder |
| MB-05 | `Views.swift:2504` | Sources · \(count) on | keep | Clear | Tests/mutate-mac-dictation-core.py:783, Tests/mutate-card-files.py:190, Tests/mutate-work-chat-helper.py:38, Tests/mutate-pet-refresh.py:78 (+53 more) | none | hub-builder |
| MB-07 | `Views.swift:2577` | Apply | keep | Clear | Tests/run.sh:5853 | control/docs/index.html:686, control/docs/index.html:1005, control/docs/index.html:1055, control/docs/index.html:1210 | hub-builder |
| MB-08 | `Views.swift:2581` | Run Now | Run now | Sentence case | none | none | hub-builder |
| MB-08h | `Views.swift:2583` | Runs the brief right away and drops it in the inbox. Five a day. | keep | Clear | none | none | hub-builder |
| MB-09 | `Views.swift:2436` | Loading the schedule… | keep | Clear | none | none | hub-builder |

### Domains

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DM-01 | `Views.swift:2305` | Domains | keep | Clear | none | philosophy/cos-philosophy-diagram.html:2799 | hub-builder |
| DM-01e | `Views.swift:2310` | No domains yet. COS uses the folders under operations/ that hold a tasks.md. | keep | Clear empty state | none | none | hub-builder |
| DM-02 | `Views.swift:2326` | Move up | keep | Clear | none | none | hub-builder |
| DM-03 | `Views.swift:2338` | Reset | keep | Clear | Tests/mutate-permission-guide.py:77, Tests/permission-guide-pins.py:78 | control/docs/index.html:569, control/docs/index.html:779 | hub-builder |
| DM-03d | `Views.swift:2345` | A folder under operations/ with a tasks.md always shows here, whether or not it is listed. Removing a name only unlists it; the folder and its tasks stay. | Any folder in operations/ with a tasks.md shows here. Remove unlists it; its tasks stay. | 90 chars; keeps "tasks stay" | none | none | hub-builder |

### Paused threads

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| FN-01 | `Views.swift:2104` | Fenced threads · \(model.fenceRecords.count) | Paused threads · \(model.fenceRecords.count) | Users know paused, not fenced | none | none | hub-builder |
| FN-01d | `Views.swift:2118` | COS sent a turn and never learned whether it arrived, so it stopped writing to the thread. Open it on your Mac before releasing. | COS stopped writing here after a message it sent went unconfirmed. Check the thread first. | 90 chars | none | none | hub-builder |
| FN-01w | `Views.swift:2127` | These will not survive a server restart — the server could not write them to disk. | These clear on a server restart. The server could not save them. | No em dash | none | none | hub-builder |
| FN-01f | `Views.swift:2142` | fenced \(fence.fencedAtLabel) | paused \(fence.fencedAtLabel) | Same term | none | none | hub-builder |
| FN-02 | `Views.swift:2147` | Release | keep | Clear | Tests/run.sh:2479, Tests/fence-canary/Canary.swift:57, Tests/fence-canary/Canary.swift:81, Tests/fence-canary/Canary.swift:90 (+1 more) | docs/index.html:945, assets/ring-lessons.js:271 | hub-builder |
| FN-02h | `Views.swift:2157` | Release this fence so COS can write to the thread again | Let COS write to this thread again | Same term | none | none | hub-builder |
| FN-02c | `Views.swift:725` | Release this fence? | Release this thread? | Same term | none | none | hub-builder |
| FN-02a | `Views.swift:599` | Release | keep | Clear | Tests/run.sh:2479, Tests/fence-canary/Canary.swift:57, Tests/fence-canary/Canary.swift:81, Tests/fence-canary/Canary.swift:90 (+1 more) | none | hub-builder |

## 3.8 Privacy and permissions

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PM-01 | `PermissionGuideViews.swift:178` | Permissions | keep | Clear | Tests/SetupAssistantChecks.swift:42 | harness/index.html:374, control/docs/index.html:426, control/docs/index.html:464, control/docs/index.html:499 (+2 more) | copy-pass |
| PM-01d | `PermissionGuideViews.swift:192` | What COS can use on this Mac, and one click to allow each | keep | Clear | none | none | copy-pass |
| PM-01c | `PermissionGuideViews.swift:154` | Each one switches on a feature. COS works without any of them. | keep | Clear | none | control/docs/index.html:539 | copy-pass |
| PM-01s | `PermissionGuideModel.swift:424` | All set | keep | Clear | Tests/PermissionGuideChecks.swift:179 | none | copy-pass |
| PM-02 | `PermissionGuideModel.swift:256` | Accessibility | keep | macOS name | Tests/mutate-mac-dictation-core.py:78, Tests/mutate-mac-dictation-core.py:535, Tests/mutate-mac-dictation-core.py:566, Tests/MacRecordingChecks.swift:271 (+88 more) | wizard/index.html:725, docs/index.html:1170, docs/index.html:1183, docs/index.html:1964 (+22 more) | copy-pass |
| PM-02d | `PermissionGuideModel.swift:257` | Lets dictation type into the app you are using, and lets COS jump straight to your Claude or Cursor session and bring its window forward. | keep | Shared, kept: also shown in the Welcome window permissions step | none | none | copy-pass |
| PM-02a | `PermissionGuideViews.swift:68` | Already on? Reset and add again | keep | Clear | Tests/mutate-permission-guide.py:78, Tests/permission-guide-pins.py:79 | control/docs/index.html:566 | copy-pass |
| PM-02b | `PermissionGuideModel.swift:262` | An update changed COS Control's signature, so the old switch no longer counts. | keep | Clear | none | control/docs/index.html:564 | copy-pass |
| PM-03 | `PermissionGuideModel.swift:273` | Lets COS tell you when meeting audio stops reaching this Mac and when Work needs you. | keep | 85 chars, clear | none | none | copy-pass |
| PM-03a | `PermissionGuideModel.swift:279` | Allowed, but alerts are switched off. | keep | Clear | none | none | copy-pass |
| PM-04 | `PermissionGuideModel.swift:294` | Starts COS Control when you log in, so the pet, meeting alerts and Work stay on. | keep | Clear | none | none | copy-pass |
| PM-04a | `PermissionGuideModel.swift:300` | macOS is waiting for you to approve it in Login Items. | keep | Clear | none | none | copy-pass |
| PM-05 | `PermissionGuideModel.swift:328` | Lets the glasses server read your COS scripts in Documents. | keep | Shared, kept: also shown in the Welcome window permissions step | none | none | copy-pass |
| PM-05b | `PermissionGuideModel.swift:329` | Lets COS's scheduled jobs, such as meeting sync, read your COS folder after macOS updates. | keep | Clear | none | none | copy-pass |
| PM-05t | `PermissionGuideModel.swift:326` | Glasses server (\(name)) | keep | Shared, kept: also shown in the Welcome window permissions step | Tests/PermissionGuideChecks.swift:138 | none | copy-pass |
| PM-06 | `PermissionGuideModel.swift:375` | Lets COS reopen \(target.name) and bring your session forward. | keep | Clear | none | none | copy-pass |
| PM-06a | `PermissionGuideModel.swift:388` | Checked when \(target.name) is open. Test opens it. | keep | Clear | none | none | copy-pass |
| PM-07 | `PermissionGuideModel.swift:401` | Calendar (CalendarFetch) | keep | Names the helper app | none | none | copy-pass |
| PM-07d | `PermissionGuideModel.swift:402` | Lets COS keep your meeting-prep calendar cache up to date. | keep | Clear | none | none | copy-pass |
| PM-0b | `PermissionGuideModel.swift:133` | Allow | keep | Clear | none | docs/index.html:1969, docs/index.html:2144, control/docs/index.html:1165, control/docs/index.html:1293 | copy-pass |
| PM-0c | `PermissionGuideModel.swift:136` | Open settings | keep | Clear | Tests/PermissionGuideChecks.swift:84 | none | copy-pass |
| PM-08 | `PermissionGuideViews.swift:106` | Clean up old COS test builds | keep | Clear | none | none | copy-pass |
| PM-08e | `PermissionGuideViews.swift:113` | No old COS test builds on this Mac. | keep | Clear empty state | none | none | copy-pass |
| PM-08d | `PermissionGuideViews.swift:116` | Each one can leave its own row under Accessibility. Reset removes that build's row; COS Control stays. | keep | Clear | none | none | copy-pass |

## 3.9 Pet and appearance

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Session pet

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PT-01 | `Views.swift:1264` | Session pet | keep | Clear | Tests/run.sh:1979, Tests/run.sh:3047, Tests/run.sh:3048, Tests/run.sh:3053 (+5 more) | wizard/index.html:725, docs/index.html:1965, docs/index.html:2290, control/index.html:566 (+6 more) | hub-builder |
| PT-02 | `Views.swift:1186` | Jump to session needs Accessibility | keep | Clear | none | control/docs/index.html:643 | hub-builder |
| PT-02d | `Views.swift:1188` | Everything else about the pet works without it. | keep | Clear | none | none | hub-builder |
| PT-02b | `Views.swift:1200` | Grant | Allow | Same verb as Permissions | none | control/docs/index.html:643, control/docs/index.html:1214 | hub-builder |
| PT-02x | `ControllerModel.swift:6176` | Already on? Use Reset and add again in COS Control Settings, under Session pet. | Already on? Use Reset and add again in Settings, Pet and appearance. | Points at the new home | none | none | hub-builder |
| PT-03 | `Views.swift:4834` | Pet size | keep | Clear | Tests/run.sh:3048 | control/index.html:856, control/docs/index.html:642 | hub-builder |
| PT-04 | `Views.swift:4851` | Pet size in pixels | keep | Clear | none | none | hub-builder |
| PT-05 | `Views.swift:4866` | Character size | keep | Clear | Tests/run.sh:3132 | control/index.html:799, control/docs/index.html:642 | hub-builder |
| PT-05d | `Views.swift:4883` | Scales the figure only. Buttons, text, and the card keep their size. | keep | Clear | none | none | hub-builder |
| PT-06 | `Views.swift:4888` | Character speed | keep | Clear | Tests/run.sh:3133 | control/docs/index.html:642 | hub-builder |
| PT-06d | `Views.swift:4905` | Controls animation playback only. 25% is slow motion; 100% matches the pack. | keep | Clear | none | none | hub-builder |
| PT-07 | `Views.swift:4910` | Motion | keep | Clear | Tests/run.sh:4706, Tests/run.sh:4765 | control/docs/index.html:642 | hub-builder |
| PT-07d | `Views.swift:4915` | Full plays every state. Calm rests the character on its idle loop | Full plays every state, Calm stays idle, None holds still. Also on the pet's menu. | 90 chars; replaces the four source lines | none | none | hub-builder |
| PT-14 | `ProviderConnectViews.swift:644` | That small character by your windows is your session pet. It shows what your AI sessions are doing; click it to jump to one. | keep | Clear | none | none | copy-pass |
| PT-14h | `ProviderConnectViews.swift:652` | Turn the pet off. Settings, under Session pet, brings it back | keep | Shared, kept: also shown in the Welcome window (PetIntroLine) | none | none | copy-pass |
| PT-15 | `SessionPet.swift:1348` | Hide pet | keep | Clear | Tests/run.sh:4726, Tests/run.sh:4732, Tests/run.sh:4733, Tests/ProviderConnectRender.swift:210 (+1 more) | control/docs/index.html:634 | copy-pass |
| PT-15b | `SessionPet.swift:1351` | Settings… | keep | Clear | Tests/mutate-provider-connect.py:75, Tests/mutate-provider-connect.py:76, Tests/dictation-lock-pins.py:161, Tests/provider-connect-pins.py:132 (+2 more) | control/docs/index.html:609, control/docs/index.html:634 | copy-pass |

### Characters

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PT-09 | `Views.swift:1226` | Characters | keep | Clear | Tests/run.sh:1663, Tests/run.sh:3355 | none | hub-builder |
| PT-09a | `Views.swift:827` | Replaces the current session pet sprite with this gallery thumbnail. Use Cloud Puff restores the default; Characters offers animated pets. | keep | Clear | none | none | hub-builder |
| PT-09b | `Views.swift:1002` | Community characters unavailable right now. | keep | Clear | Tests/run.sh:1664 | none | hub-builder |
| PT-09c | `Views.swift:1014` | No characters match. | keep | Clear empty state | none | none | hub-builder |
| PT-09d | `Views.swift:1029` | Community art from openpets.dev. No license metadata is published. Personal use. | keep | The license fact | none | none | hub-builder |
| PT-10 | `Views.swift:827` | Use Cloud Puff | keep | Clear | none | ONBOARDING_RELEASE_0263.md:9, control/docs/index.html:639 | hub-builder |
| PT-11 | `Views.swift:1244` | Install sprite pack | keep | Clear | Tests/run.sh:3054 | control/index.html:786, control/docs/index.html:639 | hub-builder |
| PT-12 | `Views.swift:1248` | Choose sprite | keep | Clear | Tests/ModelsContract.swift:2070, Tests/run.sh:1980, Tests/run.sh:3053, Tests/run.sh:3074 | control/docs/index.html:639 | hub-builder |
| PT-13 | `Views.swift:1253` | Use COS figure | keep | Clear | Tests/ModelsContract.swift:2070, Tests/run.sh:3200 | none | hub-builder |

## 3.10 System and updates

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Server

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ST-01 | `Views.swift:1343` | Server | keep | Clear | none | wizard/index.html:435, docs/index.html:1057, docs/index.html:2191, control/index.html:868 | hub-builder |
| ST-03 | `Views.swift:1345` | Needs repair | keep | Clear | none | none | hub-builder |
| ST-27 | `Views.swift:1684` | Self-managed | keep | Clear | none | none | hub-builder |
| ST-30 | `Views.swift:1715` | recording(s) active. Restart is locked. | recording(s) active. Restart waits until they finish. | Says what happens | none | none | hub-builder |
| ST-31 | `Views.swift:1723` | An interrupted server change needs Repair. | keep | Clear | Tests/run.sh:610 | none | hub-builder |
| C-09a | `Views.swift:1839` | A recognized stopped legacy LaunchAgent can be adopted exactly. | COS Control can take over this stopped older server as it is. | Plain words | none | none | hub-builder |
| C-09b | `Views.swift:1846` | Your server is running. COS Control can manage it in place — status, restart, and recovery — without replacing it. | Your server is running. COS Control can restart and recover it without replacing it. | No em dashes | none | none | hub-builder |
| C-09c | `Views.swift:1860` | Ownership conflict detected. COS Control will not stop or replace the unknown listener. | keep | Quoted on gotcos.com; clear | none | none | hub-builder |
| C-01 | `Views.swift:1808` | Restart | keep | Clear | none | control/docs/index.html:598, control/docs/index.html:1092 | hub-builder |
| C-01c | `Views.swift:734` | Restart this self-managed server? | keep | Clear | Tests/run.sh:2762 | none | hub-builder |
| C-01m | `Views.swift:736` | This older server cannot prove that meetings and agent jobs are idle. Continue only when no work is active. COS Control will reload the LaunchAgent so the selected folder becomes active. | This older server cannot show whether meetings and jobs are idle. Restart only when no work is running. | Plain words; keeps the warning | none | none | hub-builder |
| C-04 | `Views.swift:1826` | Update Server | keep | Kept for test churn: 25 test locations; not misleading | Tests/WorkIntakeChecks.swift:412, Tests/WorkIntakeChecks.swift:430, Tests/WorkIntakeChecks.swift:432, Tests/SetupAssistantChecks.swift:169 (+21 more) | docs/index.html:1037, docs/index.html:1674, docs/index.html:1863, docs/index.html:2235 (+9 more) | hub-builder |
| C-04x | `ActivityWindow.swift:2803` | Update Server | keep | Kept for test churn: 25 test locations; not misleading | Tests/WorkIntakeChecks.swift:412, Tests/WorkIntakeChecks.swift:430, Tests/WorkIntakeChecks.swift:432, Tests/SetupAssistantChecks.swift:169 (+21 more) | docs/index.html:1037, docs/index.html:1674, docs/index.html:1863, docs/index.html:2235 (+9 more) | hub-builder |
| C-04y | `Models.swift:6435` | Use Update Server in Settings. | keep | Follows C-04, kept | none | none | hub-builder |
| C-04z | `ControllerModel.swift:10536` | This needs glasses-server 6.21.18 or newer — use Update Server. | This needs COS server 6.21.18 or newer. Use Update Server. | No em dash; one term for the server (2 places); button name kept | none | none | hub-builder |
| C-05 | `Views.swift:1829` | Install Server | Install server | Sentence case | none | control/docs/index.html:598 | hub-builder |
| C-06 | `Views.swift:1841` | Adopt Safely | Adopt server | Says what it adopts | Tests/SetupAssistantChecks.swift:269, Tests/mutate-setup-assistant.py:70 | control/docs/index.html:531 | hub-builder |
| C-07 | `Views.swift:1849` | Manage in place | keep | Clear | Tests/SetupAssistantChecks.swift:269 | control/docs/index.html:531 | hub-builder |
| C-08 | `Views.swift:1851` | Install managed server | Replace server | Says what happens to the old one | none | control/docs/index.html:531 | hub-builder |
| C-08c | `Views.swift:743` | Install the latest managed server? | Replace the older server? | Same term | none | none | hub-builder |
| C-08m | `Views.swift:745` | This stops your checkout LaunchAgent, then installs the current npm latest (@gotcos/glasses-server@latest). Finish active glasses work first. Prefer Manage in place if you only want status/restart without replacing the server. | Stops your older server, then installs the latest COS server. Finish glasses work first. To keep it, use Manage in place. | Plain words; same facts | none | none | hub-builder |
| C-08a | `Views.swift:747` | Stop legacy and install | Stop and replace | Same term | Tests/run.sh:385 | none | hub-builder |

### App updates

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| H-01 | `Views.swift:1313` | COS Control \(ControllerModel.currentVersion) | keep | Clear | Tests/MacRecordingChecks.swift:412, Tests/MacRecordingChecks.swift:414, Tests/MacRecordingChecks.swift:418, Tests/MacRecordingChecks.swift:487 (+285 more) | llms.txt:13, llms.txt:14, llms.txt:32, index.html:499 (+273 more) | hub-builder |
| H-02 | `Views.swift:1324` | Refresh status and check for updates | keep | Clear | Tests/mutate-refresh-check.py:61, Tests/mutate-refresh-check.py:62, Tests/refresh-check-pins.py:40, Tests/refresh-check-pins.py:41 | none | hub-builder |
| H-03 | `Views.swift:1295` | Your local glasses server | Your COS server on this Mac | One term for the server | Tests/mutate-refresh-check.py:63, Tests/refresh-check-pins.py:80, Tests/RefreshCheckChecks.swift:21 | none | hub-builder |
| H-05 | `Models.swift:4334` | Update available | keep | Release-flow copy, pinned | Tests/run-whats-new.sh:95, Tests/run-refresh-check.sh:57, Tests/run-refresh-check.sh:58, Tests/fixtures/whats-new/whats-new-0.5.275.json:27 | docs/index.html:2153, docs/index.html:2156, control/docs/index.html:592, control/docs/index.html:1134 (+2 more) | hub-builder |
| H-05b | `Models.swift:4347` | Update did not install | keep | Release-flow copy, pinned | none | none | hub-builder |
| H-07 | `Views.swift:591` | Dismiss | keep | Clear | Tests/work-intake-helper-checks.py:62, Tests/activity-today-pins.py:110, Tests/mutate-activity-today.py:119, Tests/run.sh:5228 (+1 more) | none | hub-builder |
| G-05 | `Views.swift:2992` | Controller \(controller)  •  Server \(live) (npm latest) | keep | Footer, pinned by the release checks | none | none | hub-builder |

### Troubleshooting

| ID | file:line | Current (verbatim) | Proposed | Reason | Pinned by | Quoted on gotcos.com | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| UT-01 | `Views.swift:2657` | Run Doctor | Run checks | Says what it does; as on the board | Tests/ControlsContract.swift:311, Tests/PanelLabelsRender.swift:37 | docs/index.html:1053, docs/index.html:1071, docs/index.html:1087, control/index.html:890 (+3 more) | hub-builder |
| DR-01 | `Views.swift:2625` | DOCTOR | CHECKS | Same term | none | control/docs/index.html:1098 | hub-builder |
| UT-13 | `Views.swift:2784` | Repair Managed Runtime | Repair server | One term for the server | none | control/docs/index.html:1101, control/docs/index.html:1181 | hub-builder |
| UT-22 | `Views.swift:2831` | Copy Report | Copy report | Sentence case | Tests/mutate-live-transcript.py:121, Tests/live-transcript-pins.py:82 | control/docs/index.html:1103, control/docs/index.html:1242 | hub-builder |
| UT-22d | `new (hub chrome)` | (none) | Copy a report for the COS team. Keys and tokens are left out. | Board text; verify the redaction claim before shipping | none | none | hub-builder |
| UT-23 | `Views.swift:2832` | Open Logs | Open logs | Sentence case | none | control/docs/index.html:1103 | hub-builder |
| UT-23x | `ActivityWindow.swift:6088` | Messages could not be loaded. Open Logs from the menu-bar panel, then try again. | Messages could not be loaded. Open logs from Settings, then try again. | Follows the rename and the new home | none | none | hub-builder |
| UT-24 | `Views.swift:2833` | Health | Health page | Says what opens | none | control/docs/index.html:1103 | hub-builder |
| G-04 | `Views.swift:2980` | Quit | keep | Clear | Tests/run-app-quit.sh:44, Tests/run.sh:958, Tests/run.sh:1122 | control/docs/index.html:600 | hub-builder |
| UT-26 | `Views.swift:2898` | Rollback Server | Roll back server | Verb form, sentence case | none | control/docs/index.html:1143 | hub-builder |
| UT-26c | `new (hub chrome)` | (none) | Roll back to server {previous}? | New confirm (inventory: add one); board text | none | none | hub-builder |
| UT-26m | `new (hub chrome)` | (none) | COS Control stops {current} and starts the version it kept. You can update again from this page. | Board text | none | none | hub-builder |
| UT-27 | `Views.swift:2899` | Reconcile Change | Finish server change | Says what it does | none | none | hub-builder |
| UT-28 | `Views.swift:2900` | Setup Guide | Online help | O-12: it opens gotcos.com, not the guide | none | none | hub-builder |

## Over 90 characters on purpose

Confirm messages keep every fact the choice depends on, so a few run past 90 characters. Two captions could not be cut further without dropping a fact a person decides on.

| ID | Length | Why |
| --- | --- | --- |
| KL-03m | 132 | Confirm message: keeps what is deleted or ended and what is kept |
| H-04m | 156 | Confirm message: keeps what is deleted or ended and what is kept |
| UT-10m | 124 | Confirm message: keeps what is deleted or ended and what is kept |
| DI-18d | 396 | Where learning works and where it never runs are both decision facts; three phrases are pinned |
| DI-27c | 127 | Privacy disclosure; the Sonnet condition is pinned (VoiceStyleChecks.swift:380) |
| DI-30m | 96 | Confirm message: keeps what is deleted or ended and what is kept |
| C-01m | 103 | Confirm message: keeps the warning that this server cannot prove work is idle |
| C-08m | 121 | Confirm message: keeps what is deleted or ended and what is kept |

## Kept on purpose

- **Shared, kept** (shown outside Settings too): SG-14, SG-14h, SG-14b, SG-15h, SG-07, SG-07a, SG-08, SG-09d, KL-05b, KL-06n, KL-06e, KL-10, KL-14m, KL-15, SG-12, SG-12d, SG-13, SG-06c, SG-05, SG-05d, PM-02d, PM-05, PM-05t, PT-14h.
- **Test churn** (more than about 10 test locations, not misleading): SG-11d, UT-14, UT-18, C-04, C-04x. UT-14 is the lead's call: Repair restarts the whole COS server.
- **Server parity**: KL-02, KL-13d, KL-14b must match the server's key-notices catalog or the helper refusal byte for byte (`Tests/key-lanes-pins.py`). KL-14a sits over KL-14b.
- **Pinned honesty caveats**: DI-23b, DI-23c ("does not reliably fix misheard words" is guarded by `mutate-mac-dictation-core.py:401`).
- **HQ**: TR-03, TR-05. The server's option labels and notes say HQ; a rename here would split the term inside one card.
- **Release flow**: H-05, H-06, G-05 have their own pins.
