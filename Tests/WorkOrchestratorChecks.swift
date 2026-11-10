import Foundation

/// 0.5.333 Work orchestrator, pure rules (compiled alone with Sources/WorkOrchestrator.swift by Tests/run-work-orchestrator.sh).
@main struct WorkOrchestratorChecks {
    static func check(_ ok: Bool, _ name: String) { if !ok { print("FAIL " + name); exit(1) }; passed += 1 }
    nonisolated(unsafe) static var passed = 0
    static func main() {
        let card = "task:quilt:420a0114f1a9", sbu = "claude:32386d7e-f751-41c5-a185-a0d731416a01", growth = "codex:01a1384c-0b2e-7a10-9c3e-5d6f7a8b9c0d"
        let now = Date(timeIntervalSince1970: 1_792_545_000)
        // Snapshot: bounded, newest first, Guardian rows out, no live block when the list could not be read.
        let live = [WorkOrchestrator.LiveRow(id: sbu, title: "2026 SBU", status: "running", updatedAt: nil, busy: true, waitingOnUser: false, appOwned: false, summary: ""),
                    WorkOrchestrator.LiveRow(id: "codex:01a1592e-3bd1-7a71-8e99-140d21c9f1dd", title: "Guardian review", status: "", updatedAt: nil, busy: false, waitingOnUser: false, appOwned: false, summary: "")]
        let receipts = (0..<5).map { WorkOrchestrator.Receipt(id: "r\($0)", workID: card, mode: "fork", provider: "claude", sessionID: nil, sourceSessionID: sbu, forkChildID: $0 == 4 ? "claude:0bc093f2-0000-4000-8000-000000000001" : nil, status: "delivered", createdAt: Double($0)) }
        let snap = WorkOrchestrator.snapshot(links: [.init(sessionID: sbu, workID: card, at: 10)], receipts: receipts, live: live, liveCheckedAt: now, controlVersion: "0.5.333", now: now)
        let rows = (snap["live"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        check(rows.map { $0["id"] as? String } == [sbu], "Guardian review rows never reach the server")
        let sent = snap["receipts"] as? [[String: Any]] ?? []
        check(sent.first?["id"] as? String == "r4" && sent.first?["forkChildID"] as? String == "claude:0bc093f2-0000-4000-8000-000000000001", "receipts go newest first, with the fork child")
        check(sent.last?["forkChildID"] is NSNull && sent.last?["sessionID"] is NSNull, "a missing id is JSON null, never left out")
        check((try? JSONSerialization.data(withJSONObject: snap)) != nil, "the snapshot is JSON")
        let noList = WorkOrchestrator.snapshot(links: [], receipts: [], live: nil, liveCheckedAt: nil, controlVersion: "x", now: now)
        check(noList["live"] is NSNull, "an unread session list is sent as unknown, never as an empty list")
        check(WorkOrchestrator.isGuardian(id: "codex:x", title: "Anything", summary: "The following is the Codex agent history whose request action") && !WorkOrchestrator.isGuardian(id: "claude:x", title: "Guardian review", summary: ""), "Guardian rows are Codex rows by title or summary")

        func row(_ id: String, live: Bool = true, reason: String? = nil, forkable: Bool = true) -> WorkOrchestrator.Row {
            .init(id: id, title: "T", summary: "", status: "idle", discoveredBy: ["link"], linked: true, member: true, lastTouchedCard: nil, lastActivity: nil, live: live, busy: false, pickup: "note", available: reason == nil, reason: reason, forkable: forkable)
        }
        // 0.5.386 (T5): the server's parseSnapshot refused the WHOLE snapshot for one live row by a short id
        // (`claude:deadbeef`, a running CLI session from the live list), so Plan failed on every card. Left out and counted.
        let short = WorkOrchestrator.LiveRow(id: "claude:deadbeef", title: "CLI", status: "running", updatedAt: nil, busy: true, waitingOnUser: false, appOwned: false, summary: "")
        let emoji = String(repeating: "\u{1F600}", count: 151) // 302 UTF-16 units, 151 Swift characters
        let titled = WorkOrchestrator.LiveRow(id: sbu.uppercased().replacingOccurrences(of: "CLAUDE", with: "claude"), title: emoji, status: "idle\u{0007}", updatedAt: "2026-11-09T22:00:00Z", busy: false, waitingOnUser: false, appOwned: false, summary: "a\u{0001}b\tc")
        let checked = WorkOrchestrator.checkedSnapshot(links: [.init(sessionID: "claude:deadbeef", workID: card, at: 5), .init(sessionID: sbu, workID: "not a card", at: 6), .init(sessionID: sbu, workID: card, at: 7)],
                                                       receipts: [.init(id: "r9", workID: card, mode: "teleport", provider: "claude", sessionID: nil, sourceSessionID: nil, forkChildID: nil, status: "x", createdAt: 1),
                                                                  .init(id: "r8", workID: card, mode: "newSession", provider: "claude", sessionID: "claude:deadbeef", sourceSessionID: nil, forkChildID: nil, status: "delivered", createdAt: 2)],
                                                       live: [short, titled], liveCheckedAt: now, controlVersion: "0.5.386", now: now)
        let liveRows = (checked.body["live"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        check(liveRows.map { $0["id"] as? String } == [sbu] && checked.droppedLive == 1, "[T5] a live row by a short id is left out and counted; the full one goes, lowercased")
        let sentTitle = liveRows.first?["title"] as? String ?? ""
        check(sentTitle.utf16.count == 300 && sentTitle.count == 150 && emoji.count == 151, "[T5] a title is clamped to 300 UTF-16 units (JavaScript length), never split inside an emoji: \(sentTitle.utf16.count)")
        check(liveRows.first?["status"] as? String == "idle" && liveRows.first?["summary"] as? String == "ab\tc", "[T5] control characters the server refuses are dropped; a tab stays")
        let sentLinks = checked.body["links"] as? [[String: Any]] ?? []
        check(sentLinks.count == 1 && sentLinks.first?["at"] as? Double == 7 && checked.droppedLinks == 2, "[T5] a link by a short id or to a bad card is left out")
        let sentReceipts = checked.body["receipts"] as? [[String: Any]] ?? []
        check(sentReceipts.map { $0["id"] as? String } == ["r8"] && sentReceipts.first?["sessionID"] is NSNull && checked.droppedReceipts == 1, "[T5] a receipt with an unknown mode is left out; a short session id it names goes as null")
        check(WorkOrchestrator.validSessionID(sbu) && WorkOrchestrator.validSessionID(sbu.uppercased().replacingOccurrences(of: "CLAUDE", with: "claude")) && !WorkOrchestrator.validSessionID("claude:deadbeef")
              && !WorkOrchestrator.validSessionID("ollama:32386d7e-f751-41c5-a185-a0d731416a01") && !WorkOrchestrator.validSessionID("claude:32386d7e-f751-41c5-a185-a0d731416a0g")
              && WorkOrchestrator.validSessionID("cursor:01a1384c-0b2e-7a10-9c3e-5d6f7a8b9c0e"), "[T5] the server's SID: provider and a whole UUID")
        check(WorkOrchestrator.validWorkID(card) && WorkOrchestrator.validWorkID("meeting:g2:abc") && !WorkOrchestrator.validWorkID("Task:x") && !WorkOrchestrator.validWorkID("task:") && !WorkOrchestrator.validWorkID("task:a\u{0001}"), "[T5] the server's WORK_ID")
        check(WorkOrchestrator.clamp("\u{1F600}", 1) == "" && WorkOrchestrator.clamp("abc", 2) == "ab" && WorkOrchestrator.clamp("a\r\nb", 9) == "a\r\nb", "[T5] clamp counts UTF-16 units at whole characters")
        check(WorkOrchestrator.snapshot(links: [], receipts: [], live: [short], liveCheckedAt: now, controlVersion: "x", now: now)["live"].map { (($0 as? [String: Any])?["rows"] as? [Any])?.isEmpty == true } == true, "[T5] the plain snapshot filters too")

        // 0.5.386: an empty card. Providers out of usage are never offered; Claude unless its usage is low; Opus first.
        func usage(_ p: String, _ state: String) -> WorkOrchestrator.Usage { .init(provider: p, state: state, headroomPct: nil, resetsAt: nil, ageSec: nil, source: "probe", plan: nil, stale: false, note: "") }
        check(WorkOrchestrator.newSessionProviders(available: ["claude", "codex"], usage: []) == ["claude", "codex"]
              && WorkOrchestrator.newSessionProviders(available: ["claude", "codex"], usage: [usage("claude", "exhausted")]) == ["codex"]
              && WorkOrchestrator.newSessionProviders(available: ["claude"], usage: [usage("claude", "low")]) == ["claude"], "[provider] a used-up provider is never offered")
        check(WorkOrchestrator.emptyCardProvider(offered: ["claude", "codex"], usage: [usage("codex", "low")]) == "claude", "[provider] Claude by default")
        check(WorkOrchestrator.emptyCardProvider(offered: ["claude", "codex"], usage: [usage("claude", "low")]) == "codex", "[provider] Codex when Claude's usage is low")
        check(WorkOrchestrator.emptyCardProvider(offered: ["codex"], usage: [usage("claude", "exhausted")]) == "codex" && WorkOrchestrator.emptyCardProvider(offered: ["claude"], usage: [usage("claude", "low")]) == "claude"
              && WorkOrchestrator.emptyCardProvider(offered: [], usage: []) == nil, "[provider] Codex when Claude is used up; low Claude when there is nothing else; none when nothing is offered")
        check(WorkOrchestrator.preferredModel(provider: "claude", models: [("sonnet", true), ("opus", true)]) == "opus" && WorkOrchestrator.preferredModel(provider: "claude", models: [("sonnet", true), ("claude-opus-4", true)]) == "claude-opus-4"
              && WorkOrchestrator.preferredModel(provider: "claude", models: [("sonnet", true), ("opus", false)]) == "sonnet" && WorkOrchestrator.preferredModel(provider: "codex", models: [("codex-frontier", true)]) == "codex-frontier"
              && WorkOrchestrator.preferredModel(provider: "codex", models: [("x", false)]) == nil, "[provider] Claude starts on Opus when it is available")
        check(WorkOrchestrator.nothingToContinue(rows: [], automaticIDs: [], forkProviders: ["claude", "codex"]), "[empty] no rows is an empty card")
        check(!WorkOrchestrator.nothingToContinue(rows: [row(sbu)], automaticIDs: [sbu], forkProviders: []), "[empty] a row that can Continue is not")
        check(!WorkOrchestrator.nothingToContinue(rows: [row(growth, live: false, reason: "not_in_session_list")], automaticIDs: [], forkProviders: ["claude", "codex"]), "[empty] a row that can Fork is not")
        check(WorkOrchestrator.nothingToContinue(rows: [row(growth, live: false, reason: "not_in_session_list", forkable: false), row("cursor:01a1384c-0b2e-7a10-9c3e-5d6f7a8b9c0e")], automaticIDs: [], forkProviders: ["claude", "codex"]), "[empty] rows that can neither Continue nor Fork leave the card empty")
        check(WorkOrchestrator.oneNewSession([1, 2, 3, 4], isNew: { $0 % 2 == 0 }) == [1, 2, 3], "[empty] at most one New session per round")
        check(WorkOrchestrator.startNewSessionTitle("claude") == "Start a new Claude session with this request" && !WorkOrchestrator.emptyCardNote("codex").contains("\u{2014}") && WorkOrchestrator.emptyCardPhase("codex").contains("Codex"), "[empty] the words Miles asked for, no em dash")

        // Rows: Continue only into a live Claude or Codex row nothing stops; Control's own rule must agree.
        check(WorkOrchestrator.automatic(row(sbu), controlAllows: true), "a live linked Claude row can Continue")
        check(!WorkOrchestrator.automatic(row(sbu), controlAllows: false), "Control's own rule (not app owned) still decides")
        check(!WorkOrchestrator.automatic(row(sbu, live: false), controlAllows: true), "a row outside the session list cannot Continue")
        check(!WorkOrchestrator.automatic(row(growth, reason: "plan_limit"), controlAllows: true), "a provider out of plan usage cannot Continue")
        check(!WorkOrchestrator.automatic(row("cursor:01a1384c-0b2e-7a10-9c3e-5d6f7a8b9c0e"), controlAllows: true), "Cursor never Continues automatically")
        let input = WorkOrchestrator.Input(protocolVersion: 1, workID: card, now: "2026-10-20T21:29:00Z", rows: [row(sbu), row(growth, live: false, reason: "not_in_session_list")], leftOut: [], usage: [], discovered: 2, snapshotAgeSec: 0, liveListAgeSec: 5, logScanComplete: true)
        let planner = WorkOrchestrator.plannerRows(input, controlAllows: { _ in true }, openWork: { $0 == sbu })
        check(planner.map { $0["automatic"] as? Bool } == [true, false] && planner.map { $0["openWork"] as? Bool } == [true, false], "planner rows carry Control's automatic and openWork")
        check(planner[1]["reason"] as? String == "not_in_session_list" && planner[0]["reason"] == nil && planner[0]["lastTouchedCard"] is NSNull, "reasons and nulls as the server's schema wants")
        check(WorkOrchestrator.plannerRows(input, controlAllows: { _ in true }, openWork: nil).allSatisfy { $0["openWork"] == nil }, "openWork only to a server that takes it")

        // Never silent: a plan with no session that can Continue says why.
        check(WorkOrchestrator.emptyExplanation(rows: input.rows, leftOut: [], automaticIDs: [sbu], listFailed: false) == nil, "nothing to say when a session can Continue")
        let why = WorkOrchestrator.emptyExplanation(rows: input.rows, leftOut: [], automaticIDs: [], listFailed: false) ?? ""
        check(why.hasPrefix("COS found 2 sessions for this task, none can take a Continue now") && why.contains("not in the session list just read"), "names the sessions and why: \(why)")
        check(WorkOrchestrator.emptyExplanation(rows: [], leftOut: [], automaticIDs: [], listFailed: true)?.contains("could not be read just now") == true, "says when the list read failed")
        check(WorkOrchestrator.emptyExplanation(rows: [], leftOut: [], automaticIDs: [], listFailed: false)?.hasPrefix("COS found no session for this task") == true, "says when there is none")
        check(WorkOrchestrator.legacyEmptyExplanation(linkedCount: 1, inList: 0, listFailed: false) == "This task's 1 linked session is not in the session list just read, so the planner saw none.", "an older server's empty plan says why too")
        check(WorkOrchestrator.legacyEmptyExplanation(linkedCount: 1, inList: 1, listFailed: false) == nil, "and says nothing when the planner saw one")

        // Assignment kinds and the plan's own targets.
        check(WorkOrchestrator.kind(mode: nil, provider: nil) == .continueSession && WorkOrchestrator.kind(mode: "fork", provider: nil) == .fork
              && WorkOrchestrator.kind(mode: "newSession", provider: "codex") == .newSession("codex") && WorkOrchestrator.kind(mode: "newSession", provider: "cursor") == nil
              && WorkOrchestrator.kind(mode: "teleport", provider: nil) == nil, "assignment kinds")
        let newID = WorkOrchestrator.newSessionID(provider: "claude", receiptID: "abcdef12-0000")
        let ok: (String) -> Bool = { !$0.isEmpty }
        check(WorkOrchestrator.valid(kinds: [(.continueSession, sbu, "a"), (.fork, growth, "b"), (.newSession("claude"), newID, "c")], continueTargets: [sbu], forkTargets: [growth], newProviders: ["claude"], validPrompt: ok), "a plan within its targets is valid")
        check(!WorkOrchestrator.valid(kinds: [(.continueSession, growth, "a")], continueTargets: [sbu], forkTargets: [growth], newProviders: [], validPrompt: ok), "a Continue into a non-automatic row is refused")
        check(!WorkOrchestrator.valid(kinds: [(.fork, sbu, "a")], continueTargets: [sbu], forkTargets: [growth], newProviders: [], validPrompt: ok), "a Fork from a row not marked forkable is refused")
        check(!WorkOrchestrator.valid(kinds: [(.newSession("codex"), newID, "a")], continueTargets: [], forkTargets: [], newProviders: ["claude"], validPrompt: ok), "a New session on a provider not offered is refused")
        check(!WorkOrchestrator.valid(kinds: [(.newSession("claude"), sbu, "a")], continueTargets: [], forkTargets: [], newProviders: ["claude"], validPrompt: ok), "a New session must not name a session")
        check(!WorkOrchestrator.valid(kinds: [(.continueSession, sbu, "a"), (.continueSession, sbu, "b")], continueTargets: [sbu], forkTargets: [], newProviders: [], validPrompt: ok), "targets stay distinct")
        check(!WorkOrchestrator.valid(kinds: Array(repeating: (.newSession("claude"), newID, "a"), count: 4), continueTargets: [], forkTargets: [], newProviders: ["claude"], validPrompt: ok), "at most three")
        check(!WorkOrchestrator.valid(kinds: [(.continueSession, sbu, "")], continueTargets: [sbu], forkTargets: [], newProviders: [], validPrompt: ok), "every prompt is checked")
        check(!WorkOrchestrator.valid(kinds: [(nil, sbu, "a")], continueTargets: [sbu], forkTargets: [], newProviders: [], validPrompt: ok), "an unknown kind is refused")

        // Auto-send per card. Off by default; a card with no choice follows Settings, so the default is today's behaviour.
        check(!WorkOrchestrator.autoSend(workID: card, raw: "", settingDefault: false), "GOLDEN: no card choice and Settings off is off (0.5.332)")
        check(WorkOrchestrator.autoSend(workID: card, raw: "", settingDefault: true), "no card choice follows Settings on")
        let on = WorkOrchestrator.setting(workID: card, on: true, raw: "", settingDefault: false)
        check(WorkOrchestrator.autoSend(workID: card, raw: on, settingDefault: false) && !WorkOrchestrator.autoSend(workID: "task:quilt:000000000000", raw: on, settingDefault: false), "a card's choice is that card's only")
        check(WorkOrchestrator.setting(workID: card, on: false, raw: on, settingDefault: false) == "", "choosing the default removes the card's override")
        let off = WorkOrchestrator.setting(workID: card, on: false, raw: "", settingDefault: true)
        check(!WorkOrchestrator.autoSend(workID: card, raw: off, settingDefault: true), "a card can stay off while Settings is on")
        check(WorkOrchestrator.overrides("not json").isEmpty, "a damaged value reads as no choices")

        // Stop: what it does for each state.
        let q = "Queued"
        check(WorkOrchestrator.stopAction(state: q, queuedState: q, receiptStatus: nil, channel: nil, jobID: nil, sessionID: nil) == .unqueue, "a queued assignment is unqueued")
        check(WorkOrchestrator.stopAction(state: "Not sent", queuedState: q, receiptStatus: nil, channel: nil, jobID: nil, sessionID: nil) == .unqueue, "one not sent yet never goes")
        check(WorkOrchestrator.stopAction(state: "running", queuedState: q, receiptStatus: "running", channel: "job", jobID: "job-1", sessionID: nil) == .cancelJob("job-1"), "a New session's run is cancelled by its job")
        check(WorkOrchestrator.stopAction(state: "running", queuedState: q, receiptStatus: "running", channel: "turn", jobID: nil, sessionID: sbu) == .cancelTurn(provider: "claude", threadID: "32386d7e-f751-41c5-a185-a0d731416a01"), "a Continue's turn is cancelled by its session")
        if case .unavailable = WorkOrchestrator.stopAction(state: "running", queuedState: q, receiptStatus: "running", channel: "fork", jobID: nil, sessionID: nil) {} else { check(false, "a fork in progress says it cannot be stopped here") }
        check(WorkOrchestrator.stopAction(state: "delivered", queuedState: q, receiptStatus: "delivered", channel: "turn", jobID: nil, sessionID: sbu) == .none, "a finished handoff has nothing to stop")
        print("PASS work orchestrator: \(passed) checks (snapshot, 0.5.386 id filter and UTF-16 clamp, empty-card provider rules, rows, never-silent empty plans, assignment kinds, per-card Auto-send golden, Stop)")
    }
}
