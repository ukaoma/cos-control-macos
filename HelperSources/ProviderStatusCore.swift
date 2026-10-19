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

    /// Three tries at most, with 6 s per command (`ProviderStatusCore.commandTimeout`), so Cursor fits the deadline.
    static let cursorAttempts = 3
    /// Each probe command stops after this many seconds: the slowest seen here was `agent about` at 0.55 s.
    static let commandTimeout: TimeInterval = 6
    /// The whole report stops after this many seconds and answers with what it has: one hung CLI can never blank the
    /// others (the app waits `totalDeadline + 10`, ProviderGuide.statusTimeout).
    static let totalDeadline: TimeInterval = 25

    /// `agent status --format json`: its isAuthenticated field, or nil when it is not Cursor's answer.
    static func cursorStatusJSON(_ output: String) -> Bool? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authenticated = object["isAuthenticated"] as? Bool else { return nil }
        return authenticated
    }

    /// Cursor's `--version` is a date and a commit ("2026.10.01-e373342"); anything else is not proof.
    static func cursorVersionToken(_ output: String) -> String? {
        let line = output.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return line.range(of: #"^\d{4}\.\d{2}\.\d{2}-[0-9a-f]{6,}$"#, options: .regularExpression) != nil ? line : nil
    }

    /// Whether the COS server can run this Cursor candidate: it looks for `agent` (or the path an env override names).
    static func serverRunnableCursor(_ candidate: ProviderCandidate) -> Bool {
        candidate.source == "env" || URL(fileURLWithPath: candidate.path).lastPathComponent == "agent"
    }

    /// Get started's gate, from the same candidate lists the rows use, with no probe run: Claude Code or Codex that
    /// the server can run (never Claude Desktop's copy or the retired Codex.app), or Cursor's `agent`.
    static func setupProviderPresent(in environment: ProviderSearchEnvironment) -> Bool {
        for provider in ["claude", "codex"] where candidates(provider, in: environment).contains(where: { $0.executable && $0.source != "claudeDesktop" }) {
            return true
        }
        return candidates("cursor", in: environment).contains { $0.executable && serverRunnableCursor($0) }
    }

    /// A row for a provider whose probes did not finish inside the deadline.
    static func timedOut(_ provider: String) -> [String: Any] {
        ["provider": provider, "installed": false, "binaryPath": NSNull(), "version": NSNull(), "signIn": "unknown",
         "detail": "Did not answer in time. Check again.", "candidates": [[String: Any]](), "timedOut": true,
         "daemon": NSNull(), "models": [String](), "host": NSNull()]
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
            // Cursor's CLI is proven by `about` (a "CLI Version" line), else by `status --format json` (its own
            // isAuthenticated field), else by a `--version` in its date-hash form. Another `agent` on PATH is skipped.
            // At most three candidates are tried, so a Mac with several stray `agent` files stays inside the deadline.
            var tried = 0
            for index in candidates.indices where candidates[index].executable && tried < ProviderStatusCore.cursorAttempts {
                tried += 1
                let path = candidates[index].path
                var proven = false
                if let about = probes.run(path, ["about"]) {
                    let parsed = ProviderStatusCore.cursorAbout(output: about.output)
                    if parsed.isCursor { proven = true; status.version = parsed.version; status.signIn = parsed.signIn }
                }
                if !proven || status.signIn == .unknown, let json = probes.run(path, ["status", "--format", "json"]),
                   let authenticated = ProviderStatusCore.cursorStatusJSON(json.output) {
                    proven = true
                    status.signIn = authenticated ? .signedIn : .signInRequired
                }
                if !proven, let version = probes.run(path, ["--version"]), version.code == 0,
                   let token = ProviderStatusCore.cursorVersionToken(version.output) {
                    proven = true
                    status.version = token
                    status.signIn = .unknown
                }
                guard proven else {
                    candidates[index].note = "Not Cursor's CLI (no CLI Version line, status or version)."
                    continue
                }
                if status.version == nil, let version = probes.run(path, ["--version"]) {
                    status.version = ProviderStatusCore.cursorVersionToken(version.output)
                }
                choose(index)
                // The COS server runs Cursor as `agent` (server/lib/provider-binary.ts). A copy reachable only as
                // `cursor-agent` is Cursor's, but COS cannot run it: say so instead of reading it as ready.
                if !ProviderStatusCore.serverRunnableCursor(candidates[index]) {
                    status.installed = false
                    status.binaryPath = nil
                    candidates[index].chosen = false
                    status.detail = "Cursor Agent is installed only as cursor-agent. COS runs it as agent: run the Cursor installer again to add that name."
                }
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

// MARK: - Voice (local Whisper) setup

// What `glasses-server --setup-transcription --transcription-tier <tier> --prepare-only` installs (bin/cli.cjs, read
// 2026-10-08 at server f72bbe5). It does NOT install whisper.cpp: it refuses to start ("Install it first: brew install
// whisper-cpp") unless whisper-cli AND whisper-server are found, and COS Control does not bundle them. It then
// downloads, resumably (curl --continue-at), into ~/.local/share/whisper-models:
//   ggml-large-v3-turbo.bin  1,624,555,275 bytes  both tiers (Balanced commit, Max preview)
//   ggml-small.en.bin          487,614,201 bytes  Balanced only (live preview)
//   ggml-large-v3.bin        3,095,033,483 bytes  both tiers (saved-meeting polish; Max live commit)
// plus the voiceprint model (26,485,263 bytes) into ~/.cos-glasses/models, and needs the missing bytes plus a 750 MB
// margin free. It writes the tier to ~/.cos-glasses/.env; COS Control's Apply then restarts the server on it.

struct WhisperModelFile: Sendable, Equatable {
    var name: String
    var label: String
    var bytes: Int64
    var minBytes: Int64
    var tiers: Set<String>
}

enum VoiceSetupCore {
    static let models: [WhisperModelFile] = [
        WhisperModelFile(name: "ggml-large-v3-turbo.bin", label: "Large-v3-Turbo", bytes: 1_624_555_275, minBytes: 800_000_000, tiers: ["balanced", "max"]),
        WhisperModelFile(name: "ggml-small.en.bin", label: "Small.en", bytes: 487_614_201, minBytes: 400_000_000, tiers: ["balanced"]),
        WhisperModelFile(name: "ggml-large-v3.bin", label: "Large-v3", bytes: 3_095_033_483, minBytes: 2_800_000_000, tiers: ["balanced", "max"]),
    ]
    static let voiceprintFile = "3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx"
    static let voiceprintBytes: Int64 = 26_485_263
    static let safetyMarginBytes: Int64 = 750_000_000
    static let whisperBinaries = ["whisper-cli", "whisper-server"]

    static func modelDirectory(home: String) -> String { "\(home)/.local/share/whisper-models" }

    /// The server's own search for whisper.cpp: its two Homebrew paths, then PATH.
    static func whisperPath(_ name: String, in environment: ProviderSearchEnvironment) -> String? {
        let key = name == "whisper-cli" ? "COS_WHISPER_CLI_BIN" : "COS_WHISPER_SERVER_BIN"
        if let configured = environment.env[key], !configured.isEmpty {
            return configured.hasPrefix("/") && environment.isExecutable(configured) ? configured : nil
        }
        let known = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        let path = (environment.env["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }.filter { $0.hasPrefix("/") }
        return (known + path).first { environment.isExecutable($0) }
    }

    static func normalizedTier(_ raw: String) -> String? {
        let tier = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["balanced", "max"].contains(tier) ? tier : nil
    }

    /// Bytes still to download for a tier, given each file's current size (nil = absent).
    static func missingBytes(tier: String, sizes: [String: Int64], voiceprintPresent: Bool) -> Int64 {
        var total: Int64 = voiceprintPresent ? 0 : voiceprintBytes
        for model in models where model.tiers.contains(tier) {
            if (sizes[model.name] ?? 0) < model.minBytes { total += model.bytes }
        }
        return total
    }

    /// The server's disk rule: free space plus partial downloads it can resume must cover the missing bytes plus the margin.
    static func enoughDisk(missing: Int64, freeBytes: Int64, partialBytes: Int64) -> Bool {
        missing == 0 || freeBytes + partialBytes >= missing + safetyMarginBytes
    }

    /// One progress line from the setup's output. Downloads announce "Downloading ggml-large-v3 (~3.1 GB)." and curl's
    /// progress bar redraws "####  45.3%" with carriage returns.
    static func progress(_ chunk: String, current: String?) -> (model: String?, percent: Double?) {
        var model = current
        var percent: Double?
        for piece in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(piece)
            if let range = line.range(of: "Downloading ggml-") {
                let rest = line[range.upperBound...]
                let stem = rest.prefix { $0 != " " && $0 != "." && $0 != "(" }
                if let file = models.first(where: { $0.name.hasPrefix("ggml-" + stem + ".") || $0.name == "ggml-" + stem + ".bin" }) {
                    model = file.label
                    percent = nil
                }
            } else if line.contains("voiceprint model") {
                model = "Voiceprint"
                percent = nil
            }
            if let match = line.range(of: #"([0-9]{1,3}(\.[0-9])?)%"#, options: .regularExpression) {
                let value = Double(line[match].dropLast()) ?? 0
                if value <= 100 { percent = value }
            }
        }
        return (model, percent)
    }

    static func progressMessage(model: String?, percent: Double?) -> String? {
        guard let model else { return nil }
        let size = models.first { $0.label == model }.map { " (\(gigabytes($0.bytes)))" } ?? (model == "Voiceprint" ? " (26 MB)" : "")
        if let percent { return "Downloading \(model)\(size): \(Int(percent))%" }
        return "Downloading \(model)\(size)…"
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func gigabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000) : "\(bytes / 1_000_000) MB"
    }
}

/// voice-setup's child process group, for the helper's SIGTERM handler (Cancel). 0 when nothing runs.
nonisolated(unsafe) var voiceSetupChildGroup: pid_t = 0
nonisolated(unsafe) var voiceSetupCancelled: sig_atomic_t = 0

// P1.5: deterministic policy kept apart from download/process effects.
struct VoiceBenchmarkPolicy {
    static let version = 1
    // Provisional conservative threshold. Validate on smaller Macs before promoting broadly.
    static let maximumTurboRTF = 0.25
    static func recommendation(memoryBytes: UInt64, realTimeFactor: Double, onBattery: Bool, metal: Bool) -> String {
        guard realTimeFactor.isFinite, realTimeFactor > 0, metal, !onBattery,
              memoryBytes >= 16 * 1_073_741_824, realTimeFactor <= maximumTurboRTF else { return "balanced" }
        return "max"
    }
    static func chosen(requested: String, existing: String?, recommendation: String) -> String {
        if let tier = VoiceSetupCore.normalizedTier(requested) { return tier }
        return existing.flatMap(VoiceSetupCore.normalizedTier) ?? recommendation
    }
}

/// The three keys `--setup-transcription` writes into ~/.cos-glasses/.env (bin/cli.cjs:544-551) before it checks
/// anything. voice-setup snapshots them first and puts them back afterwards, whatever happened: the live tier only
/// ever changes through the transactional set-transcription-tier.
enum VoiceEnvFile {
    static let keys = ["COS_WHISPER_TRANSCRIPTION_TIER", "COS_WHISPER_PREVIEW_MODEL", "COS_WHISPER_COMMIT_MODEL"]

    /// Each key's value, or nil when the file does not set it. The last assignment wins, as dotenv reads it.
    static func values(_ text: String) -> [String: String?] {
        var out: [String: String?] = Dictionary(uniqueKeysWithValues: keys.map { ($0, nil) })
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for key in keys where line.hasPrefix(key + "=") {
                out[key] = String(line.dropFirst(key.count + 1))
            }
        }
        return out
    }

    /// `text` with the three keys set back to `snapshot` (removed where the snapshot had none). Every other line,
    /// its order and the trailing newline are kept.
    static func restore(_ text: String, to snapshot: [String: String?]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadNewline = text.hasSuffix("\n")
        if hadNewline { lines.removeLast() }
        var written = Set<String>()
        lines = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let key = keys.first(where: { trimmed.hasPrefix($0 + "=") }) else { return line }
            guard let value = snapshot[key] ?? nil, !written.contains(key) else { return nil }
            written.insert(key)
            return "\(key)=\(value)"
        }
        for key in keys where !written.contains(key) {
            if let value = snapshot[key] ?? nil { lines.append("\(key)=\(value)") }
        }
        let body = lines.joined(separator: "\n")
        return body.isEmpty ? "" : body + (hadNewline || !text.isEmpty ? "\n" : "\n")
    }
}

/// voice-setup's Cancel: the SIGTERM handler kills the child group and sets this; the helper then restores the
/// .env snapshot before it exits.

// MARK: - Mac dictation for every engine (0.5.317, server 6.74.0)
//
// The pure half of the helper's `mac-dictation`, `dictation-check` and `dictation-benchmark`. The helper does the I/O.
// A server whose capabilities list 2 in `desktopDictationVersions` takes `requiredEngine=local`: Parakeet Ultra or
// local Whisper, by the person's Dictation engine setting, never the cloud. Any other server keeps the 0.5.316 request
// (`requiredEngine=parakeet-ultra`) and its words, byte for byte. `desktopDictationVersion` stays 1 on 6.74.0 because
// the 0.5.316 helper requires exactly 1.
enum DictationBridge {
    static let audioLimit = 3_840_044
    static let localRoute = "/api/transcribe?mode=fast&requiredEngine=local"
    static let parakeetRoute = "/api/transcribe?mode=fast&requiredEngine=parakeet-ultra"
    static let engines: Set<String> = ["parakeet-ultra", "whisper"]
    static let settings: Set<String> = ["auto", "parakeet-ultra", "whisper"]
    static let fallbackReasons: Set<String> = ["parakeet_not_installed", "parakeet_warming", "parakeet_warm_failed",
                                               "parakeet_breaker_open", "parakeet_busy", "parakeet_failed", "audio_not_pcm_wav"]
    static let reasons: Set<String> = ["no_local_engine", "parakeet_unavailable"]
    /// The one action a failure card offers. `retry_when_warm` reaches Control as `retry` with retryable true.
    static let actions: Set<String> = ["install_parakeet", "use_whisper", "retry", "open_transcription_settings", "none"]

    /// Whether this server takes the local route. Old servers (no list, or a list without 2) do not.
    static func local(_ capabilities: [String: Any]) -> Bool {
        guard let versions = capabilities["desktopDictationVersions"] as? [Any] else { return false }
        return versions.contains { ($0 as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.intValue == 2 } ?? false }
    }

    /// The route for this server, or nil when Mac dictation may not send it audio at all (no audio is sent).
    static func route(_ capabilities: [String: Any]?) -> String? {
        guard let capabilities, capabilities["desktopDictationVersion"] as? Int == 1,
              capabilities["localOnly"] as? Bool == true else { return nil }
        return local(capabilities) ? localRoute : parakeetRoute
    }

    struct Answer { var ok: Bool; var message: String; var details: [String: Any] }

    static func id(_ value: Any?, _ allowed: Set<String>) -> String? { (value as? String).flatMap { allowed.contains($0) ? $0 : nil } }

    /// A server sentence fit for the card: one line, at most 200 characters, never empty.
    static func sentence(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= 200, !text.contains("\n") else { return nil }
        return text
    }

    /// COS's own words for a local-route refusal, when the server sent none it can show.
    static func refusalLine(reason: String?, action: String, detail: String?) -> String {
        switch (reason, action) {
        case ("parakeet_unavailable", "install_parakeet"): return "Parakeet Ultra is not installed on this Mac."
        case ("parakeet_unavailable", "retry"): return "Parakeet Ultra is warming up. Try again in a few seconds."
        case ("parakeet_unavailable", _): return "Parakeet Ultra cannot run right now. Whisper can take this dictation."
        case (_, "retry"): return detail == "whisper_starting" ? "Whisper is still starting. Try again in a few seconds." : "The speech engine is getting ready. Try again in a few seconds."
        case (_, "install_parakeet"): return "No speech engine is ready on this Mac. Parakeet Ultra can be installed now."
        default: return "No speech engine is set up on this Mac. Set one up in Transcription settings."
        }
    }

    /// What one transcribe answer means. `status` nil: the server did not answer.
    static func answer(status: Int?, body: [String: Any]?, local: Bool) -> Answer {
        guard let status else {
            return Answer(ok: false, message: "The local transcription server is unavailable. Try again when it is ready.",
                          details: ["action": "retry", "retryable": true])
        }
        // noSpeech: the server heard nothing it could transcribe; COS Control offers no Retry of the same audio.
        if status == 204 { return Answer(ok: false, message: "No speech detected. Check your selected microphone and try again.", details: ["noSpeech": true, "action": "none"]) }
        if status == 200, let body, let text = body["text"] as? String, !text.isEmpty, text.utf8.count <= 64_000 {
            if local, let engine = id(body["engine"], engines) {
                var details: [String: Any] = ["text": text, "engine": engine]
                if let reason = id(body["fallbackReason"], fallbackReasons) { details["fallbackReason"] = reason }
                if let setting = id(body["dictationSetting"], settings) { details["dictationSetting"] = setting }
                return Answer(ok: true, message: "Dictation ready", details: details)
            }
            if !local, body["engine"] as? String == "parakeet-ultra" {
                return Answer(ok: true, message: "Dictation ready", details: ["text": text, "engine": "parakeet-ultra"])
            }
        }
        guard local else {
            // 0.5.316's words and its Retry, unchanged, for a server without the local route.
            let message = status == 503 ? "Parakeet is not ready. Check Transcription settings and retry." : "Dictation needs the matched server with Parakeet support. No text was inserted."
            return Answer(ok: false, message: message, details: ["httpStatus": status, "action": "retry", "retryable": true])
        }
        if status == 503, let body, let reason = id(body["reason"], reasons) {
            let raw = body["action"] as? String
            let asked = raw == "retry_when_warm" ? "retry" : id(raw, actions) ?? "open_transcription_settings"
            // Retry only when the server says it can succeed (contract: retryable is true only then). A retry it
            // says cannot succeed becomes the settings, where the cause can be fixed.
            let retryable = asked == "retry" && (body["retryable"] as? Bool) == true
            let action = asked == "retry" && !retryable ? "open_transcription_settings" : asked
            let detail = (body["detail"] as? String).flatMap { VoiceAccuracy.isIdentifier($0) ? $0 : nil }
            var details: [String: Any] = ["httpStatus": 503, "reason": reason, "action": action, "retryable": retryable]
            if let detail { details["detail"] = detail }
            return Answer(ok: false, message: sentence(body["error"]) ?? refusalLine(reason: reason, action: action, detail: detail), details: details)
        }
        if status == 200 {
            return Answer(ok: false, message: "The server answered without text COS can use. No text was inserted.", details: ["httpStatus": 200, "action": "retry", "retryable": true])
        }
        // A maintenance hold (409/503 with Retry-After) or a busy server can pass; a 4xx is this request's own fault.
        let passing = status == 409 || status == 503 || status == 429 || status >= 500
        return Answer(ok: false, message: passing ? "The transcription server is busy. Try again in a moment." : "The server could not transcribe this dictation (HTTP \(status)). No text was inserted.",
                      details: ["httpStatus": status, "action": passing ? "retry" : "open_transcription_settings", "retryable": passing])
    }
}

// MARK: - AI polish for Mac dictation (0.5.325)
//
// The pure half of the helper's `dictation-polish`. Control sends {text, model, app?} on stdin (never argv: dictated
// text is private); the helper posts it to the server's POST /api/dictation/finalize, the glasses' dictation polish,
// and answers {text, polished, model, elapsedMs}. Every failure (no token, no server, an HTTP error, a bad answer, the
// deadline) is ok:false with a short reason and NO text, so Control pastes what it heard. Nothing here logs or keeps
// the text. The server ignores extra fields today; `context.app` is for a later server that uses it.
enum DictationPolishBridge {
    static let route = "/api/dictation/finalize"
    /// stdin: 8,000 characters at up to 4 UTF-8 bytes each, plus the JSON around them.
    static let inputLimit = 40_000
    /// The server answers 413 above this (UTF-16 units, a JavaScript string length).
    static let maximumCharacters = 8_000
    static let answerLimit = 16_000
    static let models: Set<String> = ["haiku", "sonnet"]

    /// The request's deadline: Control's whole wait (DictationPolish.budget: 5 s Haiku, 9 s Sonnet) less half a second
    /// for the helper to start and answer, so a slow model ends as this helper's timeout, not a killed process.
    static func requestSeconds(_ model: String) -> TimeInterval? {
        switch model {
        case "haiku": 4.5
        case "sonnet": 8.5
        default: nil
        }
    }

    struct Request: Equatable { let text: String; let model: String; let app: String? }

    /// Only text, model and app. Text: not blank, at most 8,000 UTF-16 units. Model: haiku or sonnet. App: one line, at
    /// most 64 characters, or left out (an unusable app name is dropped, never a reason to refuse the polish).
    static func parse(_ data: Data) -> Request? {
        guard data.count <= inputLimit, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: ["text", "model", "app"]),
              let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= maximumCharacters,
              let model = object["model"] as? String, models.contains(model) else { return nil }
        let app = (object["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = app.flatMap { !$0.isEmpty && $0.count <= 64 && !$0.contains(where: \.isNewline) ? $0 : nil }
        return Request(text: text, model: model, app: usable)
    }

    /// The finalize body: the text, the message surface (a dictation is typed into a message box), the model.
    static func body(_ request: Request) -> String {
        var object: [String: Any] = ["text": request.text, "surface": "message", "autocleanModel": request.model]
        if let app = request.app { object["context"] = ["app": app] }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// What one finalize answer means. `status` nil: no answer (`timedOut` says whether the deadline passed).
    static func answer(status: Int?, body: [String: Any]?, model: String, elapsedMs: Int, timedOut: Bool) -> DictationBridge.Answer {
        let base: [String: Any] = ["model": model, "elapsedMs": elapsedMs]
        func refused(_ reason: String, _ message: String, status: Int? = nil) -> DictationBridge.Answer {
            var details = base.merging(["reason": reason]) { a, _ in a }
            if let status { details["httpStatus"] = status }
            return DictationBridge.Answer(ok: false, message: message, details: details)
        }
        guard let status else {
            return timedOut ? refused("timeout", "AI polish took too long. COS pastes what it heard.")
                : refused("unreachable", "The COS server did not answer. COS pastes what it heard.")
        }
        switch status {
        case 200:
            guard let body, let text = body["text"] as? String, !text.isEmpty, text.utf16.count <= answerLimit,
                  let flag = body["polished"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                return refused("bad_answer", "The server's polish answer was not readable. COS pastes what it heard.", status: 200)
            }
            // A JSON boolean only: 1 or "true" is not the server saying Claude polished it.
            let polished = flag.boolValue
            return DictationBridge.Answer(ok: true, message: polished ? "Polished" : "Not polished",
                                          details: base.merging(["text": text, "polished": polished]) { a, _ in a })
        case 404: return refused("needs_server_update", "This COS server has no dictation polish. COS pastes what it heard.", status: 404)
        case 413: return refused("too_long", "Too long for AI polish. COS pastes what it heard.", status: 413)
        case 401, 403: return refused("unauthorized", "The COS server refused the token. COS pastes what it heard.", status: status)
        case 429: return refused("busy", "AI polish is busy. COS pastes what it heard.", status: 429)
        default: return refused("http_\(status)", "AI polish did not finish (HTTP \(status)). COS pastes what it heard.", status: status)
        }
    }
}

/// Word error rate on the pinned 30 s sample, against Resources/VoiceBenchmark/speech-30s.txt. Lowercase, punctuation
/// stripped, words split on anything else. (substitutions + deletions + insertions) / reference words. One clip is a
/// sanity check of a speech engine on this Mac, never an accuracy benchmark.
/// 0.5.318 (Queen's Mac and Miles's, 2026-10-17): the Voice row's dictation check sends ONE copy of the sample's 11 s
/// utterance. The 30 s sample repeats it (two copies of jfk.wav plus 8 s, VoiceBenchmark/SOURCE.md), and the server's
/// dictation path drops repeated text as a Whisper loop (NoSpeechDetectedError, HTTP 204: "DROPPED (hallucination or
/// empty): 288 chars"), so every check read "No speech detected. Check your selected microphone" while the engine test,
/// whose benchmark route has no such filter, passed. The benchmark keeps the full 30 s.
enum DictationCheckSample {
    static let seconds = 11
    /// The reference's first copy: "and so my fellow americans ... for your country".
    static let referenceWords = 22
    private static let rate = 16_000

    /// The first `seconds` of the pinned 16 kHz mono 16-bit PCM WAV (canonical 44-byte header), its sizes rewritten.
    /// Any other layout is nil, so a changed sample fails closed instead of sending something unplanned.
    static func singleUtterance(_ wav: Data) -> Data? {
        let b = [UInt8](wav)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard b.count > 44, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WAVE".utf8),
              Array(b[12..<16]) == Array("fmt ".utf8), u32(16) == 16, u16(20) == 1, u16(22) == 1, u32(24) == rate,
              u16(34) == 16, Array(b[36..<40]) == Array("data".utf8) else { return nil }
        let take = seconds * rate * 2
        guard u32(40) >= take, b.count >= 44 + take else { return nil }
        var out = Array(b[0..<(44 + take)])
        func put(_ value: Int, at i: Int) { for k in 0..<4 { out[i + k] = UInt8((value >> (8 * k)) & 0xff) } }
        put(36 + take, at: 4); put(take, at: 40)
        return Data(out)
    }

    /// The words the single utterance says, from the pinned reference.
    static func reference(_ full: String) -> String {
        VoiceAccuracy.words(full).prefix(referenceWords).joined(separator: " ")
    }
}

enum VoiceAccuracy {
    static let referenceFile = "VoiceBenchmark/speech-30s.txt"
    static let referenceSHA256 = "a3726daf65f3b1f41a1e8e3bf9fa6abe0f4022e873589738d8c0339965a782ec"
    static let referenceWords = 58

    static func words(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var out: [String] = [], current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" { current.unicodeScalars.append(scalar) }
            else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        // A quote mark at a word's edge is punctuation ("'tis" keeps its own, "you'" does not).
        return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }

    /// Word-level edit distance.
    static func errors(reference: [String], hypothesis: [String]) -> Int {
        guard !reference.isEmpty else { return hypothesis.count }
        guard !hypothesis.isEmpty else { return reference.count }
        var previous = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, heard) in hypothesis.enumerated() {
                row[j + 1] = min(previous[j + 1] + 1, row[j] + 1, previous[j] + (word == heard ? 0 : 1))
            }
            previous = row
        }
        return previous[hypothesis.count]
    }

    /// nil when there is no reference to score against.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        let ref = words(reference)
        guard !ref.isEmpty else { return nil }
        return Double(errors(reference: ref, hypothesis: words(hypothesis))) / Double(ref.count)
    }

    static func isIdentifier(_ text: String) -> Bool {
        (1...48).contains(text.count) && text.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-" }
    }
}

/// POST /api/transcribe/benchmark (server 6.74.0): each engine's result, whitelisted, with its word error rate against
/// the pinned reference. The server applies the COS dictionary on both engines and collapses the text to one line (no
/// hallucination filter), so both sides are lowercased and stripped of punctuation before scoring (VoiceAccuracy.words).
enum DictationBenchmark {
    static let route = "/api/transcribe/benchmark?engines=whisper,parakeet-ultra"
    static let skips: Set<String> = ["not_installed", "unavailable", "timeout"]

    static func results(_ body: [String: Any]?, reference: String) -> [[String: Any]]? {
        guard let rows = body?["results"] as? [Any] else { return nil }
        return rows.prefix(4).compactMap { raw -> [String: Any]? in
            guard let row = raw as? [String: Any], let engine = DictationBridge.id(row["engine"], DictationBridge.engines) else { return nil }
            func number(_ key: String) -> Any {
                guard let value = row[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0 else { return NSNull() }
                return value
            }
            let ran = row["ran"] as? Bool == true
            var out: [String: Any] = ["engine": engine, "ran": ran, "elapsedMs": number("elapsedMs"), "rtf": number("rtf"),
                                      "peakRssBytes": number("peakRssBytes"), "warmupMs": number("warmupMs"),
                                      "model": (row["model"] as? String).flatMap { (1...48).contains($0.count) && $0.allSatisfy { $0.isASCII && !$0.isNewline } ? $0 : nil } ?? NSNull(),
                                      "skipped": DictationBridge.id(row["skipped"], skips) ?? NSNull(), "wer": NSNull(), "words": NSNull()]
            if ran, let text = row["text"] as? String, text.utf8.count <= 64_000, let wer = VoiceAccuracy.wordErrorRate(reference: reference, hypothesis: text) {
                out["wer"] = wer
                out["words"] = VoiceAccuracy.words(reference).count
            }
            if !ran, out["skipped"] is NSNull { out["skipped"] = "unavailable" }
            return out
        }
    }
}

/// The bundled FluidAudio command line tool COS Control passes to the server (Contents/Helpers/fluidaudiocli). The
/// server proves it (codesign, team, the embedded Info.plist's version); this only refuses a path that is not one.
enum ParakeetCLIPath {
    static let suffix = "/Contents/Helpers/fluidaudiocli"
    static func valid(_ path: String, isExecutable: (String) -> Bool) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(suffix), path.utf8.count <= 1024, !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return false }
        return isExecutable(path)
    }
}

// ── Key lanes (K1, plan v4 10.1, 12; P10) ────────────────────────────────────────────────────────────────────────────
// `cos-control-helper key-lanes <action>` talks to the server's /api/key-lanes/* over loopback with the token
// (HelperSources/main.swift does the I/O). This part is pure and is what Tests/KeyLanesHelperChecks.swift drives: the
// grammar (which action is which route), the stdin bodies, and the whitelist of what crosses back to the app. A pasted
// key only ever arrives on stdin, never in argv or the environment (so `ps` never shows it), and nothing this returns
// carries it: the server never sends a secret, and the answer is dropped whole if one ever appeared in it.
enum KeyLanesHelperCore {
    static let usage = "key-lanes takes status, enable, disable, save-key, set-cap --ref R --cap USD, remove-key --ref R [--force], remove-all [--export-ledger], catalog, save-profile, delete-profile --id ID"
    /// The P1 grammars (server/lib/key-relay-contract.ts KEY_REF_RE, shared/key-preference.ts KEY_PROFILE_ID_RE).
    static let refPattern = "\\Akey_[0-9a-f]{12}\\z"
    static let profilePattern = "\\A[a-z0-9][a-z0-9-]{0,31}\\z"
    /// P3 keyed-sessions.ts SESSION_ID_RE and MAX_KEYED_SESSIONS.
    static let sessionPattern = "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z"
    static let maxKeyedSessions = 20_000
    static let kinds = ["openrouter", "anthropic", "openai", "openai-compatible"]
    static let engines = ["claude", "codex", "direct"]
    static let tiers = ["opus", "fable", "sonnet", "haiku"]
    static let stdinLimit = 4_096

    enum Stdin: Equatable { case none, key, profile }

    struct Plan: Equatable {
        let action: String
        let method: String
        let path: String
        /// Fixed body (sorted-keys JSON is written by the caller), or nil.
        let body: [String: String]?
        let stdin: Stdin
        let timeout: Int
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func option(_ name: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// `args` is what follows `key-lanes`. nil for anything outside the grammar, including any extra argument: an
    /// action that takes stdin takes NOTHING else, so a key put in argv is refused before any request.
    static func plan(_ args: [String]) -> Plan? {
        guard let action = args.first else { return nil }
        let rest = Array(args.dropFirst())
        func p(_ method: String, _ path: String, _ body: [String: String]? = nil, _ stdin: Stdin = .none, _ timeout: Int = 10) -> Plan {
            Plan(action: action, method: method, path: "/api/key-lanes" + path, body: body, stdin: stdin, timeout: timeout)
        }
        switch action {
        case "status": return rest.isEmpty ? p("GET", "/status") : nil
        case "enable": return rest.isEmpty ? p("POST", "/enable", [:]) : nil
        case "disable": return rest.isEmpty ? p("POST", "/disable", [:]) : nil
        case "catalog": return rest.isEmpty ? p("GET", "/catalog", nil, .none, 15) : nil
        // The server checks a new key with its provider (10 s), so the wait is longer than that.
        case "save-key": return rest.isEmpty ? p("POST", "/keys", nil, .key, 25) : nil
        case "save-profile": return rest.isEmpty ? p("POST", "/profiles", nil, .profile) : nil
        case "set-cap":
            guard rest.count == 4, let ref = option("--ref", rest), matches(ref, refPattern),
                  let cap = option("--cap", rest), let usd = capValue(cap) else { return nil }
            return p("POST", "/keys", ["ref": ref, "capUsd": String(format: "%.2f", usd)])
        case "remove-key":
            guard rest.count == 2 || (rest.count == 3 && rest.last == "--force"),
                  let ref = option("--ref", rest), matches(ref, refPattern) else { return nil }
            return p("DELETE", "/keys/" + ref + (rest.count == 3 ? "?force=1" : ""))
        case "remove-all":
            guard rest.isEmpty || rest == ["--export-ledger"] else { return nil }
            return p("POST", "/remove-all", ["exportLedger": rest.isEmpty ? "false" : "true"], .none, 20)
        case "delete-profile":
            guard rest.count == 2, let id = option("--id", rest), matches(id, profilePattern) else { return nil }
            return p("DELETE", "/profiles/" + id)
        default: return nil
        }
    }

    /// A cap in dollars, cents only, within the server's $0.01 to $1000.
    static func capValue(_ text: String) -> Double? {
        guard matches(text, "\\A[0-9]{1,4}(\\.[0-9]{1,2})?\\z"), let value = Double(text), value >= 0.01, value <= 1000 else { return nil }
        return value
    }

    /// The JSON the helper sends for a fixed body: numbers and booleans as JSON, not strings.
    static func fixedBody(_ body: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in body {
            if key == "capUsd", let number = Double(value) { out[key] = number }
            else if value == "true" || value == "false" { out[key] = value == "true" }
            else { out[key] = value }
        }
        return out
    }

    /// The body from stdin and, for a key, the secret (so the answer can be checked for it). nil when the stdin is not
    /// the one shape this action takes. Never echoes what it refused.
    static func stdinBody(_ kind: Stdin, _ data: Data) -> (body: [String: Any], secret: String?)? {
        guard data.count <= stdinLimit, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch kind {
        case .none: return nil
        case .key:
            guard Set(object.keys).isSubset(of: ["kind", "key", "capUsd", "baseUrl"]),
                  let kindName = object["kind"] as? String, kinds.contains(kindName),
                  let secret = object["key"] as? String, !secret.isEmpty, secret.utf8.count <= 512,
                  secret.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }) else { return nil }
            var body: [String: Any] = ["kind": kindName, "key": secret]
            if let raw = object["capUsd"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                let usd = number.doubleValue
                guard usd >= 0.01, usd <= 1000 else { return nil }
                body["capUsd"] = (usd * 100).rounded() / 100
            }
            if let url = object["baseUrl"] {
                guard kindName == "openai-compatible", let text = url as? String, text.utf8.count <= 300,
                      text.hasPrefix("https://") || text.hasPrefix("http://") else { return nil }
                body["baseUrl"] = text
            } else if kindName == "openai-compatible" { return nil }
            return (body, secret)
        case .profile:
            guard Set(object.keys).isSubset(of: ["id", "label", "keyRef", "engine", "model", "enabled", "timeoutTier"]),
                  let id = object["id"] as? String, matches(id, profilePattern),
                  let label = object["label"] as? String, !label.isEmpty, label.count <= 40,
                  let ref = object["keyRef"] as? String, matches(ref, refPattern),
                  let engine = object["engine"] as? String, engines.contains(engine),
                  let model = object["model"] as? String, matches(model, "\\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}\\z"),
                  let tier = object["timeoutTier"] as? String, tiers.contains(tier) else { return nil }
            var body: [String: Any] = ["id": id, "label": label, "keyRef": ref, "engine": engine, "model": model, "timeoutTier": tier]
            if let enabled = object["enabled"] {
                guard let flag = enabled as? Bool else { return nil }
                body["enabled"] = flag
            }
            return (body, nil)
        }
    }

    /// `answered`, or `unsupported` for a 404 that is not JSON (lanes off on this server, or a server from before them:
    /// both are today's Express 404 page).
    static func transport(status: Int, body: [String: Any]?) -> String {
        status == 404 && body == nil ? "unsupported" : "answered"
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private static func text(_ value: Any?, max: Int, pattern: String? = nil) -> String? {
        guard let s = value as? String, !s.isEmpty, s.count <= max else { return nil }
        if let pattern, !matches(s, pattern) { return nil }
        return s
    }

    /// A public key record: ref, kind, last 4, cap, and the day's spend and breaker on a status row. Nothing else.
    static func keyRecord(_ raw: Any?) -> [String: Any]? {
        guard let o = raw as? [String: Any], let ref = text(o["ref"], max: 16, pattern: refPattern),
              let kind = o["kind"] as? String, kinds.contains(kind),
              let last4 = o["last4"] as? String, last4.count == 4, let cap = number(o["capUsd"]) else { return nil }
        var out: [String: Any] = ["ref": ref, "kind": kind, "last4": last4, "capUsd": cap]
        if let spent = number(o["spentTodayUsd"]) { out["spentTodayUsd"] = spent }
        if let b = o["breaker"] as? [String: Any] {
            var breaker: [String: Any] = ["open": bool(b["open"]) ?? false, "failures": Int(number(b["failures"]) ?? 0)]
            if let at = text(b["reopensAt"], max: 40, pattern: "\\A[0-9TZ:.+-]+\\z") { breaker["reopensAt"] = at }
            out["breaker"] = breaker
        }
        return out
    }

    static func profileRecord(_ raw: Any?) -> [String: Any]? {
        guard let o = raw as? [String: Any], let id = text(o["id"], max: 32, pattern: profilePattern),
              let label = text(o["label"], max: 40), let ref = text(o["keyRef"], max: 16, pattern: refPattern),
              let engine = o["engine"] as? String, engines.contains(engine),
              let model = text(o["model"], max: 128), let enabled = bool(o["enabled"]) else { return nil }
        var out: [String: Any] = ["id": id, "label": label, "keyRef": ref, "engine": engine, "model": model, "enabled": enabled]
        if let tier = o["timeoutTier"] as? String, tiers.contains(tier) { out["timeoutTier"] = tier }
        return out
    }

    /// What crosses to the app for one action. Every answer is `ok` with `transport` and `httpStatus`; a refusal's
    /// `error` code and the server's `message` cross so the app can show the server's own words.
    static func answer(_ action: String, status: Int, body: [String: Any]?, secret: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["transport": transport(status: status, body: body), "httpStatus": status]
        guard let body else { return out }
        if let code = text(body["error"], max: 64, pattern: "\\A[a-z_]+\\z") { out["error"] = code }
        if let message = text(body["message"], max: 300) { out["message"] = message }
        if status == 409, let ids = body["profiles"] as? [Any] {
            out["profiles"] = ids.compactMap { text($0, max: 32, pattern: profilePattern) }
        }
        guard (200..<300).contains(status) else { return guarded(out, secret) }
        for key in ["enabled", "active", "removed"] { if let flag = bool(body[key]) { out[key] = flag } }
        switch action {
        case "status":
            out["keys"] = (body["keys"] as? [Any] ?? []).prefix(64).compactMap(keyRecord)
            out["profiles"] = (body["profiles"] as? [Any] ?? []).prefix(64).compactMap(profileRecord)
            out["keyedSessionIds"] = (body["keyedSessionIds"] as? [Any] ?? []).prefix(maxKeyedSessions)
                .compactMap { text($0, max: 128, pattern: sessionPattern) }
        case "disable":
            // The env switch that keeps lanes on (P1 says which; only an env name crosses).
            if let by = text(body["forcedOnBy"], max: 40, pattern: "\\A[A-Z][A-Z0-9_]*\\z") { out["forcedOnBy"] = by }
        case "save-key", "set-cap":
            if let key = keyRecord(body["key"]) { out["key"] = key }
            if let credit = body["credit"] as? [String: Any] {
                var c: [String: Any] = [:]
                if let remaining = number(credit["remainingUsd"]) { c["remainingUsd"] = remaining }
                if let free = bool(credit["freeTier"]) { c["freeTier"] = free }
                out["credit"] = c
            }
        case "remove-key":
            out["disabledProfiles"] = (body["disabledProfiles"] as? [Any] ?? []).compactMap { text($0, max: 32, pattern: profilePattern) }
        case "remove-all":
            if let removed = body["removed"] as? [Any] {
                out["removed"] = removed.compactMap { ($0 as? String).flatMap { ["keys", "profiles", "codexHomes", "ledger"].contains($0) ? $0 : nil } }
            }
            if let path = text(body["ledgerExportedTo"], max: 1024), path.hasPrefix("/") { out["ledgerExportedTo"] = path }
        case "catalog":
            out["curated"] = (body["curated"] as? [Any] ?? []).prefix(8).compactMap { raw -> [String: Any]? in
                guard let o = raw as? [String: Any], let id = text(o["id"], max: 128, pattern: "\\A[a-z0-9][a-z0-9._/-]{0,127}\\z"),
                      let name = text(o["name"], max: 80), let inPer = number(o["inUsdPerM"]), let outPer = number(o["outUsdPerM"]) else { return nil }
                var m: [String: Any] = ["id": id, "name": name, "inUsdPerM": inPer, "outUsdPerM": outPer]
                if let role = o["role"] as? String, ["default", "cheaper"].contains(role) { m["role"] = role }
                return m
            }
            if let from = body["pricesFrom"] as? String, ["openrouter", "built-in"].contains(from) { out["pricesFrom"] = from }
        case "save-profile":
            if let profile = profileRecord(body["profile"]) { out["profile"] = profile }
        default: break
        }
        return guarded(out, secret)
    }

    /// Belt and braces: an answer that somehow contains the pasted key is replaced by a refusal that does not.
    static func guarded(_ out: [String: Any], _ secret: String?) -> [String: Any] {
        guard let secret, secret.count >= 8,
              let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]),
              String(decoding: data, as: UTF8.self).contains(secret) else { return out }
        return ["transport": out["transport"] ?? "answered", "httpStatus": out["httpStatus"] ?? 0, "error": "redacted",
                "message": "COS dropped an answer that repeated the key."]
    }
}
