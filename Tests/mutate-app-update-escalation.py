#!/usr/bin/env python3
"""Mutation lane for 0.5.322 (the update can no longer strand Control on Installing). Run by hand, never by a gate.
SERIAL: one mutant at a time, and every Swift compile goes through Tests/compile-guard.sh (two kernel panics on
2026-10-07 came from parallel compiles); a busy compile lock (exit 75) is waited out, never counted.

    python3 Tests/mutate-app-update-escalation.py <worktree> <scratch dir> [name ...]

It copies the worktree once to <scratch dir>/copy, proves each lane GREEN on the unmutated copy first (a red baseline
makes every mutant look killed), then applies one mutant at a time: every target must appear EXACTLY once, the mutant must
make a check fail, and the failure must name the behaviour it breaks (one of the listed words). A mutant that lands and
survives is a finding; so is one the compiler refuses (it never ran) or one killed by an unrelated check.
Lanes:
  escalation  the real helper (compiled from the copy) under Tests/app-update-escalation-checks.py
  selftest    the same helper's self-test (the pure safety rule, timings and the signal re-check)
  checks      Sources/Models.swift with Tests/AppUpdateBadgeChecks.swift
  macrec      Sources/MacRecordingCore.swift with Tests/MacRecordingChecks.swift
  wiring      Tests/run-app-update-finish.sh wiring (the whole app, against a stand-in and the real helper)
  pins        Tests/app-update-finish-pins.py (Python only)
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, time

H = "HelperSources/main.swift"
M = "Sources/Models.swift"
C = "Sources/ControllerModel.swift"
R = "Sources/MacRecording.swift"
RC = "Sources/MacRecordingCore.swift"
V = "Sources/Views.swift"

# (name, file, original, mutant, words (any one names the killing failure), lane)
MUTANTS = [
    # The swap's safety rule and its escalation (real helper, real processes).
    ("recording treated as safe", H, 'if macCaptureActivePhases.contains(phase) { return ("recording", phase) }',
     'if macCaptureActivePhases.contains(phase) { return ("safe", phase) }', ["[recording blocks the kill]"], "escalation"),
    ("recording phases unprotected", H, '        if macCaptureActivePhases.contains(phase) { return ("recording", phase) }\n', "",
     ["[recording blocks the kill]"], "escalation"),
    ("recording gives up as a timeout", H, '                return .gaveUp("recording")', '                return .gaveUp("quitTimeout")',
     ["[recording blocks the kill]", "[recording reason]"], "escalation"),
    ("no state file is safe", H, '              let phase = object["phase"] as? String else { return ("unknown", nil) }',
     '              let phase = object["phase"] as? String else { return ("safe", nil) }', ["[unknown signals nothing]"], "escalation"),
    ("another process's record is safe", H, 'pid == Int(livePIDs[0]) else { return ("unknown", phase) }',
     'pid == Int(livePIDs[0]) else { return ("safe", phase) }', ["[unknown signals nothing]"], "escalation"),
    ("two live processes, one record", H, "        guard livePIDs.count == 1, let pid = jsonInt", "        guard !livePIDs.isEmpty, let pid = jsonInt",
     ["[unknown signals nothing]"], "escalation"),
    ("identity filter off", H, "                if Self.sameFile(path, as: target) { running.append(LiveBundleProcess(pid: pid, started: started)) }",
     "                running.append(LiveBundleProcess(pid: pid, started: started))", ["[identity filter]"], "escalation"),
    ("no SIGKILL", H, "            let killed = survivors.filter { signalLiveProcess($0, SIGKILL, executable: target) }",
     "            let killed: [LiveBundleProcess] = []", ["[forced quit installs]", "[sigkill after sigterm]"], "escalation"),
    ("SIGKILL first", H, "        let termed = victims.filter { signalLiveProcess($0, SIGTERM, executable: target) }",
     "        let termed = victims.filter { signalLiveProcess($0, SIGKILL, executable: target) }", ["[sigterm first]"], "escalation"),
    ("no grace before forcing", H, "        while elapsed() < timings.quit {\n            if !bundleHasRunningProcess(live) { return .quit }",
     "        while elapsed() < 0 {\n            if !bundleHasRunningProcess(live) { return .quit }", ["[waits for a normal quit]"], "escalation"),
    ("SIGTERM grace skipped", H, "            if survivors.isEmpty || Date() >= termDeadline { break }", "            break",
     ["[sigterm grace]", "[sigterm is enough]"], "escalation"),
    ("unknown waits nothing", H, "            if elapsed() >= timings.unknown { return .gaveUp(\"quitTimeout\") }", "            return .gaveUp(\"quitTimeout\")",
     ["[unknown waits the minute]"], "escalation"),
    ("no linger", H, "        while bundleHasRunningProcess(live), Date() < lingerUntil { Thread.sleep(forTimeInterval: 0.2) }\n", "",
     ["[recording reason]", "[linger installs]"], "escalation"),
    ("forcedQuit not recorded", H, '            "forcedQuit": forced != nil,\n        ]\n        if let forced {',
     '            "forcedQuit": false,\n        ]\n        if let forced {', ["[success records forced quit]"], "escalation"),
    ("staged verb skips its checks", H, "            try checkStagedControlApp(staged, version: version, build: build)\n        } catch {\n            details[\"message\"]",
     "        } catch {\n            details[\"message\"]", ["[staged verb verifies]"], "escalation"),
    ("staged verb any failure", H, '        guard let failureReason, ["quitTimeout", "recording"].contains(failureReason), let failureAt,',
     "        guard let failureReason, let failureAt,", ["[staged verb]"], "escalation"),
    ("staged verb no window", H, "              abs(Date().timeIntervalSince(failureAt)) <= window,\n", "", ["[staged verb]"], "escalation"),
    ("staged verb not newer", H, '        guard build > currentBuild else { return answer("notNewer"', '        guard build >= 0 else { return answer("notNewer"',
     ["[staged verb]"], "escalation"),
    ("staged verb ignores success", H, "              successDate.map({ $0 < failureAt }) ?? true else {", "              true else {", ["[staged verb]"], "escalation"),
    # The signal re-check and the production timings (helper self-test).
    ("signal without re-check", H, """        guard case let .running(path, started) = Self.processIdentity(process.pid), started == process.started,
              Self.sameFile(path, as: target) else { return false }
        return Darwin.kill""", "        return Darwin.kill", ["a PID with another start time"], "selftest"),
    ("signal ignores the start time", H, "Self.processIdentity(process.pid), started == process.started,\n", "Self.processIdentity(process.pid),\n",
     ["a PID with another start time"], "selftest"),
    ("signal ignores the executable", H, "              Self.sameFile(path, as: target) else { return false }\n        return Darwin.kill",
     "              true else { return false }\n        return Darwin.kill", ["a process running another executable"], "selftest"),
    ("production quit grace 60 s", H, "        var quit: TimeInterval = 20\n", "        var quit: TimeInterval = 60\n", ["app update quit timings"], "selftest"),
    ("test timings in production", H, '        guard let home = environment["COS_CONTROL_TEST_HOME"], home.hasPrefix("/tmp/"),\n              let raw = environment["COS_CONTROL_TEST_QUIT_TIMINGS"]',
     '        guard let raw = environment["COS_CONTROL_TEST_QUIT_TIMINGS"]', ["app update quit timings"], "selftest"),
    ("unknown phase is safe", H, '        return (macCaptureQuietPhases.contains(phase) ? "safe" : "unknown", phase)', '        return ("safe", phase)',
     ["a phase this build does not know"], "selftest"),
    # The pure app pieces (Models.swift).
    ("finish offer any reason", M, "              let reason = details[\"failureReason\"]?.string, AppUpdateFailureRecord.endsApply.contains(reason),",
     "              let reason = details[\"failureReason\"]?.string, !reason.isEmpty,", ["[finish offer reasons]"], "checks"),
    ("finish offer no window", M, "        guard age <= window, age >= -skew else { return nil }", "        guard age >= -skew else { return nil }",
     ["[finish offer window]"], "checks"),
    ("finish offer no skew bound", M, "        guard age <= window, age >= -skew else { return nil }", "        guard age <= window else { return nil }",
     ["[finish offer window]"], "checks"),
    ("finish offer ignores success", M, "        if let success = details[\"successAt\"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }), success >= at { return nil }\n", "",
     ["[finish offer success]"], "checks"),
    ("finish offer same build", M, "              let raw = details[\"build\"]?.int, raw > currentBuild,", "              let raw = details[\"build\"]?.int, raw >= currentBuild,",
     ["[finish offer newer]"], "checks"),
    ("finish offer unverified", M, "        guard details[\"reason\"]?.string == \"staged\", let version", "        guard details[\"reason\"]?.string != nil, let version",
     ["[finish offer verified]"], "checks"),
    ("unreachable drops the staged offer", M, "                if info.reason == \"unreachable\" || info.reason == \"malformed\" { return }\n", "", ["[finish flow]"], "checks"),
    ("the same build drops the staged offer", M, "                if available, let offered = info.latestBuild, offered == build { return }\n", "", ["[finish flow]"], "checks"),
    ("a newer build keeps the staged offer", M, "                finishesStaged = false\n            }\n            phase = available ? .ready : .none",
     "            }\n            phase = available ? .ready : .none", ["[finish flow]"], "checks"),
    ("restored failure replaces the offer", M, "        guard phase == .ready, !finishesStaged else { return }", "        guard phase == .ready else { return }", ["[finish flow]"], "checks"),
    ("finish without a stage", M, "        guard phase == .ready, finishesStaged else { return false }", "        guard phase == .ready else { return false }",
     ["[finish flow]"], "checks"),
    ("finish offer any version", M, "        guard build > currentBuild, AppUpdateVersion.components(version) != nil else { return }", "        guard build > currentBuild else { return }",
     ["[finish flow]"], "checks"),
    ("full install keeps the offer", M, "            downloadFirstAt = nil; downloadFirstBytes = 0; applyingStartedAt = nil; quitWaitingOn = nil\n            finishesStaged = false\n",
     "            downloadFirstAt = nil; downloadFirstBytes = 0; applyingStartedAt = nil; quitWaitingOn = nil\n", ["[finish flow]"], "checks"),
    ("footer has no Finish installing", M, "        case .ready where finishesStaged:\n            self.init(primary: .finish,", "        case .none where finishesStaged:\n            self.init(primary: .finish,",
     ["[finish words]"], "checks"),
    ("presentation drops the staged offer", M, ",\n                                                           finishesStaged: flow.finishesStaged))", "))", ["[finish words]"], "checks"),
    ("old installing words", M, '    static let installingWords = "Closing COS Control\\u{2026}"', '    static let installingWords = "Installing. COS Control closes and reopens, usually within a minute."',
     ["[applying words]"], "checks"),
    ("banner applying words", M, "            detail = flow.applyingWords\n", "            detail = \"\\(flow.versionLine). Control quits and reopens by itself. The glasses server keeps running.\"\n",
     ["[applying words]"], "checks"),
    ("recording words missing", M, "        case \"recording\":\n            return AppUpdateFailureRecord.recordingWords\n", "", ["[failure record recording]"], "checks"),
    # The shared set feeds both the early end and the launch offer, so either check may name it ...
    ("busy ends the install", M, '    static let endsApply: Set<String> = ["quitTimeout", "recording"]', '    static let endsApply: Set<String> = ["quitTimeout", "recording", "busy"]',
     ["[ends apply]", "[finish offer reasons]"], "checks"),
    # ... and the per-record predicate alone (the offer reads the set, not this) proves the early-end check by itself.
    ("busy record ends the install", M, "    var endsApply: Bool { Self.endsApply.contains(reason) }", '    var endsApply: Bool { Self.endsApply.contains(reason) || reason == "busy" }',
     ["[ends apply]"], "checks"),
    ("busy record ends the running install", M, "    var endsApply: Bool { Self.endsApply.contains(reason) }", '    var endsApply: Bool { Self.endsApply.contains(reason) || reason == "busy" }',
     ["[busy keeps waiting]"], "wiring"),
    # The state file (MacRecordingCore.swift).
    ("capture state class B", RC, "        try encode(phase: phase, pid: pid, at: date).write(to: url, options: .atomic)",
     "        try encode(phase: phase, pid: pid, at: date).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])", ["never class A or B"], "macrec"),
    ("capture state world readable", RC, "        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)\n", "", ["owner only"], "macrec"),
    ("capture state any test home", RC, '        if let test = environment["COS_CONTROL_TEST_HOME"], test.hasPrefix("/tmp/") {', '        if let test = environment["COS_CONTROL_TEST_HOME"] {',
     ["a home outside /tmp/ is ignored"], "macrec"),
    # The app, compiled whole (run-app-update-finish.sh wiring).
    ("the watch ignores the swap's record", C, "                if record?.endsApply == true || self.appUpdateFlow.applyOverdue() {", "                if self.appUpdateFlow.applyOverdue() {",
     ["[recording ends at once]"], "wiring"),
    ("What's New's finish downloads", C, "        if appUpdateFlow.finishesStaged { finishStagedAppUpdate(); return }\n", "", ["[finish one click]"], "wiring"),
    ("finish forgets the build", C, "        if let stagedBuild { apply += [\"--expected-build\", String(stagedBuild)] }\n", "", ["[finish one click]"], "wiring"),
    ("phase changes not recorded", R, "            if oldValue != phase { phaseRecorder?(phase) }\n", "", ["[phase recorder]"], "wiring"),
    ("launch phase not written", C, "        macRecording.phaseRecorder = write\n        write(macRecording.phase)\n", "        macRecording.phaseRecorder = write\n",
     ["[capture state]"], "wiring"),
    ("launch offer ignores the rule", C, "        ], timeout: 90), let offer = AppUpdateFinishOffer.offer(response.details, currentBuild: Self.currentBuild) else { return }",
     "        ], timeout: 90), let offer = Optional((version: response.details[\"version\"]?.string ?? \"\", build: response.details[\"build\"]?.int ?? 0)) else { return }",
     ["[launch offer rule]"], "wiring"),
    # Wiring nothing can click (pins).
    ("launch never writes capture state", C, "        recordMacCaptureState(to: MacCaptureStateFile.url())\n", "", ["[launch writes capture state]"], "pins"),
    ("launch never asks for a staged build", C, "            await self?.checkStagedAppUpdate()\n", "", ["[launch offer order]"], "pins"),
    ("banner opens What's New on a staged offer", V, "                if model.appUpdateFlow.finishesStaged { model.finishStagedAppUpdate() } else { model.presentWhatsNew() }",
     "                model.presentWhatsNew()", ["[banner finishes in one click]"], "pins"),
    ("forced quit before the blockers", H, "        let blockers = appUpdateWorkBlockers()\n        if !blockers.isEmpty {\n            try writeAppUpdateJSON(updatesFailureURL, [\n                \"reason\": \"busy\",",
     "        let blockers: [String] = []\n        if !blockers.isEmpty {\n            try writeAppUpdateJSON(updatesFailureURL, [\n                \"reason\": \"busy\",", ["[swap order]"], "pins"),
]

SWIFTC = ["swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete"]


def guarded(cmd, timeout=3600, env=None):
    """Runs a guarded compile (or a script that compiles), waiting out a busy lock (exit 75) without counting it."""
    for _ in range(90):
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        out = p.stdout + p.stderr
        if p.returncode != 75 and "lock busy" not in out:
            return p.returncode, out
        time.sleep(30)
    return 75, "the compile lock stayed busy"


def run(lane, copy, scratch):
    env = dict(os.environ, COS_COMPILE_PROFILE="bounded")
    guard = ["/bin/zsh", str(copy / "Tests/compile-guard.sh")]
    if lane in ("escalation", "selftest"):
        helper = scratch / "cos-control-helper"
        helper.unlink(missing_ok=True)
        code, out = guarded(guard + SWIFTC + [str(copy / H), str(copy / "HelperSources/ProviderStatusCore.swift"), str(copy / "HelperSources/PairingCore.swift"),
                                              str(copy / "Sources/WorkSessionLinks.swift"), "-framework", "Security", "-framework", "AppKit", "-o", str(helper)], env=env)
        if code != 0:
            return code, out
        if lane == "selftest":
            home = pathlib.Path(tempfile.mkdtemp(prefix="cos-mut-selftest-", dir="/tmp"))
            try:
                p = subprocess.run([str(helper), "self-test"], capture_output=True, text=True, timeout=600, env=dict(os.environ, COS_CONTROL_TEST_HOME=str(home)))
            finally:
                shutil.rmtree(home, ignore_errors=True)
            try:
                value = json.loads(p.stdout.strip().split("\n")[-1])
                return (0 if value.get("ok") else 1), value.get("message", "")
            except (ValueError, IndexError):
                return 1, p.stdout + p.stderr
        live = scratch / "live-app"
        if not live.exists():
            subprocess.run(["/usr/bin/cc", "-O1", "-o", str(live), str(copy / "Tests/fixtures/app-update/live-app.c")], check=True)
        p = subprocess.run(["/usr/bin/python3", str(copy / "Tests/app-update-escalation-checks.py"), str(helper), str(live)],
                           capture_output=True, text=True, timeout=900)
        return p.returncode, p.stdout + p.stderr
    if lane in ("checks", "macrec"):
        out_dir = pathlib.Path(tempfile.mkdtemp(prefix="cos-mut-escalate-", dir="/tmp"))
        try:
            if lane == "checks":
                files, frameworks = [str(copy / M), str(copy / "Tests/AppUpdateBadgeChecks.swift")], ["-framework", "AppKit"]
            else:
                files, frameworks = [str(copy / RC), str(copy / "Tests/MacRecordingChecks.swift")], []
            code, out = guarded(guard + SWIFTC + ["-parse-as-library", *files, *frameworks, "-o", str(out_dir / "checks")], env=env)
            if code != 0:
                return code, out
            home = out_dir / "home"
            home.mkdir()
            try:
                q = subprocess.run([str(out_dir / "checks")], capture_output=True, text=True, timeout=300,
                                   env={"HOME": str(home), "CFFIXED_USER_HOME": str(home), "PATH": "/usr/bin:/bin"})
                return q.returncode, q.stdout + q.stderr
            except subprocess.TimeoutExpired:
                return 124, "the checks did not finish"
        finally:
            shutil.rmtree(out_dir, ignore_errors=True)
    if lane == "wiring":
        return guarded(["/bin/zsh", str(copy / "Tests/run-app-update-finish.sh"), str(scratch / "baseline-helper")],
                       env=dict(env, COS_APP_UPDATE_FINISH_LANE="wiring"))
    p = subprocess.run(["/usr/bin/python3", str(copy / "Tests/app-update-finish-pins.py"), str(copy)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    scratch.mkdir(parents=True, exist_ok=True)
    copy = scratch / "copy"
    os.environ.setdefault("COS_TEST_KIT_DIR", str(scratch / "kits"))
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "dist", "*.zip"))
    chosen = [m for m in MUTANTS if not only or m[0] in only]
    lanes = sorted({m[5] for m in chosen}, key=["pins", "checks", "macrec", "selftest", "escalation", "wiring"].index)
    for lane in lanes:
        code, out = run(lane, copy, scratch)
        if code != 0:
            sys.exit(f"baseline {lane} lane is RED; no mutant can be judged:\n{out[-3000:]}")
        last = out.strip().splitlines()[-1] if out.strip() else ""
        print(f"baseline {lane}: green ({last[:160]})", flush=True)
        if lane in ("escalation", "selftest") and not (scratch / "baseline-helper").exists():
            shutil.copy2(scratch / "cos-control-helper", scratch / "baseline-helper")
    if "wiring" in lanes and not (scratch / "baseline-helper").exists():
        code, out = run("selftest", copy, scratch)
        if code != 0:
            sys.exit(f"baseline helper for the wiring lane is RED:\n{out[-2000:]}")
        shutil.copy2(scratch / "cos-control-helper", scratch / "baseline-helper")
    survived, results = [], []
    for name, rel, original, mutant, words, lane in chosen:
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        hits = text.count(original)
        if hits != 1:
            results.append(f"MISSED TARGET ({hits}x) {name}")
            survived.append(name)
            print(results[-1], flush=True)
            continue
        path.write_text(text.replace(original, mutant), encoding="utf-8")
        started = time.time()
        try:
            code, out = run(lane, copy, scratch)
        finally:
            path.write_text(text, encoding="utf-8")
        took = time.time() - started
        line = next((l for l in out.splitlines() if "failed [" in l or "failed:" in l or any(w in l for w in words)), "")
        if code == 137:
            sys.exit(f"compile guard stopped the run at mutant {name}; stopping the lane")
        if code == 75:
            results.append(f"INFRASTRUCTURE (lock) {name}")
            survived.append(name)
        elif code == 0:
            results.append(f"SURVIVED {name}")
            survived.append(name)
        elif any(w in out for w in words):
            results.append(f"killed  {name}  [{lane}] ({took:.0f}s) {line.strip()[:150]}")
        elif "error:" in out:
            results.append(f"WEAK (compile error) {name}: {next((l for l in out.splitlines() if 'error:' in l), '')[:160]}")
            survived.append(name)
        else:
            results.append(f"WEAK (another check) {name}: {line.strip()[:160] or (out.strip().splitlines()[-1][:160] if out.strip() else '')}")
            survived.append(name)
        print(results[-1], flush=True)
    print(f"{len(results) - len(survived)} of {len(results)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
