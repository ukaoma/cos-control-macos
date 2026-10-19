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
            // 0.5.328: the helper's refusal (no speech, an engine missing, the server busy) comes back with its details, so
            // the dictation reads noSpeech, reason and action instead of a bare helper_failed:command_failed (Miles
            // 2026-10-19 19:02:06: the server dropped a near-silent 4.1 s capture as empty; Control offered a Retry that
            // re-sent the same audio).
            return try await model.runHelper(["mac-dictation"], timeout: 40, stdinData: audio, answers: true)
        }
        // 0.5.325 AI polish: the heard text on stdin, never argv; the helper process gets the whole budget and no more.
        model.dictation.polishBridge = { [weak model] request, budget in
            guard let model else { throw HelperClientError.commandFailed("COS Control is closing.") }
            // 0.5.328: the helper's refusal (timeout, unreachable, too_long, busy...) comes back with its reason, so the
            // timing line names it instead of failed:helper. The heard text is pasted either way.
            return try await model.runHelper(["dictation-polish"], timeout: budget, stdinData: request, answers: true)
        }
        model.dictation.petFrame = { [weak sessionPet] in sessionPet?.visibleFrame }
        // 0.5.317: a failure card's one action, and the server version a dictation succeeded on (the Voice row's proof).
        model.dictation.installParakeet = { [weak model] in model?.installParakeet() }
        model.dictation.useWhisper = { [weak model] in await model?.useWhisperForDictation() ?? false }
        model.dictation.openTranscriptionSettings = { [weak model] in model?.showTranscriptionSettings?() }
        model.dictation.serverVersion = { [weak model] in model?.status.version }
        // 0.5.318: Allow…, Reset and System Audio Recording go through the permission guide, as the pet jump does.
        model.dictation.requestAccessibility = { [weak model] resume in model?.requestDictationAccessibility(resume: resume) }
        model.dictation.resetAccessibility = { [weak model] resume in model?.resetDictationAccessibility(resume: resume) }
        model.dictation.requestSystemAudio = { [weak model] wantsPane in
            await model?.requestSystemAudio(for: "Mute other apps", wantsPane: wantsPane) ?? false
        }
        model.macRecording.requestSystemAudio = { [weak model] in await model?.requestSystemAudio(for: "All Mac audio") ?? false }
        // 0.5.312 sounds: the pet's family picks its default sound; nothing plays while a Mac recording captures.
        // Any live COS recording, Mac or glasses (QA 2026-10-15): muting other apps would silence the call being recorded,
        // and a glasses mic hears the call through the Mac's speakers.
        model.dictation.macRecordingActive = { [weak model] in (model?.recordingCount ?? 0) > 0 }
        model.dictation.petKind = { [weak model] in
            guard let model else { return .other }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: PetSpriteStore.supportDirectory().path)) ?? []
            return DictationSoundLibrary.petKind(hasCombatStories: model.petSpriteKit.poses[.duel] != nil && model.petSpriteKit.poses[.swarm] != nil,
                                                 assetNames: names)
        }
        // 0.5.315: which shipped pack is installed, by the pose files its state map names (bundled sets read once).
        let shippedPacks = PetSpriteStore.bundledCharacters.compactMap { character in
            PetSpriteStore.bundledCharacterURL(character).map { (id: character.id, files: Set(PetSpriteStore.loadStateMap(in: $0).values.map(\.file))) }
        }
        model.dictation.petPack = {
            DictationSoundLibrary.installedPack(Set(PetSpriteStore.loadStateMap(in: PetSpriteStore.supportDirectory()).values.map(\.file)), packs: shippedPacks)
        }
        model.dictionary.bridge = { [weak model] request in
            guard let model else { throw HelperClientError.commandFailed("COS Control is closing.") }
            return try await model.runHelper(["transcription-dictionary"], timeout: 20, stdinData: request)
        }
        model.dictation.registerHotKeys()
        // 0.5.313: a meeting app on the microphone for 10 s gets a Record card on the pet. COS never records or stops
        // on its own: Record and Stop and save are the person's clicks.
        let meetings = MeetingDetectorStore.shared
        meetings.petFrame = { [weak sessionPet] in sessionPet?.visibleFrame }
        meetings.dictating = { [weak model] in model?.dictation.busy ?? false }
        meetings.recordingBusy = { [weak model] in
            guard let model else { return true }
            return MeetingDetectedCard.recordingBusy(macOccupied: model.macRecording.occupied, macCanStart: model.macRecording.canStart,
                                                   liveRecordings: model.recordingCount)
        }
        meetings.runningCaptureID = { [weak model] in
            guard let model, model.macRecording.isRecording else { return nil }
            return model.macRecording.manifest?.captureId
        }
        meetings.record = { [weak model] source in
            guard let model else { return nil }
            let id = await model.macRecording.startFromMeetingSuggestion(title: MeetingDetectedCard.title(source, at: Date()), bridge: model.macRecordingBridge)
            // The person clicked Record: a failure must be seen even with the pet hidden, so Meetings opens on the panel
            // that says why (QA 2026-10-15: a hidden pet swallowed it).
            if id == nil {
                model.petNotice = model.macRecording.error ?? "COS couldn't start recording. Open Meetings → Record on Mac to see why."
                model.openActivity?(.meetings)
            }
            return id
        }
        meetings.stopRecording = { [weak model] in await model?.macRecording.stop() }
        meetings.noticeAcknowledged = { [weak model] in model?.macRecording.noticeAcknowledged ?? false }
        meetings.acknowledgeNotice = { [weak model] in model?.macRecording.acknowledgeNotice() }
        Task { [weak model] in
            await model?.macRecording.refreshRecoverable()
            meetings.activate()
        }
        model.macRecording.openLiveMeeting = { [weak model] id in
            // Handed to the window like Dictionary and History: it opens after the switch to Meetings, never before it.
            model?.activityOpenLiveTranscriptID = id
            model?.openActivity?(.meetings)
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
        // 0.5.317: a dictation card's "Open Transcription settings" lands on COS's Transcription card, never macOS Privacy.
        model.showTranscriptionSettings = {
            SettingsOpener.open(model: model, window: settingsWindow, scroll: "transcription") { section in activityWindow.show(model: model, section: section) }
        }
        COSAppDelegate.panelVisible = { model.panelVisible }
        COSAppDelegate.onOpenActivity = { activityWindow.show(model: model, section: nil) }
        COSAppDelegate.onSetupGuide = { setupWindow.show(model: model) }
        COSAppDelegate.onSettings = { model.showSettings?() }
        COSAppDelegate.recordingAvailable = { model.recordingCount > 0 && model.liveTranscriptEnabled }
        COSAppDelegate.onOpenRecording = { model.showRecordingTranscript() }
        COSAppDelegate.onTerminate = { model.dictation.cancel(); model.dictation.flushAudio(); model.meetingAsk.flushAll() }
        MacRecordingTermination.prepare = { await model.macRecording.prepareToQuit() }
        MacRecordingTermination.needsPrepare = { model.macRecording.needsQuitTeardown }
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
                        Text(MacRecordingNotice.reminder).font(COSType.body(10.5)).foregroundStyle(.secondary)
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
                Button("Dictionary…") { model.openDictionaryInActivity() }
                Button("History…") { model.openDictationHistoryInActivity() }
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
