import AppKit
import SwiftUI

/// 2026-10-09 (Miles, after the 0.5.276 gold banner): the version card is gone; the panel header's refresh button
/// refreshes the status AND checks for updates, and the subtitle line answers. With the whole app compiled:
///
///   check <fake helper>           the model, executed against a stand-in helper: no update gives Up to date for about
///                                 4 s, a failure gives Couldn't check for about 6 s, a second click while a check runs
///                                 starts no second check, rapid clicks never stack timers, a background check that is
///                                 running never hangs the button, and the button runs both the status refresh and the
///                                 check.
///   render <dir> <fake helper>    PNGs, light and dark, of the real menu-bar panel (ControlPanel): idle, checking, up to
///                                 date, failed, update available; variant A (the shipped stamp, under the lockup) and
///                                 variant B (render-only: inline after "Control"); and the whole idle panel to its footer.
///
/// The stand-in helper answers everything; nothing reaches the real helper, the appcast or the server. The binary runs
/// with a scratch home. Windows are never ordered in, the process can never become active, and no event is sent.
@main @MainActor struct RefreshCheckRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "check":
            guard args.count > 1 else { fatalError("usage: check <fake helper>") }
            await checkModel(helper: URL(fileURLWithPath: args[1]))
        case "render":
            guard args.count > 2 else { fatalError("usage: render <dir> <fake helper>") }
            let out = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try await renderAll(out, helper: URL(fileURLWithPath: args[2]))
        default: fatalError("usage: check <fake helper> | render <dir> <fake helper>")
        }
    }

    static func fail(_ behaviour: String, _ detail: String) -> Never {
        print("check failed [\(behaviour)]: \(detail)")
        exit(1)
    }

    /// The stand-in helper's folder: `mode` picks its answer to check-app-update (uptodate, fail, unreachable, update,
    /// hold: wait for `release`, then up to date), and every verb is logged to calls.log.
    struct Stand {
        let dir: URL
        init(_ helper: URL) { dir = helper.deletingLastPathComponent() }
        func mode(_ word: String) { try? word.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
        func release() { FileManager.default.createFile(atPath: dir.appendingPathComponent("release").path, contents: Data()) }
        func unrelease() { try? FileManager.default.removeItem(at: dir.appendingPathComponent("release")) }
        func calls(_ verb: String) -> Int {
            ((try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { $0 == verb }.count
        }
    }

    static func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    static func until(_ what: String, _ condition: () -> Bool) async {
        let started = Date()
        while !condition() {
            if Date().timeIntervalSince(started) > 15 { fail("no hang", "waited 15 s for \(what)") }
            await sleep(0.02)
        }
    }

    // MARK: check

    static func checkModel(helper: URL) async {
        let stand = Stand(helper)
        // A hang on the main actor would never fail: a watchdog off it turns one into a failure.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            print("check failed [no hang]: the refresh-check checks did not finish within 120 s")
            exit(1)
        }
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        if model.headerUpdateStatus != .idle { fail("idle at start", "a new model's line is idle, got \(model.headerUpdateStatus)") }

        // No update: Up to date, held about 4 s, then idle. The header reports on the line, not the notice or an alert.
        stand.mode("uptodate")
        await model.checkForUpdatesFromHeader()
        if model.headerUpdateStatus != .upToDate { fail("outcome up to date", "no update must give Up to date, got \(model.headerUpdateStatus)") }
        if model.notice != nil || model.error != nil { fail("reports in header", "the header check must not raise the notice or the alert: \(model.notice ?? "nil") / \(model.error ?? "nil")") }
        if model.updateCheckInFlight { fail("in flight cleared", "the check ended but still shows Checking") }
        await sleep(3.0)
        if model.headerUpdateStatus != .upToDate { fail("up to date hold", "Up to date went away before 4 s") }
        await sleep(1.6)
        if model.headerUpdateStatus != .idle { fail("up to date resets", "Up to date must go back to idle after about 4 s, got \(model.headerUpdateStatus)") }

        // Rapid clicks never stack timers: a second result restarts the hold, the first timer cannot cut it short.
        await model.checkForUpdatesFromHeader()
        await sleep(2.5)
        await model.checkForUpdatesFromHeader()
        await sleep(2.0)
        if model.headerUpdateStatus != .upToDate { fail("no stacked timers", "the first click's timer cleared the second click's Up to date") }
        await sleep(2.5)
        if model.headerUpdateStatus != .idle { fail("up to date resets", "the second Up to date never went back to idle") }

        // A failure: Couldn't check, held about 6 s, then idle. Both the helper's refusal and an unreachable feed.
        stand.mode("fail")
        await model.checkForUpdatesFromHeader()
        if model.headerUpdateStatus != .failed { fail("outcome failed", "a failed check must give Couldn't check, got \(model.headerUpdateStatus)") }
        if model.error != nil { fail("reports in header", "the header check must not raise the alert: \(model.error ?? "")") }
        await sleep(4.6)
        if model.headerUpdateStatus != .failed { fail("failed hold", "Couldn't check went away before 6 s") }
        await sleep(2.0)
        if model.headerUpdateStatus != .idle { fail("failed resets", "Couldn't check must go back to idle after about 6 s, got \(model.headerUpdateStatus)") }
        stand.mode("unreachable")
        await model.checkForUpdatesFromHeader()
        if model.headerUpdateStatus != .failed { fail("outcome failed", "an unreachable feed must give Couldn't check, got \(model.headerUpdateStatus)") }

        // A second click while a check runs starts no second check, and the line says Checking meanwhile.
        stand.unrelease(); stand.mode("hold")
        let before = stand.calls("check-app-update")
        let first = Task { await model.checkForUpdatesFromHeader() }
        await until("the held check") { stand.calls("check-app-update") == before + 1 }
        let second = Task { await model.checkForUpdatesFromHeader() }
        await sleep(0.4)
        if stand.calls("check-app-update") != before + 1 { fail("no second check", "a click during a check called the helper again (\(stand.calls("check-app-update") - before) calls)") }
        if HeaderUpdateStatus.shown(inFlight: model.updateCheckInFlight, status: model.headerUpdateStatus) != .checking {
            fail("checking words", "the line must say Checking while a check runs")
        }
        stand.release()
        await first.value; await second.value
        if stand.calls("check-app-update") != before + 1 { fail("no second check", "two clicks made \(stand.calls("check-app-update") - before) checks") }
        if model.headerUpdateStatus != .upToDate { fail("outcome up to date", "the held check ended up to date, got \(model.headerUpdateStatus)") }

        // A click while a check the header did not start is running leaves the line to that check: it never sticks at
        // Checking once that check ends.
        stand.unrelease()
        let other = Task { _ = await model.checkForAppUpdateManually() }
        await until("the other check") { model.updateCheckInFlight }
        let click = Task { await model.checkForUpdatesFromHeader() }
        await sleep(0.3)
        stand.release()
        await other.value; await click.value
        if model.headerUpdateStatus == .checking { fail("no stuck checking", "the line stayed at Checking after the check ended") }

        // A background check that is running (launch, the periodic timer) never hangs the button: the click waits for
        // it, then runs once and answers (0.5.275).
        let fresh = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        stand.unrelease()
        let start = stand.calls("check-app-update")
        let background = Task { await fresh.runScheduledAppUpdateCheck(.launch) }
        await until("the background check") { stand.calls("check-app-update") == start + 1 }
        let waiting = Task { await fresh.checkForUpdatesFromHeader() }
        await sleep(0.4)
        if stand.calls("check-app-update") != start + 1 { fail("no second check", "the click called the helper while a background check ran") }
        if !fresh.updateCheckInFlight { fail("checking words", "the click must say Checking while it waits for the background check") }
        stand.release()
        await background.value; await waiting.value
        if stand.calls("check-app-update") != start + 2 { fail("background no hang", "expected the background check, then one manual check, got \(stand.calls("check-app-update") - start)") }
        if fresh.headerUpdateStatus != .upToDate { fail("background no hang", "the click must answer after the background check, got \(fresh.headerUpdateStatus)") }

        // The button's action does both: the status refresh and the update check.
        stand.mode("uptodate")
        let both = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        let statusBefore = stand.calls("status"), checksBefore = stand.calls("check-app-update")
        await both.refreshAndCheckForUpdates()
        if stand.calls("status") != statusBefore + 1 { fail("both actions", "the refresh button must refresh the status (\(stand.calls("status") - statusBefore) status calls)") }
        if stand.calls("check-app-update") != checksBefore + 1 { fail("both actions", "the refresh button must check for updates (\(stand.calls("check-app-update") - checksBefore) checks)") }
        if both.headerUpdateStatus != .upToDate { fail("both actions", "the refresh button's check must answer on the line, got \(both.headerUpdateStatus)") }
        print("PASS: refresh-check model (Up to date 4 s, Couldn't check 6 s, no second check, no stacked timers, no stuck Checking, background check never hangs it, refresh and check both run)")
    }

    // MARK: render

    static func offer(_ available: Bool, _ version: String?, _ build: Int?, reason: String) -> AppUpdateInfo {
        var details: [String: JSONValue] = ["updateAvailable": .bool(available), "reason": .string(reason)]
        if let version { details["latestVersion"] = .string(version) }
        if let build { details["latestBuild"] = .number(Double(build)) }
        if available { details["notes"] = .string("Update banner at the top of the panel.") }
        return AppUpdateInfo(details)
    }

    static func panelModel(_ helper: URL) -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        model.status = ServerStatus([
            "installed": .bool(true), "serviceLoaded": .bool(true), "running": .bool(true), "managedContract": .bool(true),
            "runtimeState": .string("managedHealthy"), "ownershipVerified": .bool(true),
            "version": .string("6.66.0"), "installedVersion": .string("6.66.0"),
        ])
        return model
    }

    static func renderAll(_ out: URL, helper: URL) async throws {
        let stand = Stand(helper)
        stand.release()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let idle = panelModel(helper)
            try panel(idle, appearance: appearance, name: "idle", out: out)
            try panel(idle, appearance: appearance, name: "variant-A-idle", out: out)
            try panel(idle, appearance: appearance, name: "variant-B-idle", out: out, inline: true)
            try panel(idle, appearance: appearance, name: "idle-full-panel", out: out, height: nil)

            let checking = panelModel(helper)
            checking.busy = true
            checking.updateCheckInFlight = true
            try panel(checking, appearance: appearance, name: "checking", out: out)

            let upToDate = panelModel(helper)
            stand.mode("uptodate")
            await upToDate.checkForUpdatesFromHeader()
            guard upToDate.headerUpdateStatus == .upToDate else { fatalError("render: the up-to-date check gave \(upToDate.headerUpdateStatus)") }
            try panel(upToDate, appearance: appearance, name: "up-to-date", out: out)

            let failed = panelModel(helper)
            stand.mode("fail")
            await failed.checkForUpdatesFromHeader()
            guard failed.headerUpdateStatus == .failed else { fatalError("render: the failed check gave \(failed.headerUpdateStatus)") }
            try panel(failed, appearance: appearance, name: "failed", out: out)

            let ready = panelModel(helper)
            ready.appUpdate = offer(true, "0.5.277", ControllerModel.currentBuild + 1, reason: "newer")
            try panel(ready, appearance: appearance, name: "update-available", out: out)
        }
        print("wrote PNGs to \(out.path)")
    }

    /// The panel's scroll document, top `height` pt (nil: all of it, to the footer), on the panel's own fill.
    static func panel(_ model: ControllerModel, appearance: NSAppearance.Name, name: String, out: URL, inline: Bool = false,
                      height: CGFloat? = 300) throws {
        let host = NSHostingView(rootView: ControlPanel(model: model, openActivity: { _ in }, versionStampInline: inline))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 640)
        defer { window.close() }
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        guard let scroll = findScroll(host), let document = scroll.documentView else { fatalError("the panel has no scroll view") }
        document.layoutSubtreeIfNeeded(); document.displayIfNeeded()
        let h = min(document.bounds.height, height ?? document.bounds.height)
        let crop = document.isFlipped ? NSRect(x: 0, y: 0, width: document.bounds.width, height: h)
            : NSRect(x: 0, y: document.bounds.height - h, width: document.bounds.width, height: h)
        guard let rep = document.bitmapImageRepForCachingDisplay(in: crop) else { fatalError("no bitmap") }
        document.cacheDisplay(in: crop, to: rep)
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { fatalError("no canvas") }
        canvas.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSColor(COSPalette.panel).setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try canvas.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
    }

    static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = findScroll(sub) { return found } }
        return nil
    }
}
