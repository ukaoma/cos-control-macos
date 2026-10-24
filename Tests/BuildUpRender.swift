import AppKit
import SwiftUI

/// 0.5.343 Build-up, in place, as drawn, by hand (Tests/run-build-up-render.sh <dir>), for a side-by-side check against the
/// approved mock (operations/personal/wk43_2026/mock-skeleton/skeleton-reveal.html). The whole app is compiled.
///
///   - v2-* PNGs: the REAL call sites (the classic Activity window's Meetings list; the Today home's Needs you and Running
///     cards) with fictional fixture data, every COSBuildUp frozen through COSBuildUpProbe.freeze at the wire drawing, the
///     wire, the 3 s words, mid-landing, final and a hand-off; and the Meeting Ask answer around stand-in text (its pane
///     needs a live meeting). Light and dark.
///   - The geometry table: for each list site, the real rows found on the pixels of the loaded view against the rows the
///     wire draws there (COSBuildUpProbe.stage), printed as "geometry <site>: …".
///
/// No window is ordered in, no event is sent, nothing becomes active. Prints "build up render: N PNGs".
@main @MainActor struct BuildUpRender {
    static var written = 0
    static let frames: [(String, COSBuildUpFrame?, Bool)] = [   // name, frame (nil: settled, the real view as is), the data has landed
        ("1-wire-drawing", .init(phase: .building, drawT: 0.35), false),
        ("2-wire", .init(phase: .building, drawT: 1.4), false),
        ("3-words", .init(phase: .building, drawT: 3.6), false),
        ("4-landing", .init(phase: .landing, drawT: 1.6, phaseT: 0.08), true),
        ("5-final", nil, true),
        ("6-handoff", .init(phase: .handoff, drawT: 2.0, phaseT: 0.08), false),
    ]

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(false, forKey: TodayHome.quietHoursKey)
        if CommandLine.arguments.contains("geometry") { try geometry(); return }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = appearance == .darkAqua ? "dark" : "light"
            for (name, frame, landed) in frames {
                COSBuildUpProbe.freeze = frame
                let handoff = frame?.phase == .handoff
                try draw(meetings(landed: landed, handoff: handoff), size: CGSize(width: 900, height: 620), appearance: appearance,
                         name: "v2-meetings-list-\(name)-\(theme)", out: out)
                try draw(today(landed: landed), size: CGSize(width: 1440, height: 980), appearance: appearance,
                         name: "v2-today-cards-\(name)-\(theme)", out: out)
                try draw(AskBoard(landed: landed, handoff: handoff), size: CGSize(width: 560, height: 260), appearance: appearance,
                         name: "v2-meeting-ask-\(name)-\(theme)", out: out)
            }
            COSBuildUpProbe.freeze = nil
        }
        try geometry()
        print("build up render: \(written) PNGs in \(out.path)")
    }

    // MARK: Real call sites

    static func base() -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        model.petEnabled = false
        var status = model.status
        status.running = true
        status.memoryAvailable = true; status.memoryCount = 412
        status.threadsAvailable = true; status.threadCount = 66
        model.status = status
        return model
    }

    static func meetings(landed: Bool, handoff: Bool = false) -> some View {
        UserDefaults.standard.set(false, forKey: TodayHome.enabledKey)
        let model = base()
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        model.libraryMonth = String(day.prefix(7))
        if landed {
            model.libraryMeetings = ["Bottle POS weekly", "Gina 1:1, content calendar", "Leadership sync", "October offer review", "Team standup", "Design review"]
                .enumerated().compactMap { index, title in
                    LibraryMeeting(.object(["filename": .string("\(day)_Meeting_\(index).md"), "month": .string(String(day.prefix(7))),
                                            "domain": .string("quilt"), "title": .string(title), "date": .string(day)]))
                }
        } else if !handoff {
            model.libraryLoading = true
        }
        model.activityOpenSection = .meetings
        return ActivityWindow(model: model)
    }

    static func today(landed: Bool) -> some View {
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        let model = base()
        model.claudeSessionsEnabled = true
        let store = TodayHomeStore()
        store.reachable = true
        let handoff = WorkHandoffStore(isolated: true)
        guard landed else { return AnyView(ActivityWindow.todayFixture(model: model, store: store, handoff: handoff, loads: [:])) }
        let now = Date()
        func iso(_ m: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-m * 60)) }
        model.claudeSessions = [("t1", "Holiday promo landing page", "running"), ("a1", "Cigars POS Gen 2 Modules", "waiting")].compactMap { id, name, state in
            ClaudeSession(.object(["id": .string(id), "provider": .string("claude"), "name": .string(name), "state": .string(state),
                                   "updatedAt": .string(iso(1)), "stateSince": .string(iso(5)), "createdAt": .string(iso(5)), "alive": .bool(true),
                                   "waitingKind": .string(state == "waiting" ? "question" : ""), "waitingQuestion": .string(state == "waiting" ? "Which page?" : ""),
                                   "workspace": .string("MU-Chief-Staff"), "stateSource": .string("hook")]))
        }
        return AnyView(ActivityWindow.todayFixture(model: model, store: store, handoff: handoff))
    }

    // MARK: Geometry: the wire against the real rows

    struct Site { let name: String; let section: ActivitySection; let kind: String; let fill: (ControllerModel) -> Void; let card: Bool }

    static func geometry() throws {
        UserDefaults.standard.set(false, forKey: TodayHome.enabledKey)
        let now = Date()
        func iso(_ m: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-m * 60)) }
        let day = String(iso(0).prefix(10))
        let sites = [
            Site(name: "meetings", section: .meetings, kind: "rows", fill: { model in
                model.libraryMonth = String(day.prefix(7))
                model.libraryMeetings = (0..<8).compactMap { LibraryMeeting(.object(["filename": .string("\(day)_M_\($0).md"), "month": .string(String(day.prefix(7))),
                                                                                       "domain": .string("quilt"), "title": .string("Meeting \($0)"), "date": .string(day)])) }
            }, card: true),
            Site(name: "sessions", section: .sessions, kind: "rows", fill: { model in
                model.claudeSessionsEnabled = true
                model.claudeSessions = (0..<8).compactMap { ClaudeSession(.object(["id": .string("s\($0)"), "provider": .string("claude"), "name": .string("Session \($0)"),
                                                                                    "state": .string("recent"), "updatedAt": .string(iso(Double($0 * 30))), "workspace": .string("MU-Chief-Staff")])) }
            }, card: true),
            Site(name: "tasks", section: .tasks, kind: "rows", fill: { model in
                model.tasks = (0..<8).compactMap { TaskRow(.object(["id": .string("t\($0)"), "domain": .string("quilt"), "text": .string("Task number \($0)"),
                                                                    "column": .string("this week"), "section": .string("marketing")])) }
            }, card: true),
            Site(name: "memories", section: .memories, kind: "rows", fill: { model in
                model.memoryRecords = (0..<8).map { ContextRecord.memory(["id": .string("m\($0)"), "content": .string("Memory number \($0) about the October offer"),
                                                                          "created_at": .string(iso(Double($0 * 60)))]) }
            }, card: true),
            Site(name: "threads", section: .threads, kind: "rows", fill: { model in
                model.threadRecords = (0..<8).map { ContextRecord.thread(["id": .string("th\($0)"), "name": .string("Thread \($0)"), "last_seen": .string(iso(Double($0 * 90)))]) }
            }, card: true),
            Site(name: "messages", section: .messages, kind: "list", fill: { model in
                model.recentMessages = (0..<8).map { GlassesTurn(id: "g\($0)", no: 300 - $0, timestamp: now.addingTimeInterval(Double(-$0) * 3600).timeIntervalSince1970,
                                                                 query: "Question \($0)", text: "", sessionId: "s", source: "G2") }
                model.recentGlassesStatus = .ready
            }, card: false),
        ]
        for site in sites {
            // The wire's own frame and rows: the loaded view frozen mid-landing, read from inside the stage.
            var probe: COSBuildUpProbeFrame?
            COSBuildUpProbe.stage = { if $0.kind == site.kind { probe = $0 } }
            COSBuildUpProbe.freeze = COSBuildUpFrame(phase: .landing, drawT: 2, phaseT: 0)
            _ = try bitmap(view(site), size: CGSize(width: 900, height: 1100), appearance: .aqua)
            COSBuildUpProbe.freeze = nil
            COSBuildUpProbe.stage = nil
            // The real rows: the same view settled, found on the pixels.
            let (rep, scale) = try bitmap(view(site), size: CGSize(width: 900, height: 1100), appearance: .aqua)
            guard let probe else { print("geometry \(site.name): no build-up on screen"); continue }
            let rows = site.card ? cardRows(rep, scale: scale, frame: probe.frame) : textRows(rep, scale: scale, frame: probe.frame)
            func fmt(_ list: [(Double, Double)]) -> String { list.prefix(4).map { "y\(Int($0.0.rounded())) h\(Int($0.1.rounded()))" }.joined(separator: ", ") }
            print("geometry \(site.name): frame \(Int(probe.frame.width))x\(Int(probe.frame.height)) | real \(fmt(rows)) | wire \(fmt(probe.rects.map { (Double($0.minY), Double($0.height)) }))")
        }
    }

    static func view(_ site: Site) -> some View {
        let model = base()
        site.fill(model)
        model.activityOpenSection = site.section
        return ActivityWindow(model: model)
    }

    /// Runs of card fill down the middle of the wire's frame: each run is a row card (top and height, in points,
    /// from the frame's top).
    static func cardRows(_ rep: NSBitmapImageRep, scale: CGFloat, frame: CGRect) -> [(Double, Double)] {
        let x = Int((frame.minX + frame.width * 0.5) * scale)
        var rows: [(Double, Double)] = []
        var start: Int?
        let top = Int(frame.minY * scale)
        for y in top..<min(rep.pixelsHigh, Int(frame.maxY * scale)) {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            let white = (c?.redComponent ?? 0) > 0.985 && (c?.greenComponent ?? 0) > 0.985 && (c?.blueComponent ?? 0) > 0.985
            if white, start == nil { start = y }
            if !white, let s = start { rows.append((Double(CGFloat(s - top) / scale), Double(CGFloat(y - s) / scale))); start = nil }
        }
        return rows.filter { $0.1 > 12 }
    }

    /// Bands of ink across the wire's frame, merged across gaps under 7 pt: each is a row's text (top and height).
    static func textRows(_ rep: NSBitmapImageRep, scale: CGFloat, frame: CGRect) -> [(Double, Double)] {
        var inked: [Bool] = []
        for y in Int(frame.minY * scale)..<min(rep.pixelsHigh, Int(frame.maxY * scale)) {
            var any = false
            var x = Int((frame.minX + 30) * scale)
            while x < Int((frame.maxX - 30) * scale) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent + c.greenComponent + c.blueComponent < 1.8 { any = true; break }
                x += 2
            }
            inked.append(any)
        }
        var rows: [(Double, Double)] = []
        var start: Int?, lastInk = -100
        for (y, ink) in inked.enumerated() where ink {
            if let s = start, CGFloat(y - lastInk) / scale > 7 { rows.append((Double(CGFloat(s) / scale), Double(CGFloat(lastInk - s) / scale))); start = y }
            if start == nil { start = y }
            lastInk = y
        }
        if let s = start { rows.append((Double(CGFloat(s) / scale), Double(CGFloat(lastInk - s) / scale))) }
        return rows
    }

    // MARK: Drawing

    static func host(_ view: some View, size: CGSize, appearance: NSAppearance.Name) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(COSPalette.panel)))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        return (window, host)
    }

    static func bitmap(_ view: some View, size: CGSize, appearance: NSAppearance.Name) throws -> (NSBitmapImageRep, CGFloat) {
        let (window, host) = host(view, size: size, appearance: appearance)
        defer { window.close() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / size.width)
    }

    static func draw(_ view: some View, size: CGSize, appearance: NSAppearance.Name, name: String, out: URL) throws {
        let (rep, _) = try bitmap(view, size: size, appearance: appearance)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
        written += 1
    }
}

/// A Meeting Ask exchange (MeetingAsk.swift `answer`), whose real pane needs a live meeting: the question, the answer in its
/// real COSBuildUp(.answer) around the same branches, two sources and the footer, on the raised card.
private struct AskBoard: View {
    let landed: Bool
    let handoff: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: "What did we decide about the October offer?").font(COSType.body(12, weight: .semibold))
            COSBuildUp(.answer, loading: !landed && !handoff, landed: landed, label: "Checking the meeting", key: AnyHashable("render"),
                       background: COSPalette.raised) {
                if landed {
                    Text("So what: keep the offer live through October 31, then review sign-ups on the Monday call. "
                         + "Graham owns the landing page copy refresh, and Gina reviews it before Wednesday.")
                        .font(COSType.body(13)).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(handoff ? "No answer · failed" : "Checking the meeting…").font(COSType.body(12)).foregroundStyle(.secondary)
                }
            }
            Text("10:42  Keep it through the 31st").font(COSType.body(11)).foregroundStyle(COSPalette.accent)
            Text("10:51  Graham owns the copy").font(COSType.body(11)).foregroundStyle(COSPalette.accent)
            HStack { Text("Through 31:00 · Claude Sonnet").foregroundStyle(.secondary); Spacer(); Text("Copy").foregroundStyle(COSPalette.accent) }
                .font(COSType.body(10.5))
        }
        .padding(12)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 9))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
