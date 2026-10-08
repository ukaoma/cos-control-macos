import Foundation

// provider-status (HelperSources/ProviderStatusCore.swift) compiled on its own against fixtures: the candidate order,
// what each CLI's status output means, Cursor's identity check and Ollama. No real CLI runs and no file is read: the
// file system and every probe are stand-ins.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1; return }
    failures += 1
    FileHandle.standardError.write(Data("check failed [\(behaviour)]: \(detail())\n".utf8))
}

let home = "/Users/fixture home.ü"

/// A Mac made of the given executable paths and directory listings.
func mac(_ executables: Set<String>, path: String = "/usr/bin:/bin", env: [String: String] = [:],
         dirs: [String: [String]] = [:]) -> ProviderSearchEnvironment {
    var environment = env
    environment["PATH"] = path
    return ProviderSearchEnvironment(home: home, env: environment,
                                     isExecutable: { executables.contains($0) },
                                     listDirectory: { dirs[$0] ?? [] })
}

/// Probes answering from a table: "path args" -> (code, output). Records every call.
final class Calls: @unchecked Sendable { var list: [String] = [] }
func probes(_ answers: [String: (Int32, String)], calls: Calls = Calls(),
            http: (status: Int, body: Data)? = nil) -> ProviderProbes {
    ProviderProbes(
        run: { path, arguments in
            let key = ([path] + arguments).joined(separator: " ")
            calls.list.append(key)
            return answers[key].map { (code: $0.0, output: $0.1) }
        },
        get: { _ in http })
}

let chatgptCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
let claudeJSONIn = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "a@b.co", "orgName": "X"}"#
let claudeJSONOut = #"{"loggedIn": false}"#
let aboutSignedIn = """
About Cursor CLI

CLI Version         2026.10.01-e373342
Latest              2026.10.01-e373342 (up to date)
Subscription Tier   Pro+
User Email          person@example.com
"""
let aboutSignedOut = """
About Cursor CLI

CLI Version         2026.10.01-e373342
User Email          Not logged in
"""

@main
struct ProviderStatusChecks {
    static func main() {
        candidateOrder()
        chatgptOnly()
        aliasesIgnored()
        notInstalled()
        signInStates()
        cursorIdentity()
        ollama()
        claudeDesktopOnly()
        json()
        if failures > 0 {
            FileHandle.standardError.write(Data("provider-status checks: \(failures) failed, \(passes) passed\n".utf8))
            exit(1)
        }
        print("provider-status checks: \(passes) passed")
    }

    static func candidateOrder() {
        // The server's order: env override, then its absolutes, then PATH, then the helper's extra roots.
        let env = mac([], path: "/custom/bin:/usr/bin", env: ["COS_CODEX_BIN": "/opt/override/codex"])
        let order = ProviderStatusCore.candidates("codex", in: env).map(\.path)
        check(order.first == "/opt/override/codex", "candidate order", "the env override comes first: \(order)")
        check(order.dropFirst().first == chatgptCodex, "candidate order", "then the ChatGPT app's codex-cli, the server's first absolute: \(order)")
        if let app = order.firstIndex(of: chatgptCodex), let path = order.firstIndex(of: "/custom/bin/codex") {
            check(app < path, "candidate order", "an app path is tried before PATH, as the server does")
        } else { check(false, "candidate order", "PATH entries are listed: \(order)") }
        check(order.contains("\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"), "candidate order", "a per-user ChatGPT app is checked")
        let claude = ProviderStatusCore.candidates("claude", in: mac([])).map(\.path)
        check(Array(claude.prefix(3)) == ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude"], "candidate order", "claude matches server/lib/provider-binary.ts: \(claude.prefix(3))")
        let cursor = ProviderStatusCore.candidates("cursor", in: mac([], path: "/p")).map(\.path)
        check(cursor.contains("/p/agent") && cursor.contains("/p/cursor-agent"), "candidate order", "Cursor answers to agent and cursor-agent: \(cursor)")
        // A stale Codex.app shim is listed but never executable.
        let stale = ProviderStatusCore.candidates("codex", in: mac(["/Applications/Codex.app/Contents/Resources/codex"], path: "/Applications/Codex.app/Contents/Resources"))
        let shim = stale.first { $0.path.hasPrefix("/Applications/Codex.app/") }
        check(shim != nil && shim?.executable == false, "stale shim", "the retired Codex.app path is never chosen")
        check(Set(stale.map(\.path)).count == stale.count, "candidate order", "no path is listed twice")
    }

    static func chatgptOnly() {
        // A Mac with only the ChatGPT app: no codex on PATH anywhere.
        let calls = Calls()
        let status = ProviderStatusProbe.status("codex", environment: mac([chatgptCodex]), probes: probes([
            "\(chatgptCodex) --version": (0, "codex-cli 0.162.0-alpha.2\n"),
            "\(chatgptCodex) login status": (0, "Logged in using ChatGPT\n"),
        ], calls: calls))
        check(status.installed && status.binaryPath == chatgptCodex, "ChatGPT-only codex", "found inside the app: \(status.binaryPath ?? "nil")")
        check(status.version == "0.162.0-alpha.2", "ChatGPT-only codex", "version: \(status.version ?? "nil")")
        check(status.signIn == .signedIn, "ChatGPT-only codex", "signed in with ChatGPT")
        check(status.candidates.filter(\.chosen).map(\.path) == [chatgptCodex], "ChatGPT-only codex", "exactly one chosen candidate")
        check(calls.list == ["\(chatgptCodex) --version", "\(chatgptCodex) login status"], "no model turn", "only --version and login status run: \(calls.list)")
    }

    static func aliasesIgnored() {
        // An alias or shell function named claude is invisible: no shell runs, and only files count.
        let status = ProviderStatusProbe.status("claude", environment: mac([], path: "/usr/bin:/bin", env: ["SHELL": "/bin/zsh", "ALIASES": "alias claude=/somewhere/claude"]),
                                               probes: probes(["/somewhere/claude --version": (0, "9.9.9")]))
        check(!status.installed && status.binaryPath == nil, "aliases ignored", "an alias never makes claude installed")
        check(status.signIn == .unknown, "aliases ignored", "nothing installed, nothing signed in")
        // A relative PATH entry is skipped (the server never resolves against its cwd).
        let relative = ProviderStatusCore.candidates("claude", in: mac(["bin/claude"], path: "bin:/usr/bin"))
        check(!relative.contains { $0.path == "bin/claude" || !$0.path.hasPrefix("/") }, "relative PATH", "relative entries are not candidates")
    }

    static func notInstalled() {
        for provider in ["claude", "codex", "cursor"] {
            let calls = Calls()
            let status = ProviderStatusProbe.status(provider, environment: mac([]), probes: probes([:], calls: calls))
            check(!status.installed && status.signIn == .unknown && status.binaryPath == nil, "not installed", "\(provider) reads not installed")
            check(calls.list.isEmpty, "not installed", "\(provider): nothing is run when nothing is found")
        }
    }

    static func signInStates() {
        let brew = "/opt/homebrew/bin/claude"
        func claude(_ code: Int32, _ output: String) -> ProviderSignIn {
            ProviderStatusProbe.status("claude", environment: mac([brew]), probes: probes([
                "\(brew) --version": (0, "2.1.293 (Claude Code)"), "\(brew) auth status --json": (code, output)])).signIn
        }
        check(claude(0, claudeJSONIn) == .signedIn, "claude sign-in", "loggedIn true with claude.ai")
        check(claude(1, claudeJSONOut) == .signInRequired, "claude sign-in required", "loggedIn false")
        check(claude(0, #"{"loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty"}"#) == .apiKey, "claude api key", "an API key is apiKey")
        check(claude(0, #"{"loggedIn": true, "authMethod": "oauth", "apiProvider": "bedrock"}"#) == .apiKey, "claude api key", "a cloud provider is billed separately")
        check(claude(2, "error: unknown command 'auth'") == .unknown, "claude unknown", "an older CLI without auth status is unknown, not signed out")
        check(claude(1, "Not logged in. Run claude auth login.") == .signInRequired, "claude sign-in required", "plain-text not logged in")
        let version = ProviderStatusProbe.status("claude", environment: mac([brew]), probes: probes([
            "\(brew) --version": (0, "2.1.293 (Claude Code)"), "\(brew) auth status --json": (0, claudeJSONIn)]))
        check(version.version == "2.1.293", "claude version", "\(version.version ?? "nil")")
        check(!"\(version.json)".contains("a@b.co") && !"\(version.json)".contains("orgName"), "no email kept", "the status carries no email or org")

        check(ProviderStatusCore.codexSignIn(output: "Logged in using ChatGPT", exitCode: 0) == .signedIn, "codex sign-in", "ChatGPT")
        check(ProviderStatusCore.codexSignIn(output: "Logged in using an API key - sk-proj-***ABCD", exitCode: 0) == .apiKey, "codex api key", "API key")
        check(ProviderStatusCore.codexSignIn(output: "Not logged in", exitCode: 1) == .signInRequired, "codex sign-in required", "not logged in")
        check(ProviderStatusCore.codexSignIn(output: "error: unrecognized subcommand 'status'", exitCode: 2) == .unknown, "codex unknown", "an older CLI is unknown")
    }

    static func cursorIdentity() {
        let local = "\(home)/.local/bin/agent"
        let other = "\(home)/.local/bin/agent"
        let real = "/opt/cursor/bin/cursor-agent"
        // Another program called `agent` first in line is skipped: only one whose `about` prints CLI Version is Cursor's.
        let calls = Calls()
        let status = ProviderStatusProbe.status("cursor", environment: mac([other, real], path: "/opt/cursor/bin"),
            probes: probes([
                "\(other) about": (0, "agent: unknown command about"),
                "\(real) about": (0, aboutSignedIn),
            ], calls: calls))
        check(calls.list.first == "\(other) about", "cursor identity", "the first candidate is tried first: \(calls.list)")
        check(status.installed && status.binaryPath == real, "cursor identity", "cursor-agent accepted, the foreign agent skipped: \(status.binaryPath ?? "nil")")
        check(status.candidates.first { $0.path == other }?.note?.contains("CLI Version") == true, "cursor identity", "the skipped binary says why")
        check(status.signIn == .signedIn && status.version == "2026.10.01-e373342", "cursor sign-in", "\(status.signIn) \(status.version ?? "nil")")
        check(!calls.list.contains { $0.contains("login") }, "no login", "never runs a login")
        let out = ProviderStatusProbe.status("cursor", environment: mac([local]), probes: probes(["\(local) about": (0, aboutSignedOut)]))
        check(out.installed && out.signIn == .signInRequired, "cursor sign-in required", "User Email Not logged in")
        let none = ProviderStatusProbe.status("cursor", environment: mac([other]), probes: probes(["\(other) about": (0, "hello")]))
        check(!none.installed, "cursor identity", "a lone foreign agent is not Cursor")
        check(ProviderStatusCore.cursorAbout(output: "CLI Version 1.0\nUser Email          <redacted-email>\n").signIn == .signedIn, "cursor sign-in", "a redacted address is still an address")
        check(ProviderStatusCore.cursorAbout(output: "CLI Version 1.0\nUser Email\n").signIn == .signInRequired, "cursor sign-in required", "an empty User Email is signed out")
        let parsed = ProviderStatusCore.cursorAbout(output: "CLI Version 1.0\n")
        check(parsed.isCursor && parsed.signIn == .unknown, "cursor unknown", "no User Email line is unknown, not signed out")
    }

    static func ollama() {
        let bin = "/usr/local/bin/ollama"
        let tags = Data(#"{"models":[{"name":"qwen3:4b"},{"name":"llama3.2:3b"}]}"#.utf8)
        let up = ProviderStatusProbe.status("ollama", environment: mac([bin]),
                                            probes: probes(["\(bin) --version": (0, "ollama version is 0.40.0")], http: (200, tags)))
        check(up.installed && up.daemon == "running" && up.models == ["qwen3:4b", "llama3.2:3b"], "ollama running", "\(up.daemon ?? "nil") \(up.models ?? [])")
        check(up.version == "0.40.0" && up.signIn == .notNeeded, "ollama running", "version and no account")
        let down = ProviderStatusProbe.status("ollama", environment: mac([bin]), probes: probes([:], http: nil))
        check(down.installed && down.daemon == "down" && down.detail?.contains("not running") == true, "ollama daemon down", "installed but not running is not 'not installed'")
        let missing = ProviderStatusProbe.status("ollama", environment: mac([]), probes: probes([:], http: nil))
        check(!missing.installed && missing.daemon == "down" && missing.detail == nil, "ollama not installed", "no binary and no daemon")
        let remote = ProviderStatusProbe.status("ollama", environment: mac([], env: ["COS_OLLAMA_HOST": "studio.local:11434"]), probes: probes([:], http: (200, tags)))
        check(remote.installed && remote.host == "http://studio.local:11434", "ollama host", "COS_OLLAMA_HOST is honoured: \(remote.host ?? "nil")")
        check(ProviderStatusCore.ollamaOrigin(nil) == "http://127.0.0.1:11434", "ollama host", "loopback by default")
        let wrong = ProviderStatusProbe.status("ollama", environment: mac([bin]), probes: probes([:], http: (200, Data("<html>".utf8))))
        check(wrong.daemon == "down", "ollama host", "a page that is not Ollama's answer is not a running daemon")
    }

    static func claudeDesktopOnly() {
        let root = "\(home)/Library/Application Support/Claude/claude-code"
        let copy = "\(root)/2.1.293/8433d0d9cd0d/claude.app/Contents/MacOS/claude"
        let env = mac([copy, "\(root)/2.1.289/ee67e3f1ea60/claude.app/Contents/MacOS/claude"],
                      dirs: [root: ["2.1.289", "2.1.293", ".DS_Store"], "\(root)/2.1.293": ["8433d0d9cd0d"], "\(root)/2.1.289": ["ee67e3f1ea60"]])
        check(ProviderStatusCore.claudeDesktopCopy(in: env) == copy, "claude desktop copy", "the newest version is reported")
        let calls = Calls()
        let status = ProviderStatusProbe.status("claude", environment: env, probes: probes([:], calls: calls))
        check(!status.installed && status.binaryPath == nil, "claude desktop copy", "Claude Desktop's own copy is never chosen: the server cannot run it")
        check(status.detail?.contains("Claude Desktop") == true && status.candidates.contains { $0.source == "claudeDesktop" && $0.executable }, "claude desktop copy", "the row can say why")
        check(calls.list.isEmpty, "claude desktop copy", "the desktop copy is never run")
    }

    static func json() {
        let status = ProviderStatusProbe.status("codex", environment: mac([chatgptCodex]), probes: probes([
            "\(chatgptCodex) --version": (0, "codex-cli 0.162.0"), "\(chatgptCodex) login status": (1, "Not logged in")]))
        let object = status.json
        check(object["signIn"] as? String == "signInRequired" && object["installed"] as? Bool == true, "json", "\(object)")
        check(JSONSerialization.isValidJSONObject(["providers": [object]]), "json", "serializable")
        check((object["candidates"] as? [[String: Any]])?.contains { $0["chosen"] as? Bool == true } == true, "json", "candidates mark the chosen one")
    }
}
