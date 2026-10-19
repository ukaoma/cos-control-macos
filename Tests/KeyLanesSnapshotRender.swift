import AppKit
import CryptoKit
import SwiftUI

// K0-G G-control, part 2 (plan v4 section 3.3): the shipped Control views a key lane will touch, drawn off screen today
// with no key-lane code: Welcome (Get started, ControlSetup.swift:116), Connect your AI (ProviderConnectViews.swift:250,
// reached through Get started), Settings (the Activity window's Settings and the panel document), the Work Agent
// workspace (new session, the provider and model choice) and the Work Start sheet. For each, light and dark: the size
// drawn, a SHA-256 of the bitmap's pixel bytes, and the accessibility text (role, label, value), which is what a K1
// replay compares (expected difference: exactly one Settings row, plan 3.2).
//
// Same rules as every render harness here (Tests/desktop-safety-check.py): no window is ordered in, the process can never
// become active, nothing opens Terminal, an app or a link, and no helper or server runs: provider-status answers come
// from fixture JSON. Run by Tests/KeyLanesSnapshot.run.sh, one full compile, through the compile guard.

let allMissing = data(row("claude", installed: false, signIn: "unknown"), row("codex", installed: false, signIn: "unknown"),
                      row("cursor", installed: false, signIn: "unknown"), row("ollama", installed: false, signIn: "notNeeded", daemon: "down", models: []))
let allIn = data(row("claude", path: "/opt/homebrew/bin/claude", version: "2.1.293"),
                 row("codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", version: "0.163.0"),
                 row("cursor", path: "/Users/you/.local/bin/agent", version: "2026.10.01-e373342"),
                 row("ollama", path: "/usr/local/bin/ollama", signIn: "notNeeded", version: "0.40.0", daemon: "running", models: ["qwen3:4b"]))

func row(_ provider: String, installed: Bool = true, path: String? = nil, signIn: String = "signedIn",
         version: String? = nil, daemon: String? = nil, models: [String]? = nil) -> String {
    let cand = path.map { #"[{"path":"\#($0)","source":"absolute","executable":true,"chosen":true}]"# } ?? "[]"
    let m = models.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
    return #"{"provider":"\#(provider)","installed":\#(installed),"binaryPath":\#(path.map { "\"\($0)\"" } ?? "null"),"version":\#(version.map { "\"\($0)\"" } ?? "null"),"signIn":"\#(signIn)","candidates":\#(cand),"detail":null,"daemon":\#(daemon.map { "\"\($0)\"" } ?? "null"),"models":\#(m),"host":null}"#
}
func data(_ rows: String...) -> Data { Data(#"{"providers":[\#(rows.joined(separator: ","))],"checkedAt":"2026-10-19T15:00:00Z"}"#.utf8) }

@MainActor func fixtureGuide(_ answer: Data, apps: Set<String> = ["claude", "codex"]) async -> ProviderGuide {
    let defaults = UserDefaults(suiteName: "cos.key-lanes-snapshot.\(UUID().uuidString)")!
    let guide = ProviderGuide(home: "/Users/you", defaults: defaults) { _ in answer }
    guide.appInstalled = { apps.contains($0) }
    guide.runInTerminal = { _ in true }
    guide.openURL = { _ in true }
    guide.makeFolder = { _ in true }
    guide.refreshApps()
    await guide.refresh()
    return guide
}

@MainActor func firstRunModel(_ guide: ProviderGuide, installed: Bool) -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent"), "setupProviderInstalled": .bool(installed)])
    model.providerGuide = guide
    // Its own defaults suite, so Get started on one render never carries into the next.
    model.setupGuide = SetupGuideState(defaults: UserDefaults(suiteName: "cos.key-lanes-setup.\(UUID().uuidString)")!)
    return model
}

@MainActor func healthyModel(_ guide: ProviderGuide) -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus([
        "installed": .bool(true), "serviceLoaded": .bool(true), "running": .bool(true), "managedContract": .bool(true),
        "runtimeState": .string("managedHealthy"), "ownershipVerified": .bool(true),
        "version": .string("6.79.0"), "installedVersion": .string("6.79.0"),
        "claudeCliReady": .bool(true), "codexCliReady": .bool(true), "cursorState": .string("ready"),
    ])
    model.providerGuide = guide
    return model
}

@MainActor func pump(_ rounds: Int = 14) { for _ in 0..<rounds { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) } }

/// Role, label and value of every accessibility element under `element`, depth first, one line each.
@MainActor func accessibilityText(_ element: Any, depth: Int = 0, into lines: inout [String]) {
    guard depth < 60, let object = element as? NSAccessibilityProtocol & NSObject else { return }
    let role = object.accessibilityRole()?.rawValue ?? ""
    let label = object.accessibilityLabel() ?? ""
    var value = ""
    if let v = object.accessibilityValue() { value = String(describing: v) }
    let title = object.accessibilityTitle() ?? ""
    let parts = [label, title, value].filter { !$0.isEmpty }
    if !parts.isEmpty { lines.append(String(repeating: " ", count: min(depth, 30)) + "\(role): " + parts.joined(separator: " | ")) }
    for child in object.accessibilityChildren() ?? [] { accessibilityText(child, depth: depth + 1, into: &lines) }
}

@MainActor func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL?) throws -> [String: Any] {
    var result: [String: Any] = [:]
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump(4)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        let byteCount = rep.bytesPerRow * rep.pixelsHigh
        let pixels = rep.bitmapData.map { Data(bytes: $0, count: byteCount) } ?? Data()
        let digest = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
        var lines: [String] = []
        accessibilityText(host, into: &lines)
        let word = appearance == .darkAqua ? "dark" : "light"
        if let out { try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png")) }
        result[word] = ["pixelsWide": rep.pixelsWide, "pixelsHigh": rep.pixelsHigh, "pixelSha256": digest, "accessibility": lines]
        window.close()
    }
    return result
}

func canonical(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

@main @MainActor struct KeyLanesSnapshotRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        // Optional PNG folder (for a person to look at); the JSON on stdout is the golden.
        let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : nil
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var views: [String: Any] = [:]

        // Welcome (Get started), nothing installed and all signed in.
        views["welcome-all-missing"] = try snapshot(ControlSetupView(model: firstRunModel(await fixtureGuide(allMissing), installed: false)),
                                                    width: 540, height: 1080, name: "welcome-all-missing", out: out)
        views["welcome-all-signed-in"] = try snapshot(ControlSetupView(model: firstRunModel(await fixtureGuide(allIn), installed: true)),
                                                      width: 540, height: 900, name: "welcome-all-signed-in", out: out)
        // Connect your AI: Get started pressed.
        for (name, answer) in [("connect-all-missing", allMissing), ("connect-all-signed-in", allIn)] {
            let guide = await fixtureGuide(answer)
            let model = firstRunModel(guide, installed: answer == allIn)
            model.setupGuide.beginJourney()
            views[name] = try snapshot(ControlSetupView(model: model), width: 540, height: 1300, name: name, out: out)
        }
        // Settings: the Activity window's Settings tab, and the panel card for Connect your AI.
        let settingsModel = healthyModel(await fixtureGuide(allIn))
        views["activity-settings"] = try snapshot(ActivityWindow.settingsFixture(model: settingsModel), width: 1000, height: 1400,
                                                  name: "activity-settings", out: out)
        let cardModel = healthyModel(await fixtureGuide(allIn))
        views["panel-connect-ai-row"] = try snapshot(PanelConnectAIRow(guide: cardModel.providerGuide, model: cardModel).padding(16).background(COSPalette.panel),
                                                     width: 390, height: 120, name: "panel-connect-ai-row", out: out)

        // Work: the Agent workspace's new-session choice (provider and model) and the Start sheet, on the isolated
        // preview store (no server, no provider).
        let store = WorkHandoffStore(isolated: true)
        let task = WorkWorkspaceProjection.previewRows(store.previewTasks).first { !$0.checked }!
        let source = WorkSource.taskSnapshot(task)
        for (provider, modelID) in [("claude", "opus"), ("codex", "codex-frontier"), ("ollama", "ollama")] {
            var draft = store.draft(for: source)
            draft.mode = .newSession; draft.provider = provider; draft.modelID = modelID
            draft.prompt = "Golden prompt for the key-lanes snapshot."
            _ = store.updateDraft(draft, for: source)
            views["work-workspace-\(provider)"] = try snapshot(WorkHandoffView(store: store, source: source, isPreview: true, onOpenSession: { _ in }).padding(18),
                                                               width: 440, height: 900, name: "work-workspace-\(provider)", out: out)
        }
        views["work-start-sheet"] = try snapshot(WorkStartSheet(store: store, files: store.cardFiles, title: "Golden card", subtitle: "Key-lanes snapshot",
                                                                source: source, isPreview: true, sending: .constant(false),
                                                                onOpenSession: { _ in }, onClose: {}),
                                                 width: 600, height: 640, name: "work-start-sheet", out: out)
        let catalog = store.models.map { ["provider": $0.provider, "id": $0.id, "title": $0.title, "available": $0.available, "reason": $0.reason ?? NSNull()] as [String: Any] }
        print(canonical(["schema": "key-lanes-control-render/1", "views": views, "workModelCatalog": catalog]))
    }
}
