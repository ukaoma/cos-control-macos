import Foundation
import Combine

// Connect your AI (onboarding P1, Miles 2026-10-07 and 2026-10-08). The Welcome step and the panel card that show,
// per AI, whether its command line is installed and signed in, open Terminal on the exact login command, and can hand
// the setup to an AI app ("Pass to Claude / ChatGPT / Cursor"). Status comes only from `cos-control-helper
// provider-status` (HelperSources/ProviderStatusCore.swift); an AI's own "COS-SETUP" line is display only.
//
// Imports Foundation and Combine only, so Tests/ProviderConnectChecks.swift compiles it alone. Every effect (the
// helper, Terminal, opening a link, the clipboard, a folder) is injected: no check opens an app or a link.

// MARK: - Providers

enum AIProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case claude, codex, cursor, ollama
    var id: String { rawValue }

    /// The name people know the subscription by.
    var title: String {
        switch self { case .claude: "Claude"; case .codex: "ChatGPT"; case .cursor: "Cursor"; case .ollama: "Ollama" }
    }
    /// The command line COS runs.
    var cliName: String {
        switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .cursor: "Cursor Agent"; case .ollama: "Ollama" }
    }
    var usage: String {
        switch self {
        case .claude: "Uses your Claude plan. Usage counts toward that subscription."
        case .codex: "Uses your ChatGPT plan through Codex. Usage counts toward that subscription."
        case .cursor: "Uses your Cursor plan. Usage counts toward that subscription."
        case .ollama: "Optional, local. Runs on this Mac with no account."
        }
    }
    /// The app whose chat can run commands, by the URL scheme it registers (LaunchServices, read 2026-10-08:
    /// claude:// is Claude.app, codex:// is ChatGPT.app com.openai.codex, cursor:// is Cursor). Ollama has none.
    var appScheme: String? {
        switch self { case .claude: "claude"; case .codex: "codex"; case .cursor: "cursor"; case .ollama: nil }
    }
    var appName: String {
        switch self { case .claude: "Claude"; case .codex: "ChatGPT"; case .cursor: "Cursor"; case .ollama: "Ollama" }
    }
    /// Where to get it when it is missing. Official pages only.
    var downloadURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.com/download")!
        case .codex: URL(string: "https://openai.com/chatgpt/download/")!
        case .cursor: URL(string: "https://cursor.com/download")!
        case .ollama: URL(string: "https://ollama.com/download")!
        }
    }
    /// The official user-local installer, a constant. Codex has none: it ships inside the ChatGPT app. Never sudo,
    /// Homebrew or a global npm install.
    var installCommand: String? {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .cursor: "curl https://cursor.com/install -fsS | bash"
        case .codex, .ollama: nil
        }
    }
    /// The login, as the person runs it in Terminal.
    var loginCommand: String? {
        switch self { case .claude: "claude"; case .codex: "codex login"; case .cursor: "agent login"; case .ollama: nil }
    }
    /// What happens after the command, in one line.
    var loginHint: String {
        switch self {
        case .claude: "Claude Code opens. Type /login, then sign in with your Claude account in the browser."
        case .codex: "Your browser opens. Sign in with ChatGPT."
        case .cursor: "Your browser opens. Sign in to Cursor."
        case .ollama: "No sign-in."
        }
    }
    /// The three CLIs COS can route sessions to. Ollama is optional and never satisfies Get started in P1.
    static let agents: [AIProvider] = [.claude, .codex, .cursor]
}

// MARK: - What the helper reports

struct ProviderCandidateInfo: Decodable, Equatable, Sendable {
    var path: String
    var source: String
    var executable: Bool
    var chosen: Bool
    var note: String?
}

struct ProviderLocalStatus: Decodable, Equatable, Sendable {
    var provider: String
    var installed: Bool
    var binaryPath: String?
    var version: String?
    /// signedIn | signInRequired | unknown | apiKey | notNeeded
    var signIn: String
    var candidates: [ProviderCandidateInfo]
    var detail: String?
    var daemon: String?
    var models: [String]?
    var host: String?

    var kind: AIProvider? { AIProvider(rawValue: provider) }
    var signedIn: Bool { signIn == "signedIn" || signIn == "apiKey" }
    /// Claude Desktop's own copy was found and nothing COS can run.
    var desktopOnly: Bool { !installed && candidates.contains { $0.source == "claudeDesktop" && $0.executable } }
}

struct ProviderStatusReport: Decodable, Equatable, Sendable {
    var providers: [ProviderLocalStatus]
    var checkedAt: String?

    static func decode(_ data: Data) -> ProviderStatusReport? {
        try? JSONDecoder().decode(ProviderStatusReport.self, from: data)
    }
    func status(_ provider: AIProvider) -> ProviderLocalStatus? { providers.first { $0.provider == provider.rawValue } }
    /// Overlays a partial report (`--only`) on this one.
    func merging(_ partial: ProviderStatusReport) -> ProviderStatusReport {
        var next = self
        for row in partial.providers {
            if let index = next.providers.firstIndex(where: { $0.provider == row.provider }) { next.providers[index] = row }
            else { next.providers.append(row) }
        }
        next.checkedAt = partial.checkedAt ?? checkedAt
        return next
    }
}

// MARK: - Rows

enum ProviderTone: Sendable, Equatable { case good, needsYou, neutral, optional }

enum ProviderPrimaryAction: Sendable, Equatable { case none, install, signIn }

struct ProviderRowModel: Identifiable, Sendable, Equatable {
    var provider: AIProvider
    var status: String
    var detail: String?
    var tone: ProviderTone
    var action: ProviderPrimaryAction
    /// "Skip for now" shows for an installed CLI that still needs signing in.
    var canSkip: Bool
    var waiting: Bool
    var id: String { provider.rawValue }
}

enum ProviderRules {
    /// The row a status draws. `nil` status = still checking.
    static func row(_ provider: AIProvider, _ status: ProviderLocalStatus?, skipped: Bool, waiting: Bool) -> ProviderRowModel {
        guard let status else {
            return ProviderRowModel(provider: provider, status: "Checking…", detail: nil, tone: .neutral, action: .none,
                                    canSkip: false, waiting: false)
        }
        if provider == .ollama {
            if status.daemon == "running" {
                let count = status.models?.count ?? 0
                let models = count == 0 ? "Running, no models yet" : count == 1 ? "Running, 1 model" : "Running, \(count) models"
                return ProviderRowModel(provider: provider, status: models, detail: provider.usage, tone: .optional,
                                        action: .none, canSkip: false, waiting: false)
            }
            return ProviderRowModel(provider: provider, status: status.installed ? "Installed, not running" : "Not installed",
                                    detail: status.installed ? "Open the Ollama app to start it." : provider.usage,
                                    tone: .optional, action: status.installed ? .none : .install, canSkip: false, waiting: false)
        }
        guard status.installed else {
            let detail = waiting
                ? "Follow the steps in the AI app you passed this to. This row updates when \(provider.cliName) is installed and signed in."
                : status.desktopOnly
                ? "Claude Desktop has its own copy of Claude Code. COS needs the Claude Code command line too."
                : nil
            return ProviderRowModel(provider: provider, status: waiting ? "Waiting for setup…" : "Not installed", detail: detail,
                                    tone: .neutral, action: .install, canSkip: false, waiting: waiting)
        }
        let version = status.version.map { " \($0)" } ?? ""
        switch status.signIn {
        case "signedIn":
            return ProviderRowModel(provider: provider, status: "Signed in", detail: "\(provider.cliName)\(version)",
                                    tone: .good, action: .none, canSkip: false, waiting: false)
        case "apiKey":
            return ProviderRowModel(provider: provider, status: "API key", detail: "Signed in with an API key, billed separately from a subscription.",
                                    tone: .good, action: .none, canSkip: false, waiting: false)
        case "signInRequired":
            if skipped && !waiting {
                return ProviderRowModel(provider: provider, status: "Skipped for now", detail: "Installed, not signed in.",
                                        tone: .neutral, action: .signIn, canSkip: false, waiting: false)
            }
            return ProviderRowModel(provider: provider, status: waiting ? "Waiting for sign-in…" : "Installed, not signed in",
                                    detail: waiting ? provider.loginHint : "\(provider.cliName)\(version)",
                                    tone: .needsYou, action: .signIn, canSkip: !waiting, waiting: waiting)
        default:
            // The CLI answered something this build cannot read. Installed is what matters; never a failure.
            return ProviderRowModel(provider: provider, status: "Installed", detail: "\(provider.cliName)\(version). Sign-in could not be checked.",
                                    tone: .good, action: .none, canSkip: false, waiting: false)
        }
    }

    /// The panel line: "All signed in", "1 needs you", "None installed".
    static func summary(_ report: ProviderStatusReport?, skipped: Set<AIProvider>) -> String {
        guard let report else { return "Checking…" }
        let installed = AIProvider.agents.compactMap { report.status($0) }.filter(\.installed)
        if installed.isEmpty { return "None installed" }
        let need = needCount(report, skipped: skipped)
        if need == 0 { return installed.count == 1 ? "1 connected" : "\(installed.count) connected" }
        return need == 1 ? "1 needs you" : "\(need) need you"
    }

    /// Installed agent CLIs that still need signing in and were not skipped.
    static func needCount(_ report: ProviderStatusReport, skipped: Set<AIProvider>) -> Int {
        AIProvider.agents.filter { provider in
            guard let status = report.status(provider) else { return false }
            return status.installed && status.signIn == "signInRequired" && !skipped.contains(provider)
        }.count
    }
}

// MARK: - The Get started gate

enum ProviderGate {
    /// The HARD gate is unchanged from 0.5.267: an AI command line is installed (`setupProviderInstalled`, computed by
    /// the helper, which also refuses `setup` without one). Sign-in never disables Get started.
    static func getStartedEnabled(setupProviderInstalled: Bool, busy: Bool) -> Bool { setupProviderInstalled && !busy }

    /// The sign-in step reads as done when every installed agent CLI is signed in or skipped. Until then Get started
    /// stays enabled but secondary, under "Sign in to each AI you installed, or choose Skip for now".
    static func signInStepDone(_ report: ProviderStatusReport?, skipped: Set<AIProvider>) -> Bool {
        guard let report else { return true }
        return ProviderRules.needCount(report, skipped: skipped) == 0
    }
}

// MARK: - Sign in (Terminal)

enum ProviderLogin {
    /// Directories a fresh Terminal finds on PATH without help. Anywhere else, the command names the binary by path
    /// (a ChatGPT-only Mac has `codex` only inside the app).
    static let shellPathDirectories: Set<String> = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The exact command Sign in runs, with the binary the helper found. nil for Ollama.
    static func command(_ provider: AIProvider, binaryPath: String?) -> String? {
        guard let login = provider.loginCommand else { return nil }
        guard let binaryPath, binaryPath.hasPrefix("/") else { return login }
        let directory = (binaryPath as NSString).deletingLastPathComponent
        if shellPathDirectories.contains(directory) { return login }
        let parts = login.split(separator: " ", maxSplits: 1).map(String.init)
        return ([shellQuote(binaryPath)] + parts.dropFirst()).joined(separator: " ")
    }

    /// AppleScript that opens a new Terminal window running `command` and brings Terminal forward. The command is
    /// escaped for an AppleScript string; it was already shell-quoted.
    static func terminalScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
    }
}

// MARK: - Pass to an AI app

enum ProviderPass {
    /// Strict query encoding: RFC 3986 unreserved ASCII only. Byte-for-byte the same set as
    /// WorkHandoffStore.linkQueryAllowed (Tests/provider-connect-pins.py compares the two).
    static let linkQueryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let promptLimit = 4_000

    /// A tag is the only value ever put into a prompt: lowercase letters and digits, 8 to 32 of them.
    static func isValidTag(_ tag: String) -> Bool {
        let bytes = Array(tag.utf8)
        guard (8...32).contains(bytes.count) else { return false }
        return bytes.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    static func newTag<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }

    /// ~/Library/Application Support/COS Control/setup/<tag>: an empty folder that exists only for this pass, because
    /// a new Claude Code thread trusts the folder it opens in.
    static func setupFolder(home: String, tag: String) -> String? {
        guard isValidTag(tag) else { return nil }
        return "\(home)/Library/Application Support/COS Control/setup/\(tag)"
    }

    /// Which app a row's Pass button hands the setup to: the provider's own app when it is installed, else the first
    /// installed one (Claude, ChatGPT, Cursor). Ollama's app cannot run commands, so it is never a target.
    static func target(for provider: AIProvider, installedApps: Set<AIProvider>) -> AIProvider? {
        if provider != .ollama, installedApps.contains(provider) { return provider }
        return AIProvider.agents.first { installedApps.contains($0) }
    }

    /// The fixed prompt. Control writes every word; the tag is the only value interpolated. No COS endpoint, no
    /// token, no web search, no sudo, Homebrew or global npm. Logins are handed to the person.
    static func prompt(setUp provider: AIProvider, tag: String) -> String? {
        guard isValidTag(tag), provider != .ollama else { return nil }
        let steps: String
        switch provider {
        case .claude:
            steps = """
            1. Run `claude --version`. If it prints a version, Claude Code is installed: go to step 3.
            2. If `claude` is not found, install it with exactly this command, which installs into ~/.local/bin and needs no administrator password:
               curl -fsSL https://claude.ai/install.sh | bash
               Then run `~/.local/bin/claude --version`.
            3. Run `claude auth status --text` (or `~/.local/bin/claude auth status --text`). Do not print or repeat the email address it shows.
            4. If it says I am not logged in, do not try to log in for me. Tell me to open Terminal and run this one command (or `~/.local/bin/claude` if Terminal says command not found), then type /login when Claude Code opens and sign in with my Claude account in the browser:
               claude
            """
        case .codex:
            steps = """
            1. Codex comes with the ChatGPT app for Mac. Run `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex --version`.
            2. If that file does not exist, do not install Codex with npm or Homebrew. Tell me to install or update the ChatGPT app from https://openai.com/chatgpt/download/ and stop.
            3. Run `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex login status`.
            4. If it says Not logged in, do not try to log in for me. Tell me to open Terminal and run this one command, then sign in with ChatGPT in the browser:
               /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex login
            """
        case .cursor:
            steps = """
            1. Run `~/.local/bin/agent --version`. If it prints a version, Cursor Agent is installed: go to step 3.
            2. If it is not found, install it with exactly this command, which installs into ~/.local/bin and needs no administrator password:
               curl https://cursor.com/install -fsS | bash
            3. Run `~/.local/bin/agent status`. Do not print or repeat the email address it shows.
            4. If it says I am not logged in, do not try to log in for me. Tell me to open Terminal and run this one command, then sign in to Cursor in the browser:
               ~/.local/bin/agent login
            """
        case .ollama:
            return nil
        }
        return """
        COS-SETUP \(tag)

        Please help me set up \(provider.cliName) on this Mac so COS Control can use it. Only set up \(provider.cliName); change nothing else.

        Rules:
        - Use only the exact commands below. Do not search the web for other installers.
        - Never use sudo, Homebrew, or a global npm install. If a step would need an administrator password or a change to System Settings, stop and ask me first.
        - Do not read, print, or copy any token, key, password, or credentials file, and do not contact any COS address.
        - This folder is empty on purpose. Do not create files in it.

        Steps:
        \(steps)
        5. Tell me in one or two sentences what you ran and what each check printed.

        End your reply with exactly one line, either:
        COS-SETUP \(tag): connected
        or:
        COS-SETUP \(tag): blocked: <one short reason>

        COS Control checks the result itself and turns its row green once \(provider.cliName) is signed in.
        """
    }

    /// The new-thread link for an app, prompt filled in, never sent.
    /// claude://code/new?folder=&q=   codex://threads/new?path=&prompt=   cursor://anysphere.cursor-deeplink/prompt?text=&mode=agent
    /// (Claude 2.26454.2 may ignore folder=, canary 2026-10-07: the prompt names no folder, so that does not matter.
    /// Cursor's link takes no folder.)
    static func link(app: AIProvider, prompt: String, folder: String) -> URL? {
        guard !prompt.isEmpty, prompt.utf16.count <= promptLimit,
              let text = prompt.addingPercentEncoding(withAllowedCharacters: linkQueryAllowed),
              let path = folder.addingPercentEncoding(withAllowedCharacters: linkQueryAllowed) else { return nil }
        switch app {
        case .claude: return URL(string: "claude://code/new?folder=\(path)&q=\(text)")
        case .codex: return URL(string: "codex://threads/new?path=\(path)&prompt=\(text)")
        case .cursor: return URL(string: "cursor://anysphere.cursor-deeplink/prompt?text=\(text)&mode=agent")
        case .ollama: return nil
        }
    }

    /// The AI's closing line, for display only: "connected", "blocked: <reason>", or nil. State never comes from it.
    static func reportedLine(_ text: String, tag: String) -> String? {
        guard isValidTag(tag) else { return nil }
        let marker = "COS-SETUP \(tag): "
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(marker) { return String(trimmed.dropFirst(marker.count)).prefix(140).description }
        }
        return nil
    }
}

// MARK: - Polling

/// Poll a waiting row every 3 s, backing off to 15 s, only while the card is on screen, and never past 15 minutes.
enum ProviderPollSchedule {
    static let fast: TimeInterval = 3
    static let slow: TimeInterval = 15
    static let fastPolls = 10
    static let limit: TimeInterval = 15 * 60

    /// The wait before poll number `attempt` (0-based), or nil once `elapsed` has reached the limit.
    static func delay(attempt: Int, elapsed: TimeInterval) -> TimeInterval? {
        guard elapsed < limit else { return nil }
        let base = attempt < fastPolls ? fast : min(slow, fast * pow(1.5, Double(attempt - fastPolls + 1)))
        return min(base, max(0, limit - elapsed))
    }
}

// MARK: - Dock

enum DockPresence {
    static let modeKey = "cos.dock.mode"
    enum Mode: String, Sendable { case dock, menuBarOnly }

    /// Decision (2026-10-08, F3): COS Control shows in the Dock unless the person chose "Show in menu bar only". That
    /// covers existing installs too: none of them could have chosen before, the menu-bar icon stays where it was, and
    /// the setting is one switch in the panel. A menu-bar-only person always has the menu-bar icon, and opening COS
    /// Control from Finder or Spotlight opens Activity.
    static func mode(stored: String?) -> Mode { Mode(rawValue: stored ?? "") ?? .dock }

    enum ReopenTarget: Sendable, Equatable { case setup, activity }
    /// A Dock click (or opening the running app again): Welcome while COS is not set up, else Activity.
    static func reopenTarget(needsFirstRun: Bool, activityAvailable: Bool) -> ReopenTarget {
        needsFirstRun || !activityAvailable ? .setup : .activity
    }
}

// MARK: - Pet introduction (F4)

enum PetIntro {
    static let seenKey = "cos.petIntro.seen"
    /// The pet settings a person can change. Touching any of them means they already met the pet.
    static let touchedKeys = ["cos.sessionPetEnabled", "cos.sessionPetCalmMotion", "cos.sessionPetNoMotion",
                              "cos.sessionPetSize", "cos.sessionPetSizePixels", "cos.sessionPetCharacterPercent"]
    /// Once, on first run and for anyone who never touched pet settings, while the pet is on.
    static func shouldShow(seen: Bool, touchedKeys: Int, petEnabled: Bool) -> Bool { !seen && touchedKeys == 0 && petEnabled }
}

// MARK: - The panel's Agent CLIs line (fixes "Not signed in" shown for a CLI that was not found)

enum AgentCliText {
    /// One line naming what to fix. Local provider-status wins; the server's flags are the fallback. A server flag of
    /// false means its `--version` probe failed: that is "not found by the server", never "not signed in".
    static func detail(server: [AIProvider: Bool?], cursorState: String?, local: ProviderStatusReport?) -> String? {
        var notFound: [String] = [], signIn: [String] = [], serverMissed: [String] = []
        for provider in AIProvider.agents {
            let serverReady: Bool? = provider == .cursor ? (cursorState.map { $0 == "connected" }) : (server[provider] ?? nil)
            if serverReady == true { continue }
            let name = provider == .cursor ? "cursor" : provider.rawValue
            if let status = local?.status(provider) {
                if !status.installed { notFound.append(name) }
                else if status.signIn == "signInRequired" {
                    signIn.append("\(name) (run: \(ProviderLogin.command(provider, binaryPath: status.binaryPath) ?? ""))")
                } else if serverReady == false { serverMissed.append(name) }
            } else if provider == .cursor {
                if cursorState == "notInstalled" { notFound.append(name) }
                else if cursorState == "signInRequired" { signIn.append("cursor (run: agent login)") }
            } else if serverReady == false {
                notFound.append(name)
            }
        }
        var parts: [String] = []
        if !notFound.isEmpty { parts.append("Not found: " + notFound.joined(separator: ", ")) }
        if !signIn.isEmpty { parts.append("Not signed in: " + signIn.joined(separator: ", ")) }
        if !serverMissed.isEmpty { parts.append("Installed, but the COS server could not run: " + serverMissed.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Jev and glasses rows (F5, F6)

enum GuideExtras {
    static let typesafeURL = URL(string: "https://typesafe.ai")!
    static let glassesWizardURL = URL(string: "https://gotcos.com/wizard/#glasses-setup")!

    /// The Jev row's status from the server's key state. The key is never read or shown.
    static func jevStatus(configured: Bool?, available: Bool?, serverRunning: Bool = true) -> String {
        guard serverRunning else { return "After setup" }
        guard let available, let configured else { return "Checking…" }
        if !available { return "Needs a newer COS server" }
        return configured ? "Key saved" : "No key yet"
    }
}

// MARK: - The guide

@MainActor
final class ProviderGuide: ObservableObject {
    @Published private(set) var report: ProviderStatusReport?
    @Published private(set) var error: String?
    /// Rows waiting on a sign-in the person started (Sign in or Pass): provider -> when.
    @Published private(set) var waiting: [AIProvider: Date] = [:]
    /// The pass in flight per provider (one at a time): provider -> tag.
    @Published private(set) var passes: [AIProvider: String] = [:]
    @Published private(set) var skipped: Set<AIProvider> = []
    @Published private(set) var installedApps: Set<AIProvider> = []
    /// The panel shows the Connect your AI card while this is true. Only the opener writes it.
    @Published var panelRouteActive = false
    @Published var notice: String?

    /// `cos-control-helper provider-status [--only …]`, returning the `details` object as JSON.
    var runStatus: @MainActor ([String]) async throws -> Data
    var runInTerminal: @MainActor (String) -> Bool = { _ in false }
    var openURL: @MainActor (URL) -> Bool = { _ in false }
    var copy: @MainActor (String) -> Void = { _ in }
    /// Whether an app handles a URL scheme (LaunchServices).
    var appInstalled: @MainActor (String) -> Bool = { _ in false }
    var makeFolder: @MainActor (String) -> Bool = { _ in false }
    var home: String
    private let defaults: UserDefaults
    private(set) var pollCount = 0
    private var refreshing = false

    static let skippedKey = "cos.connectAI.skipped"

    init(home: String, defaults: UserDefaults = .standard,
         runStatus: @escaping @MainActor ([String]) async throws -> Data) {
        self.home = home
        self.defaults = defaults
        self.runStatus = runStatus
        skipped = Set((defaults.stringArray(forKey: Self.skippedKey) ?? []).compactMap(AIProvider.init(rawValue:)))
    }

    var summary: String { ProviderRules.summary(report, skipped: skipped) }
    var needCount: Int { report.map { ProviderRules.needCount($0, skipped: skipped) } ?? 0 }
    var signInStepDone: Bool { ProviderGate.signInStepDone(report, skipped: skipped) }

    func row(_ provider: AIProvider) -> ProviderRowModel {
        ProviderRules.row(provider, report?.status(provider), skipped: skipped.contains(provider), waiting: waiting[provider] != nil)
    }

    func refreshApps() {
        installedApps = Set(AIProvider.agents.filter { provider in provider.appScheme.map { appInstalled($0) } ?? false })
    }

    /// Reads every provider again (or only `only`). Overlapping calls are dropped, never stacked.
    func refresh(only: [AIProvider]? = nil) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var arguments = ["provider-status", "--json"]
        if let only, !only.isEmpty { arguments += ["--only", only.map(\.rawValue).joined(separator: ",")] }
        do {
            let data = try await runStatus(arguments)
            guard let next = ProviderStatusReport.decode(data) else { throw ProviderGuideError.unreadable }
            report = (only == nil || report == nil) ? next : report!.merging(next)
            error = nil
        } catch {
            self.error = "COS could not check your AI apps: \(error.localizedDescription)"
        }
        for provider in Array(waiting.keys) where report?.status(provider)?.signedIn == true {
            waiting[provider] = nil
            passes[provider] = nil
            notice = "\(provider.title) is connected."
        }
    }

    /// Providers a poll should re-read: waiting rows, and installed rows that still need signing in.
    var pollTargets: [AIProvider] {
        AIProvider.agents.filter { provider in
            if waiting[provider] != nil { return true }
            guard let status = report?.status(provider) else { return true }
            return !status.installed || status.signIn == "signInRequired"
        }
    }

    /// The poll loop for a visible card. Runs on the view's task, so it ends when the card goes away; stops on its
    /// own after 15 minutes or once nothing is left to wait for. `sleep` is injected for checks.
    func poll(sleep: @escaping @MainActor (TimeInterval) async -> Bool = { seconds in
        (try? await Task.sleep(for: .seconds(seconds))) != nil
    }, now: @escaping @MainActor () -> Date = Date.init) async {
        let started = now()
        var attempt = 0
        pollCount = 0
        if report == nil { await refresh() }
        while !Task.isCancelled {
            let targets = pollTargets
            guard !targets.isEmpty,
                  let wait = ProviderPollSchedule.delay(attempt: attempt, elapsed: now().timeIntervalSince(started)),
                  wait > 0 else { return }
            guard await sleep(wait) else { return }
            await refresh(only: targets)
            pollCount += 1
            attempt += 1
        }
    }

    /// Sign in: Terminal opens on the exact command; the row waits and turns green when the CLI says signed in.
    func signIn(_ provider: AIProvider) {
        guard let command = ProviderLogin.command(provider, binaryPath: report?.status(provider)?.binaryPath) else { return }
        if runInTerminal(ProviderLogin.terminalScript(command)) {
            waiting[provider] = Date()
            unskip(provider)
            notice = nil
        } else {
            copy(command)
            notice = "Terminal could not be opened. The command is on the clipboard: paste it into Terminal."
        }
    }

    /// Stop waiting on a sign-in without skipping it: the row goes back to Sign in.
    func stopWaiting(_ provider: AIProvider) {
        waiting[provider] = nil
        passes[provider] = nil
    }

    func skip(_ provider: AIProvider) {
        skipped.insert(provider)
        waiting[provider] = nil
        defaults.set(skipped.map(\.rawValue).sorted(), forKey: Self.skippedKey)
    }

    func unskip(_ provider: AIProvider) {
        guard skipped.remove(provider) != nil else { return }
        defaults.set(skipped.map(\.rawValue).sorted(), forKey: Self.skippedKey)
    }

    /// Pass to an AI app: a new thread in an empty folder with the fixed prompt filled in, for the person to send.
    @discardableResult
    func pass(_ provider: AIProvider, to app: AIProvider, tag: String) -> Bool {
        if passes[provider] != nil, waiting[provider] != nil {
            notice = "A setup for \(provider.cliName) is already open. Send it there, or use Sign in."
            return false
        }
        guard let prompt = ProviderPass.prompt(setUp: provider, tag: tag),
              let folder = ProviderPass.setupFolder(home: home, tag: tag), makeFolder(folder),
              let url = ProviderPass.link(app: app, prompt: prompt, folder: folder) else {
            notice = "\(app.appName) could not be opened. Use the steps below instead."
            return false
        }
        guard openURL(url) else {
            notice = "\(app.appName) could not be opened. Use the steps below instead."
            return false
        }
        passes[provider] = tag
        waiting[provider] = Date()
        unskip(provider)
        notice = "Opened \(app.appName) with the setup filled in. Read it, then press Send there. This row turns green when \(provider.cliName) is signed in."
        return true
    }

    func openInPanel() {
        panelRouteActive = true
        Task { await refresh() }
    }

    func closePanelRoute() { panelRouteActive = false }
}

enum ProviderGuideError: LocalizedError {
    case unreadable
    var errorDescription: String? { "the helper's answer could not be read" }
}
