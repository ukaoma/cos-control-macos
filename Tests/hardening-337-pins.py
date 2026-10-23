#!/usr/bin/env python3
"""0.5.337 hardening (the loop and performance audits): the wiring the compiled views and stores hide, pinned on code with
comments stripped. The rules are executed in Tests/Hardening337Checks.swift. Each failure names its fix in brackets.

    python3 Tests/hardening-337-pins.py <worktree>
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
fails = []
count = 0
def need(ok, label):
    global count
    count += 1
    if not ok:
        fails.append(label)

def strip(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//") and not l.strip().startswith("///"))

def body(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i + len(start))]

def read(name):
    return strip((root / name).read_text())

model = read("Sources/ControllerModel.swift")
win = read("Sources/ActivityWindow.swift")
work = read("Sources/WorkWorkspaceView.swift")
helper = read("HelperSources/main.swift")
dictation = read("Sources/MacDictation.swift")
chat = read("Sources/WorkTaskChat.swift")
queue = read("Sources/WorkChatQueue.swift")
lens_pump = read("Sources/WorkLensPlansPump.swift")
meetings = read("Sources/ActivityMeetings.swift")
ask = read("Sources/MeetingAsk.swift")
pet = read("Sources/SessionPet.swift")
motion = read("Sources/COSMotion.swift")
brand = read("Sources/COSBrand.swift")
views = read("Sources/Views.swift")
app = read("Sources/COSControlApp.swift")
recording = read("Sources/MacRecording.swift")
core = read("Sources/MeetingAskCore.swift")
run_sh = (root / "Tests/run.sh").read_text()

# W1: every work-loop 404 is unsupported, never a red line; Expired and Undo only where they exist.
loop_helper = body(helper, "    private func emitWorkLoop(args: [String]) throws {", "\n    private func emitWorkIntakeResolve() throws {")
need('if response.status == 404 { emit(ok: true, message: "Update the server to use this Work action", details: ["unsupported": true]); return }' in loop_helper
     and 'action == "dismiss"' not in loop_helper, "[W1 404] the helper answers a 404 as unsupported for every action")
loop = body(model, "    func workLoop(_ action: String, body: [String: Any]? = nil, acceptUnsupported: Bool = false)", "\n    func probeWorkLoopIfNeeded() async {")
need("if WorkLoopSupport.unsupported(response.details) {" in loop and "workLoopUnsupported.insert(action); workLoopError = nil" in loop
     and "return acceptUnsupported ? response.details : nil" in loop, "[W1 no error] unsupported sets no error and returns nothing to callers that would read it as done")
need('await workLoop("dismiss", body: ["ids": chunk, "action": "dismiss", "batchId": batch], acceptUnsupported: true)' in model,
     "[W1 fallback] Skip all keeps its single-item fallback")
probe = body(model, "    func probeWorkLoopIfNeeded() async {", "\n    func undoWorkIntake() async {")
need('await workLoop("decisions", acceptUnsupported: true)' in probe and "workLoopError = kept" in probe and "workLoopProbedFor = server" in probe,
     "[W1 probe] one read-only GET per server version, and it never shows an error")
need("if model.workExpiryAvailable {" in work and 'Button("Expired this week:' in body(work, "if model.workExpiryAvailable {", "Restore within 30 days"),
     "[W1 expired] Expired only on a server that answered its settings")
undo_view = body(work, "    @ViewBuilder private var undoLastDecision: some View {", "\n    var body: some View {")
need("if model.workUndoAvailable {" in undo_view and "WorkLoopSupport.undoMissing" in undo_view and work.count("undoLastDecision") == 3,
     "[W1 undo] Work's Undo last decision only where undo exists, else where to go")
need('if !model.workLoopUnsupported.contains("seen") {' in work, "[W1 seen] no seen call per row on a server without it")
need("if row.undo != nil, model.workUndoAvailable {" in win and "await model.probeWorkLoopIfNeeded()" in body(win, "    func dismiss(", "\n    func undoDismiss("),
     "[W1 undo] Today's Undo only where undo exists")
need('python3 "$ROOT/Tests/work-loop-helper-checks.py" "$TMP/cos-control-helper"' in run_sh, "[W1 helper] the full suite runs the work-loop helper checks")

# W2, W11: the board shows queued work and plans from the glasses; a background stop and a new lens round notify.
pass_body = body(queue, "    func pass() async {", "\n    private func publishCounts(")
need("defer { publishCounts(files, server: server) }" in pass_body and "WorkChatBoardCounts.notice(before: before, after: after, title: source.title)" in pass_body
     and "onNotice?(WorkProgressNotice(" in pass_body, "[W2 pump] each pass counts every card and notices a queue that stopped")
need("pump.onCounts = { [weak self] counts in if self?.workChatCounts != counts { self?.workChatCounts = counts } }" in model
     and "pump.onNotice = { [weak self] notice in self?.postWorkNotice(notice) }" in model and "lens.onNotice = { [weak self] notice in self?.postWorkNotice(notice) }" in model,
     "[W2 model] counts publish only on change; notices go through Work notices")
card = body(work, "    private func boardCard(", "\n    private func cardTapArea(")
need("if let line = model.workChatCounts[item.sourceID]?.line {" in card and "Button(line) { select(item) }" in card, "[W2 card] the card's line opens its Work chat")
history = body(lens_pump, "    private func writeHistory(", "\n    private func postHistory(")
need("let already = chat.record?.rounds.contains(where: { $0.lensRoundID == round.roundId }) == true" in history
     and "if !already, !noticed.contains(round.roundId), !on {" in history, "[W11 lens] one notice, only for a round newly written and waiting for review")

# W3: a queued round lists what it waits on, with status, age and the action that resolves it.
queued = body(queue, "struct WorkChatQueuedLine: View {", "\nstruct WorkChatHeldNote: View {")
need("ForEach(blocking) { receipt in" in queued and "WorkChatPreflight.line(receipt, now:" in queued and "Waits until you review" in queued
     and "handoff.markReviewed(receiptID: receipt.id)" in queued and 'Button("Open session")' in queued, "[W3 blockers] each blocking handoff, its age and its action")
need("WorkChatQueuedLine(chat: chat, handoff: handoff, source: source, round: round, onOpenSession: onOpenSession)" in chat, "[W3 open] Open session reaches the session")

# W4: the polish pause.
need("notePolishPause(outcome)" in dictation and "DictationPolishPause.shouldFlash(lastFlashedDay:" in dictation
     and "UserDefaults.standard.set(today, forKey: DictationPolishPause.flashedDayKey)" in dictation, "[W4 flash] once a day, remembered")
need("if store.polishModel != .off, let pause = store.polishPause {" in dictation and "DictationPolishPause.settingLine(pause)" in dictation, "[W4 line] Settings says so under AI polish")

# W5: Today runs open their session, stop through their job, and come back when finished.
open_fn = body(win, "    func todayOpen(_ action: TodayHome.OpenAction) {", "\n    func todayOpenNeed(")
need("TodayHome.workRunSession(id: id, receipts: handoffStore.receipts.map { ($0.id, $0.sessionID) })" in open_fn, "[W5 open] Open goes to the run's session")
need('todayOpen(.workRun(handoffStore.receipts(for: target).first?.id ?? ""))' in win and 'todayOpen(.workRun(""))' not in win, "[W5 prep] Prep in Sessions names its run")
stop = body(win, "    func stopRun(job: String, handoff: WorkHandoffStore) async {", "\n    func flash(")
need('["work-job-cancel", "--job-id", job]' in stop and "(200..<300).contains(http)" in stop, "[W5 stop] Stop is work-job-cancel, and only a 2xx says it stopped")
need("if let job = row.stopJobID {" in win and 'r.workID.hasPrefix("today:")' in win and 'openLabel: "Open result"' in win, "[W5 rows] Stop on the row; finished runs come back")

# W7: Stop on a queued turn.
need('["session-chat-queue-cancel", "--provider", provider, "--thread-id", thread, "--client-turn-id", turn]' in chat
     and "receiptID: receipt?.id, queueSessionID: receipt?.sourceSessionID" in chat, "[W7 queue] Stop takes a parked turn out of the session's queue")
queued_stop = body(chat, "    private func stopQueued(", "\n    private func requestStop(")
need("WorkOrchestrator.queueCancelLine(state: state)" in queued_stop and "if verdict.stopped, let rounds = record?.rounds," in queued_stop, "[W7 queue] only a cancelled turn is marked Skipped")

# W8, W9, W10.
need("limits: model.meetingAsk.liveCues.settings?.limits, cuesOn: model.meetingAsk.liveCues.settings?.enabled" in ask
     and "CueVerdicts.limitLine(" in ask and "CueVerdicts.emptyLine(" in ask, "[W8 cues] the Cues view says which limit, and when it lifts")
need("if LiveMeeting.needsDecisionKey(arm) {" in meetings and "model.showDecisionKeySettings?()" in meetings
     and "model.showDecisionKeySettings = {" in app and "scroll: LiveCues.decisionKeysAnchor" in app, "[W9 key] a missing key opens the key fields")
saved = body(meetings, "ForEach(Array(row.meetingAskSessions(keys: keys).enumerated()), id: \\.element) { captureIndex, session in", "LiveAskPanel(state: model.meetingAsk, model: model, session: session, saved: true")
need("macCues: model.liveMeetingCapability.macCues" in saved, "[W10 saved] a saved Mac recording shows its Cues tab")

# W12, W13, W14, W15.
need("lastNaming = TodayHome.LastNaming(name: name, undo: result.batchId ?? result.undoHandle, at: Date())" in win
     and "if let named = today.lastNaming, TodayHome.showsNamed(named, now: now) {" in win, "[W12 named] Named X. Undo after naming from Today")
need("func load() async { loadFailed = !(await send(\"get\")) }" in dictation and "store.loadFailed" in dictation and 'Button("Try again") { Task { await store.load()' in dictation,
     "[W13 polish] a failed first read says why, with Try again")
learned = body(dictation, "    private func editLearned(", "\n    func applySuggestions(")
need("suggestions = DictationSuggestions.suggesting(item, in: suggestions, now: Date()); saveSuggestions()" in learned, "[W14 learn] a failed save is kept as a suggestion")
need("guard undone else {" in body(dictation, "    func undoLearned(_ id: UUID) async {", "\n    func pruneSuggestions()"), "[N15 undo] a failed Undo keeps the row")
need("!WorkLensPlans.isFull(rounds: record.rounds.count)" in chat and "|| full" in chat and "WorkLensPlans.fullLine" in chat, "[W15 cap] Plan is off on a full card and says why")
need("WorkLensPlans.notSavedReason(rounds:" in lens_pump, "[W15 lens] the lens hears that the card is full")

# Performance: B1, W3, W4, W5, W6, W7, B2.
sessions = body(win, "    private var sessionsList: some View {", "\n    private var scheduledJobRunsSection: some View {")
need("let sessions = visibleSessions" in sessions and sessions.count("visibleSessions") == 1 and "sessionRow(session, ambiguous: ambiguous)" in sessions,
     "[B1 list] the list and its duplicate titles once per redraw")
need("ambiguousSessionTitles" not in win, "[B1 row] no per-row recompute of the duplicate titles")
need("WorkIntakeItem.stamp(trimmed)" in read("Sources/Models.swift") and "ISO8601DateFormatter()" not in body(read("Sources/Models.swift"), "    static func parseStamp(_ raw: String) -> Date? {", "\n    init?(_ value: JSONValue?) {"),
     "[B1 stamp] no new formatter per read")
need("if let cached = cache[name] { return cached }" in brand and "cache[name] = image" in brand, "[W3 svg] each SVG is read once")
need("paused: PetPause.paused(occluded: model.petOccluded, locked: model.screenLocked, displayAsleep: model.displayAsleep)" in pet
     and "paused: paused || (reduceMotion && frames.count <= 1)" in motion and "func windowDidChangeOcclusionState(_ notification: Notification) {" in pet,
     "[W4 pet] the sprite's clock stops while nobody can see it")
need("if model.screenLocked || model.displayAsleep { continue }" in pet, "[W4 poll] no pet session reads while locked")
need("com.apple.screenIsLocked" in model and "com.apple.screenIsUnlocked" in model and "screensDidSleepNotification" in model and "screensDidWakeNotification" in model,
     "[W5 lock] the lock and display sleep are followed")
refresh = body(model, "    func refresh(quiet: Bool = false) async {", "\n    func setRecentGlassesExpanded(")
need("if bytes == nil || bytes != statusDetailsBytes {" in refresh and "if extras { await loadOrphans(quiet: true) }" in refresh and "if extras { await loadYourMove() }" in refresh,
     "[W5 refresh] an unchanged status is not republished; extras only for what is on screen")
need("guard RefreshCadence.due(last: model.lastRefreshAt, now: Date(), every: model.refreshSeconds) else { continue }" in model, "[W5 loop] the loop follows the cadence")
need("didSet { recordingCountChanged(); statusDetailsBytes = nil }" in model, "[W5 bytes] any other write to status publishes the next answer")
need("activityOnScreen = onScreen" in model and "model?.setLiveTranscriptWindowOnScreen(false)" in win, "[W5 visible] the Activity window's visibility reaches the cadence")
need("if slot.live { WhatsNewWindowContent(model: model, close: close) }" in views and "MainActor.assumeIsolated { self?.slot.live = false }" in views,
     "[W6 whats new] a closed window stops observing the model")
need("let byTurn = LiveMeeting.cuesByTurn(cues, id: \\.id, anchored: anchored)" in meetings and "ForEach(byTurn[turn.id] ?? [])" in meetings, "[W7 cues] each turn's cues looked up")
need("if let dragWidth { askWidth = dragWidth }" in meetings and "dragWidth = min(max(280," in meetings, "[W7 drag] AppStorage is written when the drag ends")
frame = body(win, "    var todayFrameView: some View {", "\n    func todayResetExpansions()")
def in_order(text, *parts):
    at = -1
    for part in parts:
        i = text.find(part, at + 1)
        if i < 0: return False
        at = i
    return True
need(in_order(frame, "TimelineView(TodayFrameSchedule(paused: !today.windowVisible))", "let frame = todayFrame(now: timeline.date)", "GeometryReader { geometry in"),
     "[B2 frame] composed per tick, then the geometry inside it")
need('"$ROOT/Tests/run-work-board-perf.sh" --gate' in run_sh and "TodayHome.composeRuns" in (root / "Tests/WorkBoardResizePerf.swift").read_text(), "[B2 gate] the resize gate covers the Today window")

# Notes folded in.
need("if self?.runNote == note { self?.runNote = nil }" in win, "[N5 note] the Ask box note clears itself")
need('Text("Prep me is off: Settings, Start Work runs from Today")' in win, "[N7 prep] Prep me off says where")
need("After 6 PM, before 6 AM and on weekends" in views, "[N8 quiet] the help names the early morning")
need("if let kept = liveMeetingTitlesKept[sessionId] { return kept }" in model, "[N10 title] a calendar title stays for its meeting")
need("model.liveMeetingFileInfo(session)" in meetings and "let info = model.liveMeetingFileInfo(session)" in ask, "[N11 files] live files are filed under the meeting's title and day")
# 0.5.339: the drop line under the bar is gone (the whole pane takes the drop); adding of any kind still needs meeting files on.
need("guard let files = model.workHandoffStore?.meetingFiles, files.enabled else { return false }" in meetings, "[N12 drop] adding to a live meeting only with meeting files on")
need("else if next.state != .loaded || missed >= 2 { next = Meeting(state: state, cues: next.cues, count: next.count) }" in core, "[N13 cues] failed reads keep the last cues")
need("gate.mayPost(now: Date())" in recording, "[N14 grey] the preview loop asks the gate before reading audio")
need("store.lastOK ? Color.secondary : COSPalette.amber" in dictation, "[N17 saved] Saved. is not amber")
need("TimelineView(.periodic(from: .now, by: 1)) { context in Self.elapsedText(feed, now: context.date) }" in win and "Timer.publish(every: 1" not in body(win, "struct SessionActivityFeed: View {", "    private func fallbackLine("),
     "[feed] the session clock ticks only while it works")
need("TimelineView(.animation(minimumInterval: 1.0 / 30.0" not in body(brand, "struct COSSpinner: View {", "    private var arc: some View {"), "[spinner] no 30 fps timeline")
need('zsh "$ROOT/Tests/run-hardening-337.sh"' in run_sh, "[gate] the full suite runs this lane")

# Tier 2.
helper_client = read("Sources/HelperClient.swift")
need("Self.runQueue.async {" in helper_client and "Task.detached(priority: .userInitiated)" not in helper_client
     and "attributes: .concurrent" in helper_client, "[P-W8 queue] a helper run waits on its own dispatch thread")
need("a pool task waited" in (root / "Tests/HelperTransportContract.swift").read_text() and '"$TMP/helper-transport-contract"' in run_sh,
     "[P-W8 test] the transport contract runs the concurrency check in the full suite")
need("WorkOrchestrator.stopOffered(action, sentWithoutReview:" in chat, "[W6 stop] Stop on a reviewed round's running assignments")
need("StrandedCapture.shown(" in model and "discarded: macRecording.noMeetingCaptureIDs" in model
     and "stringArray(forKey: MacRecordingStore.discardedKey)" in recording
     and "didSet { UserDefaults.standard.set(Array(noMeetingCaptureIDs.sorted().suffix(100)), forKey: MacRecordingStore.discardedKey) }" in recording,
     "[W16 discard] filtered by the set, which is kept across launches")
need("if case .changed(let undo?) = result { createdUndo[item.id] = undo; await model.probeWorkLoopIfNeeded() }" in win
     and "if today.createdUndo[item.id] != nil, model.workUndoAvailable {" in win and "await model.undoWorkIntake(batchId: undo)" in body(win, "    func undoCreate(", "\n    func dismiss("),
     "[W17 undo] Undo beside Created. with that row's own undo id, where undo exists")
need('stopNote = "Asked it to stop.' in chat and "if let note = chat.stopNote, chat.error == nil {" in chat, "[N1 stop] a Stop says it was asked")
need('round.sentFromGlasses == true ? " · sent from the glasses"' in chat, "[N3 glasses] a round sent from the glasses says so")

# Miles 2026-10-22 21:11.
overlay = body(dictation, "@MainActor final class DictationOverlayPresenter {", "\nstruct DictationOverlayRoot: View {")
need("DictationOverlayFrame.place(size: size, caret: nil, screen: screen)" in overlay and "NSWindow.didResizeNotification" in overlay
     and "self?.panelResized()" in overlay and "y: screen.minY + 8, width: size.width" not in overlay,
     "[fix frame] the floating panel is placed inside its screen, again whenever its content resizes it")
need("delivered.own = target" in dictation and "finish(delivered.context?.text ?? text, outcome: delivered.outcome, target: delivered.target, context: delivered.context, own: delivered.own)" in dictation,
     "[own learn] a dictation into COS's own text view carries its target")
fin = body(dictation, "    private func finish(_ text: String, outcome: DictationDeliveryOutcome", "\n        if let flash = outcome.flash {")
need("} else if let own, case .inserted = outcome {" in fin and "editWatcher.startOwn(own, mode: learnMode)" in fin, "[own learn] the watch starts for COS's own fields")
own_start = body(dictation, "    func startOwn(_ target: DictationOwnTarget,", "\n    struct WatchField: @unchecked Sendable {")
need("DictationEditLearning.eligibility(mode: mode," in own_start and "run(field, span: target.span, typed: target.text" in own_start
     and "DictationOwnField.read(" in own_start and "DictationOwnField.snapshot(" in own_start, "[own learn] the same rules and the same loop, reading the view itself")
watcher = body(dictation, "    nonisolated private static func watch(", "\n    static func candidate(_ edit: DictationReplace.Edit")
need(watcher.count("await field.measure()") == 2 and "await field.text(bounds.location, bounds.length)" in watcher and "await field.focus(canary.rebinds)" in watcher
     and "DictationEditLearning.stop(elapsed:" in watcher and "AXUIElement" not in watcher, "[own learn] one watch loop for both kinds of field")
composer = body(chat, "struct WorkChatSendControls: View {", "\n        .confirmationDialog(\"Send plans without review?\"")
need("ViewThatFits(in: .horizontal) {" in composer and ".frame(minWidth: WorkChatPolicy.plannerPickerMinWidth, maxWidth: 190)" in composer
     and ".frame(minWidth: WorkChatPolicy.effortPickerMinWidth, maxWidth: 170)" in composer and "        .fixedSize()\n" in composer
     and 'hint(lines: 3).frame(maxWidth: .infinity, alignment: .leading); buttons' in composer, "[composer] two rows when narrow; pickers keep their width; buttons never wrap")
need("WorkChatSendControls(" in (root / "Tests/ActivitySizing.swift").read_text(), "[composer] the sizing check measures the composer footer")
need(sum(read(str(f.relative_to(root))).count("setPlannerChoicesForLayout(") for f in (root / "Sources").glob("*.swift")) == 1,
     "[composer] the layout seam is the sizing check's only (never called by the app)")

copy = []
for name, text in (("ActivityWindow", win), ("WorkWorkspaceView", work), ("WorkChatQueue", queue), ("MacDictation", dictation), ("ActivityMeetings", meetings)):
    copy.append(text)
import re
new_literals = [l for l in re.findall(r'"((?:[^"\\]|\\.)*)"', "\n".join(copy)) if any(k in l for k in ("Undo needs", "Waits until", "Queued ", "Prep me is off", "Stopping", "Dismiss suggestion", "Open result"))]
need(all("—" not in l and "→" not in l for l in new_literals), "[copy] no em dash or arrow in the new words")

if fails:
    for f in fails:
        print("0.5.337 hardening pin: " + f)
    sys.exit(1)
print(f"PASS: 0.5.337 hardening wiring pins: {count} passed")
