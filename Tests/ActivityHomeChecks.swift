import AppKit
import Foundation

// 0.5.259 Activity home (boards 1 to 3 of MOCK_activity_work_search_2026-10-06, and the QA fixes of 2026-10-07), executed:
// which sessions get a desk, what is a fact and what only "may need you", the one-row desk strip, Reduce Motion; the Needs
// you items (sessions first, three at most, then the backlog as one segment of counts), the words by waiting kind, the quiet
// line only once every source answered, and where Next ⌘] goes; and every card's lead, which never repeats its footer.
// Fixture rows only: nothing is drawn, clicked, shown or played. Compiled with Sources/Models.swift alone
// (Tests/run-activity-home.sh).

@main @MainActor struct ActivityHomeChecks {
    nonisolated(unsafe) static var ran = 0

    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()
    /// Tuesday 2026-10-06, 23:10 in Austin.
    static let now = ISO8601DateFormatter().date(from: "2026-10-07T04:10:00Z")!

    static func iso(_ minutesAgo: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60)) }

    /// A session row as the helper sends it. `source` is the server's state source ("hook", "registry", or "" when the
    /// helper read the transcript itself); `onUser`, the transcript's open question.
    static func session(_ id: String, _ state: String, updated minutesAgo: Double, provider: String = "claude", name: String? = nil,
                        since: Double? = nil, kind: String = "", detail: String = "", source: String = "", onUser: Bool = false,
                        job: String? = nil, alive: Bool = false) -> ClaudeSession {
        var o: [String: JSONValue] = ["id": .string(id), "provider": .string(provider), "name": .string(name ?? "Session \(id)"),
                                      "state": .string(state), "updatedAt": .string(iso(minutesAgo)), "alive": .bool(alive),
                                      "waitingKind": .string(kind), "waitingDetail": .string(detail), "stateSource": .string(source),
                                      "waitingOnUser": .bool(onUser)]
        if let since { o["stateSince"] = .string(iso(since)) }
        if let job { o["origin"] = .string("job"); o["jobLabel"] = .string(job); o["jobScript"] = .string("sync_meetings.py") }
        return ClaudeSession(.object(o))!
    }

    static func meeting(_ id: String, _ title: String, date: String, time: String, unnamed: Int?) -> ReviewableMeeting {
        var o: [String: JSONValue] = ["sessionId": .string(id), "title": .string(title), "date": .string(date), "time": .string(time)]
        if let unnamed { o["voiceReview"] = .object(["voices": .number(Double(unnamed + 2)), "unattributedVoices": .number(Double(unnamed))]) }
        return ReviewableMeeting(.object(o))!
    }

    nonisolated static func tag(_ meeting: ReviewableMeeting) -> MeetingVoiceTag? {
        guard let unnamed = meeting.unattributedVoices else { return nil }
        return unnamed > 0 ? .needsNames(unnamed) : nil
    }

    static func state(_ session: ClaudeSession, live: Bool = true) -> ActivityHome.DeskState? {
        ActivityHome.deskState(session, live: live, now: now, calendar: calendar)
    }

    static func main() {
        deskChecks()
        needsChecks()
        cardChecks()
        print("PASS: Activity home (0.5.259): \(ran) checks: desks (fact or may need you, one row then +N, Reduce Motion), Needs you (sessions first and three at most, words by waiting kind, the backlog as one segment, the quiet line once every source answered, Next advancing), and card leads that never repeat their footers")
    }

    // MARK: Desks

    static func deskChecks() {
        let asked = session("a1", "waiting", updated: 2, name: "Bottle POS switch offer", since: 12, kind: "question", source: "hook")
        let failed = session("e1", "error", updated: 40)
        let fresh = session("w1", "running", updated: 1, provider: "cursor", name: "IT Retail lane images")
        let quiet = session("q1", "waiting", updated: 16, provider: "codex", name: "gotcos docs sweep")
        let quietJob = session("j1", "waiting", updated: 30, job: "Meeting watcher")
        let doneToday = session("d1", "recent", updated: 18 * 60 + 20, name: "Meeting files release")     // 04:50 today
        let doneYesterday = session("y1", "recent", updated: 24 * 60, name: "Last night")
        let warm = session("k1", "running", updated: 1, name: "Ready")

        // [desk selection] running, waiting and finished today only.
        check(state(asked) == .asked, "desk selection", "a waiting session asks")
        check(state(failed) == .asked, "desk selection", "a failed turn needs a person, as on the pet")
        check(state(fresh) == .working, "desk selection", "a running session works")
        check(state(doneToday) == .finished, "desk selection", "a session that stopped today finished today")
        check(state(doneYesterday) == nil, "desk selection", "yesterday's session is idle, no desk")
        check(state(warm) == nil, "desk selection", "a warm-up never gets a desk")

        // [may need you] a wait the helper only read from 15 quiet minutes of an open turn may need Miles; never a fact.
        check(state(quiet) == .maybe, "may need you", "a wait inferred from quiet")
        check(state(quietJob) == .working, "may need you", "a scheduled job cannot stop on a prompt")
        // [known wait] the hooks, the registry, a named kind, a registry wait or the transcript's open question make it a fact.
        check(state(session("h1", "waiting", updated: 30, source: "hook")) == .asked, "known wait", "the hooks said so")
        check(state(session("r1", "waiting", updated: 30, source: "registry")) == .asked, "known wait", "the registry said so")
        check(state(session("k2", "waiting", updated: 30, kind: "permission")) == .asked, "known wait", "the server named the kind")
        check(state(session("t1", "waiting", updated: 30, onUser: true)) == .asked, "known wait", "the transcript holds an open question")
        // [working] running is working, however long: the helper already counts a live subagent, and the hooks see prompts.
        check(state(session("l1", "running", updated: 45)) == .working, "working", "a session busy for 45 min with subagents or a long tool")
        check(state(session("l2", "running", updated: 45, source: "hook")) == .working, "working", "a hook says it is running")

        // [live list] a row the live list does not carry is not running or waiting, whatever its snapshot says.
        let staleRunning = session("s1", "running", updated: 40)
        check(state(staleRunning, live: false) == .finished, "live list", "a stale running row finished today")
        let staleWaiting = session("s2", "waiting", updated: 24 * 60 + 5)
        check(state(staleWaiting, live: false) == nil, "live list", "a stale waiting row from yesterday is idle")

        let full = session("abcdef12-3456-7890-aaaa-bbbbccccdddd", "running", updated: 3, name: "Speakers: open meeting")
        let short = session("abcdef12", "running", updated: 2, name: "Speakers: open meeting")
        let list = [asked, fresh, quiet, quietJob, doneToday, doneYesterday, warm, staleRunning, full]
        // The live list can carry one session twice, by its short and its full id.
        let fullLive = session("abcdef12-3456-7890-aaaa-bbbbccccdddd", "running", updated: 2, name: "Speakers: open meeting")
        let live = [asked, fresh, quiet, quietJob, short, failed, fullLive]
        let seats = ActivityHome.seats(list: list, live: live, now: now, calendar: calendar)
        let matched = seats.first { $0.row.id == short.id }
        check(matched?.inList == true && matched?.open.id == full.id, "live list", "the live short id opens the list's full id")
        check(seats.filter { ClaudeSession.sameSession($0.row.id, full.id) }.count == 1, "live list", "one seat per session")
        check(seats.first { $0.row.id == staleRunning.id }?.state == .finished, "live list", "absent from the live list: not running")
        check(seats.first { $0.row.id == failed.id }?.inList == false, "live list", "a live row the list lacks still gets a seat")

        let desks = ActivityHome.desks(seats)
        check(!desks.contains { $0.session.id == quietJob.id }, "desk selection", "scheduled jobs are listed in Sessions, not on desks")
        check(!desks.contains { $0.session.id == warm.id || $0.session.id == doneYesterday.id }, "desk selection", "no desk for warm-ups or yesterday")
        check(desks.map(\.state) == [.asked, .asked, .maybe, .working, .working, .finished, .finished],
              "desk selection", "\(desks.map { "\($0.session.id):\($0.state)" })")
        // [desk order] what waits on Miles first, oldest first; then working and finished, newest first.
        check(desks[0].session.id == failed.id && desks[1].session.id == asked.id, "desk order", "the older wait leads: \(desks.map(\.session.id))")
        check(desks[3].session.id == fresh.id && desks[4].session.id == short.id, "desk order", "newest working first: \(desks.map(\.session.id))")
        check(desks[5].session.id == staleRunning.id && desks[6].session.id == doneToday.id, "desk order", "newest finish first: \(desks.map(\.session.id))")
        check(desks[1].since == now.addingTimeInterval(-12 * 60), "desk order", "an ask dates from when it began waiting")

        // [desk help] "<title> · <state> · <age>", the state in the waiting kind's words.
        check(desks[1].help(now: now) == "Bottle POS switch offer · asked you a question · 12 min", "desk help", desks[1].help(now: now))
        check(desks[2].help(now: now) == "gotcos docs sweep · quiet, may need you · 16 min", "desk help", desks[2].help(now: now))
        check(desks[0].help(now: now).contains("stopped with an error"), "desk help", desks[0].help(now: now))
        check(desks[3].help(now: now).hasSuffix("· working · 1 min"), "desk help", desks[3].help(now: now))

        // [desk strip] one row: the desks the card's width holds (12 at most), then +N; what waits on Miles leads.
        var many = (0..<15).map { session("f\($0)", "recent", updated: Double(30 + $0)) }
        many += [session("x1", "waiting", updated: 5, since: 5, source: "hook"), session("x2", "waiting", updated: 6, since: 6, source: "hook")]
        let manyDesks = ActivityHome.desks(ActivityHome.seats(list: many, live: nil, now: now, calendar: calendar))
        check(manyDesks.count == 17 && manyDesks.prefix(2).allSatisfy { $0.state == .asked }, "desk strip", "the waits lead the strip")
        let wide = ActivityHome.deskFit(count: 17, width: 1000)
        check(wide.shown == 12 && wide.more == 5, "desk strip", "12 at most, then +5: \(wide)")
        let row = { (n: Int) -> CGFloat in CGFloat(n) * ActivityHome.deskWidth + CGFloat(max(0, n - 1)) * ActivityHome.deskGap }
        check(ActivityHome.deskFit(count: 12, width: row(12)) == (12, 0), "desk strip", "12 that fit show whole, with no +0")
        let narrow = ActivityHome.deskFit(count: 17, width: 133)   // a card at the 760 pt minimum
        check(narrow.shown == 3 && narrow.more == 14 && row(narrow.shown) + ActivityHome.deskGap + ActivityHome.deskMoreWidth <= 133,
              "desk strip", "three desks and +14 fit one 133 pt row: \(narrow)")
        let card920 = ActivityHome.deskFit(count: 17, width: 168)
        check(card920 == (4, 13) && row(card920.shown) + ActivityHome.deskGap + ActivityHome.deskMoreWidth <= 168,
              "desk strip", "one 168 pt row: \(card920)")
        for width in stride(from: 70.0, through: 600.0, by: 7.0) {
            let fit = ActivityHome.deskFit(count: 20, width: width)
            let used = row(fit.shown) + (fit.more > 0 ? (fit.shown > 0 ? ActivityHome.deskGap : 0) + ActivityHome.deskMoreWidth : 0)
            check(fit.shown + fit.more == 20 && fit.shown <= 12 && used <= width, "desk strip", "never wider than the row at \(width): \(fit)")
        }
        check(ActivityHome.deskFit(count: 0, width: 168) == (0, 0), "desk strip", "no sessions, an empty row")
        check(ActivityHome.deskFit(count: 7, width: 133) == (3, 4), "desk strip", "seven on a 133 pt card: three and +4, still one row")

        // [sessions tally] the card's numbers come from the same seats.
        let tally = ActivityHome.tally(seats)
        check(tally.onDisk == 8, "sessions tally", "the list less its warm-up: \(tally)")
        check(tally.asked == 2 && tally.working == 2 && tally.finished == 2, "sessions tally", "a quiet desk is neither working nor waiting: \(tally)")
        check(tally.idle == 1, "sessions tally", "only yesterday is idle: \(tally)")

        // [reduce motion] only a working desk glows, and never under Reduce Motion.
        check(ActivityHome.DeskState.working.glows(reduceMotion: false), "reduce motion", "a working desk glows")
        check(!ActivityHome.DeskState.working.glows(reduceMotion: true), "reduce motion", "still under Reduce Motion")
        for state in [ActivityHome.DeskState.asked, .maybe, .finished] {
            check(!state.glows(reduceMotion: false) && !state.glows(reduceMotion: true), "reduce motion", "\(state) never glows")
        }
    }

    // MARK: Needs you

    static func needsChecks() {
        let asked = session("a1", "waiting", updated: 12, name: "Bottle POS switch offer", since: 12, kind: "question", source: "hook")
        let quiet = session("q1", "waiting", updated: 16, provider: "codex", name: "gotcos docs sweep")
        let desks = ActivityHome.desks(ActivityHome.seats(list: [asked, quiet], live: nil, now: now, calendar: calendar))
        // Two of each kind of session: a failed turn 40 min ago and a question 12 min ago; quiet 30 and 16 min.
        let failedOld = session("e1", "error", updated: 40)
        let quietOld = session("q2", "waiting", updated: 30, name: "Older quiet")
        let busy = ActivityHome.desks(ActivityHome.seats(list: [asked, quiet, failedOld, quietOld], live: nil, now: now, calendar: calendar))
        let meetings = [
            meeting("m1", "Weekly pipeline", date: "2026-10-05", time: "09:30", unnamed: 2),
            meeting("m2", "Deprioritize CityHive, Feature DoorDash Integrations", date: "2026-10-06", time: "11:46", unnamed: 1),
            meeting("m3", "No report from this server", date: "2026-10-06", time: "15:00", unnamed: nil),
            meeting("m4", "All named", date: "2026-10-06", time: "16:00", unnamed: 0),
        ]
        let voices = ActivityHome.voicesToName(meetings, tag: tag)
        check(voices?.voices == 3 && voices?.meetings == 2, "voices to name", "unreported meetings never count: \(String(describing: voices))")
        check(voices?.newest?.sessionId == "m2", "voices to name", "names the newest meeting that waits")
        check(ActivityHome.voicesToName([], tag: tag) == nil, "missing source", "no meetings loaded: no voices source")

        let sunday = ISO8601DateFormatter().date(from: "2026-10-04T15:00:00Z")!
        let all = ActivityHome.NeedSources(desks: desks, voices: voices, memoriesToReview: 3, memoriesOldest: sunday, workAttention: 7)
        let items = ActivityHome.needs(all, calendar: calendar)
        // [sessions first] a blocked session leads, then a quiet one, then the backlog, though Sunday's memories are older.
        check(items.prefix(2).map(\.kind) == [.asked, .maybe] && items.dropFirst(2).allSatisfy { !$0.isSession },
              "sessions first", "\(items.map(\.kind.rawValue))")
        check(items.dropFirst(2).map(\.kind) == [.voices, .memories, .work], "backlog order", "\(items.map(\.kind.rawValue))")
        let ranked = ActivityHome.needs(.init(desks: busy, voices: voices, memoriesToReview: 3, memoriesOldest: sunday, workAttention: 7), calendar: calendar)
        check(ranked.prefix(4).map(\.kind) == [.asked, .asked, .maybe, .maybe], "sessions first", "asked and failed, then quiet: \(ranked.map(\.kind.rawValue))")
        check(ranked.prefix(4).map { $0.desk?.session.id ?? "" } == ["claude:e1", "claude:a1", "claude:q2", "codex:q1"],
              "oldest first", "within each group: \(ranked.map { $0.desk?.session.id ?? $0.kind.rawValue })")
        // [oldest first] within a group, the older first; an undated item follows the dated ones of its kind.
        check(ranked[0].since! < ranked[1].since! && ranked[2].since! < ranked[3].since!, "oldest first", "within each session group")
        let undated = ActivityHome.ordered([ActivityHome.Need(kind: .asked, what: "No stamp", why: "asked you a question", since: nil),
                                            ActivityHome.Need(kind: .asked, what: "Stamped", why: "asked you a question", since: sunday)])
        check(undated.map(\.what) == ["Stamped", "No stamp"], "oldest first", "listed first, an undated item still follows")
        // [backlog order] voices, memories, Work, whatever their dates.
        let backlogOnly = ActivityHome.ordered([ActivityHome.Need(kind: .work, what: "1 work item", why: "needs attention", since: nil),
                                                ActivityHome.Need(kind: .memories, what: "1 memory", why: "to review", since: sunday),
                                                ActivityHome.Need(kind: .voices, what: "1 voice to name", why: "Later meeting", since: now)])
        check(backlogOnly.map(\.kind) == [.voices, .memories, .work], "backlog order", "\(backlogOnly.map(\.kind.rawValue))")

        // [compact backlog] the backlog is one segment of counts: no meeting name, no description; "Also" only after sessions.
        func text(_ parts: ActivityHome.LineParts) -> String { ActivityHome.backlogPieces(parts).map(\.text).joined(separator: " ") }
        let parts = ActivityHome.parts(items)
        check(parts.sessions.map(\.kind) == [.asked, .maybe] && parts.backlog.map(\.kind) == [.voices, .memories, .work], "compact backlog", "split")
        check(text(parts) == "Also · 3 voices to name · 3 memories · 7 work items", "compact backlog", text(parts))
        let alone = ActivityHome.parts(ActivityHome.needs(.init(desks: [], voices: voices, memoriesToReview: 3, memoriesOldest: sunday, workAttention: 7), calendar: calendar))
        check(!alone.alsoPrefix && text(alone) == "3 voices to name · 3 memories · 7 work items", "compact backlog", text(alone))
        check(!ActivityHome.parts(ActivityHome.needs(.init(desks: desks), calendar: calendar)).alsoPrefix, "compact backlog", "no Also with sessions alone")
        for piece in ActivityHome.backlogPieces(parts) {
            check(!piece.text.contains("Deprioritize") && !piece.text.contains("to review") && !piece.text.contains("attention"),
                  "compact backlog", "\(piece.text): the cards say the rest")
        }

        // [session cap] three session items at most; the rest are "+N sessions".
        let five = (0..<5).map { session("c\($0)", "waiting", updated: Double(10 + $0), since: Double(10 + $0), source: "hook") }
        let crowd = ActivityHome.parts(ActivityHome.needs(.init(desks: ActivityHome.desks(ActivityHome.seats(list: five, live: nil, now: now, calendar: calendar)),
                                                                workAttention: 2), calendar: calendar))
        check(crowd.sessions.count == 5 && crowd.shown.count == 3 && crowd.moreSessions == 2, "session cap", "\(crowd.shown.count) shown, +\(crowd.moreSessions)")
        check(crowd.shown.map { $0.desk?.session.id ?? "" } == ["claude:c4", "claude:c3", "claude:c2"], "session cap", "the oldest three show")
        check(ActivityHome.moreSessionsLabel(2) == "+2 sessions" && ActivityHome.moreSessionsLabel(1) == "+1 session", "session cap", "label")
        check(ActivityHome.parts(items).moreSessions == 0, "session cap", "two sessions show whole")

        // [may need you] the open dot, its own words, never a fact.
        let maybe = items.first { $0.kind == .maybe }!
        check(!maybe.isFact && maybe.why == "quiet, may need you" && maybe.what == "gotcos docs sweep", "may need you", "\(maybe.what) \(maybe.why)")
        check(!maybe.why.contains("asked") && !maybe.why.contains("waiting"), "may need you", "a quiet session is never said to have asked")
        let ask = items.first { $0.kind == .asked }!
        check(ask.isFact && ask.why == "asked you a question" && ask.age(now: now) == "12 min", "needs words", "\(ask.why) \(String(describing: ask.age(now: now)))")
        check(maybe.age(now: now) == "16 min", "needs words", "the quiet age")
        let voice = items.first { $0.kind == .voices }!
        check(voice.what == "3 voices to name" && voice.why == "Deprioritize CityHive, Feature DoorDash Integrations" && voice.meeting?.sessionId == "m2",
              "needs words", "\(voice.what) · \(voice.why)")
        check(voice.age(now: now) == nil, "needs words", "only sessions carry an age")
        check(items.first { $0.kind == .work }?.what == "7 work items" && items.first { $0.kind == .work }?.why == "need attention", "needs words", "work")
        check(items.first { $0.kind == .memories }?.what == "3 memories", "needs words", "memories")

        // [waiting kind] the words follow the server's waiting kind; an unknown kind keeps the question words.
        let words: [(String, String)] = [("permission", "wants your permission"), ("question", "asked you a question"),
                                         ("plan", "has a plan to approve"), ("mcp_input", "needs your input"), ("elicitation", "asked you a question"),
                                         ("", "asked you a question")]
        for (kind, said) in words {
            let row = session("w-\(kind)", "waiting", updated: 3, kind: kind, source: "hook")
            check(ActivityHome.askedWords(row) == said, "waiting kind", "\(kind): \(ActivityHome.askedWords(row))")
        }
        check(ActivityHome.askedWords(session("e2", "error", updated: 3)) == "stopped with an error", "waiting kind", "a failed turn says so")
        let pair = [session("p1", "waiting", updated: 3, kind: "permission", detail: "Bash git push", source: "hook"),
                    session("p2", "waiting", updated: 4, kind: "plan", source: "hook")]
        let pairItems = ActivityHome.needs(.init(desks: ActivityHome.desks(ActivityHome.seats(list: pair, live: nil, now: now, calendar: calendar))), calendar: calendar)
        check(Set(pairItems.map(\.why)) == ["wants your permission", "has a plan to approve"], "waiting kind", "two items: the plain words \(pairItems.map(\.why))")

        // [one item detail] with one session item, what it asked, cut to the limit.
        func single(_ row: ClaudeSession) -> String {
            ActivityHome.needs(.init(desks: ActivityHome.desks(ActivityHome.seats(list: [row], live: nil, now: now, calendar: calendar))), calendar: calendar).first?.why ?? ""
        }
        check(single(session("o1", "waiting", updated: 3, kind: "question", detail: "Use the sandbox homepage or a new draft?", source: "hook"))
              == "asked: \u{201C}Use the sandbox homepage or a new draft?\u{201D}", "one item detail", "the question")
        check(single(session("o2", "waiting", updated: 3, kind: "permission", detail: "Bash git push", source: "hook")) == "wants your permission: Bash git push",
              "one item detail", "the permission")
        let long = String(repeating: "x", count: 200)
        let cut = single(session("o3", "waiting", updated: 3, kind: "question", detail: long, source: "hook"))
        check(cut.hasPrefix("asked: \u{201C}xxx") && cut.hasSuffix("…\u{201D}") && cut.count == "asked: \u{201C}".count + ActivityHome.detailLimit + 1,
              "one item detail", "cut to \(ActivityHome.detailLimit): \(cut.count)")
        check(single(session("o4", "waiting", updated: 3, kind: "plan", detail: "Long plan text", source: "hook")) == "has a plan to approve",
              "one item detail", "a plan keeps its words")
        check(single(session("o5", "waiting", updated: 3, kind: "question", source: "hook")) == "asked you a question", "one item detail", "no detail")
        check(single(session("o6", "waiting", updated: 30)) == "quiet, may need you", "one item detail", "a quiet session has no detail to give")
        let failed = ActivityHome.desks(ActivityHome.seats(list: [session("e1", "error", updated: 3)], live: nil, now: now, calendar: calendar))
        check(ActivityHome.needs(.init(desks: failed), calendar: calendar).first?.why == "stopped with an error", "needs words", "a failed turn says so")

        // [missing source] a source Control has not loaded is left out; a zero is left out too, never "0 work items".
        check(ActivityHome.needs(ActivityHome.NeedSources(), calendar: calendar).isEmpty, "missing source", "nothing loaded")
        let partial = ActivityHome.NeedSources(desks: nil, voices: nil, memoriesToReview: nil, memoriesOldest: nil, workAttention: 2)
        check(ActivityHome.needs(partial, calendar: calendar).map(\.kind) == [.work], "missing source", "only Work answered")
        let zeros = ActivityHome.NeedSources(desks: [], voices: ActivityHome.voicesToName([meetings[3]], tag: tag), memoriesToReview: 0, workAttention: 0)
        check(ActivityHome.needs(zeros, calendar: calendar).isEmpty, "missing source", "zeros are not items")

        // [quiet line] only once every source that applies has answered; never while one loads or after one failed.
        let answered: [ActivityHome.Source: ActivityHome.SourceState] = [.sessions: .answered, .voices: .answered, .memories: .answered, .work: .answered]
        check(ActivityHome.line([], states: answered) == .quiet, "quiet line", "all answered")
        var workOff = answered; workOff[.work] = .off
        check(ActivityHome.line([], states: workOff) == .quiet, "quiet line", "Work not connected is not waited for")
        var workLoading = answered; workLoading[.work] = .pending
        check(ActivityHome.line([], states: workLoading) == .hidden, "quiet line", "Work still loading: no claim")
        var voicesFailed = answered; voicesFailed[.voices] = .failed
        check(ActivityHome.line([], states: voicesFailed) == .hidden, "quiet line", "a failed source: no claim")
        check(ActivityHome.line([], states: [:]) == .hidden, "quiet line", "nothing answered yet")
        check(ActivityHome.line([], states: [.sessions: .off, .voices: .off, .memories: .off, .work: .off]) == .hidden, "quiet line", "nothing applies: no claim")
        check(ActivityHome.line(items, states: workLoading) == .items, "quiet line", "items show whatever is still loading")
        check(ActivityHome.quietLine == "Nothing is waiting on you.", "quiet line", ActivityHome.quietLine)
        // [source state] a load that came back, or rows in hand; a failed load wins over older rows; off when it does not apply.
        check(ActivityHome.sourceState(enabled: true, loaded: nil, hasData: false) == .pending, "source state", "not yet")
        check(ActivityHome.sourceState(enabled: true, loaded: nil, hasData: true) == .answered, "source state", "rows in hand")
        check(ActivityHome.sourceState(enabled: true, loaded: .answered, hasData: false) == .answered, "source state", "came back empty")
        check(ActivityHome.sourceState(enabled: true, loaded: .failed, hasData: true) == .failed, "source state", "failed, older rows in hand")
        check(ActivityHome.sourceState(enabled: false, loaded: .answered, hasData: true) == .off, "source state", "not connected")
        check(ActivityHome.sourceState(enabled: true, loaded: .off, hasData: false) == .off, "source state", "the server reports no count")

        // [compact line] a session item that nearly fits the rest of a row gives up at most a quarter of its width rather
        // than start a row; the backlog segment never shrinks. Widths measured from the 920 pt render: 350 and 323 for
        // the two sessions, 245 for the backlog, about 658 pt of row.
        let narrow = ActivityHome.flow(ideal: [350, 323, 245], shrinks: [true, true, false], width: 658, spacing: 18)
        check(narrow.map(\.row) == [0, 0, 1] && narrow[1].width == 658 - 368 && narrow[2].x == 0, "compact line", "two rows at 920: \(narrow)")
        let wide = ActivityHome.flow(ideal: [350, 323, 245], shrinks: [true, true, false], width: 857, spacing: 18)
        check(wide.map(\.row) == [0, 0, 1] && wide[1].width == 323, "compact line", "1280: sessions whole, backlog wraps whole: \(wide)")
        check(ActivityHome.flow(ideal: [350, 323, 245], shrinks: [true, true, false], width: 1000, spacing: 18).map(\.row) == [0, 0, 0],
              "compact line", "one row when it all fits")
        let tooNarrow = ActivityHome.flow(ideal: [350, 323, 245], shrinks: [true, true, false], width: 600, spacing: 18)
        check(tooNarrow.map(\.row) == [0, 1, 1] && tooNarrow[1].width == 323, "compact line", "more than a quarter lost: it wraps whole: \(tooNarrow)")
        let backlogStaysWhole = ActivityHome.flow(ideal: [350, 245], shrinks: [true, false], width: 560, spacing: 18)
        check(backlogStaysWhole.map(\.row) == [0, 1] && backlogStaysWhole[1].width == 245, "compact line", "the backlog never shrinks: \(backlogStaysWhole)")
        let huge = ActivityHome.flow(ideal: [900], shrinks: [true], width: 658, spacing: 18)
        check(huge == [ActivityHome.FlowPlace(row: 0, x: 0, width: 658)], "compact line", "wider than a row: it gets the row")

        // [next] Next ⌘] opens the first item, then the one after the item it opened last, wrapping; when that item has
        // gone, the one in its place. With one item the button reads Open.
        check(ActivityHome.nextTarget(items, after: nil)?.kind == .asked, "next", "the blocked session, not Sunday's memories")
        check(ActivityHome.nextTarget(ranked, after: nil)?.desk?.session.id == "claude:e1", "next", "the oldest blocked session")
        var cursor: ActivityHome.NextCursor? = nil
        var walked: [String] = []
        for _ in 0..<(items.count + 1) {
            let next = ActivityHome.nextTarget(items, after: cursor)!
            walked.append(next.kind.rawValue)
            cursor = ActivityHome.NextCursor(id: next.id, index: items.firstIndex { $0.id == next.id }!)
        }
        check(walked == ["asked", "maybe", "voices", "memories", "work", "asked"], "next", "it walks every item and wraps: \(walked)")
        let gone = Array(items.dropFirst(2))   // the question was answered and the quiet session went back to work
        check(ActivityHome.nextTarget(gone, after: ActivityHome.NextCursor(id: items[1].id, index: 1))?.kind == .memories, "next",
              "the item opened last has gone: the one now in its place")
        check(ActivityHome.nextTarget(gone, after: ActivityHome.NextCursor(id: "gone", index: 9))?.kind == .voices, "next", "past the end: the first")
        check(ActivityHome.nextTarget([], after: nil) == nil, "next", "nothing to open")
        check(ActivityHome.nextLabel(items) == "Next" && ActivityHome.nextLabel([items[1]]) == "Open", "next", "Open with one item")
        let sessionsOnly = ActivityHome.needs(.init(desks: desks), calendar: calendar)
        check(ActivityHome.nextTarget(sessionsOnly, after: nil)?.desk?.session.id == "claude:a1", "next", "a question before a longer quiet")
        check(ActivityHome.nextTarget(alone.backlog, after: nil)?.kind == .voices, "next", "with no sessions, the backlog in its order")
    }

    // MARK: Cards

    static func cardChecks() {
        let turns = [
            GlassesTurn(id: "t1", no: 30, timestamp: now.addingTimeInterval(-26 * 3600).timeIntervalSince1970,
                        query: "Hey, I had a question about how much longer this task is going to take", text: "", sessionId: "s", source: "g2"),
            GlassesTurn(id: "t2", no: 29, timestamp: now.addingTimeInterval(-30 * 3600).timeIntervalSince1970, query: "older", text: "", sessionId: "s", source: "g2"),
        ]
        let meetings = [
            meeting("m1", "Weekly pipeline", date: "2026-10-05", time: "09:30", unnamed: 2),
            meeting("m2", "Deprioritize CityHive, Feature DoorDash Integrations", date: "2026-10-06", time: "11:46", unnamed: 1),
            meeting("m5", "Morning standup", date: "2026-10-06", time: "08:30", unnamed: 0),
        ]
        // Sunday 10:00 in Austin; its weekday word and 5,528 are formatted for this Mac's locale, as the app formats them.
        let sunday = ISO8601DateFormatter().date(from: "2026-10-04T15:00:00Z")!
        var full = ActivityHome.CardInputs()
        full.now = now; full.calendar = calendar; full.clock = .twelveHour
        full.messages = turns; full.messagesStatus = .ready
        full.enrolled = 94; full.voices = ActivityHome.voicesToName(meetings, tag: tag)
        full.monthCount = 45; full.monthTitle = "October 2026"; full.recentMeetings = meetings
        full.toReview = 3; full.oldestReview = sunday; full.memories = 5528
        full.threads = 66; full.activeThreads = 32; full.latestThread = "Bottle POS October switch offer"
        full.sessions = ActivityHome.SessionTally(onDisk: 80, working: 2, asked: 1, finished: 3, idle: 74)
        full.workAttention = 7; full.workInProgress = 0; full.newToSort = 35
        full.tasks = []

        // [lead never repeats footer], across full, quiet and unloaded inputs.
        var quiet = full
        quiet.voices = ActivityHome.voicesToName([meetings[2]], tag: tag); quiet.toReview = 0; quiet.newToSort = 0; quiet.workInProgress = 2
        quiet.workAttention = 1; quiet.sessions = ActivityHome.SessionTally(onDisk: 9, working: 0, asked: 0, finished: 0, idle: 9)
        quiet.messagesStatus = .empty; quiet.messages = []
        var empty = ActivityHome.CardInputs(); empty.now = now; empty.calendar = calendar
        var older = full; older.toReview = nil; older.oldestReview = nil
        var noDate = full; noDate.oldestReview = nil
        for (name, input) in [("full", full), ("quiet", quiet), ("empty", empty), ("older server", older), ("undated review", noDate)] {
            for card in ActivityHome.Card.allCases {
                let body = ActivityHome.card(card, input)
                check(body.subs.count <= 2, "card copy", "\(name) \(card): at most two sub lines")
                guard let footer = body.footer, !body.leadText.isEmpty else { continue }
                check(body.leadText != footer && !footer.contains(body.leadText) && !body.leadText.contains(footer),
                      "lead never repeats footer", "\(name) \(card): \(body.leadText) / \(footer)")
            }
        }

        let kept = 5528.formatted(.number)
        let mock: [ActivityHome.Card: (lead: String, footer: String, count: String)] = [
            .speakers: ("3 voices to name", "94 enrolled", "94"),
            .meetings: ("2 today · latest 11:46 AM", "45 in October 2026", "45"),
            .memories: ("3 to review", kept + " kept", kept),
            .threads: ("32 active", "66 tracked", "66"),
            .sessions: ("2 working · 1 waiting on you", "80 on disk · 74 idle", "80"),
            .work: ("35 new to sort", "7 need attention", "7"),
        ]
        for (card, want) in mock {
            let body = ActivityHome.card(card, full)
            check(body.leadText == want.lead, "card copy", "\(card) lead: \(body.leadText)")
            check(body.footer == want.footer && body.count == want.count, "card copy", "\(card): \(String(describing: body.count)) · \(String(describing: body.footer))")
        }
        let messages = ActivityHome.card(.messages, full)
        check(messages.leadText.hasPrefix("Last from the glasses, yesterday ") && messages.footer == "2 recent", "card copy", "\(messages.leadText) / \(String(describing: messages.footer))")
        check(messages.subs.first?.hasPrefix("\u{201C}Hey, I had a question") == true, "card copy", "\(messages.subs)")
        let speakers = ActivityHome.card(.speakers, full)
        check(speakers.subs == ["Deprioritize CityHive, Feature DoorDash Integrations", "In 2 meetings"], "card copy", "\(speakers.subs)")
        check(ActivityHome.card(.work, full).subs == ["0 in progress"], "card copy", "work sub")
        check(ActivityHome.card(.sessions, full).subs == ["3 finished today"], "card copy", "sessions sub")

        // [memories card] the big number is the memories kept, as in 0.5.258; the lead says what waits to be reviewed.
        let memories = ActivityHome.card(.memories, full)
        check(memories.count == kept && memories.footer == kept + " kept" && memories.lead == [ActivityHome.Span(text: "3 to review", waits: true)],
              "memories card", "\(String(describing: memories.count)) \(memories.leadText) \(String(describing: memories.footer))")
        check(memories.subs == ["Oldest waiting since " + sunday.formatted(.dateTime.weekday(.wide))], "memories card", "\(memories.subs)")
        let none = ActivityHome.card(.memories, quiet)
        check(none.count == kept && none.leadText == "Nothing to review" && none.lead.allSatisfy { !$0.waits }, "memories card", "\(none.leadText)")
        check(ActivityHome.card(.memories, noDate).subs.isEmpty && ActivityHome.card(.memories, noDate).leadText == "3 to review", "memories card", "undated")
        let olderMemories = ActivityHome.card(.memories, older)
        check(olderMemories.count == kept && olderMemories.leadText.isEmpty, "memories card", "a server without the review count: the kept count alone")

        // [lead waits] amber only where it waits on Miles.
        check(ActivityHome.card(.speakers, full).lead.allSatisfy(\.waits), "lead waits", "voices to name wait on Miles")
        check(ActivityHome.card(.work, full).lead.allSatisfy(\.waits), "lead waits", "new to sort waits")
        check(ActivityHome.card(.sessions, full).lead.map(\.waits) == [false, false, true], "lead waits", "only the waiting part is amber")
        check(!ActivityHome.card(.threads, full).lead.contains(where: \.waits), "lead waits", "threads wait on nobody")

        // [no fake zero] an unloaded source shows no number at all (no placeholder), no lead and no footer.
        for card in ActivityHome.Card.allCases {
            let body = ActivityHome.card(card, empty)
            check(body.count == nil && body.footer == nil, "no fake zero", "\(card): \(String(describing: body.count)) \(String(describing: body.footer))")
        }
        check(ActivityHome.card(.memories, empty).leadText.isEmpty && ActivityHome.card(.threads, empty).leadText.isEmpty,
              "no fake zero", "an unloaded status is not 'Setup needed'")
        var setup = empty; setup.memorySetupNeeded = true; setup.threadSetupNeeded = true
        check(ActivityHome.card(.memories, setup).leadText == "Setup needed" && ActivityHome.card(.threads, setup).leadText == "Setup needed",
              "no fake zero", "the status said it is not set up")
        let quietWork = ActivityHome.card(.work, quiet)
        check(quietWork.leadText == "2 in progress" && quietWork.footer == "1 needs attention", "card copy", "\(quietWork.leadText) / \(String(describing: quietWork.footer))")
        check(ActivityHome.card(.sessions, quiet).leadText == "None running" && ActivityHome.card(.sessions, quiet).footer == "9 on disk · 9 idle",
              "card copy", "quiet sessions")
        check(ActivityHome.card(.speakers, quiet).leadText.isEmpty, "no fake zero", "nothing to name: no lead, never 0 voices")
    }
}
