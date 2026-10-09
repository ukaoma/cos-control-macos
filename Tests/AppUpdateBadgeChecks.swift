import AppKit
import Foundation

/// 2026-10-09 (Miles, like Vorssant): the update-ready badge, executed against Sources/Models.swift alone. The version
/// rule, the check schedule, the banner's phases and the menu-bar icon that follows them. No helper, no network, no
/// window, no status item. Every failure names the behaviour it guards as "check failed [<behaviour>]", which is what
/// Tests/mutate-app-update-badge.py matches a killing failure against.
@main @MainActor struct AppUpdateBadgeChecks {
    static var passed = 0

    static func check(_ condition: Bool, _ behaviour: String, _ detail: String = "") {
        guard condition else {
            print("check failed [\(behaviour)]: \(detail)")
            exit(1)
        }
        passed += 1
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        versions()
        schedule()
        flow()
        icon()
        print("PASS: update-ready badge, \(passed) checks (version rule, schedule, phases, menu-bar icon)")
    }

    static func info(_ available: Bool, _ version: String?, _ build: Int?, reason: String? = nil) -> AppUpdateInfo {
        var details: [String: JSONValue] = ["updateAvailable": .bool(available), "reason": .string(reason ?? (available ? "newer" : "upToDate"))]
        if let version { details["latestVersion"] = .string(version) }
        if let build { details["latestBuild"] = .number(Double(build)) }
        return AppUpdateInfo(details)
    }

    // MARK: version rule

    static func versions() {
        check(AppUpdateVersion.components("0.5.273") == [0, 5, 273], "version parse", "0.5.273")
        check(AppUpdateVersion.components(" 1.2 ") == [1, 2], "version parse", "spaces trimmed")
        for bad in ["", "0.5.", ".5", "0..5", "v0.5.274", "0.5.x", "0.5.-1", "0.5.274-beta", "٣.1", "1234567890.1"] {
            check(AppUpdateVersion.components(bad) == nil, "version malformed", "\"\(bad)\" must not parse")
        }
        check(AppUpdateVersion.compare("0.5.274", "0.5.273") == .orderedDescending, "version order", "274 > 273")
        check(AppUpdateVersion.compare("0.5.10", "0.5.9") == .orderedDescending, "version order", "numeric, not text")
        check(AppUpdateVersion.compare("0.6", "0.5.999") == .orderedDescending, "version order", "minor beats patch")
        check(AppUpdateVersion.compare("0.5", "0.5.0") == .orderedSame, "version order", "missing reads 0")
        check(AppUpdateVersion.compare("0.5.0", "0.5") == .orderedSame, "version order", "missing reads 0, either side")
        check(AppUpdateVersion.compare("0.5.1", "0.5") == .orderedDescending, "version order", "0.5.1 is newer than 0.5")
        check(AppUpdateVersion.compare("0.5", "0.5.1") == .orderedAscending, "version order", "0.5 is older than 0.5.1")
        check(AppUpdateVersion.compare("0.5.272", "0.5.273") == .orderedAscending, "version order", "older")
        check(AppUpdateVersion.compare("0.5.x", "0.5.273") == nil, "version malformed", "compare refuses")

        let current = ("0.5.273", 326)
        func newer(_ v: String?, _ b: Int?) -> Bool {
            AppUpdateVersion.isNewer(latestVersion: v, latestBuild: b, currentVersion: current.0, currentBuild: current.1)
        }
        check(newer("0.5.274", 327), "build newer", "a newer build is an update")
        check(!newer("0.5.273", 326), "build equal", "the same build is not an update")
        check(!newer("0.5.272", 325), "build older", "an older appcast is not an update")
        check(newer("0.5.273", 327), "build authoritative", "a rebuild of the same version is an update")
        check(!newer("0.5.280", 320), "build authoritative", "a higher version with a lower build is a rollback, not an update")
        check(newer("0.5.274", nil), "version without build", "no build: the version decides")
        check(!newer("0.5.273", nil), "version without build", "equal version, no build")
        check(!newer("0.5.200", nil), "version without build", "older version, no build")
        check(!newer(nil, 400), "offer malformed", "no version is never an update")
        check(!newer("", 400), "offer malformed", "an empty version is never an update")
        check(!newer("0.5.x", 400), "offer malformed", "a malformed version is never an update")
        check(!AppUpdateVersion.isNewer(latestVersion: "0.5.274", latestBuild: nil, currentVersion: "dev", currentBuild: 0),
              "offer malformed", "a running version that does not parse and no build: not newer")
    }

    // MARK: schedule

    static func schedule() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var s = AppUpdateCheckSchedule()
        check(s.nextNap(now: t0) == 1, "schedule launch", "before any check the loop does not wait")
        check(s.shouldStart(.panelOpen, now: t0) && s.shouldStart(.periodic, now: t0), "schedule launch", "nothing checked yet: every trigger may run")
        check(s.begin(.launch, now: t0), "schedule launch", "launch checks")
        // No overlap.
        for trigger in [AppUpdateCheckSchedule.Trigger.launch, .periodic, .panelOpen, .manual] {
            check(!s.begin(trigger, now: t0.addingTimeInterval(7 * 3600)), "schedule no overlap", "\(trigger) during a running check")
        }
        s.finish()
        check(!s.inFlight, "schedule no overlap", "finish frees the slot")
        // Panel open: 15 minutes.
        check(!s.shouldStart(.panelOpen, now: t0.addingTimeInterval(14 * 60 + 59)), "schedule panel open", "14:59 is fresh")
        check(s.shouldStart(.panelOpen, now: t0.addingTimeInterval(15 * 60)), "schedule panel open", "15:00 is stale")
        // Periodic: 6 hours.
        check(!s.shouldStart(.periodic, now: t0.addingTimeInterval(6 * 3600 - 1)), "schedule periodic", "5:59:59 is not due")
        check(s.shouldStart(.periodic, now: t0.addingTimeInterval(6 * 3600)), "schedule periodic", "6:00:00 is due")
        // The loop never sleeps past 15 minutes, and wakes at the due time.
        check(s.nextNap(now: t0) == AppUpdateCheckSchedule.maximumNap, "schedule nap", "right after a check: the 15 minute cap")
        check(abs(s.nextNap(now: t0.addingTimeInterval(6 * 3600 - 300)) - 300) < 0.001, "schedule nap", "five minutes before due: five minutes")
        check(s.nextNap(now: t0.addingTimeInterval(9 * 3600)) == 1, "schedule nap", "overdue (a Mac that slept): one second")
        // Manual always runs when nothing is in flight, and resets the clock for the others.
        check(s.begin(.manual, now: t0.addingTimeInterval(60)), "schedule manual", "Check for updates runs a minute after launch")
        s.finish()
        check(!s.shouldStart(.panelOpen, now: t0.addingTimeInterval(60 + 14 * 60)), "schedule panel open", "measured from the last check of any kind")
        check(!s.shouldStart(.periodic, now: t0.addingTimeInterval(6 * 3600 + 30)), "schedule periodic", "a manual check pushes the periodic one back")
        // A panel-open check is recorded like any other.
        check(s.begin(.panelOpen, now: t0.addingTimeInterval(60 + 15 * 60)), "schedule panel open", "stale panel open checks")
        check(s.lastStarted == t0.addingTimeInterval(60 + 15 * 60), "schedule panel open", "and is the new last check")
        s.finish()
        // The intervals are the ones Miles asked for.
        check(AppUpdateCheckSchedule.periodicInterval == 6 * 3600, "schedule periodic", "every 6 hours")
        check(AppUpdateCheckSchedule.panelOpenStaleAfter == 15 * 60, "schedule panel open", "15 minutes")
        check(AppUpdateCheckSchedule.helperTimeout > 8 && AppUpdateCheckSchedule.helperTimeout <= 30, "schedule timeout",
              "bounded, and longer than the helper's own 8 s fetch")
    }

    // MARK: phases

    static func flow() {
        let v = "0.5.273", b = 326
        var f = AppUpdateFlow()
        check(f.phase == .none && !f.showsBanner, "flow none", "starts with no banner")
        f.offer(info(false, "0.5.273", 326), currentVersion: v, currentBuild: b)
        check(f.phase == .none, "flow none", "up to date stays none")
        f.offer(info(false, nil, nil, reason: "unreachable"), currentVersion: v, currentBuild: b)
        check(f.phase == .none, "flow check failure silent", "an unreachable feed never shows a banner")
        f.offer(info(true, "0.5.273", 326), currentVersion: v, currentBuild: b)
        check(f.phase == .none, "flow stale offer", "an offer of this very build is not an update")
        check(!f.beginInstall(), "flow install gate", "nothing to install from none")

        f.offer(info(true, "0.5.274", 327), currentVersion: v, currentBuild: b)
        check(f.phase == .ready && f.showsBanner, "flow ready", "a newer build is ready")
        check(f.versionLine == "Version 0.5.274 (build 327)", "flow ready", "banner line: \(f.versionLine)")
        f.progress("Downloading")
        f.staged()
        f.fail("x")
        check(f.phase == .ready, "flow install gate", "progress, staged and fail do nothing before Update")

        check(f.beginInstall(), "flow staging", "Update starts staging")
        check(f.phase == .staging(nil) && f.installing, "flow staging", "staging with no line yet")
        check(!f.beginInstall(), "flow install gate", "a second press never starts a second install")
        f.progress("  Checking SHA-256…\n")
        check(f.phase == .staging("Checking SHA-256…"), "flow staging", "the helper's progress line, trimmed")
        f.progress("   ")
        check(f.phase == .staging("Checking SHA-256…"), "flow staging", "a blank line keeps the last one")
        f.offer(info(false, "0.5.273", 326), currentVersion: v, currentBuild: b)
        check(f.phase == .staging("Checking SHA-256…") && f.versionLine.contains("0.5.274"), "flow install owns banner",
              "a check during the install changes nothing")
        f.staged()
        check(f.phase == .applying, "flow applying", "staged moves to applying")
        f.progress("late line")
        check(f.phase == .applying, "flow applying", "a late staging line does not move it back")
        f.fail("Could not start the updater.")
        check(f.phase == .failed("Could not start the updater."), "flow failed", "the helper's own words")
        check(f.showsBanner && !f.installing, "flow failed", "the banner stays, nothing is running")

        f.offer(info(true, "0.5.274", 327), currentVersion: v, currentBuild: b)
        check(f.phase == .failed("Could not start the updater."), "flow failed", "the failure stays while the offer stands")
        f.offer(info(false, nil, nil, reason: "unreachable"), currentVersion: v, currentBuild: b)
        // (merging keeps a live offer across an unreachable tick in the model; here the raw payload is not an offer)
        check(f.phase == .none, "flow failed", "no offer any more: the banner goes")
        f.offer(info(true, "0.5.274", 327), currentVersion: v, currentBuild: b)
        check(f.beginInstall(), "flow staging", "Update again")
        f.fail("   ")
        check(f.phase == .failed("The update did not install."), "flow failed", "an empty error still says something")
        check(f.beginInstall() && f.phase == .staging(nil), "flow retry", "Try again stages again")
        f.fail("The download did not match the published SHA-256. The file was discarded.")
        f.offer(info(true, "0.5.275", 328), currentVersion: v, currentBuild: b)
        check(f.versionLine == "Version 0.5.275 (build 328)", "flow retry", "a newer offer while failed names the newer build")
        f.offer(info(false, "0.5.275", 328), currentVersion: v, currentBuild: b)
        check(f.phase == .none && f.versionLine.isEmpty, "flow none", "up to date clears the banner and its version")

        // The sticky offer: the model merges an unreachable tick into the previous offer, and the flow keeps ready.
        let offer = info(true, "0.5.274", 327)
        let merged = AppUpdateInfo.merging(previous: offer, incoming: info(false, nil, nil, reason: "unreachable"))
        f.offer(merged, currentVersion: v, currentBuild: b)
        check(f.phase == .ready, "flow check failure silent", "an unreachable tick keeps a live offer ready")
        var noBuild = AppUpdateFlow()
        noBuild.offer(info(true, "0.5.274", nil), currentVersion: v, currentBuild: b)
        check(noBuild.phase == .ready && noBuild.versionLine == "Version 0.5.274", "flow ready", "no build named: the version alone")
    }

    // MARK: icon

    static func icon() {
        check(MenuBarIcon.variant(for: .none) == .normal, "icon follows state", "none is the plain glasses")
        for phase in [AppUpdatePhase.ready, .staging(nil), .staging("x"), .applying, .failed("x")] {
            check(MenuBarIcon.variant(for: phase) == .updateReady, "icon follows state", "\(phase) is the gold glasses")
        }
        // The icon follows the flow end to end: a failed check never tints it.
        var f = AppUpdateFlow()
        f.offer(info(false, nil, nil, reason: "unreachable"), currentVersion: "0.5.273", currentBuild: 326)
        check(MenuBarIcon.variant(for: f.phase) == .normal, "icon follows state", "a failed check leaves the glasses plain")
        f.offer(info(true, "0.5.274", 327), currentVersion: "0.5.273", currentBuild: 326)
        check(MenuBarIcon.variant(for: f.phase) == .updateReady, "icon follows state", "a ready update tints them")
        check(MenuBarIcon.accessibilityLabel(.updateReady).contains("update available"), "icon follows state", "VoiceOver hears it")

        let plain = MenuBarIcon.compose(systemName: "eyeglasses", variant: .normal)
        let ready = MenuBarIcon.compose(systemName: "eyeglasses", variant: .updateReady)
        check(plain.isTemplate, "icon template", "the plain glasses follow the menu bar")
        check(!ready.isTemplate, "icon color", "the ready glasses are not a template (a menu bar drops a template's color)")
        check(ready.size.height == plain.size.height && ready.size.width == plain.size.width + MenuBarIcon.dotRoom
              && ready.size.width > ready.size.height + 1, "icon size", "the glyph 1:1, the dot's room on the right, still landscape")
        for name in ["eyeglasses", "eyeglasses.slash"] {
            let gap = dotClearance(MenuBarIcon.compose(systemName: name, variant: .normal))
            check(gap >= 0.75, "icon dot clear", "\(name): the dot must sit outside the glyph, at least 0.75 pt from its ink (\(String(format: "%.2f", gap)) pt)")
        }
        check(MenuBarIcon.image(systemName: "eyeglasses", variant: .updateReady) === MenuBarIcon.image(systemName: "eyeglasses", variant: .updateReady),
              "icon cache", "made once per variant")

        for (name, appearance, expected) in [("light", NSAppearance.Name.aqua, (0.537, 0.400, 0.176)),
                                             ("dark", NSAppearance.Name.darkAqua, (0.788, 0.659, 0.431))] {
            guard let a = NSAppearance(named: appearance) else { continue }
            var readyStats = (gold: 0, other: 0, dot: false), plainColored = 0
            a.performAsCurrentDrawingAppearance {
                readyStats = pixels(ready, expected: expected)
                let p = pixels(plain, expected: expected)
                plainColored = p.gold
            }
            check(readyStats.gold > 20, "icon color", "\(name): the ready glasses are drawn in gold (\(readyStats.gold) gold pixels)")
            check(readyStats.other == 0, "icon color", "\(name): every drawn pixel of the ready glasses is gold (\(readyStats.other) are not)")
            check(readyStats.dot, "icon dot", "\(name): the dot sits at the top-right corner")
            check(plainColored == 0, "icon template", "\(name): the plain glasses carry no gold")
        }
        // Contrast: the light gold against a white bar and a black bar, at or above 4:1 (and so legible where the
        // menu bar's appearance is resolved differently from the app's).
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
        }
        let light = luminance((0.537, 0.400, 0.176)), dark = luminance((0.788, 0.659, 0.431))
        check(1.05 / (light + 0.05) >= 4 && (light + 0.05) / 0.05 >= 3.5, "icon contrast", "light gold on white and on black")
        check((dark + 0.05) / (luminance((0.12, 0.12, 0.12)) + 0.05) >= 4.5, "icon contrast", "dark gold on a dark bar")
    }

    /// The plain glyph at 8x; the shortest distance (pt) from any of its ink to the edge of the ready image's dot, which
    /// sits in the top-right corner of a canvas `dotRoom` wider. Negative when they overlap.
    static func dotClearance(_ glyph: NSImage) -> Double {
        let scale: CGFloat = 8
        let w = Int(glyph.size.width * scale), h = Int(glyph.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return -1 }
        rep.size = glyph.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return -1 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        glyph.draw(in: NSRect(origin: .zero, size: glyph.size))
        NSGraphicsContext.restoreGraphicsState()
        let r = Double(MenuBarIcon.dotDiameter) / 2
        // Dot centre, in points from the top-left of the glyph's own canvas.
        let cx = Double(glyph.size.width + MenuBarIcon.dotRoom) - r, cy = r
        var nearest = Double.infinity
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 else { continue }
                let px = (Double(x) + 0.5) / Double(scale), py = (Double(y) + 0.5) / Double(scale)
                nearest = min(nearest, ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot() - r)
            }
        }
        return nearest
    }

    /// Draws the image at 4x into a clear bitmap and counts opaque pixels that are (or are not) the expected gold, and
    /// whether the top-right corner (the dot) is gold.
    static func pixels(_ image: NSImage, expected: (Double, Double, Double)) -> (gold: Int, other: Int, dot: Bool) {
        let scale: CGFloat = 4
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (0, 0, false) }
        // The point size BEFORE the context: a context made first draws 1 pt to 1 pixel, in the bottom-left corner.
        rep.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return (0, 0, false) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var gold = 0, other = 0
        func isGold(_ c: NSColor) -> Bool {
            guard c.alphaComponent > 0.9, let rgb = c.usingColorSpace(.sRGB) ?? c.usingColorSpace(.deviceRGB) else { return false }
            return abs(Double(rgb.redComponent) - expected.0) < 0.09 && abs(Double(rgb.greenComponent) - expected.1) < 0.09
                && abs(Double(rgb.blueComponent) - expected.2) < 0.09
        }
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { continue }
                if isGold(c) { gold += 1 } else { other += 1 }
            }
        }
        // The dot's centre: 2.5 pt in from the top-right corner (colorAt's y runs from the top).
        let cx = w - Int(MenuBarIcon.dotDiameter / 2 * scale), cy = Int(MenuBarIcon.dotDiameter / 2 * scale)
        let dot = rep.colorAt(x: cx, y: cy).map(isGold) ?? false
        return (gold, other, dot)
    }
}
