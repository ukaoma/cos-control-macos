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
  - 0.5.361: free text never starts a run on the first Return (no `.startRun`); a word-search hit is its own group that Return never
    moves onto; the word search is local (a helper `--local` path, the words on stdin, no server, no OpenAI), panel-owned, debounced
    and cancelled by the next key; a hit opens by its own session object; every pane and tab the window has is a Place, a Command,
    or on the explicit exclusion list; `sameSession` in the engine equals `ClaudeSession.sameSession`; the footer is three Texts.
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
# The helper has "/*" inside a string far above these functions, so `code()` would cut them out: line comments only for these two.
helper_lines = "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in read("HelperSources/main.swift").splitlines())

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
pin("case .file: submit(listing.words)" in press and "case .move(let id): chosen = id" in press,
    "Option-Return files, and a near-command only moves the highlight")
# 0.5.361: free text never starts a run on the first Return. It moves to the Ask row, and the second Return runs that row, which
# carries the saved answer, a short snapshot and the rules. The raw words never go to the Today box's submit as a run.
pin("case startRun" not in core and "return .startRun" not in core and "case .startRun" not in window, "there is no startRun outcome: a Work run starts only from the Ask row, on a second Return")
pin(press.count("submit(") == 1, "the panel's submit is Option-Return's filing and nothing else")
on_return = block(core, "        static func onReturn(option: Bool,", "        struct Footer: Equatable, Sendable {")
pin("return .startRun" not in on_return and "return .move(target.id)" in on_return, "Return on free text moves to Ask or File, never to a run")
pin(before(on_return, "if option {", "if noticeShowing { return .nothing }", "if confirming { return .confirm }", "return .nothing }\n            if let id = effective(chosen, listing) { return .activate(id) }"),
    "a chosen row that is gone returns nothing before any other rule")
order_row = block(core, "        private static func isOrder(_ row: Row) -> Bool {", "        static func listing(_ inputs: Inputs, words raw: String) -> Listing {")
pin("case .command, .place: return row.group != .sessions" in order_row and ".hit" not in order_row and ".searchAll" not in order_row, "Return moves from the top only onto a command or a place, never a hit or a session list line")
pin("listing.rows.first(where: { $0.group == .sessions && $0.selectable })" in on_return and ".found" not in on_return, "a title match keeps the move, and the hit group is never read by Return")
pin("submit: { words in todaySubmitAsk(words) }" in ext and "file: file" not in window, "Return reaches today's own submit, which only files")
pin(".onTapGesture { closeCommandCenter() }" in ext, "a click outside closes it")

# A row that ran leaves nothing armed: no highlight, no words in the box, no draft for the next open. The words are used up in
# `perform` for every row but the ones that send them, and a run, a filing or a recording empties the draft directly, because
# a panel closed by a click outside has no `clearWords` left to call.
perform = block(panel, "    private func perform(", "    private func resultLine(")
pin(before(perform, "let effect = run(row, listing)", "if effect != .notice, !C.sendsWords(row) {", "chosen = nil", "words = C.draftAfterRun(row, words)", "keys.draft = words", "switch effect {"),
    "a row that ran empties its highlight, the box and the draft, unless it sends the words or only showed the notice")
keys_class = block(window, "@MainActor final class CommandCenterKeys {", "struct CommandCenterFixture {")
pin('func clearDraft() {\n        draft = ""\n        clearWords?()\n    }' in keys_class, "clearDraft empties the draft directly, then the box if it is on screen")
pin("guard SetupAssistant.Center.sentWordsAreUsedUp(sent: sent, draft: draft, accepted: accepted) else { return }\n        clearDraft()" in keys_class,
    "a finished send empties the draft only when it was accepted and the box still holds what was sent")
filing = block(window, "    func todaySubmitAsk(", "    func todayNeedsPanel(")
pin(before(filing, "try await model.captureTask(domain: taskDomain, text: text)", "commandKeys.clearDraft(afterSend: text, accepted: true)"), "a filing that succeeded empties the draft, if it still holds what was filed")
start_run_fn = block(ext, "    func commandStartRun(", "\n    }\n")
pin(before(start_run_fn, "let accepted = await today.startRun(", "commandKeys.clearDraft(afterSend: sent, accepted: accepted)") and "startedNote" not in start_run_fn,
    "a run the guard accepted empties the draft, if it still holds what was sent, even with the panel gone; the note decides nothing")
now_fn = block(ext, "    func commandRecordNow() {", "\n    }\n")
pin(before(now_fn, "today.recordInFlight = true", "commandKeys.clearDraft()", "Task {"), "a recording under way empties the draft")
pin(window.count("commandKeys.clearDraft(") == 3 and window.count("commandKeys.clearDraft()") == 1 and "commandKeys.clearWords?()" not in ext, "a filing, a run and a recording are the only three places that empty the draft, and only the recording does it unconditionally")

# Return never moves onto Start recording from a Start phrase inside a longer sentence: that row asks nothing before it records.
notice = block(panel, "MacRecordingNoticeCard(onRecord: {", "}, onNotNow:")
pin(before(notice, "noticeShowing = false", "chosen = nil", "recordAfterNotice()"), "the card's Record uses the Start row up, so a Return after it arms nothing")
recording_inputs = block(ext, "    func commandRecording() -> SetupAssistant.Center.Recording {", "\n    }\n")
pin("r.knownGlasses = r.glassesLive > 0 && others.count >= r.glassesLive && others.allSatisfy { !$0.isPhone && !$0.isUnknown }" in recording_inputs,
    "the words say glasses only when every other recording is known to be on them")

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
reports = [h for h in helpers if h.startswith('"report", "--current-version", ControllerModel.currentVersion')]
searches = [h for h in helpers if h.startswith('"claude-sessions-search"')]
finds = [h for h in helpers if h.startswith('"agent-sessions-find"')]
pin(len(helpers) == 3 and len(reports) == 1 and len(searches) == 1 and finds == ['"agent-sessions-find"'], f"three helper calls, all with fixed arguments: {helpers}")
pin(searches == ['"claude-sessions-search", "--local", "--limit", "8"'], f"the word search is one fixed verb, local, with a fixed limit: {searches}")
pin(all("words" not in h and "listing" not in h and "query" not in h for h in helpers), "typed words are never a helper argument")
search_fn = block(ext, "    func commandSearchSessions(_ words: String) async throws -> [CommandHit] {", "\n    }\n")
pin("stdinData: Data(String(words.prefix(200)).utf8)" in search_fn and "--query" not in ext, "the one stated exception to hard rule 2: the words go to the helper's stdin, at most 200 characters, never an argument")
pin("--query" not in window[window.index("    func commandSnapshot() -> SetupAssistant.Snapshot {"):window.index("struct CommandCenterKeyHint: View {")], "the command center never builds a --query argument")
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
order = ["SetupAssistant.gate(.troubleshoot, commandSnapshot()) == .ready", "today.runRefusal(", "today.gatheringReport = true", "model.runHelper([", "commandStartRun(run, sent: words)"]
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
MEANING_LOGS = {
    'todayLog.info("command center: meaning choice \\(choice.rawValue, privacy: .public)")',
    'todayLog.info("command meaning \\(stage.rawValue, privacy: .public) \\(result.reason?.rawValue ?? "answered", privacy: .public) ms=\\(Int(Date().timeIntervalSince(started) * 1000))")',
}
logs = [line for line in (ext + panel).split("\n") if "todayLog." in line]
pin(len(logs) >= 3, f"the command center leaves breadcrumbs: {logs}")
for line in logs:
    pin("\\(" not in line or "row.logName" in line or line.strip() in MEANING_LOGS or ("outcome.kind" in line and "Int(Date().timeIntervalSince(started) * 1000)" in line and "words" not in line),
        f"a breadcrumb names a kind, never words: {line.strip()}")

# VoiceOver and no motion.
pin("AccessibilityNotification.Announcement(C.announcement(" in panel and ".accessibilityHint(hint)" in panel, "VoiceOver hears the highlight and what Return will do")
pin(".accessibilityAddTraits(highlighted ? .isSelected : [])" in panel, "VoiceOver hears which row is highlighted")
for motion in ("withAnimation", ".animation(", ".transition(", "TodayPulse", "TimelineView"):
    pin(motion not in panel, f"nothing moves in the panel: {motion}")

# The recording section (Miles, 2026-10-31): under the Today header, above everything else, and nothing when nothing records.
home = block(window, "    func todayHomeView(", "    func todayHeader(now: Date)")
pin(before(home, "todayHeader(now: now)", "TodayRecordingSection(", "TodayHome.brief(todayBriefCounts(frame, now: now))", "todayNeedsPanel(frame", "todayRunningPanel(run"),
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

# ---- 0.5.361: places, the local word search, hits, and the footer ----------------------------------------------------------------

# Every pane and tab the window has is reached by a Command, by a Place, or sits on an explicit exclusion with its reason. The enums are
# parsed from source, so a new tab fails here until it has a row or a reason. A stale exclusion fails too.
def enum_cases(text, name):
    start = text.index(f"enum {name}")
    body = text[text.index("{", start) + 1:]
    cases = []
    for line in body.split("\n"):
        stripped = line.strip()
        if stripped.startswith("case "):
            cases += [m.group(0) for c in stripped[5:].split(",") if (m := re.match(r"[A-Za-z_]\w*", c.strip()))]
        elif stripped and not stripped.startswith(("///", "//", "@", "static", "var", "func", "private")) and cases:
            break
        elif stripped.startswith(("static", "var", "func")):
            break
    return [c for c in cases if c]

go = block(ext, "    func commandGo(_ place: SetupAssistant.Center.Place) -> CommandEffect {", "\n    }\n")
opener = block(ext, "    func commandRun(_ command: SetupAssistant.Center.Command) -> CommandEffect {", "\n    }\n")
reach = go + opener
sources = {"ActivitySection": window, "SessionsPane": code(read("Sources/SessionUsageView.swift")), "MessagesSubview": window, "SpeakerSubview": window,
           "ActivityWorkSubview": window, "WorkWorkspaceScope": code(read("Sources/WorkWorkspaceView.swift")), "MemoriesSubview": window}
reached_by = {
    "ActivitySection": lambda c: f"select(.{c})" in reach or (c == "threads" and "select(.threads)" in reach),
    "SessionsPane": lambda c: (f"sessionsPane = .{c}" in reach),
    "MessagesSubview": lambda c: f"messagesSubview = .{c}" in reach,
    "SpeakerSubview": lambda c: f"speakerSubview = .{c}" in reach,
    "WorkWorkspaceScope": lambda c: f"commandOpenWork(scope: .{c})" in reach,
    "ActivityWorkSubview": lambda c: False,
    "MemoriesSubview": lambda c: False,
}
# (enum, case) -> why it is not a row. Memories tabs: the page is a web view that reads its view once, when it is made, so a tab change
# from here needs a new setter (cut from 0.5.361, said in the notes).
excluded = {
    ("ActivitySection", "tasks"): "Tasks is a synonym for Work (resolvedLaunch), and Command.openWork answers to it",
    ("ActivityWorkSubview", "tasks"): "the Work pane's only subview, with no tab to choose",
    ("ActivityWorkSubview", "meetingFollowUp"): "never set anywhere: Work's workspace replaced it, so there is no tab to reach",
    ("MemoriesSubview", "recentLearning"): "Memories is a web view that reads its view once; a tab change needs a new setter",
    ("MemoriesSubview", "allMemories"): "same",
    ("MemoriesSubview", "toReview"): "same",
    ("MemoriesSubview", "knowledge"): "same",
}
covered_by_command = {("ActivitySection", "meetings"): "openMeetings", ("ActivitySection", "speakers"): "openSpeakers", ("ActivitySection", "memories"): "openMemories",
                      ("ActivitySection", "sessions"): "openSessions", ("ActivitySection", "work"): "openWork", ("ActivitySection", "dictation"): "openDictation",
                      ("SessionsPane", "sessions"): "openSessions"}
seen_exclusions = set()
for enum_name, text in sources.items():
    cases = enum_cases(text, enum_name)
    pin(len(cases) >= 2, f"read the cases of {enum_name}: {cases}")
    for case in cases:
        key = (enum_name, case)
        if key in excluded:
            seen_exclusions.add(key)
            pin(not reached_by[enum_name](case) or key == ("ActivitySection", "tasks"), f"{enum_name}.{case} is excluded and also has a row: drop the exclusion")
            continue
        pin(reached_by[enum_name](case), f"{enum_name}.{case} has no row (a Command opener or a Place) and no explicit exclusion")
for key in excluded:
    pin(key in seen_exclusions, f"the exclusion {key} names a case that does not exist any more")
pin(re.search(r"case \.openSessions:\s*\n\s*(?://[^\n]*\n\s*)*select\(\.sessions\)\s*\n\s*sessionsPane = \.sessions", opener) is not None,
    "Open Sessions resets the Sessions tab, so it never lands on Usage")
pin("loadArchiveDays" in go and "model.archiveDays.isEmpty" in go, "Messages > Archive loads its days, which only a tab change loaded before")
_work = block(ext, "    func commandOpenWork(scope: WorkWorkspaceScope) {", "\n    }\n")
pin(all(f in _work for f in ("select(.work)", 'workWorkspaceState.query = ""', "workWorkspaceState.domain = nil", "workWorkspaceState.selectedID = nil", "handoffStore.selectedWorkID = nil",
                              "workWorkspaceState.meetingPicker = false", "workWorkspaceState.linkTarget = nil", "reviewStore.selectedMeeting = nil", "workWorkspaceState.focusOverride = false"))
    and _work.rstrip().endswith("workWorkspaceState.scope = scope"), "a Work place lands on a clean list: no open card, no domain, no search, no picker, then the scope last")
pin("model.closeDictationSettings()" in block(window, "    private func clearDetail() {", "    private func openMemoriesView("), "leaving Dictation closes its settings, as it closes its Dictionary and History")
pin("goHome()" in go and "default:" not in go, "Today is goHome(), and every Place is dispatched with no default")
place_cases = [c for line in block(core, "        enum Place: String, CaseIterable, Sendable {", "            var title: String {").split("\n") if line.strip().startswith("case ") for c in re.findall(r"\w+", line.split("case ", 1)[1])]
pin(len(place_cases) == 17, f"read the Place cases: {place_cases}")
for case in place_cases:
    pin(re.search(r"case \." + case + r"\b", go) is not None, f"commandGo dispatches .{case}")
pin("Place" in block(core, "        enum Kind: Equatable, Sendable {", "        enum Group: Int, Sendable {"), "a Place is a kind of row, separate from a Command")
pin(re.findall(r"^(?:enum|struct|class)\s+Place\b", core, re.M) == [] and core.count("enum Place: String, CaseIterable, Sendable {") == 1, "one Place enum, nested in Center")

# One session lists once: the engine's sameSession is the app's, body for body.
engine_same = re.sub(r"\s+", " ", block(core, "        static func sameSession(_ a: String, _ b: String) -> Bool {", "        static func sameListed(_ a: String, _ b: String) -> Bool"))
app_same = re.sub(r"\s+", " ", block(read("Sources/Models.swift"), "    static func sameSession(_ a: String, _ b: String) -> Bool {", "    /// The chip word."))
engine_same = engine_same.split("{", 1)[1].rsplit("}", 1)[0].strip()
app_same = app_same.split("{", 1)[1].rsplit("}", 1)[0].strip()
pin(engine_same == app_same, f"Center.sameSession equals ClaudeSession.sameSession: {engine_same!r} vs {app_same!r}")

# One session, one row, one id (QA item 3): a Desktop record is named by its cliSessionId, rows and hits share one key, and open never reads the Desktop root.
pin("let sessionId = UUID(uuidString: head.cliSessionId) != nil ? head.cliSessionId : id" in helper_lines and '"id": sessionId,' in helper_lines, "a Desktop record's row carries the cliSessionId its transcript carries")
pin(helper_lines.count("sessionRowKey(provider:") >= 5, "rows, hits and the transcript lookup share one key per session")
pin("let alias = String(desktop.id.prefix(8))" not in helper_lines and "desktopOnlyRows: false" in helper_lines, "the Desktop record rows are listed once, by the local scan itself")
reveal_call = helper_lines.split("let transcript = Self.findClaudeSessionFile(", 1)[1][:260]
pin("desktopSessionsRoot" not in reveal_call, "open never passes the Desktop root to the transcript lookup (it reads every record head, about 9 s)")
pin("local-session-search-checks.py" in read("Tests/run.sh") and "COS_CONTROL_TEST_HOME" in read("Tests/local-session-search-checks.py"), "the open path is tested through the compiled helper against a fixture home")

# Honest absence (QA item 5): the three stopword lists are one list, and the body read decodes leniently.
def _words(text, start):
    return set(re.findall(r'"([a-z]+)"', block(text, start, "]")))
_core_stop = _words(read("Sources/SetupAssistant.swift"), "static let searchStopwords: Set<String> = [")
_helper_stop = _words(read("HelperSources/main.swift"), "static let sessionSearchStopwords: Set<String> = [")
_models_stop = _words(read("Sources/Models.swift"), "static let stopwords: Set<String> = [")
pin(len(_core_stop) == 21 and _core_stop == _helper_stop == _models_stop, f"the engine, the helper and the Sessions tab skip the same words: {sorted(_core_stop ^ _helper_stop)} {sorted(_core_stop ^ _models_stop)}")
_peek = block(helper_lines, "    static func peekSessionSearchBody(in file: URL", "        return parts.joined(separator: \"\\n\")")
pin("data.split(separator: 0x0A, omittingEmptySubsequences: true)" in _peek and "String(decoding:" not in _peek and "String(data: data, encoding: .utf8)" not in _peek
    and "handle.read(upToCount: maxBytes)" in _peek and "isRegularTranscript(file)" in _peek,
    "the body read splits the bytes at newlines, throws instead of raising and reads regular files only, so a window cut inside a character drops one line, not the file")

# Privacy words (QA item 4): the bundled notes say typing stays on this Mac, say what Search all sessions uses, and say the first before the second.
import json as _json
_notes = " ".join(_json.loads(read("Resources/WhatsNew.json"))["whatsNew"]["sections"][0]["items"])
pin("sends nothing off it" in _notes and "asks the COS server" in _notes and "OpenAI" in _notes and _notes.index("sends nothing off it") < _notes.index("Search all sessions"),
    "the notes say typing stays on this Mac and Search all sessions asks the COS server, in that order")
pin("COS server" in read("CHANGELOG.md").split("## 0.5.360")[0] and "OpenAI key" in read("CHANGELOG.md").split("## 0.5.360")[0], "the changelog says what Search all sessions uses")

# The local word search: a helper path that reads files and nothing else; the panel owns the search.
local = block(helper, "    private func emitLocalSessionsSearch(args: [String]) throws {", "    private func emitClaudeSessionsSearch(args: [String]) throws {")
for banned in ("request(", "speakerReviewToken", "readToken", "speakerReviewBody", "URLSession", "Process()", "embedding", "openai", "queryEscape"):
    pin(banned.lower() not in local.lower(), f"the local search never uses {banned}")
pin("FileHandle.standardInput.read(upToCount: 4_097 - input.count)" in local and ".prefix(200)" in local and "query.count >= 3" in local, "the local search reads its words from a bounded stdin, 200 characters, at least 3")
pin("Self.localSessionKeywordHits(query: query, limit: limit, home: home," in local, "the local search is the fallback's own scan, over the helper's home (the person's, or a /tmp fixture under test)")
pin("desktopNewest: Self.localSearchDesktopNewest, transcriptNewest: Self.localSearchTranscriptNewest, readCursorPins: false," in local
    and "codexNewest: Self.localSearchCodexNewest, cursorNewest: Self.localSearchCursorNewest, codexNamesTailBytes: Self.localSearchCodexNamesTailBytes)" in local,
    "the local search bounds its title reads: the newest Desktop records, Claude transcripts, Codex rollouts and Cursor transcripts, and no sqlite3 process per Cursor workspace")
def bound(name):
    found = re.search(r"static let " + name + r" = (\d+)\n", helper)
    return int(found.group(1)) if found else None
pin((bound("localSearchDesktopNewest"), bound("localSearchTranscriptNewest"), bound("localSearchCodexNewest"), bound("localSearchCursorNewest")) == (30, 20, 20, 20),
    "the title reads are bounded to exactly 30 Desktop records and 20 each of Claude, Codex and Cursor transcripts (9.1 s unbounded, about 1.4 s at these, on 733 Desktop records and 870 transcripts)")
pin("recentCodexConversations(sessionsRoot: codexRoot, newest: codexNewest, namesTailBytes: codexNamesTailBytes)" in helper_lines
    and "pinnedIds: cursorPinned,\n            newest: cursorNewest\n" in helper_lines,
    "the local scan passes the newest bound to the Codex and Cursor scans (the answer does not show it: those scans already return 20 rows; the reads do)")
pin(helper_lines.count("allowed = Set(dated.sorted { $0.mtime > $1.mtime }.prefix(newest).map(\\.file))") == 2
    and helper_lines.count("allowed = Set(dated.sorted { $0.1 > $1.1 }.prefix(newest).map(\\.0))") == 1
    and helper_lines.count("if let allowed, !pinned, !allowed.contains(file) { continue }") == 3, "the Claude, Codex and Cursor scans title only the newest transcripts when they are told to")
pin("files = dated.sorted { $0.1 > $1.1 }.prefix(newest).map(\\.0)" in helper_lines, "loadClaudeDesktopIndex reads only the newest heads when it is told to")
reveal = block(helper, "    private func emitSessionReveal(args: [String]) throws {", "    private func emitSessionHooksStatus() throws {")
pin("let fullId = transcript.map { $0.deletingPathExtension().lastPathComponent.lowercased() }.flatMap { UUID(uuidString: $0) == nil ? nil : $0 } ?? sessionId" in reveal
    and "sessionId: fullId,\n                records: Self.claudeDesktopRecords(for: fullId, sessionsRoot: desktopRoot)," in reveal and "Self.claudeDesktopMentions(fullId, sessionsRoot: desktopRoot)" in reveal,
    "a short Claude id (how a search hit names a session) reveals through its transcript's full id, which Desktop's links need")
pin('if let at = args.firstIndex(of: "--local"), !(at > 0 && args[at - 1] == "--query") { try emitLocalSessionsSearch(args: args); return }' in helper, "the verb's --local flag is the first thing it checks, and a query of those characters is not the flag")
pin("commandKeys.searchAllWords = model.sessionQuery" in window and "if let said = commandKeys.searchAllWords, model.sessionQuery == said { model.sessionQuery = \"\"; model.scheduleSessionSearch() }" in window,
    "opening Sessions on its own takes out the words Search all left in its box")
pin("incoming.merging(keys.hitSessions.filter { old in refreshed.hits.contains { $0.id == old.key } }" in panel, "a hit kept for the person who chose it keeps its session")
pin("static let sessionSearchBodyFileLimit = 80\n" in helper, "the scan reads at most 80 transcripts")
panel_search = block(panel, "    private func runSearch(_ words: String?) async {", "    private func runMeaning(")
pin(".task(id: listing.searchWords) { await runSearch(listing.searchWords) }" in panel, "one search at a time: the task is keyed by the words, so a key cancels the last one")
pin("guard fixture == nil else { return }" in panel_search and "Task.sleep(nanoseconds: 500_000_000)" in panel_search, "500 ms of quiet first, and nothing runs under a fixture")
pin(before(panel_search, "guard let words else", "Task.sleep(nanoseconds: 500_000_000)", "guard !Task.isCancelled else { return }", "try await search(words)", "guard !Task.isCancelled else { return }", "C.refreshed("),
    "a cancelled search stores nothing")
pin("@State private var found = C.Found()" in panel and "inputs.found = found" in panel and "@State private var meaning = C.MeaningFound()" in panel and "inputs.meaningFound = meaning" in panel,
    "the hits, word and meaning, are the panel's own state")
announce = [line.strip() for line in panel_search.split("\n") if "Announcement(" in line]
pin(announce == ["if shown > 0 { AccessibilityNotification.Announcement(C.foundAnnouncement(shown)).post() }"], f"on arrival VoiceOver hears only the fixed count: {announce}")
for forbidden in ("sessionSearchHits", "sessionSearching", "sessionSearchError", "sessionSemantic"):
    pin(forbidden not in ext and forbidden not in panel, f"the command center never reads the Sessions tab's {forbidden}")
pin("model.sessionQuery = String(words.prefix(200))" in block(ext, "    func commandSearchAll(_ words: String) -> CommandEffect {", "\n    }\n")
    and ext.count("model.sessionQuery = String(") == 1 and ext.count("model.sessionQuery = \"\"") == 1 and ext.count("scheduleSessionSearch()") == 2,
    "Search all sessions is the one place the Sessions tab's box is filled, and only when that row is chosen; the Sessions opener empties it again, only of those words")
pin("let session = ClaudeSession.listed(hit: hit.session, loaded: loaded, workSessionIDs: workIDs, runningWorkSessionIDs: runningIDs)" in search_fn
    and "model.workSessionIDs" in search_fn and "model.runningWorkSessionIDs" in search_fn and "model.claudeSessions" in search_fn,
    "a hit passes the server-hold guard the list rows have: the loaded row, else marked as Work or running Work")
_leaves = block(ext, "    func commandLeaves(_ session: ClaudeSession) -> Bool {", "\n    }\n")
pin("case .platform: return session.heldByServer" in _leaves and "default: return true" in _leaves, "a platform open clears no reply; a held session or Cursor without Accessibility opens in Sessions and does")
_inputs_text = block(ext, "    func commandInputs(frame: TodayHome.Frame, now: Date) -> SetupAssistant.Center.Inputs {", "\n    func commandResultInputs()")
pin(_inputs_text.count("leavesSession: commandLeaves(") == 3 and "leavesSession: commandLeaves(session))" in search_fn, "every waiting, running, listed and hit row says whether opening it leaves the open session")
pin("search: { words in try await commandSearchSessions(words) }" in ext, "the panel reaches the search only through the window's one function")
pin(re.search(r"runHelper|model\.", panel) is None, "the panel itself calls no model and no helper")

# A hit opens by its own object, never from a lookup that only knows the list.
open_hit = block(ext, "    func commandOpenHit(_ id: String) -> CommandEffect {", "\n    }\n")
pin("commandKeys.hitSessions[id]" in open_hit and "petSession(" not in open_hit and "claudeSessions" not in open_hit, "a hit opens its own session object, not a list lookup")
pin("model.openSessionInPlatform(session)" in open_hit and "model.openClaudeSession(session)" in open_hit and "TodayHome.openFor(" in open_hit, "a hit opens the way a list row does: the platform, or Sessions' reader")
pin(window.count("hitSessions =") == 2 and "keys.hitSessions = incoming.merging(" in panel_search, "the hit sessions are written when the panel opens (cleared) and when hits arrive, nowhere else")
pin("case .hit(let id): return commandOpenHit(id)" in row_run and "case .searchAll: return commandSearchAll(listing.words)" in row_run and "case .place(let place): return commandGo(place)" in row_run, "a hit, Search all sessions and a place are each dispatched")

# The panel's list refreshes on open, not on the tick.
open_fn = block(ext, "    func openCommandCenter() {", "    func closeCommandCenter() {")
pin("Task { await model.loadClaudeSessions() }" in open_fn and "force: true" not in open_fn, "the session list refreshes when the panel opens, and is not forced")
ticker_fn = block(window, "    func todayTick() async {", "\n    func todayOpenLoads() async {")
pin("loadClaudeSessions" in ticker_fn and ticker_fn.count("loadClaudeSessions") == 1 and "if !model.petEnabled { await model.loadClaudeSessions() }" in ticker_fn, "the tick is unchanged")

# Match text: its own field, drawn verbatim, never named `why`, never a decision.
pin("Text(verbatim: match)" in panel and "row.match" in panel and ".match" not in block(core, "        static func onReturn(option: Bool,", "        struct Footer: Equatable, Sendable {"), "match text is drawn verbatim on its row and Return never reads it")
pin("var match: String? = nil" in core and "whyMatched" not in core and "whyMatched" not in window, "the match field is `match`, never a name the view half bans")
pin("let masked" not in ext and "C.mask(" not in panel, "masking happens in the engine where the row is made, not in a view")
pin("hitTitle(item.title)" in block(core, "        static func listing(_ inputs: Inputs, words raw: String) -> Listing {", "        static func effective(_ chosen: String?, _ listing: Listing) -> String? {") and "matchLine(item.match, title: item.title)" in core, "a hit's title and match text are masked where the row is made")

# The footer: the title is cut, the words around it never are, and VoiceOver hears the whole line as the field's hint.
foot = block(panel, "    private func footerLine(_ footer: C.Footer) -> some View {", "\n    }\n")
pin(foot.count("Text(verbatim:") == 3 and "footer.lead" in foot and "footer.title" in foot and "footer.tail" in foot, "the footer is three Texts")
pin(foot.count("truncationMode(.tail)") == 1 and foot.index("truncationMode(.tail)") > foot.index("footer.title") and foot.index("truncationMode(.tail)") < foot.index("footer.tail"), "only the title is cut")
pin(foot.count("fixedSize(horizontal") == 2 and ".accessibilityHidden(true)" in foot and ".accessibilityHint(hint)" in panel and "let hint = footer.text" in panel, "the lead and tail keep their width, and the field's hint is the whole line")
pin("C.noticeHint" in panel and "C.Footer(lead: C.noticeHint)" in panel, "the one-time notice has its own line")

# The window hands the engine the raw setting; the engine decides it is "off" only once the list answered (QA 0.5.361, U9).
pin("inputs.sessionsSettingOff = !model.claudeSessionsEnabled" in window and "inputs.sessionsOff =" not in window
    and "var sessionsOff: Bool { sessionsSettingOff && sessionsLoaded }" in core, "the window passes the Show AI sessions setting")

# A hit's open: the panel stays until the app has answered, so a failed open's words land where the person is looking (QA 0.5.361, U10).
open_hit = block(window, "    func commandOpenHit(_ id: String) -> CommandEffect {", "    func commandSearchAll(_ words: String) -> CommandEffect {")
pin("guard model.platformOpening else { return .stay }" in open_hit and "guard !model.platformOpenFailed, commandKeys.generation == generation else { return }" in open_hit
    and 'commandKeys.draft = ""\n                closeCommandCenter()' in open_hit and "let generation = commandKeys.generation" in open_hit and "petNotice" not in open_hit and "heldByServer" not in open_hit,
    "a hit's failed open keeps the panel open until its notice lands, a clean one clears the words, a panel opened since is left alone")
cm = code(read("Sources/ControllerModel.swift"))
pin("platformOpenFailed = petNotice != nil && !petRevealSucceeded" in cm and cm.count("petRevealSucceeded = true") == 1 and "platformOpenFailed = true; return }" in cm,
    "a platform open is a failure by its flag: a good Codex note is not one, and the key guard's refusal is")
pin("SessionSearchHit.merged(instant, remote)" in cm and "let opened = ClaudeSession.listed(hit: session, loaded: model.claudeSessions, workSessionIDs: model.workSessionIDs, runningWorkSessionIDs: model.runningWorkSessionIDs)" in window
    and "model.openClaudeSession(opened)" in window and "model.openClaudeSession(session)" not in block(window, "    private func sessionRow(", "    private var sessionsStatus: String {"),
    "a Sessions tab row opens the list's row or the hit marked as Work, and the search merges one row per session")
for fn, end in (("    func commandOpenWaiting(", "    func commandOpenedEffect()"), ("    func commandOpenRunning(", "    func commandOpenSession("), ("    func commandOpenSession(", "    func commandLeaves(_ session")):
    pin("return commandOpenedEffect()" in block(window, fn, end), f"{fn.strip()} says whether the panel stays after a refusal")
pin("!model.platformOpening && model.platformOpenFailed && model.platformOpenNotice != nil ? .stay : .close" in window, "a refusal that answers at once keeps the panel open")
pin("C.keepsWordsWhileStaying(row)" in panel and "static func keepsWordsWhileStaying(_ row: Row) -> Bool" in core, "a staying hit keeps its words")

# The credential-key rule is a copy of WorkCardFiles.credentialKey (the engine file is Foundation-only): the two bodies must stay equal.
def function_body(text, signature):
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if signature in line)
    depth, body = 0, []
    for line in lines[start + 1:]:
        depth += line.count("{") - line.count("}")
        if depth < 0:
            break
        body.append(line.strip())
    return body

mirror = "static func credentialKey(_ key: String) -> Bool {"
pin(function_body(core, mirror) == function_body(code(read("Sources/WorkCardFiles.swift")), mirror) and len(function_body(core, mirror)) > 8,
    "the credential key rule equals WorkCardFiles.credentialKey")

# A failed word search: a timeout is its own phase, and the log names the kind and the elapsed time, never the words (QA 0.5.361, G8).
search_fn = block(panel, "    private func runSearch(_ words: String?) async {", "    private func runMeaning(")
failure_fn = block(window, "    static func searchFailure(_ error: Error) -> (kind: String, phase: SetupAssistant.Center.SearchPhase) {", "    func commandSearchAll(")
pin("case .timedOut: return (\"timed out\", .timedOut)" in failure_fn and "let outcome = ActivityWindow.searchFailure(error)" in search_fn
    and "found = C.Found(words: words, phase: outcome.phase)" in search_fn, "a timed out search is its own phase")
pin("todayLog.error(\"command search \\(outcome.kind, privacy: .public) ms=\\(Int(Date().timeIntervalSince(started) * 1000))\")" in search_fn
    and "words" not in search_fn.split("todayLog.error(", 1)[1].split("\n", 1)[0], "the search log names the kind and the elapsed time only")

# ---- QA 0.5.361 item 16: pins that can fail --------------------------------------------------------------------------------------

# (G3) Each tab write sits inside the case block of the place or opener that owns it, and no block writes a tab that is not listed. The old
# check searched one pool of text for each tab, so it passed with Usage and COS cost swapped, with a write under the wrong case, and with a
# new tab nobody listed.
def case_blocks(text):
    marks = list(re.finditer(r"^[ \t]*case \.(\w+)(?:, \.\w+)*:", text, re.M))
    return {m.group(1): text[m.end():(marks[i + 1].start() if i + 1 < len(marks) else len(text))] for i, m in enumerate(marks)}

def tab_writes(text):
    found = set(re.findall(r"select\(\.\w+\)|\w*[sS]ubview = \.\w+|sessionsPane = \.\w+|commandOpenWork\(scope: \.\w+\)|goHome\(\)|model\.open\w+\(\)", text))
    return found

go_cases = case_blocks(go)
want_go = {
    "today": {"goHome()"}, "messages": {"select(.messages)"}, "threads": {"select(.threads)"},
    "messagesRecent": {"select(.messages)", "messagesSubview = .recent"}, "messagesArchive": {"select(.messages)", "messagesSubview = .archive"},
    "speakersMeetings": {"select(.speakers)", "speakerSubview = .meetings"}, "speakersSamples": {"select(.speakers)", "speakerSubview = .samples"},
    "speakersVoices": {"select(.speakers)", "speakerSubview = .voices"},
    "sessionsUsage": {"select(.sessions)", "sessionsPane = .usage"}, "sessionsCost": {"select(.sessions)", "sessionsPane = .cost"},
    "workAll": {"commandOpenWork(scope: .all)"}, "workNeeds": {"commandOpenWork(scope: .attention)"}, "workProgress": {"commandOpenWork(scope: .progress)"},
    "workCompleted": {"commandOpenWork(scope: .completed)"},
    "dictationHistory": {"select(.dictation)", "model.openDictationHistory()"}, "dictationDictionary": {"select(.dictation)", "model.openDictionary()"},
    "dictationSettings": {"select(.dictation)", "model.openDictationSettings()"},
}
pin(set(go_cases) == set(want_go) == set(place_cases), f"commandGo has exactly the Place cases: {sorted(set(go_cases) ^ set(want_go))}")
for name, expected in want_go.items():
    got = tab_writes(go_cases.get(name, ""))
    pin(got == expected, f"commandGo .{name} reaches exactly {sorted(expected)}, not {sorted(got)}")
open_cases = case_blocks(opener)
want_open = {"startRecording": set(), "stopRecording": set(), "openSessions": {"select(.sessions)", "sessionsPane = .sessions"}, "openMeetings": {"select(.meetings)"},
             "openWork": {"select(.work)"}, "openSpeakers": {"select(.speakers)"}, "openDictation": {"select(.dictation)"}, "openMemories": {"select(.memories)"},
             "openSettings": set(), "runDoctor": set()}
pin(set(open_cases) == set(want_open), f"the opener switch has exactly the Command cases: {sorted(set(open_cases) ^ set(want_open))}")
for name, expected in want_open.items():
    got = tab_writes(open_cases.get(name, "")) - {"model.openSettings()"}
    pin(got == expected, f"the opener .{name} reaches exactly {sorted(expected)}, not {sorted(got)}")
search_all = block(window, "    func commandSearchAll(_ words: String) -> CommandEffect {", "\n    }\n")
pin(tab_writes(search_all) == {"select(.sessions)", "sessionsPane = .sessions"} and "model.sessionQuery = String(words.prefix(200))" in search_all and "model.scheduleSessionSearch()" in search_all,
    "Search all opens Sessions on its list and starts that tab's own search")
# A new tab enum nobody listed fails here (a ThreadsSubview, say), as a new case does above.
every_tab_enum = set()
for file in sorted((root / "Sources").glob("*.swift")):
    every_tab_enum |= set(re.findall(r"^(?:private |fileprivate )?enum (\w+(?:Subview))\b", file.read_text(encoding="utf-8"), re.M))
pin(every_tab_enum <= set(sources), f"every Subview enum has its cases checked: {sorted(every_tab_enum - set(sources))}")

# (G4) The local scan and everything it calls: nothing reaches the network, no embedding, no key, and no process except the one sqlite3
# read the scan skips (a Cursor pin read, behind `readCursorPins`, which the panel's search passes false). `loadCursorComposerNames`
# reads the Cursor state file through the sqlite3 library on this Mac: a local file, no process.
def helper_function(name):
    match = re.search(r"\n    (?:private )?static func " + name + r"\b", helper_lines)
    if match is None:
        failures.append(f"the scan's callee {name} is not in the helper")
        return ""
    rest = helper_lines[match.start() + 10:]
    nxt = re.search(r"\n    (?:private |fileprivate )?(?:static )?(?:func|let|var|struct|enum|final class|class) ", rest)
    return rest[:nxt.start()] if nxt else rest[:4000]

scan_callees = ["localSessionKeywordHits", "listSessionSearchTranscripts", "peekSessionSearchBody", "isRegularTranscript", "recentClaudeConversations", "recentCodexConversations",
                "recentCursorConversations", "loadClaudeDesktopIndex", "loadCursorComposerNames", "loadClaudeStarredIds", "loadCodexThreadNames", "loadCodexPinnedIds",
                "scoreSessionKeyword", "tokenizeSessionQuery", "peekClaudeDesktopHead", "lastCustomTitle", "firstClaudeUserTitle", "firstCursorUserTitle", "lastCursorUserTitle",
                "peekCodexMeta", "listCodexJsonlFiles", "cursorWorkingState", "workspaceLabel", "sessionSearchBodyChunk", "claudeMessageText"]
for callee in scan_callees:
    body = helper_function(callee)
    pin(len(body) > 40, f"read the scan's callee {callee}")
    for banned in ("URLSession", "request(", "speakerReviewToken", "readToken", "embedding", "openai", "Process()", "NSWorkspace", "/usr/bin/"):
        pin(banned.lower() not in body.lower(), f"the scan's callee {callee} never uses {banned}")
pin("Process()" in helper_function("loadCursorPinnedIds") and "readCursorPins ? loadCursorPinnedIds(" in helper_function("localSessionKeywordHits"),
    "the one process the scan can reach is the Cursor pin read, and only behind readCursorPins")


# ---- 0.5.362: meaning search --------------------------------------------------------------------------------------------------------

# The engine decides and the window only carries out: no defaults, no helper, no URL in it (the first pins above hold that), and the model a person
# agreed to is a closed set.
pin("case jev, subq" in core and "enum MeaningChoice: String, CaseIterable, Sendable { case ask, on, never }" in core, "the model and the choice are closed sets")
gate = block(core, "        static func consentedProvider(_ m: Meaning) -> MeaningProvider? {", "\n        }\n")
pin("guard m.offered, m.settled == nil, let provider = m.provider, m.choice == .on else { return nil }" in gate, "one gate: the server can, a key is saved, the person said yes for this model")
pin("var choice: MeaningChoice { provider.flatMap { choices[$0.rawValue] } ?? .ask }" in core, "the choice is read for the model that decides, never any model")
pin("next.provider = nil" in block(core, "        static func forgettingProvider(_ m: Meaning) -> Meaning {", "\n        }\n"), "a model that changed is forgotten")
pin("meaningAsk = meaningResult.ask" in core and "result.meaningAsk" in core, "the listing hands over the one request")

# The window: one find, fixed argument, words on stdin, the listed guard, the consent keys, one settings read.
find_fn = block(ext, "    func commandFindSessions(", "    func commandSearchAll(")
pin('model.runHelper(["agent-sessions-find"], timeout: 8, stdinData: data)' in find_fn and '"consentedProvider": .string(ask.provider.rawValue)' in find_fn and '"query": .string(ask.words)' in find_fn,
    "meaning search is one fixed verb, the words on stdin, with the model the person agreed to")
pin("ClaudeSession.listed(hit: hit, loaded: loaded, workSessionIDs: workIDs, runningWorkSessionIDs: runningIDs)" in find_fn and "model.workSessionIDs" in find_fn and "model.runningWorkSessionIDs" in find_fn,
    "a meaning row passes the server-hold guard the list rows have")
pin("compressed ? false : commandLeaves(session)" in find_fn and 'fields["compressed"]?.bool == true' in find_fn, "a compressed row is marked and leaves nothing")
open_fn = block(ext, "    func commandOpenHit(_ id: String) -> CommandEffect {", "    static func searchFailure(")
pin(before(open_fn, "commandKeys.hitSessions[id]", "commandKeys.meaningSessions[id]") and "meaningCompressed" in open_fn and "guard case .platform = way else" in open_fn,
    "a hit opens its own object, word hits first then meaning rows, and a compressed Codex row opens in the Codex app only")
pin("only the Codex app can open it" in open_fn and open_fn.count("only the Codex app can open it") == 2, "a compressed row says so when the Codex app does not open it")
open_center = block(ext, "    func openCommandCenter() {", "    func closeCommandCenter() {")
pin(open_center.count("loadDecisionSettings(quiet: true)") == 1 and "commandKeys.meaningSessions = [:]" in open_center, "one quiet settings read when the panel opens, and no meaning rows carried over")
pin(ext.count("loadDecisionSettings") == 2 and "reread: { await model.loadDecisionSettings(quiet: true) }" in ext, "the settings are read on open and again after a refusal that says the model changed, nowhere else")
pin("loadDecisionSettings" not in ticker_fn, "the tick reads no settings")
pin("decisionMessage" not in ext and "decisionSettings = nil" not in ext, "the panel never touches Settings' decision line")
choose = block(ext, "    func commandChooseMeaning(", "\n    }\n")
pin("TodayHome.setMeaningChoice(choice.rawValue, provider: provider.rawValue, .standard)" in choose and "return .stay" in choose and "words" not in choose, "the answer is stored for the model the row named, and the panel stays")
pin("case .consent(let provider, let choice): return commandChooseMeaning(provider, choice)" in row_run, "the question's rows are dispatched")
meaning_inputs = block(ext, "    func commandMeaning() -> SetupAssistant.Center.Meaning {", "\n    }\n")
pin('settings.effective["search"]' in meaning_inputs and "settings.canFindSessions" in meaning_inputs and "settings.configured[decides.rawValue] == true" in meaning_inputs and "TodayHome.meaningChoices(.standard)" in meaning_inputs,
    "meaning search reads the model that decides search, the capability by name, the saved key and the person's choices")
pin("version" not in meaning_inputs.lower(), "the capability is never read from a version")
# The panel: the request exists only when the engine hands it over, one at a time, nothing under a fixture.
mean_task = block(panel, "    private func runMeaning(", "    private func askMeaning(")
pin(".task(id: listing.meaningAsk) { await runMeaning(listing.meaningAsk) }" in panel and "guard fixture == nil else { return }" in mean_task and "guard let ask else {" in mean_task, "meaning search runs only on the engine's request, one at a time, and not under a fixture")
pin(before(mean_task, "Task.sleep(nanoseconds: 800_000_000)", "askMeaning(ask, stage: .first)", "Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))", "askMeaning(ask, stage: .full)") and "2.0 - Date().timeIntervalSince(began)" in mean_task,
    "the first stage after 800 ms, the full stage at 2 seconds of quiet in all")
pin(panel.count("try await find(") == 1 and "find: { ask, stage in try await commandFindSessions(ask, stage: stage) }" in ext, "the panel reaches meaning search only through the window's one function")
ask_fn = block(panel, "    private func askMeaning(", "    private func move(_ delta: Int) -> Bool {")
pin(before(ask_fn, "reason.againstConsent", "forgetting = true", "await reread()", "forgetting = false"), "a refusal that says the model changed forgets it, reads the settings again, and asks nothing meanwhile")
pin("if let reason = result.reason, reason.settles { settled = reason }" in ask_fn and "keys.meaningSessions = sessions.merging(" in ask_fn and "keys.hitSessions" not in ask_fn,
    "a refusal that stays true is remembered, and the meaning rows keep their own map")
pin("C.adoptingShownIDs(" in ask_fn and "C.adoptingShownIDs(hits.map(\\.item), shown: meaning.hits)" in panel_search, "a session on screen keeps its id whichever list found it second")
ann = [line.strip() for line in ask_fn.split("\n") if "Announcement(" in line]
pin(ann == ["if shown > 0, shown != before { AccessibilityNotification.Announcement(C.foundAnnouncement(shown)).post() }"], f"meaning rows announce a fixed count only: {ann}")
pin(".onChange(of: listing.rows.map(\\.id)) { _, _ in if let highlight { proxy.scrollTo(highlight) } }" in panel, "the highlight is followed when rows arrive")
pin("lineLimit(isConsent(row) ? nil : 2)" in panel, "the question draws every line of what leaves")
pin("inputs.meaning.settled = settled" in panel and "if forgetting { inputs.meaning = C.forgettingProvider(inputs.meaning) }" in panel, "the panel hands the engine what it remembers")
# Consent storage: in Models.swift beside the Today keys; never in the engine.
pin('static func meaningChoiceKey(_ provider: String) -> String { "activityTodayMeaning." + provider }' in models and "UserDefaults" not in core, "the choice is stored per model beside the Today keys, never by the engine")
pin('raw == "on" || raw == "never"' in models, "only on and never are stored; nothing is ask")
pin(read("Sources/ControllerModel.swift").count("func loadDecisionSettings(quiet: Bool = false) async {") == 1 and "guard decisionReadGeneration == generation, !quiet else { return }" in read("Sources/ControllerModel.swift"),
    "a quiet settings read leaves Settings' line and settings alone when it fails")
pin('"capabilities"' in helper and "sessionFind" in helper and "session-find-helper-checks.py" in read("Tests/run.sh"), "the helper carries the capability and its checks run in the suite")

pin("s.classicSettings = classicSettings" in window and "var classicSettings = false" in core, "the window passes the classic Settings flag")

if failures:
    for failure in failures:
        print("Setup assistant pin: " + failure, file=sys.stderr)
    sys.exit(1)
print(f"PASS: setup assistant pins, {passed} passed")
