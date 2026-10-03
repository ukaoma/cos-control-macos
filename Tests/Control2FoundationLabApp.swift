import SwiftUI

/// Same Activity shell as COS Control; no production polling, updater, pet or hotkey.
@main struct Control2FoundationLabApp: App {
    private static let connected = ProcessInfo.processInfo.environment["COS_WORK_CONNECTED_TEST"] == "1"
        && ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] == nil
    private static let fixture = ProcessInfo.processInfo.environment["COS_WORK_FIXTURE_TEST"] == "1"
        && (ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] ?? "").hasPrefix("/tmp/")
    @StateObject private var model = ControllerModel(startBackgroundWork: false, allowActivityLoads: connected || fixture)
    /// The build script's label (0.1.9 by default; a candidate build names itself).
    private static let labVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.9"
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
        WindowGroup((Self.fixture ? "COS Control · Disposable Work QA " : Self.connected ? "COS Control · Connected Work " : "COS Control · Work Preview ") + Self.labVersion) {
            Group {
                if Self.connected || Self.fixture { ActivityWindow.workConnectedTest(model: model) }
                else { ActivityWindow.workPreview(model: model) }
            }.preferredColorScheme(previewColorScheme)
        }.defaultSize(width: previewWidth, height: previewHeight)
    }
}
