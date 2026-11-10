#!/usr/bin/env python3
"""0.5.389 (D4) mutation gate for the turn-end ask.

    python3 Tests/mutate-turn-end-ask.py [mutant-name ...]

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
    "models": (["-target", "arm64-apple-macosx14.0"] + FLAGS + ["Sources/Models.swift", "Tests/TurnEndAskChecks.swift", "-framework", "AppKit"]),
    # The wiring pins, no compile.
    "pins": "pins",
}
M, W, H = "Sources/Models.swift", "Sources/ActivityWindow.swift", "HelperSources/main.swift"
MUTANTS = [
    ("source-not-checked", "models", M, ", session.waitingSource == turnEndSource else { return nil }", " else { return nil }",
     "no waiting_source (feature off, older server): nothing changes"),
    ("not-waiting-allowed", "models", M, 'session.provider == "claude", isWaiting(session), session.waitingSource', 'session.provider == "claude", session.waitingSource',
     "only while the row is waiting"),
    ("choices-uncapped", "models", M, "            if choices.count == turnEndMaxChoices { break }\n", "",
     "at most two"),
    ("choices-repeat", "models", M, "guard let label = guarded(raw), !choices.contains(label) else { continue }", "guard let label = guarded(raw) else { continue }",
     "at most two"),
    ("reply-bare-label", "models", M, "static func turnEndReply(choice: String) -> String { turnEndPrefix + choice }", "static func turnEndReply(choice: String) -> String { choice }",
     "a choice: the prefix, then the label"),
    ("empty-other-sent", "models", M, "return trimmed.isEmpty ? nil : turnEndPrefix + text", "return turnEndPrefix + text",
     "an empty Other sends nothing"),
    ("merge-drops-fields", "models", M, "                if next.waitingSource.isEmpty { next.waitingSource = listed.waitingSource; next.waitingChoices = listed.waitingChoices }\n", "",
     "a live row keeps the list row's turn-end fields"),
    ("today-sends", "pins", W, "        model.openClaudeSession(session)\n        model.prefillChat(words)\n    }\n\n    func commandCanContinue",
     "        model.openClaudeSession(session)\n        model.prefillChat(words)\n        model.sendChatMessage()\n    }\n\n    func commandCanContinue",
     "[today] nothing is sent from Today"),
    ("helper-key-missing", "pins", H, '        ("waiting_source", "waitingSource"), ("waiting_choices", "waitingChoices"),\n', "",
     "[server gated] the two additive keys"),
    ("draft-overwritten", "pins", W, "           !model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {", "           false {",
     "[today] never over another session's unsent reply"),
]

def build_and_run(kind, out):
    if BUILDS[kind] == "pins":
        r = subprocess.run(["python3", os.path.join(ROOT, "Tests/turn-end-ask-pins.py"), ROOT], capture_output=True, text=True)
        return ("pass" if r.returncode == 0 else "fail"), r.stdout + r.stderr
    if BUILDS[kind] is None:
        r = subprocess.run(["zsh", os.path.join(ROOT, "Tests/run-work-handoff.sh")], cwd=ROOT, capture_output=True, text=True, timeout=3600)
        log = r.stdout + r.stderr
        return ("pass" if r.returncode == 0 else ("compile" if " error: " in log else "fail")), log
    cmd = ["zsh", GUARD, "swiftc"] + BUILDS[kind] + ["-o", out]
    c = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if c.returncode != 0:
        return "compile", c.stdout + c.stderr
    r = subprocess.run([out], cwd=ROOT, capture_output=True, text=True, timeout=300)
    return ("pass" if r.returncode == 0 else "fail"), r.stdout + r.stderr

def main():
    want = set(sys.argv[1:])
    tmp = tempfile.mkdtemp(prefix="cos-mutate-d4.")
    chosen = [m for m in MUTANTS if not want or m[0] in want]
    for kind in [k for k in BUILDS if any(m[1] == k for m in chosen)]:
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
