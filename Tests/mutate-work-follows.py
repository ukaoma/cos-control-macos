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

MUTANTS = [
    ("only fact counts (clauses)", S, 'verdict == "met" && kind == "fact" && evidence != nil && (confidence >= threshold || deterministic)', 'verdict == "met" && evidence != nil && (confidence >= threshold || deterministic)'),
    ("title bar 0.90", S, "clause.confidence >= Self.titleBar,", "clause.confidence >= 0.80,"),
    ("title needs two sources", S, '.subtracting([""]).count >= 2 else { return .hold }', '.subtracting([""]).count >= 1 else { return .hold }'),
    ("only fact counts (title)", S, 'guard let clause = clauses.first, clause.verdict == "met", clause.kind == "fact", let evidence', 'guard let clause = clauses.first, clause.verdict == "met", let evidence'),
    ("truncated holds", S, "if truncated { return .hold }", "if false { return .hold }"),
    ("clause bar 0.80", S, "nonisolated static let clauseBar = 0.80", "nonisolated static let clauseBar = 0.70"),
    ("evaluate respects card pause", T, "        guard !follows.isPaused(workID) else { return }\n        if follows.card(workID).pending", "        if follows.card(workID).pending"),
    ("active() respects card pause", S, "        guard !isPaused(workID) else { return [] }\n", ""),
    ("judgedRevision drop", T, "guard task.workRevision == pending.judgedRevision else {", "guard true else {"),
    ("shadow never moves", T, "if !live && shadow() {", "if false {"),
    ("shadow logs once", T, "            guard follows.card(workID).shadowKey != key else { return }\n", ""),
    ("revival needs activity after failure", S, "(replies + prompts).contains { ($0.at ?? 0) > floor }", "!(replies + prompts).isEmpty"),
    ("failed send not followed outright", S, '!["refused", "canceled", "failed"].contains(receipt.status)', '!["refused", "canceled"].contains(receipt.status)'),
    ("tracker lease", T, "        guard lease.acquire() else {", "        guard lease.acquire() || true else {"),
    ("move log keeps a busy line", S, "        queued.append(line)\n        lines.append(line)", "        lines.append(line)"),
    ("move log rotates", S, "if size >= Self.rotateAt, let rotated", "if size > Int.max - 1, let rotated"),
    ("undo line logged", T, "        store.moves.recordUndo(moveID: moveID, at: at)\n", ""),
    ("ack once", S, "guard let entry = entries.first(where: { $0.id == moveID }), entry.ackedAt == nil else { return }", "guard let entry = entries.first(where: { $0.id == moveID }) else { return }"),
    ("evidence replaces completion check", T, "        guard !board.evidenceCheck() else { return }\n        let asked", "        let asked"),
    ("fallback without the capability", T, "if board.evidenceCheck() { await checkEvidence", "if true { await checkEvidence"),
    ("done line moves live", T, "clauses: [], live: true, at: at)", "clauses: [], live: false, at: at)"),
    ("one session, several cards", H, "var links = (next[sessionID] ?? []).filter { $0.workID != source.id }", "var links: [WorkSessionCardLink] = []"),
    ("Follow only on Continue", H, "guard advice.action == .continueSession, let sessionID", "guard let sessionID"),
    ("forward move resumes", S, '            if to != "complete" { resumeIfMovedForward(workID: workID, currentStage: to) }\n', ""),
    ("back move pauses", S, '            pause(workID: workID, stage: to, why: "You moved it back to \\(WorkProgress.stageTitle(to)).", at: at)\n', ""),
    ("settings keep other keys", S, "                object = read\n", "                _ = read\n"),
    ("unknown model reads Haiku", S, "return WorkSweepModel(rawValue: raw) ?? .haiku", "return WorkSweepModel(rawValue: raw) ?? .sonnet"),
    ("handoff path respects card pause", T, "        if store.follows.isPaused(row.workID) {\n            write(id)", "        if false {\n            write(id)"),
    ("look back to card creation", T, "let since = Self.cardCreated(task) ?? active.map(\\.startedAt).min() ?? at", "let since = active.map(\\.startedAt).min() ?? at"),
    ("cursor kept", T, '            follows.setCursor(workID: workID, sessionID: cursor.provider + ":" + cursor.sessionId, cursor: cursor.cursor)\n', ""),
    ("8 checks a day", T, "card.checks.filter({ at - $0 < 86_400 }).count < Self.maxChecksPerDay", "true"),
    ("cached answers not counted", T, "if !result.cached && result.skipped == nil { card.checks.append(at) }", "card.checks.append(at)"),
    ("split on new lines", S, 'doneWhen.split(whereSeparator: { $0 == ";" || $0.isNewline })', 'doneWhen.split(whereSeparator: { $0 == ";" })'),
    ("at most 6 parts", S, "if parts.count > maxClauses {", "if parts.count > 7 {"),
    ("markers refused", S, "if saved.range(of: markerPattern, options: .regularExpression) != nil {", "if false {"),
    ("idle from the transcript", T, "        guard !reads.isEmpty, reads.allSatisfy({ Self.transcriptIdle($0, now: at) }) else { return }", "        guard !reads.isEmpty else { return }"),
    ("partial needs one met", S, "return met > 0 && met < clauses.count ? (met, clauses.count) : nil", "return met < clauses.count ? (met, clauses.count) : nil"),
    # Helper body validator (helper lane).
    ("helper: at most 4 follows", HELPER, 'let follows = body["follows"] as? [Any], follows.count <= 4,', 'let follows = body["follows"] as? [Any], follows.count <= 5,'),
    ("helper: one follow per session", HELPER, '                  seen.insert(provider + ":" + session).inserted else { return false }', "                  true else { return false }"),
    ("helper: cursor null or text", HELPER, "                guard let text = cursor as? String, (1...2_048).contains(text.utf8.count) else { return false }", "                _ = cursor"),
    ("helper: exactly the contract keys", HELPER, 'guard Set(body.keys) == ["domain", "id", "follows", "clauses", "since"],', 'guard Set(body.keys).isSuperset(of: ["domain", "id", "follows", "clauses", "since"]),'),
    ("helper: 16 KB stdin", HELPER, "let data = try readBoundedStdin(16_384)\n        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Self.evidenceCheckBodyValid(body)",
     "let data = try readBoundedStdin(4_096)\n        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Self.evidenceCheckBodyValid(body)"),
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
    if r.returncode in (GUARD_STOP, 75) and "compile-guard:" in r.stderr:
        raise Stop(r.stderr.strip().splitlines()[-1])
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
    try:
        for base in (("baseline (Swift)", S, None, None), ("baseline (helper)", HELPER, None, None)):
            name, verdict, why = run(src, scratch, base)
            print(name, "green" if verdict == "SURVIVED" else verdict + " " + why, flush=True)
            if verdict != "SURVIVED": sys.exit("the unmutated copy is not green; no mutant result means anything")
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
