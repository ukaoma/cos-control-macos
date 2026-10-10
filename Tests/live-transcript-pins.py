#!/usr/bin/env python3
"""0.5.278 live meeting transcript: the wiring pins. python3 Tests/live-transcript-pins.py [root]

What these pin that no executed check can see from outside: the secret boundary (no transcript text near a log, print,
stderr progress, error text or report), the setting gating every helper spawn, the didWake observer, the route flag's
writers, the row's place in Meetings, the Settings toggle placed once, the compile lists, and the UI copy (no em dashes
or arrows). Prints "live transcript pins: N passed".
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
passed = 0


def code(rel):
    return (root / rel).read_text()


def need(condition, what):
    global passed
    if not condition:
        print("live transcript pin FAILED: " + what)
        sys.exit(1)
    passed += 1


def section(text, start, end_marker="\n    // MARK: "):
    i = text.index(start)
    j = text.find(end_marker, i + len(start))
    return text[i:j if j >= 0 else len(text)]


def body(text, signature):
    i = text.index(signature)
    depth, j, started = 0, i, False
    while j < len(text):
        if text[j] == "{":
            depth += 1; started = True
        elif text[j] == "}":
            depth -= 1
            if started and depth == 0:
                return text[i:j + 1]
        j += 1
    raise SystemExit("unterminated " + signature)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


helper = code("HelperSources/main.swift")
model = code("Sources/ControllerModel.swift")
pure = code("Sources/LiveTranscript.swift")
meetings = code("Sources/ActivityMeetings.swift")
window = code("Sources/ActivityWindow.swift")
views = code("Sources/Views.swift")
models = code("Sources/Models.swift")

# ── The helper verbs and their secret boundary.
need('case "live-transcript": try emitLiveTranscript(args: args)' in helper, "the helper dispatches live-transcript")
need('case "live-transcript-status": try emitLiveTranscriptStatus(args: args)' in helper, "the helper dispatches live-transcript-status")
helper_live = strip_comments(section(helper, "    // MARK: - Live meeting transcript (0.5.278)", "    // End of the live meeting transcript (0.5.278)."))
for banned, why in (("progress(", "stderr progress"), ("print(", "print"), ("FileHandle.standardError", "stderr"), ("NSLog", "NSLog"),
                    ("appendHelperLog", "the helper log"), ("helperLog", "the helper log"), ("fputs", "stderr"), ("debugPrint", "print")):
    need(banned not in helper_live, "the helper's live transcript code never writes to " + why + " (" + banned + ")")
need("providerCandidates" not in helper_live, "the helper's live transcript code never reads providerCandidates")
need('object["chunksIndexed"]' in helper_live and 'object["chunks"]' not in helper_live, "the helper reads chunksIndexed, never the dense chunks array")
need("open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)" in helper_live and "fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG" in helper_live,
     "the session file is opened with O_NOFOLLOW and checked with fstat on the descriptor it reads")
need("return liveTranscriptContained(file, in: dir) ? file.standardizedFileURL : nil" in helper_live, "the resolved session path must sit directly in active-sessions")
need('for name in names where name.hasSuffix(".json") {' in helper_live and "guard liveTranscriptValidId(id)" in helper_live,
     "the list keeps only <id>.json names in the grammar (the server's temp files fail both)")
need('"liveTranscriptionSessions": maintenance?["liveTranscriptionSessions"] ?? NSNull()' in helper, "status forwards the server's live count")
need('"staleTranscriptionSessionIds": Self.staleTranscriptionSessionIds(maintenance?["staleTranscriptionSessionDetail"])' in helper,
     "status forwards the server's stale session ids")
need('liveTranscriptionSessions = details["liveTranscriptionSessions"]?.int' in models
     and 'staleTranscriptionSessionIds = (details["staleTranscriptionSessionIds"]?.array ?? []).compactMap(\\.string)' in models,
     "the status model reads both")
report = body(helper, "func redactedReport(") + body(helper, "func doctorDetails(")
need("active-sessions" not in report and "chunksIndexed" not in report and "liveTranscriptRead" not in report and "liveTranscriptList" not in report,
     "Copy Report never reads the live session files")

# ── The model: the setting gates every spawn, and no text reaches a log or an error.
model_live = strip_comments(section(model, "    // MARK: - Live meeting transcript (0.5.278)", "\n    /// 0.5.227. Is live meeting audio"))
for banned, why in (("Log.", "a Logger"), ("Logger(", "a Logger"), ("NSLog", "NSLog"), ("print(", "print"), ("debugPrint", "print"),
                    ("localizedDescription", "an error's description"), ("String(describing: error)", "an error's description"),
                    ("self.error =", "the alert"), (" error = ", "the alert"), ("notice =", "the notice"), ("fputs", "stderr")):
    need(banned not in model_live, "the model's live transcript code never sends anything to " + why + " (" + banned + ")")
poll = body(model, "func pollLiveTranscriptOnce() async {")
need(poll.split("\n")[1].strip() == "guard liveTranscriptEnabled else { return }", "the poll's first line refuses when the setting is off")
need(poll.index("guard liveTranscriptEnabled else { return }") < poll.index("helper.run("), "the setting is read before the helper is spawned")
handoffs = body(model, "func checkLiveTranscriptHandoffs(now: Date) async {")
need(handoffs.split("\n")[1].strip() == "guard liveTranscriptEnabled else { return }", "the hand-off check refuses when the setting is off")
kick = body(model, "func liveTranscriptKick() {")
need("guard liveTranscriptTask == nil, liveTranscriptShouldPoll else { return }" in kick, "one loop at a time, and only when it should poll")
need("LiveTranscript.shouldPoll(enabled: liveTranscriptEnabled," in model_live, "should-poll includes the setting")
need(model_live.count("helper.run(") == 2, "the live transcript spawns the helper in exactly two places (the poll and the status)")
need("guard liveTranscriptEnabled else { return [] }" in body(model, "var liveTranscriptRows: [LiveTranscriptRow] {"), "the setting off shows no row")
need("liveTranscriptEnabled && (liveTranscriptServerLive ?? 0) > 0" in model_live, "the dot needs the setting and the server's live count")
need("Self.liveTranscriptReasonCode(error)" in poll and "LiveTranscript.reasonCode(fromMessage: message)" in model_live,
     "a failed poll keeps a reason code")
need('case .invalidResponse: return "invalid_response"' in model_live, "an invalid response (it carries helper output) becomes a code")
init_block = body(model, "init(startBackgroundWork: Bool = true, allowActivityLoads: Bool = false, helper: HelperClient = HelperClient()) {")
need("NSWorkspace.didWakeNotification" in init_block and "self?.liveTranscriptWoke()" in init_block, "didWake re-reads the live transcript now")
need("liveTranscriptKick()" in body(model, "func refresh(quiet: Bool = false) async {"), "a status refresh can start the poll")
need(len(re.findall(r"liveTranscriptOpenID = ", model)) == 3, "the route flag is written by open, close and the setting off only")
need("Self.liveTranscriptMatches($0, sessionId: sessionId)" in model_live
     and "meeting.sessionId == sessionId || meeting.g2SessionIds.contains(sessionId)" in model_live
     and "filename" not in body(model, "nonisolated static func liveTranscriptMatches("), "the saved meeting is found by session id, never by filename")
need("model?.liveTranscriptWindowClosed()" in window, "closing Activity stops the live poll")

# ── The pure layer prints nothing.
pure_code = strip_comments(pure)
for banned in ("print(", "NSLog", "Logger", "fputs", "os_log"):
    need(banned not in pure_code, "Sources/LiveTranscript.swift never logs (" + banned + ")")
need("import Foundation" in pure and "import SwiftUI" not in pure and "import AppKit" not in pure, "Sources/LiveTranscript.swift is pure Foundation")

# ── The views.
live_views = strip_comments(meetings[meetings.index("// MARK: - Live meeting transcript (0.5.278)"):])
for banned in ("print(", "NSLog", "Logger", "Markdown"):
    need(banned not in live_views, "the live views never log or parse Markdown (" + banned + ")")
library = body(meetings, "struct MeetingLibraryBody: View {")
lib_body = body(library, "var body: some View {")
need("if !selectionOnly && showLiveTranscript {\n                LiveNowRows(model: model)" in lib_body, "the live row is hidden in the picker and when the setting is off")
need(lib_body.index("LiveNowRows(model: model)") < lib_body.index("if !model.isLibraryQueryActive {")
     < lib_body.index("MeetingMonthCalendar("), "the live row is pinned above the calendar, outside the search branch")
need('model.liveTranscriptViewer("meetings", visible: true)' in lib_body and 'model.liveTranscriptViewer("meetings", visible: false)' in lib_body,
     "Meetings registers as a viewer while it is on screen")
pane = body(meetings, "struct LiveTranscriptPane: View {")
need("LiveTranscript.header" in pane and 'Button("Copy transcript") { model.copyLiveTranscript() }' in pane and 'Button("Jump to live")' in pane,
     "the pane has the preliminary header, Copy transcript and Jump to live")
need(".frame(minWidth: 420, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .top)" in pane, "the pane has a flexible frame with a floor")
need("ForEach(feed.turns)" in pane and "LazyVStack" in pane, "turns are lazy and keyed by their first index")
need("Text(verbatim: turn.text)" in meetings and "Text(verbatim: turn.speaker)" in meetings and "COSPalette.muted" in body(meetings, "struct LiveTurnRow: View {"),
     "turn text is plain text and speaker names are muted")
need('} else if section == .meetings, model.liveTranscriptRouteActive {\n                    LiveTranscriptPane(model: model)' in window,
     "Activity mounts the pane under its own route flag")
need(window.index("} else if section == .meetings, selectedLibraryRecordID != nil {") < window.index("LiveTranscriptPane(model: model)"),
     "a meeting a person opened wins over the live pane")
need("|| model.liveTranscriptRouteActive" in window and "model.closeLiveTranscript()" in window, "the pane counts as a detail and Back closes it")
need("if item == .meetings, showLiveTranscript, model.liveTranscriptDot {" in window, "the lens rail Meetings tab carries the live dot")
need("if item == .meetings, showLiveTranscript, model.liveTranscriptDot {" in views, "the panel Meetings chip carries the live dot")
sources = "".join(p.read_text() for p in (root / "Sources").glob("*.swift"))
need(sources.count('Toggle("Show live meeting transcript"') == 1 and 'Toggle("Show live meeting transcript", isOn: $showLiveTranscript)' in views,
     "the Settings toggle is placed once, in Views.swift (the ControlPanel is shared)")
need("model.liveTranscriptSettingChanged()" in views, "the toggle tells the model")
for rel, text in (("Sources/Views.swift", views), ("Sources/ActivityWindow.swift", window), ("Sources/ActivityMeetings.swift", meetings)):
    need("@AppStorage(LiveTranscript.enabledKey)" in text, rel + " reads the setting from AppStorage")
need('static let enabledKey = "cos.liveTranscriptEnabled"' in pure, "one AppStorage key")

# ── UI copy: no em dashes or arrows in anything the live transcript shows.
ui_text = pure + live_views + "\n".join(l for l in views.split("\n") if "live" in l.lower())
for glyph, name in (("—", "em dash"), ("–", "en dash"), ("→", "arrow"), ("←", "arrow"), ("->\"", "arrow"), ("=>", "arrow")):
    strings = re.findall(r'"(?:[^"\\]|\\.)*"', ui_text)
    need(not any(glyph in s for s in strings), "no " + name + " in a live transcript UI string")
for literal in ("Live transcript · preliminary · may change when saved", "COS preliminary transcript", "No audio for", "Recording ended without saving",
                "Saved meeting not found yet", "Finalizing", "Jump to live", "Copy transcript", "Live now"):
    need(literal in pure + meetings, "the copy says " + literal)

# ── Every whole-app compile list carries the new file.
for rel in ("Tests/run.sh", "scripts/build-release.sh", "Tests/run-held-ui.sh", "Tests/run-merge-ui.sh", "Tests/run-markdown-ui.sh",
            "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh", "scripts/build-foundation-lab.sh"):
    text = code(rel)
    lists = len(re.findall(r'"\$ROOT/Sources/ActivityMeetings\.swift" +(\\|")', text))
    need(lists >= 1 and lists <= text.count('"$ROOT/Sources/LiveTranscript.swift"'),
         rel + " compiles Sources/LiveTranscript.swift wherever it compiles ActivityMeetings.swift")

print("live transcript pins: %d passed" % passed)
