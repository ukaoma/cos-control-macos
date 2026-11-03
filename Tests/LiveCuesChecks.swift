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

        // ── 0.5.362: server API v3 (the cue mode, grounding and the general cue limits). Shapes from the frozen contract.
        let generalJSON = #""general":{"limits":{"intervalSeconds":{"value":300,"source":"default","locked":false,"min":120,"max":1800,"default":300},"trigger":{"value":0.6,"source":"setting","locked":false,"min":0.4,"max":0.9,"default":0.6},"attemptsPerMeeting":{"value":8,"source":"default","locked":false,"min":1,"max":30,"default":8},"maxCuesPerMeeting":{"value":4,"source":"env","locked":true,"min":1,"max":12,"default":4},"dailyTopicCalls":{"value":60,"source":"default","locked":false,"min":1,"max":200,"default":60},"dailyWebSearches":{"value":30,"source":"default","locked":false,"min":1,"max":100,"default":30}},"today":{"day":"2026-11-01","topicCalls":4,"webSearches":2,"breakerOpenUntil":null},"publicTopics":true,"homeArea":"Austin, TX"}"#
        let v3Limits = limitsJSON.replacingOccurrences(of: #""v":2,"#, with: #""v":3,"#)
        func v3Body(mode: String = #"{"value":"general","source":"setting","locked":false}"#, grounding: String = #"{"value":"classic","source":"default","locked":false}"#,
                    general: String? = nil, limits: String? = nil) -> String {
            let block = general ?? generalJSON
            return shape(enabled: true, available: true) + "," + (limits ?? v3Limits) + #","cueMode":"# + mode + #","grounding":"# + grounding + (block.isEmpty ? "" : "," + block)
        }
        func answeredAPI(_ version: Int?, _ body: String) -> [String: JSONValue] {
            details(#"{"transport":"answered","httpStatus":200"# + (version.map { #","apiVersion":\#($0)"# } ?? "") + "," + body + "}")
        }
        let v3Settings = loaded(answeredAPI(3, v3Body()))
        let v3 = v3Settings?.v3
        check(v3?.mode == LiveCuesChoice(value: LiveCueMode.general, source: "setting", locked: false)
              && v3?.grounding == LiveCuesChoice(value: LiveCueGrounding.classic, source: "default", locked: false)
              && v3?.publicTopics == true && v3?.homeArea == "Austin, TX", "a v 3 answer carries the cue mode, the grounding switch, Public topics and the home city")
        check(v3?.today == LiveCuesGeneralToday(topicCalls: 4, webSearches: 2, breakerOpenUntil: nil), "today's general counts are read; a closed breaker is nil")
        check(v3Settings?.limits?.values.count == 10 && v3Settings?.limits?.values[.generalTrigger]?.value == 0.6 && v3Settings?.limits?.values[.generalIntervalSeconds]?.min == 120
              && v3Settings?.limits?.values[.generalMaxCuesPerMeeting]?.locked == true && v3Settings?.limits?.values[.gate]?.value == 0.8,
              "the six general limits sit beside the four, each by the server's name inside general.limits")
        check(v3Settings?.limits?.usage?.cues == 7, "the v 2 usage still reads from a v 3 answer")
        check(loaded(answeredAPI(3, v3Body(mode: #"{"value":"all","source":"env"}"#)))?.v3?.mode == LiveCuesChoice(value: LiveCueMode.all, source: "env", locked: true),
              "a mode from the environment is locked without a locked flag")
        check(loaded(answeredAPI(3, v3Body(general: generalJSON.replacingOccurrences(of: #""breakerOpenUntil":null"#, with: #""breakerOpenUntil":1790000000000"#))))?.v3?.today?.breakerOpenUntil
              == Date(timeIntervalSince1970: 1_790_000_000), "an open breaker carries the time it ends")
        check(loaded(answeredAPI(3, v3Body(general: generalJSON.replacingOccurrences(of: #","homeArea":"Austin, TX""#, with: #","homeArea":null"#))))?.v3?.homeArea == nil,
              "no home city is nil")
        // Everything v3 is hidden when the helper reports v 2, or the answer is not whole.
        check(loaded(answeredAPI(2, v3Body()))?.v3 == nil && loaded(answeredAPI(nil, v3Body()))?.v3 == nil, "apiVersion 2 or missing: no v3 controls, whatever the body says")
        check(loaded(answeredAPI(2, v3Body()))?.limits?.values.count == 4, "under apiVersion 2 only the four v 2 limits read, never the general ones")
        check(loaded(answeredAPI(3, v3Body(limits: limitsJSON)))?.v3 == nil, "a body that says v 2 under apiVersion 3 has no v3 controls")
        check(loaded(answeredAPI(3, v3Body(limits: limitsJSON)))?.limits?.values.count == 4, "and no general limits")
        check(loaded(answeredAPI(3, v3Body(mode: #"{"value":"everything"}"#)))?.v3 == nil && loaded(answeredAPI(3, v3Body(grounding: #"{"value":"on"}"#)))?.v3 == nil,
              "a mode or grounding outside the enum hides v3")
        check(loaded(answeredAPI(3, v3Body(general: "")))?.v3 == nil && loaded(answeredAPI(3, v3Body(general: #""general":{"limits":{}}"#)))?.v3 == nil,
              "no general block, or one without Public topics, hides v3")
        check(loaded(answered(200, withLimits(shape(enabled: true, available: true))))?.v3 == nil, "a v 2 server has no v3")
        // The words.
        check(LiveCueMode.allCases.map { LiveCues.modeTitle($0) } == ["Focused", "General", "All"], "the three modes by name")
        check(LiveCues.modeHelp(.focused) == "Cues from the room, drawn from your past meetings and notes."
              && LiveCues.modeHelp(.general) == "On Mac meetings, public context from the web instead of focused cues. Needs Public topics on, in Ask settings in the phone app. Until then Mac meetings keep focused cues. G2 keeps focused cues."
              && LiveCues.modeHelp(.all) == "On Mac meetings, focused cues plus public context from the web. Needs Public topics on, in Ask settings in the phone app. Until then Mac meetings keep focused cues only. G2 keeps focused cues.",
              "one plain line per mode, saying what Mac and G2 meetings get")
        check(LiveCues.modeHelp(.general).contains("G2 keeps focused cues") && LiveCues.modeHelp(.all).contains("G2 keeps focused cues") && !LiveCues.modeHelp(.focused).contains("G2"),
              "General and All say G2 keeps focused cues")
        check(LiveCues.searchesWeb(.general) && LiveCues.searchesWeb(.all) && !LiveCues.searchesWeb(.focused)
              && LiveCues.modeHelp(.general).contains("web") && LiveCues.modeHelp(.general).contains("Public topics on")
              && LiveCues.modeHelp(.all).contains("web") && LiveCues.modeHelp(.all).contains("Public topics on"), "General and All say they search the web and need Public topics")
        func v3With(_ mode: LiveCueMode, topics: Bool, area: String? = nil) -> LiveCuesV3 {
            LiveCuesV3(mode: LiveCuesChoice(value: mode, source: "setting", locked: false), grounding: LiveCuesChoice(value: .classic, source: nil, locked: false),
                       publicTopics: topics, homeArea: area, today: nil)
        }
        check(LiveCues.publicTopicsLine(v3With(.general, topics: false)) == LiveCues.publicTopicsOffLine && LiveCues.publicTopicsLine(v3With(.all, topics: false)) == LiveCues.publicTopicsOffLine
              && LiveCues.publicTopicsLine(v3With(.general, topics: true)) == nil && LiveCues.publicTopicsLine(v3With(.focused, topics: false)) == nil,
              "the live state of Public topics shows when it is off and the mode needs it")
        check(LiveCues.publicTopicsOffLine == "Public topics is off, so Mac meetings keep focused cues. Turn it on in Ask settings in the phone app."
              && LiveCues.modeHelp(.general).contains("Ask settings in the phone app") && LiveCues.modeHelp(.general).contains("Until then Mac meetings keep focused cues")
              && LiveCues.modeHelp(.all).contains("Ask settings in the phone app") && LiveCues.modeHelp(.all).contains("Until then Mac meetings keep focused cues only")
              && !LiveCues.modeHelp(.focused).contains("Public topics"),
              "the amber line and the help say where Public topics is turned on, and that Mac meetings keep focused cues until then")
        check(LiveCues.homeAreaLine(v3With(.general, topics: true, area: "Austin, TX")) == "Local items use Austin, TX."
              && LiveCues.homeAreaLine(v3With(.focused, topics: true, area: "Austin, TX")) == nil && LiveCues.homeAreaLine(v3With(.all, topics: true)) == nil,
              "the home city line shows with a city and a web mode")
        check(LiveCues.readsGeneral(v3Settings) && !LiveCues.readsGeneral(loaded(answeredAPI(3, v3Body(mode: #"{"value":"focused"}"#)))) && !LiveCues.readsGeneral(nil)
              && !LiveCues.readsGeneral(loaded(answered(200, shape(enabled: true, available: true)))), "the general status is read only in a web mode on a v 3 server")
        check(LiveCues.groundedHelp == "Each cue is checked against your past meetings, notes and files, and cites what it used."
              && LiveCues.cueModeTitle == "Cue mode" && LiveCues.groundedTitle == "Grounded cues", "the grounded switch and the picker by name")
        // 0.5.365: named for what it counts (the general cues' own counters), never "Today: ... web searches" beside the meeting assistant's own.
        check(LiveCues.generalUsageLine(LiveCuesGeneralToday(topicCalls: 4, webSearches: 2, breakerOpenUntil: nil)) == "Background topic checks today: 4, searches: 2"
              && LiveCues.generalUsageLine(LiveCuesGeneralToday(topicCalls: 0, webSearches: 0, breakerOpenUntil: nil)) == "Background topic checks today: 0, searches: 0",
              "today's general use in words, named for the general cues")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let zone = Calendar(identifier: .gregorian)
        check(LiveCues.breakerLine(LiveCuesGeneralToday(topicCalls: 0, webSearches: 0, breakerOpenUntil: now.addingTimeInterval(600)), now: now, style: .twentyFourHour, calendar: zone)?
                .hasPrefix("General cues are paused until ") == true
              && LiveCues.breakerLine(LiveCuesGeneralToday(topicCalls: 0, webSearches: 0, breakerOpenUntil: now.addingTimeInterval(-1)), now: now, style: .twentyFourHour) == nil
              && LiveCues.breakerLine(LiveCuesGeneralToday(topicCalls: 0, webSearches: 0, breakerOpenUntil: nil), now: now, style: .twentyFourHour) == nil
              && LiveCues.breakerLine(nil, now: now, style: .twentyFourHour) == nil, "the breaker line shows while it is open, and says when it ends")
        check(LiveCuesLimits.Key.allCases.filter(\.isGeneral).count == 6 && LiveCuesLimits.Key.allCases.filter { !$0.isGeneral }.map(\.rawValue) == ["gate", "maxCuesPerMeeting", "cooldownSeconds", "dailyWriterCalls"],
              "six general keys, the four v 2 keys unchanged")
        check(LiveCuesLimits.Key.allCases.filter(\.isDecimal) == [.gate, .generalTrigger], "the two probabilities send decimals")
        check(LiveCuesLimits.Key.generalMaxCuesPerMeeting.serverName == "maxCuesPerMeeting" && LiveCuesLimits.Key.generalMaxCuesPerMeeting.rawValue == "generalMaxCuesPerMeeting"
              && LiveCuesLimits.Key.generalIntervalSeconds.serverName == "intervalSeconds" && LiveCuesLimits.Key.maxCuesPerMeeting.serverName == "maxCuesPerMeeting",
              "a general limit is read by the short name and written by the long one")
        check(LiveCuesLimits.Key.allCases.map(\.flag) == ["--gate", "--max-cues", "--cooldown-seconds", "--daily-writer-calls", "--general-interval", "--general-trigger",
                                                          "--general-attempts", "--general-max-cues", "--general-daily-topic-calls", "--general-daily-web-searches"], "one helper flag per limit")
        check(LiveCues.limitsArguments([.generalTrigger: 0.7, .generalIntervalSeconds: 600, .gate: 0.8])
              == ["live-cues-settings", "--gate", "0.80", "--general-interval", "600", "--general-trigger", "0.70"], "general limits ride the same one call, in a fixed order")
        let trigger = v3Settings!.limits!.values[.generalTrigger]!
        check(LiveCues.sliderSteps(.generalTrigger, trigger) == [0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9], "the general bar steps 0.40 to 0.90 by 0.05")
        check(LiveCues.range(.generalTrigger, LiveCuesLimit(value: 0.6, source: nil, locked: false)) == 0.4...0.9
              && LiveCues.range(.generalIntervalSeconds, LiveCuesLimit(value: 300, source: nil, locked: false)) == 120...1_800
              && LiveCues.range(.generalAttemptsPerMeeting, LiveCuesLimit(value: 8, source: nil, locked: false)) == 1...30
              && LiveCues.range(.generalMaxCuesPerMeeting, LiveCuesLimit(value: 4, source: nil, locked: false)) == 1...12
              && LiveCues.range(.generalDailyTopicCalls, LiveCuesLimit(value: 60, source: nil, locked: false)) == 1...200
              && LiveCues.range(.generalDailyWebSearches, LiveCuesLimit(value: 30, source: nil, locked: false)) == 1...100, "the contract's bounds are the fallback")
        let interval = LiveCues.ladder(.generalIntervalSeconds, v3Settings!.limits!.values[.generalIntervalSeconds]!)
        check(interval.first == 120 && interval.last == 1_800 && interval.contains(300) && interval == interval.sorted(), "the general gap ladder, 2 to 30 minutes, holds the default")
        check(LiveCues.ladder(.generalMaxCuesPerMeeting, v3Settings!.limits!.values[.generalMaxCuesPerMeeting]!) == Array(1...12)
              && LiveCues.ladder(.generalAttemptsPerMeeting, v3Settings!.limits!.values[.generalAttemptsPerMeeting]!) == Array(1...30), "per-meeting counts one at a time")
        let searches = LiveCues.ladder(.generalDailyWebSearches, v3Settings!.limits!.values[.generalDailyWebSearches]!)
        let topics = LiveCues.ladder(.generalDailyTopicCalls, v3Settings!.limits!.values[.generalDailyTopicCalls]!)
        check(searches.first == 1 && searches.last == 100 && searches.contains(30) && topics.first == 1 && topics.last == 200 && topics.contains(60), "the daily ladders hold their defaults")
        check(LiveCues.countText(.generalIntervalSeconds, 300) == "5 min" && LiveCues.countText(.generalDailyWebSearches, 30) == "30", "values in words")
        check(LiveCues.generalTitle(.generalTrigger) == "General bar" && LiveCues.generalTitle(.generalIntervalSeconds) == "General check gap" && LiveCues.generalTitle(.gate) == nil
              && LiveCuesLimits.Key.allCases.filter(\.isGeneral).allSatisfy { LiveCues.generalTitle($0) != nil }, "every general limit has a title")
        check(LiveCues.changeRefusal(answeredAPI(3, v3Body())) == nil && LiveCues.changeRefusal(answeredAPI(2, v3Body())) == "The server did not confirm the change. Check again."
              && LiveCues.changeRefusal(answered(409, #""error":"env_forced""#)) == LiveCues.modeEnvNote
              && LiveCues.changeRefusal(answered(400, #""error":"invalid_request","reason":"unsupported_version""#)) == "Cue modes need a newer server. Update the server in Settings."
              && LiveCues.changeRefusal(answered(400, #""error":"invalid_request","reason":"invalid_value","field":"cueMode""#)) == "The server did not accept that value."
              && LiveCues.changeRefusal(answered(404)) == "Cue modes need a newer server. Update the server in Settings."
              && LiveCues.changeRefusal(details(#"{"transport":"unavailable"}"#)) == "COS server unreachable. The change was not saved."
              && LiveCues.changeRefusal(nil) == "COS Control could not save the change. Try again.", "each refusal of a mode change in words")
        var v3Words = [LiveCues.cueModeTitle, LiveCues.groundedTitle, LiveCues.groundedHelp, LiveCues.modeEnvNote, LiveCues.publicTopicsOffLine, LiveCues.generalBarTitle,
                       LiveCues.generalMoreCues, LiveCues.generalFewerCues, LiveCues.generalGapTitle, LiveCues.generalAttemptsTitle, LiveCues.generalMaxCuesTitle,
                       LiveCues.generalDailyTopicsTitle, LiveCues.generalDailySearchesTitle]
        v3Words += LiveCueMode.allCases.flatMap { [LiveCues.modeTitle($0), LiveCues.modeHelp($0)] }
        for text in v3Words {
            check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->") && !text.contains("_"), "plain words, no em dash, arrow or code: \(text)")
        }

        // The store: the mode and grounding change only through the server's answer.
        let v3Store = LiveCuesStore(); let v3Calls = Calls()
        await v3Store.loadIfNeeded(fake(v3Calls, [answeredAPI(3, v3Body())]))
        check(v3Calls.log == [["live-cues-settings"]] && v3Store.settings?.v3?.mode.value == .general, "the first read happens once, from loadIfNeeded")
        await v3Store.loadIfNeeded(fake(v3Calls, [answeredAPI(3, v3Body())]))
        check(v3Calls.log.count == 1, "loadIfNeeded reads nothing once something has been read")
        await v3Store.setMode(.general, run: fake(v3Calls, [answeredAPI(3, v3Body())]))
        check(v3Calls.log.count == 1, "asking for the mode the server already holds sends nothing")
        await v3Store.setMode(.all, run: fake(v3Calls, [answeredAPI(3, v3Body(mode: #"{"value":"all","source":"setting","locked":false}"#))]))
        check(v3Calls.log.last == ["live-cues-settings", "--mode", "all"] && v3Store.settings?.v3?.mode.value == .all && v3Store.pendingMode == nil && v3Store.v3Note == nil,
              "a mode change is `--mode all`, and the server's answer is what shows")
        await v3Store.setGrounding(.grounded, run: fake(v3Calls, [answeredAPI(3, v3Body(mode: #"{"value":"all","source":"setting","locked":false}"#, grounding: #"{"value":"grounded","source":"setting","locked":false}"#))]))
        check(v3Calls.log.last == ["live-cues-settings", "--grounding", "grounded"] && v3Store.settings?.v3?.grounding.value == .grounded, "grounding is `--grounding grounded`")
        let beforeRefusal = v3Calls.log.count
        await v3Store.setMode(.focused, run: fake(v3Calls, [answered(409, #""error":"env_forced""#)]))
        check(v3Calls.log.count == beforeRefusal + 1 && v3Store.settings?.v3?.mode.value == .all && v3Store.v3Note == LiveCues.modeEnvNote && v3Store.pendingMode == nil,
              "a refused change says why and keeps the server's mode, never the refused one")
        await v3Store.setGrounding(.classic, run: fake(v3Calls, [details(#"{"transport":"unavailable"}"#)]))
        check(v3Store.settings?.v3?.grounding.value == .grounded && v3Store.v3Note == "COS server unreachable. The change was not saved.", "nothing answering keeps what was shown, with the reason")
        // A mode the environment holds never sends a change; neither does a server without v3.
        let lockedStore = LiveCuesStore(); let lockedCalls = Calls()
        await lockedStore.load(fake(lockedCalls, [answeredAPI(3, v3Body(mode: #"{"value":"focused","source":"env","locked":true}"#, grounding: #"{"value":"classic","source":"env","locked":true}"#))]))
        await lockedStore.setMode(.all, run: fake(lockedCalls, [answeredAPI(3, v3Body())]))
        await lockedStore.setGrounding(.grounded, run: fake(lockedCalls, [answeredAPI(3, v3Body())]))
        check(lockedCalls.log.count == 1, "a mode or grounding the server's environment holds sends no change")
        let olderStore = LiveCuesStore(); let olderCalls = Calls()
        await olderStore.load(fake(olderCalls, [answered(200, withLimits(shape(enabled: true, available: true)))]))
        await olderStore.setMode(.all, run: fake(olderCalls, [answeredAPI(3, v3Body())]))
        await olderStore.setGrounding(.grounded, run: fake(olderCalls, [answeredAPI(3, v3Body())]))
        check(olderCalls.log.count == 1 && olderStore.settings?.v3 == nil, "a v 2 server is sent no mode and no grounding")
        // A v 2 write on a v 3 server is answered in the v 2 view: Control reads again, so the v3 controls stay.
        let keepStore = LiveCuesStore(); let keepCalls = Calls()
        await keepStore.load(fake(keepCalls, [answeredAPI(3, v3Body())]))
        await keepStore.set(false, run: fake(keepCalls, [answered(200, shape(enabled: false, available: true)), answeredAPI(3, v3Body())]))
        check(keepCalls.log == [["live-cues-settings"], ["live-cues-settings", "--set", "off"], ["live-cues-settings"]] && keepStore.settings?.v3 != nil && !keepStore.busy,
              "a switch change answered in the v 2 view is followed by a read, so the cue mode stays")
        keepStore.limitsDebounce = .seconds(60)
        keepStore.propose(.cooldownSeconds, 90, run: fake(keepCalls, []))
        await keepStore.flushLimits(fake(keepCalls, [answered(200, withLimits(shape(enabled: true, available: true))), answeredAPI(3, v3Body())]))
        check(keepCalls.log.suffix(2) == [["live-cues-settings", "--cooldown-seconds", "90"], ["live-cues-settings"]] && keepStore.settings?.v3 != nil,
              "a v 2 limit change answered in the v 2 view is followed by a read too")
        // A general limit goes through the same debounce and the same one call.
        let generalStore = LiveCuesStore(); let generalCalls = Calls()
        generalStore.limitsDebounce = .seconds(60)
        await generalStore.load(fake(generalCalls, [answeredAPI(3, v3Body())]))
        generalStore.propose(.generalMaxCuesPerMeeting, 6, run: fake(generalCalls, []))
        check(generalStore.pendingLimits.isEmpty, "a general limit set in the server's environment never moves")
        generalStore.propose(.generalTrigger, 0.7, run: fake(generalCalls, []))
        generalStore.propose(.generalDailyWebSearches, 20, run: fake(generalCalls, []))
        check(generalStore.pendingLimits == [.generalTrigger: 0.7, .generalDailyWebSearches: 20] && generalStore.limitValue(.generalTrigger) == 0.7, "general moves wait, and show where they were moved")
        let changed = v3Body(general: generalJSON.replacingOccurrences(of: #""trigger":{"value":0.6"#, with: #""trigger":{"value":0.7"#).replacingOccurrences(of: #""dailyWebSearches":{"value":30"#, with: #""dailyWebSearches":{"value":20"#))
        await generalStore.flushLimits(fake(generalCalls, [answeredAPI(3, changed)]))
        check(generalCalls.log.last == ["live-cues-settings", "--general-trigger", "0.70", "--general-daily-web-searches", "20"]
              && generalStore.settings?.limits?.values[.generalTrigger]?.value == 0.7 && generalStore.settings?.limits?.values[.generalDailyWebSearches]?.value == 20
              && generalStore.pendingLimits.isEmpty && generalStore.limitsNote == nil, "one call with the general flags, and the server's echo is what shows")


        // ── 0.5.365: the web ledger (`webToday`). The general counters above count general cues only; this counts every lookup.
        func webBlock(readable: Bool = true, cues: String = #"{"searches":1,"pagesRead":0}"#, ask: String = #"{"searches":3,"pagesRead":2}"#,
                      fact: String = #"{"searches":1,"pagesRead":1}"#, total: Int = 2) -> String {
            #","webToday":{"day":"2026-11-02","readable":\#(readable),"cues":\#(cues),"ask":\#(ask),"factCheck":\#(fact),"withheld":{"total":\#(total),"byReason":{"no_public_intent":\#(total)},"byFeature":{"cues":0,"ask":\#(total),"factCheck":0}}}"#
        }
        // The older ledger shape (no pagesFailed) reads and says nothing about failed pages; the newer one says it only above zero.
        let failedAsk = #"{"searches":3,"pagesRead":2,"pagesFailed":1}"#
        check(LiveCues.webTodayLine(loaded(answeredAPI(3, v3Body() + webBlock(ask: failedAsk)))?.v3?.webToday)
              == "Web today: 5 searches (cues 1, assistant 3, fact checks 1), 3 pages read, 1 failed. 2 held back.", "failed pages are counted across features and shown above zero")
        check(LiveCues.webTodayLine(loaded(answeredAPI(3, v3Body() + webBlock(cues: #"{"searches":1,"pagesRead":0,"pagesFailed":2}"#, ask: failedAsk,
                                                                           fact: #"{"searches":1,"pagesRead":1,"pagesFailed":3}"#)))?.v3?.webToday)
              == "Web today: 5 searches (cues 1, assistant 3, fact checks 1), 3 pages read, 6 failed. 2 held back.", "failed pages from all three features are added")
        check(LiveCues.webTodayLine(loaded(answeredAPI(3, v3Body() + webBlock(ask: #"{"searches":3,"pagesRead":2,"pagesFailed":0}"#)))?.v3?.webToday)
              == LiveCues.webTodayLine(loaded(answeredAPI(3, v3Body() + webBlock()))?.v3?.webToday), "zero failed pages is the same line as the older shape")
        check(loaded(answeredAPI(3, v3Body() + webBlock(ask: failedAsk)))?.v3?.webToday?.assistant.pagesFailed == 1
              && loaded(answeredAPI(3, v3Body() + webBlock()))?.v3?.webToday?.assistant.pagesFailed == 0, "pagesFailed is read per feature, zero when absent")
        let webAnswer = loaded(answeredAPI(3, v3Body() + webBlock()))
        check(webAnswer?.v3?.webToday == LiveCuesWebToday(cues: .init(searches: 1, pagesRead: 0), assistant: .init(searches: 3, pagesRead: 2),
                                                         factChecks: .init(searches: 1, pagesRead: 1), heldBack: 2), "the ledger is read: cues, assistant, fact checks and what was held back")
        check(LiveCues.webTodayLine(webAnswer?.v3?.webToday) == "Web today: 5 searches (cues 1, assistant 3, fact checks 1), 3 pages read. 2 held back.",
              "the web line adds every feature and says what was held back")
        check(LiveCues.webTodayLine(loaded(answeredAPI(3, v3Body() + webBlock(cues: #"{"searches":0,"pagesRead":0}"#, ask: #"{"searches":1,"pagesRead":1}"#,
                                                                           fact: #"{"searches":0,"pagesRead":0}"#, total: 0)))?.v3?.webToday)
              == "Web today: 1 search (cues 0, assistant 1, fact checks 0), 1 page read.", "one search and one page read in the singular, and no held back sentence at zero")
        check(LiveCues.webTodayLine(loaded(answeredAPI(3, v3Body() + webBlock(cues: #"{"searches":0,"pagesRead":0}"#, ask: #"{"searches":0,"pagesRead":0}"#,
                                                                           fact: #"{"searches":0,"pagesRead":0}"#, total: 0)))?.v3?.webToday)
              == "Web today: 0 searches (cues 0, assistant 0, fact checks 0), 0 pages read.", "a ledger that was read and is empty says zero")
        // Never a fake zero: no block (an older server), a ledger the server could not read, or a block missing any part shows nothing.
        check(loaded(answeredAPI(3, v3Body()))?.v3?.webToday == nil && LiveCues.webTodayLine(loaded(answeredAPI(3, v3Body()))?.v3?.webToday) == nil, "an older server sends no ledger: no line")
        check(loaded(answeredAPI(3, v3Body() + webBlock(readable: false)))?.v3?.webToday == nil, "a ledger the server could not read shows nothing, never its zeros")
        check(loaded(answeredAPI(3, v3Body() + webBlock(ask: #"{"searches":3}"#)))?.v3?.webToday == nil
              && loaded(answeredAPI(3, v3Body() + #","webToday":{"readable":true,"cues":{"searches":0,"pagesRead":0}}"#))?.v3?.webToday == nil
              && loaded(answeredAPI(3, v3Body() + webBlock(cues: #"{"searches":-1,"pagesRead":0}"#)))?.v3?.webToday == nil, "a block missing a part, or with a negative count, shows nothing")
        check(loaded(answeredAPI(3, v3Body() + webBlock()))?.v3?.today == v3?.today && loaded(answeredAPI(3, v3Body() + webBlock()))?.v3?.mode == v3?.mode,
              "the ledger leaves the general counters and the rest of v3 as they were")
        for text in [LiveCues.webTodayLine(webAnswer?.v3?.webToday)!, LiveCues.generalUsageLine(LiveCuesGeneralToday(topicCalls: 4, webSearches: 2, breakerOpenUntil: nil))] {
            check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->"), "no em dash or arrow: \(text)")
        }

        // ── 0.5.365: the limit steppers. A step during a save never kills the save, and an old failure never outlives a later save.
        // `holding` is a helper that honors cancellation the way the real one does: a cancelled call ends with CancellationError
        // (the helper is terminated) and counts as killed, while the POST has already reached the server (`applied`).
        final class Flight { var killed = 0; var applied: [[String]] = []; var serverGate = "0.8" }
        func echoGate(_ value: String) -> [String: JSONValue] {
            answered(200, withLimits(shape(enabled: true, available: true), limitsJSON.replacingOccurrences(of: #""value":0.8,"#, with: #""value":\#(value),"#)))
        }
        /// How the stand-in helper treats a limits save: it answers, it answers 500 the first time, or it throws (as a helper that
        /// timed out or exited non-zero does) after the server applied the POST, or before.
        enum Save { case answers, fails500First, throwsAfterApply, throwsBeforeApply }
        func holding(_ calls: Calls, _ flight: Flight, _ gate: Gate, _ save: Save = .answers) -> LiveCuesStore.Run {
            var writes = 0
            return { args, _ in
                if args.count == 1 { return HelperResponse(ok: true, message: "x", details: echoGate(flight.serverGate)) }
                calls.log.append(args); flight.applied.append(args); writes += 1
                if save != .throwsBeforeApply { flight.serverGate = args[2] }
                let mine = writes
                while !gate.open {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { flight.killed += 1; throw CancellationError() }
                }
                if save == .throwsAfterApply || save == .throwsBeforeApply { throw NSError(domain: "helper", code: 2, userInfo: [NSLocalizedDescriptionKey: "helper timed out"]) }
                if save == .fails500First && mine == 1 { return HelperResponse(ok: true, message: "x", details: answered(500)) }
                return HelperResponse(ok: true, message: "x", details: echoGate(args[2]))
            }
        }
        func settle(_ done: () -> Bool) async { var n = 0; while !done() && n < 400 { try? await Task.sleep(for: .milliseconds(10)); n += 1 } }
        /// A store whose waits run on a clock this check drives by hand: no real time is slept, so a loaded machine changes nothing.
        func stepper(_ calls: Calls, _ clock: ManualClock) async -> LiveCuesStore {
            let store = LiveCuesStore()
            store.limitsSleep = clock.sleep
            await store.load(fake(calls, [echoGate("0.8")]))
            return store
        }

        // Rapid steps coalesce to one send with the last value.
        let burstClock = ManualClock(); let burstCalls = Calls(); let burstFlight = Flight(); let burstGate = Gate(); burstGate.open = true
        let burst = await stepper(burstCalls, burstClock)
        let burstRun = holding(burstCalls, burstFlight, burstGate)
        for value in ["0.55", "0.6", "0.65", "0.7", "0.75"] { burst.propose(.gate, Double(value)!, run: burstRun); await burstClock.advance(100) }
        check(burstFlight.applied.isEmpty && burst.pendingLimits == [.gate: 0.75], "nothing is sent while the person keeps stepping")
        await burstClock.advance(600)
        await settle { burstFlight.applied.count == 1 && !burst.busy }
        await burstClock.advance(2_000)
        check(burstFlight.applied == [["live-cues-settings", "--gate", "0.75"]] && burstFlight.killed == 0 && burst.settings?.limits?.values[.gate]?.value == 0.75
              && burst.pendingLimits.isEmpty && burst.limitsNote == nil, "five quick steps are one send, with the last value, and no note")

        // A save in flight is never killed by a newer step; the newer value goes after it.
        let raceClock = ManualClock(); let raceCalls = Calls(); let raceFlight = Flight(); let raceGate = Gate()
        let race = await stepper(raceCalls, raceClock)
        let raceRun = holding(raceCalls, raceFlight, raceGate)
        race.propose(.gate, 0.7, run: raceRun)
        await raceClock.advance(600)
        await settle { raceFlight.applied.count == 1 }
        check(raceFlight.applied == [["live-cues-settings", "--gate", "0.70"]] && race.busy, "the first value is out")
        race.propose(.gate, 0.75, run: raceRun)
        await raceClock.advance(700)
        race.propose(.gate, 0.85, run: raceRun)
        await raceClock.advance(700)
        check(raceFlight.killed == 0 && race.limitsNote == nil && raceFlight.applied.count == 1, "steps during the save do not kill it and send nothing while it is out")
        raceGate.open = true
        await settle { !race.busy }
        await raceClock.advance(100)
        await settle { raceFlight.applied.count == 2 && !race.busy }
        await raceClock.advance(2_000)
        check(raceFlight.applied == [["live-cues-settings", "--gate", "0.70"], ["live-cues-settings", "--gate", "0.85"]] && raceFlight.killed == 0,
              "the newer value is sent once, after the first save finished, and nothing was cancelled")
        check(race.limitsNote == nil && race.pendingLimits.isEmpty && race.settings?.limits?.values[.gate]?.value == 0.85,
              "no 'could not save' note after a save that landed; the card shows the server's last value")

        // Stepping back to the value the server still shows, while a different one is on its way, is a change: it is sent next.
        let backClock = ManualClock(); let backCalls = Calls(); let backFlight = Flight(); let backGate = Gate()
        let back = await stepper(backCalls, backClock)
        let backRun = holding(backCalls, backFlight, backGate)
        back.propose(.gate, 0.7, run: backRun)
        await backClock.advance(600)
        await settle { backFlight.applied.count == 1 }
        back.propose(.gate, 0.8, run: backRun)
        check(back.pendingLimits == [.gate: 0.8] && back.limitValue(.gate) == 0.8, "back to the server's old value while 0.70 is out stays waiting, and shows")
        backGate.open = true
        await settle { !back.busy }
        check(back.settings?.limits?.values[.gate]?.value == 0.7 && back.pendingLimits == [.gate: 0.8], "the first value landed; the step back still waits")
        await backClock.advance(700)
        await settle { backFlight.applied.count == 2 && !back.busy }
        await backClock.advance(2_000)
        check(backFlight.applied.last == ["live-cues-settings", "--gate", "0.80"] && backFlight.serverGate == "0.80" && back.settings?.limits?.values[.gate]?.value == 0.8
              && back.pendingLimits.isEmpty && back.limitsNote == nil, "the undone value is sent after the first lands, and the server ends where the person left it")
        // And stepping to the value already on its way asks for nothing more.
        let sameClock = ManualClock(); let sameCalls = Calls(); let sameFlight = Flight(); let sameGate = Gate()
        let same = await stepper(sameCalls, sameClock)
        let sameRun = holding(sameCalls, sameFlight, sameGate)
        same.propose(.gate, 0.7, run: sameRun)
        await sameClock.advance(600)
        await settle { sameFlight.applied.count == 1 }
        same.propose(.gate, 0.7, run: sameRun)
        check(same.pendingLimits.isEmpty && same.limitValue(.gate) == 0.7, "the value already on its way is shown and not sent twice")
        sameGate.open = true
        await settle { !same.busy }
        await sameClock.advance(2_000)
        check(sameFlight.applied.count == 1, "no second send")

        // An old failure clears when a later save lands.
        let staleClock = ManualClock(); let staleCalls = Calls(); let staleFlight = Flight(); let staleGate = Gate()
        let stale = await stepper(staleCalls, staleClock)
        let staleRun = holding(staleCalls, staleFlight, staleGate, .fails500First)
        stale.propose(.gate, 0.7, run: staleRun)
        await staleClock.advance(600)
        await settle { staleFlight.applied.count == 1 }
        stale.propose(.gate, 0.6, run: staleRun)
        staleGate.open = true
        await settle { !stale.busy }
        await staleClock.advance(700)
        await settle { staleFlight.applied.count == 2 && !stale.busy }
        await staleClock.advance(2_000)
        check(staleFlight.applied.count == 2 && staleFlight.killed == 0 && stale.limitsNote == nil && stale.settings?.limits?.values[.gate]?.value == 0.6,
              "the first save failed (500), the second landed: the failure note is gone")
        let failed = LiveCuesStore(); let failedCalls = Calls()
        await failed.load(fake(failedCalls, [echoGate("0.8")]))
        failed.limitsDebounce = .seconds(60)
        failed.propose(.gate, 0.7, run: fake(failedCalls, []))
        await failed.flushLimits(fake(failedCalls, [answered(500)]))
        check(failed.limitsNote == "The limit was not saved (HTTP 500). Try again.", "a real failure still says so")
        check(failed.limitValue(.gate) == 0.8, "after a failure the card shows the server's value, not the one that was out")
        failed.propose(.gate, 0.7, run: fake(failedCalls, []))
        check(failed.pendingLimits == [.gate: 0.7], "and asking for that value again is a new change, sent next")

        // A wait that has run out behind a save is still a wait: a newer step restarts it instead of sending the half-made value early.
        let queuedClock = ManualClock(); let queuedCalls = Calls(); let queuedFlight = Flight(); let queuedGate = Gate()
        let queued = await stepper(queuedCalls, queuedClock)
        let queuedRun = holding(queuedCalls, queuedFlight, queuedGate)
        queued.propose(.gate, 0.6, run: queuedRun)
        await queuedClock.advance(600)
        await settle { queuedFlight.applied.count == 1 }
        await queuedClock.advance(50)
        queued.propose(.gate, 0.7, run: queuedRun)
        await queuedClock.advance(650)
        queued.propose(.gate, 0.75, run: queuedRun)
        queuedGate.open = true
        await settle { !queued.busy }
        await queuedClock.advance(200)
        check(queuedFlight.applied.count == 1 && queuedFlight.killed == 0, "a step behind a save restarts the wait: nothing is sent 200 ms after the save landed")
        await queuedClock.advance(500)
        await settle { queuedFlight.applied.count == 2 && !queued.busy }
        await queuedClock.advance(2_000)
        check(queuedFlight.applied.last == ["live-cues-settings", "--gate", "0.75"] && queuedFlight.killed == 0 && queued.limitsNote == nil, "then the last step goes once")

        // A save whose helper throws (a timeout, a non-zero exit) is read back, not assumed lost: when the server applied it there is no note.
        for (save, landed) in [(Save.throwsAfterApply, true), (Save.throwsBeforeApply, false)] {
            let calls = Calls(); let flight = Flight(); let gate = Gate(); gate.open = true
            let thrown = LiveCuesStore()
            thrown.limitsDebounce = .seconds(60)
            await thrown.load(fake(calls, [echoGate("0.8")]))
            let run = holding(calls, flight, gate, save)
            thrown.propose(.gate, 0.75, run: run)
            await thrown.flushLimits(run)
            check(thrown.settings?.limits?.values[.gate]?.value == (landed ? 0.75 : 0.8) && thrown.pendingLimits.isEmpty && !thrown.busy
                  && (thrown.limitsNote == nil) == landed && (landed || thrown.limitsNote == "COS Control could not save the limit. Try again."),
                  landed ? "a save that the server applied before the helper threw shows the server's value and no note" : "a save that never reached the server says so, and shows the old value")
        }
        let blind = LiveCuesStore(); let blindCalls = Calls()
        blind.limitsDebounce = .seconds(60)
        await blind.load(fake(blindCalls, [echoGate("0.8")]))
        blind.propose(.gate, 0.75, run: fake(blindCalls, []))
        await blind.flushLimits(fake(blindCalls, []))
        check(blind.limitsNote == "COS Control could not save the limit. Try again." && blind.settings?.limits?.values[.gate]?.value == 0.8 && !blind.busy,
              "when the read back fails too, the note says it could not be saved and the old value stays")

        // A cancelled save is read back the same way: no note, the server's value shows.
        let gone = LiveCuesStore(); let goneCalls = Calls(); let goneFlight = Flight(); let goneGate = Gate()
        gone.limitsDebounce = .seconds(60)
        await gone.load(fake(goneCalls, [echoGate("0.8")]))
        gone.propose(.gate, 0.75, run: holding(goneCalls, goneFlight, goneGate))
        let goneRun = holding(goneCalls, goneFlight, goneGate)
        let goneTask = Task { await gone.flushLimits(goneRun) }
        await settle { goneFlight.applied.count == 1 }
        goneTask.cancel()
        await goneTask.value
        check(goneFlight.killed == 1 && gone.limitsNote == nil && gone.pendingLimits.isEmpty && !gone.busy && gone.settings?.limits?.values[.gate]?.value == 0.75
              && Array(goneCalls.log.suffix(1)) == [["live-cues-settings", "--gate", "0.75"]],
              "a cancelled save leaves no note and no waiting value, and the card shows what the server holds (it had applied the POST) after a fresh read")

        print("live cues checks: \(passed) passed")
    }
}

/// A clock the checks drive by hand. `sleep` registers a waiter that ends only when `advance` reaches its time (or its task is
/// cancelled, which throws, as `Task.sleep` does), so debounce and polling waits take no real time and cannot be reordered by load.
@MainActor final class ManualClock {
    private var now = 0, next = 0
    private var waiters: [Int: (due: Int, cont: CheckedContinuation<Void, Error>)] = [:]

    var sleep: (Duration) async throws -> Void { { [self] duration in try await self.wait(duration) } }

    func wait(_ duration: Duration) async throws {
        let ms = Int(duration.components.seconds) * 1_000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        let id = next; next += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()) } else { waiters[id] = (now + ms, cont) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) { waiters.removeValue(forKey: id)?.cont.resume(throwing: CancellationError()) }

    /// Lets every ready task run until none is.
    private func drain() async { for _ in 0..<60 { await Task.yield() } }

    /// Moves time forward, waking each waiter at its own time, in order, and letting what it does run before the next.
    func advance(_ ms: Int) async {
        let target = now + ms
        while true {
            await drain()
            guard let (id, waiter) = waiters.min(by: { $0.value.due < $1.value.due }), waiter.due <= target else { break }
            now = max(now, waiter.due)
            waiters.removeValue(forKey: id)
            waiter.cont.resume()
        }
        now = target
        await drain()
    }
}
