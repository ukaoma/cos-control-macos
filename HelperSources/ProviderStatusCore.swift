import Foundation

// Provider status for Connect your AI (onboarding P1, 2026-10-08). Pure: no process is spawned and no file is read
// here. `cos-control-helper provider-status --json` wires the real probes in (HelperSources/main.swift), and
// Tests/ProviderStatusChecks.swift drives this file alone with fixtures. Nothing here starts a model turn, signs in,
// reads a token file or keeps an email address.

/// What a CLI's own status command says about its sign-in.
enum ProviderSignIn: String, Sendable, Equatable {
    case signedIn
    case signInRequired
    /// The CLI answered something this build cannot read, or the check could not run. Never shown as a failure.
    case unknown
    /// Signed in with an API key or a cloud provider account: works, billed separately from a subscription.
    case apiKey
    /// Ollama: no account.
    case notNeeded
}

struct ProviderCandidate: Sendable, Equatable {
    /// "env", "absolute", "path", "extra", "claudeDesktop" (Claude Desktop's own copy, which the COS server never runs).
    var path: String
    var source: String
    var executable = false
    var chosen = false
    var note: String?
}

/// Everything the candidate search needs from the Mac, injected.
struct ProviderSearchEnvironment {
    var home: String
    /// The helper's own environment: PATH and the COS_*_BIN overrides.
    var env: [String: String]
    var isExecutable: (String) -> Bool
    /// Names in a directory (no paths), or [] when it cannot be read.
    var listDirectory: (String) -> [String]
}

enum ProviderStatusCore {
    static let providers = ["claude", "codex", "cursor", "ollama"]

    /// Paths that are never a usable provider binary (server/lib/provider-binary.ts STALE_SHIM_PREFIXES): the Codex
    /// app no longer exists, and a leftover file there cannot serve COS.
    static let staleShimPrefixes = ["/Applications/Codex.app/"]

    /// The executable names a provider answers to. Cursor's CLI is installed as both `agent` and `cursor-agent`.
    static func names(_ provider: String) -> [String] {
        switch provider {
        case "claude": ["claude"]
        case "codex": ["codex"]
        case "cursor": ["agent", "cursor-agent"]
        case "ollama": ["ollama"]
        default: []
        }
    }

    /// Environment overrides, in the server's order.
    static func envKeys(_ provider: String) -> [String] {
        switch provider {
        case "claude": ["COS_ATTACHED_CLAUDE_BIN", "COS_CLAUDE_BIN"]
        case "codex": ["COS_ATTACHED_CODEX_BIN", "COS_CODEX_BIN"]
        case "cursor": ["COS_ATTACHED_CURSOR_AGENT_BIN", "COS_CURSOR_AGENT_BIN"]
        default: []
        }
    }

    /// The server's absolute list (server/lib/provider-binary.ts, 6.56.1), then the per-user app copies Control also
    /// checks (0.5.268). Tried BEFORE any PATH entry, exactly as the server does.
    static func absolutes(_ provider: String, home: String) -> [String] {
        switch provider {
        case "claude":
            return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude"]
        case "codex":
            return [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "\(home)/.codex/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            ]
        case "cursor":
            return ["\(home)/.local/bin/agent", "\(home)/.local/bin/cursor-agent"]
        case "ollama":
            return ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                    "/Applications/Ollama.app/Contents/Resources/ollama",
                    "\(home)/Applications/Ollama.app/Contents/Resources/ollama"]
        default:
            return []
        }
    }

    /// Where the helper has always looked after PATH (executableCandidates in main.swift). The managed server gets
    /// these directories on its PATH (launchPathDirectories), so a binary found here is one it can run.
    static func extras(_ name: String, home: String) -> [String] {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)",
         "\(home)/.local/bin/\(name)", "\(home)/.volta/bin/\(name)", "\(home)/.asdf/shims/\(name)"]
    }

    static func isStaleShim(_ path: String) -> Bool { staleShimPrefixes.contains { path.hasPrefix($0) } }

    /// Every place a provider's CLI is looked for, in order, each marked executable or not. Never a shell alias: no
    /// shell is involved, so an alias in ~/.zshrc cannot make a CLI look installed.
    static func candidates(_ provider: String, in environment: ProviderSearchEnvironment) -> [ProviderCandidate] {
        var list: [ProviderCandidate] = []
        for key in envKeys(provider) {
            let raw = environment.env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !raw.isEmpty { list.append(ProviderCandidate(path: raw, source: "env")) }
        }
        list += absolutes(provider, home: environment.home).map { ProviderCandidate(path: $0, source: "absolute") }
        let pathDirs = (environment.env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for name in names(provider) {
            list += pathDirs.map { ProviderCandidate(path: "\($0)/\(name)", source: "path") }
        }
        for name in names(provider) {
            list += extras(name, home: environment.home).map { ProviderCandidate(path: $0, source: "extra") }
        }
        if provider == "claude", let desktop = claudeDesktopCopy(in: environment) {
            list.append(ProviderCandidate(path: desktop, source: "claudeDesktop",
                                          note: "Claude Desktop's own copy. The COS server does not run it."))
        }
        var seen = Set<String>()
        return list.compactMap { candidate in
            var c = candidate
            let key = URL(fileURLWithPath: c.path).standardizedFileURL.path
            guard c.path.hasPrefix("/"), !c.path.contains("\0"), seen.insert(key).inserted else { return nil }
            c.path = key
            if isStaleShim(c.path) {
                c.note = "The Codex app no longer exists; COS never uses this path."
                return c
            }
            c.executable = environment.isExecutable(c.path)
            return c
        }
    }

    /// Claude Desktop downloads Claude Code for its own Code tab, under
    /// ~/Library/Application Support/Claude/claude-code/<version>/<hash>/claude.app. The newest version is reported
    /// so the row can say why Claude still needs installing; it is never chosen.
    static func claudeDesktopCopy(in environment: ProviderSearchEnvironment) -> String? {
        let root = "\(environment.home)/Library/Application Support/Claude/claude-code"
        let versions = environment.listDirectory(root)
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            for hash in environment.listDirectory("\(root)/\(version)").sorted() where !hash.hasPrefix(".") {
                let path = "\(root)/\(version)/\(hash)/claude.app/Contents/MacOS/claude"
                if environment.isExecutable(path) { return path }
            }
        }
        return nil
    }

    // MARK: Parsing what each CLI prints

    /// First dotted-numeric token ("2.1.293 (Claude Code)" -> 2.1.293, "codex-cli 0.162.0-alpha.2" -> 0.162.0-alpha.2,
    /// "ollama version is 0.40.0" -> 0.40.0).
    static func versionToken(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            for piece in line.split(whereSeparator: { " ()\t,".contains($0) }) {
                let candidate = String(piece)
                let head = candidate.prefix(while: { $0.isNumber || $0 == "." })
                if head.contains("."), head.first?.isNumber == true { return candidate }
            }
        }
        return nil
    }

    /// `claude auth status` (JSON by default since 2.1, `--json` accepted). Reads only loggedIn, authMethod and
    /// apiProvider: the email, org and subscription fields are never kept.
    static func claudeSignIn(output: String, exitCode: Int32) -> ProviderSignIn {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else {
            let lower = output.lowercased()
            if lower.contains("not logged in") || lower.contains("not signed in") { return .signInRequired }
            return .unknown
        }
        guard loggedIn else { return .signInRequired }
        let method = (object["authMethod"] as? String ?? "").lowercased()
        let provider = (object["apiProvider"] as? String ?? "firstParty").lowercased()
        if provider != "firstparty" { return .apiKey }
        if method.contains("api") || method.contains("console") || method.contains("key") { return .apiKey }
        return .signedIn
    }

    /// `codex login status`: "Logged in using ChatGPT", "Logged in using an API key - sk-…", "Not logged in" (exit 1).
    static func codexSignIn(output: String, exitCode: Int32) -> ProviderSignIn {
        let lower = output.lowercased()
        if lower.contains("not logged in") { return .signInRequired }
        if lower.contains("logged in") {
            return lower.contains("api key") ? .apiKey : .signedIn
        }
        // An older CLI without `login status`, or one that failed for another reason: say nothing rather than
        // send the user to sign in again.
        return .unknown
    }

    /// `agent about`: proves the binary is Cursor's CLI (a "CLI Version" line) and carries the sign-in (a
    /// "User Email" line with an address). The address itself is never returned.
    static func cursorAbout(output: String) -> (isCursor: Bool, version: String?, signIn: ProviderSignIn) {
        var version: String?
        var isCursor = false
        var emailLine: String?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("CLI Version") {
                isCursor = true
                let rest = line.dropFirst("CLI Version".count).trimmingCharacters(in: CharacterSet(charactersIn: " :\t"))
                if !rest.isEmpty { version = rest.split(separator: " ").first.map(String.init) }
            } else if line.hasPrefix("User Email") {
                emailLine = line.dropFirst("User Email".count).trimmingCharacters(in: CharacterSet(charactersIn: " :\t"))
            }
        }
        guard isCursor else { return (false, nil, .unknown) }
        guard let emailLine else { return (true, version, .unknown) }
        let lower = emailLine.lowercased()
        // An address (or one a caller already redacted) means signed in; "Not logged in" or an empty value does not.
        if (emailLine.contains("@") || lower.contains("redacted")) && !lower.contains("not logged in") { return (true, version, .signedIn) }
        return (true, version, .signInRequired)
    }

    /// Ollama's /api/tags body. nil when it is not Ollama's answer.
    static func ollamaModels(_ data: Data) -> [String]? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = body["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// COS_OLLAMA_HOST as the server reads it: a bare host:port gets http://. Anything not loopback-shaped still
    /// works (the user set it), but only http and https are accepted.
    static func ollamaOrigin(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "http://127.0.0.1:11434" }
        let origin = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "http://\(trimmed)"
        return origin.hasSuffix("/") ? String(origin.dropLast()) : origin
    }
}

/// The probes the helper runs, injected so the whole decision is testable.
struct ProviderProbes {
    /// (exit code, combined output), or nil when it could not run or timed out.
    var run: (_ path: String, _ arguments: [String]) -> (code: Int32, output: String)?
    /// GET a URL: (status, body), or nil when nothing answered.
    var get: (_ url: URL) -> (status: Int, body: Data)?
}

struct ProviderStatus: Sendable, Equatable {
    var provider: String
    var installed = false
    var binaryPath: String?
    var version: String?
    var signIn: ProviderSignIn = .unknown
    var candidates: [ProviderCandidate] = []
    /// One plain sentence when something needs explaining (a desktop-only copy, a daemon that is down).
    var detail: String?
    // Ollama only.
    var daemon: String?
    var models: [String]?
    var host: String?

    var json: [String: Any] {
        var out: [String: Any] = [
            "provider": provider,
            "installed": installed,
            "binaryPath": binaryPath ?? NSNull(),
            "version": version ?? NSNull(),
            "signIn": signIn.rawValue,
            "detail": detail ?? NSNull(),
            "candidates": candidates.map { c -> [String: Any] in
                var item: [String: Any] = ["path": c.path, "source": c.source, "executable": c.executable, "chosen": c.chosen]
                if let note = c.note { item["note"] = note }
                return item
            },
        ]
        if provider == "ollama" {
            out["daemon"] = daemon ?? NSNull()
            out["models"] = models ?? []
            out["host"] = host ?? NSNull()
        }
        return out
    }
}

enum ProviderStatusProbe {
    static func status(_ provider: String, environment: ProviderSearchEnvironment, probes: ProviderProbes) -> ProviderStatus {
        var status = ProviderStatus(provider: provider)
        var candidates = ProviderStatusCore.candidates(provider, in: environment)
        func choose(_ index: Int) {
            candidates[index].chosen = true
            status.installed = true
            status.binaryPath = candidates[index].path
        }
        switch provider {
        case "cursor":
            // Only a binary whose `about` prints a "CLI Version" line is Cursor's: another `agent` on PATH is skipped.
            for index in candidates.indices where candidates[index].executable {
                guard let about = probes.run(candidates[index].path, ["about"]) else {
                    candidates[index].note = "Did not answer `about`."
                    continue
                }
                let parsed = ProviderStatusCore.cursorAbout(output: about.output)
                guard parsed.isCursor else {
                    candidates[index].note = "Not Cursor's CLI (no CLI Version line)."
                    continue
                }
                choose(index)
                status.version = parsed.version
                status.signIn = parsed.signIn
                break
            }
        case "ollama":
            if let index = candidates.firstIndex(where: { $0.executable }) {
                choose(index)
                if let result = probes.run(candidates[index].path, ["--version"]) {
                    status.version = ProviderStatusCore.versionToken(result.output)
                }
            }
            let origin = ProviderStatusCore.ollamaOrigin(environment.env["COS_OLLAMA_HOST"])
            status.host = origin
            status.signIn = .notNeeded
            if let url = URL(string: "\(origin)/api/tags"), let answer = probes.get(url), answer.status == 200,
               let models = ProviderStatusCore.ollamaModels(answer.body) {
                status.daemon = "running"
                status.models = models
                status.installed = true
                if status.binaryPath == nil { status.detail = "Ollama answers at \(origin)." }
            } else {
                status.daemon = "down"
                status.models = []
                status.detail = status.installed ? "Ollama is installed but not running. Open the Ollama app." : nil
            }
        default:
            // claude, codex: the first executable candidate that is not Claude Desktop's own copy.
            if let index = candidates.firstIndex(where: { $0.executable && $0.source != "claudeDesktop" }) {
                choose(index)
                let path = candidates[index].path
                if let result = probes.run(path, ["--version"]), result.code == 0 {
                    status.version = ProviderStatusCore.versionToken(result.output)
                }
                if provider == "claude" {
                    status.signIn = probes.run(path, ["auth", "status", "--json"])
                        .map { ProviderStatusCore.claudeSignIn(output: $0.output, exitCode: $0.code) } ?? .unknown
                } else {
                    status.signIn = probes.run(path, ["login", "status"])
                        .map { ProviderStatusCore.codexSignIn(output: $0.output, exitCode: $0.code) } ?? .unknown
                }
            } else if provider == "claude", candidates.contains(where: { $0.source == "claudeDesktop" && $0.executable }) {
                status.detail = "Claude Desktop has its own copy of Claude Code for its Code tab. COS needs the Claude Code command line too."
            }
        }
        if !status.installed && provider != "ollama" { status.signIn = .unknown }
        status.candidates = candidates
        return status
    }
}
