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
# 0.5.288: a quiet file still on disk asks the server through the same status call, and only while the setting is on and
# the server counts a live session; the ceiling is the server's 4 h idle retention, named.
quiet_check = body(model, "func checkQuietLiveTranscriptFiles(now: Date) async {")
need(quiet_check.split("\n")[1].strip() == "guard liveTranscriptEnabled, (liveTranscriptServerLive ?? 0) > 0 else { return }",
     "the quiet-file check refuses when the setting is off or nothing is live")
need("await liveTranscriptServerState(id)" in quiet_check and "helper.run(" not in quiet_check, "the quiet-file check reuses the status call")
need("await checkQuietLiveTranscriptFiles(now: now)" in body(model, "func checkLiveTranscriptHandoffs(now: Date) async {"),
     "the hand-off check also asks about quiet files")
need("LOCAL_FIRST_MEETING_IDLE_RETENTION_MS" in pure and "static let serverIdleRetention: TimeInterval = 4 * 60 * 60" in pure
     and "keeps it live for 30 min" not in pure, "the ceiling names the server's 4 h retention; the 30 min rationale is gone")
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
# QA B1: a held session that has not ended keeps the poll going after the server's count drops.
pending = body(model, "var liveTranscriptPendingHandoff: Bool {")
need("feed.phase == .finalizing" in pending and "feed.seenLive && !feed.ended" in pending, "a held live session that has not ended is still pending (B1)")
# QA N4: only while the window is on screen, and the presenter reports it.
need("visible: !liveTranscriptViewers.isEmpty && liveTranscriptWindowOnScreen," in model_live, "the poll needs the Activity window on screen (N4)")
need("window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)" in window
     and "NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification" in window
     and "model?.setLiveTranscriptWindowOnScreen(Self.onScreen(window))" in window
     and "NotificationCenter.default.addObserver(self, selector: #selector(liveTranscriptVisibilityChanged(_:)), name: name, object: window)" in body(window, "func show(model: ControllerModel"),
     "the presenter reports occlusion and miniaturize to the model (N4)")
# QA W1: the view only copies the model's hand-off selection.
handoff_view = window[window.index(".onChange(of: model.liveTranscriptHandoff?.id) { _, id in"):]
handoff_view = handoff_view[:handoff_view.index("\n        }\n") + 10]
need("guard id != nil, let selection = model.acceptLiveTranscriptHandoff() else { return }" in handoff_view
     and all(f in handoff_view for f in ("meetingReturnWorkID = selection.returnWorkID", "meetingReturnToWork = selection.returnToWork",
                                         "meetingReturnSpeakerSessionID = selection.returnSpeakerSessionID", "meetingWorkLoaded = selection.workLoaded",
                                         "selectedLibraryRecordID = selection.recordID"))
     and "openLibraryMeeting" not in handoff_view and len(re.findall(r"^\s+\w+ = ", handoff_view, re.M)) == 5,
     "Activity's hand-off only applies the selection the model returns (W1)")
need('"dataDir": dataDir.standardizedFileURL.path' in helper and "dataDir = glassesDataDir().standardizedFileURL" in helper,
     "the helper hands back a standardized data directory (N2)")

# ── The secret boundary, everywhere the feature reaches (QA N7): in every Swift source and the helper, no line that
# sends anything to a log, stderr, the alert or the notice may name live transcript data.
SINKS = re.compile(r"NSLog\(|\bprint\(|debugPrint\(|os_log\(|fputs\(|FileHandle\.standardError|\bprogress\(|Log\.(info|notice|error|debug|warning|fault|log|trace)\("
                   r"|[Ll]og\.(info|notice|error|debug|warning|fault|log|trace)\(|\bself\.error = |\berror = |\bnotice = |logEvent\(")
TAINT = re.compile(r"liveTranscript|LiveTranscript|\.turns\b|turn\.text|chunksIndexed|copyText|LiveTurn|feed\.|liveFixture|liveAll|liveTurns")
sinks_checked = 0
for rel in sorted([p.relative_to(root).as_posix() for p in (root / "Sources").glob("*.swift")] + ["HelperSources/main.swift"]):
    for number, line in enumerate(strip_comments(code(rel)).split("\n"), 1):
        if SINKS.search(line):
            sinks_checked += 1
            need_ok = not TAINT.search(line)
            if not need_ok:
                need(False, "%s:%d sends live transcript data to a log, stderr or the alert (%s)" % (rel, number, line.strip()[:160]))
need(sinks_checked > 50, "the boundary scan saw the sinks (%d)" % sinks_checked)

# ── The pure layer prints nothing.
pure_code = strip_comments(pure)
for banned in ("print(", "NSLog", "Logger", "fputs", "os_log"):
    need(banned not in pure_code, "Sources/LiveTranscript.swift never logs (" + banned + ")")
need("import Foundation" in pure and "import SwiftUI" not in pure and "import AppKit" not in pure, "Sources/LiveTranscript.swift is pure Foundation")

# ── The views.
live_views = strip_comments(meetings[meetings.index("// MARK: - Live meeting transcript (0.5.278)"):meetings.index("// Live COS Ask:")])
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

# ── 0.5.282: the Live COS Ask model control. One setting, one control, one way to change it.
ask = strip_comments(code("Sources/MeetingAsk.swift"))
all_code = "".join(strip_comments(p.read_text()) for p in sorted((root / "Sources").glob("*.swift")))
panel_body = body(body(ask, "struct LiveAskPanel: View {"), "var body: some View {")
feed_block = body(panel_body, "            if feed != nil || saved {\n                if let note")
need(all_code.count("MeetingAskModelControl(store: state, model: model, compact: true)") == 1
     and "MeetingAskModelControl(store: state, model: model, compact: true)" in feed_block
     and feed_block.index('Button("Ask") { submit(action: "ask", question: state.draft(session)) }') < feed_block.index("MeetingAskModelControl("),
     "the Ask panel shows the model control once, under the composer, for live and explicitly loaded saved recordings")
need(all_code.count("MeetingAskModelControl(store: store, model: model)") == 1
     and "MeetingAskModelControl(store: store, model: model)" in body(ask, "struct MeetingAskSettings: View {"),
     "Settings shows the same model control once")
need(all_code.count("MeetingAskModelControl(") == 2, "the model control is drawn only in Settings and the Ask panel")
control = body(ask, "struct MeetingAskModelControl: View {")
# 0.5.289: the Transcription card (server 6.72.0) lives in this file with its own pickers, a separate setting; it is set
# aside here so the Ask model control is still the only dropdown meeting assistance draws.
stt_card = body(ask, "struct TranscriptionSettingsCard: View {")
need('COSDropdown("Model", selection: store.modelSelection(model: model), options: Self.options(config),' in control
     and ask.replace(stt_card, "").count("COSDropdown(") == 1,
     "the model control is a COSDropdown bound to the store's one selection, the only dropdown meeting assistance draws")
need("modelSelection" not in stt_card and "MeetingAskModelControl" not in stt_card,
     "the Transcription card never draws or binds the Ask model control")
need(".disabled(locked)" in control and "locked: lock != nil" in control and "let lock = store.modelLock" in control and "if let lock { Text(lock)" in control,
     "the model control is disabled, with its reason shown, whenever the store says it is locked")
need("MeetingAskModelPicker.rows(config)" in control and "enabled: row.enabled" in control and "note: row.note" in control,
     "the model control lists the server's models with unavailable ones disabled and their reason")
select = body(ask, "@discardableResult func selectModel(")
need(len(re.findall(r"\.configure\(", all_code)) == 1 and "await self?.configure(choice, model: model)" in select,
     "configure is called only from MeetingAskStore.selectModel (no second path, no per-question override)")
need(body(ask, "func modelSelection(model: ControllerModel) -> Binding<String> {").count("selectModel(") == 1,
     "the controls' binding writes only through selectModel")
need(select.index("MeetingAskModelPicker.change(") < select.index("pendingModel = choice") < select.index("Task {"),
     "selectModel takes the lock before the server is asked, so a second pick is refused")

# ── 0.5.282: the background file observer sends only changed lists; a new server identity starts empty.
need(body(ask, "func observeFiles(_ files: WorkCardFileStore, model: ControllerModel) {").count("registerFiles(session, model: model, onlyIfChanged: true)") == 1,
     "the file observer re-sends only meetings whose file list changed")
need("MeetingAskFileSync.needsRegistration(published: publishedFiles[session], current: files)" in body(ask, "@discardableResult func registerFiles(_ session: String, model: ControllerModel, onlyIfChanged: Bool = false) async -> Bool {"),
     "registerFiles compares against what this server was last sent")
identity_reset = body(ask, "if scope != identity {")
need(all(statement in identity_reset for statement in ("publishedFiles = [:]", "savedSnapshots = [:]", "sourceHealth = [:]", "identity = scope")),
     "a different server identity clears the sent file lists so the new server receives them")

# ── Every whole-app compile list carries the new file.
for rel in ("Tests/run.sh", "scripts/build-release.sh", "Tests/run-held-ui.sh", "Tests/run-merge-ui.sh", "Tests/run-markdown-ui.sh",
            "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh", "scripts/build-foundation-lab.sh"):
    text = code(rel)
    lists = len(re.findall(r'"\$ROOT/Sources/ActivityMeetings\.swift" +(\\|")', text))
    need(lists >= 1 and lists <= text.count('"$ROOT/Sources/LiveTranscript.swift"'),
         rel + " compiles Sources/LiveTranscript.swift wherever it compiles ActivityMeetings.swift")

# ── 0.5.336 (server 6.86.0): the grey provisional text keeps the same boundary as the transcript. It goes from the
# helper's answer (live-provisional, or the Mac preview) into ControllerModel.liveProvisional and the grey line, and
# nowhere else: no log, print, stderr, error, notice, report, cache, file or saved meeting, and never into Copy.
raw_model = (root / "Sources/ControllerModel.swift").read_text()
lm_model = strip_comments(raw_model[raw_model.index("    // MARK: - Live meeting view (0.5.336, server 6.86.0)"):raw_model.index("    /// 0.5.228.")])
for banned, why in (("Log.", "a Logger"), ("Logger(", "a Logger"), ("NSLog", "NSLog"), ("print(", "print"), ("debugPrint", "print"),
                    ("localizedDescription", "an error's description"), ("String(describing:", "an error's description"),
                    ("self.error =", "the alert"), (" error = ", "the alert"), ("notice =", "the notice"), ("fputs", "stderr"),
                    ("write(to", "a file"), ("UserDefaults", "the defaults"), ("liveTranscriptReason", "the paused line")):
    need(banned not in lm_model, "the grey text never reaches " + why + " (" + banned + ")")
raw_helper = (root / "HelperSources/main.swift").read_text()
lm_helper = strip_comments(raw_helper[raw_helper.index("    // MARK: - Live meeting view (0.5.336, server 6.86.0)"):raw_helper.index("    private func emitLiveCuesHistory(args: [String]) throws {")])
for banned in ("progress(", "print(", "FileHandle.standardError", "NSLog", "appendHelperLog", "helperLog", "fputs", "debugPrint"):
    need(banned not in lm_helper, "the helper's live-provisional never writes the grey text to " + banned)
need('emit(ok: true, message: "Live provisional answered (\\(response.status))", details: details)' in lm_helper,
     "the helper's message names only the status; the text rides in details for the app")
lm_views = strip_comments(meetings[meetings.index("struct LiveProvisionalLineView: View {"):meetings.index("// Live COS Ask: durable state")])
need("Text(verbatim: text)" in lm_views and "Markdown" not in lm_views and "print(" not in lm_views and "Logger" not in lm_views,
     "the grey line is drawn as plain text and never logged")
all_text = {p.name: strip_comments(p.read_text()) for p in (root / "Sources").glob("*.swift")}
holders = sorted(name for name, text in all_text.items() if "liveProvisional" in text)
need(holders == ["ActivityMeetings.swift", "ControllerModel.swift"], "only the model and the live views hold the grey text: " + ", ".join(holders))
copy = body(model, "func copyLiveTranscript() {") + body(model, "var liveTranscriptCopyText: String? {")
need("liveProvisional" not in copy and "provisional" not in copy.lower(), "Copy transcript never includes the grey text")
need("liveProvisional" not in strip_comments(code("Sources/MeetingAsk.swift")) and "liveProvisional" not in strip_comments(code("Sources/MeetingAskCore.swift")),
     "Live COS Ask and Copy full context never see the grey text")
raw_rec = code("Sources/MacRecording.swift")
mac_previews = strip_comments(raw_rec[raw_rec.index("    // MARK: The grey line's previews (0.5.336, server 6.86.0)"):raw_rec.index("    // MARK: Can COS hear this Mac? (0.5.334)")])
need(strip_comments(raw_rec).count("previewDelivered?(id, line)") == 1 and "previewDelivered?(id, line)" in mac_previews and "recordingLog" not in mac_previews,
     "the Mac preview's text goes only to the live view, never the recording log")

print("live transcript pins: %d passed" % passed)
