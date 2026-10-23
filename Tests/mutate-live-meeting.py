#!/usr/bin/env python3
"""0.5.336: mutation gate for the live meeting view (server 6.86.0).

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Each mutant must
match its target EXACTLY ONCE, and is killed only when its lane fails with a named check ("... FAILED: ...", an
AssertionError naming the check, or the helper self-test's own failing expectation); a compile failure or any other
exit is an infrastructure error, not a kill. Compiles go through the lanes, so through Tests/compile-guard.sh, one at a
time. Usage: python3 Tests/mutate-live-meeting.py [--lane pins|models|helper|wiring] [--only M23,P21,H]
"""
import os, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PURE = "Sources/LiveTranscript.swift"
MODELS = "Sources/Models.swift"
MODEL = "Sources/ControllerModel.swift"
MEET = "Sources/ActivityMeetings.swift"
REC = "Sources/MacRecording.swift"
CAP = "Sources/MacAudioCapture.swift"
CORE = "Sources/MacRecordingCore.swift"
ASKC = "Sources/MeetingAskCore.swift"
ASK = "Sources/MeetingAsk.swift"
APP = "Sources/COSControlApp.swift"
HELPER = "HelperSources/main.swift"

MUTANTS = [
    # The pure rules (Tests/LiveMeetingChecks.swift).
    ("M1 any protocol opens the surface", "models", MODELS, "var available: Bool { protocolVersion == 1 }", "var available: Bool { protocolVersion != nil }"),
    ("M2 counts without the kinds", "models", MODELS, "var counts: Bool { available && !cueKinds.isEmpty }", "var counts: Bool { available }"),
    ("M3 the grey line without its route", "models", MODELS, "var greyLine: Bool { available && provisional }", "var greyLine: Bool { available }"),
    ("M4 Mac cues ignore the Live cues switch", "models", MODELS, "var sendsMacLiveCues: Bool { available && macLiveCues && liveCuesOn }", "var sendsMacLiveCues: Bool { available && macLiveCues }"),
    ("M5 an absent macLiveCues reads true", "models", MODELS, 'macLiveCues: details["liveMeetingMacLiveCues"]?.bool == true,', 'macLiveCues: details["liveMeetingMacLiveCues"]?.bool != false,'),
    ("M6 zero counts are spoken", "models", PURE, "return n == 0 ? nil : \"\\(n) \"", "return n < 0 ? nil : \"\\(n) \""),
    ("M7 coaching kinds are counted", "models", PURE, '("followUp", "follow-up", "follow-ups")]', '("followUp", "follow-up", "follow-ups"), ("challenge", "challenge", "challenges")]'),
    ("M8 a cue anchors to the next turn", "models", PURE, "let turn = turns.last { Double($0.elapsedMs) <= offset } ?? first", "let turn = turns.first { Double($0.elapsedMs) >= offset } ?? first"),
    ("M9 cues anchor without a start", "models", PURE, "guard let start, let first = turns.first else { return [:] }", "guard let first = turns.first else { return [:] }\n        let start = start ?? Date(timeIntervalSince1970: 0)"),
    ("M10 You shows on a Mac recording", "models", PURE, '            if mac, name.lowercased() == "you" { continue }\n', ""),
    ("M11 unidentified voices are not grouped", "models", PURE, "let person = unidentified(name) ?", "let person = false ?"),
    ("M12 the ring does not wrap", "models", PURE, "next = (next + 1) % Self.capacity", "next = min(next + 1, Self.capacity - 1)"),
    ("M13 the ring does not clamp", "models", PURE, "level.isFinite ? min(1, max(0, level)) : 0", "level.isFinite ? level : 0"),
    ("M14 two previews in flight", "models", PURE, "guard open, !inFlight, chunkIndex >= 0, bytes >= Self.minimumBytes else { return nil }", "guard open, chunkIndex >= 0, bytes >= Self.minimumBytes else { return nil }"),
    ("M15 previews not spaced", "models", PURE, "        if let lastPost, now.timeIntervalSince(lastPost) < Self.interval { return nil }\n", ""),
    ("M16 previewGen not per chunk", "models", PURE, "if chunkIndex != self.chunkIndex { self.chunkIndex = chunkIndex; generation = -1 }", "if chunkIndex != self.chunkIndex { self.chunkIndex = chunkIndex }"),
    ("M17 an equal answer replaces the shown one", "models", PURE, "(chunkIndex == shownChunk && previewGen > shownGeneration)", "(chunkIndex == shownChunk && previewGen >= shownGeneration)"),
    ("M18 the breaker never opens", "models", PURE, "failures = answered ? 0 : failures + 1", "failures = 0"),
    ("M19 too little audio posts", "models", PURE, "bytes >= Self.minimumBytes else { return nil }", "bytes > 0 else { return nil }"),
    ("M20 the window is not the newest", "models", PURE, "let start = max(0, even - maximumBytes)", "let start = 0"),
    ("M21 a settled chunk stays grey", "models", PURE, "guard let line, line.chunkIndex > lastFinalChunk else { return nil }", "guard let line, line.chunkIndex >= lastFinalChunk else { return nil }"),
    ("M22 the settled cursor is ignored", "models", PURE, "return max(feed.cursor, feed.chunks.keys.max() ?? -1)", "return feed.chunks.keys.max() ?? -1"),
    ("M23 a failed read shows a line", "models", PURE, 'guard details["transport"]?.string == "answered", details["httpStatus"]?.int == 200, let live', 'guard let live'),
    ("M24 another post's answer shows", "models", PURE, 'details["previewGen"]?.int == previewGen,', ""),
    ("M25 any reason text shows", "models", PURE, '.flatMap { $0.range(of: "\\\\A[a-z][a-z0-9_]{0,63}\\\\z", options: .regularExpression) != nil ? $0 : nil }', ""),
    ("M26 an armed start says Cues off", "models", PURE, "guard let arm, !arm.armed else { return nil }", "guard let arm else { return nil }"),
    ("M27 any Mac title beats the calendar", "models", PURE, "!macTitle.isEmpty, !isAutomaticTitle(macTitle) { return macTitle }", "!macTitle.isEmpty { return macTitle }"),
    ("M28 any calendar event is the title", "models", PURE, "abs(calendar.start.timeIntervalSince(start)) <= calendarMatchSeconds", "true"),
    ("M29 an unknown kind gets a label", "models", PURE, '        case "reinforce": "Reinforce"\n        default: nil', '        case "reinforce": "Reinforce"\n        default: kind'),
    # The wiring, at runtime (the app model against the stand-in helper, Tests/LiveTranscriptRender.swift).
    ("W1 an older server reads the grey line", "wiring", MODEL, "guard liveTranscriptEnabled, liveMeetingCapability.greyLine, let open = liveTranscriptOpenID,", "guard liveTranscriptEnabled, let open = liveTranscriptOpenID,"),
    ("W2 a Mac recording is read through live-provisional", "wiring", MODEL, 'let open = liveTranscriptOpenID, !open.hasPrefix("mac_"),', "let open = liveTranscriptOpenID,"),
    ("W3 previews post for any recording", "wiring", MODEL, " && liveTranscriptOpenID == captureId && liveTranscriptWindowOnScreen", " && liveTranscriptWindowOnScreen"),
    ("W4 closing keeps the grey text", "wiring", MODEL, "        recordingShortcutDeadline = nil\n        liveProvisional.clear()\n", "        recordingShortcutDeadline = nil\n"),
    ("W5 a gone meeting keeps its line", "wiring", MODEL, "liveProvisional.set(open, answer.live ? answer.line : nil)", "if answer.live { liveProvisional.set(open, answer.line) }"),
    ("W6 Mac starts always ask for cues", "wiring", MODEL, "self?.liveMeetingCapability.sendsMacLiveCues == true }", "self?.liveMeetingCapability.macCues != nil }"),
    # The sources (Tests/live-meeting-pins.py and Tests/live-transcript-pins.py).
    ("P1 inline cues on an older server", "pins", MEET, "        guard model.liveMeetingCapability.inlineCues else { return [] }\n", ""),
    ("P2 counts on an older server", "pins", MEET, "kinds: model.liveMeetingCapability.counts ? inlineCues(id).map(\\.kind) : nil", "kinds: inlineCues(id).map(\\.kind)"),
    ("P3 the Mac start always asks for cues", "pins", REC, "let asksCues = liveCuesWanted?() == true", "let asksCues = true"),
    ("P4 the audiogram on the model", "pins", MODEL, "    let liveProvisional = LiveProvisionalFeed()\n", "    let liveProvisional = LiveProvisionalFeed()\n    let audiogram = LiveAudiogramFeed.live\n"),
    ("P5 Reduce Motion scrolls", "pins", MEET, "            if reduceMotion {\n                GeometryReader", "            if false {\n                GeometryReader"),
    ("P6 the clock ticks every 15 s", "pins", MEET, "                        TimelineView(.periodic(from: start, by: 1)) { context in\n                            Text(LiveMeeting.elapsed(context.date.timeIntervalSince(start)))\n                                .font(COSType.mono(12.5",
     "                        TimelineView(.periodic(from: start, by: 15)) { context in\n                            Text(LiveMeeting.elapsed(context.date.timeIntervalSince(start)))\n                                .font(COSType.mono(12.5"),
    ("P7 Command-Shift-R bound twice", "pins", MEET, 'Button("Copy transcript") { model.copyLiveTranscript() }', 'Button("Copy transcript") { model.copyLiveTranscript() }.keyboardShortcut("r", modifiers: [.command, .shift])'),
    ("P8 Command-Shift-R missing", "pins", APP, '                    .keyboardShortcut("r", modifiers: [.command, .shift])\n', ""),
    ("P9 the grey text logged", "pins", REC, "        previewDelivered?(id, line)\n", "        recordingLog.notice(\"preview \\(line.text, privacy: .public)\")\n        previewDelivered?(id, line)\n"),
    ("P10 the model prints the grey text", "pins", MODEL, "        liveProvisional.set(open, answer.live ? answer.line : nil)\n", "        print(answer)\n        liveProvisional.set(open, answer.live ? answer.line : nil)\n"),
    ("P11 the helper writes the grey text to stderr", "pins", HELPER, "        var details = Self.liveProvisionalAnswer(status: response.status, body: response.body)\n", "        var details = Self.liveProvisionalAnswer(status: response.status, body: response.body)\n        progress(String(describing: details))\n"),
    ("P12 /live-cues/start for a Mac recording", "pins", REC, "            if asksCues { startPayload[\"liveCues\"] = .bool(true) }\n", "            if asksCues { _ = try? await bridge?(\"live-cues-start\", [:]) }\n"),
    ("P13 the kind tables disagree", "pins", ASKC, '        case "followUp": return "Follow-up"', '        case "followUp": return "Follow up"'),
    ("P14 the preview WAV stays", "pins", REC, "        await spool.removePreview(captureId: id)\n        guard let response, response.ok else { return }\n", "        guard let response, response.ok else { return }\n"),
    ("P15 the preview counts as stray audio", "pins", CORE, " && $0 != Self.previewFilename", ""),
    ("P16 the Cues tab beside any Mac recording", "pins", ASK, '(macCues && session.hasPrefix("mac_"))', 'session.hasPrefix("mac_")'),
    ("P17 the strip shows You on a Mac recording", "pins", MEET, "let strip = LiveMeeting.participants(feed.turns, mac: mac)", "let strip = LiveMeeting.participants(feed.turns, mac: false)"),
    ("P18 the inline cues force reads", "pins", MEET, "await cueStore.loadMeeting(session, days: CueVerdicts.liveDays, run: CueReviewPane.run(model))", "await cueStore.loadMeeting(session, days: CueVerdicts.liveDays, force: true, run: CueReviewPane.run(model))"),
    ("P19 the level is not RMS", "pins", CAP, "(squares / Double(samples)).squareRoot()", "(squares / Double(samples))"),
    ("P20 Copy carries the grey text", "pins", MODEL, "    func copyLiveTranscript() {\n", "    func copyLiveTranscript() {\n        _ = liveProvisional.lines\n"),
    ("P21 the audiogram on the store", "pins", REC, "    private var previewTask: Task<Void, Never>?\n", "    private var previewTask: Task<Void, Never>?\n    @Published private(set) var levels: [Double] = []\n"),
    # The helper (its self-test and the loopback fixtures).
    ("H1 the helper drops the new kinds", "helper", HELPER, "              let kind = raw[\"kind\"] as? String, Self.liveCueKindValid(kind),", "              let kind = raw[\"kind\"] as? String, [\"reinforce\", \"challenge\"].contains(kind),"),
    ("H2 a number for liveCues", "helper", HELPER, "                guard let flag = flag as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {\n                    emit(ok: false, message: \"Mac recording start is invalid.\"); return",
     "                guard let flag = flag as? NSNumber else {\n                    emit(ok: false, message: \"Mac recording start is invalid.\"); return"),
    ("H3 liveCues false is sent", "helper", HELPER, 'if flag.boolValue { startBody["liveCues"] = true }', 'startBody["liveCues"] = flag.boolValue'),
    ("H4 any WAV is a preview", "helper", HELPER, 'localPath.hasSuffix("/" + Self.macRecordingPreviewFilename)', 'localPath.hasSuffix(".wav")'),
    ("H5 a preview over 15 s", "helper", HELPER, "previewAudio.count <= Self.macRecordingPreviewMaxBytes else {", "previewAudio.count > 0 else {"),
    ("H6 another generation's text", "helper", HELPER, "Self.liveCueCount(body[\"previewGen\"]) == previewGen,\n", "\n"),
    ("H7 the provisional line passes through", "helper", HELPER, '            out["provisional"] = ["chunkIndex": index, "previewGen": gen, "text": String(text.suffix(Self.liveProvisionalMaxCharacters))]', '            out["provisional"] = line'),
    ("H8 a bool is a protocol", "helper", HELPER, 'let version = Self.liveCueCount(meeting?["protocol"]).map { $0 as Any } ?? NSNull()', 'let version = (meeting?["protocol"] as? Int).map { $0 as Any } ?? NSNull()'),
    ("H9 Live cues on from the v1 block", "helper", HELPER, '"liveCuesOn": block?["liveCuesV2"] is [String: Any],', '"liveCuesOn": block?["liveCues"] is [String: Any],'),
    ("H10 any session id is read", "helper", HELPER, 'guard let session = option("--session", in: args), Self.liveCueSessionValid(session) else {\n            throw HelperError.message("Use --session and a meeting session id")',
     'guard let session = option("--session", in: args) else {\n            throw HelperError.message("Use --session and a meeting session id")'),
    ("H11 the grey text uncapped", "helper", HELPER, 'out["provisional"] = ["chunkIndex": index, "previewGen": gen, "text": String(text.suffix(Self.liveProvisionalMaxCharacters))]', 'out["provisional"] = ["chunkIndex": index, "previewGen": gen, "text": text]'),
    # 0.5.339 (A: one place for files; B: the glasses level strip, server 6.87.0).
    ("M30 the strip without protocol 1", "models", MODELS, "var levelStrip: Bool { available && chunkLevels }", "var levelStrip: Bool { chunkLevels }"),
    ("M31 the strip without chunkLevels", "models", MODELS, "var levelStrip: Bool { available && chunkLevels }", "var levelStrip: Bool { available }"),
    ("M32 any chunkLevels value opens the strip", "models", MODELS, 'chunkLevels: details["liveMeetingChunkLevels"]?.bool == true)', 'chunkLevels: details["liveMeetingChunkLevels"] != nil)'),
    ("M33 speech seconds ignored", "models", PURE, "        if let speech = level.speechSec { return speech < speechFloor }\n", ""),
    ("M34 dotted at the speech floor itself", "models", PURE, "return speech < speechFloor }", "return speech <= speechFloor }"),
    ("M35 the strip clips the newest", "models", PURE, "return levels.count > fit ? Array(levels.suffix(fit)) : levels", "return levels.count > fit ? Array(levels.prefix(fit)) : levels"),
    ("M36 the strip never clips", "models", PURE, "return levels.count > fit ? Array(levels.suffix(fit)) : levels", "return levels"),
    ("M37 Add file labelled under 560", "models", PURE, "Mode(addFileLabelled: barWidth >= labelWidth, meter: barWidth >= meterWidth)", "Mode(addFileLabelled: barWidth >= meterWidth, meter: barWidth >= meterWidth)"),
    ("M38 the meter under 340", "models", PURE, "Mode(addFileLabelled: barWidth >= labelWidth, meter: barWidth >= meterWidth)", "Mode(addFileLabelled: barWidth >= labelWidth, meter: true)"),
    ("M39 the Files row with no files", "models", PURE, "static func showsRow(count: Int, pendingUndo: Int) -> Bool { count > 0 || pendingUndo > 0 }", "static func showsRow(count: Int, pendingUndo: Int) -> Bool { true }"),
    ("M40 the Files row hides a pending Undo", "models", PURE, "static func showsRow(count: Int, pendingUndo: Int) -> Bool { count > 0 || pendingUndo > 0 }", "static func showsRow(count: Int, pendingUndo: Int) -> Bool { count > 0 }"),
    ("W7 the levels reach the strip on an older server", "wiring", MODEL, "               liveMeetingCapability.levelStrip {\n", "               true {\n"),
    ("W8 a Mac recording feeds the glasses strip", "wiring", MODEL, "read.sessionId == liveTranscriptOpenID, G2MeetingStop.isGlassesSession(read.sessionId),", "read.sessionId == liveTranscriptOpenID,"),
    ("W9 closing keeps the levels", "wiring", MODEL, "        liveProvisional.clear()\n        LiveChunkLevelFeed.live.clear()\n", "        liveProvisional.clear()\n"),
    ("W10 the bar ignores its width", "wiring", MEET, "            let mode = LiveRecordingBarLayout.mode(barWidth: geometry.size.width)", "            let mode = LiveRecordingBarLayout.mode(barWidth: 1000)"),
    ("W11 the buttons may wrap", "wiring", MEET, "                add(mode.addFileLabelled).fixedSize()\n                stop().lineLimit(1).fixedSize()", "                add(mode.addFileLabelled)\n                stop()"),
    ("H20 chunkLevels any truthy value", "helper", HELPER, '"liveMeetingChunkLevels": (meeting?["chunkLevels"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false]', '"liveMeetingChunkLevels": (meeting?["chunkLevels"] as? NSNumber)?.boolValue ?? false]'),
    ("H21 a level outside 0 to 1 crosses", "helper", HELPER, ", let level = number(row[\"level\"]), (0...1).contains(level) else { continue }", ", let level = number(row[\"level\"]) else { continue }"),
    ("H22 the levels not bounded", "helper", HELPER, "return byIndex.keys.sorted().suffix(liveTranscriptLevelLimit).compactMap { byIndex[$0] }", "return byIndex.keys.sorted().compactMap { byIndex[$0] }"),
    ("H23 a level row's other keys cross", "helper", HELPER, 'byIndex[index] = ["i": index, "level": level, "speechSec": speech]', 'var copy = row; copy["i"] = index; copy["speechSec"] = speech; byIndex[index] = copy'),
    ("H24 the read drops its levels", "helper", HELPER, '        if let levels = liveTranscriptLevels(object["chunkLevels"]) { read["levels"] = levels }\n', ""),
    ("P30 the line under the bar returns", "pins", MEET, "            } else {\n                Divider()\n            }\n            footer(feed)", "                Text(\"Drop in screenshots or files while it's on.\")\n            } else {\n                Divider()\n            }\n            footer(feed)"),
    ("P31 the drop on one part, not the pane", "pins", MEET, "        .modifier(MeetingFilesDrop(enabled: session.map(canAddFiles) ?? false, targeted: $dropTargeted) { providers in", "        .modifier(MeetingFilesDrop(enabled: false, targeted: $dropTargeted) { providers in"),
    ("P32 the outline takes the drop", "pins", MEET, "            .padding(6)\n            .allowsHitTesting(false)", "            .padding(6)"),
    ("P33 Command-V as a key equivalent", "pins", MEET, '            Button("") { choose() }.keyboardShortcut("o", modifiers: .command)', '            Button("") { choose() }.keyboardShortcut("v", modifiers: .command)'),
    ("P34 icon-only Add file loses its label", "pins", MEET, "        .accessibilityLabel(LiveRecordingBarLayout.addFileLabel)\n        .help(", "        .help("),
    ("P35 the Files row adds files", "pins", MEET, "                    .accessibilityValue(open ? \"Open\" : \"Closed\")\n", "                    .accessibilityValue(open ? \"Open\" : \"Closed\")\n                    .onDrop(of: WorkCardFiles.fileDropTypes, isTargeted: nil) { _ in false }\n"),
    ("P36 the Files row starts open", "pins", MEET, "@State private var filesOpen = false", "@State private var filesOpen = true"),
    ("P37 the levels on the model", "pins", MODEL, "    let liveProvisional = LiveProvisionalFeed()\n", "    let liveProvisional = LiveProvisionalFeed()\n    let chunkLevels = LiveChunkLevelFeed.live\n"),
    ("P38 Reduce Motion draws the strip", "pins", MEET, "            } else if reduceMotion {\n                GeometryReader", "            } else if false {\n                GeometryReader"),
    ("P39 the strip for a Mac recording", "pins", MEET, "levelStrip: !mac && model.liveMeetingCapability.levelStrip, sessionId: session", "levelStrip: model.liveMeetingCapability.levelStrip, sessionId: session"),
    ("P40 the audiogram squeezes its history", "pins", MEET, "                        guard x >= 0 else { break }\n", ""),
    ("P41 the levels carry text", "pins", HELPER, 'byIndex[index] = ["i": index, "level": level, "speechSec": speech]', 'byIndex[index] = ["i": index, "level": level, "speechSec": speech, "text": row["text"] ?? ""]'),
]

LANES = {"pins": ("run-live-meeting.sh", "COS_LIVE_MEETING_LANE", "pins"), "models": ("run-live-meeting.sh", "COS_LIVE_MEETING_LANE", "models"),
         "helper": ("run-live-meeting.sh", "COS_LIVE_MEETING_LANE", "helper"), "wiring": ("run-live-transcript.sh", "COS_LIVE_TRANSCRIPT_LANE", "wiring")}


def run(lane):
    script, var, value = LANES[lane]
    outs = []
    r = subprocess.run(["zsh", str(ROOT / "Tests" / script)], cwd=ROOT, env=dict(os.environ, **{var: value}), capture_output=True, text=True)
    outs.append(r)
    # The pins lane is two files: the live transcript pins carry the grey text's boundary too.
    if lane == "pins" and r.returncode == 0:
        r = subprocess.run(["zsh", str(ROOT / "Tests" / "run-live-transcript.sh")], cwd=ROOT, env=dict(os.environ, COS_LIVE_TRANSCRIPT_LANE="pins"), capture_output=True, text=True)
    return r


def named(out):
    for line in out.splitlines():
        if "FAILED:" in line or "FAILED (" in line or "self-test failed:" in line or "AssertionError" in line or "check failed" in line or "below floor" in line:
            return line.strip()
    return None


only = sys.argv[sys.argv.index("--lane") + 1] if "--lane" in sys.argv else None
lanes = [lane for lane in ("pins", "models", "wiring", "helper") if only in (None, lane)]
mutants = [m for m in MUTANTS if m[1] in lanes]
# --only M23,P21,H: re-run named mutants (an id, or a prefix letter); the lanes they need still get a green baseline.
if "--only" in sys.argv:
    wanted = sys.argv[sys.argv.index("--only") + 1].split(",")
    mutants = [m for m in mutants if any(m[0].split(" ")[0] == w or (len(w) == 1 and m[0].startswith(w)) for w in wanted)]
    lanes = [lane for lane in lanes if any(m[1] == lane for m in mutants)]
for lane in lanes:
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout[-3000:]}{base.stderr[-3000:]}")
        sys.exit(2)
print("baseline green: " + ", ".join(lanes), flush=True)

survivors = infra = 0
for name, lane, rel, old, new in mutants:
    path = ROOT / rel
    src = path.read_text()
    count = src.count(old)
    if count != 1:
        print(f"{name}: NOT APPLIED (target found {count} times)", flush=True)
        infra += 1
        continue
    path.write_text(src.replace(old, new))
    try:
        assert path.read_text().count(new) >= 1 and path.read_text() != src, "the mutation did not land"
        r = run(lane)
        out = r.stdout + r.stderr
        failed = named(out)
        if r.returncode != 0 and failed:
            print(f"{name}: killed by {failed[:220]}", flush=True)
        elif r.returncode != 0:
            print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-800:]}", flush=True)
            infra += 1
        else:
            print(f"{name}: SURVIVED", flush=True)
            survivors += 1
    finally:
        path.write_text(src)
print(f"live meeting mutants: {len(mutants) - survivors - infra} killed, {survivors} survived, {infra} infrastructure")
sys.exit(1 if survivors or infra else 0)
