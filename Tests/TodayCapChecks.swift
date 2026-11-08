import Foundation

// 0.5.380 (Miles 2026-11-08, server 7.0.5): Summaries per day and the reconnect ask, the pure rules in TodaySummary
// (Sources/Models.swift), executed. Compiled with Models.swift alone by Tests/run-today-cap.sh.
// Prints "today cap checks: N passed".

@main struct TodayCapChecks {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        typealias C = TodaySummary.Cap

        // ── The setting as the server answers it.
        let cap = C(.object(["dailyCap": .number(100), "min": .number(1), "max": .number(100), "default": .number(100), "usedToday": .number(7)]))
        check(cap?.dailyCap == 100 && cap?.min == 1 && cap?.max == 100 && cap?.usedToday == 7, "the server's answer reads whole")
        check(cap?.usedLine == "7 of 100 used today.", "the line under the row")
        check(C(.object(["dailyCap": .number(250)]))?.dailyCap == 100 && C(.object(["dailyCap": .number(0)]))?.dailyCap == 1, "a value outside 1 to 100 is clamped")
        check(C(.object(["dailyCap": .number(40), "max": .number(500)]))?.max == 100, "the range never goes past 100")
        check(C(.object(["enabled": .bool(true)])) == nil && C(.object(["dailyCap": .string("100")])) == nil, "no number, no row (an older server)")
        check(C(.object(["dailyCap": .number(40)]))?.usedLine == "", "no count from the server, no line")
        check(cap?.typed(" 25 ") == 25 && cap?.typed("0") == 1 && cap?.typed("1000") == 100, "a typed number is kept inside 1 to 100")
        check(cap?.typed("") == nil && cap?.typed("ten") == nil && cap?.typed("2.5") == nil, "anything else sends nothing")
        check(C.defaultCap == 100 && C.label == "Summaries per day", "the default and the label")

        // ── The daily cap line under the switch names the setting.
        func status(_ s: [String: JSONValue]) -> String {
            TodaySummary.Settings(.object(["enabled": .bool(true), "source": .string("settings"), "status": .object(s)]))?.statusLine() ?? "nil"
        }
        check(status(["kind": .string("daily_cap"), "count": .number(60), "cap": .number(40)]) == "Today\u{2019}s 40 summaries are used. It writes again tomorrow.",
              "the cap the server reached is the number")
        check(status(["kind": .string("daily_cap"), "count": .number(60)]) == "Today\u{2019}s 60 summaries are used. It writes again tomorrow.", "an older server's count still reads")
        check(status(["kind": .string("daily_cap"), "count": .number(1), "cap": .number(1)]) == "Today\u{2019}s 1 summary is used. It writes again tomorrow.", "one summary is singular")
        check(status(["kind": .string("daily_cap")]) == "Today\u{2019}s 100 summaries are used. It writes again tomorrow.", "no number at all: the default")
        check(TodaySummary.Settings.blurb.contains("no more than Summaries per day allows") && !TodaySummary.Settings.blurb.contains("60 times a day"),
              "the switch's words name the setting, not a fixed 60")

        // ── Reconnect: a read that recovers after a failure arms ONE early ask.
        var r = TodaySummary.Reconnect()
        r.observe(failed: false)
        check(!r.take(switchedOff: false), "nothing failed: no reconnect")
        r.observe(failed: true)
        check(!r.take(switchedOff: false), "still failing: no reconnect yet")
        r.observe(failed: true)
        r.observe(failed: false)
        check(r.take(switchedOff: false), "the first good read after a failure arms it")
        check(!r.take(switchedOff: false), "it is spent once taken")
        r.observe(failed: false)
        check(!r.take(switchedOff: false), "a second good read arms nothing")
        r.observe(failed: true); r.observe(failed: false)
        check(!r.take(switchedOff: true), "a switched-off summary never asks early")
        check(!r.take(switchedOff: false), "and the reconnect is spent all the same")

        // ── The body says reconnect; the key the ask is judged by does not change.
        let rows: JSONValue = .object(["sessions": .array([]), "needsYou": .array([])])
        let asked = TodaySummary.reconnecting(rows)
        check(asked.object?["reason"]?.string == "reconnect", "the reconnect body carries reason reconnect")
        check(TodaySummary.key(asked) == TodaySummary.key(rows), "reason never changes what counts as the same rows")
        check(TodaySummary.unforced(TodaySummary.forced(rows)).object?["force"] == nil, "force still comes off for a 7.0.0 server")

        print("today cap checks: \(checks) passed")
    }
}
