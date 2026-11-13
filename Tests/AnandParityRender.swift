import AppKit
import SwiftUI

/// Anand parity (D4, 2026-11-12): the trail row and Meetings on today, drawn in the app's own window on a fixture for Q1 and
/// Miles. Built like Tests/MessageReplyRender.swift: never ordered in, background work off, a scratch home with no helper.
/// Every message and day here is invented.
///
///     Tests/run-anand-parity-render.sh <folder> WxH ...
///
/// Writes anand-<state>-<W>x<H>-<light|dark>.png for:
///   trail           Today, Message #485, then Message #486 opened from it: the toolbar shows the way here
///   meetings-today  Meetings opened on an empty today, ringed, with the jump to the latest earlier day
@main @MainActor struct AnandParityRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-anand-parity-render"),
              FileManager.default.homeDirectoryForCurrentUser.path.contains("cos-anand-parity-render") else {
            fputs("run through Tests/run-anand-parity-render.sh (a scratch home)\n", stderr); exit(2)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else { fputs("usage: <folder> WxH ...\n", stderr); exit(2) }
        let out = URL(fileURLWithPath: arguments[0], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sizes = arguments.dropFirst().map { text -> NSSize in
            let parts = text.split(separator: "x").compactMap { Double($0) }
            precondition(parts.count == 2, "a size reads WxH: \(text)")
            return NSSize(width: parts[0], height: parts[1])
        }
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        var written = 0
        for state in ["trail", "meetings-today"] {
            for size in sizes {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    try render(state: state, size: size, appearance: appearance, out: out); written += 1
                }
            }
        }
        print("wrote \(written) PNGs to \(out.path)")
    }

    static func settle(_ window: NSWindow, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    static func turn(no: Int, query: String, text: String) -> GlassesTurn {
        let ms = Int(Date().addingTimeInterval(-25 * 60).timeIntervalSince1970 * 1000)
        return GlassesTurn(["no": .number(Double(no)), "query": .string(query), "text": .string(text), "sessionId": .string(""),
                            "source": .string("live"), "timestamp": .number(Double(ms)), "modelPreference": .string("sonnet")])!
    }

    static func render(state: String, size: NSSize, appearance: NSAppearance.Name, out: URL) throws {
        let model = ControllerModel(startBackgroundWork: false)
        let view: ActivityWindow
        if state == "trail" {
            let first = turn(no: 485, query: "Summarise the release notes.", text: "Three fixes and one new setting.")
            let second = turn(no: 486, query: "What changed in the onboarding deck since Monday?",
                              text: "Two slides moved: pricing went to the appendix, and the setup steps are now one slide.")
            model.recentMessages = [second, first]
            let home = ActivityPlace(section: nil)
            let atFirst = ActivityPlace(section: ActivitySection.messages.rawValue, turnID: first.id)
            let atSecond = ActivityPlace(section: ActivitySection.messages.rawValue, turnID: second.id)
            view = ActivityWindow.pathFixture(model: model, section: .messages, turnID: second.id,
                                              backPath: [ActivityBackStep(from: home, to: atFirst), ActivityBackStep(from: atFirst, to: atSecond)])
        } else {
            let today = ControllerModel.currentMeetingDay()
            let month = ControllerModel.currentMeetingMonth()
            // The latest earlier day with meetings this month, or the first of the month when today is the first.
            let earlier = today.hasSuffix("-01") ? today : String(today.prefix(8)) + "01"
            model.libraryMonth = month
            model.libraryDays = earlier == today ? [] : [LibraryMeetingDay(date: earlier, count: 2)]
            model.libraryDay = today
            view = ActivityWindow.buildUpFixture(model: model, section: .meetings)
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(size)
        settle(window, seconds: 1.5)
        guard let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw CocoaError(.fileWriteUnknown) }
        content.cacheDisplay(in: content.bounds, to: rep)
        let word = appearance == .darkAqua ? "dark" : "light"
        let file = "anand-\(state)-\(Int(size.width))x\(Int(size.height))-\(word).png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file))
        window.contentViewController = nil
        window.close()
    }
}
