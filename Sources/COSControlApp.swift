import SwiftUI

@main
struct COSControlApp: App {
    @StateObject private var model = ControllerModel()

    var body: some Scene {
        MenuBarExtra("COS Control", systemImage: model.status.running ? "eyeglasses" : "eyeglasses.slash") {
            ControlPanel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

