#!/usr/bin/env python3
"""0.5.388 (D4 item 7) mutation gate for the question card.

    python3 Tests/mutate-session-question-card.py [mutant-name ...]

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
    "models": (["-target", "arm64-apple-macosx14.0"] + FLAGS + ["Sources/Models.swift", "Tests/SessionQuestionCardChecks.swift", "-framework", "AppKit"]),
    # The wiring pins, no compile.
    "pins": "pins",
}
MUTANTS = [
    ("answerable-ignores-server", "models", "Sources/Models.swift",
     'heldId = state == .held && o["answerable"]?.bool == true && fits ? held : nil', 'heldId = state == .held && fits ? held : nil',
     "held but not answerable: the server's word wins"),
    ("answerable-ignores-fit", "models", "Sources/Models.swift",
     'o["answerable"]?.bool == true && fits ? held : nil', 'o["answerable"]?.bool == true ? held : nil',
     "more questions than the card shows"),
    ("match-newest-not-held", "models", "Sources/Models.swift",
     ".min { rank($0) != rank($1) ? rank($0) < rank($1) : $0.askedAt > $1.askedAt }", ".min { $0.askedAt > $1.askedAt }",
     "a held, answerable question comes first"),
    ("single-select-takes-two", "models", "Sources/Models.swift",
     "guard count >= 1, item.multiSelect || count == 1 else { return nil }", "guard count >= 1 else { return nil }",
     "single select takes exactly one"),
    ("unknown-label-sent", "models", "Sources/Models.swift",
     "guard labels.count == pick.labels.count else { return nil }", "",
     "an unknown label is never sent"),
    ("short-id-matches-anything", "models", "Sources/Models.swift",
     "min(a.count, b.count) >= 8 && ", "",
     "fewer than 8 characters never matches"),
    ("words-invented-when-missing", "models", "Sources/Models.swift",
     "if let text = questionText(session) { return .words(text) }\n        return .none", "return .words(questionText(session) ?? \"\")",
     "no card and no words: the plain line"),
    ("not-shown-reads-as-settled", "models", "Sources/Models.swift",
     '        case (409, "not_shown"?): return .failed(', '        case (409, "not_shown_never"?): return .failed(',
     "409 not_shown: not on the devices yet"),
    ("already-answered-says-mac", "models", "Sources/Models.swift",
     'case (409, "already_answered"?): return .settled("Already answered on another device.")',
     'case (409, "already_answered"?): return .settled("Already answered, here or at the Mac.")',
     "409 already answered: another COS device"),
    ("retracted-reads-as-left", "models", "Sources/Models.swift",
     ' where reason == "retracted"', ' where reason == "never"',
     "409 handed to the desk, retracted"),
    ("hook-gone-sends-to-dialog", "models", "Sources/Models.swift",
     'case (410, _): return .settled("This question is no longer waiting.")',
     'case (410, _): return .settled("This question can no longer be answered here. Answer it \\(place).")',
     "410: no longer waiting"),
    ("picks-carry-over", "models", "Sources/Models.swift",
     "previousKey == question.key && current.count == question.questions.count", "current.count == question.questions.count",
     "a new question starts with nothing picked"),
    ("other-over-limit-sent", "models", "Sources/Models.swift",
     "guard other.utf16.count <= 2_000 else { return nil }", "",
     "Other over 2,000 characters is refused"),
    ("new-picks-replay-old-id", "models", "Sources/Models.swift",
     "guard let last, last.answers == answers else { return nil }", "guard let last else { return nil }",
     "different answers get a new id"),
    ("absent-list-polled-fast", "models", "Sources/Models.swift",
     "listPresent ? 10 : 300", "10",
     "5 minutes when it does not"),
    ("picks-kept-without-id", "pins", "Sources/ActivityWindow.swift",
     ".id(questionCard.key)", "",
     "[picks] a new question starts with nothing picked"),
    ("list-registers-as-client", "pins", "HelperSources/main.swift",
     'request("/api/session-questions", method: "GET"', 'request("/api/session-questions?client=control", method: "GET"',
     "[no live client]"),
    ("answer-sends-approval", "pins", "HelperSources/main.swift",
     'Set(body.keys) == ["clientAnswerId", "answers"]', 'Set(body.keys).isSubset(of: ["clientAnswerId", "answers", "decision"])',
     "[answer] the body is a question answer"),
]

def build_and_run(kind, out):
    if BUILDS[kind] == "pins":
        r = subprocess.run(["python3", os.path.join(ROOT, "Tests/session-question-pins.py"), ROOT], capture_output=True, text=True)
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
