import AppKit
import SwiftUI

/// Settings hub (Miles, 2026-10-27), run by hand (Tests/run-settings-hub-render.sh <folder>): every category of the hub
/// with fictional fixture data, light and dark, at 1280 and 900 wide (window height, and the full page at 1280), a
/// search, a no-match search, the 760 minimum, and the Activity window around it in the Today and classic frames. For QA
/// against design/settings-hub. Background work is off, so nothing loads from a server. Windows are never ordered in and
/// nothing is clicked, typed or dragged.
@main @MainActor struct SettingsHubRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-hub-render") else { fputs("run through Tests/run-settings-hub-render.sh (a scratch home)\n", stderr); exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        UserDefaults.standard.set(false, forKey: SettingsHub.classicKey)
        // Dictation on, so its seven groups draw. Read by the store's init, which registers no hot key.
        UserDefaults.standard.set(true, forKey: "dictation.enabled")

        // 0.5.387 lane D2 (COS_HUB_RENDER_ONLY=d2): Basic view, the refiles, the server notice and the menu-bar panel's top.
        if ProcessInfo.processInfo.environment["COS_HUB_RENDER_ONLY"] == "d2" {
            UserDefaults.standard.set(SettingsHubView.basic.rawValue, forKey: SettingsHubView.key)
            try render(width: 1280, height: 1400, name: "d2-basic-general") { ControlPanel.hubFixture(model: $0, category: .general) }
            try render(width: 1280, height: 1600, name: "d2-basic-dictation") { ControlPanel.hubFixture(model: $0, category: .dictation) }
            try render(width: 1280, height: 1100, name: "d2-basic-glasses-phone-web") { ControlPanel.hubFixture(model: $0, category: .glasses) }
            // A search hit on a row Basic leaves out, and one in a group the page is not drawing.
            try render(width: 1280, height: 900, name: "d2-search-hidden-by-basic") { ControlPanel.hubFixture(model: $0, category: .general, query: "time format") }
            UserDefaults.standard.set(SettingsHubView.all.rawValue, forKey: SettingsHubView.key)
            try render(width: 1280, height: 2600, name: "d2-all-work-advanced-closed") { withReach($0); return ControlPanel.hubFixture(model: $0, category: .work) }
            try render(width: 1280, height: 3600, name: "d2-all-work-advanced-open") {
                withReach($0); return ControlPanel.hubFixture(model: $0, category: .work, advanced: Set(SettingsHubCatalog.groups(in: .work).map(\.id)))
            }
            try render(width: 1280, height: 1400, name: "d2-all-meetings-cues-advanced-open") {
                ControlPanel.hubFixture(model: $0, category: .meetings, advanced: ["meetings.cues"])
            }
            // The server is not answering: the notice on every page, and search says why a row is missing.
            try render(width: 1280, height: 1100, name: "d2-server-down-work") { serverDown($0); return ControlPanel.hubFixture(model: $0, category: .work) }
            try render(width: 1280, height: 900, name: "d2-server-down-search") { serverDown($0); return ControlPanel.hubFixture(model: $0, category: .work, query: "morning brief") }
            // The menu-bar panel's top: the All settings row, no Reset message count on the Mac-only path.
            try render(width: 390, height: 640, name: "d2-panel-top") { ControlPanel(model: $0, openActivity: { _ in }) }
            print("wrote D2 PNGs to \(out.path)")
            return
        }

        for category in SettingsHubCategory.allCases {
            try render(width: 1280, height: 900, name: "hub-\(category.rawValue)-1280") { ControlPanel.hubFixture(model: $0, category: category) }
            try render(width: 900, height: 760, name: "hub-\(category.rawValue)-900") { ControlPanel.hubFixture(model: $0, category: category) }
            try render(width: 1280, height: 2600, name: "hub-\(category.rawValue)-1280-full") {
                ControlPanel.hubFixture(model: $0, category: category, advanced: Set(SettingsHubCatalog.groups(in: category).map(\.id)))
            }
        }
        try render(width: 1280, height: 900, name: "hub-search-1280") { ControlPanel.hubFixture(model: $0, category: .general, query: "server") }
        try render(width: 1280, height: 900, name: "hub-search-old-label-1280") { ControlPanel.hubFixture(model: $0, category: .general, query: "Run Doctor") }
        try render(width: 900, height: 760, name: "hub-search-none-900") { ControlPanel.hubFixture(model: $0, category: .general, query: "zebra pairing") }
        try render(width: 760, height: 560, name: "hub-meetings-760") { ControlPanel.hubFixture(model: $0, category: .meetings) }
        try render(width: 760, height: 560, name: "hub-search-760") { ControlPanel.hubFixture(model: $0, category: .general, query: "token") }
        // The real window: Today's frame, where the hub's sidebar takes the rail's place, then the classic frame.
        try render(width: 1280, height: 900, name: "window-today-frame-1280") { ActivityWindow.settingsFixture(model: $0) }
        UserDefaults.standard.set(false, forKey: TodayHome.enabledKey)
        try render(width: 900, height: 700, name: "window-classic-frame-900") { ActivityWindow.settingsFixture(model: $0) }
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        // The rollback: Use classic Settings draws the one-page panel again.
        UserDefaults.standard.set(true, forKey: SettingsHub.classicKey)
        try render(width: 1280, height: 900, name: "window-classic-settings-1280") { ActivityWindow.settingsFixture(model: $0) }
        UserDefaults.standard.set(false, forKey: SettingsHub.classicKey)
        print("wrote PNGs to \(out.path)")

        func render<V: View>(width: CGFloat, height: CGFloat, name: String, _ make: (ControllerModel) -> V) throws {
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let view = make(fixtureModel())
                let host = NSHostingView(rootView: view.frame(width: width, height: height))
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

    /// 0.5.387: COS reaching out drawn (Drop it on, and the server's P2 settings answered), for the Work renders.
    static func withReach(_ model: ControllerModel) {
        model.status.dropIt = DropItCapability(protocolVersion: 1, enabled: true, source: "settings")
        let body = #"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":200,"protocol":1,"settings":{"pings":{"on":true,"dailyCap":6,"perSource":2,"gapMinutes":45,"quietStart":"18:00","quietEnd":"06:00","weekendsQuiet":true,"firstBanner":"08:00","sources":{"prep":true,"agent":true,"followups":true,"stale":false,"signals":true}},"followUps":{"on":true,"kinds":{"card":true,"handoff":true,"session":true,"thread":false}},"checkin":{"on":true,"weekday":1,"time":"09:00"},"reminders":{"defaultTime":"09:00","snoozeMinutes":60,"banners":true,"lensPush":true},"banners":{"reminder":true,"resolution":true,"prep":false,"agent":false,"followups":false,"stale":false,"checkin":false},"steer":{"about":"Launch, Pricing","leaveAlone":"Newsletter"}}}}"#
        let answer = try! JSONDecoder().decode(HelperResponse.self, from: Data(body.utf8))
        let reach = DropItP2Store(run: { _, _ in answer }, defaults: UserDefaults(suiteName: "settings-hub-render-reach")!)
        model.dropItP2 = reach
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in await reach.readSettings(); done.signal() }
        var spins = 0
        while done.wait(timeout: .now()) == .timedOut, spins < 250 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); spins += 1 }
    }

    /// 0.5.387: a stopped server (installed, checked, not answering). The feature flags come from /api/health, so a status
    /// read with no answer leaves them off (ServerStatus reads each `?? false`); the fixture clears them the same way.
    static func serverDown(_ model: ControllerModel) {
        var s = model.status
        s.running = false; s.runtimeState = "stopped"
        s.backgroundJobsSupported = false; s.morningBriefSupported = false; s.videoUploadV2Supported = false; s.tasksGate = nil
        s.idleMetalHqSupported = false; s.adaptiveAudioCleanupSupported = false; s.progressiveHqEnabled = nil
        s.threadAttachSupported = false; s.meetingPreviewSupported = false; s.contextBrowserSupported = false
        model.status = s
    }

    /// A healthy managed server on a fictional Mac, new enough for every card.
    static func fixtureModel() -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        model.petEnabled = true
        var s = model.status
        s.installed = true; s.running = true; s.managedContract = true; s.ownershipVerified = true
        s.runtimeState = "managedHealthy"; s.recoveryInstalled = true; s.recoveryLoaded = true; s.safeToRestart = true
        s.version = "6.94.1"; s.installedVersion = "6.94.1"
        s.workDirectory = "/Users/sam/Work"; s.operationsDirectory = "/Users/sam/Work/operations"
        s.meetingLibraryLayout = "direct"; s.meetingLibraryCount = 412
        s.contextBrowserSupported = true; s.memoryAvailable = true; s.memoryCount = 1204; s.threadsAvailable = true; s.threadCount = 38
        s.contextResolvedRoot = "/Users/sam/Work/context"; s.contextFilesDirectory = "/Users/sam/Work/context"
        s.activeJobs = 0; s.activeTranscriptionSessions = 0
        s.backgroundJobsSupported = true; s.backgroundJobsEnabled = true
        s.meetingPreviewSupported = true; s.meetingPreviewEnabled = true
        s.morningBriefSupported = true; s.morningBriefEnabled = true; s.morningBriefTime = "07:00"; s.morningBriefTimezone = "America/Chicago"
        s.tasksGate = "ok"
        s.threadAttachSupported = true; s.threadAttachEnabled = true; s.threadAttachProviders = ["Claude", "Codex"]
        s.pairingSupported = true; s.claudeSessionsEnabled = true
        s.videoUploadV2Supported = true; s.videoUploadV2Enabled = false
        s.idleMetalHqSupported = true; s.idleMetalHqEnabled = false
        s.adaptiveAudioCleanupSupported = true; s.adaptiveAudioCleanupEnabled = false
        s.whisperReady = true
        s.transcriptionRequestedTier = "balanced"; s.transcriptionEffectiveTier = "balanced"
        s.livePreviewModel = "small.en"; s.livePreviewReady = true; s.liveCommitModel = "large-v3-turbo"; s.hqPolishModel = "large-v3"; s.hqPolishReady = true
        s.cursorReady = true; s.cursorState = "ready"; s.claudeCliReady = true; s.codexCliReady = true
        s.earlyMeetingSyncEnabled = true
        model.status = s
        return model
    }
}
