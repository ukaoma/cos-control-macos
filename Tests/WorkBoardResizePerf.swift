import AppKit
import SwiftUI

/// 0.5.254 resize pass (Tests/run-work-board-perf.sh <label> [folder for PNGs]; `--gate` is the gate in Tests/run.sh and
/// scripts/build-release.sh, the other modes are by hand): the live Work
/// board as Miles has it (268 tasks across six stages, 12 handoffs and their sessions, a writable board), in a window
/// that is never ordered in. The tasks come through the real load path, from a stand-in helper beside the binary that
/// replays fixture JSON. The width steps from 1200 to 1900 pt in 10 pt steps; each step is timed from the resize to the
/// end of the follow-up pass that state written during layout schedules. Prints median, p95 and max ms per step, how
/// often the projection and the Work body ran, and the same counts over 3 s at idle. With a folder it also draws the
/// board at 1280, 1800 and 820 pt (the compact layout), light and dark, to PNGs. Nothing is clicked, typed or dragged, and the process can never
/// become active.
///
/// The gate (`--gate`) judges counts, never milliseconds (those depend on the load): over the 71-step sweep the board's
/// rows are built 0 times and the Work body runs at most 3 times (the session row's stored card count is its only
/// layout state and changes about every 332 pt, so 700 pt crosses it at most 3 times: 0.042 per step, under 0.05); and
/// in a second sweep each data change (a stage move, a handoff, a session check, a meeting review) rebuilds the rows
/// exactly once.
@main @MainActor struct WorkBoardResizePerf {
    static let stages: [(String, Int)] = [("mentioned", 40), ("planned", 80), ("draft", 50), ("built", 30), ("qa", 28), ("complete", 40)]
    static let domains = ["quilt", "sprocket_rocket", "hermit_crabs", "personal"]

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let label = arguments.first ?? "run"
        let renderFolder = arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let fixtures = ProcessInfo.processInfo.environment["COS_PERF_FIXTURES"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            fputs("COS_PERF_FIXTURES is not set: run Tests/run-work-board-perf.sh\n", stderr); exit(2)
        }
        let now = Date()
        let tasks = taskRows()
        try writeFixture(fixtures.appendingPathComponent("work-tasks.json"), details: [
            "tasks": .array(tasks), "complete": .bool(true), "capabilities": .object(["version": .number(1), "writable": .bool(true)])])

        let rows = tasks.compactMap(TaskRow.init)
        precondition(rows.count == 268, "fixture rows \(rows.count)")
        let open = rows.filter { !$0.checked }
        let statuses = ["running", "running", "running", "delivered", "delivered", "delivered", "completed", "completed", "completed", "reviewed", "reviewed", "reviewed"]
        let sessionStates = ["running", "working", "running", "idle", "waiting", "running", "idle", "idle", "recent", "idle", "idle", "idle"]
        var receipts: [WorkHandoffReceipt] = []
        var sessions: [JSONValue] = []
        let stamp = ISO8601DateFormatter()
        for index in 0..<12 {
            let source = WorkSource.taskSnapshot(open[index * 7])
            let native = String(format: "5e551%03d-0000-4000-8000-%012d", index, index)
            receipts.append(WorkHandoffReceipt(id: "perf-receipt-\(index)", workID: source.id, workTitle: source.title,
                                               sourceRevision: source.revision, mode: index.isMultiple(of: 3) ? .newSession : .continueSession,
                                               provider: "claude", modelID: "opus", sessionID: "claude:" + native,
                                               sessionTitle: source.title, status: statuses[index], detail: "",
                                               prompt: "Work on this.", createdAt: now.addingTimeInterval(-3 * 86_400 - Double(index) * 60).timeIntervalSince1970))
            sessions.append(.object(["id": .string(native), "provider": .string("claude"), "name": .string(source.title),
                                     "workspace": .string("/Users/miles/cos"), "state": .string(sessionStates[index]), "alive": .bool(true),
                                     "updatedAt": .string(stamp.string(from: now.addingTimeInterval(-3 * 86_400)))]))
        }
        let sessionRows = SessionRows(sessions)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let handoffStore = WorkHandoffStore(storageURL: home.appendingPathComponent("perf-handoffs.json"), transport: { args, _ in
            guard args.first == "claude-sessions" else { throw HelperClientError.invalidResponse("The resize harness only lists sessions.") }
            return HelperResponse(ok: true, message: "", details: ["sessions": .array(sessionRows.value)])
        })
        handoffStore.receipts = receipts
        await handoffStore.refreshActivity()
        let reviewStore = WorkReviewStore(transport: { _, _ in
            HelperResponse(ok: true, message: "", details: ["capabilities": .object(["manualReview": .bool(true)]), "reviews": .array([])])
        })
        let model = ControllerModel(startBackgroundWork: false)
        await model.loadWorkTasks()
        precondition(model.workTasks.count == 268 && model.workBoardWritable, "the stand-in helper did not load the board: \(model.workTasksError ?? "?")")
        let state = WorkWorkspaceState()
        func board() -> some View {
            WorkWorkspaceView(model: model, handoffStore: handoffStore, reviewStore: reviewStore, state: state,
                              onOpenSession: { _ in }, onEditTask: { _ in }, onReviewMeeting: { _ in })
        }

        if let renderFolder {
            try FileManager.default.createDirectory(at: renderFolder, withIntermediateDirectories: true)
            // 820 pt is under the 900 pt wide layout: the compact navigation from the first frame.
            for width in [1280, 1800, 820] { try render(board(), width: CGFloat(width), name: "board-\(width)", out: renderFolder) }
            print("wrote PNGs to \(renderFolder.path)")
            return
        }

        let host = CountingHost(rootView: board())
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host, seconds: 2)   // the view's own loads (tasks, reviews, intake) land here
        precondition(handoffStore.observedSessions().count == 12, "the sessions went stale before the run")

        WorkBoardMetrics.projections = 0
        WorkBoardMetrics.bodies = 0
        WorkBoardMetrics.boards = 0
        host.layouts = 0
        let steps = resize(window, host, widths: Array(stride(from: 1200, through: 1900, by: 10)))
        let resizeProjections = WorkBoardMetrics.projections, resizeBodies = WorkBoardMetrics.bodies, resizeLayouts = host.layouts
        let resizeBoards = WorkBoardMetrics.boards

        var failures: [String] = []
        var changes: [String] = []
        if label == "--gate" {
            if resizeProjections != 0 {
                failures.append("the board rebuilt its rows \(resizeProjections) times during a 71-step resize (must be 0): something reads a projection that is recomputed instead of WorkWorkspaceState.board")
            }
            if resizeBodies > 3 || resizeBoards > 3 {
                failures.append("the Work board was evaluated \(resizeBoards) times (the view's body \(resizeBodies) times) in 71 resize steps (bound 3 each, 0.05 per step): something rebuilds the board on every step of a resize (a GeometryReader around the body, or a raw width in @State)")
            }
            // Each data change during a sweep rebuilds the rows exactly once.
            let review = WorkReviewRecord(.object([
                "id": .string("perf-review"), "status": .string("ready"), "canonicalMeetingId": .string("m-perf"), "markdown": .string("Follow up."),
                "source": .object(["title": .string("Weekly review"), "domain": .string("quilt"), "revision": .string("1"),
                    "descriptor": .object(["recordId": .string("m-perf"), "domain": .string("quilt"), "month": .string("2026-09"), "filename": .string("2026-09-30_Weekly.md")])])]))!
            var moved = tasks[0].object!
            moved["workStage"] = .string("planned")
            let segments = Array(stride(from: 1900, through: 1200, by: -10)).chunked(4)
            for (index, widths) in segments.enumerated() {
                // Counted from before the change: an awaited session check can redraw the board while it is awaited.
                let before = WorkBoardMetrics.projections
                let name: String
                switch index {
                case 0: name = "a stage move"; model.workTasks[0] = TaskRow(.object(moved))!
                case 1: name = "a handoff changing"; handoffStore.receipts[3].status = "failed"
                case 2:
                    name = "a session check with a new state"
                    var changed = sessionRows.value[4].object!
                    changed["state"] = .string("running")
                    sessionRows.value[4] = .object(changed)
                    await handoffStore.refreshActivity()
                default: name = "a meeting review"; reviewStore.reviews = [review]
                }
                _ = resize(window, host, widths: widths)
                let rebuilt = WorkBoardMetrics.projections - before
                changes.append("\(name) \(rebuilt)")
                if rebuilt != 1 { failures.append("\(name) during a resize rebuilt the rows \(rebuilt) times (must be exactly 1)") }
            }
        }

        settle(host, seconds: 0.5)
        WorkBoardMetrics.projections = 0
        WorkBoardMetrics.bodies = 0
        settle(host, seconds: 3)
        let idleProjections = WorkBoardMetrics.projections, idleBodies = WorkBoardMetrics.bodies
        window.close()

        let sorted = steps.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let n = Double(steps.count)
        print(String(format: "%@: %d steps 1200-1900 pt | median %.2f ms | p95 %.2f ms | max %.2f ms | projections %d (%.2f/step) | bodies %d (%.2f/step) | boards %d (%.2f/step) | hosting layouts %.2f/step | idle 3 s: projections %d, bodies %d",
                     label, steps.count, median, p95, sorted.last ?? 0, resizeProjections, Double(resizeProjections) / n,
                     resizeBodies, Double(resizeBodies) / n, resizeBoards, Double(resizeBoards) / n, Double(resizeLayouts) / n, idleProjections, idleBodies))
        guard label == "--gate" else { return }
        if !failures.isEmpty {
            for failure in failures { fputs("resize gate FAILED: \(failure)\n", stderr) }
            exit(1)
        }
        print("PASS: Work resize gate (0.5.254): 0 rebuilds, \(resizeBodies) body runs and \(resizeBoards) board evaluations in 71 steps; rebuilds per change during a sweep: \(changes.joined(separator: ", "))")
    }

    /// The session list the stand-in transport answers with, changed by the gate between sweeps.
    final class SessionRows: @unchecked Sendable {
        var value: [JSONValue]
        init(_ value: [JSONValue]) { self.value = value }
    }

    /// 268 tasks: six stages, four domains, a finish line on each, meeting links on every fifth.
    static func taskRows() -> [JSONValue] {
        var rows: [JSONValue] = []
        for (stage, count) in stages {
            for index in 0..<count {
                let n = rows.count
                var row: [String: JSONValue] = [
                    "id": .string(String(format: "%012x", 0xa11ce + n * 7919)), "domain": .string(domains[n % domains.count]),
                    "title": .string("Task \(n): \(stage) work item with a title long enough to wrap on a board card"),
                    "text": .string("Task \(n): \(stage) work item with a title long enough to wrap on a board card"),
                    "checked": .bool(stage == "complete"), "source": .string(n.isMultiple(of: 3) ? "Meeting" : "Manual"),
                    "doneWhen": .string("The \(stage) item \(index) is reviewed and its outcome recorded."),
                    "stage": .string(stage == "draft" ? "active" : stage == "qa" ? "review" : "planning"),
                    "workStage": .string(stage), "workRevision": .string("rev-\(n)")]
                if n.isMultiple(of: 5) {
                    row["meetingRefs"] = .array([.object(["recordId": .string("meeting-\(n)"), "domain": .string("quilt"), "month": .string("2026-09"),
                                                          "filename": .string("2026-09-\(10 + n % 18)_Weekly_Review.md"), "title": .string("Weekly review \(n)")])])
                }
                rows.append(.object(row))
            }
        }
        return rows
    }

    static func writeFixture(_ url: URL, details: [String: JSONValue]) throws {
        let response = HelperResponse(ok: true, message: "", details: details)
        try JSONEncoder().encode(response).write(to: url)
    }

    /// One timed step per width, from the resize to the end of the follow-up pass.
    static func resize(_ window: NSWindow, _ host: NSView, widths: [Int]) -> [Double] {
        let clock = ContinuousClock()
        var steps: [Double] = []
        for width in widths {
            let started = clock.now
            window.setContentSize(NSSize(width: CGFloat(width), height: 900))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date())   // the follow-up pass that state written during layout schedules
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            steps.append(milliseconds(clock.now - started))
        }
        return steps
    }

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    static func render<V: View>(_ view: V, width: CGFloat, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            settle(host, seconds: 2)
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }

    /// The hosting view, counting its layout passes (a step can take several: the resize, the size constraints it
    /// invalidates, and the pass that state written during layout schedules).
    final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() { layouts += 1; super.layout() }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

private extension Array {
    /// The array in `count` runs of nearly equal length, in order.
    func chunked(_ count: Int) -> [[Element]] {
        let size = (self.count + count - 1) / count
        return stride(from: 0, to: self.count, by: size).map { Array(self[$0..<Swift.min($0 + size, self.count)]) }
    }
}
