#!/usr/bin/env python3
"""Activity Today home (plan v2): the wiring the compiled views hide, pinned on code with comments stripped.

    python3 Tests/activity-today-pins.py <worktree>

Behaviour lives in Tests/ActivityTodayChecks.swift; these pins hold what only the view and store code can show: the
polling rule (one 60 s tick while on screen, serial, never session questions, no second activity-signals reader), Today
never calls seen or dismiss, one intake action at a time, session questions read only, the Work-run cost guards around the
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

def body(text, start, end):
    i = text.index(start)
    j = text.index(end, i + len(start))
    return text[i:j]

win = strip((root / "Sources/ActivityWindow.swift").read_text())
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
need("today.overviewDone = true" in win and win.index("today.overviewDone = true") < win.index("private func loadHomeWork()"),
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

# Intake on Today (B4): Work's own accept path, one at a time, never seen or dismiss.
create = body(store, "    func createTask(", "\n    func nameVoice(")
need("await model.resolveWorkIntake(item, accept: true)" in create and "dismiss" not in today and '"seen"' not in today and "markSeen" not in today,
     "[never seen or dismiss] Today only ever accepts, through Work's own path (its Undo and busy ids)")
need("guard model.workIntakeBusyIDs.isEmpty" in create, "[one at a time] one intake action in flight")
need(today.count(".disabled(!model.workIntakeBusyIDs.isEmpty)") == 2, "[one at a time] Create task and Try again wait for the one in flight")
need("resolve-batch" not in today, "[one at a time] no batch")

# Session questions are read only (B1): one Open button, never an answer.
actions = body(today, "    func todayNeedActions(", "\n    func todayRunningPanel(")
session_case = body(actions, "case .session:", "case .voice:")
need(session_case.count("Button(") == 1 and "todayOpenNeed(row)" in session_case, "[read only questions] a session row has one Open button and no options")
need("session-chat-send" not in today and "permission" not in session_case, "[read only questions] Today never answers a session")

# Voices: no listen or owner acknowledgement sent from home; nothing stale read.
name = body(store, "    func nameVoice(", "\n    static func inFlightTargets(")
need("heldNamingListened" not in name and "heldNamingOwnerAck" not in name and "!preview.requiresListening, !preview.owner" in name
     and "voices[group.id] = .listen" in name, "[voices] Listen and owner checks route to Speakers, never sent from home")
need(name.index("model.heldNamingResult = nil") < name.index("await model.nameHeld(") and 'result.speaker == name' in name and "preview.speaker == name" in name,
     "[voices] the result is cleared first and must be for this name")
need("guard model.heldGroupsSpeakerModel, model.heldNamingAvailable" in name, "[voices] no naming without the speaker model")

# Cost guards (section 3): admission, then preflight, then the one submit, then accounting by the new receipt's id.
start = body(store, "    func startRun(", "\n    func flash(")
need(start.count("handoff.submit(") == 1, "[cost guards] one Work run per tap")
need(start.index("guardrail.admission(") < start.index("TodayRunGuard.preflight(") < start.index("handoff.submit(") < start.index("guardrail.account(outcome"),
     "[cost guards] admission, then the busy and open-run check, then the one submit, then the accounting")
need("guard admission == .allowed else {" in start, "[cost guards] nothing starts unless the guard allows it")
need("intentID: id)" in start and "handoff.receipts.first { $0.id == id }" in start, "[cost guards] the new receipt is matched by its own id")
need("guard !runBusy else { return }" in start and 'switchOn: TodayHome.workRunsOn(.standard)' in start, "[cost guards] the switch and one at a time")
need("TodayHome.pickRunModel(" in start, "[cost guards] runs from Today use the picked non-Opus model")
need(today.count("today.startRun(") == 2, "[cost guards] only Prep me and the Ask box start Work runs")
need("static let dailyCap = 20" in models and "static let breakerFailures = 3" in models and "static let breakerPause: TimeInterval = 15 * 60" in models,
     "[cost guards] 20 a day, 3 failures, 15 minutes")
ask = body(today, "    func todaySubmitAsk(", "\n    func todayNeedsPanel(")
need("if file || !TodayHome.workRunsOn(.standard) {" in ask and "model.captureTask(" in ask and "!today.captureBusy" in ask,
     "[cost guards] the switch off (or Option Return) files to the Work inbox, once")

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
need('.keyboardShortcut("k", modifiers: .command)' in frame and "todayAskFocused = true" in frame, "[keyboard] ⌘K focuses the Ask box from any tab")
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
need("let split = todayHome ? TodayHome.intakeSplit(items: model.workIntake.items, tasks: model.workTasks, now: Date()) : TodayHome.IntakeSplit()" in work
     and "todayHome ? Self.only(model.workIntake, split.older" in work, "[split] Work's Sort holds only older suggestions with Today on, and reads nothing new with it off")
need("if todayHome, model.workUndoBatch != nil {" in work, "[undo] Undo last decision stays with Today on")

# Helper on disk (item 18): the switch-off path writes nothing new.
need('"sessions": sessions.map { $0.filter { $0.key != "waitingQuestion" && $0.key != "waitingQuestionCount" } },' in helper,
     "[disk] the session cache never holds a question's words")

# Settings (both open questions as settings).
for key, label in (("TodayHome.enabledKey", "New Today home"), ("TodayHome.quietHoursKey", "Quiet hours on Today"), ("TodayHome.workRunsKey", "Start Work runs from Today")):
    need(key in views and f'Toggle("{label}"' in views, f"[settings] {label}")

# Copy rules: no em dash, arrows or attribution in Today's words; no eyebrow, no vanity totals.
literals = re.findall(r'"((?:[^"\\]|\\.)*)"', today + "\n" + logic)
for bad, label in (("—", "em dash"), ("→", "arrow"), ("You said", "attribution"), ("known", "vanity total"), ("this week", "vanity total")):
    need(not any(bad in l for l in literals), f"[copy] no {label} in Today's words")
need("Your COS" not in "".join(literals), "[copy] no 'Your COS' section label")

if fails:
    for f in fails:
        print("Activity Today pin: " + f)
    sys.exit(1)
print("COS Control: Activity Today wiring pinned: polling rule, accept only and one at a time, read-only questions, cost guards, capability gating, Reduce Motion, rail and keyboard, VoiceOver, the shared Sort split, settings and copy")
