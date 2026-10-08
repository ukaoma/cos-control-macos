import Foundation

// Connect your AI (Sources/ProviderConnectModel.swift), compiled on its own: the rows, the Get started gate, Sign in's
// Terminal command, the Pass to prompt and links, polling bounds, the Dock decision, the pet introduction and the
// panel's Agent CLIs line. Every effect is a stand-in: nothing opens Terminal, an app or a link.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1; return }
    failures += 1
    FileHandle.standardError.write(Data("check failed [\(behaviour)]: \(detail())\n".utf8))
}

let chatgptCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

func status(_ provider: String, installed: Bool = true, path: String? = nil, signIn: String = "signedIn",
            version: String? = "1.0.0", desktop: Bool = false, daemon: String? = nil, models: [String]? = nil) -> String {
    var candidates: [String] = []
    if let path { candidates.append(#"{"path":"\#(path)","source":"absolute","executable":true,"chosen":true}"#) }
    if desktop { candidates.append(#"{"path":"/Users/x/Library/Application Support/Claude/claude-code/2.1.293/h/claude.app/Contents/MacOS/claude","source":"claudeDesktop","executable":true,"chosen":false}"#) }
    let modelsJSON = models.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
    return #"{"provider":"\#(provider)","installed":\#(installed),"binaryPath":\#(path.map { "\"\($0)\"" } ?? "null"),"version":\#(version.map { "\"\($0)\"" } ?? "null"),"signIn":"\#(signIn)","candidates":[\#(candidates.joined(separator: ","))],"detail":null,"daemon":\#(daemon.map { "\"\($0)\"" } ?? "null"),"models":\#(modelsJSON),"host":null}"#
}

func report(_ rows: String...) -> ProviderStatusReport {
    ProviderStatusReport.decode(Data(#"{"providers":[\#(rows.joined(separator: ","))],"checkedAt":"2026-10-08T15:00:00Z"}"#.utf8))!
}

let allMissing = report(status("claude", installed: false, signIn: "unknown", version: nil),
                        status("codex", installed: false, signIn: "unknown", version: nil),
                        status("cursor", installed: false, signIn: "unknown", version: nil),
                        status("ollama", installed: false, signIn: "notNeeded", version: nil, daemon: "down", models: []))
let mixed = report(status("claude", path: "/opt/homebrew/bin/claude", signIn: "signInRequired"),
                   status("codex", path: chatgptCodex, signIn: "signedIn"),
                   status("cursor", installed: false, signIn: "unknown", version: nil),
                   status("ollama", path: "/usr/local/bin/ollama", signIn: "notNeeded", daemon: "down", models: []))
let allIn = report(status("claude", path: "/opt/homebrew/bin/claude"), status("codex", path: chatgptCodex),
                   status("cursor", path: "/Users/x/.local/bin/agent"),
                   status("ollama", path: "/usr/local/bin/ollama", signIn: "notNeeded", daemon: "running", models: ["qwen3:4b"]))

@MainActor func freshDefaults() -> UserDefaults {
    let name = "cos.provider-connect-checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor final class Effects {
    var terminal: [String] = []
    var opened: [URL] = []
    var copied: [String] = []
    var folders: [String] = []
    var statusCalls: [[String]] = []
    var terminalWorks = true
    var openWorks = true
}

@MainActor func guide(_ answers: [ProviderStatusReport], effects: Effects, defaults: UserDefaults? = nil) -> ProviderGuide {
    var queue = answers
    let g = ProviderGuide(home: "/Users/fixture home", defaults: defaults ?? freshDefaults()) { arguments in
        effects.statusCalls.append(arguments)
        let next = queue.count > 1 ? queue.removeFirst() : queue[0]
        let only = arguments.firstIndex(of: "--only").map { arguments[$0 + 1].split(separator: ",").map(String.init) }
        var answer = next
        if let only { answer.providers = next.providers.filter { only.contains($0.provider) } }
        return try JSONEncoder().encode(EncodableReport(answer))
    }
    g.runInTerminal = { effects.terminal.append($0); return effects.terminalWorks }
    g.openURL = { effects.opened.append($0); return effects.openWorks }
    g.copy = { effects.copied.append($0) }
    g.makeFolder = { effects.folders.append($0); return true }
    g.appInstalled = { $0 == "claude" || $0 == "codex" }
    return g
}

/// Re-encodes a decoded report, the way the app hands the helper's details over.
struct EncodableReport: Encodable {
    let report: ProviderStatusReport
    init(_ report: ProviderStatusReport) { self.report = report }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(report.checkedAt, forKey: .checkedAt)
        var list = c.nestedUnkeyedContainer(forKey: .providers)
        for p in report.providers {
            var o = list.nestedContainer(keyedBy: Key.self)
            try o.encode(p.provider, forKey: .provider); try o.encode(p.installed, forKey: .installed)
            try o.encode(p.binaryPath, forKey: .binaryPath); try o.encode(p.version, forKey: .version)
            try o.encode(p.signIn, forKey: .signIn); try o.encode(p.daemon, forKey: .daemon); try o.encode(p.models, forKey: .models)
            var cs = o.nestedUnkeyedContainer(forKey: .candidates)
            for c in p.candidates {
                var co = cs.nestedContainer(keyedBy: Key.self)
                try co.encode(c.path, forKey: .path); try co.encode(c.source, forKey: .source)
                try co.encode(c.executable, forKey: .executable); try co.encode(c.chosen, forKey: .chosen)
            }
        }
    }
    enum Key: String, CodingKey { case checkedAt, providers, provider, installed, binaryPath, version, signIn, daemon, models, candidates, path, source, executable, chosen }
}

@main @MainActor
struct ProviderConnectChecks {
    static func main() async {
        rows()
        gate()
        login()
        prompts()
        links()
        polling()
        await pollLoop()
        await signInFlow()
        await passFlow()
        dock()
        petIntro()
        agentCliLine()
        setupGuide()
        voiceRows()
        await voiceFlow()
        await qaFixes()
        if failures > 0 {
            FileHandle.standardError.write(Data("Connect your AI checks: \(failures) failed, \(passes) passed\n".utf8))
            exit(1)
        }
        print("Connect your AI checks: \(passes) passed")
    }

    static func rows() {
        let none = AIProvider.allCases.map { ProviderRules.row($0, allMissing.status($0), skipped: false, waiting: false) }
        check(none.prefix(3).allSatisfy { $0.status == "Not installed" && $0.action == .install }, "rows all missing", "\(none.map(\.status))")
        check(none[3].tone == .optional && none[3].status == "Not installed", "rows ollama optional", "Ollama is optional, never 'needs you'")
        let claude = ProviderRules.row(.claude, mixed.status(.claude), skipped: false, waiting: false)
        check(claude.status == "Installed, not signed in" && claude.action == .signIn && claude.canSkip && claude.tone == .needsYou, "rows sign-in required", "\(claude)")
        let skipped = ProviderRules.row(.claude, mixed.status(.claude), skipped: true, waiting: false)
        check(skipped.status == "Skipped for now" && skipped.action == .signIn && !skipped.canSkip, "rows skipped", "a skipped row can still sign in: \(skipped)")
        let waiting = ProviderRules.row(.claude, mixed.status(.claude), skipped: false, waiting: true)
        check(waiting.waiting && waiting.status == "Waiting for sign-in…" && waiting.detail?.contains("browser") == true, "rows waiting", "\(waiting)")
        check(ProviderRules.row(.codex, mixed.status(.codex), skipped: false, waiting: false).tone == .good, "rows signed in", "ChatGPT's codex is green")
        let key = ProviderRules.row(.claude, report(status("claude", path: "/opt/homebrew/bin/claude", signIn: "apiKey")).status(.claude), skipped: false, waiting: false)
        check(key.status == "API key" && key.tone == .good && key.detail?.contains("billed separately") == true, "rows api key", "\(key)")
        let unknown = ProviderRules.row(.claude, report(status("claude", path: "/opt/homebrew/bin/claude", signIn: "unknown")).status(.claude), skipped: false, waiting: false)
        check(unknown.status == "Installed" && unknown.action == .none, "rows unknown", "an unreadable sign-in is never a failure: \(unknown)")
        let desktop = ProviderRules.row(.claude, report(status("claude", installed: false, signIn: "unknown", version: nil, desktop: true)).status(.claude), skipped: false, waiting: false)
        check(desktop.status == "Not installed" && desktop.detail?.contains("Claude Desktop") == true, "rows desktop only", "\(desktop)")
        let passing = ProviderRules.row(.cursor, mixed.status(.cursor), skipped: false, waiting: true)
        check(passing.waiting && passing.status == "Waiting for setup…" && passing.action == .install, "rows pass waiting", "a pass to an app shows on a not-installed row: \(passing)")
        check(ProviderRules.row(.ollama, mixed.status(.ollama), skipped: false, waiting: false).status == "Installed, not running", "rows ollama daemon down", "down is not 'not installed'")
        check(ProviderRules.row(.ollama, allIn.status(.ollama), skipped: false, waiting: false).status == "Running, 1 model", "rows ollama running", "")
        check(ProviderRules.row(.claude, nil, skipped: false, waiting: false).status == "Checking…", "rows checking", "")
        check(ProviderRules.summary(allMissing, skipped: []) == "None installed", "summary", ProviderRules.summary(allMissing, skipped: []))
        check(ProviderRules.summary(mixed, skipped: []) == "1 needs you", "summary", ProviderRules.summary(mixed, skipped: []))
        check(ProviderRules.summary(mixed, skipped: [.claude]) == "2 connected", "summary", "a skip clears the need: \(ProviderRules.summary(mixed, skipped: [.claude]))")
        check(ProviderRules.summary(allIn, skipped: []) == "3 connected", "summary", "Ollama is not counted as a connected agent")
    }

    static func gate() {
        // The hard gate is the 0.5.267 one: installed. Installed-but-not-signed-in can always Get started.
        check(ProviderGate.getStartedEnabled(setupProviderInstalled: true, busy: false), "gate unchanged", "installed, not signed in: Get started is enabled")
        check(!ProviderGate.getStartedEnabled(setupProviderInstalled: false, busy: false), "gate unchanged", "nothing installed: disabled")
        check(!ProviderGate.getStartedEnabled(setupProviderInstalled: true, busy: true), "gate unchanged", "busy: disabled")
        check(!ProviderGate.signInStepDone(mixed, skipped: []), "sign-in step", "an installed CLI not signed in leaves the step open")
        check(ProviderGate.signInStepDone(mixed, skipped: [.claude]), "sign-in step", "Skip for now completes it")
        check(ProviderGate.signInStepDone(allMissing, skipped: []), "sign-in step", "nothing installed is not a sign-in problem")
        check(ProviderGate.signInStepDone(nil, skipped: []), "sign-in step", "an unread status never blocks")
        let ollamaOnly = report(status("claude", installed: false, signIn: "unknown"), status("ollama", path: "/usr/local/bin/ollama", signIn: "notNeeded", daemon: "running", models: ["m"]))
        check(ProviderRules.needCount(ollamaOnly, skipped: []) == 0 && ProviderRules.summary(ollamaOnly, skipped: []) == "None installed", "ollama not a gate", "Ollama alone does not satisfy Connect your AI in P1")
    }

    static func login() {
        check(ProviderLogin.command(.claude, binaryPath: "/opt/homebrew/bin/claude") == "claude auth login", "login command", "on PATH: bare")
        check(ProviderLogin.command(.codex, binaryPath: chatgptCodex) == "'\(chatgptCodex)' login", "login command", "ChatGPT-only: the app's codex by path: \(ProviderLogin.command(.codex, binaryPath: chatgptCodex) ?? "nil")")
        check(ProviderLogin.command(.cursor, binaryPath: "/Users/a b/.local/bin/agent") == "'/Users/a b/.local/bin/agent' login", "login command", "spaces quoted")
        check(ProviderLogin.command(.cursor, binaryPath: nil) == "agent login", "login command", "no path: the documented command")
        check(ProviderLogin.command(.codex, binaryPath: "/Users/o'k/bin/codex") == "'/Users/o'\\''k/bin/codex' login", "login command", "a quote in the path")
        check(ProviderLogin.command(.ollama, binaryPath: "/usr/local/bin/ollama") == nil, "login command", "Ollama has no sign-in")
        let script = ProviderLogin.terminalScript(#"'/Users/a "b"\c/agent' login"#)
        check(script.contains(#"do script "'/Users/a \"b\"\\c/agent' login""#) && script.contains("activate"), "terminal script", script)
        check(!script.contains("\n\"") && script.hasPrefix("tell application \"Terminal\""), "terminal script", "one Terminal window, brought forward")
    }

    static func prompts() {
        for provider in AIProvider.agents {
            guard let a = ProviderPass.prompt(setUp: provider, tag: "abcd1234ef"), let b = ProviderPass.prompt(setUp: provider, tag: "zz99yy88xx") else {
                check(false, "prompt", "\(provider) builds"); continue
            }
            check(a.replacingOccurrences(of: "abcd1234ef", with: "<tag>") == b.replacingOccurrences(of: "zz99yy88xx", with: "<tag>"), "prompt fixed", "\(provider): nothing but the tag varies")
            check(a.utf16.count < 4_000, "prompt length", "\(provider): \(a.utf16.count) characters")
            check(a.hasPrefix("COS-SETUP abcd1234ef") && a.contains("COS-SETUP abcd1234ef: connected") && a.contains("COS-SETUP abcd1234ef: blocked: <one short reason>"), "prompt end line", "\(provider)")
            let lower = a.lowercased()
            check(lower.contains("never use sudo, homebrew, or a global npm install"), "prompt rules", "\(provider) states the install rule")
            check(!lower.contains("sudo curl") && !lower.contains("| sudo") && !lower.contains("brew install") && !lower.contains("npm install -g") && !lower.contains("npm i -g"), "prompt installers", "no sudo, brew or global npm command")
            check(!a.contains("127.0.0.1") && !a.contains("3141") && !a.contains("3143") && !a.contains(".cos-glasses") && !a.contains("X-Cos-Token"), "prompt no COS endpoints", "\(provider)")
            check(a.contains("Do not read, print, or copy any token"), "prompt no token", "\(provider)")
            if let install = provider.installCommand { check(a.contains(install), "prompt constants", "\(provider) carries its exact installer") }
        }
        check(ProviderPass.prompt(setUp: .codex, tag: "abcd1234ef")?.contains(chatgptCodex) == true, "prompt constants", "Codex comes from the ChatGPT app, never npm")
        for bad in ["ABCD1234", "abc", "abcd1234\n", "../../etc", "abcd 1234", "abcd1234ef$(x)", "äbcd12345", String(repeating: "a", count: 33)] {
            check(ProviderPass.prompt(setUp: .claude, tag: bad) == nil && ProviderPass.setupFolder(home: "/h", tag: bad) == nil, "prompt tag", "refused: \(bad.debugDescription)")
        }
        check(ProviderPass.prompt(setUp: .ollama, tag: "abcd1234ef") == nil, "prompt", "no Pass for Ollama")
        var generator = SystemRandomNumberGenerator()
        let tags = (0..<50).map { _ in ProviderPass.newTag(using: &generator) }
        check(tags.allSatisfy(ProviderPass.isValidTag) && Set(tags).count == 50, "tag", "new tags are valid and distinct")
        check(ProviderPass.setupFolder(home: "/Users/a b", tag: "abcd1234ef") == "/Users/a b/Library/Application Support/COS Control/setup/abcd1234ef", "setup folder", "")
        check(ProviderPass.reportedLine("ok\nCOS-SETUP abcd1234ef: blocked: needs admin\n", tag: "abcd1234ef") == "blocked: needs admin", "reported line", "display only")
        check(ProviderPass.reportedLine("COS-SETUP zzzz9999zz: connected", tag: "abcd1234ef") == nil, "reported line", "a wrong tag never matches")
        check(ProviderPass.target(for: .cursor, installedApps: [.claude, .codex]) == .claude, "pass target", "no Cursor app: the first installed app")
        check(ProviderPass.target(for: .codex, installedApps: [.claude, .codex]) == .codex, "pass target", "its own app first")
        check(ProviderPass.target(for: .claude, installedApps: []) == nil, "pass target", "no app: no Pass button")
    }

    static func links() {
        let prompt = "line one\nback`tick` & ? # % \"quote\" 'single' ü + = /"
        let folder = "/Users/a b/Library/Application Support/COS Control/setup/abcd1234ef"
        for (app, scheme, textKey, folderKey) in [(AIProvider.claude, "claude://code/new?", "q", "folder"), (.codex, "codex://threads/new?", "prompt", "path"),
                                                  (.cursor, "cursor://anysphere.cursor-deeplink/prompt?", "text", nil)] {
            guard let url = ProviderPass.link(app: app, prompt: prompt, folder: folder) else { check(false, "link", "\(app) builds"); continue }
            check(url.absoluteString.hasPrefix(scheme), "link shape", url.absoluteString)
            let query = url.absoluteString.split(separator: "?", maxSplits: 1).last.map(String.init) ?? ""
            check(query.range(of: #"^[A-Za-z0-9\-._~%=&]+$"#, options: .regularExpression) != nil, "link encoder", "only unreserved characters, percent escapes, = and &: \(query.prefix(80))")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            check(items.first { $0.name == textKey }?.value == prompt, "link round trip", "\(app): the prompt decodes back exactly")
            if let folderKey { check(items.first { $0.name == folderKey }?.value == folder, "link round trip", "\(app): the folder decodes back") }
            if app == .cursor { check(items.first { $0.name == "mode" }?.value == "agent", "link shape", "Cursor opens in agent mode") }
        }
        check(ProviderPass.link(app: .claude, prompt: String(repeating: "x", count: 4_001), folder: folder) == nil, "link length", "over 4,000 characters is refused")
        check(ProviderPass.link(app: .ollama, prompt: "x", folder: folder) == nil, "link", "Ollama has no link")
        check(ProviderPass.linkQueryAllowed == CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"), "link encoder", "the strict set")
    }

    static func polling() {
        let first = (0..<10).compactMap { ProviderPollSchedule.delay(attempt: $0, elapsed: 0) }
        check(first == Array(repeating: 3, count: 10), "polling bounds", "every 3 s at first: \(first)")
        let later = (10..<40).compactMap { ProviderPollSchedule.delay(attempt: $0, elapsed: 60) }
        check(later.first! > 3 && later.allSatisfy { $0 <= 15 } && later.last == 15, "polling bounds", "backs off to 15 s and never past it: \(later.prefix(6))")
        check(zip(later, later.dropFirst()).allSatisfy { $0 <= $1 }, "polling bounds", "never speeds back up")
        check(ProviderPollSchedule.delay(attempt: 3, elapsed: 900) == nil && ProviderPollSchedule.delay(attempt: 50, elapsed: 2000) == nil, "polling bounds", "stops at 15 minutes")
        check(ProviderPollSchedule.delay(attempt: 30, elapsed: 895) == 5, "polling bounds", "the last wait ends at the limit")
        // Worst case over the whole window: at most 15 minutes and a bounded number of polls.
        var elapsed: TimeInterval = 0, attempt = 0
        while let wait = ProviderPollSchedule.delay(attempt: attempt, elapsed: elapsed), wait > 0 { elapsed += wait; attempt += 1 }
        check(elapsed <= 900 && attempt <= 80, "polling bounds", "\(attempt) polls in \(elapsed) s")
    }

    static func pollLoop() async {
        // A Claude sign-in that lands on the 4th poll: polling then stops by itself.
        let effects = Effects()
        let agent = status("cursor", path: "/Users/x/.local/bin/agent")
        let pending = report(status("claude", path: "/opt/homebrew/bin/claude", signIn: "signInRequired"), status("codex", path: chatgptCodex), agent)
        let done = report(status("claude", path: "/opt/homebrew/bin/claude"), status("codex", path: chatgptCodex), agent)
        let g = guide([pending, pending, pending, pending, done], effects: effects)
        var clock = Date(timeIntervalSince1970: 0)
        await g.poll(sleep: { seconds in clock = clock.addingTimeInterval(seconds); return true }, now: { clock })
        check(g.report?.status(.claude)?.signIn == "signedIn", "poll loop", "the row turns green")
        check(g.pollCount == 4 && effects.statusCalls.count == 5, "poll loop", "stops once nothing waits: \(g.pollCount) polls, \(effects.statusCalls.count) reads")
        check(effects.statusCalls.first == ["provider-status", "--json"], "poll loop", "one full read first: \(effects.statusCalls.first ?? [])")
        check(effects.statusCalls.dropFirst().allSatisfy { $0 == ["provider-status", "--json", "--only", "claude"] }, "poll loop", "then only the row still waiting: \(effects.statusCalls.last ?? [])")
        // Never signs in: stops at 15 minutes.
        let stuck = Effects()
        let s = guide([pending], effects: stuck)
        var t = Date(timeIntervalSince1970: 0)
        await s.poll(sleep: { seconds in t = t.addingTimeInterval(seconds); return true }, now: { t })
        check(t.timeIntervalSince1970 <= 900 && s.pollCount > 10 && s.pollCount <= 80, "poll loop", "ends at 15 minutes: \(t.timeIntervalSince1970) s, \(s.pollCount) polls")
        // Card goes away (the sleep is cancelled): no more reads.
        let gone = Effects()
        let h = guide([pending], effects: gone)
        await h.poll(sleep: { _ in false }, now: Date.init)
        check(gone.statusCalls.count == 1 && h.pollCount == 0, "poll loop", "only while visible: \(gone.statusCalls.count)")
        // Nothing to wait for: one read, no polling.
        let idle = Effects()
        let i = guide([done], effects: idle)
        var u = Date(timeIntervalSince1970: 0)
        await i.poll(sleep: { seconds in u = u.addingTimeInterval(seconds); return true }, now: { u })
        check(idle.statusCalls.count == 1 && i.pollCount == 0 && i.pollTargets.isEmpty, "poll loop", "all signed in: no polling, \(idle.statusCalls.count) reads")
    }

    static func signInFlow() async {
        let effects = Effects()
        let codexPending = report(status("claude", path: "/opt/homebrew/bin/claude"), status("codex", path: chatgptCodex, signIn: "signInRequired"))
        let codexDone = report(status("claude", path: "/opt/homebrew/bin/claude"), status("codex", path: chatgptCodex))
        let g = guide([codexPending, codexDone], effects: effects)
        await g.refresh()
        await g.signIn(.codex)
        check(effects.terminal.count == 1 && effects.terminal[0].contains(#"do script "'\#(chatgptCodex)' login""#), "sign in", "Terminal runs the app's codex login: \(effects.terminal)")
        check(g.waiting[.codex] != nil && g.row(.codex).waiting, "sign in", "the row waits")
        check(effects.opened.isEmpty, "sign in", "no link is opened")
        await g.refresh(only: [.codex])
        check(g.waiting[.codex] == nil && g.row(.codex).tone == .good && g.notice == "ChatGPT is connected.", "sign in", "turns green on its own: \(g.notice ?? "")")
        // Terminal refused: the command goes on the clipboard instead, and nothing waits.
        let failing = Effects(); failing.terminalWorks = false
        let f = guide([codexPending], effects: failing)
        await f.refresh()
        await f.signIn(.codex)
        check(failing.copied == ["'\(chatgptCodex)' login"] && f.waiting.isEmpty && f.notice?.contains("clipboard") == true, "sign in fallback", "\(failing.copied)")
        // Skip persists; signing in later clears it.
        let defaults = freshDefaults()
        let k = guide([codexPending], effects: Effects(), defaults: defaults)
        await k.refresh()
        k.skip(.codex)
        check(defaults.stringArray(forKey: ProviderGuide.skippedKey) == ["codex"] && k.signInStepDone, "skip", "remembered")
        let k2 = guide([codexPending], effects: Effects(), defaults: defaults)
        check(k2.skipped == [.codex], "skip", "a new guide reads it back")
        await k2.signIn(.codex)
        check(k2.skipped.isEmpty, "skip", "Sign in clears the skip")
    }

    static func passFlow() async {
        let effects = Effects()
        let pending = report(status("claude", installed: false, signIn: "unknown", version: nil), status("cursor", installed: false, signIn: "unknown", version: nil))
        let g = guide([pending], effects: effects)
        await g.refresh()
        g.refreshApps()
        check(g.installedApps == [.claude, .codex], "apps", "\(g.installedApps)")
        check(g.pass(.cursor, to: .claude, tag: "abcd1234ef"), "pass", "opens")
        check(effects.folders == ["/Users/fixture home/Library/Application Support/COS Control/setup/abcd1234ef"], "pass folder", "a dedicated empty folder: \(effects.folders)")
        check(effects.opened.count == 1 && effects.opened[0].absoluteString.hasPrefix("claude://code/new?folder=") && effects.opened[0].absoluteString.contains("abcd1234ef"), "pass link", "\(effects.opened)")
        check(effects.terminal.isEmpty, "pass", "Pass never opens Terminal")
        check(!g.pass(.cursor, to: .claude, tag: "zzzz9999zz") && effects.opened.count == 1, "pass one at a time", "a second pass for the same provider is refused")
        check(g.pass(.claude, to: .claude, tag: "yyyy8888yy"), "pass one at a time", "another provider can pass")
        g.stopWaiting(.cursor)
        check(g.pass(.cursor, to: .codex, tag: "xxxx7777xx") && effects.opened.last?.absoluteString.hasPrefix("codex://threads/new?path=") == true, "pass", "after Stop waiting, again")
        let closed = Effects(); closed.openWorks = false
        let c = guide([pending], effects: closed)
        check(!c.pass(.claude, to: .claude, tag: "abcd1234ef") && c.waiting.isEmpty && c.notice?.contains("could not be opened") == true, "pass refused", "an app that does not open leaves nothing waiting")
        check(!c.pass(.claude, to: .claude, tag: "BAD"), "pass tag", "a bad tag never opens anything")
    }

    static func dock() {
        check(DockPresence.mode(stored: nil) == .dock, "dock default", "never chose: Dock")
        check(DockPresence.mode(stored: "menuBarOnly") == .menuBarOnly, "dock choice", "an explicit choice is kept")
        check(DockPresence.mode(stored: "dock") == .dock && DockPresence.mode(stored: "junk") == .dock, "dock default", "anything else: Dock")
        check(DockPresence.reopenTarget(needsFirstRun: true, activityAvailable: true) == .setup, "dock click", "not set up: Welcome")
        check(DockPresence.reopenTarget(needsFirstRun: false, activityAvailable: true) == .activity, "dock click", "Activity")
        check(DockPresence.reopenTarget(needsFirstRun: false, activityAvailable: false) == .setup, "dock click", "no Activity: Welcome")
    }

    static func petIntro() {
        check(PetIntro.shouldShow(seen: false, touchedKeys: 0, petEnabled: true), "pet intro", "first run")
        check(!PetIntro.shouldShow(seen: true, touchedKeys: 0, petEnabled: true), "pet intro", "once")
        check(!PetIntro.shouldShow(seen: false, touchedKeys: 1, petEnabled: true), "pet intro", "someone who changed a pet setting already knows it")
        check(!PetIntro.shouldShow(seen: false, touchedKeys: 0, petEnabled: false), "pet intro", "no pet, no introduction")
        check(PetIntro.touchedKeys.contains("cos.sessionPetEnabled") && PetIntro.touchedKeys.contains("cos.sessionPetNoMotion"), "pet intro", "the keys the settings write")
    }

    static func agentCliLine() {
        // The field bug: the server's failed `--version` read "Not signed in" (Views.swift:2405, 0.5.267).
        let noLocal = AgentCliText.detail(server: [.claude: false, .codex: true], cursorState: "notInstalled", local: nil)
        check(noLocal == "Not found: claude, cursor", "agent line fallback", "a failed server probe is not a sign-in problem: \(noLocal ?? "nil")")
        check(!(noLocal ?? "").contains("Not signed in"), "agent line fallback", "")
        let local = AgentCliText.detail(server: [.claude: false, .codex: true], cursorState: "notInstalled", local: mixed)
        check(local == "Not found: cursor · Not signed in: claude (run: claude auth login)", "agent line local", local ?? "nil")
        let serverMissed = AgentCliText.detail(server: [.claude: false, .codex: true], cursorState: "connected", local: allIn)
        check(serverMissed == "Installed, but the COS server could not run: claude", "agent line server missed", serverMissed ?? "nil")
        check(AgentCliText.detail(server: [.claude: true, .codex: true], cursorState: "connected", local: nil) == nil, "agent line", "all ready: nothing to fix")
        let cursorSignIn = AgentCliText.detail(server: [.claude: true, .codex: true], cursorState: "signInRequired", local: nil)
        check(cursorSignIn == "Not signed in: cursor (run: agent login)", "agent line cursor", cursorSignIn ?? "nil")
        let codexPath = AgentCliText.detail(server: [.claude: true, .codex: false], cursorState: "connected",
                                            local: report(status("codex", path: chatgptCodex, signIn: "signInRequired")))
        check(codexPath?.contains("'\(chatgptCodex)' login") == true, "agent line", "the command that works on this Mac: \(codexPath ?? "nil")")
        check(AgentCliText.detail(server: [.claude: nil, .codex: nil], cursorState: nil, local: nil) == nil, "agent line unknown", "unknown is left to the caller's 'Unreported' line")
    }

    static func voiceReady() -> VoiceFacts {
        var v = VoiceFacts(); v.whisperCli = true; v.whisperServer = true; v.brew = true; v.setupAvailable = true
        v.missingBytes = ["balanced": 0, "max": 0]; v.enoughDisk = ["balanced": true, "max": true]; v.freeBytes = 900_000_000_000
        v.whisperReady = true; v.requestedTier = "balanced"; v.previewModel = "Small.en"; v.commitModel = "Turbo"; v.polishModel = "Large-v3"
        return v
    }

    static func facts(_ r: ProviderStatusReport, running: Bool = true, voice: VoiceFacts? = nil) -> SetupFacts {
        var f = SetupFacts(); f.report = r; f.serverRunning = running; f.voice = voice
        f.claudeSessionsEnabled = running ? false : nil; f.threadAttachSupported = running; f.threadAttachEnabled = running ? true : nil
        f.jevConfigured = running ? false : nil; f.permissionsNeedCount = 1
        return f
    }

    static func setupGuide() {
        // Early user before Get started: server rows wait and are not counted.
        let early = SetupGuideRules.rows(facts(allMissing, running: false), skipped: [])
        check(early.filter(\.afterSetup).map(\.id) == [.voice, .sessions, .jev], "setup guide early", "\(early.filter(\.afterSetup).map(\.id))")
        check(SetupGuideRules.progress(early) == (0, 5), "setup guide early", "counts claude, codex, cursor, ollama, permissions: \(SetupGuideRules.progress(early))")
        check(SetupGuideRules.showFinishCard(early, hidden: false) && SetupGuideRules.finishTitle(early) == "Finish setup · 0 of 5", "finish card early", SetupGuideRules.finishTitle(early))
        check(!SetupGuideRules.showFinishCard(early, hidden: true), "finish card hide", "Hide setup guide removes the card")
        // Mid: codex signed in, voice ready, continue on.
        var midFacts = facts(mixed, voice: voiceReady()); midFacts.providerSkipped = [.cursor]
        let mid = SetupGuideRules.rows(midFacts, skipped: [])
        let p = SetupGuideRules.progress(mid)
        check(p.total == 9 && p.handled == 4, "finish card mid", "codex, cursor (skipped), voice, continue: \(p)")
        check(mid.map(\.id) == [.claude, .codex, .cursor, .ollama, .voice, .sessions, .continueThreads, .jev, .permissions], "setup guide rows", "\(mid.map(\.id))")
        // Done: everything done or skipped.
        var allDone = facts(allIn, voice: voiceReady())
        allDone.claudeSessionsEnabled = true; allDone.jevConfigured = true; allDone.permissionsNeedCount = 0
        let done = SetupGuideRules.rows(allDone, skipped: [])
        check(SetupGuideRules.progress(done) == (9, 9) && !SetupGuideRules.showFinishCard(done, hidden: false), "finish card done", "\(SetupGuideRules.progress(done))")
        var allSkipped = facts(mixed, voice: voiceReady()); allSkipped.providerSkipped = Set(AIProvider.agents)
        let skippedAll = SetupGuideRules.rows(allSkipped, skipped: Set(SetupRowID.allCases))
        check(!SetupGuideRules.showFinishCard(skippedAll, hidden: false), "finish card skipped", "skipping every row also ends the card")
        // No Continue row on a server without it; settings rows say what they unlock.
        var old = facts(mixed); old.threadAttachSupported = false
        check(!SetupGuideRules.rows(old, skipped: []).contains { $0.id == .continueThreads }, "setup guide rows", "only settings this server has")
        let sessions = mid.first { $0.id == .sessions }!
        check(sessions.action == .turnOnSessions && sessions.detail?.contains("untrusted network") == true, "sessions row", "the privacy note travels with Turn on")
        let ollama = SetupGuideRules.rows(facts(allIn), skipped: []).first { $0.id == .ollama }!
        check(ollama.done && ollama.detail?.contains("qwen3:4b") == true && ollama.detail?.contains("Local model") == true, "ollama row", ollama.detail ?? "")
        var pinned = facts(allIn); pinned.ollamaPinnedModel = "qwen3:4b"
        check(SetupGuideRules.rows(pinned, skipped: []).first { $0.id == .ollama }!.detail?.contains("COS uses qwen3:4b") == true, "ollama row", "the existing Local model setting")
        let down = SetupGuideRules.rows(facts(mixed), skipped: []).first { $0.id == .ollama }!
        check(!down.done && down.action == .openOllama, "ollama row", "installed, not running: Open Ollama")
        // Skips persist.
        let d = freshDefaults()
        let g = SetupGuideState(defaults: d)
        g.skip(.voice); g.hide()
        let g2 = SetupGuideState(defaults: d)
        check(g2.skipped == [.voice] && g2.hidden, "setup guide resume", "skips and Hide are remembered")
        g2.unskip(.voice); g2.show()
        check(SetupGuideState(defaults: d).skipped.isEmpty && !SetupGuideState(defaults: d).hidden, "setup guide resume", "and can be undone")
    }

    static func voiceRows() {
        func row(_ v: VoiceFacts, tier: String = "balanced") -> SetupRow {
            var f = facts(allIn, voice: v); f.voiceTier = tier
            return SetupGuideRules.voice(f, skipped: false)
        }
        let ready = row(voiceReady())
        check(ready.done && ready.status == "Ready · Balanced" && ready.detail == "Small.en live · Turbo commit · Large-v3 polish", "voice ready", "matches the panel's rows: \(ready.status) \(ready.detail ?? "")")
        var noWhisper = voiceReady(); noWhisper.whisperReady = false; noWhisper.whisperCli = false; noWhisper.whisperServer = false
        let needs = row(noWhisper)
        check(needs.status == "Needs whisper.cpp" && needs.action == .voiceNeedsWhisper("brew install whisper-cpp") && needs.detail?.contains("does not include") == true, "voice whisper.cpp", "\(needs)")
        noWhisper.brew = false
        check(row(noWhisper).detail?.contains("brew.sh") == true, "voice whisper.cpp", "no Homebrew: says so, never installs it")
        var missing = voiceReady(); missing.whisperReady = false; missing.requestedTier = nil; missing.missingBytes = ["balanced": 5_233_688_222, "max": 4_746_074_021]
        let dl = row(missing)
        check(dl.action == .voiceDownload("balanced") && dl.actionTitle == "Download 5.2 GB" && dl.detail?.contains("is free") == true, "voice download", "\(dl.actionTitle ?? "") \(dl.detail ?? "")")
        check(row(missing, tier: "max").actionTitle == "Download 4.7 GB", "voice download", "Max downloads less")
        var full = missing; full.enoughDisk = ["balanced": false]; full.freeBytes = 2_000_000_000
        let disk = row(full)
        check(disk.status == "Needs more disk space" && disk.action == SetupAction.none && disk.detail?.contains("2.0 GB is free") == true, "voice disk", disk.detail ?? "")
        var degraded = voiceReady(); degraded.degraded = true; degraded.degradedReason = "Turbo fallback weights are missing."
        let apply = row(degraded)
        check(!apply.done && apply.action == .voiceApply("balanced") && apply.detail == "Turbo fallback weights are missing.", "voice apply", "a degraded tier is not done: \(apply)")
        var noServer = missing; noServer.setupAvailable = false
        check(row(noServer).action == SetupAction.none, "voice download", "no installed server: no in-app download")
        check(VoiceTier.explanation("balanced").contains("Small.en") && VoiceTier.explanation("max").contains("powerful Mac"), "voice tiers", "plain words")
        let decoded = VoiceFacts.decode(Data(#"{"whisperCli":"/opt/homebrew/bin/whisper-cli","whisperServer":null,"brew":"/opt/homebrew/bin/brew","missingBytes":{"balanced":5233688222},"enoughDisk":{"balanced":true},"freeBytes":10,"setupAvailable":true,"terminalCommand":{"balanced":"x"}}"#.utf8))
        check(decoded?.whisperCli == true && decoded?.whisperServer == false && decoded?.missingBytes["balanced"] == 5_233_688_222 && decoded?.terminalCommand["balanced"] == "x", "voice decode", "\(String(describing: decoded))")
        check(!VoiceSetupGate.canStart(noWhisper, tier: "balanced") && !VoiceSetupGate.canStart(full, tier: "balanced") && VoiceSetupGate.canStart(missing, tier: "balanced") && !VoiceSetupGate.canStart(missing, tier: "turbo"), "voice gate", "")
    }

    static func voiceFlow() async {
        var missing = voiceReady(); missing.whisperReady = false; missing.missingBytes = ["balanced": 5_000_000_000]
        let g = SetupGuideState(defaults: freshDefaults())
        g.voice = missing
        g.skip(.voice)
        var applied: [String] = []
        var lines: [String] = []
        g.runVoiceSetup = { tier, progress in
            progress("Downloading Large-v3 (3.1 GB): 48%")
            try await Task.sleep(for: .milliseconds(50))
            lines.append(tier)
            return "Voice models are ready."
        }
        g.applyTier = { applied.append($0) }
        g.startVoiceSetup()
        check(g.voiceRunning && !g.skipped.contains(.voice), "voice flow", "starting unskips the row")
        g.startVoiceSetup()
        for _ in 0..<100 where g.voiceRunning { try? await Task.sleep(for: .milliseconds(20)) }
        check(lines == ["balanced"] && applied == ["balanced"] && g.voiceMessage == "Voice models are ready.", "voice flow", "downloads once, then applies the tier: \(lines) \(applied)")
        // Cancel.
        let c = SetupGuideState(defaults: freshDefaults())
        c.voice = missing
        var cancelApplied: [String] = []
        c.runVoiceSetup = { _, _ in try await Task.sleep(for: .seconds(30)); return "x" }
        c.applyTier = { cancelApplied.append($0) }
        c.startVoiceSetup()
        c.cancelVoiceSetup()
        for _ in 0..<100 where c.voiceRunning { try? await Task.sleep(for: .milliseconds(20)) }
        check(!c.voiceRunning && cancelApplied.isEmpty && c.voiceMessage?.contains("kept") == true, "voice cancel", "Cancel applies nothing and says the download is kept: \(c.voiceMessage ?? "")")
        // Never starts without whisper.cpp.
        let w = SetupGuideState(defaults: freshDefaults())
        var none = missing; none.whisperCli = false
        w.voice = none
        var ran = false
        w.runVoiceSetup = { _, _ in ran = true; return "" }
        w.startVoiceSetup()
        check(!w.voiceRunning && !ran, "voice gate", "no whisper.cpp: nothing runs")
    }

    static func qaFixes() async {
        // B1: every row that shows a button does something (Get Ollama opened nothing).
        var everything: [SetupRow] = []
        for r in [allMissing, mixed, allIn] {
            for v in [nil, voiceReady()] as [VoiceFacts?] {
                for running in [false, true] { everything += SetupGuideRules.rows(facts(r, running: running, voice: v), skipped: []) }
            }
        }
        var noWhisper = voiceReady(); noWhisper.whisperReady = false; noWhisper.whisperCli = false
        everything += SetupGuideRules.rows(facts(allIn, voice: noWhisper), skipped: [])
        check(everything.allSatisfy { $0.actionTitle == nil || $0.action != SetupAction.none }, "every button acts", "\(everything.filter { $0.actionTitle != nil && $0.action == SetupAction.none }.map(\.id))")
        let getOllama = SetupGuideRules.rows(facts(allMissing), skipped: []).first { $0.id == .ollama }!
        check(getOllama.action == .download(.ollama) && getOllama.actionTitle == "Get Ollama", "get ollama", "\(getOllama.action)")
        // W5: installed with an unreadable sign-in counts as handled; nothing counts before the facts arrive.
        let unknown = report(status("claude", path: "/opt/homebrew/bin/claude", signIn: "unknown"))
        check(SetupGuideRules.rows(facts(unknown), skipped: []).first { $0.id == .claude }!.done, "unknown handled", "installed, sign-in unknown is done")
        let late = ProviderStatusReport.decode(Data(#"{"providers":[{"provider":"claude","installed":false,"binaryPath":null,"version":null,"signIn":"unknown","candidates":[],"detail":"Did not answer in time.","timedOut":true}]}"#.utf8))!
        let lateRow = ProviderRules.row(.claude, late.status(.claude), skipped: false, waiting: false)
        check(lateRow.status == "Could not check" && lateRow.canSkip && !SetupGuideRules.rows(facts(late), skipped: []).first { $0.id == .claude }!.done, "timed out row", "\(lateRow)")
        var noReport = facts(mixed); noReport.report = nil
        check(!SetupGuideRules.loaded(noReport) && !SetupGuideRules.showFinishCard(SetupGuideRules.rows(noReport, skipped: []), hidden: false, loaded: false), "finish card loading", "no card before the report")
        var noVoice = facts(mixed); noVoice.voice = nil
        check(!SetupGuideRules.loaded(noVoice), "finish card loading", "running COS waits for the voice facts")
        noVoice.voiceUnavailable = true
        check(SetupGuideRules.loaded(noVoice), "finish card loading", "or their failure")
        noVoice.whisperReady = true; noVoice.requestedTier = "max"
        let fallback = SetupGuideRules.voice(noVoice, skipped: false)
        check(fallback.done && fallback.status == "Ready · Max", "voice fallback", "voice-status failed: the server's whisperReady decides: \(fallback.status)")
        noVoice.whisperReady = false
        check(SetupGuideRules.voice(noVoice, skipped: false).status == "Could not check", "voice fallback", "never Checking forever")
        // W7: one skip store.
        let state = SetupGuideState(defaults: freshDefaults())
        state.skip(.claude)
        check(!state.skipped.contains(.claude), "one skip store", "provider rows are skipped in ProviderGuide only")
        // B3: a Max user opens the voice row and cancels: still Max, nothing applied.
        let maxUser = SetupGuideState(defaults: freshDefaults())
        maxUser.adoptServerTier("max")
        check(maxUser.voiceTier == "max", "voice tier start", "the row starts on the server's tier")
        var missing = voiceReady(); missing.whisperReady = false; missing.missingBytes = ["balanced": 5_000_000_000, "max": 4_700_000_000]
        maxUser.voice = missing
        var applied: [String] = []
        var ranTier: String?
        maxUser.runVoiceSetup = { tier, _ in ranTier = tier; try await Task.sleep(for: .seconds(30)); return "x" }
        maxUser.applyTier = { applied.append($0) }
        maxUser.startVoiceSetup()
        try? await Task.sleep(for: .milliseconds(30))
        maxUser.cancelVoiceSetup()
        for _ in 0..<100 where maxUser.voiceRunning { try? await Task.sleep(for: .milliseconds(20)) }
        check(ranTier == "max" && applied.isEmpty && maxUser.voiceTier == "max" && maxUser.voiceMessage?.contains("did not change") == true, "max user cancel", "Max stays Max: ran \(ranTier ?? "nil"), applied \(applied)")
        let picked = SetupGuideState(defaults: freshDefaults())
        picked.voiceTier = "max"
        picked.adoptServerTier("balanced")
        check(picked.voiceTier == "max", "voice tier start", "a pick in the row wins over the server's tier")
        // W5/W6: the poll limit stops the wait and says so; a new Sign in starts its own clock.
        let effects = Effects()
        let pending = report(status("claude", path: "/opt/homebrew/bin/claude", signIn: "signInRequired"), status("codex", path: chatgptCodex), status("cursor", path: "/Users/x/.local/bin/agent"))
        var logs: [String] = []
        let g = guide([pending], effects: effects)
        g.log = { logs.append($0) }
        await g.refresh()
        await g.signIn(.claude)
        var clock = Date()
        await g.poll(sleep: { seconds in clock = clock.addingTimeInterval(seconds); return true }, now: { clock })
        check(g.waiting.isEmpty && g.expired == [.claude] && g.row(.claude).status == "Stopped checking", "poll limit", "the row stops waiting and says so: \(g.row(.claude).status)")
        check(logs.contains { $0.hasPrefix("sign-in opened provider=claude") } && logs.contains { $0.hasPrefix("sign-in stopped checking provider=claude") }, "logging", "\(logs)")
        await g.checkAgain(.claude)
        check(!g.expired.contains(.claude), "poll limit", "Check again clears it")
        // W6: osascript failed but Terminal opened: the command is on the clipboard and the row waits.
        let denied = Effects(); denied.terminalWorks = false
        let d = guide([pending], effects: denied)
        d.openTerminalApp = { true }
        await d.refresh()
        await d.signIn(.claude)
        check(denied.copied == ["claude auth login"] && d.waiting[.claude] != nil && d.notice?.contains("Automation") == true, "sign in fallback", "\(denied.copied) \(d.notice ?? "")")
        // Dock and Settings decisions.
        check(DockPresence.reopenTarget(needsFirstRun: false, activityAvailable: true, statusRead: false) == .setup, "dock click", "before the first status: Welcome")
        check(DockPresence.showUpgradeNotice(stored: nil, seen: false, firstRun: false) && !DockPresence.showUpgradeNotice(stored: "dock", seen: false, firstRun: false)
              && !DockPresence.showUpgradeNotice(stored: nil, seen: true, firstRun: false) && !DockPresence.showUpgradeNotice(stored: nil, seen: false, firstRun: true), "dock notice", "once, for upgraders who never chose")
        check(DockPresence.openActivityOnActivate(mode: .dock, visibleWindows: 0, panelVisible: false)
              && !DockPresence.openActivityOnActivate(mode: .dock, visibleWindows: 0, panelVisible: true)
              && !DockPresence.openActivityOnActivate(mode: .menuBarOnly, visibleWindows: 0, panelVisible: false)
              && !DockPresence.openActivityOnActivate(mode: .dock, visibleWindows: 1, panelVisible: false), "cmd-tab", "Activity only when nothing is showing")
        let shown = SettingsRoute.StatusItem(visible: true, onScreen: true, underNotch: false)
        check(SettingsRoute.decide(panelOpen: true, item: shown) == .scrollOpenPanel, "settings route", "an open panel is never clicked closed")
        check(SettingsRoute.decide(panelOpen: false, item: shown) == .clickStatusItem, "settings route", "a visible icon opens the panel")
        check(SettingsRoute.decide(panelOpen: false, item: SettingsRoute.StatusItem(visible: true, onScreen: true, underNotch: true)) == .window
              && SettingsRoute.decide(panelOpen: false, item: SettingsRoute.StatusItem(visible: false, onScreen: true, underNotch: false)) == .window
              && SettingsRoute.decide(panelOpen: false, item: SettingsRoute.StatusItem(visible: true, onScreen: false, underNotch: false)) == .window
              && SettingsRoute.decide(panelOpen: false, item: nil) == .window, "settings route", "a hidden icon gets the Settings window")
        check(ProviderGuide.statusTimeout == 35, "status timeout", "25 s deadline plus 10 s")
        check(ProviderPass.prompt(setUp: .codex, tag: "abcd1234ef")!.contains("~/Applications/ChatGPT.app") && ProviderPass.prompt(setUp: .claude, tag: "abcd1234ef")!.contains("/opt/homebrew/bin/claude"), "pass prompts", "COS's own paths")
        check(PetIntro.touchedKeys.allSatisfy { $0 != "cos.sessionPetCharacterPercent" }, "pet intro", "the migration's key is not a sign of a person")
    }
}
