import AppKit

/// 0.5.320 (Queen's Mac, 2026-10-17): every quit COS Control starts itself goes through here.
///
/// NSApplication.terminate(nil) called inside a main-actor job deadlocks whenever applicationShouldTerminate answers
/// .terminateLater: AppKit waits for the reply inside that job, and the Task that sends the reply cannot start until the
/// job returns. The updater asked to quit from its Task, so Control never quit; the helper gave up after 60 s ("COS Control
/// did not quit in time") and the window sat on Installing, while a quit from the menu or AppleScript took 0.2 s. A
/// zero-delay perform runs terminate from a run-loop timer, outside any job, so the reply can run while AppKit waits.
/// Tests/run-app-quit.sh proves both halves on a real NSApplication: this path quits, a direct terminate in a Task hangs.
@MainActor enum AppQuit {
    static func request() {
        NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
