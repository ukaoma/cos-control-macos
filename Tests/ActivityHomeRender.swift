import AppKit
import SwiftUI

/// 0.5.259, run by hand (Tests/run-activity-home-render.sh <folder>): the shipped Activity window on its home, with
/// fixture data shaped like Miles's screenshots of 2026-10-06, drawn off screen to PNGs for a side-by-side check against
/// MOCK_activity_work_search_2026-10-06 (the first board). Four states: things waiting, one thing waiting, nothing
/// waiting, and only the backlog waiting. Background work is off, so nothing loads from a server. Windows are never ordered in, the process can never
/// become active, and nothing is clicked, typed or dragged.
@main @MainActor struct ActivityHomeRender {
    static let now = Date()

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { fputs("run through Tests/run-activity-home-render.sh (a scratch home)\n", stderr); exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let busy = model(.busy)
        try render(ActivityWindow(model: busy), width: 1280, height: 900, name: "home-busy-1280", out: out)
        try render(ActivityWindow(model: busy), width: 920, height: 680, name: "home-busy-920", out: out)
        try render(ActivityWindow(model: busy), width: 760, height: 560, name: "home-busy-760", out: out)
        try render(ActivityWindow(model: model(.one)), width: 1280, height: 900, name: "home-one", out: out)
        try render(ActivityWindow(model: model(.quiet)), width: 1280, height: 900, name: "home-quiet", out: out)
        try render(ActivityWindow(model: model(.backlog)), width: 1280, height: 900, name: "home-backlog", out: out)
        print("wrote PNGs to \(out.path)")
    }

    /// busy: sessions waiting and a backlog; one: a single question; quiet: nothing waits; backlog: no session waits.
    enum Scene { case busy, one, quiet, backlog }

    static func iso(_ minutesAgo: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60)) }
    /// A meeting's `yyyy-MM-dd` and `HH:mm`, so many minutes ago (never in the future, whatever the hour of the run).
    static func dayAndTime(_ minutesAgo: Double) -> (String, String) {
        let date = now.addingTimeInterval(-minutesAgo * 60)
        let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (ActivityHome.dayKey(date), String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0))
    }

    static func session(_ id: String, _ name: String, _ state: String, updated: Double, provider: String = "claude", since: Double? = nil) -> ClaudeSession {
        var o: [String: JSONValue] = ["id": .string(id), "provider": .string(provider), "name": .string(name), "state": .string(state),
                                      "updatedAt": .string(iso(updated)), "workspace": .string("MU-Chief-Staff")]
        if let since { o["stateSince"] = .string(iso(since)); o["waitingKind"] = .string("question") }
        return ClaudeSession(.object(o))!
    }

    static func model(_ scene: Scene) -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        model.petEnabled = false
        var status = model.status
        status.running = true
        status.memoryAvailable = true; status.memoryCount = 5528
        status.learningToReview = scene == .busy || scene == .backlog ? 3 : 0
        status.threadsAvailable = true; status.threadCount = 66; status.activeThreadCount = 32
        model.status = status
        let midnight = Calendar.current.startOfDay(for: now)
        let minutesToday = now.timeIntervalSince(midnight) / 60

        // Messages: the last from the glasses, Monday 9:00 AM.
        let monday = Calendar.current.date(byAdding: .day, value: -1, to: midnight)!.addingTimeInterval(9 * 3600)
        model.recentMessages = (0..<30).map { index in
            GlassesTurn(id: "t\(index)", no: 3000 - index, timestamp: monday.addingTimeInterval(Double(-index) * 3600).timeIntervalSince1970,
                        query: index == 0 ? "Hey, I had a question about how much longer this task is going to take" : "Earlier question \(index)",
                        text: "", sessionId: "s", source: "G2")
        }
        model.recentGlassesStatus = .ready

        // Speakers: 94 enrolled; the meeting with a voice to name.
        model.voiceDirectory = (0..<94).compactMap { VoiceDirectoryPerson(.object(["name": .string("Person \($0)")])) }
        let day = ActivityHome.dayKey(now)
        func meeting(_ id: String, _ title: String, _ minutesAgo: Double, unnamed: Int) -> ReviewableMeeting {
            let (date, time) = dayAndTime(minutesAgo)
            return ReviewableMeeting(.object(["sessionId": .string(id), "title": .string(title), "date": .string(date), "time": .string(time),
                                       "voiceReview": .object(["voices": .number(Double(unnamed + 3)), "unattributedVoices": .number(Double(unnamed)), "humanTouched": .bool(unnamed == 0)])]))!
        }
        model.reviewableMeetings = [
            meeting("m1", "Deprioritize CityHive, Feature DoorDash Integrations", 40, unnamed: scene == .busy || scene == .backlog ? 1 : 0),
            meeting("m2", "Morning standup", 190, unnamed: 0),
        ]
        // Meetings: 45 in October.
        model.libraryMonth = String(day.prefix(7))
        model.libraryMeetings = (0..<45).compactMap { index in
            LibraryMeeting(.object(["filename": .string("2026-10-0\(index % 6 + 1)_Meeting_\(index).md"), "month": .string(String(day.prefix(7))),
                                    "domain": .string("quilt"), "title": .string("Meeting \(index)"), "date": .string(day)]))
        }

        // Memories: three to review, the oldest from Sunday.
        let sunday = Calendar.current.date(byAdding: .day, value: -2, to: midnight)!.addingTimeInterval(15 * 3600)
        model.toReviewEvents = scene == .busy || scene == .backlog ? [LearningEvent(.object(["event_id": .string("e1"), "ts": .string(ISO8601DateFormatter().string(from: sunday)), "title": .string("Pattern")]))!] : []
        // Threads: the latest seen.
        model.threadRecords = [ContextRecord.thread(["id": .string("t1"), "name": .string("Bottle POS October switch offer"), "last_seen": .string(iso(90))])]

        // Sessions: 80 on disk. Busy: 2 working, 1 asked, 1 quiet for 16 min, 3 finished today. One: the IT Retail question.
        var sessions: [ClaudeSession] = []
        switch scene {
        case .busy:
            sessions += [
                session("a1", "Bottle POS switch offer", "waiting", updated: 12, since: 12),
                session("q1", "gotcos docs sweep", "running", updated: 16, provider: "codex"),
                session("w1", "Speakers: open meeting (0.5.259)", "running", updated: 1),
                session("w2", "IT Retail lane images", "running", updated: 2, provider: "cursor"),
                session("d1", "Meeting files release", "recent", updated: min(18, minutesToday - 1)),
                session("d2", "Glasses 611 strip beside list", "recent", updated: min(90, minutesToday - 1), provider: "codex"),
                session("d3", "SBP Rain form fix", "recent", updated: min(385, minutesToday - 1)),
            ]
        case .one:
            sessions += [session("a2", "IT Retail lane images", "waiting", updated: 3, provider: "cursor", since: 3)]
        case .quiet, .backlog:
            break
        }
        sessions += (sessions.count..<80).map { session("o\($0)", "Older session \($0)", "recent", updated: minutesToday + 60 * Double($0 + 1)) }
        model.claudeSessions = sessions

        // Work: 7 need attention, 35 new to sort (fresh mentions), none in progress. Quiet: nothing needs attention.
        var tasks: [TaskRow] = []
        for index in 0..<(scene == .busy || scene == .backlog ? 7 : 0) {
            tasks += [TaskRow(.object(["id": .string("f\(index)"), "domain": .string("quilt"), "text": .string("Failed task \(index)"),
                                       "failed": .bool(true), "workStage": .string("planned"), "stage": .string("planned")]))!]
        }
        for index in 0..<(scene == .busy ? 35 : 0) {
            tasks += [TaskRow(.object(["id": .string("n\(index)"), "domain": .string("quilt"), "text": .string("Mentioned \(index)"),
                                       "workStage": .string("mentioned"), "stage": .string("mentioned"), "createdAt": .string(day)]))!]
        }
        tasks += [TaskRow(.object(["id": .string("p1"), "domain": .string("quilt"), "text": .string("Planned"), "workStage": .string("planned"), "stage": .string("planned")]))!]
        model.workTasks = tasks
        model.workTasksComplete = true
        model.workIntake = WorkIntakeSnapshot(available: true, message: nil, items: [], cardCreation: true, linkWrites: true)
        if scene == .quiet { model.status.learningToReview = 0 }
        return model
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            // The cards paint in over about a second; let them land.
            for _ in 0..<14 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
