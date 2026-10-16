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

# ── 1. Record: one click on the card, All Mac audio, the panel's confirm kept everywhere else.
suggested = body(recording, "    func startFromMeetingSuggestion(title meetingTitle: String, bridge: @escaping Bridge) async -> String? {")
need(suggested.index("selectedID = MacAudioSource.allMacAudioID") < suggested.index("await start()"),
     "the card records All Mac audio (the proven source), never a per-app tap")
need("selectedID" not in body(app, "meetings.record = {") and ".pid" not in suggested,
     "nothing on the card path picks an app's tap")
starts = [(name, m.start()) for name, src in sources.items() for m in re.finditer(r"(?:store|macRecording|\bself)\.start\(\)|await start\(\)", src)]
need(len(starts) == 2, f"Mac recording starts from exactly two places (the panel's confirm and the card), found {starts}")
panel = body(recording, "struct MacRecordingPanel: View {")
confirm = panel[panel.index('.confirmationDialog("Record this Mac’s audio?"'):]
need("Task { await store.start() }" in confirm and panel.count("store.start()") == 1,
     "the panel starts only from its confirm dialog")
need(sum(src.count("startFromMeetingSuggestion(") for src in sources.values()) == 2
     and "model.macRecording.startFromMeetingSuggestion(title: MeetingSuggestion.title(source, at: Date()), bridge: model.macRecordingBridge)" in app,
     "the confirm-free start is called only from the meeting card's record closure")
record_ui = body(detector, "    func recordSuggested() {")
need("guard let current = card, current.kind == .suggest else { return }" in record_ui and "await record?(current.source)" in record_ui,
     "Record acts only on a showing suggestion")
need(sum(src.count("recordSuggested()") for src in sources.values()) == 2 and 'Button("Record") { store.recordSuggested() }' in recording,
     "recordSuggested runs only from the card's Record button")
need("guard available, canStart, recoverable.isEmpty else {" in suggested, "the card never starts over a pending or recoverable recording")

# ── 2. Never auto-stop.
need(detector.count("stopRecording?()") == 1 and "stopRecording?()" in body(detector, "    func stopAndSave() {"),
     "the detector stops a recording only in Stop and save")
need(sum(src.count("stopAndSave()") for src in sources.values()) == 2 and 'Button("Stop and save") { store.stopAndSave() }' in recording,
     "Stop and save is the card's button, nothing else")
need(".stop()" not in detector and "macRecording.stop()" not in body(app, "meetings.record = {"),
     "no detector path calls the recording's stop")
need("guard next.kind == .suggest else { return }" in body(detector, "    private func show(_ next: MeetingCard) {"),
     "the end offer waits for an answer; only the suggestion folds away")
need("MeetingSuggestion.offersEnd(" in body(detector, "    private func handle(_ event: MeetingDetectionState.Event) {"),
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
    need(re.findall(r"\\\(([^)]*)", line) in ([], ["source.app.title, privacy: .public"], ["current.source.app.title, privacy: .public"]),
         f"detector logs name the app only: {line}")
browser = body(detector, "    nonisolated private static func browserShowsMeet(_ owner: String) -> Bool? {") if "nonisolated private static func browserShowsMeet" in detector else body(detector, "    private static func browserShowsMeet(_ owner: String) -> Bool? {")
need("guard AXIsProcessTrusted() else { return nil }" in browser and "MeetingApps.showsMeet(titles)" in browser and "Log" not in browser,
     "browser titles need Accessibility, are matched by the tested rule, and are never logged")
need(core.count("static let rules: [Rule] = [") == 1 and sum(src.count("us.zoom.") for src in sources.values()) == core.count("us.zoom."),
     "the meeting app table lives in one place")

# ── 4. Gates and wiring.
busy = body(app, "meetings.recordingBusy = {")
need("MeetingSuggestion.recordingBusy(macOccupied: model.macRecording.occupied, macCanStart: model.macRecording.canStart," in busy
     and "recoverable: model.macRecording.recoverable.count, liveRecordings: model.recordingCount)" in busy,
     "busy covers active, pending, recoverable and live recordings")
need("meetings.dictating = { [weak model] in model?.dictation.busy ?? false }" in app, "dictation defers the card")
need("await model?.macRecording.refreshRecoverable()" in app and "meetings.activate()" in app, "recoverable is read before the first suggestion")
need("if meetings.surface == .pet, let card = meetings.card {\n                MeetingCardView(store: meetings, card: card, size: size)" in pet
     and "MeetingDetectorStore.shared.$card.map { $0?.id }.removeDuplicates()" in pet, "the card rides the pet and re-fits it")
need("guard let store, store.surface == .floating, let card = store.card else {" in recording and "styleMask: [.borderless, .nonactivatingPanel]" in recording,
     "with the pet hidden the card floats, never taking focus")
need("MeetingSuggestSettings(store: MeetingDetectorStore.shared)" in views and 'forKey: "meetingSuggest.enabled") as? Bool ?? true' in detector,
     "Suggest recording when a meeting starts: in Settings, on by default")
need('Text("Google Meet in a browser needs Accessibility' in recording, "Settings says when browser detection is skipped")

print(f"PASS meeting-detect pins: {checks} checks; card-only confirm-free start on All Mac audio, never auto-stop, listeners and bounded ticks, app-name-only logs, gates")
