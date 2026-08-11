import SwiftUI

@main
struct COSControlApp: App {
    @StateObject private var model = ControllerModel()
    @StateObject private var activityWindow = ActivityWindowPresenter()

    var body: some Scene {
        MenuBarExtra("COS Control", systemImage: model.status.running ? "eyeglasses" : "eyeglasses.slash") {
            ControlPanel(model: model) {
                activityWindow.show(model: model)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
