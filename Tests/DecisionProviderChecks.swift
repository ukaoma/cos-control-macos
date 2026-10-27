import Foundation

@main struct DecisionProviderChecks {
    static func details(revision: String = String(repeating: "a", count: 64), provider: String = "jev") -> [String: JSONValue] {
        ["schema": .number(1), "revision": .string(revision), "provider": .string(provider),
         "saved": .object(["provider": .null, "overrides": .object([:])]),
         "effective": .object(["session": .string(provider), "completion": .string(provider), "search": .string(provider)]),
         "sources": .object(["session": .string("default"), "completion": .string("default"), "search": .string("default")]),
         "configured": .object(["jev": .bool(true), "subq": .bool(false)]),
         "models": .object(["jev": .string("jev-1.13.0"), "subq": .string("subq-snap-preview")])]
    }
    @MainActor static func main() async throws {
        let settings = DecisionProviderSettings(details: details())!
        precondition(settings.provider == .jev && settings.savedProvider == nil && settings.overrides.isEmpty)
        precondition(settings.effectiveText("completion").contains("Jev") && settings.effectiveText("completion").contains("default"))
        let body = settings.patch(workflow: "completion", selection: "subq")!
        precondition(body["expectedRevision"]?.string == settings.revision && body["overrides"]?.object?["completion"]?.string == "subq")
        if case .null = settings.patch(workflow: nil, selection: "inherit")!["provider"]! {} else { preconditionFailure("Clear must send JSON null") }
        if case .null = settings.patch(workflow: "search", selection: "inherit")!["overrides"]!.object!["search"]! {} else { preconditionFailure("Override clear must send JSON null") }
        precondition(settings.patch(workflow: "other", selection: "jev") == nil && settings.patch(workflow: nil, selection: "unknown") == nil)
        precondition(DecisionProviderSettings(details: details(provider: "unknown")) == nil)
        var malformed = details(); malformed["schema"] = .number(1.1)
        precondition(DecisionProviderSettings(details: malformed) == nil)
        malformed = details(); malformed["effective"] = .object(["session": .string("subq")])
        precondition(DecisionProviderSettings(details: malformed) == nil)
        precondition(DecisionProviderSettings(details: details(revision: "bad")) == nil)
        for provider in DecisionProvider.allCases {
            let advice = SessionAdvice(details: ["provider": .string(provider.rawValue), "action": .string("fork"), "sessionId": .string("codex:child"), "confidence": .number(0.9)])!
            precondition(advice.provider == provider && advice.sessionID == "codex:child")
            let verdict = WorkCompletionVerdict(details: ["provider": .string(provider.rawValue), "verdict": .string("done"), "confidence": .number(0.99), "basis": .string("done_when")])!
            precondition(verdict.movesCard && verdict.provider == provider && verdict.text.hasPrefix(provider.title))
            var progress = WorkProgress(tag: "test"); progress.reported = .done; progress.reportedBy = provider.rawValue
            precondition(WorkProgressTracker.moveReason(progress) == provider.title + " read the reply as done")
            let roundTrip = try JSONDecoder().decode(WorkProgress.self, from: JSONEncoder().encode(progress))
            precondition(roundTrip.reportedBy == provider.rawValue)
        }
        precondition(SessionAdvice(details: ["provider": .string("unknown"), "action": .string("new"), "confidence": .number(0.9)]) == nil)
        precondition(WorkCompletionVerdict(details: ["provider": .string("unknown"), "verdict": .string("done"), "confidence": .number(0.99)]) == nil)
        precondition(WorkCompletionVerdict(details: ["provider": .string("subq"), "verdict": .string("done"), "confidence": .number(.infinity)]) == nil)
        precondition(WorkHandoffStore.adviceUnavailableText("subq_not_configured")?.contains("SubQ key") == true)
        precondition(WorkSearch.note("subq_key_rejected")?.contains("SubQ") == true)
        // These are the actual server DecisionProviderError codes, not provider-specific invented prefixes.
        for (reason, fragment) in ["decision_not_configured": "API key", "decision_key_rejected": "rejected",
                                   "decision_credits_required": "credits", "decision_rate_limited": "rate limited",
                                   "decision_cap_reached": "budget", "decision_usage_unavailable": "accounting",
                                   "decision_breaker_open": "paused", "decision_invalid_provider": "invalid",
                                   "decision_request_rejected": "accept", "decision_bad_answer": "unreadable",
                                   "decision_unavailable": "unavailable", "decision_cancelled": "cancelled"] {
            precondition(DecisionProvider.failureText(reason)?.contains(fragment) == true)
            precondition(WorkSearch.note(reason)?.contains(fragment) == true)
            precondition(WorkHandoffStore.adviceUnavailableText(reason)?.contains(fragment) == true)
            precondition(WorkProgressTracker.jevUnavailableText(reason)?.contains(fragment) == true)
        }
        precondition(!WorkHandoffStore.sendBackPrompt(missing: "check", evidence: "SubQ read the reply", reportedBy: "subq").contains("status line said"))

        // Real ControllerModel + a temporary helper; no live server or model calls.
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        func fixture(_ command: String, _ values: [String: JSONValue], ok: Bool = true, message: String = "fixture") throws {
            let response: JSONValue = .object(["ok": .bool(ok), "message": .string(message), "details": .object(values)])
            try JSONEncoder().encode(response).write(to: URL(fileURLWithPath: helper.path + "." + command + ".json"))
        }
        let script = "#!/bin/sh\n/usr/bin/printf '%s\\n' \"$1\" >> \"$0.calls\"\ncase \"$1\" in *-set) /bin/cat > \"$0.$1.request\";; esac\n/bin/cat \"$0.$1.json\"\n"
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        try fixture("decision-provider-status", details())
        await model.loadDecisionSettings()
        precondition(model.decisionSettings?.provider == .jev)
        let nextRevision = String(repeating: "b", count: 64)
        try fixture("decision-provider-status", details(revision: nextRevision))
        try fixture("decision-provider-set", ["reason": .string("decision_settings_conflict")])
        await model.setDecisionProvider(workflow: "completion", selection: "subq")
        precondition(model.decisionSettings?.revision == nextRevision && model.decisionMessage?.contains("select again") == true)
        let calls = try String(contentsOfFile: helper.path + ".calls", encoding: .utf8)
        precondition(calls.split(separator: "\n").filter { $0 == "decision-provider-set" }.count == 1, "A conflict must not retry the write automatically")
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: helper.path + ".decision-provider-set.request")))
        precondition(request.object?["expectedRevision"]?.string == settings.revision)
        try fixture("subq-key-set", ["available": .bool(true), "configured": .bool(true), "source": .string("config")])
        let accepted = await model.saveSubQKey("synthetic-test-key-only")
        precondition(accepted && model.subQKeyStatus?.configured == true && model.decisionSettings?.provider == .jev, "Saving a key never selects SubQ")
        try fixture("decision-provider-set", details(revision: String(repeating: "c", count: 64), provider: "subq"))
        await model.setDecisionProvider(workflow: nil, selection: "subq")
        precondition(model.decisionSettings?.provider == .subq)
        try fixture("decision-provider-status", ["available": .bool(false)])
        await model.loadDecisionSettings()
        precondition(model.decisionSettings == nil && model.decisionSettingsAvailable == false)
        try fixture("decision-provider-status", [:], ok: false, message: "HTTP 503")
        await model.loadDecisionSettings()
        precondition(model.decisionSettings == nil && model.decisionSettingsAvailable == nil && model.decisionMessage?.contains("503") == true)
        // 0.5.352: Work suggestions and Settings' key lines, through the model's real read and refresh(). A status refresh
        // that finds the server down asks nothing; the next one that finds it running asks all three, with no restart and
        // with Settings never opened, and fills the guide's facts and Settings' Jev and SubQ lines.
        let keysModel = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        keysModel.workKeys.read = keysModel.workKeysRead(HelperClient(executableOverride: helper))
        func keyCalls() -> [Substring] {
            ((try? String(contentsOfFile: helper.path + ".calls", encoding: .utf8)) ?? "").split(separator: "\n")
                .filter { ["decision-provider-status", "jev-status", "subq-status"].contains($0) }
        }
        var both = details(provider: "subq"); both["configured"] = .object(["jev": .bool(true), "subq": .bool(true)])
        try fixture("decision-provider-status", both)
        try fixture("jev-status", ["configured": .bool(true), "source": .string("scripts-env"), "usedToday": .number(0), "dailyCap": .number(1_000_000)])
        try fixture("subq-status", ["available": .bool(true), "configured": .bool(true), "source": .string("config"), "savedAt": .string("2026-10-15T14:00:00Z")])
        try fixture("status", ["running": .bool(false)])
        let before = keyCalls().count
        await keysModel.refresh(quiet: true)
        try await Task.sleep(for: .milliseconds(200))
        precondition(keyCalls().count == before && keysModel.workKeyFacts.check == .notYet && keysModel.subQKeyStatus == nil,
                     "A server that is down is not asked about Work's keys")
        try fixture("status", ["running": .bool(true)])
        await keysModel.refresh(quiet: true)
        for _ in 0..<200 where keysModel.workKeyFacts.check != .answered { try await Task.sleep(for: .milliseconds(25)) }
        precondition(keyCalls().count == before + 3, "The server coming up asks the three key routes once")
        var expected = WorkKeyFacts(); expected.check = .answered; expected.jev = true; expected.subq = true
        expected.inUse = ["session": "subq", "completion": "subq", "search": "subq"]
        precondition(keysModel.workKeyFacts == expected, "The guide reads the server's answer: \(keysModel.workKeyFacts)")
        precondition(keysModel.subQKeyStatus?.configured == true && keysModel.subQKeyStatus?.source == "config"
                     && keysModel.jevStatus?.configured == true && keysModel.jevStatus?.source == "scripts-env",
                     "Settings' SubQ and Jev lines are filled without opening Settings")
        var guideFacts = SetupFacts(); guideFacts.serverRunning = true; guideFacts.workKeys = keysModel.workKeyFacts
        precondition(SetupGuideRules.workSuggestions(guideFacts, skipped: false).status == "SubQ in use (Jev key also saved)")
        await keysModel.refresh(quiet: true)
        try await Task.sleep(for: .milliseconds(200))
        precondition(keyCalls().count == before + 3, "A later refresh keeps a fresh answer instead of asking again")
        print("PASS decision provider: known identities, inheritance/null clears, revision conflict without write retry, accurate provenance, key save never selects SubQ, old/unavailable servers, Work keys asked when the server comes up")
    }
}
