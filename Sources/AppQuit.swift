import AppKit
import os

private let quitLog = Logger(subsystem: "com.gotcos.control", category: "app-quit")

/// 0.5.320 (Queen's Mac, 2026-10-17): every quit COS Control starts itself goes through here.
///
/// NSApplication.terminate(nil) called inside a main-actor job deadlocks whenever applicationShouldTerminate answers
/// .terminateLater: AppKit waits for the reply inside that job, and the Task that sends the reply cannot start until the
/// job returns. The updater asked to quit from its Task, so Control never quit; the helper gave up after 60 s ("COS Control
/// did not quit in time") and the window sat on Installing, while a quit from the menu or AppleScript took 0.2 s. A
/// zero-delay perform runs terminate from a run-loop timer, outside any job, so the reply can run while AppKit waits.
/// Tests/run-app-quit.sh proves both halves on a real NSApplication: this path quits, a direct terminate in a Task hangs.
@MainActor enum AppQuit {
    /// 0.5.373: `source` is a breadcrumb only (subsystem com.gotcos.control, category app-quit), so the unified log says
    /// which path asked Control to quit. Every caller still quits the same way.
    static func request(_ source: String = "app") {
        quitLog.notice("quit requested: source=\(source, privacy: .public)")
        NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}

/// 0.5.373 (Miles's Mac, 2026-11-05): the update swap asks Control to quit, instead of assuming Control already asked.
///
/// The detached swap (cos-control-helper apply-app-update --swap) waits 20 s for Control to quit, then sends SIGTERM. That
/// wait assumed Control had asked itself to quit (AppQuit.request() after apply --detach, the in-app Install path). An
/// install driven from a shell never asked: 0.5.366 to 0.5.371 all ended forcedQuit=true, signals=[SIGTERM], the SIGTERM
/// 20 s after the swap began, with nothing in Control's log in between. The swap now posts this request first
/// (deliverImmediately, so an inactive app gets it), with the live bundle's path as the object. Control quits through
/// AppQuit.request() only when the path is its own bundle and updates/pending.json names a build newer than itself. A
/// request for another bundle (a test's /tmp stand-in) or with nothing newer staged changes nothing. The name is the same
/// string in HelperSources/main.swift and Tests/fixtures/app-update/live-app.c (Tests/app-update-quit-request-pins.py).
@MainActor enum AppUpdateQuitRequest {
    nonisolated static let name = Notification.Name("com.gotcos.control.appUpdate.quitRequest")

    enum Verdict: String, Equatable {
        case quit
        /// The request names another bundle (another copy of Control, a test's stand-in), or none.
        case otherBundle
        /// pending.json is missing, unreadable, or not newer than this build: nothing to install.
        case nothingNewerStaged
        /// A quit is already waiting on the Mac recording's save. A second terminate would change nothing.
        case alreadyQuitting
    }

    /// Wired by the app: whether a deferred quit is already pending (MacRecordingTermination.pending).
    static var quitPending: (@MainActor () -> Bool)?
    /// Wired by the app: the helper's updates/pending.json, read at each request.
    static var pendingRecord: (@MainActor () -> URL)?
    private static var observer: NSObjectProtocol?

    nonisolated static func verdict(object: String?, ownBundle: String, pendingBuild: Int?, currentBuild: Int, quitPending: Bool) -> Verdict {
        guard let object, samePath(object, ownBundle) else { return .otherBundle }
        guard let pendingBuild, pendingBuild > currentBuild else { return .nothingNewerStaged }
        return quitPending ? .alreadyQuitting : .quit
    }

    /// One bundle by path, after symlinks (/tmp and /private/tmp, a linked Applications folder).
    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(a) == canonical(b)
    }

    /// The build updates/pending.json names (a number or a numeric string), or nil.
    nonisolated static func pendingBuild(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let build = object["build"] as? Int { return build }
        if let build = object["build"] as? String { return Int(build) }
        return nil
    }

    /// Listens for the swap's request for the life of the app.
    static func install(ownBundle: String, currentBuild: Int) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let object = note.object as? String
            MainActor.assumeIsolated { AppUpdateQuitRequest.handle(object: object, ownBundle: ownBundle, currentBuild: currentBuild) }
        }
    }

    static func handle(object: String?, ownBundle: String, currentBuild: Int) {
        let record = pendingRecord?()
        let pending = record.flatMap { pendingBuild(at: $0) }
        let waiting = quitPending?() ?? false
        let decided = verdict(object: object, ownBundle: ownBundle, pendingBuild: pending, currentBuild: currentBuild, quitPending: waiting)
        let (verdictWord, pendingWord) = (decided.rawValue, pending ?? -1)
        quitLog.notice("update quit request: verdict=\(verdictWord, privacy: .public) pendingBuild=\(pendingWord, privacy: .public) currentBuild=\(currentBuild, privacy: .public) quitPending=\(waiting, privacy: .public)")
        if decided == .quit { AppQuit.request("update swap") }
    }

    /// What the swap sends. Tests/run-app-quit.sh posts through this; the helper posts the same name and object itself.
    nonisolated static func post(liveBundle: String) {
        DistributedNotificationCenter.default().postNotificationName(name, object: liveBundle, userInfo: nil, deliverImmediately: true)
    }
}
