import Combine
import Foundation

/// 0.5.327: rating live cues (CueVerdicts and CueVerdictsStore in Sources/MeetingAskCore.swift), executed. Compiled against
/// MeetingAskCore.swift, LiveTranscript.swift and Models.swift alone by Tests/run-cue-verdicts.sh, with a stand-in for the
/// helper: no helper binary, no server, no window. Prints "cue verdicts checks: N passed".
@main struct CueVerdictsChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("cue verdicts check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    /// The helper's details, through the same JSON round trip the app's HelperResponse takes.
    static func details(_ json: String) -> [String: JSONValue] {
        let wrapped = #"{"ok":true,"message":"x","details":"# + json + "}"
        return try! JSONDecoder().decode(HelperResponse.self, from: Data(wrapped.utf8)).details
    }
    static func answered(_ status: Int, _ body: String = "") -> [String: JSONValue] {
        details(#"{"transport":"answered","httpStatus":"# + "\(status)" + (body.isEmpty ? "" : "," + body) + "}")
    }
    /// 2026-10-19 09:00 UTC, a Monday.
    static let monday = 1_792_400_400_000.0
    static func row(_ id: String, session: String = "meeting_1792400000000_abc123", at ms: Double = monday, kind: String = "challenge",
                    detail: String = "Settle the date.", verdict: String = "null") -> String {
        #"{"cueId":"\#(id)","sessionId":"\#(session)","meetingTitle":"HC Monday standup","createdAt":\#(ms),"kind":"\#(kind)","headline":"Settle it","detail":"\#(detail)","gate":0.97,"sources":[],"model":"claude-sonnet-5-5","before":"MU: we move them.","rating":\#(verdict)}"#
    }
    static func history(_ rows: [String], total: Int, rated: Int, unrated: Int, by: String = "{}", extra: String = "") -> [String: JSONValue] {
        answered(200, #""v":1,"cues":[\#(rows.joined(separator: ","))],"counts":{"total":\#(total),"rated":\#(rated),"unrated":\#(unrated),"byVerdict":\#(by)}"# + extra)
    }

    @MainActor static func main() async {
        typealias S = CueVerdicts.State
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!

        // ── The history's answer to a state.
        check(CueVerdicts.read(nil).0 == .notChecked, "a helper that failed is not checked")
        check(CueVerdicts.read(details(#"{"transport":"unavailable"}"#)).0 == .unreachable, "nothing answered: unreachable")
        check(CueVerdicts.read(details(#"{"transport":"no_token"}"#)).0 == .reconnect, "no pairing token: reconnect")
        check(CueVerdicts.read(answered(404)).0 == .olderServer && CueVerdicts.read(details(#"{"transport":"unsupported","httpStatus":404}"#)).0 == .olderServer,
              "404, and a 404 page that is not JSON: a server from before the routes")
        check(CueVerdicts.read(answered(503, #""error":"verdicts_unreadable""#)).0 == .storageUnreadable && CueVerdicts.read(answered(503)).0 == .failed(status: 503),
              "503 verdicts_unreadable by its code")
        check(CueVerdicts.read(answered(401)).0 == .reconnect && CueVerdicts.read(answered(403)).0 == .reconnect, "401 and 403: reconnect")
        check(CueVerdicts.read(answered(502)).0 == .failed(status: 502), "a 502 names its status")
        check(CueVerdicts.read(answered(200, #""cues":[],"counts":{"total":0,"rated":0,"unrated":0}"#)).0 == .unreadable, "200 without v is not readable")
        check(CueVerdicts.read(answered(200, #""v":2,"cues":[],"counts":{"total":0,"rated":0,"unrated":0}"#)).0 == .unreadable, "another protocol is not readable")
        check(CueVerdicts.read(answered(200, #""v":1,"cues":[]"#)).0 == .unreadable, "200 without counts is not readable")
        check(CueVerdicts.read(details(#"{"httpStatus":200}"#)).0 == .notChecked, "no transport is not an answer")
        let read = CueVerdicts.read(history([
            row("cue-0001-aaaa"),
            row("cue-0002-bbbb", verdict: #"{"verdict":"repeat","note":"same ask","vote":"down","at":1792400500000}"#),
            row("cue-0003-cccc", verdict: #"{"vote":"up","at":1792400500000}"#),
            row("cue-0004-dddd", detail: ""),
        ], total: 31, rated: 3, unrated: 28, by: #"{"useful":2,"repeat":1,"late":0}"#))
        check(read.0 == .loaded && read.1?.cues.map(\.id) == ["cue-0001-aaaa", "cue-0002-bbbb", "cue-0003-cccc"], "200 in the contract: its rows, one without detail dropped")
        let first = read.1?.cues.first
        check(first?.gate == 0.97 && first?.meetingTitle == "HC Monday standup" && first?.before == "MU: we move them." && first?.rating == nil
              && first?.createdAt == Date(timeIntervalSince1970: monday / 1000), "a row's fields, an unrated one with no rating")
        check(read.1?.cues[1].rating == LiveCueRating(verdict: .repeat, note: "same ask", vote: "down", at: Date(timeIntervalSince1970: 1_792_400_500)),
              "a stored verdict with its note and the lens vote")
        check(read.1?.cues[2].verdict == nil && read.1?.cues[2].rating?.vote == "up", "a lens vote alone is not a verdict")
        check(read.1?.counts == LiveCueCounts(total: 31, rated: 3, unrated: 28, byVerdict: [.useful: 2, .repeat: 1, .late: 0]), "the counts")

        // ── Words.
        let lines: [(S, String?)] = [
            (.loaded, nil),
            (.checking, "Loading cues…"),
            (.olderServer, "Rating cues needs server 6.79.0. Update the server in Settings."),
            (.unreachable, "COS server unreachable. Cues show here once it answers."),
            (.reconnect, "Reconnect COS Control to the server to see cues."),
            (.notChecked, "COS Control could not read cues. Check again."),
            (.unreadable, "The server's answer about cues was not readable. Update the server in Settings."),
            (.storageUnreadable, "The server's ratings file cannot be read, so cues cannot be listed. Check again after the server restarts."),
            (.failed(status: 500), "The server could not list cues (HTTP 500). Check again."),
        ]
        for (state, words) in lines { check(CueVerdicts.line(state) == words, "\(state): \(words ?? "no line")") }
        check(CueVerdict.allCases.map(\.label) == ["Useful", "Late", "Repeat", "Wrong", "Obvious"]
              && CueVerdict.allCases.map(\.key) == ["1", "2", "3", "4", "5"], "five verdicts, keyed 1 to 5 in the mock's order")
        check(CueVerdicts.keysLine == "Oldest first. Keys 1 to 5 rate, N adds a note, S skips.", "the keys line")

        // ── Arguments.
        check(CueVerdicts.historyArguments(days: 7, session: nil, unrated: true) == ["live-cues-history", "--days", "7", "--unrated"], "the week's queue")
        check(CueVerdicts.historyArguments(days: 30, session: "meeting_1", unrated: false) == ["live-cues-history", "--days", "30", "--session", "meeting_1"],
              "a meeting's list")
        check(CueVerdicts.historyArguments(days: 90, session: nil, unrated: false)[2] == "30" && CueVerdicts.historyArguments(days: 0, session: nil, unrated: false)[2] == "1",
              "days stay 1 to 30")
        let cue = LiveCueRecord(id: "cue-0001-aaaa", sessionId: "meeting_1792400000000_abc123", createdAt: Date(timeIntervalSince1970: monday / 1000),
                                kind: "challenge", detail: "Settle the date.")
        let noted = CueVerdicts.rateCall(cue, verdict: .useful, note: "  more\n than  that ")
        check(noted.arguments == ["live-cues-rate", "--session", cue.sessionId, "--cue", cue.id, "--verdict", "useful", "--note-stdin"]
              && noted.stdin.flatMap { String(data: $0, encoding: .utf8) } == #"{"note":"more than that"}"#, "a verdict, its note on stdin, never in the arguments")
        let blank = CueVerdicts.rateCall(cue, verdict: .late, note: "   ")
        check(blank.arguments == ["live-cues-rate", "--session", cue.sessionId, "--cue", cue.id, "--verdict", "late"] && blank.stdin == nil, "a blank note is no note")
        let cleared = CueVerdicts.rateCall(cue, verdict: nil, note: "kept?")
        check(cleared.arguments == ["live-cues-rate", "--session", cue.sessionId, "--cue", cue.id, "--verdict", "clear"] && cleared.stdin == nil,
              "clearing carries no note")
        let cut = CueVerdicts.note(String(repeating: "\u{1F600}", count: 150))
        check(cut.utf16.count == 200 && cut.unicodeScalars.allSatisfy { $0 == "\u{1F600}" }, "a note stops at 200 UTF-16 units, on a character")

        // ── A rating's answer.
        check(CueVerdicts.rateOutcome(answered(200, #""ok":true,"verdict":"wrong","vote":"up""#)) == .saved(.wrong, vote: "up"), "saved, with the lens vote")
        check(CueVerdicts.rateOutcome(answered(200, #""ok":true,"verdict":null"#)) == .saved(nil, vote: nil), "cleared")
        check(CueVerdicts.rateOutcome(answered(200)) == .failed(status: 200), "a 200 without ok is not a save")
        check(CueVerdicts.rateOutcome(answered(404, #""error":"unknown_cue""#)) == .unknownCue, "404 unknown_cue")
        check(CueVerdicts.rateOutcome(answered(404)) == .olderServer && CueVerdicts.rateOutcome(details(#"{"transport":"unsupported","httpStatus":404}"#)) == .olderServer,
              "a bare 404 is an older server")
        check(CueVerdicts.rateOutcome(answered(409, #""error":"cue_session_mismatch""#)) == .otherMeeting, "409 cue_session_mismatch by its code")
        check(CueVerdicts.rateOutcome(answered(503, #""error":"verdicts_unreadable""#)) == .storageUnreadable
              && CueVerdicts.rateOutcome(answered(503)) == .unreachable, "503: the ratings file by its code, else the server is updating")
        check(CueVerdicts.rateOutcome(answered(400)) == .refused && CueVerdicts.rateOutcome(answered(401)) == .reconnect
              && CueVerdicts.rateOutcome(answered(500)) == .failed(status: 500), "400, 401 and 500")
        check(CueVerdicts.rateOutcome(nil) == .notChecked && CueVerdicts.rateOutcome(details(#"{"transport":"unavailable"}"#)) == .unreachable
              && CueVerdicts.rateOutcome(details(#"{"transport":"no_token"}"#)) == .reconnect, "the helper and transport failures")
        check(CueVerdicts.rateLine(.saved(.useful, vote: nil)) == nil, "a save has no line")
        check(CueVerdicts.rateLine(.unknownCue) == "This cue is older than 30 days and was removed."
              && CueVerdicts.rateLine(.unreachable) == "Server is updating. Rating not saved, try again."
              && CueVerdicts.rateLine(.storageUnreadable) == "The server's ratings file cannot be read. The rating was not saved."
              && CueVerdicts.rateLine(.failed(status: 500)) == "The rating was not saved (HTTP 500). Try again.", "a failed rating says it was not saved")
        let outcomes: [CueVerdicts.RateOutcome] = [.unknownCue, .otherMeeting, .olderServer, .unreachable, .storageUnreadable, .reconnect, .refused, .failed(status: 500), .notChecked]
        var words = outcomes.compactMap(CueVerdicts.rateLine) + lines.compactMap { $0.1 }
        words += [CueVerdicts.keysLine, CueVerdicts.notePlaceholder, CueVerdicts.doneLine(nil), CueVerdicts.doneLine(LiveCueCounts(total: 3, rated: 3, unrated: 0))]
        check(words.count == outcomes.count + 8 + 4, "every failure has words")
        for text in words {
            check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->") && !text.contains("_"), "plain words, no em dash, arrow or code: \(text)")
        }

        // ── Keys: only while the card has focus, never with Command, Option or Control.
        for verdict in CueVerdict.allCases {
            check(CueVerdicts.key(verdict.key, modified: false, cardFocused: true) == .rate(verdict), "\(verdict.key) rates \(verdict.label)")
        }
        check(CueVerdicts.key("n", modified: false, cardFocused: true) == .note && CueVerdicts.key("N", modified: false, cardFocused: true) == .note, "N goes to the note")
        check(CueVerdicts.key("s", modified: false, cardFocused: true) == .skip && CueVerdicts.key("S", modified: false, cardFocused: true) == .skip, "S skips")
        check(CueVerdicts.key("1", modified: false, cardFocused: false) == nil && CueVerdicts.key("n", modified: false, cardFocused: false) == nil
              && CueVerdicts.key("s", modified: false, cardFocused: false) == nil, "nothing happens without the card's focus (typing in the note included)")
        check(CueVerdicts.key("1", modified: true, cardFocused: true) == nil, "Command-1 and the like stay the window's")
        check(CueVerdicts.key("6", modified: false, cardFocused: true) == nil && CueVerdicts.key("x", modified: false, cardFocused: true) == nil
              && CueVerdicts.key("12", modified: false, cardFocused: true) == nil, "other keys are left alone")

        // ── The queue's order.
        func at(_ id: String, _ minutes: Double, session: String = "meeting_1792400000000_abc123") -> LiveCueRecord {
            LiveCueRecord(id: id, sessionId: session, createdAt: Date(timeIntervalSince1970: monday / 1000 + minutes * 60), kind: "challenge", detail: "D " + id)
        }
        let a = at("cue-a-000001", 1), b = at("cue-b-000002", 2), c = at("cue-c-000003", 3)
        check(CueVerdicts.queueOrder([c, a, b], skipped: []).map(\.id) == [a.id, b.id, c.id], "oldest first")
        check(CueVerdicts.queueOrder([c, a, b], skipped: [b.id, a.id]).map(\.id) == [c.id, b.id, a.id], "skipped cues last, in the order skipped")
        check(CueVerdicts.queueOrder([a], skipped: [b.id]).map(\.id) == [a.id], "a skipped cue no longer waiting is gone")

        // ── Times and lines.
        check(CueVerdicts.meetingStart("meeting_1792400000000_abc123") == Date(timeIntervalSince1970: 1_792_400_000)
              && CueVerdicts.meetingStart("meeting_17924_abc") == nil && CueVerdicts.meetingStart("mac_0123") == nil && CueVerdicts.meetingStart("g2:x") == nil,
              "a glasses meeting's start from its session id, nothing else")
        check(CueVerdicts.minutesIn(cue) == 6, "minutes into the meeting")
        check(CueVerdicts.minutesIn(LiveCueRecord(id: "x-00000001", sessionId: "meeting_1792500000000_a", createdAt: cue.createdAt, kind: "challenge", detail: "d")) == nil,
              "a cue before its meeting started has no minutes")
        let now = Date(timeIntervalSince1970: monday / 1000 + 3600)
        check(CueVerdicts.when(cue, now: now, style: .twelveHour, calendar: utc) == "Today 9:00 AM, 6 min in", "today, 12-hour, minutes in")
        check(CueVerdicts.when(cue, now: now, style: .twentyFourHour, calendar: utc) == "Today 09:00, 6 min in", "24-hour")
        check(CueVerdicts.when(cue, now: now.addingTimeInterval(86_400), style: .twelveHour, calendar: utc).hasPrefix("Yesterday 9:00 AM"), "yesterday")
        check(CueVerdicts.when(cue, now: now.addingTimeInterval(3 * 86_400), style: .twelveHour, calendar: utc).hasPrefix("Mon 9:00 AM"), "this week: the weekday")
        check(CueVerdicts.when(cue, now: now.addingTimeInterval(9 * 86_400), style: .twelveHour, calendar: utc).hasPrefix("Oct 19 9:00 AM"), "older: the date")
        let sourceless = LiveCueRecord(id: "x-00000002", sessionId: "g2:abc", createdAt: cue.createdAt, kind: "reinforce", detail: "d")
        check(CueVerdicts.when(sourceless, now: now, style: .twelveHour, calendar: utc) == "Today 9:00 AM", "no minutes when the start cannot be told")
        check(CueVerdicts.kindLabel("challenge") == "Challenge" && CueVerdicts.kindLabel("reinforce") == "Reinforce", "the kinds")
        check(CueVerdicts.score(0.9712) == "0.97" && CueVerdicts.score(nil) == nil, "the score")
        check(CueVerdicts.sourcesLine([]) == "Sources: none, from the room only", "no sources: from the room")
        check(CueVerdicts.sourcesLine([LiveCueSource(id: "1", date: "2026-10-01", title: "Grant review"), LiveCueSource(id: "2", date: "", title: "Kickoff")])
              == "Sources: Grant review (2026-10-01); Kickoff", "sources by title and date")
        var gated = cue; gated.gate = 0.91
        check(CueVerdicts.cardLine(gated, style: .twelveHour, calendar: utc) == "9:00 AM · Challenge · 0.91" && CueVerdicts.cardLine(cue, style: .twentyFourHour, calendar: utc) == "09:00 · Challenge",
              "a meeting card's first line")
        check(CueVerdicts.ratedLine(LiveCueRating(verdict: .repeat, note: "same ask as 7:49")) == "Rated Repeat · \u{201C}same ask as 7:49\u{201D}"
              && CueVerdicts.ratedLine(LiveCueRating(verdict: .useful)) == "Rated Useful" && CueVerdicts.ratedLine(LiveCueRating(vote: "up")) == nil
              && CueVerdicts.ratedLine(nil) == nil, "the rated line")
        check(CueVerdicts.voteLine(LiveCueRating(vote: "down")) == "Voted down on the glasses" && CueVerdicts.voteLine(LiveCueRating(verdict: .useful)) == nil,
              "the lens vote line")
        check(CueVerdicts.ratingsLine(LiveCueCounts(total: 31, rated: 3, unrated: 28)) == "Ratings in the last 7 days: 3 of 31.", "the last 7 days' count line")
        check(CueVerdicts.usedLine(.init(cues: 10, cap: 25)) == "10 of 25 used" && CueVerdicts.usedLine(.init(cues: 3, cap: 40)) == "3 of 40 used"
              && CueVerdicts.usedLine(.init(cues: 3, cap: nil)) == "3 used",
              "the meeting's count against the server's own cap, never an assumed one")
        check(CueVerdicts.leftLine(1) == "1 left" && CueVerdicts.leftLine(28) == "28 left", "left")
        check(CueVerdicts.doneLine(nil) == "No cues in the last 7 days." && CueVerdicts.doneLine(LiveCueCounts(total: 4, rated: 4, unrated: 0)) == "Every cue from the last 7 days is rated.",
              "the empty queue says why")
        var headed = cue; headed.headline = "LMS pages went to the 1517 team with no deadline"
        check(CueVerdicts.nextLine(headed, style: .twelveHour, calendar: utc) == "Next up: 9:00 AM · LMS pages went to the 1517 team with no deadline", "next up")
        check(CueVerdicts.pollSeconds == 15 && CueVerdicts.liveDays == 2 && CueVerdicts.savedDays == 30 && CueVerdicts.weekDays == 7, "the windows")

        // ── Titles: this Mac's saved meeting, else the server's saved title, else the title at cue time.
        let titled = CueVerdicts.read(history([
            #"{"cueId":"cue-t-000001","sessionId":"meeting_1792400000000_abc123","meetingTitle":"G2 Recording 2026-10-19 0741","title":"Archive search logs (G2)","titleSource":"saved","createdAt":1792400400000,"armedAt":1792400100000,"kind":"challenge","detail":"D","before":"","rating":null}"#,
            #"{"cueId":"cue-t-000002","sessionId":"meeting_1792400000000_abc123","meetingTitle":"G2 Recording 2026-10-19 0741","title":"G2 Recording 2026-10-19 0741","titleSource":"capture","createdAt":1792400400000,"kind":"challenge","detail":"D","before":"","rating":null}"#,
        ], total: 2, rated: 0, unrated: 2)).1!.cues
        check(titled[0].savedTitle == "Archive search logs (G2)" && titled[1].savedTitle.isEmpty, "the server's title only when it is a saved one")
        check(CueVerdicts.title(titled[0], library: []) == "Archive search logs (G2)" && CueVerdicts.title(titled[1], library: []) == "G2 Recording 2026-10-19 0741",
              "with no library row: the saved title, else the title at cue time")
        let libraryRow = LibraryMeeting(.object(["filename": .string("x.md"), "month": .string("2026-10"), "title": .string("Archive 1517 Search Logs, Chase Feedback (G2)"),
                                                  "sessionId": .string("meeting_1792399999999_zzz"), "g2SessionIds": .array([.string("meeting_1792400000000_abc123")])]))!
        check(CueVerdicts.title(titled[1], library: [libraryRow]) == "Archive 1517 Search Logs, Chase Feedback (G2)"
              && CueVerdicts.title(titled[0], library: [libraryRow]) == "Archive 1517 Search Logs, Chase Feedback (G2)", "this Mac's saved meeting wins, found by any capture it holds")
        check(CueVerdicts.minutesIn(titled[0]) == 5 && CueVerdicts.minutesIn(titled[1]) == 6, "minutes from when cues were armed, else from the session id")
        check(titled[0].before.isEmpty, "an empty before stays empty (the card draws no box)")

        // ── What the Memories page is told.
        func json(_ value: [String: JSONValue]) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
        check(json(CueVerdicts.summary(available: nil, counts: nil)) == #"{"available":false}"#
              && json(CueVerdicts.summary(available: false, counts: LiveCueCounts(total: 1, rated: 0, unrated: 1))) == #"{"available":false}"#
              && json(CueVerdicts.summary(available: nil, counts: LiveCueCounts(total: 1, rated: 0, unrated: 1))) == #"{"available":false}"#,
              "the page hides its entries until a server answers with the history")
        check(json(CueVerdicts.summary(available: true, counts: LiveCueCounts(total: 31, rated: 3, unrated: 28)))
              == #"{"available":true,"rated":3,"total":31,"unrated":28}"#, "and shows them with the counts")

        // ── Counts as the server will count them.
        let counts = LiveCueCounts(total: 5, rated: 2, unrated: 3, byVerdict: [.useful: 2])
        check(counts.moving(from: nil, to: .late) == LiveCueCounts(total: 5, rated: 3, unrated: 2, byVerdict: [.useful: 2, .late: 1]), "rating one")
        check(counts.moving(from: .useful, to: .wrong) == LiveCueCounts(total: 5, rated: 2, unrated: 3, byVerdict: [.useful: 1, .wrong: 1]), "changing one")
        check(counts.moving(from: .useful, to: nil) == LiveCueCounts(total: 5, rated: 1, unrated: 4, byVerdict: [.useful: 1]), "clearing one")
        check(counts.moving(from: .useful, to: .useful) == counts, "the same verdict again changes nothing")

        // ── The store against a stand-in helper.
        final class Calls { var log: [[String]] = []; var stdin: [Data?] = [] }
        final class Clock { var now: Date; init(_ now: Date) { self.now = now } }
        func fake(_ calls: Calls, _ answers: [[String: JSONValue]?]) -> CueVerdictsStore.Run {
            var queue = answers
            return { args, input in
                calls.log.append(args); calls.stdin.append(input)
                guard !queue.isEmpty, let next = queue.removeFirst() else {
                    throw NSError(domain: "helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper failed"])
                }
                return HelperResponse(ok: true, message: "x", details: next)
            }
        }
        let clock = Clock(Date(timeIntervalSince1970: monday / 1000 + 600))
        let store = CueVerdictsStore(); store.now = { clock.now }
        let calls = Calls()
        check(store.available == nil && store.weekState == .checking && store.queue.isEmpty, "before any answer: nothing offered, Loading")
        let week = history([row("cue-b-000002", at: monday + 120_000), row("cue-a-000001", at: monday + 60_000), row("cue-c-000003", at: monday + 180_000)],
                           total: 5, rated: 2, unrated: 3, by: #"{"useful":2}"#)
        await store.loadWeek(fake(calls, [week]))
        check(calls.log == [["live-cues-history", "--days", "7", "--unrated"]], "the week's queue is one unrated read")
        check(store.available == true && store.weekState == .loaded && store.queue.map(\.id) == ["cue-a-000001", "cue-b-000002", "cue-c-000003"]
              && store.counts?.unrated == 3, "the queue oldest first, the counts, and the capability")
        store.skip(store.queue[0])
        check(store.queue.map(\.id) == ["cue-b-000002", "cue-c-000003", "cue-a-000001"], "Skip moves a cue to the end and sends nothing")
        check(calls.log.count == 1, "Skip sends nothing")
        await store.loadWeek(fake(calls, [week]))
        check(store.queue.map(\.id) == ["cue-b-000002", "cue-c-000003", "cue-a-000001"], "a skipped cue stays last after a fresh read")

        // A saved verdict.
        await store.loadRated(fake(calls, [history([row("cue-z-000009", at: monday, verdict: #"{"verdict":"useful"}"#),
                                                    row("cue-y-000008", at: monday + 30_000, verdict: #"{"verdict":"useful"}"#),
                                                    row("cue-b-000002", at: monday + 120_000)], total: 5, rated: 2, unrated: 3, by: #"{"useful":2}"#)]))
        check(calls.log.last == ["live-cues-history", "--days", "7"] && store.rated.map(\.id) == ["cue-y-000008", "cue-z-000009"],
              "Rated cues: the week's read, rated ones only, newest first")
        let target = store.queue[0]
        await store.rate(target, verdict: .late, note: " too\nlate ", run: fake(calls, [answered(200, #""ok":true,"verdict":"late","vote":"down""#)]))
        check(calls.log.last == ["live-cues-rate", "--session", target.sessionId, "--cue", target.id, "--verdict", "late", "--note-stdin"]
              && (calls.stdin.last ?? nil).map { String(decoding: $0, as: UTF8.self) } == #"{"note":"too late"}"#, "the rating's arguments, the note on stdin")
        check(!store.queue.contains { $0.id == target.id } && store.queue.first?.id == "cue-c-000003", "a rated cue leaves the queue and the next one shows")
        check(store.counts == LiveCueCounts(total: 5, rated: 3, unrated: 2, byVerdict: [.useful: 2, .late: 1]), "the counts move with it")
        let saved = store.rated.first { $0.id == target.id }
        check(saved?.rating?.verdict == .late && saved?.rating?.note == "too late" && saved?.rating?.vote == "down" && store.rated.first?.id == target.id,
              "it joins Rated cues, newest first, its note and the lens vote kept")
        check(store.rateErrors[target.id] == nil && store.saving.isEmpty, "nothing pending, no error")

        // Changing and clearing it.
        await store.rate(saved!, verdict: .wrong, note: "too late", run: fake(calls, [answered(200, #""ok":true,"verdict":"wrong""#)]))
        check(store.rated.first { $0.id == target.id }?.verdict == .wrong && store.counts?.byVerdict[.late] == 0 && store.counts?.byVerdict[.wrong] == 1
              && store.counts?.rated == 3, "a change moves the verdict, not the totals")
        await store.rate(store.rated.first { $0.id == target.id }!, verdict: nil, run: fake(calls, [answered(200, #""ok":true,"verdict":null"#)]))
        check(calls.log.last?.suffix(2) == ["--verdict", "clear"], "Clear sends clear")
        check(!store.rated.contains { $0.id == target.id } && store.queue.contains { $0.id == target.id } && store.counts?.unrated == 3,
              "a cleared cue goes back to the queue")

        // Failures leave everything as it was and say why.
        let before = (store.queue, store.counts, store.rated)
        let waiting = store.queue[0]
        await store.rate(waiting, verdict: .useful, run: fake(calls, [answered(404, #""error":"unknown_cue""#)]))
        check(store.queue == before.0 && store.counts == before.1 && store.rated == before.2, "a refused rating changes nothing")
        check(store.rateErrors[waiting.id] == CueVerdicts.rateLine(.unknownCue) && store.available == true, "unknown_cue says so, the server keeps its routes")
        await store.rate(waiting, verdict: .useful, run: fake(calls, [details(#"{"transport":"unavailable"}"#)]))
        check(store.rateErrors[waiting.id] == "Server is updating. Rating not saved, try again." && store.queue == before.0, "unreachable: not saved")
        await store.rate(waiting, verdict: .useful, run: fake(calls, [nil]))
        check(store.rateErrors[waiting.id] == "COS Control could not save the rating. Try again.", "a helper failure: not saved")
        await store.rate(waiting, verdict: .useful, run: fake(calls, [answered(200, #""ok":true,"verdict":"useful""#)]))
        check(store.rateErrors[waiting.id] == nil && !store.queue.contains { $0.id == waiting.id }, "the next rating clears the line")

        // One rating per cue at a time.
        final class Gate { var open = false }
        let gate = Gate(); let slowCalls = Calls()
        let held: CueVerdictsStore.Run = { args, _ in
            slowCalls.log.append(args)
            while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return HelperResponse(ok: true, message: "x", details: answered(200, #""ok":true,"verdict":"obvious""#))
        }
        let next = store.queue[0]
        let rating = Task { await store.rate(next, verdict: .obvious, run: held) }
        while slowCalls.log.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        check(store.saving.contains(next.id), "a rating in flight is marked")
        await store.rate(next, verdict: .wrong, run: fake(slowCalls, [answered(200, #""ok":true,"verdict":"wrong""#)]))
        check(slowCalls.log.count == 1, "a second rating of the same cue waits for the first")
        gate.open = true
        await rating.value
        check(!store.saving.contains(next.id) && store.rated.first { $0.id == next.id }?.verdict == .obvious, "the first lands")

        // A read in flight is not read again.
        let readGate = Gate(); let readCalls = Calls()
        let heldRead: CueVerdictsStore.Run = { args, _ in
            readCalls.log.append(args)
            while !readGate.open { try? await Task.sleep(for: .milliseconds(5)) }
            return HelperResponse(ok: true, message: "x", details: week)
        }
        let reading = Task { await store.loadWeek(heldRead) }
        while readCalls.log.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        await store.loadWeek(fake(readCalls, [week]))
        check(readCalls.log.count == 1, "one week read at a time")
        readGate.open = true
        await reading.value

        // A server from before the routes.
        let older = CueVerdictsStore(); let olderCalls = Calls()
        await older.loadWeek(fake(olderCalls, [answered(404)]))
        check(older.available == false && older.weekState == .olderServer && older.queue.isEmpty && older.counts == nil, "404: no surfaces, one line")
        let fresh = CueVerdictsStore()
        await fresh.loadWeek(fake(Calls(), [details(#"{"transport":"unavailable"}"#)]))
        check(fresh.available == nil && fresh.weekState == .unreachable, "unreachable says nothing about the routes")
        await fresh.loadWeek(fake(Calls(), [week]))
        await fresh.rate(fresh.queue[0], verdict: .late, run: fake(Calls(), [details(#"{"transport":"unsupported","httpStatus":404}"#)]))
        check(fresh.available == false, "a bare 404 on a rating is a server without the routes")
        await store.loadWeek(fake(calls, [details(#"{"transport":"unavailable"}"#)]))
        check(store.weekState == .unreachable && store.queue.isEmpty && store.available == true, "an unreachable read never leaves the last queue on screen")

        // ── A meeting's list, polled no faster than every 15 seconds.
        let meeting = "meeting_1792400000000_abc123"
        let meetingStore = CueVerdictsStore(); meetingStore.now = { clock.now }
        let meetingCalls = Calls()
        let list = history([row("cue-m-000001", session: meeting, at: monday + 60_000), row("cue-o-000001", session: "meeting_1792400000001_zzz", at: monday)],
                           total: 2, rated: 0, unrated: 2, extra: #","maxCuesPerMeeting":25,"meetings":{"\#(meeting)":{"cues":7,"cap":30}}"#)
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        check(meetingCalls.log == [["live-cues-history", "--days", "2", "--session", meeting]], "a meeting's read names the meeting")
        check(meetingStore.meetings[meeting]?.state == .loaded && meetingStore.meetings[meeting]?.cues.map(\.id) == ["cue-m-000001"],
              "only that meeting's cues are kept")
        check(meetingStore.meetings[meeting]?.count == CueVerdicts.MeetingCount(cues: 7, cap: 30), "the meeting's count and cap are the server's own")
        clock.now += 14
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, run: fake(meetingCalls, [list]))
        check(meetingCalls.log.count == 1, "asked again within 15 seconds: no read")
        clock.now += 1
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, run: fake(meetingCalls, [list]))
        check(meetingCalls.log.count == 2, "at 15 seconds it reads again")
        var changes = 0
        let watch = meetingStore.objectWillChange.sink { changes += 1 }
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        check(meetingCalls.log.count == 3, "Refresh reads at once")
        check(changes == 0, "a read that changes nothing redraws nothing")
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [details(#"{"transport":"unavailable"}"#)]))
        check(meetingStore.meetings[meeting]?.state == .loaded && meetingStore.meetings[meeting]?.cues.count == 1 && changes == 0,
              "one failed read keeps the last good list (a wake, an update's restart)")
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [details(#"{"transport":"unavailable"}"#)]))
        check(meetingStore.meetings[meeting]?.state == .unreachable && meetingStore.meetings[meeting]?.cues.count == 1,
              "the second in a row says unreachable and keeps the last good cues (0.5.337 N13)")
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        check(meetingStore.meetings[meeting]?.state == .loaded, "a good read brings the list back")
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [details(#"{"transport":"unavailable"}"#)]))
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [details(#"{"transport":"unavailable"}"#)]))
        check(meetingStore.meetings[meeting]?.state == .loaded, "a good read resets the count of failures")
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [details(#"{"transport":"unsupported","httpStatus":404}"#)]))
        check(meetingStore.meetings[meeting]?.state == .olderServer && meetingStore.meetings[meeting]?.cues.isEmpty == true,
              "a server without the routes says so at once, even over a good list")
        watch.cancel()
        meetingCalls.log.removeAll()
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        let readsBefore = meetingCalls.log.count
        await meetingStore.loadMeeting("meeting_other_1", days: CueVerdicts.savedDays, run: fake(meetingCalls, [details(#"{"transport":"unsupported","httpStatus":404}"#)]))
        check(meetingCalls.log.count == readsBefore + 1 && meetingStore.meetings["meeting_other_1"]?.state == .olderServer && meetingStore.available == false,
              "each meeting keeps its own clock; an older server hides the Cues view at once")
        await meetingStore.rate(meetingStore.meetings[meeting]!.cues[0], verdict: .useful, run: fake(meetingCalls, [answered(200, #""ok":true,"verdict":"useful""#)]))
        check(meetingStore.meetings[meeting]?.cues[0].verdict == .useful, "a rating shows on the meeting's card")
        check(meetingStore.counts == nil && meetingStore.queue.isEmpty, "a meeting's rating never invents a week")

        // ── 0.5.362 (server API v3): insight cues, their sources and the general cue status.
        check(CueVerdicts.kindLabel("insight") == "Insight" && CueVerdicts.kindLabel("decision") == "Decision" && CueVerdicts.kindLabel("advice") == "advice",
              "an insight cue is labelled Insight; the older kinds and an unknown one read as before")
        let insightRow = #"{"cueId":"cue-i-000001","sessionId":"meeting_1792400000000_abc123","meetingTitle":"Standup","createdAt":\#(monday),"kind":"insight","headline":"Show dates moved","detail":"A regional jewelry show moves to March.","gate":0.9,"sources":[{"id":"w1","date":"","title":"Reuters","kind":"web","url":"https://www.reuters.com/world/x"},{"id":"w2","date":"","title":"Plain page","kind":"web","url":"http://insecure.example/a"},{"id":"m1","date":"2026-10-01","title":"Grant review","kind":"meeting","recordId":"rec-1"},{"id":"n1","date":"","title":"A note","kind":"memory","memoryId":"mem-1"}],"general":{"category":"news","query":"regional jewelry show dates"},"before":"","rating":null}"#
        let insight = CueVerdicts.read(history([insightRow], total: 1, rated: 0, unrated: 1)).1?.cues.first
        check(insight?.kind == "insight" && insight?.general == LiveCueGeneral(category: "news", query: "regional jewelry show dates") && insight?.sources.count == 4,
              "an insight row carries its category, its search and its sources")
        check(insight?.sources[0].link == .web(URL(string: "https://www.reuters.com/world/x")!) && insight?.sources[0].domain == "reuters.com",
              "a web source opens its https address and shows its domain, without www")
        check(insight?.sources[1].link == nil && insight?.sources[1].domain == nil, "an http address has no link and no domain")
        check(insight?.sources[2].link == .meeting(recordId: "rec-1") && insight?.sources[3].link == .memory(id: "mem-1"), "a meeting and a memory open by their own locator")
        check(LiveCueSource(id: "f", date: "", title: "Deck", kind: "file", fileId: "file-1").link == .file(id: "file-1"), "a file opens by its fileId")
        check(LiveCueSource(id: "1", date: "2026-10-01", title: "Grant review").link == nil && LiveCueSource(id: "1", date: "2026-10-01", title: "Grant review").domain == nil,
              "a source from an older server has no kind and no link")
        check(LiveCueSource(id: "x", date: "", title: "t", kind: "meeting", memoryId: "mem-1").link == nil
              && LiveCueSource(id: "x", date: "", title: "t", kind: "memory", recordId: "rec-1").link == nil
              && LiveCueSource(id: "x", date: "", title: "t", kind: "file", url: "https://example.com/a").link == nil
              && LiveCueSource(id: "x", date: "", title: "t", kind: "web", fileId: "file-1").link == nil
              && LiveCueSource(id: "x", date: "", title: "t", recordId: "rec-1", url: "https://example.com/a").link == nil
              && LiveCueSource(id: "x", date: "", title: "t", kind: "pdf", recordId: "rec-1").link == nil, "a locator that is not the kind's own, or a kind with none, has no link")
        check(LiveCueSource(id: "x", date: "", title: "t", kind: "meeting", recordId: "").link == nil && LiveCueSource(id: "x", date: "", title: "t", kind: "memory", memoryId: "").link == nil,
              "an empty locator has no link")
        for unsafe in ["http://example.com/a", "javascript:alert(1)", "file:///etc/passwd", "ftp://example.com/x", "https://user:pw@example.com/", "https://localhost/a",
                       "https://127.0.0.1/a", "https://192.168.1.5/a", "https://10.0.0.2/a", "https://printer.local/a", "https:///nohost", "example.com/a", ""] {
            check(LiveCueSource(id: "x", date: "", title: "t", kind: "web", url: unsafe).link == nil && LiveCueSource(id: "x", date: "", title: "t", kind: "web", url: unsafe).domain == nil,
                  "a web source never opens \(unsafe.debugDescription)")
        }
        check(LiveCueSource(id: "x", date: "", title: "t", kind: "web", url: "HTTPS://Example.com/Path").link != nil
              && LiveCueSource(id: "x", date: "", title: "t", kind: "web", url: "https://example.com/Path").domain == "example.com", "the scheme is read without case; the domain is lower case")
        check(LiveCueSource(id: "x", date: "", title: "t", kind: "web", url: nil).link == nil, "a web source without an address has no link")
        check(CueVerdicts.sourceText(insight!.sources[0]) == "Reuters (reuters.com)" && CueVerdicts.sourceText(insight!.sources[1]) == "Plain page"
              && CueVerdicts.sourceText(insight!.sources[2]) == "Grant review (2026-10-01)" && CueVerdicts.sourceText(insight!.sources[3]) == "A note",
              "a web source shows its domain; the others their date")
        check(CueVerdicts.sourcesLine(Array(insight!.sources.prefix(2))) == "Sources: Reuters (reuters.com); Plain page", "the sources line names the domain")
        check(CueVerdicts.read(history([row("cue-g-000001", kind: "insight").replacingOccurrences(of: #""sources":[]"#, with: #""sources":[],"general":{"category":"gossip","query":"q"}"#)],
                                       total: 1, rated: 0, unrated: 1)).1?.cues.first?.general == nil, "a category outside the three is no general block")
        check(CueVerdicts.read(history([row("cue-g-000002")], total: 1, rated: 0, unrated: 1)).1?.cues.first?.general == nil, "an older row has none")
        check(CueVerdicts.cardLine(insight!, style: .twelveHour, calendar: utc) == "9:00 AM · Insight · 0.90", "an insight card's first line")

        // The general cue status.
        let capped = #""state":"active","general":{"state":"capped","reason":"meeting_cap","cues":4,"attempts":6}"#
        let statusRead = CueVerdicts.generalStatus(answered(200, capped))
        check(statusRead.answered && statusRead.status == LiveCuesGeneralStatus(state: "capped", reason: "meeting_cap", cues: 4, attempts: 6), "a status with a general block")
        check(CueVerdicts.generalStatus(answered(200, #""state":"active""#)).answered && CueVerdicts.generalStatus(answered(200, #""state":"active""#)).status == nil,
              "an answer without one: answered, nothing to say")
        check(CueVerdicts.generalStatus(answered(200, #""general":{"state":"invented"}"#)).status == nil && CueVerdicts.generalStatus(answered(200, #""general":{"cues":2}"#)).status == nil,
              "a state outside the six, or none, is no status")
        check(!CueVerdicts.generalStatus(nil).answered && !CueVerdicts.generalStatus(details(#"{"transport":"unavailable"}"#)).answered
              && !CueVerdicts.generalStatus(answered(404)).answered && !CueVerdicts.generalStatus(answered(500, capped)).answered
              && !CueVerdicts.generalStatus(details(#"{"httpStatus":200}"#)).answered, "nothing answering, a refusal or a 404 is not an answer about the status")
        check(CueVerdicts.generalStatus(answered(200, #""general":{"state":"waiting"}"#)).status == LiveCuesGeneralStatus(state: "waiting", reason: nil, cues: 0, attempts: 0), "counts default to zero")
        check(CueVerdicts.statusArguments(session: "meeting_1") == ["live-cues-status", "--session", "meeting_1"], "the status read names the meeting")
        func general(_ state: String) -> LiveCuesGeneralStatus { LiveCuesGeneralStatus(state: state, reason: nil, cues: 0, attempts: 0) }
        check(CueVerdicts.generalLine(general("capped")) == "General cues are paused: a general cue limit was reached. They start again in your next meeting or tomorrow."
              && CueVerdicts.generalLine(general("withheld")) == "General cues are held back while the talk may be private. They start again when it moves on."
              && CueVerdicts.generalLine(general("breaker")) == "General cues paused after repeated failures. They start again by themselves after a pause."
              && CueVerdicts.generalLine(general("needs_public_topics")) == "General cues need Public topics on, so no web lookups run.",
              "each state worth saying has its reason in plain words")
        check(CueVerdicts.generalLine(general("off")) == nil && CueVerdicts.generalLine(general("waiting")) == nil && CueVerdicts.generalLine(general("invented")) == nil
              && CueVerdicts.generalLine(nil) == nil, "off, waiting and no status say nothing")
        for state in CueVerdicts.generalStates {
            if let text = CueVerdicts.generalLine(general(state)) {
                check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->") && !text.contains("_"), "plain words, no em dash, arrow or code: \(text)")
            }
        }
        check(CueVerdicts.generalStates == ["off", "waiting", "capped", "withheld", "breaker", "needs_public_topics"], "the six states of the contract")
        // The store keeps each meeting's status, reads no sooner than 15 s, and never loses it to a read that did not answer.
        let generalClock = Clock(Date(timeIntervalSince1970: monday / 1000))
        let generalStore = CueVerdictsStore(); generalStore.now = { generalClock.now }
        let generalCalls = Calls()
        await generalStore.loadGeneralStatus("meeting_1", run: fake(generalCalls, [answered(200, capped)]))
        check(generalCalls.log == [["live-cues-status", "--session", "meeting_1"]] && generalStore.generalStatus["meeting_1"]?.state == "capped", "the status is read and kept by meeting")
        await generalStore.loadGeneralStatus("meeting_1", run: fake(generalCalls, [answered(200, #""general":{"state":"breaker"}"#)]))
        check(generalCalls.log.count == 1 && generalStore.generalStatus["meeting_1"]?.state == "capped", "a second read inside 15 seconds reads nothing")
        generalClock.now = generalClock.now.addingTimeInterval(16)
        await generalStore.loadGeneralStatus("meeting_1", run: fake(generalCalls, [details(#"{"transport":"unavailable"}"#)]))
        check(generalCalls.log.count == 2 && generalStore.generalStatus["meeting_1"]?.state == "capped", "a read that did not answer keeps the last status")
        generalClock.now = generalClock.now.addingTimeInterval(16)
        await generalStore.loadGeneralStatus("meeting_1", run: fake(generalCalls, [answered(200, #""general":{"state":"breaker"}"#)]))
        check(generalStore.generalStatus["meeting_1"]?.state == "breaker", "a newer answer replaces it")
        await generalStore.loadGeneralStatus("meeting_2", run: fake(generalCalls, [answered(200, #""state":"active""#)]))
        check(generalCalls.log.count == 4 && generalStore.generalStatus["meeting_2"] == nil && generalStore.generalStatus["meeting_1"]?.state == "breaker", "each meeting has its own clock and its own status")
        generalClock.now = generalClock.now.addingTimeInterval(16)
        await generalStore.loadGeneralStatus("meeting_1", run: fake(generalCalls, [answered(200, #""state":"ended""#)]))
        check(generalStore.generalStatus["meeting_1"] == nil, "an answer without a general block clears the line")
        var published = 0
        let watchGeneral = generalStore.$generalStatus.dropFirst().sink { _ in published += 1 }
        generalClock.now = generalClock.now.addingTimeInterval(16)
        await generalStore.loadGeneralStatus("meeting_1", run: fake(generalCalls, [answered(200, #""state":"ended""#)]))
        check(published == 0, "an unchanged status publishes nothing")
        watchGeneral.cancel()

        // Copy full context: the cues the server logged, oldest first, once each, with what was searched and how they were rated.
        var insightCue = LiveCueRecord(id: "cue-i-000001", sessionId: "meeting_1792400000000_abc123", createdAt: Date(timeIntervalSince1970: monday / 1000), kind: "insight",
                                       headline: "Show dates moved", detail: "A regional jewelry show moves to March.",
                                       sources: [LiveCueSource(id: "w1", date: "", title: "Reuters", kind: "web", url: "https://www.reuters.com/world/x"),
                                                 LiveCueSource(id: "w2", date: "", title: "Plain page", kind: "web", url: "http://insecure.example/a")],
                                       general: LiveCueGeneral(category: "news", query: "regional jewelry show dates"))
        var coachCue = LiveCueRecord(id: "cue-c-000002", sessionId: "meeting_1792400000000_abc123", createdAt: Date(timeIntervalSince1970: monday / 1000 + 360), kind: "challenge",
                                     headline: "Settle it", detail: "Settle the date.", sources: [LiveCueSource(id: "1", date: "2026-10-01", title: "Grant review")],
                                     rating: LiveCueRating(verdict: .useful, note: "right call", vote: "up"))
        let expected = "## Cues\n\n### C1 · Insight · 6 min in\nShow dates moved\nA regional jewelry show moves to March.\nSearched the web for: regional jewelry show dates\nSources: Reuters (reuters.com); Plain page\nhttps://www.reuters.com/world/x"
            + "\n\n### C2 · Challenge · 12 min in\nSettle it\nSettle the date.\nSources: Grant review (2026-10-01)\nRated Useful · \u{201C}right call\u{201D}\nVoted up on the glasses"
        check(MeetingAskText.cuesSection([coachCue, insightCue, insightCue], timeZone: TimeZone(identifier: "UTC")!) == expected, "cues in the copied context: oldest first, once each, with sources, search and rating")
        check(MeetingAskText.cuesSection([]) == nil && MeetingAskText.cuesSection([], note: "Context coverage: cues could not be read from the server.")
              == "## Cues\n\nContext coverage: cues could not be read from the server.", "no cues, no section; a coverage note stands alone")
        coachCue.headline = coachCue.detail; coachCue.sessionId = "g2:abc"; coachCue.rating = nil
        check(MeetingAskText.cuesSection([coachCue], timeZone: TimeZone(identifier: "UTC")!) == "## Cues\n\n### C1 · Challenge · 2026-10-19 09:06\nSettle the date.\nSources: Grant review (2026-10-01)",
              "without a start the time is the local clock, a headline equal to the cue is not repeated, an unrated cue has no rating line")
        insightCue.general = nil; insightCue.sources = []
        check(MeetingAskText.cuesSection([insightCue], timeZone: TimeZone(identifier: "UTC")!)?.contains("Searched the web") == false
              && MeetingAskText.cuesSection([insightCue], timeZone: TimeZone(identifier: "UTC")!)?.contains("Sources: none, from the room only") == true, "no search line without one")

        print("cue verdicts checks: \(passed) passed")
    }
}
