#!/usr/bin/env python3
"""Control's half of the restart lockout, mutation gate. SERIAL through Tests/compile-guard.sh on a scratch copy (the checkout
is never mutated). A green baseline first; each mutant must land exactly once, fail, and fail on the check named for it.
Model mutants need only the small compile, helper mutants a full helper compile. Hand-run.
Usage: python3 Tests/mutate-meeting-restart.py <repo root>"""
import pathlib, shutil, subprocess, sys, tempfile, time

sys.stdout.reconfigure(line_buffering=True)
root = pathlib.Path(sys.argv[1]).resolve()
MAIN, MODELS = "HelperSources/main.swift", "Sources/Models.swift"
HELPER = [MAIN, "HelperSources/ProviderStatusCore.swift", "HelperSources/PairingCore.swift", "HelperSources/SessionUsageCollector.swift", "Sources/SessionUsageCore.swift", "Sources/WorkSessionLinks.swift"]
SMALL = ["Sources/KeyLanes.swift", MODELS]
MUTANTS = [
    ("the stopped phase is ignored", MODELS, 'var isHeld: Bool { phase == "stopped" }', "var isHeld: Bool { false }", "a stopped row shows the server's words and is not waiting"),
    ("a waiting row reads as held", MODELS, 'var isHeld: Bool { phase == "stopped" }', 'var isHeld: Bool { phase == "stopped" || phase == "pending" }', "an older server's waiting row is unchanged"),
    ("held rows sort with the work", MODELS, "row.isHeld ? 2 : row.isWaiting ? 1 : 0", "row.isWaiting ? 1 : 0", "held rows sort after work and the queue"),
    ("the note shows while blocked", MODELS, "guard !meetingWorkBlockingRestart else { return nil }", "", "real work beside a held job still blocks, with no note saying otherwise"),
    ("the unanswered reason is lost", MODELS, "if meetingSyncUnconfirmed {", "if false {", "a server that does not answer stays blocked and says why"),
    ("a stopped row blocks", MODELS, "            || displayedMeetingSync.blocksRestart\n", '            || displayedMeetingSync.blocksRestart\n            || meetingSyncMeetings.contains(where: \\.isHeld)\n', "a stopped job blocks nothing and says so"),
    ("stopped audio still blocks", MAIN, "if !workCanRun {", "if false {", "stopped, held audio blocks nothing"),
    ("a silent process reads as HQ polish", MAIN, "} else if !serverAnswered {", "} else if false {", "a process that does not answer stays blocked and says why"),
    ("the reason never hears it", MAIN, '"meetingSyncUnconfirmed": active && !serverAnswered,', '"meetingSyncUnconfirmed": false,', "a process that does not answer stays blocked and says why"),
    ("a folder with no audio counts as kept", MAIN, "if wavs > 0 { heldMeetings += 1 }", "heldMeetings += 1", "a folder with no audio is not kept audio"),
    ("the row's phase stops at the helper", MAIN, 'row["phase"] as? String ?? "pending",', '"pending",', "the stopped row is visible with its label"),
]


def compiled(args):
    for _ in range(60):
        done = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", *args], capture_output=True, text=True)
        if done.returncode not in (70, 75): return done.returncode == 0, (done.stdout + done.stderr)[-1200:]
        time.sleep(30)
    sys.exit("shared compile lock stayed busy for 30 minutes")


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-meeting-restart-mutants-", dir="/private/tmp"))
try:
    for name in set(HELPER + SMALL):
        (work / name).parent.mkdir(parents=True, exist_ok=True); shutil.copy(root / name, work / name)
    helper, checks = work / "helper", work / "checks"
    # A mutant builds beside the baseline binaries, so the next mutant is not run against this one's leftovers.
    build_helper = lambda out=helper: compiled([*[str(work / f) for f in HELPER], "-framework", "Security", "-framework", "AppKit", "-o", str(out)])
    build_checks = lambda out=checks: compiled(["-parse-as-library", *[str(work / f) for f in SMALL], str(root / "Tests/MeetingRestartChecks.swift"), "-framework", "AppKit", "-o", str(out)])
    def run(helper_binary=helper, checks_binary=checks):
        return subprocess.run([sys.executable, str(root / "Tests/meeting-restart-checks.py"), str(helper_binary), str(checks_binary)], capture_output=True, text=True)
    for ok, why in (build_helper(), build_checks()):
        if not ok: sys.exit("baseline did not compile:\n" + why)
    base = run()
    if base.returncode != 0: sys.exit("baseline is not green:\n" + (base.stdout + base.stderr)[-1500:])
    print("GREEN BASELINE: " + base.stdout.strip())
    survivors, misattributed = [], []
    originals = {MAIN: (work / MAIN).read_text(), MODELS: (work / MODELS).read_text()}
    for name, target, old, new, label in MUTANTS:
        if originals[target].count(old) != 1: sys.exit(f"mutant '{name}' targets {originals[target].count(old)} sites")
        (work / target).write_text(originals[target].replace(old, new))
        mutated = work / "mutant"
        ok, why = build_helper(mutated) if target == MAIN else build_checks(mutated)
        if not ok: verdict = "KILLED (did not compile)"
        else:
            done = run(helper_binary=mutated) if target == MAIN else run(checks_binary=mutated)
            output = done.stdout + done.stderr
            if done.returncode == 0: verdict = "SURVIVED"; survivors.append(name)
            elif f"Fatal error: {label}" in output: verdict = "KILLED"
            else: verdict = "MISATTRIBUTED"; misattributed.append(f"{name}: {output.strip()[-200:]}")
        print(f"{verdict:24} {name}")
        (work / target).write_text(originals[target])
    if survivors or misattributed: sys.exit(f"survivors: {survivors}; misattributed: {misattributed}")
    print(f"PASS meeting restart mutation gate: {len(MUTANTS)} mutants, all killed by their named checks, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
