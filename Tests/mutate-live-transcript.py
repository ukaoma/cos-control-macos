#!/usr/bin/env python3
"""Mutation lane for the live meeting transcript (0.5.278). Run by hand, never by a gate. SERIAL: one mutant at a time,
and every compile goes through Tests/compile-guard.sh (two kernel panics on 2026-10-07 came from parallel compiles).

    python3 Tests/mutate-live-transcript.py <worktree> <scratch dir> [name ...]

It copies the worktree once to <scratch dir>/copy, proves each UNMUTATED lane it will use green first (a red baseline
makes every mutant look killed), then applies one mutant at a time: the target text must appear exactly once, the
mutant must make the lane fail, and the failure must carry the words of the check that names the behaviour. A mutant
that lands and survives is a finding; so is one killed only by a compile error or by an unrelated check.
Lanes are Tests/run-live-transcript.sh's (COS_LIVE_TRANSCRIPT_LANE): pins (Python), models (LiveTranscript.swift +
Models.swift + LiveTranscriptChecks), helper (the compiled helper: its self-test and the fixture checks), wiring (the
whole app against a stand-in helper).
"""
import os, pathlib, shutil, subprocess, sys, time

P = "Sources/LiveTranscript.swift"
M = "Sources/Models.swift"
C = "Sources/ControllerModel.swift"
V = "Sources/Views.swift"
AM = "Sources/ActivityMeetings.swift"
AW = "Sources/ActivityWindow.swift"
H = "HelperSources/main.swift"
PIN = "live transcript pin FAILED"
CHK = "live transcript check FAILED"
HCK = "live-transcript helper check FAILED"
SELF = "self-test failed"

# (name, file, original, mutant, words the killing failure must contain, lane)
MUTANTS = [
    # ── The pure reducer, liveness, hand-off and copy (models lane).
    ("first copy of an index wins", P, "            chunks[chunk.i] = chunk\n", "            chunks[chunk.i] = chunks[chunk.i] ?? chunk\n", "the newer read of an index wins", "models"),
    ("turns not in index order", P, "        for index in chunks.keys.sorted() {", "        for index in chunks.keys.sorted(by: >) {", CHK, "models"),
    ("no speaker merge", P, "            if var last = out.last, last.speaker == speaker {", "            if var last = out.last, false, last.speaker == speaker {", CHK, "models"),
    ("turn id not its first index", P, "LiveTranscriptTurn(id: index, speaker: speaker,", "LiveTranscriptTurn(id: chunk.elapsedMs, speaker: speaker,", CHK, "models"),
    ("Unknown shown as a name", P, '["", "unknown", "speaker", "unidentified", "?", "none", "null"]', '["", "speaker", "unidentified", "?", "none", "null"]', CHK, "models"),
    ("cursor can go back", P, "cursor = max(cursor, settled)", "cursor = settled", "the --since cursor is never lowered", "models"),
    ("end time moves", P, "        guard endedAt == nil else { return false }\n        endedAt = now\n", "        endedAt = now\n", "a second ended read keeps the first end time", "models"),
    ("restored file stays ended", P, "            endedAt = nil; phase = .live; serverState = nil; lastStatusCheck = nil\n", "", "is live again", "models"),
    ("stamp never switches to hours", P, "        return hours > 0 ? String(", "        return hours > 99 ? String(", "the copy golden", "models"),
    ("copy header loses the start", P, '            header += " · " + formatter.string(from: startTime)\n', "", "the copy golden", "models"),
    ("poll ignores the setting", P, "        enabled && visible && ((serverLive ?? 0) > 0 || pendingHandoff)", "        visible && ((serverLive ?? 0) > 0 || pendingHandoff)", "the setting off never polls", "models"),
    ("poll ignores visibility", P, "        enabled && visible && ((serverLive ?? 0) > 0 || pendingHandoff)", "        enabled && ((serverLive ?? 0) > 0 || pendingHandoff)", "nobody looking never polls", "models"),
    ("rows ignore the server's count", P, "        if (serverLive ?? 0) > 0 {\n            for file", "        if true {\n            for file", "no row while the server reports no live session", "models"),
    ("stale sessions get a row", P, "for file in files where !stale.contains(file.sessionId) && !stranded.contains(file.sessionId) {", "for file in files where !stranded.contains(file.sessionId) {", "stale and stranded", "models"),
    ("stranded sessions get a row", P, "for file in files where !stale.contains(file.sessionId) && !stranded.contains(file.sessionId) {", "for file in files where !stale.contains(file.sessionId) {", "stale and stranded", "models"),
    ("ended stranded listed twice", P, "            guard feed.phase != .saved, !stranded.contains(feed.sessionId) else { continue }", "            guard feed.phase != .saved else { continue }", "not listed twice", "models"),
    ("ended row never expires", P, "            if feed.phase == .endedUnsaved, let ended = feed.endedAt, now.timeIntervalSince(ended) > endedRowLifetime { continue }\n", "", "stays ten minutes", "models"),
    ("saved row not preferred", P, "        if savedRowFound { return .saved }\n", "", "the saved row found opens it", "models"),
    ("no unsaved grace", P, "return waited >= unsavedGrace ? .endedUnsaved : .finalizing", "return .endedUnsaved", "closed or missing after a short grace", "models"),
    ("no finalizing deadline", P, "        return waited >= finalizingDeadline ? .notFoundYet : .finalizing", "        return .finalizing", "Finalizing until 3 minutes", "models"),
    ("quiet after one minute", P, "    static let quietAfterSeconds: TimeInterval = 120", "    static let quietAfterSeconds: TimeInterval = 60", "No audio for Xm", "models"),
    ("reason code lets text through", P, "code.allSatisfy({ allowed.contains($0) })", "true", "never text", "models"),
    ("growing text reads as scrolled up", P, "        guard now.timeIntervalSince(lastAutoScroll) > Self.settle, now.timeIntervalSince(lastContentChange) > Self.settle else { return }\n", "", "is not the reader scrolling up", "models"),
    ("selection resumes at the bottom", P, "        if !selecting { following = true }", "        following = true", "does not resume", "models"),
    ("em dash in the header", P, 'static let header = "Live transcript · preliminary · may change when saved"', 'static let header = "Live transcript \u2014 preliminary \u2014 may change when saved"', "no em dash", "models"),
    ("status live count not read", M, '        liveTranscriptionSessions = details["liveTranscriptionSessions"]?.int\n', "", "status carries live and stale", "models"),

    # ── The helper (helper lane: its self-test, then the fixture checks).
    ("dot allowed in an id", H, '|| s == ":" || s == "_" || s == "-"\n', '|| s == ":" || s == "_" || s == "-" || s == "."\n', "abc.tmp", "helper"),
    ("two-character ids", H, "        guard (3...96).contains(scalars.count) else { return false }", "        guard (2...96).contains(scalars.count) else { return false }", "refuses the session id", "helper"),
    ("containment not checked", H, '        return folder.lastPathComponent == "active-sessions"\n            && resolved.deletingLastPathComponent().standardizedFileURL.path == folder.path\n',
     '        return folder.lastPathComponent == "active-sessions"\n', "directly inside active-sessions", "helper"),
    ("list keeps any name", H, '        for name in names where name.hasSuffix(".json") {', "        for name in names {", "names without .json", "helper"),
    ("list keeps symlinks", H, "            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }", "            guard lstat(file.path, &info) == 0 else { continue }", "symlinks", "helper"),
    ("symlinks followed", H, "        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)", "        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)", "symlink", "helper"),
    ("FIFO read as a file", H, "        guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else { throw LiveTranscriptFailure(reason: \"unsafe_file\") }\n        let stamp",
     "        guard fstat(descriptor, &opened) == 0 else { throw LiveTranscriptFailure(reason: \"unsafe_file\") }\n        let stamp", "FIFO", "helper"),
    ("no size cap", H, "        guard opened.st_size <= liveTranscriptMaxFileBytes else { throw LiveTranscriptFailure(reason: \"too_large\") }\n        // The server replaces",
     "        // The server replaces", "over 64 MB", "helper"),
    ("stamp never matches", H, "        if let knownStamp, knownStamp == stamp {", "        if let knownStamp, knownStamp == stamp + \"x\" {", "not read again", "helper"),
    ("since includes the cursor", H, ".filter { $0 > since }", ".filter { $0 >= since }", "--since returns only", "helper"),
    ("silence does not settle", H, '            if let index = Int(key), index >= 0 { settled.insert(index) }\n', "", "silence does not", "helper"),
    ("a dropped chunk does not settle", H, '        settled.formUnion(liveTranscriptIndexes(object["asrCompletedIndices"]))\n', "", "a dropped chunk", "helper"),
    ("an old hole holds the cursor forever", H, "settled.contains(index) || index < newest - liveTranscriptSettleWindow", "settled.contains(index)", "50 behind", "helper"),
    ("a fresh hole does not hold the cursor", H, "settled.contains(index) || index < newest - liveTranscriptSettleWindow", "settled.contains(index) || index < newest", "holds the cursor before it", "helper"),
    ("segments leave the helper", H, '            chunks[index] = [\n                "i": index,', '            chunks[index] = [\n                "segments": chunk["segments"] ?? NSNull(),\n                "i": index,', "each chunk carries only", "helper"),
    ("providerCandidates leaves", H, '            "turns": turns,\n        ]', '            "turns": turns,\n            "candidates": object["providerCandidates"] ?? NSNull(),\n        ]', "providerCandidates", "helper"),
    ("empty text kept", H, "!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }", "true else { continue }", "empty text", "helper"),
    ("status keeps counts", H, '        var details: [String: Any] = ["sessionId": sessionId, "state": known.contains(state) ? state : "unknown"]',
     '        var details: [String: Any] = ["sessionId": sessionId, "state": known.contains(state) ? state : "unknown", "receivedCount": body["receivedCount"] ?? 0]', "keeps only the state", "helper"),
    ("older server is a failure", H, '        if status == 404 { return (true, ["sessionId": sessionId, "state": "unknown", "reason": "route_absent"]) }\n', "", "an older server", "helper"),
    ("status sends a bad id", H, '        guard let sessionId = option("--session", in: args), Self.liveTranscriptValidId(sessionId) else {\n            emit(ok: false, message: "Live transcript status unavailable',
     '        guard let sessionId = option("--session", in: args) else {\n            emit(ok: false, message: "Live transcript status unavailable', "a bad id never reaches the server", "helper"),
    ("any data dir taken", H, "        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path == value ? URL(fileURLWithPath: value, isDirectory: true) : nil",
     "        return URL(fileURLWithPath: value, isDirectory: true)", "data directory", "helper"),
    ("stale ids unchecked", H, '.compactMap { ($0 as? [String: Any])?["sessionId"] as? String }.filter(liveTranscriptValidId)', '.compactMap { ($0 as? [String: Any])?["sessionId"] as? String }', "stale session ids", "helper"),
    ("helper prints progress", H, '        let turns = chunks.keys.sorted().filter { $0 > since }.compactMap { chunks[$0] }\n',
     '        let turns = chunks.keys.sorted().filter { $0 > since }.compactMap { chunks[$0] }\n        FileHandle.standardError.write(Data("\\(turns)".utf8))\n', "nothing on stderr", "helper"),

    # ── The secret boundary and wiring, as pins (pins lane). Each is a regression the pins exist for.
    ("model logs the text", C, '        liveTranscriptCopyNote = "Copied preliminary transcript"\n', '        NSLog("live %@", text)\n        liveTranscriptCopyNote = "Copied preliminary transcript"\n', "NSLog", "pins"),
    ("model prints the text", C, '        liveTranscriptCopyNote = "Copied preliminary transcript"\n', '        print(text)\n        liveTranscriptCopyNote = "Copied preliminary transcript"\n', "print", "pins"),
    ("model raises the error text", C, "            liveTranscriptReason = Self.liveTranscriptReasonCode(error)\n", "            self.error = error.localizedDescription\n", PIN, "pins"),
    ("helper logs progress", H, '        let turns = chunks.keys.sorted().filter { $0 > since }.compactMap { chunks[$0] }\n',
     '        let turns = chunks.keys.sorted().filter { $0 > since }.compactMap { chunks[$0] }\n        progress("read \\(turns.count)")\n', "stderr progress", "pins"),
    ("pure layer logs", P, "    static func displaySpeaker(_ raw: String) -> String {\n", "    static func displaySpeaker(_ raw: String) -> String {\n        print(raw)\n", "never logs", "pins"),
    ("views log", AM, "struct LiveTurnRow: View {\n    let turn: LiveTranscriptTurn\n    var body: some View {\n",
     "struct LiveTurnRow: View {\n    let turn: LiveTranscriptTurn\n    var body: some View {\n        let _ = print(turn.text)\n", "never log", "pins"),
    ("report reads live files", H, "        let doctor = doctorDetails(redacted: true)\n", "        let doctor = doctorDetails(redacted: true)\n        let live = try? Self.liveTranscriptList(dataDir: glassesDataDir())\n", "Copy Report", "pins"),
    ("status drops the live count", H, '            "liveTranscriptionSessions": maintenance?["liveTranscriptionSessions"] ?? NSNull(),\n', "", "live count", "pins"),
    ("poll before the setting", C, "    func pollLiveTranscriptOnce() async {\n        guard liveTranscriptEnabled else { return }\n", "    func pollLiveTranscriptOnce() async {\n", "first line refuses", "pins"),
    ("no didWake", C, "            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main", "            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main", "didWake", "pins"),
    ("row in the picker", AM, "            if !selectionOnly && showLiveTranscript {\n                LiveNowRows(model: model)", "            if showLiveTranscript {\n                LiveNowRows(model: model)", "hidden in the picker", "pins"),
    ("toggle placed twice", V, '            Toggle("Show live meeting transcript", isOn: $showLiveTranscript)\n', '            Toggle("Show live meeting transcript", isOn: $showLiveTranscript)\n            Toggle("Show live meeting transcript", isOn: $showLiveTranscript)\n', "placed once", "pins"),
    ("window close keeps polling", AW, "        model?.liveTranscriptWindowClosed()\n", "", "stops the live poll", "pins"),
    ("pane mounted without its flag", AW, "                } else if section == .meetings, model.liveTranscriptRouteActive {\n                    LiveTranscriptPane(model: model)",
     "                } else if section == .meetings, model.liveTranscriptOpenID != nil || true {\n                    LiveTranscriptPane(model: model)", "own route flag", "pins"),
    ("no rail dot", AW, "                            if item == .meetings, showLiveTranscript, model.liveTranscriptDot {", "                            if item == .meetings, model.liveTranscriptDot {", "lens rail", "pins"),
    ("arrow in the row", AM, '                Text("Live transcript")\n', '                Text("Live transcript \u2192")\n', "arrow", "pins"),

    # ── The model with the whole app (wiring lane).
    ("setting off still polls", C, "        guard liveTranscriptEnabled else { return }\n        var args = [\"live-transcript\"]", "        var args = [\"live-transcript\"]", "setting off spawns nothing", "wiring"),
    ("loop ignores the setting", C, "        LiveTranscript.shouldPoll(enabled: liveTranscriptEnabled, visible:", "        LiveTranscript.shouldPoll(enabled: true, visible:", "setting off shows nothing", "wiring"),
    ("hand-off asks with the setting off", C, "    func checkLiveTranscriptHandoffs(now: Date) async {\n        guard liveTranscriptEnabled else { return }\n", "    func checkLiveTranscriptHandoffs(now: Date) async {\n", "setting off", "wiring"),
    ("two reads at once", C, "        guard liveTranscriptTask == nil, liveTranscriptShouldPoll else { return }", "        guard liveTranscriptShouldPoll else { return }", "one read at a time", "wiring"),
    ("wake waits for the tick", C, "                while waited < LiveTranscript.pollSeconds, !Task.isCancelled, !self.liveTranscriptImmediate {", "                while waited < LiveTranscript.pollSeconds, !Task.isCancelled {", "didWake reads at once", "wiring"),
    ("data dir looked up every read", C, '        if let dir = liveTranscriptDataDir { args += ["--data-dir", dir] }\n', "", "the data directory is looked up once per loop", "wiring"),
    ("cursor not passed", C, 'args += ["--session", target, "--since", String(feed?.cursor ?? -1)]', 'args += ["--session", target]', "the cursor is passed back", "wiring"),
    ("matched by filename", C, "        meeting.sessionId == sessionId || meeting.g2SessionIds.contains(sessionId)", "        meeting.sessionId == sessionId || meeting.filename.hasPrefix(\"2026-10-10_G2_Recording\")", "never by filename", "wiring"),
    ("merged meetings missed", C, "        meeting.sessionId == sessionId || meeting.g2SessionIds.contains(sessionId)", "        meeting.sessionId == sessionId", "no hang", "wiring"),
    ("failure keeps the text", C, "        case .invalidResponse: return \"invalid_response\"", "        case .invalidResponse(let text): return text", "an invalid answer is a code", "wiring"),
    ("a file that left is not ended", C, "            feeds[id]?.markEnded(now: now)\n", "", "a file that left the list ends", "wiring"),
    ("setting off keeps the text", C, "        liveTranscriptFeeds = [:]\n        liveTranscriptFiles = []\n", "        liveTranscriptFiles = []\n", "forgets the text", "wiring"),
]


def run(lane, copy):
    env = dict(os.environ, COS_LIVE_TRANSCRIPT_LANE=lane, COS_COMPILE_MIN_FREE_GB=os.environ.get("COS_COMPILE_MIN_FREE_GB", "20"))
    while True:
        p = subprocess.run(["/bin/zsh", str(copy / "Tests/run-live-transcript.sh")], capture_output=True, text=True, timeout=2400, env=env)
        if p.returncode != 75:  # 75: compile-guard found too little free memory; wait and try again
            return p.returncode, p.stdout + p.stderr
        time.sleep(30)


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    chosen = [m for m in MUTANTS if not only or m[0] in only]
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "dist", "*.zip"))
    for lane in ("pins", "models", "helper", "wiring"):
        if not any(m[5] == lane for m in chosen):
            continue
        code, out = run(lane, copy)
        if code != 0:
            sys.exit(f"baseline {lane} lane is RED; no mutant can be judged:\n{out[-3000:]}")
        print(f"baseline {lane}: green ({out.strip().splitlines()[-1] if out.strip() else ''})", flush=True)
    survived, results = [], []
    for name, rel, original, mutant, words, lane in chosen:
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(original) != 1:
            results.append(f"MISSED TARGET ({text.count(original)}x) {name}")
            survived.append(name)
            print(results[-1], flush=True)
            continue
        path.write_text(text.replace(original, mutant), encoding="utf-8")
        started = time.time()
        try:
            code, out = run(lane, copy)
        finally:
            path.write_text(text, encoding="utf-8")
        took = time.time() - started
        if code == 137:
            sys.exit(f"compile guard stopped the run at mutant {name}; stopping the lane")
        failing = next((l for l in out.splitlines() if "FAILED" in l or "failed" in l), "")
        if code == 0:
            results.append(f"SURVIVED {name}")
            survived.append(name)
        elif words in out and (words == "error:" or "error:" not in out or "FAILED" in out or "failed [" in out):
            results.append(f"killed  {name}  ({took:.0f}s) {failing[:150]}")
        elif "error:" in out:
            results.append(f"WEAK (compile error) {name}")
            survived.append(name)
        else:
            results.append(f"WEAK (another check) {name}: {failing[:200] or out.strip().splitlines()[-1][:200]}")
            survived.append(name)
        print(results[-1], flush=True)
    print(f"{len(results) - len(survived)} of {len(results)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
