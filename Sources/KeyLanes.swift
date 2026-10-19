import Foundation

// Key lanes in COS Control (K1 P10, plan v4 10.1, 11, 12). "Answer with your own key": a key the person pastes is
// stored by the COS server (never by Control), and answers can then run on it under a daily cap.
//
// HARD RULE (plan 3): with no key-lane answer from the server, Control looks and behaves exactly as 0.5.327 at 5cdb833.
// Everything here is inert until either the server is 6.80.0 or later (the first that can turn lanes on) or the server
// has answered that lanes are on: the Settings row is not drawn, the setup step is not drawn, nothing is read, and the
// Continue and Fork guards return nil because the keyed-session set is empty. Tests/KeyLanesSnapshot.run.sh replays
// the K0 golden against this branch to prove it.
//
// The server is reached only through `cos-control-helper key-lanes <action>` (HelperSources/ProviderStatusCore.swift
// KeyLanesHelperCore). A pasted key goes to the helper on stdin, never in argv, and nothing Control keeps or shows
// holds it: Control knows a key by its kind and its last four characters.

enum KeyLanes {
    // ── Copy the lens and the server also use (P8 server/lib/key-notices.ts at 8385336, one source of key-lane words).
    // Tests/key-lanes-pins.py checks each against Tests/fixtures/key-lanes/key-notices-8385336.ts byte for byte.
    static let keyedSessionRefusal = "This session ran on your key. Continue it from COS."
    static let downgradeLine = "Remove your keys first. Older COS cannot see them."
    static let noCreditLimitLine = "Set a credit limit on this key at openrouter.ai first."
    static let breakerLine = "Key paused 1 hour after 3 failures."
    static let providerKey: [String: String] = [
        "openrouter": "OpenRouter key", "anthropic": "Anthropic key", "openai": "OpenAI key", "openai-compatible": "endpoint key",
    ]
    static func keyRejectedLine(_ kind: String) -> String { "Your \(keyName(kind)) was rejected. Fix it in COS Control." }
    static func keyName(_ kind: String) -> String { providerKey[kind] ?? "key" }

    // ── Control's own words (Settings and setup, never the lens).
    static let rowTitle = "Answer with your own key"
    static let offLine = "Off. Answers use the AI you connected and its plan."
    static let onLine = "On. Answers you send to a key profile run on your key, under its daily cap."
    static let setupTitle = "Add your own key (optional)"
    static let setupDetail = "Answers can run on an OpenRouter, Anthropic or OpenAI key, with a daily cap. COS keeps the key on this Mac."
    static let skipLabel = "Skip"
    static let addLabel = "Add a key"
    static let pasteLabel = "Paste key"
    static let saveLabel = "Save key"
    static let removeLabel = "Remove"
    static let removeAllLabel = "Remove all keys"
    static let removeAllMessage = "Every key, key profile and the spend ledger are deleted from this Mac, and key lanes turn off. Sessions that ran on a key stay refused for Continue and Fork."
    static let exportLedgerLabel = "Save the spend ledger to Downloads first"
    static let pasteHint = "Copy the key, then press Paste key. COS never shows it again."
    static let emptyPaste = "The clipboard has no text. Copy the key, then press Paste key."
    static let cannotEnable = "COS did not turn on keys. Update COS, or remove COS_KEY_LANES=0 from its settings."
    static let unreachable = "COS is not answering. Try again in a moment."
    static let downgradeHeading = "Going back to a COS older than 6.80.0?"
    static let customURLLabel = "Endpoint URL"
    static let capLabel = "Daily cap (USD)"
    static let modelLabelTitle = "Model"
    static let noModelsLine = "Pick a model for this key in a later COS. The key is saved."
    static let defaultCapUsd = 1.0
    static let kindOrder = ["openrouter", "anthropic", "openai", "openai-compatible"]
    static let kindTitles: [String: String] = [
        "openrouter": "OpenRouter", "anthropic": "Anthropic", "openai": "OpenAI", "openai-compatible": "Custom endpoint",
    ]

    // ── Which servers and installs see any of this.
    /// 6.80.0 is the first server with `/api/key-lanes/enable` (K1 ships as 6.80.0-next.N, so a prerelease counts).
    static let minimumServer = [6, 80, 0]

    static func serverSupports(_ version: String?) -> Bool {
        guard let version else { return false }
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return false }
        let numbers = parts.map { $0! }
        for (a, b) in zip(numbers, minimumServer) where a != b { return a > b }
        return true
    }

    /// The Settings row: drawn for a server that can turn lanes on, or one that says they are on. Never otherwise.
    static func rowVisible(serverVersion: String?, enabled: Bool) -> Bool {
        enabled || serverSupports(serverVersion)
    }

    enum Install: String, Equatable { case new, existing }

    /// SetupGuideState keys (Sources/ProviderConnectModel.swift; Tests/key-lanes-pins.py keeps them equal). Any of them
    /// set means this Mac has been through setup before.
    static let priorSetupKeys = ["cos.setupGuide.journeyFinished", "cos.setupGuide.glassesHandled", "cos.setupGuide.hidden"]
    static let installKey = "cos.keyLanes.install"

    /// A NEW install (plan D12): the first status Control reads says first run (no server installed, nothing pending)
    /// AND no earlier setup was finished, hidden or past its glasses step on this Mac. Decided once, on the first status
    /// whose runtime state is known, and kept. Anything else is existing. nil until the status is known.
    static func classifyInstall(stored: String?, needsFirstRun: Bool, runtimeState: String, priorSetup: Bool) -> Install? {
        if let stored, let install = Install(rawValue: stored) { return install }
        guard runtimeState != "unknown" else { return nil }
        return needsFirstRun && !priorSetup ? .new : .existing
    }

    /// The optional "Add your own key" step: a server that can turn lanes on, not skipped, no key yet, and either a new
    /// install or lanes already turned on from Settings. An existing install never sees it with lanes off.
    static func setupStepVisible(install: Install?, serverVersion: String?, enabled: Bool, skipped: Bool, hasKey: Bool) -> Bool {
        guard serverSupports(serverVersion), !skipped, !hasKey else { return false }
        return install == .new || enabled
    }

    /// "Local first" (plan 10.1): a signed-in CLI or a running Ollama means a key is only an option.
    static func localFirstLine(claudeReady: Bool?, codexReady: Bool?, ollamaReady: Bool) -> String? {
        if claudeReady == true { return "You already have Claude. A key is optional." }
        if codexReady == true { return "You already have Codex. A key is optional." }
        if ollamaReady { return "You already have Ollama on this Mac. A key is optional." }
        return nil
    }

    // ── What a key looks like on screen: its kind and last four, never more.
    static func last4(_ secret: String) -> String { String(secret.suffix(4)) }
    static func keyLine(kind: String, last4: String) -> String { "\(kindTitles[kind] ?? "Key") key ending \(last4)" }
    /// After Paste key, before Save key: what was pasted, by kind and last four only.
    static func pendingLine(kind: String, secret: String) -> String { "Ready to save: " + keyLine(kind: kind, last4: last4(secret)) }

    static func usd(_ value: Double) -> String { String(format: "$%.2f", value.isFinite && value > 0 ? value : 0) }
    static func capLine(_ key: KeyLanesKey) -> String {
        "Cap \(usd(key.capUsd)) a day. \(usd(key.spentTodayUsd)) spent today."
    }
    static func parseCap(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard trimmed.range(of: "\\A[0-9]{1,4}(\\.[0-9]{1,2})?\\z", options: .regularExpression) != nil,
              let value = Double(trimmed), value >= 0.01, value <= 1000 else { return nil }
        return value
    }
    static func capArgument(_ value: Double) -> String { String(format: "%.2f", value) }

    // ── Profiles: one per key, named for the key, holding the model picked for it.
    static func profileID(forKey ref: String) -> String { "k-" + ref.dropFirst(4) }
    /// `anthropic/claude-sonnet-5.5` to `Sonnet 5.5` (P8 keyModelLabel).
    static func modelLabel(_ slug: String) -> String {
        let last = slug.split(separator: "/").last.map(String.init) ?? slug
        let parts = last.split(separator: "-").map(String.init)
        if parts.count >= 3, parts[0].lowercased() == "claude" {
            return parts[1].prefix(1).uppercased() + parts[1].dropFirst().lowercased() + " " + parts[2...].joined(separator: ".")
        }
        return last
    }
    /// The model a profile on this key carries for a curated slug, or nil when this kind has no curated model in K1.
    static func profileModel(slug: String, kind: String) -> String? {
        guard slug.hasPrefix("anthropic/") else { return nil }
        switch kind {
        case "openrouter": return slug
        case "anthropic": return String(slug.dropFirst("anthropic/".count)).replacingOccurrences(of: ".", with: "-")
        default: return nil
        }
    }
    static func timeoutTier(_ slug: String) -> String { slug.contains("haiku") ? "haiku" : "sonnet" }
    static func priceLine(_ model: KeyLanesModel) -> String {
        "\(modelLabel(model.id)), \(String(format: "$%g", model.inUsdPerM)) in, \(String(format: "$%g", model.outUsdPerM)) out per M"
    }

    /// The words for an answer that did not do what was asked, or nil. The server's own sentence when it sent one.
    static func problem(_ details: [String: JSONValue]?) -> String? {
        guard let details else { return unreachable }
        switch details["transport"]?.string {
        case "answered": break
        case "unsupported": return cannotEnable
        default: return unreachable
        }
        let status = details["httpStatus"]?.int ?? 0
        if (200..<300).contains(status) { return nil }
        switch details["error"]?.string {
        case "keyed_session": return keyedSessionRefusal
        case "no_credit_limit": return noCreditLimitLine
        default: return details["message"]?.string ?? "COS could not do that (HTTP \(status))."
        }
    }
}

struct KeyLanesKey: Equatable, Identifiable {
    let ref: String
    let kind: String
    let last4: String
    let capUsd: Double
    let spentTodayUsd: Double
    let breakerOpen: Bool
    var id: String { ref }

    init?(_ value: JSONValue) {
        guard let o = value.object, let ref = o["ref"]?.string, let kind = o["kind"]?.string,
              let last4 = o["last4"]?.string, let cap = o["capUsd"]?.double else { return nil }
        self.ref = ref; self.kind = kind; self.last4 = last4; capUsd = cap
        spentTodayUsd = o["spentTodayUsd"]?.double ?? 0
        breakerOpen = o["breaker"]?.object?["open"]?.bool ?? false
    }
}

struct KeyLanesProfile: Equatable, Identifiable {
    let id: String
    let label: String
    let keyRef: String
    let engine: String
    let model: String
    let enabled: Bool

    init?(_ value: JSONValue) {
        guard let o = value.object, let id = o["id"]?.string, let label = o["label"]?.string, let ref = o["keyRef"]?.string,
              let engine = o["engine"]?.string, let model = o["model"]?.string, let enabled = o["enabled"]?.bool else { return nil }
        self.id = id; self.label = label; keyRef = ref; self.engine = engine; self.model = model; self.enabled = enabled
    }
}

struct KeyLanesModel: Equatable, Identifiable {
    let id: String
    let name: String
    let inUsdPerM: Double
    let outUsdPerM: Double
    let role: String?

    init?(_ value: JSONValue) {
        guard let o = value.object, let id = o["id"]?.string, let name = o["name"]?.string,
              let inPer = o["inUsdPerM"]?.double, let outPer = o["outUsdPerM"]?.double else { return nil }
        self.id = id; self.name = name; inUsdPerM = inPer; outUsdPerM = outPer; role = o["role"]?.string
    }
}

/// What `key-lanes status` says. `off` stands for lanes off on this server (its 404).
struct KeyLanesState: Equatable {
    var enabled: Bool
    var active: Bool
    var keys: [KeyLanesKey]
    var profiles: [KeyLanesProfile]
    var keyedSessionIds: [String]

    static let off = KeyLanesState(enabled: false, active: false, keys: [], profiles: [], keyedSessionIds: [])

    /// nil when the server did not answer (keep what is shown). `off` for lanes off.
    static func decode(_ details: [String: JSONValue]) -> KeyLanesState? {
        switch details["transport"]?.string {
        case "unsupported": return .off
        case "answered": break
        default: return nil
        }
        guard details["httpStatus"]?.int == 200 else { return details["httpStatus"]?.int == 404 ? .off : nil }
        return KeyLanesState(enabled: details["enabled"]?.bool ?? false, active: details["active"]?.bool ?? false,
                             keys: (details["keys"]?.array ?? []).compactMap(KeyLanesKey.init),
                             profiles: (details["profiles"]?.array ?? []).compactMap(KeyLanesProfile.init),
                             keyedSessionIds: (details["keyedSessionIds"]?.array ?? []).compactMap(\.string))
    }
}

@MainActor
final class KeyLanesStore: ObservableObject {
    typealias Run = @MainActor ([String], Data?) async throws -> HelperResponse
    static let shared = KeyLanesStore()

    static let skippedKey = "cos.keyLanes.setupSkipped"
    static let keyedSessionsKey = "cos.keyLanes.keyedSessionIds"

    @Published private(set) var state: KeyLanesState?
    @Published private(set) var catalog: [KeyLanesModel] = []
    @Published private(set) var busy = false
    /// The last refusal or problem, in words; nil when the last action went through.
    @Published var line: String?
    @Published private(set) var install: KeyLanes.Install?
    @Published private(set) var setupSkipped: Bool
    /// Sessions that ran on a key, from every status this Mac has read. Kept after Remove all keys and after lanes turn
    /// off, so Continue and Fork stay refused (plan 12). Empty, and never written, on a Mac that never used a key.
    private(set) var keyedSessionIds: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        install = defaults.string(forKey: KeyLanes.installKey).flatMap(KeyLanes.Install.init(rawValue:))
        setupSkipped = defaults.bool(forKey: Self.skippedKey)
        keyedSessionIds = Set(defaults.stringArray(forKey: Self.keyedSessionsKey) ?? [])
    }

    var enabled: Bool { state?.enabled == true }
    var hasKey: Bool { !(state?.keys.isEmpty ?? true) }

    /// Decide new or existing once (KeyLanes.classifyInstall) from a status read.
    func observe(_ status: ServerStatus) {
        guard install == nil else { return }
        let prior = KeyLanes.priorSetupKeys.contains { defaults.object(forKey: $0) != nil }
        guard let decided = KeyLanes.classifyInstall(stored: nil, needsFirstRun: status.needsFirstRun,
                                                     runtimeState: status.runtimeState, priorSetup: prior) else { return }
        install = decided
        defaults.set(decided.rawValue, forKey: KeyLanes.installKey)
    }

    /// The Continue and Fork guard: the refusal line for a session that ran on a key, else nil.
    func refusal(sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty, keyedSessionIds.contains(sessionID) else { return nil }
        return KeyLanes.keyedSessionRefusal
    }

    func skipSetup() {
        setupSkipped = true
        defaults.set(true, forKey: Self.skippedKey)
    }

    private func call(_ arguments: [String], _ input: Data? = nil, run: Run) async -> [String: JSONValue]? {
        busy = true
        defer { busy = false }
        return try? await run(["key-lanes"] + arguments, input).details
    }

    private func apply(_ next: KeyLanesState) {
        if state != next { state = next }
        let fresh = Set(next.keyedSessionIds).subtracting(keyedSessionIds)
        guard !fresh.isEmpty else { return }
        keyedSessionIds.formUnion(fresh)
        defaults.set(Array(Array(keyedSessionIds).sorted().suffix(20_000)), forKey: Self.keyedSessionsKey)
    }

    func refresh(run: Run) async {
        guard let details = await call(["status"], run: run) else { return }
        if let next = KeyLanesState.decode(details) { apply(next) }
    }

    /// Turn lanes on (the server's one door that answers while they are off), then read the status.
    func enable(run: Run) async {
        let details = await call(["enable"], run: run)
        line = KeyLanes.problem(details)
        await refresh(run: run)
        if enabled, catalog.isEmpty { await loadCatalog(run: run) }
    }

    func disable(run: Run) async {
        line = KeyLanes.problem(await call(["disable"], run: run))
        await refresh(run: run)
    }

    func loadCatalog(run: Run) async {
        guard let details = await call(["catalog"], run: run), KeyLanes.problem(details) == nil else { return }
        catalog = (details["curated"]?.array ?? []).compactMap(KeyLanesModel.init)
    }

    /// The body `key-lanes save-key` reads from stdin. The secret is in here and nowhere else.
    static func keyInput(kind: String, secret: String, capUsd: Double, baseURL: String?) -> Data? {
        var body: [String: Any] = ["kind": kind, "key": secret, "capUsd": capUsd]
        if kind == "openai-compatible" { body["baseUrl"] = baseURL ?? "" }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Save a pasted key: on stdin to the helper, which posts it to the server. True when saved. The caller drops its
    /// copy of the secret either way. Then a profile for the default model, so answers can use it.
    @discardableResult
    func saveKey(kind: String, secret: String, capUsd: Double, baseURL: String? = nil, run: Run) async -> Bool {
        guard let input = Self.keyInput(kind: kind, secret: secret, capUsd: capUsd, baseURL: baseURL) else { return false }
        let details = await call(["save-key"], input, run: run)
        if let problem = KeyLanes.problem(details) { line = problem; return false }
        line = nil
        if catalog.isEmpty { await loadCatalog(run: run) }
        if let ref = details?["key"]?.object?["ref"]?.string,
           let model = catalog.first(where: { $0.role == "default" }) ?? catalog.first {
            await chooseModel(model.id, keyRef: ref, kind: kind, run: run)
        } else {
            await refresh(run: run)
        }
        return true
    }

    /// The profile for this key, with the model picked (from the server's curated list).
    func chooseModel(_ slug: String, keyRef: String, kind: String, run: Run) async {
        guard let model = KeyLanes.profileModel(slug: slug, kind: kind) else { line = KeyLanes.noModelsLine; await refresh(run: run); return }
        let body: [String: Any] = ["id": KeyLanes.profileID(forKey: keyRef), "label": KeyLanes.modelLabel(slug), "keyRef": keyRef,
                                   "engine": "claude", "model": model, "enabled": true, "timeoutTier": KeyLanes.timeoutTier(slug)]
        let input = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        line = KeyLanes.problem(await call(["save-profile"], input, run: run))
        await refresh(run: run)
    }

    func setCap(_ capUsd: Double, keyRef: String, run: Run) async {
        line = KeyLanes.problem(await call(["set-cap", "--ref", keyRef, "--cap", KeyLanes.capArgument(capUsd)], run: run))
        await refresh(run: run)
    }

    /// Remove one key (after the inline confirmation): its profile is turned off by the server, then removed here.
    func removeKey(_ keyRef: String, run: Run) async {
        let details = await call(["remove-key", "--ref", keyRef, "--force"], run: run)
        line = KeyLanes.problem(details)
        if line == nil, state?.profiles.contains(where: { $0.id == KeyLanes.profileID(forKey: keyRef) }) == true {
            line = KeyLanes.problem(await call(["delete-profile", "--id", KeyLanes.profileID(forKey: keyRef)], run: run))
        }
        await refresh(run: run)
    }

    func removeAll(exportLedger: Bool, run: Run) async {
        let details = await call(exportLedger ? ["remove-all", "--export-ledger"] : ["remove-all"], run: run)
        line = KeyLanes.problem(details)
        if line == nil, let path = details?["ledgerExportedTo"]?.string { line = "Spend ledger saved to \(path)." }
        await refresh(run: run)
    }
}

extension KeyLanes {
    /// Continue and Fork in Work and in Activity's chat call this before they send: the refusal line, or nil. Always nil
    /// on a Mac that never ran a keyed session.
    @MainActor static func refusal(sessionID: String?) -> String? { KeyLanesStore.shared.refusal(sessionID: sessionID) }
}
