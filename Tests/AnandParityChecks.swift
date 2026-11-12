import AppKit
import Foundation

/// Anand parity (D4, 2026-11-12): the Mac's words for the items Control Web 7.0.30 settled (W1 in COORD 10:38): Back by path,
/// the Speakers copy buttons and Meetings on today. Compiled with Sources/Models.swift alone (Tests/run-anand-parity.sh).
@main struct AnandParityChecks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0
    static func check(_ ok: Bool, _ label: String) {
        if ok { passes += 1 } else { failures += 1; print("check failed [\(label)]") }
    }

    static func main() {
        // Item 3: "Copy summary", "Copy full (N KB)", and Copied on the tapped one only.
        let W = MeetingCopyWords.self
        check(W.label(W.summary, copied: nil, fullChars: 52_000) == "Copy summary", "copy words")
        check(W.label(W.full, copied: nil, fullChars: 52_000) == "Copy full (50 KB)" && W.label(W.full, copied: nil, fullChars: 10) == "Copy full (1 KB)", "copy words")
        check(W.label(W.summary, copied: W.summary, fullChars: 52_000) == "Copied" && W.label(W.full, copied: W.summary, fullChars: 52_000) == "Copy full (50 KB)",
              "copied shows only on the tapped one")
        check(W.label(W.full, copied: W.full, fullChars: 52_000) == "Copied" && W.label(W.summary, copied: W.full, fullChars: 52_000) == "Copy summary",
              "copied shows only on the tapped one")
        check(W.copiedSeconds == 2.5, "copied for 2.5 s")
        // Item 4: today and the jump, in the web's plainDay words.
        let T = MeetingTodayWords.self
        check(T.emptyToday == "No meetings today." && T.lastMonth == "Go to last month", "today words")
        check(T.plainDay("2026-11-12", today: "2026-11-12") == "Today" && T.plainDay("2026-11-07", today: "2026-11-12") == "Nov 7"
              && T.plainDay("2025-12-31", today: "2026-11-12") == "Dec 31, 2025" && T.plainDay("not a day", today: "2026-11-12") == "not a day",
              "plain day as the web")
        let days: [(date: String, count: Int)] = [("2026-11-03", 2), ("2026-11-10", 1), ("2026-11-11", 0), ("2026-11-12", 0), ("2026-11-20", 4)]
        check(T.latestDayBefore("2026-11-12", days: days) == "2026-11-10", "jump to the latest earlier day with meetings")
        check(T.latestDayBefore("2026-11-03", days: days) == nil, "no earlier day: last month")
        check(T.jump(to: "2026-11-10", today: "2026-11-12") == "Go to Nov 10" && T.jump(to: nil, today: "2026-11-12") == "Go to last month", "today words")
        // Item 1: Back by path.
        typealias P = ActivityPlace
        let review = P(section: "speakers", speakerSessionID: "s-1"), meeting = P(section: "meetings", libraryRecordID: "r-1")
        var path = ActivityBackPath.record([], old: review, new: meeting, goingBack: false)
        check(path == [ActivityBackStep(from: review, to: meeting)], "a change of section is a step")
        check(ActivityBackPath.step(path, current: meeting, hasDetail: true)?.from == review, "Speakers, a review, Open meeting, Back lands on the review")
        check(ActivityBackPath.record(path, old: meeting, new: P(section: "meetings", libraryRecordID: "r-2"), goingBack: false) == path,
              "a move inside a section is not a step")
        check(ActivityBackPath.step(path, current: P(section: "meetings", libraryRecordID: "r-2"), hasDetail: true) == nil,
              "deeper or elsewhere in the section, Back keeps the parent chain")
        check(ActivityBackPath.step(path, current: P(section: "meetings"), hasDetail: false)?.from == review, "on the section's list, Back goes back along the path")
        check(ActivityBackPath.record(path, old: meeting, new: review, goingBack: true) == path, "Back's own move is not a step")
        check(ActivityBackPath.step(path, current: P(section: "messages", turnID: "t"), hasDetail: true) == nil, "a step for another section is not taken")
        check(ActivityBackPath.step(path, current: P(section: nil), hasDetail: false) == nil, "Activity home never goes back along the path")
        let home = P(section: nil), today = P(section: "messages", turnID: "t-9")
        path = ActivityBackPath.record([], old: home, new: today, goingBack: false)
        check(ActivityBackPath.step(path, current: today, hasDetail: true)?.from == home, "a message opened from the home goes back home")
        var long: [ActivityBackStep] = []
        for i in 0..<40 { long = ActivityBackPath.record(long, old: P(section: i % 2 == 0 ? "messages" : "meetings"), new: P(section: i % 2 == 0 ? "meetings" : "messages"), goingBack: false) }
        check(long.count == ActivityBackPath.limit, "the path keeps its last 30 steps")
        let linked = [ActivityBackStep(from: P(section: "work"), to: P(section: "sessions", sessionID: "x"))]
        check(ActivityBackPath.settle(linked, before: "sessions", after: "work").isEmpty && ActivityBackPath.settle(linked, before: "sessions", after: "meetings") == linked
              && ActivityBackPath.settle(linked, before: "sessions", after: "sessions") == linked, "a parent-chain move across sections drops only the step it undid")
        let all = [T.emptyToday, T.lastMonth, W.copied, W.label(W.summary, copied: nil, fullChars: 0)]
        check(all.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2192}") && !$0.contains("Miles") }, "no dash, arrow or name")
        print("anand parity checks: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
