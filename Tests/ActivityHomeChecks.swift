import AppKit
import Foundation

// 0.5.259 Activity home (boards 1 to 3 of MOCK_activity_work_search_2026-10-06), executed: which sessions get a desk, the
// cap and "+N", Reduce Motion; the Needs you items, oldest first, "may need you" never as fact, a missing source left out,
// the quiet line, and what Next ⌘] opens; and every card's lead, which never repeats its footer. Fixture rows only:
// nothing is drawn, clicked, shown or played. Compiled with Sources/Models.swift alone (Tests/run-activity-home.sh).

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

    static func session(_ id: String, _ state: String, updated minutesAgo: Double, provider: String = "claude", name: String? = nil,
                        since: Double? = nil, kind: String = "", job: String? = nil, alive: Bool = false) -> ClaudeSession {
        var o: [String: JSONValue] = ["id": .string(id), "provider": .string(provider), "name": .string(name ?? "Session \(id)"),
                                      "state": .string(state), "updatedAt": .string(iso(minutesAgo)), "alive": .bool(alive),
                                      "waitingKind": .string(kind)]
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

    static func main() {
        deskChecks()
        needsChecks()
        cardChecks()
        print("PASS: Activity home (0.5.259): \(ran) checks: desks (running, waiting, finished today; cap 12 then +N; Reduce Motion), Needs you (sessions first, oldest first within, then the backlog as one segment; may need you never as fact, missing sources left out, the quiet line, Next ⌘]), and card leads that never repeat their footers")
    }

    // MARK: Desks

    static func deskChecks() {
        let asked = session("a1", "waiting", updated: 2, name: "Bottle POS switch offer", since: 12, kind: "question")
        let failed = session("e1", "error", updated: 40)
        let fresh = session("w1", "running", updated: 1, provider: "cursor", name: "IT Retail lane images")
        let quiet = session("q1", "running", updated: 16, provider: "codex", name: "gotcos docs sweep")
        let quietJob = session("j1", "running", updated: 30, job: "Meeting watcher")
        let doneToday = session("d1", "recent", updated: 18 * 60 + 20, name: "Meeting files release")     // 04:50 today
        let doneYesterday = session("y1", "recent", updated: 24 * 60, name: "Last night")
        let warm = session("k1", "running", updated: 1, name: "Ready")

        // [desk selection] running, waiting and finished today only.
        check(ActivityHome.deskState(asked, live: true, now: now, calendar: calendar) == .asked, "desk selection", "a waiting session asks")
        check(ActivityHome.deskState(failed, live: true, now: now, calendar: calendar) == .asked, "desk selection", "a failed turn needs a person, as on the pet")
        check(ActivityHome.deskState(fresh, live: true, now: now, calendar: calendar) == .working, "desk selection", "a running session works")
        check(ActivityHome.deskState(doneToday, live: true, now: now, calendar: calendar) == .finished, "desk selection", "a session that stopped today finished today")
        check(ActivityHome.deskState(doneYesterday, live: true, now: now, calendar: calendar) == nil, "desk selection", "yesterday's session is idle, no desk")
        check(ActivityHome.deskState(warm, live: true, now: now, calendar: calendar) == nil, "desk selection", "a warm-up never gets a desk")

        // [may need you] mid-turn and quiet 15 minutes: may need you; a run the server holds never does.
        check(ActivityHome.deskState(quiet, live: true, now: now, calendar: calendar) == .maybe, "may need you", "16 min quiet mid-turn")
        let fourteen = session("q2", "running", updated: 14)
        check(ActivityHome.deskState(fourteen, live: true, now: now, calendar: calendar) == .working, "may need you", "14 min is still working")
        let fifteen = session("q3", "running", updated: 15)
        check(ActivityHome.deskState(fifteen, live: true, now: now, calendar: calendar) == .maybe, "may need you", "15 min exactly may need you")
        check(ActivityHome.deskState(quietJob, live: true, now: now, calendar: calendar) == .working, "may need you", "a scheduled job cannot stop on a prompt")

        // [live list] a row the live list does not carry is not running or waiting, whatever its snapshot says.
        let staleRunning = session("s1", "running", updated: 40)
        check(ActivityHome.deskState(staleRunning, live: false, now: now, calendar: calendar) == .finished, "live list", "a stale running row finished today")
        let staleWaiting = session("s2", "waiting", updated: 24 * 60 + 5)
        check(ActivityHome.deskState(staleWaiting, live: false, now: now, calendar: calendar) == nil, "live list", "a stale waiting row from yesterday is idle")

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

        // [desk help] "<title> · <state> · <age>".
        check(desks[1].help(now: now) == "Bottle POS switch offer · asked you something · 12 min", "desk help", desks[1].help(now: now))
        check(desks[2].help(now: now) == "gotcos docs sweep · quiet, may need you · 16 min", "desk help", desks[2].help(now: now))
        check(desks[0].help(now: now).contains("stopped with an error"), "desk help", desks[0].help(now: now))
        check(desks[3].help(now: now).hasSuffix("· working · 1 min"), "desk help", desks[3].help(now: now))

        // [desk cap] at most 12, then +N; what waits on Miles is never cut.
        var many = (0..<15).map { session("f\($0)", "recent", updated: Double(30 + $0)) }
        many += [session("x1", "waiting", updated: 5, since: 5), session("x2", "waiting", updated: 6, since: 6)]
        let manyDesks = ActivityHome.desks(ActivityHome.seats(list: many, live: nil, now: now, calendar: calendar))
        let strip = ActivityHome.strip(manyDesks)
        check(manyDesks.count == 17 && strip.shown.count == 12 && strip.more == 5, "desk cap", "\(manyDesks.count) desks, \(strip.shown.count) shown, +\(strip.more)")
        check(strip.shown.prefix(2).allSatisfy { $0.state == .asked }, "desk cap", "the waits lead the strip")
        let few = ActivityHome.strip(Array(manyDesks.prefix(12)))
        check(few.shown.count == 12 && few.more == 0, "desk cap", "12 desks show whole, with no +0")

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
        let asked = session("a1", "waiting", updated: 12, name: "Bottle POS switch offer", since: 12, kind: "question")
        let quiet = session("q1", "running", updated: 16, provider: "codex", name: "gotcos docs sweep")
        let desks = ActivityHome.desks(ActivityHome.seats(list: [asked, quiet], live: nil, now: now, calendar: calendar))
        // Two of each kind of session: a failed turn 40 min ago and a question 12 min ago; quiet 30 and 16 min.
        let failedOld = session("e1", "error", updated: 40)
        let quietOld = session("q2", "running", updated: 30, name: "Older quiet")
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
        let parts = ActivityHome.parts(items)
        check(parts.sessions.map(\.kind) == [.asked, .maybe] && parts.backlog.map(\.kind) == [.voices, .memories, .work], "compact backlog", "split")
        check(ActivityHome.backlogText(parts) == "Also · 3 voices to name · 3 memories · 7 work items", "compact backlog", ActivityHome.backlogText(parts))
        let alone = ActivityHome.parts(ActivityHome.needs(.init(desks: [], voices: voices, memoriesToReview: 3, memoriesOldest: sunday, workAttention: 7), calendar: calendar))
        check(!alone.alsoPrefix && ActivityHome.backlogText(alone) == "3 voices to name · 3 memories · 7 work items", "compact backlog", ActivityHome.backlogText(alone))
        check(!ActivityHome.parts(ActivityHome.needs(.init(desks: desks), calendar: calendar)).alsoPrefix, "compact backlog", "no Also with sessions alone")
        for need in parts.backlog {
            let label = ActivityHome.backlogLabel(need)
            check(!label.contains("Deprioritize") && !label.contains("to review") && !label.contains("attention"), "compact backlog", "\(label): the cards say the rest")
        }

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
        let failed = ActivityHome.desks(ActivityHome.seats(list: [session("e1", "error", updated: 3)], live: nil, now: now, calendar: calendar))
        check(ActivityHome.needs(.init(desks: failed), calendar: calendar).first?.why == "stopped with an error", "needs words", "a failed turn says so")

        // [missing source] a source Control has not loaded is left out; a zero is left out too, never "0 work items".
        let none = ActivityHome.NeedSources()
        check(ActivityHome.needs(none, calendar: calendar).isEmpty && !none.anyAvailable, "missing source", "nothing loaded")
        let partial = ActivityHome.NeedSources(desks: nil, voices: nil, memoriesToReview: nil, memoriesOldest: nil, workAttention: 2)
        check(ActivityHome.needs(partial, calendar: calendar).map(\.kind) == [.work], "missing source", "only Work answered")
        let zeros = ActivityHome.NeedSources(desks: [], voices: ActivityHome.voicesToName([meetings[3]], tag: tag), memoriesToReview: 0, workAttention: 0)
        check(ActivityHome.needs(zeros, calendar: calendar).isEmpty && zeros.anyAvailable, "missing source", "zeros are not items")

        // [quiet line] one line when a source answered and nothing waits; nothing at all before any source answers.
        check(ActivityHome.line([], available: true) == .quiet, "quiet line", "nothing waits")
        check(ActivityHome.line([], available: false) == .hidden, "quiet line", "no source yet: no claim")
        check(ActivityHome.line(items, available: true) == .items, "quiet line", "items show")
        check(ActivityHome.quietLine == "Nothing is waiting on you.", "quiet line", ActivityHome.quietLine)

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

        // [next] Next ⌘] opens the first item in the line's order: a blocked session before any backlog, even an older
        // one; with one item the button reads Open.
        check(ActivityHome.nextTarget(items)?.kind == .asked, "next", "the blocked session, not Sunday's memories")
        check(ActivityHome.nextTarget(ranked)?.desk?.session.id == "claude:e1", "next", "the oldest blocked session")
        check(ActivityHome.nextTarget([]) == nil, "next", "nothing to open")
        check(ActivityHome.nextLabel(items) == "Next" && ActivityHome.nextLabel([items[1]]) == "Open", "next", "Open with one item")
        let sessionsOnly = ActivityHome.needs(.init(desks: desks), calendar: calendar)
        check(ActivityHome.nextTarget(sessionsOnly)?.desk?.session.id == "claude:a1", "next", "a question before a longer quiet")
        check(ActivityHome.nextTarget(alone.backlog)?.kind == .voices, "next", "with no sessions, the backlog in its order")
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

        let mock: [ActivityHome.Card: (lead: String, footer: String, count: String)] = [
            .speakers: ("1 voice to name", "94 enrolled", "94"),
            .meetings: ("2 today · latest 11:46 AM", "45 in October 2026", "45"),
            .memories: ("Oldest waiting since " + sunday.formatted(.dateTime.weekday(.wide)), "3 to review", "3"),
            .threads: ("32 active", "66 tracked", "66"),
            .sessions: ("2 working · 1 waiting on you", "80 on disk · 74 idle", "80"),
            .work: ("35 new to sort", "7 need attention", "7"),
        ]
        for (card, want) in mock {
            let body = ActivityHome.card(card, full)
            if card == .speakers {
                check(body.leadText == "3 voices to name", "card copy", "speakers lead: \(body.leadText)")
            } else {
                check(body.leadText == want.lead, "card copy", "\(card) lead: \(body.leadText)")
            }
            check(body.footer == want.footer && body.count == want.count, "card copy", "\(card): \(body.count) · \(String(describing: body.footer))")
        }
        let messages = ActivityHome.card(.messages, full)
        check(messages.leadText.hasPrefix("Last from the glasses, yesterday ") && messages.footer == "2 recent", "card copy", "\(messages.leadText) / \(String(describing: messages.footer))")
        check(messages.subs.first?.hasPrefix("\u{201C}Hey, I had a question") == true, "card copy", "\(messages.subs)")
        let speakers = ActivityHome.card(.speakers, full)
        check(speakers.subs == ["Deprioritize CityHive, Feature DoorDash Integrations", "In 2 meetings"], "card copy", "\(speakers.subs)")
        check(ActivityHome.card(.work, full).subs == ["0 in progress"], "card copy", "work sub")
        check(ActivityHome.card(.sessions, full).subs == ["3 finished today"], "card copy", "sessions sub")

        // [lead waits] amber only where it waits on Miles.
        check(ActivityHome.card(.speakers, full).lead.allSatisfy(\.waits), "lead waits", "voices to name wait on Miles")
        check(ActivityHome.card(.work, full).lead.allSatisfy(\.waits), "lead waits", "new to sort waits")
        check(ActivityHome.card(.sessions, full).lead.map(\.waits) == [false, false, true], "lead waits", "only the waiting part is amber")
        check(!ActivityHome.card(.threads, full).lead.contains(where: \.waits), "lead waits", "threads wait on nobody")

        // [no fake zero] an unloaded source shows no number, no lead and no footer.
        for card in ActivityHome.Card.allCases {
            let body = ActivityHome.card(card, empty)
            check(body.count == "—" && body.footer == nil, "no fake zero", "\(card): \(body.count) \(String(describing: body.footer))")
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
        check(ActivityHome.card(.memories, quiet).leadText == 5528.formatted(.number) + " stored" && ActivityHome.card(.memories, quiet).footer == "0 to review",
              "card copy", "nothing to review")
        check(ActivityHome.card(.memories, noDate).leadText == "Waiting for you to keep or let go", "card copy", "undated review")
        check(ActivityHome.card(.speakers, quiet).leadText.isEmpty, "no fake zero", "nothing to name: no lead, never 0 voices")
    }
}
