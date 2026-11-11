import AppKit
import SwiftUI

/// Reply in the message reader (D4; asked for 2026-11-11): the reader with its Reply block, drawn in the app's own window on a
/// fixture for Q1 and Miles to look at. Built like Tests/ActivitySizing.swift: never ordered in, the process never active,
/// background work off, a scratch home with no helper. Every message, model and reply here is invented.
///
///     Tests/run-message-reply-render.sh <folder> WxH ...
///
/// Writes message-reply-<state>-<W>x<H>-<light|dark>.png for two states:
///   efforts    #486, a turn with a session, a server that serves efforts (7.0.27): Model and Effort, one reply answered
///   no-efforts #312, a turn with no session, a server that serves none (7.0.18): Model alone, "Starts a conversation."
@main @MainActor struct MessageReplyRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-message-reply-render"),
              FileManager.default.homeDirectoryForCurrentUser.path.contains("cos-message-reply-render") else {
            fputs("run through Tests/run-message-reply-render.sh (a scratch home)\n", stderr); exit(2)
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
        for state in ["efforts", "no-efforts"] {
            for size in sizes {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    try await render(state: state, size: size, appearance: appearance, out: out); written += 1
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

    static func turn(no: Int, session: String, query: String, text: String) -> GlassesTurn {
        let ms = Int(Date().addingTimeInterval(-25 * 60).timeIntervalSince1970 * 1000)
        return GlassesTurn(["no": .number(Double(no)), "query": .string(query), "text": .string(text), "sessionId": .string(session),
                            "source": .string("live"), "timestamp": .number(Double(ms)), "modelPreference": .string("sonnet")])!
    }

    static func render(state: String, size: NSSize, appearance: NSAppearance.Name, out: URL) async throws {
        let model = ControllerModel(startBackgroundWork: false)
        let shown = state == "efforts"
            ? turn(no: 486, session: "a1b2c3d4-0000-4000-8000-123456789abc", query: "What changed in the onboarding deck since Monday?",
                   text: "Two slides moved: pricing went to the appendix, and the setup steps are now one slide. The intro video link is new.")
            : turn(no: 312, session: "", query: "Remind me what the export format question was about.",
                   text: "Finance asked whether the quarterly report should export as CSV or XLSX. It is still open.")
        model.recentMessages = [shown, turn(no: 485, session: "", query: "Summarise the release notes.", text: "Three fixes and one new setting.")]
        let handoff = WorkHandoffStore(isolated: true)
        handoff.models = [WorkModelChoice(id: "sonnet", provider: "claude", title: "Claude Sonnet", available: true, reason: nil),
                          WorkModelChoice(id: "opus", provider: "claude", title: "Claude Opus", available: true, reason: nil),
                          WorkModelChoice(id: "codex-frontier", provider: "codex", title: "Codex", available: true, reason: nil)]
        if state == "efforts" {
            handoff.efforts = ["claude": [WorkEffortChoice(value: "high", label: "High"), WorkEffortChoice(value: "xhigh", label: "Extra High"),
                                          WorkEffortChoice(value: "max", label: "Max"), WorkEffortChoice(value: "ultracode", label: "Ultracode")]]
        }
        let host = NSHostingController(rootView: ActivityWindow.messageFixture(model: model, handoff: handoff, turnID: shown.id))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(size)
        settle(window, seconds: 1.2)
        if state == "efforts" {
            // One reply already sent from this Mac and answered: a stand-in run and read-back, after the reader wired its own.
            model.messageReply.askJob = { _, _, _, _, _ in .started("3a1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b") }
            model.messageReply.askState = { ids in
                [ids[0]: DropIt.AskState(status: "completed", answer: "The intro video is the 90-second walkthrough Sam recorded on Tuesday.", number: 487)]
            }
            _ = await model.messageReply.reply("Which video is the new intro link?", to: shown.id, session: shown.sessionId)
            await model.messageReply.refreshAsks()
        }
        settle(window, seconds: 1.0)
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let word = appearance == .darkAqua ? "dark" : "light"
        let file = "message-reply-\(state)-\(Int(size.width))x\(Int(size.height))-\(word).png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file))
        window.contentViewController = nil
        window.close()
    }
}
