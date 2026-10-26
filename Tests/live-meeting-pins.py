#!/usr/bin/env python3
"""0.5.336 (server 6.86.0) live meeting view: the wiring pins. python3 Tests/live-meeting-pins.py [root]

What these pin that the executed checks (Tests/LiveMeetingChecks.swift, the helper fixtures) cannot see: every new part
gated on what the server advertises; the audiogram's levels in their own object, never on ControllerModel or
MacRecordingStore; Reduce Motion; the one-second clock in its own TimelineView; Command-Shift-R on the one menu item and
nowhere else; live cues asked for on the Mac start only, never through /live-cues/start; the grey text kept out of every
log; the kind labels the same in both tables; the copy (no em dashes, arrows, eyebrows or pill tabs). Comments are
stripped first, so an explanatory comment can never satisfy a pin. Prints "live meeting pins: N passed".
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
passed = 0


def need(condition, what):
    global passed
    if not condition:
        print("live meeting pin FAILED: " + what)
        sys.exit(1)
    passed += 1


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


def code(rel):
    return strip_comments((root / rel).read_text())


def between(text, start, end):
    i = text.index(start)
    j = text.index(end, i + len(start))
    return text[i:j]


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


raw_model = (root / "Sources/ControllerModel.swift").read_text()
model = strip_comments(raw_model)
pure = code("Sources/LiveTranscript.swift")
models = code("Sources/Models.swift")
meetings = code("Sources/ActivityMeetings.swift")
window = code("Sources/ActivityWindow.swift")
recording = code("Sources/MacRecording.swift")
capture = code("Sources/MacAudioCapture.swift")
core = code("Sources/MacRecordingCore.swift")
ask_core = code("Sources/MeetingAskCore.swift")
ask = code("Sources/MeetingAsk.swift")
app = code("Sources/COSControlApp.swift")
helper = code("HelperSources/main.swift")
pet = code("Sources/SessionPet.swift")
sources = {p.name: strip_comments(p.read_text()) for p in (root / "Sources").glob("*.swift")}
all_sources = "\n".join(sources.values())

# ── The capability, from public health through the helper's status, never a status code.
need('details.merge(Self.liveMeetingStatusFields(health?["capabilities"])) { _, new in new }' in helper, "status forwards the live meeting keys")
fields = body(helper, "static func liveMeetingStatusFields(_ capabilities: Any?) -> [String: Any] {")
for key in ("liveMeetingProtocol", "liveMeetingMacLiveCues", "liveMeetingProvisional", "liveCueKinds", "liveCuesOn", "liveMeetingChunkLevels"):
    need('"' + key + '"' in fields and 'details["' + key + '"]' in models, "the " + key + " key crosses and the model reads it")
need('block?["liveCuesV2"] is [String: Any]' in fields, "Live cues on is the server advertising liveCuesV2 (it does only while the switch is on)")
need("liveMeeting = LiveMeetingCapability(statusDetails: details)" in models, "ServerStatus reads the capability")
cap = body(models, "struct LiveMeetingCapability: Equatable, Sendable {")
need("var available: Bool { protocolVersion == 1 }" in cap, "the surface is protocol 1")
for gate in ("var inlineCues: Bool { available }", "var counts: Bool { available && !cueKinds.isEmpty }",
             "var greyLine: Bool { available && provisional }", "var sendsMacLiveCues: Bool { available && macLiveCues && liveCuesOn }",
             "var macCues: Bool { available && macLiveCues }"):
    need(gate in cap, "the gate: " + gate)
need("var liveMeetingCapability: LiveMeetingCapability { status.liveMeeting }" in model, "the model's capability is the status's")
for banned in ("httpStatus", "== 404", "status == 404"):
    need(banned not in body(meetings, "struct LiveTranscriptPane: View {"), "the live pane never gates on a status code (" + banned + ")")

# ── Inline cues, counts and the Cues tab.
pane = body(meetings, "struct LiveTranscriptPane: View {")
inline = body(pane, "private func inlineCues(_ session: String) -> [LiveCueRecord] {")
need("guard model.liveMeetingCapability.inlineCues else { return [] }" in inline, "inline cues only on a server with the live meeting surface")
need("kinds: model.liveMeetingCapability.counts ? inlineCues(id).map(\\.kind) : nil" in pane, "the counts only when the server lists its kinds")
need("LiveMeeting.anchor(cues: cues.map { ($0.id, $0.createdAt) }, turns: feed.turns, start: feed.startTime)" in pane, "cues anchor by createdAt")
need("LiveInlineCueRow(cue: cue, saving: cueStore.saving.contains(cue.id), error: cueStore.rateErrors[cue.id])" in pane
     and "await cueStore.rate(cue, verdict: verdict, note: cue.rating?.note, run: CueReviewPane.run(model))" in pane,
     "inline cues keep the verdicts, through the one cue store")
row = body(meetings, "struct LiveInlineCueRow: View {")
need("CueVerdictButtons(selected: cue.verdict, disabled: saving)" in row and "if let label = LiveMeeting.kindLabel(cue.kind) {" in row
     and "} else {\n                    Text(verbatim: cue.detail)" in row, "a known kind leads with its label; an unknown kind is a plain cue")
follow = body(pane, "private func followInlineCues(_ session: String?) async {")
need("guard let session, !PhoneMeetingCapture.protected(session), model.liveMeetingCapability.inlineCues" in follow and "LiveMeeting.inlineCueCheckSeconds" in follow
     and "force" not in follow and "await cueStore.loadMeeting(session, days: CueVerdicts.liveDays, run: CueReviewPane.run(model))" in follow,
     "the inline cues re-ask through the store's 15 s floor, never forced, only on the surface")
need("@ObservedObject private var cueStore: CueVerdictsStore" in pane and "_cueStore = ObservedObject(wrappedValue: model.meetingAsk.cueVerdicts)" in pane,
     "the pane observes the cue store, so read cues redraw it")
need("macCues: model.liveMeetingCapability.macCues" in pane, "the Cues tab is offered beside a Mac recording only when the server cues them")
side = body(ask, "struct MeetingSidePanel<Ask: View>: View {")
need("G2MeetingStop.isGlassesSession(session) || (macCues && session.hasPrefix(\"mac_\"))" in side, "glasses meetings, or Mac recordings the server cues")
kinds_pure = dict(re.findall(r'case "(\w+)": "([^"]+)"', body(pure, "static func kindLabel(_ kind: String) -> String? {")))
kinds_core = dict(re.findall(r'case "(\w+)": return "([^"]+)"', body(ask_core, "static func kindLabel(_ kind: String) -> String {")))
need(kinds_pure == kinds_core and set(kinds_pure) == {"reinforce", "challenge", "decision", "promise", "followUp"},
     "the inline lines and the Cues tab label the five kinds the same way")
need('static let knownKinds = ["reinforce", "challenge", "decision", "promise", "followUp"]' in pure, "the kinds in the server's spelling")
need("Self.liveCueKindValid(kind)" in body(helper, "static func liveCueRow(_ value: Any?) -> [String: Any]? {"),
     "the helper keeps a kind it does not know, in the kind spelling")

# ── Live cues on a Mac recording: on the start only, never /live-cues/start.
start = body(recording, "private func start() async {")
need("let asksCues = liveCuesWanted?() == true" in start and 'if asksCues { startPayload["liveCues"] = .bool(true) }' in start
     and 'let response = try await invoke("start", startPayload)' in start, "the Mac start asks for cues only when wanted")
need('if asksCues { liveCuesArm = LiveMeeting.arm(response["liveCues"]) }' in start, "the arm answer is kept, never an error")
need("liveCuesArm = nil" in start and start.index("liveCuesArm = nil") < start.index('invoke("start"'), "every start clears the last arm answer")
need("macRecording.liveCuesWanted = { [weak self] in self?.liveMeetingCapability.sendsMacLiveCues == true }" in model,
     "cues are wanted only with Live cues on and a server that takes the flag")
for name, text in list(sources.items()) + [("main.swift", helper)]:
    need("live-cues/start" not in text and '"live-cues-start"' not in text, name + " never calls /live-cues/start")
need("if flag.boolValue { startBody[\"liveCues\"] = true }" in helper, "the helper sends liveCues only as a JSON true")
need("if let arm = model.macRecording.manifest?.captureId == model.liveTranscriptOpenID ? model.macRecording.liveCuesArm : nil," in pane
     and "let line = LiveMeeting.armLine(arm)" in pane,
     "Cues off shows on the recording it belongs to")

# ── The audiogram: computed in the drain, its own object, never on the model or the store.
drain = body(capture, "private func drain() throws {")
need("defer { if let level { level(samples > 0 ? (squares / Double(samples)).squareRoot() : 0) } }" in drain, "one level per drain tick, 0 when nothing arrived")
need("squares += MacRecordingSignal.sumOfSquares(UnsafeBufferPointer(start: data, count: raw.count / 4)); samples += raw.count / 4" in drain,
     "the level is the RMS of the raw float samples")
need("timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))" in capture, "the drain runs every 100 ms")
need("LiveAudiogramFeed" not in model, "ControllerModel never holds the audiogram")
need(recording.count("LiveAudiogramFeed") == 2 and "Task { @MainActor in LiveAudiogramFeed.live.push(rms: rms) }" in recording
     and "LiveAudiogramFeed.live.reset()" in recording, "MacRecordingStore only hands levels to the feed and resets it")
need("@Published" not in between(recording, "@Published private(set) var liveCuesArm", "    private var previewTask") .replace("@Published private(set) var liveCuesArm", ""),
     "no level or grey text is published on MacRecordingStore")
published_live = re.compile(r"@Published[^\n]*(\blevels?\b|Level\b|[Aa]udiogram|\brms\b|RMS|[Pp]rovisional|\bgrey|Grey)")
published_preview = re.compile(r"@Published[^\n]*[Pp]review")
need(not published_live.search(recording) and not published_preview.search(recording) and not published_live.search(model), "no level, audiogram or grey text is published on MacRecordingStore or ControllerModel")
need(all_sources.count("@ObservedObject var feed: LiveAudiogramFeed") == 2, "only the audiogram and the rail glyph observe the levels")
feed = body(meetings, "@MainActor final class LiveAudiogramFeed: ObservableObject {")
need("static let live = LiveAudiogramFeed()" in feed and "private var meter = DictationLevelMeter()" in feed, "one feed, levels through DictationLevelMeter")
audiogram = body(meetings, "struct LiveAudiogramView: View {")
need("@Environment(\\.accessibilityReduceMotion) private var reduceMotion" in audiogram and "if reduceMotion {" in audiogram
     and audiogram.index("if reduceMotion {") < audiogram.index("Canvas {") and "Canvas {" not in between(audiogram, "if reduceMotion {", "} else {"),
     "Reduce Motion draws a static level bar, never the scrolling Canvas")
need(audiogram.count("Canvas {") == 1 and "LiveAudiogramRing.isSilent(level)" in audiogram, "one Canvas, dotted where silent")
bar = body(meetings, "struct LiveRecordingBar<Add: View, Stop: View>: View {")
need("TimelineView(.periodic(from: start, by: 1))" in bar and "LiveAudiogramView(feed: .live)" in bar and "if mode.meter && mac {" in bar,
     "the bar's clock ticks each second in its own TimelineView; the audiogram is for Mac recordings only")
need("LiveRecordingBar(start: feed?.startTime ?? macStart(session), mac: mac," in pane and "} stop: { stopControls(feed) }" in pane,
     "the pane draws the bar while it records")
strip = body(meetings, "struct LiveParticipantStrip: View {")
need("LiveLastHeardBar(still: reduceMotion)" in strip and "guard !still else { return }" in body(meetings, "struct LiveLastHeardBar: View {"),
     "the last-heard bar is still under Reduce Motion")
need("let strip = LiveMeeting.participants(feed.turns, mac: mac)" in pane and 'let mac = session?.hasPrefix("mac_") == true' in pane,
     "the strip knows a Mac recording (no You)")

# ── The grey line: gated, never logged, memory only.
need("@Published private(set) var lines: [String: LiveProvisionalLine] = [:]" in body(meetings, "@MainActor final class LiveProvisionalFeed: ObservableObject {"),
     "the grey text lives in memory, in its own object")
section = strip_comments(between(raw_model, "    // MARK: - Live meeting view (0.5.336, server 6.86.0)", "    /// 0.5.228."))
for banned in ("Log.", "Logger(", "NSLog", "print(", "debugPrint", "localizedDescription", "String(describing:", "self.error =", " error = ",
               "notice =", "fputs", "write(to", "UserDefaults", "Notice"):
    need(banned not in section, "the model's live meeting section never sends the grey text to " + banned)
need(section.count("helper.run(") == 1 and 'helper.run(["live-provisional", "--session", open], timeout: 6)' in section, "one helper spawn, the provisional read")
poll = body(section, "func pollLiveProvisionalOnce() async {")
need('guard liveTranscriptEnabled, liveMeetingCapability.greyLine, let open = liveTranscriptOpenID, !open.hasPrefix("mac_"),' in poll
     and poll.index("guard liveTranscriptEnabled") < poll.index("helper.run("), "the read needs the setting, the capability and an open glasses meeting")
need(model.count("await pollLiveProvisionalOnce()") == 1 and "await pollLiveProvisionalOnce()" in body(model, "func pollLiveTranscriptOnce() async {"),
     "the grey line reads beside the live transcript, at its cadence")
wanted = body(section, "func liveMeetingPreviewWanted(_ captureId: String) -> Bool {")
need("liveTranscriptEnabled && liveMeetingCapability.greyLine && liveTranscriptOpenID == captureId && liveTranscriptWindowOnScreen" in wanted,
     "Mac previews post only with the setting, the capability and the view open on screen")
need("liveProvisional.clear()" in body(model, "func closeLiveTranscript() {"), "closing the view drops the grey text")
previews = strip_comments(between((root / "Sources/MacRecording.swift").read_text(), "    // MARK: The grey line's previews (0.5.336, server 6.86.0)", "    // MARK: Can COS hear this Mac? (0.5.334)"))
for banned in ("recordingLog", "Logger", "NSLog", "print(", "self.error", "message =", "localizedDescription"):
    need(banned not in previews, "the Mac preview path never logs or shows its text (" + banned + ")")
need("previewDelivered?(id, line)" in previews and previews.count("previewDelivered") == 1, "the text goes only to the live view")
need("gate.begin(chunkIndex: open.index, bytes: pcm.count, now: Date())" in previews and "defer { gate.finish(answered: answered) }" in previews
     and "gate.accept(chunkIndex: line.chunkIndex, previewGen: line.previewGen)" in previews, "every post through the rate cap, an old answer dropped")
need("await spool.removePreview(captureId: id)" in previews and "gate.mayPost(now: Date())" in previews, "the WAV goes after each post; the breaker pauses the loop (0.5.337: and retries a minute later)")
need("previewTask?.cancel(); previewTask = nil" in body(recording, "private func finishStop() async {") and "await spool.removePreview(captureId: id)" in body(recording, "private func finishStop() async {"),
     "stop ends the previews and removes the WAV")
need("&& $0 != Self.previewFilename" in body(core, "func recoverable() throws -> [MacRecordingManifest] {"), "the preview WAV is never audio outside the journal")
need("static let maximumBytes = 480_000" in body(core, "enum LiveMeetingPreviewLimit {") and "static let maximumBytes = 480_000" in body(pure, "struct LiveMeetingPreviewGate: Equatable, Sendable {")
     and "static let macRecordingPreviewMaxBytes = 480_044" in helper, "the spool, the gate and the helper agree on 15 s")
helper_live = strip_comments(between((root / "HelperSources/main.swift").read_text(), "    // MARK: - Live meeting view (0.5.336, server 6.86.0)", "    private func emitLiveCuesHistory(args: [String]) throws {"))
for banned in ("progress(", "print(", "FileHandle.standardError", "NSLog", "fputs", "helperLog", "appendHelperLog"):
    need(banned not in helper_live, "the helper's live meeting code never writes the grey text to " + banned)
preview_case = between(helper, 'case "preview":', "            return\n")
for banned in ("progress(", "print(", "FileHandle.standardError", "NSLog", "helperLog"):
    need(banned not in preview_case, "the helper's preview never writes its text to " + banned)
need('"/api/transcribe-stream/preview?sessionId=" + capture + "&chunkIndex=\\(index.intValue)&previewGen=\\(gen.intValue)"' in preview_case
     and '"&serverInstanceId=" + pin + "&previewModels=parakeet-ultra"' in preview_case and 'headers: ["X-COS-Server-Instance": instance]' in preview_case,
     "the preview post as the contract says")
need('localPath.hasSuffix("/" + Self.macRecordingPreviewFilename)' in preview_case and "Self.macRecordingAudio(home: home, capture: capture, path: localPath)" in preview_case,
     "the preview reads only preview.wav, through the confined spool reader")
view = body(meetings, "struct LiveProvisionalLineView: View {")
need("Text(verbatim: text)" in view and "LiveMeeting.visibleProvisional(feed.lines[sessionId], lastFinalChunk: lastFinalChunk)" in view,
     "the grey line is plain text, only past the last final chunk")
need(pane.count("model.liveMeetingCapability.greyLine") == 2, "both grey line spots gate on the capability (a Mac line exists only through gated previews)")

# ── Command-Shift-R: the one menu item, nowhere else.
need(all_sources.count('.keyboardShortcut("r", modifiers: [.command, .shift])') == 1, "Command-Shift-R is bound once")
menu = between(app, 'CommandMenu("Meetings") {', 'CommandMenu("Dictation") {')
need('Button("Stop Mac recording and save") { Task { await model.macRecording.stop() } }\n                    .keyboardShortcut("r", modifiers: [.command, .shift])\n                    .disabled(!model.macRecordingActive)' in menu,
     "it is the Stop Mac recording menu item, disabled when nothing records")
for name, text in sources.items():
    others = re.findall(r'keyboardShortcut\("[rR]"', text) + re.findall(r'keyEquivalent: "[rR]"', text) + re.findall(r'KeyEquivalent\("[rR]"\)', text)
    need(len(others) == (1 if name == "COSControlApp.swift" else 0), name + ": no other R key equivalent")
    need("keyCode == 15" not in text and "kVK_ANSI_R" not in text, name + ": no key monitor on R")

# ── The rail, the title and the files line.
rail = between(window, "if item == .meetings, showLiveTranscript, model.liveTranscriptDot {", ".font(COSType.body(11.5, weight:")
need("LiveRailBadge(start: badge.start, mac: badge.mac)" in rail, "the badge sits in the rail's Meetings tab, only while recording")
badge = body(meetings, "struct LiveRailBadge: View {")
need("TimelineView(.periodic(from: start, by: 1))" in badge and "LiveMeeting.elapsed(" in badge, "the badge's elapsed time on its own clock")
need("model.liveMeetingCalendarEvent = nextEvent" in window, "the calendar's event reaches the title")
need('Text(verbatim: model.liveTranscriptOpenID.map { model.liveMeetingTitle($0, start: feed?.startTime) } ?? "Live meeting")' in pane, "the header shows the real title")

# ── 0.5.339: one place for files (the approved mock, wk43 mock-339). The whole pane takes the drop; the bar's Add file
# opens Paste screenshot and Choose files…; the Files row is collapsed, hidden with none, and adds nothing itself.
meeting_body = body(pane, "private var meetingBody: some View {")
need("Drop in screenshots" not in all_sources and "LiveFilesDropLine" not in all_sources, "the line under the bar is gone")
need(".modifier(MeetingFilesDrop(enabled: session.map(canAddFiles) ?? false, targeted: $dropTargeted) { providers in" in meeting_body
     and "Task { await files.intakeMeeting(providers: providers, key: key, info: info) }" in meeting_body,
     "the whole live pane is the drop target, through the meeting files intake")
need(meeting_body.index(".modifier(MeetingFilesDrop(") > meeting_body.index("footer(feed)"), "the drop is on the pane itself, after all its parts, never on one of them")
need(".overlay { if dropTargeted { LiveFilesDropOutline() } }" in meeting_body, "while dragging, the transcript is outlined")
outline = body(meetings, "struct LiveFilesDropOutline: View {")
need(".allowsHitTesting(false)" in outline and "LiveMeetingFiles.dropLabel" in outline, "the outline is drawn only (an overlay drop destination never fires), with where it goes")
need('static let dropLabel = "Drop to add to this meeting"' in pure, "the drop's words")
can_add = body(pane, "private func canAddFiles(_ session: String) -> Bool {")
need("files.enabled" in can_add and "WorkCardFiles.meetingID(forKey: LibraryMeeting.captureContextKey(session)) != nil" in can_add,
     "adding needs meeting files on and a meeting folder for the capture (0.5.337 N12)")
need("addFileControl(session, labelled: labelled)" in pane and "if canAddFiles(session) {" in body(pane, "private func addFileControl(_ session: String, labelled: Bool) -> some View {"),
     "Add file sits in the bar, only while files may be added")
add_button = body(meetings, "struct LiveAddFileButton: View {")
need(".accessibilityLabel(LiveRecordingBarLayout.addFileLabel)" in add_button and "if labelled { Text(LiveRecordingBarLayout.addFileLabel)" in add_button,
     "icon-only Add file keeps its VoiceOver label")
need('Image(systemName: "paperclip")' in add_button and "LiveAddFileMenu(paste: paste, choose: choose)" in add_button, "the paperclip, and the menu above it")
menu = body(meetings, "struct LiveAddFileMenu: View {")
need('row(LiveMeetingFiles.pasteLabel, symbol: "doc.on.clipboard", keys: "\\u{2318}V", action: paste)' in menu
     and 'row(LiveMeetingFiles.chooseLabel, symbol: "folder", keys: "\\u{2318}O", action: choose)' in menu, "Paste screenshot and Choose files…, with their keys")
need(all_sources.count('.keyboardShortcut("o", modifiers: .command)') == 1 and '.keyboardShortcut("o", modifiers: .command)' in add_button,
     "Command-O is bound once, on Add file")
need('keyboardShortcut("v"' not in all_sources and 'keyboardShortcut("V"' not in all_sources,
     "Command-V is never a key equivalent (it would take a text field's paste); it is the pane's paste command")
need(".onPasteCommand(of: [.fileURL, .png, .tiff]) { _ in if let session { pasteScreenshot(session) } }" in meeting_body
     and ".focusable(session.map(canAddFiles) ?? false, interactions: .edit)" in meeting_body and ".focusEffectDisabled()" in meeting_body,
     "Command-V adds a screenshot while the pane has focus, with no focus ring")
paste_fn = body(pane, "private func pasteScreenshot(_ session: String) {")
choose_fn = body(pane, "private func chooseFiles(_ session: String) {")
need("files.pasteMeeting(from: NSPasteboard.general, key: key, info: info)" in paste_fn and "files.intakeMeeting(urls: urls, key: key, info: info)" in choose_fn
     and "guard canAddFiles(session)" in paste_fn and "guard canAddFiles(session)" in choose_fn, "both menu rows reuse the meeting files store")
need("MeetingFilesSection(" not in pane and "LiveMeetingFilesRow(files: files, key: LibraryMeeting.captureContextKey(session), info: model.liveMeetingFileInfo(session), open: $filesOpen)" in pane,
     "the header holds the one Files row, not the old Files box")
need("@State private var filesOpen = false" in pane, "the Files row starts collapsed")
files_row = body(meetings, "struct LiveMeetingFilesRow: View {")
need("if LiveMeetingFiles.showsRow(count: shown.count, pendingUndo: undo.count) {" in files_row and "if open {" in files_row
     and "MeetingFileRow(files: files, file: entry.file, folder: entry.folder, id: entry.id, removable: true, preview: $preview)" in files_row
     and "LiveMeetingFiles.note" in files_row, "collapsed by default, hidden with none; open, the shared rows and the note")
for banned in ("intakeMeeting", "pasteMeeting", "NSOpenPanel", "MeetingFilesDrop", "onDrop", "Paste screenshot", "Add files", "pasteLabel", "chooseLabel"):
    need(banned not in files_row, "the Files row adds nothing itself (" + banned + ")")
need("WorkCardFlashView(files: files, workID: id)" in files_row and "files.error" in files_row, "an add's flash or error shows under the row, open or not")
shared_row = body(meetings, "struct MeetingFileRow: View {")
need('icon("eye", "Quick Look")' in shared_row and '"Show in Finder"' in shared_row and '"Remove from this meeting (Undo is offered)"' in shared_row,
     "the rows keep Quick Look, Show in Finder and Remove")
need("MeetingFileRow(files: files, file: file, folder: folder, id: id, removable: supported == true, preview: $preview)" in body(meetings, "struct MeetingFilesSection: View {"),
     "the saved meeting's Files box draws the same rows")
detail = body(meetings, "struct MeetingLibraryDetailPane: View {")
need(detail.count("MeetingFilesSection(files: files, keys: keys") == 1 and "LiveMeetingFilesRow" not in detail, "the saved meeting keeps its one Files box")

# ── 0.5.339: the bar's widths (the mock's ladder) and the glasses meeting's level strip (server 6.87.0).
need("let mode = LiveRecordingBarLayout.mode(barWidth: geometry.size.width)" in bar and "add(mode.addFileLabelled).fixedSize()" in bar
     and "stop().lineLimit(1).fixedSize()" in bar, "the bar picks its mode from its own width; the buttons never wrap")
need(bar.count(".frame(minWidth: LiveRecordingBarLayout.meterFloor, maxWidth: .infinity)") == 2, "both meters shrink first, to the 40 pt floor")
need("} else if mode.meter && levelStrip, let sessionId {" in bar and "LiveChunkLevelStripView(feed: .live, sessionId: sessionId)" in bar
     and "LiveLevelGlyph(feed: nil)" in bar, "the strip for a glasses meeting on a 6.87.0 server, else the still glyph")
need("levelStrip: !mac && model.liveMeetingCapability.levelStrip, sessionId: session" in pane, "the strip only for a glasses meeting, gated on the capability")
need("guard x >= 0 else { break }" in audiogram and "levels.reversed().enumerated()" in audiogram and ".mask(LiveMeterFade())" in audiogram,
     "the audiogram clips its oldest levels at the faded left edge, newest at the right")
need("var levelStrip: Bool { available && chunkLevels }" in cap and 'details["liveMeetingChunkLevels"]?.bool == true' in models, "the strip's gate")
level_feed = body(meetings, "@MainActor final class LiveChunkLevelFeed: ObservableObject {")
need("static let live = LiveChunkLevelFeed()" in level_feed and "@Published private(set) var levels: [LiveChunkLevel] = []" in level_feed,
     "the strip's levels in their own object, the audiogram's pattern")
need(all_sources.count("@ObservedObject var feed: LiveChunkLevelFeed") == 1, "only the strip observes the chunk levels")
need(model.count("LiveChunkLevelFeed") == 2 and "LiveChunkLevelFeed.live.set(read.sessionId, levels)" in model and "LiveChunkLevelFeed.live.clear()" in body(model, "func closeLiveTranscript() {"),
     "ControllerModel only hands the levels on and clears them; it never holds them")
hand = between(model, "if let levels = read.levels,", "LiveChunkLevelFeed.live.set(read.sessionId, levels)")
need("read.sessionId == liveTranscriptOpenID" in hand and "G2MeetingStop.isGlassesSession(read.sessionId)" in hand and "liveMeetingCapability.levelStrip" in hand,
     "only the open glasses meeting's levels, on a server that keeps them")
level_strip = body(meetings, "struct LiveChunkLevelStripView: View {")
need("@Environment(\\.accessibilityReduceMotion) private var reduceMotion" in level_strip and "} else if reduceMotion {" in level_strip
     and level_strip.index("} else if reduceMotion {") < level_strip.index("Canvas {") and level_strip.count("Canvas {") == 1,
     "Reduce Motion: a static level bar, never the strip's Canvas")
need(".accessibilityLabel(LiveLevelStrip.accessibilityLabel)" in level_strip and "LiveLevelStrip.isSilent(level)" in level_strip
     and "LiveLevelStrip.visible(levels, width: Double(size.width))" in level_strip, "dotted where quiet, the newest that fit, labelled for VoiceOver")
helper_levels = body(helper, "static func liveTranscriptLevels(_ value: Any?) -> [[String: Any]]? {")
need('byIndex[index] = ["i": index, "level": level, "speechSec": speech]' in helper_levels and "text" not in helper_levels
     and ".suffix(liveTranscriptLevelLimit)" in helper_levels, "the helper passes three numbers a chunk, the newest 120, never text")
need('if let levels = liveTranscriptLevels(object["chunkLevels"]) { read["levels"] = levels }' in helper, "a read carries the levels from the session file")
need("LiveAskPanel(" in pane and 'Button(showAsk ? "Hide Ask" : "Live COS Ask") { showAsk.toggle() }' in pane, "the Ask panel stays")

# ── The pet keeps its REC dot, which opens the live window (no popover cards).
need(pet.count('dot: COSPalette.live, label: "REC"') == 1 and pet.count("model.showRecordingTranscript()") == 1, "the pet's REC dot opens the live meeting")
show = body(model, "func showRecordingTranscript() {")
need("openActivity?(.meetings)" in show and "openLiveTranscript(id)" in show, "REC opens Meetings on the live recording")
need("LiveMeeting" not in pet and "LiveInlineCueRow" not in pet and "LiveProvisional" not in pet, "no live meeting cards on the pet")

# ── Copy: no em dashes, arrows, eyebrows or pill tabs in the new parts.
new_views = strip_comments(between((root / "Sources/ActivityMeetings.swift").read_text(), "// MARK: - Live meeting view (0.5.336, server 6.86.0)", "// Live COS Ask:"))
ui = new_views + body(pure, "enum LiveMeeting {") + pane
for glyph, name in (("—", "em dash"), ("–", "en dash"), ("→", "arrow"), ("←", "arrow"), ("->\"", "arrow"), ("=>", "arrow")):
    strings = re.findall(r'"(?:[^"\\]|\\.)*"', ui)
    need(not any(glyph in s for s in strings), "no " + name + " in the live meeting's words")
for banned in (".textCase(.uppercase)", ".tracking(", "COSViewSwitch(", "Picker(", ".pickerStyle(.segmented)", ".sheet(", ".popover(", "print(", "NSLog", "Logger"):
    need(banned not in new_views, "the new views have no " + banned)

print(f"live meeting pins: {passed} passed")
