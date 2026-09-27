import SwiftUI

/// Same Activity shell as COS Control; no production polling, updater, pet or hotkey.
@main struct Control2FoundationLabApp: App {
    @StateObject private var model = ControllerModel(startBackgroundWork: false)
    private var previewColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["COS_CONTROL_TEST_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
    private var previewWidth: CGFloat {
        let value = Double(ProcessInfo.processInfo.environment["COS_CONTROL_TEST_WIDTH"] ?? "") ?? 1120
        return CGFloat(min(1800, max(760, value)))
    }
    private var previewHeight: CGFloat {
        let value = Double(ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HEIGHT"] ?? "") ?? 780
        return CGFloat(min(1400, max(560, value)))
    }
    var body: some Scene {
        WindowGroup("COS Control · Work Preview") {
            ActivityWindow.workPreview(model: model)
                .preferredColorScheme(previewColorScheme)
        }.defaultSize(width: previewWidth, height: previewHeight)
    }
}
