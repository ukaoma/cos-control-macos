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
