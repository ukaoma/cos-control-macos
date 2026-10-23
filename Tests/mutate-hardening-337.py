#!/usr/bin/env python3
"""0.5.337 hardening mutation lane. Run by hand, never by a gate.

    python3 Tests/mutate-hardening-337.py <worktree> <scratch dir> [name ...]

Copies the worktree to <scratch dir>/copy, proves the UNMUTATED lane green first (Tests/run-hardening-337.sh: the pins,
then the checks), then applies one mutant at a time: the target must appear exactly once, the mutant must make a check
fail, and the failure must name the fix it breaks. The copy is restored and compared byte for byte after every mutant.
A mutant that lands and survives is a finding. One suite at a time; every compile goes through the guard.
"""
import os
import filecmp, pathlib, shutil, subprocess, sys, time

M = "Sources/Models.swift"
W = "Sources/ActivityWindow.swift"
CM = "Sources/ControllerModel.swift"
WW = "Sources/WorkWorkspaceView.swift"
H = "HelperSources/main.swift"
LT = "Sources/LiveTranscript.swift"
MA = "Sources/MeetingAskCore.swift"
LP = "Sources/WorkLensPlans.swift"
WO = "Sources/WorkOrchestrator.swift"
DC = "Sources/MacDictationCore.swift"
MD = "Sources/MacDictation.swift"
TC = "Sources/WorkTaskChat.swift"
Q = "Sources/WorkChatQueue.swift"
LPP = "Sources/WorkLensPlansPump.swift"
AM = "Sources/ActivityMeetings.swift"
BR = "Sources/COSBrand.swift"
SP = "Sources/SessionPet.swift"
MO = "Sources/COSMotion.swift"
V = "Sources/Views.swift"
HC = "Sources/HelperClient.swift"
MR = "Sources/MacRecording.swift"
MUTANTS = [
    # Rules (executed in Tests/Hardening337Checks.swift)
    ("W1: unsupported never read", M, '    static func unsupported(_ details: [String: JSONValue]) -> Bool { details["unsupported"]?.bool == true }', '    static func unsupported(_ details: [String: JSONValue]) -> Bool { false }', "[W1 unsupported]"),
    ("W1: Undo before the server is known", M, "{ available == true && !unsupported.contains(\"undo\") }", "{ available != false && !unsupported.contains(\"undo\") }", "[W1 undo]"),
    ("W1: Undo after undo was missing", M, "{ available == true && !unsupported.contains(\"undo\") }", "{ available == true }", "[W1 undo]"),
    ("W5: a recording slows down", M, "        if recording { return tick }\n", "", "[W5 cadence]"),
    ("W5: locked stays fast", M, "        if locked { return idle }\n", "", "[W5 cadence]"),
    ("W5: nothing on screen stays fast", M, "        return panelVisible || activityOnScreen ? tick : idle", "        return tick", "[W5 cadence]"),
    ("W5: due ignores the cadence", M, "        return now.timeIntervalSince(last) >= seconds - 1", "        return true", "[W5 due]"),
    ("W5: extras always read", M, "{ panelVisible || activityOnScreen || recording }", "{ true }", "[W5 extras]"),
    ("W4: occlusion ignored", M, "{ occluded || locked || displayAsleep }", "{ locked || displayAsleep }", "[W4 pause]"),
    ("B2: the clock never pauses", M, "            next = paused ? nil : current.addingTimeInterval(frameInterval)", "            next = current.addingTimeInterval(frameInterval)", "[B2 clock]"),
    ("W2: queued not counted", LP, "            count.queued += (round.assignments ?? []).filter { $0.state == queuedState }.count\n", "", "[W2 count]"),
    ("W2: glasses rounds counted when sent", LP, '            if round.origin == "glasses", round.state == "Ready to send" { count.fromGlasses += 1 }', '            if round.origin == "glasses" { count.fromGlasses += 1 }', "[W2 count]"),
    ("W2: another server counted", LP, "record.serverID == server else { return nil }", "true else { return nil }", "[W2 count]"),
    ("W2: a stale round noticed again", LP, "        if after.needsPlan > before.needsPlan {", "        if after.needsPlan > 0 {", "[W2 notice]"),
    ("W15: full at 101", LP, "    static func isFull(rounds: Int) -> Bool { rounds >= roundCap }", "    static func isFull(rounds: Int) -> Bool { rounds > roundCap }", "[W15 cap]"),
    ("W15: the lens never hears full", LP, "{ isFull(rounds: rounds) ? historyFull : notInHistory }", "{ notInHistory }", "[W15 lens]"),
    ("W8: the meeting cap ignored", MA, "        if let cap = count.cap, cap > 0, count.cues >= cap {", "        if let cap = count.cap, cap > 0, count.cues > cap {", "[W8 meeting]"),
    ("W8: a zero daily limit is reached", MA, "daily > 0,\n           let used = limits?.usage?.writerCalls, used >= daily {", "\n           let used = limits?.usage?.writerCalls, used >= daily {", "[W8 daily]"),
    ("W8: cues off unsaid", MA, '        if cuesOn == false { return "Live cues is off in Settings, so this meeting has no cues." }\n', "", "[W8 empty]"),
    ("W9: the budget called today's", LT, '"this week\'s live cues limit is used up, and cues start again next week"', '"today\'s cue budget is used up"', "[W9 words]"),
    ("W9: every refusal gets the key opener", LT, '        return arm.reason == "decision_not_configured" || arm.reason == "jev_not_configured"', "        return true", "[W9 key]"),
    ("W7 perf: a cue in every turn", LT, "        for cue in cues { if let turn = turnOf[id(cue)] { out[turn, default: []].append(cue) } }", "        for cue in cues { for turn in anchored.keys { out[turn, default: []].append(cue) } }", "[W7 lookup]"),
    ("N14: the breaker never retries", LT, "    func mayPost(now: Date) -> Bool { open || (lastPost.map { now.timeIntervalSince($0) >= Self.breakerPause } ?? false) }", "    func mayPost(now: Date) -> Bool { open }", "[N14 breaker]"),
    ("W4: the breaker is not a pause", DC, '        return ["daily_cap", "breaker_open"].contains(code) ? code : nil', '        return code == "daily_cap" ? code : nil', "[W4 code]"),
    ("W4: the pill every dictation", DC, "    static func shouldFlash(lastFlashedDay: String?, today: String) -> Bool { lastFlashedDay != today }", "    static func shouldFlash(lastFlashedDay: String?, today: String) -> Bool { true }", "[W4 once]"),
    ("W4: a timeout clears the line", DC, "        case .applied, .unchanged: return true", "        case .applied, .unchanged, .timeout: return true", "[W4 clear]"),
    ("W7: a queued turn cannot stop", WO, '        case "queue":\n', '        case "queue-never":\n', "[W7 stop]"),
    ("W7: any answer stopped it", WO, '        case "cancelled": return (true, "Stopped. It was taken out of the session\'s queue and was not sent.")', '        case "cancelled", "": return (true, "Stopped. It was taken out of the session\'s queue and was not sent.")', "[W7 stop]"),
    ("W6: no Stop on reviewed rounds", WO, "        case .cancelJob, .cancelTurn, .cancelQueued: return action", "        case .cancelJob, .cancelTurn: return action", "[W6 stop]"),
    ("W6: unsent rows get Stop on reviewed rounds", WO, "        if sentWithoutReview { return action }", "        if true { return action }", "[W6 stop]"),
    ("W5: a run opens the wrong session", M, "        return receipts.first { $0.id == id }?.sessionID", "        return receipts.first?.sessionID", "[W5 open]"),
    ("W5: no Stop job on the row", M, "                               stopJobID: run.jobID))", "                               stopJobID: nil))", "[W5 stop]"),
    ("W5: finished runs lose Open result", M, 'openLabel: row.openLabel ?? "In Sessions",', 'openLabel: "In Sessions",', "[W5 finished]"),
    ("W12: Named stays forever", M, "        now >= named.at && now.timeIntervalSince(named.at) < namedLineSeconds", "        now >= named.at", "[W12 named]"),
    ("B1: the stamp ignores fractions", M, "        return WorkIntakeItem.stamp(trimmed)", "        return ISO8601DateFormatter().date(from: trimmed)", "[B1 stamp]"),
    ("tick: hidden wakes every second", M, "            guard await wait(visible() ? step : hiddenStep) else { return }", "            guard await wait(step) else { return }", "[tick]"),
    ("W16: a discarded capture comes back", M, "{ rows.filter { !discarded.contains($0.sessionId) } }", "{ rows }", "[W16 discard]"),
    # Wiring (pins)
    ("W1: dismiss-only 404", H, '        if response.status == 404 { emit(ok: true, message: "Update the server to use this Work action"', '        if response.status == 404, action == "dismiss" { emit(ok: true, message: "Update the server to use this Work action"', "[W1 404]"),
    ("W1: unsupported is an error", CM, "                workLoopUnsupported.insert(action); workLoopError = nil\n", "                workLoopUnsupported.insert(action)\n", "[W1 no error]"),
    ("W1: Expired always shown", WW, "            if model.workExpiryAvailable {\n                HStack {", "            if true {\n                HStack {", "[W1 expired]"),
    ("W1: Undo always offered in Work", WW, "            if model.workUndoAvailable {\n", "            if true {\n", "[W1 undo]"),
    ("W1: seen on every row", WW, 'if !model.workLoopUnsupported.contains("seen") {', "if true {", "[W1 seen]"),
    ("W2: counts every pass even unchanged", CM, "if self?.workChatCounts != counts { self?.workChatCounts = counts }", "self?.workChatCounts = counts", "[W2 model]"),
    ("W2: no card line", WW, "            if let line = model.workChatCounts[item.sourceID]?.line {", "            if let line = Optional<String>.none {", "[W2 card]"),
    ("W11: every lens round notified", LPP, "        if !already, !noticed.contains(round.roundId), !on {", "        if !noticed.contains(round.roundId) {", "[W11 lens]"),
    ("W3: no blockers listed", Q, "            ForEach(blocking) { receipt in", "            ForEach([WorkHandoffReceipt]()) { receipt in", "[W3 blockers]"),
    ("W4: no Settings line", MD, "                if store.polishModel != .off, let pause = store.polishPause {", "                if false, let pause = store.polishPause {", "[W4 line]"),
    ("W5: Prep opens an empty Sessions", W, 'todayOpen(.workRun(handoffStore.receipts(for: target).first?.id ?? ""))', 'todayOpen(.workRun(""))', "[W5 prep]"),
    ("W5: any answer stopped the run", W, 'flash((200..<300).contains(http) ? "Asked the server to stop it."', 'flash(true ? "Asked the server to stop it."', "[W5 stop]"),
    ("W7: a queued Stop marks every answer Skipped", TC, "            if verdict.stopped, let rounds = record?.rounds,", "            if let rounds = record?.rounds,", "[W7 queue]"),
    ("W9: no key opener", AM, "                    if LiveMeeting.needsDecisionKey(arm) {", "                    if false {", "[W9 key]"),
    ("W10: saved Mac cues hidden", AM, "                                                 macCues: model.liveMeetingCapability.macCues, askTitle: \"Meeting Ask\") {", "                                                 askTitle: \"Meeting Ask\") {", "[W10 saved]"),
    ("W13: a failed read vanishes", MD, 'func load() async { loadFailed = !(await send("get")) }', 'func load() async { _ = await send("get") }', "[W13 polish]"),
    ("W14: a failed save drops the edit", MD, "                suggestions = DictationSuggestions.suggesting(item, in: suggestions, now: Date()); saveSuggestions()\n                dictationLog.notice(\"learn save failed, kept as a suggestion\"); return", "                dictationLog.notice(\"learn save failed, kept as a suggestion\"); return", "[W14 learn]"),
    ("W15: Plan on a full card", TC, "            || full\n", "\n", "[W15 cap]"),
    ("B1: the list per row", W, "                            sessionRow(session, ambiguous: ambiguous)", "                            sessionRow(session, ambiguous: ClaudeSession.ambiguousTitles(in: visibleSessions))", "[B1 list]"),
    ("W3 svg: read from disk each time", BR, "        if let cached = cache[name] { return cached }\n", "", "[W3 svg]"),
    ("W4: the pet never pauses", MO, "paused: paused || (reduceMotion && frames.count <= 1)", "paused: reduceMotion && frames.count <= 1", "[W4 pet]"),
    ("W4: the pet polls while locked", SP, "                if model.screenLocked || model.displayAsleep { continue }\n", "", "[W4 poll]"),
    ("W5: every status republished", CM, "            if bytes == nil || bytes != statusDetailsBytes {", "            if true {", "[W5 refresh]"),
    ("W5: a stale byte cache", CM, "didSet { recordingCountChanged(); statusDetailsBytes = nil }", "didSet { recordingCountChanged() }", "[W5 bytes]"),
    ("W6: a closed What's New still observes", V, "            MainActor.assumeIsolated { self?.slot.live = false }", "            MainActor.assumeIsolated { _ = self }", "[W6 whats new]"),
    ("W7: AppStorage per drag event", AM, "                            if let dragWidth { askWidth = dragWidth }\n", "", "[W7 drag]"),
    ("B2: geometry around the frame", W, "        TimelineView(TodayFrameSchedule(paused: !today.windowVisible)) { timeline in", "        TimelineView(TodayFrameSchedule(paused: false)) { timeline in", "[B2 frame]"),
    ("N10: the title flips", CM, "        if let kept = liveMeetingTitlesKept[sessionId] { return kept }\n", "", "[N10 title]"),
    ("N12: adding with files off", AM, "        guard let files = model.workHandoffStore?.meetingFiles, files.enabled else { return false }", "        guard let files = model.workHandoffStore?.meetingFiles else { return false }", "[N12 drop]"),
    ("P-W8: back on the pool", HC, "              Self.runQueue.async {", "              Task.detached(priority: .userInitiated) {", "[P-W8 queue]"),
    ("W16: the set forgotten at launch", MR, "forKey: MacRecordingStore.discardedKey) }", "forKey: \"unused\") }", "[W16 discard]"),
    # Miles 2026-10-22 21:11
    ("fix frame: no flip above the caret", DC, "            if y < screen.minY + margin { y = caret.maxY + margin }   // no room below: above it\n", "", "[fix frame]"),
    ("fix frame: past the right edge", DC, "        x = min(max(x, screen.minX + margin), screen.maxX - margin - width)", "        x = max(x, screen.minX + margin)", "[fix frame]"),
    ("fix frame: taller than the screen", DC, "height = max(1, min(size.height, screen.height - 2 * margin))", "height = max(1, size.height)", "[fix frame]"),
    ("fix frame: the old bottom-edge frame", MD, "        let frame = DictationOverlayFrame.place(size: size, caret: nil, screen: screen)", "        let frame = NSRect(x: (screen.midX - size.width / 2).rounded(), y: screen.minY + 8, width: size.width, height: size.height)", "[fix frame]"),
    ("fix frame: never re-placed after a resize", MD, "            MainActor.assumeIsolated { self?.panelResized() }", "            MainActor.assumeIsolated { _ = self }", "[fix frame]"),
    ("own learn: a slice past the end", DC, "        guard location >= 0, length >= 0, location + length <= units.count else { return nil }", "        guard location >= 0, length >= 0 else { return nil }", "[own learn]"),
    ("own learn: never started", MD, "            editWatcher.startOwn(own, mode: learnMode) { [weak self] candidate in self?.editLearned(candidate, app: own.app) }", "            editWatcher.stop(\"own\")", "[own learn]"),
    ("own learn: Off ignored", MD, "        let eligibility = DictationEditLearning.eligibility(mode: mode, secure: IsSecureEventInputEnabled(), terminal: false,", "        let eligibility = DictationEditLearning.eligibility(mode: .automatic, secure: IsSecureEventInputEnabled(), terminal: false,", "[own learn]"),
    ("own learn: no target carried", MD, "            if case .inserted = outcome { delivered.own = target }", "            _ = target", "[own learn]"),
    ("composer: one row always", TC, "        ViewThatFits(in: .horizontal) {", "        Group {", "[composer]"),
    ("composer: buttons wrap", TC, "        }\n        .fixedSize()\n    }\n    var body: some View {", "        }\n    }\n    var body: some View {", "[composer]"),
    ("W17: no Undo after Create", W, "                    if today.createdUndo[item.id] != nil, model.workUndoAvailable {", "                    if false {", "[W17 undo]"),
]

def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    # 0.5.267: every compile in the lane runs through Tests/compile-guard.sh; a guard stop ends the lane (it is not a kill).
    if "compile-guard: STOPPED" in proc.stdout + proc.stderr:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + (proc.stderr or "")[-400:])
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started

def suite(copy):
    return run(["zsh", "Tests/run-hardening-337.sh"], copy)

def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    # Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
    os.environ.setdefault("COS_TEST_KIT_DIR", str(scratch / "kits"))
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "HelperSources"):
        shutil.copytree(src / part, copy / part)
    code, out, seconds = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS:")]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(p[:140] for p in passed) or '(no PASS line)'}", flush=True)
    if code != 0 or len(passed) != 2:
        print(out[-3000:])
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed, survived = 0, 0
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        mutated = text.replace(old, new)
        path.write_text(mutated, encoding="utf-8")
        try:
            code, out, seconds = suite(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        if not filecmp.cmp(path, src / rel, shallow=False):
            sys.exit(f"RESTORE FAILED for {name}: {rel} differs from the worktree")
        lines = [l for l in out.splitlines() if "check failed [" in l or "hardening pin:" in l or ": error:" in l]
        reason = lines[0].strip() if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:240]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:240]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 else 1)

if __name__ == "__main__":
    main()
