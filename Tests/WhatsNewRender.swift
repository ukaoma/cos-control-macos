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
        case "render":
            guard args.count > 2 else { fatalError("usage: render <dir> <whatsNew.json>") }
            let out = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try renderAll(out, whatsNew: URL(fileURLWithPath: args[2]))
        default: fatalError("usage: check <fake helper> | render <dir> <whatsNew.json>")
        }
    }

    static func fail(_ behaviour: String, _ detail: String) -> Never {
        print("check failed [\(behaviour)]: \(detail)")
        exit(1)
    }

    final class Counter { var value = 0 }

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
        func until(_ what: String, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(15)
            while !condition() {
                if Date() > end { fail("install path", "timed out waiting for \(what)") }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("check failed [install path]: the wiring checks did not finish within 60 s")
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
        // Close the window while it stages: the install carries on.
        presenter.close()
        try? await Task.sleep(for: .milliseconds(300))
        if case .staging = model.appUpdateFlow.phase {} else { fail("close does not cancel", "closing the window changed the install: \(model.appUpdateFlow.phase)") }
        if !model.busy { fail("close does not cancel", "closing the window ended the install") }
        // The stand-in refuses (a meeting is running), in the helper's own words.
        FileManager.default.createFile(atPath: release.path, contents: Data())
        await until("the refusal") { if case .failed = model.appUpdateFlow.phase { return true } else { return false } }
        let refusal = "Finish this first, then install: meeting=1. The glasses server was not touched."
        if model.appUpdateFlow.phase != .failed(refusal) { fail("install path", "the helper's words: \(model.appUpdateFlow.phase)") }
        let footer = WhatsNewFooter(model.appUpdateFlow.phase, busy: model.busy)
        if footer.primary != .tryAgain || !footer.primaryEnabled || footer.status != refusal { fail("install path", "Try again with the refusal: \(footer)") }
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

    static func renderAll(_ out: URL, whatsNew: URL) throws {
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
            try render(WhatsNewView(content: WhatsNewContent(offer), flow: flow, busy: flow.installing, onInstall: {}, onCancel: {}), name: name, out: out)
        }
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
