import AppKit
import SwiftUI

/// 0.5.322: Finish installing and the swap's give-up, with the whole app compiled (Tests/run-app-update-finish.sh).
///
///   check <stand-in helper> <real helper>   the launch offer (staged-app-update), one click straight to apply-app-update
///                                           with no download, the install ending at once on the swap's recording or
///                                           quitTimeout record (never on busy or an older record), and the Mac
///                                           recording state this process writes, read by the REAL helper's
///                                           app-update-quit-safety for this very process (the binary runs as a
///                                           bundle's own executable).
///
/// The stand-in answers staged-app-update from staged.json and apply-app-update ok only while apply-ok exists. A quit the
/// app asks for (AppQuit) is refused by this binary's delegate, so nothing here can end the process early; the runner
/// also requires the final PASS line. No window is ordered in, nothing becomes active.
@MainActor final class QuitRefuser: NSObject, NSApplicationDelegate {
    var asked = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        asked += 1
        return .terminateCancel
    }
}

@MainActor final class PhaseLog {
    var phases: [String] = []
}

@main @MainActor struct AppUpdateFinishWiring {
    static var passed = 0
    static let iso = ISO8601DateFormatter()

    static func fail(_ behaviour: String, _ detail: String) -> Never {
        print("check failed [\(behaviour)]: \(detail)")
        exit(1)
    }

    static func check(_ ok: Bool, _ behaviour: String, _ detail: String = "") {
        if !ok { fail(behaviour, detail) }
        passed += 1
    }

    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let refuser = QuitRefuser()
        NSApplication.shared.delegate = refuser
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, args[0] == "check" else { fatalError("usage: check <stand-in helper> <real helper>") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            print("check failed [finish wiring hang]: the checks did not finish within 180 s")
            exit(1)
        }
        let fake = URL(fileURLWithPath: args[1]), real = URL(fileURLWithPath: args[2])
        await launchOffer(fake)
        await finishClick(fake)
        await endsAtOnce(fake)
        await captureState(real)
        NSObject.cancelPreviousPerformRequests(withTarget: NSApplication.shared)
        print("PASS: Finish installing wiring, \(passed) checks (launch offer, one click with no download, the swap's give-up ends the install, capture state read by the real helper)")
    }

    // MARK: the stand-in

    static func dir(_ fake: URL) -> URL { fake.deletingLastPathComponent() }

    static func calls(_ fake: URL) -> [String] {
        ((try? String(contentsOf: dir(fake).appendingPathComponent("args.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    static func reset(_ fake: URL) {
        for name in ["args.log", "staged.json", "apply-ok", "last-failure.json", "success.json"] {
            try? FileManager.default.removeItem(at: dir(fake).appendingPathComponent(name))
        }
    }

    static func stage(_ fake: URL, build: Int, failure: String = "quitTimeout", at: Date = Date()) {
        let body = #"{"ok":true,"message":"staged","details":{"reason":"staged","version":"9.9.9","build":\#(build),"failureReason":"\#(failure)","failureAt":"\#(iso.string(from: at))"}}"#
        try? body.write(to: dir(fake).appendingPathComponent("staged.json"), atomically: true, encoding: .utf8)
    }

    static func record(_ fake: URL, _ reason: String, at: Date = Date()) {
        let body = #"{"reason":"\#(reason)","at":"\#(iso.string(from: at))"}"#
        try? body.write(to: dir(fake).appendingPathComponent("last-failure.json"), atomically: true, encoding: .utf8)
    }

    static func makeModel(_ fake: URL) -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: fake))
        model.updateFailureRecord = dir(fake).appendingPathComponent("last-failure.json")
        model.updateSuccessRecord = dir(fake).appendingPathComponent("success.json")
        return model
    }

    static func wait(_ seconds: Double, until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    static func offerInfo(_ available: Bool, _ version: String?, _ build: Int?, reason: String) -> AppUpdateInfo {
        var details: [String: JSONValue] = ["updateAvailable": .bool(available), "reason": .string(reason)]
        if let version { details["latestVersion"] = .string(version) }
        if let build { details["latestBuild"] = .number(Double(build)) }
        return AppUpdateInfo(details)
    }

    // MARK: launch offer

    static func launchOffer(_ fake: URL) async {
        let next = ControllerModel.currentBuild + 5
        reset(fake)
        stage(fake, build: next)
        let model = makeModel(fake)
        await model.checkStagedAppUpdate()
        let flow = model.appUpdateFlow
        check(flow.phase == .ready && flow.finishesStaged && flow.version == "9.9.9" && flow.build == next, "launch offer",
              "a staged build after a quit timeout is offered: \(flow.phase) staged=\(flow.finishesStaged)")
        check(calls(fake) == ["staged-app-update --current-version \(ControllerModel.currentVersion) --current-build \(ControllerModel.currentBuild) --failure-window 1800"],
              "launch offer asks", "one read-only call, with this build and the 30 minute window: \(calls(fake))")
        check(AppUpdateBannerWords(flow).title == "Finish installing 9.9.9" && AppUpdateBannerWords(flow).action == "Install", "launch offer",
              "the banner offers Finish installing 9.9.9")
        // The check's restored failure never replaces it; a feed that cannot be read, or still offers the build, keeps it.
        record(fake, "quitTimeout")
        model.appUpdate = offerInfo(false, nil, nil, reason: "unreachable")
        check(model.appUpdateFlow.finishesStaged && model.appUpdateFlow.phase == .ready, "launch offer kept", "an unreachable check keeps the staged offer")
        model.appUpdate = offerInfo(true, "9.9.9", next, reason: "newer")
        check(model.appUpdateFlow.finishesStaged && model.appUpdateFlow.phase == .ready, "launch offer kept",
              "the feed still offering the staged build keeps it, and the recent quitTimeout is not restored over it: \(model.appUpdateFlow.phase)")
        model.appUpdate = offerInfo(true, "9.9.10", next + 1, reason: "newer")
        check(!model.appUpdateFlow.finishesStaged && model.appUpdateFlow.build == next + 1, "launch offer kept", "a newer build replaces the staged one")
        // Nothing staged, an old failure, or a busy refusal: no offer.
        for (label, prepare) in [("nothing staged", { reset(fake) }),
                                 ("failure older than 30 minutes", { reset(fake); stage(fake, build: next, at: Date().addingTimeInterval(-3600)) }),
                                 ("busy refusal", { reset(fake); stage(fake, build: next, failure: "busy") })] as [(String, () -> Void)] {
            prepare()
            let other = makeModel(fake)
            await other.checkStagedAppUpdate()
            check(other.appUpdateFlow.phase == .none && !other.appUpdateFlow.finishesStaged, "launch offer rule", "\(label): no offer")
        }
    }

    // MARK: one click, no download

    static func finishClick(_ fake: URL) async {
        let next = ControllerModel.currentBuild + 5
        for entry in ["banner", "What's New"] {
            reset(fake)
            stage(fake, build: next)
            let model = makeModel(fake)
            await model.checkStagedAppUpdate()
            // The banner's Install calls finishStagedAppUpdate; What's New's Finish installing calls installAppUpdate, which
            // routes a staged offer the same way (Tests/app-update-finish-pins.py pins the banner's closure).
            if entry == "banner" { model.finishStagedAppUpdate() } else { model.installAppUpdate() }
            check(model.appUpdateFlow.phase == .applying && model.busy, "finish one click", "\(entry): straight to applying")
            let done = await wait(10) { if case .failed = model.appUpdateFlow.phase { return true }; return false }
            check(done, "finish one click", "\(entry): the stand-in refuses apply, so the install must end with its words")
            let made = calls(fake)
            check(!made.contains { $0.hasPrefix("stage-app-update") }, "finish no download", "\(entry): Finish installing never downloads: \(made)")
            let apply = made.first { $0.hasPrefix("apply-app-update") } ?? ""
            check(apply.hasPrefix("apply-app-update --detach --live-bundle ") && apply.hasSuffix("--expected-build \(next)"), "finish one click",
                  "\(entry): the same apply path, for the staged build: \(apply)")
            check(model.appUpdateFlow.phase == .failed("The staged update is missing.") && !model.busy, "finish one click",
                  "\(entry): the helper's refusal in its words, Try again: \(model.appUpdateFlow.phase)")
            // Try again after that is a full install (the staged offer is gone): it stages first.
            check(!model.appUpdateFlow.finishesStaged, "finish one click", "\(entry): after a refusal the offer is an ordinary Try again")
        }
    }

    // MARK: the swap's give-up ends the install at once

    static func endsAtOnce(_ fake: URL) async {
        let next = ControllerModel.currentBuild + 5
        func applying(_ model: ControllerModel) async {
            reset(fake)
            stage(fake, build: next)
            FileManager.default.createFile(atPath: dir(fake).appendingPathComponent("apply-ok").path, contents: Data())
            await model.checkStagedAppUpdate()
            model.finishStagedAppUpdate()
            let started = await wait(10) { model.notice == "Installing. Control will reopen." }
            check(started && model.appUpdateFlow.phase == .applying, "ends at once", "the apply must start: \(model.appUpdateFlow.phase)")
            NSObject.cancelPreviousPerformRequests(withTarget: NSApplication.shared)
        }
        let model = makeModel(fake)
        await applying(model)
        check(AppUpdateBannerWords(model.appUpdateFlow).detail == "Closing COS Control\u{2026}", "applying words", "the banner says Closing COS Control…")
        // busy: the swap waits for Control to quit and reopens it, so the install keeps waiting.
        record(fake, "busy")
        try? await Task.sleep(for: .milliseconds(2500))
        check(model.appUpdateFlow.phase == .applying, "busy keeps waiting", "a busy record does not end the install early: \(model.appUpdateFlow.phase)")
        // recording: ends at once, in its words, with Try again.
        record(fake, "recording")
        let ended = await wait(4) { if case .failed = model.appUpdateFlow.phase { return true }; return false }
        check(ended && model.appUpdateFlow.phase == .failed(AppUpdateFailureRecord.recordingWords), "recording ends at once",
              "the swap's recording record ends the install within a few seconds: \(model.appUpdateFlow.phase)")
        check(!model.busy && model.notice == nil && model.operationProgress == nil, "recording ends at once", "and Control is free again")
        check(WhatsNewFooter(model.appUpdateFlow.phase, busy: model.busy).primaryTitle == WhatsNewFooter.retryTitle, "recording ends at once", "with Try again")
        // A record from before this apply never ends it; a fresh quitTimeout does.
        let second = makeModel(fake)
        await applying(second)
        record(fake, "quitTimeout", at: Date().addingTimeInterval(-600))
        try? await Task.sleep(for: .milliseconds(2500))
        check(second.appUpdateFlow.phase == .applying, "older record ignored", "a record older than this apply is not this apply's: \(second.appUpdateFlow.phase)")
        record(fake, "quitTimeout")
        let timedOut = await wait(4) { if case .failed = second.appUpdateFlow.phase { return true }; return false }
        check(timedOut && second.appUpdateFlow.phase == .failed(AppUpdateFailureRecord.quitTimeoutWords), "quit timeout ends at once",
              "a fresh quitTimeout ends the install: \(second.appUpdateFlow.phase)")
        NSObject.cancelPreviousPerformRequests(withTarget: NSApplication.shared)
    }

    // MARK: the Mac recording state, from this process to the real helper

    static func captureState(_ real: URL) async {
        let url = MacCaptureStateFile.url()
        check(url.path.hasPrefix("/tmp/") && url.lastPathComponent == "mac-capture-state.json", "capture state",
              "the test home's file, where the real helper looks: \(url.path)")
        let model = ControllerModel(startBackgroundWork: false)
        check(model.macRecording.phaseRecorder == nil, "capture state", "a test model records nothing until asked")
        model.recordMacCaptureState(to: url)
        guard let first = try? Data(contentsOf: url), let decoded = MacCaptureStateFile.decode(first) else { fail("capture state", "nothing written at launch") }
        check(decoded.phase == "idle" && decoded.pid == getpid(), "capture state", "launch writes the phase and this process: \(decoded)")
        // Every phase change reaches the file: Recover of a journal that does not exist goes idle, recovering, idle.
        let log = PhaseLog()
        let writer = model.macRecording.phaseRecorder
        model.macRecording.phaseRecorder = { phase in log.phases.append(phase); writer?(phase) }
        let missing = MacRecordingManifest(captureId: "mac_" + UUID().uuidString.lowercased(), startTime: 1, serverInstanceId: "check",
                                           sourceName: "check", title: "check", stopped: false, saved: false, acknowledged: 0, chunks: [])
        _ = await model.macRecording.recover(missing)
        check(log.phases == ["recovering", "idle"], "phase recorder", "every phase change is recorded, in order: \(log.phases)")
        // The real helper reads what this process wrote, for this process (it runs the bundle's executable).
        let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func safety() -> [String: Any] {
            let p = Process()
            p.executableURL = real
            p.arguments = ["app-update-quit-safety", "--live-bundle", bundle.path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { fail("capture state read by the helper", "could not run \(real.path)") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            return ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["details"] as? [String: Any] ?? [:]
        }
        var s = safety()
        check(s["verdict"] as? String == "safe" && s["phase"] as? String == "idle" && (s["pids"] as? [Int]) == [Int(getpid())], "capture state read by the helper",
              "the helper sees this process, idle, as safe to close: \(s)")
        for phase in ["starting", "recording", "stopping"] {
            do { try MacCaptureStateFile.write(phase: phase, to: url) } catch { fail("capture state", "write \(phase): \(error)") }
            s = safety()
            check(s["verdict"] as? String == "recording" && s["phase"] as? String == phase, "capture state read by the helper",
                  "a Mac recording that is \(phase) is never closed: \(s)")
        }
        do { try MacCaptureStateFile.write(phase: "idle", pid: getpid() + 1, to: url) } catch { fail("capture state", "write: \(error)") }
        s = safety()
        check(s["verdict"] as? String == "unknown", "capture state read by the helper", "a record naming another process is unknown: \(s)")
    }
}
