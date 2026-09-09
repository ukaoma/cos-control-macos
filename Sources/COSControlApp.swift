import SwiftUI

@main
struct COSControlApp: App {
    @StateObject private var model: ControllerModel
    @StateObject private var activityWindow: ActivityWindowPresenter
    @StateObject private var sessionPet: SessionPetPresenter

    init() {
        let model = ControllerModel()
        let activityWindow = ActivityWindowPresenter()
        let sessionPet = SessionPetPresenter()
        sessionPet.bindIfNeeded(model: model) { section in
            activityWindow.show(model: model, section: section)
        }
        // The Activity hotkey: registered from the saved combo at launch and
        // routed to the same presenter the chips use.
        HotKeyCenter.shared.onFire = { activityWindow.show(model: model, section: nil) }
        HotKeyCenter.shared.register(model.activityHotKey)
        _model = StateObject(wrappedValue: model)
        _activityWindow = StateObject(wrappedValue: activityWindow)
        _sessionPet = StateObject(wrappedValue: sessionPet)
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
            ControlPanel(model: model) { section in
                activityWindow.show(model: model, section: section)
            }
        } label: {
            Image(systemName: model.status.running ? "eyeglasses" : "eyeglasses.slash")
                .fixedSize()
                .overlay(alignment: .topTrailing) {
                    if model.appUpdate.shouldSurface {
                        Circle()
                            .fill(.primary)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -1)
                    }
                }
                .accessibilityLabel("COS Control")
        }
        .menuBarExtraStyle(.window)
    }
}
