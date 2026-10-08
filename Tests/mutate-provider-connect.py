#!/usr/bin/env python3
"""Mutation lane for Connect your AI's guards (onboarding P1). Run by hand, never by a gate. SERIAL: one mutant at a
time, and every compile goes through Tests/compile-guard.sh (two kernel panics on 2026-10-07 came from parallel compiles).

    python3 Tests/mutate-provider-connect.py <worktree> <scratch dir> [name ...]

It copies the worktree once to <scratch dir>/copy, proves each UNMUTATED lane green first (a red baseline makes every
mutant look killed), then applies one mutant at a time: the target text must appear exactly once, the mutant must make
a check fail, and the failure must name the behaviour the mutant breaks ("check failed [<behaviour>]" or "pin failed
[<behaviour>]"). A mutant that lands and survives is a finding. Lanes: "core" compiles HelperSources/ProviderStatusCore
with its fixture checks; "model" compiles Sources/ProviderConnectModel.swift with its checks; "pins" runs Python only.
"""
import pathlib, shutil, subprocess, sys, tempfile, time

K = "HelperSources/ProviderStatusCore.swift"
H = "HelperSources/main.swift"
M = "Sources/ProviderConnectModel.swift"
W = "Sources/ProviderConnectViews.swift"
C = "Sources/ControllerModel.swift"
V = "Sources/Views.swift"
S = "Sources/ControlSetup.swift"
R = "scripts/build-release.sh"
CH = '"/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",\n'
# (name, file, original, mutant, words the killing failure must contain, lane)
MUTANTS = [
    # provider-status core.
    ("ChatGPT app codex dropped", K, "                " + CH, "", "[ChatGPT-only codex]", "core"),
    ("PATH before the server's absolutes", K,
     '        list += absolutes(provider, home: environment.home).map { ProviderCandidate(path: $0, source: "absolute") }\n        let pathDirs',
     '        let pathDirs', "[candidate order]", "core"),
    ("stale Codex.app shim usable", K, "            if isStaleShim(c.path) {", "            if false {", "[stale shim]", "core"),
    ("Claude Desktop's copy chosen", K, "firstIndex(where: { $0.executable && $0.source != \"claudeDesktop\" })", "firstIndex(where: { $0.executable })", "[claude desktop copy]", "core"),
    ("any agent is Cursor", K, "                guard parsed.isCursor else {", "                guard parsed.isCursor || true else {", "[cursor identity]", "core"),
    ("a redacted address reads signed out", K, '(emailLine.contains("@") || lower.contains("redacted"))', 'emailLine.contains("@")', "[cursor sign-in]", "core"),
    ("cloud provider read as subscription", K, '        if provider != "firstparty" { return .apiKey }\n', "", "[claude api key]", "core"),
    ("an old codex reads signed out", K, "        // send the user to sign in again.\n        return .unknown", "        // send the user to sign in again.\n        return .signInRequired", "[codex unknown]", "core"),
    ("a down daemon reads running", K, '                status.daemon = "down"\n', '                status.daemon = "running"\n', "[ollama", "core"),
    ("COS_OLLAMA_HOST ignored", K, 'let origin = ProviderStatusCore.ollamaOrigin(environment.env["COS_OLLAMA_HOST"])', "let origin = ProviderStatusCore.ollamaOrigin(nil)", "[ollama host]", "core"),
    # The app model.
    ("Get started waits on busy no more", M, "{ setupProviderInstalled && !busy }", "{ setupProviderInstalled }", "[gate unchanged]", "model"),
    ("an unread status blocks the sign-in step", M, "        guard let report else { return true }\n        return ProviderRules.needCount", "        guard let report else { return false }\n        return ProviderRules.needCount", "[sign-in step]", "model"),
    ("skip not counted", M, ' && status.signIn == "signInRequired" && !skipped.contains(provider)', ' && status.signIn == "signInRequired"', "[sign-in step]", "model"),
    ("any tag length", M, "guard (8...32).contains(bytes.count) else { return false }", "guard (1...64).contains(bytes.count) else { return false }", "[prompt tag]", "model"),
    ("uppercase tags", M, '(UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }\n    }', '(UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }\n    }', "[prompt tag]", "model"),
    ("& left raw in links", M, 'CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")\n    static let promptLimit',
     'CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~&")\n    static let promptLimit', "[link", "model"),
    ("no length limit", M, "guard !prompt.isEmpty, prompt.utf16.count <= promptLimit,", "guard !prompt.isEmpty,", "[link length]", "model"),
    ("backs off to 30 s", M, "static let slow: TimeInterval = 15", "static let slow: TimeInterval = 30", "[polling bounds]", "model"),
    ("polls for 30 minutes", M, "static let limit: TimeInterval = 15 * 60", "static let limit: TimeInterval = 30 * 60", "[poll", "model"),
    ("polls with nothing to wait for", M, "            guard !targets.isEmpty,\n", "            guard true,\n", "[poll loop]", "model"),
    ("polls signed-in rows", M, '            return !status.installed || status.signIn == "signInRequired"', "            return true", "[poll loop]", "model"),
    ("every binary named bare", M, "        if shellPathDirectories.contains(directory) { return login }", "        if true { return login }", "[login command]", "model"),
    ("quotes not escaped for AppleScript", M, '.replacingOccurrences(of: "\\"", with: "\\\\\\"")\n        return "tell application', '\n        return "tell application', "[terminal script]", "model"),
    ("a failed --version reads Not signed in", M, "            } else if serverReady == false {\n                notFound.append(name)",
     "            } else if serverReady == false {\n                signIn.append(name)", "[agent line fallback]", "model"),
    ("menu bar only by default", M, "Mode(rawValue: stored ?? \"\") ?? .dock", "Mode(rawValue: stored ?? \"\") ?? .menuBarOnly", "[dock default]", "model"),
    ("pet intro for people who changed settings", M, "!seen && touchedKeys == 0 && petEnabled", "!seen && petEnabled", "[pet intro]", "model"),
    ("two passes at once", M, "        if passes[provider] != nil, waiting[provider] != nil {", "        if false {", "[pass one at a time]", "model"),
    ("Terminal failure loses the command", M, "            copy(command)\n            let opened = openTerminalApp()", "            let opened = openTerminalApp()", "[sign in fallback]", "model"),
    ("a signed-in row keeps waiting", M, "where report?.status(provider)?.signedIn == true {", "where false {", "[sign in]", "model"),
    # The setup guide and voice (Miles 2026-10-08 10:52 and 10:59).
    ("missing bytes ignore truncated files", K, "            if (sizes[model.name] ?? 0) < model.minBytes { total += model.bytes }", "            if sizes[model.name] == nil { total += model.bytes }", "[voice sizes]", "core"),
    ("no disk margin", K, "freeBytes + partialBytes >= missing + safetyMarginBytes", "freeBytes + partialBytes >= missing", "[voice disk]", "core"),
    ("curl's percent ignored", K, "                if value <= 100 { percent = value }", "                if value > 100 { percent = value }", "[voice progress]", "core"),
    ("Hide ignored", M, "!hidden && p.total > 0 && p.handled < p.total", "p.total > 0 && p.handled < p.total", "[finish card hide]", "model"),
    ("a skip is not handled", M, "var handled: Bool { done || skipped }", "var handled: Bool { done }", "[finish card", "model"),
    ("rows that wait for the server are counted", M, "let counted = rows.filter { !$0.afterSetup }", "let counted = rows", "[setup guide early]", "model"),
    ("a degraded tier reads ready", M, "if voice.whisperReady && !voice.degraded, let requested", "if voice.whisperReady, let requested", "[voice apply]", "model"),
    ("no disk check before download", M, "            if voice.enoughDisk[tier] == false {", "            if false {", "[voice disk]", "model"),
    ("setup starts without whisper.cpp", M, "return voice.whisperCli && voice.whisperServer && voice.setupAvailable", "return voice.setupAvailable", "[voice gate]", "model"),
    ("Cancel reads as a failure", M, "            } catch is CancellationError {", "            } catch is URLError {", "[voice cancel]", "model"),
    ("skips forgotten", M, "func skip(_ id: SetupRowID) { skipped.insert(id); save() }", "func skip(_ id: SetupRowID) { skipped.insert(id) }", "[setup guide resume]", "model"),
    ("finish card below the fold", V, "                header\n                // Early users: Finish setup at the top", "                updateRow\n                header\n                // Early users: Finish setup at the top", "[finish card]", "pins"),
    ("pet loses Settings", "Sources/SessionPet.swift", '        Button("Settings…") { model.showSettings?() }\n', "", "[pet menu]", "pins"),
    ("Dock menu loses the guide", W, '["Open Activity", "Setup guide…", "Settings…"]', '["Open Activity", "Settings…"]', "[dock menu]", "pins"),
    ("Guided Setup back to bare npx", C, "        let command = setupGuide.voice?.terminalCommand[normalized]\n            ?? ", "        let command = ", "[guided setup]", "pins"),
    ("voice setup without its own process group", H, "posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))", "posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))", "[voice cancel]", "pins"),
    # QA 2026-10-08 fixes.
    ("Get Ollama does nothing", M, "status?.installed == true ? .openOllama : .download(.ollama),", "status?.installed == true ? .openOllama : .none,", "[every button acts]", "model"),
    ("an unknown sign-in is not handled", M, "done: status?.signedIn == true || unknown,", "done: status?.signedIn == true,", "[unknown handled]", "model"),
    ("the card shows before the facts", M, "return loaded && !hidden && p.total > 0", "return !hidden && p.total > 0", "[finish card loading]", "model"),
    ("the voice row ignores the server's tier", M, "guard !voiceTierChosen, let tier = requested", "guard false, let tier = requested", "[voice tier start]", "model"),
    ("a wait never stops", M, "for (provider, started) in waiting where at.timeIntervalSince(started) >= ProviderPollSchedule.limit {", "for (provider, started) in waiting where false {", "[poll limit]", "model"),
    ("no Terminal when the script fails", M, "            let opened = openTerminalApp()", "            let opened = false", "[sign in fallback]", "model"),
    ("the migration's key hides the pet intro", M, '"cos.sessionPetSize", "cos.sessionPetSizePixels"]', '"cos.sessionPetSize", "cos.sessionPetSizePixels", "cos.sessionPetCharacterPercent"]', "[pet intro]", "model"),
    ("Settings clicks an open panel closed", M, "        if panelOpen { return .scrollOpenPanel }\n", "", "[settings route]", "model"),
    ("provider skips in two stores", M, "guard !SetupGuideState.providerRows.contains(id) else { return }; ", "", "[one skip store]", "model"),
    ("no status json fallback for Cursor", K, "if !proven || status.signIn == .unknown, let json = probes.run(", "if false, let json = probes.run(", "[cursor fallback]", "core"),
    ("cursor-agent read as runnable", K, '        candidate.source == "env" || URL(fileURLWithPath: candidate.path).lastPathComponent == "agent"', "        true", "[cursor-agent only]", "core"),
    ("the gate counts Claude Desktop", K, 'contains(where: { $0.executable && $0.source != "claudeDesktop" })', "contains(where: { $0.executable })", "[gate agrees]", "core"),
    ("restore keeps the setup's keys", K, "            guard let value = snapshot[key] ?? nil, !written.contains(key) else { return nil }", "            guard let value = snapshot[key] ?? nil, !written.contains(key) else { return line }", "[env restore]", "core"),
    ("Cancel exits before the restore", H, "            voiceSetupCancelled = 1\n", "            voiceSetupCancelled = 1\n            _exit(143)\n", "[voice env]", "pins"),
    ("no restore after the setup", H, "        try restoreVoiceEnvSnapshotIfPresent()\n        let tail = String(stripEmails(output.text).suffix(1500))", "        let tail = String(stripEmails(output.text).suffix(1500))", "[voice env]", "pins"),
    # Wiring.
    ("no panel row", V, "                PanelConnectAIRow(guide: model.providerGuide, model: model)\n", "", "[panel row]", "pins"),
    ("Get started runs nothing", S, 'getStarted: { model.perform("setup") })', "getStarted: { })", "[welcome]", "pins"),
    ("sign-in gates Get started", W, "                        .buttonStyle(COSPrimaryButtonStyle())\n                        .disabled(!ProviderGate.getStartedEnabled(setupProviderInstalled: setupProviderInstalled, busy: busy))",
     "                        .buttonStyle(COSPrimaryButtonStyle())\n                        .disabled(!guide.signInStepDone || !setupProviderInstalled)", "[gate unchanged]", "pins"),
    ("the guide is live in checks", C, "        guard inApp else { return guide }\n        guide.log = { line in onboardingLog", "        guide.log = { line in onboardingLog", "[inert in checks]", "pins"),
    ("probes stopped before the rows are read", H, "        let rows = wanted.map { results.get($0) ?? ProviderStatusCore.timedOut($0) }\n        if !complete { ProbeRunner.stopAll() }",
     "        if !complete { ProbeRunner.stopAll() }\n        let rows = wanted.map { results.get($0) ?? ProviderStatusCore.timedOut($0) }", "[deadline]", "pins"),
    ("a login run as a probe", K, 'probes.run(path, ["auth", "status", "--json"])', 'probes.run(path, ["auth", "login"])', "[read-only probes]", "pins"),
    ("the card opens on a need", W, "            if guide.panelRouteActive {\n                ProviderConnectCard", "            if guide.panelRouteActive || guide.needCount > 0 {\n                ProviderConnectCard", "[route flag]", "pins"),
    ("the collapsed row polls", W, ".task { if guide.report == nil { await guide.refresh() } }", ".task { await guide.poll() }", "[polling]", "pins"),
    ("no Dock switch", V, '            Toggle("Show in menu bar only"', '            Toggle("Hide from Dock"', "[dock]", "pins"),
    ("release build without the views", R, ' "$ROOT/Sources/ProviderConnectViews.swift"', "", "[source lists]", "pins"),
    ("the old label is back", V, "            AgentCliDetailLine(guide: model.providerGuide, model: model, allReady: agentCliAllReady)", "            Text(\"x\")", "[label fix]", "pins"),
]


def run(lane, copy):
    if lane == "core":
        cmd = ["/bin/zsh", str(copy / "Tests/run-provider-status.sh")]
    elif lane == "model":
        out = pathlib.Path(tempfile.mkdtemp(prefix="cos-mut-connect-", dir="/tmp"))
        compile_cmd = ["/bin/zsh", str(copy / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6",
                       "-strict-concurrency=complete", "-parse-as-library", str(copy / M), str(copy / "Tests/ProviderConnectChecks.swift"), "-o", str(out / "checks")]
        while True:
            p = subprocess.run(compile_cmd, capture_output=True, text=True)
            if p.returncode != 75:
                break
            time.sleep(30)
        if p.returncode != 0:
            shutil.rmtree(out, ignore_errors=True)
            return p.returncode, p.stdout + p.stderr
        home = out / "home"
        home.mkdir()
        try:
            q = subprocess.run([str(out / "checks")], capture_output=True, text=True, timeout=300,
                               env={"HOME": str(home), "CFFIXED_USER_HOME": str(home), "PATH": "/usr/bin:/bin"})
            return q.returncode, q.stdout + q.stderr
        except subprocess.TimeoutExpired:
            return 124, "check failed [poll loop timeout]: the checks did not finish"
        finally:
            shutil.rmtree(out, ignore_errors=True)
    else:
        cmd = ["/usr/bin/python3", str(copy / "Tests/provider-connect-pins.py"), str(copy)]
    while True:
        p = subprocess.run(cmd, capture_output=True, text=True)
        # 75: the guard's lock wait timed out (another agent compiling). Contention, not a verdict: wait and retry.
        if p.returncode == 75:
            time.sleep(30)
            continue
        return p.returncode, p.stdout + p.stderr


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "dist", "*.zip"))
    for lane in ("core", "model", "pins"):
        code, out = run(lane, copy)
        if code != 0:
            sys.exit(f"baseline {lane} lane is RED; no mutant can be judged:\n{out[-3000:]}")
        print(f"baseline {lane}: green", flush=True)
    survived, results = [], []
    for name, rel, original, mutant, words, lane in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        n = text.count(original)
        if n != 1:
            results.append(f"MISSED TARGET ({n}x) {name}")
            survived.append(name)
            continue
        path.write_text(text.replace(original, mutant), encoding="utf-8")
        started = time.time()
        try:
            code, out = run(lane, copy)
        finally:
            path.write_text(text, encoding="utf-8")
        took = time.time() - started
        if code == 137:
            sys.exit(f"compile guard stopped the run at mutant {name}; stopping the lane")
        if code == 0:
            results.append(f"SURVIVED {name}")
            survived.append(name)
        elif words in out:
            results.append(f"killed  {name}  ({words}, {took:.0f}s)")
        elif "error:" in out:
            # A mutant the compiler refuses never ran: it says nothing about the checks (QA 2026-10-08 W3).
            results.append(f"WEAK (compile error) {name}")
            survived.append(name)
        else:
            results.append(f"WEAK (another check) {name}: {out.strip().splitlines()[-1][:160] if out.strip() else ''}")
            survived.append(name)
        print(results[-1], flush=True)
    print(f"{len(results) - len(survived)} of {len(results)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
