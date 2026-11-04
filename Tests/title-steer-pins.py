#!/usr/bin/env python3
"""0.5.366 (server 6.99.0) renaming a live recording: the wiring pins. python3 Tests/title-steer-pins.py [root]

What these pin that the executed checks (Tests/TitleSteerChecks.swift, the wiring check, the helper fixtures) cannot see:
Rename gated on what the server advertises and on the availability rule; the title text kept out of every argument, log and
notice; the title on stdin only; Escape handed to the store before any route; the steer first in the header's title and in the
Mac save; the field's own state kept off the pane; the helper's whitelist; the copy (no em dashes or arrows); the version
touchpoints. Comments are stripped first, so an explanatory comment can never satisfy a pin. Prints "title steer pins: N passed".
"""
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
passed = 0


def need(condition, what):
    global passed
    if not condition:
        print("title steer pin FAILED: " + what)
        sys.exit(1)
    passed += 1


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


def code(rel):
    return strip_comments((root / rel).read_text())


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


core = code("Sources/MeetingAskCore.swift")
steer_core = core[core.index("enum TitleSteer {"):]
enum_body = body(core, "enum TitleSteer {")
store_body = body(core, "final class TitleSteerStore: ObservableObject {")
live = code("Sources/LiveTranscript.swift")
models = code("Sources/Models.swift")
meetings = code("Sources/ActivityMeetings.swift")
window = code("Sources/ActivityWindow.swift")
model = code("Sources/ControllerModel.swift")
recording = code("Sources/MacRecording.swift")
recording_core = code("Sources/MacRecordingCore.swift")
helper = code("HelperSources/main.swift")
run_sh = (root / "Tests/run.sh").read_text()

# ── The capability: Rename only on a server that advertises the route.
need('titleSteer: details["meetingTitleSteer"]?.bool == true' in models and "var titleSteer = false" in models, "the capability is a real true from the helper's meetingTitleSteer key, off by default")
need('"meetingTitleSteer": Self.meetingTitleSteerAdvertised(block?["titleSteer"])' in helper, "the helper's status carries meetingTitleSteer from capabilities.titleSteer")
adv = body(helper, "static func meetingTitleSteerAdvertised(_ value: Any?) -> Bool {")
need("CFBooleanGetTypeID()" in adv and "intValue == 1" in adv, "only the number 1 advertises it, never a boolean")
need("capable: liveMeetingCapability.titleSteer" in model, "availability asks the capability")
avail = body(enum_body, "static func availability(")
need("guard capable, hasFeed, validSession(sessionId), !PhoneMeetingCapture.protected(sessionId) else { return .hidden }" in avail, "no capability, no read, a bad id or an iPhone recording: hidden")
need("return ended || saving ? .locked : .open" in avail, "a stopped recording is locked, otherwise open")
mav = body(model, "func titleSteerAvailability(_ sessionId: String?) -> TitleSteer.Availability {")
need("macRecording.manifest?.captureId == sessionId && !macRecording.isRecording" in mav and "glassesMeetingStopping(sessionId)" in mav and "feed?.ended == true" in mav,
     "locked when the Mac capture stopped, a glasses stop is out, or the file is gone")
need("guard titleSteerAvailability(sessionId) == .open else { return }" in body(model, "func beginTitleSteer(_ sessionId: String) {"), "begin re-checks availability at the click")

# ── The header.
header = body(meetings, "private func header(_ feed: LiveTranscriptFeed?, now: Date) -> some View {")
need('Text(verbatim: model.liveTranscriptOpenID.map { model.liveMeetingTitle($0, start: feed?.startTime) } ?? "Live meeting")' in header, "the header's title still comes from liveMeetingTitle")
need("let rename = model.titleSteerAvailability(model.liveTranscriptOpenID)" in header and "if rename != .hidden, let id = model.liveTranscriptOpenID {" in header, "Rename shows unless hidden")
need(".disabled(rename != .open || steerStore.busy)" in header, "Rename is disabled while locked or a rename is out")
need("Label(TitleSteer.renameLabel, systemImage: \"pencil\")" in header and ".buttonStyle(COSTextButtonStyle())" in body(header, "if rename != .hidden"), "Rename is a quiet pencil text button")
need(".onTapGesture { if let id = model.liveTranscriptOpenID { model.beginTitleSteer(id) } }" in header, "clicking the title opens the field")
need("if let id = model.liveTranscriptOpenID, steerStore.editing == id {" in header and "LiveTitleEditor(store: steerStore" in header, "the field replaces the title row while editing this recording")
need("LiveTranscript.switcherLabel(" in header and "model.liveTranscriptFeeds[$0.sessionId]?.titleSteer" in header, "the switcher uses the steer")
need("Text(TitleSteer.hint)" in header and "Text(TitleSteer.note)" in header and "steerStore.messageSession == id" in header, "the hint, the note and the line show under the row, the line for its own recording only")
need("started: namedStart(feed)" in header and "showsStart: namedStart(feed) == nil" in header, "a name moves the start into the source line and out of the subtitle")
need("guard let feed, let steer = feed.titleSteer, !steer.isEmpty, let start = feed.startTime, !PhoneMeetingCapture.protected(feed.sessionId) else { return nil }" in body(meetings, "private func namedStart("), "the start moves only with a name and a start")
need("@ObservedObject private var steerStore: TitleSteerStore" in meetings and "_steerStore = ObservedObject(wrappedValue: model.titleSteer)" in meetings, "the pane observes the store")
need("steerStore.sessionChanged(to: id)" in meetings and ".onDisappear { steerStore.cancel() }" in meetings, "an open field closes when the pane moves or goes")
editor = body(meetings, "struct LiveTitleEditor: View {")
need("@State private var draft: String" in editor and "_draft = State(initialValue: store.initialDraft)" in editor, "the text is the field's own state, opened on the store's first text")
need("@Published" not in editor and "$draft" in editor, "no published state in the field")
need(".onSubmit { if !over { save(draft) } }" in editor, "Return saves, unless over the limit")
need(".onExitCommand { _ = store.escape() }" in editor, "Escape in the field closes it")
need("Button(\"Save\") { save(draft) }" in editor and ".buttonStyle(COSPrimaryButtonStyle())" in editor and ".disabled(over || store.busy)" in editor, "Save is the primary button, off over the limit or while out")
need("Button(\"Cancel\") { store.cancel() }" in editor and ".buttonStyle(COSQuietButtonStyle())" in editor, "Cancel closes")
need("Text(TitleSteer.counter(draft))" in editor and "COSType.display(22, weight: .medium)" in editor, "the counter, and the title's own serif size")
need("COSType.display(22, weight: .medium)" in header, "the title is 22 pt serif, as the field is")
need(re.search(r"\.focused\(\$focused\)\s*\.disabled\(store\.busy\)\s*\.onSubmit", editor) is not None, "the text field itself waits while a rename is out")
need("select" in editor.lower() and "as? NSText" in editor, "the title is selected when the field opens, through the field editor only")
need(not re.search(r"\b(print|NSLog)\(|Logger|\.notice\(|\.error\(", editor + store_body + enum_body), "no log, print or notice in the field, the store or the rules")

# ── Escape: the window hands it to the store before any route.
esc = body(window, "private func handleActivityEscape() -> Bool {")
need("if model.titleSteer.escape() { return true }" in esc, "the window asks the title store first")
need(esc.index("if showingSettings {") < esc.index("model.titleSteer.escape()") < esc.index("workWorkspaceState.startItemID != nil"), "after the floating overlays, before every route")
need("func escape() -> Bool {" in store_body and "guard editing != nil else { return false }" in store_body, "the store takes Escape only with a field open")
need(re.search(r"func cancel\(\) \{\s*guard !busy else \{ return \}", store_body) is not None, "Cancel waits while a rename is out")

# ── The store: one rename at a time, the revision, the conflict.
save = body(store_body, "func save(draft: String, run: Run, apply: (String, String?) -> Void) async {")
need("!busy" in save.split("\n")[1] and "!TitleSteer.overLimit(draft)" in save.split("\n")[1], "save is single-flight and never sends over the cap")
need("guard snapshot.title == started.steer else {" in save, "a name that moved since the edit began is adopted without a write")
need("expectedRevision: snapshot.revision" in save, "the write names the revision it read")
need("case .none: close(); return" in save, "an unchanged name sends nothing")
need("defer { busy = false }" in save, "busy always clears")
need("messageSeconds" in store_body and "Task.sleep(for: .seconds(seconds))" in store_body and "self.messageToken == token" in store_body, "a line goes by itself, unless a newer one took its place")

# ── The calls: the title on stdin only.
wc = body(enum_body, "static func writeCall(")
need('"--title-stdin"' in wc and 'withJSONObject: ["title": title]' in wc and "title)" not in wc.split("return (")[1], "the title is stdin JSON, never an argument")
need('["meeting-title-steer", "--session", session]' in enum_body, "a read is the verb and the session")
need("validSession(session)" in wc and "expectedRevision >= 0" in wc, "a bad session or a negative revision makes no call")
need("timeout: 12, stdinData: input" in body(model, "private var titleSteerRun: TitleSteerStore.Run {"), "the model runs the helper with the title on stdin")
need("self?.liveTranscriptFeeds[id]?.titleSteer = title" in body(model, "func saveTitleSteer(draft: String) {"), "the server's answer lands in the live feed")

# ── The title in the header and the Mac save.
lmt = body(model, "func liveMeetingTitle(_ sessionId: String, start: Date?) -> String {")
need(lmt.index("liveTranscriptFeeds[sessionId]?.titleSteer") < lmt.index("liveMeetingTitlesKept[sessionId]"), "the steer comes before the kept calendar title")
need("macRecording.steerTitle = { [weak self] id in self?.liveTranscriptFeeds[id]?.titleSteer }" in model, "the Mac store reads the steer from the live feed")
need('"title": .string(MacRecordingNotice.saveTitle(recording: current.title, steer: self.steerTitle?(id)))' in recording, "a Mac save sends the steer as the title")
need("guard let steer = steer?.trimmingCharacters(in: .whitespacesAndNewlines), !steer.isEmpty else { return recording }" in recording_core, "no steer: the recording's own title")
need("TitleSteer" not in recording and "TitleSteer" not in recording_core, "the Mac lanes that compile without MeetingAskCore never name TitleSteer")

# ── The feed.
need("var titleSteer: String? = nil" in live and "if steer != titleSteer { titleSteer = steer; changed = true }" in live, "a full read sets the feed's steer, or clears it")
apply_body = body(live, "mutating func apply(_ read: LiveTranscriptRead, now: Date) -> Bool {")
need(apply_body.index("guard !read.unchanged else { return changed }") < apply_body.index("titleSteer = steer"), "an unchanged read never touches the steer")

# ── The helper.
need('case "meeting-title-steer": try emitMeetingTitleSteer(args: args)' in helper, "the verb is dispatched")
verb = body(helper, "private func emitMeetingTitleSteer(args: [String]) throws {")
need("Self.meetingTitleSteerStdin(try readBoundedStdin(4_096))" in verb, "the title is read from bounded stdin")
need('method: "PUT"' in verb and 'Self.meetingTitleSteerRoute + "?sessionId=" + session' in verb, "a write is a PUT, a read is a GET with the session")
need('details: ["transport": "no_token"]' in verb and 'details: ["transport": "unavailable"]' in verb, "no token and no server are their own transports")
need('hasPrefix("phone_")' in verb, "an iPhone microphone recording is refused")
need(not re.search(r"\b(print|NSLog|Logger)\b|progress|\.notice\(|\.error\(", verb + body(helper, "static func meetingTitleSteerAnswer(") + body(helper, "static func meetingTitleSteerBody(")), "no log or progress line in the verb")
ans = body(helper, "static func meetingTitleSteerAnswer(status: Int, body: [String: Any]?) -> [String: Any] {")
need("Self.meetingTitleSteerCodes.contains(code)" in ans and 'status == 409, code == "title_changed"' in ans, "only the fixed codes cross, and `current` only on title_changed")
need("steerCodes" not in helper and "invalid_title" in helper and "steer_persistence_failed" in helper, "the fixed set names the server's codes")
need('if let steer = titleSteerText(object["titleSteer"]) { read["titleSteer"] = steer }' in helper, "a live read carries the file's titleSteer, cleaned")
need("prefix(Self.meetingTitleSteerMax)" in body(helper, "static func titleSteerText(_ value: Any?) -> String? {"), "a title from the file is cut on a code point")
need("guard cleaned.unicodeScalars.count <= Self.meetingTitleSteerMax else { return nil }" in helper, "a write over 120 code points is refused, never cut")

# ── The copy.
words = re.findall(r'static let (?:hint|note|savingLine|changedLine|endedLine|failedLine|renameLabel) = "([^"]*)"', enum_body)
need(len(words) == 7, "the seven lines are where the checks expect them")
need(all(not re.search("[—–→]|->", w) for w in words), "no em dash, en dash or arrow in a line")
need(not re.search("[—–→]", meetings[meetings.index("struct LiveTitleEditor"):meetings.index("struct LiveTurnRow")]), "none in the field")

# ── Version touchpoints.
plist = (root / "Resources/Info.plist").read_text()
need("<string>0.5.366</string>" in plist and "<string>420</string>" in plist, "Info.plist is 0.5.366, build 420")
need("0.5.365</string>" not in plist and "<string>419</string>" not in plist, "no 0.5.365 or build 419 left in Info.plist")
whats = json.loads((root / "Resources/WhatsNew.json").read_text())
need(whats["version"] == "0.5.366" and whats["whatsNew"]["sections"][0]["title"] == "0.5.366", "What's New is 0.5.366, first")
need(any("Rename" in item for item in whats["whatsNew"]["sections"][0]["items"]), "What's New says Rename")
need((root / "CHANGELOG.md").read_text().startswith("## 0.5.366 (build 420)"), "the changelog's first entry is 0.5.366 (build 420)")
need("run-title-steer.sh" in run_sh and "title-steer-helper-checks.py" in run_sh, "Tests/run.sh runs the lane and the helper checks")

print("title steer pins: %d passed" % passed)
