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
        switch arguments.first {
        case "check":
            var failures: [String] = []
            // Both frames: the classic window, and the Today rail beside the pane (Miles's).
            for surface in Surface.allCases {
                for rail in [false, true] {
                    UserDefaults.standard.set(rail, forKey: TodayHome.enabledKey)
                    let result = drive(surface, size: NSSize(width: 760, height: 560), out: nil)
                    let name = "\(surface.rawValue), Today rail \(rail ? "on" : "off")"
                    print(name + ": " + result.report)
                    if let failure = result.failure { failures.append(name + ": " + failure) }
                }
            }
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
                    let result = drive(surface, size: NSSize(width: parts[0], height: parts[1]), out: out)
                    print(surface.rawValue + " " + result.report + (result.failure.map { " | FAIL: \($0)" } ?? " | PASS"))
                }
            }
        default:
            fputs("usage: check | render <folder> WxH ...\n", stderr); exit(2)
        }
    }

    /// Both hosts of MeetingLibraryBody: Activity's Meetings pane, and Work's "Review a meeting" picker (about 175 pt more
    /// fixed above it: Work's header, its controls and the back row).
    enum Surface: String, CaseIterable { case meetings, workPicker = "work-picker" }

    static func model() -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        let day = ControllerModel.currentMeetingDay()
        let month = ControllerModel.currentMeetingMonth()
        model.libraryMonth = month
        model.libraryMeetings = titles.enumerated().compactMap { index, title in
            LibraryMeeting(.object(["filename": .string("\(day)_Meeting_\(index).md"), "month": .string(month),
                                    "domain": .string("quilt"), "title": .string(title), "date": .string(day)]))
        }
        model.libraryDays = [LibraryMeetingDay(date: day, count: titles.count)]
        model.libraryDay = day
        model.activityOpenSection = .meetings
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
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = content.bounds.size
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string, text.contains(needle) else { continue }
            let box = observation.boundingBox
            return NSRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        return nil
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

    static func describe(_ rect: NSRect?) -> String {
        guard let rect else { return "not drawn" }
        return "y \(Int(rect.minY))-\(Int(rect.maxY))"
    }

    static func drive(_ surface: Surface, size: NSSize, out: URL?) -> (report: String, failure: String?) {
        let model = model()
        let window = ActivityWindowPresenter.makeWindow(model: model)
        if surface == .workPicker {
            model.activityOpenSection = nil
            guard let controller = window.contentViewController as? NSHostingController<ActivityWindow> else { return ("", "Activity is not hosted") }
            controller.rootView = ActivityWindow.workMeetingPickerFixture(model: model)
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(.zero)
        window.setContentSize(size)
        settle(window, seconds: 1.5)
        defer { window.contentViewController = nil; window.close() }
        let contentHeight = window.contentView?.bounds.height ?? 0
        let first = titles[0]
        let before = find(first, in: window)
        let home = find("Home", in: window)
        if let out { snap(window, out: out, name: "\(surface.rawValue)-\(Int(size.width))x\(Int(size.height))-\(UserDefaults.standard.bool(forKey: TodayHome.enabledKey) ? "rail" : "classic")-before.png") }
        // The middle of the pane, right of the rail: on a pane that cannot scroll it lands on the calendar.
        let point = NSPoint(x: size.width * 0.6, y: size.height * 0.45)
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
        let report = "\(Int(size.width))x\(Int(size.height)): content \(Int(contentHeight)) pt, top bar ends \(describe(home)), "
            + "first row before \(describe(before)), wheel sent \(sent)x-60 px over \(scrollView.map { String(describing: type(of: $0)) } ?? "no scroll view"), "
            + "first row after \(describe(after)); \(geometry)"
        guard built else { return (report, "the wheel events could not be built") }
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
