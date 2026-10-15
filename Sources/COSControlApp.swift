import SwiftUI

@main
struct COSControlApp: App {
    /// F3: the Dock icon and its click (ProviderConnectViews.swift).
    @NSApplicationDelegateAdaptor(COSAppDelegate.self) private var appDelegate
    @StateObject private var model: ControllerModel
    @StateObject private var activityWindow: ActivityWindowPresenter
    @StateObject private var sessionPet: SessionPetPresenter
    @StateObject private var setupWindow: SetupWindowPresenter
    @StateObject private var settingsWindow: SettingsWindowPresenter

    init() {
        ControlInstance.shared.claimOrExit()
        let model = ControllerModel()
        let activityWindow = ActivityWindowPresenter()
        let sessionPet = SessionPetPresenter()
        let setupWindow = SetupWindowPresenter()
        let settingsWindow = SettingsWindowPresenter()
        sessionPet.bindIfNeeded(model: model) { section in
            activityWindow.show(model: model, section: section)
        }
        // The Activity hotkey: registered from the saved combo at launch and
        // routed to the same presenter the chips use.
        HotKeyCenter.shared.onFire = { activityWindow.show(model: model, section: nil) }
        HotKeyCenter.shared.register(model.activityHotKey)
        model.dictation.bridge = { [weak model] audio in
            guard let model else { throw HelperClientError.commandFailed("COS Control is closing.") }
            return try await model.runHelper(["mac-dictation"], timeout: 40, stdinData: audio)
        }
        model.dictation.petFrame = { [weak sessionPet] in sessionPet?.visibleFrame }
        model.dictation.registerHotKeys()
        model.macRecording.openLiveMeeting = { [weak model] id in
            model?.openActivity?(.meetings)
            model?.openLiveTranscript(id)
        }
        model.openActivity = { section in activityWindow.show(model: model, section: section) }
        model.openSetup = { setupWindow.show(model: model) }
        // 2026-10-09: Update (the banner) and the header's refresh button (when it finds one) open What's New, one window at a
        // time. The closure keeps the presenter alive for the life of the app.
        let whatsNewWindow = WhatsNewWindowPresenter()
        model.showWhatsNew = { whatsNewWindow.show(model: model) }
        // The setup guide and Settings, from the Dock menu, Help, the panel and the pet (Miles 2026-10-08 10:52).
        model.showSetupGuide = { setupWindow.show(model: model) }
        // Settings…: the open panel scrolls, a visible menu-bar icon opens the panel, anything else (a hidden icon,
        // the notch, menu bar only) gets the real Settings window.
        model.showSettings = {
            SettingsOpener.open(model: model, window: settingsWindow) { section in activityWindow.show(model: model, section: section) }
        }
        COSAppDelegate.panelVisible = { model.panelVisible }
        COSAppDelegate.onOpenActivity = { activityWindow.show(model: model, section: nil) }
        COSAppDelegate.onSetupGuide = { setupWindow.show(model: model) }
        COSAppDelegate.onSettings = { model.showSettings?() }
        COSAppDelegate.recordingAvailable = { model.recordingCount > 0 && model.liveTranscriptEnabled }
        COSAppDelegate.onOpenRecording = { model.showRecordingTranscript() }
        COSAppDelegate.onTerminate = { model.dictation.cancel(); model.meetingAsk.flushAll() }
        MacRecordingTermination.prepare = { await model.macRecording.prepareToQuit() }
        model.recordingStatusChanged = { [weak model] _ in NSApp.dockTile.badgeLabel = model?.recordingDockBadge }
        // A Dock click opens Welcome while COS is not set up, else Activity.
        COSAppDelegate.onReopen = {
            if model.recordingCount > 0, model.liveTranscriptEnabled {
                model.showRecordingTranscript()
                return
            }
            switch DockPresence.reopenTarget(needsFirstRun: model.status.needsFirstRun, activityAvailable: model.openActivity != nil,
                                             statusRead: model.statusReadOnce) {
            case .setup: setupWindow.show(model: model)
            case .activity: activityWindow.show(model: model, section: nil)
            }
        }
        _model = StateObject(wrappedValue: model)
        _activityWindow = StateObject(wrappedValue: activityWindow)
        _sessionPet = StateObject(wrappedValue: sessionPet)
        _setupWindow = StateObject(wrappedValue: setupWindow)
        _settingsWindow = StateObject(wrappedValue: settingsWindow)
        // Reproducible native QA without competing for the live menu-bar
        // hotkey. This opens the same presenter and WebView as the UI chips.
        let environment = ProcessInfo.processInfo.environment
        if environment["COS_CONTROL_TEST_HOME"]?.hasPrefix("/tmp/") == true,
           environment["COS_CONTROL_TEST_OPEN_MEMORY"] == "1" {
            DispatchQueue.main.async {
                activityWindow.show(model: model, section: .memories)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            // Work opens from the panel's Activity chips like every other view (they come from
            // ActivitySection.allCases). No separate, unstyled button above the panel (Miles, 2026-09-28).
            VStack(spacing: 0) {
                if model.macRecordingActive {
                    HStack {
                        Label("Mac recording", systemImage: "record.circle.fill").foregroundStyle(COSPalette.danger)
                        Spacer()
                        Button("View live transcript") { model.showRecordingTranscript() }.buttonStyle(COSQuietButtonStyle())
                        Button("Stop and save") { Task { await model.macRecording.stop() } }.buttonStyle(COSQuietButtonStyle())
                    }.font(COSType.body(12)).padding(12)
                }
                ControlPanel(model: model) { section in
                    activityWindow.show(model: model, section: section)
                }
            }
        } label: {
            // Recording gets a red dot; a pending update keeps its gold glasses underneath it.
            // Colored variants must be original images or the menu bar discards the dot's color.
            let variant = MenuBarIcon.variant(for: model.appUpdateFlow.phase, recording: model.recordingCount > 0 || model.macRecordingActive)
            Group {
                if variant != .normal {
                    Image(nsImage: MenuBarIcon.image(systemName: model.status.running ? "eyeglasses" : "eyeglasses.slash", variant: variant))
                        .renderingMode(.original)
                } else {
                    Image(systemName: model.status.running ? "eyeglasses" : "eyeglasses.slash")
                }
            }
            .fixedSize()
            .accessibilityLabel(MenuBarIcon.accessibilityLabel(variant))
        }
        .menuBarExtraStyle(.window)
        .commands {
            // In the Dock, COS Control has a menu bar of its own: the setup guide lives in the app menu and Help.
            CommandGroup(after: .appInfo) {
                Button("Setup guide…") { setupWindow.show(model: model) }
            }
            CommandMenu("Meetings") {
                Button("Record on Mac…") { activityWindow.show(model: model, section: .meetings) }
                Button("Stop Mac recording and save") { Task { await model.macRecording.stop() } }
                    .disabled(!model.macRecordingActive)
                Button("View live transcript") { model.showRecordingTranscript() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.recordingCount == 0 || !model.liveTranscriptEnabled)
            }
            CommandMenu("Dictation") {
                Button("Stop dictation") { model.dictation.stop() }
                Button("Cancel dictation") { model.dictation.cancel() }
                Button("Microphone and shortcuts…") { model.showSettings?() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings?() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button("Setup guide…") { setupWindow.show(model: model) }
                Button("COS Control help") { model.openSetupGuide() }
            }
        }
    }
}
