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
        // Item 1: Back by path (lead 10:47 scope, with the 10:5x conditions).
        typealias P = ActivityPlace
        typealias B = ActivityBackPath
        func rec(_ path: [ActivityBackStep], _ old: P, _ new: P, back: Bool = false, pick: P? = nil) -> [ActivityBackStep] {
            B.record(path, old: old, new: new, goingBack: back, pick: pick).path
        }
        let review = P(section: "speakers", speakerSessionID: "s-1"), meeting = P(section: "meetings", libraryRecordID: "r-1")
        var path = rec([], review, meeting)
        check(path == [ActivityBackStep(from: review, to: meeting)], "a change of section is a step")
        check(B.step(path, current: meeting, hasDetail: true)?.from == review, "Speakers, a review, Open meeting, Back lands on the review")
        check(rec(path, meeting, P(section: "meetings"), back: false) == path, "closing an item to its list is not a step")
        check(B.step(path, current: P(section: "meetings", libraryRecordID: "r-2"), hasDetail: true) == nil,
              "elsewhere in the section, Back keeps the parent chain")
        check(B.step(path, current: P(section: "meetings"), hasDetail: false)?.from == review, "on the section's list, Back goes back along the path")
        check(rec(path, meeting, review, back: true) == path, "Back's own move is not a step")
        check(B.step(path, current: P(section: "messages", turnID: "t"), hasDetail: true) == nil, "a step for another section is not taken")
        check(B.step(path, current: P(section: nil), hasDetail: false) == nil, "the home never goes back along the path")
        // Two jumps stack: the home, a message, a meeting opened from it; Back, Back.
        let home = P(section: nil), message = P(section: "messages", turnID: "t-9"), fromMessage = P(section: "meetings", libraryRecordID: "r-7")
        path = rec(rec([], home, message), message, fromMessage)
        let first = B.step(path, current: fromMessage, hasDetail: true)
        check(first?.from == message, "two jumps stack: the first Back returns to the message")
        path = Array(path.dropLast())
        check(B.step(path, current: message, hasDetail: true)?.from == home, "two jumps stack: the second Back returns home")
        // One item opened from another in the same section is a step (a session from a session).
        let s1 = P(section: "sessions", sessionID: "a"), s2 = P(section: "sessions", sessionID: "b")
        path = rec([], s1, s2)
        check(path == [ActivityBackStep(from: s1, to: s2)] && B.step(path, current: s2, hasDetail: true)?.from == s1, "an item from an item in one section is a step")
        check(rec([], P(section: "sessions"), s1) == [], "opening an item from its own list is not a step")
        // A sidebar or Home pick starts a fresh path and is not a step.
        let picked = B.record(rec([], home, message), old: message, new: P(section: "meetings"), goingBack: false, pick: P(section: "meetings"))
        check(picked.path.isEmpty && picked.pick == nil, "a sidebar pick clears the path and is spent on arrival")
        let notYet = B.record(rec([], home, message), old: message, new: P(section: "messages"), goingBack: false, pick: P(section: "meetings"))
        check(notYet.pick == P(section: "meetings"), "a pick waits until the window arrives")
        check(B.record([], old: message, new: home, goingBack: false, pick: P(section: nil)).path.isEmpty, "Home is a pick")
        var long: [ActivityBackStep] = []
        for i in 0..<40 { long = rec(long, P(section: i % 2 == 0 ? "messages" : "meetings"), P(section: i % 2 == 0 ? "meetings" : "messages")) }
        check(long.count == B.limit, "the path keeps its last 12 steps, as the web")
        let linked = [ActivityBackStep(from: P(section: "work"), to: P(section: "sessions", sessionID: "x"))]
        check(B.settle(linked, before: "sessions", after: "work").isEmpty && B.settle(linked, before: "sessions", after: "meetings") == linked
              && B.settle(linked, before: "sessions", after: "sessions") == linked, "a parent-chain move across sections drops only the step it undid")
        // Miles's pick B: the trail reads the same steps; one line, shortened from the middle.
        let twoSteps = rec(rec([], home, message), message, fromMessage)
        check(B.trail(twoSteps, current: fromMessage, hasDetail: true) == [home, message, fromMessage], "the trail is the way here, this page last")
        check(B.trail(twoSteps, current: P(section: "meetings", libraryRecordID: "other"), hasDetail: true).isEmpty, "no trail where Back keeps the parent chain")
        check(B.trail([], current: message, hasDetail: true).isEmpty, "no trail without a path")
        check(B.shortened(3) == [0, 1, 2] && B.shortened(4) == [0, 1, 2, 3], "a short trail shows every place")
        check(B.shortened(7) == [0, nil, 5, 6], "a long trail keeps the first and the last two, shortened in the middle")
        let titles: (String) -> String? = { $0 == "speakers" ? "Speakers" : nil }
        check(B.word(ActivityBackStep(from: review, to: meeting), titles: titles, home: "Today") == "Speakers"
              && B.word(ActivityBackStep(from: home, to: message), titles: titles, home: "Today") == "Today", "Back names where it goes")
        let all = [T.emptyToday, T.lastMonth, W.copied, W.label(W.summary, copied: nil, fullChars: 0)]
        check(all.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2192}") && !$0.contains("Miles") }, "no dash, arrow or name")
        print("anand parity checks: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
