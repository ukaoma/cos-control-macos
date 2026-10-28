#!/usr/bin/env python3
"""Ask COS setup assistant mutation lane. Run by hand, never by a gate.

    python3 Tests/mutate-setup-assistant.py <worktree> <scratch dir> [name ...]

Copies the worktree to <scratch dir>/copy, proves the UNMUTATED lane green first (Tests/run-setup-assistant.sh: the pins,
then the compiled checks), then applies one mutant at a time: the target must appear exactly once, the mutant must make
the lane fail, and the failure must name the behaviour it breaks. The copy is restored and compared byte for byte after
every mutant. A mutant that lands and survives is a finding. One lane run at a time; every compile goes through the guard,
and a run that hangs is killed after LIMIT seconds (Tests/mutate_bounded.py) and counted as a kill by timeout.
"""
import filecmp, pathlib, shutil, sys, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mutate_bounded as bounded

LIMIT = 900
C = "Sources/SetupAssistant.swift"
R = "scripts/build-release.sh"
S = "Tests/run.sh"
MUTANTS = [
    # Gates
    ("gate: a change that does not apply is offered", C, "        guard applies(action, s) else { return .notApplicable }\n", "", "[unverified ownership]"),
    ("gate: busy ignored", C, "        if s.helperBusy, action.helperCommand != nil || action == .retryAppUpdate { return .held(Held.busy) }\n", "", "[busy]"),
    ("gate: an ownership conflict ignored", C, "        if action.touchesServer, s.ownerConflict { return .held(Held.ownerConflict) }\n", "", "[ownership conflict offers nothing]"),
    ("gate: a G2 recording ignored", C, "if s.activeTranscriptionSessions > 0 || s.macRecordingActive { return .held(Held.recording) }",
     "if s.macRecordingActive { return .held(Held.recording) }", "[no restart while a recording runs]"),
    ("gate: a Mac recording ignored", C, "if s.activeTranscriptionSessions > 0 || s.macRecordingActive { return .held(Held.recording) }",
     "if s.activeTranscriptionSessions > 0 { return .held(Held.recording) }", "[a Mac recording holds]"),
    ("gate: a meeting still saving ignored", C, "            if s.meetingWorkBlockingRestart { return .held(Held.saving) }\n", "", "[a meeting still saving holds]"),
    ("gate: running jobs ignored", C, "            if s.activeJobs > 0 { return .held(Held.jobs(s.activeJobs)) }\n", "", "[no restart while a job runs]"),
    ("gate: Restart ignores an interrupted update", C, "        case .restartServer:\n            if s.transactionPending { return .held(Held.interruptedUpdate) }\n",
     "        case .restartServer:\n", "[interrupted update]"),
    ("gate: Update Server ignores an interrupted update", C,
     "            // install() refuses while a transaction is pending (\"A previous update needs repair before another install\").\n            if s.transactionPending { return .held(Held.interruptedUpdate) }\n",
     "            break\n", "[interrupted update]"),
    ("gate: an in-place restart with one tap", C, '            if s.runtimeState == "managedInPlace", !s.safeToRestart { return .held(Held.unprovenIdle) }\n', "", "[in-place restart asks first]"),
    ("gate: the app update twice", C, "            if s.appUpdate.installing { return .held(Held.installing) }\n", "", "[installing]"),
    ("gate: the app update closes a recording", C, "            if s.macRecordingActive || s.activeTranscriptionSessions > 0 { return .held(Held.recording) }\n", "", "[the update waits for a recording]"),
    ("gate: Repair Whisper is not a restart", C, "            case .restartServer, .repairRuntime, .repairWhisper, .updateServer: return true",
     "            case .restartServer, .repairRuntime, .updateServer: return true", "[no restart while a job runs]"),
    # What applies
    ("applies: setup without an AI app", C, "            return s.needsFirstRun && s.setupProviderInstalled\n", "            return s.needsFirstRun\n", "[first run]"),
    ("applies: Start for a running server", C, '            return s.runtimeState == "stopped"\n', "            return true\n", "[server down: local repairs]"),
    ("applies: Restart for a stopped server", C, '            return s.runtimeState == "managedHealthy" || s.runtimeState == "managedInPlace"\n', "            return true\n",
     "[server down: local repairs]"),
    ("applies: Repair against a Terminal server", C, '            guard s.installed, s.runtimeState != "legacyForeground" else { return false }\n',
     "            guard s.installed else { return false }\n", "[repair only when it fixes something]"),
    ("applies: Repair whenever installed", C, "            return s.transactionPending || failing(CheckName.updateRecovery, s) || failing(CheckName.recovery, s)\n",
     "            return true || failing(CheckName.recovery, s)\n", "[repair only when it fixes something]"),
    ("applies: Repair Whisper while Whisper is fine", C,
     "            return s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)\n",
     "            return s.serverReachable && s.managedContract && s.ownershipVerified\n", "[answers offer only what applies]"),
    ("applies: Repair Whisper on an unverified server", C,
     "            return s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)\n",
     "            return s.serverReachable && (!s.whisperReady || s.whisperCircuitOpen)\n", "[unverified ownership]"),
    ("applies: Update Server on an unverified server", C, "            return s.installed && s.managedContract && s.ownershipVerified\n",
     "            return s.installed\n", "[unverified ownership]"),
    ("applies: troubleshoot with the server down", C, "            return s.serverReachable && s.workRunsOn\n", "            return s.workRunsOn\n", "[troubleshoot needs the server]"),
    ("applies: troubleshoot with Work runs off", C, "            return s.serverReachable && s.workRunsOn\n", "            return s.serverReachable\n", "[troubleshoot needs Work runs]"),
    ("applies: an app update with none offered", C, "            return s.appUpdate.available || s.appUpdate.downloadFailed\n", "            return true\n", "[installing]"),
    # The board
    ("board: the conflict offers more", C, "        if s.ownerConflict {\n            let only", "        if false {\n            let only", "[ownership conflict offers nothing]"),
    ("board: a server row on first run", C, "        if !s.serverReachable && !s.needsFirstRun {\n", "        if !s.serverReachable {\n", "[first run]"),
    ("board: a stopped server is repaired", C, '"It is not running, so Work, meetings and the glasses cannot reach it.", .startServer)',
     '"It is not running, so Work, meetings and the glasses cannot reach it.", .repairRuntime)', "[ranking]"),
    ("board: a Terminal server is updated", C, '"Finish active work, then stop it in Terminal with Control-C. COS Control can then run the server for you.", nil)',
     '"Finish active work, then stop it in Terminal with Control-C. COS Control can then run the server for you.", .updateServer)', "[server down: local repairs]"),
    ("board: a running self-managed server is not offered", C, '        if s.runtimeState == "legacyService" {\n', "        if false {\n", "[a server you run yourself]"),
    ("board: a stopped self-managed server is not offered", C, 'Adopt Safely in Settings installs the managed server.", .openSettings)', 'Adopt Safely in Settings installs the managed server.", nil)', "[a server you run yourself]"),
    ("board: a degraded server is not repaired", C, "                if s.installed {\n", "                if false {\n", "[interrupted update]"),
    ("board: a failed download offered twice", C, "        if s.appUpdate.available && !s.appUpdate.downloadFailed && !s.appUpdate.installing {\n",
     "        if s.appUpdate.available && !s.appUpdate.installing {\n", "[the anchor case]"),
    ("board: no Try again beside the steps", C, "                .openUnstuck, secondary: .retryAppUpdate)\n", "                .openUnstuck)\n", "[the anchor case]"),
    ("board: the second button skips its gate", C, "            if let secondary, gate(secondary, s) == .ready { item.secondary = secondary }\n",
     "            if let secondary { item.secondary = secondary }\n", "[the update waits for a recording]"),
    ("board: a held change still offered", C, "                case .held(let reason): item.held = reason\n",
     "                case .held(let reason): item.held = reason; item.action = action\n", "[no restart while a job runs]"),
    ("board: a held change says nothing", C, "                case .held(let reason): item.held = reason\n", "                case .held: break\n", "[no restart while a job runs]"),
    ("board: Whisper only from Doctor", C,
     "        if (s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)) || failing(CheckName.whisperServer, s) {\n",
     "        if failing(CheckName.whisperServer, s) {\n", "[whisper]"),
    ("board: an interrupted update is not first", C, '        add("interrupted-update", .repair, 10,', '        add("interrupted-update", .repair, 99,', "[interrupted update]"),
    ("board: the microphone with dictation off", C, "        if s.dictationEnabled && s.microphoneAllowed == false {\n", "        if s.microphoneAllowed == false {\n", "[dictation permissions]"),
    ("board: an unread microphone is a problem", C, "        if s.dictationEnabled && s.microphoneAllowed == false {\n", "        if s.dictationEnabled && s.microphoneAllowed != true {\n",
     "[dictation permissions]"),
    ("board: unread Accessibility is a problem", C, "        if s.dictationEnabled && s.accessibilityTrusted == false {\n", "        if s.dictationEnabled && s.accessibilityTrusted != true {\n",
     "[dictation permissions]"),
    ("board: integrity offers Repair", C, '"Doctor says the installed server failed its integrity check. Update Server installs a fresh, verified copy.", .updateServer)',
     '"Doctor says the installed server failed its integrity check. Update Server installs a fresh, verified copy.", .repairRuntime)', "[doctor rows]"),
    ("board: done rows offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.skipped && !item.afterSetup && !item.awaitsServer {", "[all clear]"),
    ("board: skipped rows offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.done && !item.afterSetup && !item.awaitsServer {", "[setup rows]"),
    ("board: rows before setup offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.done && !item.skipped && !item.awaitsServer {", "[setup rows]"),
    ("board: rows still checking offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.done && !item.skipped && !item.afterSetup {", "[setup rows]"),
    ("board: optional rows counted as setup", C, "item.counted ? .setup : .extra", ".setup", "[all clear]"),
    ("board: a checkup after Doctor", C, "        if s.checks.isEmpty && !s.needsFirstRun {\n", "        if !s.needsFirstRun {\n", "[all clear]"),
    ("board: a checkup on first run", C, "        if s.checks.isEmpty && !s.needsFirstRun {\n", "        if s.checks.isEmpty {\n", "[first run]"),
    ("board: five shown", C, "    static let shown = 4\n", "    static let shown = 5\n", "[ranking]"),
    ("board: more never counted", C, "more: max(0, ranked.count - shown))", "more: 0)", "[at most four]"),
    ("board: an extra breaks all clear", C, "        let clear = !ranked.contains { $0.tier != .extra }\n", "        let clear = ranked.isEmpty\n", "[checkup offered before Doctor]"),
    ("board: ranked backwards", C, "found.sorted { ($0.tier, $0.rank) < ($1.tier, $1.rank) }", "found.sorted { ($0.tier, $0.rank) > ($1.tier, $1.rank) }", "[ranking]"),
    # The knowledge base
    ("match: phrases ignored", C, "            if entry.phrases.contains(where: has) {\n", "            if false {\n", "[the anchor case]"),
    # Killed first by the server-down answer: "server not connected" is taken for the glasses entry.
    ("match: one group is enough", C, "entry.groups.allSatisfy({ $0.contains(where: has) })", "entry.groups.contains(where: { $0.contains(where: has) })", "[server down: local repairs]"),
    ("match: phrases of whisper ignored", C, 'phrases: ["restart whisper", "repair whisper"],', "phrases: [],", "[knowledge base: whisper-stalled]"),
    ("answer: Restart offered for a stopped server", C, "              actions: [.restartServer],\n", "              actions: [.restartServer, .startServer],\n", "[answers offer only what applies]"),
    ("match: the first entry wins", C, "            if score > (best?.score ?? 0) { best = (entry, score) }\n", "            if best == nil { best = (entry, score) }\n", "[knowledge base"),
    ("match: boosts ignored", C, "            score += entry.boosts.filter(has).count\n", "", "[knowledge base"),
    ("match: part of a word matches", C, "        func has(_ term: String) -> Bool { words.contains(normalized(term)) }\n",
     "        func has(_ term: String) -> Bool { words.contains(term) }\n", "[knowledge base"),
    ("match: apostrophes kept", C, "            if scalar == \"'\" || scalar == \"\\u{2019}\" { continue }\n", "", "[knowledge base"),
    ("match: the whole question read", C, "        let words = normalized(String(text.prefix(maxQuestion)))\n", "        let words = normalized(text)\n", "[knowledge base reads a bounded question]"),
    ("answer: three offers", C, "        for action in entry.actions where offers.count < 2 {\n", "        for action in entry.actions where offers.count < 3 {\n", "[an answer offers two at most]"),
    ("answer: a change that does not apply is offered", C, "            case .notApplicable: continue\n",
     "            case .notApplicable: offers.append(Offer(action: action, title: action.title, held: nil))\n", "[ownership conflict offers nothing]"),
    ("answer: a held change offered as ready", C, "            case .held(let reason): offers.append(Offer(action: action, title: action.title, held: reason))\n",
     "            case .held: offers.append(Offer(action: action, title: action.title, held: nil))\n", "[ownership conflict offers nothing]"),
    ("answer: the hold not named", C, '        if entry.namesRestartHold, case .held(let reason) = gate(.restartServer, s) { text += " Right now: " + reason }\n', "",
     "[the greyed-out answer names the hold]"),
    # Confirmations
    ("confirm: Repair Whisper hides the restart", C, '"This restarts the whole COS server, then waits for Whisper to answer."', '"COS restarts local Whisper."',
     "[Repair Whisper says it restarts the server]"),
    ("confirm: Reset and add again is not a change", C, "                 .retryAppUpdate, .resetAccessibility, .troubleshoot: return true", "                 .retryAppUpdate, .troubleshoot: return true",
     "[every change confirms]"),
    ("confirm: a pending update reads as a plain repair", C, "            if s.transactionPending {\n                return Confirmation(question: \"Finish the interrupted server update?\",",
     "            if false {\n                return Confirmation(question: \"Finish the interrupted server update?\",", "[repair says what it does]"),
    ("confirm: a stopped server is restarted", C, "            if s.desiredState == \"stopped\" {\n", "            if false {\n", "[repair says what it does]"),
    ("confirm: the cap misquoted", C, "    static let dailyRuns = 20\n", "    static let dailyRuns = 25\n", "dailyRuns equals"),
    # Troubleshoot
    ("troubleshoot: no gate", C, "        guard gate(.troubleshoot, s) == .ready else { return nil }\n", "", "[troubleshoot needs the server]"),
    ("troubleshoot: no ask-first rule", C, "        - Ask before you run anything that changes this Mac: installs, restarts, deleting files, System Settings.\n", "", "[troubleshoot asks first]"),
    ("troubleshoot: the packet not redacted", C, "report.map { scrubbed(String($0.prefix(maxPacket))) }", "report.map { String($0.prefix(maxPacket)) }", "[troubleshoot redacts]"),
    ("troubleshoot: the packet unbounded", C, "report.map { scrubbed(String($0.prefix(maxPacket))) }", "report.map { scrubbed($0) }", "[troubleshoot is bounded]"),
    ("troubleshoot: the question unbounded", C, "        let words = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestion))\n",
     "        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)\n", "[troubleshoot is bounded]"),
    ("troubleshoot: outside Today's in-flight check", C, '    static let targetPrefix = "today:troubleshoot:"\n', '    static let targetPrefix = "setup:troubleshoot:"\n', "[troubleshoot prompt]"),
    # Copy
    ("copy: an em dash in a held line", C, '"A meeting is still saving. This comes back when it is done."', '"A meeting is still saving \u2014 this comes back when it is done."', "[copy rules]"),
    ("copy: a hedge word in an answer", C, '"Repair Whisper restarts the COS server and local Whisper together,', '"Repair Whisper might restart the COS server and local Whisper together,', "[copy rules]"),
    # Pins (the files the compiled checks cannot see)
    ("pins: the release build leaves the file out", R, ' "$ROOT/Sources/SetupAssistant.swift" \\\n', " \\\n", "leaves out SetupAssistant.swift"),
    ("pins: an action names a missing command", C, '            case .repairWhisper: return "restart-whisper"\n', '            case .repairWhisper: return "repair-whisper"\n', "command switch has a case"),
    ("pins: a Doctor row renamed", C, '        static let recovery = "Recovery controller"\n', '        static let recovery = "Recovery agent"\n', "doctorDetails writes"),
    ("pins: the engine opens a link", C, "    static let maxPacket = 12_000\n", '    static let maxPacket = 12_000\n    static let site = URL(string: "https://www.gotcos.com")\n', "never uses URL("),
    ("pins: the suite skips the lane", S, 'zsh "$ROOT/Tests/run-setup-assistant.sh"\n', "", "runs the setup assistant lane once"),
]


def suite(copy):
    started = time.time()
    result = bounded.run(["zsh", "Tests/run-setup-assistant.sh"], LIMIT, cwd=copy)
    out = result.stdout + result.stderr
    if "compile-guard: STOPPED" in out:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + out[-400:])
    return result.returncode, out, time.time() - started, result.timed_out


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "HelperSources", "scripts"):
        shutil.copytree(src / part, copy / part)
    code, out, seconds, _ = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS: setup assistant")]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(passed) or '(no PASS line)'}", flush=True)
    if code != 0 or len(passed) != 2:
        print(out[-3000:])
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed = survived = 0
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out, seconds, timed_out = suite(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        if not filecmp.cmp(path, src / rel, shallow=False):
            sys.exit(f"RESTORE FAILED for {name}: {rel} differs from the worktree")
        lines = [l for l in out.splitlines() if "check failed [" in l or "Setup assistant pin:" in l or ": error:" in l]
        reason = lines[0].strip() if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if timed_out:
            killed += 1; print(f"killed  {name}: TIMEOUT after {LIMIT} s (no named check)", flush=True)
        elif code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:220]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:260]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 else 1)


if __name__ == "__main__":
    main()
