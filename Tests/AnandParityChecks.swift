import AppKit
import Foundation

/// Anand parity (D4, 2026-11-12): the Mac's words for the items Control Web 7.0.30 settled (W1 in COORD 10:38): the Speakers
/// copy buttons and Meetings on today. Compiled with Sources/Models.swift alone (Tests/run-anand-parity.sh).
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
        let all = [T.emptyToday, T.lastMonth, W.copied, W.label(W.summary, copied: nil, fullChars: 0)]
        check(all.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2192}") && !$0.contains("Miles") }, "no dash, arrow or name")
        print("anand parity checks: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
