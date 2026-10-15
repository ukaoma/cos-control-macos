import AppKit
import SwiftUI

// Static rendering only. No visible windows, events, server or AI calls.
@main @MainActor struct OnboardingRender {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let states = ["welcome-mac", "welcome-glasses", "provider", "downloading", "preparing", "stopped", "retry", "permissions", "glasses", "ready", "existing-guide"]
        for state in states {
            let model = ControllerModel(startBackgroundWork: false)
            let defaults = UserDefaults(suiteName: "cos.onboarding-render." + UUID().uuidString)!
            model.setupGuide = SetupGuideState(defaults: defaults)
            let providers: [[String: Any]] = AIProvider.allCases.map { provider in
                let installed = provider == .claude && state != "provider"
                return ["provider": provider.rawValue, "installed": installed,
                        "signIn": installed ? "signedIn" : "unknown", "candidates": [],
                        "version": installed ? "1.0.0" : NSNull(), "models": []]
            }
            let providerData = try JSONSerialization.data(withJSONObject: ["providers": providers, "checkedAt": "2026-10-14T20:00:00Z"])
            model.providerGuide = ProviderGuide(home: NSHomeDirectory(), defaults: defaults) { _ in providerData }
            model.jevStatus = JevStatus(details: ["available": .bool(false)])
            model.status = ServerStatus(["runtimeState": .string("notInstalled"), "launchAgentKind": .string("absent"), "setupProviderInstalled": .bool(state != "provider")])
            if !state.hasPrefix("welcome") && state != "existing-guide" { model.setupGuide.beginJourney() }
            if state == "welcome-glasses" || state == "glasses" { model.setupGuide.chooseDevicePath(.glasses) }
            if state == "downloading" || state == "preparing" { model.busy = true; model.operationProgress = "Downloading server components…" }
            if state == "preparing" || state == "stopped" {
                model.status.installed = true; model.status.runtimeState = "stopped"
            }
            if state == "retry" {
                model.status.runtimeState = "interrupted"
                model.status.transactionPending = true
                model.error = "The download could not finish. Check your internet connection and repair setup to continue."
            }
            if ["permissions", "glasses", "ready", "existing-guide"].contains(state) {
                model.status.running = true; model.status.installed = true
                model.status.ownershipVerified = true; model.status.runtimeState = "managedHealthy"
            }
            model.permissionGuide.onboardingDone = state != "permissions"
            let expected: SetupJourneyStage = switch state {
            case "welcome-mac", "welcome-glasses": .welcome
            case "provider", "downloading": .connect
            case "preparing", "stopped", "retry": .preparing
            case "permissions": .permissions
            case "glasses": .glasses
            case "ready": .ready
            default: .guide
            }
            let actual = SetupJourneyStage.resolve(needsFirstRun: model.status.needsFirstRun,
                ready: model.status.running && model.status.ownershipVerified && model.status.runtimeState == "managedHealthy" && !model.status.transactionPending && !model.busy,
                started: model.setupGuide.journeyStarted, finished: model.setupGuide.journeyFinished,
                permissionsDone: model.permissionGuide.onboardingDone, path: model.setupGuide.devicePath,
                glassesHandled: model.setupGuide.glassesHandled)
            precondition(actual == expected, "Fixture does not exercise its named stage: " + state)
            for width in [CGFloat(390), CGFloat(560)] {
                try render(ControlSetupView(model: model), width: width, height: 760, name: "\(state)-\(Int(width))", out: out)
            }
        }
        print("Rendered eleven onboarding states at 390 and 560 points in light and dark")
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
