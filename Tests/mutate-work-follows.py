#!/usr/bin/env python3
"""Mutation lane for the Work follows and evidence guards (next release). Run by hand, never by a gate.

    python3 Tests/mutate-work-follows.py <worktree> <scratch dir> [--workers 1|2] [name ...]

RESOURCE SAFETY (2026-10-07, two kernel panics on a 96 GB Mac): one compile of Sources + Tests/WorkProgressChecks.swift
peaked near 39 GB before that file was split (now about 3 GB), and this lane once ran 10 at once. So:
- one worker by default, never more than 2;
- every compile goes through Tests/compile-guard.sh (one guarded compile machine-wide, a free-memory floor, and a
  watchdog that kills a runaway swift-frontend); a guard stop (exit 137) or a refused start (75) stops the whole lane;
- every step has a timeout.

Verdicts. The unmutated copy must be green first (Swift lane and helper lane), or nothing runs.
- killed:   the mutant compiled, landed exactly once, and a NAMED check failed (a "check failed at line N" line, a
            Precondition with its message, a helper self-test failure, or a Python AssertionError with its line).
- SURVIVED: it compiled, landed, and every check passed. A finding.
- INVALID:  the target text was not found exactly once, or the mutant did not compile. Never counted as killed.
- UNNAMED:  it failed with no named check (a crash, a timeout). Reported, never counted as killed.
"""
import os, pathlib, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

S, T, H = "Sources/WorkProgress.swift", "Sources/WorkProgressTracker.swift", "Sources/WorkHandoffStore.swift"
HELPER = "HelperSources/main.swift"
MUTANTS = [
    # The evidence policy (Sources/WorkProgress.swift).
    ("one met: fact only", S, 'verdict == "met" && kind == "fact" && hasEvidence && (confidence >= clauseBar || deterministic)', 'verdict == "met" && hasEvidence && (confidence >= clauseBar || deterministic)'),
    ("one met: needs evidence", S, 'verdict == "met" && kind == "fact" && hasEvidence && (confidence >= clauseBar || deterministic)', 'verdict == "met" && kind == "fact" && (confidence >= clauseBar || deterministic)'),
    ("clause bar 0.80", S, "nonisolated static let clauseBar = 0.80", "nonisolated static let clauseBar = 0.70"),
    ("title bar 0.90", S, "state.met, state.confidence >= titleBar,", "state.met,"),
    ("title needs two supporting sources", S, "nonisolated static let titleSources = 2", "nonisolated static let titleSources = 1"),
    ("supporting, never offered", S, 'supportingSources: verdict == "met" ? supporting : []', 'supportingSources: verdict == "met" ? supporting + ((details["sources"]?.array ?? []).compactMap(\\.string)) : []'),
    ("truncated holds", S, "if truncated { return .hold }", "if false { return .hold }"),
    ("sticky: met kept", S, "guard let old = kept.first(where: { $0.text == verdict.text }), old.met, !next.met else { return next }",
     "guard let old = kept.first(where: { $0.text == verdict.text }), old.met, !next.met, false else { return next }"),
    ("sticky: newer evidence wins", S, "if let newer = verdict.evidence?.at.flatMap(WorkProgress.parseStamp), newer > old.evidenceAt { return next }", ""),
    ("sticky: same path only", S, "let kept = previousBasis == basis ? (previous ?? []) : []", "let kept = previous ?? []"),
    ("decision: clause count", S, "guard expected > 0, states.count == expected else { return .hold }", "guard expected > 0 else { return .hold }"),
    ("UTF-16 clause length", S, "if parts.contains(where: { $0.utf16.count > maxClauseLength })", "if parts.contains(where: { $0.count > maxClauseLength })"),
    ("cursor limit 512", S, "(1...WorkFinishLine.maxCursorLength).contains(cursor.utf16.count) else { return nil }", "!cursor.isEmpty else { return nil }"),
    ("revival needs your message", S, "prompts.contains { ($0.at ?? 0) > floor }", "!prompts.isEmpty"),
    ("backfill 14 days", S, "&& (tracked || now - receipt.createdAt < backfillDays * 86_400)", ""),
    ("unknown not followed", S, '!["refused", "canceled", "failed", "unknown"].contains(receipt.status)', '!["refused", "canceled", "failed"].contains(receipt.status)'),
    ("move log: COS moved since", S, "$0.line.to == to && $0.line.at >= since", "$0.line.to == to"),
    ("move log: seen since", S, "&& (($0.type == .move && $0.by == .you && $0.shadow != true) || $0.type == .pause || $0.type == .resume) }", "&& false }"),
    ("ack on arrival only once", S, "guard let mark = mark(workID: workID), mark.id != previous else { return false }", "guard let mark = mark(workID: workID) else { return false }"),
    ("shadow toggle clears checks", S, "file.cards[id]?.checkedAt = nil; file.cards[id]?.shadowKey = nil; changed = true", "changed = true"),
    ("move log entries cache keyed by epoch", S, "if let cached = entriesCache, cached.epoch == epoch { return cached.entries }", "if let cached = entriesCache { return cached.entries }"),
    ("active() respects card pause", S, "        guard !isPaused(workID) else { return [] }\n", ""),
    ("move log keeps a busy line", S, "        queued.append(line)\n        lines.append(line)", "        lines.append(line)"),
    ("back move pauses", S, '            pause(workID: workID, stage: to, why: "You moved it back to \\(WorkProgress.stageTitle(to)).", at: at)\n', ""),
    # The tracker (Sources/WorkProgressTracker.swift).
    ("sticky: decision on the merged set", T, "let decision = WorkEvidencePolicy.decision(basis: result.basis, states: merged, expected: clauses.count)",
     "let decision = result.decision"),
    ("truncated v2 cursor kept", T, "if !result.truncated || result.v2 { keep(result.cursors) }", "if !result.truncated { keep(result.cursors) }"),
    ("truncated v1 cursor dropped", T, "if !result.truncated || result.v2 { keep(result.cursors) }", "keep(result.cursors)"),
    ("truncated not counted, no verdicts", T, "        if result.truncated {\n            // Partial", "        if false {\n            // Partial"),
    ("no_evidence cursors kept", T, "            keep(answer.cursors)\n", ""),
    ("failure sets checkedAt", T, "                card.checkedAt = at; card.checkedRevision = judged; card.checkedActivity = activity\n                card.lastDecision = \"no answer: \" + reason",
     "                card.lastDecision = \"no answer: \" + reason"),
    ("back off on refusals", T, "            noteEvidenceUnavailable(reason, retryAt: answer.retryAt)\n", ""),
    ("disabled falls back", T, 'case "evidence_disabled", "jev_not_configured": evidenceOff = (tomorrow, true, reason)', 'case "evidence_disabled", "jev_not_configured": evidenceOff = (tomorrow, false, reason)'),
    ("cap waits for retryAt", T, 'case "jev_cap": evidenceOff = (given ?? Self.nextUTCMidnight(date), false, reason)', 'case "jev_cap": evidenceOff = (date, false, reason)'),
    ("breaker an hour", T, 'case "jev_breaker": evidenceOff = (given ?? date.addingTimeInterval(3_600), false, reason)', 'case "jev_breaker": evidenceOff = (date, false, reason)'),
    ("cached after your move holds", T, "        guard decision == .move, !stale else { return }", "        guard decision == .move else { return }"),
    ("done line once (digest)", T, "        if store.follows.card(workID).actedDone?.contains(digest) == true { return true }\n", ""),
    ("done line once (receipt history)", T, "        return store.receipts.contains { row in\n            row.workID == workID && (row.progress?.events.contains { $0.kind == .moved && $0.toStage == \"qa\" && $0.at >= replyAt } ?? false)\n        }",
     "        return false"),
    ("moved back outside Control pauses", T, "            await pauseIfMovedBack(task, at: start)\n", ""),
    ("moved back: fresh board first", T, "        guard await board.readFresh(), let identity", "        guard let identity"),
    ("first checks per pass", T, "let waiting = Set(fresh.dropFirst(Self.firstChecksPerPass).map(\\.workSourceID))", "let waiting = Set<String>()"),
    ("shadow gates the handoff Jev path", T, "let shadowed = moves && shadow()", "let shadowed = false"),
    ("lease: moves only by the holder", T, "        guard holdsLease, let row = store.receipts.first(where: { $0.id == id }), let progress = row.progress,",
     "        guard let row = store.receipts.first(where: { $0.id == id }), let progress = row.progress,"),
    ("lease: follows only by the holder", T, "        if holdsLease { await followPass(start: start, tracked: Set(open.map(\\.id))) }", "        await followPass(start: start, tracked: Set(open.map(\\.id)))"),
    ("evaluate respects card pause", T, "        guard !follows.isPaused(workID) else { return }\n        if follows.card(workID).pending", "        if follows.card(workID).pending"),
    ("judgedRevision drop", T, "guard task.workRevision == pending.judgedRevision else {", "guard true else {"),
    ("shadow never moves", T, "if !live && shadow() {", "if false {"),
    ("shadow logs once", T, "            guard follows.card(workID).shadowKey != key else { return }\n", ""),
    ("undo line logged", T, "        store.moves.recordUndo(moveID: moveID, at: at)\n", ""),
    ("8 checks a day", T, "guard card.checks.filter({ at - $0 < 86_400 }).count < Self.maxChecksPerDay else {", "guard true else {"),
    ("cached answers not counted", T, "if !result.cached && result.skipped == nil { card.checks.append(at) }", "card.checks.append(at)"),
    ("idle from the transcript", T, "        guard !reads.isEmpty, reads.allSatisfy({ Self.transcriptIdle($0, now: at) }) else {", "        guard !reads.isEmpty else {"),
    ("handoff path respects card pause", T, "        if store.follows.isPaused(row.workID) {\n            write(id)", "        if false {\n            write(id)"),
    # The store (Sources/WorkHandoffStore.swift).
    ("helper refusal is not unavailable", H, '            return EvidenceAnswer(reason: "helper_refused")', '            return EvidenceAnswer(reason: "unavailable")'),
    ("prune only after a whole board", H, "        guard complete else { return }\n        follows.prune", "        follows.prune"),
    ("Follow again resumes", H, "        follows.resume(workID: workID)\n        moves.append(WorkMoveLine(type: .resume", "        moves.append(WorkMoveLine(type: .resume"),
    ("one session, several cards", H, "var links = (next[sessionID] ?? []).filter { $0.workID != source.id }", "var links: [WorkSessionCardLink] = []"),
    # The update row (Sources/Models.swift).
    ("update row: never current on a failed check", "Sources/Models.swift", 'let controlKnown = controlBehind != nil || app.reason == "upToDate"', "let controlKnown = true"),
    ("update row: server compare", "Sources/Models.swift", "if isNewer { serverBehind = (installed, latest) }", ""),
    ("update row: numeric compare", "Sources/Models.swift", "return a.lexicographicallyPrecedes(b) ? false : a != b", "return latest > installed"),
    # Helper body validator (helper lane).
    ("helper: at most 4 follows", HELPER, 'let follows = body["follows"] as? [Any], follows.count <= 4,', 'let follows = body["follows"] as? [Any], follows.count <= 5,'),
    ("helper: one follow per session", HELPER, '                  seen.insert(provider + ":" + session).inserted else { return false }', "                  true else { return false }"),
    ("helper: cursor 512", HELPER, "guard let text = cursor as? String, (1...512).contains(text.utf16.count) else { return false }", "guard let text = cursor as? String, (1...2_048).contains(text.utf8.count) else { return false }"),
    ("helper: UTF-16 clause", HELPER, "(1...300).contains(text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) else { return false }", "(1...300).contains(text.count), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }"),
    ("helper: exactly the contract keys", HELPER, 'guard Set(body.keys) == ["domain", "id", "follows", "clauses", "since"],', 'guard Set(body.keys).isSuperset(of: ["domain", "id", "follows", "clauses", "since"]),'),
]

GUARD_STOP = 137
STEP_TIMEOUT = 2_400   # a guarded compile can wait up to 30 min for the machine-wide lock
SWIFT_FLAGS = ["-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete"]
NAMED = re.compile(r"(check failed at line \d+.*|Precondition failed.*\S.*|Fatal error: .*check failed.*|"
                   r"self-test failed.*|AssertionError.*)")

class Stop(Exception): pass

def guarded(work, argv):
    """One compile through the guard. Returns (ok, log). Raises Stop when the guard stopped or refused it."""
    try:
        r = subprocess.run(["zsh", str(work / "Tests/compile-guard.sh")] + argv, cwd=work, capture_output=True, text=True, timeout=STEP_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Stop("a guarded compile ran past %d s" % STEP_TIMEOUT)
    # 137: the watchdog stopped it. 75: the guard would not start (memory), or lockf timed out waiting for the lock.
    if (r.returncode == GUARD_STOP and "compile-guard:" in r.stderr) or r.returncode == 75:
        raise Stop((r.stderr.strip().splitlines() or ["exit %d" % r.returncode])[-1])
    return r.returncode == 0, r.stdout + r.stderr

def run_step(argv, **kw):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=600, **kw)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        return None, "TIMEOUT after 600 s\n" + str(e.stdout or "")

def lane(work, helper):
    """(compiled, passed, log)."""
    if not helper:
        sources = sorted(str(p) for p in (work / "Sources").glob("*.swift") if p.name != "COSControlApp.swift")
        binary = work / "work-progress-checks"
        ok, log = guarded(work, ["swiftc"] + SWIFT_FLAGS + ["-parse-as-library"] + sources + [str(work / "Tests/WorkProgressChecks.swift"),
                         "-framework", "SwiftUI", "-framework", "AppKit", "-framework", "ServiceManagement", "-o", str(binary)])
        if not ok: return False, False, log
        home = work / "home"; home.mkdir(exist_ok=True)
        code, out = run_step([str(binary)], env=dict(os.environ, COS_CONTROL_TEST_HOME=str(home)))
        return True, code == 0, out
    binary = work / "cos-control-helper"
    ok, log = guarded(work, ["swiftc"] + SWIFT_FLAGS + [str(work / HELPER), "-framework", "Security", "-framework", "AppKit", "-o", str(binary)])
    if not ok: return False, False, log
    home = work / "home"; home.mkdir(exist_ok=True)
    c1, st = run_step([str(binary), "self-test-work"], env=dict(os.environ, COS_CONTROL_TEST_HOME=str(home)))
    c2, py = run_step(["python3", str(work / "Tests/work-progress-helper-checks.py"), str(binary)])
    if '"ok":true' not in st and "self-test failed" not in st: st += "\n(helper self-test-work did not report ok)"
    return True, c1 == 0 and '"ok":true' in st and c2 == 0, st + py

def run(src, scratch, mutant):
    name, path, old, new = mutant
    work = scratch / ("m-" + "".join(c if c.isalnum() else "-" for c in name))
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(src, work, ignore=shutil.ignore_patterns(".git", "build", "*.app"))
    try:
        if old is not None:
            text = (work / path).read_text()
            if text.count(old) != 1: return name, "INVALID", "target found %d times" % text.count(old)
            (work / path).write_text(text.replace(old, new))
        compiled, passed, log = lane(work, path == HELPER)
        (scratch / (work.name + ".log")).write_text(log)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if not compiled: return name, "INVALID", "did not compile: " + next((l.strip()[:160] for l in log.splitlines() if "error:" in l), "no error line")
    if passed: return name, "SURVIVED", ""
    named = [m.group(0).strip()[:200] for m in map(NAMED.search, log.splitlines()) if m]
    if not named: return name, "UNNAMED", (log.strip().splitlines() or ["no output"])[-1][:200]
    return name, "killed", named[0]

def main():
    args = sys.argv[1:]
    workers = 1
    if "--workers" in args:
        i = args.index("--workers"); workers = int(args[i + 1]); del args[i:i + 2]
    if not 1 <= workers <= 2: sys.exit("--workers is 1 or 2: each worker is a full COS Control compile (two panics, 2026-10-07)")
    src, scratch = pathlib.Path(args[0]), pathlib.Path(args[1])
    if not (src / "Tests/compile-guard.sh").exists(): sys.exit("Tests/compile-guard.sh is missing: refusing to compile unguarded")
    scratch.mkdir(parents=True, exist_ok=True)
    chosen = [m for m in MUTANTS if not args[2:] or m[0] in args[2:]]
    unknown = set(args[2:]) - {m[0] for m in MUTANTS}
    if unknown: sys.exit("unknown mutant: " + ", ".join(sorted(unknown)))
    # The green baseline is proved once per exact source tree: its hash is kept in the scratch dir, so a lane run in
    # several short calls (a foreground call is capped at 10 minutes) proves it once, never skips it for a changed tree.
    import hashlib, json
    digest = hashlib.sha256()
    for rel in sorted([str(p.relative_to(src)) for p in (src / "Sources").glob("*.swift")] +
                      [HELPER, "Tests/WorkProgressChecks.swift", "Tests/work-progress-helper-checks.py"]):
        digest.update(rel.encode()); digest.update((src / rel).read_bytes())
    tree = digest.hexdigest()
    proof = scratch / "baseline-green.json"
    try:
        if (json.loads(proof.read_text()) if proof.exists() else {}).get("tree") == tree:
            print("baseline green for this exact tree (proved earlier, %s)" % tree[:12], flush=True)
        else:
            for base in (("baseline (Swift)", S, None, None), ("baseline (helper)", HELPER, None, None)):
                name, verdict, why = run(src, scratch, base)
                print(name, "green" if verdict == "SURVIVED" else verdict + " " + why, flush=True)
                if verdict != "SURVIVED": sys.exit("the unmutated copy is not green; no mutant result means anything")
            proof.write_text(json.dumps({"tree": tree}))
        tally = {"killed": 0, "SURVIVED": 0, "INVALID": 0, "UNNAMED": 0}
        with ThreadPoolExecutor(workers) as pool:
            for name, verdict, why in pool.map(lambda m: run(src, scratch, m), chosen):
                tally[verdict] += 1
                print("%-9s %s :: %s" % (verdict, name, why), flush=True)
    except Stop as stop:
        sys.exit("STOPPED by the compile guard: %s. Nothing was retried." % stop)
    print("%(killed)d killed, %(SURVIVED)d survived, %(INVALID)d invalid, %(UNNAMED)d unnamed" % tally + " of %d" % len(chosen))
    sys.exit(1 if tally["SURVIVED"] or tally["INVALID"] or tally["UNNAMED"] else 0)

main()
