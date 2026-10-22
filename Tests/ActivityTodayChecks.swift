import AppKit
import Foundation

// Activity Today home (PLAN_control_activity_home_v2_2026-10-21), executed against fictional fixture rows: the B3 predicates
// shared by rail, headers, brief, cards and tabs, and the plan's five pin tests; the B1 tool-name guard; section 6's platform
// table and fallbacks; Running's finished hour and cap; the today and older intake split and its midnight move; quiet hours;
// the Work-run cost guards; capability gating; the layout breakpoints. Nothing is drawn, clicked, shown or played. Compiled
// with Sources/Models.swift alone (Tests/run-activity-today.sh), in Austin's time zone.

@main @MainActor struct ActivityTodayChecks {
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
    static func at(_ local: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: local)!
    }
    /// The canvas day: Wednesday 2026-10-21, 2:47 PM in Austin.
    static let now = at("2026-10-21 14:47")
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func ago(_ minutes: Double) -> String { iso(now.addingTimeInterval(-minutes * 60)) }

    static func session(_ id: String, _ state: String, provider: String = "claude", name: String, minutes: Double = 5, kind: String = "",
                        detail: String = "", question: String = "", workspace: String = "MU-Chief-Staff", job: String? = nil) -> ClaudeSession {
        var o: [String: JSONValue] = ["id": .string(String(id.split(separator: ":").last!)), "provider": .string(provider), "name": .string(name), "state": .string(state),
                                      "updatedAt": .string(ago(1)), "stateSince": .string(ago(minutes)), "createdAt": .string(ago(minutes)),
                                      "alive": .bool(true), "waitingKind": .string(kind), "waitingDetail": .string(detail),
                                      "waitingQuestion": .string(question), "workspace": .string(workspace), "stateSource": .string("hook")]
        if let job { o["origin"] = .string("job"); o["jobLabel"] = .string(job) }
        return ClaudeSession(.object(o))!
    }

    static var nextID = 0
    static func intake(_ filename: String, status: String = "ask", text: String = "Send the revised pricing") -> WorkIntakeItem {
        nextID += 1
        let id = "wi_" + String(format: "%032x", nextID)
        return WorkIntakeItem(.object(["id": .string(id), "kind": .string("ask"), "status": .string(status), "confidence": .number(0.9),
                                       "text": .string(text),
                                       "meeting": .object(["recordId": .string("ops:quilt:2026-10:" + filename), "domain": .string("quilt"),
                                                           "month": .string("2026-10"), "filename": .string(filename), "title": .string("Pricing page review")])]))!
    }
    static func mentioned(_ id: String, filename: String?) -> TaskRow {
        var o: [String: JSONValue] = ["id": .string(id), "domain": .string("quilt"), "text": .string("Card " + id), "workStage": .string("mentioned"), "stage": .string("planned")]
        if let filename {
            o["meetingRefs"] = .array([.object(["recordId": .string("ops:quilt:2026-10:" + filename), "domain": .string("quilt"), "month": .string("2026-10"),
                                                "filename": .string(filename), "title": .string("Design review")])])
        }
        return TaskRow(.object(o))!
    }
    static func group(_ id: String, name: String?, similarity: Double) -> HeldVoiceGroup {
        var o: [String: JSONValue] = ["id": .string(id), "members": .array([.object(["sessionId": .string("s-" + id), "chunkIndex": .number(3)])]), "sampleCount": .number(4)]
        if let name { o["suggestion"] = .object(["name": .string(name), "similarity": .number(similarity), "agreeing": .number(3), "of": .number(3)]) }
        return HeldVoiceGroup(.object(o))!
    }
    static func move(_ id: String, title: String, session: String? = nil) -> WorkYourMove {
        var o: [String: JSONValue] = ["id": .string(id), "workId": .string("task:quilt:" + id), "title": .string(title), "kind": .string("qa"), "action": .string("review")]
        if let session { o["activity"] = .object(["sessionId": .string(session)]) }
        return WorkYourMove(.object(o))!
    }

    static func main() async {
        guardChecks()
        intakeChecks()
        platformChecks()
        runningChecks()
        needsChecks()
        pinChecks()
        briefChecks()
        quietChecks()
        runGuardChecks()
        layoutChecks()
        stateChecks()
        composeChecks()
        actionChecks()
        await tickLoopChecks()
        print("PASS: Activity Today home: \(ran) checks (predicates, five pin tests, tool-name guard, platform table, finished hour and cap, intake split and midnight, quiet hours, cost guards, capability gating, layout)")
    }

    // MARK: B1 tool-name guard

    static func guardChecks() {
        for name in ["AskUserQuestion", "ExitPlanMode", "Bash", " WebFetch "] {
            check(TodayHome.isBareToolName(name), "a bare tool name is caught", name)
        }
        // QA round 1 (item 9): one CamelCase word is often a brand or a title, never a tool, and it stays.
        for brand in ["ThriftCart", "MarktPOS", "DiveShop360", "HubSpot", "CigarsPOS", "LikeSew", "DeAndre"] {
            check(!TodayHome.isBareToolName(brand) && TodayHome.guarded(brand) == brand, "a brand title is never taken for a tool", brand)
        }
        let branded = session("claude:b1", "running", name: "ThriftCart")
        check(TodayHome.inFlight({ var i = TodayHome.RunInputs(); i.now = now; i.sessions = [branded]; return i }()).first?.title == "ThriftCart",
              "a brand title is never taken for a tool")
        for words in ["Bash git push", "Build the age-gate module?", "Priya", "Holiday promo landing page", "HubSpot theme settings"] {
            check(!TodayHome.isBareToolName(words), "words are not a tool name", words)
        }
        let asked = session("claude:a1", "waiting", name: "Cigars POS Gen 2 Modules", kind: "question", detail: "AskUserQuestion",
                            question: "Build the age-gate module on the sandbox homepage, or on a new draft page?")
        check(TodayHome.questionText(asked) == "Build the age-gate module on the sandbox homepage, or on a new draft page?", "the question text shows")
        let bare = session("claude:a2", "waiting", name: "Docs sweep", kind: "question", detail: "AskUserQuestion")
        check(TodayHome.questionText(bare) == nil && TodayHome.askedTitle(bare) == "Docs sweep asked you a question", "a tool name detail falls back to the words")
        let named = session("claude:a3", "waiting", name: "AskUserQuestion", kind: "question", detail: "AskUserQuestion")
        check(TodayHome.askedTitle(named) == "A session asked you a question", "a session named after a tool is not shown by that name")
        let plan = session("claude:a4", "waiting", name: "Release plan", kind: "plan", detail: "ExitPlanMode", question: "ignored")
        check(TodayHome.questionText(plan) == nil && TodayHome.askedWhy(plan) == "Has a plan for you to approve", "a plan has no question text")
        let cursor = session("cursor:c1", "waiting", provider: "cursor", name: "Bottle POS footer tweak", detail: "AskUserQuestion")
        check(TodayHome.askedTitle(cursor) == "Bottle POS footer tweak is waiting for your reply" && TodayHome.questionText(cursor) == nil, "Cursor waits read as a reply")
        let permission = session("claude:a5", "waiting", name: "Deploy", kind: "permission", detail: "Bash")
        check(TodayHome.askedWhy(permission) == nil, "a permission whose detail is a bare tool name says nothing more")
        let permission2 = session("claude:a6", "waiting", name: "Deploy", kind: "permission", detail: "Bash git push")
        check(TodayHome.askedWhy(permission2) == "Wants to run Bash git push", "a permission names its command")
    }

    // MARK: B4 intake split and the midnight move (pin 3)

    static func intakeChecks() {
        check(TodayHome.meetingDay("2026-10-21_Pricing_page_review.md") == "2026-10-21", "the meeting day is the filename's date")
        check(TodayHome.meetingDay("Pricing review.md") == nil && TodayHome.meetingDay("2026-13-01_x.md") == nil, "no parsable date: none")
        let today = intake("2026-10-21_Pricing_page_review.md")
        let older = intake("2026-10-19_Rain_POS_pricing_sync.md")
        let undated = intake("Pricing review.md")
        let accepted = intake("2026-10-21_x.md", status: "accepted")
        let cards = [mentioned("m1", filename: "2026-10-21_Design_review.md"), mentioned("m2", filename: "2026-10-12_Old.md"), mentioned("m3", filename: nil)]
        let split = TodayHome.intakeSplit(items: [today, older, undated, accepted], tasks: cards, now: now, calendar: calendar)
        check(split.today.map(\.id) == [today.id] && split.todayCards.map(\.id) == ["m1"], "today's meetings own today's suggestions")
        check(Set(split.older.map(\.id)) == [older.id, undated.id] && split.olderCards.map(\.id) == ["m2", "m3"], "older and undated go to Work")
        check(split.todayCount + split.olderCount == 3 + 3, "older + today == every open item", "\(split.todayCount) + \(split.olderCount)")
        // Pin 3: a fixture item from 23:50 is in Today at 23:59 and in Work's to sort at 00:01, with no server call.
        let late = intake("2026-10-21_Late_call.md")
        let before = TodayHome.intakeSplit(items: [late], tasks: [], now: at("2026-10-21 23:59"), calendar: calendar)
        let after = TodayHome.intakeSplit(items: [late], tasks: [], now: at("2026-10-22 00:01"), calendar: calendar)
        check(before.today.map(\.id) == [late.id] && before.older.isEmpty, "at 23:59 it is Today's")
        check(after.older.map(\.id) == [late.id] && after.today.isEmpty, "at 00:01 it is in Work's to sort")
        check(before.todayCount + before.olderCount == after.todayCount + after.olderCount, "midnight loses nothing")
    }

    // MARK: Section 6 platform table

    static func platformChecks() {
        let terminal = TodayHome.Host(app: "Terminal", terminal: true)
        let iterm = TodayHome.Host(app: "iTerm", terminal: true)
        let desktop = TodayHome.Host(app: "Claude", terminal: false)
        let cc = session("claude:t1", "running", name: "Holiday promo landing page")
        check(TodayHome.platform(cc, host: terminal) == .claudeCode && TodayHome.openFor(cc, host: terminal, cursorTrusted: true).label == "Open in Terminal", "Terminal Claude Code")
        check(TodayHome.openFor(cc, host: iterm, cursorTrusted: true).label == "Open in iTerm", "iTerm Claude Code")
        check(TodayHome.platform(cc, host: desktop) == .claude && TodayHome.openFor(cc, host: desktop, cursorTrusted: true).label == "Open in Claude", "Claude Desktop")
        check(TodayHome.openFor(cc, host: nil, cursorTrusted: true).label == "Open session", "no host known: Open session, which routes")
        let codex = session("codex:x1", "running", provider: "codex", name: "Rain POS schema audit")
        check(TodayHome.platform(codex, host: nil) == .codex && TodayHome.openFor(codex, host: nil, cursorTrusted: true).label == "Open in Codex", "Codex")
        let cursor = session("cursor:u1", "running", provider: "cursor", name: "Footer")
        let trusted = TodayHome.openFor(cursor, host: nil, cursorTrusted: true)
        let untrusted = TodayHome.openFor(cursor, host: nil, cursorTrusted: false)
        check(trusted.label == "Open in Cursor" && trusted.note == nil, "Cursor with Accessibility")
        check(untrusted.label == "In Sessions" && untrusted.note == "Open in Cursor needs Accessibility. Turn on in Settings"
              && untrusted.action == .inSessions(cursor.id), "Cursor without Accessibility falls back to Sessions and says why")
        var work = session("claude:w1", "waiting", name: "Pricing page QA pass"); work.workRunning = true
        check(TodayHome.platform(work, host: terminal) == .work && TodayHome.openFor(work, host: terminal, cursorTrusted: true).label == "In Sessions",
              "a Work run the server holds cannot open in an app")
        let job = session("claude:j1", "running", name: "x", job: "Meeting watcher")
        check(TodayHome.platform(job, host: nil) == .routine, "a scheduled job is a routine row")
        for platform in TodayHome.Platform.allCases {
            check(platform.badge.count >= 4 && platform.badge.first!.isUppercase, "badges are spelled words, never monograms", platform.badge)
        }
    }

    // MARK: Running

    static func runningInputs() -> TodayHome.RunInputs {
        var input = TodayHome.RunInputs()
        input.now = now; input.calendar = calendar
        input.sessions = [
            session("claude:t1", "running", name: "Holiday promo landing page", minutes: 12),
            session("codex:x1", "running", provider: "codex", name: "Rain POS schema audit", minutes: 8),
            session("claude:a1", "waiting", name: "Cigars POS Gen 2 Modules", kind: "question", detail: "AskUserQuestion",
                    question: "Build the age-gate module on the sandbox homepage, or on a new draft page?"),
            session("cursor:c1", "waiting", provider: "cursor", name: "Bottle POS footer tweak", minutes: 3),
        ]
        input.hosts = ["claude:t1": TodayHome.Host(app: "Terminal", terminal: true)]
        input.workRuns = [TodayHome.WorkRun(id: "r1", title: "Pricing page QA pass", sessionID: nil, jobIDs: ["job-w1"], startedAt: now.addingTimeInterval(-360))]
        input.recordings = [TodayHome.Recording(sessionId: "g2-1", start: at("2026-10-21 14:29"), isMac: false)]
        input.jobs = [
            TodayHome.ActiveJob(.object(["jobId": .string("job-q1"), "origin": .string("person"), "title": .string("What did Dana say about renewal timing?"), "elapsedMs": .number(40_000), "messageNo": .number(3120)]), receivedAt: now)!,
            TodayHome.ActiveJob(.object(["jobId": .string("job-w1"), "origin": .string("task"), "title": .string("Pricing page QA pass"), "elapsedMs": .number(360_000)]), receivedAt: now)!,
        ]
        input.finished = [
            TodayHome.Finished(id: "claude:f1", title: "Testimonial HubDB refresh", provider: "claude", finishedAt: now.addingTimeInterval(-4 * 60)),
            TodayHome.Finished(id: "claude:f2", title: "Old one", provider: "claude", finishedAt: now.addingTimeInterval(-61 * 60)),
        ]
        input.event = TodayHome.NextEvent(title: "Northwind renewal", start: at("2026-10-21 15:30"))
        return input
    }

    static func runningChecks() {
        let input = runningInputs()
        let rows = TodayHome.inFlight(input)
        check(rows.map(\.platform) == [.claudeCode, .codex, .work, .glasses, .question], "grouped by platform in section 6's order", "\(rows.map(\.platform))")
        check(rows[0].detail == "in Terminal, working 12 min" && rows[0].openLabel == "Open in Terminal", "the Terminal row", rows[0].detail)
        check(rows[0].voiceLabel == "Claude Code in Terminal, Holiday promo landing page, working 12 minutes, Open in Terminal", "VoiceOver reads the row and its Open", rows[0].voiceLabel)
        check(rows[2].detail == "from Work, on the server, 6 min" && rows[2].openLabel == "In Sessions", "a Work run")
        check(rows[3].title == "Recording from 2:29 PM" && rows[3].openLabel == "Live view", "a G2 recording has no title of its own", rows[3].title)
        check(rows[4].detail == "COS is answering, 40 s" && rows[4].open == .messages(3120), "a glasses question opens its conversation")
        check(rows.filter { $0.title == "Pricing page QA pass" }.count == 1, "a Work run's server job is the Work row, never a second row")
        var stray = input
        stray.jobs = [TodayHome.ActiveJob(.object(["jobId": .string("job-o9"), "origin": .string("other"), "title": .string("Meeting review"), "elapsedMs": .number(9000)]), receivedAt: now)!,
                      TodayHome.ActiveJob(.object(["jobId": .string("job-t9"), "origin": .string("task"), "title": .string("Fix the H1"), "elapsedMs": .number(9000)]), receivedAt: now)!]
        let strayRows = TodayHome.inFlight(stray)
        check(!strayRows.contains { $0.id == "job:job-o9" } && strayRows.contains { $0.id == "job:job-t9" && $0.platform == .work },
              "an unmatched `other` job is skipped; a task dispatch shows once as Work")
        check(TodayHome.Platform.question.badge == "Question", "a person's question is not claimed for the glasses")
        check(!rows.contains { $0.id.contains("claude:a1") || $0.id.contains("cursor:c1") }, "a waiting session is never in Running")
        check(rows.allSatisfy(\.working) && rows.allSatisfy { !$0.finished }, "every in-flight row pulses")
        var older = input; older.jobs = nil
        check(!TodayHome.inFlight(older).contains { $0.platform == .question }, "an older server (no capability): no glasses questions, and no error")
        var overlap = input; overlap.recordings = [TodayHome.Recording(sessionId: "g2-2", start: at("2026-10-21 15:28"), isMac: false)]
        check(TodayHome.inFlight(overlap).contains { $0.title == "Northwind renewal" }, "a recording that starts with the calendar event takes its title")

        let finished = TodayHome.finishedRows(input)
        check(finished.map(\.title) == ["Testimonial HubDB refresh"] && finished[0].detail == "finished 4 min ago" && !finished[0].working,
              "finished within the hour, muted, no pulse; a row at 61 min is gone")
        var sixty = input; sixty.finished = [TodayHome.Finished(id: "claude:f3", title: "Edge", provider: "claude", finishedAt: now.addingTimeInterval(-3600))]
        check(TodayHome.finishedRows(sixty).count == 1, "a row at exactly 60 min still shows")
        let view = TodayHome.runningView(inFlight: rows, finished: finished, cap: 6)
        check(view.count == 5 && view.shown.count == 5 && view.finished.count == 1 && view.moreLabel == nil, "five running and one finished fit the cap of six")

        var many = input
        many.sessions += (0..<6).map { session("claude:m\($0)", "running", name: "Agent \($0)", minutes: Double($0 + 1)) }
        let crowded = TodayHome.runningView(inFlight: TodayHome.inFlight(many), finished: TodayHome.finishedRows(many), cap: 6)
        check(crowded.count == 11 && crowded.shown.count == 6 && crowded.finished.isEmpty && crowded.moreLabel == "5 more running, and 1 finished",
              "8 or more running: six shown, finished drop first, N more in Sessions", crowded.moreLabel ?? "nil")
        let stacked = TodayHome.runningView(inFlight: rows, finished: finished, cap: 3)
        check(stacked.shown.count == 3 && stacked.moreLabel == "2 more running, and 1 finished", "stacked: three rows above the fold", stacked.moreLabel ?? "nil")

        var dupes = input
        dupes.sessions = [session("claude:d1", "running", name: "Footer tweak", workspace: "Bottle POS"), session("claude:d2", "running", name: "Footer tweak", workspace: "IT Retail")]
        dupes.workRuns = []; dupes.recordings = []; dupes.jobs = []; dupes.finished = []
        check(Set(TodayHome.inFlight(dupes).map(\.title)) == ["Footer tweak, Bottle POS", "Footer tweak, IT Retail"], "duplicate titles get their repo")
    }

    // MARK: Needs you

    static func needInputs(_ run: TodayHome.RunInputs) -> TodayHome.NeedInputs {
        var input = TodayHome.NeedInputs()
        input.now = now; input.calendar = calendar
        input.waiting = run.sessions
        input.hosts = run.hosts
        input.voiceGroups = [group("vg1", name: "Priya Shah", similarity: 0.82)]
        input.groupMeeting = ["vg1": "Design review"]
        input.yourMove = [move("mv1", title: "the Rain POS pricing table copy"), move("mv2", title: "Footer", session: "cursor:c1")]
        input.memoriesToReview = 7
        input.memoriesTotal = 7
        input.olderToSort = 23
        return input
    }

    static func needsChecks() {
        let rows = TodayHome.things(needInputs(runningInputs()))
        check(rows.map(\.kind) == [.session, .session, .voice, .work, .memories, .olderToSort], "ranked: sessions, voices, Work, memories, older", "\(rows.map(\.kind))")
        check(rows[0].title == "Cigars POS Gen 2 Modules asked you a question" && rows[0].quote?.hasPrefix("Build the age-gate") == true && rows[0].openLabel == "Open session",
              "the oldest question first, its text read only, one Open session")
        check(rows[1].openLabel == "Open in Cursor", "a Cursor wait opens in Cursor")
        check(rows[2].why == "Sounds like Priya Shah, similarity 0.82." && rows[2].title == "Name a voice from Design review", "a voice shows its similarity, never agreeing counts")
        check(!rows.contains { $0.move?.id == "mv2" }, "a Work item for a waiting session is that session's row")
        check(rows[4].title == "Review 7 memories" && rows[4].items == 7 && rows[4].why == "7 to review", "a thing carries its item count")
        var bigger = needInputs(runningInputs()); bigger.memoriesTotal = 23
        check(TodayHome.things(bigger)[4].why == "Next 7 of 23", "Next 7 of 23 when To review holds more")
        var unnamed = needInputs(runningInputs()); unnamed.groupMeeting = [:]; unnamed.groupStart = ["vg1": at("2026-10-21 13:00")]
        check(TodayHome.things(unnamed)[2].title == "Name a voice from a 1:00 PM recording", "without a meeting join: the start time")
        check(Set(rows.map(\.id)).count == rows.count, "no id twice")
        check(TodayHome.shortLabel(rows[5]) == "sort 23 older suggestions in Work", "the Show more line's words")
    }

    // MARK: The plan's pin tests

    /// Every source answered, the calendar read: the day as the production composition draws it (TodayHome.compose).
    static func answeredSources() -> TodayHome.SourceInputs {
        TodayHome.SourceInputs(reachable: true, sessions: .answered, voices: .answered, memories: .answered, work: .answered)
    }
    static func dayInputs(_ run: TodayHome.RunInputs, _ need: TodayHome.NeedInputs, sources: TodayHome.SourceInputs? = nil) -> TodayHome.HomeInputs {
        var input = TodayHome.HomeInputs()
        input.run = run
        input.need = need
        input.sources = sources ?? answeredSources()
        input.facts.memoriesToReview = need.memoriesToReview
        input.facts.memoriesTotal = need.memoriesTotal
        input.facts.calendarRead = true
        input.facts.voicesLoaded = need.voiceGroups != nil
        input.facts.yourMoveLoaded = need.yourMove != nil
        input.split = need.olderToSort.map { n in
            var split = TodayHome.IntakeSplit()
            split.olderCards = (0..<n).map { mentioned("o\($0)", filename: "2026-10-12_Old.md") }
            return split
        }
        return input
    }
    static func dayCounts(_ run: TodayHome.RunInputs, _ need: TodayHome.NeedInputs) -> (TodayHome.Counts, [TodayHome.NeedRow], [TodayHome.RunRow]) {
        let frame = TodayHome.compose(dayInputs(run, need))
        return (frame.counts, frame.needs, frame.running)
    }

    static func pinChecks() {
        let run = runningInputs()
        let need = needInputs(run)
        let (c, needs, running) = dayCounts(run, need)
        // Pin 1: identical numbers on rail, header, brief and tab.
        check(TodayHome.story("today", c, now: now, calendar: calendar).text == "6 need you, 5 running", "Today's rail story", TodayHome.story("today", c, now: now, calendar: calendar).text)
        check(c.needs == needs.count && c.running == running.count, "header == rows for Needs you and Running")
        let waiting = TodayHome.waitingSessions(run.sessions)
        check(c.sessionsWaiting == waiting.count && c.sessionsWaiting == needs.filter { $0.kind == .session }.count, "Sessions rail == Needs you session rows == Sessions' Waiting list")
        check(TodayHome.story("sessions", c, now: now, calendar: calendar).text == "2 waiting on you, 3 working", "Sessions' rail story",
              TodayHome.story("sessions", c, now: now, calendar: calendar).text)
        check(TodayHome.story("work", c, now: now, calendar: calendar).text == "1 needs you, 23 older to sort", "Work's rail story")
        check(TodayHome.card("sessions", c, now: now, calendar: calendar).tag == "2 waiting", "the Sessions card uses the same count")
        check(TodayHome.story("memories", c, now: now, calendar: calendar).text == "7 to review" && TodayHome.card("memories", c, now: now, calendar: calendar).tag == "7 to review",
              "Memories rail and card agree")
        check(TodayHome.story("speakers", c, now: now, calendar: calendar).text == "1 voice to name", "Speakers' rail")
        check(TodayHome.story("meetings", c, now: now, calendar: calendar).text == "Next at 3:30 PM", "Meetings' rail")
        // Pin 2: working to waiting moves the session from Running to Needs you in the same refresh.
        var moved = run
        moved.sessions[0] = session("claude:t1", "waiting", name: "Holiday promo landing page", kind: "question")
        let (mc, mneeds, mrunning) = dayCounts(moved, needInputs(moved))
        check(!mrunning.contains { $0.id == "session:claude:t1" } && mneeds.contains { $0.id == "session:claude:t1" }, "the session left Running and entered Needs you")
        check(mc.running == c.running - 1 && mc.needs == c.needs + 1, "both counts moved together")
        // Pin 5: a Needs you row never has a Running row's id.
        let runIDs = Set(running.compactMap { $0.id.hasPrefix("session:") ? $0.id : nil })
        check(runIDs.isDisjoint(with: Set(needs.map(\.id))), "no Needs you id is a Running id")
        // The tool-name guard on every surface: a session waiting on AskUserQuestion never shows the tool name.
        var tool = run
        tool.sessions = [session("claude:z1", "waiting", name: "Docs", kind: "question", detail: "AskUserQuestion", question: "AskUserQuestion")]
        let (tc, tneeds, trunning) = dayCounts(tool, needInputs(tool))
        var text = [TodayHome.brief(tc, calendar: calendar)] + ["today", "sessions", "work", "messages", "speakers", "meetings", "memories", "threads", "dictation"].map { TodayHome.story($0, tc, now: now, calendar: calendar).text }
        text += tneeds.flatMap { [$0.title, $0.quote, $0.why, $0.source, $0.openLabel].compactMap { $0 } }
        text += trunning.flatMap { [$0.title, $0.detail, $0.openLabel, $0.voiceLabel] }
        check(!text.contains { $0.contains("AskUserQuestion") }, "AskUserQuestion never renders on home or rail")
        // Rail counts use the same functions as the lists (memories: To review's first page).
        check(TodayHome.memoriesStory(7, total: 7) == "7 to review" && TodayHome.memoriesStory(7, total: nil) == "7 to review", "To review opens on the same 7")
    }

    // MARK: Pin 4: the brief is built only from the counts

    static func briefChecks() {
        let run = runningInputs()
        let (c, _, _) = dayCounts(run, needInputs(run))
        check(TodayHome.brief(c, calendar: calendar) == "Two sessions are waiting on you, and Northwind renewal starts at 3:30 PM. Three agents are working, COS is answering a question and the glasses are recording.",
              "the canvas brief", TodayHome.brief(c, calendar: calendar))
        var quiet = TodayHome.Counts(); quiet.calendarRead = true; quiet.settled = true
        check(TodayHome.brief(quiet, calendar: calendar) == "Nothing is waiting on you, and your calendar is clear for the rest of the day.", "the caught-up brief")
        var unread = TodayHome.Counts(); unread.needs = 1; unread.settled = true
        check(TodayHome.brief(unread) == "One thing needs you.", "no calendar read: nothing said about it")
        var routine = TodayHome.Counts(); routine.routinesRunning = 2; routine.agentsWorking = 1; routine.settled = true
        check(TodayHome.brief(routine) == "Nothing is waiting on you. One agent is working and two routines are running.", "routines", TodayHome.brief(routine))
        // QA round 1 (item 1): nothing says "nothing" until every source answered.
        let loading = TodayHome.Counts()
        check(TodayHome.brief(loading) == "Still reading what needs you." && TodayHome.story("today", loading, now: now, calendar: calendar).text == "Reading",
              "no false caught up while loading", TodayHome.brief(loading))
        var failedWork = TodayHome.Counts(); failedWork.failedSources = [.work]
        check(TodayHome.brief(failedWork) == "Couldn't read Work, so this may not be everything." && !TodayHome.brief(failedWork).contains("Nothing"),
              "no false caught up after a source failed", TodayHome.brief(failedWork))
        var partial = TodayHome.Counts(); partial.needs = 2
        check(TodayHome.brief(partial) == "Two things need you so far.", "a count before every source answered says so far", TodayHome.brief(partial))
        var clearUnknown = TodayHome.Counts(); clearUnknown.settled = true
        check(TodayHome.brief(clearUnknown) == "Nothing is waiting on you.", "the calendar is never called clear unless the server said it read it")
        let a = TodayHome.brief(c, calendar: calendar), b = TodayHome.brief(c, calendar: calendar)
        check(a == b, "the brief is deterministic")
        for word in ["\u{2014}", "\u{2192}", "you said", "You said"] { check(!a.contains(word), "no em dash, arrow or attribution in the brief", word) }
    }

    // MARK: Quiet hours

    static func quietChecks() {
        check(!TodayHome.isQuiet(now: now, enabled: true, calendar: calendar), "2:47 PM on a Wednesday is not quiet")
        check(TodayHome.isQuiet(now: at("2026-10-21 18:00"), enabled: true, calendar: calendar), "6 PM is quiet")
        check(TodayHome.isQuiet(now: at("2026-10-24 10:00"), enabled: true, calendar: calendar), "Saturday is quiet")
        check(TodayHome.isQuiet(now: at("2026-10-21 03:00"), enabled: true, calendar: calendar) && !TodayHome.isQuiet(now: at("2026-10-21 06:00"), enabled: true, calendar: calendar),
              "before 6 AM on a weekday is quiet; 6 AM is not")
        check(!TodayHome.isQuiet(now: at("2026-10-24 10:00"), enabled: false, calendar: calendar), "the switch off: never quiet")
        let rows = TodayHome.things(needInputs(runningInputs()))
        let folded = TodayHome.fold(rows, quiet: true)
        check(folded.now.allSatisfy { $0.tier == 1 } && folded.now.count == 2 && folded.tomorrow.count == 4, "tiers 2 to 5 fold; session questions never fold")
        check(TodayHome.tomorrowLine(folded.tomorrow) == "For tomorrow: 4 more things", "the fold line")
        check(TodayHome.fold(rows, quiet: false).tomorrow.isEmpty, "outside quiet hours nothing folds")
    }

    // MARK: Cost guards

    static func runGuardChecks() {
        let suite = "cos.activity-today-checks.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let guardrail = TodayRunGuard(defaults: defaults, calendar: calendar)
        check(guardrail.admission(target: "prep:a", inFlight: [], switchOn: false, now: now) == .switchOff, "the switch off starts nothing")
        check(guardrail.admission(target: "prep:a", inFlight: ["prep:a"], switchOn: true, now: now) == .inFlight, "one run in flight per meeting")
        check(TodayRunGuard.line(.inFlight) == "Prep in Sessions", "an in-flight prep reads Prep in Sessions")
        for _ in 0..<19 { guardrail.recordStart(now: now) }
        check(guardrail.admission(target: "prep:a", inFlight: [], switchOn: true, now: now) == .allowed && guardrail.used(now: now) == 19, "the 20th is allowed")
        guardrail.recordStart(now: now)
        check(guardrail.admission(target: "prep:b", inFlight: [], switchOn: true, now: now) == .capReached, "the 21st of the day is refused")
        check(TodayRunGuard.line(.capReached) == "Today's limit on this Mac is reached. Open Work to start more.", "the cap's words")
        check(guardrail.admission(target: "prep:b", inFlight: [], switchOn: true, now: at("2026-10-22 08:00")) == .allowed, "a new day starts a new count")
        let fresh = TodayRunGuard(defaults: UserDefaults(suiteName: suite + ".b")!, calendar: calendar)
        defer { UserDefaults(suiteName: suite + ".b")!.removePersistentDomain(forName: suite + ".b") }
        fresh.recordOutcome(admitted: false, now: now); fresh.recordOutcome(admitted: false, now: now)
        check(fresh.admission(target: "ask:1", inFlight: [], switchOn: true, now: now) == .allowed, "two failures do not open the breaker")
        fresh.recordOutcome(admitted: true, now: now)
        fresh.recordOutcome(admitted: false, now: now); fresh.recordOutcome(admitted: false, now: now)
        check(fresh.admission(target: "ask:1", inFlight: [], switchOn: true, now: now) == .allowed, "a success in between resets the count")
        fresh.recordOutcome(admitted: false, now: now)
        check(fresh.admission(target: "ask:1", inFlight: [], switchOn: true, now: now) == .paused(until: now.addingTimeInterval(900)), "3 failures in a row pause for 15 minutes")
        check(TodayRunGuard.line(.paused(until: now.addingTimeInterval(900)), calendar: calendar) == "Paused after 3 failed starts. Try again at 3:02 PM.", "the breaker says when")
        check(fresh.admission(target: "ask:1", inFlight: [], switchOn: true, now: now.addingTimeInterval(901)) == .allowed, "after 15 minutes starts are allowed again")
    }

    // MARK: Layout breakpoints (B2)

    static func layoutChecks() {
        check(TodayHome.railMode(windowWidth: 1099) == .icons && TodayHome.railMode(windowWidth: 1100) == .full, "the rail is icons at 1,099 pt and full at 1,100 pt")
        check(!TodayHome.twoColumns(windowWidth: 1100) && !TodayHome.twoColumns(windowWidth: 920) && TodayHome.twoColumns(windowWidth: 1280), "two columns only once the main column is 900 pt")
        check(TodayHome.mainContentWidth(windowWidth: 760) == 760 - 64 - 56 && TodayHome.runningCap(windowWidth: 920) == 2 && TodayHome.runningCap(windowWidth: 1440) == 6
              && TodayHome.runningCap(windowWidth: 760) == 2, "760 and 920 stack with two Running rows; six beside Needs you")
        check(!TodayHome.twoColumns(windowWidth: 1227) && TodayHome.twoColumns(windowWidth: 1228) && !TodayHome.twoColumns(windowWidth: 1099),
              "two columns from a 1,228 pt window, never with the icon rail")
        check(TodayHome.columns(windowWidth: 1228).right == 380 && TodayHome.columns(windowWidth: 1228).left == 900 - 28 - 380
              && TodayHome.columns(windowWidth: 1800).right > 380, "the right column never narrower than 380 pt")
    }

    // MARK: States and capability parsing

    static func stateChecks() {
        var states: [TodayHome.Source: ActivityHome.SourceState] = [.sessions: .answered, .voices: .answered, .memories: .answered, .work: .answered, .dictation: .answered]
        check(TodayHome.needsLine(rows: 0, states: states) == .caughtUp, "caught up once every source answered")
        states[.work] = .failed
        check(TodayHome.needsLine(rows: 0, states: states) == .loading && TodayHome.failed(states) == [.work], "never nothing waiting while a source is down")
        check(TodayHome.failureLine(.work) == "Couldn't read Work. Try again", "the failed source's line")
        states[.work] = .pending
        check(TodayHome.needsLine(rows: 0, states: states) == .loading, "still loading: no claim")
        states[.work] = .off
        check(TodayHome.needsLine(rows: 0, states: states) == .caughtUp, "a source that does not apply is left out")
        check(TodayHome.checkedLine(now, states: [.sessions: .answered, .voices: .answered, .memories: .answered, .work: .answered, .dictation: .answered], calendar: calendar)
              == "Checked sessions, voices, memories, Work and dictation at 2:47 PM.", "the checked line")
        let event = TodayHome.nextEvent(.object(["title": .string("Northwind renewal"), "time": .string(iso(at("2026-10-21 15:30"))), "inMinutes": .number(43)]), now: now, calendar: calendar)
        check(event?.title == "Northwind renewal" && event.map { TodayHome.eventWhen($0, now: now) } == "In 43 min", "one next event, its minutes from now")
        check(TodayHome.nextEvent(.object(["title": .string("Tomorrow"), "time": .string(iso(at("2026-10-22 09:00")))]), now: now, calendar: calendar) == nil, "an event not today is not Next up")
        check(TodayHome.ActiveJob(.object(["origin": .string("person")])) == nil, "a job without an id is dropped")
        let routine = TodayHome.RoutineRun(.object(["id": .string("rr1"), "label": .string("Morning brief"), "firedAt": .string(iso(at("2026-10-21 14:40")))]))
        check(routine?.label == "Morning brief", "a routine run keeps its label")
        var input = TodayHome.RunInputs(); input.now = now; input.calendar = calendar; input.routines = [routine!]; input.jobs = []
        check(TodayHome.inFlight(input).first?.detail == "running since 2:40 PM", "a running routine says since when; a schedule is never a row")
        let header = TodayHome.headerDate(now, calendar: calendar)
        check(header == "Wednesday, October 21, 2:47 PM", "the header date", header)
        let defaults = UserDefaults(suiteName: "cos.activity-today-defaults.\(getpid())")!
        defer { defaults.removePersistentDomain(forName: "cos.activity-today-defaults.\(getpid())") }
        check(!TodayHome.enabled(defaults) && TodayHome.quietHoursOn(defaults) && TodayHome.workRunsOn(defaults), "opt-in home; quiet hours and Work runs on by default")
    }

    // MARK: QA round 1: composition, reachability, sources (items 1, 2, 10)

    static func composeChecks() {
        let run = runningInputs()
        let need = needInputs(run)
        // Unreachable: this Mac's sessions only, the server's sources failed, nothing says "nothing".
        var down = answeredSources(); down.reachable = false
        let off = TodayHome.compose(dayInputs(run, need, sources: down))
        check(off.needs.allSatisfy { $0.kind == .session } && off.needs.count == 2, "unreachable: Needs you keeps this Mac's sessions only")
        check(off.states[.voices] == .failed && off.states[.memories] == .failed && off.states[.work] == .failed && off.states[.sessions] == .answered,
              "unreachable: the server's sources are failed, sessions are not")
        check(!off.counts.settled && off.counts.voicesToName == nil && off.counts.memoriesToReview == nil && off.counts.olderToSort == nil,
              "unreachable: no count that reads the server")
        check(TodayHome.story("speakers", off.counts, now: now, calendar: calendar).text != "Every voice has a name"
              && TodayHome.story("work", off.counts, now: now, calendar: calendar).text != "Nothing to sort", "unreachable: no false nothing on the rail")
        // Empty and unreachable: never caught up.
        var quietRun = TodayHome.RunInputs(); quietRun.now = now
        let emptyDown = TodayHome.compose(dayInputs(quietRun, TodayHome.NeedInputs(), sources: down))
        check(emptyDown.line == .loading && !TodayHome.brief(emptyDown.counts).contains("Nothing is waiting"), "unreachable and empty: no false caught up",
              TodayHome.brief(emptyDown.counts))
        // Intake failed fails Work; a pending source keeps the line from claiming anything.
        var intake = answeredSources(); intake.intakeFailed = true
        let noIntake = TodayHome.compose(dayInputs(run, need, sources: intake))
        check(noIntake.states[.work] == .failed && noIntake.counts.olderToSort == nil && !noIntake.needs.contains { $0.kind == .olderToSort },
              "a failed Intake read fails Work and its counts")
        var pending = answeredSources(); pending.voices = .pending
        let voicing = TodayHome.compose(dayInputs(quietRun, TodayHome.NeedInputs(), sources: pending))
        check(voicing.line == .loading && voicing.counts.voicesToName == nil, "voices still loading: no Every voice has a name, no caught up")
        let caught = TodayHome.compose(dayInputs(quietRun, { var n = TodayHome.NeedInputs(); n.voiceGroups = []; n.yourMove = []; n.memoriesToReview = 0; return n }()))
        check(caught.line == .caughtUp && caught.counts.settled && TodayHome.story("speakers", caught.counts, now: now, calendar: calendar).text == "Every voice has a name",
              "every source answered: caught up, and the rail may say so")
        // The calendar is clear only when the server says it read it.
        var unsaid = dayInputs(quietRun, TodayHome.NeedInputs()); unsaid.facts.calendarRead = nil
        check(!TodayHome.brief(TodayHome.compose(unsaid).counts).contains("calendar"), "no calendarRead from the server: no clear-day claim")
        // Pin 1 again, on the composed frame: rail, header and rows agree.
        let frame = TodayHome.compose(dayInputs(run, need))
        check(frame.counts.needs == frame.needs.count && frame.counts.running == frame.running.count
              && TodayHome.story("today", frame.counts, now: now, calendar: calendar).text == "\(frame.needs.count) need you, \(frame.running.count) running",
              "the composed frame: rail == header == rows")
    }

    // MARK: QA round 1: hosts, questions, jobs, routines, guard, actions (items 11, 12, 13, 22, 23, 26)

    static func actionChecks() {
        let cc = session("claude:h1", "running", name: "Holiday promo landing page")
        let read = TodayHome.openFor(cc, host: nil, cursorTrusted: true, hostsRead: true)
        check(read.label == "In Sessions" && read.note == "Terminal is not running this session any more." && read.action == .inSessions(cc.id),
              "no host after the lookup: section 6's fallback, In Sessions")
        check(TodayHome.openFor(cc, host: nil, cursorTrusted: true, hostsRead: false).label == "Open session", "before the lookup: Open session routes")
        var asking = session("claude:q3", "waiting", name: "Docs", kind: "question", question: "Sandbox or new draft?")
        asking.waitingQuestionCount = 3
        check(TodayHome.askedWhy(asking) == "Question 1 of 3", "several questions: 1 of N")
        let received = now
        let job = TodayHome.ActiveJob(.object(["jobId": .string("j1"), "elapsedMs": .number(40_000), "title": .string("Q")]), receivedAt: received)!
        check(job.origin == "other" && job.started == now.addingTimeInterval(-40), "a missing origin is other; the start is the answer's time less elapsed")
        var input = TodayHome.RunInputs(); input.now = now.addingTimeInterval(80)
        input.jobs = [TodayHome.ActiveJob(.object(["jobId": .string("j2"), "origin": .string("person"), "elapsedMs": .number(40_000), "title": .string("Q")]), receivedAt: received)!]
        check(TodayHome.inFlight(input).first?.detail == "COS is answering, 2 min", "elapsed counts up between ticks", TodayHome.inFlight(input).first?.detail ?? "nil")
        input.jobs = [TodayHome.ActiveJob(.object(["jobId": .string("j3"), "elapsedMs": .number(1000)]), receivedAt: received)!]
        check(TodayHome.inFlight(input).isEmpty, "a job with no origin is never a second row")
        let stuck = TodayHome.RoutineRun(.object(["id": .string("r1"), "status": .string("submitting"), "firedAt": .string(iso(now.addingTimeInterval(-1200)))]))!
        let fresh = TodayHome.RoutineRun(.object(["id": .string("r2"), "status": .string("submitting"), "firedAt": .string(iso(now.addingTimeInterval(-120)))]))!
        var routines = TodayHome.RunInputs(); routines.now = now; routines.routines = [stuck, fresh]
        check(TodayHome.inFlight(routines).map(\.id) == ["routine:r2"], "a jobless run still submitting after 10 minutes is not running")
        // Guard accounting: only starts that reached the server count; refusals before that are neither starts nor failures.
        check(TodayRunGuard.outcome(receiptStatus: nil, error: "busy") == .notStarted("busy") && TodayRunGuard.outcome(receiptStatus: "queued", error: nil) == .admitted
              && TodayRunGuard.outcome(receiptStatus: "refused", error: nil) == .refused("The server did not start it."), "the run outcome from the new receipt")
        let suite = "cos.activity-today-account.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let guardrail = TodayRunGuard(defaults: defaults, calendar: calendar)
        for _ in 0..<5 { guardrail.account(.notStarted("busy"), now: now) }
        check(guardrail.used(now: now) == 0 && guardrail.pausedUntil(now: now) == nil, "refused before submit: not a start and not a breaker failure")
        for _ in 0..<3 { guardrail.account(.refused("no"), now: now) }
        check(guardrail.used(now: now) == 3 && guardrail.pausedUntil(now: now) != nil, "three admission refusals open the breaker")
        check(TodayRunGuard.preflight(busy: true, holds: false) != nil && TodayRunGuard.preflight(busy: false, holds: true) != nil
              && TodayRunGuard.preflight(busy: false, holds: false) == nil, "busy Work or an open run refuses before anything is recorded")
        check(TodayRunGuard.line(.capReached)?.contains("on this Mac") == true, "the cap says it is this Mac's")
        // The model: Sonnet, never Opus by default, never Cursor.
        let models: [(id: String, provider: String, available: Bool)] = [("claude-opus-4-8", "claude", true), ("cursor-auto", "cursor", true),
                                                                       ("claude-sonnet-4-6", "claude", true), ("gpt-5", "codex", true)]
        check(TodayHome.pickRunModel(models) == 2, "a run from Today uses Sonnet")
        check(TodayHome.pickRunModel([("claude-opus-4-8", "claude", true), ("gpt-5", "codex", true)]) == 1
              && TodayHome.pickRunModel([("claude-opus-4-8", "claude", true)]) == nil, "never Opus by default")
        // Suggestions: Create task for an ask, Open card for a link; state from Work's one accept path.
        let ask = intake("2026-10-21_x.md")
        let link = WorkIntakeItem(.object(["id": .string("wi_" + String(repeating: "a", count: 32)), "kind": .string("link"), "status": .string("suggested"),
                                           "confidence": .number(0.8), "task": .object(["text": .string("Age-gate module")]),
                                           "meeting": .object(["recordId": .string("r"), "domain": .string("quilt"), "month": .string("2026-10"),
                                                               "filename": .string("2026-10-21_d.md"), "title": .string("Design review")])]))!
        check(TodayHome.suggestionAction(ask, cardCreation: true) == .createTask && TodayHome.suggestionAction(ask, cardCreation: false) == .unavailable
              && TodayHome.suggestionAction(link, cardCreation: true) == .openCard("Age-gate module"), "an ask creates, a link opens its card")
        check(TodayHome.suggestionState(ask.id, busy: [ask.id], created: [], failures: [:]) == .creating
              && TodayHome.suggestionState(ask.id, busy: [], created: [ask.id], failures: [:]) == .created
              && TodayHome.suggestionState(ask.id, busy: [], created: [], failures: [ask.id: "No"]) == .failed("No"), "the row follows Work's busy ids")
        let rows = TodayHome.things(needInputs(runningInputs()))
        check(TodayHome.showMoreLabel(Array(rows.suffix(4))) == "Show 4 more: " + TodayHome.shortLabel(rows[2]) + ", " + TodayHome.shortLabel(rows[3]) + " and 2 more",
              "Show more names two at most", TodayHome.showMoreLabel(Array(rows.suffix(4))))
    }

    // MARK: QA round 1: the tick loop on a fake clock (item 20)

    static func tickLoopChecks() async {
        var clock = now
        var visible = true
        var ticks = 0
        var steps = 0
        await TodayTickLoop.run(now: { clock }, visible: { visible }, ready: { true }, tick: { ticks += 1 }, wait: { seconds in
            clock = clock.addingTimeInterval(seconds); steps += 1
            if steps == 180 { visible = false }      // three minutes on screen
            if steps == 360 { visible = true }       // three minutes hidden, then back
            return steps < 400
        })
        check(ticks == 4, "one tick a minute while on screen, none while hidden, one at once on return", "\(ticks) ticks")
        var waited = 0
        var ready = false
        var early = 0
        var firstTickAt: Date?
        clock = now
        await TodayTickLoop.run(now: { clock }, visible: { true }, ready: { ready }, tick: { early += 1; if firstTickAt == nil { firstTickAt = clock } }, wait: { seconds in
            clock = clock.addingTimeInterval(seconds); waited += 1
            if waited == 6 { ready = true }
            return waited < 8
        })
        check(early == 1 && firstTickAt == now.addingTimeInterval(3), "the first tick waits for the window's opening loads")
    }
}
