import AppKit
import SwiftUI

/// 0.5.259, run by hand (Tests/run-activity-home-perf.sh): how long the Activity window takes to draw its home for the
/// first time, and whether the loads it starts on opening (from 0.5.259 also Work's board, its meeting reviews, Intake and
/// the Memories review list) begin only after that first frame. The helper is a stand-in that answers every command after
/// 300 ms and writes when each call starts and ends, so the order is read from its log. It uses only what the Activity
/// window had before 0.5.259 too, so the same file measures both. Windows are never ordered in, the process can never
/// become active, and nothing is clicked, typed or dragged.
@main @MainActor struct ActivityHomeFirstRender {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-perf"), let logPath = ProcessInfo.processInfo.environment["COS_PERF_HELPER_LOG"] else {
            fputs("run through Tests/run-activity-home-perf.sh (a scratch home and a stand-in helper)\n", stderr); exit(2)
        }
        let log = URL(fileURLWithPath: logPath)
        let runs = 7
        for loads in [false, true] {
            var firstFrame: [Double] = []
            var firstCall: [Double] = []
            var lastEnd: [Double] = []
            var commands: [String] = []
            for run in 0..<runs {
                try? FileManager.default.removeItem(at: log)
                let model = ControllerModel(startBackgroundWork: false, allowActivityLoads: loads)
                fill(model)
                let started = Date()
                let host = NSHostingView(rootView: ActivityWindow(model: model).frame(width: 1280, height: 900))
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
                host.cacheDisplay(in: host.bounds, to: rep)
                let drawn = Date()
                // Let the window's own tasks run: until the stand-in helper has been quiet for 1.2 s (12 s at most).
                var quietSince = Date()
                var lines = 0
                while Date().timeIntervalSince(started) < (loads ? 12 : 0.6) {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    let now = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").count ?? 0
                    if now != lines { lines = now; quietSince = Date() }
                    if loads, lines > 0, Date().timeIntervalSince(quietSince) > 1.2 { break }
                }
                let entries = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.split(separator: " ", maxSplits: 2).map(String.init) }
                let drawnMs = drawn.timeIntervalSince1970 * 1000
                let starts = entries.filter { $0.count == 3 && $0[1] == "start" }
                let ends = entries.filter { $0.count == 3 && $0[1] == "end" }
                window.close()
                if run == 0 { continue }   // the first run warms up fonts and SwiftUI's caches
                firstFrame.append(drawn.timeIntervalSince(started) * 1000)
                if let first = starts.compactMap({ Double($0[0]) }).min() { firstCall.append(first - drawnMs) }
                if let last = ends.compactMap({ Double($0[0]) }).max() { lastEnd.append(last - drawnMs) }
                if run == runs - 1 { commands = starts.map { $0[2] } }
            }
            print("loads \(loads ? "on " : "off"): first frame median \(fmt(median(firstFrame))) ms (min \(fmt(firstFrame.min())), max \(fmt(firstFrame.max()))) over \(firstFrame.count) runs")
            if loads {
                print("  first helper call after the first frame: median +\(fmt(median(firstCall))) ms (min +\(fmt(firstCall.min())))")
                print("  last load finished: median +\(fmt(median(lastEnd))) ms after the first frame")
                print("  calls in order: \(commands.joined(separator: " | "))")
            }
        }
    }

    static func fmt(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "n/a" }
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// What the home shows on opening when its data is already in hand: 80 sessions, 30 messages, 94 voices, two
    /// meetings to review, 45 meetings this month. Work's board is left empty, so opening loads it.
    static func fill(_ model: ControllerModel) {
        let now = Date()
        func iso(_ minutesAgo: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60)) }
        model.petEnabled = false
        var status = model.status
        status.running = true
        status.memoryAvailable = true; status.memoryCount = 5528; status.learningToReview = 3
        status.threadsAvailable = true; status.threadCount = 66; status.activeThreadCount = 32
        model.status = status
        var sessions: [ClaudeSession] = []
        for index in 0..<80 {
            let state: String = index < 2 ? "running" : (index == 2 ? "waiting" : "recent")
            let provider: String = ["claude", "codex", "cursor"][index % 3]
            let row: [String: JSONValue] = ["id": .string("s\(index)"), "provider": .string(provider), "name": .string("Session \(index)"),
                                            "state": .string(state), "updatedAt": .string(iso(Double(index * 37))), "workspace": .string("MU-Chief-Staff")]
            if let session = ClaudeSession(.object(row)) { sessions.append(session) }
        }
        model.claudeSessions = sessions
        model.recentMessages = (0..<30).map { index in
            GlassesTurn(id: "t\(index)", no: 3000 - index, timestamp: now.addingTimeInterval(Double(-index) * 3600).timeIntervalSince1970,
                        query: "Question \(index)", text: "", sessionId: "s", source: "G2")
        }
        model.recentGlassesStatus = .ready
        model.voiceDirectory = (0..<94).compactMap { VoiceDirectoryPerson(.object(["name": .string("Person \($0)")])) }
        let day = String(iso(0).prefix(10))
        model.reviewableMeetings = ["m1", "m2"].compactMap { id in
            ReviewableMeeting(.object(["sessionId": .string(id), "title": .string("Meeting \(id)"), "date": .string(day), "time": .string("09:00"),
                                       "voiceReview": .object(["voices": .number(4), "unattributedVoices": .number(1)])]))
        }
        model.libraryMonth = String(day.prefix(7))
        model.libraryMeetings = (0..<45).compactMap { index in
            LibraryMeeting(.object(["filename": .string("\(day)_Meeting_\(index).md"), "month": .string(String(day.prefix(7))),
                                    "domain": .string("quilt"), "title": .string("Meeting \(index)"), "date": .string(day)]))
        }
    }
}
