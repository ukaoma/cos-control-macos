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

/// Word error rate on the pinned 30 s sample, against Resources/VoiceBenchmark/speech-30s.txt. Lowercase, punctuation
/// stripped, words split on anything else. (substitutions + deletions + insertions) / reference words. One clip is a
/// sanity check of a speech engine on this Mac, never an accuracy benchmark.
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
