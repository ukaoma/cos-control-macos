#!/usr/bin/env python3
"""Reply in the message reader (D4): mutation gate.

    python3 Tests/mutate-message-reply.py [--targets] [mutant-name ...]

Builds each kind unmutated and refuses unless it passes (a gate over a red suite proves nothing); then for each mutant asserts
its target appears EXACTLY ONCE, applies it, rebuilds, and requires a FAIL carrying the named message. Files are restored in
`finally`. Compiles run one at a time through Tests/compile-guard.sh, under the swift-slot lease.
"""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "Tests/compile-guard.sh")
SW = ["-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete"]
BUILDS = {
    "models": SW + ["Sources/DropIt.swift", "Sources/Models.swift", "Tests/MessageReplyChecks.swift", "-framework", "AppKit"],
    "pins": "pins",
    "helper": "helper",
}
M, D, W, V, H, HS = "Sources/Models.swift", "Sources/DropIt.swift", "Sources/ActivityWindow.swift", "Sources/MessageReplyView.swift", "Sources/WorkHandoffStore.swift", "HelperSources/main.swift"
MUTANTS = [
    ("lines-swapped", "models", M, "session(sessionId) == nil ? startsLine : continuesLine", "session(sessionId) == nil ? continuesLine : startsLine",
     "[session] with one it says it continues"),
    ("any-session-sent", "models", M, '''sessionId.range(of: "\\\\A[A-Za-z0-9-]{8,80}\\\\z", options: .regularExpression) != nil ? sessionId : nil''', "sessionId.isEmpty ? nil : sessionId",
     "[session] an id the helper would refuse is never sent"),
    ("effort-any-agent", "models", M, "effortChoices(provider: provider, efforts: efforts).contains { $0.value == effort }", "efforts.values.joined().contains { $0.value == effort }",
     "[effort] an effort goes only with a model whose agent was offered it"),
    ("haiku-listed", "models", M, '[("opus", "Claude Opus"), ("fable", "Claude Fable"), ("sonnet", "Claude Sonnet")]',
     '[("opus", "Claude Opus"), ("fable", "Claude Fable"), ("sonnet", "Claude Sonnet"), ("haiku", "Claude Haiku")]', "[menu] the web's order; Haiku is not on it"),
    ("unready-listed", "models", M, "guard let row = runs(e.id), row.available else { return nil }", "guard let row = runs(e.id) else { return nil }",
     "[menu] the web's order; Haiku is not on it; Cursor only when ready"),
    ("pick-ignored", "models", M, "if let picked, menu.contains(where: { $0.id == picked }) { return picked }", "",
     "[model] a pick on the menu is used, Opus included"),
    ("default-first", "models", M, "return menu.contains { $0.id == defaultModel } ? defaultModel : menu.first?.id", "return menu.first?.id",
     "[model] nothing picked: Sonnet"),
    ("shown-always", "models", M, "static func available(_ models: [(id: String, available: Bool, resolved: String?)]) -> Bool { !menu(models).isEmpty }",
     "static func available(_ models: [(id: String, available: Bool, resolved: String?)]) -> Bool { true }", "[shown] Reply shows only where the menu has a model"),
    ("substitute-model", "pins", W, "runNote = modelID == nil ? \"No model is available for a Work run. Open Work to start one.\" : MessageReply.modelGoneLine",
     "runNote = \"No model is available for a Work run. Open Work to start one.\"", "[run] a picked model only while Work can run it"),
    ("parity-drift", "pins", M, '("cursor-composer", "Cursor", "Composer")', '("cursor-composer", "Cursor", "Composer 2")', "[parity] the engines"),
    ("no-fresh-retry", "models", D, "        if case .refused = start, session != nil { start = await askJob(MessageReply.target(turnID: turnID, replyID: replyID + \"-fresh\"), words, ids, nil, nil) }\n", "",
     "[retry] a refused session starts fresh"),
    ("session-dropped", "models", D, "var start = await askJob(MessageReply.target(turnID: turnID, replyID: replyID), words, ids, session, nil)",
     "var start = await askJob(MessageReply.target(turnID: turnID, replyID: replyID), words, ids, nil, nil)", "[reply] it sends the words, trimmed, with the turn's session"),
    ("untagged", "models", D, "            made.replyTo = turnID\n", "", "[reply] it is kept as this turn's reply"),
    ("mount-removed", "pins", W, '''                MessageReplyBlock(store: model.messageReply, handoff: handoffStore, turn: turn, onAppear: wireMessageReply)
                    .id("reply:" + turn.id)
''', "", "[reader] Reply mounts once"),
    ("effort-always", "pins", V, "        if !efforts.isEmpty {\n", "        if true {\n", "[effort] Effort shows only when the server serves efforts"),
    ("effort-ungated", "pins", W, "MessageReply.effortOffered(e, provider: handoff.models[index].provider, efforts: handoff.efforts) ? e : nil", "e",
     "[run] an effort only one the server served"),
    ("effort-every-mode", "pins", H, "if mode == .newSession, let effort { job[\"effort\"] = effort }", "if let effort { job[\"effort\"] = effort }",
     "[handoff] the effort rides only a new Work run"),
    ("chat-store-used", "pins", W, "MessageReplyBlock(store: model.messageReply,", "MessageReplyBlock(store: model.dropIt,", "[reader] Reply mounts once"),
    ("helper-any-effort", "helper", HS, "guard let effort = value as? String, workEffortValues.contains(effort) else { return nil }",
     "guard let effort = value as? String else { return nil }", "Work effort contract self-test failed"),
    ("helper-efforts-raw", "helper", HS, "guard let value = row[\"value\"] as? String, workEffortValues.contains(value), seen.insert(value).inserted else { return nil }",
     "guard let value = row[\"value\"] as? String else { return nil }", "Work effort contract self-test failed"),
]

def helper_build(out):
    files = ["HelperSources/main.swift", "HelperSources/ProviderStatusCore.swift", "HelperSources/PairingCore.swift",
             "HelperSources/SessionUsageCollector.swift", "Sources/SessionUsageCore.swift", "Sources/WorkSessionLinks.swift"]
    c = subprocess.run(["zsh", GUARD, "swiftc"] + SW + [os.path.join(ROOT, f) for f in files] + ["-framework", "Security", "-framework", "AppKit", "-o", out],
                       cwd=ROOT, capture_output=True, text=True)
    if c.returncode != 0: return "compile", c.stdout + c.stderr
    home = tempfile.mkdtemp(prefix="cos-mr-helper-home.")
    env = {**os.environ, "HOME": home, "CFFIXED_USER_HOME": home, "COS_CONTROL_TEST_HOME": home}
    # The Work contract self-tests (workNewPayload, workEffort, workEfforts) run under `self-test-work`; it answers in JSON.
    r = subprocess.run([out, "self-test-work"], cwd=ROOT, capture_output=True, text=True, timeout=600, env=env)
    import json
    try: ok = json.loads(r.stdout.strip().splitlines()[-1]).get("ok") is True
    except Exception: ok = False
    return ("pass" if ok else "fail"), r.stdout + r.stderr

def build_and_run(kind, out):
    if BUILDS[kind] == "pins":
        r = subprocess.run(["python3", os.path.join(ROOT, "Tests/message-reply-pins.py"), ROOT], capture_output=True, text=True)
        return ("pass" if r.returncode == 0 else "fail"), r.stdout + r.stderr
    if BUILDS[kind] == "helper":
        return helper_build(out)
    c = subprocess.run(["zsh", GUARD, "swiftc"] + BUILDS[kind] + ["-o", out], cwd=ROOT, capture_output=True, text=True)
    if c.returncode != 0: return "compile", c.stdout + c.stderr
    home = tempfile.mkdtemp(prefix="cos-mr-home.")
    r = subprocess.run([out], cwd=ROOT, capture_output=True, text=True, timeout=300, env={**os.environ, "HOME": home, "CFFIXED_USER_HOME": home, "COS_CONTROL_TEST_HOME": home})
    return ("pass" if r.returncode == 0 else "fail"), r.stdout + r.stderr

def main():
    want = set(sys.argv[1:]); targets_only = "--targets" in want; want.discard("--targets")
    chosen = [m for m in MUTANTS if not want or m[0] in want]
    for name, kind, rel, target, repl, message in chosen:
        hits = open(os.path.join(ROOT, rel)).read().count(target)
        if hits != 1: sys.exit(f"REFUSED: mutant {name} target appears {hits} times in {rel}, expected exactly 1")
    if targets_only: print(f"targets: {len(chosen)} found exactly once"); return
    tmp = tempfile.mkdtemp(prefix="cos-mutate-d4-reply.")
    for kind in [k for k in BUILDS if any(m[1] == k for m in chosen)]:
        state, log = build_and_run(kind, os.path.join(tmp, "base-" + kind))
        print(f"baseline {kind}: {state}")
        if state != "pass": print(log[-3000:]); sys.exit("REFUSED: baseline is not green, so no mutant result would mean anything")
    killed = survived = 0
    for name, kind, rel, target, repl, message in chosen:
        path = os.path.join(ROOT, rel); original = open(path).read()
        try:
            open(path, "w").write(original.replace(target, repl, 1)); state, log = build_and_run(kind, os.path.join(tmp, name))
        finally:
            open(path, "w").write(original)
        assert open(path).read() == original, f"{rel} not restored after {name}"
        if state == "fail" and message in log: killed += 1; print(f"KILLED   {name}: failed with '{message}'")
        else: survived += 1; print(f"SURVIVED {name}: state={state}, named message seen={message in log}"); print(log[-2000:])
    print(f"mutants: {killed} killed, {survived} survived"); sys.exit(1 if survived else 0)

if __name__ == "__main__":
    main()
