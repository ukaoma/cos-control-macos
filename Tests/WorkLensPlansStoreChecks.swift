import Foundation

/// 0.5.333 lens plans, by execution: the real WorkLensPlansPump, WorkTaskChatStore and WorkHandoffStore against a fake
/// helper that speaks the server 6.83.0 lens routes. Nothing reaches a provider or a server.
private actor LensFixture {
    let sbu: String
    let lensPlans: Bool
    var jobState = "running"
    private var seq = 0
    private var pending: [(seq: Int, id: String, round: JSONValue)] = []
    private var sends: [JSONValue] = []
    private var stops: [JSONValue] = []
    private(set) var calls: [String] = []
    private(set) var history: [(id: String, body: Data)] = []
    private(set) var results: [(id: String, body: Data)] = []
    private(set) var macSends: [(id: String, body: Data)] = []
    private(set) var chatData: [Data] = []
    private(set) var turns: [String] = []
    private(set) var newJobs: [String] = []
    private(set) var cancels: [[String]] = []
    init(sbu: String, lensPlans: Bool) { self.sbu = sbu; self.lensPlans = lensPlans }
    func addRound(_ json: String) {
        let v = try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        seq += 1; pending.append((seq, v.object!["roundId"]!.string!, v))
    }
    func addSend(_ json: String) { sends.append(try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) }
    func addStop(_ json: String) { stops.append(try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) }
    func setJob(_ state: String) { jobState = state }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        let name = args.first ?? ""; calls.append(name)
        func arg(_ k: String) -> String { args.firstIndex(of: k).map { args[$0 + 1] } ?? "" }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func session(_ id: String, _ title: String) -> JSONValue {
            .object(["id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])), "name": .string(title), "workspace": .string("/tmp/fixture"), "state": .string("recent")])
        }
        func job(_ id: String) -> JSONValue {
            .object(["clientJobId": .string(id), "generation": .number(1), "jobId": .string("job-lens-1"), "status": .string(jobState), "provider": .string("claude")])
        }
        var out: [String: JSONValue] = [:]
        switch name {
        case "work-models": out = ["serverInstanceId": .string("lens-fixture"), "models": .array([
            .object(["id": .string("claude-opus"), "provider": .string("claude"), "title": .string("Claude Opus"), "available": .bool(true)])])]
        case "claude-sessions": out = ["sessions": .array([session(sbu, "2026 SBU /XBU")])]
        case "work-chat-capabilities":
            out = ["protocolVersion": .number(1), "planners": .array([.string("sonnet"), .string("opus")]), "efforts": .array([.string("high")]), "queueRounds": .bool(true)]
            if lensPlans { out["lensPlans"] = .bool(true) }
        case "work-context": out = ["contextText": .string("Toadstone review evidence"), "workRevision": .string(String(repeating: "c", count: 64)),
            "task": .object(["id": .string("420a0114f1a9"), "workIdentity": .string("420a0114f1a9"), "domain": .string("quilt"), "title": .string("Toadstone review"), "text": .string("Toadstone review"), "source": .string("Fixture evidence")])]
        case "work-chat":
            if let data { chatData.append(data) }
            out = ["protocolVersion": .number(1), "answer": .string("Nothing to send yet."), "model": .string("claude:opus"), "effort": .string("high"), "assignments": .array([])]
        case "work-lens-inbox":
            precondition(lensPlans, "an older server's inbox is never polled")
            let since = Int(arg("--since")) ?? 0
            let rows = pending.filter { $0.seq > since }
            out = ["available": .bool(true), "v": .number(1), "cursor": .number(Double(rows.map(\.seq).max() ?? since)),
                   "rounds": .array(rows.map(\.round)), "sends": .array(sends), "stops": .array(stops)]
            sends = []; stops = [] // listing is the pick-up
        case "work-lens-history":
            let id = arg("--round-id"); history.append((id, data ?? Data())); pending.removeAll { $0.id == id }
            out = ["accepted": .bool(true)]
        case "work-lens-mac-send":
            macSends.append((arg("--round-id"), data ?? Data())); out = ["accepted": .bool(true)]
        case "work-lens-result":
            results.append((arg("--send-id"), data ?? Data())); out = ["accepted": .bool(true)]
        case "session-recent-replies": throw HelperClientError.commandFailed("Fixture has no session history")
        case "session-chat-attachability": out = ["attachable": .bool(true)]
        case "session-chat-attach": out = ["state": .string("attached"), "bindingId": .string("lens-fixture"), "epoch": .number(1), "boundTo": .string("exact")]
        case "session-chat-send": turns.append(arg("--thread-id")); out = ["state": .string("completed")]
        case "session-chat-turn": out = ["state": .string("completed")]
        case "session-chat-queued": out = ["state": .string("none"), "queued": .array([])]
        case "work-new":
            newJobs.append(body["model"] as? String ?? "")
            out = ["httpStatus": .number(202), "job": job(body["clientJobId"] as? String ?? "")]
        case "work-job": out = ["job": job(arg("--client-job-id"))]
        case "work-job-cancel", "session-chat-cancel": cancels.append(args); out = ["httpStatus": .number(202)]
        default: preconditionFailure("Lens fixture must not reach \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

private func lensObject(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }
@MainActor private func lensHistory(_ f: LensFixture) async -> [(id: String, body: [String: Any])] { (await f.history).map { ($0.id, lensObject($0.body)) } }
@MainActor private func lensResults(_ f: LensFixture) async -> [(id: String, rows: [[String: Any]])] { (await f.results).map { ($0.id, lensObject($0.body)["assignments"] as? [[String: Any]] ?? []) } }
@MainActor func runWorkLensPlansStoreChecks(root: URL) async throws {
    let previous = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"]
    defer { if let previous { setenv("COS_CONTROL_TEST_HOME", previous, 1) } else { unsetenv("COS_CONTROL_TEST_HOME") } }
    UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey)
    defer { UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey) }
    let sbu = "claude:32386d7e-f751-41c5-a185-a0d731416a01", card = "task:quilt:420a0114f1a9"
    let task = TaskRow(.object(["id": .string("420a0114f1a9"), "workIdentity": .string("420a0114f1a9"), "domain": .string("quilt"), "title": .string("Toadstone review"), "text": .string("Toadstone review"), "source": .string("Fixture evidence")]))!
    let source = WorkSource.taskSnapshot(task)
    precondition(source.id == card)
    func setup(_ name: String, lensPlans: Bool) async -> (LensFixture, WorkHandoffStore, WorkLensPlansPump, UserDefaults, () -> WorkTaskChatStore, (Double) -> Void) {
        setenv("COS_CONTROL_TEST_HOME", root.appendingPathComponent("lens-home-" + name).path, 1)
        let fixture = LensFixture(sbu: sbu, lensPlans: lensPlans)
        let store = WorkHandoffStore(storageURL: root.appendingPathComponent("lens-" + name + ".json"), transport: { args, data in try await fixture.run(args, data) })
        precondition(store.confirmSessionCard(sessionID: sbu, source: source))
        await store.refresh()
        let defaults = UserDefaults(suiteName: "cos-lens-check-" + UUID().uuidString)!
        let pump = WorkLensPlansPump(handoff: store, sources: { [source] }, enabled: true, defaults: defaults)
        var clock = Date(timeIntervalSince1970: 1_792_592_460)
        pump.now = { clock }; pump.idleWait = .seconds(2)
        let chat = { () -> WorkTaskChatStore in let c = WorkTaskChatStore(); c.enabled = true; c.open(source: source, handoff: store); return c }
        return (fixture, store, pump, defaults, chat, { clock = clock.addingTimeInterval($0) })
    }
    let round1 = """
    {"roundId":"lr_00000000000000a1","workID":"\(card)","clientRoundId":"lens-00000001-0000-4000-8000-000000000000","question":"Ship the toadstone fix","answer":"Continue the SBU session; start a Claude session for the canaries.",
     "planner":"opus","effort":"high","orchestrator":true,"createdAt":"2026-10-21T14:20:00.000Z","recordedAt":"2026-10-21T14:20:05.000Z","assignments":[
     {"id":"a1","mode":"continue","sessionID":"\(sbu)","provider":"claude","prompt":"Review the toadstone plan against the SBU work.","contextItemIDs":["req","task"]},
     {"id":"a2","mode":"newSession","provider":"claude","prompt":"Draft the C5 canary steps.","contextItemIDs":["req","task","cos"]}]}
    """
    let round2 = """
    {"roundId":"lr_00000000000000a2","workID":"\(card)","clientRoundId":"lens-00000002-0000-4000-8000-000000000000","question":"And the follow-up","answer":"Continue the SBU session.",
     "planner":"opus","effort":"high","orchestrator":true,"createdAt":"2026-10-21T14:30:00.000Z","recordedAt":"2026-10-21T14:30:01.000Z","assignments":[
     {"id":"a1","mode":"continue","sessionID":"\(sbu)","provider":"claude","prompt":"Follow up on the review.","contextItemIDs":["req","task"]}]}
    """
    func send(_ id: String, round: String, ids: [String], confirmed: Bool) -> String {
        "{\"sendRequestId\":\"\(id)\",\"roundId\":\"\(round)\",\"workID\":\"\(card)\",\"assignmentIds\":[\(ids.map { "\"\($0)\"" }.joined(separator: ","))],\"confirm\":\(confirmed ? "\"two-step\"" : "null"),\"confirmedAt\":null,\"autoSend\":\(!confirmed),\"requestedAt\":\"2026-10-21T14:31:00.000Z\"}"
    }

    // 1. An older server (no lensPlans): the capability read only. No inbox poll, no history write, no send.
    do {
        let (fixture, store, pump, _, chat, advance) = await setup("older", lensPlans: false)
        let before = await fixture.calls.count
        await pump.pass(); await pump.pass()
        var after = Array(await fixture.calls.dropFirst(before))
        precondition(after == ["work-chat-capabilities"], "an older server is asked for its capabilities once a minute and nothing else: \(after)")
        advance(61); await pump.pass()
        after = Array(await fixture.calls.dropFirst(before))
        precondition(after == ["work-chat-capabilities", "work-chat-capabilities"], "and asked again after a minute: \(after)")
        precondition(!pump.offered && store.receipts.isEmpty && chat().record?.rounds.isEmpty == true, "nothing written or sent for an older server")
    }

    // 2. A lens round lands in the card's Work chat history, once, as the same WorkChatRound a Mac plan makes.
    let (fixture, store, pump, defaults, chat, advance) = await setup("lens", lensPlans: true)
    await fixture.addRound(round1)
    await pump.pass()
    precondition(pump.offered, "a 6.83.0 server offers lens plans")
    var history = await lensHistory(fixture)
    precondition(history.map(\.id) == ["lr_00000000000000a1"] && history[0].body["state"] as? String == "in_history" && history[0].body["autoSendCard"] as? Bool == false,
                 "Control reports the round in history with the card's Auto-send: \(history.map(\.body))")
    let saved = chat().record!.rounds
    precondition(saved.count == 1, "one round in the card's history: \(saved.count)")
    let r1 = saved[0]
    precondition(r1.origin == "glasses" && r1.lensRoundID == "lr_00000000000000a1" && r1.lensAt == 1_792_592_405 && r1.state == "Ready to send"
                 && r1.question == "Ship the toadstone fix" && r1.answer.hasPrefix("Continue the SBU session") && r1.planner == "opus", "the round says it came from the glasses, with its time: \(r1.state) \(r1.lensAt ?? 0)")
    precondition(WorkLensPlans.fromGlassesLabel(at: Date(timeIntervalSince1970: r1.lensAt!), now: Date(timeIntervalSince1970: r1.lensAt!), timeZone: TimeZone(identifier: "UTC")!) == "From glasses · 2:20 PM", "From glasses with the time")
    precondition(r1.assignments.map(\.lensID) == ["a1", "a2"] && r1.assignments.map(\.mode) == [nil, "newSession"] && WorkOrchestrator.isNewSessionID(r1.assignments[1].sessionID)
                 && r1.assignments[0].sessionID == sbu && r1.assignments.allSatisfy { $0.state == "Not sent" }, "assignments keep their lens ids and kinds, nothing sent")
    precondition(r1.revision.count == 64 && !r1.linkDigest.isEmpty && r1.attachmentDigest != nil && r1.contextItems?.isEmpty == false
                 && r1.assignments[0].contextItemIDs?.contains("req") == true, "the round carries what Send checks: revision, links, attachments, items")
    precondition(r1.orchestrated?.map(\.id) == [sbu] && r1.orchestrated?.first?.automatic == true && r1.newSessionProviders == ["claude"], "the plan's own targets as Control sees them")
    precondition(store.receipts.isEmpty, "recording a plan sends nothing")
    // Listed again (a history report the server lost): still one round.
    await fixture.addRound(round1)
    await pump.pass()
    let reported = await lensHistory(fixture).count
    precondition(chat().record!.rounds.count == 1 && reported == 2, "a repeat is not written twice, and is reported again")
    // History works: the next Mac plan carries the lens round as history.
    let mac = chat(); await mac.loadPlanners(handoff: store, retryDelay: .zero)
    mac.setDraft("What is left?")
    await mac.send(source: source, handoff: store, planner: "opus", effort: "high")
    let plan = (await fixture.chatData).last.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    precondition(((plan?["history"] as? [[String: Any]]) ?? []).contains { $0["question"] as? String == "Ship the toadstone fix" }, "the lens round is in the history the planner reads")

    // 3. Send this plan (confirmed on the lens): each assignment through Send's own submit, receipts journaled, results reported.
    await fixture.addSend(send("ls_00000000000000b1", round: "lr_00000000000000a1", ids: ["a1", "a2"], confirmed: true))
    await pump.pass()
    let round = chat().record!.rounds.first { $0.lensRoundID == "lr_00000000000000a1" }!
    let turns = await fixture.turns, jobs = await fixture.newJobs
    precondition(turns == [String(sbu.split(separator: ":")[1])] && jobs == ["claude-opus"], "the Continue and the New session each go through submit once: \(turns) \(jobs)")
    let ids = Set(round.assignments.map(\.receiptID))
    precondition(Set(store.receipts.map(\.id)) == ids && store.receipts.allSatisfy { $0.orchestrationRunID == round.id }, "the receipts are the round's own, as a Mac Send journals them")
    precondition(round.sentFromGlasses == true && round.assignments.allSatisfy { $0.lensSendID == "ls_00000000000000b1" }, "the round remembers the lens send")
    var results = await lensResults(fixture)
    precondition(results.count == 1 && results[0].id == "ls_00000000000000b1", "one report for the send")
    let byID = Dictionary(uniqueKeysWithValues: results[0].rows.map { ($0["id"] as! String, $0) })
    precondition(["sent", "delivered"].contains(byID["a1"]?["state"] as? String ?? "") && byID["a2"]?["state"] as? String == "sent"
                 && byID["a1"]?["receiptId"] as? String == round.assignments[0].receiptID, "each assignment's result, with its receipt: \(results[0].rows)")

    // 4. Stop from the lens: the existing Stop cancels the New session's job; the result follows when it ends.
    await fixture.addStop("{\"stopRequestId\":\"lst_00000000000000c1\",\"roundId\":\"lr_00000000000000a1\",\"workID\":\"\(card)\",\"assignmentIds\":[\"a2\"],\"sendRequestId\":\"ls_00000000000000b1\",\"requestedAt\":\"x\"}")
    await pump.pass()
    let cancels = await fixture.cancels
    precondition(cancels == [["work-job-cancel", "--job-id", "job-lens-1"]], "Stop cancels that job and nothing else: \(cancels)")
    await fixture.setJob("canceled")
    advance(16); await pump.pass()
    results = await lensResults(fixture)
    precondition(results.last?.id == "ls_00000000000000b1" && results.last?.rows.contains { $0["id"] as? String == "a2" && $0["state"] as? String == "stopped" } == true,
                 "the stopped job is reported stopped: \(results.last?.rows ?? [])")

    // 5. Not confirmed, card Auto-send off: refused by Control, nothing sent.
    await fixture.addRound(round2)
    await fixture.addSend(send("ls_00000000000000b2", round: "lr_00000000000000a2", ids: ["a1"], confirmed: false))
    await pump.pass()
    results = await lensResults(fixture)
    var turnCount = await fixture.turns.count
    precondition(results.last?.id == "ls_00000000000000b2" && results.last?.rows.first?["state"] as? String == "refused"
                 && results.last?.rows.first?["detail"] as? String == WorkLensPlans.autoSendOff && turnCount == 1, "an unconfirmed send with Auto-send off is refused: \(results.last?.rows ?? [])")

    // 6. Auto-send turned on for the card: reported to the server, then an unconfirmed send goes, and (earlier work open on the
    // session) it queues exactly as a Mac Send would.
    defaults.set(WorkOrchestrator.setting(workID: card, on: true, raw: "", settingDefault: false), forKey: WorkOrchestrator.autoSendCardsKey)
    await pump.pass()
    history = await lensHistory(fixture)
    precondition(history.contains { $0.id == "lr_00000000000000a2" && $0.body["autoSendCard"] as? Bool == true }, "the card's switch is reported again when it changes")
    await fixture.addSend(send("ls_00000000000000b3", round: "lr_00000000000000a2", ids: ["a1"], confirmed: false))
    await pump.pass()
    results = await lensResults(fixture)
    turnCount = await fixture.turns.count
    let queued = chat().record!.rounds.first { $0.lensRoundID == "lr_00000000000000a2" }!.assignments[0]
    precondition(results.last?.id == "ls_00000000000000b3" && results.last?.rows.first?["state"] as? String == "held" && queued.state == WorkChatHold.queuedState
                 && turnCount == 1, "held behind the earlier delivered turn, queued, nothing sent mid-turn: \(results.last?.rows ?? []) \(queued.state)")
    // 7. Recording never sends, even with the card's Auto-send on: a new round sits in history until a send request or
    // Miles's own Send. Neither pump sends it.
    let round3 = """
    {"roundId":"lr_00000000000000a3","workID":"\(card)","clientRoundId":"lens-00000003-0000-4000-8000-000000000000","question":"Third","answer":"Continue the SBU session.",
     "planner":"opus","effort":"high","orchestrator":true,"createdAt":"2026-10-21T14:40:00.000Z","recordedAt":"2026-10-21T14:40:01.000Z","assignments":[
     {"id":"a1","mode":"continue","sessionID":"\(sbu)","provider":"claude","prompt":"Check the third thing.","contextItemIDs":["req","task"]}]}
    """
    precondition(pump.cardAutoSend(card), "the card's Auto-send is on for this check")
    let receiptsBefore = store.receipts.count
    await fixture.addRound(round3)
    advance(16); await pump.pass()
    await WorkChatQueuePump(handoff: store, sources: { [source] }).pass()
    advance(16); await pump.pass()
    let r3 = chat().record!.rounds.first { $0.lensRoundID == "lr_00000000000000a3" }!
    turnCount = await fixture.turns.count
    let jobCount = await fixture.newJobs.count
    precondition(r3.state == "Ready to send" && r3.assignments.allSatisfy { $0.state == "Not sent" } && turnCount == 1 && jobCount == 1 && store.receipts.count == receiptsBefore,
                 "a recorded round is never sent by itself, Auto-send or not: \(r3.state) turns \(turnCount) receipts \(store.receipts.count - receiptsBefore)")
    var macSends = await fixture.macSends
    precondition(macSends.isEmpty, "nothing reported as sent from the Mac")

    // 8. Miles sends that round from the Mac (the lens was told to after a 423): the server is told, so the lens never
    // sends it twice. Held behind earlier work, it is reported held.
    let mac2 = chat(); await mac2.loadPlanners(handoff: store, retryDelay: .zero)
    await mac2.sendAll(roundID: r3.id, source: source, handoff: store)
    precondition(mac2.record!.rounds.first { $0.id == r3.id }!.assignments[0].state == WorkChatHold.queuedState, "held behind earlier work on the Mac")
    let lensResultsBefore = await lensResults(fixture).count
    await pump.pass()
    macSends = await fixture.macSends
    let macRows = macSends.last.map { lensObject($0.body)["assignments"] as? [[String: Any]] ?? [] } ?? []
    precondition(macSends.last?.id == "lr_00000000000000a3" && macRows.count == 1 && macRows[0]["id"] as? String == "a1" && macRows[0]["state"] as? String == "held",
                 "Miles's own Send of a lens round is reported on the round: \(macSends.map(\.id)) \(macRows)")
    let lensResultsAfter = await lensResults(fixture).count
    precondition(lensResultsAfter == lensResultsBefore, "a Mac send is never reported as a lens send's result")
    print("PASS work lens plans store: older server polls nothing, round lands once in history as a WorkChatRound (From glasses, time, checks), history reaches the planner, confirmed send through submit with receipts and results, lens Stop through Stop, Auto-send off refuses, Auto-send on re-reported and queued behind earlier work, recording never sends, a Mac Send of a lens round reported through mac-send")
}
