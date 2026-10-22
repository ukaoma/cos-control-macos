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

# Polling (plan section 8).
loop = body(today, "func todayTickLoop() async {", "\n    func todayOpenLoads() async {")
need("if model.liveTranscriptWindowOnScreen { await today.tick(model: model) }" in loop, "[polling] the tick runs only while the window is on screen")
need("try? await Task.sleep(nanoseconds: TodayHomeStore.tickSeconds * 1_000_000_000)" in loop and "static let tickSeconds: UInt64 = 60" in store,
     "[polling] one 60 s tick")
need("static let slowSeconds: TimeInterval = 300" in store and store.count("Self.slowSeconds") == 2, "[polling] calendar and intake at most every 5 minutes")
need(len(re.findall(r"\btodayTickLoop\(\)", win)) == 2 and ".task(id: todayEnabled) { await todayTickLoop() }" in today,
     "[polling] one tick loop, owned by the Today frame (it ends when the window goes)")
tick = body(store, "    func tick(model: ControllerModel, now: Date = Date()) async {", "\n    static func readHosts(")
need(tick.count("model.todayHelper(") == 1 and "guard !ticking else { return }" in tick, "[polling] one helper call per tick, never two at once")
need("async let" not in today and "TaskGroup" not in today, "[polling] the home's loads are serial")
need("session-questions" not in win and "session-questions" not in helper, "[polling] never poll /api/session-questions")
need("activity-signals" not in today and "loadActivitySignals" not in today, "[polling] the home is not a second reader of activity-signals")
need("loadClaudeSessions" not in today, "[polling] no new sessions loop: the status and pet loops publish sessions")

# Intake on Today (B4): accept only, one at a time, never seen or dismiss.
create = body(store, "    func createTask(", "\n    func nameVoice(")
need('"action": "accept"' in create and "dismiss" not in today and '"seen"' not in today and "markSeen" not in today,
     "[never seen or dismiss] Today only ever accepts")
need("guard !intakeBusy" in create and "intakeBusy = true" in create, "[one at a time] one intake action in flight")
need(".disabled(today.intakeBusy || !model.workIntake.cardCreation)" in today, "[one at a time] Create task is disabled while one is in flight")
need("resolveWorkIntake" not in today and "resolve-batch" not in today, "[one at a time] no batch, no shared resolve that blanks Work's error")

# Session questions are read only (B1): one Open button, never an answer.
actions = body(today, "    func todayNeedActions(", "\n    func todayRunningPanel(")
session_case = body(actions, "case .session:", "case .voice:")
need(session_case.count("Button(") == 1 and "todayOpenNeed(row)" in session_case, "[read only questions] a session row has one Open button and no options")
need("session-chat-send" not in today and "permission" not in session_case, "[read only questions] Today never answers a session")

# Voices: no listen or owner acknowledgement sent from home.
name = body(store, "    func nameVoice(", "\n    static func inFlightTargets(")
need("heldNamingListened" not in name and "heldNamingOwnerAck" not in name and "!preview.requiresListening, !preview.owner" in name
     and "voices[group.id] = .listen" in name, "[voices] Listen and owner checks route to Speakers, never sent from home")

# Cost guards (section 3): admission before the one submit, counted when asked, outcome after.
start = body(store, "    func startRun(", "\n}\n")
need(start.count("handoff.submit(") == 1, "[cost guards] one Work run per tap")
need(start.index("guardrail.admission(") < start.index("guardrail.recordStart(") < start.index("handoff.submit(") < start.index("guardrail.recordOutcome("),
     "[cost guards] admission, then count, then the one submit, then the breaker's outcome")
need("guard admission == .allowed else {" in start, "[cost guards] nothing starts unless the guard allows it")
need("guard !runBusy else { return }" in start and 'switchOn: TodayHome.workRunsOn(.standard)' in start, "[cost guards] the switch and one at a time")
need(today.count("today.startRun(") == 2, "[cost guards] only Prep me and the Ask box start Work runs")
need("static let dailyCap = 20" in models and "static let breakerFailures = 3" in models and "static let breakerPause: TimeInterval = 15 * 60" in models,
     "[cost guards] 20 a day, 3 failures, 15 minutes")
ask = body(today, "    func todaySubmitAsk(", "\n    func todayNeedsPanel(")
need("if file || !TodayHome.workRunsOn(.standard) {" in ask and "model.captureTask(" in ask, "[cost guards] the switch off (or Option Return) files to the Work inbox")

# Capability gating (D4, 1b): glasses questions only on a server that advertises the route.
need("input.jobs = today.jobsSupported == true ? today.jobs : nil" in today, "[capability] no capability, no question rows")
need('details["activeQueryJobs"] = Self.activityTodayJobsSupported(' in helper and 'features?["activeQueryJobs"] as? Bool == true' in helper,
     "[capability] detected by the advertised feature, never by a status code")

# Reduce Motion: the pulse is still.
pulse = body(today, "struct TodayPulse: View {", "\n}\n")
need("if !reduceMotion {" in pulse and "repeatForever" in pulse, "[reduce motion] no pulse animation under Reduce Motion")
need("TodayPulse(reduceMotion: reduceMotion)" in today and "if row.working { TodayPulse" in today, "[reduce motion] only working rows pulse")

# Rail on every tab (D1), with ⌘0 Today, ⌘1 to ⌘9 tabs, ⌘K the Ask box.
frame = body(today, "    var todayFrameView: some View {", "\n    func todayTickLoop() async {")
need("todayRail(mode: mode, frame: frame, now: timeline.date)" in frame and "activityContent(today: frame" in frame, "[rail] the rail sits beside every tab's content")
need('.keyboardShortcut("k", modifiers: .command)' in frame and "todayAskFocused = true" in frame, "[keyboard] ⌘K focuses the Ask box from any tab")
rail_item = body(today, "    func todayRailItem(", "\n    func todayHomeView(")
need(".keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)" in rail_item, "[keyboard] ⌘0 Today, then ⌘1 to ⌘8 the tabs")
need(".accessibilityLabel(label)" in rail_item and ".help(label)" in rail_item, "[voiceover] rail items carry their story")
need(".accessibilityLabel(row.voiceLabel)" in today, "[voiceover] Running rows read their platform, title, state and Open")

# Work's Sort reads the same split (D2).
need("let split = TodayHome.intakeSplit(items: model.workIntake.items, tasks: model.workTasks, now: Date())" in work
     and "todayHome ? Self.only(model.workIntake, split.older" in work, "[split] Work's Sort holds only older suggestions with Today on")

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
