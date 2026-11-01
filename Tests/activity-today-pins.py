#!/usr/bin/env python3
"""Activity Today home (plan v2): the wiring the compiled views hide, pinned on code with comments stripped.

    python3 Tests/activity-today-pins.py <worktree>

Behaviour lives in Tests/ActivityTodayChecks.swift; these pins hold what only the view and store code can show: the
polling rule (one 60 s tick while on screen, serial, never session questions, no second activity-signals reader), Today
never calls seen or a batch and dismisses only through Work's own resolve (0.5.337), one intake action at a time, session questions read only, the Work-run cost guards around the
one submit, capability gating, Reduce Motion, the rail on every tab, the shared intake split in Work's Sort, keyboard, and
copy rules. Each failure names its behaviour in brackets.
"""
import re, sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
fails = []
def need(ok, label):
    if not ok:
        fails.append(label)

def strip(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//") and not l.strip().startswith("///"))

def in_order(text, *parts):
    """Every part present, in this order (a missing part is a failed pin, never a crash)."""
    at = -1
    for part in parts:
        i = text.find(part, at + 1)
        if i < 0 or i <= at:
            return False
        at = i
    return True

def body(text, start, end):
    i = text.index(start)
    j = text.index(end, i + len(start))
    return text[i:j]

win = strip((root / "Sources/ActivityWindow.swift").read_text())
controller = strip((root / "Sources/ControllerModel.swift").read_text())
models = strip((root / "Sources/Models.swift").read_text())
work = strip((root / "Sources/WorkWorkspaceView.swift").read_text())
views = strip((root / "Sources/Views.swift").read_text())
helper = strip((root / "HelperSources/main.swift").read_text())
today = win[win.index("enum TodayInk {"):]
store = body(win, "@MainActor final class TodayHomeStore", "\nextension ActivityWindow {")
logic = models[models.index("enum TodayHome {"):]

# Polling (plan section 8). The loop's rules execute in ActivityTodayChecks (TodayTickLoop on a fake clock); these pin
# that the window drives that loop with its own visibility and its opening loads.
loop = body(today, "func todayTickLoop() async {", "\n    func todayTick() async {")
need("TodayTickLoop.run(now: { Date() }, visible: { today.windowVisible }, ready: { today.overviewDone }, tick: { await todayTick() }," in loop,
     "[polling] the tick loop runs on the window's own visibility, after the opening loads")
need("TodayWindowWatcher { visible in if today.windowVisible != visible { today.windowVisible = visible } }" in today,
     "[polling] the window's visibility (close, minimize, cover) reaches the loop")
need(in_order(win, "today.overviewDone = true", "private func loadHomeWork()"),
     "[polling] the opening loads say when they are done")
need("static let interval: TimeInterval = 60" in models and "static let slowSeconds: TimeInterval = 300" in store and store.count("Self.slowSeconds") == 2,
     "[polling] one tick a minute; calendar and intake at most every 5 minutes")
need(len(re.findall(r"\btodayTickLoop\(\)", win)) == 2 and ".task(id: todayEnabled) { await todayTickLoop() }" in today,
     "[polling] one tick loop, owned by the Today frame (it ends when the window goes)")
tick = body(store, "    func tick(model: ControllerModel, now: Date = Date()) async {", "\n    static func readHosts(")
need(tick.count("model.todayHelper(") == 1 and "guard !ticking else { return }" in tick, "[polling] one helper run per tick, never two at once")
need("if reachable == true { checkedAt = Date() }" in tick and tick.count("checkedAt =") == 1, "[states] checked only after a tick that reached the server")
need('reachable = response.details["unreachable"]?.bool != true' in tick and len(re.findall(r"\breachable = ", store)) == 1,
     "[reachability] unreachable only when the helper says nothing answered")
need("async let" not in today and "TaskGroup" not in today, "[polling] the home's loads are serial")
need("session-questions" not in win and "session-questions" not in helper, "[polling] never poll /api/session-questions")
need("activity-signals" not in today and "loadActivitySignals" not in today, "[polling] the home is not a second reader of activity-signals")
ticker = body(today, "    func todayTick() async {", "\n    func todayOpenLoads() async {")
need("if !model.petEnabled { await model.loadClaudeSessions() }" in ticker, "[pet off] the tick refreshes sessions when the pet is off")
opens = body(today, "    func todayOpenLoads() async {", "\n    func todayRail(")
need("reviewStore.refresh" not in opens and "loadToReviewEvents" not in opens and "loadWorkIntake" not in opens,
     "[open burst] Today's opening loads skip what loadOverviewIfNeeded already reads")
need("Task.detached(priority: .utility)" in body(store, "    static func readHosts(", "\n    func createTask("), "[hosts] session files are read off the main thread")
need("let frame = TodayHome.compose(" not in today and "TodayHome.compose(input)" in today, "[composition] the frame is TodayHome.compose, which the checks execute")

# Intake on Today (B4): Work's own resolve path, one at a time, never seen, never a batch. Create task accepts; 0.5.337
# (Miles 2026-10-22) Dismiss dismisses, through the same call Work's Sort Dismiss makes, with no new route.
create = body(store, "    func createTask(", "\n    func dismiss(")
dismiss = body(store, "    func dismiss(", "\n    func undoDismiss(")
undo = body(store, "    func undoDismiss(", "\n    private func expireDismissals()")
need("await model.resolveWorkIntake(item, accept: true)" in create and "accept: false" not in create,
     "[create accepts] Create task only ever accepts, through Work's own path (its Undo and busy ids)")
need("let result = await model.resolveWorkIntake(item, accept: false)" in dismiss and today.count("accept: false") == 1,
     "[dismiss through Work's path] Today dismisses only in dismiss(), through Work's own resolve")
need('"seen"' not in today and "markSeen" not in today and "dismissWorkIntake" not in today and "resolve-batch" not in today
     and "work-intake-resolve" not in today, "[never seen or batch] Today never marks seen, never batches and has no route of its own")
need("guard model.workIntakeBusyIDs.isEmpty" in create, "[one at a time] one intake action in flight")
need("guard model.workIntakeBusyIDs.isEmpty, !created.contains(item.id), dismissals.begin(item.id) else { return }" in dismiss,
     "[one at a time] one dismiss in flight, and never on a row Today created")
need(today.count(".disabled(!model.workIntakeBusyIDs.isEmpty)") == 3, "[one at a time] Create task, Try again and Dismiss wait for the one in flight")
# Only the server's confirmation collapses a row (TodayDismissals.finish, executed in the checks): the store never writes
# the rows itself, and a refusal keeps the panel (workIntakeError is then a refusal, not a read failure).
need("dismissals.finish(item, result: result, now: Date())" in dismiss and "dismissals.rows" not in today,
     "[confirmed only] the row collapses only through TodayDismissals.finish")
need(in_order(dismiss, "case .refused(_, let code):", "lastResolveError = model.workIntakeError", 'todayLog.error("dismiss refused code=\\(code, privacy: .public)")'),
     "[refusal keeps the row] a refused dismiss keeps the panel and logs its code")
logs = [l for l in (dismiss + undo).split("\n") if "todayLog." in l]
need(len(logs) >= 3 and all("workIntakeError" not in l and "reason" not in l and "\\(error" not in l and "item.text" not in l for l in logs),
     "[log the code only] no reason, error text or title in a dismiss log line")
need("let error = await model.undoWorkIntake(batchId: undo)" in undo and "guard let undo = dismissals.beginUndo(item.id) else { return }" in undo
     and "model.undoWorkIntake()" not in today and "dismissals.finishUndo(item.id, error: error, now: Date())" in undo,
     "[undo its own row] Undo sends that row's own undo id, never Work's last decision")
need("self?.dismissals.expire(now: Date())" in store and "TodayDismissals.undoSeconds" in store, "[collapsed line] the Dismissed line leaves after its window")
panel = body(today, "    func todayMeetingsPanel(", "\n    func todaySuggestionRow(")
need("TodayHome.suggestionSlots(open: $0.today, dismissals: today.dismissals, now: now)" in panel and "ForEach(split.today," not in panel
     and "case .dismissed(let row): todayDismissedRow(row)" in panel and "split.todayCount + created.count + collapsed > 0" in panel,
     "[collapsed line] dismissed rows hold their place, and the panel stays while one shows")
button = body(today, "    func todayDismissButton(", "\n    func todayDismissedRow(")
need('Button("Dismiss")' in button and "TodayLinkStyle(color: TodayInk.sub, size: 12.5)" in button and "TodayButtonStyle" not in button,
     "[quiet] Dismiss is a link, never a third filled button")
need(".accessibilityLabel(TodayHome.dismissLabel(item))" in button, "[voiceover] Dismiss reads Dismiss suggestion and the title")
row = body(today, "    func todaySuggestionRow(", "\n    func todayDismissButton(")
need(row.count("todayDismissButton(item)") == 2 and ".onKeyPress(keys: [.delete, .deleteForward], phases: .down)" in row
     and row.count("Task { await today.dismiss(item, model: model) }") == 1 and ".focusable(interactions: .activate)" in row,
     "[keyboard] Delete on a focused row dismisses it, as the link does")
need("if case .dismissFailed(let reason) = state {" in row, "[refusal keeps the row] the server's reason shows in place")
# The same predicate everywhere (TodayHome.isShown): Today, the rail and Work's Sort leave a dismissed item out at once,
# so it never shows again on Today and never moves to Work at midnight.
need(win.count("dismissed: model.workIntakeDismissedIDs") == 1 and work.count("dismissed: model.workIntakeDismissedIDs") == 2,
     "[same predicate] Today, the rail and Work's Sort leave out what was dismissed here")
need("if !accept, case .changed = result { workIntakeDismissedIDs.insert(item.id) }" in controller
     and "result = WorkIntakeResolveResult(details: response.details, message: response.message, itemID: item.id, accept: accept)" in controller,
     "[same predicate] only a dismiss the server confirmed hides the item")
undo_model = body(controller, "    func undoWorkIntake(batchId: String) async -> String? {", "\n    func resolveWorkIntake(")
need(in_order(undo_model, 'guard await workLoop("undo", body: ["batchId": batchId]) != nil else {', "workIntakeDismissedIDs = TodayDismissals.afterUndo(workIntakeDismissedIDs, batchId: batchId)", "return nil"),
     "[undo its own row] only a confirmed undo gives the item back")

# Session questions are read only (B1): one Open button, never an answer.
actions = body(today, "    func todayNeedActions(", "\n    func todayRunningPanel(")
session_case = body(actions, "case .session:", "case .voice:")
need(session_case.count("Button(") == 1 and "todayOpenNeed(row)" in session_case, "[read only questions] a session row has one Open button and no options")
need("session-chat-send" not in today and "permission" not in session_case, "[read only questions] Today never answers a session")

# Voices: no listen or owner acknowledgement sent from home; nothing stale read.
name = body(store, "    func nameVoice(", "\n    static func inFlightTargets(")
need("heldNamingListened" not in name and "heldNamingOwnerAck" not in name and "!preview.requiresListening, !preview.owner" in name
     and "voices[group.id] = .listen" in name, "[voices] Listen and owner checks route to Speakers, never sent from home")
need(in_order(name, "model.heldNamingResult = nil", "await model.nameHeld(") and 'result.speaker == name' in name and "preview.speaker == name" in name,
     "[voices] the result is cleared first and must be for this name")
need("guard model.heldGroupsSpeakerModel, model.heldNamingAvailable" in name, "[voices] no naming without the speaker model")

# Cost guards (section 3): admission, then preflight, then the one submit, then accounting by the new receipt's id.
start = body(store, "    func startRun(", "\n    func flash(")
need(start.count("handoff.submit(") == 1, "[cost guards] one Work run per tap")
need(in_order(start, "guardrail.admission(", "TodayRunGuard.preflight(", "handoff.submit(", "guardrail.account(outcome"),
     "[cost guards] admission, then the busy and open-run check, then the one submit, then the accounting")
need("guard admission == .allowed else {" in start, "[cost guards] nothing starts unless the guard allows it")
need("intentID: id)" in start and "handoff.receipts.first { $0.id == id }" in start, "[cost guards] the new receipt is matched by its own id")
need("guard !runBusy else { return false }" in start and 'switchOn: TodayHome.workRunsOn(.standard)' in start, "[cost guards] the switch and one at a time")
need("-> Bool {" in start and start.count("return false") == 4 and "return accepted" in start and "accepted = true" in start,
     "[cost guards] startRun says whether the run was accepted, so no caller reads a note that may be 20 seconds old")
need("TodayHome.pickRunModel(" in start, "[cost guards] runs from Today use the picked non-Opus model")
need(today.count("today.startRun(") == 2, "[cost guards] only Prep me and the command center's Ask and troubleshoot rows start Work runs; the Today box only files")
need("if let refusal = today.runRefusal(" in body(today, "    func commandTroubleshoot(", "\n    func commandStartRun("), "[cost guards] troubleshoot asks the guard before Doctor spends a question")
refusal = body(store, "    func runRefusal(", "\n    @Published var stopping")
need("guardrail.account(" not in refusal and "handoff.submit(" not in refusal and "TodayRunGuard(defaults: .standard).admission(" in refusal and "TodayRunGuard.preflight(" in refusal,
     "[cost guards] the check before Doctor is read only: it records nothing and starts nothing")
need("static let dailyCap = 20" in models and "static let breakerFailures = 3" in models and "static let breakerPause: TimeInterval = 15 * 60" in models,
     "[cost guards] 20 a day, 3 failures, 15 minutes")
ask = body(today, "    func todaySubmitAsk(", "\n    func todayNeedsPanel(")
need("model.captureTask(" in ask and "!today.captureBusy" in ask and "startRun(" not in ask and "file:" not in ask,
     "[cost guards] Option Return and the File row file to the Work inbox, once, and the raw words never start a run")

# Capability gating (D4, 1b): glasses questions only on a server that advertises the route.
need("input.jobs = today.jobsSupported == true ? today.jobs : nil" in today, "[capability] no capability, no question rows")
need('details["activeQueryJobs"] = Self.activityTodayJobsSupported(' in helper and 'features?["activeQueryJobs"] as? Bool == true' in helper,
     "[capability] detected by the advertised feature, never by a status code")
need('if let health, health.status == 200 {' in helper, "[capability] only a 200 health answers the probe")

# Reduce Motion: the pulse is still, and follows the setting live.
pulse = body(today, "struct TodayPulse: View {", "\n}\n")
need("@Environment(\\.accessibilityReduceMotion)" in pulse and ".onChange(of: reduceMotion)" in pulse and "animate(!reduceMotion)" in pulse,
     "[reduce motion] no pulse under Reduce Motion, followed live")
need("if row.working { TodayPulse() }" in today, "[reduce motion] only working rows pulse")

# Rail on every tab (D1), with ⌘0 Today, ⌘1 to ⌘9 tabs, ⌘K the Ask box, Settings in both rails.
frame = body(today, "    var todayFrameView: some View {", "\n    func todayResetExpansions()")
need("todayRail(mode: mode, frame: frame, now: timeline.date)" in frame and "activityContent(today: frame" in frame, "[rail] the rail sits beside every tab's content")
cmdk = frame[frame.index('Button("") { toggleCommandCenter() }'):frame.index('.keyboardShortcut("k", modifiers: .command)')]
need('.keyboardShortcut("k", modifiers: .command)' in frame and cmdk.strip() == 'Button("") { toggleCommandCenter() }', "[keyboard] ⌘K opens the command center from any tab")
toggle = body(today, "    func toggleCommandCenter() {", "\n    func commandSectionChanged() {") + body(today, "    func openCommandCenter() {", "\n    func closeCommandCenter() {")
need("goHome" not in cmdk and "goHome" not in toggle and "select(" not in toggle and "section =" not in toggle, "[keyboard] ⌘K never navigates: it stays on the tab it was pressed on")
need(".onAppear { todayResetExpansions() }" in frame and "todayResetExpansions()" in frame, "[reset] a reopened window or a new day starts folded")
rail_item = body(today, "    func todayRailItem(", "\n    func todayHomeView(")
need("if index <= 9 { button.keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command) } else { button }" in rail_item,
     "[keyboard] ⌘0 Today, then ⌘1 to ⌘9; never a two-character key")
need(".accessibilityLabel(label)" in rail_item and ".help(label)" in rail_item, "[voiceover] rail items carry their story")
need('Image(systemName: "gearshape")' in body(today, "    func todayRail(", "\n    func todayServerLine("), "[settings] Settings in the icon rail too")
need(".accessibilityLabel(row.voiceLabel)" in today, "[voiceover] Running rows read their platform, title, state and Open")
needs_panel = body(today, "    func todayNeedsPanel(", "\n    func todayRetryLine(")
need("let rows = folded.now" in needs_panel, "[keyboard] ⌘] walks the rows shown, never the folded ones")
retry = body(today, "    func todayRetryLine(", "\n    func todayNeedRow(")
need("guard !todayRetrying else { return }" in retry and ".disabled(todayRetrying)" in retry, "[retry] one retry at a time")

# Work's Sort reads the same split (D2), only with Today on, and keeps Undo.
need("let split = todayHome ? TodayHome.intakeSplit(items: model.workIntake.items, tasks: model.workTasks, now: Date(), dismissed: model.workIntakeDismissedIDs) : TodayHome.IntakeSplit()" in work
     and "todayHome ? Self.only(model.workIntake, split.older" in work, "[split] Work's Sort holds only older suggestions with Today on, and reads nothing new with it off")
need("if todayHome, model.workUndoBatch != nil {" in work, "[undo] Undo last decision stays with Today on")

# Helper on disk (item 18): the switch-off path writes nothing new.
need('"sessions": sessions.map { $0.filter { $0.key != "waitingQuestion" && $0.key != "waitingQuestionCount" } },' in helper,
     "[disk] the session cache never holds a question's words")

# Settings (both open questions as settings).
for key, label in (("TodayHome.enabledKey", "Today home"), ("TodayHome.quietHoursKey", "Quiet hours"), ("TodayHome.workRunsKey", "Work runs from Today")):
    need(key in views and f'Toggle("{label}"' in views, f"[settings] {label}")

# 0.5.361 wording (Miles, 2026-10-31: ⌘K said "Nothing is waiting on you" where Today said "Six things need you"): the headline and ⌘K read the
# same quiet-hours fold, in the same words. The fold itself is TodayHome.fold, executed in ActivityTodayChecks; this pins who reads it.
core_text = strip((root / "Sources/SetupAssistant.swift").read_text())
brief_counts = body(today, "    func todayBriefCounts(", "\n    func todayHomeView(")
need("counts.folded = TodayHome.fold(frame.needs, quiet: TodayHome.isQuiet(now: now, enabled: TodayHome.quietHoursOn(.standard))).tomorrow.count" in brief_counts
     and "Text(TodayHome.brief(todayBriefCounts(frame, now: now)))" in today and "Text(TodayHome.brief(frame.counts))" not in today,
     "[wording] Today's headline reads the quiet-hours fold, so it agrees with the ⌘K panel")
need("quiet: TodayHome.isQuiet(now: now, enabled: TodayHome.quietHoursOn(.standard)))" in body(today, "    func commandInputs(", "\n    func commandResultInputs()")
     and "inputs.foldedCount = commandFixture?.foldedCount ?? folded.tomorrow.count" in today, "[wording] ⌘K counts what the same fold moved to tomorrow")
need("c.needs - c.folded" in logic and "things can wait until tomorrow" in logic and "things can wait until tomorrow" in core_text and "Nothing urgent right now." in core_text,
     "[wording] the headline and ⌘K say the folded count in the same words")
need("var folded = 0" in body(logic, "    struct Counts: Equatable {", "    static let agentPlatforms"), "[wording] the fold count is part of the counts the brief reads")
# The rail and the Needs you header read the same fold (QA 0.5.361, U4: the rail said "6 need you" over a headline that said they can wait).
rail_fn = body(today, "    func todayRail(", "\n    func todayRailItem(")
panel_fn = body(today, "    func todayNeedsPanel(", "\n    func todayRetryLine(")
need("let railCounts = todayBriefCounts(frame, now: now)" in rail_fn and "TodayHome.story(item.key, railCounts, now: now)" in rail_fn
     and "TodayHome.story(item.key, frame.counts" not in today, "[rail] the rail reads the quiet-hours fold the headline reads")
need('if line == .rows, !folded.now.isEmpty { Text("\\(folded.now.count)")' in panel_fn and 'Text("\\(frame.needs.count)")' not in panel_fn,
     "[header] the Needs you header counts the rows it lists, not the ones the fold moved to tomorrow")
# The list refreshes when ⌘K opens (not forced), and the tick is unchanged: one refresh in each place.
need(body(today, "    func openCommandCenter() {", "\n    func closeCommandCenter() {").count("loadClaudeSessions()") == 1
     and "force: true" not in body(today, "    func openCommandCenter() {", "\n    func closeCommandCenter() {"), "[command center] the session list refreshes when ⌘K opens, not forced")
need(win.count("if !model.petEnabled { await model.loadClaudeSessions() }") == 1, "[pet off] the tick is unchanged: the one refresh the pet-off home had")
# One list from the loaded sessions and the live rows (the pet-on home had only the live ones): bounded, merged by the engine's sameSession.
need("SetupAssistant.Center.merged(live: newest(todaySessions()).map(item), listed: model.petEnabled ? newest(model.claudeSessions).map(item) : [])" in today
     and "static let commandSessionLimit = 80\n" in today, "[command center] the panel's sessions are the live rows and the loaded list, merged and bounded")

# Copy rules: no em dash, arrows or attribution in Today's words; no eyebrow, no vanity totals.
literals = re.findall(r'"((?:[^"\\]|\\.)*)"', today + "\n" + logic)
for bad, label in (("—", "em dash"), ("→", "arrow"), ("You said", "attribution"), ("known", "vanity total"), ("this week", "vanity total")):
    need(not any(bad in l for l in literals), f"[copy] no {label} in Today's words")
need("Your COS" not in "".join(literals), "[copy] no 'Your COS' section label")

if fails:
    for f in fails:
        print("Activity Today pin: " + f)
    sys.exit(1)
print("COS Control: Activity Today wiring pinned: polling rule, Work's own resolve one at a time, Dismiss and its Undo, read-only questions, cost guards, capability gating, Reduce Motion, rail and keyboard, VoiceOver, the shared Sort split, settings and copy")
