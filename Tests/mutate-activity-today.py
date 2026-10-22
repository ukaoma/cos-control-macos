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
    # B1 tool-name guard
    ("guard: a CamelCase tool name passes", M, 'return t.range(of: "^[A-Z][a-z0-9]+([A-Z][A-Za-z0-9]*)+$", options: .regularExpression) != nil', "return false", "[a bare tool name is caught]"),
    ("guard: the question text is not guarded", M, "if let text = guarded(session.waitingQuestion) { return ActivityHome.clip(text, 240) }", "if !session.waitingQuestion.isEmpty { return session.waitingQuestion }", "[AskUserQuestion never renders"),
    ("guard: a plan shows question text", M, 'guard session.provider == "claude", session.waitingKind != "plan" else { return nil }', 'guard session.provider == "claude" else { return nil }', "[a plan has no question text]"),
    # D2 intake split and midnight
    ("split: today by producedAt day, not the filename", M, "if isToday(filename: item.meeting.filename, now: now, calendar: calendar) { split.today.append(item) } else { split.older.append(item) }",
     "if item.producedDate.map({ calendar.isDate($0, inSameDayAs: now) }) ?? true { split.today.append(item) } else { split.older.append(item) }", "[today's meetings own"),
    ("split: closed items counted", M, "for item in items where isOpen(item) {", "for item in items {", "[today's meetings own"),
    ("split: an undated card goes to Today", M, "guard let ref = card.meetingRefs.first else { return false }", "guard let ref = card.meetingRefs.first else { return true }", "[today's meetings own"),
    # Running
    ("running: a waiting session is running", M, 'return session.state == "running" || (session.state == "waiting" && session.heldByServer)', 'return session.state == "running" || session.state == "waiting"', "[grouped by platform"),
    ("running: a Work run's server job is a second row", M, "guard !workJobIDs.contains(job.jobId), !routineJobs.contains(job.jobId) else { continue }", "guard !routineJobs.contains(job.jobId) else { continue }", "[grouped by platform"),
    ("running: an `other` job gets a row", M, '            default:\n                // `other`: a Control Work session or a meeting review.', '            case "other-never":\n                break\n            default:\n                rows.append(RunRow(id: "job:" + job.jobId, platform: .work, title: job.title, detail: "", openLabel: "In Sessions", open: .inSessions(nil), working: true, finished: false, started: nil))\n                // `other`: a Control Work session or a meeting review.', "[an unmatched `other` job is skipped"),
    ("finished: the hour is two", M, "static let finishedWindow: TimeInterval = 3600", "static let finishedWindow: TimeInterval = 7200", "[finished within the hour"),
    ("finished: counted in Running", M, "                           moreFinished: finished.count - done.count, count: inFlight.count)", "                           moreFinished: finished.count - done.count, count: inFlight.count + done.count)", "[five running and one finished fit"),
    ("cap: finished rows keep their room", M, "        let room = max(0, cap - shown.count)\n", "        let room = finished.count\n", "[8 or more running"),
    ("platform: Cursor without Accessibility opens Cursor", M, ': ("In Sessions", .inSessions(session.id), "Open in Cursor needs Accessibility. Turn on in Settings")', ': ("Open in Cursor", .platform(session.id), nil)', "[Cursor without Accessibility"),
    ("platform: a Work run opens in an app", M, "        case .work, .routine: return (\"In Sessions\", .inSessions(session.id), nil)", "        case .work, .routine: return (\"Open session\", .platform(session.id), nil)", "[a Work run the server holds cannot open"),
    # Needs you
    ("needs: a Work item for a waiting session shows twice", M, "if let sid = move.sessionID, waitingIDs.contains(where: { ClaudeSession.sameSession($0, sid) }) { continue }", "", "[ranked"),
    ("needs: newest question first", M, "return x == y ? a.id < b.id : x < y\n        }\n    }\n    static func waitingSince", "return x == y ? a.id < b.id : x > y\n        }\n    }\n    static func waitingSince", "[the oldest question first"),
    ("needs: agreeing counts instead of similarity", M, 'why: name.map { "Sounds like \\($0), similarity " + String(format: "%.2f", group.suggestionSimilarity) + "." },', 'why: name.map { "Sounds like \\($0), \\(group.suggestionAgreeing) of \\(group.suggestionOf) agree." },', "[a voice shows its similarity"),
    ("memories: always 7 to review", M, "        if let total, total > count { return \"Next \\(count) of \\(total)\" }\n", "", "[Next 7 of 23"),
    # Quiet hours
    ("quiet: session questions fold", M, "return (rows.filter { $0.tier == 1 }, rows.filter { $0.tier != 1 })", "return ([], rows)", "[tiers 2 to 5 fold"),
    ("quiet: 7 PM, not 6 PM", M, "calendar.component(.hour, from: now) >= 18", "calendar.component(.hour, from: now) >= 19", "[6 PM is quiet]"),
    ("quiet: weekends are not quiet", M, "return calendar.isDateInWeekend(now) || calendar.component", "return calendar.component", "[Saturday is quiet]"),
    ("quiet: the switch ignored", M, "        guard enabled else { return false }\n        return calendar.isDateInWeekend", "        return calendar.isDateInWeekend", "[the switch off: never quiet]"),
    # Cost guards
    ("guard: the cap is 21", M, "if used(now: now) >= Self.dailyCap { return .capReached }", "if used(now: now) > Self.dailyCap { return .capReached }", "[the 21st of the day is refused]"),
    ("guard: the switch ignored", M, "        guard switchOn else { return .switchOff }\n", "", "[the switch off starts nothing]"),
    ("guard: two runs per meeting", M, "        if inFlight.contains(target) { return .inFlight }\n", "", "[one run in flight per meeting]"),
    ("guard: the breaker never opens", M, "        if let until = pausedUntil(now: now) { return .paused(until: until) }\n", "", "[3 failures in a row pause"),
    ("guard: a success does not reset", M, "        guard !admitted else { defaults.set(0, forKey: Self.failuresKey); return }", "        guard !admitted else { return }", "[a success in between resets"),
    ("guard: yesterday's count carries over", M, "defaults.string(forKey: Self.dayKey) == ActivityHome.dayKey(now, calendar: calendar) ? defaults.integer(forKey: Self.countKey) : 0", "defaults.integer(forKey: Self.countKey)", "[a new day starts a new count]"),
    # Brief and states
    ("brief: no calendar claim when clear", M, '            first += ", and your calendar is clear for the rest of the day"\n', "", "[the caught-up brief]"),
    ("states: caught up while a source failed", M, "return !counted.isEmpty && counted.allSatisfy { $0 == .answered } ? .caughtUp : .loading", "return counted.allSatisfy { $0 != .pending } ? .caughtUp : .loading", "[never nothing waiting while a source is down]"),
    ("layout: the rail breakpoint at 1099", M, "windowWidth >= fullRailBreakpoint ? .full : .icons", "windowWidth > fullRailBreakpoint ? .full : .icons", "[the rail is icons at 1,099 pt"),
    # Wiring (pins)
    ("polling: the tick runs with the window hidden", W, "if model.liveTranscriptWindowOnScreen { await today.tick(model: model) }", "await today.tick(model: model)", "[polling]"),
    ("polling: the calendar every tick", W, "        let calendar = lastCalendar.map { now.timeIntervalSince($0) >= Self.slowSeconds } ?? true\n", "        let calendar = true\n", "[polling]"),
    ("never dismiss: Today dismisses", W, 'let payload = try JSONSerialization.data(withJSONObject: ["id": item.id, "action": "accept"])', 'let payload = try JSONSerialization.data(withJSONObject: ["id": item.id, "action": "dismiss"])', "[never seen or dismiss]"),
    ("one at a time: two creates at once", W, "        guard !intakeBusy, intake[item.id] != .created else { return }\n", "        guard intake[item.id] != .created else { return }\n", "[one at a time]"),
    ("cost: a run before admission", W, "        guard admission == .allowed else {", "        guard admission == .allowed || true else {", "[cost guards]"),
    ("capability: questions on an older server", W, "input.jobs = today.jobsSupported == true ? today.jobs : nil", "input.jobs = today.jobs", "[capability]"),
    ("reduce motion: the pulse moves anyway", W, "            .onAppear { if !reduceMotion { withAnimation", "            .onAppear { if true { withAnimation", "[reduce motion]"),
    ("capability: detected by status code", H, 'return features?["activeQueryJobs"] as? Bool == true && jsonInt(features?["activeQueryJobsProtocol"]) == 1', "return health != nil", "[capability]"),
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
        lines = [l for l in out.splitlines() if "check failed [" in l or "Activity Today pin:" in l or "error:" in l]
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
