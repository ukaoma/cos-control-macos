import Foundation

/// 0.5.322: the Live cues switch in Settings (LiveCues and LiveCuesStore in Sources/MeetingAskCore.swift), executed.
/// Compiled against MeetingAskCore.swift, LiveTranscript.swift and Models.swift alone by Tests/run-live-cues.sh, with a
/// stand-in for the helper: no helper binary, no server, no window. Prints "live cues checks: N passed".
@main struct LiveCuesChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("live cues check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    /// The helper's details, through the same JSON round trip the app's HelperResponse takes.
    static func details(_ json: String) -> [String: JSONValue] {
        let wrapped = #"{"ok":true,"message":"x","details":"# + json + "}"
        return try! JSONDecoder().decode(HelperResponse.self, from: Data(wrapped.utf8)).details
    }
    static func answered(_ status: Int, _ body: String = "") -> [String: JSONValue] {
        details(#"{"transport":"answered","httpStatus":"# + "\(status)" + (body.isEmpty ? "" : "," + body) + "}")
    }
    static func shape(enabled: Bool, source: String = "setting", available: Bool, reason: String? = nil,
                      model: String = "claude-sonnet-5-5", memory: String = "notes", provider: String? = nil) -> String {
        let why = reason.map { ",\"reason\":\"\($0)\"" } ?? ""
        let decision = provider.map { ",\"decisionProvider\":\"\($0)\"" } ?? ""
        return #""enabled":\#(enabled),"source":"\#(source)","capability":{"available":\#(available)\#(why)\#(decision),"protocol":2,"model":"\#(model)","memory":"\#(memory)"}"#
    }
    static func loaded(_ d: [String: JSONValue]) -> LiveCuesSettings? {
        if case .loaded(let settings) = LiveCues.state(d) { settings } else { nil }
    }

    @MainActor static func main() async {
        typealias S = LiveCues.State
        func line(_ d: [String: JSONValue]) -> String { LiveCues.line(LiveCues.state(d)) }

        // ── The answer to a state.
        check(LiveCues.state(nil) == .notChecked, "a helper that failed is not checked, never unreachable or a state")
        check(LiveCues.state(details(#"{"transport":"unavailable"}"#)) == .unreachable, "nothing answered: unreachable")
        check(LiveCues.state(details(#"{"transport":"no_token"}"#)) == .reconnect, "no pairing token: reconnect")
        check(LiveCues.state(answered(404, #""error":"Not found""#)) == .olderServer, "404: an older server")
        check(LiveCues.state(answered(401)) == .reconnect && LiveCues.state(answered(403)) == .reconnect, "401 and 403: reconnect")
        check(LiveCues.state(answered(500)) == .failed(status: 500), "500 names its status")
        check(LiveCues.state(answered(200, #""enabled":true"#)) == .unreadable, "200 without the capability is not readable")
        check(LiveCues.state(answered(200, #""enabled":true,"source":"admin","capability":{"available":true}"#)) == .unreadable,
              "200 with a source outside the contract is not readable")
        check(LiveCues.state(details(#"{"httpStatus":200}"#)) == .notChecked, "no transport is not an answer")
        let on = loaded(answered(200, shape(enabled: true, available: true)))
        check(on == LiveCuesSettings(enabled: true, source: "setting",
                                     capability: LiveCuesCapability(available: true, reason: nil, model: "claude-sonnet-5-5", memory: "notes")),
              "200 in the contract's shape is the server's settings")
        check(loaded(answered(200, #""enabled":false,"source":"default","capability":{"available":false}"#))?.capability.memory == nil,
              "memory and reason are read when sent and never required")
        check(loaded(answered(200, shape(enabled: true, available: true, provider: "subq")))?.capability.decisionProvider == "subq",
              "decisionProvider is read")

        // ── Words for every state.
        check(line(answered(200, shape(enabled: true, available: true))) == "On. Cues use Claude Sonnet 5.5 and your notes.",
              "available with notes")
        check(line(answered(200, shape(enabled: true, available: true, memory: "cue_memory"))) == "On. Cues use Claude Sonnet 5.5 and your meetings.",
              "available with cue_memory reads your meetings")
        check(line(answered(200, shape(enabled: true, available: true, memory: "none"))) == "On. Cues use Claude Sonnet 5.5 and the conversation only.",
              "available with no memory reads the conversation only")
        check(line(answered(200, shape(enabled: true, available: true, model: "claude-haiku-4-5-20251001"))).hasPrefix("On. Cues use Claude Haiku 4.5 and"),
              "a dated model id reads as its name")
        // The decision model, named when the server says which (server 6.76.2).
        check(line(answered(200, shape(enabled: true, available: true, provider: "subq"))) == "On. Cues use Claude Sonnet 5.5, SubQ, and your notes.",
              "SubQ named with notes")
        check(line(answered(200, shape(enabled: true, available: true, memory: "cue_memory", provider: "jev"))) == "On. Cues use Claude Sonnet 5.5, Jev, and your meetings.",
              "Jev named with meetings")
        check(line(answered(200, shape(enabled: true, available: true, memory: "none", provider: "subq")))
              == "On. Cues use Claude Sonnet 5.5, SubQ, and the conversation only.", "SubQ with the conversation only")
        check(line(answered(200, shape(enabled: true, available: true, memory: "other", provider: "subq"))) == "On. Cues use Claude Sonnet 5.5 and SubQ.",
              "two parts read with and")
        check(line(answered(200, shape(enabled: true, available: true, provider: "openai"))) == "On. Cues use Claude Sonnet 5.5 and your notes.",
              "a provider outside the contract is not named")
        check(LiveCues.modelName("claude-opus-5") == "Opus 5" && LiveCues.modelName("gpt-x") == "gpt-x" && LiveCues.modelName("") == nil
              && LiveCues.modelName("claude-3-5-sonnet") == "claude-3-5-sonnet", "model names: family and version, else as sent")
        check(line(answered(200, shape(enabled: false, source: "default", available: false, reason: "master_flag_off"))) == LiveCues.offLine
              && LiveCues.offLine == "Off. Turn it on to see cues on the glasses during a meeting.", "master_flag_off: the switch is off")
        check(line(answered(200, shape(enabled: false, available: false, reason: "jev_not_configured"))) == LiveCues.offLine,
              "off says off, whatever else is missing")
        let reasons: [(String, String)] = [
            ("api_key_in_env", "An Anthropic API key is set in the server's environment; live cues stay off while it is there."),
            ("jev_not_configured", "Needs a Jev or SubQ key."),
            ("decision_not_configured", "Needs a Jev or SubQ key."),
            ("claude_not_found", "Install the Claude command-line tool, then check again."),
            ("budget_exhausted", "This week's live cues limit is used up. Cues start again next week."),
            ("jev_cap_reached", "Today's Jev limit for live cues is used up. Cues start again tomorrow."),
            ("jev_breaker_open", "Jev failed several times in a row, so cues are paused for up to an hour. They start again by themselves."),
            ("decision_cap_reached", "The decision model's limit for live cues is used up. Cues start again by themselves."),
            ("decision_breaker_open", "The decision model failed several times in a row, so cues are paused for a while. They start again by themselves."),
            ("unavailable", "The server could not tell whether cues can run. Check again."),
            ("something_new", "Cues cannot run right now. Check again in a minute."),
        ]
        for (reason, words) in reasons {
            check(line(answered(200, shape(enabled: true, available: false, reason: reason))) == words, "\(reason): \(words)")
        }
        check(line(answered(200, #""enabled":true,"source":"setting","capability":{"available":false}"#)) == LiveCues.reasonLine("unavailable"),
              "unavailable without a reason reads as unavailable")
        // Both spellings of the decision-model limits; the neutral one names the provider the server reports.
        check(line(answered(200, shape(enabled: true, available: false, reason: "decision_cap_reached", provider: "jev")))
              == "Today's Jev limit for live cues is used up. Cues start again tomorrow.", "decision_cap_reached on Jev reads as Jev's daily limit")
        check(line(answered(200, shape(enabled: true, available: false, reason: "decision_cap_reached", provider: "subq")))
              == "The SubQ limit for live cues is used up. Cues start again by themselves.", "decision_cap_reached on SubQ names SubQ")
        check(line(answered(200, shape(enabled: true, available: false, reason: "decision_breaker_open", provider: "subq")))
              == "SubQ failed several times in a row, so cues are paused for a while. They start again by themselves.", "decision_breaker_open on SubQ")
        check(line(answered(200, shape(enabled: true, available: false, reason: "jev_breaker_open", provider: "subq")))
              == LiveCues.reasonLine("jev_breaker_open"), "a jev_ reason always names Jev")
        // The server's environment.
        let env = loaded(answered(200, shape(enabled: true, source: "env", available: true)))
        check(env?.locked == true && line(answered(200, shape(enabled: true, source: "env", available: true)))
              == "Turned on in the server's environment. Cues use Claude Sonnet 5.5 and your notes.", "env: on and says where from")
        check(line(answered(200, shape(enabled: true, source: "env", available: false, reason: "jev_not_configured")))
              == "Turned on in the server's environment. Needs a Jev or SubQ key.", "env and a reason: both")
        check(line(answered(200, shape(enabled: false, source: "env", available: false, reason: "master_flag_off")))
              == "Turned off in the server's environment.", "env holding it off says so")
        check(LiveCues.envOnPrefix == "Turned on in the server's environment.", "the env words")
        // Not loaded.
        check(LiveCues.line(.olderServer) == "Needs server 6.76.2. Update the server in Settings.", "404 words")
        check(LiveCues.line(.unreachable) == "COS server unreachable. Live cues show here once it answers.", "unreachable words")
        check(LiveCues.line(.reconnect) == "Reconnect COS Control to the server to change live cues.", "reconnect words")
        check(LiveCues.line(.notChecked) == "COS Control could not check live cues. Check again.", "not checked words")
        check(LiveCues.line(.failed(status: 502)) == "The server could not answer about live cues (HTTP 502). Check again.", "failed words")
        check(LiveCues.line(.checking) == "Checking live cues…", "checking words")
        check(LiveCues.line(.unreachable, pending: true) == "Turning live cues on…" && LiveCues.line(.checking, pending: false) == "Turning live cues off…",
              "a change in flight says so")
        check(LiveCues.glassesLine == "Cues also need Live Cues on in the glasses app.", "the glasses line")

        var every: [S] = [.checking, .olderServer, .unreachable, .reconnect, .notChecked, .unreadable, .failed(status: 500)]
        for (reason, _) in reasons { every.append(LiveCues.state(answered(200, shape(enabled: true, available: false, reason: reason)))) }
        every += [LiveCues.state(answered(200, shape(enabled: true, available: true))), LiveCues.state(answered(200, shape(enabled: false, available: false))),
                  LiveCues.state(answered(200, shape(enabled: true, source: "env", available: true)))]
        for state in every {
            let words = LiveCues.line(state)
            check(!words.isEmpty && !words.contains("\u{2014}") && !words.contains("\u{2192}") && !words.contains("->") && !words.contains("_"),
                  "plain words, no em dash, arrow or code: \(words)")
        }
        for words in [LiveCues.glassesLine, LiveCues.envForcedNote, LiveCues.addKeyLabel, LiveCues.checkAgainLabel, LiveCues.title] {
            check(!words.contains("\u{2014}") && !words.contains("\u{2192}") && !words.contains("->"), "no em dash or arrow: \(words)")
        }

        // ── The control each line asks for.
        check(LiveCues.action(LiveCues.state(answered(200, shape(enabled: true, available: false, reason: "jev_not_configured")))) == .addDecisionKey
              && LiveCues.action(LiveCues.state(answered(200, shape(enabled: true, available: false, reason: "decision_not_configured")))) == .addDecisionKey,
              "Needs a Jev or SubQ key offers the key fields, in both spellings")
        check(LiveCues.action(LiveCues.state(answered(200, shape(enabled: true, source: "env", available: false, reason: "decision_not_configured")))) == .addDecisionKey,
              "env on without a key offers it too")
        check(LiveCues.action(LiveCues.state(answered(200, shape(enabled: true, available: false, reason: "decision_cap_reached")))) == .none
              && LiveCues.action(LiveCues.state(answered(200, shape(enabled: true, available: false, reason: "decision_breaker_open")))) == .none,
              "a limit or a pause that clears by itself offers nothing to press")
        check(LiveCues.action(LiveCues.state(answered(200, shape(enabled: false, available: false, reason: "jev_not_configured")))) == .none,
              "off offers nothing but the switch")
        check(LiveCues.action(LiveCues.state(answered(200, shape(enabled: true, available: false, reason: "claude_not_found")))) == .checkAgain
              && LiveCues.action(.unreachable) == .checkAgain && LiveCues.action(.notChecked) == .checkAgain && LiveCues.action(.failed(status: 500)) == .checkAgain,
              "unreachable, failed and Claude not found offer another read")
        check(LiveCues.action(.olderServer) == .none && LiveCues.action(.reconnect) == .none
              && LiveCues.action(LiveCues.state(answered(200, shape(enabled: true, available: true)))) == .none, "nothing to press when nothing would help")
        check(LiveCues.decisionKeysAnchor == "decision-models" && LiveCues.addKeyLabel == "Add a Jev or SubQ key", "the key fields jump")

        // ── The 409.
        check(LiveCues.envForced(answered(409, #""error":"env_forced""#)), "409 env_forced is the environment holding it on")
        check(!LiveCues.envForced(answered(409, #""error":"other""#)) && !LiveCues.envForced(answered(200, #""error":"env_forced""#)),
              "only a 409 env_forced")
        check(LiveCues.state(answered(409, #""error":"other""#)) == .failed(status: 409), "another 409 names its status")

        // ── The store against a stand-in helper.
        final class Calls { var log: [[String]] = []; var stdin: [Data?] = [] }
        final class Gate { var open = false }
        func fake(_ calls: Calls, _ answers: [[String: JSONValue]?]) -> LiveCuesStore.Run {
            var queue = answers
            return { args, input in
                calls.log.append(args); calls.stdin.append(input)
                guard !queue.isEmpty, let next = queue.removeFirst() else {
                    throw NSError(domain: "helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper failed"])
                }
                return HelperResponse(ok: true, message: "x", details: next)
            }
        }
        let offAnswer = answered(200, shape(enabled: false, source: "default", available: false, reason: "master_flag_off"))
        let onAnswer = answered(200, shape(enabled: true, available: true))
        let store = LiveCuesStore(); let calls = Calls()
        check(store.state == .checking && store.settings == nil && !store.switchEnabled, "before any answer: checking, no switch")
        await store.load(fake(calls, [offAnswer]))
        check(calls.log == [["live-cues-settings"]] && calls.stdin == [nil], "a read is `live-cues-settings`, no stdin")
        check(store.settings?.enabled == false && store.switchEnabled && store.line == LiveCues.offLine, "off from the server, the switch can move")
        await store.set(true, run: fake(calls, [onAnswer]))
        check(calls.log.last == ["live-cues-settings", "--set", "on"] && calls.stdin.last == .some(nil), "on is `--set on`")
        check(store.settings?.enabled == true && store.line == "On. Cues use Claude Sonnet 5.5 and your notes." && store.pending == nil,
              "the POST's answer is shown")
        let count = calls.log.count
        await store.set(true, run: fake(calls, [onAnswer]))
        check(calls.log.count == count, "asking for what the server already holds sends nothing")
        // A 409 env_forced: the sentence, then a fresh read.
        let envOn = answered(200, shape(enabled: true, source: "env", available: true))
        await store.set(false, run: fake(calls, [answered(409, #""error":"env_forced""#), envOn]))
        check(Array(calls.log.suffix(2)) == [["live-cues-settings", "--set", "off"], ["live-cues-settings"]], "409 env_forced reads again")
        check(store.note == LiveCues.envForcedNote && store.settings?.locked == true && store.settings?.enabled == true && !store.switchEnabled,
              "409: says why and shows the switch held on")
        let afterEnv = calls.log.count
        await store.set(false, run: fake(calls, [offAnswer]))
        check(calls.log.count == afterEnv, "a switch set in the server's environment never sends a change")
        // An unreachable server replaces what was shown, on a read and on a change.
        await store.load(fake(calls, [details(#"{"transport":"unavailable"}"#)]))
        check(store.state == .unreachable && store.settings == nil && store.action == .checkAgain, "unreachable never leaves the last answer on screen")
        await store.load(fake(calls, [offAnswer]))
        await store.set(true, run: fake(calls, [details(#"{"transport":"unavailable"}"#)]))
        check(store.state == .unreachable && store.settings == nil && store.pending == nil, "a change that reached nothing shows unreachable, not on")
        check(store.note == nil, "the next change cleared the 409 sentence")
        await store.load(fake(calls, [nil]))
        check(store.state == .notChecked, "a helper failure on a read is not checked")
        await store.load(fake(calls, [answered(404)]))
        check(store.state == .olderServer && store.line == "Needs server 6.76.2. Update the server in Settings." && !store.switchEnabled,
              "404 on a read: an older server, no switch")
        let olderCount = calls.log.count
        await store.set(true, run: fake(calls, [onAnswer]))
        check(calls.log.count == olderCount, "no change is sent to a server without the route")
        // A read in flight shows Checking and no switch, never the last answer.
        let reading = LiveCuesStore(); let readCalls = Calls(); let readGate = Gate()
        await reading.load(fake(readCalls, [onAnswer]))
        let heldRead: LiveCuesStore.Run = { args, _ in
            readCalls.log.append(args)
            while !readGate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return HelperResponse(ok: true, message: "x", details: offAnswer)
        }
        let read = Task { await reading.load(heldRead) }
        while readCalls.log.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        check(reading.state == .checking && reading.settings == nil && !reading.switchEnabled && reading.line == "Checking live cues…",
              "a read in flight shows Checking, never the last answer")
        readGate.open = true
        await read.value
        check(reading.settings?.enabled == false && !reading.busy, "the read lands")
        // Single flight: a change in flight holds the switch and the reads.
        let slow = LiveCuesStore(); let slowCalls = Calls()
        await slow.load(fake(slowCalls, [offAnswer]))
        let gate = Gate()
        let held: LiveCuesStore.Run = { args, _ in
            slowCalls.log.append(args)
            while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return HelperResponse(ok: true, message: "x", details: onAnswer)
        }
        let change = Task { await slow.set(true, run: held) }
        while slowCalls.log.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        check(slow.pending == true && slow.busy && !slow.switchEnabled && slow.line == "Turning live cues on…" && slow.action == .none,
              "while a change is in flight: Turning on, the switch held")
        await slow.load(fake(slowCalls, [offAnswer]))
        check(slowCalls.log.count == 2, "a read never crosses a change in flight")
        gate.open = true
        await change.value
        check(slow.settings?.enabled == true && !slow.busy, "the change lands")

        print("live cues checks: \(passed) passed")
    }
}
