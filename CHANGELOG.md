## 0.5.273 — 2026-10-08 — Guided setup and Activity Settings

- Open Settings inside Activity, using the same controls and saved state as the menu-bar panel.
- Includes the provider sign-in, Dock, permissions and resumable setup improvements from the onboarding candidates.
- Voice setup downloads the signed and notarized whisper.cpp runtime without Homebrew, preserves your existing tier, and benchmarks new Macs before recommending a tier.
- Pairs with server 6.66.0, including reliable Claude detection outside the interactive shell PATH.
- Smaller-Mac benchmark calibration and physical clean-Mac testing remain documented limitations; existing Max choices are preserved.

## 0.5.272 candidate — 2026-10-08 — Voice setup without Homebrew

- Download verified, Developer ID signed and notarized whisper.cpp 1.9.1 tools during voice setup using COS's bundled Node.
- Prepare Turbo, measure 30 seconds of speech on the device, recommend Balanced or Max, and preserve saved choices. The initial speed threshold remains provisional pending smaller-Mac testing.
- Retain onboarding P1 fixes; recover interrupted older voice setup, keep cancellation free of tier changes, and show low disk space before starting.
- Requires the matching server 6.66.0 candidate and versioned runtime asset. See `docs/qa/voice-runtime-2026-10-08.md` for acceptance gates and distribution status.

## 0.5.270 (build 323), test candidate

- **Permissions guide.** COS now walks you through each macOS permission instead of leaving a line of text. Allow opens the exact page in System Settings, and a small bar under the window holds COS Control's real icon: drag it into the list (or click + and choose COS Control). COS notices the grant within a second or two, says Allowed, and brings you back. The feature that asked, such as jumping to your session from the pet, then carries on by itself.
- **Where it shows up.** A new Permissions step in the Welcome window after Connect your AI (skip it with Not now). A Permissions line in the menu-bar panel that reads All set or 1 needs you and opens the list in place. And just in time: the first pet jump, a meeting starting with alerts off, the first Work notification, or a background job that macOS stopped.
- **Each row says what it unlocks** and shows Allowed, Needs you or Not needed yet: Accessibility, Notifications, Open at login, and on a Mac with the COS pipeline, background jobs (Full Disk Access for the Python and Node programs the jobs actually run, with Check now to confirm on a fresh run), Automation for Claude, Cursor, Terminal and iTerm (Test asks macOS), and Calendar for CalendarFetch.
- **Repair.** Already on but not working after an update? Reset and add again clears COS Control's old entry and opens the drag bar on a clean list. Clean up old COS test builds lists old COS builds found on this Mac and removes each one's Accessibility entry only when you click it.
- The drag bar adapts code from PermissionFlow by jaywcjlove (MIT, commit cb96db4b); the license ships in the app under Resources/ThirdParty.
- **Connect your AI.** The Welcome window now shows Claude, ChatGPT (Codex), Cursor and Ollama one row each: Not installed, Installed, not signed in, or Signed in. Each command has a Copy button. **Sign in** opens Terminal on the exact login for that AI (`claude auth login`; `codex login`, using the copy inside the ChatGPT app when that is the only one; `agent login`), and the row turns green by itself once you are signed in. If macOS stops COS Control from typing into Terminal, the command goes on the clipboard and Terminal opens for you to paste it. After 15 minutes the row stops checking and offers Check again. Not ready yet? **Skip for now** on each row. Get started still needs only one AI installed, as before.
- **Pass to Claude, ChatGPT or Cursor.** When one of those apps is on your Mac, a row can hand its setup to it: a new chat opens with COS's setup steps filled in, in an empty folder of its own, and nothing is sent until you press Send. The steps use only the official installers, never an administrator password, Homebrew or a global npm install, and never touch COS's token. COS checks the result itself.
- **A setup guide for everything COS can use.** Claude, ChatGPT and Cursor; Ollama (running or not, its models and the Local model setting); local voice; and the settings that go with them: Show your AI sessions, Continue agent threads, Jev (TypeSafe) and Permissions, plus a link to the glasses steps. Each row says what it unlocks, has one button, and **Skip for now**; skips are remembered and every row can be set up later. Nothing blocks using COS: Get started still needs only one AI installed.
- **Finish setup · 3 of 9** sits at the top of the menu-bar panel and of Activity, once COS has read your Mac, until every row is done or skipped, or you choose **Hide setup guide**. The guide is always one click away: the Dock icon's menu, the app menu and Help (Setup guide…), the panel (Setup guide), Activity, and the pet's right-click menu.
- **Local voice sets itself up in the app.** The voice row explains Balanced and Max in plain words, shows the download size and the free disk space first, then downloads the Whisper models inside COS Control with live progress and a Cancel button (what was downloaded is kept and resumes), and applies the tier with the usual safe restart. No Terminal step. It starts on the tier you already use, and Cancel or a failure never changes it. Local voice runs on whisper.cpp, which COS does not include: when it is missing, the row says so and gives the one Homebrew command. Run in Terminal and Guided Setup now run the same in-app setup, so they work on a Mac without npx.
- **Settings everywhere.** The pet's right-click menu adds Settings… and Setup guide… (Hide pet and the motion choices stay), and Activity has both too. Settings… opens the menu-bar panel at its settings when its icon is showing, and otherwise a Settings window with the same controls, so Show in menu bar only can always be undone.
- **"Not signed in" was not always true.** The panel said "Not signed in: claude" whenever the COS server could not run `claude --version`, which also happens when it was simply not found. It now says Not found, Not signed in (with the command that works on this Mac), or Installed, but the COS server could not run it.
- **COS Control is in the Dock.** Clicking its Dock icon, or switching to it with ⌘-Tab, opens Activity (or the Welcome window before setup); right-click it for Open Activity, Setup guide… and Settings…. Settings has **Show in menu bar only**; the menu-bar icon stays either way, and opening COS Control again from Finder opens Activity. If you used COS Control before, the panel says so once.
- **Meet the session pet.** One line explains the small character by your windows, with Keep, Calm and Hide, until you answer it. It does not show if you already changed a pet setting.
- For developers: a new read-only helper command, `provider-status --json` (`--only claude,codex`), reports each CLI's path, version and sign-in from its own status command (`claude auth status`, `codex login status`, `agent about`) and Ollama's model list, in the COS server's binary order. No server, no model turn, no login, and no email address in the answer. `provider-status` probes every provider at once under a 25-second deadline and answers with what it has. `voice-status` (read-only) and `voice-setup <balanced|max>` (the installed server's own `--setup-transcription --prepare-only`, run with COS Control's Node in its own process group so Cancel stops the downloads too; the three tier keys it writes to ~/.cos-glasses/.env are saved first and put back afterwards, even after a crash). Tests may no longer open an app, a link or Terminal (desktop-safety check).

## 0.5.269 (build 322)

- The Mac download opens again. Since 0.5.263, opening the downloaded zip with a double-click (Archive Utility) added three small files inside the app, and macOS then said COS Control "is damaged and can't be opened". The download is now packed so nothing is added when it is opened. Updates from inside COS Control were not affected.
- For developers: the release build refuses an archive that would do this.

## 0.5.268 (build 321)

- COS Control now finds Codex on a Mac that has only the ChatGPT app. The ChatGPT app moved its built-in Codex to a new folder on September 27, and COS Control still looked in the old Codex app, so Get started said "Connect an AI app first" even though Codex was installed. COS Control now looks in the same places as the COS server, in the same order, including a ChatGPT app installed in your own Applications folder.
- The server COS Control starts can find that Codex too.

## 0.5.267 (build 320)

- Jump to session can again ask Claude, Cursor or Terminal to reopen and come to the front, like clicking it in the Dock. The notarized 0.5.266 was signed without permission to send Apple Events, so macOS blocked those requests without asking. This build carries that permission and says why it needs it; macOS asks once for each app, the first time you jump to it.
- Guided Setup can open Terminal again, for the same reason.
- Speaker ID now works on Macs that use COS Control's built-in Node. That Node could not load the speaker-ID add-on (or any other npm native add-on), so new Macs set up from the app lost speaker identification. Only the built-in Node gets this permission; it already runs the server's own scripts, and native add-ons need it.
- If Jump to session needs Accessibility while System Settings already shows COS Control turned on, Settings > Session pet now has **Reset and add again**. It removes COS Control's old entry, asks macOS again and opens the list so you can turn the new entry on. This replaces the advice to toggle it off and on.
- A Cursor chat that cannot be found now says what to do instead of showing diagnostic codes.
- For developers: every test compile runs one at a time through a memory guard that scales with the Mac, and the largest test file compiles in about 3 GB instead of 39 GB.

## 0.5.266 (build 319)

- Apply the GOTCOS checkbox style to Include completed tasks and center task-row selection icons in the meeting-to-task picker. Includes the 0.5.265 meeting linking and prior onboarding improvements.
- Replaces the unpublished 0.5.265 candidate after release QA found the unthemed toggle.

## 0.5.265 (build 318)

- Meetings and Speakers now offer **Link to existing task**. Search across domains, optionally include completed work, choose a task and explicitly link it without creating a duplicate.
- Reuses canonical saved-meeting references and the revision-guarded Work writer. Existing task identity, text, status and prior meeting links are preserved. Linked references and meeting files participate in the next Work handoff; a running agent is not messaged automatically.
- Already-linked, incomplete-reference, missing-revision, read-only and full-link cases explain why a link cannot be added. Refresh failures and stale-write refusals stay visible.
- Speakers resolves the saved meeting using the existing exact-record resolver, stays in Speakers while the picker is open, and ignores a lookup if the review changes before it finishes.
- Includes 0.5.264 recovery and 0.5.263 Cloud Puff/onboarding work. Notarized candidate, superseded before publication by 0.5.266; prior archives remain frozen.

## 0.5.264 (build 317)

- Open in platform shows progress and persistent recovery instructions in the Sessions pane, including missing Claude Desktop, archived sessions, unavailable transcripts and helper failures. Repeated clicks cannot launch overlapping opens.
- Waiting follow-ups show their recorded hold reason. Queue copy no longer promises delivery merely because a turn ends.
- Keeps bundled runtime onboarding, Developer ID release signing and the Cloud Puff default from 0.5.263. Chris’s specific stalled-send cause still requires his installed versions and refusal evidence; these changes do not bypass session ownership or resend uncertain turns.

## 0.5.263 (build 316)

- New installations start with Cloud Puff, bundled for offline first launch. Existing pet choices remain intact. Use Cloud Puff restores the default; the COS robot and animated characters remain available.

## 0.5.262 (build 315)

- New installations start with the simple built-in COS robot. Existing chosen sprites and stock character upgrades remain intact; Miles Windu stays optional in Characters.

## 0.5.261 (build 314)

- Bundle a verified private Node runtime so first-run server setup needs no Homebrew, Node, npm, or npx installation.
- Add a persistent welcome window with provider guidance, automatic server setup, retry, and deferred notification consent.
- Sign public builds with Developer ID, notarize and staple them, then verify the extracted download with Gatekeeper.
- Retain the 0.5.260 task-editor performance, branding, draft protection, and atomic save fixes.

## 0.5.260 (build 313) · Task editing

- Task-name and finish-line drafts live in the editor, so typing no longer invalidates the full Activity window and Work board.
- The editor uses GOTCOS typography, warm surfaces, themed fields, and a gold Save changes button that stays visible. Task details show the Work stage. Secondary actions are grouped under More task actions.
- One revision-guarded Save changes action writes the task name and finish line together. Background refreshes keep the draft and original revision; errors leave the draft open.
- Refresh availability checks the configured task bridge without discarding or rebasing the draft. Repair advice distinguishes missing bridge support from invalid task metadata.
- Macs using the full COS Python bridge also need its task-edit-work command and editTasks capability. The server’s bundled portable bridge already supports both; updating the npm server alone does not update a separately configured COS checkout.

## 0.5.259 (build 312) · Activity and Work search

- **Open meeting from Speakers.** A meeting's speaker review has an Open meeting button. It opens that meeting in Meetings, with its transcript, summary and files, and Back returns to the review. A merged meeting opens as the merged record, which is the row Meetings lists. A meeting the loaded month does not show is looked up by its own day, so a meeting from any day opens and the Meetings list stays on its month. When the lookup fails, the review says "Couldn't load this meeting" with the reason. It says the meeting isn't in the list only when every day it could be on was read in full.
- **Nameless drops on a meeting get a time.** A screenshot or file dropped on a meeting without a name of its own is named for when it was dropped, like a paste: "Dropped screenshot 2026-10-06 at 22.56.12.png". Several in one drop are numbered (1), (2). Before, every one read "Dropped file.png". Drops on a Work card keep "Dropped file", because that is the name its suggestions replace.
- **Needs you.** A line above the Activity cards lists what waits on you.
  - Sessions come first. A known question, permission request or plan approval has a filled dot and words that name the request. A failed session says "stopped with an error". A wait inferred by the helper says "quiet, may need you" with an open dot. Working sessions with live subagents stay working. At most three sessions show in full; the rest open through "+N sessions". Each group is oldest first.
  - The backlog follows as one short segment: "Also · 1 voice to name · 3 memories · 7 work items". The cards below name the meeting and say the rest.
  - Next ⌘] opens the first item, then advances and wraps on subsequent visits, so a blocked session opens before any backlog. With one item the button reads Open. In a Speakers review ⌘] is still Next to name; the two never share a screen.
  - A source Control has not loaded is left out, never shown as 0. Only after every enabled source answers does the line say "Nothing is waiting on you." Memories opens To review, and Work opens what needs attention.
- **Live cards.** Each Activity card has one lead line, amber when it waits on you, up to two sub lines, and a footer that says what its number counts. The descriptions moved to help text and the caps captions are gone. Work's number is what needs attention. Memories counts kept memories; its lead says how many await review.
- **Desks.** The Sessions card shows a mark for each session that is working, waiting on you, quiet, or finished today, with its provider's mark: as many as fit on one fixed-height row, up to 12, then "+N". Working desks glow slowly and hold still under Reduce Motion. Hover shows the title, state and age; a click opens the session. No new sound.
- **Activity opens faster.** Opening Activity also loads Work's board, meeting reviews, Intake and the Memories review list, after the home has drawn. With the pet off, sessions refresh each minute while Home is visible. Session times are read once per session, which cut a pass over 80 sessions from about 18 ms to under 1 ms.
- **Find a card.** Search the Work board you are on ("Search this board"; All work: "Search work"). Title and word matches show as you type: every word in the title, or any word in the task, its source, its meetings or its files. Words match from their start, so "launch" finds "launches" and "ads" never finds "leads".
- **By meaning.** From three characters, 400 ms after you stop typing, COS asks the server's Jev search once. A card Jev rates 0.15 or more is a "Similar meaning" match; anything lower is left out. An answer for an older search is dropped, and typing never waits for it. Needs server 6.65.0; with an older server the board searches by title and words and says so in one line. While waiting it says "Searching by meaning…". Missing keys, rejected requests, budgets, pauses and temporary failures get an explanation. Temporary failures allow another request. The server sends task text to TypeSafe after removing URLs, emails and secret-like strings. All work searches open cards by meaning; completed cards still match words. Focus uses the same word matching and ⌘F, without meaning search.
- **Best matches.** Up to three rows above the columns, Jev's most likely first, each with its stage, the found words underlined, and why it matched. "N matches", the board's "N of M tasks" and the columns' counts always agree, and "2 more in Personal" opens All work. ⌘F searches, Esc clears before going back, ↓ ↑ walk the matches and Return opens one.
- **Order.** Board order (default), Recent activity, Newest or Oldest, within every column and remembered per board. Date ordering adds one line: "active 2 h ago", "dated Oct 6", "first seen Oct 6" or "No date". Dated means the meeting or source day; first seen means the day the task line appeared in git. Undated cards go last. Recent activity uses the newest stage move, Work session, added file, committed line change or source day. A committed line change appears when the task file is next committed. Dates are computed once per data change, and labels allocate no formatter. Nothing is written into tasks.md.
- **Helper.** A new `work-search` command, its search switch and token cap survive Update Server, and Work rows carry `createdOn`, `createdFrom` and `lineChangedAt`.

## 0.5.258 (build 311) — Files on a meeting

Drop screenshots, slides, PDFs and other files onto a meeting, and every Work card linked to that meeting sends them to its agent after the card's own files. Needs server 6.64.0. With an older server the meeting says to update the server.

- **Where.** A meeting's detail has a Files box: drop, Add files… or Paste screenshot. Click the box, then ⌘V also pastes there, and search fields keep their own paste. A meeting row shows a paperclip and a count. Copy as context adds the files' paths, with the same checks a send applies.
- **Files stay on this Mac.** COS keeps copies in `~/cos-data/meeting-context` with the same rules as card files: snapshots, secret refusals, 20 files and 2 GB, and Remove hides with Undo. Nothing is written into the meeting itself. The key is the meeting's own G2 session or Fireflies id, from the server. A merged meeting whose file declares the captures it holds also shows those captures' files.
- **Words read on this Mac (Phase 2).** Each image gets a text copy that macOS Vision reads on device, at no cost, and the handoff names it, so Codex and Cursor get a slide's words. Nothing is embedded or uploaded.
  - The check fails closed. An image goes only once its words were read and none looks like a password or key, or once it had no words.
  - An image still being read waits for a later send. So does one whose reading failed.
  - A screenshot that reads like a credential stays on the meeting, marked "Not sent". The check covers:
    - `KEY=value` lines, also behind an editor's gutter;
    - settings labels such as "API Key: …";
    - a label and its value read as two lines;
    - PEM keys, JWTs and bearer tokens;
    - Google, Stripe, Slack, GitHub and OpenAI-style keys.
  - The whole of an image's text is checked.
  - The text-file rules' own false alarms also apply here. A slide line like "Token: ERC-20" keeps that image out of sends.
- **Into linked cards (one block).** The card's files come first, then each meeting's under "From meeting: <title> (<date>)", all in the same Context files block, so Cursor's cut keeps every path as before.
  - When a send runs out of room (the 20-file cap, the draft limit or Cursor's link), meeting files are dropped first. The timeline names each file left out. They never stop a send or the Start countdown.
  - A Continue does not resend meeting files this card already sent to that session.
  - The Agent workspace lists them under "From linked meetings". Its preview does not apply the send's length limits, so a Cursor send can leave out a file the preview listed. The timeline says which.
- **Whichever record id the card links.** A meeting's record id changes when sync files a capture, when the pipeline renames it, and when it moves domains. Control finds the meeting's files anyway:
  - Before a send, it asks the server (new read-only route) about each of the card's meeting links.
  - When Work loads, and after a drop, it asks about links it has no answer for yet.
  - It asks only once some meeting holds a file. The answers are kept on disk.
  - A card's task metadata is unchanged.
- **Two meetings claiming one recording** (a duplicate in two domains): files can't be added or removed there. A send then gets no files through that meeting's links. The exception is files dropped before the duplicate appeared: they keep going with cards linked to the meeting they were dropped on.
- **Retention.** Removed files leave in two ways. A removed file that no session was ever sent is deleted 14 days later, the next time Work cleans up. A removed file a session was sent stays. A meeting folder is never deleted.
- **Not in this release:**
  - the drop target on a meeting row (only the meeting's Files box takes drops);
  - files on a meeting merged in Control's own merge (its record has no key yet);
  - the `meeting_context.py` command and the meeting-cleanup report, which come with the COS scripts update.

## 0.5.257 (build 310)

Forks run in the background with server 6.63.0. Fork sends the card's receipt id with the request; the server answers at once, and the card shows the fork as running, naming no session until the copy exists. Check status and the background tracker read the outcome by that id and land it exactly where a direct answer would have: the copy linked, a failed first turn opening its copy, or a refusal with its reason. A fork the server has no record of stays unconfirmed, and an answer this build does not recognise changes nothing. Check status is offered on fork receipts again. With an older server the fork answers when it is done, as in 0.5.256.

Memories now remembers a prune after a reload: a quarantined memory is labelled Quarantined and offers Restore to recall, and To review lists Prune ready memories with the reason, Accept or Prune, and a confirmed Quarantine all.

## 0.5.256 (build 308) — Work loop candidate

Unreleased candidate. Native usability and physical G2 acceptance are outstanding.

Today separates new intake and Mentioned cards from Catch up. Keep/Drop decisions persist immediately; meeting-wide dismissals use one batch. Your move preserves reviewed questions until answered or explicitly cleared, and appears on Home, Work and the menu bar. Waiting on includes check-in, Done, Still waiting, Drop and Restore. Expiry is off by default, protects your own and unknown-owner items, and offers weekly counts and Restore.

Sessions offer explicit card association when the match is sufficiently distinct. Linking never sends a prompt. Canonical task changes and local observations support the new metrics report. Fork/Continue recovery preserves failed child identity, warns for app-owned Continue and refuses oversized headless turns without queue retries. A summary can be edited before starting fresh.

A fork whose copy was made but could not answer (server 6.62.1 `turnFailed`) links the copy, so Open session opens it, never the original. Any other refused fork clears the session link. Usage-limit, too-long and sign-in failures from the server have their own copy, and fork receipts no longer offer Check status, which had nothing to read.

A fork with no answer after 5 minutes now says the copy may still be in progress (the server allows 21 minutes), instead of "Server stopped". The Work intake expiry setting shows only when the server answers, uses the COS switch, and no longer shows a shared Work error in Settings.

This candidate includes the 0.5.255 hardening fixes below. It does not qualify a public rollout until the release acceptance checklist passes.

## 0.5.255 (build 305)

Local hardening candidate. Stable promotion still requires native UI and G2 acceptance.

Task names and finish lines save together through the exact task revision guard. File-derived name/finish proposals use the same transaction. The task editor retains its draft on refusal.

Merged meeting review keeps the selected record and recording through loading, rejects mismatched content, and sends the viewed source revision with corrections. Saving, stale-source and read-only conflicts have separate recovery states.

Review rendering uses exact document content for its cache. Pending layout changes cancel when a resize reverses. Review-name writes report persistence failures and refresh the board/search projection. Handoff prompt saves bind to the original source revision, flush before sending, and preserve stale drafts for explicit recovery. Starting fresh records the earlier delivery as unconfirmed.

The integrated Work QA candidate uses disposable tasks and a separate journal; provider dispatch is disabled.

## 0.5.254 (build 304)

An unconfirmed handoff can start a new session. That clears the block and does not send the old instruction. Open full session brings forward the Claude, Codex, or Cursor tab.

## 0.5.254 (build 303)

Open session on a Work handoff brings forward the Claude, Codex, or Cursor tab that receipt names. The Work card stays put.

## 0.5.254 (build 302)

A finished meeting review lays out the paragraphs on screen, not the whole writeup, and the page is not rebuilt while the window is still being dragged. Click the review title to rename it. That name is the subject of the work you send.

## 0.5.254 (build 301)

A file dropped on a card can offer a due date, a finish line, and a clearer name. Nothing is written until Apply. Dismiss keeps the file. The handoff still sends the file path only, and a card is not moved.

## 0.5.254 (build 300)

Open card and Claude stays available after the live session check goes stale, because the handoff receipt still names the provider and the session. A session the COS server is still writing is not opened in the app. The card stays on Work.

## 0.5.254 (build 299)

A session in Sessions working now opens its card and the Claude, Codex, or Cursor session together. The task on that session is a board card: its menu moves it, and a drag lands on a column. Complete still asks first when the drag is onto Complete.

## 0.5.254 (build 298)

Drop a Work card anywhere in a column. The header, the empty list, and another card in that column all take the move. A file dropped on a card still goes on that card, and the next one does too: a file drop does not use the one-drop claim. Dropping on Complete still asks first. The first place that takes a card move is the only one that runs, and the column stays lit while any of those places is still under the pointer. Typing in Context to send waits a third of a second before it writes the journal, and search waits before it filters the board. Resizing a task page rebuilds the text field only when the width crosses 760 or 1,100. Installed over build 296 for a morning test. Build 296 is the rollback in Application Support.

## 0.5.254 (build 296)

Drop files on a Work card, and their paths go out with the work. COS Control only: no server release. Works with server 6.59.0. Build 296 is QA rounds 1 and 2 and a faster Work resize on build 293, which was installed for review only. Build 295, a local trial of the resize, is replaced and its number is not reused.

- **Files on a card** (Miles, 2026-09-30 21:13: "build out a card ... drag-and-drop ... PDFs, JPEGs, HEICs, PNGs, MP4s ... Really, all it's doing is passing the path of the card."). Drop files on a card on the board, or use Add files… in the card's Agent workspace. COS Control keeps a copy of each in `~/cos-data/work-context`, one folder per card, so moving or deleting the original changes nothing. A copy is a clone on the same disk (no extra space) or a plain copy, readable only by you. The card's footer shows a paperclip and the count, plus "1 preparing" while a copy is still being made. A card with no files looks as it did.
  - Finder files, files from Photos, Mail, Messages and the screenshot thumbnail, and images dragged from a browser are kept. A link dragged from a browser is kept as a link, not downloaded. A link with a username or password in it is refused ("Not added: this link has a username or password in it. Copy the link without them."). A folder is never copied: it goes as a link marked "may change", with its file count.
  - Before a card's first file is saved, COS writes the card's identity on its task (the same Work write a stage change makes), so renaming the card later, even outside COS, keeps its files with it. If that write fails, nothing is added and the card says so.
  - An iCloud file that is not on the Mac yet is downloaded first, for up to a minute.
  - A file's type is read from its own bytes, never its name. Copies are named `NN-name.ext` in plain letters and digits, so a file's name never reaches a prompt.
- **What a card won't take, and says so** (in the reviewed mock's words): secrets files, by name (.env and anything ending .env, .pem, .key, .p12, .pfx, .ppk, .kdbx, id_rsa, id_ed25519, keychains, .cos-profile.json, credentials, .npmrc, .netrc, .pypirc, .pgpass, .git-credentials, a Docker login), by what is in them (a private key, a KEY=value line naming a token, secret, password or API, access or private key, an AWS credentials block, an npm token, a netrc password), and through an alias by the file it points to; more than 20 files or 2 GB on a card; apps, disk images, installers and programs; the same file twice; an iCloud file that does not download within a minute. The reason shows on the card, then fades, and nothing is half-added. A Keynote deck (.key) is not taken for a key.
  - Folders: the whole disk, /Users, your home folder, its Library and system folders are too wide, and .ssh, .gnupg, .aws and Keychains (or a link to one) are secrets. A folder with a secret in its top two levels is refused by name: "Not added: this folder holds secrets (sub/settings.txt). Add the files you need one by one."
- **Copies an agent can read**: a HEIC gets a JPEG, an image over 2,048 pixels a 2,048-pixel copy, a PDF or Word file a text copy, and a video (MP4, MOV, M4V) up to 12 frames at 1,280 pixels. They are made in the background and listed under the file. One a relaunch interrupted starts again once, then is marked failed: none stays at preparing. When one can't be made (a scanned PDF has no text), the file stays Ready and goes as it is, with a quiet note ("No text copy (a scan).", "Couldn't convert the photo."), and it does not stop a start.
- **In the handoff**: every send (New session, Continue, Fork, Cursor filled in, the note for a session its app owns, and work the glasses start) carries one block that lists each file's path and what it is, after your context and before the COS-WORK status line, never first. The Agent workspace shows that block under What gets sent with the files, and the handoff records which files went.
  - Continue and Fork send only the files that session has not had, with Send all again.
  - Cursor's link keeps every path: a long handoff is cut in the context, never in the file list. A file list too long for Cursor's link is refused before anything is sent, and says what to do.
  - A local model can't open files. The Agent workspace and the Start sheet say so, and the countdown stops for you to choose.
- **Start sheet**: "With 4 files, 14.6 MB", and Show lists them. The countdown waits while a copy is still being made. A local model, a copy that is gone or a folder that is gone stops it, and the button reads Send anyway. Start now while copies are still being made sends what is ready, and the handoff's timeline says what was not.
- **Dragging on the board**: a card now drags as COS Control's own type. Columns and Start work take only cards, and a card takes only files. A file dropped on Start work or a column says "Files go on a card. Drop it on the card you want it sent with." when it is let go (not while it passes over), and nothing else happens: a drop never sends.
- **Remove and cleanup**: Remove hides a file at once, with Undo in its place. A file any handoff carried stays on disk until its card's folder goes; one never sent is deleted by the first cleanup at least an hour later. A card's folder is deleted only 14 days after the latest of: the card being complete, its newest file, and its newest handoff, and never while a handoff of it is sending, queued, running or unresolved. A card that leaves the board (renamed outside COS, say) keeps its files. COS deletes and writes only inside its own folder for the card: a name it did not write, or a folder or file that is a link, is never touched. The preview never cleans anything.
- **Deferred**: video transcripts and route B (server image inputs through `attachmentIds` and Claude `--add-dir`) are not included in 0.5.255. The earlier version promise is withdrawn; neither feature is available yet.
- **Tests**: `Tests/run-work-card-files.sh` runs the rules against real files it makes (a PNG, a large PNG, a HEIC, a 3-page PDF, a 3-second MP4, a Word file) under a home whose path has a space, a dot and a non-ASCII letter, and `Tests/work-card-files-pins.py` pins the wiring the views hide. No test drags, clicks or opens a panel: drops are tested by calling the intake with URLs and item providers, and the desktop check now also refuses a file panel or Quick Look in any test.
  - Mutation lane (`Tests/mutate-card-files.py`, by hand), from a green baseline: 28 of 28 mutants killed, each by a check that names what it broke (secret refusal, cap, duplicate, block placement, Cursor protection, delta, cleanup references, the private card type, the countdown, the iCloud timeout, nothing half-added, the name cleaner, a copy interrupted twice). The first run left one alive: a read granted after the iCloud deadline was never tested, because the deadline cancels the read first. A check now holds the read past the deadline and grants it, and nothing is copied.
  - QA round 1 (build 294): the lane grew to 55 mutants, one for each new guard (a name COS does not write, a path outside the card's folder, a linked folder or file, a link with a password, secrets by name, content and alias, folders too wide or holding secrets, the identity written first, the cleanup clock, a card in flight, Remove that only hides, the board line on drop, a failed companion, a second card's folder). 55 of 55 killed. The one that first survived (an alias's real name checked only after the copy) showed that a secret behind an alias was read before it was refused; a check now refuses it without reading it.
- **QA round 2** (2026-10-01):
  - `.env.example`, `.env.sample` and `.env.template` are taken, since they hold placeholders. In any file, a value that is a placeholder or a reference (`${DB_PASSWORD}`, `$1`, `<your key>`, `YOUR_API_KEY`, `xxx`, `changeme`, `os.environ[...]`, `process.env.X`) is no longer taken for a secret.
  - Real values now caught: OpenAI and Stripe keys (`sk-`, `sk_live_`), AWS key ids (`AKIA…`), a password inside a link (`postgres://user:pass@host`), and credential values in JSON and YAML (`"password": "…"`, `password: …`). A UTF-16 file, as Windows writes a `.env`, is read as text and checked the same way. It was read as audio before.
  - A folder is checked four levels deep. One with more than 2,000 entries is refused: "Not added: this folder is too big to check for secrets. Add the files you need one by one." Documents, Desktop and Downloads themselves are too wide.
  - The card's identity is written beside the copy, not before it, so a file starts copying at once. If that write fails, or the board is read-only, the file is added anyway with a quiet note: "This card's identity isn't saved, so rename it only in COS."
  - Undo never makes a second copy of a file already on the card, and keeps to the card's 20 files.
  - The lane grew to 73 mutants: 73 of 73 killed. The one that first lived, a placeholder marked only by angle brackets, had no check of its own; it has one now.
- **Resizing Work** (Miles, 2026-10-01 08:44: "changing the size of the window (Resizing) is laging so badily ... Is there something we can do to polish up that experience."):
  - The board's rows were rebuilt from scratch on every read, 27 times on each step of a resize. Now they are built once when the tasks, handoffs, session check or reviews change, and never while the window is dragged.
  - Nothing around the Work view re-runs it on a resize. The session row keeps how many cards fit beside Start work, not its width.
  - A session check that finds the same sessions, every 15 seconds, rebuilds nothing.
  - The Activity window keeps its own size limits, 760 x 560 at the least and no maximum, as before, instead of measuring every tab for them on each layout pass. That was about half of what each resize step still cost. Every tab (Messages, Speakers, Meetings, Memories, Threads, Sessions, Work and home) draws exactly as before at 760 x 560, 1280 and 1800 pt, light and dark.
  - On a 268-task board, one 10 pt step of a resize took about 550 ms before and 12 to 17 ms after (median; at p95, about 565 ms and 24 to 32 ms), measured off screen with `Tests/run-work-board-perf.sh` while the Mac was transcribing a meeting. The board looks the same: drawn before and after at 1280, 1800 and 820 pt, light and dark, every pixel matches.
  - A build whose board is rebuilt while the window resizes is not released: `Tests/run.sh` and the release script count it, never time it. Over a 700 pt sweep the rows are rebuilt 0 times and the board drawn at most 3 times, and a stage move, a handoff, a session check or a review during a sweep rebuilds them exactly once. Putting back the old computed rows, or a GeometryReader around the board, fails it.
  - Tests: `Tests/WorkBoardCacheChecks.swift` changes each source the way the app does (a stage move, a handoff added or changed, a session check, a review, the preview) and requires the board to follow, and an unchanged board not to rebuild. Its mutation lane (`Tests/mutate-work-board-cache.py`, by hand), from a green baseline: 29 of 29 mutants killed, each by a check that names what it broke (each source's change, each part of the key, the memo, the filter, the session cards, the row capacity). The first run left two alive: a preview stage move made right after a task change, with no read between, rode on the task change's rebuild. The check now reads the board between them. `Tests/run-activity-sizing.sh check` holds the window to what each tab needs and to 760 x 560; taking away the pinned minimum, letting the window accept a smaller one, or turning the size tracking back on fails it.

## 0.5.253 (build 292)

Icons sit in the middle of their words, Cursor opens its own window with the work filled in for you to send, the QA notes deferred from 0.5.252 are fixed, and no test clicks, types or puts a window on screen any more. Works with server 6.59.0.

- **Icons in the middle of their words** (Miles, 2026-09-30 16:51, with screenshots: "Center the refresh icon on Check for updates." and "There are several places where that same top vertical alignment is happening."). A label lined its icon up with the first line of its words, so one that wraps, such as Check for updates in the updates card and Create Folders in the menu-bar panel, showed its icon at the top: 8.5 pt above the middle, measured on the rendered panel. One label style now puts the icon in the middle of the whole text block, with the same 8 pt gap as before, so no button changes width or wraps differently, and wrapped words stay aligned to the left. Every COS button style uses it (a menu's face is one), the dropdown's face and rows center theirs, and each window root sets it for every other label.
  - Ten rows that put an icon beside words that can wrap, aligned to the top or to the first line, center it now too: the info and clock notes in Activity, the Doctor checks, the notice and update-available banners, a voice's quoted lines, and the Jev suggestion rows in Start work. A list bullet set on its first line and the checkbox (which, as the stock one does, sits by the first line of its words) stay as they were.
- **Cursor: filled in, for you to send** (Miles, 2026-09-30 13:27: "it's a fragile path. If it just passes to the platform and opens the window so I can submit that is sufficient for now if we can't auto create the thread like Claude and Codex"). A New session or a Continue on Cursor runs nothing in the background and opens nothing in Terminal. COS Control opens Cursor's own window with the handoff filled in (Cursor's prompt link, as 0.5.248 did): choose Create Chat, then press Send there. Claude and Codex keep start-then-open.
  - Cursor's link cannot name an existing chat, so a Continue opens a new Cursor chat with your note.
  - The text starts with a line naming the task ("COS Work handoff" and its id). Once you send it, Work finds that chat by that line (Cursor's chats made since it opened, exactly one, never a guess), marks it sent and follows it as any handoff: Received moves the card to Draft, its done line to QA.
  - Cursor takes about 9,000 characters from a link and drops a longer one without a word. Past 8,500 the handoff is cut, keeps its first line and its status line, and says it was cut. The whole handoff goes on the clipboard, and the card says so: paste it over the text there before you send.
  - Until it is sent the card offers Open again (the same words) and Not sending it. Cursor's link picks no model, so Cursor uses its own.
  - A Cursor run 0.5.249 to 0.5.252 started, still waiting to open in Terminal, reads as not opened, with its reply in Work.
  - Nobody at the Mac can press Send for the glasses, so a glasses request whose destination is Cursor (a New session on a Cursor model, a Continue or a reply into a Cursor chat) is refused before anything is recorded: "Cursor needs you at the Mac to press send. Start it from COS Control."
  - The Agent workspace and Settings say how Cursor opens.
  - Removed with the Terminal route: the helper's Cursor chat finder (`work-cursor-chat`) and the Terminal command file. Kept: the Accessibility steps (the Cursor search field and the typed name) that the pet's and Sessions' Open in platform use to find an existing Cursor chat. Work's route never used them, and those two callers still do.
- **From 0.5.252's QA** (deferred):
  - Results are posted one pass at a time. A pass and a send that just finished could post one result twice.
  - The results ledger is shared by every COS Control on this Mac: read, changed and written under one lock, and each write reaches the disk (fsync of the file and its folder) before the lock is let go. Each launch signs the claims it holds and posts only its own; what a launch that is gone left is taken over by the next to read the ledger. A change the lock keeps out waits in memory for the next pass.
  - The token of a claim made again goes to the helper on its standard input, never on its command line, where any process on the Mac can read it. The helper refuses it there, and never logs it.
  - A result the server answered with 401 or 403 is posted again with the growing wait, not dropped.
  - An open dropdown whose options change (a model catalog or a session list refreshed meanwhile) shows the new ones at once, and its keys and clicks choose from them.
  - The board a glasses request is checked against is a read that began after the request was claimed, and read the board. An older read that failed, or one a newer read superseded, never reads as fine because a newer one ran.
  - Open in Claude (or Codex) while a glasses send holds Work's history records its opened note: in that window at once, and on disk as soon as the history is free (when the send lets go, or on the next tracker pass).
  - 0.5.252's notes said the inbox lists "every 5 seconds while it has one in hand". It lists every 30 seconds throughout; the next list comes 5 seconds after it takes a request, at once when a send finishes, and within 5 seconds when a result is due to be posted again. The 0.5.252 entry says so now.
- **Tests no longer click** (Miles, 2026-09-30 19:28: "I really just want to remove the test click effect that was creating the noise."). No test sends a synthetic mouse, key or scroll event, orders a window in (not even far off screen), activates an app or plays a sound. The app itself is unchanged by this: Open in platform and its Accessibility steps are exactly as in 0.5.252.
  - The controls contract checks behaviour through the rules the controls run on (the dropdown's keys, highlight, choice, list width and placement, reopening, and an open list whose options change; the view switch's and stepper's steps), and looks on still drawings of views in windows that are never ordered in (switch, checkbox, spinner, the root theme, the open list's card, icon labels and the menu-bar panel). What it can no longer check by doing it (the open list's child panel and its dismissals, focus with Keyboard navigation on, where a tap lands on a switch) is pinned by source in `Tests/run.sh`.
  - The panel, Markdown, held naming, pet composer and merge renders draw without ordering a window in. The Jedi canary that opened a window and took the focus, and the dropdown canary that posted clicks and keys into a real menu-bar panel, are gone.
  - `Tests/desktop-safety-check.py` now fails on any test that sends or makes an event, orders a window in, activates an app or plays a sound, with no opt-in or off-screen exemption; its self-test proves 24 such forms fail and 5 allowed ones pass. `Tests/run.sh` and the release script run it first.
- **Tests:**
  - Labels (`Tests/run-controls.sh`): under the quiet, primary and text button styles and the menu face (none of them under the window root's theme), a plain button and a bare Label under it, the icon's middle is the words' middle within 1 pt on one line and on two, the gap is the system's 8 pt, and a label is as wide and wraps where the system's own style would have it (which, the same board shows, still tops the icon). The real menu-bar panel, drawn in light and dark with the build's version and legacy scroll bars: Check for updates and Create Folders wrap to two lines there and their icons are 0 and 0.5 pt from their text block's middle (8.5 pt before), Work Folder and Run Doctor (one line) 0 and 0.25 pt. Before and after drawings of the updates card and the buttons grid were saved for review.
  - `Tests/label-alignment-guard.py` fails when a Sources file puts an icon first in an HStack aligned to the top or a text baseline, or sets the system's label style; its self-test proves 5 banned forms fail and 5 allowed ones pass, and it failed on the 0.5.252 tree at the ten rows this build fixes.
  - Work (`Tests/run-work-progress.sh`): Cursor filled in for a New session and a Continue (no background run, no server turn, the link character by character, its first line), a cut handoff (8,500 characters, never through a character, the whole on the clipboard, the card's words), Open again, Not sending it, a refused open, the chat found once sent (none, two, one older than the handoff), followed to QA by its untimed done line, a 0.5.252 Cursor run waiting for Terminal; a glasses Start, Continue and reply on Cursor refused with nothing recorded or opened; results posted once for two passes at once; two running launches sharing the ledger (each posts only its own, the other's kept on disk, a change held while the lock is taken, a gone launch's claim taken over); the claim token never on any command line; 401 and 403 posted again; the board read rule; Open in Claude while a glasses send holds the journal, and while another COS Control does.
  - Helper: `self-test-work` (62 checks; the re-claim token read from stdin only), `Tests/work-requests-helper-checks.py` (a re-claim on stdin, a token on the command line refused, a malformed one refused, nothing reaching the server), `Tests/work-progress-helper-checks.py` (the Cursor chat finder is gone).
- **Gates**, one suite at a time, with nothing activated, ordered in, clicked or sounded: the desktop-safety check and its self-test (24 desktop-touching or UI-driving forms fail, 5 allowed ones pass); `Tests/run-work.sh`, `Tests/run-work-progress.sh` and `Tests/run-work-handoff.sh`; the helper's `self-test` (774) and `self-test-work` (62) and both helper check scripts; then `Tests/run.sh`, exit 0 in about 12 minutes.
- **Mutation gate**, logic lanes, from a green baseline, each change applied exactly once and each kill named by the check that caught it: 42 of 42 killed. Label guard 6 of 6, desktop-safety check 6 of 6, helper 3 of 3, Work 25 of 25 (the Cursor route, the glasses refusal and the 0.5.252 QA fixes), and the open list's source pins 2 of 2. The render lane is not in this round: its first run killed 5 of 8, the three that lived (button styles the window root's theme was masking) led to drawing those rows outside the root theme, and it was stopped before it ran again when the test-click change came in.
- **Not verified here:** a live Cursor send (the prompt link and its dialog were canaried with Cursor 3.22.12 on 2026-09-29; finding the sent chat was checked against fixtures in the helper's shapes), a live glasses request, and the menu-bar panel in a real MenuBarExtra (it was drawn off screen, never shown).

## 0.5.252 (build 291)

Work you start from the glasses runs on this Mac. Start work, Reply by voice and Not done yet on the glasses leave a request on the COS server; COS Control picks it up, sends it exactly as the Agent workspace would, and tells the glasses what happened. Includes 0.5.251 (never installed on its own) and the fixes from its QA round. Needs server 6.59.0 (released, npm latest) for requests; with an older server nothing changes and nothing is shown. Build 291: the build 290 zip was never installed and is superseded.

- Miles approved the scope on 2026-09-30 (Work on the glasses: server 6.59.0, glasses 6.9.561, this build), with the request contract as revised that morning (versions 2 and 3), and decided the same day that a New session started from the glasses stays in the background.
- **Listening.** COS Control lists the server's pending requests every 30 seconds for as long as it runs, with Activity open or closed. The next list comes 5 seconds after it takes a request, at once when a send finishes, and within 5 seconds when a result is due to be posted again (corrected in 0.5.253: these notes first said every 5 seconds while it had one in hand). The list is how the server knows COS Control is taking requests, so it keeps its rhythm while a request is being sent: each send runs in its own task. An older server has no inbox: COS Control stops asking, with no message, until the server's version changes or ten minutes pass.
- **Claimed once, sent once.** A request is claimed (one claim wins; an expired request is never claimed), and one this Mac already sent is never sent again: before sending, COS Control reads the journal again from disk, so a request another launch sent is found and its result reported instead.
- **Checked again on this Mac.** Before anything is sent, COS Control reads the task's row again and checks the task's own revision, reads its live sessions and model catalog, and resolves the destination itself (the glasses' choice, and where it came from, are hints). A running Claude session that this Mac lists by its first 8 characters is the session the glasses named in full. Refused with the reason, and nothing sent:
  - a task that is gone, complete (checked, or in the Complete column) or changed since the glasses read it;
  - a board, or a sessions and models list, that could not be read just now ("COS Control could not read the board just now. Nothing was sent.", and the same for its sessions and models): an unreadable list is never taken for an empty one, and never for an earlier one;
  - a session not on this Mac, or a model the request names that is not in this Mac's catalog, for a New session and for a Fork (a Fork to the other platform whose model is missing is never turned into a copy on the session's own platform);
  - a request type this build does not know ("COS Control does not know this request type. Nothing was sent."), never read as Start.
- **What is sent is the task's own.** A Start from the glasses sends the task's composed prompt, the one a fresh draft on the Mac starts from, with the note under it. Never the Mac's saved draft for that task: drafts save on every keystroke, so a half-typed prompt on the Mac would otherwise reach the agent unseen on the glasses. The Mac's draft is left as it was.
- **Every guard still holds.** The send goes through the same paths as the Agent workspace: one active handoff per task, the journal fence, the status line, the session name, the COS server's hold on a session it is still running. A note from the glasses is added under the task's context, and a note that carries a status line of its own is refused.
- **Reply by voice and Not done yet** go back to the session that asked or reported done. The reply they answer is marked reviewed only once the new handoff is on its way: a reply the Mac refused (the session cannot take one now, say) leaves the old one delivered and still asking, so nothing is lost.
- **A New session from the glasses stays in the background** (Miles, 2026-09-30). Its app is not opened on the Mac by itself, so the server keeps holding the session and the glasses can reply to it. Work shows it "from the glasses · not opened in its app", and its Open in Claude (or Codex) button still opens it: from then its app owns it, as with any other. A New session started on the Mac opens in its app as before.
- **Never late, never the clipboard.** A claim that came with no deadline is refused. The claim's deadline is checked again immediately before each thing that goes on the wire (a new session, a native fork, asking about a session, attaching it, a turn, a queued turn); past it the request is refused ("Claimed too long ago; not sent"), so a late request never binds a session. A Continue into a session its app owns is refused from the glasses ("This session is open in its app on the Mac. Continue it there."), because Continue there puts your note on the Mac's clipboard.
- **Told back, even across a relaunch.** The result goes to the server under the claim's token: sent with its receipt, refused with the reason (and the receipt when there is one, including a run that failed or was canceled), or unresolved with the receipt when its delivery could not be confirmed or is still going. Results are kept beside the journal until the server takes them; a claim made before a relaunch is claimed again under its token and finished. One the server could not take just now (unreachable, 5xx, 429) is posted again after 5 seconds, then 10, doubling to at most 30 minutes, and dropped after a day; one it will never take (the claim ended) is dropped at once. A refusal is not left as an error on the Mac's Work page.
- **The Agent workspace stays yours.** Sending for the glasses does not disable the Agent workspace or close an open dropdown; a draft you type meanwhile is kept and saved when that send lets go. A send you start on the Mac in that moment is told to wait ("COS Control is sending work your glasses asked for. Try again in a moment."), and so are Mark reviewed, Clear unresolved, Check status, Refresh and Not sending it, instead of the journal lock's "Another COS window is updating Work". That line stays on the Work page when the glasses send reports back. The timed status checks skip that moment and say nothing.
- **Recorded.** A handoff sent for the glasses carries `requestedFrom: "glasses"` and the request's id on its receipt (new optional fields, never a new status), and Work's history says "from the glasses". The session name drops the same inline markdown the server's display title drops (links, code, emphasis), not only bold.
- **Logged** under the subsystem `com.gotcos.control` (category `work-requests`; Work tracking's category is now there too): a list that fails, a claim that is refused, the older-server pause, result retries and a result given up, each once when it changes, never on every pass.
- **Helper:** three commands for the inbox (list, claim with an optional claim token, result), on the loopback address the server requires for them, with the same token as every other Work call. A route missing on an older server reads as "server too old", never an error. The list no longer passes on a quarantine count COS Control never showed.
- **Controls, from 0.5.251's QA:**
  - **The open dropdown is the approved card.** It opens as a borderless child panel under the face, not a popover: rounded 8 pt, the gold hairline, the chosen row's gold rule, a soft shadow, and no arrow or system chrome. It is as wide as the face, wider only when a row needs it (at most 440 pt), and a name still too long keeps both its ends with the whole of it in its tooltip. Past ten rows it scrolls, and the keys bring the highlighted row into view. A click on the face of an open list, or anywhere outside it, Escape, Tab or a scroll elsewhere closes it, and the click that closed it never opens it again, however long it is held. The panel never takes the keyboard from its window, so the menu-bar panel stays open around it; keys reach the list through the app.
  - **Keyboard, again.** Switches, checkboxes and chips take keyboard focus when Keyboard navigation is on, as the dropdown and view switch do, and Space flips them. A switch flips from the switch itself and not from its words, as a stock macOS switch does (measured against the stock control; a checkbox flips from its box and its words, as the stock one does). VoiceOver's hint on an open dropdown says "Close list".
  - **Light mode.** A hovered or pressed quiet button, a featured button's ink, a hovered icon button and the spinner's arc use the accent token, a deeper gold in light mode, over 3:1 on a white card (raw gold is about 2.3:1).
- **Guard, widened.** `Tests/run.sh` now also fails on `.buttonStyle(.borderless)`, `.progressViewStyle(.circular)` or `.linear`, a chip-like `.toggleStyle(.button)`, the long-form style names (`BorderedButtonStyle()`, `SwitchToggleStyle()`, `CircularProgressViewStyle()` and the rest), a Menu with no `cosMenu()`, and a TextField or SecureField with no `.textFieldStyle(.plain)`. Each file is read whole, so a style split across lines is found, and prose in block comments is ignored. `Tests/run-controls-guard-selftest.py` proves it on every gate: 15 banned forms added to a scratch copy of Sources each fail it, and 5 allowed ones do not.
- **Tests:**
  - Work, end to end on a synthetic transport and board (`Tests/run-work-progress.sh`, test 22): everything above, including a Fork with a model missing from an empty catalog (refused, never a native fork), a catalog that could not be read, a refused reply leaving the old one delivered and asking, results kept on disk and posted after a relaunch, a claim re-made under its token, re-probing an older server after ten minutes, a list while a send is in flight, a board that could not be read, back-off and giving up, a claim with no deadline, the deadline before each of the four wire sends, a glasses New session left in the background while a Mac one still opens, an unknown or missing intent, a complete task both ways, failed, canceled and still-going runs, 5xx and 429 retried and a never-takeable result given up, Fork native and to the other platform, the journal read again from disk, `start()` listing and taking a request, and each log line written once. From the round 2 review: a glasses Start that sends the task's own prompt and not a half-typed Mac draft; Mark reviewed, Clear unresolved, Check status, Not sending it and a Mac send told to wait during a glasses send, the timed poll silent, and the line kept after the send reports; a late request that never asks about or attaches a session, and a deadline that passes mid-Continue stopping the attach, the queued turn or the turn.
  - Revision parity: the server's 12 golden rows (glasses-server 6.59.0, `server/lib/__fixtures__/control-task-snapshot`) are in `Tests/fixtures/control-task-snapshot`, and Control's own task revision must match every one.
  - Controls, executed (`Tests/run-controls.sh`), in windows off screen with clicks and keys sent through the app: the open list as a child panel (opens, a row click, a disabled row, Down and Return, a letter and Space, the face click and a slow face click, Escape, a click, Tab and a scroll elsewhere, the pointer, its card's pixels, twenty rows and the highlight scrolled into view); nothing takes a window's first focus by default; with Keyboard navigation's state, the face's keys, the view switch's arrows, and Space on a switch, a checkbox and a chip; a switch's words that do not flip it; the chip; the disclosure expanding; the root theme's button, progress, disclosure and tint, each drawn three ways; the light-mode contrast of the pressed button, the featured button and the spinner.
  - `Tests/dropdown-canary`, off screen by default: frames of the open list in dark and light, and the calibration against a stock macOS switch and checkbox (a click on a stock switch's words leaves it as it was; a stock checkbox flips from its words; the gotcos ones do the same). Its desktop mode (`COS_DESKTOP_CANARY=1`, set only by a person at the Mac) drove the open list in a real MenuBarExtra(.window) and a real window on 2026-09-30, 11:38 to 11:44: it opened as a child panel, a row click, Down then Return, a click on the face, Escape and a click outside all worked, and the menu-bar panel stayed open and key throughout. That was before two later refinements (more room for the card's shadow; a key or a scroll no longer delays the next click on the face), which the off-screen contract covers; the desktop mode was not run again, to leave Miles's Mac alone.
- **Tests leave the Mac alone** (Miles, 2026-09-30: focus jumped and his clicks landed in the wrong window while gates ran). The controls contract can no longer become the active app (activation policy `.prohibited`, as the other UI suites) and fails if it ever does; its windows sit far off every screen and no event leaves the process. The dropdown canary runs off screen unless a person sets `COS_DESKTOP_CANARY=1`; the Jedi idle canary needs `COS_JEDI_CANARY_OUTPUT`, checked in its own code as well. `Tests/desktop-safety-check.py` runs first in `Tests/run.sh` and fails when a test activates an app without such an opt-in on the same line, moves the pointer or posts a system event, orders a window in (orderFrontRegardless, orderFront or makeKeyAndOrderFront) from a process that could activate, or without placing that window far off every screen earlier in the same function (each window on its own, never one covering another), or adds a status item or app window outside the hand-run canaries; its self-test proves 17 such forms fail it and 5 allowed ones pass. The two windows a person opens by hand (the Jedi idle canary, the dropdown canary's desktop window) carry their opt-in on the line that shows them. The Work checks' stores now fail if they ever reach a real app, Terminal or the clipboard (none did: measured with each hook replaced by a print across all three Work suites).
- **Mutation gate** (a scratch copy; a green baseline first; each target found exactly once; a compile error is not a kill; each kill names the check that failed): all 42 Work mutants killed (the glasses requests, Miles's background decision, and QA items 1 to 8 and 15 to 18; two first survived, a checked-task fixture that read as Complete anyway and a dedupe the send's own fence masked, and were killed once those checks were sharpened); all 7 guard mutants killed. The controls lane was stopped at Miles's request (his Mac's focus jumped while it ran) after 6 mutants, all killed; an earlier run of it, on the tree before the two small refinements above, killed 15 more and had 2 survivors, both fixed since (a scroll check that passed without the list open, and a panel background a drawing cannot show, now read directly) and not run again. Not run at all for 0.5.252: Space on a chip, no first focus by default, the root theme's button, progress, disclosure and tint, a chip's click, the view switch's Right, a closed face's keys, and the three light-mode contrast mutants. The 0.5.251 controls gate and the controls contract itself (which executes each of those behaviours) still stand. For the round 2 items, 12 more Work mutants (the glasses Start reading the Mac's draft; each Mac action, the timed poll and a Mac send not told to wait; outcome() erasing the line; each of the four deadline checks on a Continue) and 5 desktop-check mutants (either ordering call not seen, offscreen read per file, a placement after the call, a window made on screen): all 17 killed, each by a named check.
- **Not verified here:** a live request from the glasses (server 6.59.0 is installed on Miles's Mac; these were checked against its routes with fixtures), VoiceOver speaking the open list, and the pointer's hover over a real display.

## 0.5.251 (build 289)

Every stock macOS control in COS Control now wears the gotcos theme: dropdowns, view switches, switches, checkboxes, steppers, progress, disclosure, fields and buttons. And a Claude session started from Work is named after its task's whole title, not the board's short one. Works with server 6.58.2.

- Miles, 2026-09-29, on 0.5.250's Agent workspace: the Provider and Model dropdowns (grey fill, blue stepper) and the Board/Focus control were macOS defaults, and "we should be using our GOTCOS theme across the board." He approved the rendered design on 2026-09-30 ("Build all as shown"), with open dropdowns showing the themed card list.
- **Dropdown.** An optional label, then a face drawn like a field: warm card, hairline, the value in DM Sans, a gold chevron, and a gold hairline while it is open or hovered. A placeholder ("Choose model") reads muted; a disabled dropdown dims and does not open. Open, it shows a card list: the chosen row carries a gold rule, the row under the pointer or the keys a gold wash, and a muted row its note ("unavailable", "not pulled"). An unavailable model can still be chosen, as before, and its reason shows. A row can also be disabled outright.
  - Keys: Space or Return opens it, Up and Down move, Return chooses, Escape closes, and a letter jumps to the next row that starts with it. The face takes focus when keyboard navigation is on, as a macOS pop-up button does, so it never takes a window's first focus.
  - VoiceOver reads the face as a button with its label and value, and each row as a button, the chosen one selected.
  - It opens as a popover in the Activity window and in the menu-bar panel. `Tests/dropdown-canary` drove a real MenuBarExtra(.window) with clicks and keys posted to the app: the popover opened, a row click and Down then Return both chose, and the panel stayed open. The same harness reproduced the 2026-08-23 finding for `.confirmationDialog` (its Release never ran, and the panel closed), so it sees this panel's failure mode. If a real click ever dismisses the panel, one environment value drops every list inline under its face instead.
- **View switch** (Board/Focus, Recent/Archive, the Speakers and Memories views, the sessions clock, transcription tier, correction scope, pet size and motion): words, the current one in ink with a 2 pt gold rule under it, the others muted. Never a pill row. Left and Right change it when it has keyboard focus; VoiceOver reads a tab group with the current word selected.
- **Switch and checkbox, by meaning.** Settings that turn something on or off are switches: a warm track that fills gold, an ink knob. Filters and confirm steps are checkboxes: a hairline square that fills gold with an ink check. The morning brief weekdays and Work's Intake are small chips that fill gold when on.
- **Progress:** a gold arc on a hairline ring for busy (the old sizes: 10, 16 and 32 pt), which holds still under Reduce Motion, and a gold line on a hairline track for a bar. **Stepper:** the value between two round minus and plus buttons, kept inside its range; VoiceOver adjusts it as one control. **Disclosure:** the words, then a gold chevron that turns. **Menus:** the quiet button with a gold chevron.
- **Replaced:** 28 pickers (19 dropdowns, 9 view switches; the two sort menus in Speakers were a picker inside a menu and are dropdowns now), 23 of the 24 toggles (14 switches, 7 checkboxes, 2 chips; the pet's right-click menu items stay system menu items), 12 rounded-border fields to the card field (a secure field among them), 2 text editors to the same card, 5 prominent buttons to the gold primary, 7 bordered to quiet (a destructive confirm to the danger tone, Stop too), 5 link buttons to text buttons, 12 borderless buttons (6 icon, 6 text), 3 menus to the themed face, 3 steppers. All 56 progress views and 11 disclosure groups take the theme from one modifier on each window root, which also gives any button without a style of its own the quiet style, and tints the two native controls that stay (2 sliders, 2 date pickers) gold.
- Behaviour is unchanged: the same bindings, disabled states, help text and accessibility identifiers.
- **Guard.** `Tests/run.sh` fails when a Sources file other than `COSBrand.swift` uses a segmented or menu picker style, a bare Picker, a prominent, bordered or link button style, a rounded-border field, a switch or checkbox toggle style, a Stepper, or a borderless menu, and when a Toggle outside the pet's menu names no COS style. Proven able to fail: each banned form added to a scratch copy of Sources failed it.
- **Work: the Claude session name is the task's whole title.** The 0.5.250 canary named its session "Canary 0.5.250 Claude name: reply with the", the board's 42-character display title. A task's New session now sends its whole title (as Work's Start work sheet shows it), cleaned by the same rules: controls and invisible marks become spaces, joiners stay, whitespace collapses, at most 100 characters cut back to a space at 50 or later, no trailing punctuation.
- **Tests:**
  - `Tests/run-controls.sh` executes the components: the dropdown's key rules, inline and popover choice by click, Down and Return, Escape, a disabled dropdown and a disabled row, the view switch, switch, checkbox and stepper bounds by posted clicks, the switch and checkbox by their rendered pixels in light and dark, and the spinner sizes.
  - Work, through the real snapshot and send path: an 84-character title arrives whole; a 130-character one is cut to its first 98 characters, at the last space and without its trailing comma.

## 0.5.250 (build 288)

New sessions from Work are named after their task in Claude, and with server 6.58.2 a Claude one is visible in Work, Sessions and on the pet from the moment it starts, under that name. Includes 0.5.249. Needs server 6.58.2 for both; with an older server they still run and open in Claude, unnamed, and show once they finish.

- Miles, 2026-09-29, from the first live run of 0.5.249 (job c3878966, 8:36 to 8:39 PM): Control opened the session in Claude 31 seconds after the run ended, as designed, but its sidebar name was "General coding session", Claude's default for an imported session with no title. While it ran it was nowhere: the card said "session live status unavailable" and Sessions listed it as "COS server · Scheduled job".
- **Named after the task.** New session, Start work and Fork to another platform, when the session is Claude's, send the Work item's title as the session's name. Server 6.58.2 passes it to `claude -p` as `--name=<title>`, which writes it into the transcript, and Claude's sidebar shows it once the session opens there.
  - Cleaned as server 6.58.2 cleans it, so the two agree: C0 and C1 controls, zero-width spaces, direction marks and overrides and the byte-order mark become spaces (joiners and tag characters stay, so emoji and words hold together), whitespace collapses to one space, and the ends are trimmed.
  - At most 100 characters, counted as the server counts them (grapheme clusters). A longer title is cut at 100, then back to the last space when that space is at least 50 characters in. Control also drops trailing punctuation.
  - A title with nothing visible in it sends no name. Codex, Cursor and Ollama sessions carry no name.
  - Server 6.58.2 never gives a named session its boot warm-up session, and leaves the name out when the installed Claude CLI does not offer `--name`. A server before 6.58.2 ignores it.
- **Visible from the start (Claude only).** Server 6.58.2 names a New session's Claude session near the start of the run, not at the end. Control reads the job again after waits of 1, 2, 4 and 8 seconds (about 1, 3, 7 and 15 seconds after the send); when the session opens in its app it keeps reading every 5 seconds, and otherwise the tracker follows it every 30 seconds. So the card links the session while it runs: Open session works and the card shows its live status. Codex, Cursor and Ollama are unchanged.
  - Only a run that is going or finished well is linked. A job that failed, was canceled or was interrupted is not, even when the server named its session.
  - Sessions and the pet list it as Work under its own name, not as a COS server job, and the ledger of scheduled runs never records it. They are marked as soon as the receipt links the session, whichever read linked it (Check status and a Work refresh included), and again when the run ends.
  - The live list gives a running Claude session by its first 8 characters, while the receipt holds the full id. Work, Sessions and the pet treat those as the same session, never a shorter prefix and never another provider's, and Work's Continue picker lists it once.
- **One writer while it runs.** Until its run ends, only the COS server writes a Work New session. Open in platform is off (the pet's figure and its Waiting jump open it in Control instead), and Continue is off in Work, in Sessions and on the pet; each says it is still running its first turn. It opens in Claude once the run has completed, never because a session id appeared.
- **Sessions reads the name from the transcript.** The server's list reads only a transcript's last 256 KB for its title, and the name is written near the top, so a long run showed its first prompt instead. Control's fresh list and the pet's live list now take the newest title in each Claude transcript for rows Claude Desktop has not titled; Desktop's own title still wins.
  - A warm-up is known by its first prompt, never by a title someone gave the session: a Work item called "Ready" stays listed.
  - Fixed on the way: that title reader dropped a whole window, and the title in it, when the window ended inside a multibyte character.
- **Tests:**
  - The name, character by character: invisible and control characters, joiners and tag characters that stay, whitespace, the 100 limit and the cut back to a space at 50 or later, one long word, emoji counted as characters, trailing punctuation, and the signs and brackets that stay (C++, C#, a closing parenthesis or quote). The helper's Work self-test checks its own cleaning the same way (now 51 checks).
  - A running job that names its session is linked by the first read, moves the card to Draft and is Work in Sessions under its title, held: it does not open the app and a Continue into it is refused. It opens once the run completed, and the end of the hold is marked. Only Claude sessions carry a name, a fork to Claude included.
  - Failed, canceled and interrupted jobs are never linked; a job with its answer ready is. Check status marks a link at once.
  - Short and full ids for one session, the Continue picker listing it once, and the cases that must not match; a session named Ready is not a warm-up.
  - The helper: the name rides in the job request only when there is one; the title reader over a transcript whose first 256 KB ends inside a character, a newer title in the tail, Desktop's title winning, named rows never hidden as warm-ups, and the pet naming a live row before the warm-up filter (its self-test, now 774 tests).
- **Not verified here:** the name reaching Claude's sidebar rests on the canary of 2026-09-29 on claude 2.1.285 (`claude -p --name` writes `custom-title`, and Desktop shows it) and on server 6.58.2, which is not part of this build.

## 0.5.249 (build 287)

New sessions from Work start on the COS server and open in their app once the first reply is done: Claude and Codex in their own apps, Cursor in Terminal with cursor-agent. You continue there, alongside COS, and Work follows the session as before. Replaces 0.5.248's prefilled tab. Includes 0.5.248 and 0.5.247. Pairs with server 6.57.1; the Jev check needs server 6.58.0.

- Miles, 2026-09-29 (G2, 18:00), chose "start it, then open it" for Claude, Codex and Cursor, in place of a prefilled chat that waited for him to press Send. The canaries that evening:
  - Claude 2.16120.0 imports a finished CLI session as a Claude tab (`claude://resume?session=<id>`), and it can be continued there.
  - The ChatGPT app 26.928 resumes a finished Codex thread (`codex://threads/<id>`). A thread opened while `codex exec` was still writing stayed view only ("already has an active writer") and was never retried.
  - The Cursor app cannot open a chat the CLI started. `cursor-agent --resume <id>` picks it up.
- **Start it.** New session, Start work and Fork to another platform run the background job that 0.5.247 uses: the COS server runs the session, and Control links it by reading the job again after 1, 2, 4 and 8 seconds. The handoff, its status line and tracking are unchanged.
- **Then open it, once.** When the run's first turn has finished and its session is known, Control opens it:
  - Claude, as a Claude tab. The link comes from the helper's session check (the one Open in platform uses), which gives none while the transcript is still being written and never imports a session a Claude tab already holds. So it opens once the transcript has been quiet for 30 seconds.
  - Codex, as its thread in the ChatGPT app.
  - Cursor, in a Terminal window in the folder the chat ran in, running `cursor-agent --resume <id>`. The command is a `.command` file beside Work's history, never in your repository, and Terminal runs it when it opens it, so no Automation permission is needed. The id must be a chat id and the folder a plain absolute path, and both are quoted.
  - Nothing opens while the run is going, and nothing opens until 5 seconds after it ended. A run that failed, was refused or named no session opens nothing, and the card shows why, as before.
  - A run that ended more than an hour before Control saw it (Control was closed) does not open by itself. The card offers Open in Claude, Open in Codex or Open in Terminal.
  - Each session opens once. The journal records the opening before the app is asked, so another pass, another window or a second COS Control never opens it again.
- **Finding the Cursor chat.** The server names no Cursor chat for a run, so the helper has a new command, `work-cursor-chat`. It lists Cursor CLI chats created since the handoff and returns those whose first message carries the task's `COS-WORK <id>:` line. It reads local files only. Control links a chat only when exactly one matches, and looks for up to 2 minutes after the run ends. Once linked, tracking reads the chat itself.
- **The card.** While it runs: "Running in the background. It opens in Claude when the first reply is done." Once open: "Opened in Claude. Continue there." For Cursor: "Opened in Terminal with cursor-agent. Continue there." Open again opens the same session (a Claude session that is already a tab is focused, not imported twice) or runs the same Terminal command. The Progress timeline records the opening.
- **Continue on a session its app owns.** Once a session is open in its app, COS never sends a server turn into it: the app and the server would write one transcript at once. Continue, and Not done yet, take your note to the app instead:
  - Codex opens the thread with your note filled in (`codex://threads/<id>?prompt=<note>`). You press Send.
  - Claude and Cursor open the session and put your note on the clipboard. The card says "Your note is on the clipboard. Paste it there."
  - The handoff counts as delivered once the session's conversation shows your note arriving. Cursor writes no times, so for Cursor that is when a message that starts like your note first appears. Tracking follows it from there: Received moves the card to Draft, and done moves it to QA.
  - Not sending it drops a note you will not send, so the item can take a new handoff.
  - A session started from a 0.5.248 tab is the app's too. A Cursor one lives in the Cursor app, which has no link to a chat, so Continue puts the note on the clipboard and says so.
- **Removed: the prefilled tab.** The 0.5.248 route is gone with its tests: the prefilled new chat, "Press Send there", Not sending it for a New session, linking a tab by its first message, the Cursor handoff file, and the helper's `work-tab-folder`.
- **Receipts written by 0.5.248.** A tab 0.5.248 opened and never linked to a session reads as a handoff that never started: "Not started. COS Control 0.5.248 opened this as a tab for you to send, and it was never linked to a session." It no longer blocks the item, so a New session can start the work again. Keeping Open again for its prefilled link would have kept the whole prefill route alive for the few tabs opened on the one afternoon 0.5.248 was live. If you did send one in the app, that session is still there. A tab 0.5.248 did link keeps its session, which the app owns.
- **Settings.** "Open new sessions in the app" keeps its setting, and now means: open the session in its app when the first reply is done. Off, the session stays in the background, as in 0.5.247. Ollama has no app and always stays in the background.
- **Journal compatibility.** Opening lives in a new optional receipt field, and a note taken to the app in its own channel, never in a new status: the server refuses a journal with a status it does not know. 0.5.248 reads these journals. Rolled back to it, a session Work opened in its app would take a server Continue again.
- **Tests:**
  - `Tests/run-work-progress.sh` covers the new rules on their own: session ids (a lowercase UUID only; a trailing newline, uppercase or a path is refused), the Codex link and the Cursor command character by character (non-ASCII letters, reserved characters, quotes, `$` and backticks), the only two Claude links accepted, when a session opens (running, settling, settled, late, failed, no session, Cursor still looking), who owns a session, and the card's lines and buttons.
  - End to end over a synthetic transport: Claude never opens or asks while running, waits while the helper says the transcript is being written, retries when the helper does not answer, then opens once, including two passes at once and a second window on the same journal; Open again focuses the tab. Codex opens its thread; a failed run opens nothing; Settings off and Ollama stay in the background. Cursor links only a single matching chat, writes the exact command, private and executable, beside the journal, and opens it once. Continue and Not done yet on app-owned Claude, Codex and Cursor sessions never reach the server's turn path, and each note is delivered when it arrives. A 0.5.248 journal reads as described above.
  - `Tests/work-progress-helper-checks.py` runs the compiled helper's `work-cursor-chat` over a fixture home: only this handoff's chat since the handoff, never an older one, another task's, one with no transcript or a name the CLI does not write, and never a server call. The helper's Work self-test covers the matching rules.
  - The Work handoff suite checks that the intent to open is journaled with the handoff before the run starts, and that a Continue on an app-owned session makes no server call even when no link can be built.
- **Not verified here:** no test opens a real app. The Claude, Codex and Cursor behaviour rests on the canaries above. The Cursor canary resumed with `cursor-agent -p --resume`; the interactive `cursor-agent --resume` in Terminal is the same chat without `-p`.

## 0.5.248 (build 286)

New sessions from Work open as a tab in Claude, Codex or Cursor. You press Send there and work in the app alongside COS, and Work follows the session as before. Includes 0.5.247. Pairs with server 6.57.1; the Jev check needs server 6.58.0.

- Miles, 2026-09-29: "Tabs right away, in claude, ChatGPT and Cursor. Goal is to be able to work collaboratively with our orchestrator so that step is important. We can't see or recover those headless sessions with the GUI." A New session used to run in the background on the COS server, so it never appeared in the app's sidebar.
- **New session opens a tab.** Start a new session (and Start work) for Claude, Codex or Cursor opens a new chat in that app with the handoff filled in, including its status line. It never sends by itself. The card reads "Opened in Claude. Press Send there to start it."
  - Claude opens a new Code tab in the COS folder (the folder the server runs agents in).
  - Codex opens a new thread in that project, in the ChatGPT app.
  - Cursor shows its own "Create chat with prompt" dialog, then a new chat in the workspace Cursor has open. Choose Create Chat, then Send.
  - Each app uses its own default model. None of their links can choose one.
- **Work links the session once you send it.** The tracker looks for that app's sessions started after the tab opened whose first message is the handoff, then records the session. Received moves the card to Draft and done moves it to QA, as with every tracked handoff. A session older than the tab, or another app's, is never matched.
- **Cursor and long handoffs.** Cursor drops a link of about 10,000 characters or more without a word, so a longer handoff is saved to a file beside Work's history, and the tab carries a short prompt that names the file and starts with the task's tag.
- **Open again and Not sending it.** A tab not sent yet can be opened again with the same words, or closed, which lets the item take a new handoff.
- **Fork to another platform** opens its tab the same way, with the conversation carried over.
- **Ollama has no app**, so it keeps the background run, as does every provider when Settings > Open new sessions in the app is off.
- The exact words each tab opened with are kept beside Work's history, never in your repository.
- Fixed in the tests: the helper's Work self-test (the model catalog, admission, and now the tab folder rules) was its own command that nothing ran. The test suite runs it now.
- Tests: the links for each app, character by character, including non-ASCII letters and reserved characters; no background run for a tab; linking skips older sessions and other apps; Cursor's file handoff, Open again, and a Cursor session whose messages carry no times; a refused open; Not sending it; Ollama in the background. The helper's self-test covers each folder rule the server uses.

## 0.5.247 (build 285)

Sessions move their own tasks. Every handoff is followed from sent to done, and the Kanban keeps up by itself, as far as QA. Pairs with server 6.57.1. The Jev check below needs server 6.58.0.

- Miles, 2026-09-29: "there should be a status update when the user has sent something to a session and it's been confirmed ... If a session is responsible for completing multiple tasks and we have evidence of the session receiving the context necessary to complete that task (as well as a confirmation that it has), then we want to be moving those tasks through the Kanban as well automatically." His choices:
  - automatic moves go up to QA and never to Complete;
  - done comes from the session's own status line, with Jev as the fallback;
  - progress shows on the board, in a timeline and as a Mac notification.
- **Every handoff asks for a status line.** COS adds one instruction after your context on every send, so no draft can leave it out. The session is asked to make its first reply line, in plain text, `COS-WORK <task id>: done, needs input or blocked: <one sentence of evidence>`, with one line per task when it holds several.
  - It goes first because the server keeps a reply's first 4,000 characters and drops fenced code.
  - A draft now holds up to 31,520 characters, so what is sent stays within 32,000.
- **Received moves the card to Draft.** Either of two things counts as received:
  - The server confirms the session has the work. A Continue turn or a queued turn landed, a fork holds the instruction, or a New session run is confirmed.
  - The session's own conversation shows your instruction arriving. This is usually sooner: a Continue turn is confirmed only when it finishes.
- **Done moves it to QA.**
  - A status line of done with evidence moves the card to QA.
  - Needs input and blocked move nothing. They notify you and show the session's question on the card, until you mark the reply reviewed.
  - Only replies written after your instruction arrived count. For Cursor, which writes no times, replies already in the session when tracking first read it never count.
  - A line naming a task that session was not given is ignored.
- **Jev when there is no status line.** Jev runs when the session has gone idle and its newest reply since the handoff has no status line.
  - Idle means its conversation untouched for 90 seconds, not running, and its turn or run finished.
  - Jev reads the replies since the handoff arrived. It judges them against the task's Done when or, when there is none (no open task has one today), against the task itself.
  - The server reads both itself. Control sends only names and a time.
  - The card moves to QA on a done at 80%, or 85% without a Done when.
  - At most twice per handoff, once per reply. A failure to reach Jev is retried after 10 minutes and never uses up a check.
  - A server before 6.58.0 answers "needs server 6.58.0", and only status lines count.
- **Every move says why, and can be undone.**
  - A card COS moved says "Moved here at 9:52: the session reported done." with Undo, until you move it.
  - The newest move also shows above the columns for 30 minutes.
  - Undo, or moving the card back yourself, stops automatic moves for that handoff.
  - Moves only go forward, never into or out of Complete.
- **Moves that cannot be made now are kept.** A busy or read-only board, or a task that changed, keeps the move pending and retries it, up to 5 times, with a note on the timeline. When the board saved the move and only its refresh failed, the move counts as made.
- **Records that find the journal busy are kept.** When a send holds the journal, the record is written on the next pass, so a moved card always gets its why-line and Undo, and a notification is recorded once.
- **When tracking stops:**
  - at done;
  - when a newer handoff replaces this one for the same work;
  - when the task is complete;
  - after 14 days.

  Quiet sessions are read less often: every pass (30 seconds) within an hour of their last message, every 5 minutes up to a day, then every 30 minutes. The tracker logs to the `work-tracking` category (Console).
- **The session row lists what each session holds.**
  - Tracked handoffs to one session share one card. It lists up to four tasks with their state (Sent, Received, Working, Done, Needs input, Blocked) and stage.
  - A task waiting on you leads the card, and counts toward "need attention".
  - Handoffs sent before 0.5.247 keep their own cards.
- **The Agent workspace has a Progress timeline.**
  - It shows Sent, Received, Replied, the status line, Jev's reading, each move (with Undo while the card is where COS put it), your undos, and any notes.
  - A reported state leads the status box. A done task offers Mark complete.
  - Jev's reading is never quoted as the session's words.
- **Not done yet.** Miles picked it for this release. A task the session reported done shows **Not done yet** beside Mark complete.
  - It asks what is missing.
  - It marks the reply reviewed, continues the same session with your note (and, when the session wrote one, its earlier status line), and moves the card back to Draft from Built or QA.
  - The old handoff's timeline records "You sent it back". The new handoff is tracked like any other, so the old done line cannot finish it.
  - It is offered only when the session can take a Continue and no turn for this work is still in flight.
- **Notifications** cover three moments: received, done, and needs input or blocked. Clicking one opens its item. Settings has a Work notifications switch (on by default).
- **Tracking runs with Activity closed.** The Work journal and its tracker now live with the app, and the Activity window shares them. A journal that could not be read at launch is read again, without a relaunch. An event kind this build does not know reads as a note.
- **Fixed: a running Continue no longer reads as lost.** The server answers 404 for a turn still running, and 0.5.244 to 0.5.246 showed that as "Delivery needs checking" until the turn finished. It now stays running. It reads as unresolved only after two hours with no receipt.
- **Fixed: a New session from Work is findable while it runs.** Miles, 2026-09-29: a New session sent at 1:46 PM showed "session live status unavailable" in Work, and Sessions listed it only as `COS server · Scheduled job`.
  - Work's first read of the job came 0.17 s before the server named the session, and nothing read it again while the item stayed open. Control now reads the job again after 1, 2, 4 and 8 seconds, until the server names the session or the run ends, so Open session appears within seconds.
  - Sessions no longer shows a session Work sent as a COS server job. The COS server starts it, and the helper labels every run the server starts that way, which hid its title and transcript and removed Continue. A session a Work handoff names keeps its own title, transcript and Continue.
  - The card says where a New session runs: on this Mac through COS, not as a tab in the Claude or Codex app. Once it has finished, Open session, then Open in platform, keeps it going in the app.
- **Only handoffs sent from 0.5.247 on are tracked**, since earlier ones never asked for a status line.
- **Journal compatibility.** Progress lives in a new optional receipt field, never in a new status, because the server refuses a journal with a status it does not know. Rolling back to 0.5.246 keeps every card where it is and drops the timeline.
- **Tests:**
  - `Tests/run-work-progress.sh`, now also run by `run.sh`, covers:
    - pure rules: the parser (including the template filled in as instructed), delivery, stages, the tracking window at its boundary, and Jev thresholds per basis;
    - board projections: the session list, one card per session, and the move strip;
    - Not done yet: send-back, the prompt, what the old handoff records, and where it is not offered;
    - the tracker end to end, over fixtures in the real helper shapes: a running turn's pending 404, arrival from the transcript, stale and foreign lines, several tasks in one session, pause and moved-back, retries, a journal held across a move, Jev gating (working, idle, transient and final reasons, once per reply), the untimed baseline, no history, a job's result, superseded handoffs, and back-off.
  - `Tests/work-progress-helper-checks.py` runs the compiled helper against a loopback server.
  - `run.sh` pins the wiring.
  - QA: four reviewers. Their reports and fixes are in `operations/personal/wk40_2026/control_0_5_247_qa/`.

## 0.5.246 (build 284)

Drag and drop works, a drop that meets every criterion runs and opens its session, and a handoff COS lost track of can be continued. Pairs with server 6.57.1.

- **Cards drag.** Miles, 2026-09-29: "drag and drop cards don't work here." Each card was a Button, and a Button swallows the drag: real mouse drags on a test window showed a Button-wrapped card never dropped, while a card that opens on a tap dropped every time. Cards now open on a tap and drag between columns or into the session row.
- **Drop into the working area.** The whole "Sessions on this board" row takes a dropped card, and Start work lights up while a card is over it. In 0.5.245 only the pinned Start work tile could take a drop, and a drop target pinned that way never received one; that was also measured with real drags.
- **Runs when every criterion is met.** Miles: "the card needs to meet all criteria to run and open session." A dropped card starts by itself only when:
  - its work has no handoff yet;
  - its destination is certain: a destination you saved, or a Continue or Fork suggestion at its bar;
  - the send is valid;
  - a Continue target is not busy (running or waiting on you).
  It counts down three seconds (Cancel, Change where it goes, or Start now), sends, and opens the session. Anything less asks first: one line to confirm, or the full chooser.
- **Continue after COS lost track.** Miles: "why can't we continue here even tho it's lost track?" When the server sent an instruction but never saw it land, the handoff blocks another send so the session does not get it twice. "Continue in this session…" now says so once and, on confirm, clears the stuck handoff and sets the composer to continue in the same session. "Clear without sending" remains.
- The session row no longer stretches into a large empty band when it has no sessions (0.5.245).
- Tests:
  - The Work suite covers the auto-start rule: saved destination; confident suggestion; nothing certain; earlier handoff; New advice; and busy Continue targets against forks of busy sessions.
  - run.sh pins that cards are a tap gesture, not a Button; that the row, not the pinned tile, is the drop zone; that a qualifying drop starts by itself; and that a started drop opens its session.
  - Verified with real mouse drags on the Work board with sample data: a card moved to another column; drops on the Start work tile and on the empty row opened the overlay; a fully specified card counted down, sent and opened its session.

## 0.5.245 (build 283)

Start work is pinned beside the session row. Pairs with server 6.57.1.

- Miles, 2026-09-29: "The overlap on the start work section doesn't look clean. It has a hard cut." With more session cards than fit, the row's scroll area ended beside Start work and cut the last card off mid-word.
  - Start work is now a pinned column the cards slide under.
  - When cards run under it, they fade out over their last 40 pt, and the column shows a soft shade and a hairline on its edge (deeper in dark mode, where a light shade disappears). The shade is horizontal only, so nothing bleeds onto the header or the board.
  - With room to spare (two cards on a wide window), the row stays flat, with no shade or line. The last card can scroll fully clear of the column.
- Tests: the Work suite checks when the row counts as overflowing, derived from the card, gap and target widths the layout uses.

## 0.5.244 (build 282)

Work becomes a dashboard of the sessions doing the work, with drag to start and the Agent workspace pinned beside every item. Pairs with server 6.57.1.

- **Board and Focus.** Miles, 2026-09-28: "the Agent workspace is the most important view but it gets buried", and he wanted to "quickly swap between the two layouts". Work now has a Board / Focus switch that remembers your choice. Board is the default.
  - **Board** shows "Sessions on this board" (or "Sessions working now" across domains) above the Kanban. Each card is a session Work sent: running (a pulsing green dot), waiting for your input, a reply ready for review, needing attention, sent, awaiting delivery or queued. A card shows the item it works on, why it is in that state (the reply's first lines, or the refusal or delivery detail), and Open session, Mark reviewed or Acknowledge, and Open card.
  - A card edited or linked while its session works stays on the row, marked as an earlier version of the card. A completed card leaves the row once its session is no longer working.
  - The row can be hidden to give the board more room. Start work stays pinned beside it.
  - **Focus** is the list. An open item takes the whole pane, with its Agent workspace pinned on the right when the pane is at least 760 pt wide, which the default window gives (a 400 pt column, 452 pt from 1,100 pt), and directly under the title when narrower. In Focus, picking a domain now opens that domain's list rather than its board.
- **Counts open their work.** "1 in progress" and "2 need attention" are links. Each opens its list, or the item itself when only one matches, without changing your remembered layout.
- **Drag to start.** Drag a card between columns to change its stage (a drop on Complete asks first), or onto Start work to put a session on it. Start work… in a card's context menu does the same without dragging. Nothing runs on a drop. An overlay first loads your sessions and Jev's advice, then:
  - on work with no handoff yet, offers one line and one button when a Continue or Fork suggestion reaches its bar, or when a destination you saved is complete;
  - otherwise opens the full chooser.
  - It keeps whichever it chose ("Choose myself" skips the check). It closes once the handoff is delivered, queued or running, and stays open to show why if it was refused, failed or could not be confirmed. Escape, a click outside, Back and moving to another view close it, except while a send is being handed over; then it waits and shows the result when you return to Work.
- **The Agent workspace.**
  - A status box on top says what is happening now: the session, its state, the reply or the reason, with Open session and Mark reviewed (or Acknowledge for a failure). This replaces the separate Activity card and the "I reviewed this session" button at the bottom.
  - Errors show whether or not the composer is open.
  - Where it goes is three choices (Continue a session, Fork a session, Start a new session), each saying what it does. Continue lists the likeliest sessions first (Jev's pick, word matches, then the most recently active), with every other session one menu away.
  - The send button names the destination, and history folds to one line.
  - Long meeting reviews open folded with "Show the full review", and their notes collapse to one line.
- **Handoffs that could never be cleared can be now.**
  - A New session that finished as "completed" stayed under Needs attention forever. It can be marked reviewed.
  - A failed or refused handoff can be acknowledged. It keeps its status and reason in history, so it never reads as a delivery (the Sessions back-link and session suggestions still treat it as refused).
  - A canceled handoff no longer blocks the next one, and a server run reported as interrupted is recorded as failed.
  - An unconfirmed ("unknown") delivery still blocks, and after you check the session yourself it can be cleared, with a confirm. A cleared one never counts as a delivery: the Sessions page does not link it as "From Work", and suggestions do not treat it as a confirmed handoff.
- Session states read the same on the board, the Kanban, the Focus list and the status box. A session waiting on you or in error says so even while its receipt still reads running or delivered, and "Running" needs proof: a session seen running, a send in progress, or a New session the server is running.
- Tests: the Work suite adds the session row and its order, domain filter and plurals; a state precedence table; earlier-version and completed cards; the send plan for every destination and its button words; the one-click rule (per-action bars, no one click with history or for New advice); the overlay's close rule; date-ordered session shortlists; stage-change guards; and acknowledging each status against a real journal, including kept history, canceled never blocking and clearing an unknown delivery. run.sh pins the drop validators, the overlay route, Escape and navigation closing it, the counts, the shared send path and Reduce Motion.

## 0.5.243 (build 281)

Fork a session to another platform, and session suggestions for meeting reviews. Pairs with server 6.57.1.

- **Fork to another platform.** Miles, 2026-09-28: "How can we fork it over to a new platform?" Fork in the Agent workspace now has a Fork to choice.
  - **Same platform** copies the conversation natively, as before, for Claude and Codex sessions.
  - **Claude or Codex (OpenAI)**, when different from the session's own platform, starts a new session there. It carries the context you reviewed, then the conversation up to now from the chosen session, read from its transcript (the same text as Copy session).
  - Claude, Codex and Cursor sessions can be the source, so a Cursor session can move to Claude or Codex.
  - Cursor and Ollama are not offered as destinations yet: a run started from Work there has no session to open afterwards, and Cursor runs read-only.
  - The conversation sits between markers unique to that fork. The new session is told that "You" in it means your earlier messages, and that its instructions and approvals do not carry over.
  - The total stays within 32,000 characters. A long conversation keeps its beginning and its most recent part, and a context too long to leave room is refused before anything is read.
  - The new session uses the server's configured workspace and permissions, not the original session's. The original session is unchanged.
  - Handoff history shows "Forked from" and the source session. It keeps your context and a note about the carried conversation, not the conversation itself, so the history file stays small. Nothing new is stored, so an older Control can still read it.
- **Suggestions for meeting reviews.** The meeting review "Retail Liquor Summit Campaign Launch" got no suggestion, even beside a session with the same name: suggestions only asked about board tasks. With server 6.57.1 a meeting review asks too, by its review id, and the server reads the review's own text. On an older server the review says suggestions need a newer server; after Update Server that note clears without a relaunch.
- "Use this" on a Fork suggestion is always a same-platform fork, and switching to Fork clears a platform picked under New session. A plain New session never shows as a fork in history.
- A task or review that changed while its suggestion was loading says so, instead of calling the server too old.
- Providers show by name everywhere (Codex (OpenAI), not "codex").
- Tests: the Work suite covers the review target and request; a full Fork to platform against a fake helper (export read, New session with context and conversation, lineage, the journal note); the Cursor-destination, no-transcript, empty-export and no-room refusals (no helper call); the composer's 32,000 cap, its 30/70 split, per-fork markers and unsplit characters; lineage only for real forks; forgetting lasting answers when the server changes; clipped session summaries; and "Use this" clearing a leftover platform. The compiled-helper checks cover the review body, malformed review requests, the server's error codes and an older server's refusal of a review. run.sh pins the Fork to wiring.

## 0.5.242 (build 280)

The menu-bar panel opens straight into itself again. Pairs with server 6.57.0.

- Miles, 2026-09-28: an unstyled "Open Work" button sat above the panel. 0.5.240 added it with the Work preview, outside the panel's design, and it repeated what the Activity section already does: Work has its own chip there, like every other view. It is gone.
- Tests: run.sh now checks that the menu-bar window opens straight into the panel with nothing above it. The check fails on the 0.5.241 source.

## 0.5.241 (build 279)

Work's new Intake view shows what your meetings produced that is not on the board yet. Tasks show who their meetings involved, and the Agent workspace suggests which session should take the work. Pairs with server 6.57.0.

- **People on source meetings.** Each linked meeting lists its people: attendees and action-item owners, with Miles left out. A name opens a card with three lists. First, that person's items from the meeting, each marked "On the board", "In Intake" (with Make it mine and Dismiss), or "Not tracked". Second, their other open asks in Intake. Third, open tasks that mention them, each of which opens that task. Choosing another task closes the card. Transcript labels ("Speaker 1", "Unknown speaker") and your own calendar handle are left out, owners joined by "and" count as two people, and a meeting whose people could not be read offers Try again.
- **Session suggestions.** The Agent workspace asks Jev whether to Continue a session already doing this task, Fork one that shares its context, or start a New session, and shows the answer with its confidence. "Use this" fills Destination and Session in one click; sending stays a separate, explicit step. Without a Jev key, the word match remains, and it no longer counts words every session shares (your name, dates, "brief"). That was how a Morning brief got suggested for a 1:1 task. Leaving a task before Jev answers no longer turns suggestions off for it, and a key added later or a server that comes back is used on the next visit. When no suggestion comes, one line says why (no key, key rejected, daily limit, paused) instead of falling back in silence. Fork is only suggested for Claude and Codex sessions.
- **Jev key in Settings.** A "Jev (TypeSafe)" section takes a key. The server checks it with TypeSafe before saving, stores it privately and never shows it again. A key saved here is the one in use, even when a `.env` file also holds one (server 6.57.0). The section shows where the active key comes from and when it was saved, today's use against the daily cap, any pause after errors, and the last error in words. While the server is not answering it says so instead of "Checking…".

- **Open in platform opens the Claude session.** Miles, 2026-09-28: a Work "New session" for the Retail Liquor Summit launch finished, and Open in platform opened Claude with no session in view. Work runs a new session on the server, so Claude Desktop had no sidebar row for it, and Control looked for a row by name. Control now uses Claude Desktop's own links, verified on Claude 2.9939.4. A Desktop session opens directly by its id, with no Accessibility clicking. A finished session Work ran on the server is imported and opens as a normal Claude tab. Once imported, Claude owns it, so deleting that tab also deletes its transcript. A session that is still running is never imported; Control says so and asks you to open it when it finishes. The same applies to one archived in Claude or with no transcript left. Older Claude builds keep the sidebar search.
- **Sessions lead back to Work.** A session started from Work shows "From Work", with the item's title and status and an Open in Work button, however you opened it. A session run on the server takes its Work title instead of "Claude session".

- A new Intake view in Work, with its count in the sidebar. Three groups, each answered in place, your own first: Review (your items that need a look, with the reason: older meeting, may not be a task, or owner unclear; "Keep as card" or Skip), Suggested links to existing tasks (Link or Dismiss), and Asks from others ("Make it mine" creates a Mentioned card linked to the meeting and written "(from Name)", or Dismiss).
- An ask that one of your recent agent sessions probably covers is pulled to the top, likeliest first, and names the session with its confidence. Nothing is started or sent to a session.
- Review items from older meetings can be skipped together after one confirm. There is no undo for a dismissal yet.
- Accepting writes on the server through the same task writer, locks and revision checks as every other Work change. A refused change says why and what to do (task changed or closed, meeting renamed or removed, eight links already, the same words on closed work, the task bridge didn't answer) and stays in Intake. A double click cannot write twice.
- Meeting titles in Intake open the saved meeting. Choosing a view or a domain closes Intake, including from the compact layout. Rows stack their actions under the meeting in a narrow window, and disabled buttons say why.
- On an older server Intake stays hidden and the rest of Work is unchanged. On 6.57.0, a store or bridge that is down shows Intake with the reason instead of hiding it.
- Tests: the Work contract suite covers several areas: item decoding, grouping and order, review reasons, the route flag and the unavailable states. It also covers people and person cards, Jev advice parsing, and the advice request (one per task revision, stale sessions hidden). `Tests/run.sh` now runs the compiled helper's Work review, Intake and Jev transport checks against loopback fixtures; the key is never printed. The helper self-test covers the Claude link choice: the version floor, a Desktop session found by its transcript id, an archived copy, a running or missing transcript, non-UUID ids, and the isArchived read. The app suite covers link validation, the notices, the From Work lookup and the title.

## 0.5.240 (build 278)

Work brings tasks, meeting follow-up and agent sessions together in the existing Activity window.

- Work is the Tasks home on normal launch. Existing Tasks shortcuts, badges and saved task IDs continue to work.
- Domain boards show Mentioned, Planned, Draft, Built, QA and Complete. Stage updates check the task revision before writing. A completed agent run does not complete a task.
- Tasks link to exact saved meetings, and meetings show associated work and sessions. Continue, Fork and New session retain the existing provider permissions and record a durable handoff receipt.
- Manual meeting review runs when requested. Review settings survive Update Server and Repair. No automatic preparation or publication is enabled by this release.
- The Work surface uses the existing COS cream/gold styles and supports full-row selection and dismissible task dialogs.
- Requires paired server 6.56.0 for Work routes and the portable canonical task bridge. Earlier servers retain their established features; Work shows unavailable when its contract is absent.
- Signed with the stable COS Control Local identity to preserve Accessibility grants. This build is not Apple-notarized.

## 0.5.239 (build 277)

Control keeps the server switches you set by hand. Pairs with server 6.52.0.

- Update Server, repair and adoption rewrite the server's launch settings from an allowlist, and any setting not on it was dropped. Seven server switches from 6.49 to 6.52 were missing, so a value set by hand (usually a kill switch) quietly reverted on the next update: `COS_CONTINUE_LIVE` (live Continue into an open Claude session), `COS_CODEX_LIVE_QUEUE` (Codex Continue into the Codex app's queue), `COS_SESSION_HOOKS`, `COS_PERMISSION_BROKER` with `COS_PERMISSION_BROKER_DESK_IDLE_S` and `COS_PERMISSION_BROKER_TIMEOUT_S` (questions and approvals answered from the glasses), and `COS_MESSAGES_TRAIL` (the readable Messages trail). Two 6.48.0 hook settings were missing too, `COS_SESSION_HOOKS_SPOOL_DIR` (a dropped spool folder leaves the installed hook writing where the server no longer reads) and `COS_SESSION_HOOK_SSE`. All nine are now kept. The pet does not show a held glasses question yet; that comes with the app release that answers them. Found by the plan validation on 2026-09-19.
- Tests: the helper self-test checks each key is allowlisted; run.sh pins all nine in the allowlist block.

## 0.5.238 (build 276)

Codex and Cursor sessions on the pet, the Sessions pane queues like the pet, and the pet has a right-click menu. Pairs with server 6.51.0.

- **The pet sees Codex threads that are working.** Miles, 2026-09-19 08:17: a Codex thread was working in the Codex app and on the lens, and the pet showed nothing. The pet's Codex rows came only from `session-list-cache.json` (moved only by an Activity Sessions walk; 08:12 that morning) and their state from that cached time, so a working thread aged out of the pet and a thread started after the walk was never listed. The Claude half of this was fixed in 0.5.225; Codex never got it. Now a Codex row reads its own rollout: found from the thread id without walking `~/.codex/sessions` (a Codex id is a UUIDv7, so its start day names the folder), its file time, and the newest turn marker in the tail (`task_started` opens a turn; `task_complete`, `turn_complete`, `turn_aborted` close it). An open turn is running, then waiting after 15 quiet minutes (the Claude rule); a closed turn leaves the pet as a finish. Only threads a Codex process has open or that wrote in the last 15 minutes are read, and a read stops at 1 MB (past that the file-time rule answers).
- **The pet finds threads the cache never listed:** Codex threads a Codex process has open (`~/.codex/thread-writer-locks/<id>.lock`: the app holds a thread's lock while it is loaded and removes it on unload), named from `session_index.jsonl`, and named Cursor composers active right now. A cached row always wins; discovery never duplicates one.
- **The Sessions pane parks a message on a busy thread, as the pet and the lens do.** The screenshot showed "Your Mac is writing to this thread right now. Wait a few seconds and try again, or fork it." on a Codex thread mid-turn: the pane parked only a refusal that came back from the turn route, never one from the probe or the attach. Now a probe that says the thread is mid-turn shows "Working right now. A message you send ..." and Send parks it on the server queue; an attach that comes back busy parks the same way; if the queue says the thread freed, the ordinary send (or the attach's own refusal, with Retry and Fork) takes over.
- **Copy for Codex and Cursor on the park path.** Codex: "joins the Codex app's queue for this thread". Cursor: a message waits for the chat's current turn to end (server 6.51.0 hands it over through that turn's Stop hook); a Cursor chat that is not mid-turn says so instead of the old "Cursor cannot queue a message". The composer's held-session note for Codex says the message goes into the Codex app's own queue and shows there; the Claude note is unchanged.
- The Claude pet is unchanged: the same six Claude rows, same names and states, were read by the installed 0.5.237 helper and this one against the live Mac. The pane's park-on-busy applies to Claude threads too, as the pet's has since 0.5.234 (Miles, 9/17: a mid-turn session parks a message, never shows a refusal); Fork stays beside the hint, so nothing the pane offered before is gone.
- **Right-click the pet to hide it or calm it down.** Miles, 2026-09-19, with Codex's own pet menu beside ours: "on right-click of the pet ... give them the option to hide said pet", and "full motion vs no motion if people don't like it moving so much". The figure's menu has Full motion, Calm motion and No motion (the current one checked), then Hide pet. Hide pet is the Session pet switch; the pet comes back from COS Control in the menu bar, under Session pet. No motion is new: the figure holds one frame and the pet's own animations stop (reveals, the ledger's breathing, the ticker), as macOS Reduce Motion already did, but for the pet only. Calm is the existing choice and keeps its stored value. Settings shows the same three as one Motion control (it replaces the Calm switch), and the Session pet summary names the choice when it is not Full. No choice touches the bar: every count still shows.
- QA fixes before publish: Fork kept beside the park hint; the hint clears once the message is parked; a Codex turn left open by a process that died (lock file outlived it) leaves the pet after 30 quiet minutes instead of reading waiting for ever; Codex rollout reads stop at 1 MB.
- Tests for the menu: ModelsContract executes the motion choice (the two flags round-trip, No motion wins, only No motion and macOS Reduce Motion stop the animations, distinct names), 4 of 4 mutants caught; run.sh pins the menu on the figure, Hide pet turning the pet off, each motion item and the settings control calling the one setter, No motion persisted and read back, the pet's single Reduce Motion read folding it in, and the ledger untouched, 6 of 6 mutants caught against a green baseline.
- Tests: helper self-test 727 (a real rollout found by its UUIDv7 day and across a day edge; turn markers; the read gate and the 4 MB cap; the open-thread list; discovery; the pet pipeline: a Codex thread still writing reads running whatever the cache says, a closed turn leaves, a quiet open turn waits, an unread old thread is absent, a discovered thread and a Cursor composer show, a cached row is never duplicated). Source pins: the pane's probe arms the park path before any refusal, a send parks before any attach, a busy attach parks, the hint renders, the Codex rollout refresh runs after the Claude refresh.

## 0.5.237 (build 275)

Meeting sync lists each meeting and where it is.

- Under Meeting sync, one line per meeting the Mac is polishing or saving: its start time ("1:05 PM meeting"), and its stage as the server reports it ("HQ polish 62% (70/113)", "Saving to meeting library", or "Waiting · 21 min of audio"). The meeting being worked on is listed first, then the queue, oldest first. Up to four lines, then "+N more". Miles, 2026-09-18 15:31: "2 meetings syncing" next to "HQ prefill 0/0 sealed" read as one empty meeting blocking the others. It was a 114-minute meeting polishing ahead of a 22-minute one and a 21-second clip, and all three landed by 15:31:34. The server has published these rows since 6.18.4; Control showed only their count.
- HQ prefill says "Ready" between recordings instead of "0/0 sealed". Prefill only runs during a recording; the count shows once one starts.
- Helper: `meetingSyncMeetings` passes the server's rows through (id, phase, percent, segments, chunk count, label), bounded at 12, id-less rows dropped. Older servers send none, and the panel shows the count as before.
- Tests: the helper self-test drives the row projection; ModelsContract executes decode, order, titles (today, another day, a non-meeting id), the waiting and working stage lines, and the prefill wording for idle, live, sealed, unavailable and off. `run.sh` pins the passthrough, the rows in the panel, and that the panel reads the model's prefill string. Six mutants of the model logic were each caught.

## 0.5.236 (build 274)

A queued message opens to its whole text, and can be edited while it waits.

- Tap a queued row on the pet card and it opens to the whole message (up to twelve lines); tap again to fold it (Miles, 2026-09-17: "we need a way to be able to expand or view more of the context of it. Ideally we could edit a queue as well if it hasn't already gone"). A row queued from the glasses or the phone says it holds only the first 80 characters, because that is all the server publishes. The Sessions pane already showed the whole text.
- Edit, while it is still waiting. Edit puts the message in the field (the card's edge goes amber, the placeholder says so); Return replaces it, Escape keeps it as it was. The pane has Edit beside Cancel, Keep it as it was while editing, and its Send reads Replace. The server has no edit route, so a replace is a cancel and a new park with a fresh turn id, in that order, and the server appends: with one message waiting nothing moves, with more the edited one goes to the back of the line and the card says "Replaced, now 3 in line." A thread that freed between the cancel and the park gets the text by the ordinary send, now. A message the session already took cannot be replaced: Control says "Too late to edit: the session already has it." and leaves your text in the field to send fresh. A cancel that the server answers with a settled status (delivered) now reads as too late, not as cancelled.
- Tests: ModelsContract executes the cancel outcome (a 200 carrying "delivered" is too late; "cancelled" or no status is cancelled); run.sh pins the expand toggle, Edit gated on a waiting row, cancel-before-park in both replace paths, the too-late branch keeping the draft, Escape folding an edit before it closes the card, and the pane's Replace label; the pet harness renders the expanded row and the editing field.

## 0.5.235 (build 273)

See what is queued behind a session, and cancel it.

- The pet card and the Sessions pane list what is parked behind a thread (Miles, 2026-09-17: "Is there a way to cancel messages that are in queue? also being able to list the prompts in queue."). Each row shows its place (Next, 2nd in line), its text, and an × on the card or Cancel in the pane while it is still waiting. A turn the adapter already holds reads Delivering… and cannot be recalled; the server says so and Control repeats it ("Too late to cancel: the session already has it.") rather than pretending. A turn the server gave up on reads Refused with its reason, or Expired, for the half hour the server keeps it, so an outcome is never silently lost; delivered and cancelled rows drop off.
- The full text, when this Mac queued it. The server publishes only the first 80 characters of a queued prompt by design, so Control keeps the full text of every turn it parked itself, by turn id, and draws that; a turn the glasses or the phone parked shows the server's preview. The ledger is pruned to what the server still lists, so nothing accumulates.
- The list follows the server. It loads when a card or pane opens, after a park, after a cancel, whenever the row's queued count moves on a refresh, and every 15 seconds while a surface shows a non-empty queue, so a delivery drops its row without a click. The card shows at most three rows and points at the session view for the rest.
- Helper: `session-chat-queued --provider --thread-id` reads the queue; `session-chat-queue-cancel --provider --thread-id --client-turn-id` cancels one and reads back cancelled, already_delivering or unknown_turn.
- Tests: the helper self-test drives the cancel classifier and the row projection (704 checks, floor raised); ModelsContract executes the row decode, the state lines and the card's three-row cut; run.sh pins the two verbs, the DELETE, the × gated on a waiting row, the pane's Cancel, the ledger prune and the queued-count hook on both surfaces; the pet harness renders the card with a queue.

## 0.5.234 (build 272)

Message a session from the pet, and meeting times read on a 12-hour clock.

- The Session Pet can send a message into one live session (Miles, 2026-09-17: "co-op the update that Codex pushed to their pet ... leveraging the continue functionality that we built for the G2 glasses"). Each live row in the RUNNING list carries a fourth path, a paperplane, beside Open in platform, Open the session view and Drop; it is also in the row's right-click menu. It opens a card above the figure that names the target ("TO ◇ COS-glasses Server work"), with a field and a round send button, in place of the list, so a message costs one card and never a card and a list. Return sends, Option-Return starts a new line, Escape closes. Claude, Codex and Cursor sessions all take it; the server publishes which providers it binds and the pet reads that list, the same gate the Sessions pane uses. A scheduled job, a finished row and a session the server will not bind show no paperplane rather than a dead one.
- A session mid-turn takes the message the way the glasses do: it is parked on the COS server's queue and lands the moment the turn ends (Miles, on the first live send: "Why can't we use the same continue queued approach as we do on the G2?" — the first cut printed "Your Mac is writing to this thread right now" and greyed the send). The card says "Working right now. A message you send waits and lands when this turn ends." and the send stays live; after Send it reads "Queued. It lands when this turn ends." with its place in line, the row shows "1 queued", and the drainer delivers into the live Claude window when the engine closes the turn (6.48.1 queue-and-deliver, 6.49.0 live hop). The same happens when a send meets the busy thread after the card opened, and the Sessions pane's composer parks the same way, with Retry and Fork kept for what the queue will not take. Only the two refusals the server itself parks behind (`native_thread_working`, `native_target_busy`) queue; a structural refusal still disables the send with the server's copy, and Cursor, which the server cannot queue, says so and asks you to wait for the turn to end.
- What the send does is what the glasses' Continue does, over the same binding routes: attach once, one turn with a fresh id, one silent re-attach if the server says the binding is gone, never a second copy. A running Claude session takes the message into its own window (glasses-server 6.49.0 answers 200 `via: live`); a Codex or Cursor session, or a quiet Claude one, is queued and the server opens the thread with the reply landing in its transcript (202). The pet does not follow a queued turn to its end; the row's live line shows the session working from the poll it always ran, refreshed the moment the send is accepted.
- The card shows where the message is. Send lifts the text out of the field into a chip and the button becomes a ring; when the session has it the ring becomes a check, the chip and the card's edge go gold, one line says "Landed in the live session." or "Sent. COS is opening the thread; the reply lands in its transcript.", and the card closes itself 2.8 seconds later. A refusal keeps the card, prints the server's copy verbatim under the field in amber, puts the text back in the field, and offers Open the session view, where Fork, Retry and Continue anyway live. Before the first send the card asks the server whether the thread can be reached: a thread it cannot reach disables the send and says why; a thread another app has open gets one quiet line under the field instead of the pane's confirm, because the row was chosen on purpose. A card that closes mid-send still reports: the result lands as a pet notice with the session's name.
- Typing in the pet does not bring COS Control forward. The pet is a nonactivating panel; it now answers that it may become key, so the field takes keystrokes while the agent's terminal stays the active app, and when the card closes the pet steps out and back so the keyboard returns to that terminal. A click into another window closes an empty, idle card like a list; a draft or a send in flight survives it.
- The pet and the Sessions pane share one binding per session. Attaching twice to one thread is refused as busy against COS Control's own binding, a self-inflicted thirty-minute dead end, so both paths read the shared cache before they attach and both drop it when the server says the binding expired.
- Meetings, Speakers: a meeting time reads "1:02 PM" and "12:37 AM" instead of "13:02" and "00:37" (Miles, 2026-09-17: "Rather than 13, we should see 1:02 pm"). The server still sends `HH:mm`, sorting and recency still read it raw, and the merge sides compare it raw; only what is drawn changes, on the meeting rows, search hits, the detail header, both sides of a suggested merge, and Meetings to review under Speakers. Settings, Advanced, Clock offers 12-hour (the default) and 24-hour. Times the app already drew from a date, such as Sessions and the meeting audio rows, keep following the Mac's locale as before.
- Helper: `session-chat-queue --provider --thread-id --client-turn-id` (prompt on stdin) parks a turn on `POST /api/agent-sessions/:provider/:threadId/queued-turns` and reads back parked, thread_free (send now), route_absent or the server's refusal; `session-chat-send` forwards the server's `via` on a completed turn, so a live hand-off reads as landed rather than recorded.
- Tests: the helper self-test drives the queued-turns classifier (202 parked, 409 thread_free vs any other 409, 423 structural, 404 route absent, 5xx unavailable) and pins the queueable pair (697 checks, floor raised); run.sh pins the park verb, the pair mirrored in helper and model, the probe arming the park path instead of blocking, park-before-attach, and thread_free falling through with the same turn id. `ClockStyle.format` is executed across the hour edges (midnight, noon, single-digit hours, a malformed string returns itself); run.sh pins the send path in both row builders and the slot, the context-menu path, the composer card's target line, the chip transition, the three send-button states, the key-window override on the panel, the outside-click rule, the shared binding cache on both attach paths, the `via` forward, and the clock picker under Advanced; the trailing slot is 74pt now (four glyphs) and still fixed. `Tests/run-pet-composer-ui.sh` renders the pet column offscreen in the four card phases, light and dark, plus the list at rest, through a `SessionPetCanary` seam (the ring and the check were rebuilt as plain views after the first render showed a disabled Button dimming the check).

## 0.5.233 (build 271)

A Claude session shows what it is doing right now, and Sessions can install the hooks that make that possible.

- Opening a Claude session shows a live Activity block above the stored turns: the state word with a clock ("Working 4m 12s", "Waiting · Permission: Bash git push", "Failed · rate limit", "Idle · last reply: …"), the prompt the session is on, and the last eight things it did as one line each (Read …, Edited …, Ran …, Searched …, Delegated …). The block moves the moment the COS server sees the event (server 6.48.1 and later stream the state the hooks derive), and the clock ticks on this Mac. The lens already draws this trail; the phone follows in its next build; Control had a static pane.
- The feed opens at the start of the current turn and resumes where it left off. A dropped connection reconnects three times with backoff, asking the server for only what was missed, and says "reconnecting…" once; a server that cannot stream (older than 6.48.0, no transcript to follow, or out of stream room) leaves the stored turns in charge and says so in one line rather than an empty box. "missed N" appears when frames were lost so a gap is never silent.
- The composer names the fork mode and the queue. When another app on this Mac holds the session it now says the reply lands in the transcript and the open desk tab will not show it until you resume, which is what happens; and "1 follow-up queued; it lands when this turn ends." shows under the send box while the server holds one (the server delivers it the moment the engine closes the turn, 6.48.1). The Activity block carries the same "1 queued" chip.
- Sessions can install Claude Code's hooks from its own UI. When the COS server reports the hooks missing, drifted or the script outdated, a banner under the search bar says so and offers Install hooks (or Reinstall hooks); the helper asks the running server to merge them into `~/.claude/settings.json` and then reads the status back, so "installed" is the server's word, not a guess. A server before 6.48.0 says "Live session state needs COS server 6.48.0 or later" with Update Server, never "not installed"; a server that does not answer shows nothing.
- Under the hood: a new helper verb `session-stream` opens the server's event stream and writes one line per event on the progress channel, ending with one JSON line that says why it stopped (done, heartbeat gap after 40 s, the 6 h ceiling, or an HTTP status); `session-hooks-status` and `session-hooks-install` back the banner. The app reaches all of it through HelperClient, one process per open pane, cancelled when the pane closes.
- Tests: an executed contract replays eighteen recorded 6.48.2 frames through the feed reducer (the newest eight tools with prose skipped, elapsed off `state_since`) and drives the rules a recording cannot show (a seq gap counts as missed, a reseed clears, a new prompt starts a new window, waiting and failed read as words); the helper self-test drives the SSE frame parser with torn, joined and comment-only chunks and pins the heartbeat gap above two missed beats (690 checks, floor raised); run.sh pins the verb wiring, the no-timeout HelperClient call, the bounded reconnect with `--after`, the pane order, the composer lines and the banner's five states.

## 0.5.232 (build 270)

Meetings, threads, memories and session replies read as documents, the actions on a pane come in three weights, and Sessions reads the server's own state.

- A meeting, a thread, a memory and a Claude reply are stored as Markdown, and through 0.5.231 every pane printed the raw text: `## Attendees`, `| **Date** |`, `<details>` and all, and the meeting pane printed Attendees and Summary as fields and then the whole file again under Transcript (Miles, 2026-09-15: "Can we style these screens ... similar to what we can get from .md FluxMarkdown"). Every pane now renders the file once as a document in Control's own vocabulary: Fraunces headings with a hairline under them, the metadata table as a key and value grid, bullet and numbered lists, task items with their box and the `[REVIEW]` marker, inline code, quotes, rules, and the transcript's details block as a disclosure that names its speakers in mono and counts its lines. The title stays in the pane header, so the file's H1 is not repeated. Copy summary, Copy transcript, Copy as context and Copy as Context keep copying the stored Markdown, byte for byte.
- Actions by weight (Miles: "create some distinction on the high use UI elements"). Copy as context is the one filled gold button on the meeting pane and takes ⌘C; Copy as Context the same on a thread or memory. Copy summary, Copy transcript and Reveal in Finder are quiet outlines. Review voices wears a gold outline with its NEW pill inside the button while the meeting is new to review, then settles to quiet.
- Sessions reads the state the COS server derives from Claude Code's own hooks (glasses-server 6.48.0 and later). The helper carries the eight fields on every row, peer, overlay and search hit, and when the server's source is the hooks or the registry that state decides the row: a permission prompt reads "Waiting · Permission: Bash git push" the second it appears instead of after fifteen minutes, a rate limit or an overloaded engine reads "Failed · rate limit" and sits in the pet's WAITING ON YOU section rather than Idle, and a queued follow-up counts on the chip ("Running · 1 queued"). Against an older server nothing changes: the helper's transcript reading stands.
- Tests: an executed Markdown parser contract on the scribe's meeting file (headings, the metadata table, lists, tasks, code, quotes, rules, details, speaker lines, the title drop, document detection); the helper self-test pins the four projections, the overlay and the state mapping (685 checks, floor raised); `run-markdown-ui.sh` renders the meeting pane, the thread pane and the three action weights light and dark and asserts no raw heading, table separator or tag survives.

## 0.5.231 (build 269)

A thread opens with everything COS holds for it, and Copy as Context carries all of it.

- Thread detail showed only the thread's first note. Stakeholders, linked meetings, milestones and sources all reached COS Control and were dropped before the pane drew, so Project Mainstreet, which holds 42 sources, 17 milestones and 6 meetings, opened as one paragraph. The pane now shows the note, then the target date, when the thread was seen, its topics, and a section each for stakeholders, meetings, milestones and sources, in the order the glasses already use.
- Copy as Context copies that same body, so a pasted thread brings its sources and meetings with it.
- Each section counts what arrived. The COS server sends at most 30 sources and 30 milestones per thread, each shortened to 500 characters; Meetings says "6 of 9" when the thread links more than were sent.
- With the COS pipeline as of 2026-09-15, meetings show their date and title instead of an id, and the 30 sources kept are the newest.

## 0.5.230 (build 268)

Meetings another recorder made come in, and COS says which ones are the same meeting.

- Meetings has two new doorways: Import meetings and Suggested merges. Import meetings connects Fireflies with an API key, picks how far back to look (7, 30 or 90 days), sets the plan so COS stays inside its daily call limit, and can keep bringing new meetings in on its own. The key is typed once, stored on this Mac and never shown again; it is handed to the helper over stdin, so it never appears in a process list.
- Every importer state says what happened and offers something to do about it: a refused key, a rate limit, Fireflies being down or unreachable, a daily call limit reached, meetings still processing at Fireflies. On a Mac whose COS pipeline already brings Fireflies meetings in, the card says so and points at suggested merges instead of importing them a second time.
- Suggested merges lists what COS thinks is one meeting recorded twice, with both sides and how many phrases they share. Merge or Not the same meeting in imports mode; Looks right or Not the same meeting where COS only advises, with the line "COS does not change your pipeline's files in advise mode. Your answers are saved." The list scrolls in place, so a long queue never pushes the header off the window. Both sides carry their title, start, length and source as the COS server resolved them, on a Mac with a COS pipeline as much as on one without; a side the server could not place in the library says "Not in the library" under that side alone.
- A merged or split record says how it was made and can be undone. Undo shows a dry run first, naming what it removes and anything that changed since COS wrote it, and applies only that preview. The originals stay reachable from the record, and a merge COS did not make (one your pipeline made before this release) is listed without an Undo, because COS did not make it.
- A merge or an undo that did not finish can be tried again from the record. Retry asks the COS server to run it again, in the direction it was going: an undo that failed says "Undo failed" and offers "Try the undo again", never a merge. An undo the server parked behind your meeting sync says it is waiting and carries the same button, so it is recoverable without restarting anything. Refresh is its own button beside it.
- A Mac with the COS pipeline can switch COS from suggesting to merging into its meetings tree, and can undo every merge COS made from the same row, behind the same dry run. The switch is behind a confirmation that names what it does. The status row shows what the pipeline itself reads and names both sides when the two disagree, says why the last run did nothing when it did nothing, says when merges COS already made are staying put under Suggesting only, and raises an alarm when this Mac changed kind. While COS cannot say how it is merging, the pane says so and answering is off, rather than showing the wrong buttons.
- A merged record no longer counts as a recording that lost its session id, and a split piece keeps its own row instead of collapsing onto its sibling. A merge older than the hundred most recent is fetched on its own rather than leaving the record's card blank, and a card that could not load its merge says so.
- Splits are offered where the COS server can write the pieces. Where it cannot, the row says "Splits arrive as suggestions in apply mode." instead of a button that could only fail.
- How far back to look and which Fireflies plans exist come from the COS server, so the menus and the daily-call sentence follow it rather than a number typed into COS Control.
- Against a COS server older than 6.47.0 all of this reads "Update the COS server to 6.47.0" with the Update Server button, not an error.

## 0.5.229 (build 267)

COS's own background Claude runs show as scheduled jobs.

- COS starts Claude runs of its own, such as the meeting watcher's sync and the glasses server's queries. Claude Code lists each run like any session, so Sessions and the Session Pet showed rows named after a folder, such as scripts-b8, with no transcript, no Claude tab and nothing to continue. COS Control now names each run by the job that started it, found by walking the process tree up to its COS LaunchAgent: Meeting watcher, COS server, or From a Claude session for a run that a session's hook starts. Claude Desktop and terminal sessions are unchanged.
- The pet shows a running job with its script and a Scheduled job line. When a job's runs finish it keeps one DONE row with the last finish and today's run count, so a burst of runs never pushes a session's finish out of the list, and a job finishing never counts as NEW.
- Sessions marks a running job SCHEDULED JOB and lists today's finished runs under Scheduled jobs today with their script, finish time and duration. Opening a job shows those facts instead of a transcript, with no Open in platform and no Continue. Runs are recorded while the Session Pet is on; a run that starts and ends between two of its refreshes is not.
- Meeting audio alert telemetry is readable: `log show --predicate 'subsystem == "com.gotcos.control"'` shows permission answers, posting errors and failed checks. 0.5.228 wrote them with NSLog, which the unified log redacted to <private>.

## 0.5.228 (build 266)

The meeting audio alert fires only when the phone is still running and its audio is not.

- An alert now needs a phone heartbeat that arrived at least 30 seconds after the last audio chunk. A phone that goes quiet on both channels at once (relaunched, offline, or recording without the Mac) reads No word from phone and never notifies. Replayed over the 29 G2 meetings with heartbeats from 2026-09-10 to 09-14, 0.5.227's rules posted 17 notifications; 0.5.228's post 3, the two phone-lock drops and one storage pause, at the same moments.
- A phone whose upload queue keeps growing is still recording. That meeting reads Phone catching up and does not notify.
- A heartbeat counts as recent for 3 minutes, matching the server, so a locked phone's paused timers no longer turn a drop into No word from phone halfway through. A meeting leaves the Meeting audio rows after 30 minutes with neither audio nor a heartbeat, when Retained captures lists it, and within a minute of the phone's Stop.
- Pause notifications name the reason: a storage limit, a storage error, or a plain pause. When two meetings are live, each row and notification shows its start time.
- When audio reaches the Mac again, its notification is removed from Notification Center.
- During a live meeting the panel shows Meeting alerts: Off for COS Control, with a Notification settings button, when macOS is not showing COS Control's alerts. COS Control asks again while macOS has no answer on record. Permission answers and posting errors are logged (`log show --process "COS Control"`).
- A failed check clears the Meeting audio rows instead of leaving the last ones on screen, and a check that finishes after a newer one is ignored.
- One notification per drop holds while COS Control stays open; relaunching mid-drop notifies again. The alert shows on this Mac only, and a Focus that does not allow COS Control holds it in Notification Center.

## 0.5.227 (build 265)

COS Control tells you when meeting audio stops reaching this Mac.

- While a G2 meeting records, COS Control checks on every 12-second status refresh when the last audio chunk reached this Mac and what the phone last reported. When the phone's newest heartbeat is under 90 seconds old and says it is recording with the microphone on, and no chunk has arrived for 60 seconds, it posts a macOS notification: "Meeting audio stopped reaching your Mac". A phone storage pause posts "Meeting audio paused on your phone". One notification per drop; the same meeting can notify again once its audio has reached the Mac again.
- The panel shows a Meeting audio row for each live meeting: Reaching this Mac, Stopped, Paused on phone, No word from phone, or Ending. A phone with no heartbeat for 90 seconds never notifies, because a phone recording offline sends neither heartbeats nor chunks.
- Why: on 2026-09-14 two phone locks stopped meeting audio for 8 and 9 minutes while this Mac kept receiving the phone's heartbeats, and nothing reached the wearer. This Mac is the one place that sees both facts.
- The first launch asks for permission to send notifications. The alert reaches you where you can see this Mac; a push to the phone is a later step.
- Reads `active-sessions/` and the end of `client-diagnostics.jsonl` in the glasses data folder. No server change: works with server 6.46.0 and any glasses build that sends meeting heartbeats.

## 0.5.226 (build 264)

Session names match the Claude desktop tab.

- The Session Pet and the Sessions tab name each Claude session with the title Claude Desktop shows on its tab. The pet showed the registry's derived name, such as mu-chief-staff-bc, for any session started after Sessions last refreshed, and the Sessions tab showed the first prompt or skill name for newer sessions.
- An idle row on the pet says idle, not working, when the session has no summary.

## 0.5.225 (build 263)

The Session Pet shows what Claude sessions are actually doing.

- A live Claude session reads from its transcript's newest user or assistant record, the timestamp rule server 6.45.5 uses for the phone's Sessions list. A finished or interrupted turn reads idle at once, so the finish lands when the turn ends. A running tool call reads working, a pending AskUserQuestion or ExitPlanMode reads waiting, and a turn with no new record for fifteen minutes reads waiting rather than finished, since that is usually a permission prompt.
- A subagent still working keeps its session working, including parallel batches and background agents, which write to their own transcripts.
- Local commands, meta records and bookkeeping writes to an idle transcript do not read as work. A newest record larger than 200 KB, such as a prompt with a pasted image, is read.
- A session that appeared after Activity last refreshed keeps its full id, so a later refresh no longer counts a false finish. When the server answers, a cached session it no longer lists stops reading live.
- The pet paints Activity's snapshot only until the live helper first answers, which stops the flicker between the two and lets a dismissal stick. Activity's Sessions list reads the same transcript records.

## 0.5.224 (build 262)

The Session Pet tracks live work again. Installed on one Mac only and never offered through the update feed; 0.5.225 supersedes it.

- A running Claude session reads as working while its transcript moves, including sessions started from the Claude desktop app, whose session registry carries no status. Since 0.5.214 the pet's live rows started from the Sessions cache, whose last-activity time only advanced when Activity walked the list, so a few minutes after Activity closed every session read idle.
- Live peer times from the server arrive as epoch milliseconds and now reach each row as dates instead of blanks.
- Waiting on you still comes only from the status Claude Code publishes. The Claude desktop session measured for this fix publishes none, so such a session cannot show as waiting.

## 0.5.223 (build 261)

Name held voice samples with a preview of the meeting labels, then apply or undo.

- Each loose sample has its own row and can show an existing voice suggestion with its score and owner-proximity caution. Long lists scroll in place, including a 239-row fixture.
- Add to a person and Name open a read-only preview. The preview separates enrolled samples from transcript labels, shows each meeting and its named/wider matches, plays only a complete server-provided raw-audio mapping, and requires listening or owner acknowledgment when the server calls for it. Apply carries the preview hash and fails closed if the meeting changes.
- Results retain per-meeting and per-copy outcomes. Undo restores this batch’s labels while keeping voice samples enrolled and deleted audio deleted. Interrupted naming is visible on view-open; Resume requests a fresh preview and Revert is explicit. Labels newer than the graph remain visible, and indexing copy says search catches up at up to 10 meetings per run.
- Requires the server 6.46.0 naming capability for preview, Apply, and Undo. Older servers keep listening and discard; Control verifies the capability before every naming request so a preview cannot accidentally reach an older applying endpoint. The helper preserves 400, 409, 422, and 503 response bodies.
- Validation includes helper self-tests, an isolated HTTP transport test, and 239-row / unicode / raw-index / expired-preview / undo-after-deletion model contracts. Release artifacts are prepared separately from publication.

## 0.5.222 (build 260)

Speakers has three views, and the toolbar stays on screen.

- Speakers reads Meetings to review, Samples to review, and Voices (Miles, 2026-09-13: "There's no place for us to review existing speakers"). The Add a voice card sat on top of the voice directory with a fixed-height list. It could not shrink, so in a normal window it squeezed the enrolled speakers to nothing and made the column taller than the window, and the window centered the overflow, clipping Home, Back and the breadcrumbs. An offscreen render of 0.5.221 with real data reproduces it.
- The Activity window pins its content region under the toolbar (minimum width and height zero, top aligned) and clips it, and the window minimum is now a content size. The old minimum counted the title bar, so the content could be 28 points shorter than the view asked for.
- Samples to review is the Add a voice card on its own. Past four rows (five sessions on an older server) its list scrolls in place and fills the view, above a floor of about one row. The line that says naming uses the audio up sits above the list, where a short window cannot clip it. Until the grouping route answers, the card says it is grouping instead of showing the per-session rows, whose Name uses enroll-ext. The card's second Refresh is gone; the view's Refresh reloads it, and a result notice clears when you change views.
- While naming a held voice, a line says whether the name adds to an existing person (the server appends only on an exact match) or creates a new voice, with up to three near matches as one-click fills.
- Voices lists every enrolled speaker with SAMPLES, the voiceprints stored in the profile (shown on any server), and CONFIDENCE: the share of the voice's scored speech the server rated confident, with the segment-weighted average match under it and "thin" below 10 scored segments. The detail pane uses the same name. MATCH is gone and SEGMENTS moved after MEETINGS. Sort adds Most samples and Lowest confidence, which ranks voices with enough scored speech first. Counts carry thousands separators, rows use the gotcos fonts and hairlines, the search field and sort menus use the COS styles, and a search with no match says so with Clear search.
- An empty directory opens Samples to review in one click; a directory that failed to load offers Retry instead. The Meetings empty state and the zero-profile message also point to Samples to review.
- A refresh asked for while the directory or the held sessions are already loading now runs after that load instead of being dropped, so SAMPLES is current after naming a voice and switching views.

## 0.5.221 (build 259)

Add a voice speaks the gotcos theme, in light and dark.

- Speakers, Voices, Add a voice: the card now uses the vocabulary the rest of the window uses. It sits on the warm card with a hairline, aligned with the voice list below it; the title is set in Fraunces, prose in DM Sans and counts in JetBrains Mono. The blue system link buttons are gone (Miles, 2026-09-13: "the blue links are kinda odd"). Name this voice and Add to X? are quiet chips; Save, Confirm and a high-confidence Add to X are the gold primary button; Cancel and Keep are muted text actions; Discard is a text action that becomes a red chip to confirm.
- Listen is a round play button that fills gold while a sample plays, with previous and next around a "3 of 119" counter, in one column so the rows scan as a list. A suggested person's name is set in the accent color, the agreement figures in mono.
- Every color is an adaptive palette token. Views.swift gains accent, danger, muted and raised with the light and dark values the Memories theme already uses (gold is too faint to read as text on a white card, so light mode uses the theme's darker accent). The new COSTextButtonStyle, COSIconButtonStyle and the destructive tone of COSQuietButtonStyle live in COSBrand.swift for the other panes.

## 0.5.220 (build 258)

Naming a held voice is disabled when the Mac has no speaker model, as 0.5.219 said it would be.

- Speakers, Voices, Add a voice: the helper now passes the server's `speakerModel` flag through from `GET /api/voice/held-groups`. In 0.5.219 the helper dropped it, so the panel always assumed the model was loaded. On a Mac without the speaker model, Name and Add to a person stayed enabled, and every click was refused by the server (`speaker_model_unavailable`) with nothing changed. The panel now says the model is not loaded, keeps Listen and Discard, and disables naming.
- A Mac with the model loaded sees no change. If a server omits the flag, Control still assumes the model is loaded, as before.
- Tests: the held-voice contract now requires the helper to forward the flag exactly once, inside `emitVoiceHeldGroups`. The 0.5.219 pin checked only the controller's read of the field, which is why it passed while the helper never sent it.

## 0.5.219 (build 257)

Held voices, grouped by who they sound like.

- Speakers, Voices, Add a voice: against glasses-server 6.45.4 the panel lists VOICES, not sessions. On Miles's own store that is 81 voices and 442 loose samples out of 906 held chunks across 32 sessions, listed in about a third of a second. Each row is one person's held samples across every meeting in the window ("14 samples · 3 meetings"), with the 0.5.218 Listen control stepping through them from the server's most representative sample. A row the server can match to an enrolled profile says so ("Sounds like Chris 78%" at the identifier's own auto-enrol bar, "May be Chris 64%" above its floor) ("4 of 20 samples agree" beside it — the server vouches only with two or more agreeing samples, one from an anchored source, never from a bulk session enrol alone) with a one-click "Add to Chris", which appends the samples to that profile — the self-healing loop for a voice that missed in a new room. "Name this voice" creates or appends to any name; the server re-checks that the set is one voice and writes only that core. Miles, 2026-09-12: "group those samples together… clump users together so that we're not constantly having to train."
- Loose samples — the ones that match no voice, the random artifacts — sit in one row with the clip's meeting time and chunk under the cursor: listen through them, name the one under the cursor on its own, discard it, or discard them all (sent in slices, so a full week's loose set goes in one gesture). Discard is two clicks everywhere; adding a "likely" match to a profile is two clicks too, and only a "high" match — the bar the identifier itself enrols at — is one.
- Honest when it cannot group: with the speaker model not loaded on the Mac, or samples still being read, the panel says so and keeps the per-session rows instead of claiming nothing is held; a failed grouping call is shown, not swallowed. A reload asked for mid-load is queued, not dropped. After a naming or a discard every cursor starts over; a discard that fails part-way says how many went and refreshes. While the Mac has no speaker model the panel says so, disables naming (the server would refuse it), and keeps Listen and Discard. The server fails closed without `confirm`, and the helper sends it after Control's own gate; a 404 names the version the panel needs (6.45.4).
- The grouped list is capped like the session list (four rows, then a fixed scrolling frame). On an older server the panel keeps the per-session rows, unchanged.
- Helper: `voice-held-groups`, `voice-held-enroll --name <n> --members <json>`, `voice-held-discard --members <json>`. The member list is validated and de-duplicated before any request (self-test pins); the server's own refusals (a sentence for a name, a set that is not one voice) are surfaced verbatim.

## 0.5.218 (build 256)

Listen to a held voice before naming it.

- Speakers, Voices, Add a voice: each held session now has a Listen control beside its sample count: play or stop, "sample k of N", and previous or next to step through the chunks the server still holds. Plays through the same player as the meeting review. Queen, 2026-09-12: "There is no way to listen to the voices that are here and add them from the top panel."
- Shown only when the server reports the chunk indices (glasses-server 6.45.3); on an older server the row looks as before, so the button never appears where the click would fail.
- Helper: `review-audio --session <id> --ext-chunk <n>` asks `GET /api/voice/ext-audio/<id>/sample?chunk=<n>`; the route choice is a pure function with self-test pins.

## 0.5.217 (build 255)

QA fixes on the 0.5.216 reward chrome, from four validators against the installed build.

- Applied never asserts a path or a measurement it has not read: before status answers it says it is checking; a failed status says so; an empty trace says use has not been recorded yet rather than none this week.
- The Applied card no longer fabricates "Recorded 1 time": the count comes from the projector title or is omitted, a lesson record that fails to load says so instead of loading forever, and the raw id appears once.
- One ranking sentence in one place, present tense, gated on the literal flag, pinned to appear exactly once. The flag now reads `COS_MEMORY_REWARD` with the hook's own predicate, so an empty or unknown value is off on both sides.
- Applied fails closed when a server returns unfiltered rows, dedupes Load more by event id, keeps the 7/90-day switch in the header, shows errors and coverage gaps in the list column, and clamps excerpts with ellipses.
- The activity log counts overflow from the window total and reads the legacy trace sink as readable.
- Status refresh has a 45-second deadline, so a helper blocked in a permission prompt errors instead of leaving every row at its default.
- The updater backs up the live bundle only when it is a different build and names it in `updates/previous/version.json`; a same-build re-apply can no longer overwrite the rollback copy.
- The helper is signed with an identity-based designated requirement so Documents-folder access survives updates; one more prompt on this install, then none.
- Codex rollouts are readable by the applied detector; the ranking penalty counts only inclusions the detector actually scanned, so an unreadable engine cannot demote a lesson.

## 0.5.216 (build 254)

Sessions rows wear the bundled Claude, Cursor, and ChatGPT marks.

- Activity list uses the same `mark-claude` / `mark-cursor` / `mark-codex` SVGs as the pet. Codex uses the ChatGPT blossom, not a Codex wordmark.
- COSQuiet card chrome is unchanged. Claude opt-in still hides only Desktop Claude rows.

Memories reward chrome, for the person who wrote the lesson: did a later answer use it.

- Applied this week: a fourth learning filter that asks the helper for `used` rows over 7 days (90 as a quiet switch). Rows show the lesson, the assistant sentence that referenced it, engine and time; the card shows the lesson, the excerpt, and, only when the projector says the reward term is on, one sentence that later recall ranking moved. Never a number.
- `helperOps` forwards `kind` on `learning.list` from the projector's closed vocabulary; the page no longer depends on the first Recent page.
- Empty states follow the memory path this install chose: bridge saw no use; files and Knowledge cannot detect it; an unreadable trace invents nothing.
- The activity log names the lessons a later answer used, capped at ten, before the type counts.
- Helper status carries `learningRewardEnabled` from the projector's `reward_enabled` (COS_MEMORY_REWARD); absent is NSNull, never true.
- Home chip stays Needs you. Applied is never badged.

## 0.5.215 (build 253)

Memories chrome reads real projector data: Needs you, not the SIQ dump.

- Home chip, activity number, and To review(N) use `needs_you` (gated, cap 7). They no longer sum `to_review` patterns + task proposals.
- Server 6.45.1 still strips that field; the helper overlays `learning_events.py needs-you` (90s cache).
- Captured cards render `used` / `checked` / `retrieved` rows from the same lesson. Empty Expected effect / Checks / Repeat / Next use stay hidden when unobserved.

## 0.5.214 (build 252)

Sessions opens from cache. The 7-day walk no longer blocks first paint.

- First paint reads `session-list-cache.json` (last successful list plus dropped counts). Header shows Refreshing while the full walk runs.
- No cache: a mtime/size index paints pinned and recent rows without opening hidden transcripts. Totals (older / over cap) come from that index, then the server walk replaces them.
- `session-pet-live` uses the cache plus live Claude peers. It does not wait on `/api/agent-sessions`.
- Refresh still forces a fresh walk. Search and Recency still filter the in-memory list.

## 0.5.213 (build 251)

Knowledge modal sits above the graph rail. Sync Indexing names pending vs batch size. Real records opens source records.

- Recent learning overlay uses an opaque backdrop at z-index 300. Graph Layout/Keys chrome stays behind or hides while the modal is open.
- INDEXING shows the live pending count. Batch size is a labeled picker (10, 25, all), not "the next 10". Index now has a --line hairline on the white card.
- Real records is a button. It opens Source records ("What was actually said") and scrolls to that heading.

## 0.5.212 (build 250)

Tasks: Done on every row. Schedule owns its timestamp. Overlay is a paper card, not a drop shadow.

- Run at is no longer a board-level orphan. Capture files to inbox. Schedule opens a date picker.
- Each row has Schedule, Run now, and Done.
- Task overlay uses the same card/hairline as the board. No drop shadow.

## 0.5.211 (build 249)

Done actually completes a task. Ask the graph shows source titles and dates next to [S#] citations.

- `task-check` reaches the server, so Done / Reopen no longer print `unknown command: task-check`.
- Ask citations `[S1]` are links. Evidence references render as a Sources list with meeting title and date, outside the answer scroll.

## 0.5.210 (build 248)

Knowledge Ask progress, clean graph-rail labels, and a truthful Meeting sync row on server 6.45.1.

- Graph rail labels (Layout, Edge strength, First indexed, Entity types, Keys) no longer ghost through backdrop blur.
- Ask the graph shows a spinner and elapsed status while the question runs, including the Setup ask step.
- If HQ polish reports Idle during library handoff or a live recording, Meeting sync names the real work and keeps Update/Restart blocked.

## 0.5.209 (build 247)

- Drain internal command output while the child runs. A blocked launchctl write could make a healthy managed server appear orphaned and prevent updates; status and update now capture output without waiting for process exit first.
- Bound captured output, timeout cleanup, and pipes held by descendants. Preserve the prior EOF/CPU repair and all 208 Knowledge, owner, appearance and retained-capture improvements.

## 0.5.208 (build 246)

A simpler Knowledge view and truthful capture recovery (server 6.45.1).

- Memories follows the app’s light or dark appearance, including graph inspectors and tooltips.
- Ask the graph is the primary Knowledge interaction. A populated, bounded graph opens below it; manual controls remain under Advanced investigation.
- Verified answers can choose anchors and waypoints. Late answers preserve manual edits, dragging, pins and owner changes; saving remains explicit.
- Set the person COS serves in Memory settings. Changes preserve other profile fields and do not transfer indexing or memory authority.
- A single retained meeting has one Save action. Captures without a usable transcript show their state and retain their audio without offering a Save that cannot succeed.

## 0.5.207 (build 245)

Memory review, relationship exploration, and reliable fork transcripts (server 6.45.0).

- Stop timed-out helpers from leaving closed-pipe monitors spinning in the
  background. Helper output, progress, cancellation and pipe cleanup now share
  one bounded transport; repeated failures cannot accumulate EOF callbacks.
- Explore connections between two anchors, add waypoints, expand bounded hops,
  inspect source passages, and save a path. Association is labeled separately
  from causal evidence. Keep anchors separate records a reviewed identity rule.
- Memory review distinguishes captured, proposed, saved, used, and checked
  evidence. Changes carry revisions, receipts, and explicit stale-data handling.
- Resolve Claude Desktop sessions through their explicit CLI identifier so an
  alias opens its local transcript. Same-title forks remain separate; ambiguous
  or missing mappings fail closed.
- Continuing in a fork opens the exact child returned by the helper. Navigation
  during a fork cannot append its prompt to the parent or replace another session.

## 0.5.206 (build 244)

The Speakers empty state names the meetings it cannot review and why.

- Chelsie and Queen, 2026-09-08: "Meetings to review is empty, and it says 3
  recent meetings have no session id and can't be reviewed. Is that expected
  for recordings from before 6.44?" It was not a version problem, and the
  sentence gave nothing to act on. The helper now reports the skipped rows with
  their source, and the empty state says how many came from Fireflies or
  another source (no G2 audio to review) and names any G2 recording that was
  saved without its speaker sidecar, with the file title and date, so the user
  can report exactly which one.

## 0.5.205 (build 243)

Merge from the Manage sheet, with a preview from the owner Mac and a receipt, and a
Possible duplicates card that proposes and never merges (server 6.44.14).

- Miles 2026-09-08: "Build the Manage merge path with the preview" and "address any of
  the obvious duplicates like the miels and queen example from above without clobbering
  entities."
- Merge into… in the explorer's Manage panel now runs for real: after the explorer's
  own comparison, a second sheet shows the owner Mac's preview (both entities as the
  index knows them, shared neighbors, relationships moved and collapsed, texts re-embedded,
  about how long, and every warning), then one more click starts the merge. The page
  polls the receipt every three seconds, shows each step (snapshot, merging, rebuilding
  the index, exporting), and re-reads the graph around the surviving entity when it is
  done. A pair the graph knows to be different people (Miles Ukaoma and Miles Mallard,
  Manoj Bisht and Manoj Kumar, the Kyles, the Jacobuses) is refused with the reason and
  the explorer's local change is undone. Rename and Remove still say they are not built.
- Possible duplicates: a card under the graph lists person entities whose names look like
  one person, grouped under the full name with the most connections, with each member's
  connections, shared neighbors and why it was grouped. Preview merge on a member opens
  the same two-step sheet. Nothing merges on its own.
- Explorer: the host now decides whether a change applied. A refused or failed change is
  undone in the view and its row says refused; the "Changes" list is named for this session
  and no longer offers the prototype's Revert on real data.
- Helper: `context-graph-merge-preview`, `context-graph-merge --confirm`,
  `context-graph-merge-status`, `context-graph-duplicates`, gated on 6.44.14.

## 0.5.204 (build 242)

- An entity card's "first indexed" is a date; 0.5.203 printed the index's epoch seconds.

## 0.5.203 (build 241)

The graph's answer reads as a page, copies, and hands back the entities it names.

- **Rendered, not raw.** The answer's headings, bold, lists and tables render
  in the page's own type instead of Markdown marks (Miles, 2026-09-07).
- **Copy answer** puts the question and answer on the clipboard; **Copy with
  context** adds the entity cards under it, so a pasted block carries what the
  graph knows.
- **The entities the answer names come back as cards**, the same card the
  inspector shows: type, connections, first indexed, the description, the
  strongest relationships, with Copy context, Show passages and Explore from
  here. Headings and bold names are looked up in the index; an exact id wins,
  then a person. A card says "in view" when its entity is in the neighborhood
  above, and Explore from here loads the rest, so the two containers work as
  one reading of the graph.

## 0.5.202 (build 240)

Ask the graph in plain language, from the focus.

- Under the Knowledge graph there is a question box prefilled from the focus
  and its strongest neighbor ("Show me the relation between Queen and Miles
  Ukaoma"), with one-click pairs for the nearest neighbors. Enter runs the
  same hybrid graph query the setup step uses (about a minute, two model
  calls under the subscription); the answer renders in place, marked as a
  synthesis rather than a quote, and the names it mentions become focus
  buttons. Nothing new reaches the helper: it is the existing graph.ask op.

## 0.5.201 (build 239)

Prune or accept a captured memory, and guardrails that prune nonsense for you (server 6.44.13).

- **Accept and Prune on a captured memory.** A "COS captured this" card in the
  lesson timeline now carries Accept (keeps it and marks it reviewed) and
  Prune (two clicks; deletes it from bot memory). Both become timeline events,
  and a pruned memory leaves the lists at once.
- **Guardrails in Memory settings.** Your own rules for what a captured
  memory must be: minimum words, distinct characters, a repeat-ratio ceiling,
  banned patterns; and an optional model pass that judges what survives
  against the COS philosophy principles, on the tier you choose, at most N
  per run. The same rules refuse nonsense at capture time.
- **Review captured memories now.** Runs the guardrails over the last 30 days
  and shows every flagged memory with its reasons; nothing is deleted until
  you press Prune the flagged. A memory you accepted is never flagged.

## 0.5.200 (build 238)

The Knowledge down-select (server 6.44.12).

- **Step 4 asks one question before the four embedding cards: may your
  text leave this Mac for embeddings?** Miles 2026-09-07: the local
  embeddings are the free path for people who run COS without an OpenAI
  key, and the setup's job is to help each person down-select. Two
  buttons, Cloud is fine and Stays on this Mac. The answer, plus what this
  Mac already has (an OpenAI key, Ollama running), moves a Recommended
  mark onto one of the four cards with the reason in a sentence: a key and
  the cloud allowed recommends OpenAI large; stay local recommends Local
  premium when Ollama is running here, else Local light; no key recommends
  the free local path and says how to get OpenAI large. All four stay real
  selectable cards; the answer never changes the choice.
- **A chosen embedding that is not ready blocks indexing, with the fix
  named.** The card shows the one sentence that makes it ready (start
  Ollama, pull bge-m3, fetch the 130 MB Local light model, add the key),
  step 4 reads blocked, and step 5's Index button is disabled with that
  reason beside it. The server refuses the kickoff the same way (409
  `embedding_not_ready`), so nothing spawns an indexer that dies in its log.
- Against a 6.44.11 server the strip says the recommendation needs 6.44.12
  and the pickers keep working; the helper translates that server's 400 on
  a preference-only call into the update line.
- Coverage: the page is checked by source-shape assertions in `Tests/run.sh`
  (no DOM harness runs `memories-app.js`); the behaviour behind it is
  execution-tested in the server (`context-browser.test.ts`) and the bridge
  (`test_learning_bridge.py`, `test_embedding_settings.py`), plus an opt-in
  real Local light smoke (`test_embedding_onnx_smoke.py`) that fetched the
  model and embedded 384 dims in a scratch interpreter on 2026-09-07.

## 0.5.199 (build 237)

- The two choice commands name 6.44.11 when their route is missing, not 6.44.9.

## 0.5.198 (build 236)

Choose how Knowledge indexes (server 6.44.11).

- **Step 4 of Set up Knowledge is now a choice, not a description.** Two
  pickers. Embeddings: OpenAI large (the default), OpenAI small, Local
  premium through Ollama, Local light through fastembed/ONNX; each card says
  what it costs, what it needs, and whether this Mac is ready for it, with a
  Fetch model button for a local one that is not. Indexing: Fast (Haiku),
  Balanced (Sonnet), Deep (Opus); under a Claude subscription the cost is
  time and the daily budget, and it takes effect on the next run. The
  embedding serves LightRAG and every Qdrant collection alike. A graph
  already built with one embedding says so and keeps the others off until
  a rebuild path exists; a mismatch is named in red and blocks Index now.
  The privacy line follows the choice: a local embedding keeps every vector
  on this Mac.

## 0.5.197 (build 235)

- The Sync card's "View as this Mac / the Air" toggle is gone. It previewed
  one other Mac's wording and made sense on exactly one desk (Miles,
  2026-09-07: "not pushing things into production that aren't useful for
  the whole"). The card shows this Mac's real state: the owner line reads
  owner or replica from the server, so a replica Mac sees the replica
  wording without a switch.

## 0.5.196 (build 234)

- Index now says how many will actually run: "Indexing all 1 queued" on a
  short queue, "Indexing the next 5 of 36 queued" on a long one. 0.5.195 read
  "the next 5 of 1 queued" on the first real run.

## 0.5.195 (build 233)

Watch an index run as it happens (server 6.44.10).

- **Progress on the Sync card and in the setup path.** While the ingest lock
  is held, the card reads the run every five seconds and shows how many of
  the run's documents are indexed, which one is in flight and about how many
  calls it will cost, the last few outcomes with their seconds, the budget
  line, the queue's pending count, and a Show log disclosure with the last
  lines. A run started somewhere else (a Claude session) shows as "from
  another session" with the counts, since it writes no log here. When the lock
  frees, the card says what the run indexed and what is still queued. Index
  now and the sample step both feed this.

## 0.5.194 (build 232)

Knowledge from zero: a guided setup path in the Knowledge tab (server 6.44.9).

- **Set up Knowledge** is the third route beside Source records and the
  graph: seven steps, each one a live check with its own control. Enable
  (the LightRAG SDK, the model backend, the embedding key); Choose sources
  (a real folder picker, folders on and off); Owner Mac (make this Mac the
  one that indexes); Validate (backend, embeddings, today's budget, and what
  leaves the Mac); Index three sample documents (the three newest documents
  from the chosen folders through the indexer's own dedup, one bounded run,
  the card refreshing until it finishes); Ask one question (the answer, with
  its time); Scheduled batches (the `com.cos.lightrag-ingest` agent, on or
  off, every 15 minutes to a day). Every write is owner-only, and a replica
  says so in a sentence. Each person's graph, queue, owner file and sources
  stay on their own Mac by construction.
- The page's op table gains six bounded ops for the path and one native
  affordance, the folder picker; nothing else new can be reached from it.

## 0.5.193 (build 231)

The other tabs speak the Memories tab's language.

- **Meetings, Threads, Sessions, and Tasks wear the reviewed vocabulary.**
  Each pane opens with its title in Fraunces and a strip of live numbers under
  it (the month's calls, stored, days with calls; on disk, waiting, pinned;
  open, scheduled, need attention; tracked, shown), the same value and label
  pair the home tiles show. Rows are warm cards with a hairline that turns
  gold under the pointer; search and capture fields share that card; buttons
  are one quiet style with a single gold primary (Capture, a prominent
  Refresh). DM Sans carries prose and JetBrains Mono the instrument chrome, so
  no row or header in these panes falls back to the system font. The meeting,
  session, thread, and memory detail panes get the same title and label
  treatment. No new motion.

## 0.5.192 (build 230)

Knowledge opens on you, and the queue can be indexed from the Sync card.

- **The graph opens on the person this COS is about.** The helper's status
  carries the profile's owner name (masked in the redacted report), and the
  page resolves it through a graph search before falling back to COS. A focus
  you pick, recenter on, or explore from is never overridden.
- **Index now (server 6.44.8).** On the owner Mac the Sync card's Indexing row
  offers one bounded run of the queue (the next 5, 10, 25 or 50, or all of a
  short queue) through the new `context-graph-ingest` command, which is the
  page's second and last kickoff op. A run started anywhere else shows as
  "Indexing now" with its pid, and the card refreshes every 15 s until the
  ingest lock frees, then says how many were indexed and how many are still
  queued. Nothing pending, a spent daily budget, or a replica are each refused
  with a sentence; nothing is forced, and the child stops on its own limit.

## 0.5.191 (build 229)

The Memories tab is the reviewed design, on your data.

- **The prototype you reviewed is now the tab.** Memories hosts the design
  package's page itself: the hero, the summary strip, the four views, the
  two-pane workspace with the lesson list on the left and its timeline on the
  right (source, proposed change with the expected-effect rungs, later use,
  evidence), Copy context with a preview, the Learning settings and activity
  log dialogs, and Knowledge with the Sync card grid, source records, and the
  D3 explorer with its legend, recency, edge-strength, layouts, pinning,
  path tracing, inspector, passages, and Explore from here. Every number is
  live through the same helper commands the native panes used; the page
  never holds the server token, and the only ops it may post are read
  commands, the index-build kickoff, and one review decision.
- **Dismiss and Restore proposal work.** They write a review-ledger row
  through server 6.44.7; To review moves on the next read. Accept and Edit
  are present and disabled with the reason: a skill version is a later
  release. Merge, rename and remove open their sheets and say the curation
  engine is a later release; nothing is changed.
- Entity types are hue-separated on the graph (person gold, organization
  sky, artifact mint, and so on), not shades of one brown.
- The native panes remain as the fallback if the page bundle is ever
  missing from the app.
- Needs server 6.44.5 for the tab, 6.44.6 for To review, 6.44.7 for Dismiss.

## 0.5.190 (build 228)

Memories learns to say what it learned, and the knowledge graph gets a front door.

- **Memories is four views.** A picker at the top of the tab: Recent learning,
  All memories, To review, Knowledge. All memories is the list you had. The
  picker opens on All memories in this build; the flip to Recent learning is
  the next one.
- **Recent learning** is what COS captured, proposed, checked and used in the
  last 90 days, newest first, from every store it can read: bot memory, the
  correction journal, the self-improvement queue, the review ledger, skill
  versions, eval scores, the reflect log. Click one for the source excerpt,
  before/after/rule where the store has them, an Expected effect block by rung
  (what it applies to, checks, repeat rate; the preview rung says it is not
  here yet), the evidence, Copy context with an "Include related knowledge"
  toggle, and Explore in graph.
- **To review** lists the promotable patterns and the self-improvement task
  proposals waiting on you. There is no Dismiss yet, on purpose: this build is
  read-only, so it cannot move the number. That verb ships with the ledger
  route in a following pair.
- **Knowledge** opens on a Sync card: which Mac owns ingestion, what is queued
  and how old the oldest is, missing sources and iCloud conflict copies when
  there are any, what is indexed and how fresh the index is, the daily budget,
  the ingest lock, the processor. A missing or stale index offers Build index;
  the card then follows the build to done or failed. Under it, a search box:
  an entity opens as a native list, its descriptions, relationships ranked by
  weight, neighbor chips that re-select, the memories that mention it, and
  where its source records stand. No web view and no explorer script in the
  bundle; merging, renaming and removing are a later gate.
- **A hotkey opens Activity.** Control-Option-Command-A by default, from any
  app; record your own in the panel next to Launch at login, or turn it off.
- The Activity home tiles keep their title on one line: beside a wide count
  like 2,346 the count drops under the title instead of the title breaking
  mid-word.
- **Two marks on the Activity chips.** A number means needs you (unrecognized
  speaker sessions, stranded recordings, learning to review, fenced sessions,
  tasks due today plus unseen inbox rows). A dot means something newer than
  the last time you opened that section. One legend line under the chips.
  Every count is absent, not zero, when its source is.
- Needs server 6.44.5 for Recent learning and Knowledge, and 6.44.6 for To
  review (the strict set the chip counts); on an older server those tabs say
  Update the managed server and All memories keeps working. Doctor gains one
  Recent learning and Knowledge line, states and counts only.
- What /qa found before this shipped, folded the same night: the Checks row
  read a key the wire never carries (`outcome.result` now); the graph's
  `created_at` is epoch seconds, not a string; To review approximated its set
  with a kind filter (121 on the chip beside "50 of 837" in the list); an
  index build that never finished hid the Build button until Control quit;
  the build poll trusted the previous build's receipt; Explore in graph then
  Back left the Sync card at Loading; the chip row broke mid-word at a
  three-digit number; a stale search answer could repopulate a cleared box;
  a missing index read as "no matches" and as "run Doctor"; no helper call
  had a timeout; an empty edge endpoint could crash the entity pane; the
  activity signals ran ten calls every 12 s (now 60 s, 20 s budget) and a
  failed call looked like "nothing needs you"; a cursor of the wrong shape
  stuck a dot; the graph owner hostname reached the redacted report.
  Recent learning pages with Load more; entity descriptions and lists are
  capped with Show all; passages show under an entity.

## 0.5.189 (build 227)

A task says what finished looks like, and nothing runs until it does.

- **Done when.** Every task detail carries a finish line. It is the first thing
  in the sheet, and an empty one is marked, because **Run now is refused without
  it** — the server answers that dispatch with `409 done_when_required`. An agent
  sent at a task with no definition of done cannot succeed at it, and cannot be
  judged to have failed either. Setting it leaves the sheet open, since it
  unblocks the button right below it.
- **Stage.** Tasks move Planning, Active, Review. The detail shows the stage and
  moves between them. A row with no marker is Planning, so nothing needed
  migrating and every captured task started where it belongs.
- Needs server 6.44.4 for both. On an older server the fields simply read empty
  and the stage shows Planning.

## 0.5.188 (build 226)

Open a task, read it, change it. And set your own domains.

- **Click a task.** The row opens a detail with the whole line, its source, lane,
  section, schedule, agent state and ref. Rows used to render `title`, which the
  server caps at 44 characters for a G2 lens row, so every task in a 1900px
  window ended in an ellipsis. Needs server 6.44.3 for the full text; on an older
  server the detail falls back to the capped title rather than showing nothing.
- **Edit the words**, then Save text. The source block and the schedule survive
  the edit. A task with a running agent is refused, because rewriting the line
  would change the task the agent was dispatched against.
- **Done and Reopen**, which Control had no button for at all. Plus To inbox,
  Schedule, and Run now from the same place.
- **Domains card in the panel.** Add, rename, reorder and remove, written to
  `~/.cos-glasses/.cos-profile.json` through server 6.44.3 instead of by hand. A
  folder under `operations/` holding a `tasks.md` always appears whether or not
  it is listed, and the card says so: removing a name only unlists it, and the
  folder and its tasks stay.

## 0.5.187 (build 225)

The Tasks pane shows captured work, and the domain picker is the user's own.

- The pane kept only `today`, `carried`, `scheduled` and anything flagged, so a
  server holding 80 captured rows and nothing yet due reported "No open tasks"
  and read as broken. It keeps every open row now, ranked so the 30-row limit
  holds what matters: failed, missed, due, running, scheduled, then captured.
  `done` stays out — it is history, there are 121 of them here, and including it
  would push out every actionable row.
- The domain picker hardcoded Quilt / Personal / Hermit Crabs / Sprocket Rocket,
  one user's business units, so a second COS install had nothing it could file a
  task against. It reads `GET /api/domains` (server 6.44.2) via a new `domains`
  helper command. `librarySearchDomainOptions` loses the same hardcoded four.
- On a server without that route the picker derives its options from the board's
  own rows rather than emptying itself, because an empty picker removes the only
  way to file a task. Label and abbreviation are derived the same way the server
  derives them, so the two agree.
- A 404 on a task route named 6.44.0 regardless of which route was missing,
  which told a user already on 6.44.1 to update to a version they had. It now
  names the route and the version that route actually needs.

## 0.5.186 (build 224)

Tasks is a seventh Activity pane. Capture, schedule, move, and Run now go
through the helper to server 6.44.0. The home grid is four-wide so seven
tiles stay two rows. Pairs with server 6.44.0.

## 0.5.185 (build 223)

Every message row says where it came from. With server 6.43.4 a run the Mac
started, the scheduled morning brief today and agent tasks next, carries a
ROUTINE or TASK label in the Activity window's Messages list and on the
message detail line, with the routine or task named in the list row's hover;
the model that answered sits beside it wherever the server reports one.
Nothing is inferred from a row that carries no label, and the legend above
the list explains the two labels without saying anything about rows that
carry none (on a server before 6.43.4 the Mac's own brief is unlabeled). The
helper
passes four bounded keys through its allowlist (modelPreference, origin,
originId, messageEra) and drops anything outside the server's two origin
kinds, its id alphabet, or a plain identifier; the model applies the same
bounds again. The morning brief card now shows WHY the last brief failed, on
its own line, so a server that refuses a submission is readable on the card.
The panel's own recent-messages card, unmounted since 0.5.19, is removed
along with the private attachment strip only it called.

## 0.5.184 (build 222)

Update Server no longer depends on one vendor's meter. The transactional
proof now tries every installed provider (Claude, Codex, and Cursor when its
agent is present), commits the update when at least one real query passes,
and records the others as skips with a named reason: "Codex (7s) proved ·
Claude skipped: session or usage limit". Zero proofs still fails closed, and
the Whisper and Kokoro gates are unchanged. On 2026-09-01 Claude's session
limit rolled six 6.43.1 updates back while Codex had proved in seven seconds.
With server 6.43.2 the reason comes from the server's failure code; older
servers are classified from their error sentence. The last proof's verdict is
carried in status as lastProofSummary.

## 0.5.183 (build 221)

The Morning brief card now shows what is behind each source. Under every
source in the Sources list is the line server 6.43.1 reports for it: meetings
stored and the newest month, memories and threads, events on today's calendar,
open tasks, the reflection log, whether the named skill exists. Green when
the well is reachable and non-empty, amber only when a probe that should
answer did not, plain when the COS reads it at run time (Slack, health,
dashboards). The last-run line reads "Delivered #74 · 3 of 4 sections ·
calendar not delivered" once the brief completes. On a 6.43.0 server the card
is unchanged.

## 0.5.182 (build 220)

Miles's three-session fight now keeps his feet under him through both retreat
beats instead of explaining depth with a shrinking figure. The repaired
footwork leads into the approved slash, the Force-thrown debris blocks the
incoming bolt without putting it through his hand, and the bottom-right droid
separates on contact before the larger destruction burst. The exact 2.86-second
loop, 110 ms shipping cadence, other session stories, idle scale, and every
custom character remain unchanged.

## 0.5.181 (build 219)

A Morning brief card, when the managed server is 6.43.0 or newer. The server
now composes a start-of-day brief on a schedule and drops it in the inbox as a
numbered reply; this card is where you say when and from what. Turn it on or
off, set the time and the weekdays, and open Sources to choose what goes in
(Calendar, recent-meeting decisions, tasks due, what is waiting on you, and the
optional set: knowledge graph, reflection, health, an opening reading, a
metrics pulse, one of your own skills such as /good-morning, or a custom
section), each with its own window. Apply saves the whole card in one change.
Run Now fires a brief immediately, five a day at most.

The card edits a draft. A background refresh never overwrites a half-typed
time, and every field goes to the server in one PUT rather than a stepper
saving on each click. The status line tells you when the next brief fires, or
why it will not: off while Background jobs are off, paused during maintenance.
The source list is capped and scrolls, so eleven sources with their options
cannot push the footer off the panel.

The helper carries three pass-throughs (`morning-brief`, `set-morning-brief`
with the change on stdin, `run-morning-brief`). Validation stays on the
server; a refused change comes back as the server's own sentence.

## 0.5.180 (build 218)

When two rows cannot be told apart, the pet shows the time instead of the
workspace. Sessions that share a name usually share a workspace too, so the
second line under the age was spending itself on a value that distinguished
nothing. A finished row now shows when it finished; a live one shows when it
opened. Rows with a name of their own are untouched, and so are rows that share
a name across different workspaces, where the workspace is already doing the job.

Clicking a Cursor row no longer opens the wrong agent. The jump presses the
Agents row whose title matches the session's name, which is only safe while the
name belongs to one agent. It does not always: two Cursor sessions here are both
called "COS glasses session update", and the press took whichever came first.
When the name is shared, Control now opens the Agents window, leaves the choice
alone, and tells you which one is yours by the time it started.

## 0.5.179 (build 217)

Finished rows lead with the session's name, the same as the live rows and the
Sessions tab. They led with the summary, and every resumed session carries the
same one, so the finished list repeated a single line of boilerplate where the
names should have been. What the session did moves to the second line.

The ledger bar shows its true colours. The bar's segments were painting through
the panel's material onto whatever was behind the window, so DONE came out a
duller, greener tan than the DONE button's own dot, even though both are set
from one value. The bar now sits on a solid floor like the buttons do.

## 0.5.178 (build 216)

The figure holds still when a list opens, and the lists keep their own width.

The window sizes itself from its content, and that kind of resize is anchored at
the top left, so opening a list grew the panel downward and pushed a
bottom-parked character off the screen. The panel now puts its bottom edge back
after every resize, so the menu opens upward from where you parked it. It still
moves down in one case only, when the pet sits so high that an open menu would
leave the top of the display.

The previous attempt at this turned the window's self-sizing off entirely. That
stopped the downward growth but also stopped the content tracking the window, so
the lists laid out at the wrong width and spilled out of their cards. That build
was withdrawn and never published.

Running rows lead with the session's name. They led with the live summary, and
every resumed session carries the same one, so several rows read identically
while the name that tells them apart sat underneath.

## 0.5.176 (build 214) — withdrawn, never published

This build tried to hold the figure still by trimming the panel's height. That
was the wrong lever and it was rejected in testing. The entry is kept so the
build numbers read straight; the behaviour it described is not in any shipped
release. 0.5.177 was withdrawn the same way, for changing how the window sized
itself, which made the lists lay out at the wrong width.

## 0.5.175 (build 213)

Double-clicking the figure opens and closes the menu again, and it remembers
where you were. It had been gated on having more than one running session, so
at one running session, which is most of the time, the gesture quietly did
nothing. It also only ever worked on the running list, so double-clicking while
the finished list was open looked broken. Now it closes whichever list is open
and reopens that same one, and the RUNNING and DONE buttons set what it reopens
too. It stays inert only when there is genuinely nothing to show.

Close all clears the finished list in one go. It sits between the list and the
figure while that list is open. Nothing is stopped or deleted; the rows just
stop being listed.

## 0.5.174 (build 212)

The session list stops cutting the ends off its right-hand column. Past three
items each list scrolls, and a scroll view clips whatever leaves its bounds, so
the rows' trailing column was being sliced rather than nudged: an age of seven
minutes rendered as "7", a workspace called mu-chief-staff rendered as
mu-chief-staf, and under the pointer the last of the three row actions lost its
right edge. Nothing there reached outside the list any more. The tucked edge is
now set by the list itself, and the resting text and the hover actions share one
trailing edge instead of being aligned by hand.

## 0.5.173 (build 211)

Miles moves through the Three and Four-plus fights with four additional bridge
poses at the seams that were still reading as jumps. Every approved V15 cel is
unchanged, and both stories keep their exact original loop length. The runtime
strip encodes the approved 110 ms bridges and 220 ms holds without blending,
camera movement or a new timing engine.

Idle is 1.45x, an 11.5 percent increase from 1.30x. It uses the same authored
eight-frame loop and changes only the character's pack-owned presentation
scale. Recognized stock Miles installs receive both updates automatically;
custom art and custom idle scales remain untouched.

Release packaging now adopts the stable COS Control signing identity whenever
it is available. A throwaway ad-hoc build can no longer replace a signed local
release and silently strand an existing Accessibility grant.

## 0.5.172 (build 210)

The session list keeps its right edge. The age, the workspace and the three row
actions were landing on the card border itself, so a resting row read as clipped
and the actions looked like they had slid off the panel. They sit 6pt in now,
still tucked well past the 10pt the list would hand them by default, and clear
of the 1px stroke they were touching.

Nothing else about the rows moved. Same sections, same hover crossfade, same
three actions in the same order, same fixed 57pt slot.

## 0.5.171 (build 209)

The session card tells you what happened. Every finished row used to print the
literal word "Finished", so two sessions forked off the same repo read as the
same three tokens no matter how long you looked at them. A row now leads with
what that session actually did, on its own line at the top of the row.

The card is wider, because the sprite was deciding how much room the reading
got. At the old width a finished title was 68pt, which is ten characters of the
font it is set in, and that is exactly the "You match…" you were looking at.
The title has 276pt now and the outcome line has 281pt.

Point at a row and it opens up. The three paths off a row, open it in the
platform, open the session view here, clear it, used to sit lit on every row,
spending 57pt of every line on controls you were not using. They now share the
fixed slot that carries the age and the workspace at rest, and cross over when
the pointer arrives. Nothing changes size, so the card never jumps. Right-click
reaches the same three, for when the pointer is not the input.

The outcome scrolls while you point at it, like a ticker, so a long sentence
can be read without the row growing. Only the row under the pointer moves, and
it waits a beat before it starts, so sweeping down the list moves nothing.

The trailing items sit on the card's edge now instead of 11pt inside it. Every
row was being inset to dodge a scroll indicator. The indicator is hidden, and
the 10pt went to the words.

Search by meaning moved out of the toolbar. It was sitting third in the panel,
between Activity and Server status, which is a lot of room for a switch most
people set once. It now sits at the end of the Messages search row, beside the
search it governs, and still says what it costs. When a search comes up thin
and the switch is off, the offer turns it on for you instead of sending you
somewhere else to find it.

## 0.5.170 (build 208)

One box searches recent messages and the archive. Two boxes meant "No recent
message contains thule" while the archive held thirty four hits one tap away,
and you had to retype the word to find that out. The line under the box now
carries both counts for the same term. The side you are on is a label, the
other side is a door, and crossing over runs the term for you.

The archive count never answers for a term you have moved on from. Until the
scan runs for what is actually in the box it says "press return" rather than
showing the last term's number as though it were live.

Search by meaning has a switch in the toolbar, and it is off. It is the one
thing in Control that spends model tokens, so it states what it costs in both
states rather than sitting there as a bare switch. Off is keyword only, no
model calls. On, Control offers to look for related days when a search comes
up thin, and asks only when you tap it. Twenty five a day.

Behind that switch, the model is pinned to Haiku, a breaker stops it after two
failures, and every day it proposes is checked against the real archive before
it reaches you. A date that holds nothing is dropped rather than shown, which
is what makes the layer safe without building an embedding index.

## 0.5.169 (build 207)

Recent messages are searchable. The newest turns were the one place you could
not look, so a phrase you remembered from an hour ago meant scrolling. The
box filters as you type and says how many of how many matched.

The search box stays put while you scroll. In an archived day and inside a
chat, the bar now sits above the list instead of scrolling away with it, so
what you searched for is still on screen when you reach the passage.

Matches are marked in the text itself, in yellow on dark and amber on light,
with dark ink either way. A tinted row told you the term was somewhere in
there; the mark tells you where.

## 0.5.168 (build 206)

Search results read like conversations again. The server cuts its snippets as
a raw window out of the archive file, so a hit near the top of a chat dragged
"sessionId", "exchanges" and "role" into the result with it. Snippets are
cleaned to the sentence a person actually said.

A search now opens on its matches. Finding one chat in eleven and then having
to flip a switch to see it buried the thing you asked for; the filter starts
on, and stays off when nothing matched so a day is never mysteriously empty.

Search tolerates a typo. "Thulle" finds Thule — one doubled or transposed
letter no longer makes a conversation look like it never happened. Short
words still match exactly rather than fuzzily, because at three letters
almost every word is one edit from another.

## 0.5.167 (build 205)

Updates moved to the top of the panel. The check used to be the very last
thing under everything else, so asking "am I current?" meant scrolling to the
bottom. The first card now answers it on every open: the version you are on
when you are current, an install offer when you are not, and the manual check
in both states. Quit stays at the bottom where it belongs.

Search now follows you all the way down. Finding the day got you a day;
finding the chat got you a transcript you still had to read by eye. An
archived chat now has its own find bar, seeded with the term that got you
there, with a match count, next and previous, and matched turns highlighted
in place — so a chat with forty-six mentions takes one keystroke to walk
rather than a scroll.

## 0.5.166 (build 204)

Archived days are searchable and readable. Finding the day a conversation
happened on used to end there: the day opened as "Chat 1" through "Chat 11",
and the term you searched for did not come with you, so you had to open every
chat to find the one you meant.

Each chat now leads with what it was actually about — the words that
conversation kept returning to, taken from your own side of it — instead of
an ordinal and an opening line that reads the same on every chat of the day.
The time, message count and chat number are still there underneath.

The search that found the day now carries into it. Chats that contain the
term are badged with their match count and show the passage that matched,
and a switch narrows the day to just those chats. Searching an archived day
costs one request, not one per chat.

## 0.5.165 (build 203)

Calm motion. An advanced character's multi-session fights are the whole
appeal for most people and motion sickness or plain distraction for others,
and until now the only alternative was macOS Reduced Motion, which freezes
the figure entirely. Turn on Calm motion in Session Pet settings and the
character rests on its gentle idle loop no matter how many sessions are
running — the same register as the still characters — while the bar below it
keeps reporting every count: running, waiting, finished. Lower motion costs
you nothing in status.

Alerts still reach the figure. An error or a jump that needs your attention
is not a motion preference, it is the app telling you it could not do
something, and both are brief. For no motion at all, macOS Reduced Motion
still freezes everything.

## 0.5.164 (build 202)

A large session now opens with its full history, not a sliver. 0.5.162 fixed
the refusal but read only the newest 8 MB, which on a 278 MB transcript
surfaced fifteen turns where the view can hold a hundred and twenty. The
window is now sized by measurement rather than guess: 64 MB fills the view's
turn budget on that same transcript in about a second, and reading further
buys nothing.

## 0.5.163 (build 201)

The agent rows now carry each platform's real logo instead of a stand-in:
the Anthropic sunburst for Claude, the OpenAI knot for Codex, and the Cursor
prism. They ship as monochrome vectors tinted like every other mark in the
app, so they stay legible in light and dark. A local model, which has no
brand mark, keeps its chip.

## 0.5.162 (build 200)

Large Codex and Cursor sessions open now. A transcript over 32 MB was
refused outright — "This Codex session is too large to open in Control",
behind a Retry button that could never succeed. Oversized transcripts are
windowed instead of refused: the head still supplies the working folder,
branch and title, and the newest turns come from the end of the file, which
is what you opened the row for. The middle is skipped and the session
subtitle says so. Nothing is refused for size any more.

Finished sessions on the pet now carry three paths instead of one: open the
session in its own platform, open the session view in Control, or clear the
entry.

## 0.5.161 (build 199)

Every agent row now carries its platform's mark, so you can tell Claude from
Codex from Cursor at a glance instead of reading the label: a spark for
Claude, a terminal prompt for Codex, a cube for Cursor, and a chip for a
local model, each in that platform's colour. The marks come from one shared
builder used by live rows, idle rows, and finished entries alike, so a
platform can never look like one thing in the list and another in the chips.

## 0.5.160 (build 198)

The live activity line is readable now. It was sharing the title column with
the age and workspace stack, which left it about 84 points — under twenty
characters, not enough for one whole word of a scrolling sentence. It now has
its own full-width line beneath the title, 209 points, and a slightly larger
face: 39 characters visible instead of 18, despite the bigger type.

## 0.5.159 (build 197)

Fixes found by an adversarial QA pass over everything shipped in the last
two days.

A session dropped from the list could become unreachable. The list is the
only home of the "Show dropped" restore row, but the poll closed it whenever
no sessions remained — so dropping your last row shut the list under the
cursor, and re-opening it lasted twenty seconds. It now stays open while
anything is left to show.

The live-line ticker mismeasured every non-Latin summary. Width was estimated
from a monospaced advance, which is exact for ASCII but up to 2.3x short for
CJK and emoji, because those glyphs come from fallback faces the mono font
does not cover. Overflowing text was judged to fit and silently clipped.
Non-ASCII text is now really measured. A line that does not scroll also ends
in an ellipsis instead of a hard cut — which is every running row when
Reduced Motion is on — and a line whose window narrows under it, as when the
drop control appears, now re-evaluates instead of staying frozen.

The bar's green segment kept breathing only if it was running when it first
appeared; a segment that became running while the bar was already on screen
sat still. The WAITING tooltip now says it opens the session rather than
promising a jump it no longer performs. The live list starts scrolling at
four rows rather than six, where the taller mission rows genuinely exceed
the scrolled height.

## 0.5.158 (build 196)

The WAITING pill now respects the choice. With one session waiting on you it
jumps straight in, as before. With two or more it opens the live list instead
of picking one arbitrarily and silently ignoring the rest — the state where
choosing matters most. Waiting sessions have their own amber section there.

## 0.5.157 (build 195)

The pet stays where you parked it. Opening a list grows the panel upward,
and when that would run past the top of the screen macOS slides the whole
panel down to keep it on screen — the pet then took that slid position as
its new home, so closing the list left it lower than it started. A pet
parked high on the screen walked 450 points down in a single open. Every
frame is now rebuilt from the spot you dragged the pet to, so a slide is
temporary and closing always returns it exactly. Dragging still re-parks it.

The live activity line is now a news ticker. A long summary scrolls through
a fixed window at a steady reading pace, so you can see what an agent is
actually doing instead of a truncated fragment. Text that already fits never
moves, a new summary restarts from the beginning, and Reduced Motion keeps
the line still.

## 0.5.156 (build 194)

Fixes the giant blank column 0.5.155's mission rows could open inside the
live list. The state rail was a bare shape sitting in the row, and a shape
accepts any height it is offered — under the panel's sizing probe one
running row absorbed hundreds of points of empty card. The rail now rides
as an overlay on the row content, which by definition takes the row's own
height and cannot stretch it. Rows are exactly as tall as what they say.

## 0.5.155 (build 193)

The live-session list is now mission rows, built to orchestrate a fleet at a
glance. One list, three weights: RUNNING rows carry a green rail, a two-line
title, a pulsing mono LIVE line saying what the agent is doing right now,
its workspace, and a colored age figure. WAITING ON YOU is its own amber
section that names what it waits on. Idle sessions recede to dim one-liners.
The LIVE line renders the per-session summary the helper has shipped all
along and the pet never displayed; the raw "user" wait token reads as
"needs you." The whole row still jumps, the drop x and restore row are
unchanged, and the scroll frame grew to fit the richer rows.

## 0.5.154 (build 192)

All four Jedi now have walking animations. Nia Solari, Elara Vale and Rowan
Vale gain separate eight-frame patrol cycles with alternating steps and coat
movement; Miles keeps his original walk. Nia also gains an eight-frame seated
meditation loop while waiting, with breathing and a rising electric aura.
Elara and Rowan retain their animated idle while waiting. Distinct calm clips
remain walking rests without duplicate playlist entries.

The 32 new frames are registered to each character's existing scale. All 76
previous PNGs, combat stories and Miles's 1.30x idle remain unchanged. Native
canary coverage checks all 12 calm-state paths, frame selection at four speeds,
Reduced Motion, transparent gutters and all 16 retained stock upgrade histories.
Art generation 17 upgrades untouched stock packs automatically; custom artwork,
pose metadata and saved character/size/speed preferences are preserved.

## 0.5.153 (build 191)

Nia Solari, Elara Vale and Rowan Vale now keep their eight-frame breathing,
glance and cloth-motion idle loops playing with quiet open sessions and while
waiting. Those real runtime states previously selected a legacy still, even
though the zero-session idle already animated. Reusing the same calm clip no
longer restarts it as a second playlist entry or changes its authored cadence.

Exact stock packs from 0.5.151/0.5.152 and earlier upgrade automatically.
Custom art, timing and scale are preserved. All image bytes, combat sequences,
Miles Windu's distinct ambient clips and 1.30x idle remain unchanged. Native
canary coverage exercises state resolution, playback, reduced motion, stock
migration, and the retained gallery fix before publication.

## 0.5.152 (build 190)

Fix the blank Nia Solari, Elara Vale and Rowan Vale previews in the character
gallery. Thumbnails now read the idle filename and frame count together from
each pack's state map, instead of slicing the old still using the new loop's
frame count. All four Jedi have pixel-checked gallery regression coverage.
Animation artwork, idle scales, selected character and saved settings are
unchanged.

## 0.5.151 (build 189)

Nia Solari, Elara Vale and Rowan Vale now have their approved combat stories
and eight-frame idle loops. The 223 new frames include connected defensive
reads, grounded strikes, Force pulls, visible droid defeats and recovery.
Each character keeps a distinct fighting style and an idle scale matched to
its own combat art. Miles Windu V15.4 and his 1.30x idle are unchanged.

Untouched bundled Jedi packs upgrade automatically, including the old still,
four-frame and V1/V1.1 releases. Recognition checks the entire state map and
retained image bytes. Custom artwork, pose timing or scale, selected character,
and saved global size/speed stay untouched. Versioned images land before the
state map changes, allowing safe retry after an interrupted write. Patrol,
waiting, success, error and attention keep their existing still fallbacks.

## 0.5.150 (build 188)

The pet is one surface family now. Both session lists, the terminal hint,
and notices ride the same blur material and 12pt rounded rect as the ledger
(notices are the error channel, so they sit on the heavier material — never
less legible than before). The floating focus dot is gone; the ledger's
colored segments already say it. A fully quiet pet keeps its IDLE capsule on
hover instead of revealing dead pills, while a pet whose only session was
dropped from the list still reveals the way back in. The RUNNING pill can
open a one-row list and the poll no longer closes it under the cursor; rows
keep one width whether or not the list scrolls; a finished list whose
entries age out or resume releases its pin instead of wedging the pet in
pills state; and the bar-to-pills crossfade animates on every path that can
flip it.

COS Control's own panel gets its first pass of the same discipline: eight
accumulated corner radii collapse to a 12/8/5 scale (cards 12, tiles 8,
small controls 5), with the few-pixel meter and legend radii kept as
proportional geometry.

## 0.5.149 (build 187)

Miles Windu V15.4 publishes the approved 26-frame four-plus-session story.
The rear-facing block turns through a foot-led underhand preparation into
the rising cut. An added slash follow-through bridges the upper droid's hit
and dissolve, the Force catch lifts the lower droid before the pull and
chest thrust, and the blaster advances with readable reaction time.

The stock idle scale is now 1.30x, bringing its apparent character size in
line with combat. Exact-stock older packs upgrade automatically; custom
artwork and non-stock pose scales stay untouched. The one-, two-, and
three-session strips, other characters, ledger UI and saved global size
and speed settings are unchanged. The swarm retains 0.22 seconds per
frame, for a complete 5.72-second loop at 100% speed.

## 0.5.148 (build 186)

The droids now agree with the ledger. Escalation used to read TOTAL alive
sessions, so three sessions with one running rendered a three-droid trio over
a "1 RUNNING" caption. The fight ladder now counts sessions in play — running
plus waiting, the same units the bar's colored segments show — so one running
is one droid, and idle-alive sessions read as patrol instead of summoning
opponents. Error, attention, amber waiting, and the completing flash keep
their precedence.

The clear x in an overflowing list no longer sits under the scroll indicator:
scrolling rows inset from the right edge where the indicator paints, in both
the live and finished lists. The ledger's blurred capsule is optically
re-balanced — it carried more air above the bar than below the caption.

## 0.5.147 (build 185)

Hover is pills-only now. The focused-session title card and the two circular
buttons are gone from the reveal: the RUNNING, DONE, and WAITING pills open
whatever is active, so a card naming one session and a second set of openers
were redundancy on screen (a single click on the figure still opens the
focused session). Hover no longer changes the panel's layout at all — the bar
cross-fades into the pills in its own slot, and only a pill click adds a list
above the figure.

Finished entries are now clearable: every row in the DONE list carries the
same x the live list has. Clearing removes that one entry and persists; it
returns only if the session runs and finishes again. Clearing the last entry
closes the list.

The ledger sits on its own blurred surface — a soft material capsule behind
the bar and caption — so the counts stay readable over busy wallpaper. With
Reduce Transparency the blur becomes a flat fill and the edge stroke keeps
the shape.

## 0.5.146 (build 184)

The ledger now sits UNDER the figure, a nameplate at its feet, instead of
riding its head. Character on top, bar and caption beneath, hover pills in
the bar's same slot. Both rows keep riding the panel's fixed bottom edge, so
nothing moves when the title card, actions, or lists unfold above the figure
on hover.

## 0.5.145 (build 183)

The ledger now hugs the character. The panel reserved the height of the
TALLEST pose for every pose — and with the stock idle at 3x, a 1x combat
figure sat under roughly two figure-heights of invisible headroom, leaving
the bar floating up to ~700px above the character's head. The panel now keeps
the stable envelope width (a poll never re-centers the pet) but takes the
CURRENT pose's height, so the bar, caption, pills, and hover reveals sit
directly above the figure in every state. The figure itself never moves: it
is bottom-aligned in a bottom-anchored panel, so a pose change repositions
only the chrome riding its head.

## 0.5.144 (build 182)

The consolidated public release: everything since 0.5.139 under one build
number. The ledger-bar pet chrome with its non-jumpy hover reveal, per-session
completion chips, the iTerm2/Terminal session jump, Miles Windu V15.2 stories
plus the approved 25-frame V15.3 swarm, the 25% to 200% character-speed
control, and the 3x stock idle. No code or art changes over 0.5.143 — one
version now names the combined interface and animation for the updater and
the site.

## 0.5.143 (build 181)

Miles Windu's approved V15.3 four-plus-session story now has 25 frames. The
clockwise spin flows directly into the lower-right droid strike without changing
the crossed-arm reverse grip. Contact, electrical breakup, wrist load, visible
saber release, flip, and catch form one continuous sequence. Force control,
pull-to-strike, defensive blocks, and complete droid dissolves remain intact.

The one-, two-, and three-session stories are byte-identical to V15.2. The swarm
keeps its authored 0.22-second cadence, with all 25 frames playing in 5.50 seconds
at 100% speed. Stock V15.2 and earlier packs upgrade automatically through an
exact-byte match; custom artwork and pose scales remain untouched. The ledger
bar, completion chips, terminal jump, speed control, and 3x idle are preserved.

## 0.5.142 (build 180)

The pet's chrome is now a ledger bar: a slim segmented health bar riding above
the sprite with a counted caption beneath it — amber for sessions waiting on
you (always at the front), green for running (with a slow breathe), gold for
finished. That is the whole idle footprint; the buttons, chips, chevron, count
badge, and status card are gone from the resting state.

Hovering the pet brings everything back: the bar cross-fades into three state
pills in its own slot, the focused session's title card and the two action
buttons unfold above. Click RUNNING to pin the live-session list, DONE to pin
the finished list, WAITING to jump straight to the session that needs you.
Zero-count pills sit dimmed. Click anywhere else to close a pinned list.

The motion is built not to jump: nothing above the sprite ever changes size
(the pills occupy the bar's exact slot), reveals grow upward from the pinned
bottom edge so the character never moves on screen, expansion waits a beat so
a cursor passing through triggers nothing, and collapse waits longer and fades
before it shrinks so leaving the pet never flickers. Hover arms even though the
app is not active — the sensor registers its own always-on tracking area, which
SwiftUI's own hover would not on a menu-bar app's nonactivating panel. macOS
Reduced Motion drops every slide and the bar's breathing, keeping plain fades.

## 0.5.141 (build 179)

The pet now tells you WHICH session finished, and takes you there. One of four
sessions finishing used to be invisible: the completion check was a fleet-wide
boolean, so any finish while others still ran never fired, and the 2-second
flash kept no record. Finishes are now detected per session, held as chips
behind a checkmark on the pet (unseen count in green), and survive a relaunch
for four hours, capped at eight. Clicking a chip opens that session in Control;
opening it anywhere marks it seen. A session that runs again drops its chip and
a re-finish is news again. Dropped rows and keep-warm sessions never emit.

Completing only flashes success when nothing else is still running or waiting,
and a session waiting on you now outranks the fight ladder: one waiting plus
three idle reads amber, not a five-droid swarm.

Clicking a Claude Code session that runs in a TERMINAL now raises that terminal
instead of Claude Desktop. Routing keys on the session's own recorded
entrypoint plus a two-terminal allowlist (iTerm2, Terminal) — never on tty
presence, which the 2026-08-30 census falsified when Claude Desktop itself
owned a tty. The activation sends no Apple Event and raises no extra windows;
a recycled pid is caught by a UTC-safe process-start comparison that fails
open. Desktop sessions keep their sidebar jump unchanged. Tab-level selection
inside the terminal is a later release.

An installed pack whose art is replaced by an update now takes the new art's
frame timing. Retention kept the previous cadence, which left the 17-frame
V15.2 duel playing a third slow against its authored 1.87-second loop.

## 0.5.140 (build 178)

Character speed now sits directly below Character size in Session Pet settings. The
saved 25% to 200% control slows or accelerates the animation without changing the
figure, card, buttons, or text; 100% remains each sprite pack's authored cadence.

Speed scales the animation clock rather than rewriting individual frame intervals.
That keeps complete combat stories and patrol rest beats intact at every setting, so
slow motion actually reveals every frame instead of cutting a sequence short. macOS
Reduced Motion still freezes the sprite regardless of the saved speed.

Miles Windu's bundled idle presentation is now 3× instead of 2×—an additional
1.5×—so idle, meditation, and patrol read at the same visual weight as the
multi-agent stories. Recognized stock installs migrate automatically while a
manually-authored pose scale remains untouched.

Miles's V15.2 active-session stories now contain 16, 17, 13, and 23 frames.
The two-session fight adds a rightward jump-roll, a clean landing beat, and a
visible replacement-droid entry. The three-session opening blocks three shots;
its ground and airborne attackers now aim at Miles rather than his blade.
The swarm mixes the cleaned single-blade backstab and visible rotating handoff
with Force control, a pull into a chest thrust, and complete droid dissolves.
Four counterclockwise turn beats lead into the visible behind-the-back chest
thrust; its compact pivot footwork keeps the final strike deliberate and readable.

The sprite pipeline now supports up to 32 frames so the longer stories retain
their exact cell boundaries instead of being silently sliced as 16. Versioned
assets and art generation 11 migrate byte-identical stock Miles packs to V15.2;
old assets remain available for recognition and custom art stays untouched.

## 0.5.139 (build 177)

Miles Windu now ships the approved V15.1 one-, two-, three-, and four-plus-session
stories reviewed in canary. Their six-pixel runtime gutter replaces the older V15
sheets that could crop effects at a frame edge, and existing unmodified Miles installs
upgrade automatically without touching custom sprite packs.

Miles's idle pose now renders at twice its prior size through pack-owned pose metadata.
Combat scenes and the user's global character-size setting stay unchanged, while the
shared viewport reserves enough room for the larger idle figure instead of clipping or
recentering it when session state changes.

Elara Vale's four active-session stories now use corrected V1.1 transparency. The
extractor preserves only the white blade core bracketed by both green saber rails, so
the broad white background matte no longer makes the saber look oversized. Existing
byte-identical Elara V1 installs upgrade automatically; customized packs remain intact.

## 0.5.138 (build 176)

Nia Solari, Elara Vale, and Rowan Vale now carry complete active-session stories at the
same bar as Miles Windu. One, two, three, and four-plus sessions play approved
16/12/13/16-frame sequences instead of a standing portrait followed by three four-frame
combat loops. Their attacks now establish each threat, show the block or strike, resolve
the droid on contact, and return to a readable loop seam.

Existing stock installs upgrade automatically. The app recognizes the exact retained
four-frame state map and byte-matches all four old assets before it writes anything; a
customized character is never touched. Versioned story files land and verify before the
state map switches, so an interrupted launch leaves the old pack readable and retryable.

## 0.5.137 (build 175)

Meetings to review can be read by date.

The list is a work queue: it puts meetings that still need speaker names on
top, so an unnamed meeting from Wednesday sits above everything captured
today. That is right when you are working through names and wrong when you
are looking for what you recorded this morning.

A sort control now sits next to Hide reviewed. Needs review first stays the
default. Newest first and Oldest first order purely by capture time and
ignore review state.

Rows now show the capture time alongside the date, because a dozen rows all
reading 2026-08-28 gave no way to see that a date sort had done anything.

Next unnamed is untouched. It still walks the review-priority queue, so
re-sorting the list to browse never reshuffles the naming order.

## 0.5.136 (build 174)

Turning the session pet on now asks for Accessibility, instead of waiting for a jump to
fail. That permission is what lets the pet open the session you clicked in Claude, Codex
or Cursor, and until now the first anyone heard of it was an error after a click that did
nothing. Settings also says plainly when the grant is missing, with a Grant button, and
clears the notice as soon as you allow it.

The permission is scoped and the panel says so: it gates the jump and nothing else.
Meetings, transcription, the server, Activity and search all work without it, so there is
no reason to allow it if you do not use the pet.

A failed jump now names the step that failed. Four different failures used to render one
sentence — a session name too short to match, no windows returned, a sidebar deeper than
the search limit, and a click the app refused — so a report from another machine said
nothing about which had happened. Each one now reports itself, with counts, and writes the
same detail to the log.

## 0.5.135 (build 173)

Miles Windu's four active-session stories now use the reviewed V15 artwork rendered from
the 2x masters. One session deflects the off-screen bolt, closes the distance and cuts
down the revealed droid. Two sessions restore the approved single-strike and backswing
deflection fight. Three sessions carry the rebuilt thirteen-frame three-droid sequence,
including the corrected final recovery with one attached purple saber instead of two.
Four or more sessions keep the full sixteen-frame swarm escalation.

Every strip keeps one authored scale for its whole loop, a transparent RGBA canvas,
cleared frame gutters and an exact opening composition at the seam. Runtime art is the
single final downsample from the reviewed 2x master.

Existing stock Miles V7 installs advance automatically to V15 on launch. The migration
recognizes only byte-identical bundled Miles artwork; custom sprites, OpenPets characters
and the three other bundled Jedi remain untouched.

## 0.5.134 (build 172)

Jedi Nia Solari, Jedi Elara Vale, and Jedi Rowan Vale now fight. Each carries authored
four-frame strips for the two, three, and four-plus session states: guard, the droids
fire, the blade lands on one of them, and that droid is knocked back with a cut scar and
its blaster down while the rest stay upright. Escalation reads from droid count, one then
three then five, the same way Miles Windu's loops do.

The other seven states keep the single portrait, which reads fine standing still. This is
the authored-frames answer to the motion 0.5.131 tried to fake and 0.5.132 reverted.

A shorter strip no longer plays faster. Frame rate was authored per pose against Miles
Windu's sixteen-cell strips, so a four-cell duel ran its whole loop in 0.44s instead of
1.76s. The loop duration is now what's held constant, and Miles Windu's own playback is
bit-for-bit unchanged.

Dropping an idle row is undoable again. `restorePetDismissals` had no caller, so a row
dropped by mistake was gone for good — the dismissal persists across relaunch. The list now
carries a "Show N dropped" control whenever anything is hidden, and Reset clears dismissals.

A dropped row also used to come back on its own within one poll. The pet applies sessions
twice per cycle, once from a snapshot only the Activity window refreshes, and pruning on
that stale pass retired the dismissal because the row was merely absent from an old list.
Only a list we know is current can retire a stamp now.

Two paths could destroy an installed character. Choosing a sprite over 8 MB cleared the pet
and then refused the replacement, leaving nothing; the file is validated before anything is
cleared. And a sprite pack that failed partway through the swap left a half-erased folder
whose state map pointed at files that never arrived; the outgoing character is now held
aside and restored if the copy fails.

Legacy packs draw at every session count. duel, trio and swarm fell back only to each
other, so a pack carrying none of the three resolved to nothing and painted the stock
figure once 0.5.130 stopped leaving the previous pack's art behind to cover for it.

Known and not fixed: the three Jedi are not scale-normalized against their own portrait,
so the character changes apparent size when combat starts. That needs a re-render.

## 0.5.132 (build 170)

Reverts the 0.5.131 procedural cadence. Translating and rotating a whole still
figure read as a sticker being wiggled, not as a character moving. The three
bundled Jedi go back to standing still until they have real sprite frames.

## 0.5.131 (build 169)

Gave characters that ship one image per state a procedural weight-shift cadence that
escalated with session load. Reverted in 0.5.132: sliding and rotating a whole static
figure read as a sticker being wiggled rather than a character moving. Recorded here
because it was published, and because 0.5.132 and 0.5.133 both refer to it.

## 0.5.130 (build 168)

Switching characters now actually switches. Installing a sprite pack, or picking
a single sprite from the gallery, used to layer on top of whatever was already
installed: every pose the incoming character did not declare stayed owned by the
outgoing one, and because a plain sprite is only the last-resort rung of the
pose lookup, choosing a legacy pet while one of the advanced Jedi packs was
installed could not change anything on screen. A pack is now built in a scratch
folder and swapped in whole, so a pack that fails halfway leaves the existing
character untouched instead of half-erased, and a stale combat strip can no
longer outlive the pack that wrote it and keep fighting under new artwork.

Legacy packs render every state again. The error and attention poses used to
fall back only to each other, so a pack carrying neither drew nothing at all for
both once the previous pack's leftovers stopped covering for it. Every fallback
chain now terminates at a pose a minimal pack actually declares.

Idle sessions can be dropped from the pet list. After ten minutes without
activity a row shows an x; clicking it removes the row from the list only. The
session keeps running, nothing is deleted, and the row returns on its own the
moment it does something. Four parked sessions no longer pin the pet in the
five-droid swarm while the one session actually working goes unseen.

Double-clicking the character opens the active-session list, so the chevron is
no longer the only way in. A single click still opens the focused session and
still never expands the list.

## 0.5.129 (build 167)

Session Pet settings now open as one compact section. State sprites and the
unified 304-character gallery each live behind their own disclosure, and the
four state-aware Jedi carry an Advanced badge inside the same grid as OpenPets.

Jedi Nia Solari, Jedi Elara Vale, and Jedi Rowan Vale join Jedi Miles Windu as
bundled choices. An enabled pet remains visible in idle when no session is
running. The collapsed pet reserves one lifecycle-wide viewport, and only its
chevron opens the active-session list, so poll-driven session-count changes no
longer move the character or expand the list under the pointer.

Miles's one-session work strip now tells one ordered story: sprint, brake, see
the incoming error, slash it with the purple saber, and return to the run. The
two-session strip uses the same running bridge around a two-droid counterattack:
brake, strike right, turn before the rear bolt arrives, deflect it, counter the
left droid, and sprint away. The three-session and four-plus strips were rebuilt
to keep Miles and every surviving droid present, use exactly one saber, show a
real block before contact, and remove enemies only after a visible hit/recoil.
All four loops close on a pixel-identical opening composition. Every internal
beat shares one measured camera scale, keeps 3px-or-greater cell gutters and true
alpha, and uses artwork-local scale, so arbitrary character packs are never
enlarged by a global combat transform.

Recognized older Miles installs refresh to the four new story assets once. The
check accepts the original stock pack or the retained prior one-/two-session
story pack only when all ten mapped assets remain byte-identical, then lands all
four strips before atomically updating their map records. A custom pose is
preserved, and an interrupted refresh retries on the next launch.

## 0.5.128 (build 166)

The archive opens.

Messages archived a day at a time and then counted history it could not show.
A date row said "24 chats, 256 messages" and did nothing when clicked, so
everything older than today was a number rather than something you could read.

Archive now drills through the way Recent already does. A date opens that day's
chats, and a chat opens its full transcript, paired question and answer, with
Copy turn on each one in the same clipboard format Recent uses. Back unwinds a
rung at a time: a chat returns to its day, the day returns to the list.

Search hits open too. A hit is a day, so finding a conversation by searching and
then not being able to open it was the same dead end reached a second way.

The server already served all three levels. Only Control was missing the last
two, so no server update is needed.

## 0.5.127 (build 165)

Miles is a character you can choose, not only the default you can restore.

The gallery now counts bundled animated characters and OpenPets community
stills together. With the current 300-item community catalog it reads
"Characters 301." Search covers both sources, including Miles, Black Jedi,
purple saber and droid terms. The Miles row says Use and retains the existing
replacement confirmation before it changes an installed pack.

Bundled characters now use a small registry with stable IDs, descriptions,
search terms and asset folders. Miles is the first entry. The next female and
male Jedi packs can join by adding their processed asset folder and one catalog
record without another gallery rewrite. COS-owned characters remain above the
OpenPets attribution so community licensing language stays correctly scoped.

The bundled Miles artwork also receives its final alpha polish. All eight
sprint frames have true transparency between the rear arm and coat, detached
paper specks are gone, and the patrol cycle no longer contains a split figure
or displaced fragment. The real importer and contrasting-background audit pass
all 74 frames with transparent cell edges.

## 0.5.126 (build 164)

Miles Windu is twice as readable without sacrificing the animation frame.

The character dial now defaults to 300% and reaches 600%. Existing preferences
migrate once, so a pet already maxed at 300% opens at 600% after the update and
stays there after restart. Oversized pet-size and character-scale combinations
fit the active display before rendering, while the saved preference remains
unchanged and returns at full scale on a roomier screen. The status card keeps
its own width as the transparent sprite envelope grows around the figure.

V4 duel, trio and swarm strips advance frame by frame instead of cross-fading
distinct combat poses into ghost overlays. Running and patrol settle only into
idle or meditation; success and attention keep their saber draws for the real
signal instead of repeating them during ambient playback.

The duel strip is rebuilt from the original artwork after importer validation:
the neighboring-frame droid no longer spills behind Miles, the opponent remains
fully inside its frame, and the white checkerboard regions between the fighters
are transparent without erasing the purple saber effects.

QA added executable coverage for first-load migration, restart idempotence and
maximum-size display fitting. The release gate's provider fixture is now
independent of whichever agent CLIs happen to be on the caller's PATH.

## 0.5.125 (build 163)

The default character is polished art, and the pet gallery can restore it.

Miles Windu V4 becomes the bundled default: rebuilt meditation frames with
corrected crossed-leg anatomy, the violet aura contained inside safe margins,
and body scale plus baseline normalised across every state. Validated through
the real importer — 74 of 74 declared frames preserved, and ZERO frames in any
of the ten poses now touch a frame boundary, where the previous pack had all
eight meditation frames cut through the character.

Frame cuts only leave the authored grid for a column that is empty, or clearly
cleaner than the grid column. A search that roamed a third of a cell for the
"emptiest" column carved through the figure whenever a strip had no real gaps.

The pet gallery gains a Restore row for the shipped character, above the
community gallery so its attribution still covers only its own art. Restore
deletes the installed pack, so it now asks first — installing a gallery pet,
which is less destructive, already did.

From a two-agent QA pass, all mutation-verified: the gallery thumbnail read
whichever pack owned idle, so the row labelled with the shipped character could
show someone else's art, and read raw it rendered an eight-frame strip into
44pt; restore wiped the installed pack BEFORE checking a replacement existed;
a partial copy reported success; the empty-column threshold was a fraction of
source height, so it meant one stray pixel on a short board and ten rows of ink
on a tall one; canvas padding took both axes from max(width, height), so one
wide effect frame shrank the figure everywhere. Three canaries that could not
fail were replaced with probes that do — proven by re-running each mutation.

## 0.5.124 (build 162)

Settled beats rotate through every solo clip.

Running and patrol already broke into bursts against a rest clip, but that clip
was always idle — so the meditation, the draw-and-flourish and the guard
sequences sat unused behind states that are rarely on screen. A settled beat now
picks among all of them (idle, waiting, success, attention), on a hash
independent of the action schedule so the two do not move together, and the
active pose is never used as its own rest. Measured across 1200 beats, no clip
is starved.

## 0.5.123 (build 161)

Running is a burst, not a treadmill — and the character holds its size.

A session is "working" almost all the time, so a sprint on a permanent loop
was what the pet did roughly 90% of the time. Running and patrol now play as
periodic bursts against the idle clip: settled most beats, breaking into the
action about 30% of the time, at most two beats in a row (a third would be a
loop again). The cadence is a pure function of the clock, so it never jumps
when the panel redraws, and it is irregular enough not to read as a pattern.
Fight poses are untouched — a duel should look like a duel for as long as it
lasts.

Each frame was cropped to its own ink and scaled to fill the same box, so a
crouched running frame was ENLARGED to match a standing one — the figure
appeared to grow and shrink mid-stride, and its feet drifted. A strip is now
normalised as a whole: one canvas, one scale, ink bottoms on a shared baseline.
Authored pose differences survive (a crouch stays shorter than a stand) while
the character itself holds its size. Measured on the V3 running strip: baseline
spread 0 px across all eight frames, down from per-frame drift.

## 0.5.121 (build 159)

The default character animates in every state.

Jedi Miles Windu V3 replaces the bundled default: 10 animated states, 74
frames, 6-8 per state — idle, patrol, waiting, running, success, error,
attention, duel, trio, and swarm. Every frame ran through the real install
pipeline (paper knockout, valley slicing, boundary-spillover suppression,
crop, 256px fit, equal-cell stitch) and all 74 survived it, with declared and
actual frame counts matching for all ten poses.

A pack's own animated duel, trio, or swarm strip now takes precedence over the
stitched cinematic ladder, so three and five sessions play their own
choreography instead of replaying the escalation sequence. A single-frame pose
still climbs the ladder, so V2-style packs are unchanged.

Thinking, reading, writing, searching, grepping, and stopped are not in the V3
live-state manifest and fall back to their related poses, as before.

## 0.5.120 (build 158)

Jedi Miles Windu ships as the default character, and the corner flash is gone.

The processed character is bundled with the app and seeded on a fresh install,
so the pet has real art without installing a pack. Seeding is gated on a
one-time flag rather than an empty folder, so choosing your own sprite or Use
COS figure is never undone.

Frame edges: a fragment CUT by the frame boundary is spillover from the
neighbouring scene, whatever its size. The combat board leaves a 540px blaster
bolt against the left edge — 5% of the figure and a few rows tall — which the
area rule and then the cut-face rule both kept, and which showed as a flash in
the pet's top-left corner. Anything reaching the boundary now goes; detail
composed inside the frame stays, because cropOpaque pads afterwards.

## 0.5.119 (build 157)

Character size is its own dial, and the fight stops blinking out.

**Character size** joins Pet size in Settings: Pet size is the card (buttons,
text, bubbles, list) and Character size scales only the figure, 100% to 300%,
default 150%. Growing the art no longer inflates the chrome around it.

Build 156 was cut but never published: retiring the cinematic strip on any
cinematic-pose install also deleted the strip a pack's own board had just
written, because a pack installs boards and pose strips in one pass. A pack
install no longer retires its own strip; choosing a single sprite still does.

The two-session duel played the combat board's droid-only scenes, so the
character vanished mid-loop. A story strip now drops the frames its subject is
absent from, measured by the strip's own colour content against its median
(hero scenes 0.21-0.43, droid-only 0.012-0.10) — relative, so a monochrome
pack keeps every frame, and never more than half a strip.

The panel and the sprite now compute their width from the SAME measured art.
The card reserved a fixed 2.6:1 cinematic aspect while the view measured the
real frames (0.97:1 as installed), so it claimed up to 2.7x the width the
figure needed — the card looked inflated around a small character, and at the
other extreme a wide scene rendered past the panel and clipped. Pixel art also
compares against the size it is drawn at now, so scaled-up art stays blocky.

Three sessions no longer look like five: the escalation strip is a ladder, and
each level plays it only up to its own rung instead of both trio and swarm
replaying the whole thing, patrol scene included.

From a four-agent QA pass on 0.5.110-0.5.116, in order of what could bite:

- The Cursor search fallback typed the session name after a fixed delay
  without proving a text field had focus. Keystrokes go to the process, so on
  a slow palette they could land in an open source file, which no Escape
  undoes. It now waits for a text-entry element and gives up silently instead.
- "File > New Agent" fired whenever activation was refused, not when the
  window was missing, so a jump to an already-open Agents window could spawn
  an empty composer. Window existence and activation are now separate facts.
- A pet notice never expired, and any notice reads as the attention state,
  which outranks every escalation pose — one failed jump pinned the pet in
  "alert, blade ignited" indefinitely. Notices now clear after 12 seconds.
- Edge-sliver suppression ran only on strips, never on the BOARD cells that
  showed the bleed, and judged by area: a bisected neighbour at 42% survived
  while a deliberate 1.6% blaster bolt was erased. It now runs on both paths
  and keys on the cut face (edge contact across 30% of the figure's rows).
- Choosing a sprite for patrol, duel, trio, or swarm retires the stale
  stitched strip that would otherwise keep rendering in its place.
- A lost state file no longer shreds a single-cell PNG into ten slivers, and
  the frame-count stepper is no longer hidden by the value it exists to raise.
- Cursor search text posts UTF-16, so an emoji in a session title cannot
  corrupt the query; the search walker reaches the same depth as the row
  walker; the search box is cleared after a successful jump; and a tab miss no
  longer claims the window failed to open when it is on screen.

## 0.5.116 (build 154)

Frame edges are clean, and the character stands at 1.5x.

A strip cut that lands inside a figure leaves a truncated sliver of the
neighbor frame's content at the edge — it flickered during playback and broke
the animation. An ink island touching the frame's first or last column that
is not the frame's primary island is now erased at install time
(contract-tested; the primary figure survives even when it reaches the edge).
Character scale rises from 1.35x to 1.5x; the chrome still does not move.

## 0.5.115 (build 153)

The character stands 35% taller; the chrome does not move.

The figure read small against its own buttons and bubbles. The sprite now
renders 1.35x the configured pixel size — applied only to the character
frame, so buttons, text, and the session list keep their sizes and the panel
grows just enough to hold the figure. Build 152 was cut but never installed
or published; its changes ship here.

## 0.5.114 (build 152)

Cinematic frames align to their cells, and the fight dissolves between scenes.

Playback guessed the cinematic strip's frame count from its aspect ratio —
996/256 rounds to 3 across a 4-cell strip, so every frame was cut mid-cell and
a half-droid bled in from the neighbor. installGrid now persists the true cell
count and playback slices by it (contract-tested; reinstalling a pack writes
the meta). Cinematic poses cross-dissolve over the last third of each frame
interval instead of hard-cutting, so patrol, duel, trio, and swarm play as a
flowing sequence.

## 0.5.113 (build 151)

The sprite pipeline is orientation-true, and the pet reads in dark mode.

Root cause of every recurring flip: the shared bitmap buffer applied a flip
transform, but a Quartz bitmap-context round trip is already orientation-true,
so each pass inverted the image once and upright-ness depended on how many
passes a path made — it also mirrored cropOpaque's bounding box, which is why
droids kept getting cropped out. The flip is deleted and an executable probe
in ModelsContract pins orientation through fitHeight, cropOpaque, and prepare.
Cell boards split on ink islands with narrow gaps merged (a detached bolt or
debris cloud rides with its scene) forced to the manifest cell count. Strips
keep their declared frame count, with each cut nudged to the emptiest nearby
column — the Windu fight scenes connect through 2px bolt bridges, so equal
cuts bisected droids and pure gap logic could not separate them at all.
Playback slices by the count that was stitched. Cinematic scenes render a
step larger.
Pet buttons use adaptive plate ink instead of fixed ink, ending black-on-black
in dark mode.

## 0.5.112 (build 150)

The three-droid fight loops, and the droids stay in frame.

Equal-width slices cut the escalation board through the droids, then a tight
crop shaved the rest. Three or more sessions now play the four fight scenes
as a loop in a wider pet. Install the pack again after this update.

## 0.5.111 (build 149)

Pack sprites sit upright and fill the pet.

0.5.109 wrote each installed PNG upside down and kept the empty board cell
around the figure, so Running and Duel shrank into a speck. Install the pack
again after this update.

## 0.5.110 (build 148)

A Cursor pet click survives contact with real Cursor.

Three breaks, all found by probing Cursor's live accessibility tree. Agents
rows expose their title as "Chat title. <name>", which defeated every matcher
branch; the matcher now strips that chrome (contract-tested). The closed-window
fallback pressed four menu items current Cursor no longer has; it now presses
File > New Agent, the one persistent command that opens the Agents window. The
Agents list is Electron-virtualized, so a scrolled-away row is absent from the
tree; a missing row is now driven through the window's own Search affordance.
The raise is verified against the frontmost app, the notice only says "Opened
Agents" when that is true, and every jump logs raised/fronted/window-titles to
Console so a field miss names its own cause.

## 0.5.109 (build 147)

The pet escalates from patrol to a five-droid swarm.

One quiet session patrols. A running turn sprints with the saber. Two sessions
duel a droid. Three fight a cluster. Four or more go full swarm. Error deflects
a red bolt. Attention ignites the blade. A V2 pack (core states, saber run,
droid combat, escalation) installs as a folder. A V1 combat strip still covers
a two-session duel.

## 0.5.108 (build 146)

The session pet can use a different sprite for each live state.

Idle, waiting, working, several sessions, and done each take their own PNG or
horizontal strip. A folder install maps a pack (idle, search, grep, combat,
done). Two or more live sessions play combat. One identity PNG still covers
every state that has no strip of its own.

## 0.5.107 (build 145)

The Accessibility grant survives updates, and the repair notice tells the truth.

macOS keys the Accessibility grant to each build's code signature. Ad-hoc
signing gave every build a new signature, so each update stranded the grant
while System Settings still showed COS Control enabled, and the old notice
("quit and reopen") could not fix that state. Local builds now sign with a
stable identity (`COS_LOCAL_SIGN_IDENTITY`), so a grant made once keeps
working across updates. The Claude and Cursor jumps share one Accessibility
gate; when it fails, the pet says to toggle COS Control off and on under
Accessibility and opens that Settings pane directly.

## 0.5.106 (build 144)

A Claude pet click opens that session.

0.5.105 opened the workspace folder, which only raises the last Claude tab.
Claude Desktop has no working link for an existing Code session. This build
turns on Claude's accessibility tree, then clicks the sidebar row whose title
matches the session name. It does not start a new Claude session.

## 0.5.105 (build 143)

A Codex pet click opens that thread.

0.5.104 showed the running Codex row, then opened the workspace folder, which
only raises the last Codex tab. This build opens `codex://threads/<id>`, the
link Codex Desktop documents for a local chat. It does not start a new thread.

## 0.5.104 (build 142)

The pet shows a Codex turn that is actually running.

The session list treated every Codex row as idle, so a live Codex thread never
made the pet. A transcript written in the last three minutes is now Running,
same window Cursor uses for file mtime. Clicking a Cursor row no longer raises
Cursor when this build cannot use Accessibility. Quit Control and open it
again after the Accessibility toggle. The Agents jump no longer activates
every Cursor window. That raise was the IDE.

## 0.5.103 (build 141)

The Cursor card selects that session's Agents tab.

0.5.102 opened Agents, then left whichever tab was already front. This build
still raises Agents first, then clicks the list row whose title matches the
session name. It does not match that name against Cursor window titles. That
raise is the IDE. Tab jump needs Accessibility for this Control build.

## 0.5.102 (build 140)

The Cursor card opens Cursor again.

0.5.101 named an Agents miss and then did nothing. The older jump already
brought Cursor forward. It was the IDE, not Agents. This build tries Agents
first. If that misses, it activates the running Cursor app. The pet says so.
It still does not spawn `--glass --new-window` while Cursor is already
running.

## 0.5.101 (build 139)

The pet names a Cursor Agents miss instead of opening another IDE window.

0.5.96 and 0.5.99 still raised the IDE when Cursor was already running. This
build does not spawn `--glass --new-window` in that case. The pet prints
whether Accessibility is on, which window titles it saw, and whether it
spawned. The session card stays clickable under that notice.

## 0.5.100 (build 138)

The pet session card opens the session.

The list row only changed which figure was focused. The square-arrow was the
only open. The whole card, including the empty space, now opens that session
the same way the arrow does. The focused status bubble does too.

## 0.5.99 (build 137)

The pet target opens Cursor's Agents Window, not the IDE.

`--glass` by itself is a Cursor architecture flag. A running Cursor treats it
as focus-the-last-window, which is the IDE. The jump now raises a window titled
Cursor Agents, uses Switch / Open or Focus / New Agents Window, and only then
launches `cursor --glass --new-window` with no folder.

## 0.5.98 (build 136)

The session pet comes back onto the screen.

0.5.97 grew Large downward from the bottom corner, and autosave parked the
panel under the display. An off-screen pet frame snaps back. Size still
follows Small, Medium, Large, or custom pixels.

## 0.5.97 (build 135)

The session pet has a size you can set.

Small, Medium, and Large are 25 percent off the original 64 px figure.
Custom types the sprite size in pixels (32 to 128). The rest of the pet
chrome follows that size. The target still opens Cursor's Agents Window.

## 0.5.96 (build 134)

The pet target opens Cursor's Agents Window.

`--chat` is a documented Cursor flag that the running app never reads, so
0.5.95 still raised the IDE. The target on a Cursor row now focuses an
existing Agents window, or opens one with `--glass`. Claude and Codex still
open that row in Activity. Open in platform for Cursor uses the same Agents
jump. Cursor still has no composer-id deep link, so that jump focuses Agents,
not one thread.

## 0.5.95 (build 133)

The pet follows the session that is actually working.

A Claude Desktop process that is still alive is not a turn in flight, so
Blocker Clearance no longer stays Running while Cursor is the live thread.
A Cursor agent that is still generating no longer drops off the pet just
because the transcript file went quiet. Open in platform for Cursor uses the
standalone chat window (`cursor --chat`) instead of opening the workspace
folder in the IDE. A minimized Claude or Cursor window comes back the way
clicking the Dock icon does. Cursor still has no composer-id deep link, so
that jump focuses Agents, not one thread.

## 0.5.94 (build 132)

Open in platform no longer quits Control.

0.5.93 handled the Cursor jump on Apple's Launch Services queue while the rest
of Control is main-actor, so the square-arrow control trapped and the app
exited. That open now waits on the async AppKit call, unhides the platform
window, and brings it forward. The pet prints Running, Waiting, or Idle. The
target opens that row in Activity. Two or more live sessions expand the list.

## 0.5.93 (build 131)

Gallery thumbs stay put while you scroll.

0.5.92 only kept 32 stills in memory, so loading the next row dropped ones
still on screen. Loaded thumbs now stay for the session, and a thumb already
on disk is not fetched again.

## 0.5.92 (build 130)

The OpenPets gallery is on the panel.

0.5.90 hid it behind a collapsed Pet gallery disclosure under Choose sprite, so
the only obvious path was the Mac file picker. Session pet now shows the
curated OpenPets thumbnails, with search, as soon as that toggle is on. Choose
sprite is still your own PNG.

## 0.5.91 (build 129)

The menu-bar eyeglasses keep their shape.

0.5.90 drew that symbol into a square so it could carry the update pip, and
the lenses went wide. The tray is the system eyeglasses glyph again. The pip
still appears on the corner when an update is waiting.

## 0.5.90 (build 128)

A gallery of community pet figures, without leaving Control.

Pet gallery next to Choose sprite loads the OpenPets thumbnail catalog (300
curated stills, not the zip packs). Picking one copies that thumb through the
same sprite store Choose sprite already uses. Sessions, prompts, and Open in
platform stay on COS. The closed-tray update pip from 0.5.89 is unchanged.

## 0.5.89 (build 127)

The closed tray shows when an update is waiting.

The eyeglasses glyph still says whether the server is up. A small pip appears
on that same icon only when the appcast has a newer Control build, so you do
not have to open the panel to know. Install stays the banner already in the
panel. An offline tick no longer wipes a real offer, and Check for updates
says it could not reach the feed instead of claiming you are current.

## 0.5.88 (build 126)

Open in platform from the session, and a sprite you picked.

The waveform still opens the Activity session. That split was right. What was
missing is the jump to Cursor, Claude Desktop, or ChatGPT from the session
itself, so the footer next to Copy session now says Open in platform. The pet
grows the same control. Choose sprite copies a PNG into Application Support
without resampling, so a 32x32 pixel figure stays blocky. Use COS figure puts
the original visor back.

## 0.5.87 (build 125)

Live sessions stay on the desktop when Activity is closed.

The Sessions list already knew which Claude, Cursor, and Codex threads were
Running or Waiting, but that knowledge lived inside a window you had to keep
open. The pet is a floating COS figure that appears only while those rows are
live, shows a count when more than one is, and jumps to the native app that
owns the thread — Cursor, Claude Desktop, or ChatGPT — without bringing
Control forward. Clicking the waveform is the fallback: it opens that same
row in Activity, because Cursor still has no composer deeplink. The toggle
sits with Launch at login; it never talks to the server.

## 0.5.86 (build 124)

The whole calendar square selects the day.

Picking a day in Meetings meant hitting the date number itself or the little
dot under it. Everything else inside the highlighted square did nothing, so
the target was an 11.5pt glyph and a 5pt dot instead of the cell you can see.
Under `.buttonStyle(.plain)` SwiftUI hit-tests only the RENDERED content, and
the cell's background is clear until the day is selected, so the surrounding
area was never a target at all. The cell now declares its own content shape
and the entire square is clickable. Days with no meetings stay disabled.

## 0.5.85 (build 123)

The message icon itself says what is attached.

The left-column bubble was the same for every row, so a video and a text-only
turn were identical until your eye reached the far side of the row. The bubble
now wears a small filled type mark on its corner: a camcorder for video, a
framed peak for photos, a folded page for files, and stacked cards when a turn
holds more than one kind. The bubble grows from 16 to 20pt INSIDE its existing
32pt frame, so nothing about row height or alignment moves.

The marks are filled rather than stroked, and that is the reason they work. A
first pass drew them as 1.15pt outlines and every one collapsed into an
indistinct speck at that size. Each shape was then rendered at 64pt to confirm
it is the thing it claims to be, which is how the original paperclip was caught
reading as a battery and became stacked cards instead. Colors come from the
Activity section palette, so the badge and the right-hand count badge agree.

## 0.5.84 (build 122)

The message list says WHAT is attached.

Every attachment badge rendered the same `photo` glyph, so a 75-second video
sat in the list wearing an image icon and there was no way to tell a video
from a picture from a file without opening the message. The badge now takes
its icon from what is actually attached: a video glyph for video, a document
glyph for files, a photo glyph for images, and a paperclip when a turn mixes
types rather than picking a winner among its parts. Hovering names it in
words -- "1 video", "2 files" -- because a 9.5pt glyph is a hint and the
tooltip is where the answer should be unambiguous.

## 0.5.83 (build 121)

The fourth filter. Video playback now actually works.

There were FOUR independent image-only gates between the server and the
screen, not three. 0.5.82 fixed the helper's byte verifier and I confirmed
the helper returned `state: ready, mime: video/quicktime` — then shipped
without tracing what the app did with that response. `fetchMediaFile` re-
checked the mime against a JPEG/PNG allowlist of its own and threw the
ready video away, so the poster still rendered and the click still failed.
The helper working was not the feature working.

That decision now lives in one place, on the attachment model, where the
contract test executes it rather than a grep asserting it. Also fixed in
the same pass: the agent handoff exported the full video under an
`image-NN.jpg` name (masked until now by its image-decode guard, which
rejected the video and printed "unavailable"). It exports the poster frame
instead, named `poster-NN.jpg`, because a poster is the only part of a video
another agent can actually inspect.

## 0.5.82 (build 120)

Playing a video actually plays it.

0.5.81 got the poster, the play badge and the duration onto the screen.
Clicking it still failed with "This image is unavailable", because the media
FETCH path carried a third image-only gate: it sniffed magic bytes with a
JPEG/PNG-only sniffer and refused anything else. That was the last of three
independent image-only filters between the server and the screen.

Fetched bytes are now verified against the type the server declared, per
family: images by magic bytes exactly as before, video by its ISO base media
`ftyp` container, PDF by its signature, and text by decoding as UTF-8, which
is the honest check for a family with no magic bytes. The declared-vs-actual
cross-check is KEPT and pinned in both directions -- a container declared as
a PNG is still refused, and so is a JPEG declared as video. The temp file is
now written with the extension its type implies, since LaunchServices routes
on that, and the full-size ceiling rises to the 100 MB the server's own video
contract already allows. The error copy no longer calls a video an image, and
a verification failure now says so instead of hiding behind "unavailable".

## 0.5.81 (build 119)

The video fix from 0.5.80, actually reaching the screen.

0.5.80 widened the app's attachment parser and shipped. It changed nothing
visible, because the helper has its OWN image-only allowlist sitting in
front of it: a video ref died in `normalizeAttachment` and the app received
`attachments: null`. Caught by querying the shipped 0.5.80 helper for the
real Message #29 rather than trusting that the change had worked. Both
filters now carry the same vocabulary, and the helper forwards the
`category`, `bytes` and `durationMs` the poster needs to say "1:16" and
"2.1 MB". Pinned by self-tests that run the actual #29 payload through the
normalizer, and by mutations that restore each half of the old behavior.

## 0.5.80 (build 118)

Readable timestamps, and your videos and files finally show up.

Every message row rendered a bare 24-hour clock. Thirty turns spanning
several days all looked like "19:15" over "18:31", with no way to tell today
from Monday, and no AM/PM on a machine whose locale uses it, because a
hardcoded date format ignores locale entirely. Rows now carry their day:
"Today 7:15 PM", "Yesterday 6:31 PM", "Aug 24, 2:19 PM". The time half is
locale-driven, so a 24-hour locale keeps 24-hour rather than having AM/PM
forced onto it.

Video and file attachments were being DROPPED IN SILENCE. Control's parser
accepted three image kinds crossed with JPEG and PNG, so a video ref failed
it and disappeared: no badge in the list, no asset in the detail, nothing to
click. The server had been sending the whole ref all along, including a
75-second video with 13 extracted frames. The parser now accepts the full
media contract, and because a video's thumbnail variant is already a real
JPEG poster frame, posters render through the existing path. Video shows a
play affordance and its duration; documents get a file glyph and size;
clicking either hands the file to QuickTime or Preview with an extension
derived from its MIME rather than from the server's untrusted label. Images
still open inline exactly as before.

## 0.5.79 (build 117)

Pick your local model, and pin it.

With more than one Ollama model pulled, the server's automatic selection
follows the NEWEST pull -- so pulling anything silently repoints the lens.
A "Local model" picker now sits in Settings beside the other server
switches: it lists the daemon's pulled tags, shows Automatic for what the
server does unpinned, and Apply writes COS_OLLAMA_MODEL through the same
restart transaction every other setting uses. A pin whose model is no
longer pulled still renders (marked "not pulled") rather than lying about
the configuration, and an unreachable daemon is a rendered state, not an
error. The tag charset is guarded so a pasted shell fragment can never
reach the LaunchAgent environment; the write shape is executed by
self-tests. Pairs with server 6.40.0, which scales local thinking with the
requested effort.

## 0.5.78 (build 116)

One environment key for server 6.39.3: COS_OLLAMA_THINK.

(Renumbered from a 0.5.77 collision: a parallel session published 0.5.77
with the Review speakers overflow fix while this entry was being cut. Two
different binaries must never share a version string.)

Server 6.39.3 turns local-model thinking off by default (a thinking-class
model spent 98 seconds of hidden reasoning on a two-second answer) and reads
COS_OLLAMA_THINK for anyone who wants it back ("1", or a budget: low, medium,
high, max). The helper builds the LaunchAgent environment from a fixed key
list, so without this entry an opted-in thinking budget silently vanished on
every Update Server. Pinned by a self-test assertion beside the
COS_OLLAMA_MODEL one from 0.5.73, which was this exact lesson.

## 0.5.77 (build 115)

Review speakers no longer runs off the window.

Add a voice lists the unrecognized audio the server is holding, and the server
holds it for 72 hours. With thirty-odd sessions that list grew without limit,
and because the card sits outside the voice directory's scroll area it pushed
the section header, the view picker and the breadcrumbs off screen. There was
no way back to navigation without resizing the window.

Past five held sessions the list now scrolls inside a fixed frame and the lead
line says how many are held, since a scrolling box hides its own length. Five
or fewer keeps its natural height. A test pins the cap and goes red if the
list ever renders uncapped again.

## 0.5.76 (build 114)

The refusal said "fork it." Now you can.

0.5.75 shipped the composer rendering the server's busy-thread copy — "Wait a
few seconds and try again, or fork it" — with no fork anywhere in Control, an
instruction with no affordance. Caught live in the first session. A "Fork with
this message" button now appears wherever the rendered copy recommends it:
your message runs in a copy of the thread, seeded with its history, while the
original stays byte-identical. The fork lands at the top of the Sessions list
(the server deliberately withholds the new thread's id). Cursor sessions
refuse with the server's own copy — bindable, not forkable.

The 0.5.75 fallback line ("Forking is not available in Control yet") never
rendered either: it matched capital-F "Fork" against copy that says "fork it".
The button's trigger matches case-insensitively, and that exact regression is
pinned red. The fork prompt travels over stdin like the send path.

## 0.5.75 (build 113)

Continue a session from the Sessions view — text in, reply back.

A composer now sits under every Claude, Codex, and Cursor session detail. Type
a message, and it lands in the real thread on this Mac through the same
attach/turn API the glasses' Continue ships on: attach a binding, post one
idempotent turn, poll to a terminal outcome, then show the session's newest
reply. Text only, by design — files and images wait until the text path has
earned them.

The poll classifier encodes the server's least obvious truth: a RUNNING turn
polls as 404, because the ledger records only terminal outcomes. Anything that
is not a 200 body carrying completed/refused/ambiguous stays pending, bounded
by wall clock — mapping it to a failure would invite the retry that double-
posts into a real conversation. Refusals render the server's copy verbatim
with the composer disabled; native_thread_changed gets an explicit Refresh /
Continue-anyway choice, and only that gesture ever sends an acknowledgement.
An attachable verdict with a live owner (a session that merely looks idle this
second) asks before the first send instead of showing a green light. The
prompt travels to the helper over stdin, never argv.

Also fixed: the Continue agent threads OFF toggle wrote nothing. It deleted
the environment key, which servers 6.37.0+ (default-ON) read as ENABLED — so
opting out silently re-enabled the feature and then stranded a stuck
transaction on the failed proof. Off now writes an explicit "0", which means
disabled on every server era, and the self-test executes the write.

## 0.5.74 (build 112)

The panel now says when a local Ollama model is live.

An "Ollama · {model}" row appears in About, and a matching line in Doctor, when
the server reports a local daemon ready with a pulled model -- and both vanish
entirely otherwise. No row is the correct render for "no local daemon": painting
a red mark on every Mac without Ollama would imply it is expected setup, and a
pre-6.39.0 server (which never reports the keys) must not look broken.

Three properties are pinned by helper self-tests: a healthy server with the
daemon down is not a provider capability failure; a pre-6.39.0 health body stays
clean; and the model tag never routes through version parsing, which would
truncate "qwen2.5-coder" to "2.5". The health read ignores the top-level
`ollama` key deliberately -- it is a spread check STRING ("fetch failed" on a
daemonless box), not a boolean.

## 0.5.73 (build 111)

Two environment keys for the new local-model support in server 6.39.0.

COS_OLLAMA_MODEL (pin a local model) and COS_OLLAMA_HOST (alternate loopback)
are now allowlisted into the LaunchAgent environment the helper writes. The
helper builds that plist from a fixed key list, so without this a user's Ollama
settings silently vanished on every Update Server. Pinned by two self-test
assertions so the keys cannot drop out of the list unnoticed.

## 0.5.72 (build 110)

Six months of conversation you could store but not reach.

COS archives every day's conversations. On a working install that is 175 day
files going back six months, and nothing in COS Control could open any of it --
no helper command touched the archive at all.

Messages now has a Recent / Archive switch. Archive lists every archived day with
its volume (chats and messages, not just a date, so a busy day is distinguishable
from an idle one at a glance) and searches the whole store by text. Search runs on
submit rather than per keystroke, because a wide window is a real multi-second
scan on the server, not a local filter.

A hit is attributed to a DAY, with the text around each match. Not to a chat: the
server scans day files as raw bytes and never materialises one, which is what
makes searching six months affordable at all.

OPENING THIS VIEW WILL NOT WAKE A SLEEPING GIANT. On a server predating the
archive index, GET /api/archive builds its summaries by parsing every day file --
1.2 GB on the real corpus, and 2.3 GB RSS for the largest single day, on the same
process running the wearer's live session. So the listing PROBES the search route
first and refuses with "update your server" rather than making the request. An
older server does not 404 for that probe; it falls the path through to
/archive/:date and answers 400 "Invalid date", which is the signature this checks
for. Verified live against 6.37.3.

Until a server carrying the archive routes is published, Archive shows that update
notice. Everything else in this build is unaffected.

Four guards pinned in Tests/run.sh, each mutation-verified red: the 400
fallthrough, probe-before-list ordering, search-on-submit, and the day list's
volume counts. Two of those pins were decoration when first written -- one loose
substring was satisfied by an unrelated row elsewhere in the same file, and one
mutation never applied at all -- and were tightened until the mutation actually
turned the suite red.

## 0.5.71 (build 109)

A way to tell people what they can now do.

The appcast can carry a `notice` block: an id, a title, a body, and a minBuild.
COS Control shows it as a dismissible banner at the top of the panel, beside the
update banner, and it is edited on the server rather than shipped in a build.

It is deliberately NOT gated on an update being available. Somebody who just
finished updating is up to date, and that is precisely the moment a "here is what
you can now do" message is worth reading. Gating it on `updateAvailable` would
hide it from the only audience it is for. It is parsed before the killSwitch,
malformed and requiresMacOS returns for the same reason, so those paths cannot
swallow it.

`minBuild` keeps it off builds that lack the feature being announced, so nobody
is told about something they cannot use. Dismissal is stored per notice id, so a
later notice still appears and a dismissed one never returns.

## 0.5.70 (build 108)

Named speakers failed silently, in the one panel built to fix them.

The 26 MB voiceprint model that separates speakers is fetched by Guided Setup and
by nothing else. Installing COS Control does not fetch it and neither does
Update Server: both stage the server with `npm install --ignore-scripts` and
never execute `bin/cli.cjs`, and the package ships no install hook. Without the
model, diarization falls back to wearer/Ext.

That produced the worst version of the failure. Open a five-person meeting in
Review speakers, see two voices called Me and Ext, and get no reason. The server
has reported `speaker_id` on /api/health the whole time. Control had never read
it.

Control now reads it and, when it is not `active`, the Review speakers card
carries a banner saying every voice stays Me or Ext until the model is
installed, with a button that opens Guided Setup. An older server that predates
the field reports nothing and the banner stays hidden, so upgrading does not
start nagging.

The field is read from the TOP LEVEL of the health body. health.ts assigns
`checks.speaker_id` but spreads `checks` into the response, so the nested path
the source implies is always nil. Wiring it from the assignment site would have
shipped a banner that could never appear. Verified against the live payload
first, and pinned in Tests/run.sh.

# Changelog

## 0.5.69 (build 107)

Two CTAs that read wrong.

DUPLICATE RECOVER. With exactly one recoverable capture the panel rendered two
buttons both reading "Recover": a bulk button whose label collapsed to the
singular, and the per-row button. Both fired the same recovery on the same
session — the bulk branch fell through to `recoverableOrphans.first` — one
appeared greyed because the row was mid-recovery, and nothing told the user which
was authoritative. The bulk button is now guarded on `count > 1`, and its
single-capture fallback is deleted with it since the guard makes it unreachable.
The per-row button already covers one capture AND carries the label and chunk
count that say what is being recovered.

FOOTER CTAs. "Check for updates" and "Quit" were `.buttonStyle(.link)` at
mono(10) with a secondary foreground and no spacing between them, in a panel
where every other action is a bordered chip with an SF Symbol. They read as one
run-on string, with nothing separating a harmless action from one that kills the
app. Now bordered chips with icons, on their own row beneath the version label —
the panel is a fixed 390pt and the label already wraps, so sharing a row would
have squeezed it further.

Both are pinned in Tests/run.sh, and both pins were mutation-verified: restoring
the singular Recover label or returning Quit to `.link` fails the suite.

## 0.5.68 (build 106)

The Meeting Turbo preview checkbox was lying.

It resolved its value as `== "1"`, and an absent environment key reads as nil,
so the box rendered OFF for every user who had never set the variable — while
the server had the feature ON the whole time (`COS_WHISPER_MEETING_PREVIEW` is
`!== '0'` server-side, and always has been). Turning it "on" changed nothing,
because it was already on. Seen on a first-time user's 6.36.28 install
reporting meetingPreviewEnabled:false against a server running the feature.

A checkbox that misreports a running feature is worse than no checkbox.

Three more gates flipped to default-ON in glasses-server 6.37.0 — Continue
agent threads, Reliable video uploads, Adaptive audio cleanup. Those read the
server's live health first, so a running server was already reported
correctly; their STOPPED-server fallbacks had the same `== "1"` mistake and are
fixed too.

All four now resolve through one `featureGateDefaultOn` helper, unit-tested in
the helper self-test (absent, empty, "1", a stray truthy value → ON; only a
literal "0" → OFF) with a Tests/run.sh assertion that every call site still
goes through it. Both layers mutation-verified.

Also allowlists COS_MEETING_SUMMARY and COS_MEETING_SUMMARY_DAILY_CAP in the
provider environment. `providerEnvironment` is filtered to that set on every
plist rewrite, so without them a user who enabled standalone meeting summaries
would find them silently off again after the next Install / Repair / Update
Server — the same failure that made COS_PROFILE_PATH stop surviving updates.

Idle Metal HQ and Show Claude sessions are unchanged: they are genuinely
opt-in server-side, so `== "1"` is correct for them.

## 0.5.67 (build 105)

A Check for updates button, in the footer.

The automatic check runs once at launch and then every 6 hours. That is the right
cadence for a background poll and the wrong one for a hotfix: a Control left
running -- which is the normal case for a menu-bar app -- can sit behind a release
for hours with no banner and no way to ask.

Measured today. A Control up since the previous afternoon was TWO builds behind,
0.5.64 against an appcast at 0.5.66, because every 6-hourly tick had landed
before the releases went out. The only remedy was to quit and reopen the app.

SILENCE IS THE WRONG CONTRACT FOR A BUTTON

`checkForAppUpdate()` deliberately swallows its failures, and that is correct for
a background check -- an offline laptop should not raise an error nobody asked
for. But a user who clicks and sees nothing cannot tell "you are up to date" from
"the check failed" from "the button is broken". That is the same
indistinguishable-outcomes problem that has cost this project real days.

So the manual check is a separate method rather than the same one wired to a
button, and every path reports: an update (the banner already offers it), up to
date (says so, with the version), or the failure (says what went wrong). It also
shows "Checking…" while in flight, which the background check never does.

Three guards in Tests/run.sh, all mutation-verified: removing the up-to-date
message fails, swallowing the failure fails, and a button that stops calling the
method fails.

## 0.5.66 (build 104)

Add a voice, from the Speakers pane. Closes the second half of #2.

Naming a voice already worked, but only INSIDE a meeting review, and that can
only ever rename a voice the system had already separated out. A user whose
whole transcript came back `[Ext]` has nothing to rename, and no reason to know
the glasses voice command exists. 0.5.65 told them what was wrong; this gives
them somewhere to click.

WHERE THE AUDIO COMES FROM

The server already holds unrecognized-speaker audio for 72 hours. Naming one of
those sessions builds a real profile from real meeting audio, which is better
training material than a cold 30-second sample and is exactly what a review
would have used.

SAFETY, all of it server behaviour rather than our guesses

- Always scoped to ONE session. The server treats the unscoped form as a
  profile-poisoning default -- it assumes one speaker across every held session
  and deletes them all -- and gates it behind `confirmAllSessions`. The helper
  never sends that flag and refuses a call without `--session`, so the dangerous
  form is unreachable from Control by construction, not by discipline.
- The panel says a held session can still contain MORE THAN ONE unknown speaker
  before the user commits. That is a real risk, not a hypothetical: it is why an
  earlier manual enrolment was declined.
- It says the audio is consumed on success. There is no undo.
- The expiry countdown is the server's own string, so it cannot drift from the
  retention actually enforced.

Shown in BOTH the empty and populated directory. A user with zero profiles is
precisely who needs it, and an empty state that only explains the problem is
what sent the original report to Discord instead of to the fix.

Four guards in Tests/run.sh, all mutation-verified. One of them was decoration
on the first pass: asserting the string `--session` appears only proved the flag
is mentioned, and a mutation that defaulted it to `""` sailed through. It now
pins the refusal message, which lives only in the guard's else branch.

## 0.5.65 (build 103)

Hotfix for issues #1 and #2. An empty speaker-review list told new users to do
the one thing that could not help.

Reported by Chelsie on 2026-08-24: server 6.36.28 (latest), `speaker_id: active`,
voiceprint model installed, 31-minute G2 meeting transcribed entirely as
`[Ext]`/`[Unknown]`, and no `voice-profiles.json` ever written. Speakers to
Meetings-to-review said "1 recent meeting predates speaker review. Update the
server to review new ones." She was already on latest. Hours lost.

Nothing was broken. She had zero enrolled voices.

- `voice-profiles.json` is created BY enrolment, so its absence is the initial
  state, not a fault.
- With zero profiles the server's `identifySpeaker` finds no match and labels
  every segment `Ext`. 170 `[Ext]` lines was correct behaviour.
- It cannot self-heal: `autoEnroll` needs a match against an EXISTING profile and
  explicitly skips `Ext`, so it can never create the first one.

The old message was wrong on its own terms too. `skipped` counts rows the helper
dropped for having no sessionId; it has nothing to do with the server version.

WHAT CHANGED

- `emptyReviewReason` asks the server for the enrolled count and reports the
  actual cause. Zero profiles now says so and names the fix. Rows dropped for a
  missing sessionId say that, and no longer blame the server version.
- The count is fetched rather than read from `voiceDirectory`, which a different
  subview loads and may never have run. Only on the empty path, so the normal
  case costs nothing. If the count cannot be established we say the honest thing
  instead of guessing — an unanswered probe is not evidence of zero.
- Both empty-state messages now name the action. Enrolment was already built and
  wired (a guided 30-second flow on the glasses) but reachable only by the voice
  command "enroll my voice", and Control's Speakers pane is view-only — so a user
  who read the accurate message still had nowhere to click.

Guards in Tests/run.sh, both mutation-verified: the misleading sentence cannot
return, and both empty-state messages must name the enrolment phrase. The first
guard is comment-aware — a plain grep matched the doc comment recording the old
wording, which is the "assertion satisfied by the file's own prose" failure, and
it was caught by running it.

Not fixed here: there is still no enrol action in Control, and the 72-hour
`ext-audio` recovery window is not surfaced anywhere. Both tracked in #2.

## 0.5.64 (build 102)

**"Show Claude sessions" was telling you it was off while it was on.**

The checkbox seeded from `model.claudeSessionsEnabled`, which only
`loadClaudeSessions()` sets -- and every caller of that lives in the Activity
window, never in the panel. Open the panel without visiting the Activity window's
Claude tab and the box rendered false regardless of the real setting. The setting
was on; Miles enabled it four times against a control that could only show him one
value. The comment above the line named the hazard ("only accurate once that has
loaded") and it shipped anyway.

It now reads `status.claudeSessionsEnabled`, which the panel refreshes on its own,
like every other toggle on that screen. Server 6.36.22 publishes it in
`health.features` -- a pure env read, free on a poll -- rather than the panel
paying for a 58-session listing to learn one boolean.

ONE SOURCE, no fallback to the old path. A second source is how this broke, and it
also defeated the new guard: the fallback mentioned `model.status` in a `== nil`
check, which satisfied the check while assigning from somewhere else.

Against a server older than 6.36.22 the field is absent and the toggle is left
alone rather than forced off.

**New guard: every panel toggle must be BOUND from status.** It took three
attempts to write one that could actually fail. Whole-line matching was satisfied
by that `== nil` guard; a four-line window was satisfied by the NEIGHBOURING
toggle's status read, because every seed in `onAppear` sits within four lines of
another. The check now requires the assigned value itself to come from status, and
lives in `Tests/panel-toggle-source.py` because inlining it in a heredoc mangled
its regexes into a syntax error that looked like a failing test.

## 0.5.63 (build 101)

**Every confirmation button in the panel was dead except Cancel.**

Inside `MenuBarExtra(.window)` a `.confirmationDialog`'s non-cancel button action
never runs. Clicking it dismisses the sheet and executes nothing. `role: .cancel`
DOES run, which is why this survived: the dialog appeared, Cancel closed it, and
the panel looked healthy from every angle including code review.

Nine dialogs were wired that way. Release fence, Reset live message count, Clear
stranded video uploads, Restart self-managed server, and Stop legacy and install
all did nothing when confirmed. Choose Again / View Examples / Recover all /
Save all / Install and reopen were on the same mechanism.

Proven on-device with `Tests/fence-canary`, which puts the presentations side by
side in a real menu-bar popover and logs a breadcrumb at every step:

    A  confirmationDialog + @State   Release NEVER fired; only Cancel dismissed
    B  confirmationDialog + model    Release NEVER fired; the setter ran TWICE
    C  inline overlay                fired, every time
    E  the shipped cosConfirm        fired, and the captured value came through

All ten confirmations now use `cosConfirm`, an inline overlay. The one surviving
`.alert` carries a lone cancel-role button, and a test now enforces that any
`.alert` may carry nothing else.

The fence release also captures its record while the confirmation is on screen.
`cosConfirm` dismisses before running the action and dismissal nils
`fencePendingRelease`, so an action that read the model would guard out and
release nothing. The previous code read the model inside the action while a
comment above it claimed the opposite.

Two test lessons are now enforced rather than written down. The 0.5.47 assertion
that guarded this exact button passed for months against a button that never
ran -- it checked that a capture preceded a `Task`, which was true and
irrelevant. It now asserts the invariant. And the new guards strip comments
before matching, because both files explain the rule in prose and a plain grep
would match the explanation.

`Tests/run.sh` is grep-over-source and cannot see whether a closure is entered,
which is how this shipped. The canary is committed alongside it and compiles the
shipped component rather than a copy, so a regression there fails here.

## 0.5.62 (build 100)

**RESET # no longer rotates the era when it cannot reach the server.** The disk
fallback ran whenever `request()` returned nil -- a timeout on a busy Mac was
enough -- and it writes `message-era.json` directly, bypassing the server's
confirm, in-flight and shutting-down refusals entirely. It also discarded the
result of its own `POST /api/archive/now`, so the snapshot silently failed for
exactly the reason the fallback triggered, and it still reported "Archived".
Transport failure now surfaces an error. The disk path is reserved for a genuine
404/405 -- a server too old to carry the route -- and fails closed if the
snapshot does not return 2xx.

**The confirmation dialog stopped describing behaviour that no longer exists.**
It said "Archives live messages" and "This does not delete anything." Against
server 6.36.20 nothing is archived, and against a phone older than 6.8.423 it
deletes the entire chat list, the prompt queue, the nav position and any
half-typed prompt. It now says what happens and names the version it needs.

## 0.5.61 (build 99)
- **RESET # stops claiming it archived anything.** Server 6.36.19 rotates the
  message era without ending live sessions, so `archived` is now always 0 and the
  old copy would have read "0 live sessions archived." The message now says what
  actually happens: next message is #1, older cards keep their numbers, history
  stays in ARCHIVE. The non-zero wording is kept for an older server.
- Requires server **6.36.19** and app **6.8.422** before resetting from any
  surface. On an older pair the reset still empties the chat.

## 0.5.60 (build 98)
- **Show Claude sessions is a switch again.** The helper has shipped
  `set-claude-sessions` for some time, writing both `COS_CLAUDE_SESSIONS_ENABLED`
  and `COS_CLAUDE_SESSIONS_SHOW_NAMES` through the manifest — but nothing in the
  app ever called it. The feature was reachable only by knowing an undocumented
  environment variable, so to a beta tester it looked broken. Advanced now has
  the toggle, and because it routes through the helper it survives Control
  rewriting the LaunchAgent, which a hand-set `launchctl setenv` does not.
- **A switched-off list says so.** Sessions are off by default — the endpoint
  projects another product's private 0700 state directory over a LAN-bound
  socket, so it is opt-in. When off, the pane showed the ordinary empty copy,
  which reads as "this is broken" rather than "this is turned off". It now names
  the setting and where to find it.
- Anyone who worked around this with a `launchctl setenv` login item can remove
  it; the toggle is the supported path and writes the same keys durably.

## 0.5.59 (build 97)
- **Meetings to review is a work queue.** Unnamed first, reviewed last. Hide
  reviewed keeps finished rows off the list. The review pane puts unnamed
  voices at the top, says how many still need names, and **Next to name**
  (⌘]) jumps to the next unfinished meeting. The Meetings library shows the
  same tags on G2 rows.

## 0.5.58 (build 96)
- **Speakers opens on Meetings to review.** Voices is the secondary tab.
- **New recordings, refresh needed, and review progress are visible on the list.**
  NEW tags meetings that arrived after the last baseline. Refresh turns amber
  with a count when a quiet poll finds sessionIds not on the current list —
  it does not shuffle the list while a meeting is open. Each row shows
  **N to name** or **REVIEWED** from server `voiceReview` (6.36.18+) and from
  the visit overlay after you leave a meeting.

## 0.5.57 (build 95)
- **Naming a new person in Speakers review now claims the voice profile it creates.**
  Server 6.36.17 enrols a wrong existing label → new name (Nick Gurney → Milo
  LeBaron). The confirm card says the name is not in profiles yet; after save the
  toast reports samples added, and the picker can use that name on the next
  cluster without retyping it as "new name." The this-meeting scope copy no longer
  pretends enrolment is unbuilt.

## 0.5.56 (build 94)
- **Activity cards are gotcos paper, not espresso with a corner smudge.** The public
  `.chapcard` treatment is a 9px gold stipple over the whole tile, faded 135° from
  the leading edge. Control had been drawing that screen onto a trailing glyph, so
  the gateway photographed as flat. The field is the card now; hover densifies it.
  Same Canvas layer as before — still not a `.drawingGroup()` mask.

## 0.5.55 (build 93)
- **The black lockup was in three places, and 0.5.54 fixed one.** The Activity header was
  corrected; the window toolbar and the menu-bar panel header still used `COSPalette.ink`, a
  fixed dark that renders black on espresso. All three are adaptive now, and the check sweeps
  every source file rather than the one instance that happened to be on screen.
- **The halftone is a field again, not a traced outline.** It was masking the dot screen to a
  glyph stroke, so ink only landed along a thin line and the plate read as a few specks. It is
  now an even field with the mark showing through as a density change, sized to bleed off the
  trailing corner instead of sitting in it, at .22 resting and .52 on hover.

## 0.5.54 (build 92)
- **The plate was invisible.** `.drawingGroup()` rasterises into an offscreen buffer, which
  does not survive being used as a mask, so the halftone composited to nothing. The stroke was
  also 1.6pt under a 5pt dot screen, which punches through nearly the whole line and leaves
  specks rather than an engraving. Stroke is 5pt now, and the resting opacity moved from .07
  to .16 — the .07 was tuned against a mock where the dots covered the whole card, not a
  single glyph.
- **The COS lockup rendered black on the dark panel.** It used `COSPalette.ink`, which is a
  fixed dark: correct on the brand tile it was written for, invisible on espresso. It takes an
  adaptive style now.
- **The counts were being scraped out of a sentence.** Leading digits became the number and
  the remainder became the label, so "50 of 5528" showed **50** over `OF 5528` — the smaller
  number promoted and the label left a fragment. Memories, Threads and Meetings now read
  `status.memoryCount`, `status.threadCount` and the library count directly.
- **Hover reads without depending on the plate.** A faint gold wash joins the border, lift and
  cascade, and the hover handler no longer clears state for a tile you have already left,
  which raced the enter event of the one you moved onto.

## 0.5.53 (build 91)
- **The Activity gateway is rebuilt, and the accent bar is gone.** That bar was a 3pt pill
  overlaid on a 16pt-radius card — a CSS `border-left` moved into SwiftUI without reconciling
  the geometry, so the card curved away and the bar stayed straight. Nothing sits on the edge
  now. Each tile carries its section's own mark as a ghosted, dot-screened plate, and the plate
  is a child clipped by the tile, so it follows the radius by construction rather than by care.
- **Six ad-hoc hues became one accent.** Gold marks hover and selection; nothing else on the
  gateway is colored. Semantic color inside the panes — provider, speaker, review state — is
  untouched, because there it carries information.
- **Marks paint themselves in, the way the gotcos lockup does.** Each glyph draws its outline
  on, each heading wipes in left to right, cascading 45ms per tile. Hover resolves a tile's
  layers in sequence rather than together, and the delay applies on the way in only, since a
  staggered exit reads as lag. Reduce Motion lands the finished frame rather than a half-drawn
  one — the pre-states here hide content, so leaving them stranded would blank the headings.
- **The tab indicator travels instead of blinking.** One gold underline slides between tabs
  rather than six colored ones toggling.
- **Three columns, two rows.** All six views sit above the fold in 266pt instead of 454pt.
- **Open panes match.** The tinted chip in pane headers and rows is now the same stroked mark
  as the gateway and the rail, at unchanged 32/42pt frames, so a pane no longer presents a
  second vocabulary for the same six things.

## 0.5.52 (build 90)
- **Activity is the first thing in the menu bar.** It sat below Restart / Stop /
  Update Server, so the main reason to open Control was the fourth block. It is
  now directly under the header. Each chip (Messages, Speakers, Meetings,
  Memories, Threads, Sessions) opens that tab. Open still restores the window
  without wiping a place you already had.

## 0.5.51 (build 89)
- **Install the update from the menu bar.** When gotcos.com advertises a newer
  Control build, the banner's Install button downloads the zip, checks the
  published SHA-256, verifies the signature and bundle identity, replaces this
  app, and reopens it. The glasses server is not drained, restarted, or
  rewritten. A meeting in progress refuses the install rather than interrupting
  it. This is the last unzip: later releases install in place from here.

## 0.5.50 (build 88)
- **`recent` stopped meaning Today.** That state is the server's "not running"
  bucket. Control printed it as a date word, so a session last touched 82 days ago
  sat in the list looking like it moved this morning. The chip is gone for that
  bucket. The row now always shows when it was actually updated — including
  same-day rows, which used to be suppressed unless the open→update span exceeded
  36 hours.
- **The list now says what the caps hid.** The server reports how many sessions
  the 7-day window, the 20-per-provider cap, and the Cursor 32 MB skip dropped.
  Control surfaces that as a sibling of the session array (the 12-key row
  projection is unchanged) and in the Sessions subtitle. Search still reaches
  past the 7-day window.

## 0.5.49 (build 87)
- **None of your pinned Claude sessions reached the Pinned view.** Two causes, both in
  Control. It compared pins against an 8-character session id when they are stored as full
  UUIDs, so the lookup was never true for Claude. And it built the list by walking
  `~/.claude/projects` only — six of seven pinned sessions have no file there, they live in
  the Claude Desktop store, and the desktop index was used to enrich a row's title but
  never to create one. Measured: 7 starred, 0 shown.
- **The Sessions list now comes from the server instead of a second local scanner.** The
  server already resolved both cases correctly and returned all 7 pins with the right
  titles; Control simply never asked it. Live status is still overlaid from the live-peers
  route, matched by prefix because those ids are the short form. If the server is
  unreachable the old local scan still runs, so the window is never empty — but it is the
  degraded path now, not the source of truth.

## 0.5.48 (build 86)
- **Session search stopped discarding the server's answer over 400ms.** The lookup used a
  2s client timeout on a route measured at 1.44-2.40s — the slowest of six consecutive
  calls already exceeded it, so whether you got the server's ranked, semantic answer or a
  local keyword scan came down to timing. Raised to 15s.
- **"This server is too old" was reported for four different failures.** A missing token,
  an unreachable server, a non-200 status and a genuinely absent route all emitted
  `server_too_old`, which sent you looking for an update that was never the problem. Each
  now reports what actually happened, and the hint under the search field says so.

## 0.5.47 (build 85)
- **The Release button on a fenced thread could silently do nothing.** Dismissing the
  confirmation dialog nils `fencePendingRelease`, and the button deferred its work into
  a `Task` that began `guard let record = fencePendingRelease else { return }`. If
  SwiftUI ran the dismissal setter first — an ordering this code must not depend on and
  cannot verify from source — the release returned with no request, no error and no
  note. That is the 0.5.17 dead-button shape, and no source grep can see it.
- The record is now a PARAMETER, captured synchronously in the button closure before the
  `Task`, which removes the dependency on the ordering rather than betting on it. Two
  mutations fail the suite: moving the capture back inside the `Task`, and re-reading the
  published property in the model.
- **Not verified on a real fence.** There has never been one on this machine
  (`GET /api/agent-sessions/fences` returns empty), so this path has still never been
  exercised end to end. The fix is correct under either ordering; that is the claim, not
  that it was observed working.

## 0.5.46 (build 84)
- **Forks were never missing — they were indistinguishable.** Miles: "I forked that COS
  glass server work, and now I can't see any of the forks. I do see the original running,
  though." Both forks were in the list the whole time. A Claude fork is
  `--resume <id> --fork-session`, which inherits the parent's history, so the derived title
  is IDENTICAL. Measured 2026-08-18: two live sessions both named "COS-glasses Server work
  (meetings)" with distinct ids (31732572… / a4b2b4dd…), same workspace, same state — the
  rows were pixel-identical, and 8 duplicate-title groups existed across 69 rows.
- When a title appears more than once on screen, the row now shows when that session was
  opened — the one field that actually differs and that a person can act on. Applies to the
  list and to search, because both share `sessionRow`.
- The duplicate detection is a pure static helper (`ClaudeSession.ambiguousTitles`) so it is
  covered by execution rather than by reading the view; four wiring assertions pin that the
  row actually consults and renders it. Four mutations, four caught.
- Note: two untitled sessions in the same workspace legitimately share a title (`title`
  falls back name → workspace → id) and ARE flagged. A test asserting otherwise was wrong
  and the suite caught it.

## 0.5.45 (build 83)
- **The durable-fence flag now survives an update.** `COS_THREAD_FENCE_DURABLE` was
  not in `providerEnvironmentKeys`, and Control FILTERS the LaunchAgent environment
  to that set on every plist rewrite — so setting it by hand would have been dropped
  by the next Update Server, silently reopening every fenced thread. Same seam that
  stopped `COS_PROFILE_PATH` from surviving updates. A test now fails if the key
  leaves the allowlist.

## 0.5.44 (build 82)
- **Fenced threads are visible and releasable from Control.** A fence shuts a native
  thread that may already hold an undelivered COS turn, so a prompt cannot be
  double-delivered into a real conversation. Until glasses-server 6.36.10 it was
  in-memory only, wrote no log line, and the only thing that cleared it was
  restarting the server. A new card lists fenced threads with when each was fenced,
  and a Release action reopens one after a confirmation.
- **The card is conditional, like Doctor.** Normally there are no fences and the card
  is absent; a permanently empty card teaches you to skim past the one time it
  matters. It loads when the panel opens, because a card gated on a non-empty list
  cannot appear if nothing looks.
- **Releasing is two deliberate actions.** The server fails closed and answers 400
  with a preview of what it would reopen; only the confirmed call carries `confirm`.
  Control shows a confirmation dialog first, the same pattern as the legacy-restart
  and managed-install actions. A fence is addressed by digest, never by the raw
  target key, which embeds the private native thread id.
- **A release that could not be durably recorded is not reported as success.** The
  server answers 500 and keeps the fence; Control says so rather than claiming the
  thread is open. If the server's own fence writes are failing, the card says these
  will not survive a restart — a memory-only fence behaves identically until then.
- **Requires glasses-server 6.36.10** for the `/api/agent-sessions/fences` routes.
- Seven assertions pin the chain: helper commands exist, the release is confirm-gated,
  the helper does not throw on the server's 400 gate, the card is mounted, its rows
  call the opener, the dialog is bound to what the opener writes, and the panel loads
  fences on appear. Each was mutation-tested. Three of them initially passed against a
  broken tree because a bare grep matched an identical line in another function, so
  those are now scoped to the block they are about.

## 0.5.43 (build 81)

- **Continue an agent thread survives Update Server.** Glasses server 6.29.0 gates
  the Continue write path behind `COS_THREAD_ATTACH_ENABLED`, which it reads
  straight off `process.env` and never parses out of a `.env` file. The
  LaunchAgent plist is therefore the only channel that reaches it, and Control
  rebuilds that plist from its own allowlist on every Install, Repair, and Update
  Server. The key was not on that allowlist, so a hand-set flag was silently
  dropped by the next update and Continue vanished from the session menu with no
  message and nothing to point at. Same failure that lost `COS_PROFILE_PATH`. The
  key is now allowlisted, and a self-test executes the real capture path to prove
  it carries through.
- **A toggle for it, in Tools.** "Continue agent threads" appears only when the
  running server says it supports the feature, which that server now publishes
  itself rather than having it inferred from a version number. Off by default.
- **Off REMOVES the setting rather than writing a zero.** Continue defaults off,
  so an absent key already means disabled, and the server states that contract
  directly: absent means disabled, never enabled. Removing the key returns the
  LaunchAgent to its untouched default instead of leaving a value behind to be
  maintained forever, and it makes the off state provable by absence. This is
  deliberately the opposite of Meeting Turbo preview, which defaults ON and must
  write an explicit zero, because for that flag an absent key means enabled and a
  delete would quietly disarm its rollback.
- Applying the change is verified two independent ways before it reports success:
  what launchd actually handed the service, and what the running build says it did
  with it. Either one alone can be wrong.
- Both new guards are mutation-verified against a green baseline. Dropping the key
  from the allowlist, and changing Off to write a zero, each fail the suite while
  still compiling.

## 0.5.42 (build 80)

- **COS Data never switches your tier on its own.** Choosing a folder used to
  re-derive which store you get from what that folder contains, preferring the
  Python bridge whenever a workspace held both. So a user on plain markdown notes
  who re-picked their own folder — after moving it, or because an error told them
  to choose it again — was silently moved onto the pipeline. The two tiers serve
  DIFFERENT data and never merge: a working bridge means the server stops reading
  `memory/` and `threads/` entirely. Measured on a real install, that swap traded
  11 memories and 6 threads for 21 and 5 sharing no content.
- Resolution now happens WITHIN the tier you are already on. Nothing new is
  stored: the preference was always durable as which env key is set, and the bug
  was that resolution ignored it. Existing installs keep their tier by
  construction. A brand-new install gets plain notes — no venv, no Python — and
  the bridge is an explicit choice rather than something that happens to you.
- Asking for the bridge in a folder that has none now says so, instead of quietly
  handing back the other tier. A silent downgrade is the same surprise as the
  silent upgrade.
- **"This COS workspace uses an older Memory and Threads bridge" is gone.** It was
  thrown for ANY non-zero exit from the bridge, and the common cause by far is
  Qdrant being unreachable after Docker fails to restart. That wording sent three
  separate sessions chasing a version problem, and it told the user to re-pick
  their folder — which, before the fix above, is what swapped their tier. It now
  reports the actual exit code and output and names Docker as the usual cause.
- **A symlinked `memory/` or `threads/` is recognised again.** The check rejected
  symlinks while the server follows them, so Control reported "no root" for a
  store it was simultaneously reading 11 memories and 6 threads out of — then
  offered "Create Folders" over folders that already existed.
- Three execution self-tests cover these, alongside the ones added for the
  2026-08-08 meetings-library case. Both guards are mutation-verified: restoring
  bridge-first preference and re-rejecting symlinks each fail the suite while
  still compiling.

## 0.5.41 (build 79)

- **Lookup Recency next to Domain.** Meetings, Sessions, Memories, and Threads
  search can sort Newest (default), Oldest, or Best match. Newest uses last
  made/edited time so this morning's call beats an older higher-score hit.
  Changing Recency re-sorts the hits already on screen.

## 0.5.40 (build 78)

- **Sessions lookup reads recent transcript bodies.** Keyword search still
  matches titles first. It then peeks the newest 80 Claude, Codex, and Cursor
  transcripts from the last 7 days (96 KB each), so a term like EWIC in the
  first user turn hits even when the sidebar title does not. Full-history
  body scan is what hung before; this does not do that.

## 0.5.39 (build 77)

- **Sessions lookup no longer hangs.** Titles already in the open list match as
  you type. The helper scores sidebar names instead of re-reading every
  transcript, and lookup cannot spin forever.
- **Claude Code sidebar titles on live rows.** Activity uses the Desktop
  `title` (the name in the Claude Code sidebar), so chats like "POS complexity
  and competitive challenges" show as that instead of the first prompt.

## 0.5.38 (build 76)

- **Sessions lookup.** Search titles, sidebar names, first prompts, and
  transcript text — including chats older than the 7-day list. Keyword plus
  meaning, same pattern as Meetings. Keyword works on this Mac even before
  the server ships the lookup route; meaning needs that update and an
  OpenAI key.

## 0.5.37 (build 75)

- **GOT COS lockup in the open panels.** The menu bar still uses eyeglasses
  for a quick running/offline glance. Once Control or Activity is open, the
  official COS lockup is the brand, at a quieter size. Headings use Fraunces,
  UI copy uses DM Sans, and chrome numbers use JetBrains Mono — the same
  trio as gotcos.com.

## 0.5.36 (build 74)

- **Pinned now includes Claude Desktop stars and Cursor sidebar pins.** Claude
  `starred-local-code-sessions` and Cursor `pinnedComposers` use the same rule
  as ChatGPT `pinned-thread-ids`: they show on Pinned at any age. Desktop-only
  Claude chats (no `~/.claude` jsonl) still list by their Desktop title.

## 0.5.35 (build 73)

- **Pinned is its own Sessions clock.** Updated / Opened / Pinned. Codex/ChatGPT
  `pinned-thread-ids` (Markt POS, Jewelry, G2, …) show there at any age. Cursor
  and Claude pins were added in 0.5.36.
- **Keep-warm `ready` rows stay out.** Claude CLI pre-warm (`ready`) and Control
  provider-proof prompts are not real sessions; they no longer eat the list.

## 0.5.34 (build 72)

- **Cursor sidebar titles, not last user_query.** Sessions uses
  `composerHeaders.name` so "V2 verification and performance" shows as that,
  not the summarizer prompt. The `empty-window` copy of the same chat is
  dropped.
- **Pinned Codex threads stay visible.** ChatGPT `pinned-thread-ids` (Jewelry,
  G2, ThriftCart, …) list even when the jsonl is weeks old. Updated vs Opened
  picker is unchanged.

## 0.5.33 (build 71)

- **Sessions clocks: Updated vs Opened.** Default is last write in 7 days, so
  pinned Codex/ChatGPT threads (Markt POS 2.0 build still lives in the May 8
  rollout) show up when they get a new turn. Opened keeps the same window on
  session start. Codex titles come from `session_index.jsonl`. Files over 32 MB
  list; opening the full transcript is still capped.

## 0.5.32 (build 70)

- **Sessions look back 7 days.** Same Claude / Codex / Cursor mix. Codex day
  folders now cover a week, not three calendar days. Empty copy says last 7
  days.

## 0.5.31 (build 69)

- **Sessions lists Claude, Codex, and Cursor.** Same 48-hour window. Each row
  is badged. Click and Copy session still work per provider. Codex subagents
  and Cursor `subagents/` folders stay out. Files over 32 MB are skipped.
  Cursor titles use the latest user query, not system-prompt wrappers.

## 0.5.30 (build 68)

- **Session history on click.** Activity → Sessions opens the local Claude Code
  jsonl as a read-only You / Assistant transcript. Tool calls, tool output,
  thinking, and subagent sidechains stay out.
- **Copy session.** Same pane. Puts a kickstart brief on the clipboard for
  another agent (Cursor, Codex, a new Claude chat). That is a paste, not a
  Claude Code resume. Secrets matching known token shapes are redacted.
  Huge sessions keep the original request and the newest turns.

## 0.5.29 (build 67)

- **Save still-live captures from Control.** Stranded G2 sessions (phone never
  saved) now have Save / Save all. That is POST `/api/meeting/save`, not Recover
  all — Recover all only works after the 4-hour quarantine cutoff. Session files
  become meetings; they are not deleted.
- **Sessions tab shows /rename titles and today’s conversations.** Live presence
  used the workspace folder name, so "Fireflies meeting sync" rendered as
  "MU-Chief-Staff" or as empty if Claude Desktop had just launched. The helper
  now reads `custom-title` from the project jsonl and lists conversations from
  the last 48 hours.

## 0.5.28 (build 66)

- **Unsaved captures row hides when nothing is recoverable.** Recovered
  quarantine leftovers no longer show an amber "None" with no Recover button.
  Stranded live sessions still surface.

## 0.5.27 (build 65)

- **One-click orphan recovery.** Status card Recover / Recover all turns
  unsaved captures into meetings, one at a time. Session files are not
  deleted. Curl copy is gone.
- **Sessions in Activity.** Sixth read-only view: Claude Code workspace
  basename plus waiting / running / stale. Off until
  `COS_CLAUDE_SESSIONS_ENABLED=1` on the server.
- **Run sync now.** Button next to Meeting sync runs
  `cos_python sync_meetings.py` from `COS_SCRIPTS_DIR`. Disabled while HQ
  polish is active. Does not pass `--force`.
- **Memories and Threads lookup.** Same keyword + meaning pattern as Meetings.
  Memories meaning uses the existing `cos_memory` index; threads are keyword
  only. Needs the 6.27.6 `/api/memory/search` and `/api/threads/search`
  hotfix.

## 0.5.26 (build 64)

- **Meetings on the home Activity card.** The panel still listed four chips after
  Meetings shipped as a fifth Activity view. Chips now come from the same
  section list as the Activity window, so Meetings is visible without opening.

## 0.5.25 (build 63)

- **Meeting lookup.** Search field on Meetings: keyword over title/summary plus
  meaning search against the existing COS meeting index (one query embedding, no
  LLM). Results span every stored month, not just the open calendar day. Badge
  shows Keyword / Meaning / both. Needs the 6.27.6 `/api/meetings/search`
  hotfix; without it the field still runs, but the helper will error.

## 0.5.24 (build 62)

- **Meetings in Activity.** Fifth peer view next to Speakers. Month pager and
  day calendar over the saved-call library, with domain, duration, full
  transcript, summary, and copy (summary / transcript / as context). Speakers
  still owns identity correction — "Meetings to review" is unchanged. Needs the
  6.27.6 meeting-list `month`/`day` hotfix; older servers still list the latest
  50 rows.

## 0.5.23 (build 61)

- **Reset live message count.** Toolbar archive-box next to Refresh. Confirms,
  then archives live glasses messages and starts numbering at #1. History stays
  in ARCHIVE / Message History. Talks to `POST /api/message-era/reset` on a
  hotfixed 6.27.6; if that route is missing it snapshots via `/api/archive/now`
  and writes `message-era.json` itself. Reopen the phone companion if Control
  did the reset while the app was already open.

## 0.5.22 (build 60)

- **Clear stranded video uploads.** Sideload or a killed composer can leave a
  `receiving` draft for 4 hours. That draft is what Control shows as
  "Video uploads · N active", and it holds `blocksRestart` so Repair and Update
  stall on it. Repair does not cancel these. Clear stranded does: receiving
  drafts with no bytes for 60 seconds. In-progress uploads and compressing
  videos are left alone. Talks to server 6.27.7 when present; on 6.27.6 it
  DELETEs the same drafts from disk.

## 0.5.21 (build 59)

- **A blocked update now tells you what is blocking it.** The drain only ever
  read `lifecycle.activeByKind`, and when that was empty it printed the literal
  string "restart proof" — naming nothing. It now names the actual cause: a
  video upload holding the restart (with its receiving/finalizing counts), the
  server shutting down, a blocked gate, which specific proof field mismatched,
  or a changed server identity. Stale sessions are shown as context and marked
  as not blocking.
- This cost over an hour across two sessions on 2026-08-12. One abandoned video
  upload, stuck in `receiving` for three hours after a client-side bug, held
  `blocksRestart` — and the server reported it in the very same payload the
  drain was already reading. Three wrong root causes were proposed before
  anyone looked at the right field.

## 0.5.20 (build 58)

Reliable video uploads is a private, machine-wide canary for server 6.27.3 and
companion 6.8.343. When enabled, every MP4/MOV uses the restart-safe resumable
transport rather than relying on a single long request. Control reports active
drafts, finalization, and unacknowledged receipts; disabling the canary restores
the prior transport without hiding already accepted uploads.

Server updates and ordinary restarts remain allowed after publication, but Control
refuses a binary downgrade below 6.27.3 while any V2 draft or unacknowledged receipt
still exists. The transaction verifies the loaded LaunchAgent environment and the
authenticated health/maintenance contract before committing. Phone frame extraction
is deliberately not enabled: the original MP4/MOV and proven Mac validation/extraction
pipeline remain canonical until a physical iPhone benchmark proves a material gain.

## 0.5.19 (build 57)

COS Activity moves Messages, Speakers, Memories, and Threads out of the narrow
menu-bar popover and into one durable, resizable window. Peer tabs, Home, Back,
and a scoped breadcrumb make it clear where you are without throwing away the
place you came from. Closing the window now cancels detail work and stops voice
playback; late server responses cannot overwrite a newer selection.

Speakers is now a Voice Directory instead of a list of meeting titles. Enrolled
people show training-sample provenance, attributed and review segments, meeting
count, last seen, and a segment-weighted **observed match** with its evidence
basis. A voice detail opens its recent meeting appearances, while Meetings to
review remains a peer view for corrections. Unidentified meeting-local voices
stay separate and are never presented as one global person. Requires the new
voice-directory route for history; older servers still show honest profile-only
coverage and an update explanation.

Server updates resolve correctly when COS Control is launched from Finder or at
login. Control previously found Homebrew's `npm` executable, then launched it
with macOS's minimal GUI `PATH`; npm's `#!/usr/bin/env node` launcher could not
find Node and the UI collapsed that failure into “Could not resolve the latest
npm server release.” The resolver now supplies the discovered Node directory,
suppresses non-JSON npm update notices, and keeps the existing transactional
update and rollback path unchanged.

Repair also restores a previously committed, integrity-verified generation
without re-running that older server's provider verifier. Ownership, package
integrity, health, local Whisper, and the credentialed maintenance handoff remain
mandatory; every new candidate still runs the full real-query proof before commit.

## 0.5.18 (build 56)

Review Memories and Review Threads actually work. In 0.5.17 they did nothing.

- **The click was dead.** The buttons set `contextBrowseKind`, but the pane was
  mounted inside `if model.reviewRouteActive` — a flag only the speaker-review flow
  ever sets — so state changed and no view was watching. It compiled, the helper
  worked, and 110 self-test assertions passed, because nothing connected the opener
  to the render condition.
- **Rebuilt in the shape it should have had:** a titled list card in the main panel
  with its own Refresh and chevron rows, and a click that routes the whole panel to
  a detail view. The same pattern as Review speakers, which is what was asked for.
- **The buttons are gone from the controls row.** Five buttons plus a path did not
  fit 390pt and truncated to "CO…", "Revi…", "Revi…", "Cre…". Lists belong in cards.
- Detail shows the full body selectable, the record id, Copy as Context, and Reveal
  in Finder for file-tier records. A detail-fetch failure annotates the record
  rather than clearing it, so a click always leaves something on screen.
- **A dead click is now a test failure.** Four assertions tie every `*RouteActive`
  flag to a view that reads it, require the context pane to be gated on its own flag
  ALONE, and require the route flag to read the exact variable the opener writes.
  Re-creating the original bug fails the suite.

## 0.5.17 (build 55)

Review Memories and Review Threads, on the desktop.

- Two new buttons open the SAME read-only records the glasses browse, using the
  authenticated routes that already existed. No new server surface, no mutation.
- **Copy as Context** puts the record on the clipboard quoted and labelled with its
  id — the same data-not-instructions contract the glasses use when attaching a
  reference — ready to paste into whatever you are already typing.
- **Reveal in Finder** appears for file-tier records, where a memory IS a file. That
  is something the glasses cannot do, and the reason a desktop view earns its place
  rather than just mirroring the lens.
- No send path was added. Control has never had one, and arming a reference for the
  next prompt needs a write route the amendment design does not have yet. Copying
  grounded context does the same job today without inventing a mutation surface.
- The headline separates the page from the store: a live probe returned "4 threads"
  beside "11 active", because the server sends a limited page with full-store counts.
  It now reads "Showing 4 · 11 active".
- `/api/memory` returns a TOP-LEVEL ARRAY for released-companion compatibility, which
  a dictionary-only reader sees as empty. Queen's own probe hit that and read working
  data as a failure, so the response reader handles both shapes and a test pins it.

## 0.5.16 (build 54)

Queen installed server 6.22.0 and hit "Memory & Threads: Setup needed" with a hint
that sent her to the COS Data picker. The picker was the wrong control: her
`COS_OPERATIONS_DIR` was already correct and would have resolved immediately. The
only problem was that `memory/` and `threads/` did not exist, and nothing created
them or said what they were. Her words: "choosing COS Data is not what fixes it.
What fixes it is creating two directories."

- **Create Folders.** One button makes `memory/` and `threads/` in the folder COS
  would already look in, each with a README explaining that any markdown file
  dropped in becomes browsable. Idempotent. A created-and-empty store reports
  READY, not setup-needed — collapsing empty with missing is what caused the
  wrong turn.
- **The panel says where it looked.** It now shows the resolved root path, or the
  candidate roots it tried when nothing resolved. That entire diagnosis previously
  required reading the server source.
- **A dormant Python bridge is called out.** `COS_SCRIPTS_DIR` is written in exactly
  one place, the COS Data picker, so anyone who set up through the meetings picker
  has a complete venv and `cos_api_bridge.py` sitting unused with no indication.
  Control now detects that and says so.
- **It is NOT applied automatically, deliberately.** Setting `COS_SCRIPTS_DIR` flips
  an install from the file tier to the bridge tier, and the server stops consulting
  the file tier entirely once a bridge resolves, so notes being browsed today would
  silently stop appearing. Queen flagged this herself. It stays a visible choice.
- The hint text now names the button instead of pointing at a picker that cannot
  help.

Resolution order is mirrored from the server's `resolveContextFilesRoot()` so the
path can be shown without putting filesystem paths on the API. The order and the
accepted folder spellings are asserted in the self-test so the two implementations
cannot drift quietly.

## 0.5.15 (build 53)

- COS Data accepts a folder of markdown notes, not only a Python bridge. A folder
  holding `memory/`, `memories/`, `threads/` or `thread/` — at the folder chosen or
  one level down in `operations/` — applies `COS_CONTEXT_DIR` and requires server
  6.22.0. A workspace with a working bridge still resolves to the bridge and still
  requires 6.21.35, so an existing install is not downgraded to browse-only.
- Switching tiers removes the other tier's environment key. The server prefers the
  bridge whenever `COS_SCRIPTS_DIR` resolves, so leaving it behind would make
  choosing a notes folder appear to do nothing.
- The panel names the tier — "Bridge:" or "Notes:" — instead of a bare path, so a
  file-backed install cannot be mistaken for a vector pipeline. Copy Report carries
  both, redacted.
- The Memory and Threads hint says what to do next and branches on why it is
  unavailable. It read "Choose COS Data below. Empty stores are healthy", which is
  true and useless to someone who has no COS workspace.
- The refusal message offers the notes path first instead of demanding
  `cos_api_bridge.py` and `venv/bin/python3`.

## 0.5.14 (build 52)

- Adds a separate COS Data picker for Memory and Threads. It accepts a COS
  workspace or `operations/scripts`, validates bridge protocol 1, then applies
  `COS_SCRIPTS_DIR` with the same reversible restart transaction as other settings.
- Reports authenticated Memory and Threads readiness and counts without exposing
  paths or store metadata on public health.
- Redacts Work, Meetings, and COS Data directory paths from copied support
  reports while retaining useful configured/not-configured diagnostics.
- Doctor distinguishes healthy empty stores from setup needed, a degraded
  dependency, or an outdated workspace bridge.
- Keeps Work Folder, Meetings Library, and COS Data as three independent paths.

Requires glasses-server 6.21.35. This binary is build 52.

## 0.5.13 (build 51)

- Makes an existing month-based meeting folder the recommended setup path:
  choose the folder that directly contains `YYYY-MM/*.md` and COS uses it
  without moving or renaming anything.
- Keeps multi-folder organization optional and fully customizable. Any safe
  folder names work when each contains `meetings/YYYY-MM/*.md`; COS roles never
  dictate filesystem names.
- Replaces internal "multi-domain" terminology and role-specific examples with
  plain guidance for one folder or multiple custom-named folders.
- Improves invalid-folder recovery messages so users can correct the selected
  level without rebuilding an existing library.
- Requires glasses-server 6.21.33. This binary is build 51.

## 0.5.12 (build 50)

- **Existing meeting folders now work directly.** Choose a folder that contains
  `YYYY-MM/*.md`, or choose a multi-domain operations folder containing
  `<domain>/meetings/YYYY-MM/*.md`.
- **The picker explains both supported layouts.** Invalid selections show
  actionable examples, let the user choose again, or allow setup to continue
  without a meeting library.
- **Browse and write responsibilities stay separate.** Direct libraries are
  read-only. Existing operations roots keep enrichment, new G2 output, and
  speaker edits. Mixed results prefer the canonical enriched copy.
- **Activation is transactional.** Control removes stale conflicting keys,
  restarts through launchd, verifies the authenticated effective root and
  layout, and restores the exact prior environment on failure.

  Requires glasses-server 6.21.33. This binary is build 50.

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
