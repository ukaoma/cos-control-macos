import Foundation

// 0.5.317 dictation for everyone: the helper's pure half (HelperSources/ProviderStatusCore.swift) compiled on its own.
// The compatibility gate (which route each server gets), what each answer means and which one action it offers, the
// word error rate against the pinned reference, the engine test's whitelist, and the bundled tool's path rule. No
// server, no audio, no helper binary. Each check names its behaviour for Tests/mutate-dictation-everyone.py.

nonisolated(unsafe) var passes = 0
nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1; return }
    failures += 1
    FileHandle.standardError.write(Data("check failed [\(behaviour)]: \(detail())\n".utf8))
}

@main
struct DictationEveryoneChecks {
    static func main() {
        let reference = CommandLine.arguments.count > 1 ? (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? "" : ""

        // The gate. 6.74.0 keeps desktopDictationVersion 1 (the 0.5.316 helper requires exactly 1) and lists 2.
        let v2: [String: Any] = ["desktopDictationVersion": 1, "desktopDictationVersions": [1, 2], "requiredEngines": ["parakeet-ultra", "local"], "localOnly": true]
        let v1: [String: Any] = ["desktopDictationVersion": 1, "requiredEngines": ["parakeet-ultra"], "localOnly": true]
        check(DictationBridge.route(v2) == "/api/transcribe?mode=fast&requiredEngine=local", "gate local", "a server listing 2 gets requiredEngine=local")
        check(DictationBridge.route(v1) == "/api/transcribe?mode=fast&requiredEngine=parakeet-ultra", "gate old", "a 6.73.14 server keeps the Parakeet-only route")
        check(DictationBridge.route(["desktopDictationVersion": 1, "desktopDictationVersions": [1], "localOnly": true]) == DictationBridge.parakeetRoute, "gate old", "a list without 2 is an old server")
        check(DictationBridge.route(["desktopDictationVersion": 1, "desktopDictationVersions": [1, true], "localOnly": true]) == DictationBridge.parakeetRoute, "gate strict", "a boolean is not version 2")
        check(DictationBridge.route(["desktopDictationVersion": 1, "desktopDictationVersions": ["2"], "localOnly": true]) == DictationBridge.parakeetRoute, "gate strict", "a string is not version 2")
        check(DictationBridge.route(["desktopDictationVersion": 2, "desktopDictationVersions": [2], "localOnly": true]) == nil, "gate refuses", "a server that dropped version 1 gets no audio")
        check(DictationBridge.route(["desktopDictationVersion": 1, "desktopDictationVersions": [1, 2], "localOnly": false]) == nil, "gate refuses", "a server that is not local-only gets no audio")
        check(DictationBridge.route(nil) == nil && DictationBridge.route([:]) == nil, "gate refuses", "no capabilities, no audio")

        // A 200 on the local route: any local engine, with the fallback reason and the setting whitelisted.
        let whisper = DictationBridge.answer(status: 200, body: ["text": "Ask not.", "engine": "whisper", "fallbackReason": "parakeet_warming", "dictationSetting": "auto"], local: true)
        check(whisper.ok && whisper.details["engine"] as? String == "whisper" && whisper.details["text"] as? String == "Ask not.", "local accepts whisper", "\(whisper.details)")
        check(whisper.details["fallbackReason"] as? String == "parakeet_warming" && whisper.details["dictationSetting"] as? String == "auto", "fallback passes", "\(whisper.details)")
        let parakeet = DictationBridge.answer(status: 200, body: ["text": "Ask not.", "engine": "parakeet-ultra"], local: true)
        check(parakeet.ok && parakeet.details["engine"] as? String == "parakeet-ultra" && parakeet.details["fallbackReason"] == nil, "local accepts parakeet", "\(parakeet.details)")
        let sneaky = DictationBridge.answer(status: 200, body: ["text": "x", "engine": "whisper", "fallbackReason": "rm -rf", "dictationSetting": "cloud"], local: true)
        check(sneaky.ok && sneaky.details["fallbackReason"] == nil && sneaky.details["dictationSetting"] == nil, "fallback whitelist", "unknown reason and setting are dropped")
        for engine in ["openai", "cloud", "large-v3", ""] {
            check(!DictationBridge.answer(status: 200, body: ["text": "x", "engine": engine], local: true).ok, "local refuses other engines", engine)
        }
        check(!DictationBridge.answer(status: 200, body: ["text": "", "engine": "whisper"], local: true).ok, "empty refused", "empty text is not a dictation")
        check(!DictationBridge.answer(status: 200, body: ["text": String(repeating: "a", count: 64_001), "engine": "whisper"], local: true).ok, "bounded text", "over 64,000 bytes refused")

        // The old route: exactly 0.5.316. Only parakeet-ultra, and its words.
        check(DictationBridge.answer(status: 200, body: ["text": "x", "engine": "parakeet-ultra"], local: false).ok, "old accepts parakeet", "")
        let oldWhisper = DictationBridge.answer(status: 200, body: ["text": "x", "engine": "whisper"], local: false)
        check(!oldWhisper.ok && oldWhisper.message == "Dictation needs the matched server with Parakeet support. No text was inserted.", "old refuses whisper", oldWhisper.message)
        let old503 = DictationBridge.answer(status: 503, body: ["error": "busy", "reason": "parakeet_unavailable", "action": "install_parakeet"], local: false)
        check(old503.message == "Parakeet is not ready. Check Transcription settings and retry." && old503.details["action"] as? String == "retry", "old words kept", old503.message)

        // 503 on the local route: the server's reason, its sentence, and one action.
        let notInstalled = DictationBridge.answer(status: 503, body: ["error": "Parakeet Ultra is not installed.", "reason": "parakeet_unavailable", "retryable": false, "action": "install_parakeet"], local: true)
        check(!notInstalled.ok && notInstalled.details["action"] as? String == "install_parakeet" && notInstalled.details["retryable"] as? Bool == false, "action install", "\(notInstalled.details)")
        check(notInstalled.message == "Parakeet Ultra is not installed.", "server sentence shown", notInstalled.message)
        let warming = DictationBridge.answer(status: 503, body: ["reason": "parakeet_unavailable", "retryable": true, "action": "retry_when_warm"], local: true)
        check(warming.details["action"] as? String == "retry" && warming.details["retryable"] as? Bool == true, "retry when warm", "\(warming.details)")
        check(warming.message == "Parakeet Ultra is warming up. Try again in a few seconds.", "own words when the server sends none", warming.message)
        let deadRetry = DictationBridge.answer(status: 503, body: ["reason": "no_local_engine", "retryable": false, "action": "retry_when_warm"], local: true)
        check(deadRetry.details["action"] as? String == "open_transcription_settings" && deadRetry.details["retryable"] as? Bool == false, "never a dead retry", "\(deadRetry.details)")
        check(!deadRetry.message.contains("Try again"), "never a dead retry", "the words do not promise a retry: \(deadRetry.message)")
        let starting = DictationBridge.answer(status: 503, body: ["reason": "no_local_engine", "retryable": true, "action": "retry_when_warm", "detail": "whisper_starting"], local: true)
        check(starting.details["detail"] as? String == "whisper_starting" && starting.message == "Whisper is still starting. Try again in a few seconds.", "detail passes", starting.message)
        let noEngine = DictationBridge.answer(status: 503, body: ["reason": "no_local_engine", "retryable": false, "action": "open_transcription_settings", "detail": "whisper_unavailable"], local: true)
        check(noEngine.details["action"] as? String == "open_transcription_settings", "action settings", "\(noEngine.details)")
        let useWhisper = DictationBridge.answer(status: 503, body: ["reason": "parakeet_unavailable", "retryable": false, "action": "use_whisper"], local: true)
        check(useWhisper.details["action"] as? String == "use_whisper", "action use whisper", "\(useWhisper.details)")
        let junk = DictationBridge.answer(status: 503, body: ["reason": "parakeet_unavailable", "action": "format_disk", "error": "line one\nline two", "detail": "bad detail; rm"], local: true)
        check(junk.details["action"] as? String == "open_transcription_settings" && junk.details["detail"] == nil, "action whitelist", "\(junk.details)")
        check(!junk.message.contains("line two"), "one-line sentences only", junk.message)
        let long = DictationBridge.answer(status: 503, body: ["reason": "no_local_engine", "action": "install_parakeet", "error": String(repeating: "x", count: 201)], local: true)
        check(long.message.count <= 200, "bounded sentence", "\(long.message.count)")
        let unknown503 = DictationBridge.answer(status: 503, body: ["error": "SECRET stack", "reason": "maintenance"], local: true)
        check(!unknown503.message.contains("SECRET") && unknown503.details["action"] as? String == "retry", "unknown 503 is a busy server", unknown503.message)
        let bad = DictationBridge.answer(status: 400, body: ["error": "invalid"], local: true)
        check(bad.details["action"] as? String == "open_transcription_settings" && bad.details["retryable"] as? Bool == false, "4xx never retries", "\(bad.details)")
        let quiet = DictationBridge.answer(status: 204, body: nil, local: true)
        check(!quiet.ok && quiet.details["noSpeech"] as? Bool == true && quiet.details["action"] as? String == "none", "no speech", "\(quiet.details)")
        let gone = DictationBridge.answer(status: nil, body: nil, local: true)
        check(!gone.ok && gone.details["action"] as? String == "retry" && gone.details["retryable"] as? Bool == true, "unreachable retries", "\(gone.details)")

        // Word error rate on the pinned sample. Lowercase, punctuation stripped.
        check(VoiceAccuracy.words("And so, my fellow Americans!") == ["and", "so", "my", "fellow", "americans"], "wer words", "\(VoiceAccuracy.words("And so, my fellow Americans!"))")
        check(VoiceAccuracy.words("you'll 'quoted'") == ["you'll", "quoted"], "wer apostrophes", "\(VoiceAccuracy.words("you'll 'quoted'"))")
        check(VoiceAccuracy.errors(reference: ["a", "b", "c"], hypothesis: ["a", "x", "c", "d"]) == 2, "wer distance", "one substitution and one insertion")
        check(VoiceAccuracy.errors(reference: ["a", "b", "c"], hypothesis: ["a", "c"]) == 1, "wer distance", "one deletion")
        check(VoiceAccuracy.errors(reference: [], hypothesis: ["a"]) == 1 && VoiceAccuracy.errors(reference: ["a"], hypothesis: []) == 1, "wer distance", "empty sides")
        check(VoiceAccuracy.wordErrorRate(reference: "", hypothesis: "x") == nil, "wer no reference", "nothing to score against")
        check(!reference.isEmpty, "reference pinned", "Resources/VoiceBenchmark/speech-30s.txt is readable")
        check(VoiceAccuracy.words(reference).count == VoiceAccuracy.referenceWords, "reference pinned", "\(VoiceAccuracy.words(reference).count) words, pinned \(VoiceAccuracy.referenceWords)")
        let turbo = "And so my fellow Americans, ask not what your country can do for you. Ask what you can do for your country. And so my fellow Americans, ask not what your country can do for you. Ask what you can do for your country. And so my fellow Americans, ask not what your country can do for you."
        check(VoiceAccuracy.wordErrorRate(reference: reference, hypothesis: turbo) == 0, "wer exact", "Turbo's transcript of the sample scores 0 (punctuation does not count)")
        let oneOff = turbo.replacingOccurrences(of: "fellow", with: "yellow")
        check(abs((VoiceAccuracy.wordErrorRate(reference: reference, hypothesis: oneOff) ?? 0) - 3.0 / 58.0) < 1e-9, "wer exact", "three substitutions of 58")

        // The engine test: whitelisted rows, WER on the raw text, memory never invented for Whisper.
        let rows = DictationBenchmark.results(["audioSeconds": 30, "results": [
            ["engine": "whisper", "model": "large-v3-turbo", "ran": true, "elapsedMs": 2400, "rtf": 0.08, "peakRssBytes": NSNull(), "text": turbo],
            ["engine": "parakeet-ultra", "model": "ultra", "ran": true, "elapsedMs": 900, "rtf": 0.03, "peakRssBytes": 1_200_000_000, "warmupMs": 14_000, "text": oneOff],
            ["engine": "openai", "ran": true, "text": "x"],
            ["engine": "whisper", "ran": false, "skipped": "format_disk"],
        ]], reference: reference) ?? []
        check(rows.count == 3 && rows.allSatisfy { ["whisper", "parakeet-ultra"].contains($0["engine"] as? String ?? "") }, "benchmark whitelist", "\(rows.count) rows")
        check((rows[0]["wer"] as? Double) == 0 && rows[0]["peakRssBytes"] is NSNull && rows[0]["text"] == nil, "benchmark whisper", "\(rows[0])")
        check(abs((rows[1]["wer"] as? Double ?? 1) - 3.0 / 58.0) < 1e-9 && (rows[1]["peakRssBytes"] as? NSNumber)?.int64Value == 1_200_000_000 && (rows[1]["warmupMs"] as? NSNumber)?.doubleValue == 14_000, "benchmark parakeet", "\(rows[1])")
        check(rows[2]["skipped"] as? String == "unavailable" && rows[2]["wer"] is NSNull, "benchmark skipped", "an unknown skip reads unavailable, unscored")
        check(DictationBenchmark.results(["results": "nope"], reference: reference) == nil, "benchmark shape", "a non-list is not an answer")

        // The bundled tool's path: absolute, inside an app's Contents/Helpers, executable, no dot segments.
        let yes: (String) -> Bool = { _ in true }
        check(ParakeetCLIPath.valid("/Applications/COS Control.app/Contents/Helpers/fluidaudiocli", isExecutable: yes), "cli path", "the installed app's copy")
        check(!ParakeetCLIPath.valid("/tmp/fluidaudiocli", isExecutable: yes), "cli path", "anywhere else is refused")
        check(!ParakeetCLIPath.valid("/Applications/COS Control.app/Contents/Helpers/fluidaudiocli-0.17.4", isExecutable: yes)
              && !ParakeetCLIPath.valid("/Applications/COS Control.app/Contents/Helpers/xfluidaudiocli", isExecutable: yes), "cli path", "the file name is exactly fluidaudiocli (the server 400s anything else)")
        check(!ParakeetCLIPath.valid("Applications/X.app/Contents/Helpers/fluidaudiocli", isExecutable: yes), "cli path", "relative is refused")
        check(!ParakeetCLIPath.valid("/Applications/X.app/Contents/Helpers/../../../tmp/Contents/Helpers/fluidaudiocli", isExecutable: yes), "cli path", "dot segments are refused")
        check(!ParakeetCLIPath.valid("/Applications/COS Control.app/Contents/Helpers/fluidaudiocli", isExecutable: { _ in false }), "cli path", "a missing or non-executable file is refused")

        // 0.5.318: the Voice row's check sends ONE 11 s utterance; the server drops the 30 s sample's repeat as a loop.
        let sampleURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "")
            .deletingLastPathComponent().appendingPathComponent("speech-30s.wav")
        if let wav = try? Data(contentsOf: sampleURL), let one = DictationCheckSample.singleUtterance(wav) {
            let b = [UInt8](one)
            func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
            check(one.count == 44 + 352_000, "check sample", "exactly 11 s of 16 kHz mono 16-bit audio after the header")
            check(u32(4) == 36 + 352_000 && u32(40) == 352_000, "check sample", "the RIFF and data sizes describe the cut, not the 30 s file")
            check(one.prefix(4) == wav.prefix(4) && one.subdata(in: 8..<36) == wav.subdata(in: 8..<36), "check sample", "format chunk unchanged")
            check(one.suffix(352_000) == wav.subdata(in: 44..<(44 + 352_000)), "check sample", "the first utterance, from its first sample")
            check(wav.subdata(in: (44 + 352_000)..<(44 + 704_000)) == one.suffix(352_000), "check sample", "the 30 s sample really repeats it (why one copy)")
        } else { check(false, "check sample", "the pinned sample cuts to one utterance") }
        if var stereo = try? Data(contentsOf: sampleURL) {
            stereo[22] = 2
            check(DictationCheckSample.singleUtterance(stereo) == nil, "check sample", "any other layout fails closed (stereo)")
        }
        check(DictationCheckSample.singleUtterance(Data("RIFF".utf8) + Data(count: 100)) == nil, "check sample", "a short or broken file fails closed")
        check(DictationCheckSample.reference(reference) == "and so my fellow americans ask not what your country can do for you ask what you can do for your country",
              "check sample", "the reference is the first copy's 22 words")
        check(VoiceAccuracy.wordErrorRate(reference: DictationCheckSample.reference(reference),
              hypothesis: "And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.") == 0,
              "check sample", "a correct single utterance scores 0")

        // 0.5.325 AI polish: the helper's dictation-polish, pure half. The request it accepts, the body it posts, and
        // what each finalize answer means. A failure never carries text.
        typealias PB = DictationPolishBridge
        func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
        check(PB.parse(json(["text": "um hi", "model": "haiku", "app": " iTerm2 "])) == .init(text: "um hi", model: "haiku", app: "iTerm2"), "polish parse", "text, model and a trimmed app")
        check(PB.parse(json(["text": "um hi", "model": "sonnet"])) == .init(text: "um hi", model: "sonnet", app: nil), "polish parse", "app is optional")
        check(PB.parse(json(["text": "um hi", "model": "haiku", "app": String(repeating: "A", count: 65)]))?.app == nil
              && PB.parse(json(["text": "um hi", "model": "haiku", "app": "a\nb"]))?.app == nil
              && PB.parse(json(["text": "um hi", "model": "haiku", "app": 7]))?.app == nil, "polish app dropped", "an unusable app name is dropped, the polish still runs")
        for model in ["opus", "", "Haiku", "off"] {
            check(PB.parse(json(["text": "um hi", "model": model])) == nil, "polish model", "only haiku or sonnet: \(model)")
        }
        check(PB.parse(json(["text": "  \n", "model": "haiku"])) == nil && PB.parse(json(["model": "haiku"])) == nil
              && PB.parse(json(["text": 5, "model": "haiku"])) == nil, "polish text", "blank, missing or non-string text is refused")
        check(PB.parse(json(["text": String(repeating: "a", count: 8_000), "model": "haiku"])) != nil
              && PB.parse(json(["text": String(repeating: "a", count: 8_001), "model": "haiku"])) == nil
              && PB.parse(json(["text": String(repeating: "😀", count: 4_001), "model": "haiku"])) == nil, "polish limit", "8,000 UTF-16 units, the server's 413 limit")
        check(PB.parse(json(["text": "um hi", "model": "haiku", "surface": "email"])) == nil, "polish keys", "only text, model and app")
        check(PB.parse(Data("not json".utf8)) == nil && PB.parse(Data(count: PB.inputLimit + 1)) == nil, "polish parse", "not JSON or too large")
        check(PB.requestSeconds("haiku") == 4.5 && PB.requestSeconds("sonnet") == 8.5 && PB.requestSeconds("opus") == nil,
              "polish deadline", "half a second inside Control's 5 s and 9 s")
        let sent = (try? JSONSerialization.jsonObject(with: Data(PB.body(.init(text: "um hi", model: "sonnet", app: "Claude")).utf8))) as? [String: Any] ?? [:]
        check(sent["text"] as? String == "um hi" && sent["surface"] as? String == "message" && sent["autocleanModel"] as? String == "sonnet"
              && (sent["context"] as? [String: String]) == ["app": "Claude"] && sent.count == 4, "polish body", "the finalize contract, with the app as context")
        let bare = (try? JSONSerialization.jsonObject(with: Data(PB.body(.init(text: "x", model: "haiku", app: nil)).utf8))) as? [String: Any] ?? [:]
        check(bare.count == 3 && bare["context"] == nil, "polish body", "no context without an app")
        let good = PB.answer(status: 200, body: ["text": "So hi.", "surface": "message", "polished": true], model: "haiku", elapsedMs: 2300, timedOut: false)
        check(good.ok && good.details["text"] as? String == "So hi." && good.details["polished"] as? Bool == true
              && good.details["model"] as? String == "haiku" && good.details["elapsedMs"] as? Int == 2300, "polish answer", "a polished answer passes with its time")
        let fallback = PB.answer(status: 200, body: ["text": "um hi", "polished": false], model: "haiku", elapsedMs: 900, timedOut: false)
        check(fallback.ok && fallback.details["polished"] as? Bool == false, "polish answer", "the server's dictionary-only answer says polished false")
        check(good.details["polishSkipped"] == nil && fallback.details["polishSkipped"] == nil, "polish skipped", "no polishSkipped from the server, none passed on")
        // 0.5.328 (server 6.79.1): why the model did not polish, passed on only as one of five codes.
        for code in ["daily_cap", "breaker_open", "too_long", "disabled", "failed"] {
            let skipped = PB.answer(status: 200, body: ["text": "um hi", "polished": false, "polishSkipped": code], model: "haiku", elapsedMs: 4, timedOut: false)
            check(skipped.ok && skipped.details["polishSkipped"] as? String == code && skipped.details["polished"] as? Bool == false, "polish skipped", "\(code) is passed on")
        }
        let fillers = PB.answer(status: 200, body: ["text": "So hi.", "polished": true, "polishSkipped": "daily_cap"], model: "sonnet", elapsedMs: 4, timedOut: false)
        check(fillers.ok && fillers.details["polished"] as? Bool == true && fillers.details["polishSkipped"] as? String == "daily_cap",
              "polish skipped", "polished true with a skip code (only the filler pass ran) keeps both")
        for odd: Any in ["Daily Cap", "quota_exceeded", "daily_cap; rm", 1, true, ["daily_cap"]] {
            let answer = PB.answer(status: 200, body: ["text": "um hi", "polished": false, "polishSkipped": odd], model: "haiku", elapsedMs: 4, timedOut: false)
            check(answer.ok && answer.details["polishSkipped"] == nil, "polish skipped whitelist", "\(odd) is not one of the five codes and is dropped")
        }
        // 0.5.329 (server 6.79.2): clean is a skip code too; the token rides on finalize; what became of it comes back.
        let clean = PB.answer(status: 200, body: ["text": "um hi", "polished": false, "polishSkipped": "clean"], model: "haiku", elapsedMs: 4, timedOut: false)
        check(clean.details["polishSkipped"] as? String == "clean", "polish skipped", "clean is passed on")
        // 0.5.334 (server 6.84.0): link_guard, the server refused an answer with a link nobody said.
        let guarded = PB.answer(status: 200, body: ["text": "go to /pricing", "polished": true, "polishSkipped": "link_guard"], model: "haiku", elapsedMs: 4, timedOut: false)
        check(guarded.ok && guarded.details["polishSkipped"] as? String == "link_guard" && guarded.details["polished"] as? Bool == true,
              "polish skipped link_guard", "link_guard is passed on with polished, so Control can say it was not Claude's polish")
        // 0.5.344 (server 6.91.0, plan r2Answer contract): the model step, the guard, the register and the learned style, each passed
        // on only from its closed styleSet (or 8 hex characters). Fictional values only.
        let r2Answer = PB.answer(status: 200, body: ["text": "So hi.", "polished": true, "polishOutcome": "unchanged", "guard": "number", "polishRegister": "literal", "polishPrompt": "v4",
                                              "learnedStyle": true, "learnedStyleHash": "0a1b2c3d"], model: "haiku", elapsedMs: 4, timedOut: false)
        check(r2Answer.details["polishOutcome"] as? String == "unchanged", "polish outcome set", "polishOutcome is passed on")
        check(r2Answer.details["guard"] as? String == "number", "polish guard set", "guard is passed on")
        check(r2Answer.details["polishRegister"] as? String == "literal", "polish register set", "polishRegister is passed on")
        check(r2Answer.details["polishPrompt"] as? String == "v4", "polish prompt set", "polishPrompt is passed on")
        check(r2Answer.details["learnedStyle"] as? Bool == true && r2Answer.details["learnedStyleHash"] as? String == "0a1b2c3d", "polish learned style", "the flag and its hash")
        check(PB.polishOutcomes == ["polished", "unchanged", "guarded"] && PB.guardKinds == ["negation", "number", "date", "name", "link", "literal"]
              && PB.registers == ["literal", "default"] && PB.prompts == ["v3", "v4"], "polish r2 sets", "the contract's closed sets")
        for (key, odd) in [("polishOutcome", "great" as Any), ("polishOutcome", 1), ("guard", "tone"), ("guard", true), ("polishRegister", "chat"), ("polishPrompt", "v5"), ("polishPrompt", "V4"), ("polishPrompt", 4),
                           ("learnedStyle", 1), ("learnedStyle", "true"), ("learnedStyleHash", "0A1B2C3D"), ("learnedStyleHash", "0a1b2c3"), ("learnedStyleHash", 12345678)] {
            let r2Odd = PB.answer(status: 200, body: ["text": "So hi.", "polished": true, key: odd], model: "haiku", elapsedMs: 4, timedOut: false)
            let r2Behaviour = key == "polishOutcome" ? "polish outcome set" : key == "guard" ? "polish guard set" : key == "polishRegister" ? "polish register set" : key == "polishPrompt" ? "polish prompt set" : "polish learned style"
            check(r2Odd.ok && r2Odd.details[key] == nil, r2Behaviour, "\(key)=\(odd) is not in its set and is dropped")
        }
        check(PB.parse(json(["text": "um hi", "model": "haiku", "polishOutcome": "unchanged"])) == nil, "polish keys", "the stdin allowlist is unchanged")

        // 0.5.344: the learned-style route (strict rules, codes only) and Previous polish.
        typealias LS = DictationLearnedStyleBridge
        let styleRule: [String: Any] = ["id": "drop-honestly", "kind": "drop_phrase", "register": "all", "param": "honestly", "count": 2, "lastSeen": "2026-10-24T22:00:00.000Z"]
        let styleContraction: [String: Any] = ["id": "contractions", "kind": "contractions", "register": "all", "param": "use", "count": 3, "lastSeen": "2026-10-24T22:00:00Z"]
        check(LS.rule(styleRule) == LS.Rule(id: "drop-honestly", kind: "drop_phrase", register: "all", param: "honestly", count: 2, lastSeen: "2026-10-24T22:00:00.000Z")
              && LS.rule(styleContraction) != nil, "learned style rule", "a drop_phrase and a contractions rule")
        for (key, odd) in [("kind", "tone" as Any), ("register", "chat"), ("param", "Honestly"), ("param", "drop; rm"), ("id", "Drop Honestly"), ("count", -1),
                           ("count", true), ("count", 1.5), ("lastSeen", "yesterday"), ("extra", "x")] {
            var styleBad = styleRule; styleBad[key] = odd
            let r2Behaviour = key == "kind" ? "learned style kinds" : key == "register" ? "learned style register" : key == "param" ? "learned style param" : "learned style rule"
            check(LS.rule(styleBad) == nil, r2Behaviour, "\(key)=\(odd) is refused")
        }
        var styleTone = styleContraction; styleTone["kind"] = "tone"
        check(LS.rule(styleTone) == nil, "learned style kinds", "an unknown kind is refused even with a param another kind takes")
        var styleWrongParam = styleContraction; styleWrongParam["param"] = "honestly"
        check(LS.rule(styleWrongParam) == nil, "learned style param", "contractions take use or avoid only")
        check(LS.parse(json(["operation": "get"])) == .get && LS.parse(json(["operation": "clear"])) == .clear
              && LS.parse(json(["operation": "get", "x": 1])) == nil, "learned style parse", "get and clear take nothing else")
        let styleSet = LS.parse(json(["operation": "set", "rules": [styleRule, styleContraction], "enabled": true, "baseHash": "0a1b2c3d"]))
        check(styleSet == .set(rules: [LS.rule(styleRule)!, LS.rule(styleContraction)!], enabled: true, baseHash: "0a1b2c3d"), "learned style parse", "set with its rules")
        check(LS.parse(json(["operation": "set", "rules": [styleRule, styleRule]])) == nil && LS.parse(json(["operation": "set", "rules": Array(repeating: styleRule, count: 21)])) == nil
              && LS.parse(json(["operation": "set", "rules": [styleRule], "text": "x"])) == nil && LS.parse(json(["operation": "set", "rules": [styleRule], "hash": "0a1b2c3d"])) == nil
              && LS.parse(json(["operation": "set", "rules": [styleRule], "enabled": 1])) == nil && LS.parse(json(["operation": "set", "rules": [styleRule], "baseHash": "nope"])) == nil,
              "learned style parse", "no duplicate ids, at most 20, never text or a hash of the client's own")
        let styleBody = (try? JSONSerialization.jsonObject(with: Data(LS.body(rules: [LS.rule(styleRule)!], enabled: nil, baseHash: "0a1b2c3d").utf8))) as? [String: Any] ?? [:]
        check(Set(styleBody.keys) == ["rules", "baseHash"] && (styleBody["rules"] as? [[String: Any]])?.first?["param"] as? String == "honestly", "learned style body", "rules and baseHash only")
        let styleHealth: [String: Any] = ["capabilities": ["dictationCleanup": ["learnedStyle": ["protocol": 1, "maxChars": 1500, "maxRules": 20, "enabled": false],
                                                                          "polishOptions": ["protocol": 1]]]]
        check(LS.advertised(styleHealth) == LS.Capability(maxChars: 1500, maxRules: 20, enabled: false), "learned style capability", "protocol 1 with its caps and switch")
        check(LS.advertised(["capabilities": ["dictationCleanup": ["learnedStyle": ["protocol": 2, "maxChars": 1500, "maxRules": 20]]]]) == nil
              && LS.advertised(["capabilities": ["dictationCleanup": ["learnedStyle": ["protocol": true, "maxChars": 1500, "maxRules": 20]]]]) == nil
              && LS.advertised(["capabilities": ["dictationCleanup": ["customInstructions": ["protocol": 1, "maxChars": 1000]]]]) == nil && LS.advertised(nil) == nil,
              "learned style capability", "only protocol 1, never a boolean, absent on an older server")
        check(DictationPolishOptionsBridge.advertised(styleHealth) && !DictationPolishOptionsBridge.advertised(["capabilities": ["dictationCleanup": [:]]])
              && !DictationPolishOptionsBridge.advertised(["capabilities": ["dictationCleanup": ["polishOptions": ["protocol": 2]]]]), "polish options capability", "protocol 1 only")
        let styleGot = LS.answer(status: 200, body: ["enabled": true, "rules": [styleRule, ["id": "x", "kind": "tone"]], "text": "Drop the filler \"honestly\".", "hash": "0a1b2c3d",
                                              "updatedAt": "2026-10-24T22:00:00.000Z", "registers": ["iTerm2": "literal", "Odd": "chat"], "kinds": ["drop_phrase", "tone"],
                                              "allowlist": ["honestly", "Literally"]], operation: "get")
        check(styleGot.ok && (styleGot.details["rules"] as? [[String: Any]])?.count == 1 && styleGot.details["hash"] as? String == "0a1b2c3d"
              && styleGot.details["registers"] as? [String: String] == ["iTerm2": "literal"] && styleGot.details["kinds"] as? [String] == ["drop_phrase"]
              && styleGot.details["allowlist"] as? [String] == ["honestly"], "learned style answer", "each field from its closed set")
        check(!LS.answer(status: 200, body: ["rules": [], "text": String(repeating: "x", count: 1_501)], operation: "get").ok, "learned style answer", "text over the cap is unreadable")
        check(LS.answer(status: 409, body: nil, operation: "set").details["reason"] as? String == "conflict"
              && LS.answer(status: 413, body: nil, operation: "set").details["reason"] as? String == "too_long"
              && LS.answer(status: 404, body: nil, operation: "get").details["available"] as? Bool == false, "learned style statuses", "409 conflict, 413 too long, 404 unavailable")
        // 0.5.344 part 2: the server's real contract (6.91.0 at 31c59dd).
        var styleNull = styleRule; styleNull["lastSeen"] = NSNull(); styleNull.removeValue(forKey: "count")
        check(LS.rule(styleNull) == LS.Rule(id: "drop-honestly", kind: "drop_phrase", register: "all", param: "honestly", count: 0, lastSeen: nil),
              "learned style rule", "lastSeen null and count absent read as never and 0")
        check(LS.parse(json(["operation": "set", "enabled": false])) == .set(rules: nil, enabled: false, baseHash: nil)
              && LS.parse(json(["operation": "set", "enabled": true, "baseHash": ""])) == .set(rules: nil, enabled: true, baseHash: "")
              && LS.parse(json(["operation": "set"])) == nil && LS.parse(json(["operation": "set", "baseHash": "0a1b2c3d"])) == nil,
              "learned style switch", "the switch alone, an empty base hash, never an empty set")
        let switchBody = (try? JSONSerialization.jsonObject(with: Data(LS.body(rules: nil, enabled: false, baseHash: nil).utf8))) as? [String: Any] ?? [:]
        check(Set(switchBody.keys) == ["enabled"] && switchBody["enabled"] as? Bool == false, "learned style switch", "Off sends only enabled, so the rules stay")
        let styleAllowlist = ["honestly", "literally", "pretty much", "i guess", "to be honest", "frankly", "obviously", "kinda", "sorta", "you see",
                              "at the end of the day", "if that makes sense"]
        let styleReal = LS.answer(status: 200, body: ["rules": [styleNull], "text": "", "hash": "", "registerValues": ["all", "chat"], "contractionParams": ["use", "avoid", "maybe"],
                                                     "appliesTo": ["message", "meeting", "email"], "maxChars": 1500, "maxRules": 20, "serverEnabled": true,
                                                     "registersEnabled": false, "allowlist": styleAllowlist], operation: "get")
        check(styleReal.ok && (styleReal.details["rules"] as? [[String: Any]])?.count == 1 && styleReal.details["allowlist"] as? [String] == styleAllowlist,
              "learned style real get", "a null lastSeen rule and the full 12-phrase allowlist")
        check(styleReal.details["registerValues"] as? [String] == ["all"] && styleReal.details["contractionParams"] as? [String] == ["use", "avoid"]
              && styleReal.details["appliesTo"] as? [String] == ["message", "meeting"] && styleReal.details["maxChars"] as? Int == 1500
              && styleReal.details["maxRules"] as? Int == 20 && styleReal.details["serverEnabled"] as? Bool == true
              && styleReal.details["registersEnabled"] as? Bool == false, "learned style real get", "each new field from its closed set")
        check(LS.answer(status: 200, body: ["rules": [], "text": "", "maxRules": true, "registersEnabled": "no"], operation: "get").details["maxRules"] == nil
              && LS.answer(status: 200, body: ["rules": [], "text": "", "registersEnabled": "no"], operation: "get").details["registersEnabled"] == nil,
              "learned style real get", "a boolean is no limit and a string is no switch")
        check(LS.answer(status: 409, body: ["hash": "12345678"], operation: "set").details["serverHash"] as? String == "12345678"
              && LS.answer(status: 409, body: ["hash": ""], operation: "set").details["serverHash"] as? String == ""
              && LS.answer(status: 409, body: ["hash": "../x"], operation: "set").details["serverHash"] == nil, "learned style conflict hash",
              "a 409 passes on the server's hash, empty or 8 hex, nothing else")
        typealias PO = DictationPolishOptionsBridge
        check(PO.parse(json(["operation": "get"])) == .get && PO.parse(json(["operation": "set", "promptVersion": "v3"])) == .set("v3")
              && PO.parse(json(["operation": "set", "promptVersion": "v4"])) == nil && PO.parse(json(["operation": "set", "promptVersion": "v3", "x": 1])) == nil,
              "polish options parse", "default or v3 only")
        check(PO.answer(status: 200, body: ["promptVersion": "default"], operation: "get").details["promptVersion"] as? String == "default"
              && !PO.answer(status: 200, body: ["promptVersion": "v9"], operation: "get").ok, "polish options answer", "only default or v3 comes back")
        let warmToken = "0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d"
        let withToken = PB.parse(Data(#"{"text":"um hi","model":"haiku","prewarmToken":"\#(warmToken)"}"#.utf8))
        check(withToken?.prewarmToken == warmToken && withToken?.text == "um hi", "prewarm token", "a real token is accepted with the text")
        for odd in [#""NOT-A-TOKEN""#, #""../../x""#, "7", "true", #""0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D""#] {
            let parsed = PB.parse(Data(#"{"text":"um hi","model":"haiku","prewarmToken":\#(odd)}"#.utf8))
            check(parsed != nil && parsed?.prewarmToken == nil, "prewarm token", "a malformed token (\(odd)) is dropped, never a reason to refuse the polish")
        }
        check(PB.parse(Data(#"{"text":"um hi","model":"haiku","prewarmToken":"\#(warmToken)","extra":1}"#.utf8)) == nil, "prewarm token",
              "an unknown key is still refused")
        let sentWarm = (try? JSONSerialization.jsonObject(with: Data(PB.body(.init(text: "um hi", model: "haiku", app: nil, prewarmToken: warmToken)).utf8))) as? [String: Any] ?? [:]
        check(sentWarm["prewarmToken"] as? String == warmToken && sentWarm.count == 4, "prewarm token", "the finalize body carries the token when there is one")
        check(bare["prewarmToken"] == nil, "prewarm token", "and not when there is none")
        for outcome in ["used", "missed", "discarded"] {
            let a = PB.answer(status: 200, body: ["text": "So hi.", "polished": true, "prewarm": outcome], model: "haiku", elapsedMs: 4, timedOut: false)
            check(a.ok && a.details["prewarm"] as? String == outcome, "prewarm outcome", "\(outcome) is passed on")
        }
        for odd: Any in ["Used", "warm", 1, true] {
            let a = PB.answer(status: 200, body: ["text": "So hi.", "polished": true, "prewarm": odd], model: "haiku", elapsedMs: 4, timedOut: false)
            check(a.ok && a.details["prewarm"] == nil, "prewarm outcome", "\(odd) is not one of used, missed, discarded and is dropped")
        }
        typealias PW = DictationPolishPrewarmBridge
        check(PW.parse(Data(#"{"model":"haiku"}"#.utf8)) == .start(model: "haiku") && PW.parse(Data(#"{"model":"sonnet"}"#.utf8)) == .start(model: "sonnet")
              && PW.parse(Data(#"{"discard":"\#(warmToken)"}"#.utf8)) == .discard(token: warmToken), "prewarm request", "a model starts one; a token discards one")
        for bad in [#"{"model":"opus"}"#, #"{"model":"haiku","text":"um hi"}"#, #"{"discard":"../x"}"#, #"{}"#, "not json", #"{"model":"haiku","discard":"\#(warmToken)"}"#] {
            check(PW.parse(Data(bad.utf8)) == nil, "prewarm request", "refused before the network: \(bad)")
        }
        check(PW.parse(Data(repeating: 32, count: 300)) == nil, "prewarm request", "over 256 bytes is refused")
        let startBody = (try? JSONSerialization.jsonObject(with: Data(PW.body(model: "sonnet").utf8))) as? [String: String] ?? [:]
        check(startBody == ["model": "sonnet", "surface": "message"], "prewarm request", "the server's prewarm body: the model and the message surface, nothing else")
        check(PW.discardPath(warmToken) == "/api/dictation/polish/prewarm/" + warmToken && PW.discardPath("../../x") == nil, "prewarm request",
              "a discard deletes that token's path, and only a token's")
        let warm = PW.answer(status: 200, body: ["token": warmToken, "expiresMs": 150_000], elapsedMs: 120, timedOut: false)
        check(warm.ok && warm.details["prewarmToken"] as? String == warmToken && warm.details["expiresMs"] as? Int == 150_000 && warm.details["elapsedMs"] as? Int == 120,
              "prewarm answer", "a started process comes back as its token, lifetime and time")
        for body: [String: Any]? in [nil, [:], ["token": "nope", "expiresMs": 1], ["token": warmToken], ["token": warmToken, "expiresMs": true], ["token": warmToken, "expiresMs": 0]] {
            let a = PW.answer(status: 200, body: body, elapsedMs: 1, timedOut: false)
            check(!a.ok && a.details["reason"] as? String == "bad_answer" && a.details["prewarmToken"] == nil, "prewarm answer", "an unreadable 200 is bad_answer: \(String(describing: body))")
        }
        for reason in ["disabled", "model", "breaker_open", "daily_cap", "cli"] {
            let a = PW.answer(status: 409, body: ["error": "prewarm_unavailable", "reason": reason], elapsedMs: 3, timedOut: false)
            check(!a.ok && a.details["reason"] as? String == reason, "prewarm answer", "409 \(reason) is passed on")
        }
        check(PW.answer(status: 409, body: ["reason": "whatever words"], elapsedMs: 3, timedOut: false).details["reason"] as? String == "refused"
              && PW.answer(status: 404, body: nil, elapsedMs: 3, timedOut: false).details["reason"] as? String == "unsupported"
              && PW.answer(status: nil, body: nil, elapsedMs: 2_000, timedOut: true).details["reason"] as? String == "timeout"
              && PW.answer(status: nil, body: nil, elapsedMs: 3, timedOut: false).details["reason"] as? String == "unreachable"
              && PW.answer(status: 500, body: nil, elapsedMs: 3, timedOut: false).details["reason"] as? String == "http_500",
              "prewarm answer", "an unknown 409 reason is refused; 404 is unsupported (an older server); no answer is a timeout or unreachable")
        check(PW.discardAnswer(status: 200, body: ["discarded": true]).details["discarded"] as? Bool == true
              && PW.discardAnswer(status: 200, body: ["discarded": false]).ok
              && PW.discardAnswer(status: 404, body: nil).details["reason"] as? String == "unsupported"
              && !PW.discardAnswer(status: 200, body: ["discarded": 1]).ok, "prewarm discard", "a discard reads only the server's boolean")
        for body: [String: Any]? in [nil, [:], ["text": "", "polished": true], ["text": "x"], ["text": "x", "polished": 1], ["text": "x", "polished": "true"],
                                     ["text": String(repeating: "a", count: 16_001), "polished": true], ["text": 4, "polished": true]] {
            let answer = PB.answer(status: 200, body: body, model: "haiku", elapsedMs: 1, timedOut: false)
            check(!answer.ok && answer.details["reason"] as? String == "bad_answer" && answer.details["text"] == nil, "polish bad answer", "\(String(describing: body))")
        }
        let late = PB.answer(status: nil, body: nil, model: "sonnet", elapsedMs: 8_500, timedOut: true)
        check(!late.ok && late.details["reason"] as? String == "timeout", "polish timeout", "no answer by the deadline is a timeout")
        let polishGone = PB.answer(status: nil, body: nil, model: "sonnet", elapsedMs: 3, timedOut: false)
        check(!polishGone.ok && polishGone.details["reason"] as? String == "unreachable", "polish unreachable", "no answer before the deadline is an unreachable server")
        for (status, reason) in [(404, "needs_server_update"), (413, "too_long"), (401, "unauthorized"), (403, "unauthorized"), (429, "busy"), (500, "http_500"), (400, "http_400")] {
            let answer = PB.answer(status: status, body: ["text": "private words", "polished": true], model: "haiku", elapsedMs: 5, timedOut: false)
            check(!answer.ok && answer.details["reason"] as? String == reason && answer.details["httpStatus"] as? Int == status
                  && answer.details["text"] == nil && !answer.message.contains("private words"), "polish http", "\(status) is \(reason), with no text")
        }
        for answer in [late, polishGone, PB.answer(status: 404, body: nil, model: "haiku", elapsedMs: 1, timedOut: false)] {
            check(!answer.message.contains("\u{2014}") && !answer.message.contains("\u{2192}") && answer.message.hasSuffix("COS pastes what it heard."),
                  "polish copy", answer.message)
        }

        // Copy the card may show: no em dash, arrow or eyebrow-style caps.
        for line in [DictationBridge.refusalLine(reason: "parakeet_unavailable", action: "install_parakeet", detail: nil),
                     DictationBridge.refusalLine(reason: "parakeet_unavailable", action: "retry", detail: nil),
                     DictationBridge.refusalLine(reason: "parakeet_unavailable", action: "use_whisper", detail: nil),
                     DictationBridge.refusalLine(reason: "no_local_engine", action: "retry", detail: "whisper_starting"),
                     DictationBridge.refusalLine(reason: "no_local_engine", action: "install_parakeet", detail: nil),
                     DictationBridge.refusalLine(reason: "no_local_engine", action: "open_transcription_settings", detail: nil)] {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains("->") && line != line.uppercased(), "copy", line)
        }

        if failures > 0 { print("FAIL dictation for everyone (helper core): \(failures) failed, \(passes) passed"); exit(1) }
        print("PASS dictation for everyone (helper core) checks: \(passes) passed")
    }
}
