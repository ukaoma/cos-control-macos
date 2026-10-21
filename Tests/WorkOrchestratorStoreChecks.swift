import Foundation

/// 0.5.333 Work orchestrator, by execution: the real WorkTaskChatStore and WorkHandoffStore against a fake transport in the
/// shape of the toadstone card on 2026-10-20 (one linked Claude session in the list; the Codex session on the card by
/// handoff history only, outside the list; a Codex Guardian review row in the list). Nothing reaches a provider.
private actor WorkOrchestratorFixture {
    let sbu: String, growth: String, guardian: String
    let orchestrator: Bool
    var rows: [JSONValue]
    var plan: [JSONValue]
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
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        let name = args.first ?? ""; calls.append(name)
        var out: [String: JSONValue] = [:]
        let thread = args.firstIndex(of: "--thread-id").map { args[$0 + 1] } ?? ""
        func session(_ id: String, _ title: String) -> JSONValue {
            .object(["id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])), "name": .string(title), "workspace": .string("/tmp/fixture"), "state": .string("recent")])
        }
        switch name {
        case "work-models": out = ["serverInstanceId": .string("orchestrator-fixture"), "models": .array([
            .object(["id": .string("claude-opus"), "provider": .string("claude"), "title": .string("Claude Opus"), "available": .bool(true)]),
            .object(["id": .string("gpt-codex"), "provider": .string("codex"), "title": .string("Codex"), "available": .bool(true)])])]
        case "claude-sessions": out = ["sessions": .array([session(sbu, "2026 SBU /XBU"), session(guardian, "Guardian review")])]
        case "work-chat-capabilities":
            out = ["protocolVersion": .number(1), "planners": .array([.string("sonnet"), .string("opus")]), "efforts": .array([.string("high")])]
            if orchestrator { out["orchestrator"] = .bool(true) }
        case "work-context": out = ["contextText": .string("Toadstone review evidence"), "workRevision": .string(String(repeating: "c", count: 64)),
            "task": .object(["id": .string("420a0114f1a9"), "workIdentity": .string("420a0114f1a9"), "domain": .string("quilt"), "title": .string("Toadstone review"), "text": .string("Toadstone review"), "source": .string("Fixture evidence")])]
        case "work-orchestrator-input":
            if let data { snapshotData.append(data) }
            out = ["protocolVersion": .number(1), "workID": .string("task:quilt:420a0114f1a9"), "now": .string("2026-10-20T21:29:00Z"), "rows": .array(rows), "leftOut": .array([]),
                   "usage": .array([.object(["provider": .string("codex"), "state": .string("low"), "headroomPct": .number(8), "resetsAt": .string("2026-10-27T11:51:14.000Z"), "ageSec": .number(60), "source": .string("probe"), "plan": .string("prolite"), "stale": .bool(false), "note": .string("")])]),
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
        precondition(chat.record!.rounds.last!.sessionsNote?.hasPrefix("COS found no session for this task") == true, "and says when there is none")
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
    print("PASS work orchestrator store: toadstone card plans with both sessions, Guardian row out, refresh before input, Continue/Fork/New session through submit, fork child journaled, Auto-send with Stop, never-silent empty plans, older server unchanged")
}
