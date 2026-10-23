import AppKit
import Foundation

// 0.5.337 hardening (PATCHLIST_control_0_5_337_2026-10-22, the loop and performance audits), executed against fictional
// fixtures: the rules each fix put in a pure place. Compiled with Models.swift, LiveTranscript.swift, MeetingAskCore.swift,
// WorkLensPlans.swift, WorkOrchestrator.swift and MacDictationCore.swift alone (Tests/run-hardening-337.sh), in Austin's
// time zone. Nothing is drawn, clicked, shown or played. The wiring is pinned in Tests/hardening-337-pins.py.

@main @MainActor struct Hardening337Checks {
    nonisolated(unsafe) static var ran = 0

    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }
    static let t0 = Date(timeIntervalSince1970: 1_792_700_000)

    static func main() async {
        workLoopChecks()
        cadenceChecks()
        boardCountChecks()
        roundCapChecks()
        cueLimitChecks()
        liveMeetingChecks()
        polishPauseChecks()
        stopChecks()
        todayRunChecks()
        sessionStampChecks()
        await tickLoopChecks()
        tierTwoChecks()
        milesChecks()
        print("PASS: 0.5.337 hardening: \(ran) checks (work loop support, refresh cadence, pet pause, board counts and notices, the 100-round cap, cue limits, live meeting words and lookups, the preview breaker, polish pause, queued Stop, Today runs and naming, session stamps, the hidden tick, the frame clock, Stop on reviewed rounds, discarded captures, the Fix a word frame, COS's own fields)")
    }

    // W1
    static func workLoopChecks() {
        check(WorkLoopSupport.unsupported(["unsupported": .bool(true)]) && !WorkLoopSupport.unsupported(["changed": .number(1)]), "[W1 unsupported] a 404 answer reads as unsupported")
        check(!WorkLoopSupport.undoOffered(available: nil, unsupported: []), "[W1 undo] Undo waits until the server is known to have the routes")
        check(!WorkLoopSupport.undoOffered(available: false, unsupported: []), "[W1 undo] no Undo on the shipped server")
        check(!WorkLoopSupport.undoOffered(available: true, unsupported: ["undo"]), "[W1 undo] no Undo after the server said undo is missing")
        check(WorkLoopSupport.undoOffered(available: true, unsupported: ["seen"]), "[W1 undo] Undo on a server with the routes")
        check(!WorkLoopSupport.undoMissing.contains("—") && WorkLoopSupport.undoMissing.contains("open it in Work"), "[W1 undo] says where to go instead")
    }

    // P-W5, P-W4, P-B2
    static func cadenceChecks() {
        check(RefreshCadence.seconds(panelVisible: true, activityOnScreen: false, locked: false, recording: false) == 12, "[W5 cadence] the panel open: 12 s")
        check(RefreshCadence.seconds(panelVisible: false, activityOnScreen: true, locked: false, recording: false) == 12, "[W5 cadence] Activity on screen: 12 s")
        check(RefreshCadence.seconds(panelVisible: false, activityOnScreen: false, locked: false, recording: false) == 60, "[W5 cadence] nothing on screen: 60 s")
        check(RefreshCadence.seconds(panelVisible: true, activityOnScreen: true, locked: true, recording: false) == 60, "[W5 cadence] locked: 60 s")
        check(RefreshCadence.seconds(panelVisible: false, activityOnScreen: false, locked: true, recording: true) == 12, "[W5 cadence] a recording keeps 12 s, even locked")
        check(RefreshCadence.due(last: nil, now: t0, every: 60), "[W5 due] the first tick refreshes")
        check(!RefreshCadence.due(last: t0, now: t0.addingTimeInterval(48), every: 60) && RefreshCadence.due(last: t0, now: t0.addingTimeInterval(59.5), every: 60),
              "[W5 due] 60 s waits for 60 s (a second early counts)")
        check(RefreshCadence.due(last: t0, now: t0.addingTimeInterval(12), every: 12), "[W5 due] 12 s refreshes every tick")
        check(!RefreshCadence.readsExtras(panelVisible: false, activityOnScreen: false, recording: false)
              && RefreshCadence.readsExtras(panelVisible: false, activityOnScreen: false, recording: true)
              && RefreshCadence.readsExtras(panelVisible: true, activityOnScreen: false, recording: false), "[W5 extras] orphans and your move only for what is on screen, or a recording")
        check(!PetPause.paused(occluded: false, locked: false, displayAsleep: false), "[W4 pause] a visible pet animates")
        check(PetPause.paused(occluded: true, locked: false, displayAsleep: false) && PetPause.paused(occluded: false, locked: true, displayAsleep: false)
              && PetPause.paused(occluded: false, locked: false, displayAsleep: true), "[W4 pause] covered, locked or asleep: paused")
        let running = Array(TodayHome.frameEntries(from: t0, paused: false).prefix(3))
        check(running == [t0, t0.addingTimeInterval(30), t0.addingTimeInterval(60)], "[B2 clock] every 30 s on screen", "\(running)")
        let paused = Array(TodayHome.frameEntries(from: t0, paused: true).prefix(3))
        check(paused == [t0], "[B2 clock] off screen: one entry, then none", "\(paused)")
    }

    // W2, W3, W11
    static func record(_ server: String, rounds: [[String: JSONValue]]) -> Data {
        try! JSONEncoder().encode(JSONValue.object(["workID": .string("task:quilt:abc"), "serverID": .string(server), "draft": .string(""),
                                                    "rounds": .array(rounds.map(JSONValue.object))]))
    }
    static func boardCountChecks() {
        let queued: [String: JSONValue] = ["state": .string("Ready to send"), "assignments": .array([.object(["state": .string("Queued")]), .object(["state": .string("Queued")]), .object(["state": .string("Sent")])])]
        let lens: [String: JSONValue] = ["state": .string("Ready to send"), "origin": .string("glasses"), "assignments": .array([.object(["state": .string("Not sent")])])]
        let lensSent: [String: JSONValue] = ["state": .string("Delivered"), "origin": .string("glasses"), "assignments": .array([])]
        let data = record("srv-1", rounds: [queued, lens, lensSent])
        guard let row = WorkChatBoardCounts.count(data, server: "srv-1") else { return check(false, "[W2 count] a history file counts") }
        check(row.workID == "task:quilt:abc" && row.count.queued == 2 && row.count.fromGlasses == 1, "[W2 count] queued assignments and plans from the glasses waiting", "\(row.count)")
        check(row.count.line == "Queued 2, From glasses 1", "[W2 line] the card's line", row.count.line ?? "nil")
        check(WorkChatBoardCounts.count(data, server: "srv-2") == nil, "[W2 count] another server's history is not counted")
        check(WorkChatBoardCounts.count(Data("{}".utf8), server: "srv-1") == nil, "[W2 count] not a history file")
        check(WorkChatBoardCount().line == nil && WorkChatBoardCount(queued: 0, fromGlasses: 0, needsPlan: 2, notSent: 1).isEmpty, "[W2 line] nothing queued or from glasses: no line")
        check(WorkChatBoardCount(queued: 1).line == "Queued 1" && WorkChatBoardCount(fromGlasses: 3).line == "From glasses 3", "[W2 line] one part alone")
        let before = WorkChatBoardCount(queued: 2)
        let stale = WorkChatBoardCounts.notice(before: before, after: WorkChatBoardCount(needsPlan: 1), title: "Pricing page QA pass")
        check(stale?.body.contains("needs a new plan") == true && stale?.body.contains("“Pricing page QA pass”") == true, "[W2 notice] queued work that needs a new plan says so", stale?.body ?? "nil")
        let unsent = WorkChatBoardCounts.notice(before: before, after: WorkChatBoardCount(notSent: 1), title: "Pricing page QA pass")
        check(unsent?.body.contains("was not sent") == true, "[W2 notice] queued work not sent says so", unsent?.body ?? "nil")
        check(WorkChatBoardCounts.notice(before: before, after: WorkChatBoardCount(queued: 1), title: "x") == nil, "[W2 notice] a send that went out is not this notice")
        check(WorkChatBoardCounts.notice(before: WorkChatBoardCount(needsPlan: 1), after: WorkChatBoardCount(needsPlan: 1), title: "x") == nil, "[W2 notice] an old stale round is not noticed again")
        let glasses = WorkChatBoardCounts.lensNotice(roundID: "lr_1", title: "Footer copy")
        check(glasses.key == "lens-round-lr_1" && glasses.body.contains("from your glasses") && glasses.body.contains("“Footer copy”"), "[W11 notice] a plan from the glasses says so, once per round")
        for text in [stale?.body ?? "", unsent?.body ?? "", glasses.body] { check(!text.contains("—") && !text.contains("→"), "[copy] no em dash or arrow", text) }
    }

    // W15
    static func roundCapChecks() {
        check(!WorkLensPlans.isFull(rounds: 99) && WorkLensPlans.isFull(rounds: 100) && WorkLensPlans.isFull(rounds: 101), "[W15 cap] full at 100 rounds")
        check(WorkLensPlans.notSavedReason(rounds: 100) == WorkLensPlans.historyFull && WorkLensPlans.notSavedReason(rounds: 3) == WorkLensPlans.notInHistory,
              "[W15 lens] the lens hears why: full, or not saved")
        check(WorkLensPlans.historyFull.contains("100") && WorkLensPlans.fullLine.contains("100"), "[W15 words] the cap is named")
    }

    // W8, W9
    static func cueLimitChecks() {
        check(CueVerdicts.limitLine(CueVerdicts.MeetingCount(cues: 12, cap: 12), limits: nil) == "This meeting reached its limit of 12 cues. Cues start again in your next meeting.",
              "[W8 meeting] the meeting's cap, and when it lifts")
        check(CueVerdicts.limitLine(CueVerdicts.MeetingCount(cues: 3, cap: 12), limits: nil) == nil, "[W8 meeting] under the cap: nothing")
        var limits = LiveCuesLimits()
        limits.values[.dailyWriterCalls] = LiveCuesLimit(value: 25, source: nil, locked: false, min: nil, max: nil)
        limits.usage = LiveCuesUsage(cues: 9, writerCalls: 25, writerTokensIn: 0, writerTokensOut: 0, jevTokens: 0)
        check(CueVerdicts.limitLine(CueVerdicts.MeetingCount(cues: 3, cap: 12), limits: limits) == "Today's live cue limit of 25 writer calls is used up. Cues start again tomorrow.",
              "[W8 daily] today's limit, and when it lifts")
        limits.usage?.writerCalls = 24
        check(CueVerdicts.limitLine(CueVerdicts.MeetingCount(cues: 3, cap: 12), limits: limits) == nil, "[W8 daily] under today's limit: nothing")
        limits.values[.dailyWriterCalls] = LiveCuesLimit(value: 0, source: nil, locked: false, min: nil, max: nil)
        limits.usage?.writerCalls = 400
        check(CueVerdicts.limitLine(CueVerdicts.MeetingCount(cues: 3, cap: nil), limits: limits) == nil, "[W8 daily] a limit of 0 is off, never reached")
        check(CueVerdicts.emptyLine(polls: true, cuesOn: false).contains("Live cues is off"), "[W8 empty] Live cues off at the start says so")
        check(CueVerdicts.emptyLine(polls: true, cuesOn: true) == "No cues yet in this meeting." && CueVerdicts.emptyLine(polls: false, cuesOn: nil) == "No cues were shown in this meeting.",
              "[W8 empty] otherwise the old words")
        check(LiveMeeting.reasonWords("budget_exhausted").contains("this week's") && !LiveMeeting.reasonWords("budget_exhausted").contains("today"),
              "[W9 words] the weekly budget is called this week's", LiveMeeting.reasonWords("budget_exhausted"))
        check(LiveMeeting.reasonWords("decision_cap_reached").contains("start again"), "[W9 words] a limit says when it lifts")
        check(LiveMeeting.needsDecisionKey(MacLiveCuesArm(armed: false, reason: "decision_not_configured"))
              && LiveMeeting.needsDecisionKey(MacLiveCuesArm(armed: false, reason: "jev_not_configured"))
              && !LiveMeeting.needsDecisionKey(MacLiveCuesArm(armed: false, reason: "master_flag_off"))
              && !LiveMeeting.needsDecisionKey(MacLiveCuesArm(armed: true, reason: nil)) && !LiveMeeting.needsDecisionKey(nil),
              "[W9 key] only a missing key gets the Settings opener")
    }

    // P-W7, N14
    struct Cue: Equatable { let id: String }
    static func liveMeetingChecks() {
        let cues = [Cue(id: "c1"), Cue(id: "c2"), Cue(id: "c3"), Cue(id: "c4")]
        let byTurn = LiveMeeting.cuesByTurn(cues, id: \.id, anchored: [0: ["c2", "c1"], 3: ["c4"]])
        check(byTurn[0] == [Cue(id: "c1"), Cue(id: "c2")] && byTurn[3] == [Cue(id: "c4")] && byTurn[1] == nil, "[W7 lookup] each turn's cues, in the history's order", "\(byTurn)")
        check(!byTurn.values.flatMap { $0 }.contains(Cue(id: "c3")), "[W7 lookup] a cue the anchoring did not place is left out, as before")
        var gate = LiveMeetingPreviewGate()
        for n in 0..<LiveMeetingPreviewGate.breakerFailures {
            _ = gate.begin(chunkIndex: n, bytes: 64_000, now: t0.addingTimeInterval(Double(n) * 3)); gate.finish(answered: false)
        }
        check(!gate.mayPost(now: t0.addingTimeInterval(30)), "[N14 breaker] paused after three failures")
        check(gate.mayPost(now: t0.addingTimeInterval(6 + LiveMeetingPreviewGate.breakerPause)), "[N14 breaker] tries again a minute after the last failure")
        check(LiveMeetingPreviewGate().mayPost(now: t0), "[N14 breaker] a fresh gate may post")
    }

    // W4
    static func polishPauseChecks() {
        check(DictationPolishPause.code(.skipped("daily_cap")) == "daily_cap" && DictationPolishPause.code(.fillersOnly("breaker_open", text: "x")) == "breaker_open",
              "[W4 code] the daily cap and the breaker are a pause")
        check(DictationPolishPause.code(.skipped("too_long")) == nil && DictationPolishPause.code(.failed("helper")) == nil && DictationPolishPause.code(.timeout) == nil,
              "[W4 code] other skips are not a pause")
        check(DictationPolishPause.clears(.applied("x")) && DictationPolishPause.clears(.unchanged) && !DictationPolishPause.clears(.timeout) && !DictationPolishPause.clears(.skipped("daily_cap")),
              "[W4 clear] a polish that ran clears the line")
        check(DictationPolishPause.pill("daily_cap").contains("DAILY LIMIT") && DictationPolishPause.pill("breaker_open").contains("ERRORS"), "[W4 pill] says which")
        check(DictationPolishPause.settingLine("daily_cap").contains("tomorrow") && DictationPolishPause.settingLine("breaker_open").contains("shortly"), "[W4 line] says when it lifts")
        check(DictationPolishPause.shouldFlash(lastFlashedDay: nil, today: "2026-10-22") && DictationPolishPause.shouldFlash(lastFlashedDay: "2026-10-21", today: "2026-10-22")
              && !DictationPolishPause.shouldFlash(lastFlashedDay: "2026-10-22", today: "2026-10-22"), "[W4 once] the pill flashes once a day")
    }

    // W7
    static func stopChecks() {
        let session = "claude:32386d7e-f751-41c5-a185-a0d731416a01"
        let action = WorkOrchestrator.stopAction(state: "Sending", queuedState: "Queued", receiptStatus: "queued", channel: "queue", jobID: nil, sessionID: nil,
                                                 receiptID: "0f2b7c3a-1d4e-4c8b-9a6f-2e5d7c1b3a90", queueSessionID: session)
        check(action == .cancelQueued(provider: "claude", threadID: "32386d7e-f751-41c5-a185-a0d731416a01", clientTurnID: "0f2b7c3a-1d4e-4c8b-9a6f-2e5d7c1b3a90"),
              "[W7 stop] a queued turn is taken out of its session's queue", "\(action)")
        if case .unavailable = WorkOrchestrator.stopAction(state: "Sending", queuedState: "Queued", receiptStatus: "queued", channel: "queue", jobID: nil, sessionID: nil) {} else {
            check(false, "[W7 stop] no session known yet: it says so")
        }
        check(WorkOrchestrator.queueCancelLine(state: "cancelled").stopped && !WorkOrchestrator.queueCancelLine(state: "already_delivering").stopped
              && !WorkOrchestrator.queueCancelLine(state: "unknown_turn").stopped && !WorkOrchestrator.queueCancelLine(state: "").stopped,
              "[W7 stop] only cancelled stopped it")
        check(WorkOrchestrator.stopHelp(action).contains("queue"), "[W7 stop] its help says what Stop does")
    }

    // W5, W12
    static func todayRunChecks() {
        check(TodayHome.workRunSession(id: "r1", receipts: [("r0", "claude:a"), ("r1", "claude:b")]) == "claude:b", "[W5 open] a run opens its own session")
        check(TodayHome.workRunSession(id: "", receipts: [("", "claude:a")]) == nil && TodayHome.workRunSession(id: "r1", receipts: [("r1", nil)]) == nil,
              "[W5 open] no id or no session yet: Sessions as before")
        var input = TodayHome.RunInputs()
        input.now = t0
        input.workRuns = [TodayHome.WorkRun(id: "r1", title: "Prep: Northwind renewal", sessionID: nil, jobIDs: ["r1", "qj_9"], startedAt: t0.addingTimeInterval(-120), jobID: "qj_9")]
        input.finished = [TodayHome.Finished(id: "claude:p1", title: "Prep: Design review", provider: "claude", finishedAt: t0.addingTimeInterval(-300), openLabel: "Open result")]
        let running = TodayHome.inFlight(input)
        check(running.first { $0.id == "work:r1" }?.stopJobID == "qj_9", "[W5 stop] a Work run's row carries its job for Stop")
        let finished = TodayHome.finishedRows(input)
        check(finished.first?.openLabel == "Open result" && finished.first?.open == .inSessions("claude:p1"), "[W5 finished] a run from Today comes back with Open result")
        var plain = input; plain.finished = [TodayHome.Finished(id: "claude:p2", title: "x", provider: "claude", finishedAt: t0.addingTimeInterval(-60))]
        check(TodayHome.finishedRows(plain).first?.openLabel == "In Sessions", "[W5 finished] other finished rows keep In Sessions")
        let named = TodayHome.LastNaming(name: "Priya Shah", undo: "b1", at: t0)
        check(TodayHome.showsNamed(named, now: t0.addingTimeInterval(30)) && !TodayHome.showsNamed(named, now: t0.addingTimeInterval(TodayHome.namedLineSeconds + 1))
              && !TodayHome.showsNamed(named, now: t0.addingTimeInterval(-5)), "[W12 named] Named X. Undo shows for two minutes")
    }

    // P-B1
    static func sessionStampChecks() {
        for stamp in ["2026-10-22T19:41:16Z", "2026-10-22T19:41:16.123Z", " 2026-10-22T19:41:16+00:00 "] {
            let old: Date? = {
                let trimmed = stamp.trimmingCharacters(in: .whitespacesAndNewlines)
                let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = a.date(from: trimmed) { return d }
                let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
                return b.date(from: trimmed)
            }()
            check(old != nil && ClaudeSession.parseStamp(stamp) == old, "[B1 stamp] the shared formatters read what the two new ones did", stamp)
        }
        check(ClaudeSession.parseStamp("") == nil && ClaudeSession.parseStamp("yesterday") == nil, "[B1 stamp] nothing to read: nil")
    }

    // Tier 2: W6 Stop on reviewed rounds, W16 a discarded capture stays gone
    static func tierTwoChecks() {
        let job = WorkOrchestrator.StopAction.cancelJob("qj_1")
        let turn = WorkOrchestrator.StopAction.cancelTurn(provider: "claude", threadID: "t")
        let queued = WorkOrchestrator.StopAction.cancelQueued(provider: "claude", threadID: "t", clientTurnID: "c")
        for action in [job, turn, queued] {
            check(WorkOrchestrator.stopOffered(action, sentWithoutReview: false) == action, "[W6 stop] a running assignment of a reviewed round has Stop", "\(action)")
            check(WorkOrchestrator.stopOffered(action, sentWithoutReview: true) == action, "[W6 stop] and of a round sent without review", "\(action)")
        }
        check(WorkOrchestrator.stopOffered(.unqueue, sentWithoutReview: false) == nil && WorkOrchestrator.stopOffered(.unqueue, sentWithoutReview: true) == .unqueue,
              "[W6 stop] an unsent row's Stop only on rounds sent without review")
        check(WorkOrchestrator.stopOffered(.unavailable("x"), sentWithoutReview: false) == nil && WorkOrchestrator.stopOffered(.none, sentWithoutReview: true) == nil,
              "[W6 stop] no cannot-stop line on a reviewed round, and nothing to stop is no Stop")
        let rows = ["mac_1", "mac_2", "meeting_3"].compactMap { StrandedCapture(.object(["sessionId": .string($0), "chunks": .number(3)])) }
        check(rows.count == 3 && StrandedCapture.shown(rows, discarded: ["mac_2"]).map(\.sessionId) == ["mac_1", "meeting_3"],
              "[W16 discard] a capture discarded here is not offered again")
        check(StrandedCapture.shown(rows, discarded: []).count == 3, "[W16 discard] nothing discarded: every row")
    }

    // Miles 2026-10-22 21:11: the Fix a word panel inside the screen, and Learn from my edits in COS's own fields
    static func milesChecks() {
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)   // a visible frame above the Dock
        let size = CGSize(width: 360, height: 420)
        func inside(_ r: CGRect) -> Bool { r.minX >= screen.minX + 8 && r.maxX <= screen.maxX - 8 && r.minY >= screen.minY + 8 && r.maxY <= screen.maxY - 8 }
        let bottom = DictationOverlayFrame.place(size: size, caret: nil, screen: screen)
        check(inside(bottom) && bottom.minY == screen.minY + 8 && abs(bottom.midX - screen.midX) <= 1, "[fix frame] no caret: bottom centre, inside", "\(bottom)")
        let nearBottom = DictationOverlayFrame.place(size: size, caret: CGRect(x: 700, y: 60, width: 2, height: 18), screen: screen)
        check(inside(nearBottom) && nearBottom.minY >= 78, "[fix frame] a caret near the bottom: above it, inside", "\(nearBottom)")
        let nearTop = DictationOverlayFrame.place(size: size, caret: CGRect(x: 700, y: 900, width: 2, height: 18), screen: screen)
        check(inside(nearTop) && nearTop.maxY <= 900 - 8, "[fix frame] a caret near the top: below it, inside", "\(nearTop)")
        let nearLeft = DictationOverlayFrame.place(size: size, caret: CGRect(x: 4, y: 600, width: 2, height: 18), screen: screen)
        check(inside(nearLeft) && nearLeft.minX == screen.minX + 8, "[fix frame] a caret at the left edge: kept inside", "\(nearLeft)")
        let nearRight = DictationOverlayFrame.place(size: size, caret: CGRect(x: 1508, y: 600, width: 2, height: 18), screen: screen)
        check(inside(nearRight) && nearRight.maxX == screen.maxX - 8, "[fix frame] a caret at the right edge: kept inside", "\(nearRight)")
        let tall = DictationOverlayFrame.place(size: CGSize(width: 360, height: 2000), caret: nil, screen: screen)
        check(inside(tall) && tall.height == screen.height - 16, "[fix frame] taller than the screen: the screen's height", "\(tall)")
        let other = CGRect(x: 1512, y: -300, width: 1920, height: 1055)   // a second screen, below and to the right
        let there = DictationOverlayFrame.place(size: size, caret: CGRect(x: 3420, y: -290, width: 2, height: 18), screen: other)
        check(there.minX >= other.minX + 8 && there.maxX <= other.maxX - 8 && there.minY >= other.minY + 8 && there.maxY <= other.maxY - 8,
              "[fix frame] on another screen, inside that screen", "\(there)")
        let field = "Ask Sakolik about the renewal"
        check(DictationOwnField.snapshot(text: field, selection: NSRange(location: 4, length: 7)) == DictationFieldSnapshot(characters: 29, location: 4, length: 7),
              "[own learn] the view's count and caret, in UTF-16 units")
        check(DictationOwnField.read(field, location: 4, length: 7) == "Sakolik" && DictationOwnField.read("é Sokolic", location: 2, length: 7) == "Sokolic",
              "[own learn] a bounded slice in UTF-16 units")
        check(DictationOwnField.read(field, location: 25, length: 10) == nil && DictationOwnField.read(field, location: -1, length: 2) == nil,
              "[own learn] outside the text: nil")
        check(DictationEditLearning.eligibility(mode: .automatic, secure: false, terminal: false, electron: false, chromium: false, setterWorked: true) == .learn
              && DictationEditLearning.eligibility(mode: .off, secure: false, terminal: false, electron: false, chromium: false, setterWorked: true) == .skip("off"),
              "[own learn] COS's own view is native: it learns under the same rules, and Off still stops it")
    }

    // Performance audit note: the hidden Today loop
    static func tickLoopChecks() async {
        var clock = t0
        var waits: [TimeInterval] = []
        var visible = true
        await TodayTickLoop.run(now: { clock }, visible: { visible }, ready: { true }, tick: {}, wait: { seconds in
            waits.append(seconds); clock = clock.addingTimeInterval(seconds)
            if waits.count == 3 { visible = false }
            return waits.count < 8
        })
        check(waits.prefix(3).allSatisfy { $0 == TodayTickLoop.step } && waits.dropFirst(3).allSatisfy { $0 == TodayTickLoop.hiddenStep },
              "[tick] on screen every second, off screen every 5 s", "\(waits)")
    }
}
