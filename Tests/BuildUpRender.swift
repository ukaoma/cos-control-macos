import AppKit
import SwiftUI

/// 0.5.343 Build-up, in place, as drawn, by hand (Tests/run-build-up-render.sh <dir>), for a side-by-side check against the
/// approved mock (operations/personal/wk43_2026/mock-skeleton/skeleton-reveal.html). The whole app is compiled; each
/// board is the real `COSBuildUp` around stand-in content styled like its call site (the Meetings list's row cards, a
/// Meeting Ask exchange, the Today home's Needs you card), with invented text. Each board is drawn frozen at five moments:
/// the wire drawing (0.35 s into the build), the wire drawn (1.4 s, pulsing), mid-fill (120 ms after the data lands),
/// inking (250 ms) and final (settled), in light and dark.
///
/// One check: the final frame is pixel for pixel the content drawn without the wrapper, so the end state is the UI itself.
/// No window is ordered in, no event is sent, nothing becomes active. Prints "build up render: N passed".
@main @MainActor struct BuildUpRender {
    static var passed = 0
    static func expect(_ condition: Bool, _ what: String) {
        guard condition else { print("build up render FAILED: \(what)"); exit(1) }
        passed += 1
    }

    static let frames: [(String, COSBuildUpFrame)] = [
        ("1-wire-drawing", .init(phase: .building, drawT: 0.35)),
        ("2-wire", .init(phase: .building, drawT: 1.4)),
        ("3-mid-fill", .init(phase: .landing, drawT: 1.52, phaseT: 0.12)),
        ("4-inking", .init(phase: .landing, drawT: 1.65, phaseT: 0.25)),
        ("5-final", .init(phase: .settled, drawT: 0)),
    ]

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = appearance == .darkAqua ? "dark" : "light"
            for (name, frame) in frames {
                try draw(MeetingsBoard(frozen: frame), size: CGSize(width: 560, height: 420), appearance: appearance,
                         name: "meetings-list-\(name)-\(theme)", out: out)
                try draw(AskBoard(frozen: frame), size: CGSize(width: 560, height: 300), appearance: appearance,
                         name: "meeting-ask-\(name)-\(theme)", out: out)
                try draw(TodayBoard(frozen: frame), size: CGSize(width: 560, height: 300), appearance: appearance,
                         name: "today-needs-you-\(name)-\(theme)", out: out)
            }
            // The end state is the UI itself: the settled wrapper draws exactly what the content draws alone.
            for (label, wrapped, plain) in [("meetings", AnyView(MeetingsBoard(frozen: .init(phase: .settled, drawT: 0))), AnyView(MeetingsBoard(frozen: nil))),
                                            ("ask", AnyView(AskBoard(frozen: .init(phase: .settled, drawT: 0))), AnyView(AskBoard(frozen: nil))),
                                            ("today", AnyView(TodayBoard(frozen: .init(phase: .settled, drawT: 0))), AnyView(TodayBoard(frozen: nil)))] {
                let size = CGSize(width: 560, height: label == "meetings" ? 420 : 300)
                let a = try bitmap(wrapped, size: size, appearance: appearance)
                let b = try bitmap(plain, size: size, appearance: appearance)
                expect(a == b, "\(label) \(theme): the settled build-up draws the content pixel for pixel")
            }
        }
        print("build up render: \(passed) passed; \(frames.count * 3 * 2) PNGs in \(out.path)")
    }

    static func host(_ view: some View, size: CGSize, appearance: NSAppearance.Name) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(COSPalette.panel).cosControlTheme()))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        settle(host, 0.4)
        return (window, host)
    }

    static func bitmap(_ view: some View, size: CGSize, appearance: NSAppearance.Name) throws -> Data {
        let (window, host) = host(view, size: size, appearance: appearance)
        defer { window.close() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerPlane)
    }

    static func draw(_ view: some View, size: CGSize, appearance: NSAppearance.Name, name: String, out: URL) throws {
        let (window, host) = host(view, size: size, appearance: appearance)
        defer { window.close() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
        expect(rep.pixelsWide > 0, "\(name) drew")
    }

    static func settle(_ host: NSView, _ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
    }
}

/// `frozen == nil`: the content alone, as today draws it.
@MainActor @ViewBuilder
private func wrap<V: View>(_ frozen: COSBuildUpFrame?, _ shape: COSBuildUpShape, label: String, background: Color = COSPalette.panel,
                           @ViewBuilder _ content: @escaping () -> V) -> some View {
    if let frozen {
        COSBuildUp(shape, loading: true, landed: false, label: label, background: background, frozen: frozen, content: content)
    } else {
        content()
    }
}

/// The Meetings list (ActivityMeetings.swift): a month header, then the row cards as `meetingRow` draws them.
private struct MeetingsBoard: View {
    let frozen: COSBuildUpFrame?
    static let rows = [("Bottle POS weekly", "Thu Oct 23 · 31 min · Mac recording"), ("Gina 1:1, content calendar", "Thu Oct 23 · 28 min · Glasses"),
                       ("Leadership sync", "Wed Oct 22 · 54 min · Fireflies"), ("October offer review", "Wed Oct 22 · 19 min · Mac recording"),
                       ("Team standup", "Wed Oct 22 · 22 min · Google Meet")]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meetings").font(COSType.display(22, weight: .medium)).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
            Divider()
            wrap(frozen, .rows(6), label: "Loading meetings") {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Self.rows, id: \.0) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.0).font(COSType.body(13.5, weight: .semibold))
                                    Text(row.1).font(COSType.body(11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("REVIEWED").font(COSType.mono(8.5, weight: .bold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2).overlay(Capsule().stroke(COSPalette.line))
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                            .cosRowCard()
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A Meeting Ask exchange (MeetingAsk.swift `answer`): the question, the answer, two sources and the footer, on the raised card.
private struct AskBoard: View {
    let frozen: COSBuildUpFrame?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: "What did we decide about the October offer?").font(COSType.body(12, weight: .semibold))
            wrap(frozen, .answer, label: "Checking the meeting", background: COSPalette.raised) {
                Text("**So what:** keep the offer live through October 31, then review sign-ups on the Monday call. "
                     + "Graham owns the landing page copy refresh, and Gina reviews it before Wednesday.")
                    .font(COSType.body(13)).fixedSize(horizontal: false, vertical: true)
            }
            Text("10:42  Keep it through the 31st").font(COSType.body(11)).foregroundStyle(COSPalette.accent)
            Text("10:51  Graham owns the copy").font(COSType.body(11)).foregroundStyle(COSPalette.accent)
            HStack {
                Text("Through 31:00 · Claude Sonnet").foregroundStyle(.secondary)
                Spacer()
                Text("Copy").foregroundStyle(COSPalette.accent)
            }
            .font(COSType.body(10.5))
        }
        .padding(12)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 9))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The Today home's Needs you card (ActivityWindow.swift `todayNeedsPanel`): the header, then its rows.
private struct TodayBoard: View {
    let frozen: COSBuildUpFrame?
    static let rows = [("Name 2 voices in Bottle POS weekly", "Speakers · from a meeting today"), ("Review 4 suggestions from today's meetings", "Work · 4 waiting"),
                       ("Approve the Monday persona refresh", "Memories · waiting since Friday")]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Needs you").font(COSType.body(17, weight: .semibold)).foregroundStyle(TodayInk.ink)
                Text("3").font(COSType.body(17, weight: .semibold)).foregroundStyle(TodayInk.hot)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            wrap(frozen, .cardRows(3, badge: false), label: "Reading sessions and Work", background: TodayInk.panel) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.rows, id: \.0) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.0).font(COSType.body(14, weight: .semibold)).foregroundStyle(TodayInk.ink)
                            Text(row.1).font(COSType.body(12.5)).foregroundStyle(TodayInk.sub)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(TodayInk.rowBorder).frame(height: 1) }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(TodayInk.panel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TodayInk.page)
    }
}
