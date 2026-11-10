import Foundation

/// 0.5.333 Work orchestrator, by execution: the real WorkTaskChatStore and WorkHandoffStore against a fake transport in the
/// shape of the toadstone card on 2026-10-20 (one linked Claude session in the list; the Codex session on the card by
/// handoff history only, outside the list; a Codex Guardian review row in the list). Nothing reaches a provider.
private actor WorkOrchestratorFixture {
    let sbu: String, growth: String, guardian: String
    let orchestrator: Bool
    var rows: [JSONValue]
    var plan: [JSONValue]
    /// 0.5.386: a running CLI session the live list gives by its first 8 characters, as on 2026-11-09.
    var shortSession = false
    var failInput = false
    var usage: [JSONValue] = [.object(["provider": .string("codex"), "state": .string("low"), "headroomPct": .number(8), "resetsAt": .string("2026-10-27T11:51:14.000Z"), "ageSec": .number(60), "source": .string("probe"), "plan": .string("prolite"), "stale": .bool(false), "note": .string("")])]
    private(set) var calls: [String] = []
    private(set) var chatData: [Data] = []
    private(set) var snapshotData: [Data] = []
    private(set) var forks: [String] = []
    private(set) var newJobs: [String] = []
    private(set) var turns: [String] = []
    private(set) var cancels: [[String]] = []
    init(sbu: String, growth: String, guardian: String, orchestrator: Bool, rows: [JSONValue], plan: [JSONValue]) {
        self.sbu = sbu; self.growth = growth; self.guardian = guardian; self.orchestrator = orchestrator; self.rows = rows; self.plan = plan
    }
    func setRows(_ value: [JSONValue]) { rows = value }
    func setPlan(_ value: [JSONValue]) { plan = value }
    func setShortSession(_ value: Bool) { shortSession = value }
    func setFailInput(_ value: Bool) { failInput = value }
    func setUsage(_ value: [JSONValue]) { usage = value }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        let name = args.first ?? ""; calls.append(name)
        var out: [String: JSONValue] = [:]
        let thread = args.firstIndex(of: "--thread-id").map { args[$0 + 1] } ?? ""
        func session(_ id: String, _ title: String) -> JSONValue {
            .object(["id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])), "name": .string(title), "workspace": .string("/tmp/fixture"), "state": .string("recent")])
        }
        switch name {
        case "work-models": out = ["serverInstanceId": .string("orchestrator-fixture"), "models": .array([
            // Sonnet is listed first, so only the 0.5.386 Opus preference starts a Claude New session on Opus.
            .object(["id": .string("claude-sonnet"), "provider": .string("claude"), "title": .string("Claude Sonnet"), "available": .bool(true)]),
            .object(["id": .string("claude-opus"), "provider": .string("claude"), "title": .string("Claude Opus"), "available": .bool(true)]),
            .object(["id": .string("gpt-codex"), "provider": .string("codex"), "title": .string("Codex"), "available": .bool(true)])])]
        case "claude-sessions": out = ["sessions": .array([session(sbu, "2026 SBU /XBU"), session(guardian, "Guardian review")] + (shortSession ? [session("claude:deadbeef", "CLI session")] : []))]
        case "work-chat-capabilities":
            out = ["protocolVersion": .number(1), "planners": .array([.string("sonnet"), .string("opus")]), "efforts": .array([.string("high")])]
            if orchestrator { out["orchestrator"] = .bool(true) }
        case "work-context": out = ["contextText": .string("Toadstone review evidence"), "workRevision": .string(String(repeating: "c", count: 64)),
            "task": .object(["id": .string("420a0114f1a9"), "workIdentity": .string("420a0114f1a9"), "domain": .string("quilt"), "title": .string("Toadstone review"), "text": .string("Toadstone review"), "source": .string("Fixture evidence")])]
        case "work-orchestrator-input":
            if let data { snapshotData.append(data) }
            // As the server's parseSnapshot (7.0.12): one live row or link by an id that is not a full session id refuses the
            // whole snapshot, and the helper turns that into its failure words.
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["snapshot"] as? [String: Any] ?? [:]
            let full = try! NSRegularExpression(pattern: "^(claude|codex|cursor):[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")
            func ok(_ id: Any?) -> Bool { (id as? String).map { full.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false }
            let liveRows = (body["live"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
            if failInput || !liveRows.allSatisfy({ ok($0["id"]) && ($0["title"] as? String ?? "").utf16.count <= 300 }) || !((body["links"] as? [[String: Any]]) ?? []).allSatisfy({ ok($0["sessionID"]) }) {
                throw HelperClientError.commandFailed("COS could not read the session list on this Mac (one session had an id COS cannot use). Server reason: invalid_snapshot, invalid_live_row (HTTP 400).")
            }
            out = ["protocolVersion": .number(1), "workID": .string("task:quilt:420a0114f1a9"), "now": .string("2026-10-20T21:29:00Z"), "rows": .array(rows), "leftOut": .array([]),
                   "usage": .array(usage),
                   "discovered": .number(Double(rows.count)), "snapshotAgeSec": .number(0), "liveListAgeSec": .number(1), "logScanComplete": .bool(true)]
        case "work-chat":
            if let data { chatData.append(data) }
            out = ["protocolVersion": .number(1), "answer": .string("Continue the SBU session; fork Growth for the pilot; start a Claude session for the canaries."), "model": .string("claude:opus"), "effort": .string("high"),
                   "assignments": .array(plan)]
        case "session-recent-replies": throw HelperClientError.commandFailed("Fixture has no session history")
        case "session-chat-attachability": out = ["attachable": .bool(true)]
        case "session-chat-attach": out = ["state": .string("attached"), "bindingId": .string("orchestrator-fixture"), "epoch": .number(1), "boundTo": .string("exact")]
        case "session-chat-send": turns.append(thread); out = ["state": .string("completed")]
        case "session-chat-fork":
            forks.append(thread)
            out = ["state": .string("forked"), "forkSession": session("codex:0bc093f2-0000-4000-8000-00000000f0f0", "Growth fork")]
        case "work-new":
            let job = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let id = job?["clientJobId"] as? String ?? ""
            newJobs.append(job?["model"] as? String ?? "")
            out = ["httpStatus": .number(202), "job": .object(["clientJobId": .string(id), "generation": .number(1), "jobId": .string("job-orchestrator-1"), "status": .string("running"), "provider": .string("claude")])]
        case "work-job-cancel", "session-chat-cancel": cancels.append(args); out = ["httpStatus": .number(202)]
        // Receipt refreshes between sends: the New session is still running; delivered turns stay delivered.
        case "work-job":
            let id = args.firstIndex(of: "--client-job-id").map { args[$0 + 1] } ?? ""
            out = ["job": .object(["clientJobId": .string(id), "generation": .number(1), "jobId": .string("job-orchestrator-1"), "status": .string("running"), "provider": .string("claude")])]
        case "session-chat-turn": out = ["state": .string("completed")]
        case "session-chat-queued": out = ["state": .string("none"), "queued": .array([])]
        case "session-chat-fork-status": out = ["state": .string("forked"), "forkSession": session("codex:0bc093f2-0000-4000-8000-00000000f0f0", "Growth fork")]
        default: preconditionFailure("Orchestrator fixture must not reach \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
    func seen() -> [String] { calls }
}

private func objects(_ data: [Data]) -> [[String: Any]] { data.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
@MainActor func runWorkOrchestratorStoreChecks(root: URL) async throws {
    // Every Control file this check writes (links, chat history, journals) stays under its own scratch home.
    let previous = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"]
    setenv("COS_CONTROL_TEST_HOME", root.appendingPathComponent("orchestrator-home").path, 1)
    defer { if let previous { setenv("COS_CONTROL_TEST_HOME", previous, 1) } else { unsetenv("COS_CONTROL_TEST_HOME") } }
    let sbu = "claude:32386d7e-f751-41c5-a185-a0d731416a01", growth = "codex:01a1384c-0b2e-7a10-9c3e-5d6f7a8b9c0d", guardian = "codex:01a1592e-3bd1-7a71-8e99-140d21c9f1dd"
    let task = TaskRow(.object(["id": .string("420a0114f1a9"), "workIdentity": .string("420a0114f1a9"), "domain": .string("quilt"), "title": .string("Toadstone review"), "text": .string("Toadstone review"), "source": .string("Fixture evidence")]))!
    let card = WorkSource.taskSnapshot(task)
    func row(_ id: String, live: Bool, reason: String?, linked: Bool, found: [String]) -> JSONValue {
        var r: [String: JSONValue] = ["id": .string(id), "title": .string(id.hasPrefix("claude") ? "2026 SBU /XBU" : "Quilt Growth System Evolution"), "summary": .string(""), "status": .string(live ? "recent" : "not in the session list"),
            "discoveredBy": .array(found.map { .string($0) }), "linked": .bool(linked), "member": .bool(true), "lastTouchedCard": .string("2026-10-20T20:31:00.000Z"), "lastActivity": .null,
            "live": .bool(live), "busy": .bool(false), "pickup": .string("Stopped after a reply."), "available": .bool(reason == nil), "forkable": .bool(true)]
        if let reason { r["reason"] = .string(reason) }
        return .object(r)
    }
    let rows = [row(sbu, live: true, reason: nil, linked: true, found: ["link", "prompt"]), row(growth, live: false, reason: "not_in_session_list", linked: false, found: ["continued", "prompt"])]
    let plan: [JSONValue] = [
        .object(["sessionID": .string(sbu), "prompt": .string("Review the toadstone plan against the SBU work.")]),
        .object(["mode": .string("fork"), "sessionID": .string(growth), "prompt": .string("Pick up the pilot decision from the review brief.")]),
        .object(["mode": .string("newSession"), "provider": .string("claude"), "prompt": .string("Draft the C5 canary steps.")])]
    UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey)
    defer { UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey) }
    func setup(_ name: String, orchestrator: Bool = true) async throws -> (WorkOrchestratorFixture, WorkHandoffStore, WorkTaskChatStore) {
        let fixture = WorkOrchestratorFixture(sbu: sbu, growth: growth, guardian: guardian, orchestrator: orchestrator, rows: rows, plan: plan)
        let store = WorkHandoffStore(storageURL: root.appendingPathComponent("orchestrator-" + name + ".json"), transport: { args, data in try await fixture.run(args, data) })
        precondition(store.confirmSessionCard(sessionID: sbu, source: card))
        await store.refresh()
        let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: card, handoff: store)
        await chat.loadPlanners(handoff: store, retryDelay: .zero)
        return (fixture, store, chat)
    }

    // 1. The toadstone card: the planner sees both sessions, the Guardian row never, and the input says what time it is.
    do {
        let (fixture, store, chat) = try await setup("toadstone")
        precondition(chat.orchestratorOffered, "a 6.83.0 server offers the orchestrator")
        chat.setDraft("Can you look into the toadstone plan?")
        await chat.send(source: card, handoff: store, planner: "opus", effort: "high")
        let bodies = objects(await fixture.chatData), snapshots = objects(await fixture.snapshotData), seen = await fixture.seen()
        precondition(chat.error == nil, "planned: \(chat.error ?? "")")
        let body = bodies.last!
        let sessions = body["sessions"] as? [[String: Any]] ?? []
        precondition(sessions.compactMap { $0["id"] as? String } == [sbu, growth], "the planner sees both of the card's sessions: \(sessions.compactMap { $0["id"] as? String })")
        precondition(sessions.map { $0["automatic"] as? Bool } == [true, false], "Continue only into the live linked session")
        precondition(body["orchestrator"] as? Bool == true && (body["now"] as? String)?.isEmpty == false && (body["newSessionProviders"] as? [String]) == ["claude", "codex"]
            && ((body["usage"] as? [[String: Any]])?.first?["state"] as? String) == "low", "the plan carries the time, usage and the providers a New session may use")
        let snap = snapshots.last?["snapshot"] as? [String: Any] ?? [:]
        let live = ((snap["live"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        precondition(live == [sbu], "the Guardian review row never reaches the server: \(live)")
        precondition((snap["links"] as? [[String: Any]])?.first?["sessionID"] as? String == sbu, "the link is in the snapshot")
        let input = seen.lastIndex(of: "work-orchestrator-input")!
        precondition(input > 0 && seen[input - 1] == "claude-sessions" && seen[input + 1] == "work-chat", "the session list is read again right before the input, and the plan right after it: \(seen)")
        let round = chat.record!.rounds.last!
        precondition(round.state == "Ready to send" && round.sessionsNote == nil && round.orchestrated?.map(\.id) == [sbu, growth] && round.assignments.count == 3,
                     "the round keeps the plan's targets and nothing claims there are no sessions: \(round.state) \(round.sessionsNote ?? "")")
        precondition(round.assignments.map(\.mode) == [nil, "fork", "newSession"] && WorkOrchestrator.isNewSessionID(round.assignments[2].sessionID), "assignment kinds survive")
        precondition(chat.assignmentTitle(round.assignments[1], round: round, handoff: store, source: card) == "Fork of Quilt Growth System Evolution"
            && chat.assignmentTitle(round.assignments[2], round: round, handoff: store, source: card) == "New Claude session", "each assignment names what it will do")
        // Reviewed send (Auto-send off): nothing went until Send all.
        precondition(store.receipts.isEmpty, "a plan sends nothing by itself with Auto-send off")
        precondition(chat.stopAction(roundID: round.id, assignmentID: round.assignments[0].receiptID, handoff: store) == nil, "no Stop on a round that waits for review")
        await chat.sendAll(roundID: round.id, source: card, handoff: store)
        let turns = await fixture.turns, forks = await fixture.forks, jobs = await fixture.newJobs
        precondition(turns == [String(sbu.split(separator: ":")[1])] && forks == [String(growth.split(separator: ":")[1])] && jobs == ["claude-opus"],
                     "Continue, Fork and New session each go through submit once: \(turns) \(forks) \(jobs)")
        let fork = store.receipts.first { $0.mode == .fork }!
        precondition(fork.forkChildID == "codex:0bc093f2-0000-4000-8000-00000000f0f0" && fork.sourceSessionID == growth, "the fork's child is journaled")
        precondition(store.receipts.first { $0.mode == .newSession }?.orchestrationRunID == round.id, "the New session belongs to the round")
    }

    // 2. Auto-send: planned and sent without review; each running assignment has a Stop that reaches the server.
    do {
        let (fixture, store, chat) = try await setup("auto")
        await fixture.setPlan([plan[0], plan[2]])
        chat.setDraft("Go")
        await chat.send(source: card, handoff: store, planner: "opus", effort: "high", autoSend: true)
        let round = chat.record!.rounds.last!
        precondition(round.sentWithoutReview == true && store.receipts.count == 2, "Auto-send sends every assignment without the review click: \(round.state)")
        let newSession = round.assignments[1]
        precondition(chat.stopAction(roundID: round.id, assignmentID: newSession.receiptID, handoff: store) == .cancelJob("job-orchestrator-1"), "the running New session can be stopped")
        await chat.stop(roundID: round.id, assignmentID: newSession.receiptID, handoff: store)
        let cancels = await fixture.cancels
        precondition(cancels == [["work-job-cancel", "--job-id", "job-orchestrator-1"]], "Stop cancels that job and nothing else: \(cancels)")
        precondition(chat.stopAction(roundID: round.id, assignmentID: round.assignments[0].receiptID, handoff: store) == nil, "a delivered turn has nothing to stop")
    }

    // 3. Never silent: no session can take a Continue, and the round says why (the planner still plans).
    do {
        let (fixture, store, chat) = try await setup("empty")
        await fixture.setRows([row(growth, live: false, reason: "not_in_session_list", linked: false, found: ["continued"])])
        await fixture.setPlan([plan[2]])
        chat.setDraft("Pick this back up")
        await chat.send(source: card, handoff: store)
        let note = chat.record!.rounds.last!.sessionsNote ?? ""
        precondition(note.hasPrefix("COS found 1 session for this task, none can take a Continue now") && note.contains("Quilt Growth System Evolution"), "the round names the session and why: \(note)")
        await fixture.setRows([])
        chat.setDraft("And now?")
        await chat.send(source: card, handoff: store)
        // 0.5.386: with nothing to pick up, the round says the New session it planned starts on Send.
        precondition(chat.record!.rounds.last!.sessionsNote == WorkOrchestrator.emptyCardNote("claude"), "and says when there is none: \(chat.record!.rounds.last!.sessionsNote ?? "")")
    }

    // 4. An older server (no orchestrator): exactly 0.5.332's body, linked sessions only.
    do {
        let (fixture, store, chat) = try await setup("older", orchestrator: false)
        await fixture.setPlan([plan[0]])
        chat.setDraft("Plan on an older server")
        await chat.send(source: card, handoff: store)
        let body = objects(await fixture.chatData).last!, seen = await fixture.seen()
        precondition(!seen.contains("work-orchestrator-input") && ["orchestrator", "now", "usage", "leftOut", "newSessionProviders"].allSatisfy { body[$0] == nil }, "an older server gets no orchestrator keys")
        let sessions = body["sessions"] as? [[String: Any]] ?? []
        precondition(sessions.compactMap { $0["id"] as? String } == [sbu] && sessions.allSatisfy { Set($0.keys).isSubset(of: ["id", "title", "summary", "status", "automatic", "openWork"]) }, "only the linked session, with 0.5.332's keys")
        precondition(chat.record!.rounds.last!.orchestrated == nil && chat.record!.rounds.last!.sessionsNote == nil, "no orchestrator state on an older server's round")
    }
    // 5. 0.5.386 (T5 by execution): a running CLI session listed by a short id no longer fails every plan. The fixture
    // refuses a snapshot as the 7.0.12 server does, so this round only plans when Control leaves that row out.
    do {
        let (fixture, store, chat) = try await setup("short-id")
        await fixture.setShortSession(true)
        await store.refreshActivity()
        precondition(store.observedSessions().contains { $0.id == "claude:deadbeef" }, "the fixture lists the short-id session as the live list does")
        chat.setDraft("Plan with a CLI session running")
        await chat.send(source: card, handoff: store)
        let snap = objects(await fixture.snapshotData).last?["snapshot"] as? [String: Any] ?? [:]
        let live = ((snap["live"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        precondition(chat.error == nil && chat.record!.rounds.last!.state == "Ready to send", "[short id] Plan works with a short-id session running: \(chat.error ?? "")")
        precondition(!live.contains("claude:deadbeef") && live.contains(sbu), "[short id] the short-id row is left out of the snapshot, the rest kept: \(live)")
    }

    // 6. 0.5.386 (T6): a plan that failed before the planner answered gets Plan again, which reruns THAT round in place.
    do {
        let (fixture, store, chat) = try await setup("plan-again")
        await fixture.setFailInput(true)
        // The card's history carries the earlier sections' rounds (one history per card and server): count from here.
        let before = chat.record!.rounds.count
        chat.setDraft("Pick up the toadstone review")
        await chat.send(source: card, handoff: store)
        let failed = chat.record!.rounds.last!
        precondition(failed.state == "Needs attention" && failed.answer.isEmpty && failed.assignments.isEmpty && WorkChatPolicy.canPlanAgain(failed), "[plan again] a pre-plan failure can be planned again")
        precondition(chat.error?.hasPrefix("COS could not read the session list on this Mac") == true && chat.error?.hasSuffix("Nothing was sent.") == true && chat.error?.contains("invalid_live_row") == true,
                     "[plan again] the error names the real cause and keeps the server's reason: \(chat.error ?? "")")
        chat.setDraft("Something else I am typing")
        await fixture.setFailInput(false)
        let chats = await fixture.chatData.count
        await chat.send(source: card, handoff: store, planner: "opus", effort: "high", replanRoundID: failed.id)
        let rounds = chat.record!.rounds, again = rounds.last!
        precondition(rounds.count == before + 1 && again.id == failed.id && again.question == failed.question && again.state == "Ready to send" && !again.answer.isEmpty,
                     "[plan again] the same round is planned in place, never a second bubble: \(rounds.count - before) round(s), \(again.state)")
        let chatsAfter = await fixture.chatData.count
        precondition(chat.draft.value.text == "Something else I am typing" && chatsAfter == chats + 1, "[plan again] the composer's draft is left alone and the planner ran once")
        precondition(!WorkChatPolicy.canPlanAgain(again), "[plan again] a planned round is not a pre-plan failure")
        await chat.send(source: card, handoff: store, replanRoundID: again.id)
        let chatsThen = await fixture.chatData.count
        precondition(chat.record!.rounds.count == before + 1 && chatsThen == chats + 1 && chat.record!.rounds.last!.assignments.count == 3, "[plan again] Plan again never replans a round that has a plan")
        precondition(store.receipts.isEmpty, "[plan again] planning again sends nothing")
    }

    // 7. 0.5.386: an empty card (nothing to continue or fork). The planner is offered one provider; one New session at
    // most; the round stops at Ready to send; nothing starts until Send.
    do {
        let (fixture, store, chat) = try await setup("empty-card")
        await fixture.setRows([])
        await fixture.setPlan([plan[2], .object(["mode": .string("newSession"), "provider": .string("claude"), "prompt": .string("A second new session.")])])
        chat.setDraft("Start on the toadstone canaries")
        await chat.send(source: card, handoff: store, planner: "opus", effort: "high")
        let body = objects(await fixture.chatData).last!, round = chat.record!.rounds.last!
        precondition((body["newSessionProviders"] as? [String]) == ["claude"], "[empty card] the planner is offered Claude only: \(body["newSessionProviders"] ?? "nil")")
        precondition(round.state == "Ready to send" && round.assignments.count == 1 && round.assignments[0].mode == "newSession" && round.assignments[0].provider == "claude",
                     "[empty card] one New session, stopped at Ready to send: \(round.state) \(round.assignments.count)")
        precondition(round.sessionsNote == WorkOrchestrator.emptyCardNote("claude") && round.offerNewSession == nil, "[empty card] the round says what Send will start")
        let jobsBefore = await fixture.newJobs
        precondition(store.receipts.isEmpty && jobsBefore.isEmpty, "[empty card] nothing started before Send")
        // Claude's usage low: Codex. Claude used up: Codex, and Claude is never offered.
        await fixture.setPlan([.object(["mode": .string("newSession"), "provider": .string("codex"), "prompt": .string("Draft the canaries.")])])
        await fixture.setUsage([.object(["provider": .string("claude"), "state": .string("low"), "headroomPct": .number(5), "resetsAt": .null, "ageSec": .number(10), "source": .string("probe"), "plan": .null, "stale": .bool(false), "note": .string("")])])
        chat.setDraft("Again, with Claude low")
        await chat.send(source: card, handoff: store)
        let lowBody = objects(await fixture.chatData).last!
        precondition((lowBody["newSessionProviders"] as? [String]) == ["codex"] && chat.record!.rounds.last!.sessionsNote == WorkOrchestrator.emptyCardNote("codex"), "[empty card] Codex when Claude's usage is low")
        await fixture.setUsage([.object(["provider": .string("claude"), "state": .string("exhausted"), "headroomPct": .number(0), "resetsAt": .null, "ageSec": .number(10), "source": .string("probe"), "plan": .null, "stale": .bool(false), "note": .string("")])])
        await fixture.setRows([row(sbu, live: true, reason: nil, linked: true, found: ["link"])])
        await fixture.setPlan([plan[0]])
        chat.setDraft("A card with a session, Claude used up")
        await chat.send(source: card, handoff: store)
        let outBody = objects(await fixture.chatData).last!
        precondition((outBody["newSessionProviders"] as? [String]) == ["codex"] && chat.record!.rounds.last!.sessionsNote == nil, "[provider] a used-up provider is never offered, on any card")
    }

    // 8. 0.5.386 (T7): the planner answered without a New session on an empty card. One click starts one, through dispatch.
    do {
        let (fixture, store, chat) = try await setup("offer")
        await fixture.setRows([])
        await fixture.setPlan([])
        chat.setDraft("What should happen on this card?")
        await chat.send(source: card, handoff: store)
        let round = chat.record!.rounds.last!
        let noJobs = await fixture.newJobs
        precondition(round.state == "Answered" && round.offerNewSession == "claude" && store.receipts.isEmpty && noJobs.isEmpty,
                     "[offer] the round offers one click and starts nothing: \(round.state) \(round.offerNewSession ?? "nil")")
        await chat.startNewSession(roundID: round.id, source: card, handoff: store)
        let after = chat.record!.rounds.last!
        let jobs = await fixture.newJobs
        precondition(jobs == ["claude-opus"] && store.receipts.count == 1 && store.receipts[0].mode == .newSession && store.receipts[0].orchestrationRunID == round.id
                     && store.receipts[0].prompt.contains("What should happen on this card?"),
                     "[offer] one Claude Opus session starts, with the request, through submit and its receipt: \(jobs)")
        precondition(after.assignments.count == 1 && after.assignments[0].mode == "newSession" && after.offerNewSession == nil && after.state != "Answered", "[offer] the round shows the one assignment it sent")
        await chat.startNewSession(roundID: round.id, source: card, handoff: store)
        let jobsAgain = await fixture.newJobs
        precondition(jobsAgain.count == 1 && store.receipts.count == 1, "[offer] a second click starts nothing")
        // One case per term of the one-click guard (the button is drawn only on an Answered round with no assignment).
        // An Answered round that already has its assignment, with the offer forced back: the click starts nothing.
        let sent = chat.record!
        var answeredWithOne = sent; let last = sent.rounds.count - 1
        answeredWithOne.rounds[last].state = "Answered"; answeredWithOne.rounds[last].offerNewSession = "claude"; chat.record = answeredWithOne
        await chat.startNewSession(roundID: round.id, source: card, handoff: store)
        let jobsAnswered = await fixture.newJobs
        // (A second send would queue behind the first one's running job, so the round itself is what proves nothing moved.)
        precondition(jobsAnswered.count == 1 && store.receipts.count == 1 && chat.record!.rounds.last!.assignments.map(\.receiptID) == sent.rounds[last].assignments.map(\.receiptID)
                     && chat.record!.rounds.last!.state == "Answered",
                     "[offer] an Answered round that already has an assignment gets no one-click start")
        // A round that is not Answered (Ready to send) with no assignment, the offer forced on: the click starts nothing.
        var notAnswered = sent
        notAnswered.rounds[last].state = "Ready to send"; notAnswered.rounds[last].assignments = []; notAnswered.rounds[last].offerNewSession = "claude"; chat.record = notAnswered
        await chat.startNewSession(roundID: round.id, source: card, handoff: store)
        let jobsNotAnswered = await fixture.newJobs
        precondition(jobsNotAnswered.count == 1 && store.receipts.count == 1 && chat.record!.rounds.last!.assignments.isEmpty && chat.record!.rounds.last!.offerNewSession == "claude",
                     "[offer] a round that is not Answered gets no one-click start")
        chat.record = sent
    }

    // 9. 0.5.386 (T8): Agent workspace. A card with no session of its own opens on Start a new session (Claude Opus); a
    // card with a session keeps Continue; another card's suggestion is never taken for Miles.
    do {
        let (_, store, _) = try await setup("workspace")
        let other = WorkSource.taskSnapshot(TaskRow(.object(["id": .string("b1b2c3d4e5f6"), "workIdentity": .string("b1b2c3d4e5f6"), "domain": .string("quilt"), "title": .string("A new card"), "text": .string("A new card"), "source": .string("Fixture evidence")]))!)
        let empty = store.draft(for: other), linked = store.draft(for: card)
        precondition(empty.mode == .newSession && empty.provider == "claude" && empty.modelID == "claude-opus", "[workspace] an empty card preselects Start a new session on Opus: \(empty.mode) \(empty.modelID)")
        precondition(linked.mode == .continueSession && linked.modelID.isEmpty, "[workspace] a card with a session keeps Continue")
        precondition(store.savedDraft(for: other) == nil, "[workspace] the default is not a saved destination")
        let advice = SessionAdvice(details: ["provider": .string("subq"), "action": .string("continue"), "sessionId": .string(sbu), "confidence": .number(0.73), "reason": .string("Same topic.")])!
        let hasSession = WorkHandoffStore.cardHasSession(workID: other.id, links: store.confirmedSessionCards, receipts: store.receipts)
        precondition(!hasSession && WorkHandoffStore.cardHasSession(workID: card.id, links: store.confirmedSessionCards, receipts: store.receipts), "[workspace] which card has a session")
        precondition(WorkHandoffStore.applicableAdvice(advice, workID: other.id, hasSession: false, links: store.confirmedSessionCards) == nil, "[workspace] another card's session is never preselected on an empty card")
        let unlinked = SessionAdvice(details: ["provider": .string("jev"), "action": .string("fork"), "sessionId": .string(growth), "confidence": .number(0.9), "reason": .string("Close match.")])!
        precondition(store.confirmedSessionCards[growth] == nil && WorkHandoffStore.applicableAdvice(unlinked, workID: other.id, hasSession: false, links: store.confirmedSessionCards) == nil,
                     "[workspace] on an empty card no Continue or Fork suggestion is preselected, linked anywhere or not")
        let fresh = SessionAdvice(details: ["provider": .string("jev"), "action": .string("new"), "confidence": .number(0.8)])!
        precondition(WorkHandoffStore.applicableAdvice(fresh, workID: other.id, hasSession: false, links: store.confirmedSessionCards) == fresh, "[workspace] a New session suggestion still applies")
        precondition(WorkHandoffStore.applicableAdvice(advice, workID: "task:quilt:c0c0c0c0c0c0", hasSession: true, links: store.confirmedSessionCards) == nil, "[workspace] nor on a card that has sessions of its own")
        precondition(WorkHandoffStore.applicableAdvice(advice, workID: card.id, hasSession: true, links: store.confirmedSessionCards) == advice, "[workspace] the card's own session still can be")
        let blank = WorkHandoffDraft(sourceID: other.id, sourceRevision: other.revision, prompt: other.suggestedPrompt)
        precondition(WorkHandoffStore.startPlan(draft: blank, advice: WorkHandoffStore.applicableAdvice(advice, workID: other.id, hasSession: false, links: store.confirmedSessionCards),
                                                sessions: store.sessions, models: store.models, hasHistory: false) == nil, "[workspace] Start work opens the chooser, never a one-click Continue elsewhere")
    }
    print("PASS work orchestrator store: toadstone card plans with both sessions, Guardian row out, refresh before input, Continue/Fork/New session through submit, fork child journaled, Auto-send with Stop, never-silent empty plans, older server unchanged; 0.5.386: short-id session left out, Plan again in place, empty-card New session at Ready to send, one-click start, Agent workspace default")
}
