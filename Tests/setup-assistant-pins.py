#!/usr/bin/env python3
"""Ask COS setup assistant (Sources/SetupAssistant.swift): the pins its compiled checks cannot see.

    python3 Tests/setup-assistant-pins.py <root>

  - The engine imports Foundation only, declares one top-level name (enum SetupAssistant) that no other Sources file
    uses, and has no way to run, open or send anything (no Process, NSWorkspace, URLSession, URL, defaults or files).
  - Every helper command an action names is a case in the helper's command switch, every Doctor row it reads is one the
    helper writes, and every runtime state it compares against is a RuntimeState case.
  - Its run cap is TodayRunGuard.dailyCap, and every code path a knowledge-base entry cites exists.
  - Every explicit full-app compile list names SetupAssistant.swift (Tests/kit-compile.py builds the shared kit from every
    Sources file, so a list without it would silently stop matching its kit).
  - The full suite runs this lane.
  - The ⌘K command center's view half (Sources/ActivityWindow.swift, the Command center extension and CommandCenterPanel), which
    the compiled checks cannot see: ⌘K stays on its tab, Esc reaches the panel first, the field is never disabled, Return and
    Option-Return keep their meanings, every command and action has a dispatch case with no default, typed words reach only a
    run or a filed task, recording goes through the store's gates, a confirm checks fresh state, session titles are drawn
    verbatim and open only their own row, breadcrumbs carry no words, and nothing moves.
  - The recording section under the Today header: its place, nothing when nothing records, and Stop only through its confirm.
The engine has no way to run anything, and nothing a person types becomes a command. The views run it through closed switches.
Comments are stripped before a code pin, so a comment can never satisfy one.
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
failures, passed = [], 0


def read(rel):
    return (root / rel).read_text(encoding="utf-8")


def code(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.splitlines())


def pin(condition, what):
    global passed
    if condition:
        passed += 1
    else:
        failures.append(what)


def before(text, *parts):
    """Every part present, in this order. A missing part fails the pin that asked, by name, instead of ending the run."""
    at = -1
    for part in parts:
        i = text.find(part, at + 1)
        if i < 0:
            return False
        at = i
    return True


def block(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i + len(start))]


core_raw = read("Sources/SetupAssistant.swift")
core = code(core_raw)
helper = code(read("HelperSources/main.swift"))
models = code(read("Sources/Models.swift"))

# 1. Local first: Foundation only, one namespace, nothing that runs, opens or sends.
imports = re.findall(r"^import\s+(\w+)", core, re.M)
pin(imports == ["Foundation"], f"SetupAssistant.swift imports Foundation only: {imports}")
top = re.findall(r"^(?:enum|struct|class|actor|extension|func|let|var|typealias|protocol)\s+(\w+)", core, re.M)
pin(top == ["SetupAssistant"], f"one top-level declaration, enum SetupAssistant: {top}")
for banned in ("Process(", "Process.", "NSWorkspace", "URLSession", "URL(", "NSTask", "posix_spawn", "popen", "system(", "UserDefaults",
               "FileManager", "NSPasteboard", "Data(contentsOf", "write(to"):
    pin(banned not in core, f"the engine never uses {banned}")
others = [p.name for p in (root / "Sources").glob("*.swift")
          if p.name != "SetupAssistant.swift" and re.search(r"\b(enum|struct|class|typealias|actor)\s+SetupAssistant\b", p.read_text(encoding="utf-8"))]
pin(not others, f"no other Sources file declares SetupAssistant: {others}")

# 2. The helper commands exist, in the helper's command switch.
commands = re.findall(r'case \.(\w+): return "([a-z-]+)"', block(core, "var helperCommand: String? {", "default: return nil"))
pin(len(commands) == 8, f"eight actions are helper commands: {commands}")
switch = block(helper, "        switch command {", '        default: throw HelperError.message("unknown command')
for action, command in commands:
    pin(f'case "{command}":' in switch, f"{action}: the helper's command switch has a case \"{command}\"")

# 3. The Doctor rows it reads are rows the helper writes.
names = re.findall(r'static let \w+ = "([^"]+)"', block(core, "enum CheckName {", "}"))
pin(len(names) == 6, f"six Doctor rows are read: {names}")
doctor = block(helper, "private func doctorDetails(redacted: Bool)", "private func manifestConfiguredWorkDirectory")
for name in names:
    pin(f'add("{name}"' in doctor, f'doctorDetails writes the "{name}" row')

# 4. The runtime states it compares against are RuntimeState cases.
states = set(re.findall(r'runtimeState [!=]= "(\w+)"', core))
states |= set(re.findall(r'case "(\w+)":', block(core, "switch s.runtimeState {", "default:")))
cases = set(re.findall(r"case (\w+)", block(helper, "enum RuntimeState: String {", "}")))
pin(states and states <= cases, f"runtime states {sorted(states - cases)} are not RuntimeState cases")

# 5. The cap it quotes is the Today cap.
cap = re.search(r"static let dailyCap = (\d+)", models)
runs = re.search(r"static let dailyRuns = (\d+)", core)
pin(cap and runs and cap.group(1) == runs.group(1), "dailyRuns equals TodayRunGuard.dailyCap")

# 6. Every code path a knowledge-base entry cites exists.
sources = re.findall(r'source: "([^"]+)"', core_raw)
pin(len(sources) == core_raw.count("Entry(id:"), "every knowledge-base entry has a source")
for cited in sorted({p for s in sources for p in re.findall(r"\b((?:Sources|HelperSources)/\w+\.swift)", s)}):
    pin((root / cited).is_file(), f"cited file {cited} exists")

# 7. Every explicit full-app compile list names the file (they all end a line with SessionUsageView.swift).
lists = 0
for path in sorted(list(root.glob("scripts/*.sh")) + list(root.glob("Tests/*.sh"))):
    text = path.read_text(encoding="utf-8")
    lists += text.count('"$ROOT/Sources/SessionUsageView.swift" "$ROOT/Sources/SetupAssistant.swift" \\\n')
    pin('"$ROOT/Sources/SessionUsageView.swift" \\\n' not in text, f"{path.relative_to(root)}: a full-app compile list leaves out SetupAssistant.swift")
pin(lists >= 10, f"SetupAssistant.swift is in the explicit full-app compile lists ({lists} found, 10 expected)")
release = read("scripts/build-release.sh")
pin(release.count('"$ROOT/Sources/SetupAssistant.swift"') == 1, "the release build compiles SetupAssistant.swift once")

# 8. The suite runs the lane.
pin(read("Tests/run.sh").count('zsh "$ROOT/Tests/run-setup-assistant.sh"') == 1, "Tests/run.sh runs the setup assistant lane once")

# 9. The command center's view half.
window = code(read("Sources/ActivityWindow.swift"))
ext = block(window, "    func commandSnapshot() -> SetupAssistant.Snapshot {", "struct CommandCenterKeyHint: View {")
panel = window[window.index("struct CommandCenterPanel: View {"):]
frame = block(window, "    var todayFrameView: some View {", "    func todayResetExpansions()")

# Placement: at frame level, in the TimelineView closure, above the clipped content, with this tick's rows.
pin("let frame = todayFrame(now: timeline.date)" in frame and before(frame, ".clipped()", "if commandOpen { commandCenter(frame: frame, now: timeline.date, windowSize: geometry.size, mode: mode) }"),
    "the panel sits in the TimelineView closure, above the clipped content, and reads that tick's frame")
pin("CommandCenterPanel(" in window and window.count("CommandCenterPanel(") == 1, "one panel in the window")
pin("@State private var words" in panel and "@State private var commandQuery" not in window, "typing is the panel's own state, so it never composes the window")
pin(".sheet(" not in panel and ".popover(" not in panel, "the panel is inline, never a sheet or a popover")

# ⌘K opens it where you are. Tests/activity-today-pins.py holds the same rule for the Today suite.
pin('Button("") { toggleCommandCenter() }' in frame and "goHome" not in block(window, "    func toggleCommandCenter() {", "    func commandSectionChanged() {")
    and "goHome" not in block(window, "    func openCommandCenter() {", "    func closeCommandCenter() {"), "⌘K never navigates")

# The box only opens it. The field is never disabled: Return guards instead.
box = block(window, "    var todayAskBox: some View {", "    func todaySubmitAsk(")
pin("Button { openCommandCenter() } label:" in box and "TextField(" not in box, "the Today box is a button that opens the panel")
pin(".disabled(" not in panel, "the panel's field and rows are never disabled")
pin("today.runBusy || today.captureBusy" not in window and ".disabled(today.runBusy || today.captureBusy)" not in window, "the old disabled Ask field is gone")
submit = block(window, "    func todaySubmitAsk(", "    func todayNeedsPanel(")
pin("guard !text.isEmpty, !today.runBusy, !today.captureBusy else { return }" in submit, "Return guards while a run or a capture is on its way")

# Keys.
escape = block(window, "    private func handleActivityEscape() -> Bool {", "    private func goBack()")
pin(before(escape, "if commandOpen {", "if showingSettings {") and [l.strip() for l in escape.split("\n") if l.strip()][1] == "if commandOpen {",
    "Esc reaches the panel before anything else")
pin("if commandKeys.escape?() != true { closeCommandCenter() }" in escape, "Esc undoes one thing in the panel, then closes it")
pin("keys.escape = { pressEscape() }" in panel and "keys.escape = nil" in panel, "the panel owns its Esc while it is mounted")
monitor = block(window, "private struct CommandCenterKeyMonitor: NSViewRepresentable {", "struct CommandCenterPanel: View {")
pin("event.keyCode == 125 || event.keyCode == 126" in monitor and "hasMarkedText() != true" in monitor and "window.isKeyWindow, window.attachedSheet == nil" in monitor,
    "Up and Down go through a local monitor scoped to this window, and text being composed keeps them")
pin("NSEvent.removeMonitor(monitor)" in monitor and "CommandCenterKeyMonitor(onMove: { move($0) }, onOptionReturn: {" in panel, "the monitor lives only while the panel is mounted")
press = block(panel, "    private func pressReturn(", "    private func activate(")
pin("private func pressReturn(option: Bool = false) {" in press and "C.onReturn(option: option," in press, "Return reaches the engine's one rule")
pin("event.keyCode == 36 || event.keyCode == 76, flags == .option" in monitor and "pressReturn(option: true)" in panel,
    "Option-Return goes through the monitor: a single-line field types a line break for it and never submits")
pin("case .file: submit(listing.words, true)" in press and "case .move(let id): chosen = id" in press,
    "Option-Return files, and a near-command only moves the highlight")
# A bare Return run goes through the Ask row: the saved answer, a short snapshot and the rules ride with the words. The raw words
# never go to the Today box's submit as a run.
start_run = block(press, "        case .startRun:", "        case .file:")
pin("submit(" not in start_run and "listing.rows.first(where: { $0.kind == .ask && $0.selectable })" in start_run and "activate(ask.id, listing)" in start_run,
    "Return with no highlight starts its Work run through the Ask row, never with the raw words")
pin(press.count("submit(") == 1, "the panel's submit is Option-Return's filing and nothing else")
pin("submit: { words, file in todaySubmitAsk(words, file: file) }" in ext, "Return reaches today's own submit")
pin(".onTapGesture { closeCommandCenter() }" in ext, "a click outside closes it")

# A row that ran leaves nothing armed: no highlight, no words in the box, no draft for the next open. The words are used up in
# `perform` for every row but the ones that send them, and a run, a filing or a recording empties the draft directly, because
# a panel closed by a click outside has no `clearWords` left to call.
perform = block(panel, "    private func perform(", "    private func resultLine(")
pin(before(perform, "let effect = run(row, listing)", "if effect != .notice, !C.sendsWords(row) {", "chosen = nil", "words = C.draftAfterRun(row, words)", "keys.draft = words", "switch effect {"),
    "a row that ran empties its highlight, the box and the draft, unless it sends the words or only showed the notice")
keys_class = block(window, "@MainActor final class CommandCenterKeys {", "struct CommandCenterFixture {")
pin('func clearDraft() {\n        draft = ""\n        clearWords?()\n    }' in keys_class, "clearDraft empties the draft directly, then the box if it is on screen")
filing = block(window, "    func todaySubmitAsk(", "    func todayNeedsPanel(")
pin(before(filing, "try await model.captureTask(domain: taskDomain, text: text)", "commandKeys.clearDraft()"), "a filing that succeeded empties the draft")
start_run_fn = block(ext, "    func commandStartRun(", "\n    }\n")
pin(before(start_run_fn, "if today.runNote == TodayHomeStore.startedNote { commandKeys.clearDraft() }"), "a run that started empties the draft, even with the panel gone")
now_fn = block(ext, "    func commandRecordNow() {", "\n    }\n")
pin(before(now_fn, "today.recordInFlight = true", "commandKeys.clearDraft()", "Task {"), "a recording under way empties the draft")
pin(window.count("commandKeys.clearDraft()") == 3 and "commandKeys.clearWords?()" not in ext, "a filing, a run and a recording are the only three places that empty the draft")

# Every command and action has a dispatch case, with no default.
for fn, enum in (("func commandRun(_ command: SetupAssistant.Center.Command) -> CommandEffect {", "enum Command: String, CaseIterable, Sendable {"),
                 ("func commandRun(_ action: SetupAssistant.Action, words: String) -> CommandEffect {", "enum Action: String, Sendable, CaseIterable {")):
    run = block(ext, fn, "\n    }\n")
    pin("default:" not in run, f"{fn}: no default, so a new case will not compile")
    declared = block(core, enum, "            var title: String {" if "Command" in enum else "        var helperCommand: String? {")
    names = [n for line in declared.split("\n") if line.strip().startswith("case ") for n in re.findall(r"\b(\w+)\b", line.split("case ", 1)[1])]
    pin(len(names) >= 10, f"{enum}: read the cases: {names}")
    for name in names:
        pin(re.search(r"\." + name + r"\b", run) is not None, f"{fn}: dispatches .{name}")
row_run = block(ext, "    func commandRun(_ row: SetupAssistant.Center.Row, _ listing: SetupAssistant.Center.Listing) -> CommandEffect {", "\n    }\n")
pin("default:" not in row_run, "every kind of row is dispatched, with no default")

# Typed words reach only a run or a filed task, never a helper argument or an opener.
pin('model.perform(command)' in ext and ext.count("model.perform(") == 1 and "guard let command = action.helperCommand" in ext, "a helper command comes only from the closed action")
helpers = re.findall(r"model\.runHelper\(\[([^\]]*)\]", ext)
pin(len(helpers) == 1 and helpers[0].startswith('"report", "--current-version", ControllerModel.currentVersion'), f"the one helper call has fixed arguments: {helpers}")
pin("words" not in helpers[0] and "listing" not in helpers[0], "typed words are never a helper argument")
pin("commandRun(.runDoctor, words: \"\")" in ext, "Doctor from the list carries no words")

# Recording: the store's gates, the same busy rule as the meeting card, Stop on the Mac capture only.
recording = block(ext, "    func commandRecording() -> SetupAssistant.Center.Recording {", "\n    }\n")
pin("r.stoppable = store.isRecording || r.starting" in recording and 'r.starting = store.phase == "starting"' in recording, "Stop keys on the Mac capture")
pin("r.stoppable" in recording and "recordingCount" not in recording.split("r.stoppable")[1].split("\n")[0], "Stop never keys on recordingCount")
pin("MeetingDetectedCard.recordingBusy(macOccupied: store.occupied, macCanStart: store.canStart, liveRecordings: model.recordingCount)" in recording,
    "Start uses the one busy rule, which counts a glasses meeting")
now = block(ext, "    func commandRecordNow() {", "\n    }\n")
pin("guard !today.recordInFlight, SetupAssistant.Center.recordingHold(commandRecording(), commandSnapshot()) == nil else { return }" in now, "one start at a time, and the hold is checked again at the click")
pin(before(now, "today.recordInFlight = true", "store.record(title:") and "today.recordInFlight = false" in now, "the start has an in-flight flag")
pin("if id == nil {" in now and "select(.meetings)" in now and "commandKeys.recordFailed = true" in now, "a failed start says why and opens Meetings")
pin("words" not in now and "listing" not in now, "the words in the box never name the recording")
pin("MacRecordingNoticeCard(onRecord:" in panel and "recordAfterNotice()" in panel, "the notice shows in the panel")
start = block(ext, "    func commandStartRecording() -> CommandEffect {", "\n    }\n")
pin("guard MacRecordingNotice.step(acknowledged: model.macRecording.noticeAcknowledged) == .start else { return .notice }" in start, "the notice comes first")
pin("commandStopRecording()" in block(ext, "    func commandRun(_ command: SetupAssistant.Center.Command) -> CommandEffect {", "\n    }\n")
    and "Task { await model.macRecording.stop() }" in block(ext, "    func commandStopRecording() {", "\n    }\n"), "Stop stops the Mac capture")

# A confirm checks fresh state and has no force path.
confirm = block(panel, "    private func confirmOpen(_ listing: C.Listing) {", "    private func perform(")
pin(before(confirm, "C.recheck(row, snapshot(), recording())", "return\n", "perform(row, listing)"), "a confirm re-checks fresh state, and a held row runs nothing")
activate = block(panel, "    private func activate(", "    private func confirmOpen(")
pin(before(activate, "C.confirmation(row, snapshot()) != nil", "perform(row, listing)"), "a change opens its confirm instead of running")
pin("row.selectable else { return }" in activate, "a held row never runs")

# Asking: troubleshoot's order, and no Doctor for Ask.
trouble = block(ext, "    func commandTroubleshoot(_ words: String) {", "    func commandStartRun(")
order = ["SetupAssistant.gate(.troubleshoot, commandSnapshot()) == .ready", "today.runRefusal(", "today.gatheringReport = true", "model.runHelper([", "commandStartRun(run)"]
pin(all(p in trouble for p in order) and [trouble.index(p) for p in order] == sorted(trouble.index(p) for p in order), "troubleshoot: guard first, in-flight flag, then Doctor, then the run")
pin("guard !today.gatheringReport, !today.runBusy," in trouble, "troubleshoot: one at a time")
ask = block(ext, "    func commandAsk(_ listing: SetupAssistant.Center.Listing) {", "    func commandTroubleshoot(")
pin("SetupAssistant.Center.askRun(" in ask and "runHelper" not in ask and "perform(" not in ask, "Ask COS spends no Doctor")

# Sessions: the fold, looked up again at open, the Cursor fallback kept, no question words, verbatim.
inputs = block(ext, "    func commandInputs(frame: TodayHome.Frame, now: Date) -> SetupAssistant.Center.Inputs {", "\n    }\n")
pin("TodayHome.fold(frame.needs, quiet: TodayHome.isQuiet(now: now, enabled: TodayHome.quietHoursOn(.standard)))" in inputs and "folded.now.map" in inputs, "Waiting uses the quiet-hours fold")
pin(".quote" not in ext and ".why" not in ext and "waitingQuestion" not in ext, "a question's words never reach the panel")
pin("inputs.waitingKnown = frame.line != .loading" in inputs, "a list not loaded yet never says nothing is waiting")
opener = block(ext, "    func commandOpenWaiting(_ id: String) -> CommandEffect {", "\n    }\n")
pin("todayFrame(now: Date()).needs.first(where: { $0.id == id })" in opener and "todayOpenNeed(row)" in opener, "a waiting row is looked up again at open, and todayOpenNeed keeps the Cursor fallback")
pin("todayFrame(now: Date()).running.first(where: { $0.id == id })" in block(ext, "    func commandOpenRunning(_ id: String) -> CommandEffect {", "\n    }\n"), "a running row is looked up again at open")
pin("Text(verbatim: row.title)" in panel and "Text(row.title)" not in panel and "Text(row.detail" not in panel, "row text is drawn verbatim")
pin("AttributedString" not in panel and "markdown" not in panel.lower(), "a title is never parsed as anything")

# Breadcrumbs carry no typed words and no titles.
logs = [line for line in (ext + panel).split("\n") if "todayLog." in line]
pin(len(logs) >= 3, f"the command center leaves breadcrumbs: {logs}")
for line in logs:
    pin("\\(" not in line or "row.logName" in line, f"a breadcrumb names a kind, never words: {line.strip()}")

# VoiceOver and no motion.
pin("AccessibilityNotification.Announcement(C.announcement(" in panel and ".accessibilityHint(hint)" in panel, "VoiceOver hears the highlight and what Return will do")
pin(".accessibilityAddTraits(highlighted ? .isSelected : [])" in panel, "VoiceOver hears which row is highlighted")
for motion in ("withAnimation", ".animation(", ".transition(", "TodayPulse", "TimelineView"):
    pin(motion not in panel, f"nothing moves in the panel: {motion}")

# The recording section (Miles, 2026-10-31): under the Today header, above everything else, and nothing when nothing records.
home = block(window, "    func todayHomeView(", "    func todayHeader(now: Date)")
pin(before(home, "todayHeader(now: now)", "TodayRecordingSection(", "TodayHome.brief(frame.counts)", "todayNeedsPanel(frame", "todayRunningPanel(run"),
    "the recording section sits under the header, above the brief, Needs you and Running")
pin("if !frame.recordings.isEmpty {\n                    TodayRecordingSection(" in home, "no recording, no section: it takes no space")
section = block(window, "struct TodayRecordingSection: View {", "struct CommandCenterKeyHint: View {")
pin("Button(SetupAssistant.Center.stopConfirm.confirm) { confirming = row.id }" in section, "Stop and save in the section opens its confirm")
pin(section.count("stop()") == 1 and "if recording().stoppable { stop() }" in section, "the section stops only from its confirm, after checking the store again")
pin("row.recording?.canStop == true && live.stoppable" in section, "Stop and save is offered only for this Mac's own capture, while it records")
pin("TodayHome.recordingStopNote(" in section, "a glasses meeting says where it stops")
pin("LiveDot(live: !saving, size: 11)" in section and "COSPalette.live" in section, "the recording mark is COSPalette.live")
for motion in ("withAnimation", ".animation(", ".transition(", "TodayPulse", "TimelineView"):
    pin(motion not in section, f"the section has no pulse: {motion}")
pin("recordingCount" not in section, "the section never reads recordingCount")
live_rows = block(window, "    func todayRecordings() -> [TodayHome.Recording] {", "    func todayRunInputs(now: Date)")
pin("let stoppable = store.isRecording || starting" in live_rows and 'let starting = store.phase == "starting"' in live_rows and "recordingCount" not in live_rows,
    "a recording keys on the Mac capture's own state and the server's live sessions, never recordingCount")
pin("canStop: stoppable" in live_rows and live_rows.count("canStop:") == 1, "only this Mac's capture can have Stop")
# A Mac capture the server still counts after this Mac let go of it (saved, or pending after a failed save) is a Mac row. It is never
# the unnamed recording the section falls back to, and never a glasses meeting in ⌘K.
pin("TodayHome.nonMacLive(serverLive: model.liveTranscriptServerLive, liveSessionIDs: model.liveTranscriptRows.filter { $0.phase == .live }.map(\\.sessionId)," in live_rows
    and "macHeld: store.occupied, captureID: captureID)" in live_rows, "the unnamed recording leaves out every Mac capture the server counts")
pin("TodayHome.nonMacLive(serverLive: model.recordingCount, liveSessionIDs: model.liveTranscriptRows.filter { $0.phase == .live }.map(\\.sessionId)," in recording
    and "macHeld: store.occupied, captureID: store.manifest?.captureId)" in recording, "a Mac capture is never a glasses meeting in the command center")
pin("input.recordings = todayRecordings()" in window, "Running's inputs and the section read one list")
pin("inputs.live = frame.recordings.compactMap" in ext, "⌘K lists the same recordings as the section")
pin("case .recording(let id):\n            todayOpen(.liveView(id))" in ext, "a recording row opens its live view, the same action as the section")
pin(ext.count("model.macRecording.stop()") == 1,
    "one Stop for the command center and the section")

# Result line and the alert.
pin("get: { model.error != nil && !commandOpen }," in window, "a failure shows in place while the panel is open, not over it")
results = block(ext, "    func commandResultInputs() -> SetupAssistant.Center.ResultInputs {", "\n    }\n")
for name in ("today.notice", "model.platformOpenNotice", "model.operationProgress", "model.error", "today.runNote"):
    pin(name in results, f"the result line reads {name}")

if failures:
    for failure in failures:
        print("Setup assistant pin: " + failure, file=sys.stderr)
    sys.exit(1)
print(f"PASS: setup assistant pins, {passed} passed")
