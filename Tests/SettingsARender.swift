import AppKit
import SwiftUI

/// Settings Release A, run by hand (Tests/run-settings-a-render.sh <folder>): the pages the release changed, light and dark,
/// with fictional fixture data. The Work page's restart rows in four states (matching the server; a choice not applied yet;
/// that choice while work runs; a failed Apply), General with Today home off and on, a search that finds an option whose switch
/// is off, Dictation with AI polish off and on, Meetings with Live cues limits (a typed count, menus, an off-list saved value),
/// AI and accounts with a key's daily cap, and System with the Stop, Roll back, Repair and Quit dialogs and the Versions line.
/// A stand-in helper answers `live-cues-settings` from a file this harness writes; no server is reached. Windows are never
/// ordered in and nothing is clicked, typed or dragged. No sound plays.
@main @MainActor struct SettingsARender {
    static var written = 0

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-settings-a-render") else { fputs("run through Tests/run-settings-a-render.sh (a scratch home)\n", stderr); exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        UserDefaults.standard.set(false, forKey: SettingsHub.classicKey)
        UserDefaults.standard.set(true, forKey: "dictation.enabled")

        let stand = FileManager.default.temporaryDirectory.appendingPathComponent("cos-settings-a-stand-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stand, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stand) }
        let helper = stand.appendingPathComponent("helper")
        try """
        #!/bin/sh
        D="$(cd "$(dirname "$0")" && pwd)"
        f="$D/$1.json"
        if [ -f "$f" ]; then cat "$f"; printf '\\n'; exit 0; fi
        printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\\n' "$1"
        exit 1

        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        // ── Work: the restart rows.
        try render(out, "work-restart-match", width: 1280, height: 1500) { ControlPanel.hubFixture(model: $0, category: .work) } model: { fixtureModel(helper) }
        try render(out, "work-restart-not-applied", width: 1280, height: 1500) { ControlPanel.hubFixture(model: $0, category: .work) } model: {
            let m = fixtureModel(helper); var s = m.status; s.claudeSessionsEnabled = nil; s.threadAttachEnabled = nil; m.status = s; return m
        }
        try render(out, "work-restart-waits-for-work", width: 1280, height: 1500) { ControlPanel.hubFixture(model: $0, category: .work) } model: {
            let m = fixtureModel(helper); var s = m.status; s.claudeSessionsEnabled = nil; s.threadAttachEnabled = nil; s.activeJobs = 2; m.status = s; return m
        }
        try render(out, "work-restart-failed", width: 1280, height: 1500) { ControlPanel.hubFixture(model: $0, category: .work) } model: {
            let m = fixtureModel(helper)
            m.restartApplyFailure = ControllerModel.RestartApplyFailure(command: "set-background-jobs", message: "Timed out draining 1 running job. Nothing was changed.")
            return m
        }
        // ── General: Today home off and on, and a search that finds an option whose switch is off.
        UserDefaults.standard.set(false, forKey: TodayHome.enabledKey)
        try render(out, "general-today-off", width: 1280, height: 1100) { ControlPanel.hubFixture(model: $0, category: .general) } model: { fixtureModel(helper) }
        try render(out, "search-hidden-option-today-off", width: 1280, height: 700) { ControlPanel.hubFixture(model: $0, category: .general, query: "quiet hours") } model: { fixtureModel(helper) }
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        try render(out, "general-today-on", width: 1280, height: 1100) { ControlPanel.hubFixture(model: $0, category: .general) } model: { fixtureModel(helper) }
        // ── Dictation: AI polish off, then on.
        UserDefaults.standard.set("off", forKey: DictationPolishModel.defaultsKey)
        try render(out, "dictation-polish-off", width: 1280, height: 2600) { ControlPanel.hubFixture(model: $0, category: .dictation) } model: { fixtureModel(helper) }
        UserDefaults.standard.set("sonnet", forKey: DictationPolishModel.defaultsKey)
        try render(out, "dictation-polish-on", width: 1280, height: 2600) { ControlPanel.hubFixture(model: $0, category: .dictation) } model: { fixtureModel(helper) }
        UserDefaults.standard.set("off", forKey: DictationPolishModel.defaultsKey)
        // ── Meetings: Live cues limits. 18 of 1 to 50 cues; a gap off the ladder (100 s); a saved daily limit above the server's 500.
        func limits(cues: Int, gap: Int, daily: Int) -> String {
            #"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":200,"enabled":true,"source":"setting","capability":{"available":true,"decisionProvider":"subq","protocol":2,"model":"claude-sonnet-5-5","memory":"notes"},"v":2,"limits":{"gate":{"value":0.8,"source":"default","locked":false,"min":0.5,"max":0.95,"default":0.8},"maxCuesPerMeeting":{"value":\#(cues),"source":"setting","locked":false,"min":1,"max":50,"default":25},"cooldownSeconds":{"value":\#(gap),"source":"setting","locked":false,"min":20,"max":900,"default":45},"dailyWriterCalls":{"value":\#(daily),"source":"setting","locked":false,"min":1,"max":500,"default":150}},"writerCallsPerMeeting":50,"today":{"day":"2026-11-03","writerCalls":12,"writerTokensIn":41200,"writerTokensOut":2900,"cues":7,"jevTokens":9100}}}"#
        }
        try limits(cues: 18, gap: 100, daily: 750).write(to: stand.appendingPathComponent("live-cues-settings.json"), atomically: true, encoding: .utf8)
        try render(out, "meetings-live-cues-limits", width: 1280, height: 2200) { ControlPanel.hubFixture(model: $0, category: .meetings) } model: { fixtureModel(helper) }
        // ── AI and accounts: a key whose cap ($3.50) is not one of the presets.
        let keysStatus = #"{"transport":"answered","httpStatus":200,"enabled":true,"active":true,"keys":[{"ref":"key_0123456789ab","kind":"openrouter","last4":"9f3c","capUsd":3.5,"spentTodayUsd":0.12,"breaker":{"open":false,"failures":0}}],"profiles":[{"id":"k-0123456789ab","label":"Sonnet 5.5","keyRef":"key_0123456789ab","engine":"claude","model":"anthropic/claude-sonnet-5.5","enabled":true}],"keyedSessionIds":[]}"#
        let keysCatalog = #"{"transport":"answered","httpStatus":200,"curated":[{"id":"anthropic/claude-sonnet-5.5","name":"Claude Sonnet 5.5","inUsdPerM":2,"outUsdPerM":10,"role":"default"},{"id":"anthropic/claude-haiku-5.5","name":"Claude Haiku 5.5","inUsdPerM":0.1,"outUsdPerM":0.5,"role":"cheaper"}]}"#
        let run: KeyLanesStore.Run = { args, _ in
            try! JSONDecoder().decode(HelperResponse.self, from: Data(#"{"ok":true,"message":"x","details":\#(args.count > 1 && args[1] == "catalog" ? keysCatalog : keysStatus)}"#.utf8))
        }
        await KeyLanesStore.shared.refresh(run: run)
        await KeyLanesStore.shared.loadCatalog(run: run)
        try render(out, "ai-key-daily-cap", width: 1280, height: 2000) { ControlPanel.hubFixture(model: $0, category: .ai) } model: { fixtureModel(helper) }
        // ── System: the four dialogs, the Versions line.
        try render(out, "system-versions", width: 1280, height: 1300) { ControlPanel.hubFixture(model: $0, category: .system) } model: { fixtureModel(helper) }
        for (name, confirm) in [("stop", ServerConfirm.stop), ("rollback", .rollback), ("repair", .repair), ("quit", .quit)] {
            try render(out, "system-confirm-\(name)", width: 1280, height: 760) { ControlPanel.hubFixture(model: $0, category: .system, serverConfirm: confirm) } model: { fixtureModel(helper) }
        }
        print("wrote \(written) PNGs to \(out.path)")
    }

    static func render<V: View>(_ out: URL, _ name: String, width: CGFloat, height: CGFloat, _ make: (ControllerModel) -> V, model makeModel: () -> ControllerModel) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let view = make(makeModel())
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            for _ in 0..<14 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
            written += 1
        }
    }

    /// A healthy managed server on a fictional Mac, new enough for every card (as Tests/SettingsHubRender.swift builds it).
    static func fixtureModel(_ helper: URL) -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
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
