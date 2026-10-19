import AppKit
import SwiftUI

// K1 P10, by hand: the key-lane views drawn off screen to PNGs for a person to look at (Tests/run-key-lanes.sh render
// <dir>). No window is ordered in, the process can never become active, no helper or server runs: the store reads
// fixture answers. Light and dark.

@MainActor func pump(_ rounds: Int = 14) { for _ in 0..<rounds { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) } }

@MainActor func draw<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws {
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top).background(COSPalette.panel))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump(4)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
        window.close()
    }
}

func answer(_ json: String) -> HelperResponse {
    try! JSONDecoder().decode(HelperResponse.self, from: Data(#"{"ok":true,"message":"x","details":\#(json)}"#.utf8))
}

@MainActor func healthy(_ version: String) -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus(["installed": .bool(true), "running": .bool(true), "runtimeState": .string("managedHealthy"),
                                 "version": .string(version), "claudeCliReady": .bool(true)])
    return model
}

@main @MainActor struct KeyLanesRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-key-lanes") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "cos.key-lanes-render.\(UUID().uuidString)")!

        let off = KeyLanesStore(defaults: defaults)
        try draw(KeyLanesSettingsRow(model: healthy("6.80.0"), store: off).padding(16), width: 390, height: 160, name: "row-off-6.80.0", out: out)

        let on = KeyLanesStore(defaults: defaults)
        let onStatus = #"{"transport":"answered","httpStatus":200,"enabled":true,"active":true,"keys":[{"ref":"key_0123456789ab","kind":"openrouter","last4":"9f3c","capUsd":1,"spentTodayUsd":0.12,"breaker":{"open":false,"failures":0}}],"profiles":[{"id":"k-0123456789ab","label":"Sonnet 5.5","keyRef":"key_0123456789ab","engine":"claude","model":"anthropic/claude-sonnet-5.5","enabled":true}],"keyedSessionIds":[]}"#
        let catalog = #"{"transport":"answered","httpStatus":200,"curated":[{"id":"anthropic/claude-sonnet-5.5","name":"Claude Sonnet 5.5","inUsdPerM":2,"outUsdPerM":10,"role":"default"},{"id":"anthropic/claude-haiku-5.5","name":"Claude Haiku 5.5","inUsdPerM":0.1,"outUsdPerM":0.5,"role":"cheaper"}]}"#
        let run: KeyLanesStore.Run = { args, _ in answer(args.count > 1 && args[1] == "catalog" ? catalog : onStatus) }
        await on.refresh(run: run); await on.loadCatalog(run: run)
        try draw(KeyLanesSettingsRow(model: healthy("6.80.0"), store: on).padding(16), width: 390, height: 640, name: "row-on-key", out: out)

        let fresh = KeyLanesStore(defaults: UserDefaults(suiteName: "cos.key-lanes-render.\(UUID().uuidString)")!)
        let firstRun = ControllerModel(startBackgroundWork: false)
        firstRun.status = ServerStatus(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent")])
        fresh.observe(firstRun.status)
        try draw(KeyLanesSetupStep(model: healthy("6.80.0"), store: fresh).padding(32), width: 540, height: 320, name: "setup-step-new-install", out: out)
        print("key lanes render: wrote \(out.path)")
    }
}
