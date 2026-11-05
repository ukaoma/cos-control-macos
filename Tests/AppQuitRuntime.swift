import AppKit

// 0.5.320: runs a real NSApplication whose applicationShouldTerminate answers .terminateLater and replies from a Task,
// the shape COSAppDelegate has while a Mac recording saves. Mode "scheduled" quits with AppQuit.request() from inside a
// main-actor Task (the updater's path); mode "direct" calls terminate(nil) there, the pre-0.5.320 code. run-app-quit.sh
// expects "scheduled" to exit by itself and "direct" to still be running, so the lane fails if either half stops holding.
//
// 0.5.373: the update swap's quit request (AppUpdateQuitRequest), on the same real, never-active NSApplication.
//   listen <bundle> <pending.json> <current build> [pending]   listens as the app does and says READY; quits only
//                                                              through AppQuit.request(). "pending": a quit already waits.
//   post <bundle>                                              posts the request the swap sends, then exits
//   decide                                                     the pure rule (verdict, samePath, pendingBuild)
@MainActor final class QuitProbeDelegate: NSObject, NSApplicationDelegate {
    let mode: String
    let args: [String]
    init(mode: String, args: [String]) { self.mode = mode; self.args = args }
    func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if mode == "listen" {
            let pendingPath = args.count > 1 ? args[1] : "/nonexistent"
            let waiting = args.count > 3 && args[3] == "pending"
            AppUpdateQuitRequest.pendingRecord = { URL(fileURLWithPath: pendingPath) }
            AppUpdateQuitRequest.quitPending = { waiting }
            AppUpdateQuitRequest.install(ownBundle: args.first ?? "", currentBuild: args.count > 2 ? Int(args[2]) ?? 0 : 0)
            say("READY")
            return
        }
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

/// The pure rule. Each failure names its behaviour, "check failed [<behaviour>]", for the mutation lane.
func decideChecks(scratch: String) -> Bool {
    var ok = true
    func need(_ value: Bool, _ behaviour: String, _ detail: String) {
        if !value { FileHandle.standardError.write(Data("check failed [\(behaviour)]: \(detail)\n".utf8)); ok = false }
    }
    let own = scratch + "/live/COS Control.app"
    for path in [own, scratch + "/other/COS Control.app"] {   // real folders, so symlink resolution is real
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    typealias V = AppUpdateQuitRequest.Verdict
    need(AppUpdateQuitRequest.verdict(object: own, ownBundle: own, pendingBuild: 199, currentBuild: 88, quitPending: false) == V.quit,
         "quits on its own request", "its own bundle with a newer build staged quits")
    need(AppUpdateQuitRequest.verdict(object: scratch + "/other/COS Control.app", ownBundle: own, pendingBuild: 199, currentBuild: 88, quitPending: false) == V.otherBundle,
         "ignores another bundle", "another bundle's request is not this Control's")
    need(AppUpdateQuitRequest.verdict(object: nil, ownBundle: own, pendingBuild: 199, currentBuild: 88, quitPending: false) == V.otherBundle,
         "ignores another bundle", "a request that names no bundle")
    need(AppUpdateQuitRequest.verdict(object: "", ownBundle: "", pendingBuild: 199, currentBuild: 88, quitPending: false) == V.otherBundle,
         "ignores another bundle", "two empty paths are not one bundle")
    need(AppUpdateQuitRequest.verdict(object: own, ownBundle: own, pendingBuild: 88, currentBuild: 88, quitPending: false) == V.nothingNewerStaged,
         "nothing newer staged", "the running build staged again is not an update")
    need(AppUpdateQuitRequest.verdict(object: own, ownBundle: own, pendingBuild: nil, currentBuild: 88, quitPending: false) == V.nothingNewerStaged,
         "nothing newer staged", "no pending.json")
    need(AppUpdateQuitRequest.verdict(object: own, ownBundle: own, pendingBuild: 199, currentBuild: 88, quitPending: true) == V.alreadyQuitting,
         "already quitting", "a quit already waiting on the recording's save is not asked again")
    if scratch.hasPrefix("/tmp/") {
        need(AppUpdateQuitRequest.samePath("/private" + own, own), "decide", "/private/tmp and /tmp are one bundle")
    }
    let record = URL(fileURLWithPath: scratch + "/decide-pending.json")
    for (body, want) in [("{\"build\": 427}", 427), ("{\"build\": \"428\"}", 428)] as [(String, Int?)] {
        try? body.write(to: record, atomically: true, encoding: .utf8)
        need(AppUpdateQuitRequest.pendingBuild(at: record) == want, "decide", "pending.json \(body) names build \(want.map { String($0) } ?? "nil")")
    }
    try? "not json".write(to: record, atomically: true, encoding: .utf8)
    need(AppUpdateQuitRequest.pendingBuild(at: record) == nil, "decide", "an unreadable pending.json names no build")
    return ok
}

@main struct AppQuitRuntime {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.first ?? "scheduled"
        if mode == "post" {
            AppUpdateQuitRequest.post(liveBundle: arguments.count > 1 ? arguments[1] : "")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            exit(0)
        }
        if mode == "decide" {
            let ok = decideChecks(scratch: arguments.count > 1 ? arguments[1] : "/tmp")
            FileHandle.standardError.write(Data((ok ? "DECIDE OK\n" : "DECIDE FAILED\n").utf8))
            exit(ok ? 0 : 1)
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        let delegate = QuitProbeDelegate(mode: mode, args: Array(arguments.dropFirst()))
        app.delegate = delegate
        app.run()
    }
}
