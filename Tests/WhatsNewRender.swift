import AppKit
import SwiftUI

/// 2026-10-09 (Miles, 13:09, with screenshots of Vorssant): the What's New window with the whole app compiled.
///
///   check <fake helper>         the wiring: a background check never opens the window, Check for updates that finds an
///                               update opens it (once), the banner's path opens it, one window at a time, and Download
///                               and install runs the real installAppUpdate against a stand-in helper: staging with the
///                               helper's progress words, closing the window stops nothing, a refusal shows the
///                               helper's own words and Try again.
///   render <dir> <whatsNew.json> PNGs, light and dark: ready with a full whatsNew, ready with the notes fallback,
///                               downloading, installing, failed.
///
/// Nothing contacts the real helper, the appcast or the server: the model has no background work, the binary runs with a
/// scratch home, and the stand-in helper never answers apply-app-update (the install fails at staging, so Control is
/// never asked to quit). Windows are made and never ordered in; the process can never become active; no event is sent.
@main @MainActor struct WhatsNewRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "check":
            guard args.count > 1 else { fatalError("usage: check <fake helper>") }
            singleWindow()
            await wiring(helper: URL(fileURLWithPath: args[1]))
            await nonStaged(helper: URL(fileURLWithPath: args[1]))
            await afterUpdate(helper: URL(fileURLWithPath: args[1]))
            print("PASS: What's New checks complete")
        case "render":
            guard args.count > 3 else { fatalError("usage: render <dir> <whatsNew.json> <Resources/WhatsNew.json>") }
            let out = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try renderAll(out, whatsNew: URL(fileURLWithPath: args[2]), bundled: URL(fileURLWithPath: args[3]))
        default: fatalError("usage: check <fake helper> | render <dir> <whatsNew.json>")
        }
    }

    static func fail(_ behaviour: String, _ detail: String) -> Never {
        print("check failed [\(behaviour)]: \(detail)")
        exit(1)
    }

    final class Counter { var value = 0 }

    static func write(_ text: String, _ url: URL) {
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { fail("stand-in", "could not write \(url.path)") }
    }

    static func until(_ what: String, _ behaviour: String = "install path", _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > end { fail(behaviour, "timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// QA 2026-10-09 (live in 0.5.274): a stage that answers ok:true without staging (the old helper did for an
    /// unreachable, paused, malformed or up-to-date feed), names no staged app, or staged another build is never
    /// applied: no apply-app-update, no quit, the failure in words. A good stage reaches apply with --expected-build.
    /// The stand-in refuses every apply, so even a regression could never quit this process.
    static func nonStaged(helper: URL) async {
        let dir = helper.deletingLastPathComponent()
        let stageFile = dir.appendingPathComponent("stage.json"), args = dir.appendingPathComponent("args.log")
        func applies() -> [String] {
            ((try? String(contentsOf: args, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("apply-app-update") }
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("check.json"))
        write("update", dir.appendingPathComponent("mode"))
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        await model.checkForAppUpdateManually()
        if model.appUpdateFlow.phase != .ready { fail("stage check", "the stand-in offers build 999999: \(model.appUpdateFlow.phase)") }
        let before = applies().count
        let cases: [(String, String)] = [
            (#"{"ok":true,"message":"Update check unavailable","details":{"reason":"unreachable"}}"#, "COS Control could not reach the update feed. Nothing was installed."),
            (#"{"ok":true,"message":"Update checks paused by publisher","details":{"reason":"killSwitch"}}"#, "Updates are paused by the publisher right now. Nothing was installed."),
            (#"{"ok":true,"message":"Update listing is missing a SHA-256. Refusing to install.","details":{"reason":"malformed"}}"#, "The update listing is missing a SHA-256. Nothing was installed."),
            (#"{"ok":true,"message":"COS Control is up to date","details":{"reason":"upToDate","latestBuild":999999}}"#, "COS Control is already up to date. Nothing was installed."),
            (#"{"ok":true,"message":"staged","details":{"reason":"staged","latestBuild":999999}}"#, "The update was not staged. Nothing was installed."),
            (#"{"ok":true,"message":"staged","details":{"reason":"staged","stagedAppPath":"/tmp/x/COS Control.app","latestBuild":5}}"#, "The staged update is build 5, not the offered build 999999. Nothing was installed."),
            (#"{"ok":false,"message":"COS Control is already up to date. Nothing was installed.","details":{}}"#, "COS Control is already up to date. Nothing was installed."),
        ]
        for (index, (response, words)) in cases.enumerated() {
            write(response, stageFile)
            model.installAppUpdate()
            await until("refusal \(index)", "stage check") { if case .failed = model.appUpdateFlow.phase { return !model.busy } else { return false } }
            if applies().count != before { fail("stage check", "case \(index) applied: \(applies())") }
            let status = WhatsNewFooter(model.appUpdateFlow.phase, busy: model.busy).status
            if status != words { fail("stage check", "case \(index) words: \(status ?? "nil")") }
        }
        // A good stage of the offered build reaches apply, naming that build.
        write(#"{"ok":true,"message":"Update 9.9.9 verified and staged","details":{"reason":"staged","stagedAppPath":"/tmp/x/COS Control.app","latestBuild":999999}}"#, stageFile)
        model.installAppUpdate()
        await until("the apply", "stage check build") { applies().count == before + 1 && !model.busy }
        let applied = applies().last ?? ""
        if !applied.contains("--detach") || !applied.contains("--expected-build 999999") {
            fail("stage check build", "apply names the staged build: \(applied)")
        }
        if model.appUpdateFlow.phase != .failed("the stand-in never applies") { fail("stage check build", "the stand-in's apply refusal: \(model.appUpdateFlow.phase)") }
        try? FileManager.default.removeItem(at: stageFile)
        print("PASS: a stage that did not stage the offered build is never applied (7 cases, no apply, no quit); a good one applies with --expected-build")
    }

    /// The window after an update: once per build, after a check that reached the feed, never during a meeting, never
    /// on a first run; this build's words from the appcast.
    static func afterUpdate(helper: URL) async {
        let dir = helper.deletingLastPathComponent()
        let running = ControllerModel.currentBuild, version = ControllerModel.currentVersion
        let check = dir.appendingPathComponent("check.json")
        write(#"{"ok":true,"message":"COS Control is up to date","details":{"updateAvailable":false,"reason":"upToDate","latestVersion":"\#(version)","latestBuild":\#(running),"whatsNew":{"summary":"This build's words.","sections":[{"title":"Added","items":["One"]}]}}}"#, check)
        let record = dir.appendingPathComponent("success.json")
        func model(seen: Int?, updated: Int? = nil) -> (ControllerModel, Counter) {
            let m = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
            let c = Counter()
            m.showWhatsNew = { c.value += 1 }
            m.whatsNewSeen = WhatsNewSeenStore(defaults: nil, initial: seen)
            try? FileManager.default.removeItem(at: record)
            if let updated { write(#"{"version":"x","build":\#(updated),"appliedAt":"2026-10-09T20:00:00Z"}"#, record) }
            m.updateSuccessRecord = record
            m.beginPostUpdateWhatsNew()
            return (m, c)
        }
        // Updated, during a meeting: waits.
        let (m, opened) = model(seen: running - 1)
        m.status = ServerStatus(["activeTranscriptionSessions": .number(1)])
        await m.runScheduledAppUpdateCheck(.launch)
        if opened.value != 0 || m.whatsNewSeen.lastSeenBuild != running - 1 { fail("after update meeting", "shown during a meeting (\(opened.value))") }
        // The meeting ends (the next status refresh): shown once, in installed mode, with this build's words.
        m.status = ServerStatus([:])
        m.considerPostUpdateWhatsNew()
        if opened.value != 1 { fail("after update show", "shown once the meeting ended, got \(opened.value)") }
        guard case let .installed(content, shownVersion, shownBuild) = m.whatsNewMode else { fail("after update show", "installed mode, got \(m.whatsNewMode)") }
        if content.summary != "This build's words." || content.sections.count != 1 || shownVersion != version || shownBuild != running {
            fail("after update content", "this build's appcast words: \(content) \(shownVersion) \(shownBuild)")
        }
        if WhatsNewPresentation.present(m.whatsNewMode, info: m.appUpdate, flow: m.appUpdateFlow, frozen: nil, busy: false).footer != .installed {
            fail("after update show", "Done alone")
        }
        if m.whatsNewSeen.lastSeenBuild != running { fail("after update store", "the build is remembered as it shows") }
        // Never twice: another refresh, another check.
        m.considerPostUpdateWhatsNew()
        await m.runScheduledAppUpdateCheck(.launch)
        if opened.value != 1 { fail("after update twice", "shown a second time") }
        // Update then opens the offer again, not the installed window.
        m.presentWhatsNew()
        if m.whatsNewMode != .offer { fail("after update show", "Update opens the offer") }
        // A later launch of the same build: nothing.
        let (same, sameOpened) = model(seen: running)
        await same.runScheduledAppUpdateCheck(.launch)
        same.considerPostUpdateWhatsNew()
        if sameOpened.value != 0 { fail("after update twice", "the same build showed again on the next launch") }
        // First run ever: remembered at once, never shown.
        let (first, firstOpened) = model(seen: nil)
        if first.whatsNewSeen.lastSeenBuild != running { fail("after update first run", "a first run remembers the build at launch") }
        await first.runScheduledAppUpdateCheck(.launch)
        if firstOpened.value != 0 { fail("after update first run", "a first run showed What's New") }
        // Updated from 0.5.274 (nothing remembered) by the updater: the success record names this build, so it shows once.
        let (fromOld, fromOldOpened) = model(seen: nil, updated: running)
        if fromOld.whatsNewSeen.lastSeenBuild != nil { fail("after update updater", "an update from 0.5.274 is not a first run") }
        await fromOld.runScheduledAppUpdateCheck(.launch)
        if fromOldOpened.value != 1 || fromOld.whatsNewSeen.lastSeenBuild != running { fail("after update updater", "shown once and remembered (\(fromOldOpened.value))") }
        await fromOld.runScheduledAppUpdateCheck(.launch)
        if fromOldOpened.value != 1 { fail("after update twice", "an update from 0.5.274 showed twice") }
        // A fresh install that finds an old record of another build: a first run.
        let (fresh, freshOpened) = model(seen: nil, updated: running - 1)
        await fresh.runScheduledAppUpdateCheck(.launch)
        if freshOpened.value != 0 || fresh.whatsNewSeen.lastSeenBuild != running { fail("after update updater", "a record of another build is a first run") }
        try? FileManager.default.removeItem(at: record)
        // A check that did not reach the feed: waits for one that does.
        write(#"{"ok":true,"message":"Update check unavailable","details":{"updateAvailable":false,"reason":"unreachable"}}"#, check)
        let (offline, offlineOpened) = model(seen: running - 1)
        await offline.runScheduledAppUpdateCheck(.launch)
        offline.considerPostUpdateWhatsNew()
        if offlineOpened.value != 0 { fail("after update show", "shown before any check reached the feed") }
        try? FileManager.default.removeItem(at: check)
        print("PASS: What's New after an update: waits for a meeting, shows once with this build's words and Done, never twice, never on a first run, never before the feed answers; an update from 0.5.274 shows it via the updater's record")
    }

    // MARK: check

    /// One window at a time: a second open hands back the same window, and so does an open after Close.
    static func singleWindow() {
        let model = ControllerModel(startBackgroundWork: false)
        let presenter = WhatsNewWindowPresenter()
        let first = presenter.prepare(model: model)
        let second = presenter.prepare(model: model)
        if first !== second || presenter.windowsMade != 1 { fail("single window", "a second open made another window (\(presenter.windowsMade))") }
        if first.isVisible { fail("single window", "prepare must never order the window in") }
        presenter.close()
        let third = presenter.prepare(model: model)
        if third !== first || presenter.windowsMade != 1 { fail("single window", "an open after Close made another window") }
        if first.isReleasedWhenClosed { fail("single window", "a closed window is kept for the next open") }
        if first.styleMask.contains(.resizable) || !first.styleMask.contains(.closable) || !first.styleMask.contains(.titled) {
            fail("window shape", "a titled, closable window of a fixed size: \(first.styleMask)")
        }
        let size = first.contentRect(forFrameRect: first.frame).size
        if abs(size.width - 620) > 1 || abs(size.height - 620) > 1 { fail("window shape", "620 by 620, got \(size)") }
        if !(first.contentViewController is NSHostingController<WhatsNewWindowRoot>) { fail("window shape", "the window hosts WhatsNewWindowRoot") }
        if first.title != "What's New in COS Control" { fail("window shape", "the window's own title: \(first.title)") }
        print("PASS: What's New is one window: reopened and reopened after Close, it is the same one (620 x 620, never ordered in)")
    }

    static func wiring(helper: URL) async {
        let dir = helper.deletingLastPathComponent()
        let calls = dir.appendingPathComponent("calls.log"), mode = dir.appendingPathComponent("mode"), release = dir.appendingPathComponent("release")
        func count(_ verb: String) -> Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == verb }.count
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            print("check failed [install path]: the wiring checks did not finish within 120 s")
            exit(1)
        }
        try? "update".write(to: mode, atomically: true, encoding: .utf8)
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        let opened = Counter()
        model.showWhatsNew = { opened.value += 1 }

        // A background check finds the update: the glasses and the banner, never a window.
        await model.runScheduledAppUpdateCheck(.launch)
        if model.appUpdateFlow.phase != .ready { fail("background check", "the stand-in offers 9.9.9: ready, got \(model.appUpdateFlow.phase)") }
        if opened.value != 0 { fail("background check", "a background check opened What's New") }
        // The whatsNew the helper passed arrives in the model.
        if model.appUpdate.whatsNew?.sections.map(\.title) != ["Added", "Fixed"] || model.appUpdate.whatsNew?.summary != "From the stand-in." {
            fail("helper whatsNew reaches the window", "got \(String(describing: model.appUpdate.whatsNew))")
        }
        if WhatsNewContent(model.appUpdate).sections.count != 2 { fail("helper whatsNew reaches the window", "the window's content") }

        // Check for updates finds it: What's New opens, once.
        await model.checkForAppUpdateManually()
        if opened.value != 1 { fail("check for updates opens", "Check for updates found an update: open once, got \(opened.value)") }
        if model.notice != nil || model.error != nil { fail("check for updates opens", "no notice line as well: \(model.notice ?? "") \(model.error ?? "")") }
        // The banner's Update (and Try again) path.
        model.presentWhatsNew()
        if opened.value != 2 { fail("banner opens", "presentWhatsNew opens the window") }

        // Download and install: the real installAppUpdate, against the stand-in (which holds stage-app-update open).
        let presenter = WhatsNewWindowPresenter()
        let window = presenter.prepare(model: model)
        model.installAppUpdate()
        if case .staging = model.appUpdateFlow.phase {} else { fail("install path", "Download and install stages at once, got \(model.appUpdateFlow.phase)") }
        if !model.busy { fail("install path", "an install holds busy, so nothing else starts") }
        if WhatsNewFooter(model.appUpdateFlow.phase, busy: model.busy).primaryEnabled { fail("install path", "no second install from the footer") }
        await until("the helper's SHA-256 line") { model.appUpdateFlow.phase == .staging("Checking SHA-256…") }
        if WhatsNewFooter(model.appUpdateFlow.phase, busy: model.busy).status != "Checking…" { fail("install path", "the footer shows Checking…") }
        if count("stage-app-update") != 1 { fail("install path", "exactly one stage-app-update, got \(count("stage-app-update"))") }
        // Close the window while it stages (Close is enabled): the install carries on.
        let staging = WhatsNewFooter(model.appUpdateFlow.phase, busy: model.busy)
        if !staging.cancelEnabled || staging.cancelTitle != "Close" { fail("close does not cancel", "Close is offered while staging: \(staging)") }
        presenter.close()
        try? await Task.sleep(for: .milliseconds(300))
        if case .staging = model.appUpdateFlow.phase {} else { fail("close does not cancel", "closing the window changed the install: \(model.appUpdateFlow.phase)") }
        if !model.busy { fail("close does not cancel", "closing the window ended the install") }
        // The stand-in refuses (a meeting is running), in the helper's own words.
        FileManager.default.createFile(atPath: release.path, contents: Data())
        await until("the refusal") { if case .failed = model.appUpdateFlow.phase { return true } else { return false } }
        let refusal = "Finish this first, then install: meeting=1. The glasses server was not touched."
        if model.appUpdateFlow.phase != .failed(refusal) { fail("install path", "the helper's refusal: \(model.appUpdateFlow.phase)") }
        let footer = WhatsNewFooter(model.appUpdateFlow.phase, busy: model.busy)
        if footer.primary != .tryAgain || !footer.primaryEnabled
            || footer.status != "Finish your meeting first, then install. The glasses server was not touched." {
            fail("install path", "Try again with the refusal in words: \(footer)")
        }
        if model.busy || count("apply-app-update") != 0 { fail("install path", "a refused stage never applies") }
        if presenter.prepare(model: model) !== window { fail("single window", "the same window after an install attempt") }

        // Try again runs the same path again.
        try? FileManager.default.removeItem(at: release)
        model.installAppUpdate()
        await until("the second stage") { count("stage-app-update") == 2 }
        FileManager.default.createFile(atPath: release.path, contents: Data())
        await until("the second refusal") { if case .failed = model.appUpdateFlow.phase { return !model.busy } else { return false } }

        // Up to date now: Check for updates says so and opens nothing.
        try? "uptodate".write(to: mode, atomically: true, encoding: .utf8)
        await model.checkForAppUpdateManually()
        if opened.value != 2 { fail("check for updates opens", "an up-to-date answer opened What's New") }
        if model.appUpdateFlow.phase != .none { fail("check for updates opens", "up to date clears the offer, got \(model.appUpdateFlow.phase)") }
        print("PASS: What's New wiring (background check never opens, Check for updates and the banner open it, Download and install stages, close does not cancel, refusal and Try again)")
    }

    // MARK: render

    static func renderAll(_ out: URL, whatsNew: URL, bundled: URL) throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: whatsNew))
        guard AppUpdateWhatsNew(raw) != nil else { fatalError("\(whatsNew.path) is not a usable whatsNew") }
        func info(_ whatsNew: JSONValue?) -> AppUpdateInfo {
            var details: [String: JSONValue] = ["updateAvailable": .bool(true), "latestVersion": .string("0.5.275"), "latestBuild": .number(328),
                                                "reason": .string("newer"),
                                                "notes": .string("Updates now open a What's New window with what changed. Download and install shows each step, and COS Control reopens by itself.")]
            if let whatsNew { details["whatsNew"] = whatsNew }
            return AppUpdateInfo(details)
        }
        let full = info(raw), notesOnly = info(nil)
        var ready = AppUpdateFlow()
        ready.offer(full, currentVersion: "0.5.274", currentBuild: 327)
        var downloading = ready; _ = downloading.beginInstall(); downloading.progress("Downloading COS Control update…")
        var installing = downloading; installing.staged()
        var failed = downloading
        failed.fail("Finish this first, then install: meeting=1. The glasses server was not touched.")
        let states: [(String, AppUpdateInfo, AppUpdateFlow)] = [
            ("whats-new-ready-full", full, ready), ("whats-new-ready-notes-only", notesOnly, ready),
            ("whats-new-downloading", full, downloading), ("whats-new-installing", full, installing), ("whats-new-failed", full, failed),
        ]
        for (name, offer, flow) in states {
            let shown = WhatsNewPresentation.present(.offer, info: offer, flow: flow, frozen: WhatsNewContent(offer), busy: flow.installing)
            try render(WhatsNewView(presentation: shown, onInstall: {}, onCancel: {}), name: name, out: out)
        }
        // After an update: this build's words, Done alone.
        let installedContent = WhatsNewAfterUpdate.content(appcast: AppUpdateInfo(), bundled: try? Data(contentsOf: bundled), version: "0.5.275", build: 328)
        let installed = WhatsNewPresentation.present(.installed(content: installedContent, version: "0.5.275", build: 328),
                                                     info: AppUpdateInfo(), flow: AppUpdateFlow(), frozen: nil, busy: false)
        try render(WhatsNewView(presentation: installed, onInstall: {}, onCancel: {}), name: "whats-new-installed", out: out)
        print("wrote PNGs to \(out.path)")
    }

    static func render<V: View>(_ view: V, name: String, out: URL) throws {
        let size = NSSize(width: WhatsNewView.width, height: WhatsNewView.height)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
            window.close()
        }
    }
}
