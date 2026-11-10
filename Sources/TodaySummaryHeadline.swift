import SwiftUI

/// T1 (Miles 2026-11-09 21:34, "The title keeps changing (probably every minutes) which creates alot of bouncing"): the
/// Today summary is one paragraph of large serif text with nothing under it holding its place, so every rewrite that
/// changed its line count moved "Updated", Ask about this, Needs you, Running and Next up by a whole line (38.8 pt at
/// 25 pt Fraunces with 8 pt line spacing; 33.1 pt at 22 pt with 6), and a fall back to the counts headline moved them
/// by four lines.
///
/// The block now keeps the tallest height its text has needed: it grows when a longer summary needs room, and shrinks
/// only when the day turns, the window's width changes (the text re-flows anyway) or Refresh finishes (the person asked
/// for a new summary and is looking at it). Nothing is cut: a longer text always gets its room. Pure, so
/// Tests/TodaySummaryHeadlineChecks.swift executes every rule.
struct TodayHeadlineHeight: Equatable {
    /// How long after a reset the next measurement may still shrink the block (the new text lands in the same pass or
    /// just after; a later one is an ordinary rewrite and may not).
    static let fitWindow: TimeInterval = 3
    /// The height the block keeps, in points (0: nothing measured yet, so no minimum).
    private(set) var reserved: CGFloat = 0
    /// The last measured text height, for a reset that arrives with no new measurement (the text did not change).
    private(set) var last: CGFloat = 0
    private(set) var width: CGFloat = -1
    private(set) var key = ""
    private(set) var fitUntil: Date?

    /// A new measurement of the text at this width under this key (the day and the last Refresh): the block grows to
    /// fit; it shrinks only on a new width, a new key, or just after a reset.
    mutating func measured(height: CGFloat, width: CGFloat, key: String, now: Date) -> CGFloat {
        let h = (max(0, height) * 2).rounded(.up) / 2
        last = h
        if abs(width - self.width) >= 1 || key != self.key || (fitUntil.map { now <= $0 } ?? false) {
            reserved = h
            self.width = width
            self.key = key
            fitUntil = nil
        } else {
            reserved = max(reserved, h)
        }
        return reserved
    }

    /// The day turned or Refresh finished: the block fits the text shown now, and the next measurement (the new text,
    /// when it lands within `fitWindow`) may shrink it too.
    mutating func reset(key: String, now: Date) -> CGFloat {
        guard key != self.key else { return reserved }
        self.key = key
        reserved = last
        fitUntil = now.addingTimeInterval(Self.fitWindow)
        return reserved
    }
}

/// The Today headline (the server's summary, or the local counts line) at a held height (TodayHeadlineHeight). The text
/// itself is drawn exactly as before: the font, line spacing, ink and the 980 pt reading width come from the caller.
struct TodayHeadlineText: View {
    let text: String
    let font: Font
    let lineSpacing: CGFloat
    let color: Color
    /// The day and the last finished Refresh: a change lets the block fit its text again.
    let resetKey: String
    var maxWidth: CGFloat = 980
    @State private var height = TodayHeadlineHeight()
    @State private var reserved: CGFloat = 0

    var body: some View {
        Text(text)
            .font(font)
            .lineSpacing(lineSpacing)
            .foregroundStyle(color)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // The column's width (not the text's own, which changes with every rewrite) and the text's height, measured
            // before the held minimum is applied.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                let next = height.measured(height: size.height, width: size.width, key: resetKey, now: Date())
                if next != reserved { reserved = next }
            }
            .frame(minHeight: reserved > 0 ? reserved : nil, alignment: .topLeading)
            .onChange(of: resetKey) { _, key in
                let next = height.reset(key: key, now: Date())
                if next != reserved { reserved = next }
            }
            .accessibilityAddTraits(.isHeader)
    }
}

/// T1, from Miles's two screenshots of 9:33 PM (the same minute): the Today block alternated between the model's summary
/// (with "Updated N min ago" and the Ask box) and the one-line counts headline ending "so far" (with neither). Cause: every
/// 20 s the pet's live poll sets the session read to pending for the length of its helper call (and to failed when the
/// live read was partial), and Today showed the summary only over a session list that was read, so each poll dropped the
/// summary, the Updated line and the Ask box for a moment and put them back: about 158 pt of page movement each way. A
/// Today tick that landed inside that window also told the server the session list "could not be read", which became the
/// summary's last sentence.
enum TodaySummaryHold {
    /// The summary to show: today's, with text, fresh or stale. A session read in flight or one that failed does not hide
    /// it (the Updated line says when a source could not be read, and "Things have moved since" when the rows moved on).
    /// The caller still hides it while the server is not answering.
    static func shown(_ reply: TodaySummary.Reply?, now: Date, calendar: Calendar = .current) -> TodaySummary.Reply? {
        guard let reply, !reply.text.isEmpty, reply.state == "fresh" || reply.state == "stale" else { return nil }
        // Yesterday's summary, kept in memory past midnight when an ask got no answer, is not today's.
        if let at = reply.at, !calendar.isDate(at, inSameDayAs: now) { return nil }
        return reply
    }

    /// Whether Today's automatic ask goes now. While the session read is in flight (pending) it waits, so the server is
    /// never told the list "could not be read" because a poll was running; but only while an ask went within the last
    /// five minutes (TodaySummary.resendSeconds), so a read that stays pending can never stop the summary for good.
    static func askNow(sessions: ActivityHome.SourceState, lastSent: Date?, now: Date) -> Bool {
        guard sessions == .pending, let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= TodaySummary.resendSeconds
    }
}
