import Foundation

/// K1 P10: KeyLanesHelperCore (HelperSources/ProviderStatusCore.swift), the helper's key-lanes grammar, stdin bodies and
/// whitelist, executed alone (Foundation only). Prints "key lanes helper core checks: N passed".
@main struct KeyLanesHelperChecks {
    nonisolated(unsafe) static var passed = 0
    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("key lanes helper core check FAILED: \(what)"); exit(1) }
        passed += 1
    }
    static func json(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }
    static func text(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static let secret = "sk-or-v1-0123456789abcdef0123456789abcdef9f3c"
    static let ref = "key_0123456789ab"

    static func main() {
        typealias C = KeyLanesHelperCore
        // ── Grammar.
        check(C.plan(["status"]) == .init(action: "status", method: "GET", path: "/api/key-lanes/status", body: nil, stdin: .none, timeout: 10), "status is a GET")
        check(C.plan(["enable"])?.method == "POST" && C.plan(["enable"])?.path == "/api/key-lanes/enable" && C.plan(["enable"])?.body == [:], "enable posts {}")
        check(C.plan(["disable"])?.path == "/api/key-lanes/disable", "disable")
        check(C.plan(["catalog"])?.path == "/api/key-lanes/catalog" && C.plan(["catalog"])?.method == "GET", "catalog")
        check(C.plan(["save-key"]) == .init(action: "save-key", method: "POST", path: "/api/key-lanes/keys", body: nil, stdin: .key, timeout: 25),
              "save-key reads the key from stdin")
        check(C.plan(["save-key", secret]) == nil && C.plan(["save-key", "--key", secret]) == nil && C.plan(["status", secret]) == nil,
              "a key passed in argv is refused before any request")
        check(C.plan(["save-profile"])?.stdin == .profile && C.plan(["save-profile", "x"]) == nil, "save-profile reads stdin and nothing else")
        check(C.plan(["set-cap", "--ref", ref, "--cap", "2.5"])?.body == ["ref": ref, "capUsd": "2.50"], "set-cap posts the ref and cap")
        check(C.plan(["set-cap", "--ref", "key_x", "--cap", "2"]) == nil && C.plan(["set-cap", "--ref", ref, "--cap", "0"]) == nil
              && C.plan(["set-cap", "--ref", ref, "--cap", "1001"]) == nil, "set-cap refuses a bad ref or cap")
        check(C.plan(["remove-key", "--ref", ref])?.path == "/api/key-lanes/keys/\(ref)" && C.plan(["remove-key", "--ref", ref])?.method == "DELETE",
              "remove-key is DELETE /keys/:ref")
        check(C.plan(["remove-key", "--ref", ref, "--force"])?.path == "/api/key-lanes/keys/\(ref)?force=1", "remove-key --force")
        check(C.plan(["remove-key", "--ref", "../status"]) == nil, "remove-key refuses a path in the ref")
        check(C.plan(["remove-all"])?.body == ["exportLedger": "false"] && C.plan(["remove-all", "--export-ledger"])?.body == ["exportLedger": "true"],
              "remove-all with and without the ledger export")
        check(C.fixedBody(["exportLedger": "true", "capUsd": "2.50", "ref": ref]) as NSDictionary == ["exportLedger": true, "capUsd": 2.5, "ref": ref] as NSDictionary,
              "fixed bodies carry JSON booleans and numbers")
        check(C.plan(["delete-profile", "--id", "k-0123456789ab"])?.path == "/api/key-lanes/profiles/k-0123456789ab", "delete-profile")
        check(C.plan(["delete-profile", "--id", "K!"]) == nil && C.plan(["nope"]) == nil && C.plan([]) == nil, "anything else is refused")

        // ── Stdin.
        let key = C.stdinBody(.key, Data(#"{"kind":"openrouter","key":"\#(secret)","capUsd":1.004}"#.utf8))
        check(key?.secret == secret && key?.body["key"] as? String == secret && key?.body["capUsd"] as? Double == 1.0, "the key body, cap to cents")
        check(C.stdinBody(.key, Data(#"{"kind":"openrouter","key":"\#(secret)","extra":1}"#.utf8)) == nil, "an extra field is refused")
        check(C.stdinBody(.key, Data(#"{"kind":"gemini","key":"\#(secret)"}"#.utf8)) == nil, "an unknown kind is refused")
        check(C.stdinBody(.key, Data(#"{"kind":"openrouter","key":"sk or v1"}"#.utf8)) == nil, "a key with spaces is refused")
        check(C.stdinBody(.key, Data(#"{"kind":"openai-compatible","key":"\#(secret)"}"#.utf8)) == nil, "a custom endpoint needs its URL")
        check(C.stdinBody(.key, Data(#"{"kind":"openai-compatible","key":"\#(secret)","baseUrl":"https://llm.example/v1"}"#.utf8))?.body["baseUrl"] as? String
              == "https://llm.example/v1", "a custom endpoint URL passes")
        check(C.stdinBody(.key, Data(#"{"kind":"openrouter","key":"\#(secret)","capUsd":true}"#.utf8)) == nil, "a boolean cap is refused")
        check(C.stdinBody(.key, Data(repeating: 0x20, count: 5_000)) == nil, "oversize stdin is refused")
        let profile = C.stdinBody(.profile, Data(#"{"id":"k-0123456789ab","label":"Sonnet 5.5","keyRef":"\#(ref)","engine":"claude","model":"anthropic/claude-sonnet-5.5","enabled":true,"timeoutTier":"sonnet"}"#.utf8))
        check(profile?.secret == nil && profile?.body["model"] as? String == "anthropic/claude-sonnet-5.5", "a profile body")
        check(C.stdinBody(.profile, Data(#"{"id":"k","label":"x","keyRef":"\#(ref)","engine":"claude","model":"m","timeoutTier":"sonnet","key":"\#(secret)"}"#.utf8)) == nil,
              "a profile body never carries a key")

        // ── Whitelist.
        check(C.transport(status: 404, body: nil) == "unsupported" && C.transport(status: 404, body: [:]) == "answered", "a 404 page is unsupported")
        let status = C.answer("status", status: 200, body: json(#"{"enabled":true,"active":true,"secret":"\#(secret)","keys":[{"ref":"\#(ref)","kind":"openrouter","last4":"9f3c","capUsd":1,"spentTodayUsd":0.2,"breaker":{"open":true,"failures":3,"reopensAt":"2026-10-19T20:00:00.000Z","why":"x"},"secret":"zzz"},{"ref":"bad"}],"profiles":[{"id":"k-0123456789ab","label":"Sonnet 5.5","keyRef":"\#(ref)","engine":"claude","model":"anthropic/claude-sonnet-5.5","enabled":true,"timeoutTier":"sonnet","directTools":false}],"keyedSessionIds":["0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0","bad id!"]}"#))
        check(status["enabled"] as? Bool == true && status["active"] as? Bool == true && status["secret"] == nil, "status: only the contract's fields")
        let keys = status["keys"] as? [[String: Any]] ?? []
        check(keys.count == 1 && keys[0]["secret"] == nil && keys[0]["last4"] as? String == "9f3c"
              && (keys[0]["breaker"] as? [String: Any])?["why"] == nil && (keys[0]["breaker"] as? [String: Any])?["open"] as? Bool == true,
              "status: a key is ref, kind, last 4, cap, spend and breaker")
        check((status["profiles"] as? [[String: Any]])?.first?["directTools"] == nil, "status: a profile without fields Control does not use")
        check(status["keyedSessionIds"] as? [String] == ["0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"], "status: keyed sessions in the server's grammar")
        let refused = C.answer("save-key", status: 422, body: json(#"{"error":"key_rejected","message":"OpenRouter rejected this key. Check it and paste it again.","key":{"ref":"\#(ref)"}}"#))
        check(refused["error"] as? String == "key_rejected" && refused["message"] as? String != nil && refused["key"] == nil, "a refusal carries its code and sentence only")
        let leak = C.answer("save-key", status: 422, body: json(#"{"error":"key_rejected","message":"bad key \#(secret)"}"#), secret: secret)
        check(leak["error"] as? String == "redacted" && !text(leak).contains(secret), "an answer that repeats the key is dropped")
        let saved = C.answer("save-key", status: 200, body: json(#"{"key":{"ref":"\#(ref)","kind":"openrouter","last4":"9f3c","capUsd":1,"savedAt":"x"},"credit":{"remainingUsd":4.5,"freeTier":false,"extra":1}}"#), secret: secret)
        check((saved["key"] as? [String: Any])?["savedAt"] == nil && (saved["credit"] as? [String: Any])?["remainingUsd"] as? Double == 4.5, "a saved key and its credit")
        let inUse = C.answer("remove-key", status: 409, body: json(#"{"error":"key_in_use","message":"Turn off the profiles that use this key first: Sonnet.","profiles":["k-0123456789ab"]}"#))
        check(inUse["profiles"] as? [String] == ["k-0123456789ab"], "a key in use names its profiles")
        let all = C.answer("remove-all", status: 200, body: json(#"{"removed":["keys","profiles","codexHomes","ledger","zzz"],"enabled":false,"active":false,"ledgerExportedTo":"/Users/you/Downloads/cos-key-ledger-2026-10-19.jsonl","hookFailures":["x"]}"#))
        check(all["removed"] as? [String] == ["keys", "profiles", "codexHomes", "ledger"] && all["hookFailures"] == nil
              && all["ledgerExportedTo"] as? String == "/Users/you/Downloads/cos-key-ledger-2026-10-19.jsonl", "remove-all")
        let catalog = C.answer("catalog", status: 200, body: json(#"{"curated":[{"id":"anthropic/claude-sonnet-5.5","name":"Claude Sonnet 5.5","inUsdPerM":2,"outUsdPerM":10,"role":"default"}],"pricesFrom":"openrouter","search":[{"id":"x"}]}"#))
        check((catalog["curated"] as? [[String: Any]])?.first?["role"] as? String == "default" && catalog["search"] == nil, "catalog: the curated two, no search")
        let disable = C.answer("disable", status: 200, body: json(#"{"enabled":true,"active":false,"forcedOnBy":"COS_KEY_LANES"}"#))
        check(disable["forcedOnBy"] as? String == "COS_KEY_LANES", "disable says when the env forces lanes on")
        // ── QA U6, U7.
        check(C.plan(["reset-breaker", "--ref", ref]) == .init(action: "reset-breaker", method: "POST", path: "/api/key-lanes/breaker/reset", body: ["ref": ref], stdin: .none, timeout: 10),
              "Reset pause posts the ref to the breaker route")
        check(C.plan(["reset-breaker", "--ref", "x"]) == nil && C.plan(["reset-breaker"]) == nil, "Reset pause refuses a bad ref")
        let reset = C.answer("reset-breaker", status: 200, body: json(#"{"reset":true,"breaker":{"open":false,"failures":0,"why":"x"}}"#))
        check(reset["reset"] as? Bool == true && (reset["breaker"] as? [String: Any])?["why"] == nil, "a reset answers with the closed breaker only")
        check(C.plan(["remove-saved-keys"])?.path == "/api/key-lanes/remove-all" && C.plan(["remove-saved-keys"])?.body == ["exportLedger": "false"]
              && C.plan(["remove-saved-keys", "--all"]) == nil, "Remove saved keys asks the server first")
        check(C.savedKeyFiles == ["key-secrets/provider-keys.json", "provider-keys.json", "provider-profiles.json", "key-ledger.jsonl"]
              && C.savedKeyDirectories == ["codex-homes"] && !(C.savedKeyFiles + C.savedKeyDirectories).contains("keyed-sessions.json"),
              "the disk path deletes both key store places, profiles, ledger and Codex homes, and keeps keyed sessions")
        check(C.diskRemovalBlocker(maintenance: nil) != nil, "no work report: nothing is deleted")
        check(C.diskRemovalBlocker(maintenance: ["activeJobs": 1]) != nil && C.diskRemovalBlocker(maintenance: ["activeTranscriptionSessions": 2]) != nil
              && C.diskRemovalBlocker(maintenance: ["lifecycle": ["activeByKind": ["recording_session": 1]]]) != nil,
              "a job, a transcription or a recording blocks the disk path")
        check(C.diskRemovalBlocker(maintenance: ["activeJobs": 0, "lifecycle": ["activeByKind": [String: Any]()]]) == nil, "an idle server allows it")
        // ── Server downgrade journey.
        check(C.belowKeyLanes("6.79.1") && C.belowKeyLanes("5.99.0") && C.belowKeyLanes("garbage"), "6.79.1 and unreadable versions are below key lanes")
        check(!C.belowKeyLanes("6.80.0") && !C.belowKeyLanes("6.80.0-next.4") && !C.belowKeyLanes("6.81.0") && !C.belowKeyLanes("7.0.0"), "6.80.0 and later are not")
        check(C.downgradeRefusal(targetVersion: "6.79.1", savedKeysPresent: true)?.hasPrefix("Remove your saved keys first.") == true,
              "installing 6.79.1 with keys saved is refused")
        check(C.downgradeRefusal(targetVersion: "6.79.1", savedKeysPresent: false) == nil && C.downgradeRefusal(targetVersion: "6.80.1", savedKeysPresent: true) == nil,
              "no keys, or a server with key lanes, installs as before")
        check(C.keyStoreFiles == ["key-secrets/provider-keys.json", "provider-keys.json"], "both key store places count as saved keys")
        print("key lanes helper core checks: \(passed) passed")
    }
}
