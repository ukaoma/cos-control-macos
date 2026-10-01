#!/usr/bin/env python3
"""0.5.254 resize pass: mutation lane for the Work board's cached rows. Run by hand, never by a gate (each mutant
compiles the app).

    python3 Tests/mutate-work-board-cache.py <worktree> <scratch dir> [name ...]

The rows are rebuilt only when a source's epoch moves (WorkWorkspaceState.board). Each epoch is bumped where its
source is stored (a didSet), so every write to the source, in place or whole, passes through it. These mutants take a
bump, a key field or a memo rule away; the cache checks must then see a stale board and say which (failures read
"check failed [<behaviour>]"). It copies the worktree to <scratch dir>/copy, proves the UNMUTATED checks are green
first (Tests/run-work-board-cache.sh), then applies one mutant at a time: the target text must appear exactly once,
the mutant must make a check fail, and the failure must name the behaviour. A mutant that lands and survives is a
finding. One suite at a time.
"""
import pathlib, shutil, subprocess, sys, time

V = "Sources/WorkWorkspaceView.swift"
H = "Sources/WorkHandoffStore.swift"
SESSIONS_KEY = "sessions: handoffStore.isolated ? handoffStore.sessionsEpoch : handoffStore.activitySessionsEpoch,"
FILTER = "let next = Filter(scope: scope, domain: domain, query: query)"
RESET = "        filter = nil; cardsDomain = nil\n"
CAPACITY = "        while !rowOverflows(cards: capacity + 1, width: width) { capacity += 1 }\n        return capacity\n"
# (name, file, original, mutant, words the killing failure must contain)
MUTANTS = [
    # Each source's epoch: no bump, a stale board.
    ("epoch: a stage move", "Sources/ControllerModel.swift", "{ didSet { workTasksEpoch &+= 1 } }", "{ didSet { } }", "[stale after a stage move]"),
    ("epoch: a receipt change", H, "{ didSet { receiptsEpoch &+= 1 } }", "{ didSet { } }", "[stale after a receipt change]"),
    ("epoch: a live session change", H, "{ didSet { if activitySessions != oldValue { activitySessionsEpoch &+= 1 } } }", "{ didSet { } }", "[stale after a session change]"),
    ("epoch: a preview session change", H, "{ didSet { sessionsEpoch &+= 1 } }", "{ didSet { } }", "[stale after a session change]"),
    ("epoch: a preview task change", H, "{ didSet { previewTasksEpoch &+= 1 } }", "{ didSet { } }", "[stale after a preview task change]"),
    ("epoch: a review change", "Sources/WorkReviewStore.swift", "{ didSet { reviewsEpoch &+= 1 } }", "{ didSet { } }", "[stale after a review change]"),
    ("epoch: a preview stage move", V, "{ didSet { previewStagesEpoch &+= 1 } }", "{ didSet { } }", "[stale after a preview stage move]"),
    ("epoch: an unchanged session check rebuilds", H, "if activitySessions != oldValue { activitySessionsEpoch &+= 1 }", "activitySessionsEpoch &+= 1",
     "[an unchanged session check keeps the rows]"),
    # The key: a source left out of it.
    ("key: tasks", V, "tasks: model.workTasksEpoch,", "tasks: 0,", "[stale after a stage move]"),
    ("key: receipts", V, "receipts: handoffStore.receiptsEpoch,", "receipts: 0,", "[stale after a receipt change]"),
    ("key: reviews", V, "reviews: reviewStore.reviewsEpoch,", "reviews: 0,", "[stale after a review change]"),
    ("key: the live session check", V, SESSIONS_KEY, "sessions: handoffStore.sessionsEpoch,", "[stale after a session change]"),
    ("key: the preview's sessions", V, SESSIONS_KEY, "sessions: handoffStore.activitySessionsEpoch,", "[stale after a session change]"),
    ("key: preview tasks", V, "previewTasks: handoffStore.previewTasksEpoch,", "previewTasks: 0,", "[stale after a preview task change]"),
    ("key: preview stages", V, "previewStages: previewStagesEpoch,", "previewStages: 0,", "[stale after a preview stage move]"),
    ("key: the 45-second freshness", V, "fresh: handoffStore.isolated || handoffStore.activityFresh(now: now))", "fresh: true)",
     "[stale after the session check expires]"),
    ("key: which stores", V, "stores: [ObjectIdentifier(model), ObjectIdentifier(handoffStore), ObjectIdentifier(reviewStore)],", "stores: [],",
     "[stores in the key]"),
    # The memo.
    ("memo: never rebuilds", V, "guard key != self.key else { return self }", "guard self.key == nil else { return self }", "[stale after"),
    ("memo: rebuilds on every read", V, "guard key != self.key else { return self }", "guard true else { return self }", "[unchanged data keeps the rows]"),
    ("memo: the filter outlives the rows", V, RESET, "        cardsDomain = nil\n", "[stale after a stage move]"),
    ("memo: the session cards outlive the rows", V, RESET, "        filter = nil\n", "[stale session cards after a receipt change]"),
    ("memo: the filter ignores the query", V, FILTER, 'let next = Filter(scope: scope, domain: domain, query: "")', "[the filter follows the query]"),
    ("memo: the filter ignores the domain", V, FILTER, "let next = Filter(scope: scope, domain: nil, query: query)", "[the filter follows the domain]"),
    ("memo: the filter ignores the scope", V, FILTER, "let next = Filter(scope: .all, domain: domain, query: query)", "[the filter follows the scope]"),
    ("memo: columns ignore the filter", V, "columns = Dictionary(grouping: filtered.filter { $0.task != nil })",
     "columns = Dictionary(grouping: items.filter { $0.task != nil })", "[the filter follows"),
    ("memo: session cards ignore the domain", V, "if cardsDomain != .some(domain) {", "if cardsDomain == nil {", "[session cards follow the domain]"),
    # The rows themselves (one pass over the journal) and the session row's stored capacity.
    ("projection: receipts found by the wrong id", V, "            let mine = receiptsByWork[source.id] ?? []\n", "            let mine = receiptsByWork[task.id] ?? []\n",
     "receipt"),
    ("capacity: one card too many", V, CAPACITY, CAPACITY.replace("return capacity\n", "return capacity + 1\n"), "[row capacity matches the overflow rule]"),
    ("capacity: an unmeasured row casts an edge", V, "guard width > 0 else { return .max }", "guard width > 0 else { return 0 }",
     "[row capacity matches the overflow rule]"),
]

def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started

def suite(copy):
    return run(["zsh", "Tests/run-work-board-cache.sh"], copy)

def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "Resources"):
        shutil.copytree(src / part, copy / part)
    code, out, seconds = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS:")]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(p[:140] for p in passed) or '(no PASS line)'}", flush=True)
    if code != 0 or not passed:
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed, survived = 0, 0
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out, seconds = suite(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        lines = [l for l in out.splitlines() if "check failed [" in l or "error:" in l]
        reason = lines[0].strip() if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:220]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:220]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour", flush=True)
    sys.exit(0 if survived == 0 else 1)

if __name__ == "__main__":
    main()
