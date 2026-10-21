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

        // Rows: Continue only into a live Claude or Codex row nothing stops; Control's own rule must agree.
        func row(_ id: String, live: Bool = true, reason: String? = nil, forkable: Bool = true) -> WorkOrchestrator.Row {
            .init(id: id, title: "T", summary: "", status: "idle", discoveredBy: ["link"], linked: true, member: true, lastTouchedCard: nil, lastActivity: nil, live: live, busy: false, pickup: "note", available: reason == nil, reason: reason, forkable: forkable)
        }
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
        print("PASS work orchestrator: \(passed) checks (snapshot, rows, never-silent empty plans, assignment kinds, per-card Auto-send golden, Stop)")
    }
}
