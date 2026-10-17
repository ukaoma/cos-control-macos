import AppKit

// 0.5.320: runs a real NSApplication whose applicationShouldTerminate answers .terminateLater and replies from a Task,
// the shape COSAppDelegate has while a Mac recording saves. Mode "scheduled" quits with AppQuit.request() from inside a
// main-actor Task (the updater's path); mode "direct" calls terminate(nil) there, the pre-0.5.320 code. run-app-quit.sh
// expects "scheduled" to exit by itself and "direct" to still be running, so the lane fails if either half stops holding.
@MainActor final class QuitProbeDelegate: NSObject, NSApplicationDelegate {
    let mode: String
    init(mode: String) { self.mode = mode }
    func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            say("asking to quit: \(mode)")
            if mode == "direct" { NSApplication.shared.terminate(nil) } else { AppQuit.request() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        say("shouldTerminate: later")
        Task { @MainActor in
            say("reply task ran")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { say("QUIT OK") }
}

@main struct AppQuitRuntime {
    @MainActor static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        let delegate = QuitProbeDelegate(mode: CommandLine.arguments.dropFirst().first ?? "scheduled")
        app.delegate = delegate
        app.run()
    }
}
