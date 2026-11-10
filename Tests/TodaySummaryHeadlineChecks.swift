import AppKit
import CoreText
import SwiftUI

/// T1 (Miles 2026-11-09, "The title keeps changing ... which creates alot of bouncing"): Sources/TodaySummaryHeadline.swift.
/// Part 1 executes every TodayHeadlineHeight and TodaySummaryHold rule. Part 2 draws the Today headline off screen, the way todayHomeView lays
/// it out (Fraunces 25 pt with 8 pt line spacing in a 980 pt column, and 22 pt with 6 pt in the 697 pt column of an
/// 817 pt window), with the "Updated" line under it, and swaps the text through summaries of different lengths and the
/// one-line counts headline. It records, in points, where the first element below the headline sits after each swap:
/// BEFORE (the plain Text, as 0.5.386 drew it) and AFTER (TodayHeadlineText). PNGs of both go to the folder given.
/// Nothing is shown on screen, clicked or typed. Fictional text only.
@main @MainActor struct TodaySummaryHeadlineChecks {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments.dropFirst()
        guard let fontPath = args.first else { print("usage: <Fraunces.ttf> [png folder]"); exit(2) }
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: fontPath) as CFURL, .process, nil)
        let out = args.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        rules()
        holdRules()
        await render(column: 980, size: 25, spacing: 8, label: "wide-1634pt-window", out: out)
        await render(column: 697, size: 22, spacing: 6, label: "narrow-817pt-window", out: out)
        await alternation(column: 980, size: 25, spacing: 8, label: "wide-1634pt-window", out: out)
        await alternation(column: 697, size: 22, spacing: 6, label: "narrow-817pt-window", out: out)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Part 1: the rules

    static func rules() {
        let t0 = Date(timeIntervalSince1970: 1_794_000_000)
        var h = TodayHeadlineHeight()
        check(h.measured(height: 194.1, width: 980, key: "d1|0", now: t0) == 194.5, "first measurement: the block fits its text (half-point steps)")
        check(h.measured(height: 155.3, width: 980, key: "d1|0", now: t0.addingTimeInterval(600)) == 194.5, "a shorter rewrite keeps the height (nothing below moves up)")
        check(h.measured(height: 233.0, width: 980, key: "d1|0", now: t0.addingTimeInterval(1200)) == 233.0, "a longer rewrite grows the block (nothing is cut)")
        check(h.measured(height: 39.0, width: 980, key: "d1|0", now: t0.addingTimeInterval(1300)) == 233.0, "a fall back to the one-line counts headline keeps the height")
        check(h.measured(height: 155.0, width: 700, key: "d1|0", now: t0.addingTimeInterval(1400)) == 155.0, "a new window width re-fits (the text re-flowed anyway)")
        check(h.measured(height: 194.0, width: 700.4, key: "d1|0", now: t0.addingTimeInterval(1500)) == 194.0, "under a point of width jitter is the same width: grows only")
        check(h.measured(height: 150.0, width: 700.4, key: "d1|0", now: t0.addingTimeInterval(1510)) == 194.0, "and does not shrink on jitter")
        // Refresh finished with the same text (no new measurement): the block fits what is shown now.
        check(h.reset(key: "d1|99", now: t0.addingTimeInterval(1600)) == 150.0, "Refresh: the block fits the text shown now")
        check(h.measured(height: 117.0, width: 700.4, key: "d1|99", now: t0.addingTimeInterval(1601)) == 117.0, "Refresh: the new text landing within 3 s may shrink it")
        check(h.measured(height: 80.0, width: 700.4, key: "d1|99", now: t0.addingTimeInterval(1602)) == 117.0, "Refresh: only the first text after it re-fits")
        _ = h.reset(key: "d1|100", now: t0.addingTimeInterval(1700))
        check(h.measured(height: 60.0, width: 700.4, key: "d1|100", now: t0.addingTimeInterval(1704)) == 117.0, "Refresh: a rewrite after the 3 s window is an ordinary one (no shrink)")
        check(h.reset(key: "d1|100", now: t0.addingTimeInterval(1800)) == 117.0, "the same key again is not a reset")
        check(h.measured(height: 80.0, width: 700.4, key: "d2|100", now: t0.addingTimeInterval(90_000)) == 80.0, "a new day re-fits")
    }

    // MARK: Part 1b: Miles's 9:33 PM alternation (TodaySummaryHold)

    static func holdRules() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        func reply(_ state: String, at: Date?, text: String = s5) -> TodaySummary.Reply? {
            var o: [String: JSONValue] = ["text": .string(text), "state": .string(state), "enabled": .bool(true)]
            if let at { o["at"] = .string(iso.string(from: at)) }
            return TodaySummary.Reply(.object(o))
        }
        let stored = reply("stale", at: now.addingTimeInterval(-6 * 60))
        check(stored?.at != nil, "fixture: the stored summary parses with its time")
        var c = TodayHome.Counts()
        c.sessionsKnown = true
        // The pet's poll every 20 s: answered, pending (the helper call), answered, failed (a partial live read), pending, answered.
        let reads: [ActivityHome.SourceState] = [.answered, .pending, .answered, .failed, .pending, .answered]
        var beforeDropped = 0, afterDropped = 0, askMissing = 0
        for state in reads {
            c.sessionsKnown = state == .answered
            if TodaySummary.headline(c, summary: TodaySummary.shown(stored, sessionsRead: c.sessionsKnown)) != stored?.text { beforeDropped += 1 }
            let shown = TodaySummaryHold.shown(stored, now: now)
            if TodaySummary.headline(c, summary: shown) != stored?.text { afterDropped += 1 }
            if !TodayAskAbout.available(summaryShown: shown != nil, reachable: true, chatAvailable: true, workRunsOn: true, preview: false) { askMissing += 1 }
        }
        print("alternation over \(reads.count) session-read states: BEFORE the counts line replaced the summary \(beforeDropped) times, AFTER \(afterDropped)")
        check(beforeDropped == 3, "BEFORE: each pending or failed read dropped the summary for the counts line (the check can fail)")
        check(afterDropped == 0, "AFTER: once today has a summary, row and read changes never show the counts line")
        check(askMissing == 0, "AFTER: the Ask box stays mounted through every read state")
        check(TodaySummaryHold.shown(reply("fresh", at: now.addingTimeInterval(-26 * 3600)), now: now) == nil, "yesterday's summary kept in memory is not shown")
        check(TodaySummaryHold.shown(reply("failed", at: now), now: now) == nil, "a failed view with no summary falls back to the counts line")
        check(TodaySummaryHold.shown(reply("off", at: now), now: now) == nil, "the switch off falls back to the counts line")
        check(TodaySummaryHold.shown(reply("stale", at: now, text: ""), now: now) == nil, "no text: the counts line")
        check(TodaySummaryHold.shown(reply("fresh", at: nil), now: now) != nil, "a summary with no time still shows")
        check(!TodaySummaryHold.askNow(sessions: .pending, lastSent: now.addingTimeInterval(-60), now: now), "the automatic ask waits while the session read is in flight")
        check(TodaySummaryHold.askNow(sessions: .pending, lastSent: now.addingTimeInterval(-300), now: now), "but not past five minutes")
        check(TodaySummaryHold.askNow(sessions: .pending, lastSent: nil, now: now), "and never before the first ask")
        check(TodaySummaryHold.askNow(sessions: .answered, lastSent: now, now: now) && TodaySummaryHold.askNow(sessions: .failed, lastSent: now, now: now),
              "a read that answered or failed asks as before")
    }

    // MARK: Part 2: off-screen layout, in points

    final class Page: ObservableObject {
        @Published var text = ""
        @Published var resetKey = "d1|0"
        var belowY: CGFloat = -1
    }
    struct Home: View {
        @ObservedObject var page: Page
        let held: Bool
        let size: CGFloat, spacing: CGFloat, column: CGFloat
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if held {
                    TodayHeadlineText(text: page.text, font: .custom("Fraunces", size: size), lineSpacing: spacing, color: .black, resetKey: page.resetKey)
                } else {
                    // 0.5.386, as todayHomeView drew it.
                    Text(page.text).font(.custom("Fraunces", size: size)).lineSpacing(spacing).foregroundStyle(Color.black)
                        .frame(maxWidth: 980, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                Text("Updated 3 min ago.").font(.system(size: 12.5)).foregroundStyle(Color.gray)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("home")).minY } action: { page.belowY = $0 }
                Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 120).overlay(Text("Needs you, Running, Next up").font(.system(size: 14)))
            }
            .frame(width: column, alignment: .topLeading)
            .padding(20)
            .coordinateSpace(name: "home")
            .background(Color.white)
        }
    }

    static let s5 = "Your server and desktop release lanes are moving: the candidate suite passed after one fix, the first run screens are rendering, and two lanes wait in the build queue. The glasses build is in review. Next is the integrated desktop build once the last compile slot frees up."
    static let s4 = "Your release lanes are moving: the candidate suite passed after one fix and two desktop lanes wait in the build queue. The glasses build is in review, and the integrated desktop build comes next."
    static let s6 = "Your server and desktop release lanes are moving fast tonight: the candidate suite passed after one fix to a file guard, the first run screens are rendering, the usage view has its prices, and two lanes still wait in the shared build queue for their compile turns. The glasses build is in review with the store. Next is the integrated desktop build once the last compile slot frees up, then the private install."
    static let counts = "Three agents are working, with 9 more sessions open."

    static func layout(_ host: NSHostingView<Home>) async {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            await Task.yield()
        }
    }

    /// The two states Miles saw at 9:33 PM, laid out as todayHomeView does: the summary with its Updated line and the Ask
    /// box, and the counts line with Refresh only. Reports where Needs you starts in each.
    struct Block: View {
        let summary: Bool
        let size: CGFloat, spacing: CGFloat, column: CGFloat
        let report: (CGFloat) -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary ? s5 : "Six things can wait until tomorrow so far, and your calendar is clear for the rest of the day. Three agents are working and a routine is running.")
                        .font(.custom("Fraunces", size: size)).lineSpacing(spacing).frame(maxWidth: 980, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if summary { Text("Updated 6 min ago. Things have moved since.").font(.system(size: 12.5)) }
                        Text("Refresh").font(.system(size: 12.5))
                        Spacer(minLength: 0)
                    }
                    if summary { RoundedRectangle(cornerRadius: 10).stroke(Color.gray).frame(minHeight: 34).frame(maxWidth: 620) }
                }
                Text("Needs you").font(.system(size: 15, weight: .semibold))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("block")).minY } action: { report($0) }
            }
            .frame(width: column, alignment: .topLeading).padding(20).coordinateSpace(name: "block").background(Color.white)
        }
    }

    static func alternation(column: CGFloat, size: CGFloat, spacing: CGFloat, label: String, out: URL?) async {
        var y: [Bool: CGFloat] = [:]
        for summary in [true, false] {
            var got: CGFloat = -1
            let host = NSHostingView(rootView: Block(summary: summary, size: size, spacing: spacing, column: column, report: { got = $0 }))
            host.frame = NSRect(x: 0, y: 0, width: column + 40, height: 600)
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)); await Task.yield() }
            y[summary] = got
            if let out, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(label)-0533pm-\(summary ? "A-summary" : "B-counts").png"))
            }
        }
        let a = y[true] ?? -1, b = y[false] ?? -1
        print("\(label) 9:33 PM states: Needs you starts at \(String(format: "%.1f", a)) pt with the summary (A), \(String(format: "%.1f", b)) pt with the counts line (B): \(String(format: "%.1f", a - b)) pt each swap before the fix, 0 after (B is no longer shown once today has a summary)")
        check(a > 0 && b > 0 && a - b > 60, "\(label): the two 9:33 PM states differ by more than a line (the alternation was a real jump)")
    }

    static func render(column: CGFloat, size: CGFloat, spacing: CGFloat, label: String, out: URL?) async {
        // Each step: a text swap, or Refresh finishing ("reset") with a text.
        let steps: [(String, String, Bool)] = [("5-line summary", s5, false), ("4-line rewrite", s4, false), ("6-line rewrite", s6, false),
                                               ("5-line rewrite", s5, false), ("counts headline (fallback)", counts, false), ("5-line rewrite", s5, false),
                                               ("Refresh with the 4-line text", s4, true)]
        var ys: [Bool: [CGFloat]] = [:]
        for held in [false, true] {
            let page = Page()
            let host = NSHostingView(rootView: Home(page: page, held: held, size: size, spacing: spacing, column: column))
            host.frame = NSRect(x: 0, y: 0, width: column + 40, height: 760)
            var trace: [CGFloat] = []
            for (i, step) in steps.enumerated() {
                page.text = step.1
                if step.2 { page.resetKey = "d1|refresh-\(i)" }
                await layout(host)
                trace.append(page.belowY)
                if let out, i < 4 {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(label)-\(held ? "after" : "before")-\(i + 1).png"))
                    }
                }
            }
            ys[held] = trace
            let moves = zip(trace, trace.dropFirst()).map { abs($1 - $0) }
            print("\(label) \(held ? "AFTER " : "BEFORE") belowY: \(trace.map { String(format: "%.1f", $0) }.joined(separator: " ")) | moved per swap: \(moves.map { String(format: "%.1f", $0) }.joined(separator: " ")) | total \(String(format: "%.1f", moves.reduce(0, +))) pt")
        }
        let before = ys[false] ?? [], after = ys[true] ?? []
        guard before.count == steps.count, after.count == steps.count, !before.contains(-1), !after.contains(-1) else { check(false, "\(label): every step measured"); return }
        // The texts really have different heights (else the check proves nothing).
        check(before[1] < before[0] && before[2] > before[0] && before[4] < before[1], "\(label): BEFORE, each rewrite moved what is under the headline (the check can fail)")
        check(after[1] == after[0], "\(label): AFTER, a shorter rewrite moves nothing")
        check(after[2] > after[1], "\(label): AFTER, a longer rewrite gets its room (grows)")
        check(after[3] == after[2] && after[4] == after[2] && after[5] == after[2], "\(label): AFTER, shorter rewrites and the counts fallback move nothing once the block has grown")
        check(after[6] < after[5] && abs(after[6] - before[6]) < 0.5, "\(label): AFTER, Refresh re-fits the block to the text shown (as before)")
    }
}
