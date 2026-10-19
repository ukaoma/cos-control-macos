import Foundation

// K0-G G-control, part 1 (plan v4 section 3.3): what provider-status (HelperSources/ProviderStatusCore.swift) reports
// today, with no key-lane code, for fixture Macs. The JSON it prints is the golden: every provider's status object and
// every probe the helper runs (path and arguments), so a K1 change that adds a probe, a field or a provider shows up as
// a diff. No real CLI runs and no file is read: the file system and every probe are stand-ins (the same shape as
// Tests/ProviderStatusChecks.swift). Output is canonical (sorted keys), with no clock, id or port: nothing to normalize.
//
// Compiled with only ProviderStatusCore.swift (Foundation), through Tests/compile-guard.sh, by KeyLanesSnapshot.run.sh.

let home = "/Users/fixture"
let chatgptCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

func mac(_ executables: Set<String>, path: String = "/usr/bin:/bin", env: [String: String] = [:],
         dirs: [String: [String]] = [:]) -> ProviderSearchEnvironment {
    var environment = env
    environment["PATH"] = path
    return ProviderSearchEnvironment(home: home, env: environment,
                                     isExecutable: { executables.contains($0) },
                                     listDirectory: { dirs[$0] ?? [] })
}

final class Calls: @unchecked Sendable { var list: [String] = [] }
func probes(_ answers: [String: (Int32, String)], calls: Calls, http: (status: Int, body: Data)?) -> ProviderProbes {
    ProviderProbes(
        run: { path, arguments in
            let key = ([path] + arguments).joined(separator: " ")
            calls.list.append(key)
            return answers[key].map { (code: $0.0, output: $0.1) }
        },
        get: { url in
            calls.list.append("GET \(url.absoluteString)")
            return http
        })
}

let claudeIn = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}"#
let claudeOut = #"{"loggedIn": false}"#
let aboutIn = "About Cursor CLI\n\nCLI Version         2026.10.01-e373342\nSubscription Tier   Pro+\nUser Email          person@example.com\n"
let ollamaTags = Data(#"{"models":[{"name":"qwen3:4b"},{"name":"llama3.2:3b"}]}"#.utf8)

struct Fixture { let name: String; let environment: ProviderSearchEnvironment; let answers: [String: (Int32, String)]; let http: (status: Int, body: Data)? }

func answersAll(claude: String, codex: String, agent: String) -> [String: (Int32, String)] {
    var a: [String: (Int32, String)] = [:]
    for (bin, version) in [(claude, "2.1.293 (Claude Code)"), (codex, "codex-cli 0.163.0"), (agent, "2026.10.01-e373342")] {
        a["\(bin) --version"] = (0, version)
    }
    a["\(claude) auth status --json"] = (0, claudeIn)
    a["\(claude) auth status"] = (0, claudeIn)
    a["\(codex) login status"] = (0, "Logged in using ChatGPT")
    a["\(agent) about"] = (0, aboutIn)
    a["\(agent) status"] = (0, "Logged in as person@example.com")
    a["/usr/local/bin/ollama --version"] = (0, "ollama version is 0.40.0")
    return a
}

func makeFixtures() -> [Fixture] { [
    Fixture(name: "nothing-installed", environment: mac([]), answers: [:], http: nil),
    Fixture(name: "all-signed-in",
            environment: mac(["/opt/homebrew/bin/claude", chatgptCodex, "\(home)/.local/bin/agent", "/usr/local/bin/ollama"],
                             path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
            answers: answersAll(claude: "/opt/homebrew/bin/claude", codex: chatgptCodex, agent: "\(home)/.local/bin/agent"),
            http: (status: 200, body: ollamaTags)),
    Fixture(name: "claude-signed-out",
            environment: mac(["/opt/homebrew/bin/claude"], path: "/opt/homebrew/bin:/usr/bin:/bin"),
            answers: ["/opt/homebrew/bin/claude --version": (0, "2.1.293 (Claude Code)"),
                      "/opt/homebrew/bin/claude auth status --json": (1, claudeOut),
                      "/opt/homebrew/bin/claude auth status": (1, claudeOut)],
            http: nil),
    // Env overrides, as COS Control's plist and the server read them (COS_*_BIN).
    Fixture(name: "env-overrides",
            environment: mac(["/opt/cos/bin/claude", "/opt/cos/bin/codex"], env: ["COS_CLAUDE_BIN": "/opt/cos/bin/claude", "COS_CODEX_BIN": "/opt/cos/bin/codex"]),
            answers: ["/opt/cos/bin/claude --version": (0, "2.1.293 (Claude Code)"), "/opt/cos/bin/codex --version": (0, "codex-cli 0.163.0")],
            http: nil),
] }

func canonical(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

@main
struct KeyLanesSnapshotStatus {
    static func main() {
        var out: [String: Any] = [:]
        for fixture in makeFixtures() {
            var providers: [String: Any] = [:]
            for provider in ProviderStatusCore.providers {
                let calls = Calls()
                let status = ProviderStatusProbe.status(provider, environment: fixture.environment,
                                                       probes: probes(fixture.answers, calls: calls, http: fixture.http))
                providers[provider] = ["status": status.json, "probes": calls.list]
            }
            out[fixture.name] = [
                "providers": providers,
                "setupProviderPresent": ProviderStatusCore.setupProviderPresent(in: fixture.environment),
            ]
        }
        var tables: [String: Any] = [:]
        for provider in ProviderStatusCore.providers {
            tables[provider] = ["names": ProviderStatusCore.names(provider), "envKeys": ProviderStatusCore.envKeys(provider),
                                "absolutes": ProviderStatusCore.absolutes(provider, home: home)]
        }
        print(canonical(["schema": "key-lanes-control-status/1", "providerTables": tables, "fixtures": out]))
    }
}
