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
        _model = StateObject(wrappedValue: model)
        _activityWindow = StateObject(wrappedValue: activityWindow)
        _sessionPet = StateObject(wrappedValue: sessionPet)
    }

    var body: some Scene {
        MenuBarExtra("COS Control", systemImage: model.status.running ? "eyeglasses" : "eyeglasses.slash") {
            ControlPanel(model: model) { section in
                activityWindow.show(model: model, section: section)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
