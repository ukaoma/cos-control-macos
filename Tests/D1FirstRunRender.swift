import AppKit
import SwiftUI

// Lane D1 (0.5.387): offscreen renders of the first-run states this lane changed, light and dark, from fixtures. No window
// is shown, no helper runs, nothing opens Terminal, a link or System Settings, nothing reads TCC. Compiled with every
// Sources file by Tests/run-d1-renders.sh. Fixture JSON shape is ProviderConnectRender's.

let d1Codex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

func d1Row(_ provider: String, installed: Bool = true, path: String? = nil, signIn: String = "signedIn", version: String? = nil,
           daemon: String? = nil, models: [String]? = nil) -> String {
    let m = models.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
    return #"{"provider":"\#(provider)","installed":\#(installed),"binaryPath":\#(path.map { "\"\($0)\"" } ?? "null"),"version":\#(version.map { "\"\($0)\"" } ?? "null"),"signIn":"\#(signIn)","candidates":[],"detail":null,"daemon":\#(daemon.map { "\"\($0)\"" } ?? "null"),"models":\#(m),"host":null}"#
}
func d1Data(_ rows: String...) -> Data { Data(#"{"providers":[\#(rows.joined(separator: ","))],"checkedAt":"2026-11-09T20:00:00Z"}"#.utf8) }

let d1Missing = d1Data(d1Row("claude", installed: false, signIn: "unknown"), d1Row("codex", installed: false, signIn: "unknown"),
                       d1Row("cursor", installed: false, signIn: "unknown"), d1Row("ollama", installed: false, signIn: "notNeeded", daemon: "down", models: []))
let d1ClaudeFound = d1Data(d1Row("claude", path: "/Users/you/.local/bin/claude", signIn: "signInRequired", version: "2.1.293"),
                           d1Row("codex", installed: false, signIn: "unknown"), d1Row("cursor", installed: false, signIn: "unknown"),
                           d1Row("ollama", installed: false, signIn: "notNeeded", daemon: "down", models: []))
let d1SignedIn = d1Data(d1Row("claude", path: "/Users/you/.local/bin/claude", version: "2.1.293"), d1Row("codex", installed: false, signIn: "unknown"),
                        d1Row("cursor", installed: false, signIn: "unknown"), d1Row("ollama", installed: false, signIn: "notNeeded", daemon: "down", models: []))

@MainActor func d1Guide(_ answer: Data, terminalWorks: Bool = true) async -> ProviderGuide {
    let defaults = UserDefaults(suiteName: "cos.d1-render.\(UUID().uuidString)")!
    let guide = ProviderGuide(home: "/Users/you", defaults: defaults) { _ in answer }
    guide.appInstalled = { _ in false }
    guide.runInTerminal = { _ in terminalWorks }
    guide.openTerminalApp = { true }
    guide.openURL = { _ in true }
    guide.makeFolder = { _ in true }
    guide.refreshApps()
    await guide.refresh()
    return guide
}

@MainActor func d1FirstRun(_ guide: ProviderGuide, installed: Bool, connect: Bool) -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent"), "setupProviderInstalled": .bool(installed)])
    model.providerGuide = guide
    if connect && !model.setupGuide.journeyStarted { model.setupGuide.beginJourney() }
    return model
}

@main @MainActor struct D1FirstRunRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Dictation on, neither start shortcut recorded, before MacDictationStore.shared is first read (ControllerModel's init reads it).
        let d = UserDefaults.standard
        d.set(true, forKey: "dictation.enabled")
        for prefix in ["dictation.hold", "dictation.toggle"] { d.set(false, forKey: prefix + ".enabled") }

        // 1. Welcome, the first step (its line changed).
        try render(ControlSetupView(model: d1FirstRun(await d1Guide(d1Missing), installed: false, connect: false)),
                   width: 560, height: 760, name: "01-welcome", out: out)
        // 2. Connect your AI: no AI app found, the Install Claude Code button.
        try render(ControlSetupView(model: d1FirstRun(await d1Guide(d1Missing), installed: false, connect: true)),
                   width: 560, height: 1120, name: "02-connect-no-ai-install-button", out: out)
        // 3. Install clicked, Terminal opened: Installing.
        let installing = await d1Guide(d1Missing)
        await installing.install(.claude)
        try render(ControlSetupView(model: d1FirstRun(installing, installed: false, connect: true)),
                   width: 560, height: 1120, name: "03-connect-installing", out: out)
        // 4. Automation denied: the command on the clipboard, Terminal opened, the manual path.
        let denied = await d1Guide(d1Missing, terminalWorks: false)
        await denied.install(.claude)
        try render(ControlSetupView(model: d1FirstRun(denied, installed: false, connect: true)),
                   width: 560, height: 1180, name: "04-connect-automation-denied", out: out)
        // 5. AI app found, not signed in: the Sign in line.
        try render(ControlSetupView(model: d1FirstRun(await d1Guide(d1ClaudeFound), installed: true, connect: true)),
                   width: 560, height: 1060, name: "05-connect-ai-found-sign-in", out: out)
        // 6. AI app found and signed in: the Get started line.
        try render(ControlSetupView(model: d1FirstRun(await d1Guide(d1SignedIn), installed: true, connect: true)),
                   width: 560, height: 1000, name: "06-connect-signed-in-get-started", out: out)

        // 6b. 0.5.388 (C1): setup stopped at the proof, plain words first, the helper's text below.
        let failedModel = d1FirstRun(await d1Guide(d1ClaudeFound), installed: true, connect: true)
        failedModel.error = "Update failed. Control restored the previous version. Original error: Managed server transactional verification failed: no AI provider proved a real query (Claude skipped: not signed in)."
        try render(ControlSetupView(model: failedModel), width: 560, height: 1160, name: "11-connect-setup-stopped-proof", out: out)

        // 7. Permissions (Welcome's access step). The step re-reads its facts on appear, so the facts come from fixture
        // probes the guide's own read() calls: nothing asked yet, then a no while the feature is on, unreadable, add only.
        func permissionGuide(_ probes: PermissionProbes) -> PermissionGuide {
            PermissionGuide(probes: probes, appName: "COS Control", appPath: "/Applications/COS Control.app",
                            bundleID: "com.gotcos.control", currentBuild: 441,
                            defaults: UserDefaults(suiteName: "cos.d1-render.perm.\(UUID().uuidString)")!)
        }
        var notAsked = PermissionProbes.inert
        notAsked.microphone = { .notAsked }; notAsked.systemAudio = { .notAsked }; notAsked.calendars = { .notAsked }
        let fresh = permissionGuide(notAsked)
        await fresh.refresh()
        try render(OnboardingPermissionsStep(guide: fresh) {}.padding(28).background(COSPalette.panel),
                   width: 560, height: 1100, name: "07-permissions-not-asked", out: out)
        var denials = PermissionProbes.inert
        denials.accessibilityTrusted = { true }; denials.notifications = { .allowed(alertsOn: true) }; denials.loginItem = { .enabled }
        denials.microphone = { .denied }; denials.microphoneWanted = { true }
        denials.systemAudio = { nil }
        denials.calendars = { .writeOnly }; denials.calendarsWanted = { true }
        let denied2 = permissionGuide(denials)
        await denied2.refresh()
        try render(OnboardingPermissionsStep(guide: denied2) {}.padding(28).background(COSPalette.panel),
                   width: 560, height: 1100, name: "08-permissions-denied-unreadable-add-only", out: out)

        // 9. Dictation on with no shortcut: the whole settings view (panel width) and the Dictation section alone (hub card).
        let dictModel = ControllerModel(startBackgroundWork: false)
        try render(ScrollView { MacDictationSettings(store: dictModel.dictation, activityShortcut: nil).padding(16) }.background(COSPalette.panel),
                   width: 390, height: 900, name: "09-dictation-no-shortcut-panel", out: out)
        try render(MacDictationSettings(store: dictModel.dictation, activityShortcut: nil, section: .dictation).padding(20).background(COSPalette.card),
                   width: 620, height: 260, name: "10-dictation-no-shortcut-section", out: out)
        print("D1 renders: \(try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".png") }.count) PNGs")
    }

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
}
