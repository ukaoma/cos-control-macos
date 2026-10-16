#!/usr/bin/env python3
"""0.5.313 meeting detection and the record suggestion: wiring pins the executable checks cannot see.

Text only (no compile), over COMMENT-STRIPPED code. Tests/MacRecordingChecks.swift executes the pure rules (the app
table, Meet titles, the 10 s / 60 s state machine, once per meeting, busy and dictation gates, the end offer); this
pins that the app routes through them, records only on the card's click with All Mac audio, and never stops on its own.
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
checks = 0


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    out = []
    for line in src.splitlines():
        cut, quoted, i = None, False, 0
        while i < len(line) - 1:
            ch = line[i]
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                quoted = not quoted
            elif ch == "/" and line[i + 1] == "/" and not quoted:
                cut = i
                break
            i += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


def read(name: str) -> str:
    return strip_comments((root / name).read_text(encoding="utf-8"))


def need(condition: bool, message: str) -> None:
    global checks
    if not condition:
        sys.exit(f"meeting-detect: {message}")
    checks += 1


def body(src: str, opener: str) -> str:
    start = src.index(opener)
    depth, i, seen = 0, start, False
    while i < len(src):
        if src[i] == "{":
            depth += 1; seen = True
        elif src[i] == "}":
            depth -= 1
            if seen and depth == 0:
                return src[start:i + 1]
        i += 1
    return src[start:]


recording = read("Sources/MacRecording.swift")
core = read("Sources/MacRecordingCore.swift")
app = read("Sources/COSControlApp.swift")
model = read("Sources/ControllerModel.swift")
pet = read("Sources/SessionPet.swift")
views = read("Sources/Views.swift")
sources = {p.name: strip_comments(p.read_text(encoding="utf-8")) for p in (root / "Sources").glob("*.swift")}
detector = body(recording, "@MainActor final class MeetingDetectorStore: ObservableObject {")

# ── 1. Record: every start through ONE gated function; the one-time notice; All Mac audio from the card.
suggested = body(recording, "    func startFromMeetingSuggestion(title meetingTitle: String, bridge: @escaping Bridge) async -> String? {")
need("await record(title: meetingTitle, sourceID: MacAudioSource.allMacAudioID, bridge: bridge)" in suggested,
     "the card records All Mac audio (the proven source), never a per-app tap")
need("selectedID" not in body(app, "meetings.record = {"), "nothing on the card path picks an app's tap")
gate = body(recording, "    func record(title chosen: String, sourceID: UInt32, bridge: @escaping Bridge) async -> String? {")
need(gate.index("guard MacRecordingNotice.step(acknowledged: noticeAcknowledged) == .start else { return nil }") < gate.index("await start()")
     and gate.index("selectedID = sourceID; title = chosen") < gate.index("await start()"),
     "record() refuses until the notice was acknowledged, then starts the chosen source")
start = body(recording, "    private func start() async {")
need(start.split("\n")[1].strip() == "guard noticeAcknowledged else { return }", "start() itself refuses an unacknowledged first recording")
starts = [(name, m.start()) for name, src in sources.items() for m in re.finditer(r"(?:store|macRecording|\bself)\.start\(\)|await start\(\)", src)]
need(len(starts) == 1, f"Mac recording starts from exactly one place, record(), found {starts}")
records = [(name, m.group(0)) for name, src in sources.items() for m in re.finditer(r"(?:store\.|await )record\(title:", src)]
need(len(records) == 2, f"record() is reached from Meetings' Record and the card only, found {records}")
need(sum(src.count("startFromMeetingSuggestion(") for src in sources.values()) == 2
     and "model.macRecording.startFromMeetingSuggestion(title: MeetingDetectedCard.title(source, at: Date()), bridge: model.macRecordingBridge)" in app,
     "the card's start is called only from the meeting card's record closure")
for alert in (".confirmationDialog(", "NSAlert", ".alert(", "Record this Mac’s audio?"):
    need(alert not in recording, f"no stock alert for a recording start: {alert}")
need(sum(src.count('"Record this Mac') for src in sources.values()) == 1 and 'static let title = "Record this Mac\'s audio"' in core,
     "the notice's words live in one place")
panel = body(recording, "struct MacRecordingPanel: View {")
need('Button("Record") { record() }.buttonStyle(COSPrimaryButtonStyle())' in panel and "Start recording" not in panel and "Set up recording" not in panel,
     "Meetings has one primary Record")
need("@AppStorage(MacRecordingNotice.optionsExpandedKey) private var optionsExpanded = false" in panel, "Options is collapsed until opened, remembered")
options = panel[panel.index('DisclosureGroup("Options", isExpanded: $optionsExpanded) {'):]
options = options[:options.index(".font(COSType.body(11))")]
need("TextField(automaticTitle, text: $store.title)" in options and 'COSDropdown("Audio source"' in options and 'Button("Refresh apps")' in options,
     "title, audio source and Refresh apps sit under Options")
panel_record = body(panel, "    private func record() {")
need(panel_record.index("guard MacRecordingNotice.step(acknowledged: store.noticeAcknowledged) == .start else { showingNotice = true; return }")
     < panel_record.index("store.record(title:")
     and "MacRecordingNotice.title(typed: store.title, meetingApp: meetings.current?.app.title, at: Date())" in panel_record,
     "Meetings' Record shows the notice first time, and titles the recording automatically")
need(sum(src.count("acknowledgeNotice()") for src in sources.values()) == 3
     and "store.acknowledgeNotice(); showingNotice = false; record()" in panel
     and "meetings.acknowledgeNotice = { [weak model] in model?.macRecording.acknowledgeNotice() }" in app,
     "the notice is acknowledged only by its own Record (panel and pet)")
need("acknowledgeNotice?()" in body(detector, "    func recordAfterNotice() {") and detector.count("acknowledgeNotice?()") == 1,
     "the pet acknowledges only from the notice card")
record_ui = body(detector, "    func recordSuggested() {")
need("guard let current = card, current.kind == .suggest else { return }" in record_ui
     and "guard MacRecordingNotice.step(acknowledged: noticeAcknowledged?() ?? false) == .start else {" in record_ui
     and "show(MeetingCard(kind: .notice, source: current.source))" in record_ui,
     "the pet's Record shows the same one-time notice first")
need("await record?(current.source)" in body(detector, "    private func startRecording(_ current: MeetingCard) {"), "the pet records through the record closure")
need(sum(src.count("recordSuggested()") for src in sources.values()) == 2 and 'Button("Record") { store.recordSuggested() }' in recording,
     "recordSuggested runs only from the card's Record button")
need("guard available, canStart else {" in gate and "recoverable" not in gate.split("guard available, canStart else {")[1].split("}")[0],
     "Record never starts over a pending recording, and a retained (recoverable) capture never blocks it (QA 2026-10-15)")
need(sum(src.count("MacRecordingNotice.reminder") for src in sources.values()) == 3, "Recording · let people know on the panel, menu and pet-panel rows")
settings = body(recording, "struct MeetingSuggestSettings: View {")
need("if let recording { recording.resetNotice() } else { acknowledged = false }" in settings
     and sum(src.count(".resetNotice()") for src in sources.values()) == 1,
     "Settings' Show the recording notice again calls the store's resetNotice, so every view reading it updates")

# ── 1b. QA 0.5.313: refusal text by cause, the panel notice follows the acknowledgement, the Recover list, telemetry.
need("switch MacRecordingRefusal.decide(available: available, currentError: error, live: occupied, pendingCapture: pendingCapture) {" in gate
     and "case .keep: break" in gate and "case .set(let text): error = text" in gate and 'error = "A Mac recording is waiting' not in gate,
     "Record's refusal says the real cause and never paints a live recording red")
need("MacRecordingNotice.panelShowsNotice(requested: showingNotice, acknowledged: acknowledged, occupied: store.occupied)" in panel
     and "if noticeVisible {" in panel and "if showingNotice {" not in panel,
     "the panel's notice hides once acknowledged anywhere or once a recording runs")
need("ForEach(MacRecordingRecoveryPolicy.listed(store.recoverable, current: store.manifest?.captureId)) { value in" in panel
     and "store.recoverable.filter" not in panel, "a zero-chunk journal is never offered to Recover (and never deleted)")
for event in ("prepare failed:", "record refused:", "append failed:", "capture failed:", "start ok", "start failed:", '"stop"',
              "markStopped failed:", "save ok", "recover failed:", "keep for later failed:"):
    need(event in recording.split("struct MacRecordingPanel: View {")[0], f"recording telemetry: {event}")
need('recordingLog.error("meeting card start failed app=' in detector
     and re.search(r'case \.skipped\(let source, let reason\):\s*recordingLog\.notice\("meeting not offered app=', detector) is not None,
     "the detector logs a failed card start and a suggestion skipped while busy")

# ── 2. Never auto-stop.
need(detector.count("stopRecording?()") == 1 and "stopRecording?()" in body(detector, "    func stopAndSave() {"),
     "the detector stops a recording only in Stop and save")
need(sum(src.count("stopAndSave()") for src in sources.values()) == 2 and 'Button("Stop and save") { store.stopAndSave() }' in recording,
     "Stop and save is the card's button, nothing else")
need(".stop()" not in detector and "macRecording.stop()" not in body(app, "meetings.record = {"),
     "no detector path calls the recording's stop")
need("guard next.kind != .ended else { return }" in body(detector, "    private func show(_ next: MeetingCard) {"),
     "the end offer waits for an answer; only the suggestion folds away")
need("MeetingDetectedCard.offersEnd(" in body(detector, "    private func handle(_ event: MeetingDetectionState.Event) {"),
     "the end offer goes through the tested rule")
need("if !active { MeetingDetectorStore.shared.recordingStopped() }" in model, "a recording stopped any other way clears the end offer")

# ── 3. Detection: CoreAudio process objects, listeners, a 2 s tick only while it matters, no screen reading.
need("kAudioHardwarePropertyProcessObjectList" in detector and "kAudioProcessPropertyIsRunningInput" in detector
     and detector.count("AudioObjectAddPropertyListenerBlock(") == 2, "listeners on the process list and on each process's input")
tick = body(detector, "    private func scheduleTick() {")
need("let needed = state.wantsTicks || listenersUnavailable" in tick and ".seconds(2)" in tick and ".seconds(1)" not in tick,
     "a 2 s tick, only while a meeting app holds the mic, a meeting has not ended, or listeners are unavailable")
need("MeetingApps.holding(" in detector and "state.step(holding: found.sources" in detector, "detection goes through the tested table and state machine")
need(all(s not in detector for s in ("CGWindowList", "SCShareableContent", "SCStream", "CGDisplayCreateImage")), "no screen reading")
for line in re.findall(r"recordingLog\.\w+\(\"[^\n]*", detector):
    need(re.findall(r"\\\(([^)]*)", line) in ([], ["source.app.title, privacy: .public"], ["current.source.app.title, privacy: .public"],
                                                ["source.app.title, privacy: .public", "reason, privacy: .public"]),
         f"detector logs name the app only: {line}")
reader = body(detector, "    private func readTitles(_ owner: String) {")
titles = body(detector, "    nonisolated private static func windowTitlesShowMeet(pid: pid_t) async -> Bool {")
need("guard AXIsProcessTrusted() else { titleCache[owner] = .some(nil); return }" in reader and "guard !titleReads.contains(owner) else { return }" in reader
     and "await Self.windowTitlesShowMeet(pid: pid)" in reader, "titles need Accessibility, one read per browser at a time, off the main actor")
need(titles.count("AXUIElementSetMessagingTimeout(") == 2 and "AXUIElementSetMessagingTimeout(window, 0.25)" in titles
     and "list.prefix(40)" in titles and "Date().timeIntervalSince(started) < 1" in titles and "MeetingApps.showsMeet(titles)" in titles
     and "Log" not in titles, "every AX element bounded at 0.25 s, 40 windows, about 1 s; matched by the tested rule, never logged")
evaluate = body(detector, "    private func evaluate(_ ids: [AudioObjectID]) {")
need("latched: browserLatch) { owner in" in evaluate and "browserLatch = found.latched" in evaluate
     and "MeetingApps.titleReadDue(holdersChanged: holdersChanged, cached: cached != nil, tick: tick)" in evaluate
     and "windowTitlesShowMeet" not in evaluate,
     "a Meet tab latched while on the mic; titles read only when due, never inline on the main actor")
need(core.count("static let rules: [Rule] = [") == 1 and sum(src.count("us.zoom.") for src in sources.values()) == core.count("us.zoom."),
     "the meeting app table lives in one place")

# ── 4. Gates and wiring.
busy = body(app, "meetings.recordingBusy = {")
need("MeetingDetectedCard.recordingBusy(macOccupied: model.macRecording.occupied, macCanStart: model.macRecording.canStart," in busy
     and "liveRecordings: model.recordingCount)" in busy and "recoverable" not in busy,
     "busy covers active, pending and live recordings; a retained capture is not busy")
need("model.openActivity?(.meetings)" in body(app, "meetings.record = {"), "a failed Record from the pet card opens Meetings, so a hidden pet never swallows it")
need("meetings.dictating = { [weak model] in model?.dictation.busy ?? false }" in app, "dictation defers the card")
need("await model?.macRecording.refreshRecoverable()" in app and "meetings.activate()" in app, "recoverable is read before the first suggestion")
need("if meetings.surface == .pet, let card = meetings.card {\n                MeetingCardView(store: meetings, card: card, size: size)" in pet
     and "MeetingDetectorStore.shared.$card.map { $0?.id }.removeDuplicates()" in pet, "the card rides the pet and re-fits it")
need("guard let store, store.surface == .floating, let card = store.card else {" in recording and "styleMask: [.borderless, .nonactivatingPanel]" in recording,
     "with the pet hidden the card floats, never taking focus")
need("MeetingSuggestSettings(store: MeetingDetectorStore.shared)" in views and 'forKey: "meetingSuggest.enabled") as? Bool ?? true' in detector,
     "Suggest recording when a meeting starts: in Settings, on by default")
need('Text("Google Meet in a browser needs Accessibility' in recording, "Settings says when browser detection is skipped")

print(f"PASS meeting-detect pins: {checks} checks; one gated start behind the one-time inline notice, Options collapsed, All Mac audio from the card, never auto-stop, listeners and bounded ticks, app-name-only logs, gates")
