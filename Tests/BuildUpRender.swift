import AppKit
import SwiftUI

/// 0.5.343 Build-up, in place, as drawn, by hand (Tests/run-build-up-render.sh <dir>), for a side-by-side check against the
/// approved mock (operations/personal/wk43_2026/mock-skeleton/skeleton-reveal.html). The whole app is compiled.
///
///   - v2-* PNGs: the REAL call sites (the classic Activity window's Meetings list; the Today home's Needs you and Running
///     cards) with fictional fixture data, every COSBuildUp frozen through COSBuildUpProbe.freeze at the wire drawing, the
///     wire, the 3 s words, mid-landing, final and a hand-off; and the Meeting Ask answer around stand-in text (its pane
///     needs a live meeting). Light and dark.
///   - The geometry parity (the wire's rows against the real rows) is a check in Tests/BuildUpViewChecks.swift.
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
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = appearance == .darkAqua ? "dark" : "light"
            for (name, frame, landed) in frames {
                COSBuildUpProbe.freeze = frame
                let handoff = frame?.phase == .handoff
                try draw(meetings(landed: landed, handoff: handoff), size: CGSize(width: 900, height: 1100), appearance: appearance,
                         name: "v2-meetings-list-\(name)-\(theme)", out: out)
                try draw(today(landed: landed), size: CGSize(width: 1440, height: 980), appearance: appearance,
                         name: "v2-today-cards-\(name)-\(theme)", out: out)
                try draw(AskBoard(landed: landed, handoff: handoff), size: CGSize(width: 560, height: 260), appearance: appearance,
                         name: "v2-meeting-ask-\(name)-\(theme)", out: out)
            }
            COSBuildUpProbe.freeze = nil
        }
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
            // 0.5.353: the Working line sits above the answer's block while it is written (MeetingAsk.swift).
            if !landed && !handoff { Text(MeetingAskText.working).font(COSType.body(12)).foregroundStyle(.secondary) }
            COSBuildUp(.answer, loading: !landed && !handoff, landed: landed, label: "Checking the meeting", key: AnyHashable("render"),
                       background: COSPalette.raised) {
                if landed {
                    Text("So what: keep the offer live through October 31, then review sign-ups on the Monday call. "
                         + "Graham owns the landing page copy refresh, and Gina reviews it before Wednesday.")
                        .font(COSType.body(13)).fixedSize(horizontal: false, vertical: true)
                } else {
                    if handoff { Text("No answer · failed").font(COSType.body(12)).foregroundStyle(.secondary) } else { Color.clear.frame(height: 0) }
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
