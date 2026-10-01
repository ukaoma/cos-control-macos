import AppKit
import SwiftUI

/// 0.5.254 resize pass, by hand (Tests/run-activity-sizing.sh): the Activity window's content size limits for every tab,
/// and drawings of every tab for a before and after check. The window is built as ActivityWindowPresenter.show builds
/// it (a hosting controller as the content view controller, the same style and sizes) but is never ordered in, the
/// process can never become active, and nothing is clicked, typed or dragged. Background work is off, so no tab loads
/// live data: what is measured is the window's own layout.
///
///     measure                     per tab: SwiftUI's minimum and maximum (sizeThatFits), the limits the hosting view
///                                 publishes to the window, and the size the window takes when asked to be tiny or huge
///     render <folder> WxH ...     each tab at each content size, light and dark, to PNGs
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

    /// The window as ActivityWindowPresenter.show built it before 0.5.254's sizing change: the hosting controller keeps
    /// its default sizing (.standardBounds), which publishes SwiftUI's minimum and maximum to the window.
    static func window(_ tab: ActivitySection?) -> (NSWindow, NSHostingController<ActivityWindow>) {
        let model = ControllerModel(startBackgroundWork: false)
        model.activityOpenSection = tab
        let controller = NSHostingController(rootView: ActivityWindow.live(model: model))
        let window = NSWindow(contentViewController: controller)
        window.title = "COS Activity"
        window.setContentSize(NSSize(width: 920, height: 680))
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        return (window, controller)
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
