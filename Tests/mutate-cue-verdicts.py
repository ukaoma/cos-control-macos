#!/usr/bin/env python3
"""0.5.327: mutation gate for rating live cues.

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Then each mutant
must match its target EXACTLY ONCE, and is killed only when its lane fails with a named check ("... FAILED: ..." or a
failed precondition, or the page canary's assertion); a compile failure or any other exit is an infrastructure error, not
a kill. Compiles go through the lane, so through Tests/compile-guard.sh, one at a time, never in parallel.
Usage: python3 Tests/mutate-cue-verdicts.py [--lane pins|models|page|helper]
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANE = ROOT / "Tests" / "run-cue-verdicts.sh"
CORE = "Sources/MeetingAskCore.swift"
ASK = "Sources/MeetingAsk.swift"
MODEL = "Sources/ControllerModel.swift"
WINDOW = "Sources/ActivityWindow.swift"
PAGE = "Resources/memories/memories-app.js"
HELPER = "HelperSources/main.swift"

MUTANTS = [
    # The words, the keys, the floor and the store (Tests/CueVerdictsChecks.swift).
    ("M1 keys act without the card's focus", "models", CORE,
     "        guard cardFocused, !modified else { return nil }\n", "        guard !modified else { return nil }\n"),
    ("M2 keys act with Command, Option or Control", "models", CORE,
     "        guard cardFocused, !modified else { return nil }\n", "        guard cardFocused else { return nil }\n"),
    ("M3 a meeting's list has no 15-second floor", "models", CORE,
     "        if !force, let last = readAt[session], now().timeIntervalSince(last) < CueVerdicts.pollSeconds { return }\n", ""),
    ("M4 Refresh waits for the floor too", "models", CORE,
     "        if !force, let last = readAt[session],", "        if let last = readAt[session],"),
    ("M5 the floor is 5 seconds", "models", CORE,
     "    static let pollSeconds: TimeInterval = 15\n", "    static let pollSeconds: TimeInterval = 5\n"),
    ("M6 a second rating of a cue goes out while the first is in flight", "models", CORE,
     "        guard !saving.contains(cue.id) else { return }\n", ""),
    ("M7 two week reads at once", "models", CORE,
     '        guard reading.insert("week").inserted else { return }\n', '        reading.insert("week")\n'),
    ("M8 a 404 is not an older server", "models", CORE, "        case 404: return (.olderServer, nil)\n", ""),
    ("M9 a 404 does not hide the surfaces", "models", CORE,
     " : state == .olderServer ? false : available", " : available"),
    ("M10 another protocol version reads", "models", CORE, '            guard details["v"]?.int == 1, let rows', '            guard let rows'),
    ("M11 a 200 without ok is a save", "models", CORE,
     '            guard details["ok"]?.bool == true else { return .failed(status: 200) }\n', ""),
    ("M12 unknown_cue reads as an older server", "models", CORE,
     '        case "unknown_cue": return .unknownCue\n', '        case "unknown_cue": return .olderServer\n'),
    ("M13 clearing carries the note", "models", CORE,
     "        guard verdict != nil, let text = raw.map(note), !text.isEmpty,", "        guard let text = raw.map(note), !text.isEmpty,"),
    ("M14 a note runs past 200", "models", CORE,
     "            guard out.utf16.count + String(character).utf16.count <= noteMax else { break }\n",
     "            guard out.utf16.count + String(character).utf16.count <= noteMax * 2 else { break }\n"),
    ("M15 rating one does not move rated and unrated", "models", CORE,
     "        if old == nil { next.rated += 1; next.unrated = max(0, next.unrated - 1) }\n", ""),
    ("M16 skipped cues are not moved last", "models", CORE,
     "        let fresh = cues.filter { !skipped.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }\n",
     "        let fresh = cues.sorted { $0.createdAt < $1.createdAt }\n"),
    ("M17 a meeting keeps other meetings' cues", "models", CORE,
     "            let cues = history.cues.filter { $0.sessionId == session }\n", "            let cues = history.cues\n"),
    ("M18 an unreachable read leaves the last queue", "models", CORE,
     "        let next = CueVerdicts.queueOrder((history?.cues ?? []).filter { $0.verdict == nil }, skipped: skipped)\n        if queue != next { queue = next }\n",
     "        if let history { let next = CueVerdicts.queueOrder(history.cues.filter { $0.verdict == nil }, skipped: skipped); if queue != next { queue = next } }\n"),
    ("M19 the page is told to show its entries before any answer", "models", CORE,
     "        guard available == true, let counts else", "        guard available != false, let counts else"),
    ("M20 one failed poll drops the list", "models", CORE,
     "            if next.state != .loaded || missed >= 2 || state == .olderServer { next = Meeting(state: state) }",
     "            next = Meeting(state: state)"),
    ("M21 an older server waits for a second failure", "models", CORE, " || missed >= 2 || state == .olderServer {", " || missed >= 2 {"),
    ("M22 every poll publishes", "models", CORE, "        if meetings[session] != next { meetings[session] = next }\n", "        meetings[session] = next\n"),
    ("M23 the note rides in the arguments", "models", CORE,
     '        arguments.append("--note-stdin")\n        return (arguments, data)', '        arguments += ["--note", text]\n        return (arguments, nil)'),
    ("M24 a 503 is not the server updating", "models", CORE, "        case 503: return .unreachable\n", ""),
    ("M25 the saved titles are ignored", "models", CORE,
     '        for title in [row?.title ?? "", cue.savedTitle, cue.meetingTitle] where', "        for title in [cue.meetingTitle] where"),
    ("M26 armedAt is ignored", "models", CORE, "        guard let start = cue.armedAt ?? meetingStart(cue.sessionId)", "        guard let start = meetingStart(cue.sessionId)"),
    ("M27 a 404 page that is not JSON is not an older server", "models", CORE, '        case "unsupported": return (.olderServer, nil)\n', ""),
    # The view, the route, the release (Tests/cue-verdicts-pins.py).
    ("P1 the keys ignore the card's focus", "pins", ASK, "cardFocused: focus == .card)", "cardFocused: true)"),
    ("P2 the card never takes focus", "pins", ASK, "            .focused($focus, equals: .card)\n", ""),
    ("P3 the note is published on the store", "pins", CORE,
     "    private var skipped: [String] = []\n", '    private var skipped: [String] = []\n    @Published var noteText = ""\n'),
    ("P4 a tab switch leaves the pane open", "pins", WINDOW, "        model.closeDictationHistory()\n        model.closeCueReview()\n", "        model.closeDictationHistory()\n"),
    ("P5 Back does not close the pane", "pins", WINDOW,
     "        } else if section == .memories, model.cueReviewRouteActive {\n            model.closeCueReview()\n", ""),
    ("P6 the pane is not a detail", "pins", WINDOW, " || selectedGraphEntityID != nil || model.cueReviewRouteActive\n", " || selectedGraphEntityID != nil\n"),
    ("P7 Cues offered before the server answered with the history", "pins", ASK,
     "private var cuesOffered: Bool { store.available == true && G2MeetingStop", "private var cuesOffered: Bool { G2MeetingStop"),
    ("P8 the live poll forces every read", "pins", ASK,
     "                await store.loadMeeting(session, days: days, run: run)\n                try? await Task.sleep",
     "                await store.loadMeeting(session, days: days, force: true, run: run)\n                try? await Task.sleep"),
    ("P9 a saved meeting polls", "pins", ASK, "            guard polls else { return }\n", ""),
    ("P10 the route flag is written from outside", "pins", MODEL,
     "    @Published private(set) var cueReview: CueVerdicts.Review?", "    @Published var cueReview: CueVerdicts.Review?"),
    ("P11 the page opens any view it names", "pins", WINDOW,
     'if let view = (args["view"] as? String).flatMap(CueVerdicts.Review.init(rawValue:)) {', "if let view = Optional(CueVerdicts.Review.toRate) {"),
    ("P12 the cue views open a sheet", "pins", ASK,
     "        .onAppear { focus = .card }\n", "        .onAppear { focus = .card }\n        .sheet(isPresented: .constant(false)) { EmptyView() }\n"),
    # Version-independent since 0.5.328 (the pins keep 0.5.327's history rather than requiring it to be the newest).
    ("P13 the 0.5.327 CHANGELOG entry is lost", "pins", "CHANGELOG.md", "## 0.5.327 (build 380)", "## 0.5.3x (build 380)"),
    ("P14 the rate card shows the title at cue time", "pins", ASK,
     "CueRateCard(cue: cue, title: CueVerdicts.title(cue, library: model.libraryMeetings),", "CueRateCard(cue: cue, title: cue.meetingTitle,"),
    # The Memories page's entries (Tests/MemoriesCuesCanary.cjs).
    ("W1 the page shows its entries without available", "page", PAGE,
     "state.cues = d && d.available === true ? d : null;", "state.cues = d || null;"),
    ("W2 the page sends any view name", "page", PAGE,
     "call('cues.open', { view: view === 'rated' ? 'rated' : 'rate' })", "call('cues.open', { view: view })"),
    ("W3 the page never asks for the counts", "page", PAGE, "    loadCues();\n", ""),
    ("W4 the page draws any count it is given", "page", PAGE,
     "(typeof state.cues.unrated === 'number' && state.cues.unrated > 0 ?", "(state.cues.unrated ?"),
    # The helper (its self-test and Tests/cue-verdicts-helper-checks.py).
    ("H1 --days takes more than 30", "helper", HELPER, ", let count = Int(window), (1...30).contains(count) else { return nil }",
     ", let count = Int(window), count > 0 else { return nil }"),
    ("H2 --session is not checked on a read", "helper", HELPER,
     "            guard Self.liveCueSessionValid(session) else { return nil }\n            path +=", "            path +="),
    ("H3 clear takes a note", "helper", HELPER, '            guard verdict != "clear" else { return nil }\n', ""),
    ("H4 any verdict crosses", "helper", HELPER,
     '              Self.liveCueVerdicts.contains(verdict) || verdict == "clear" else { return nil }', "              !verdict.isEmpty else { return nil }"),
    ("H5 a refused read carries rows", "helper", HELPER,
     '        if let code = Self.liveCueErrorCode(body) { out["error"] = code }\n        guard status == 200 else { return out }\n        if let version',
     '        if let code = Self.liveCueErrorCode(body) { out["error"] = code }\n        if let version'),
    ("H6 a stored verdict crosses whole", "helper", HELPER,
     '        out["rating"] = Self.liveCueRating(raw["rating"] ?? raw["verdict"]) ?? NSNull()\n', '        out["rating"] = raw["rating"] ?? NSNull()\n'),
    ("H7 a note is not collapsed", "helper", HELPER,
     '        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")\n        var out = ""\n        for character in collapsed {\n            guard out.utf16.count + String(character).utf16.count <= Self.liveCueNoteMax',
     '        let collapsed = raw\n        var out = ""\n        for character in collapsed {\n            guard out.utf16.count + String(character).utf16.count <= Self.liveCueNoteMax'),
    ("H8 a read without a token reads as unreachable", "helper", HELPER,
     '            throw HelperError.message("Use --days 1 to 30 and a meeting session id")\n        }\n        guard let token = try? readToken() else {\n            emit(ok: true, message: "No pairing token", details: ["transport": "no_token"])',
     '            throw HelperError.message("Use --days 1 to 30 and a meeting session id")\n        }\n        guard let token = try? readToken() else {\n            emit(ok: true, message: "No pairing token", details: ["transport": "unavailable"])'),
    ("H9 a rating is a GET", "helper", HELPER, 'request(Self.liveCuesFeedbackPath, method: "POST"', 'request(Self.liveCuesFeedbackPath, method: "GET"'),
    ("H10 unknown_cue is lost", "helper", HELPER, '        for key in ["reason", "error"] {\n', '        for key in ["error"] {\n'),
    ("H11 a 404 page is never unsupported", "helper", HELPER, '        status == 404 && body == nil ? "unsupported" : "answered"', '        "answered"'),
    ("H12 stdin is not bounded", "helper", HELPER, "Self.liveCueStdinNote(try readBoundedStdin(4_096))", "Self.liveCueStdinNote(try readBoundedStdin(65_536))"),
    ("H13 a meeting's counters cross whole", "helper", HELPER, '                var row: [String: Any] = ["cues": cues]\n', "                var row: [String: Any] = meeting\n"),
]


def run(lane):
    env = dict(os.environ, COS_CUE_VERDICTS_LANE=lane)
    return subprocess.run(["zsh", str(LANE)], cwd=ROOT, env=env, capture_output=True, text=True)


only = sys.argv[sys.argv.index("--lane") + 1] if "--lane" in sys.argv else None
lanes = [lane for lane in ("pins", "models", "page", "helper") if only in (None, lane)]
mutants = [m for m in MUTANTS if m[1] in lanes]
for lane in lanes:
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout}{base.stderr}")
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
        r = run(lane)
        out = r.stdout + r.stderr
        failed_line = next((l for l in out.splitlines() if "FAILED:" in l or "Precondition failed" in l), None)
        if r.returncode != 0 and failed_line:
            print(f"{name}: killed by {failed_line.strip()[:220]}", flush=True)
        elif r.returncode != 0:
            print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-600:]}", flush=True)
            infra += 1
        else:
            print(f"{name}: SURVIVED", flush=True)
            survivors += 1
    finally:
        path.write_text(src)
print(f"cue verdicts mutants: {len(mutants) - survivors - infra} killed, {survivors} survived, {infra} infrastructure")
sys.exit(1 if survivors or infra else 0)
