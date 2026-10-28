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
