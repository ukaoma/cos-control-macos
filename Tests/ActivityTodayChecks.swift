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

    static func main() {
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
        print("PASS: Activity Today home: \(ran) checks (predicates, five pin tests, tool-name guard, platform table, finished hour and cap, intake split and midnight, quiet hours, cost guards, capability gating, layout)")
    }

    // MARK: B1 tool-name guard

    static func guardChecks() {
        for name in ["AskUserQuestion", "ExitPlanMode", "Bash", "SomeNewTool", " WebFetch "] {
            check(TodayHome.isBareToolName(name), "a bare tool name is caught", name)
        }
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
            TodayHome.ActiveJob(.object(["jobId": .string("job-q1"), "origin": .string("person"), "title": .string("What did Dana say about renewal timing?"), "elapsedMs": .number(40_000), "messageNo": .number(3120)]))!,
            TodayHome.ActiveJob(.object(["jobId": .string("job-w1"), "origin": .string("task"), "title": .string("Pricing page QA pass"), "elapsedMs": .number(360_000)]))!,
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
        stray.jobs = [TodayHome.ActiveJob(.object(["jobId": .string("job-o9"), "origin": .string("other"), "title": .string("Meeting review"), "elapsedMs": .number(9000)]))!,
                      TodayHome.ActiveJob(.object(["jobId": .string("job-t9"), "origin": .string("task"), "title": .string("Fix the H1"), "elapsedMs": .number(9000)]))!]
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
        check(crowded.count == 11 && crowded.shown.count == 6 && crowded.finished.isEmpty && crowded.moreLabel == "5 more running, and 1 finished, in Sessions",
              "8 or more running: six shown, finished drop first, N more in Sessions", crowded.moreLabel ?? "nil")
        let stacked = TodayHome.runningView(inFlight: rows, finished: finished, cap: 3)
        check(stacked.shown.count == 3 && stacked.moreLabel == "2 more running, and 1 finished, in Sessions", "stacked: three rows above the fold", stacked.moreLabel ?? "nil")

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

    static func dayCounts(_ run: TodayHome.RunInputs, _ need: TodayHome.NeedInputs) -> (TodayHome.Counts, [TodayHome.NeedRow], [TodayHome.RunRow]) {
        let needs = TodayHome.things(need)
        let running = TodayHome.inFlight(run)
        var c = TodayHome.counts(needs: needs, running: running, finished: TodayHome.finishedRows(run))
        c.voicesToName = need.voiceGroups?.count
        c.memoriesToReview = need.memoriesToReview
        c.memoriesTotal = need.memoriesTotal
        c.workNeedsYou = needs.filter { $0.kind == .work }.count
        c.olderToSort = need.olderToSort
        c.nextEvent = run.event
        c.calendarRead = true
        return (c, needs, running)
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
        check(TodayHome.story("meetings", c, now: now, calendar: calendar).text == "Next at 3:30", "Meetings' rail")
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
        check(TodayHome.brief(c, calendar: calendar) == "Two sessions are waiting on you, and Northwind renewal starts at 3:30. Three agents are working, COS is answering a glasses question and the glasses are recording.",
              "the canvas brief", TodayHome.brief(c, calendar: calendar))
        var quiet = TodayHome.Counts(); quiet.calendarRead = true
        check(TodayHome.brief(quiet) == "Nothing is waiting on you, and your calendar is clear for the rest of the day.", "the caught-up brief")
        var unread = TodayHome.Counts(); unread.needs = 1
        check(TodayHome.brief(unread) == "One thing needs you.", "no calendar read: nothing said about it")
        var routine = TodayHome.Counts(); routine.routinesRunning = 2; routine.agentsWorking = 1
        check(TodayHome.brief(routine) == "Nothing is waiting on you. One agent is working and two routines are running.", "routines", TodayHome.brief(routine))
        let a = TodayHome.brief(c, calendar: calendar), b = TodayHome.brief(c, calendar: calendar)
        check(a == b, "the brief is deterministic")
        for word in ["\u{2014}", "\u{2192}", "you said", "You said"] { check(!a.contains(word), "no em dash, arrow or attribution in the brief", word) }
    }

    // MARK: Quiet hours

    static func quietChecks() {
        check(!TodayHome.isQuiet(now: now, enabled: true, calendar: calendar), "2:47 PM on a Wednesday is not quiet")
        check(TodayHome.isQuiet(now: at("2026-10-21 18:00"), enabled: true, calendar: calendar), "6 PM is quiet")
        check(TodayHome.isQuiet(now: at("2026-10-24 10:00"), enabled: true, calendar: calendar), "Saturday is quiet")
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
        check(TodayRunGuard.line(.capReached) == "Daily limit reached. Open Work to start more.", "the cap's words")
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
        check(TodayHome.mainContentWidth(windowWidth: 760) == 760 - 64 - 56 && TodayHome.runningCap(windowWidth: 920) == 3 && TodayHome.runningCap(windowWidth: 1440) == 6
              && TodayHome.runningCap(windowWidth: 760) == 2, "760 and 920 stack; three Running rows at 920, two at 760")
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
}
