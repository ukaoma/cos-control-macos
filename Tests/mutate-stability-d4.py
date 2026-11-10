#!/usr/bin/env python3
"""0.5.387 (D4) mutation gate for the duplicate-id and usage-index guards.

    python3 Tests/mutate-stability-d4.py [mutant-name ...]

1. Builds both checks unmutated and refuses to go on unless they PASS (a gate over a red suite proves nothing).
2. For each mutant: asserts its target text appears EXACTLY ONCE, applies it, rebuilds the one affected check, and
   requires the check to FAIL with the named precondition message. The file is restored in `finally`.
Compiles run one at a time through Tests/compile-guard.sh. Run it under the swift-slot lease.
"""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "Tests/compile-guard.sh")
FLAGS = ["-swift-version", "6", "-strict-concurrency=complete"]
BUILDS = {
    "models": (["-target", "arm64-apple-macosx14.0"] + FLAGS + ["Sources/Models.swift", "Tests/StabilityD4Checks.swift", "-framework", "AppKit"]),
    "helper": (FLAGS + ["-parse-as-library", "Sources/SessionUsageCore.swift", "HelperSources/SessionUsageCollector.swift", "Tests/StabilityD4HelperChecks.swift"]),
}
MUTANTS = [
    # (name, build, file, target, replacement, message the killing check prints)
    ("pet-first-copy-wins", "models", "Sources/Models.swift",
     "activity(other) > activity(kept) ? other : kept", "kept",
     "an idle copy listed first does not hide a copy that still runs"),
    ("pet-repeat-prior-emits-twice", "models", "Sources/Models.swift",
     "guard !suppressedIDs.contains(prior.id), emitted.insert(prior.id).inserted else { continue }",
     "guard !suppressedIDs.contains(prior.id) else { continue }",
     "a prior listed twice emits one finish"),
    ("calendar-last-repeat-wins", "models", "Sources/Models.swift",
     "uniquingKeysWith: { max($0, $1) })", "uniquingKeysWith: { $1 })",
     "a repeated date keeps its largest count"),
    ("usage-index-never-built", "helper", "HelperSources/SessionUsageCollector.swift",
     "do { try ensureRollupIndex() } catch let failure as Failure where failure.busy { historyBusy = true }", "",
     "an importing pass builds usage_rollup"),
    ("usage-index-not-covering", "helper", "HelperSources/SessionUsageCollector.swift",
     "ON events(day,provider,model,input,output,cache_read,cache_write,usd)", "ON events(day,provider,model)",
     "the summary reads the covering index"),
    ("usage-index-built-read-only", "helper", "HelperSources/SessionUsageCollector.swift",
     "        if !readOnly {\n            do { try ensureRollupIndex() }", "        if true {\n            do { try ensureRollupIndex() }",
     "a read-only pass never creates the index"),
]

def build_and_run(kind, out):
    cmd = ["zsh", GUARD, "swiftc"] + BUILDS[kind] + ["-o", out]
    c = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if c.returncode != 0:
        return "compile", c.stdout + c.stderr
    r = subprocess.run([out], cwd=ROOT, capture_output=True, text=True, timeout=300)
    return ("pass" if r.returncode == 0 else "fail"), r.stdout + r.stderr

def main():
    want = set(sys.argv[1:])
    tmp = tempfile.mkdtemp(prefix="cos-mutate-d4.")
    for kind in BUILDS:
        state, log = build_and_run(kind, os.path.join(tmp, "base-" + kind))
        print(f"baseline {kind}: {state}")
        if state != "pass":
            print(log[-3000:]); sys.exit("REFUSED: baseline is not green, so no mutant result would mean anything")
    killed = survived = 0
    for name, kind, rel, target, repl, message in MUTANTS:
        if want and name not in want: continue
        path = os.path.join(ROOT, rel)
        original = open(path).read()
        hits = original.count(target)
        if hits != 1:
            sys.exit(f"REFUSED: mutant {name} target appears {hits} times in {rel}, expected exactly 1")
        try:
            open(path, "w").write(original.replace(target, repl, 1))
            state, log = build_and_run(kind, os.path.join(tmp, name))
        finally:
            open(path, "w").write(original)
        assert open(path).read() == original, f"{rel} not restored after {name}"
        named = message in log
        if state == "fail" and named:
            killed += 1; print(f"KILLED   {name}: failed with '{message}'")
        else:
            survived += 1; print(f"SURVIVED {name}: state={state}, named message seen={named}"); print(log[-2000:])
    print(f"mutants: {killed} killed, {survived} survived")
    sys.exit(1 if survived else 0)

if __name__ == "__main__":
    main()
