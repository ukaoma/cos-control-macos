import SwiftUI

/// Lab-only entry point avoids production controller, hotkey and update startup.
@main struct Control2FoundationLabApp: App {
    var body: some Scene {
        WindowGroup("COS Control 2 · Foundation Lab") {
            Control2FoundationView()
        }.defaultSize(width: 1080, height: 740)
    }
}
