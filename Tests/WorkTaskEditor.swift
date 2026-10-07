import AppKit
import SwiftUI

/// Production Activity + editor, offscreen in a disposable home. Changes the
/// binding directly; sends no input events, never opens or focuses a window.
@main @MainActor struct WorkTaskEditorChecks {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        precondition(NSHomeDirectory().contains("cos-task-editor"))
        let model = ControllerModel(startBackgroundWork: false)
        let values: [JSONValue] = (0..<295).map { index in
            .object([
                "id": .string(String(format: "%012x", index + 1)), "domain": .string("quilt"),
                "text": .string(index == 0 ? "Review Pete's slide deck and promo landing page for the October program, then decide which demand channels marketing will use to drive traffic." : "Review fixture task \(index)"),
                "title": .string("Review slide deck"), "ref": .string("quilt-\(index + 1)"),
                "workStage": .string("built"), "stage": .string("active"), "column": .string("inbox"),
                "section": .string("inbox"), "workRevision": .string(String(repeating: "a", count: 64)),
                "source": .string("Push Back on Facebook Promo Mandate (G2) [2026-10-02]")
            ])
        }
        model.workTasks = values.compactMap(TaskRow.init)
        let fixture = HelperResponse(ok: true, message: "Fixture tasks", details: ["tasks": .array(values), "complete": .bool(true),
            "capabilities": .object(["version": .number(1), "writable": .bool(true), "editTasks": .number(1)])])
        try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["COS_EDITOR_FIXTURE"]!))
        model.workTaskEditAvailable = true; model.workBoardWritable = true; model.workTasksComplete = true
        let state = WorkTaskEditorState(task: model.workTasks[0])
        precondition(!state.dirty && state.requestClose())
        state.text += " Scotch competitor Offer review"
        state.doneWhen = "Choose demand channels and document the next steps."
        precondition(state.dirty && !state.requestClose() && state.confirmingDismiss)
        precondition(!state.requestClose() && !state.confirmingDismiss)
        state.busy = true
        precondition(!state.requestClose())
        state.busy = false
        let draft = state.text
        let saved = await state.perform { throw HelperClientError.commandFailed("Fixture: stale revision.") }
        precondition(!saved && state.error == "Fixture: stale revision." && !state.busy)
        precondition(state.text == draft && state.dirty && !state.requestClose() && state.confirmingDismiss)
        state.confirmingDismiss = false
        state.text = String(repeating: "x", count: 2001)
        precondition(state.validationMessage != nil)
        state.text = draft; state.error = ""

        let host = NSHostingView(rootView: ActivityWindow.taskEditorFixture(model: model, state: state))
        host.sizingOptions = ActivityWindowPresenter.hostingSizing
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        settle(host, seconds: 1)
        precondition(model.workTasks.count == 295 && WorkBoardMetrics.projections > 0, "the full fixture board was not exercised")
        precondition(WorkBoardMetrics.activityBodies > 0, "the production Activity body was not exercised")
        WorkBoardMetrics.activityBodies = 0; WorkBoardMetrics.bodies = 0; WorkBoardMetrics.projections = 0
        var times: [Double] = []
        for _ in 0..<200 {
            let start = Date()
            state.text.append("x")
            settle(host, seconds: 0.001)
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let rendered = textViews(host)
        precondition(rendered.contains { $0.string == state.text }, "the native editor did not receive the complete draft")
        precondition(WorkBoardMetrics.activityBodies == 0, "typing rebuilt Activity \(WorkBoardMetrics.activityBodies) times")
        precondition(WorkBoardMetrics.bodies == 0 && WorkBoardMetrics.projections == 0, "typing rebuilt the Work board")
        times.sort()
        print("200 draft changes: Activity bodies 0, Work bodies 0, projections 0; p95 \(String(format: "%.1f", times[189])) ms; native text exact")
        state.text = draft
        // Background data refresh must not replace the draft or silently rebase its revision.
        model.workTasks = Array(model.workTasks.reversed())
        settle(host, seconds: 0.05)
        precondition(state.text == draft && state.task.id == "000000000001")
        if let out = CommandLine.arguments.dropFirst().first {
            let folder = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance); host.appearance = window.appearance
                for (width, height) in [(1280,900),(760,560)] {
                    window.setContentSize(NSSize(width: width, height: height)); settle(host, seconds: 0.08)
                    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("task-editor-\(name)-\(width).png"))
                }
            }
        }
        window.close()
        print("Task draft validation, close protection, busy protection, failed-save retention, and refresh isolation passed")
    }
    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        } while Date() < end
    }
    static func textViews(_ view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap { textViews($0) }
    }
}
