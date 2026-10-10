import AppKit
import SwiftUI

/// 2026-10-09 (Miles, like Vorssant): the update-ready badge with the whole app compiled.
///
///   check           the model wiring: every write of `appUpdate` moves `appUpdateFlow`, the icon follows it, a test
///                   model never schedules a check, and the menu-bar gold is the panel's accent token.
///   render <dir>    PNGs, light and dark: the real menu-bar panel (ControlPanel) with an update ready and with none,
///                   the banner alone while ready, staging, applying and failed, and the menu-bar glasses plain and
///                   ready on light, dark, highlighted and tinted menu bars.
///
/// Nothing contacts the helper, the appcast or the server: the model is made with no background work and the binary
/// runs with a scratch home. Windows are never ordered in, the process can never become active, and no event is sent.
@main @MainActor struct AppUpdateBadgeRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "check":
            checkWiring()
            if args.count > 1 { await manualDuringBackground(helper: URL(fileURLWithPath: args[1])) }
        case "render":
            guard args.count > 1 else { fatalError("usage: render <dir>") }
            let out = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try renderAll(out)
        default: fatalError("usage: check | render <dir>")
        }
    }

    static func fail(_ behaviour: String, _ detail: String) -> Never {
        print("check failed [\(behaviour)]: \(detail)")
        exit(1)
    }

    static func offer(_ available: Bool, _ version: String?, _ build: Int?, reason: String) -> AppUpdateInfo {
        var details: [String: JSONValue] = ["updateAvailable": .bool(available), "reason": .string(reason)]
        if let version { details["latestVersion"] = .string(version) }
        if let build { details["latestBuild"] = .number(Double(build)) }
        if available { details["notes"] = .string("Update banner at the top of the panel.") }
        return AppUpdateInfo(details)
    }

    // MARK: check

    static func checkWiring() {
        let model = ControllerModel(startBackgroundWork: false)
        guard !model.backgroundWorkEnabled else { fail("model wiring", "a test model must not run background work") }
        let current = ControllerModel.currentBuild
        if model.appUpdateFlow.phase != .none { fail("model wiring", "a new model starts with no banner") }
        model.appUpdate = offer(true, "9.9.9", current + 5, reason: "newer")
        if model.appUpdateFlow.phase != .ready { fail("model wiring", "a newer offer written to appUpdate must make the flow ready, got \(model.appUpdateFlow.phase)") }
        if MenuBarIcon.variant(for: model.appUpdateFlow.phase) != .updateReady { fail("model wiring", "the icon follows the model's flow") }
        // A background tick that missed the feed is merged into the live offer (checkForAppUpdate), so it stays ready.
        model.appUpdate = AppUpdateInfo.merging(previous: model.appUpdate, incoming: offer(false, nil, nil, reason: "unreachable"))
        if model.appUpdateFlow.phase != .ready { fail("model wiring", "an unreachable tick must not take the banner away") }
        model.appUpdate = offer(false, "9.9.9", current + 5, reason: "upToDate")
        if model.appUpdateFlow.phase != .none { fail("model wiring", "upToDate clears the banner") }
        model.appUpdate = offer(true, "9.9.9", current, reason: "newer")
        if model.appUpdateFlow.phase != .none { fail("model wiring", "an offer of the running build never shows a banner") }
        // Opening the panel in a test model schedules nothing (no helper, no network).
        model.panelOpenedForUpdates()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if model.updateCheckInFlight { fail("model wiring", "panel open in a test model must not check") }
        // The menu-bar gold is the panel's accent token, in both appearances.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            var a: NSColor?, b: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                a = MenuBarIcon.updateTint.usingColorSpace(.sRGB)
                b = NSColor(COSPalette.accent).usingColorSpace(.sRGB)
            }
            guard let a, let b else { fail("icon tint token", "could not resolve the colors") }
            let same = abs(a.redComponent - b.redComponent) < 0.004 && abs(a.greenComponent - b.greenComponent) < 0.004
                && abs(a.blueComponent - b.blueComponent) < 0.004
            if !same { fail("icon tint token", "\(name.rawValue): menu-bar gold \(a) is not COSPalette.accent \(b)") }
        }
        print("PASS: update-ready badge wiring (appUpdate moves the flow, the icon follows, no test check, gold = accent token)")
    }

    /// QA 2026-10-09 (main-actor spin): a background check is held open by a stand-in helper while Check for updates
    /// starts. The manual check must wait for it (no second helper call while the first runs), then run once, report,
    /// and leave the slot free: exactly two helper calls, then a third check may run. A spin on the main actor hangs
    /// the process, so a watchdog off the main actor turns a hang into a failure.
    static func manualDuringBackground(helper: URL) async {
        let dir = helper.deletingLastPathComponent()
        let calls = dir.appendingPathComponent("calls.log"), release = dir.appendingPathComponent("release")
        func count() -> Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == "check-app-update" }.count
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            print("check failed [manual check spin]: Check for updates did not finish within 30 s of a held background check")
            exit(1)
        }
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        let background = Task { await model.runScheduledAppUpdateCheck(.launch) }
        while count() < 1 { try? await Task.sleep(for: .milliseconds(20)) }
        let manual = Task { await model.checkForAppUpdateManually() }
        try? await Task.sleep(for: .milliseconds(400))
        if count() != 1 { fail("no overlap", "Check for updates called the helper while a background check was running (\(count()) calls)") }
        if !model.updateCheckInFlight { fail("no overlap", "Check for updates must show Checking while it waits") }
        FileManager.default.createFile(atPath: release.path, contents: Data())
        await background.value
        let outcome = await manual.value
        if count() != 2 { fail("manual check spin", "expected exactly 2 helper calls (background, then manual), got \(count())") }
        if model.updateCheckInFlight { fail("manual check spin", "Check for updates finished but still shows Checking") }
        if outcome != .upToDate { fail("manual check spin", "the manual check must report its answer, got \(outcome)") }
        await model.runScheduledAppUpdateCheck(.launch)
        if count() != 3 { fail("slot freed in task", "after both checks the slot must be free for the next one (\(count()) calls)") }
        print("PASS: Check for updates during a held background check: waits, runs once, reports, frees the slot (3 helper calls)")
    }

    // MARK: render

    static func renderAll(_ out: URL) throws {
        let v = ControllerModel.currentVersion, b = ControllerModel.currentBuild
        var ready = AppUpdateFlow()
        ready.offer(offer(true, "0.5.274", 327, reason: "newer"), currentVersion: v, currentBuild: b)
        var staging = ready; _ = staging.beginInstall(); staging.progress("Checking SHA-256…")
        var applying = staging; applying.staged()
        var failed = staging
        failed.fail("The download did not match the published SHA-256. The file was discarded.")
        for (name, flow) in [("banner-ready", ready), ("banner-staging", staging), ("banner-applying", applying), ("banner-failed", failed)] {
            try render(AppUpdateBanner(flow: flow, onUpdate: {}).padding(16), width: 390, name: name, out: out)
        }
        // The real panel: an update ready, and none.
        for (name, info) in [("panel-update-ready", offer(true, "0.5.274", 327, reason: "newer")),
                             ("panel-no-update", offer(false, "0.5.273", b, reason: "upToDate"))] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let model = panelModel()
                model.appUpdate = info
                try panel(model, appearance: appearance, name: name, out: out)
            }
        }
        try menuBar(out)
        print("wrote PNGs to \(out.path)")
    }

    static func panelModel() -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        model.status = ServerStatus([
            "installed": .bool(true), "serviceLoaded": .bool(true), "running": .bool(true), "managedContract": .bool(true),
            "runtimeState": .string("managedHealthy"), "ownershipVerified": .bool(true),
            "version": .string("6.66.0"), "installedVersion": .string("6.66.0"),
        ])
        return model
    }

    static func render<V: View>(_ view: V, width: CGFloat, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width).background(COSPalette.panel).cosControlTheme())
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(host.fittingSize.height, 40)))
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
            window.close()
        }
    }

    /// The panel's scroll document, top 360 pt (the banner, the header and the cards under it), as the menu bar shows it.
    static func panel(_ model: ControllerModel, appearance: NSAppearance.Name, name: String, out: URL) throws {
        let host = NSHostingView(rootView: ControlPanel(model: model, openActivity: { _ in }))
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
        let height = min(document.bounds.height, 360)
        let crop = document.isFlipped ? NSRect(x: 0, y: 0, width: document.bounds.width, height: height)
            : NSRect(x: 0, y: document.bounds.height - height, width: document.bounds.width, height: height)
        guard let rep = document.bitmapImageRepForCachingDisplay(in: crop) else { fatalError("no bitmap") }
        document.cacheDisplay(in: crop, to: rep)
        // The panel's own fill sits behind the scroll view, outside the document: lay the capture on it, as the menu
        // bar shows it (otherwise the dark header's light words land on a transparent, white-looking page).
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

    /// The glasses as a menu bar draws them, at 4x: a template image in the bar's own ink (black on a light bar, white
    /// on a dark one), the ready image as itself. Rows: light, light highlighted (the panel open), light over a blue
    /// wallpaper, then the same three dark. Columns: running plain, running ready, stopped plain, stopped ready.
    static func menuBar(_ out: URL) throws {
        let scale: CGFloat = 4
        let bars: [(String, NSAppearance.Name, NSColor, NSColor)] = [
            ("light bar", .aqua, NSColor(white: 0.965, alpha: 1), .black),
            ("light, panel open", .aqua, NSColor(white: 0.80, alpha: 1), .black),
            ("light over blue", .aqua, NSColor(red: 0.70, green: 0.79, blue: 0.90, alpha: 1), .black),
            ("dark bar", .darkAqua, NSColor(white: 0.13, alpha: 1), .white),
            ("dark, panel open", .darkAqua, NSColor(white: 0.30, alpha: 1), .white),
            ("dark over blue", .darkAqua, NSColor(red: 0.16, green: 0.24, blue: 0.38, alpha: 1), .white),
        ]
        let cells: [(String, MenuBarIcon.Variant)] = [("eyeglasses", .normal), ("eyeglasses", .updateReady),
                                                       ("eyeglasses.slash", .normal), ("eyeglasses.slash", .updateReady)]
        let cellW: CGFloat = 44, rowH: CGFloat = 24, labelW: CGFloat = 112
        let size = NSSize(width: labelW + cellW * CGFloat(cells.count), height: rowH * CGFloat(bars.count))
        for (file, rows) in [("menubar-icon-light", Array(bars[0..<3])), ("menubar-icon-dark", Array(bars[3..<6])), ("menubar-icon-all", bars)] {
            let canvas = NSSize(width: size.width, height: rowH * CGFloat(rows.count))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = canvas
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for (index, bar) in rows.enumerated() {
                let y = canvas.height - rowH * CGFloat(index + 1)
                bar.2.setFill(); NSRect(x: 0, y: y, width: canvas.width, height: rowH).fill()
                (bar.3 == .black ? NSColor(white: 0, alpha: 0.6) : NSColor(white: 1, alpha: 0.6)).set()
                NSAttributedString(string: bar.0, attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: bar.3.withAlphaComponent(0.6)])
                    .draw(at: NSPoint(x: 6, y: y + 7))
                NSAppearance(named: bar.1)?.performAsCurrentDrawingAppearance {
                    for (column, cell) in cells.enumerated() {
                        let image = MenuBarIcon.compose(systemName: cell.0, variant: cell.1)
                        let origin = NSPoint(x: labelW + cellW * CGFloat(column) + (cellW - image.size.width) / 2, y: y + (rowH - image.size.height) / 2)
                        let rect = NSRect(origin: origin, size: image.size)
                        if image.isTemplate { drawTemplate(image, in: rect, ink: bar.3) } else { image.draw(in: rect) }
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(file).png"))
        }
    }

    /// A template image in one ink, as NSStatusBarButton draws it.
    static func drawTemplate(_ image: NSImage, in rect: NSRect, ink: NSColor) {
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            ink.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }
}
