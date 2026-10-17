#!/usr/bin/env python3
"""0.5.316 mutation gate for the helper's Work chat plan failure words (HelperSources/main.swift workChatPlanFailure,
executed by `cos-control-helper self-test-work`). SERIAL helper compiles through Tests/compile-guard.sh on a scratch copy;
green baseline first. The last mutant (emitWorkChat ignores the mapping) cannot be seen by self-test-work, which never
runs the live POST; Tests/run-work-session-hub.sh pins it instead, so it is the one expected survivor here.

Usage: python3 Tests/mutate-work-chat-helper.py <repo root>
"""
import os
import pathlib, shutil, subprocess, sys, tempfile, json
root = pathlib.Path(sys.argv[1]).resolve(); H = "HelperSources/main.swift"
MUTANTS = [
 ("every failure reads as unavailable again", '        if status == 404 { return "Task chat planning is unavailable on this server (HTTP 404)." }', '        if status != 200 { return "Task chat planning is unavailable on this server (HTTP 404)." }'),
 ("timeout not told apart", '            return elapsedMs >= (timeoutSeconds - 5) * 1000', '            return false'),
 ("server code dropped", '        let code = (body?["error"] as? String) ?? (nested?["code"] as? String)', '        let code: String? = nil'),
 ("nested error shape ignored", '        let code = (body?["error"] as? String) ?? (nested?["code"] as? String)', '        let code = body?["error"] as? String'),
 ("protocol mismatch accepted", '            return version == 1 ? nil', '            return true ? nil'),
 ("busy reads as a planner failure", '        case "work_chat_busy":\n', '        case "work_chat_busy_never":\n'),
 ("emitWorkChat ignores the mapping", '        if let failure = Self.workChatPlanFailure(status: response?.status, body: response?.body, elapsedMs: elapsedMs, timeoutSeconds: 190) {', '        if let failure = Optional<String>.none {'),
]
def run(work):
    out = work / "helper"
    if out.exists(): out.unlink()
    b = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
        str(work/H), str(work/"HelperSources/ProviderStatusCore.swift"), str(work/"HelperSources/PairingCore.swift"), str(work/"Sources/WorkSessionLinks.swift"),
        "-framework", "Security", "-framework", "AppKit", "-o", str(out)], capture_output=True, text=True)
    if b.returncode: return 2, "compile"
    home = tempfile.mkdtemp(dir="/private/tmp")
    r = subprocess.run([str(out), "self-test-work"], capture_output=True, text=True, env={"COS_CONTROL_TEST_HOME": home, "PATH": "/usr/bin:/bin"})
    shutil.rmtree(home, ignore_errors=True)
    try: ok = json.loads(r.stdout).get("ok") is True
    except Exception: ok = False
    return (0 if ok and r.returncode == 0 else 1), r.stdout[:160]
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-helper-mutants-", dir="/private/tmp"))
# Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    (work/"HelperSources").mkdir(); (work/"Sources").mkdir()
    for f in ("HelperSources/main.swift","HelperSources/ProviderStatusCore.swift","HelperSources/PairingCore.swift","Sources/WorkSessionLinks.swift"): shutil.copy(root/f, work/f)
    code, msg = run(work)
    if code: sys.exit(f"baseline not green: {msg}")
    print("baseline GREEN", flush=True)
    original = (work/H).read_text(); surv = []
    for name, a, b in MUTANTS:
        if original.count(a) != 1: sys.exit(f"{name}: {original.count(a)} sites")
        (work/H).write_text(original.replace(a, b)); code, msg = run(work); (work/H).write_text(original)
        print(f"{'KILLED' if code == 1 else ('NO-COMPILE' if code == 2 else 'SURVIVED'):10} {name} :: {msg}", flush=True)
        if code != 1: surv.append(name)
    expected = {"emitWorkChat ignores the mapping"}
    if set(surv) - expected: sys.exit(f"FAIL survivors/no-compile: {sorted(set(surv) - expected)}")
    print(f"PASS Work chat helper mutation gate: {len(MUTANTS)} mutants, all killed but the pinned expected survivor, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
