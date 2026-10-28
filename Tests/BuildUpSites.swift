import AppKit
import SwiftUI

/// The build-up sites, shared by the measuring tool (Tests/BuildUpGeometry.swift) and the geometry lane of
/// Tests/BuildUpViewChecks.swift: every view that shows a build-up skeleton, on the real call site (the production
/// Activity window through ActivityWindow.buildUpFixture / todayFixture, or the real detail pane drawn alone at the content
/// column's width), loading or loaded with fixture data, and the pixel readers for the loaded view.
@MainActor enum BuildUpSites {
    enum Rows: String { case cards, divided, ink }

    struct Site {
        let name: String
        let kind: String
        let rows: Rows
        /// Which stage is this site's when the window shows more than one.
        var pick: (COSBuildUpProbeFrame) -> Bool = { _ in true }
        /// A divided list's rule starts this far in from the row's leading edge (the row's x is the rule's less this).
        var ruleInset: Double = 0
        /// The site at this window size, loading (false) or loaded (true), on a fresh model.
        let view: (_ loaded: Bool, _ size: CGSize) -> AnyView
        /// Drawn alone at the content column's width (a detail pane whose route needs live navigation), not in the window.
        var alone = false
    }

    struct Measure: Codable, Sendable {
        var site = "", width = 0, theme = "", alone = false
        // Skeleton (frame-local rects; frame in window points).
        var skFrame: [Double] = [], skRows = 0, skRowX = 0.0, skRowW = 0.0, skRowH = 0.0, skPitch = 0.0, skExtent = 0.0
        // Loaded.
        var ldFrame: [Double] = [], ldRows = 0, ldRowX = 0.0, ldRowW = 0.0, ldRowH = 0.0, ldPitch = 0.0, ldExtent = 0.0
        var ldInk: [Double] = []   // left, top, right, bottom, frame-local
        var skBoxes: [[Double]] = [], ldBoxes: [[Double]] = [], ldLines: [[Double]] = []   // [x, y, w, h], first few
        var note = ""
    }


    /// One site at one window size and appearance: the skeleton (every COSBuildUp frozen at the drawn wire, still loading)
    /// against the loaded view (its frame from the first landing frame, its rows from the settled pixels). PNGs to `out`.
    static func measure(_ site: Site, size: CGSize, appearance: NSAppearance.Name, out: URL?) throws -> Measure {
        var m = Measure(site: site.name, width: Int(size.width), theme: appearance == .darkAqua ? "dark" : "light", alone: site.alone)
        let base = "\(site.name)-\(Int(size.width))-\(appearance == .darkAqua ? "dark" : "light")"
        // The skeleton.
        fresh()
        var probe: COSBuildUpProbeFrame?
        // Only a stage inside this window (a hosted view from an earlier render may still report its own).
        let inside = { (p: COSBuildUpProbeFrame) in p.frame.maxX <= size.width + 0.5 && p.frame.maxY <= size.height + 0.5 }
        COSBuildUpProbe.stage = { if $0.kind == site.kind, site.pick($0), inside($0) { probe = $0 } }
        COSBuildUpProbe.freeze = COSBuildUpFrame(phase: .building, drawT: 1.4)
        let skel = bitmap(site.view(false, size), size: size, appearance: appearance)
        if let out { try png(skel, out.appendingPathComponent(base + "-skeleton.png")) }
        if let p = probe {
            m.skFrame = [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height].map { Double($0) }
            let rs = p.rects
            m.skRows = rs.count
            if let r = rs.first { m.skRowX = Double(r.minX); m.skRowW = Double(r.width); m.skRowH = Double(r.height) }
            if rs.count > 1 { m.skPitch = Double(rs[1].minY - rs[0].minY) }
            m.skExtent = Double(rs.map(\.maxY).max() ?? 0)
            m.skBoxes = rs.prefix(8).map { [$0.minX, $0.minY, $0.width, $0.height].map { Double($0) } }
        } else { m.note += "no skeleton drawn; " }
        // The loaded content's frame: the first landing frame (nothing hidden, nothing resized).
        fresh()
        probe = nil
        COSBuildUpProbe.freeze = COSBuildUpFrame(phase: .landing, drawT: 2, phaseT: 0)
        _ = bitmap(site.view(true, size), size: size, appearance: appearance)
        COSBuildUpProbe.freeze = nil
        COSBuildUpProbe.stage = nil
        let frame = probe?.frame
        if frame == nil { m.note += "no loaded frame; " }
        // The loaded view, settled.
        fresh()
        let loaded = bitmap(site.view(true, size), size: size, appearance: appearance)
        if let out { try png(loaded, out.appendingPathComponent(base + "-loaded.png")) }
        if let frame {
            m.ldFrame = [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }
            let px = BuildUpPixels(rep: loaded, size: size, frame: frame)
            if let ink = px.ink() { m.ldInk = ink }
            let rows: [CGRect]
            switch site.rows {
            case .cards: rows = px.cardRows()
            case .divided: rows = px.dividedRows()
            case .ink: rows = []
            }
            m.ldRows = rows.count
            m.ldBoxes = rows.prefix(8).map { [$0.minX, $0.minY, $0.width, $0.height].map { Double($0) } }
            m.ldLines = px.inkLines().prefix(16).map { [Double($0.0), Double($0.1)] }
            if let r = rows.first { m.ldRowX = Double(r.minX); m.ldRowW = Double(r.width); m.ldRowH = Double(r.height) }
            if rows.count > 1 { m.ldPitch = Double(rows[1].minY - rows[0].minY) }
            m.ldExtent = rows.isEmpty ? (m.ldInk.count == 4 ? m.ldInk[3] : 0) : Double(rows.map(\.maxY).max() ?? 0)
        }
        return m
    }

    static func fresh() {
        COSBuildUpSession.memory = COSBuildUpMemory()
        UserDefaults.standard.removeObject(forKey: COSBuildUpSession.emptyKey)
    }

    // MARK: Sites

    static func model() -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        model.petEnabled = false
        var status = model.status
        status.running = true
        status.memoryAvailable = true; status.memoryCount = 412
        status.threadsAvailable = true; status.threadCount = 66
        model.status = status
        return model
    }

    static let now = Date()
    static func iso(_ m: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-m * 60)) }
    static var day: String { String(iso(0).prefix(10)) }

    static func window(_ section: ActivitySection, speakers: String? = nil, memories: String? = nil, _ setup: @escaping (ControllerModel, Bool) -> Void)
        -> (Bool, CGSize) -> AnyView {
        { loaded, size in
            UserDefaults.standard.set(false, forKey: TodayHome.enabledKey)
            let m = model()
            setup(m, loaded)
            m.activityOpenSection = section
            return AnyView(ActivityWindow.buildUpFixture(model: m, section: section, speakers: speakers, memories: memories)
                .frame(width: size.width, height: size.height))
        }
    }

    /// The content column's width beside the rail at this window size (a pane drawn alone sits in it).
    static func column(_ size: CGSize) -> CGFloat { size.width - railWidth(size) }
    static var rails: [CGFloat: CGFloat] = [:]
    static func railWidth(_ size: CGSize) -> CGFloat {
        if let w = rails[size.width] { return w }
        var frame: CGRect?
        let savedStage = COSBuildUpProbe.stage
        defer { COSBuildUpProbe.stage = savedStage }
        COSBuildUpProbe.stage = { if $0.kind == "rows" { frame = $0.frame } }
        let saved = COSBuildUpProbe.freeze
        COSBuildUpProbe.freeze = COSBuildUpFrame(phase: .building, drawT: 1.4)
        _ = bitmap(window(.sessions) { m, _ in m.claudeSessionsEnabled = true; m.claudeSessionsLoading = true }(false, size), size: size, appearance: .aqua)
        COSBuildUpProbe.freeze = saved
        let w = frame?.minX ?? 0
        rails[size.width] = w
        return w
    }

    static func all() -> [Site] {
        let meetings = (0..<16).compactMap { i in
            LibraryMeeting(.object(["filename": .string("\(day)_M_\(i).md"), "month": .string(String(day.prefix(7))), "domain": .string("quilt"),
                                    "title": .string(["Bottle POS weekly", "Gina 1:1, content calendar", "Leadership sync", "October offer review"][i % 4]),
                                    "date": .string(day)]))
        }
        return [
            Site(name: "meetings-list", kind: "rows", rows: .cards, view: window(.meetings) { m, loaded in
                m.libraryMonth = String(day.prefix(7))
                if loaded { m.libraryMeetings = meetings } else { m.libraryLoading = true }
            }),
            Site(name: "sessions-list", kind: "rows", rows: .cards, view: window(.sessions) { m, loaded in
                m.claudeSessionsEnabled = true
                if loaded {
                    m.claudeSessions = (0..<16).compactMap { ClaudeSession(.object(["id": .string("s\($0)"), "provider": .string("claude"), "name": .string("Session \($0) holiday promo"),
                                                                                 "state": .string("recent"), "updatedAt": .string(iso(Double($0 * 30))), "workspace": .string("MU-Chief-Staff")])) }
                } else { m.claudeSessionsLoading = true }
            }),
            Site(name: "memories-list", kind: "rows", rows: .cards, view: window(.memories, memories: "allMemories") { m, loaded in
                if loaded {
                    m.memoryRecords = (0..<16).map { ContextRecord.memory(["id": .string("m\($0)"), "content": .string("Memory number \($0) about the October offer"),
                                                                           "created_at": .string(iso(Double($0 * 60)))]) }
                } else { m.memoryRecordsLoading = true }
            }),
            Site(name: "threads-list", kind: "rows", rows: .cards, view: window(.threads) { m, loaded in
                if loaded {
                    m.threadRecords = (0..<16).map { ContextRecord.thread(["id": .string("th\($0)"), "name": .string("Thread \($0)"), "last_seen": .string(iso(Double($0 * 90)))]) }
                } else { m.threadRecordsLoading = true }
            }),
            Site(name: "messages-list", kind: "list", rows: .divided, ruleInset: 46, view: window(.messages) { m, loaded in
                if loaded {
                    m.recentMessages = (0..<16).map { GlassesTurn(id: "g\($0)", no: 300 - $0, timestamp: now.addingTimeInterval(Double(-$0) * 3600).timeIntervalSince1970,
                                                                  query: "Question \($0) about the offer", text: "", sessionId: "s", source: "G2") }
                    m.recentGlassesStatus = .ready
                } else { m.recentGlassesStatus = .loading }
            }),
            Site(name: "speakers-meetings", kind: "list", rows: .divided, ruleInset: 46, view: window(.speakers, speakers: "meetings") { m, loaded in
                if loaded {
                    m.reviewableMeetings = (0..<16).compactMap { ReviewableMeeting(.object(["sessionId": .string("r\($0)"), "title": .string("Review meeting \($0)"),
                                                                                            "date": .string(day), "duration": .string("42 minutes")])) }
                } else { m.meetingsLoading = true }
            }),
            Site(name: "speakers-voices", kind: "list", rows: .divided, ruleInset: 52, view: window(.speakers, speakers: "voices") { m, loaded in
                if loaded {
                    m.voiceDirectory = (0..<16).compactMap { VoiceDirectoryPerson(.object(["name": .string("Person \($0)"), "embeddings": .number(12)])) }
                } else { m.voiceDirectoryLoading = true }
            }),
            Site(name: "learning-recent", kind: "list", rows: .divided, ruleInset: 46, view: window(.memories, memories: "recentLearning") { m, loaded in
                if loaded {
                    m.learningEvents = (0..<16).compactMap { LearningEvent(.object(["event_id": .string("e\($0)"), "event_type": .string("captured"), "ts": .string(iso(Double($0 * 20))),
                                                                                    "title": .string("Lesson \($0): keep the offer live"), "store": .string("gotchas")])) }
                } else { m.learningLoading = true }
            }),
            Site(name: "today-needs-you", kind: "cardRows", rows: .ink, pick: { ($0.rects.first?.minX ?? 0) > 1 }, view: { loaded, size in today(loaded: loaded, size: size) }),
            Site(name: "today-running", kind: "cardRows", rows: .ink, pick: { ($0.rects.first?.minX ?? 1) < 1 }, view: { loaded, size in today(loaded: loaded, size: size) }),
            Site(name: "meeting-ask-answer", kind: "answer", rows: .ink, view: { loaded, size in
                AnyView(BuildUpAskBoard(landed: loaded).frame(width: min(560, column(size) * 0.5), height: 320).frame(width: size.width, height: size.height, alignment: .topLeading))
            }, alone: true),
            Site(name: "session-detail", kind: "turns", rows: .ink, view: { loaded, size in
                let m = model()
                m.openClaudeRow = ClaudeSession(.object(["id": .string("s1"), "provider": .string("claude"), "name": .string("Holiday promo landing page"),
                                                         "state": .string("recent"), "updatedAt": .string(iso(3)), "workspace": .string("MU-Chief-Staff")]))
                if loaded {
                    m.claudeSessionDetail = ClaudeSessionDetail(.object(["title": .string("Holiday promo landing page"), "turns": .array((0..<14).map { i in
                        .object(["id": .string("t\(i)"), "role": .string(i % 2 == 0 ? "user" : "assistant"),
                                 "text": .string(i % 2 == 0 ? "Can you tighten the hero copy?" : "Done. The hero now leads with the offer, and the second line names the deadline. "
                                                 + "I kept the CTA as it was."), "timestamp": .string(iso(Double(30 - i)))])
                    })]))
                } else { m.claudeSessionDetailLoading = true }
                return AnyView(ClaudeSessionDetailPane(model: m).frame(width: column(size), height: size.height).frame(width: size.width, height: size.height, alignment: .topTrailing))
            }, alone: true),
            Site(name: "meeting-detail", kind: "summary", rows: .ink, view: { loaded, size in
                let m = model()
                m.openLibraryRow = meetings.first
                if loaded {
                    m.libraryDetail = LibraryMeetingDetail(.object(["title": .string("Bottle POS weekly"), "date": .string(day), "summary": .string(
                        "The team kept the October offer live through the 31st and moved the landing page refresh to Graham. Gina reviews the copy before Wednesday."),
                        "transcript": .string((0..<24).map { "**Speaker \($0 % 3 + 1)** [00:\(String(format: "%02d", $0)):00]: We keep the offer live and review sign-ups on Monday." }
                            .joined(separator: "\n\n"))]))
                } else { m.libraryDetailLoading = true }
                return AnyView(MeetingLibraryDetailPane(model: m, onReviewVoices: { _, _ in }).frame(width: column(size), height: size.height)
                    .frame(width: size.width, height: size.height, alignment: .topTrailing))
            }, alone: true),
        ] + (ProcessInfo.processInfo.environment["COS_CONTROL_WORK_DISABLED"] == "1" ? [
            Site(name: "tasks-list", kind: "rows", rows: .cards, view: window(.tasks) { m, loaded in
                if loaded {
                    m.tasks = (0..<16).compactMap { TaskRow(.object(["id": .string("k\($0)"), "title": .string("Task \($0): send the offer recap"), "domain": .string("quilt"),
                                                                     "column": .string("This week")])) }
                } else { m.tasksLoading = true }
            }),
        ] : [])
    }

    static func today(loaded: Bool, size: CGSize) -> AnyView {
        UserDefaults.standard.set(true, forKey: TodayHome.enabledKey)
        let m = model()
        m.claudeSessionsEnabled = true
        let store = TodayHomeStore()
        store.reachable = true
        let handoff = WorkHandoffStore(isolated: true)
        guard loaded else { return AnyView(ActivityWindow.todayFixture(model: m, store: store, handoff: handoff, loads: [:]).frame(width: size.width, height: size.height)) }
        m.claudeSessions = [("t1", "Holiday promo landing page", "running"), ("t2", "Cigars POS Gen 2 Modules", "running"), ("a1", "Bottle hero refresh", "waiting"),
                            ("a2", "ITR footer QA", "waiting")].compactMap { id, name, state in
            ClaudeSession(.object(["id": .string(id), "provider": .string("claude"), "name": .string(name), "state": .string(state),
                                   "updatedAt": .string(iso(1)), "stateSince": .string(iso(5)), "createdAt": .string(iso(5)), "alive": .bool(true),
                                   "waitingKind": .string(state == "waiting" ? "question" : ""), "waitingQuestion": .string(state == "waiting" ? "Which page?" : ""),
                                   "workspace": .string("MU-Chief-Staff"), "stateSource": .string("hook")]))
        }
        return AnyView(ActivityWindow.todayFixture(model: m, store: store, handoff: handoff).frame(width: size.width, height: size.height))
    }

    // MARK: Drawing

    static func bitmap(_ view: some View, size: CGSize, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(COSPalette.panel)))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        window.close()
        return rep
    }

    static func png(_ rep: NSBitmapImageRep, _ url: URL) throws {
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

/// The loaded view's pixels inside the content frame, in frame-local points.
@MainActor struct BuildUpPixels {
    let rep: NSBitmapImageRep
    let scale: CGFloat
    let frame: CGRect
    let bg: (Double, Double, Double)

    init(rep: NSBitmapImageRep, size: CGSize, frame: CGRect) {
        self.rep = rep
        scale = CGFloat(rep.pixelsWide) / size.width
        self.frame = frame
        // The surface: the most common colour down the frame's first 3 pt (a gutter on every site).
        var counts: [String: (Int, (Double, Double, Double))] = [:]
        let x = Int((frame.minX + 2) * scale)
        for y in stride(from: Int(frame.minY * scale) + 1, to: min(rep.pixelsHigh, Int(frame.maxY * scale)) - 1, by: 2) {
            guard let c = Self.rgb(rep, x, y) else { continue }
            let key = String(format: "%.2f %.2f %.2f", c.0, c.1, c.2)
            counts[key, default: (0, c)].0 += 1
        }
        bg = counts.values.max { $0.0 < $1.0 }?.1 ?? (1, 1, 1)
    }

    static func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Double, Double, Double)? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// Whether the pixel at frame-local points (x, y) differs from the surface.
    func off(_ x: CGFloat, _ y: CGFloat, by limit: Double = 0.012) -> Bool {
        guard let c = Self.rgb(rep, Int((frame.minX + x) * scale), Int((frame.minY + y) * scale)) else { return false }
        return abs(c.0 - bg.0) > limit || abs(c.1 - bg.1) > limit || abs(c.2 - bg.2) > limit
    }

    /// The box around everything drawn in the frame (left, top, right, bottom), 1 pt in from its edges.
    func ink() -> [Double]? {
        var l = CGFloat.infinity, t = CGFloat.infinity, r = -CGFloat.infinity, b = -CGFloat.infinity
        for y in stride(from: CGFloat(1), to: frame.height - 1, by: 1) {
            for x in stride(from: CGFloat(1), to: frame.width - 1, by: 1) where off(x, y, by: 0.03) {
                l = min(l, x); r = max(r, x); t = min(t, y); b = max(b, y)
            }
        }
        return l.isFinite ? [Double(l), Double(t), Double(r), Double(b)] : nil
    }

    /// The bands of the frame that hold any ink (text lines, rules, cards' edges), as (top, height), 1 pt in from the sides.
    func inkLines() -> [(CGFloat, CGFloat)] {
        var bands: [(CGFloat, CGFloat)] = []
        var start: CGFloat?
        for y in stride(from: CGFloat(0), to: frame.height, by: 1) {
            var any = false
            for x in stride(from: CGFloat(4), to: frame.width - 4, by: 2) where off(x, y, by: 0.03) { any = true; break }
            if any, start == nil { start = y }
            if !any, let s = start { bands.append((s, y - s)); start = nil }
        }
        if let s = start { bands.append((s, frame.height - s)) }
        return bands
    }

    /// Card rows: the card's left edge is the first column from the left where a quarter of the frame is off the surface;
    /// rows are the runs of card fill 6 pt inside it, at least 12 pt tall; their width runs to the card's right edge.
    func cardRows() -> [CGRect] {
        var left: CGFloat?
        for x in stride(from: CGFloat(1), to: min(80, frame.width), by: 1) {
            var hits = 0, total = 0
            for y in stride(from: CGFloat(0), to: frame.height, by: 2) { total += 1; if off(x, y) { hits += 1 } }
            if Double(hits) > Double(total) * 0.25 { left = x; break }
        }
        guard let left else { return [] }
        let x = left + 6
        var rows: [CGRect] = []
        var start: CGFloat?
        for y in stride(from: CGFloat(0), to: frame.height, by: 0.5) {
            let card = off(x, y)
            if card, start == nil { start = y }
            if !card, let s = start {
                if y - s > 12 { rows.append(CGRect(x: left, y: s, width: 0, height: y - s)) }
                start = nil
            }
        }
        if let s = start, frame.height - s > 12 { rows.append(CGRect(x: left, y: s, width: 0, height: frame.height - s)) }
        guard let first = rows.first else { return [] }
        var right = left
        // Below the card's 10 pt corner radius, so the edge is the card's full width.
        let y = first.minY + 12
        for xx in stride(from: left, to: frame.width, by: 0.5) { if off(xx, y) { right = xx } else if xx > left + 40 { break } }
        return rows.map { CGRect(x: $0.minX, y: $0.minY, width: right - left + 0.5, height: $0.height) }
    }

    /// A divided list: 1 pt rules across the right half; each row runs from the rule above (or the first rule less a pitch)
    /// to the rule below. A rule's left and right ends are the row's x and width.
    func dividedRows() -> [CGRect] {
        let xs: [CGFloat] = [0.55, 0.7, 0.85].map { frame.width * $0 }
        var rules: [CGFloat] = []
        var last: CGFloat = -10
        for y in stride(from: CGFloat(0), to: frame.height, by: 0.5) {
            let line = xs.allSatisfy { off($0, y, by: 0.02) } && xs.allSatisfy { !off($0, y - 2.5, by: 0.02) || !off($0, y + 2.5, by: 0.02) }
            if line, y - last > 4 { rules.append(y) }
            if line { last = y }
        }
        guard rules.count >= 2 else { return [] }
        let y = rules[0]
        var l = frame.width * 0.55, r = frame.width * 0.55
        while l > 0, off(l - 0.5, y, by: 0.02) { l -= 0.5 }
        while r < frame.width, off(r + 0.5, y, by: 0.02) { r += 0.5 }
        let pitch = rules[1] - rules[0]
        var rows = [CGRect(x: l, y: rules[0] - (pitch - 1), width: r - l, height: pitch - 1)]
        for k in 0..<(rules.count - 1) { rows.append(CGRect(x: l, y: rules[k] + 1, width: r - l, height: rules[k + 1] - rules[k] - 1)) }
        return rows
    }
}

/// A Meeting Ask exchange (MeetingAsk.swift `answer`), whose real pane needs a live meeting: the question, the answer in its
/// real COSBuildUp(.answer) around the same branches, two sources and the footer, on the raised card.
struct BuildUpAskBoard: View {
    let landed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: "What did we decide about the October offer?").font(COSType.body(12, weight: .semibold))
            COSBuildUp(.answer, loading: !landed, landed: landed, label: "Checking the meeting", key: AnyHashable("geometry"),
                       background: COSPalette.raised) {
                if landed {
                    // The real answer's renderer (MeetingAsk.swift draws a plain answer with COSMarkdownView at 13 pt).
                    COSMarkdownView(text: "So what: keep the offer live through October 31, then review sign-ups on the Monday call. "
                                    + "Graham owns the landing page copy refresh, and Gina reviews it before Wednesday.", bodySize: 13)
                } else {
                    Text("Checking the meeting…").font(COSType.body(12)).foregroundStyle(.secondary)
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
