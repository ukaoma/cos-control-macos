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

        // ── 0.5.329: the spend limits (server 6.79.2).
        // Server 6.79.2's exact v2 view (SERVER_6792_SETTINGS_WIRE.md).
        let limitsJSON = #""v":2,"limits":{"gate":{"value":0.8,"source":"default","locked":false,"min":0.5,"max":0.95,"default":0.8},"maxCuesPerMeeting":{"value":25,"source":"setting","locked":false,"min":1,"max":25,"default":25},"cooldownSeconds":{"value":45,"source":"default","locked":false,"min":20,"max":900,"default":45},"dailyWriterCalls":{"value":150,"source":"env","locked":true,"min":1,"max":500,"default":150}},"writerCallsPerMeeting":50,"today":{"day":"2026-10-19","writerCalls":12,"writerTokensIn":41200,"writerTokensOut":2900,"cues":7,"jevTokens":9100}"#
        func withLimits(_ base: String, _ extra: String = limitsJSON) -> String { base + "," + extra }
        let full = loaded(answered(200, withLimits(shape(enabled: true, available: true))))?.limits
        check(full?.values.count == 4 && full?.values[.gate] == LiveCuesLimit(value: 0.8, source: "default", locked: false, min: 0.5, max: 0.95, defaultValue: 0.8)
              && full?.values[.dailyWriterCalls]?.locked == true && full?.usage == LiveCuesUsage(cues: 7, writerCalls: 12, writerTokensIn: 41_200, writerTokensOut: 2_900, jevTokens: 9_100),
              "the four limits and today's usage are read")
        check(loaded(answered(200, shape(enabled: true, available: true)))?.limits == nil, "an older server has no limits: the switch alone")
        check(loaded(answered(200, withLimits(shape(enabled: true, available: true), limitsJSON.replacingOccurrences(of: #""v":2,"#, with: ""))))?.limits == nil,
              "limits count only in an answer that says v 2")
        check(loaded(answered(200, withLimits(shape(enabled: true, available: true), #""v":2,"limits":{"gate":{"value":"high"},"cooldownSeconds":{"value":30,"source":"env"}}"#)))?.limits?.values.keys.map(\.rawValue) == ["cooldownSeconds"]
              && loaded(answered(200, withLimits(shape(enabled: true, available: true), #""v":2,"limits":{"cooldownSeconds":{"value":30,"source":"env"}}"#)))?.limits?.values[.cooldownSeconds]?.locked == true,
              "a limit without a number is skipped; env without a locked flag is locked")
        let bar = full!.values[.gate]!
        check(LiveCues.gateSteps(bar) == [0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95], "the bar steps 0.50 to 0.95 by 0.05")
        check(LiveCues.gateSteps(LiveCuesLimit(value: 0.8, source: nil, locked: false)) == LiveCues.gateSteps(bar), "no bounds: the same 0.50 to 0.95")
        check(LiveCues.gateText(0.75) == "0.75" && LiveCues.gateText(0.5) == "0.50", "the bar reads with two decimals")
        check(LiveCues.ladder(.maxCuesPerMeeting, full!.values[.maxCuesPerMeeting]!) == Array(1...25), "max cues 1 to 25, one at a time")
        let gap = LiveCues.ladder(.cooldownSeconds, full!.values[.cooldownSeconds]!)
        check(gap.first == 20 && gap.last == 900 && gap.contains(45) && gap.contains(90) && gap == gap.sorted(), "the gap ladder holds 45 s and 1.5 min, 20 s to 15 min")
        check(LiveCues.ladder(.dailyWriterCalls, full!.values[.dailyWriterCalls]!).first == 1 && LiveCues.ladder(.dailyWriterCalls, full!.values[.dailyWriterCalls]!).last == 500,
              "the daily limit 1 to 500")
        check(LiveCues.ladder(.cooldownSeconds, LiveCuesLimit(value: 50, source: nil, locked: false, min: 20, max: 100)) == [20, 30, 45, 50, 60, 90, 100],
              "the ladder keeps the server's bounds and its current value")
        check(LiveCues.ladder(.dailyWriterCalls, LiveCuesLimit(value: 300, source: nil, locked: false, min: 0, max: 400)) == [0, 10, 25, 50, 75, 100, 150, 200, 300, 400],
              "the daily writer limit by round numbers")
        check(LiveCues.range(.maxCuesPerMeeting, LiveCuesLimit(value: 5, source: nil, locked: false, min: 9, max: 1)) == 1...25, "bounds upside down fall back")
        check(LiveCues.gapText(0) == "None" && LiveCues.gapText(45) == "45 s" && LiveCues.gapText(60) == "1 min" && LiveCues.gapText(90) == "1.5 min"
              && LiveCues.countText(.dailyWriterCalls, 0) == "Off" && LiveCues.countText(.maxCuesPerMeeting, 12) == "12", "values in words")
        check(LiveCues.usageLine(full!.usage!) == "Today: 7 cues, 12 writer calls, ~44K tokens"
              && LiveCues.usageLine(LiveCuesUsage(cues: 1, writerCalls: 1, writerTokensIn: 300, writerTokensOut: 200, jevTokens: 0)) == "Today: 1 cue, 1 writer call, 500 tokens",
              "today's usage line")
        check(LiveCues.limitsArguments([:]) == nil, "nothing waiting, nothing sent")
        check(LiveCues.limitsArguments([.dailyWriterCalls: 200, .gate: 0.75, .cooldownSeconds: 90]) == ["live-cues-settings", "--gate", "0.75", "--cooldown-seconds", "90", "--daily-writer-calls", "200"],
              "one call, the flags in a fixed order, the bar with two decimals")
        check(LiveCues.limitsRefusal(answered(200, withLimits(shape(enabled: true, available: true)))) == nil, "an echo with the limits is the save")
        check(LiveCues.limitsRefusal(answered(200, shape(enabled: true, available: true))) == "The server did not confirm the limit. Check again.", "an echo without them is not")
        check(LiveCues.limitsRefusal(answered(400, #""error":"invalid_request","reason":"out_of_bounds","field":"maxCuesPerMeeting","min":1,"max":25,"integer":true"#))
              == "The server takes 1 to 25 there."
              && LiveCues.limitsRefusal(answered(400, #""error":"invalid_request","reason":"out_of_bounds","field":"gate","min":0.5,"max":0.95,"integer":false"#))
              == "The server takes 0.50 to 0.95 there."
              && LiveCues.limitsRefusal(answered(400, #""error":"invalid_request","reason":"unknown_field","field":"gate""#)) == "Limits need server 6.79.2. Update the server in Settings."
              && LiveCues.limitsRefusal(answered(400, #""error":"invalid_request","reason":"empty""#)) == "The server did not accept that value.",
              "a 400 by its reason, with the server's own bounds")
        check(LiveCues.limitsRefusal(answered(409, #""error":"env_locked","fields":["gate"]"#)) == "That limit is set in the server's .env, so it cannot be changed here."
              && LiveCues.limitsRefusal(answered(400)) == "The server did not accept that value."
              && LiveCues.limitsRefusal(answered(404)) == "Limits need server 6.79.2. Update the server in Settings."
              && LiveCues.limitsRefusal(details(#"{"transport":"unavailable"}"#)) == "COS server unreachable. The limit was not saved."
              && LiveCues.limitsRefusal(nil) == "COS Control could not save the limit. Try again.", "each refusal in words")
        for text in [LiveCues.barTitle, LiveCues.moreCues, LiveCues.fewerCues, LiveCues.maxCuesTitle, LiveCues.gapTitle, LiveCues.dailyTitle, LiveCues.envNote,
                     LiveCues.usageLine(full!.usage!), LiveCues.limitsRefusal(answered(409))!, LiveCues.limitsRefusal(answered(500))!] {
            check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->"), "no em dash or arrow: \(text)")
        }

        // The store: debounced, one call, shown only from the server's echo.
        let limited = LiveCuesStore(); let limitCalls = Calls()
        limited.limitsDebounce = .milliseconds(40)
        let echo = answered(200, withLimits(shape(enabled: true, available: true),
            limitsJSON.replacingOccurrences(of: #""value":0.8,"#, with: #""value":0.75,"#).replacingOccurrences(of: #""value":25,"#, with: #""value":12,"#)))
        await limited.load(fake(limitCalls, [answered(200, withLimits(shape(enabled: true, available: true)))]))
        let limitRun = fake(limitCalls, [echo])
        limited.propose(.dailyWriterCalls, 100, run: limitRun)
        check(limited.pendingLimits.isEmpty, "a limit set in .env never moves")
        limited.propose(.gate, 0.8, run: limitRun)
        check(limited.pendingLimits.isEmpty, "moving to the server's own value waits for nothing")
        limited.propose(.gate, 0.7, run: limitRun)
        limited.propose(.gate, 0.75, run: limitRun)
        limited.propose(.maxCuesPerMeeting, 12, run: limitRun)
        check(limited.pendingLimits == [.gate: 0.75, .maxCuesPerMeeting: 12] && limited.limitValue(.gate) == 0.75 && limitCalls.log.count == 1,
              "moves wait: nothing sent yet, the controls show where they were moved")
        check(limited.settings?.limits?.values[.gate]?.value == 0.8, "the server's value is unchanged until it answers")
        var waited = 0
        while limitCalls.log.count < 2 && waited < 200 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        try? await Task.sleep(for: .milliseconds(30))
        check(limitCalls.log.count == 2 && limitCalls.log.last == ["live-cues-settings", "--gate", "0.75", "--max-cues", "12"], "after the pause: one call with every move")
        check(limited.pendingLimits.isEmpty && limited.settings?.limits?.values[.gate]?.value == 0.75 && limited.settings?.limits?.values[.maxCuesPerMeeting]?.value == 12
              && limited.limitsNote == nil, "the echo is what shows")
        // A refusal: the note, nothing waiting, the server's values as they were.
        limited.propose(.maxCuesPerMeeting, 3, run: fake(limitCalls, [answered(400, #""error":"out_of_range""#)]))
        await limited.flushLimits(fake(limitCalls, [answered(400, #""error":"out_of_range""#)]))
        check(limited.limitsNote == "The server did not accept that value." && limited.pendingLimits.isEmpty && limited.settings?.limits?.values[.maxCuesPerMeeting]?.value == 12,
              "a refusal says why and shows the server's value, never the refused one")
        // Each move restarts the wait: a person still moving never sends a half-made change.
        let moving = LiveCuesStore(); let movingCalls = Calls()
        moving.limitsDebounce = .milliseconds(150)
        await moving.load(fake(movingCalls, [answered(200, withLimits(shape(enabled: true, available: true)))]))
        let movingRun = fake(movingCalls, [echo, echo])
        moving.propose(.gate, 0.7, run: movingRun)
        try? await Task.sleep(for: .milliseconds(100))
        moving.propose(.gate, 0.75, run: movingRun)
        try? await Task.sleep(for: .milliseconds(100))
        check(movingCalls.log.count == 1, "a move inside the wait restarts it (nothing sent 200 ms after the first move)")
        waited = 0
        while movingCalls.log.count < 2 && waited < 200 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        try? await Task.sleep(for: .milliseconds(200))
        check(movingCalls.log.count == 2 && movingCalls.log.last == ["live-cues-settings", "--gate", "0.75"], "then one call with the last move")
        // A change waits for a read in flight instead of crossing it.
        let reading2 = LiveCuesStore(); let readingCalls = Calls(); let readingGate = Gate()
        await reading2.load(fake(readingCalls, [answered(200, withLimits(shape(enabled: true, available: true)))]))
        reading2.limitsDebounce = .seconds(60)
        reading2.propose(.gate, 0.75, run: fake(readingCalls, [echo]))
        let heldReading: LiveCuesStore.Run = { args, _ in
            readingCalls.log.append(args)
            while !readingGate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return HelperResponse(ok: true, message: "x", details: answered(200, withLimits(shape(enabled: true, available: true))))
        }
        let readTask = Task { await reading2.load(heldReading) }
        while readingCalls.log.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        let flushTask = Task { await reading2.flushLimits(fake(readingCalls, [echo])) }
        try? await Task.sleep(for: .milliseconds(80))
        check(readingCalls.log.count == 2, "a limits change waits while a read is out")
        readingGate.open = true
        await readTask.value
        await flushTask.value
        check(readingCalls.log.count == 3 && readingCalls.log.last?.first == "live-cues-settings" && readingCalls.log.last?.count == 3
              && reading2.settings?.limits?.values[.gate]?.value == 0.75, "then it goes, and its echo shows")
        // A move during a call stays waiting for its own call.
        let heldLimits = LiveCuesStore(); let heldCalls = Calls(); let limitGate = Gate()
        heldLimits.limitsDebounce = .seconds(60)
        await heldLimits.load(fake(heldCalls, [answered(200, withLimits(shape(enabled: true, available: true)))]))
        let slowEcho: LiveCuesStore.Run = { args, _ in
            heldCalls.log.append(args)
            while !limitGate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return HelperResponse(ok: true, message: "x", details: echo)
        }
        heldLimits.propose(.gate, 0.75, run: slowEcho)
        let flight = Task { await heldLimits.flushLimits(slowEcho) }
        while heldCalls.log.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        heldLimits.propose(.gate, 0.9, run: slowEcho)
        check(heldLimits.busy && heldLimits.limitValue(.gate) == 0.9, "a move while a change is out shows where it was moved")
        await heldLimits.load(fake(heldCalls, [onAnswer]))
        check(heldCalls.log.count == 2, "a read never crosses a limits change")
        limitGate.open = true
        await flight.value
        check(heldLimits.pendingLimits == [.gate: 0.9], "the newer move stays waiting after the older one lands")

        print("live cues checks: \(passed) passed")
    }
}
