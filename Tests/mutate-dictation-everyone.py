#!/usr/bin/env python3
"""Mutation lane for 0.5.317 dictation for everyone. Run by hand, never by a gate. SERIAL: one mutant at a time, every
Swift compile through Tests/compile-guard.sh (two kernel panics on 2026-10-07 came from parallel compiles).

    python3 Tests/mutate-dictation-everyone.py <worktree> <scratch dir> [name ...]

Copies the worktree once to <scratch dir>/copy, proves each UNMUTATED lane green first (a red baseline makes every
mutant look killed), then applies one mutant at a time: the target must appear exactly once, the mutant must make a
check fail, and the failure must name the behaviour the mutant breaks. A mutant that lands and survives is a finding.

Lanes: core (ProviderStatusCore + DictationEveryoneChecks), store (run-transcription-settings.sh), connect
(ProviderConnectModel + ProviderConnectChecks), dictation (MacDictationCore + MacDictationChecks), pins
(dictation-everyone-pins.py, no compile), release (the CLI and entitlements self-tests, no Swift), helper (the full
helper, then the three helper check scripts; one large compile per mutant, so few mutants use it).
"""
import os, pathlib, shutil, subprocess, sys, tempfile

PSC = "HelperSources/ProviderStatusCore.swift"
H = "HelperSources/main.swift"
CORE = "Sources/MeetingAskCore.swift"
CONNECT = "Sources/ProviderConnectModel.swift"
MDC = "Sources/MacDictationCore.swift"
MD = "Sources/MacDictation.swift"
APP = "Sources/COSControlApp.swift"
REL = "scripts/build-release.sh"
ENT = "Tests/check-release-entitlements.py"
FA = "Tests/check-fluidaudio-cli.py"

MUTANTS = [
    # The compatibility gate and the answers (helper core).
    ("gate never local", PSC, "        return versions.contains { ($0 as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.intValue == 2 } ?? false }",
     "        return false", "gate local", "core"),
    ("gate takes a boolean", PSC, "($0 as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.intValue == 2 }",
     "($0 as? NSNumber).map { $0.intValue == 2 || $0.boolValue }", "gate strict", "core"),
    ("gate drops version 1", PSC, '        guard let capabilities, capabilities["desktopDictationVersion"] as? Int == 1,\n              capabilities["localOnly"] as? Bool == true else { return nil }',
     '        guard let capabilities, capabilities["localOnly"] as? Bool == true else { return nil }', "gate refuses", "core"),
    ("local accepts any engine", PSC, '            if local, let engine = id(body["engine"], engines) {', '            if local, let engine = body["engine"] as? String {', "local refuses other engines", "core"),
    ("old route accepts whisper", PSC, '            if !local, body["engine"] as? String == "parakeet-ultra" {', '            if !local {', "old refuses whisper", "core"),
    ("a dead retry is offered", PSC, '            let action = asked == "retry" && !retryable ? "open_transcription_settings" : asked', '            let action = asked', "never a dead retry", "core"),
    ("retryable ignores the server", PSC, '            let retryable = asked == "retry" && (body["retryable"] as? Bool) == true', '            let retryable = asked == "retry"', "never a dead retry", "core"),
    ("any action crosses", PSC, '            let asked = raw == "retry_when_warm" ? "retry" : id(raw, actions) ?? "open_transcription_settings"',
     '            let asked = raw == "retry_when_warm" ? "retry" : raw ?? "open_transcription_settings"', "action whitelist", "core"),
    ("multi-line server text", PSC, '              text.count <= 200, !text.contains("\\n") else { return nil }', '              true else { return nil }', "one-line sentences only", "core"),
    ("a 4xx retries", PSC, "        let passing = status == 409 || status == 503 || status == 429 || status >= 500", "        let passing = true", "4xx never retries", "core"),
    ("WER is case sensitive", PSC, "        let lowered = text.lowercased()", "        let lowered = text", "wer words", "core"),
    ("WER double-counts substitutions", PSC, "previous[j] + (word == heard ? 0 : 1))", "previous[j] + (word == heard ? 0 : 2))", "wer distance", "core"),
    ("benchmark keeps any engine", PSC, '            guard let row = raw as? [String: Any], let engine = DictationBridge.id(row["engine"], DictationBridge.engines) else { return nil }',
     '            guard let row = raw as? [String: Any], let engine = row["engine"] as? String else { return nil }', "benchmark whitelist", "core"),
    ("tool path anywhere", PSC, "        guard path.hasPrefix(\"/\"), path.hasSuffix(suffix), path.utf8.count <= 1024,", "        guard path.hasPrefix(\"/\"), path.utf8.count <= 1024,", "cli path", "core"),
    ("tool path with dot segments", PSC, '              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return false }',
     '              true else { return false }', "cli path", "core"),
    # The store and the Parakeet row.
    ("no disk precheck", CORE, "        if let free = freeBytes(), free < Transcription.requiredFreeBytes { error = Transcription.diskLine(free: free); return }\n", "",
     "too little disk: refused before any request", "store"),
    ("row ignores the disk", CORE, "        if let freeBytes, freeBytes < requiredFreeBytes { return .blocked(reason: diskLine(free: freeBytes), action: .checkAgain) }\n", "",
     "under 1.5 GB free", "store"),
    ("uninstallable row offers Install", CORE, "        if !parakeet.installable {\n", "        if false {\n", "an untrusted tool: its reason and Check again", "store"),
    ("tool path not passed", CORE, '            let request = try JSONSerialization.data(withJSONObject: cliPath().map { ["cliPath": $0] } ?? [String: String]())',
     '            let request = try JSONSerialization.data(withJSONObject: [String: String]())', "install passes the bundled tool", "store"),
    ("tool registered on every read", CORE, "        if !cliRegistered { cliRegistered = true; await registerCLI(run) }", "        await registerCLI(run)", "registered once per launch", "store"),
    ("explicit Parakeet offers Check again", CORE, "            return .blocked(reason: notInstallableLine(parakeet), action: explicit ? .useWhisper : .checkAgain)",
     "            return .blocked(reason: notInstallableLine(parakeet), action: .checkAgain)", "explicit Parakeet that cannot install", "store"),
    ("cancelled reads as a failure", CORE, '        if parakeet.cancelled { return "Install cancelled. Nothing was kept, and dictation keeps using Whisper." }\n', "",
     "cancelled: says nothing was kept", "store"),
    ("server note dropped", CORE, "        if let note = choice.note { return note }\n", "", "the server's note reaches the screen", "store"),
    ("507 ignored", CORE, "            case 507:\n                error = Transcription.diskLine(free: Int64(started.details[\"freeBytes\"]?.int ?? 0)); return\n", "",
     "the server's 507 says how much is free", "store"),
    # The setup guide.
    ("Checking counts as green", CONNECT, "        case .checking:\n            row.done = false", "        case .checking:\n            row.done = true", "voice truth", "connect"),
    ("proof from any server version", CONNECT, "        if let proof = facts.dictationProof, proof.serverVersion == current { return .proven(proof.engine) }",
     "        if let proof = facts.dictationProof { return .proven(proof.engine) }", "voice truth", "connect"),
    ("background check during a recording", CONNECT, "        guard !recording, !facts.dictationChecking, let current = facts.serverVersion, facts.dictationCheckAttempted != current,",
     "        guard !facts.dictationChecking, let current = facts.serverVersion, facts.dictationCheckAttempted != current,", "check once", "connect"),
    ("background check every refresh", CONNECT, "        guard !recording, !facts.dictationChecking, let current = facts.serverVersion, facts.dictationCheckAttempted != current,",
     "        guard !recording, !facts.dictationChecking, let current = facts.serverVersion,", "check once", "connect"),
    ("pending check reads amber", CONNECT, "        if facts.dictationCheckAttempted != current { return .checking }\n", "", "voice truth", "connect"),
    ("memory shown for Whisper", CONNECT, '        if result.engine == "whisper" { parts.append("already running, so no extra memory") }\n        else if let peak',
     '        if let peak', "advice lines", "connect"),
    ("accuracy ignored", CONNECT, "            if let p = parakeet.wer, let w = test?.result(\"whisper\")?.wer, test?.result(\"whisper\")?.ran == true, p > w + werMargin {",
     "            if let p = parakeet.wer, let w = test?.result(\"whisper\")?.wer, test?.result(\"whisper\")?.ran == true, p > w + 1.0 {", "advice", "connect"),
    ("memory ignored", CONNECT, "        guard memoryBytes == 0 || memoryBytes >= minimumParakeetMemory else {", "        guard true else {", "advice", "connect"),
    ("a refused save is a pick", CONNECT, "            guard await self.setDictationEngine(setting) else {", "            guard await self.setDictationEngine(setting) || true else {", "engine pick", "connect"),
    # The failure card's action (app core).
    ("retry the server refused", MDC, "            if retryable == false { return .openTranscriptionSettings }\n", "", "never Retry when the server says it cannot succeed", "dictation"),
    ("retry without audio", MDC, "            return audioHeld ? .retry : .none", "            return .retry", "never Retry without the audio", "dictation"),
    ("no speech offers an action", MDC, "        if noSpeech { return .none }\n        let asked", "        let asked", "no speech offers nothing", "dictation"),
    ("engine not saved", MDC, "        try c.encodeIfPresent(engine, forKey: .engine); try c.encodeIfPresent(fallbackReason, forKey: .fallbackReason)\n", "",
     "the engine is saved with the dictation", "dictation"),
    ("Fix a word drops the engine", MDC, "delivery: $0.delivery, engine: $0.engine, fallbackReason: $0.fallbackReason) : $0 }", "delivery: $0.delivery) : $0 }",
     "Fix a word keeps the engine", "dictation"),
    # Wiring (source pins).
    ("app requires Parakeet again", MD, '                      let engine = response.details["engine"]?.string, DictationEngineName.title(engine) != nil else {',
     '                      let engine = response.details["engine"]?.string, engine == "parakeet-ultra" else {', "any local engine", "pins"),
    ("card shows a dead Retry", MD, "                    if let title = action.title, action != .retry || store.canRetry {", "                    if let title = action.title {", "one action", "pins"),
    ("settings opens the wrong place", APP, 'SettingsOpener.open(model: model, window: settingsWindow, scroll: "transcription")', 'SettingsOpener.open(model: model, window: settingsWindow, scroll: "settings")',
     "settings not privacy", "pins"),
    ("tool signed without hardened runtime", REL, '    /usr/bin/codesign --force --options runtime --timestamp --identifier com.gotcos.control.fluidaudiocli --sign "$SIGN_ID"',
     '    /usr/bin/codesign --force --timestamp --identifier com.gotcos.control.fluidaudiocli --sign "$SIGN_ID"', "cli signed", "pins"),
    ("release ships without the tool", REL, 'elif [ -n "${COS_SIGN_IDENTITY:-}" ]; then\n  echo "Refusing to ship a Developer ID release without the pinned fluidaudiocli',
     'elif false; then\n  echo "Refusing to ship a Developer ID release without the pinned fluidaudio', "cli pinned", "pins"),
    ("voice row ignores the truth", CONNECT, "        switch DictationTruth.of(facts) {", "        switch DictationTruth.proven(\"parakeet-ultra\") {", "voice truth", "pins"),
    # Release checks (no Swift).
    ("tool entitlements unchecked", ENT, '        if got:\n            found.append(f"the bundled fluidaudiocli carries entitlements it does not need: {got!r}")',
     '        if False:\n            found.append(f"the bundled fluidaudiocli carries entitlements it does not need: {got!r}")', "cli-with-entitlements", "release"),
    ("tool version unchecked", FA, "    for key, want in [('CFBundleIdentifier', pin['identifier']), ('CFBundleShortVersionString', pin['version']),",
     "    for key, want in [('CFBundleIdentifier', pin['identifier']),", "a wrong version must fail", "release"),
    ("tool runtime unchecked", FA, "        if not re.search(r'flags=0x[0-9a-f]*\\(.*runtime.*\\)', info):", "        if False:", "AssertionError", "release"),
    # The compiled helper (one large compile each).
    ("helper keeps the Parakeet route", H, "              let route = DictationBridge.route(capabilities.body) else {",
     "              let route = DictationBridge.route(capabilities.body).map({ _ in DictationBridge.parakeetRoute }) else {", "a 6.74.0 server gets requiredEngine=local", "helper"),
    ("helper install forbids the download", H, '            var payload: [String: Any] = call == .installParakeet ? ["allowDownload": true] : [:]',
     '            var payload: [String: Any] = [:]', "install is a POST to the install route, no localSource", "helper"),
    ("helper cancels with a POST", H, '        case .cancelInstall: "DELETE"\n', '        case .cancelInstall: "POST"\n', "Cancel is a DELETE of the install route", "helper"),
]


def swiftc(copy, sources, out, frameworks=()):
    cmd = ["/usr/bin/python3", str(copy / "Tests/kit-compile.py"), str(copy / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library"]
    cmd += [str(copy / s) for s in sources]
    for f in frameworks: cmd += ["-framework", f]
    return subprocess.run(cmd + ["-o", str(out)], capture_output=True, text=True)


def lane(copy, name):
    build = copy / "build"; build.mkdir(exist_ok=True)
    if name == "store":
        return subprocess.run(["zsh", str(copy / "Tests/run-transcription-settings.sh")], capture_output=True, text=True)
    if name == "pins":
        return subprocess.run(["python3", str(copy / "Tests/dictation-everyone-pins.py"), str(copy)], capture_output=True, text=True)
    if name == "release":
        scratch = pathlib.Path(tempfile.mkdtemp(dir="/private/tmp", prefix="cos-mut-release-"))
        try:
            shutil.copy("/usr/bin/true", scratch / "sample")
            a = subprocess.run(["python3", str(copy / ENT), "--selftest", str(scratch), str(scratch / "sample")], capture_output=True, text=True)
            b = subprocess.run(["python3", str(copy / FA), "--selftest", str(copy / "Resources/fluidaudio-cli.json"), str(scratch / "fa")], capture_output=True, text=True)
            return subprocess.CompletedProcess(a.args, a.returncode or b.returncode, a.stdout + b.stdout, a.stderr + b.stderr)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    if name == "core":
        b = swiftc(copy, [PSC, "Tests/DictationEveryoneChecks.swift"], build / "core")
        return b if b.returncode else subprocess.run([str(build / "core"), str(copy / "Resources/VoiceBenchmark/speech-30s.txt")], capture_output=True, text=True)
    if name == "connect":
        b = swiftc(copy, [CONNECT, "Tests/ProviderConnectChecks.swift"], build / "connect")
        if b.returncode: return b
        home = build / "connect home.ü"; home.mkdir(exist_ok=True)
        return subprocess.run([str(build / "connect")], capture_output=True, text=True, env=dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home)))
    if name == "dictation":
        b = swiftc(copy, [MDC, "Tests/MacDictationChecks.swift"], build / "dictation")
        return b if b.returncode else subprocess.run([str(build / "dictation")], capture_output=True, text=True)
    if name == "helper":
        b = subprocess.run(["/usr/bin/python3", str(copy / "Tests/kit-compile.py"), str(copy / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
                            str(copy / H), str(copy / PSC), str(copy / "HelperSources/PairingCore.swift"), str(copy / "Sources/WorkSessionLinks.swift"),
                            "-framework", "Security", "-framework", "AppKit", "-o", str(build / "cos-control-helper")], capture_output=True, text=True)
        if b.returncode: return b
        out, err, code = "", "", 0
        for script, extra in [("Tests/mac-dictation-helper-checks.py", []), ("Tests/dictation-everyone-helper-checks.py", [str(copy)]),
                              ("Tests/transcription-settings-helper-checks.py", [str(copy / "Tests/fixtures/stt-settings-6.72.0.json")])]:
            r = subprocess.run(["python3", str(copy / script), str(build / "cos-control-helper")] + extra, capture_output=True, text=True)
            out += r.stdout; err += r.stderr; code = code or r.returncode
        return subprocess.CompletedProcess([], code, out, err)
    raise SystemExit(f"unknown lane {name}")


def main():
    root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    wanted = set(sys.argv[3:])
    copy = scratch / "copy"
    # Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
    os.environ.setdefault("COS_TEST_KIT_DIR", str(scratch / "kits"))
    shutil.rmtree(copy, ignore_errors=True)
    shutil.copytree(root, copy, ignore=shutil.ignore_patterns(".git", "dist"))
    chosen = [m for m in MUTANTS if not wanted or m[0] in wanted or m[5] in wanted]
    for name in sorted({m[5] for m in chosen}):
        result = lane(copy, name)
        if result.returncode != 0:
            print(f"BASELINE RED [{name}]\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}"); sys.exit(1)
        print(f"baseline green [{name}]: {(result.stdout.strip().splitlines() or ['(no output)'])[-1][:160]}")
    findings = 0
    for name, path, original, mutant, words, lane_name in chosen:
        target = copy / path
        text = target.read_text()
        if text.count(original) != 1:
            print(f"NOT APPLIED [{name}]: target appears {text.count(original)} times"); findings += 1; continue
        target.write_text(text.replace(original, mutant))
        try:
            result = lane(copy, lane_name)
        finally:
            target.write_text(text)
        output = result.stdout + result.stderr
        if result.returncode == 0:
            print(f"SURVIVED [{name}]"); findings += 1
        elif "error:" in output and words not in output:
            print(f"DID NOT COMPILE [{name}]\n{output[-600:]}"); findings += 1
        elif words not in output:
            print(f"KILLED BY THE WRONG CHECK [{name}]: expected '{words}'\n{output[-800:]}"); findings += 1
        else:
            line = next((l for l in output.splitlines() if words in l), words)
            print(f"killed [{name}]: {line.strip()[:200]}")
    print(f"{len(chosen) - findings} of {len(chosen)} mutants killed by the named check")
    sys.exit(1 if findings else 0)


main()
