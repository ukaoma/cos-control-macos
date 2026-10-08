import AppKit
import SwiftUI

// Static renders of the permission guide, light and dark: the Welcome step, the panel row in each state, the guide
// card, the floating bar in each phase and the repair. Nothing is ordered on screen, clicked or typed; the guide reads
// fixture facts, never macOS.

@MainActor
func fixtureProbes(_ facts: PermissionFacts, stale: [StaleBuild] = []) -> PermissionProbes {
    var probes = PermissionProbes.inert
    probes.accessibilityTrusted = { facts.accessibilityTrusted }
    probes.notifications = { facts.notifications }
    probes.loginItem = { facts.loginItem }
    probes.launchJobs = { facts.jobs }
    let installed = Set(facts.automation.map(\.target.bundleID))
    let answers = Dictionary(uniqueKeysWithValues: facts.automation.map { ($0.target.bundleID, $0.fact) })
    probes.installedApp = { installed.contains($0) ? "/Applications/X.app" : nil }
    probes.automation = { id, _ in answers[id] ?? .notRunning }
    probes.calendarAppPath = { facts.calendarAppPath }
    probes.calendar = { facts.calendar }
    probes.staleBuilds = { _ in stale }
    probes.resetAccessibility = { _ in true }
    return probes
}

@MainActor
func fixtureGuide(_ facts: PermissionFacts, stale: [StaleBuild] = [], build: Int = 300, lastTrusted: Int? = nil) async -> PermissionGuide {
    let name = "cos.permission-guide-render.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    if let lastTrusted { defaults.set(lastTrusted, forKey: PermissionGuide.lastTrustedBuildKey) }
    let guide = PermissionGuide(probes: fixtureProbes(facts, stale: stale), appName: "COS Control",
                                appPath: "/Applications/COS Control.app", bundleID: "com.gotcos.control",
                                currentBuild: build, defaults: defaults)
    await guide.refresh()
    return guide
}

func job(_ label: String, _ interpreter: String, running: Bool = false, runs: Int? = nil, exit: Int? = nil) -> LaunchJob {
    var j = LaunchJob(label: label, interpreter: interpreter, readsProtectedFolder: true)
    j.running = running; j.runs = runs; j.lastExit = exit
    return j
}

let python = "/Users/miles/Documents/COS/operations/scripts/venv/bin/python"

@MainActor
func pipelineFacts(stopped: Bool) -> PermissionFacts {
    var facts = PermissionFacts()
    facts.accessibilityWanted = true
    facts.notifications = .notDetermined
    facts.loginItem = .enabled
    facts.jobs = [job("com.cos.meeting-sync", python, runs: 3, exit: stopped ? 78 : 0),
                  job("com.cos.daily-loop-morning", python, runs: 2, exit: stopped ? 78 : 0),
                  job("com.cos.glasses-server", "/opt/homebrew/bin/node", running: true, runs: 1)]
    facts.automation = [(AutomationTarget(bundleID: "com.anthropic.claudefordesktop", name: "Claude"), .allowed),
                        (AutomationTarget(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"), .notAsked)]
    facts.calendarAppPath = "/Users/miles/Documents/COS/operations/scripts/bin/CalendarFetch.app"
    facts.calendar = .allowed
    return facts
}

@main @MainActor struct PermissionGuideRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // 1. The Welcome window's Permissions step (a fresh Mac without the COS pipeline).
        let model = ControllerModel(startBackgroundWork: false)
        model.status = ServerStatus(["runtimeState": .string("managedHealthy"), "launchAgentKind": .string("managed"), "setupProviderInstalled": .bool(true)])
        model.status.running = true; model.status.installed = true; model.status.ownershipVerified = true
        var fresh = PermissionFacts()
        fresh.notifications = .notDetermined
        model.permissionGuide = await fixtureGuide(fresh)
        try render(ControlSetupView(model: model), width: 540, height: 720, name: "onboarding-step", out: out)

        // 2. The panel row: all set, one needs you, two need you.
        var allSet = PermissionFacts()
        allSet.accessibilityTrusted = true; allSet.notifications = .allowed(alertsOn: true); allSet.loginItem = .enabled
        let panelWidth: CGFloat = 358
        try render(PanelPermissionsRow(guide: await fixtureGuide(allSet)).padding(16).background(COSPalette.panel), width: panelWidth + 32, height: 64, name: "panel-row-all-set", out: out)
        var one = allSet; one.notifications = .denied
        try render(PanelPermissionsRow(guide: await fixtureGuide(one)).padding(16).background(COSPalette.panel), width: panelWidth + 32, height: 64, name: "panel-row-one-needs-you", out: out)
        let two = await fixtureGuide(pipelineFacts(stopped: true))
        try render(PanelPermissionsRow(guide: two).padding(16).background(COSPalette.panel), width: panelWidth + 32, height: 64, name: "panel-row-two-need-you", out: out)

        // 3. The guide card in the panel, opened just in time by a stopped background job.
        let card = await fixtureGuide(pipelineFacts(stopped: true))
        card.need(.backgroundJobs, for: "Background jobs", interactive: false)
        try render(ScrollView { PermissionGuideCard(guide: card).padding(16) }.background(COSPalette.panel),
                   width: panelWidth + 32, height: 1180, name: "guide-card", out: out)

        // 4. The floating bar: waiting with the feature that asked, Allowed, Having trouble?, Full Disk Access.
        let app = PermissionDragSource(path: "/Applications/COS Control.app", name: "COS Control")
        let ax = PermissionDragRequest(rowID: "accessibility", pane: .accessibility, source: app, feature: "Jump to your session")
        let appURL = URL(fileURLWithPath: app.path)
        for (name, phase) in [("bar-waiting", HelperBarStep.Phase.waiting), ("bar-allowed", .allowed), ("bar-trouble", .trouble)] {
            try render(PermissionHelperBarContent(state: PermissionHelperBarState(request: ax, phase: phase, sourceURL: appURL)).padding(12),
                       width: 520, height: name == "bar-trouble" ? 250 : 190, name: name, out: out)
        }
        let fda = PermissionDragRequest(rowID: "backgroundJobs:" + python, pane: .fullDiskAccess,
                                        source: PermissionDragSource(path: python, name: "COS background helper (Python)"), feature: "Background jobs")
        try render(PermissionHelperBarContent(state: PermissionHelperBarState(
                    request: fda, phase: .waiting, sourceURL: URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
                    checkMessage: "Still stopped. Make sure the switch beside it is on, then check again.")).padding(12),
                   width: 520, height: 250, name: "bar-full-disk-access", out: out)

        // 5. Repair: a re-signed update (Reset and add again) and the old test builds, one already reset.
        var stale = PermissionFacts(); stale.notifications = .allowed(alertsOn: true); stale.loginItem = .enabled
        let repair = await fixtureGuide(stale, stale: [StaleBuild(bundleID: "com.gotcos.COSControl.FoundationLab", copies: 1),
                                                         StaleBuild(bundleID: "com.gotcos.COSControl.WorkPreview019", copies: 2)],
                                        build: 301, lastTrusted: 300)
        await repair.findStaleBuilds()
        await repair.resetStaleBuild("com.gotcos.COSControl.FoundationLab")
        repair.openInPanel(focus: "accessibility")
        try render(ScrollView { PermissionGuideCard(guide: repair).padding(16) }.background(COSPalette.panel),
                   width: panelWidth + 32, height: 720, name: "repair", out: out)
        print("Rendered the permission guide (onboarding step, panel rows, card, bar, repair) in light and dark")
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
