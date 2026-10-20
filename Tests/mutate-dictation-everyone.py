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
helper, then the helper check scripts, 0.5.325's dictation-polish among them; one large compile per mutant, so few
mutants use it), polishpins (0.5.325 dictation-polish-pins.py, no compile), tailpins (0.5.326 dictation-tail-pins.py, no
compile), startpins (0.5.327 dictation-start-pins.py, no compile), smoothpins (0.5.328 dictation-smooth-pins.py, no
compile).
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
    ("Whisper gets a memory figure", CONNECT, '        whisper.append(whisperRunning ? "Ready" : "Not running")',
     '        whisper.append("3.0 GB peak memory")', "result rows", "connect"),
    ("untested Parakeet offers no Test", CONNECT, "            offersTest = true", "            offersTest = false", "result rows", "connect"),
    ("rows drop the recommendation", CONNECT, '            if advice.engine == "parakeet-ultra" { parakeet.append("Recommended on Apple silicon") }\n', "", "result rows", "connect"),
    ("Automatic on Whisper reads amber", CONNECT, '        row.calm = effective == "whisper" || effective == "parakeet-ultra" || facts.engineTesting || voice.parakeetInstalling',
     '        row.calm = facts.engineTesting || voice.parakeetInstalling', "calm status", "connect"),
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
    # 0.5.325 AI polish: the helper core (DictationPolishBridge), the wiring pins and the compiled helper.
    ("polish takes any model", PSC, '              let model = object["model"] as? String, models.contains(model) else { return nil }',
     '              let model = object["model"] as? String else { return nil }', "polish model", "core"),
    ("polish takes blank text", PSC, '              let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,',
     '              let text = object["text"] as? String,', "polish text", "core"),
    ("polish over the limit", PSC, "              text.utf16.count <= maximumCharacters,", "              true,", "polish limit", "core"),
    ("polish limit counts characters", PSC, "              text.utf16.count <= maximumCharacters,", "              text.count <= maximumCharacters,", "polish limit", "core"),
    ("polish takes extra keys", PSC, '              Set(object.keys).isSubset(of: ["text", "model", "app", "prewarmToken"]),', "              true,", "polish keys", "core"),
    ("polish keeps a long app", PSC, "!$0.isEmpty && $0.count <= 64 && !$0.contains(where: \\.isNewline)", "!$0.isEmpty", "polish app dropped", "core"),
    ("polish deadline is the budget", PSC, '        case "haiku": 4.5', '        case "haiku": 5', "polish deadline", "core"),
    ("polish posts another surface", PSC, '["text": request.text, "surface": "message", "autocleanModel": request.model]',
     '["text": request.text, "surface": "email", "autocleanModel": request.model]', "polish body", "core"),
    ("polish drops the app", PSC, '        if let app = request.app { object["context"] = ["app": app] }\n', "", "polish body", "core"),
    ("polish takes a numeric polished", PSC, 'let flag = body["polished"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {',
     'let flag = body["polished"] as? NSNumber else {', "polish bad answer", "core"),
    ("polish answer unbounded", PSC, "!text.isEmpty, text.utf16.count <= answerLimit,", "!text.isEmpty,", "polish bad answer", "core"),
    ("polish answer may be empty", PSC, '            guard let body, let text = body["text"] as? String, !text.isEmpty, text.utf16.count <= answerLimit,',
     '            guard let body, let text = body["text"] as? String, text.utf16.count <= answerLimit,', "polish bad answer", "core"),
    ("polish timeout reads as unreachable", PSC, '            return timedOut ? refused("timeout",', '            return false ? refused("timeout",', "polish timeout", "core"),
    ("polish failure carries text", PSC, '            var details = base.merging(["reason": reason]) { a, _ in a }',
     '            var details = base.merging(["reason": reason, "text": "private words"]) { a, _ in a }', "polish http", "core"),
    ("polish 404 is a plain HTTP error", PSC, '        case 404: return refused("needs_server_update"', '        case 404: return refused("http_404"', "polish http", "core"),
    ("polish pins: no re-check after the await", MD, "let polished = await polish(heard)\n                guard generation == attempt, !Task.isCancelled else { return }",
     "let polished = await polish(heard)", "current after polish", "polishpins"),
    ("polish pins: a timeout is a failure", MD, "        } catch HelperClientError.timedOut {\n            outcome = .timeout\n        } catch {", "        } catch {", "timeout", "polishpins"),
    ("polish pins: the text is logged", MD, "outcome=\\(outcome.logName, privacy: .public) ms=\\(elapsed)\")",
     "outcome=\\(outcome.logName, privacy: .public) ms=\\(elapsed) \\(heard, privacy: .private)\")", "no text logged", "polishpins"),
    ("polish pins: a failure shows a card", MD, "        let elapsed = Int(Date().timeIntervalSince(started) * 1000)\n",
     "        let elapsed = Int(Date().timeIntervalSince(started) * 1000)\n        if case .failed(let why) = outcome { fail(why) }\n", "never a failure", "polishpins"),
    ("polish pins: what was heard kept when unchanged", MD, "if case .applied? = polished?.outcome, let model = polished?.model { lastPolish",
     "if let model = polished?.model { lastPolish", "heard only when applied", "polishpins"),
    ("polish pins: no budget on the helper", APP, 'runHelper(["dictation-polish"], timeout: budget, stdinData: request, answers: true)',
     'runHelper(["dictation-polish"], timeout: 40, stdinData: request, answers: true)', "bridge", "polishpins"),
    # 0.5.328: the polish twin of the dictation refusal fix, and the server's skip reason.
    ("polish pins: refusals thrown as failed:helper", APP, 'runHelper(["dictation-polish"], timeout: budget, stdinData: request, answers: true)',
     'runHelper(["dictation-polish"], timeout: budget, stdinData: request)', "bridge", "polishpins"),
    ("polish pins: the skip reason not read", MD, '                                             skipped: response.details["polishSkipped"]?.string)',
     '                                             skipped: nil)', "skip reason", "polishpins"),
    ("polish core: any skip word passes", PSC, 'if let skipped = body["polishSkipped"] as? String, skipReasons.contains(skipped) { details["polishSkipped"] = skipped }',
     'if let skipped = body["polishSkipped"] as? String { details["polishSkipped"] = skipped }', "polish skipped whitelist", "core"),
    ("polish core: the skip reason dropped", PSC, 'if let skipped = body["polishSkipped"] as? String, skipReasons.contains(skipped) { details["polishSkipped"] = skipped }',
     '', "polish skipped", "core"),
    ("polish pins: the deadline equals the budget", PSC, '        case "sonnet": 8.5', '        case "sonnet": 9', "deadline inside budget", "polishpins"),
    ("polish helper probes health first", H, "could spend the whole budget.\n        guard let token = try? readToken() else {",
     "could spend the whole budget.\n        guard let token = try? speakerReviewToken() else {",
     "no health probe spends the budget", "helper"),
    ("polish helper has no deadline", H, "                               timeout: Int(seconds.rounded(.up)), deadlineUptime: deadline)", "                               timeout: 9)",
     "a slow model is a timeout", "helper"),
    # 0.5.326 release tail wiring (Tests/dictation-tail-pins.py, no compile).
    ("tail pins: the hold release closes at once", MD, "    func stop() { stop(ending: .released) }", "    func stop() { stop(ending: .maximum) }", "person's stop", "tailpins"),
    ("tail pins: the limit tails", MD, "if !Task.isCancelled { stop(ending: .maximum) }", "if !Task.isCancelled { stop() }", "limit", "tailpins"),
    ("tail pins: a stale tail closes a newer dictation", MD, "guard let self, !Task.isCancelled, self.generation == attempt, self.tailing else { return }",
     "guard let self else { return }", "tail current", "tailpins"),
    ("tail pins: the release shows TRANSCRIBING early", MD, "        tailing = true\n        let attempt = generation\n        tailTask = Task",
     "        tailing = true; pill = .transcribing\n        let attempt = generation\n        tailTask = Task", "pill stays listening", "tailpins"),
    ("tail pins: a press during the tail starts a second dictation", MD, "                held = true; holdPending = true; extendTail()",
     "                held = true; holdPending = true; start()", "press during tail", "tailpins"),
    ("tail pins: cancel leaves the tail running", MD, "        generation = UUID(); pendingAudio = nil; task?.cancel(); task = nil; timer?.cancel(); timer = nil\n        tailing = false; tailTask?.cancel(); tailTask = nil; releaseMark = nil; timing = nil\n",
     "        generation = UUID(); pendingAudio = nil; task?.cancel(); task = nil; timer?.cancel(); timer = nil\n", "cancel", "tailpins"),
    ("tail pins: the converter is not drained", MD, "        converter?.finish(); converter = nil\n", "        converter = nil\n", "drain", "tailpins"),
    ("tail pins: a late buffer converts after the drain", MD, "        lock.lock(); defer { lock.unlock() }\n        guard !finished else { return }\n        let capacity",
     "        lock.lock(); defer { lock.unlock() }\n        let capacity", "drain lock", "tailpins"),
    ("tail pins: a failed dictation writes no timing", MD, '        recordTiming("failed")\n', "", "every outcome", "tailpins"),
    # 0.5.327 truthful start wiring (Tests/dictation-start-pins.py, no compile).
    ("start pins: the sound plays on the press", MD, "            if self.phase == \"Starting\" { self.pill = .starting }\n",
     "            if self.phase == \"Starting\" { self.pill = .starting; self.playSound(.start) }\n", "nothing on press", "startpins"),
    ("start pins: LISTENING on the press", MD, "            if self.phase == \"Starting\" { self.pill = .starting }\n",
     "            if self.phase == \"Starting\" { self.pill = .listening(since: Date()) }\n", "starting on press", "startpins"),
    ("start pins: the mute before the microphone", MD, "        startMarks = DictationStartMarks(pressed: pressed); startMarks?.editWatchAtPress = watching\n",
     "        startMarks = DictationStartMarks(pressed: pressed); startMarks?.editWatchAtPress = watching\n        quiet.begin(mode: quietMode, macRecording: false)\n", "nothing on press", "startpins"),
    ("start pins: Listening before the first buffer", MD, "            switch await awaitFirstAudio(next, attempt: attempt) {",
     '            phase = "Listening"\n            switch await awaitFirstAudio(next, attempt: attempt) {', "one way to listen", "startpins"),
    ("start pins: the list read on every press", MD, "            let chosen = DictationStart.resolve(selectedUID: microphoneUID,",
     "            refreshMicrophones()\n            let chosen = DictationStart.resolve(selectedUID: microphoneUID,", "no list on press", "startpins"),
    ("start pins: a silent microphone left open", MD, "                capture = nil; _ = try? next.stop()\n", "                capture = nil\n", "mic closed on start failure", "startpins"),
    ("start pins: the spare starts while it waits", MD, "        try select(deviceID)\n        _ = engine.inputNode",
     "        try select(deviceID)\n        engine.prepare(); try engine.start()\n        _ = engine.inputNode", "spare never started", "startpins"),
    ("start pins: a spare built while dictating", MD, "guard let self, !Task.isCancelled, self.capture == nil, !self.busy else { return }",
     "guard let self, !Task.isCancelled else { return }", "spare only when idle", "startpins"),
    ("start pins: a stale spare used", MD, 'if case .discard(let why) = verdict { dictationLog.notice("spare engine discarded: \\(why, privacy: .public)"); return nil }',
     "_ = verdict", "spare taken once", "startpins"),
    ("start pins: start numbers left off the line", MD, "                timing?.include(startMarks)\n", "", "timing fields", "startpins"),
    ("start pins: the first-buffer time from the pill", MD, "startMarks?.pressToFirstBufferMs = DictationStartMarks.ms(pressed, at)",
     "startMarks?.pressToFirstBufferMs = startMarks?.since(ProcessInfo.processInfo.systemUptime)", "timing fields", "startpins"),
    ("start pins: a failure's code not written", MD, "        timing?.failReason = code\n", "", "fail reason", "startpins"),
    ("start pins: a start failure writes no line", MD, "        if timing == nil, let marks = startMarks { timing = DictationTiming.startFailure(marks, at: Date()) }\n", "",
     "fail reason", "startpins"),
    # 0.5.328 smooth start wiring (Tests/dictation-smooth-pins.py, no compile).
    ("smooth pins: the mute back on the main actor", MD, "final class DictationQuietController: @unchecked Sendable {",
     "@MainActor final class DictationQuietController: @unchecked Sendable {", "audio off main", "smoothpins"),
    ("smooth pins: the mute built where the store asks", MD, "        DictationAudioQueues.output.async {\n            let began = ProcessInfo.processInfo.systemUptime\n            controller.begin(",
     "        do {\n            let began = ProcessInfo.processInfo.systemUptime\n            controller.begin(", "quiet queued", "smoothpins"),
    ("smooth pins: the sound played on the main actor", MD, "        DictationAudioQueues.output.async {\n            let began = ProcessInfo.processInfo.systemUptime\n            player.play(",
     "        do {\n            let began = ProcessInfo.processInfo.systemUptime\n            player.play(", "sound queued", "smoothpins"),
    ("smooth pins: the engine opened on the main queue", MD, "let opened = try await DictationAudioQueues.perform(on: DictationAudioQueues.input) {",
     "let opened = try await DictationAudioQueues.perform(on: .main) {", "engine off main", "smoothpins"),
    ("smooth pins: an engine opened after a release keeps running", MD, "                    DictationAudioQueues.input.async { _ = try? orphan.stop() }\n", "", "orphan closed", "smoothpins"),
    ("smooth pins: LISTENING reads the mute's note", MD, '            phase = "Listening"; pill = .listening(since: Date())\n',
     '            phase = "Listening"; pill = .listening(since: Date())\n            quietNote = quiet.fallbackNote\n', "pill first", "smoothpins"),
    ("smooth pins: placement on the main thread", MD, "(try? await DictationAudioQueues.perform(on: .global(qos: .userInitiated)) { DictationFocusedWindow.frame(lookup) }) ?? nil",
     "DictationFocusedWindow.frame(lookup)", "placement off main", "smoothpins"),
    ("smooth pins: LISTENING before the placement", MD, "            await placing?.value\n", "", "placement off main", "smoothpins"),
    ("smooth pins: the edit watch on the main actor", MD, "task = Task.detached(priority: .utility) { [weak self] in", "task = Task { [weak self] in",
     "edit watch off main", "smoothpins"),
    ("smooth pins: the heartbeat paused by tracking", MD, "RunLoop.main.add(timer, forMode: .common)", "RunLoop.main.add(timer, forMode: .default)", "heartbeat", "smoothpins"),
    ("smooth pins: cancel leaves the heartbeat running", MD, "startMarks = nil; _ = heartbeat.finish(); placing?.cancel(); placing = nil",
     "startMarks = nil; placing?.cancel(); placing = nil", "heartbeat", "smoothpins"),
    ("smooth pins: the stall left off the line", MD, "                startMarks?.mainThreadStallMs = heartbeat.finish()\n", "", "heartbeat", "smoothpins"),
    ("smooth pins: quit does not wait for the unmute", APP, "model.dictation.cancel(); model.dictation.flushAudio();", "model.dictation.cancel();", "quit restores", "smoothpins"),
    ("smooth pins: the pet resizes for the pill", "Sources/SessionPet.swift", "        let dictation = model.dictation\n",
     "        let dictation = model.dictation\n        observers.append(dictation.$pill.sink { _ in })\n", "no resize", "smoothpins"),
    ("smooth pins: an unreviewed detached task", MD, "        spareTask = Task { [weak self] in", "        spareTask = Task.detached { [weak self] in", "census", "smoothpins"),
    ("smooth pins: dictation refusals thrown as command_failed", APP, 'runHelper(["mac-dictation"], timeout: 40, stdinData: audio, answers: true)',
     'runHelper(["mac-dictation"], timeout: 40, stdinData: audio)', "refusal reaches dictation", "smoothpins"),
    ("smooth pins: runHelper drops answers", "Sources/ControllerModel.swift", "try await helper.run(arguments, timeout: timeout, stdinData: stdinData, answers: answers)",
     "try await helper.run(arguments, timeout: timeout, stdinData: stdinData)", "refusal reaches dictation", "smoothpins"),
    # 0.5.329 early polish: the helper core (DictationPolishBridge token, DictationPolishPrewarmBridge) and the wiring pins.
    ("prewarm core: the token key refused", PSC, 'Set(object.keys).isSubset(of: ["text", "model", "app", "prewarmToken"]),',
     'Set(object.keys).isSubset(of: ["text", "model", "app"]),', "prewarm token", "core"),
    ("prewarm core: a malformed token kept", PSC, 'let token = (object["prewarmToken"] as? String).flatMap { DictationPolishPrewarmBridge.isToken($0) ? $0 : nil }',
     'let token = object["prewarmToken"] as? String', "prewarm token", "core"),
    ("prewarm core: the finalize body drops the token", PSC, '        if let token = request.prewarmToken { object["prewarmToken"] = token }\n', "", "prewarm token", "core"),
    ("prewarm core: any prewarm word passes", PSC, 'if let prewarm = body["prewarm"] as? String, prewarmOutcomes.contains(prewarm) { details["prewarm"] = prewarm }',
     'if let prewarm = body["prewarm"] as? String { details["prewarm"] = prewarm }', "prewarm outcome", "core"),
    ("prewarm core: an older server is just an HTTP error", PSC, '        case 404: return refused("unsupported", status: 404)',
     '        case 404: return refused("http_404", status: 404)', "prewarm answer", "core"),
    ("prewarm core: any 409 reason passes", PSC, 'let reason = (body?["reason"] as? String).flatMap { refusalReasons.contains($0) ? $0 : nil } ?? "refused"',
     'let reason = (body?["reason"] as? String) ?? "refused"', "prewarm answer", "core"),
    ("prewarm core: the start takes more keys", PSC, "as? [String: Any], object.count == 1 else { return nil }",
     "as? [String: Any], object.count >= 1 else { return nil }", "prewarm request", "core"),
    ("prewarm core: any string is deleted", PSC, 'static func discardPath(_ token: String) -> String? { isToken(token) ? route + "/" + token : nil }',
     'static func discardPath(_ token: String) -> String? { route + "/" + token }', "prewarm request", "core"),
    ("prewarm core: a bad token answer kept", PSC, '            guard let body, let token = body["token"] as? String, isToken(token), let expires',
     '            guard let body, let token = body["token"] as? String, let expires', "prewarm answer", "core"),
    ("prewarm pins: the press does not start it", MD, "        startPrewarm(attempt)\n", "", "prewarm at press", "polishpins"),
    ("prewarm pins: started on the main actor", MD, "        let task = Task.detached(priority: .utility) {\n            let response = try? await bridge(request)",
     "        let task = Task {\n            let response = try? await bridge(request)", "prewarm off main", "polishpins"),
    ("prewarm pins: AI polish off still starts it", MD, "guard DictationPolishPrewarm.shouldStart(model: model, unsupportedOn: prewarmUnsupportedOn, serverVersion: serverVersion?()),\n              let bridge",
     "guard let bridge", "prewarm off main", "polishpins"),
    ("prewarm pins: the token is not sent", MD, "prewarmToken: warm) else { return nil }", "prewarmToken: nil) else { return nil }", "prewarm token", "polishpins"),
    ("prewarm pins: a token for another model reused", MD, "guard held.attempt == generation, held.model == model else {", "guard held.attempt == generation else {",
     "prewarm token", "polishpins"),
    ("prewarm pins: cancel keeps the token", MD, "placing = nil\n        discardPrewarm()\n", "placing = nil\n", "prewarm discard", "polishpins"),
    ("prewarm pins: finish discards a newer press's token", MD, "        lastEngine = nil; lastPolish = nil\n",
     "        lastEngine = nil; lastPolish = nil\n        discardPrewarm()\n", "prewarm discard", "polishpins"),
    ("prewarm pins: the outcome not recorded", MD,
     '            timing?.polishPrewarm = DictationPolishPrewarm.outcome(sentToken: warm != nil, answer: response.details["prewarm"]?.string)\n', "",
     "prewarm timing", "polishpins"),
    ("prewarm pins: the bridge throws on refusals", "Sources/ControllerModel.swift",
     "return { input in try await helper.run([verb], timeout: timeout, stdinData: input, answers: true) }",
     "return { input in try await helper.run([verb], timeout: timeout, stdinData: input) }", "prewarm off main", "polishpins"),
    ("start pins: STARTING shows level bars", MD, "                Text(pill.label)\n            case .listening(let since):",
     "                liveBars\n                Text(pill.label)\n            case .listening(let since):", "starting pill", "startpins"),
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
    if name == "tailpins":
        return subprocess.run(["python3", str(copy / "Tests/dictation-tail-pins.py"), str(copy)], capture_output=True, text=True)
    if name == "smoothpins":
        return subprocess.run(["python3", str(copy / "Tests/dictation-smooth-pins.py"), str(copy)], capture_output=True, text=True)
    if name == "startpins":
        return subprocess.run(["python3", str(copy / "Tests/dictation-start-pins.py"), str(copy)], capture_output=True, text=True)
    if name == "polishpins":
        return subprocess.run(["python3", str(copy / "Tests/dictation-polish-pins.py"), str(copy)], capture_output=True, text=True)
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
                              ("Tests/transcription-settings-helper-checks.py", [str(copy / "Tests/fixtures/stt-settings-6.72.0.json")]),
                              ("Tests/dictation-polish-helper-checks.py", [])]:
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
