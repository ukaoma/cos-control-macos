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
nonisolated(unsafe) var voiceSetupCancelled: sig_atomic_t = 0
