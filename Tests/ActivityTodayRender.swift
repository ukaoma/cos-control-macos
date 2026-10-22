import AppKit
import SwiftUI

/// Activity Today home (plan v2), run by hand (Tests/run-activity-today-render.sh <folder>): the shipped Activity window
/// with the Today home on and fictional fixture data shaped like the canvas day, drawn off screen to PNGs for a
/// side-by-side check against activity-canvas (Main 1440, Narrow 920, Dark, CaughtUp). Background work is off, so nothing
/// loads from a server. Windows are never ordered in, the process can never become active, and nothing is clicked, typed
/// or dragged.
@main @MainActor struct ActivityTodayRender {
    static let now = Date()

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-today-render") else { fputs("run through Tests/run-activity-today-render.sh (a scratch home)\n", stderr); exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        UserDefaults.standard.set(false, forKey: TodayHome.quietHoursKey)

        try render(.busy, width: 1440, height: 1240, name: "today-main-1440")
        try render(.busy, width: 1280, height: 900, name: "today-main-1280")
        try render(.busy, width: 1100, height: 760, name: "today-main-1100")
        try render(.busy, width: 1099, height: 760, name: "today-main-1099")
        try render(.busy, width: 920, height: 680, name: "today-narrow-920")
        try render(.busy, width: 920, height: 1900, name: "today-narrow-920-full")
        try render(.busy, width: 760, height: 560, name: "today-narrow-760")
        try render(.busy, width: 760, height: 1600, name: "today-narrow-760-full")
        try render(.caughtUp, width: 1440, height: 980, name: "today-caughtup-1440")
        try render(.many, width: 1440, height: 1240, name: "today-many-running-1440")
        try render(.busy, width: 1440, height: 900, name: "today-tab-sessions-1440", tab: .sessions)
        try render(.busy, width: 920, height: 680, name: "today-tab-work-920", tab: .work)
        UserDefaults.standard.set(true, forKey: TodayHome.quietHoursKey)
        try render(.busy, width: 1440, height: 1240, name: "today-quiet-hours-1440")
        print("wrote PNGs to \(out.path)")
        func render(_ scene: Scene, width: CGFloat, height: CGFloat, name: String, tab: ActivitySection? = nil) throws {
            try ActivityTodayRender.render(scene, width: width, height: height, name: name, tab: tab, out: out)
        }
    }

    enum Scene { case busy, caughtUp, many }

    static func iso(_ minutesAgo: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60)) }

    static func session(_ id: String, _ name: String, _ state: String, minutes: Double, provider: String = "claude", kind: String = "",
                        question: String = "", workspace: String = "MU-Chief-Staff", updated: Double = 1) -> ClaudeSession {
        ClaudeSession(.object(["id": .string(id), "provider": .string(provider), "name": .string(name), "state": .string(state),
                               "updatedAt": .string(iso(updated)), "stateSince": .string(iso(minutes)), "createdAt": .string(iso(minutes)),
                               "alive": .bool(state != "recent"), "waitingKind": .string(kind), "waitingQuestion": .string(question),
                               "workspace": .string(workspace), "stateSource": .string("hook")]))!
    }

    static func setup(_ scene: Scene) -> (ControllerModel, TodayHomeStore, WorkHandoffStore) {
        let model = ControllerModel(startBackgroundWork: false)
        model.petEnabled = false
        var status = model.status
        status.running = true
        status.memoryAvailable = true; status.memoryCount = 5528
        status.threadsAvailable = true; status.threadCount = 66; status.activeThreadCount = 13
        status.learningToReview = scene == .caughtUp ? 0 : 7
        if scene != .caughtUp { status.liveTranscriptionSessions = 1 }
        model.status = status
        model.claudeSessionsEnabled = true
        let day = ActivityHome.dayKey(now)
        model.recentMessages = [GlassesTurn(id: "t1", no: 3120, timestamp: now.addingTimeInterval(-3 * 3600).timeIntervalSince1970,
                                            query: "Morning brief", text: "", sessionId: "s", source: "G2")]
        model.recentGlassesStatus = .ready
        model.threadRecords = [ContextRecord.thread(["id": .string("t1"), "name": .string("HubSpot theme settings"), "last_seen": .string(iso(90))])]
        let store = TodayHomeStore()
        store.reachable = true
        store.calendarRead = true
        store.checkedAt = now
        let handoff = WorkHandoffStore(isolated: true)
        guard scene != .caughtUp else {
            model.heldGroupsState = "ready"
            model.workYourMoveAvailable = true
            model.workIntake = WorkIntakeSnapshot(available: true, message: nil, items: [], cardCreation: true, linkWrites: true)
            model.workTasks = []; model.workTasksComplete = true
            return (model, store, handoff)
        }
        var sessions = [
            session("t1", "Holiday promo landing page", "running", minutes: 12),
            session("x1", "Rain POS schema audit", "running", minutes: 8, provider: "codex"),
            session("a1", "Cigars POS Gen 2 Modules", "waiting", minutes: 1, kind: "question",
                    question: "Build the age-gate module on the sandbox homepage, or on a new draft page?"),
            session("c1", "Bottle POS footer tweak", "waiting", minutes: 3, provider: "cursor"),
            session("f1", "Testimonial HubDB refresh", "recent", minutes: 40, updated: 4),
        ]
        if scene == .many {
            sessions += (0..<6).map { session("m\($0)", ["Bottle POS SEO pass", "IT Retail hardware loops", "gotcos docs sweep", "Footer tweak", "Footer tweak", "Pet pack review"][$0],
                                              "running", minutes: Double(3 + $0 * 4), provider: ["claude", "codex", "cursor"][$0 % 3], workspace: ["Bottle POS", "IT Retail"][$0 % 2]) }
        }
        model.claudeSessions = sessions
        store.hosts = ["claude:t1": TodayHome.Host(app: "Terminal", terminal: true)]
        store.jobsSupported = true
        store.jobs = [TodayHome.ActiveJob(.object(["jobId": .string("qj1"), "origin": .string("person"),
                                                   "title": .string("What did Dana say about renewal timing?"), "elapsedMs": .number(40_000), "messageNo": .number(3121)]))!]
        let soon = Calendar.current.isDate(now.addingTimeInterval(43 * 60), inSameDayAs: now) ? now.addingTimeInterval(43 * 60) : now.addingTimeInterval(60)
        store.nextEvent = TodayHome.NextEvent(title: "Northwind renewal", start: soon)
        handoff.receipts = [WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: "task:quilt:pricing-qa", workTitle: "Pricing page QA pass", sourceRevision: "1",
                                               mode: .newSession, provider: "claude", modelID: "opus", sessionID: nil, sessionTitle: "Pricing page QA pass",
                                               status: "queued", detail: "Running on the server", prompt: "QA", createdAt: now.addingTimeInterval(-360).timeIntervalSince1970,
                                               sourceSessionID: nil, serverInstanceID: nil)]
        handoff.receipts[0].channel = "job"
        model.heldGroups = [HeldVoiceGroup(.object(["id": .string("vg1"), "members": .array([.object(["sessionId": .string("m-design"), "chunkIndex": .number(3)])]),
                                                    "sessions": .array([.string("m-design")]), "sampleCount": .number(4),
                                                    "suggestion": .object(["name": .string("Priya Shah"), "similarity": .number(0.82)])]))!]
        model.heldGroupsState = "ready"
        let clock = Calendar.current.dateComponents([.hour, .minute], from: now.addingTimeInterval(-100 * 60))
        model.reviewableMeetings = [ReviewableMeeting(.object(["sessionId": .string("m-design"), "title": .string("Design review"), "date": .string(day),
                                                               "time": .string(String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0))]))!]
        model.workYourMove = [WorkYourMove(.object(["id": .string("mv1"), "workId": .string("task:quilt:rain"), "title": .string("the Rain POS pricing table copy"),
                                                    "kind": .string("qa"), "action": .string("review")]))!]
        model.workYourMoveAvailable = true
        var n = 0
        func intake(_ filename: String, _ text: String, kind: String = "ask", status: String = "ask", title: String, pull: String? = nil) -> WorkIntakeItem {
            n += 1
            var o: [String: JSONValue] = ["id": .string("wi_" + String(format: "%032x", n)), "kind": .string(kind), "status": .string(status), "confidence": .number(0.9),
                                          "ownerIsMiles": .bool(true), "meeting": .object(["recordId": .string("ops:quilt:\(day.prefix(7)):" + filename), "domain": .string("quilt"),
                                                                                         "month": .string(String(day.prefix(7))), "filename": .string(filename), "title": .string(title)])]
            if kind == "link" { o["task"] = .object(["text": .string(text)]); if let pull { o["pull"] = .object(["title": .string(pull), "p": .number(0.8)]) } } else { o["text"] = .string(text) }
            return WorkIntakeItem(.object(o))!
        }
        var items = [
            intake("\(day)_Pricing_page_review.md", "Send Dana the revised renewal pricing", title: "Pricing page review"),
            intake("\(day)_Design_review.md", "Pick up the age-gate copy review", kind: "link", status: "suggested", title: "Design review", pull: "Age-gate module"),
            intake("\(day)_QBR_attribution_prep.md", "Ask Sam for the Q4 attribution export", title: "QBR attribution prep"),
        ]
        items += (0..<23).map { intake("2026-10-1\($0 % 9)_Older_\($0).md", "Older suggestion \($0)", title: "Older meeting \($0)") }
        model.workIntake = WorkIntakeSnapshot(available: true, message: nil, items: items, cardCreation: true, linkWrites: true)
        model.workTasks = []
        model.workTasksComplete = true
        return (model, store, handoff)
    }

    static func render(_ scene: Scene, width: CGFloat, height: CGFloat, name: String, tab: ActivitySection?, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let (model, store, handoff) = setup(scene)
            model.activityOpenSection = tab
            let view = ActivityWindow.todayFixture(model: model, store: store, handoff: handoff)
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.12)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
