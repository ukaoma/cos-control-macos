#!/usr/bin/env python3
"""Activity Today home (plan v2) mutation lane. Run by hand, never by a gate.

    python3 Tests/mutate-activity-today.py <worktree> <scratch dir> [name ...]

Copies the worktree to <scratch dir>/copy, proves the UNMUTATED lane green first (Tests/activity-today-pins.py, then
Tests/run-activity-today.sh), then applies one mutant at a time: the target must appear exactly once, the mutant must make a
check fail, and the failure must name the behaviour it breaks. The copy is restored and compared byte for byte after every
mutant. A mutant that lands and survives is a finding. One suite at a time; every compile goes through the guard.
"""
import os
import filecmp, pathlib, shutil, subprocess, sys, time

M = "Sources/Models.swift"
W = "Sources/ActivityWindow.swift"
H = "HelperSources/main.swift"
MUTANTS = [
    # B1 tool-name guard (QA round 1 item 9: known names only, brands stay)
    ("guard: a known tool name passes", M, "        toolNames.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))\n", "        false\n", "[a bare tool name is caught]"),
    ("guard: CamelCase brands taken for tools", M, "        toolNames.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))\n",
     '        toolNames.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) || text.range(of: "^[A-Z][a-z0-9]+([A-Z][A-Za-z0-9]*)+$", options: .regularExpression) != nil\n', "[a brand title is never taken for a tool]"),
    ("guard: the question text is not guarded", M, "if let text = guarded(session.waitingQuestion) { return ActivityHome.clip(text, 240) }", "if !session.waitingQuestion.isEmpty { return session.waitingQuestion }", "[AskUserQuestion never renders"),
    ("guard: a plan shows question text", M, 'guard session.provider == "claude", session.waitingKind != "plan" else { return nil }', 'guard session.provider == "claude" else { return nil }', "[a plan has no question text]"),
    ("questions: 1 of N never said", M, '        if session.waitingQuestionCount > 1, questionText(session) != nil { return "Question 1 of \\(session.waitingQuestionCount)" }\n', "", "[several questions: 1 of N]"),
    # D2 intake split and midnight
    ("split: today by producedAt day, not the filename", M, "if isToday(filename: item.meeting.filename, now: now, calendar: calendar) { split.today.append(item) } else { split.older.append(item) }",
     "if item.producedDate.map({ calendar.isDate($0, inSameDayAs: now) }) ?? true { split.today.append(item) } else { split.older.append(item) }", "[today's meetings own"),
    ("split: closed items counted", M, "for item in items where isOpen(item) {", "for item in items {", "[today's meetings own"),
    ("split: an undated card goes to Today", M, "guard let ref = card.meetingRefs.first else { return false }", "guard let ref = card.meetingRefs.first else { return true }", "[today's meetings own"),
    # Running
    ("running: a waiting session is running", M, 'return session.state == "running" || (session.state == "waiting" && session.heldByServer)', 'return session.state == "running" || session.state == "waiting"', "[grouped by platform"),
    ("running: a Work run's server job is a second row", M, "guard !workJobIDs.contains(job.jobId), !routineJobs.contains(job.jobId) else { continue }", "guard !routineJobs.contains(job.jobId) else { continue }", "[grouped by platform"),
    ("running: a missing origin is a person", M, 'let raw = o["origin"]?.string ?? "other"', 'let raw = o["origin"]?.string ?? "person"', "[a missing origin is other"),
    ("running: the start ignores elapsed", M, "started = receivedAt.addingTimeInterval(-elapsedMs / 1000)", "started = receivedAt", "[a glasses question opens its conversation]"),
    ("running: elapsed frozen at the tick", M, 'detail: "COS is answering, " + duration(input.now.timeIntervalSince(job.started)),', 'detail: "COS is answering, " + duration(job.elapsedMs / 1000),', "[elapsed counts up between ticks]"),
    ("running: a jobless routine runs forever", M, "static let routineSubmitWindow: TimeInterval = 600", "static let routineSubmitWindow: TimeInterval = 600_000", "[a jobless run still submitting"),
    ("finished: the hour is two", M, "static let finishedWindow: TimeInterval = 3600", "static let finishedWindow: TimeInterval = 7200", "[finished within the hour"),
    ("finished: counted in Running", M, "                           moreFinished: finished.count - done.count, count: inFlight.count)", "                           moreFinished: finished.count - done.count, count: inFlight.count + done.count)", "[five running and one finished fit"),
    ("cap: finished rows keep their room", M, "        let room = max(0, cap - shown.count)\n", "        let room = finished.count\n", "[8 or more running"),
    ("platform: Cursor without Accessibility opens Cursor", M, ': ("In Sessions", .inSessions(session.id), "Open in Cursor needs Accessibility. Turn on in Settings")', ': ("Open in Cursor", .platform(session.id), nil)', "[Cursor without Accessibility"),
    ("platform: a Work run opens in an app", M, '        case .work, .routine: return ("In Sessions", .inSessions(session.id), nil)', '        case .work, .routine: return ("Open session", .platform(session.id), nil)', "[a Work run the server holds cannot open"),
    ("platform: no fallback when no host is found", M, "            return hostsRead ? (\"In Sessions\"", "            return false ? (\"In Sessions\"", "[no host after the lookup"),
    # Needs you
    ("needs: a Work item for a waiting session shows twice", M, "if let sid = move.sessionID, waitingIDs.contains(where: { ClaudeSession.sameSession($0, sid) }) { continue }", "", "[ranked"),
    ("needs: newest question first", M, "return x == y ? a.id < b.id : x < y\n        }\n    }\n    static func waitingSince", "return x == y ? a.id < b.id : x > y\n        }\n    }\n    static func waitingSince", "[the oldest question first"),
    ("needs: agreeing counts instead of similarity", M, 'why: name.map { "Sounds like \\($0), similarity " + String(format: "%.2f", group.suggestionSimilarity) + "." },', 'why: name.map { "Sounds like \\($0), \\(group.suggestionAgreeing) of \\(group.suggestionOf) agree." },', "[a voice shows its similarity"),
    ("memories: always 7 to review", M, "        if let total, total > count { return \"Next \\(count) of \\(total)\" }\n", "", "[Next 7 of 23"),
    ("show more: every hidden title", M, "        let labels = hidden.prefix(2).map(shortLabel)\n", "        let labels = hidden.map(shortLabel)\n", "[Show more names two at most]"),
    ("suggestions: a link creates a task", M, "        if item.kind == .link { return .openCard(item.pullTitle ?? item.text) }\n", "", "[an ask creates, a link opens"),
    # Composition (QA round 1 items 1, 2, 10)
    ("compose: unreachable keeps the server's rows", M, "        if !reachable {\n            need.voiceGroups = nil;", "        if false {\n            need.voiceGroups = nil;", "[unreachable: Needs you keeps"),
    ("compose: the server's sources stay answered when unreachable", M, "func server(_ state: ActivityHome.SourceState) -> ActivityHome.SourceState { input.reachable || state == .off ? state : .failed }",
     "func server(_ state: ActivityHome.SourceState) -> ActivityHome.SourceState { state }", "[unreachable: the server's sources are failed"),
    ("compose: a failed Intake ignored", M, "        if input.intakeFailed, work != .off { work = .failed }\n", "", "[a failed Intake read fails Work"),
    ("compose: voices counted while loading", M, "c.voicesToName = answered(.voices, states) && facts.voicesLoaded ?", "c.voicesToName = facts.voicesLoaded ?", "[unreachable: no count that reads the server]"),
    ("compose: the calendar clear unless the server said otherwise", M, "        c.calendarRead = facts.calendarRead == true\n", "        c.calendarRead = facts.calendarRead != false\n", "[no calendarRead from the server"),
    ("states: settled while a source failed", M, "return !counted.isEmpty && counted.allSatisfy { $0 == .answered }\n    }", "return !counted.isEmpty && counted.allSatisfy { $0 != .pending }\n    }", "[never nothing waiting while a source is down]"),
    ("brief: nothing waiting while still reading", M, "        } else if c.settled {\n            first = \"Nothing is waiting on you\"", "        } else {\n            first = \"Nothing is waiting on you\"", "[no false caught up while loading]"),
    ("brief: no clear-day claim when clear", M, '            first = first.map { $0 + ", and your calendar is clear for the rest of the day" } ?? "Your calendar is clear for the rest of the day"\n', "", "[the caught-up brief]"),
    # Quiet hours
    ("quiet: session questions fold", M, "return (rows.filter { $0.tier == 1 }, rows.filter { $0.tier != 1 })", "return ([], rows)", "[tiers 2 to 5 fold"),
    ("quiet: 7 PM, not 6 PM", M, "|| hour >= 18 ||", "|| hour >= 19 ||", "[6 PM is quiet]"),
    ("quiet: the early morning is not quiet", M, "|| hour >= 18 || hour < 6", "|| hour >= 18", "[before 6 AM on a weekday is quiet"),
    ("quiet: weekends are not quiet", M, "return calendar.isDateInWeekend(now) || hour >= 18", "return hour >= 18", "[Saturday is quiet]"),
    ("quiet: the switch ignored", M, "        guard enabled else { return false }\n        let hour", "        let hour", "[the switch off: never quiet]"),
    # Cost guards
    ("guard: the cap is 21", M, "if used(now: now) >= Self.dailyCap { return .capReached }", "if used(now: now) > Self.dailyCap { return .capReached }", "[the 21st of the day is refused]"),
    ("guard: the switch ignored", M, "        guard switchOn else { return .switchOff }\n", "", "[the switch off starts nothing]"),
    ("guard: two runs per meeting", M, "        if inFlight.contains(target) { return .inFlight }\n", "", "[one run in flight per meeting]"),
    ("guard: the breaker never opens", M, "        if let until = pausedUntil(now: now) { return .paused(until: until) }\n", "", "[3 failures in a row pause"),
    ("guard: a success does not reset", M, "        guard !admitted else { defaults.set(0, forKey: Self.failuresKey); return }", "        guard !admitted else { return }", "[a success in between resets"),
    ("guard: yesterday's count carries over", M, "defaults.string(forKey: Self.dayKey) == ActivityHome.dayKey(now, calendar: calendar) ? defaults.integer(forKey: Self.countKey) : 0", "defaults.integer(forKey: Self.countKey)", "[a new day starts a new count]"),
    ("guard: a refusal before submit counts", M, "        case .notStarted: break\n", "        case .notStarted: recordStart(now: now); recordOutcome(admitted: false, now: now)\n", "[refused before submit"),
    ("guard: a refused receipt reads as admitted", M, 'if ["refused", "failed"].contains(status) { return .refused(error ?? "The server did not start it.") }', 'if ["refused", "failed"].contains(status) { return .admitted }', "[the run outcome from the new receipt]"),
    ("guard: busy Work ignored", M, '        if busy { return "Work is sending something else. Try again in a moment." }\n', "", "[busy Work or an open run"),
    ("model: Opus allowed by default", M, ' && !choices[$0].id.lowercased().contains("opus") }', " }", "[never Opus by default]"),
    # Layout and the tick loop
    ("layout: the rail breakpoint at 1099", M, "windowWidth >= fullRailBreakpoint ? .full : .icons", "windowWidth > fullRailBreakpoint ? .full : .icons", "[the rail is icons at 1,099 pt"),
    ("layout: two columns from 1,100 pt", M, "static let twoColumnWindow: CGFloat = 1228", "static let twoColumnWindow: CGFloat = 1100", "[two columns only once"),
    ("layout: no right-column floor", M, "let right = max(rightColumnFloor, (content - gap) / 2.6)", "let right = (content - gap) / 2.6", "[the right column never narrower"),
    ("tick: hidden windows tick", M, "            if visible(), last.map", "            if true, last.map", "[one tick a minute while on screen"),
    ("tick: no wait for the opening loads", M, "        while !ready(), now().timeIntervalSince(start) < readyLimit {", "        while false, now().timeIntervalSince(start) < readyLimit {", "[the first tick waits"),
    # Wiring (pins)
    ("polling: the loop ignores the window", W, "visible: { today.windowVisible }", "visible: { true }", "[polling]"),
    ("polling: the loop ignores the opening loads", W, "ready: { today.overviewDone }", "ready: { true }", "[polling]"),
    ("polling: the calendar every tick", W, "        let calendar = lastCalendar.map { now.timeIntervalSince($0) >= Self.slowSeconds } ?? true\n", "        let calendar = true\n", "[polling]"),
    ("states: checked after a failed tick", W, "            if reachable == true { checkedAt = Date() }\n", "            checkedAt = Date()\n", "[states]"),
    ("pet off: no session refresh", W, "        if !model.petEnabled { await model.loadClaudeSessions() }\n", "", "[pet off]"),
    ("never dismiss: Today dismisses", W, "await model.resolveWorkIntake(item, accept: true)", "await model.resolveWorkIntake(item, accept: false)", "[never seen or dismiss]"),
    ("one at a time: two creates at once", W, "        guard model.workIntakeBusyIDs.isEmpty, !created.contains(item.id) else { return }\n", "        guard !created.contains(item.id) else { return }\n", "[one at a time]"),
    ("cost: a run before admission", W, "        guard admission == .allowed else {", "        guard admission == .allowed || true else {", "[cost guards]"),
    ("cost: an earlier receipt read as this one", W, "let receipt = handoff.receipts.first { $0.id == id }", "let receipt = handoff.receipts.first { $0.workID == target }", "[cost guards]"),
    ("capability: questions on an older server", W, "input.jobs = today.jobsSupported == true ? today.jobs : nil", "input.jobs = today.jobs", "[capability]"),
    ("reduce motion: the setting is read once", W, "            .onChange(of: reduceMotion) { _, still in animate(!still) }\n", "", "[reduce motion]"),
    ("voices: a stale result reused", W, "        model.heldNamingResult = nil\n        model.cancelHeldNamingPreview()\n", "        model.cancelHeldNamingPreview()\n", "[voices]"),
    ("capability: detected by status code", H, 'return features?["activeQueryJobs"] as? Bool == true && jsonInt(features?["activeQueryJobsProtocol"]) == 1', "return health != nil", "[capability]"),
    ("disk: the question cached on disk", H, '"sessions": sessions.map { $0.filter { $0.key != "waitingQuestion" && $0.key != "waitingQuestionCount" } },', '"sessions": sessions,', "[disk]"),
]

def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    # 0.5.267: every compile in the lane runs through Tests/compile-guard.sh; a guard stop ends the lane (it is not a kill).
    if "compile-guard: STOPPED" in proc.stdout + proc.stderr:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + (proc.stderr or "")[-400:])
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started

def suite(copy):
    code, out, seconds = run(["/usr/bin/python3", "Tests/activity-today-pins.py", "."], copy)
    if code != 0:
        return code, out, seconds
    code2, out2, seconds2 = run(["zsh", "Tests/run-activity-today.sh"], copy)
    return code2, out + out2, seconds + seconds2

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
    passed = [l for l in out.splitlines() if l.startswith("PASS:") or "wiring pinned" in l]
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
        lines = [l for l in out.splitlines() if "check failed [" in l or "Activity Today pin:" in l or ": error:" in l]
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
