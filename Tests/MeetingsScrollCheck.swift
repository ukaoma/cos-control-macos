import AppKit
import SwiftUI
import Vision

/// 0.5.393 Meetings scroll (D4, 2026-11-12; Miles 23:43: "meetings will not allow the user to scroll"). The Activity
/// window's own window (ActivityWindowPresenter.makeWindow), never ordered in, background work off, a scratch home, the
/// Today rail on as on his Mac. A day with eight meetings is selected. Every meeting here is invented.
///
///     check                   the gate: at 760x560 a real scroll-wheel event, sent through the window over the middle
///                             of the pane, brings the first meeting row fully on screen below the top bar
///     render <folder> WxH ... by hand: Meetings at each size before and after the same scroll, to PNGs, with the row's
///                             frame printed
///
/// What ActivitySizing does not prove: it checks the window's minimum and maximum SIZE for every tab, never whether the
/// content inside a tab can be reached at that size. This check drives the pane with the wheel and reads where the row is.
@main @MainActor struct MeetingsScrollCheck {
    static let titles = ["Bottle POS weekly", "Gina 1:1, content calendar", "Leadership sync", "October offer review",
                         "Team standup", "Design review", "Pricing page walkthrough", "Quarter close prep"]

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-meetings-scroll"),
              FileManager.default.homeDirectoryForCurrentUser.path.contains("cos-meetings-scroll") else {
            fputs("run through Tests/run-meetings-scroll.sh (a scratch home)\n", stderr); exit(2)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        // Vision loads its text model on the first request in a process: about 33 s here (02:36 to 03:50, every process).
        // Paid once up front on a blank image, so the 6 s bound on each pre-scroll read measures drawing, not the model load.
        let warm = Date()
        if let blank = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: blank, options: [:]).perform([request])
        }
        print(String(format: "text recognition warmed in %.2f s", Date().timeIntervalSince(warm)))
        switch arguments.first {
        case "check":
            // `check N` runs the four legs N times in one process (stability series); run.sh runs them once.
            let rounds = max(1, Int(arguments.dropFirst().first ?? "1") ?? 1)
            var failures: [String] = []
            var slowest = 0.0
            for round in 1...rounds {
                // Both frames: the classic window, and the Today rail beside the pane (Miles's).
                for surface in Surface.allCases {
                    for rail in [false, true] {
                        UserDefaults.standard.set(rail, forKey: TodayHome.enabledKey)
                        let result = drive(surface, size: NSSize(width: 760, height: 560), out: nil)
                        slowest = max(slowest, lastRead)
                        let name = (rounds > 1 ? "round \(round), " : "") + "\(surface.rawValue), Today rail \(rail ? "on" : "off")"
                        print(name + ": " + result.report)
                        if let failure = result.failure { failures.append(name + ": " + failure) }
                    }
                }
            }
            print(String(format: "%d round(s) of 4 legs, %d failing; slowest pre-scroll read %.2f s", rounds, failures.count, slowest))
            if !failures.isEmpty {
                for failure in failures { fputs("Meetings scroll check FAILED: \(failure)\n", stderr) }
                exit(1)
            }
            print("PASS: Meetings scroll: at 760x560, in Meetings and in Work's meeting picker, Today rail off and on, the wheel brings the first meeting row on screen below the top bar")
        case "render":
            guard arguments.count >= 3 else { fputs("render <folder> WxH ...\n", stderr); exit(2) }
            let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for text in arguments.dropFirst(2) {
                let parts = text.split(separator: "x").compactMap { Double($0) }
                precondition(parts.count == 2, "a size reads WxH: \(text)")
                for surface in Surface.allCases {
                    let size = NSSize(width: parts[0], height: parts[1])
                    let result = drive(surface, size: size, out: out)
                    print(surface.rawValue + " " + result.report + (result.failure.map { " | FAIL: \($0)" } ?? " | PASS"))
                    // The loading state inside the page: the build-up reads its size, so it has a floor there.
                    let window = Self.window(surface, model: Self.model(surface, loading: true))
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.setFrameOrigin(.zero)
                    window.setContentSize(size)
                    settle(window, seconds: 1.5)
                    snap(window, out: out, name: "\(surface.rawValue)-\(Int(size.width))x\(Int(size.height))-loading.png")
                    window.contentViewController = nil
                    window.close()
                }
            }
        default:
            fputs("usage: check | render <folder> WxH ...\n", stderr); exit(2)
        }
    }

    /// Both hosts of MeetingLibraryBody: Activity's Meetings pane, and Work's "Review a meeting" picker (about 175 pt more
    /// fixed above it: Work's header, its controls and the back row).
    enum Surface: String, CaseIterable { case meetings, workPicker = "work-picker" }

    /// Text only that surface draws, asserted before the first wheel event, so a leg can never pass on the other surface.
    static func marker(_ surface: Surface) -> String {
        surface == .meetings ? "Saved calls by day" : "Choose a saved meeting"
    }

    static func model(_ surface: Surface, loading: Bool = false) -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        let day = ControllerModel.currentMeetingDay()
        let month = ControllerModel.currentMeetingMonth()
        model.libraryMonth = month
        model.activityOpenSection = surface == .meetings ? .meetings : nil
        guard !loading else { model.libraryLoading = true; return model }
        model.libraryMeetings = titles.enumerated().compactMap { index, title in
            LibraryMeeting(.object(["filename": .string("\(day)_Meeting_\(index).md"), "month": .string(month),
                                    "domain": .string("quilt"), "title": .string(title), "date": .string(day)]))
        }
        model.libraryDays = [LibraryMeetingDay(date: day, count: titles.count)]
        model.libraryDay = day
        return model
    }

    static func settle(_ window: NSWindow, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Where `needle` is DRAWN, read off the window's own pixels with Vision text recognition, as a frame in points from
    /// the top of the content. SwiftUI builds no accessibility tree for a window that is never ordered in (the walk saw
    /// one element), and a frame from layout would also count a row that is clipped away. Text that is drawn is on screen.
    static func find(_ needle: String, in window: NSWindow) -> NSRect? {
        recognised(in: window).first { $0.text.contains(needle) }?.frame
    }

    /// Every line of text drawn in the window, with its frame in points from the top of the content.
    static func recognised(in window: NSWindow) -> [(text: String, frame: NSRect)] {
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return [] }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let image = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = content.bounds.size
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, NSRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height))
        }
    }

    /// Waits for `needle` to be DRAWN: reads the window's text every 0.25 s until it appears or `bound` seconds pass. Returns
    /// its frame, the seconds it took, and, on giving up, the text that was drawn instead.
    static func waitForDrawn(_ needle: String, in window: NSWindow, bound: TimeInterval = 6) -> (frame: NSRect?, seconds: Double, instead: [String]) {
        let start = Date()
        var lines: [(text: String, frame: NSRect)] = []
        while true {
            lines = recognised(in: window)
            if let hit = lines.first(where: { $0.text.contains(needle) }) { return (hit.frame, Date().timeIntervalSince(start), []) }
            if Date().timeIntervalSince(start) >= bound { return (nil, Date().timeIntervalSince(start), lines.map(\.text)) }
            settle(window, seconds: 0.25)
        }
    }

    /// One wheel notch through the window, as the trackpad sends it: a CGEvent scroll in pixels at a point in the window.
    static func wheel(_ window: NSWindow, at point: NSPoint, pixels: Int32) -> Bool {
        let screenPoint = window.convertPoint(toScreen: point)
        let primary = NSScreen.screens.first?.frame.height ?? 0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return false }
        cg.location = CGPoint(x: screenPoint.x, y: primary - screenPoint.y)
        guard let event = NSEvent(cgEvent: cg) else { return false }
        // To the view under the pointer, as AppKit routes a wheel event (it climbs the responder chain to the first view that
        // scrolls). window.sendEvent drops it for a window that is never ordered in.
        guard let target = window.contentView?.hitTest(point) else { return false }
        target.scrollWheel(with: event)
        return true
    }

    static var lastRead = 0.0

    static func describe(_ rect: NSRect?) -> String {
        guard let rect else { return "not drawn" }
        return "y \(Int(rect.minY))-\(Int(rect.maxY))"
    }

    /// The app's window (ActivityWindowPresenter.makeWindow). For the picker, a NEW hosting controller with the picker
    /// fixture, sized as the app's: swapping rootView on the built one keeps its @State (section, picker), so it would
    /// still draw what it first drew (Q1, 01:12).
    static func window(_ surface: Surface, model: ControllerModel) -> NSWindow {
        let window = ActivityWindowPresenter.makeWindow(model: model)
        if surface == .workPicker {
            let host = NSHostingController(rootView: ActivityWindow.workMeetingPickerFixture(model: model))
            host.sizingOptions = ActivityWindowPresenter.hostingSizing
            window.contentViewController = host
        }
        return window
    }

    static func drive(_ surface: Surface, size: NSSize, out: URL?) -> (report: String, failure: String?) {
        let model = Self.model(surface)
        let window = Self.window(surface, model: model)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(.zero)
        window.setContentSize(size)
        settle(window, seconds: 1.5)
        defer { window.contentViewController = nil; window.close() }
        let contentHeight = window.contentView?.bounds.height ?? 0
        let first = titles[0]
        // The surface's own text must be DRAWN before the first wheel event: a positive signal, polled, never a fixed sleep
        // (a single read missed once under load, 02:36). Bounded at 6 s; on giving up, what was drawn instead is reported.
        let drawn = waitForDrawn(marker(surface), in: window)
        let surfaceShown = drawn.frame
        let readNote = surfaceShown != nil
            ? String(format: "read in %.2f s", drawn.seconds)
            : String(format: "NOT read in %.2f s; drawn instead: %@", drawn.seconds, drawn.instead.prefix(24).joined(separator: " | "))
        lastRead = drawn.seconds
        let before = find(first, in: window)
        let home = find("Home", in: window)
        if let out { snap(window, out: out, name: "\(surface.rawValue)-\(Int(size.width))x\(Int(size.height))-\(UserDefaults.standard.bool(forKey: TodayHome.enabledKey) ? "rail" : "classic")-before.png") }
        // On the surface's own drawn title, the first thing a person scrolls over (in AppKit's coordinates, 0 at the bottom).
        // Where it is fixed (67f9d4d) there is no scroll view under it.
        let point = surfaceShown.map { NSPoint(x: $0.midX, y: contentHeight - $0.midY) } ?? NSPoint(x: size.width * 0.6, y: size.height * 0.45)
        let hit = window.contentView?.hitTest(point)
        var scrollView: NSView? = hit
        while let view = scrollView, !(view is NSScrollView) { scrollView = view.superview }
        // A notch at a time, as a person scrolls until the row shows: stop once it is drawn whole below the top bar.
        let barBottom = home?.maxY ?? 0
        func shown(_ rect: NSRect?) -> Bool { rect.map { $0.minY >= barBottom && $0.maxY <= contentHeight } ?? false }
        var sent = 0
        var built = true
        while sent < 24, !shown(find(first, in: window)) {
            guard wheel(window, at: point, pixels: -60) else { built = false; break }
            sent += 1
            settle(window, seconds: 0.15)
        }
        settle(window, seconds: 0.3)
        let scroller = scrollView as? NSScrollView
        let geometry = scroller.map { "clip y \(Int($0.contentView.bounds.origin.y)), document \(Int($0.documentView?.frame.height ?? -1)) pt in \(Int($0.contentView.bounds.height)) pt" } ?? "no scroll view"
        let after = find(first, in: window)
        if let out { snap(window, out: out, name: "\(surface.rawValue)-\(Int(size.width))x\(Int(size.height))-\(UserDefaults.standard.bool(forKey: TodayHome.enabledKey) ? "rail" : "classic")-after.png") }
        let viewport = (scrollView as? NSScrollView)?.contentView.bounds.height ?? 0
        let report = "\(Int(size.width))x\(Int(size.height)): \"\(marker(surface))\" \(describe(surfaceShown)) before the wheel (\(readNote)), viewport \(Int(viewport)) pt, content \(Int(contentHeight)) pt, top bar ends \(describe(home)), "
            + "first row before \(describe(before)), wheel sent \(sent)x-60 px over \(scrollView.map { String(describing: type(of: $0)) } ?? "no scroll view"), "
            + "first row after \(describe(after)); \(geometry)"
        guard surfaceShown != nil else { return (report, "\"\(marker(surface))\" is not drawn before the wheel: this leg is not on \(surface.rawValue)") }
        guard built else { return (report, "the wheel events could not be built") }
        // A row reachable through a slit is not reachable: the scroll view under the pointer shows at least two rows.
        guard viewport >= 120 else { return (report, "the scroll view under the pointer is \(Int(viewport)) pt tall, under 120 pt (about two rows)") }
        guard home != nil else { return (report, "the top bar's Home is not drawn, so there is no bar to measure below") }
        guard let after else { return (report, "after \(sent) wheel notches the first meeting row is not drawn (the list is not on screen)") }
        if after.minY < barBottom || after.maxY > contentHeight {
            return (report, "after the wheel the first meeting row is at \(describe(after)), outside \(Int(barBottom))-\(Int(contentHeight)) (below the top bar, inside the window)")
        }
        return (report, nil)
    }

    static func snap(_ window: NSWindow, out: URL, name: String) {
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
    }
}
