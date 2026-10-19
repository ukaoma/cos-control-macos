import Foundation

/// K1 P10: key lanes in COS Control (KeyLanes and KeyLanesStore in Sources/KeyLanes.swift), executed. Compiled against
/// KeyLanes.swift and Models.swift alone by Tests/run-key-lanes.sh, with a stand-in for the helper: no helper binary,
/// no server, no window, and a throwaway defaults suite. Prints "key lanes checks: N passed".
@main struct KeyLanesChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("key lanes check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    static func details(_ json: String) -> [String: JSONValue] {
        let wrapped = #"{"ok":true,"message":"x","details":"# + json + "}"
        return try! JSONDecoder().decode(HelperResponse.self, from: Data(wrapped.utf8)).details
    }
    static func answered(_ status: Int, _ body: String = "") -> [String: JSONValue] {
        details(#"{"transport":"answered","httpStatus":"# + "\(status)" + (body.isEmpty ? "" : "," + body) + "}")
    }
    static func freshDefaults() -> UserDefaults {
        let name = "cos.key-lanes-checks.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    static func status(_ fields: [String: JSONValue]) -> ServerStatus { ServerStatus(fields) }

    /// A stand-in helper: records every call (arguments and stdin) and answers from a table keyed by the action.
    @MainActor final class Helper {
        var calls: [(args: [String], input: Data?)] = []
        var answers: [String: [String: JSONValue]] = [:]
        var run: KeyLanesStore.Run {
            { args, input in
                self.calls.append((args, input))
                let action = args.count > 1 ? args[1] : ""
                return HelperResponse(ok: true, message: "x", details: self.answers[action] ?? answered(500, #""error":"boom""#))
            }
        }
        var everyArgument: String { calls.flatMap(\.args).joined(separator: " ") }
    }

    static let secret = "sk-or-v1-0123456789abcdef0123456789abcdef9f3c"
    static let keyRef = "key_0123456789ab"
    static let statusOn = answered(200, #""enabled":true,"active":true,"keys":[{"ref":"key_0123456789ab","kind":"openrouter","last4":"9f3c","capUsd":1,"spentTodayUsd":0.12,"breaker":{"open":false,"failures":0}}],"profiles":[{"id":"k-0123456789ab","label":"Sonnet 5.5","keyRef":"key_0123456789ab","engine":"claude","model":"anthropic/claude-sonnet-5.5","enabled":true}],"keyedSessionIds":["0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"]"#)
    static let catalog = answered(200, #""curated":[{"id":"anthropic/claude-sonnet-5.5","name":"Claude Sonnet 5.5","inUsdPerM":2,"outUsdPerM":10,"role":"default"},{"id":"anthropic/claude-haiku-5.5","name":"Claude Haiku 5.5","inUsdPerM":0.1,"outUsdPerM":0.5,"role":"cheaper"}],"pricesFrom":"openrouter""#)

    @MainActor static func main() async {
        // ── Which servers see anything (plan 3: older servers never do).
        check(KeyLanes.serverSupports("6.80.0"), "6.80.0 supports key lanes")
        check(KeyLanes.serverSupports("6.80.0-next.3"), "the K1 prerelease 6.80.0-next.N supports key lanes")
        check(KeyLanes.serverSupports("6.81.2") && KeyLanes.serverSupports("6.100.0") && KeyLanes.serverSupports("7.0.0"), "later servers support key lanes")
        check(!KeyLanes.serverSupports("6.79.0") && !KeyLanes.serverSupports("6.79.99") && !KeyLanes.serverSupports("5.99.0"), "6.79 and older do not")
        check(!KeyLanes.serverSupports(nil) && !KeyLanes.serverSupports("") && !KeyLanes.serverSupports("6.80") && !KeyLanes.serverSupports("six"),
              "no version or a malformed one does not")

        // ── The Settings row.
        check(!KeyLanes.rowVisible(serverVersion: "6.79.0", enabled: false), "the Settings row is hidden on 6.79.0 with no key-lane answer (the golden)")
        check(!KeyLanes.rowVisible(serverVersion: nil, enabled: false), "the Settings row is hidden before a version is known")
        check(KeyLanes.rowVisible(serverVersion: "6.80.0", enabled: false), "the Settings row shows Off on 6.80.0 (plan 3.2, the one allowed row)")
        check(KeyLanes.rowVisible(serverVersion: "6.79.0", enabled: true), "the Settings row is shown when lanes are on")
        check(KeyLanes.rowVisible(serverVersion: "6.80.0", enabled: true), "the Settings row stays when lanes are on, on 6.80.0")

        // ── New install or existing (plan D12).
        check(KeyLanes.classifyInstall(stored: nil, needsFirstRun: true, runtimeState: "notInstalled", priorSetup: false) == .new,
              "first run with no earlier setup is a new install")
        check(KeyLanes.classifyInstall(stored: nil, needsFirstRun: true, runtimeState: "notInstalled", priorSetup: true) == .existing,
              "first run on a Mac that finished setup before is existing")
        check(KeyLanes.classifyInstall(stored: nil, needsFirstRun: false, runtimeState: "managedHealthy", priorSetup: false) == .existing,
              "a running server is existing")
        check(KeyLanes.classifyInstall(stored: nil, needsFirstRun: false, runtimeState: "unknown", priorSetup: false) == nil,
              "an unknown runtime decides nothing")
        check(KeyLanes.classifyInstall(stored: "new", needsFirstRun: false, runtimeState: "managedHealthy", priorSetup: true) == .new,
              "a decided install stays decided")

        // ── The setup step.
        check(!KeyLanes.setupStepVisible(install: .existing, serverVersion: "6.80.0", enabled: false, skipped: false, hasKey: false),
              "an existing install never sees the key step with lanes off")
        check(!KeyLanes.setupStepVisible(install: nil, serverVersion: "6.80.0", enabled: false, skipped: false, hasKey: false),
              "an undecided install does not see the key step")
        check(KeyLanes.setupStepVisible(install: .new, serverVersion: "6.80.0", enabled: false, skipped: false, hasKey: false),
              "a new install sees the key step on 6.80.0")
        check(!KeyLanes.setupStepVisible(install: .new, serverVersion: "6.79.0", enabled: false, skipped: false, hasKey: false),
              "a new install does not see the key step on 6.79.0")
        check(KeyLanes.setupStepVisible(install: .existing, serverVersion: "6.80.0", enabled: true, skipped: false, hasKey: false),
              "an existing install sees the key step once lanes are on")
        check(!KeyLanes.setupStepVisible(install: .new, serverVersion: "6.80.0", enabled: false, skipped: true, hasKey: false), "Skip hides the step")
        check(!KeyLanes.setupStepVisible(install: .new, serverVersion: "6.80.0", enabled: true, skipped: false, hasKey: true), "a saved key hides the step")

        // ── The store decides the install from defaults and status.
        do {
            let d = freshDefaults()
            let store = KeyLanesStore(defaults: d)
            store.observe(status(["runtimeState": .string("unknown")]))
            check(store.install == nil && d.string(forKey: KeyLanes.installKey) == nil, "an unknown status writes nothing")
            store.observe(status(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent")]))
            check(store.install == .new && d.string(forKey: KeyLanes.installKey) == "new", "a fresh Mac at first run is recorded new")
            store.observe(status(["runtimeState": .string("managedHealthy"), "running": .bool(true), "installed": .bool(true)]))
            check(store.install == .new, "a new install stays new after setup finishes")
            check(KeyLanesStore(defaults: d).install == .new, "the decision survives a relaunch")
        }
        do {
            let d = freshDefaults()
            d.set(true, forKey: "cos.setupGuide.journeyFinished")
            let store = KeyLanesStore(defaults: d)
            store.observe(status(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent")]))
            check(store.install == .existing, "first run after an earlier finished setup is existing")
        }
        do {
            let d = freshDefaults()
            let store = KeyLanesStore(defaults: d)
            store.observe(status(["runtimeState": .string("managedHealthy"), "running": .bool(true), "installed": .bool(true)]))
            check(store.install == .existing, "an upgrade from 0.5.327 with a running server is existing")
        }

        // ── A key on screen: kind and last four, never the key (plan 10.1 "never echoed").
        let pendingText = KeyLanes.pendingLine(kind: "openrouter", secret: secret)
        check(pendingText == "Ready to save: OpenRouter key ending 9f3c", "the pasted key shows as its kind and last four")
        check(!pendingText.contains(String(secret.dropLast(4))) && !pendingText.contains("sk-or"), "the pasted key is not echoed in the UI")
        check(KeyLanes.keyLine(kind: "anthropic", last4: "ab12") == "Anthropic key ending ab12", "a saved key reads by kind and last four")
        check(KeyLanes.last4(secret) == "9f3c", "last four")

        // ── Words.
        check(KeyLanes.problem(nil) == KeyLanes.unreachable, "a helper that failed is unreachable")
        check(KeyLanes.problem(details(#"{"transport":"unsupported","httpStatus":404}"#)) == KeyLanes.cannotEnable, "a 404 page says COS did not turn keys on")
        check(KeyLanes.problem(answered(200)) == nil, "a 200 is no problem")
        check(KeyLanes.problem(answered(409, #""error":"keyed_session","message":"x""#)) == KeyLanes.keyedSessionRefusal, "keyed_session reads as the refusal")
        check(KeyLanes.problem(answered(422, #""error":"key_rejected","message":"OpenRouter rejected this key. Check it and paste it again.""#))
              == "OpenRouter rejected this key. Check it and paste it again.", "a refusal shows the server's sentence")
        check(KeyLanes.problem(answered(422, #""error":"no_credit_limit""#)) == KeyLanes.noCreditLimitLine, "no credit limit")
        check(KeyLanes.keyRejectedLine("openrouter") == "Your OpenRouter key was rejected. Fix it in COS Control.", "key rejected line")
        check(KeyLanes.modelLabel("anthropic/claude-sonnet-5.5") == "Sonnet 5.5" && KeyLanes.modelLabel("claude-haiku-5-5") == "Haiku 5.5", "model labels")
        check(KeyLanes.profileModel(slug: "anthropic/claude-sonnet-5.5", kind: "openrouter") == "anthropic/claude-sonnet-5.5", "OpenRouter keeps the slug")
        check(KeyLanes.profileModel(slug: "anthropic/claude-sonnet-5.5", kind: "anthropic") == "claude-sonnet-5-5", "an Anthropic key takes the bare id")
        check(KeyLanes.profileModel(slug: "anthropic/claude-sonnet-5.5", kind: "openai") == nil, "an OpenAI key has no curated Claude model")
        check(KeyLanes.parseCap("1.00") == 1 && KeyLanes.parseCap("$2.5") == 2.5 && KeyLanes.parseCap("0") == nil && KeyLanes.parseCap("1001") == nil
              && KeyLanes.parseCap("1.001") == nil, "caps are $0.01 to $1000, cents")
        check(KeyLanes.defaultCapUsd == 1.0, "the default cap is $1 (D11)")
        check(KeyLanes.localFirstLine(claudeReady: true, codexReady: nil, ollamaReady: false) == "You already have Claude. A key is optional.", "local first")
        check(KeyLanes.localFirstLine(claudeReady: false, codexReady: false, ollamaReady: false) == nil, "no local AI, no line")
        check(KeyLanes.profileID(forKey: keyRef) == "k-0123456789ab", "one profile per key")

        // ── Status decode.
        check(KeyLanesState.decode(details(#"{"transport":"unsupported","httpStatus":404}"#)) == .off, "lanes off on the server read as off")
        check(KeyLanesState.decode(details(#"{"transport":"unavailable"}"#)) == nil, "unreachable keeps what is shown")
        let on = KeyLanesState.decode(statusOn)
        check(on?.enabled == true && on?.keys.first?.last4 == "9f3c" && on?.keys.first?.spentTodayUsd == 0.12 && on?.profiles.first?.model == "anthropic/claude-sonnet-5.5",
              "a status decodes keys and profiles")
        check(KeyLanes.capLine(on!.keys[0]) == "Cap $1.00 a day. $0.12 spent today.", "cap line")
        let models = (catalog["curated"]?.array ?? []).compactMap(KeyLanesModel.init)
        check(models.map { KeyLanes.priceLine($0) } == ["Sonnet 5.5, $2 in, $10 out per M", "Haiku 5.5, $0.1 in, $0.5 out per M"],
              "the model choice is the server's curated two, with prices")

        // ── Lanes never used: nothing is read, nothing is written, nothing is refused (the HARD RULE).
        do {
            let d = freshDefaults()
            let store = KeyLanesStore(defaults: d)
            check(store.refusal(sessionID: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0") == nil && store.refusal(sessionID: nil) == nil,
                  "with no key-lane answer Continue and Fork are never refused")
            check(store.state == nil && !store.enabled && !store.hasKey, "with no key-lane answer the store is empty")
            check(d.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("cos.keyLanes") }, "with no key-lane answer nothing is written")
            let helper = Helper()
            helper.answers["status"] = details(#"{"transport":"unsupported","httpStatus":404}"#)
            await store.refresh(run: helper.run)
            check(store.state == .off && store.refusal(sessionID: "anything") == nil, "a lanes-off server reads off and refuses nothing")
            check(d.stringArray(forKey: KeyLanesStore.keyedSessionsKey) == nil, "a lanes-off server writes no keyed sessions")
        }

        // ── Turning lanes on, saving a key, the model, the cap, removing.
        do {
            let d = freshDefaults()
            let store = KeyLanesStore(defaults: d)
            let helper = Helper()
            helper.answers["enable"] = answered(200, #""enabled":true,"active":false"#)
            helper.answers["status"] = answered(200, #""enabled":true,"active":false,"keys":[],"profiles":[],"keyedSessionIds":[]"#)
            helper.answers["catalog"] = catalog
            await store.enable(run: helper.run)
            check(helper.calls.map { $0.args } == [["key-lanes", "enable"], ["key-lanes", "status"], ["key-lanes", "catalog"]],
                  "turning it on calls the enable door, reads the status, then the curated models")
            check(store.enabled && store.line == nil && store.catalog.count == 2, "on, with the server's two curated models")

            helper.calls = []
            helper.answers["save-key"] = answered(200, #""key":{"ref":"key_0123456789ab","kind":"openrouter","last4":"9f3c","capUsd":1}"#)
            helper.answers["save-profile"] = answered(200, #""profile":{},"active":true"#)
            helper.answers["status"] = statusOn
            let saved = await store.saveKey(kind: "openrouter", secret: secret, capUsd: 1, run: helper.run)
            check(saved, "a key saves")
            check(helper.calls.first?.args == ["key-lanes", "save-key"], "save-key takes no arguments")
            check(!helper.everyArgument.contains(secret) && !helper.everyArgument.contains("sk-or"), "the key is never passed in argv")
            let keyInput = helper.calls.first?.input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check(keyInput?["key"] as? String == secret && keyInput?["kind"] as? String == "openrouter" && keyInput?["capUsd"] as? Double == 1,
                  "the key goes on stdin with its kind and cap")
            let profile = helper.calls.first { $0.args == ["key-lanes", "save-profile"] }?.input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check(profile?["model"] as? String == "anthropic/claude-sonnet-5.5" && profile?["id"] as? String == "k-0123456789ab"
                  && profile?["engine"] as? String == "claude" && profile?["timeoutTier"] as? String == "sonnet" && profile?["keyRef"] as? String == keyRef,
                  "the default model (Sonnet 5.5) becomes the key's profile")
            check(helper.calls.filter { $0.args[1] != "save-key" }.allSatisfy { $0.input.map { !String(decoding: $0, as: UTF8.self).contains(secret) } ?? true },
                  "no other call carries the key")
            check(!"\(store.state as Any) \(store.line as Any) \(store.catalog)".contains(secret), "the store keeps no copy of the key")
            check(store.justSaved == "Sonnet 5.5" && KeyLanes.glassesHint("Sonnet 5.5") == "On the glasses: Model, then Key: Sonnet 5.5.",
                  "after the first save Control says where to pick the key on the lens (QA U8)")
            check(store.savedKeys == 1 && d.integer(forKey: KeyLanesStore.savedKeysKey) == 1, "a lanes-on status records how many keys are saved (QA U7)")

            helper.calls = []
            helper.answers["reset-breaker"] = answered(200, #""reset":true,"breaker":{"open":false,"failures":0}"#)
            await store.resetBreaker(keyRef, run: helper.run)
            check(helper.calls.first?.args == ["key-lanes", "reset-breaker", "--ref", keyRef] && store.line == nil, "Reset pause resets the key's breaker (QA U6)")
            helper.calls = []
            await store.setProfileEnabled(store.state!.profiles[0], false, run: helper.run)
            let off = helper.calls.first?.input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check(helper.calls.first?.args == ["key-lanes", "save-profile"] && off?["enabled"] as? Bool == false && off?["model"] as? String == "anthropic/claude-sonnet-5.5"
                  && off?["timeoutTier"] as? String == "sonnet", "Use for answers off turns the key's profile off, nothing else changed (QA U6)")

            helper.calls = []
            await store.chooseModel("anthropic/claude-haiku-5.5", keyRef: keyRef, kind: "openrouter", run: helper.run)
            let haiku = helper.calls.first?.input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check(haiku?["model"] as? String == "anthropic/claude-haiku-5.5" && haiku?["timeoutTier"] as? String == "haiku" && haiku?["label"] as? String == "Haiku 5.5",
                  "picking Haiku 5.5 rewrites the key's profile")

            helper.calls = []
            helper.answers["set-cap"] = answered(200, #""key":{"ref":"key_0123456789ab","kind":"openrouter","last4":"9f3c","capUsd":2.5}"#)
            await store.setCap(2.5, keyRef: keyRef, run: helper.run)
            check(helper.calls.first?.args == ["key-lanes", "set-cap", "--ref", keyRef, "--cap", "2.50"], "a cap change names the key and the cap")

            // Keyed sessions refuse Continue and Fork, and keep refusing after lanes are off.
            check(store.refusal(sessionID: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0") == KeyLanes.keyedSessionRefusal, "a keyed session is refused on Continue and Fork")
            check(store.refusal(sessionID: "11111111-2222-3333-4444-555555555555") == nil, "another session is not refused")

            helper.calls = []
            helper.answers["remove-key"] = answered(200, #""removed":true,"disabledProfiles":["k-0123456789ab"],"active":false"#)
            helper.answers["delete-profile"] = answered(200, #""removed":true,"active":false"#)
            await store.removeKey(keyRef, run: helper.run)
            check(helper.calls.map { $0.args } == [["key-lanes", "remove-key", "--ref", keyRef, "--force"], ["key-lanes", "delete-profile", "--id", "k-0123456789ab"],
                                                     ["key-lanes", "status"]], "Remove deletes the key, then its profile")

            helper.calls = []
            helper.answers["remove-all"] = answered(200, #""removed":["keys","profiles","ledger"],"enabled":false,"active":false,"ledgerExportedTo":"/Users/you/Downloads/cos-key-ledger-2026-10-19.jsonl""#)
            helper.answers["status"] = details(#"{"transport":"unsupported","httpStatus":404}"#)
            await store.removeAll(exportLedger: true, run: helper.run)
            check(helper.calls.first?.args == ["key-lanes", "remove-all", "--export-ledger"], "Remove all keys with the ledger export")
            check(store.state == .off && !store.enabled, "after Remove all keys lanes read off")
            check(store.savedKeys == 0 && d.object(forKey: KeyLanesStore.savedKeysKey) == nil, "after Remove all keys no saved keys are remembered")
            check(store.line == "Spend ledger saved to /Users/you/Downloads/cos-key-ledger-2026-10-19.jsonl.", "the export path is shown")
            check(store.refusal(sessionID: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0") == KeyLanes.keyedSessionRefusal,
                  "a keyed session stays refused after Remove all keys")
            check(KeyLanesStore(defaults: d).refusal(sessionID: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0") == KeyLanes.keyedSessionRefusal,
                  "a keyed session stays refused after a relaunch")
        }

        // ── A refused save keeps nothing and says why.
        do {
            let store = KeyLanesStore(defaults: freshDefaults())
            let helper = Helper()
            helper.answers["save-key"] = answered(422, #""error":"no_credit_limit","message":"Set a credit limit on this key at openrouter.ai first.""#)
            let saved = await store.saveKey(kind: "openrouter", secret: secret, capUsd: 1, run: helper.run)
            check(!saved && store.line == KeyLanes.noCreditLimitLine && helper.calls.count == 1, "a refused key shows the server's line and nothing else runs")
            helper.calls = []
            helper.answers["enable"] = details(#"{"transport":"unsupported","httpStatus":404}"#)
            helper.answers["status"] = details(#"{"transport":"unsupported","httpStatus":404}"#)
            await store.enable(run: helper.run)
            check(store.line == KeyLanes.cannotEnable && !store.enabled, "a server that would not turn on says so")
            store.skipSetup()
            check(store.setupSkipped, "Skip is remembered")
        }

        // ── QA U5 and U10: setup never saves a key into a dead end.
        let curated = (catalog["curated"]?.array ?? []).compactMap(KeyLanesModel.init)
        check(KeyLanes.offeredKinds(curated, claudeInstalled: true, codexInstalled: true) == ["openrouter", "anthropic"],
              "with Claude models only, OpenAI keys are not offered (QA U5)")
        check(KeyLanes.offeredKinds(curated, claudeInstalled: false, codexInstalled: true).isEmpty,
              "without Claude Code no Claude-engine profile is offered (QA U10)")
        let gpt = KeyLanesModel(JSONValue.object(["id": .string("openai/gpt-5.5"), "name": .string("GPT-5.5"), "inUsdPerM": .number(1), "outUsdPerM": .number(8)]))!
        check(KeyLanes.offeredKinds(curated + [gpt], claudeInstalled: true, codexInstalled: true) == ["openrouter", "anthropic", "openai"],
              "an OpenAI key is offered once the server lists a model it can run")
        check(KeyLanes.profileModel(slug: "openai/gpt-5.5", kind: "openai") == "gpt-5.5" && KeyLanes.engine("openai/gpt-5.5") == "codex",
              "an OpenAI key runs the bare id in Codex")
        check(KeyLanes.usableModels(curated + [gpt], kind: "openrouter", claudeInstalled: false, codexInstalled: true).map(\.id) == ["openai/gpt-5.5"],
              "only models whose CLI is on this Mac are offered")
        check(KeyLanes.setupDetail(kinds: ["openrouter", "anthropic"]) == "Answers can run on your OpenRouter or Anthropic key, with a daily cap.",
              "setup names only the offered kinds")
        check(KeyLanes.providerLimitApplies("anthropic") && KeyLanes.providerLimitApplies("openai") && !KeyLanes.providerLimitApplies("openrouter"),
              "the no-provider-limit line is for Anthropic and OpenAI keys")

        // ── QA U7: saved keys outlive a downgrade or lanes off, until removed.
        check(KeyLanes.rowVisible(serverVersion: "6.79.1", enabled: false, savedKeys: 1), "an older server still shows the row while keys are saved")
        check(!KeyLanes.rowVisible(serverVersion: "6.79.1", enabled: false, savedKeys: 0), "an older server with no saved keys shows nothing")
        check(KeyLanes.savedKeysRowVisible(enabled: false, savedKeys: 2) && !KeyLanes.savedKeysRowVisible(enabled: true, savedKeys: 2)
              && !KeyLanes.savedKeysRowVisible(enabled: false, savedKeys: 0), "Remove saved keys shows only when lanes cannot manage them")
        check(KeyLanes.savedKeysLine(serverVersion: "6.79.1") == KeyLanes.savedKeysOlderServerLine && KeyLanes.savedKeysLine(serverVersion: "6.80.0") == KeyLanes.savedKeysOffLine,
              "the saved-keys line says why")
        do {
            let d = freshDefaults()
            d.set(2, forKey: KeyLanesStore.savedKeysKey)
            let store = KeyLanesStore(defaults: d)
            check(store.savedKeys == 2, "saved keys are remembered across a relaunch")
            let helper = Helper()
            helper.answers["status"] = details(#"{"transport":"unsupported","httpStatus":404}"#)
            await store.refresh(run: helper.run)
            check(store.savedKeys == 2, "a lanes-off status does not forget saved keys")
            helper.answers["remove-saved-keys"] = details(#"{"transport":"answered","httpStatus":409,"error":"busy","message":"COS is recording or answering right now. Remove saved keys when it finishes."}"#)
            await store.removeSavedKeys(run: helper.run)
            check(store.savedKeys == 2 && store.line == "COS is recording or answering right now. Remove saved keys when it finishes.", "a busy server keeps the keys and says why")
            helper.answers["remove-saved-keys"] = details(#"{"transport":"answered","httpStatus":200,"removed":["provider-keys.json"],"via":"disk"}"#)
            await store.removeSavedKeys(run: helper.run)
            check(store.savedKeys == 0 && d.object(forKey: KeyLanesStore.savedKeysKey) == nil && store.line == KeyLanes.savedKeysRemovedLine,
                  "Remove saved keys forgets them and says so")
        }
        do {
            let store = KeyLanesStore(defaults: freshDefaults())
            let helper = Helper()
            helper.answers["catalog"] = catalog
            helper.answers["save-key"] = answered(200, #""key":{"ref":"key_0123456789ab","kind":"openrouter","last4":"9f3c","capUsd":1}"#)
            helper.answers["status"] = statusOn
            await store.saveKey(kind: "openrouter", secret: secret, capUsd: 1, claudeInstalled: false, codexInstalled: false, run: helper.run)
            check(!helper.calls.contains { $0.args == ["key-lanes", "save-profile"] } && store.justSaved == nil,
                  "without Claude Code a saved key gets no Claude profile (QA U10)")
        }

        print("key lanes checks: \(passed) passed")
    }
}
