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
        model.openActivity = { section in activityWindow.show(model: model, section: section) }
        model.openSetup = { setupWindow.show(model: model) }
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
        // A Dock click opens Welcome while COS is not set up, else Activity.
        COSAppDelegate.onReopen = {
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
            ControlPanel(model: model) { section in
                activityWindow.show(model: model, section: section)
            }
        } label: {
            // 2026-10-09 (Miles, like Vorssant): gold glasses with a dot while an update is ready. A menu bar ignores
            // color in a template image, so ONLY the ready icon is an NSImage that is not one (MenuBarIcon), drawn as
            // itself. Otherwise the tray is the system eyeglasses glyph, exactly as since 0.5.91 (0.5.90's composed
            // icon squashed the lenses). It follows appUpdateFlow, so a failed check never tints it.
            let variant = MenuBarIcon.variant(for: model.appUpdateFlow.phase)
            Group {
                if variant == .updateReady {
                    Image(nsImage: MenuBarIcon.image(systemName: model.status.running ? "eyeglasses" : "eyeglasses.slash", variant: .updateReady))
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
