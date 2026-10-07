import AppKit
import SwiftUI

// Static rendering only. No visible windows, events, server or AI calls.
@main @MainActor struct OnboardingRender {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for state in ["welcome", "provider", "preparing", "retry", "ready"] {
            let model = ControllerModel(startBackgroundWork: false)
            model.status = ServerStatus(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent"), "setupProviderInstalled": .bool(state != "provider")])
            if state == "preparing" { model.busy = true; model.operationProgress = "Downloading server 6.64.0…" }
            if state == "retry" { model.error = "The download could not finish. Check your internet connection and try again." }
            if state == "ready" { model.status.running = true; model.status.installed = true; model.status.ownershipVerified = true; model.status.runtimeState = "managedHealthy" }
            try render(ControlSetupView(model: model), width: 540, height: 540, name: state, out: out)
        }
        print("Rendered five onboarding states in light and dark")
    }
    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            // The cards paint in over about a second; let them land.
            for _ in 0..<14 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
