#!/usr/bin/env python3
"""0.5.262 mutation lane for the Work follows and evidence guards. Run by hand, never by a gate (each mutant compiles).

    python3 Tests/mutate-work-follows.py <worktree> <scratch dir> [--workers N] [name ...]

Proves the UNMUTATED copy green first (Tests/run-work-progress.sh, and the compiled helper's
Tests/work-progress-helper-checks.py), then runs each mutant in its own copy: the target text must appear exactly once,
and the mutant must make a check fail. A mutant that lands and survives is a finding. Swift mutants run the Work tracking
checks; helper mutants compile the helper and run its self-test-work and the loopback helper checks.
"""
import os, pathlib, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

S, T, H = "Sources/WorkProgress.swift", "Sources/WorkProgressTracker.swift", "Sources/WorkHandoffStore.swift"
HELPER = "HelperSources/main.swift"
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

def lane(work, helper):
    if not helper:
        r = subprocess.run(["zsh", "Tests/run-work-progress.sh"], cwd=work, capture_output=True, text=True)
        return r.returncode == 0, r.stdout + r.stderr
    binary = work / "cos-control-helper"
    r = subprocess.run(["swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
                        str(work / HELPER), "-framework", "Security", "-framework", "AppKit", "-o", str(binary)], capture_output=True, text=True)
    if r.returncode != 0: return False, "helper did not compile\n" + r.stderr
    home = work / "home"; home.mkdir(exist_ok=True)
    st = subprocess.run([str(binary), "self-test-work"], env=dict(os.environ, COS_CONTROL_TEST_HOME=str(home)), capture_output=True, text=True)
    py = subprocess.run(["python3", str(work / "Tests/work-progress-helper-checks.py"), str(binary)], capture_output=True, text=True)
    ok = '"ok":true' in st.stdout and py.returncode == 0
    return ok, st.stdout + py.stdout + py.stderr

def run(src, scratch, mutant):
    name, path, old, new = mutant
    work = scratch / ("m-" + "".join(c if c.isalnum() else "-" for c in name))
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(src, work, ignore=shutil.ignore_patterns(".git"))
    if path:
        text = (work / path).read_text()
        if text.count(old) != 1: return name, "BAD TARGET (found %d times)" % text.count(old)
        (work / path).write_text(text.replace(old, new))
    ok, log = lane(work, path == HELPER)
    (scratch / (work.name + ".log")).write_text(log)
    shutil.rmtree(work, ignore_errors=True)
    lines = [l for l in log.splitlines() if "check failed" in l or "Precondition failed" in l or "error:" in l or "AssertionError" in l or "FAILED" in l]
    return name, "passed" if ok else "failed: " + (lines[0].strip()[:200] if lines else "non-zero exit")

def main():
    args = sys.argv[1:]
    workers = 8
    if "--workers" in args:
        i = args.index("--workers"); workers = int(args[i + 1]); del args[i:i + 2]
    src, scratch = pathlib.Path(args[0]), pathlib.Path(args[1])
    scratch.mkdir(parents=True, exist_ok=True)
    chosen = [m for m in MUTANTS if not args[2:] or m[0] in args[2:]]
    for base in (("baseline (Swift)", None, None, None), ("baseline (helper)", HELPER, "static func evidenceCheckBodyValid(", "static func evidenceCheckBodyValid(")):
        name, verdict = run(src, scratch, base)
        print(name, verdict, flush=True)
        if verdict != "passed": sys.exit("the unmutated copy is not green; no mutant result means anything")
    survivors = 0
    with ThreadPoolExecutor(workers) as pool:
        for name, verdict in pool.map(lambda m: run(src, scratch, m), chosen):
            if verdict == "passed": survivors += 1
            print(("SURVIVED " if verdict == "passed" else "killed   ") + name + " :: " + verdict, flush=True)
    print(f"{len(chosen) - survivors} of {len(chosen)} killed, {survivors} survived")
    sys.exit(1 if survivors else 0)

main()
