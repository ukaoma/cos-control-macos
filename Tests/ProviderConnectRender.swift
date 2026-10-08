import AppKit
import SwiftUI

// Static renders of Connect your AI (onboarding P1), light and dark: the Welcome step with nothing installed, a mixed
// Mac and everything signed in; the panel card; a row waiting on Sign in; the collapsed panel row; the session pet
// introduction; and the whole panel document (with the Dock setting). The guide reads fixture JSON, never the helper;
// nothing opens Terminal, an app or a link; no window is ordered in and the process can never become active.

let chatgptCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

func row(_ provider: String, installed: Bool = true, path: String? = nil, signIn: String = "signedIn",
         version: String? = nil, daemon: String? = nil, models: [String]? = nil) -> String {
    let cand = path.map { #"[{"path":"\#($0)","source":"absolute","executable":true,"chosen":true}]"# } ?? "[]"
    let m = models.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
    return #"{"provider":"\#(provider)","installed":\#(installed),"binaryPath":\#(path.map { "\"\($0)\"" } ?? "null"),"version":\#(version.map { "\"\($0)\"" } ?? "null"),"signIn":"\#(signIn)","candidates":\#(cand),"detail":null,"daemon":\#(daemon.map { "\"\($0)\"" } ?? "null"),"models":\#(m),"host":null}"#
}

func data(_ rows: String...) -> Data { Data(#"{"providers":[\#(rows.joined(separator: ","))],"checkedAt":"2026-10-08T15:00:00Z"}"#.utf8) }

let allMissing = data(row("claude", installed: false, signIn: "unknown"), row("codex", installed: false, signIn: "unknown"),
                      row("cursor", installed: false, signIn: "unknown"), row("ollama", installed: false, signIn: "notNeeded", daemon: "down", models: []))
let mixed = data(row("claude", path: "/opt/homebrew/bin/claude", signIn: "signInRequired", version: "2.1.293"),
                 row("codex", path: chatgptCodex, version: "0.162.0-alpha.2"),
                 row("cursor", installed: false, signIn: "unknown"),
                 row("ollama", path: "/usr/local/bin/ollama", signIn: "notNeeded", version: "0.40.0", daemon: "down", models: []))
let allIn = data(row("claude", path: "/opt/homebrew/bin/claude", version: "2.1.293"), row("codex", path: chatgptCodex, version: "0.162.0-alpha.2"),
                 row("cursor", path: "/Users/you/.local/bin/agent", version: "2026.10.01-e373342"),
                 row("ollama", path: "/usr/local/bin/ollama", signIn: "notNeeded", version: "0.40.0", daemon: "running", models: ["qwen3:4b", "llama3.2:3b"]))

@MainActor func fixtureGuide(_ answer: Data, apps: Set<String> = []) async -> ProviderGuide {
    let name = "cos.provider-connect-render.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
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
    return model
}

@main @MainActor struct ProviderConnectRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let apps: Set<String> = ["claude", "codex"]

        // 1. Welcome, Connect your AI: nothing installed, a mixed Mac, everything signed in.
        try render(ControlSetupView(model: firstRunModel(await fixtureGuide(allMissing, apps: apps), installed: false)),
                   width: 540, height: 1080, name: "welcome-all-missing", out: out)
        try render(ControlSetupView(model: firstRunModel(await fixtureGuide(mixed, apps: apps), installed: true)),
                   width: 540, height: 980, name: "welcome-mixed", out: out)
        try render(ControlSetupView(model: firstRunModel(await fixtureGuide(allIn, apps: apps), installed: true)),
                   width: 540, height: 760, name: "welcome-all-signed-in", out: out)

        // 2. The panel card (390 pt panel, 16 pt padding), a mixed Mac, opened in place.
        let panelWidth: CGFloat = 358
        let cardModel = ControllerModel(startBackgroundWork: false)
        let card = await fixtureGuide(mixed, apps: apps)
        cardModel.providerGuide = card
        card.panelRouteActive = true
        try render(ScrollView { PanelConnectAIRow(guide: card, model: cardModel).padding(16) }.background(COSPalette.panel),
                   width: panelWidth + 32, height: 1180, name: "panel-card", out: out)

        // 3. A row waiting on Sign in (Terminal opened on `claude`).
        let waiting = await fixtureGuide(mixed, apps: apps)
        waiting.signIn(.claude)
        try render(ProviderRowView(guide: waiting, provider: .claude).padding(.horizontal, 16).background(COSPalette.card),
                   width: panelWidth + 32, height: 210, name: "sign-in-waiting", out: out)
        // And after Pass to Claude for Cursor (one pass at a time; the row waits on provider-status, never the chat).
        let passed = await fixtureGuide(mixed, apps: apps)
        passed.pass(.cursor, to: .claude, tag: "abcd1234ef")
        try render(VStack(alignment: .leading) {
            ProviderRowView(guide: passed, provider: .cursor)
            Text(passed.notice ?? "").font(COSType.body(11)).foregroundStyle(COSPalette.accent).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 16).background(COSPalette.card), width: panelWidth + 32, height: 260, name: "pass-waiting", out: out)

        // 4. The collapsed panel rows: one needs you, all connected.
        let rowModel = ControllerModel(startBackgroundWork: false)
        for (name, answer) in [("panel-row-one-needs-you", mixed), ("panel-row-connected", allIn)] {
            let g = await fixtureGuide(answer, apps: apps)
            try render(PanelConnectAIRow(guide: g, model: rowModel).padding(16).background(COSPalette.panel),
                       width: panelWidth + 32, height: 64, name: name, out: out)
        }

        // 5. The session pet introduction (F4).
        let petModel = ControllerModel(startBackgroundWork: false)
        petModel.petIntroVisible = true
        try render(PetIntroLine(model: petModel).padding(16).background(COSPalette.panel),
                   width: panelWidth + 32, height: 130, name: "pet-intro", out: out)

        // 6. The whole panel document: the AI apps row, the pet introduction, and Settings with Show in menu bar only.
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let model = ControllerModel(startBackgroundWork: false)
            model.status = ServerStatus([
                "installed": .bool(true), "serviceLoaded": .bool(true), "running": .bool(true), "managedContract": .bool(true),
                "runtimeState": .string("managedHealthy"), "ownershipVerified": .bool(true),
                "version": .string("6.65.0"), "installedVersion": .string("6.65.0"),
                "claudeCliReady": .bool(false), "codexCliReady": .bool(true), "cursorState": .string("notInstalled"),
            ])
            model.providerGuide = await fixtureGuide(mixed, apps: apps)
            model.petIntroVisible = true
            try renderPanel(model, appearance: appearance, out: out)
        }
        print("Rendered Connect your AI (Welcome x3, panel card, waiting rows, panel rows, pet intro, whole panel) in light and dark")
    }

    static func pump() { for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) } }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top).cosControlTheme())
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.12)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    static func renderPanel(_ model: ControllerModel, appearance: NSAppearance.Name, out: URL) throws {
        let host = NSHostingView(rootView: ControlPanel(model: model, openActivity: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 640)
        defer { window.close() }
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump()
        guard let scroll = scrollView(in: host), let document = scroll.documentView else { throw CocoaError(.fileReadUnknown) }
        pump(); host.layoutSubtreeIfNeeded(); pump()
        document.layoutSubtreeIfNeeded(); document.displayIfNeeded()
        guard let rep = document.bitmapImageRepForCachingDisplay(in: document.bounds) else { throw CocoaError(.fileWriteUnknown) }
        document.cacheDisplay(in: document.bounds, to: rep)
        let word = appearance == .darkAqua ? "dark" : "light"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("panel-whole-\(word).png"))
    }
}
