import AppKit
import SwiftUI

/// 0.5.254 resize pass (Tests/run-activity-sizing.sh): the Activity window's content size limits for every tab, and
/// drawings of every tab for a before and after check. The window is the app's own (ActivityWindowPresenter.makeWindow)
/// and is never ordered in, the process can never become active, and nothing is clicked, typed or dragged. Background
/// work is off, so no tab loads live data: what is measured is the window's own layout.
///
///     check                       the gate (Tests/run.sh): the hosting controller leaves the limits alone, and for home
///                                 and every tab the window can't be made smaller than what the tab needs or than the
///                                 760 x 560 measured before 0.5.254, and can still grow
///     measure                     per tab, by hand: SwiftUI's minimum and maximum (sizeThatFits), the limits on the
///                                 window, and the size the window takes when asked to be tiny or huge
///     render <folder> WxH ...     by hand: each tab at each content size, light and dark, to PNGs
@main @MainActor struct ActivitySizing {
    static let tabs: [ActivitySection?] = [nil] + ActivitySection.allCases

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Activity's Work store opens its journal and card folder under the home folder: never the real one.
        guard NSHomeDirectory().contains("cos-activity-sizing"), FileManager.default.homeDirectoryForCurrentUser.path.contains("cos-activity-sizing") else {
            fputs("run through Tests/run-activity-sizing.sh (a scratch home)\n", stderr); exit(2)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "check":
            var failures: [String] = []
            for tab in tabs { failures += check(tab) }
            if !failures.isEmpty {
                for failure in failures { fputs("Activity sizing check FAILED: \(failure)\n", stderr) }
                exit(1)
            }
            print("PASS: Activity window sizing (0.5.254): no hosting size tracking; home and \(tabs.count - 1) tabs hold 760x560 at the least, grow without a limit, and never go below what they need")
        case "measure":
            for tab in tabs { measure(tab) }
        case "render":
            guard arguments.count >= 3 else { fputs("render <folder> WxH ...\n", stderr); exit(2) }
            let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let sizes = arguments.dropFirst(2).map { text -> NSSize in
                let parts = text.split(separator: "x").compactMap { Double($0) }
                precondition(parts.count == 2, "a size reads WxH: \(text)")
                return NSSize(width: parts[0], height: parts[1])
            }
            for tab in tabs { for size in sizes { try render(tab, size: size, out: out) } }
            print("wrote \(tabs.count * sizes.count * 2) PNGs to \(out.path)")
        default:
            fputs("usage: measure | render <folder> WxH ...\n", stderr); exit(2)
        }
    }

    static func name(_ tab: ActivitySection?) -> String { tab?.rawValue ?? "home" }

    /// The app's window (ActivityWindowPresenter.makeWindow), opened on a tab as show(section:) opens it.
    static func window(_ tab: ActivitySection?) -> (NSWindow, NSHostingController<ActivityWindow>) {
        let model = ControllerModel(startBackgroundWork: false)
        model.activityOpenSection = tab
        let window = ActivityWindowPresenter.makeWindow(model: model)
        guard let controller = window.contentViewController as? NSHostingController<ActivityWindow> else { fatalError("Activity is not hosted") }
        return (window, controller)
    }

    /// Measured before 0.5.254 with the hosting controller's default sizing, for home and every tab.
    static let measuredMin = NSSize(width: 760, height: 560)

    static func check(_ tab: ActivitySection?) -> [String] {
        let (window, controller) = window(tab)
        defer { window.close() }
        settle(window)
        var failures: [String] = []
        if !controller.sizingOptions.isEmpty {
            failures.append("\(name(tab)): the hosting controller tracks its content's size again (\(controller.sizingOptions.rawValue)), which measured the whole window on every layout pass")
        }
        let needs = controller.sizeThatFits(in: .zero)
        let floor = NSSize(width: max(needs.width, measuredMin.width), height: max(needs.height, measuredMin.height))
        let pinned = window.contentMinSize
        if pinned.width < floor.width || pinned.height < floor.height {
            failures.append("\(name(tab)): the window's minimum content size is \(text(pinned)), below the \(text(floor)) this tab needs (it was 760x560 before 0.5.254)")
        }
        window.setContentSize(NSSize(width: 100, height: 100))
        settle(window, seconds: 0.4)
        let tiny = window.contentView?.frame.size ?? .zero
        if tiny.width < floor.width || tiny.height < floor.height {
            failures.append("\(name(tab)): asked for 100x100 the window became \(text(tiny)), below \(text(floor))")
        }
        window.setContentSize(NSSize(width: 8_000, height: 6_000))
        settle(window, seconds: 0.4)
        let huge = window.contentView?.frame.size ?? .zero
        if huge.width < 8_000 || huge.height < 6_000 {
            failures.append("\(name(tab)): asked for 8000x6000 the window stopped at \(text(huge)); it had no maximum before 0.5.254")
        }
        return failures
    }

    static func settle(_ window: NSWindow, seconds: TimeInterval = 1) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    static func text(_ size: NSSize) -> String {
        size.width > 50_000 || size.height > 50_000 ? String(format: "%.0fx%.0f (unbounded)", size.width, size.height)
                                                   : String(format: "%.1fx%.1f", size.width, size.height)
    }

    static func measure(_ tab: ActivitySection?) {
        let (window, controller) = window(tab)
        settle(window)
        let swiftUIMin = controller.sizeThatFits(in: .zero)
        let swiftUIMax = controller.sizeThatFits(in: CGSize(width: 100_000, height: 100_000))
        let publishedMin = window.contentMinSize, publishedMax = window.contentMaxSize
        window.setContentSize(NSSize(width: 100, height: 100))
        settle(window, seconds: 0.5)
        let tiny = window.contentView?.frame.size ?? .zero
        window.setContentSize(NSSize(width: 8_000, height: 6_000))
        settle(window, seconds: 0.5)
        let huge = window.contentView?.frame.size ?? .zero
        print("\(name(tab)): sizing \(controller.sizingOptions.rawValue) | SwiftUI min \(text(swiftUIMin)) max \(text(swiftUIMax)) | window contentMinSize \(text(publishedMin)) contentMaxSize \(text(publishedMax)) | asked 100x100 got \(text(tiny)) | asked 8000x6000 got \(text(huge))")
        window.close()
    }

    static func render(_ tab: ActivitySection?, size: NSSize, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let (window, _) = window(tab)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            settle(window, seconds: 1.5)
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            let file = "\(name(tab))-\(Int(size.width))x\(Int(size.height))-\(word).png"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file))
            if view.bounds.size != size { print("note: \(file) drew at \(text(view.bounds.size)), asked \(text(size))") }
            window.close()
        }
    }
}
