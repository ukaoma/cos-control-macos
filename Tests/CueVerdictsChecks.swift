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
        #"{"cueId":"\#(id)","sessionId":"\#(session)","meetingTitle":"HC Monday standup","createdAt":\#(ms),"kind":"\#(kind)","headline":"Settle it","detail":"\#(detail)","gate":0.97,"sources":[],"model":"claude-sonnet-5-5","before":"MU: we move them.","verdict":\#(verdict)}"#
    }
    static func history(_ rows: [String], total: Int, rated: Int, unrated: Int, by: String = "{}") -> [String: JSONValue] {
        answered(200, #""v":1,"cues":[\#(rows.joined(separator: ","))],"counts":{"total":\#(total),"rated":\#(rated),"unrated":\#(unrated),"byVerdict":\#(by)}"#)
    }

    @MainActor static func main() async {
        typealias S = CueVerdicts.State
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!

        // ── The history's answer to a state.
        check(CueVerdicts.read(nil).0 == .notChecked, "a helper that failed is not checked")
        check(CueVerdicts.read(details(#"{"transport":"unavailable"}"#)).0 == .unreachable, "nothing answered: unreachable")
        check(CueVerdicts.read(details(#"{"transport":"no_token"}"#)).0 == .reconnect, "no pairing token: reconnect")
        check(CueVerdicts.read(answered(404)).0 == .olderServer, "404: a server from before the routes")
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
        check(CueVerdicts.rateArguments(cue, verdict: .useful, note: "  more\n than  that ")
              == ["live-cues-rate", "--session", cue.sessionId, "--cue", cue.id, "--verdict", "useful", "--note", "more than that"], "a verdict with its note")
        check(CueVerdicts.rateArguments(cue, verdict: .late, note: "   ") == ["live-cues-rate", "--session", cue.sessionId, "--cue", cue.id, "--verdict", "late"],
              "a blank note is no note")
        check(CueVerdicts.rateArguments(cue, verdict: nil, note: "kept?") == ["live-cues-rate", "--session", cue.sessionId, "--cue", cue.id, "--verdict", "clear"],
              "clearing carries no note")
        let cut = CueVerdicts.note(String(repeating: "\u{1F600}", count: 150))
        check(cut.utf16.count == 200 && cut.unicodeScalars.allSatisfy { $0 == "\u{1F600}" }, "a note stops at 200 UTF-16 units, on a character")

        // ── A rating's answer.
        check(CueVerdicts.rateOutcome(answered(200, #""ok":true,"verdict":"wrong","vote":"up""#)) == .saved(.wrong, vote: "up"), "saved, with the lens vote")
        check(CueVerdicts.rateOutcome(answered(200, #""ok":true,"verdict":null"#)) == .saved(nil, vote: nil), "cleared")
        check(CueVerdicts.rateOutcome(answered(200)) == .failed(status: 200), "a 200 without ok is not a save")
        check(CueVerdicts.rateOutcome(answered(404, #""error":"unknown_cue""#)) == .unknownCue, "404 unknown_cue")
        check(CueVerdicts.rateOutcome(answered(404)) == .olderServer, "a bare 404 is an older server")
        check(CueVerdicts.rateOutcome(answered(400)) == .refused && CueVerdicts.rateOutcome(answered(401)) == .reconnect
              && CueVerdicts.rateOutcome(answered(503)) == .failed(status: 503), "400, 401 and 503")
        check(CueVerdicts.rateOutcome(nil) == .notChecked && CueVerdicts.rateOutcome(details(#"{"transport":"unavailable"}"#)) == .unreachable
              && CueVerdicts.rateOutcome(details(#"{"transport":"no_token"}"#)) == .reconnect, "the helper and transport failures")
        check(CueVerdicts.rateLine(.saved(.useful, vote: nil)) == nil, "a save has no line")
        check(CueVerdicts.rateLine(.unknownCue) == "The server no longer has this cue. Cues are kept 30 days."
              && CueVerdicts.rateLine(.unreachable) == "COS server unreachable. The rating was not saved."
              && CueVerdicts.rateLine(.failed(status: 500)) == "The rating was not saved (HTTP 500). Try again.", "a failed rating says it was not saved")
        let outcomes: [CueVerdicts.RateOutcome] = [.unknownCue, .olderServer, .unreachable, .reconnect, .refused, .failed(status: 500), .notChecked]
        var words = outcomes.compactMap(CueVerdicts.rateLine) + lines.compactMap { $0.1 }
        words += [CueVerdicts.keysLine, CueVerdicts.notePlaceholder, CueVerdicts.doneLine(nil), CueVerdicts.doneLine(LiveCueCounts(total: 3, rated: 3, unrated: 0))]
        check(words.count == outcomes.count + 7 + 4, "every failure has words")
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
        check(CueVerdicts.ratingsLine(LiveCueCounts(total: 31, rated: 3, unrated: 28)) == "Ratings this week: 3 of 31.", "the week's count line")
        check(CueVerdicts.usedLine(10) == "10 of 25 used" && CueVerdicts.meetingCap == 25, "the meeting's count against the cap")
        check(CueVerdicts.leftLine(1) == "1 left" && CueVerdicts.leftLine(28) == "28 left", "left")
        check(CueVerdicts.doneLine(nil) == "No cues in the last 7 days." && CueVerdicts.doneLine(LiveCueCounts(total: 4, rated: 4, unrated: 0)) == "Every cue from the last 7 days is rated.",
              "the empty queue says why")
        var headed = cue; headed.headline = "LMS pages went to the 1517 team with no deadline"
        check(CueVerdicts.nextLine(headed, style: .twelveHour, calendar: utc) == "Next up: 9:00 AM · LMS pages went to the 1517 team with no deadline", "next up")
        check(CueVerdicts.pollSeconds == 15 && CueVerdicts.liveDays == 2 && CueVerdicts.savedDays == 30 && CueVerdicts.weekDays == 7, "the windows")

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
        final class Calls { var log: [[String]] = [] }
        final class Clock { var now: Date; init(_ now: Date) { self.now = now } }
        func fake(_ calls: Calls, _ answers: [[String: JSONValue]?]) -> CueVerdictsStore.Run {
            var queue = answers
            return { args, _ in
                calls.log.append(args)
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
        check(calls.log.last == ["live-cues-rate", "--session", target.sessionId, "--cue", target.id, "--verdict", "late", "--note", "too late"], "the rating's arguments")
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
        check(store.rateErrors[waiting.id] == "COS server unreachable. The rating was not saved." && store.queue == before.0, "unreachable: not saved")
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
        await fresh.rate(fresh.queue[0], verdict: .late, run: fake(Calls(), [answered(404)]))
        check(fresh.available == false, "a bare 404 on a rating is a server without the routes")
        await store.loadWeek(fake(calls, [details(#"{"transport":"unavailable"}"#)]))
        check(store.weekState == .unreachable && store.queue.isEmpty && store.available == true, "an unreachable read never leaves the last queue on screen")

        // ── A meeting's list, polled no faster than every 15 seconds.
        let meeting = "meeting_1792400000000_abc123"
        let meetingStore = CueVerdictsStore(); meetingStore.now = { clock.now }
        let meetingCalls = Calls()
        let list = history([row("cue-m-000001", session: meeting, at: monday + 60_000), row("cue-o-000001", session: "meeting_1792400000001_zzz", at: monday)],
                           total: 2, rated: 0, unrated: 2)
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        check(meetingCalls.log == [["live-cues-history", "--days", "2", "--session", meeting]], "a meeting's read names the meeting")
        check(meetingStore.meetings[meeting]?.state == .loaded && meetingStore.meetings[meeting]?.cues.map(\.id) == ["cue-m-000001"],
              "only that meeting's cues are kept")
        clock.now += 14
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, run: fake(meetingCalls, [list]))
        check(meetingCalls.log.count == 1, "asked again within 15 seconds: no read")
        clock.now += 1
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, run: fake(meetingCalls, [list]))
        check(meetingCalls.log.count == 2, "at 15 seconds it reads again")
        await meetingStore.loadMeeting(meeting, days: CueVerdicts.liveDays, force: true, run: fake(meetingCalls, [list]))
        check(meetingCalls.log.count == 3, "Refresh reads at once")
        await meetingStore.loadMeeting("meeting_other_1", days: CueVerdicts.savedDays, run: fake(meetingCalls, [answered(404)]))
        check(meetingCalls.log.count == 4 && meetingStore.meetings["meeting_other_1"]?.state == .olderServer && meetingStore.available == false,
              "each meeting keeps its own clock; a 404 hides the Cues view")
        await meetingStore.rate(meetingStore.meetings[meeting]!.cues[0], verdict: .useful, run: fake(meetingCalls, [answered(200, #""ok":true,"verdict":"useful""#)]))
        check(meetingStore.meetings[meeting]?.cues[0].verdict == .useful, "a rating shows on the meeting's card")
        check(meetingStore.counts == nil && meetingStore.queue.isEmpty, "a meeting's rating never invents a week")

        print("cue verdicts checks: \(passed) passed")
    }
}
