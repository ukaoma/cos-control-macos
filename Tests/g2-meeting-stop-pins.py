#!/usr/bin/env python3
"""0.5.321: wiring pins for Stop and save on a glasses meeting (G2MeetingStop in Sources/LiveTranscript.swift).

The decisions run in Tests/G2MeetingStopChecks.swift. These pin what a SwiftUI view or the helper does, which that
check cannot execute: every Stop and save button only opens the inline confirmation, the stop runs only from the
confirmation's action, the model asks through the helper and never saves a live glasses meeting from the Mac.
Prints "g2 meeting stop pins: N passed". Usage: g2-meeting-stop-pins.py <checkout>
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
passed = 0


def check(condition, what):
    global passed
    if not condition:
        print(f"g2 meeting stop pin FAILED: {what}")
        sys.exit(1)
    passed += 1


def read(rel):
    return (root / rel).read_text()


def body(src, start, end):
    i = src.index(start)
    j = src.index(end, i + len(start))
    return src[i:j]


pane = read("Sources/ActivityMeetings.swift")
panel = read("Sources/Views.swift")
model = read("Sources/ControllerModel.swift")
helper = read("HelperSources/main.swift")
sources = {p.name: p.read_text() for p in (root / "Sources").glob("*.swift")}

# The buttons only ask for the confirmation.
check(pane.count("Button(G2MeetingStop.buttonLabel) { confirmGlassesStop = true }") == 1, "the live pane's button opens its confirmation")
check(panel.count("Button(G2MeetingStop.buttonLabel) { glassesStopTarget = id }") == 1, "the panel's button opens its confirmation")
check(pane.count("Button(G2MeetingStop.buttonLabel) { glassesStopTarget = row.sessionId }") == 1, "the Live now row's button opens its confirmation")
check(sum(s.count("Button(G2MeetingStop.buttonLabel)") for s in sources.values()) == 3, "exactly three Stop and save buttons for glasses meetings")

# The stop runs only from a confirmation's destructive action.
calls = [(name, m.start()) for name, s in sources.items() for m in re.finditer(r"stopGlassesMeeting\(", s)
         if not s[max(0, m.start() - 5):m.start()].endswith("func ")]
check(len(calls) == 3, f"stopGlassesMeeting has exactly three call sites, found {len(calls)}")
for name, at in calls:
    before = sources[name][max(0, at - 220):at]
    check(".destructive(G2MeetingStop.confirmAction) {" in before, f"{name}: the stop runs inside the confirmation's action")
check(pane.count(".cosConfirm(G2MeetingStop.confirmTitle, isPresented: $confirmGlassesStop, message: G2MeetingStop.confirmMessage") == 1,
      "the live pane uses COSConfirm, inline")
check(re.search(r"\.cosConfirm\(\s*G2MeetingStop\.confirmTitle,\s*isPresented: Binding\(get: \{ glassesStopTarget != nil \}", panel) is not None,
      "the panel uses COSConfirm, inline")
check(re.search(r"\.cosConfirm\(G2MeetingStop\.confirmTitle, isPresented: Binding\(get: \{ glassesStopTarget != nil \}", pane) is not None,
      "the Live now rows use COSConfirm, inline")
# 0.5.321 adds no confirmationDialog: the three in ActivityMeetings.swift predate it (Activity window, not the panel).
check(pane.count(".confirmationDialog(") == 3 and ".confirmationDialog(" not in panel, "no new confirmationDialog")
check("} else if row.phase == .live, G2MeetingStop.isGlassesSession(row.sessionId) {" in pane,
      "the Live now row offers it only while the glasses meeting is live and the quiet-capture End is not offered")

# Where it shows: a live glasses meeting only.
check("if let id = model.liveTranscriptOpenID, G2MeetingStop.isGlassesSession(id), feed?.ended != true {" in pane,
      "the pane offers it only on a live glasses meeting")
check("let live = liveTranscriptRows.filter { $0.phase == .live && G2MeetingStop.isGlassesSession($0.sessionId) }" in model
      and "return live.count == 1 ? live[0].sessionId : nil" in model, "the panel offers it only for the one live glasses meeting")
check("model.glassesMeetingStopLine(model.liveTranscriptOpenID)" in pane, "the pane shows the stop's words")
check("model.glassesMeetingStopLine(model.glassesMeetingStop?.sessionId)" in panel, "the panel shows the stop's words")

# The model asks the glasses; it never saves a live glasses meeting itself.
follow = body(model, "private func followGlassesMeetingStop(", "    func saveAllStranded() {")
check(follow.count('helper.run(["meeting-stop-request", "--session", sessionId]') == 1, "one ask")
check(follow.count('helper.run(["meeting-stop-request", "--session", sessionId, "--request", requestId]') == 1, "one poll")
check("meeting-stranded-save" not in follow and "/api/meeting/save" not in follow, "no save from the Mac")
check("G2MeetingStop.afterRequest(first?.details)" in follow and "G2MeetingStop.afterPoll(polled?.details" in follow, "the words come from G2MeetingStop")
start = body(model, "func stopGlassesMeeting(_ sessionId: String) {", "private func followGlassesMeetingStop(")
check("guard G2MeetingStop.isGlassesSession(sessionId), glassesMeetingStop?.phase.isActive != true else { return }" in start,
      "one stop at a time, glasses sessions only")

# The helper.
check(helper.count('case "meeting-stop-request": try emitMeetingStopRequest(args: args)') == 1, "the helper verb is dispatched once")
path = body(helper, "static func meetingStopRequestPath(", "private func emitMeetingStopRequest(")
check('!sessionId.hasPrefix("mac_")' in path, "the helper refuses a Mac recording")
check('"/api/meeting/sessions/\\(sessionId)/stop-request/\\(requestId)"' in path and '"/api/meeting/sessions/\\(sessionId)/stop-request"' in path,
      "the helper reaches only the stop-request routes")
emit = body(helper, "private func emitMeetingStopRequest(", "private func emitMeetingStrandedSave(")
check('details: ["transport": "unavailable"]' in emit, "no answer is reported as unavailable, never as a stop")
check("/api/meeting/save" not in emit, "the helper never saves from this verb")

# The Mac recording's own Stop and save is unchanged (0.5.321 leaves it; not a one-line change).
check(sum(s.count('Button("Stop and save") { Task { await model.macRecording.stop() } }') for s in sources.values()) == 2,
      "the Mac recording's Stop and save buttons are unchanged")

print(f"g2 meeting stop pins: {passed} passed")
