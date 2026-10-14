import Foundation

private actor WorkChatFixture {
    let ids: [String]
    var calls: [String] = []
    var contextReads = 0
    init(_ ids: [String]) { self.ids = ids }
    func seen() -> [String] { calls }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        let name = args.first ?? ""; calls.append(name)
        var out: [String: JSONValue] = [:]
        switch name {
        case "work-models": out = ["serverInstanceId": .string("fixture-server"), "models": .array([])]
        case "claude-sessions": out = ["sessions": .array(ids.prefix(2).map { id in .object([
            "sessionId": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])),
            "name": .string("Exact " + id), "workspace": .string("/tmp/fixture"), "state": .string("recent")]) })]
        case "work-context":
            contextReads += 1
            out = ["contextText": .string("Fixture task evidence"), "workRevision": .string(String(repeating: contextReads == 1 ? "a" : "b", count: 64)), "task": .object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")])]
        case "work-chat":
            // Let a second Send and a navigation change race with planning.
            try await Task.sleep(for: .milliseconds(100))
            out = ["protocolVersion": .number(1), "answer": .string("Review independent copy and code checks."),
                "assignments": .array(ids.prefix(2).map { .object(["sessionID": .string($0), "prompt": .string("Report checks; do not publish.")]) })]
        default: preconditionFailure("Fixture must stop before any provider delivery: \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@MainActor func runWorkOrchestrationChecks() async throws {
    let root = URL(fileURLWithPath: "/tmp/cos-work-chat-checks-" + UUID().uuidString)
    let previous = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"]
    setenv("COS_CONTROL_TEST_HOME", root.path, 1)
    defer { if let previous { setenv("COS_CONTROL_TEST_HOME", previous, 1) } else { unsetenv("COS_CONTROL_TEST_HOME") }; try? FileManager.default.removeItem(at: root) }
    let ids = ["claude:abcdefab-0000-4000-8000-000000000001", "codex:abcdefab-0000-4000-8000-000000000002", "cursor:abcdefab-0000-4000-8000-000000000003"]
    let task = TaskRow(.object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")]))!
    let source = WorkSource.taskSnapshot(task)
    let sessions = ids.map { WorkSession(id: $0, nativeID: String($0.split(separator: ":")[1]), provider: String($0.split(separator: ":")[0]), title: "Exact " + $0, summary: "", project: "/tmp/fixture", status: "recent") }
    let valid = WorkChatPlannerAnswer(protocolVersion: 1, answer: "Describe bounded checks.", assignments: [WorkChatAssignment(sessionID: ids[0], prompt: "Review copy.")])
    precondition(WorkChatPolicy.valid(valid, targets: Set(ids.prefix(2))))
    precondition(!WorkChatPolicy.valid(valid, targets: [ids[1]]))
    precondition(!WorkChatPolicy.valid(valid, targets: Set(ids), summary: true))
    let duplicate = WorkChatPlannerAnswer(protocolVersion: 1, answer: "Plan", assignments: valid.assignments + valid.assignments)
    precondition(!WorkChatPolicy.valid(duplicate, targets: Set(ids)))
    let file = root.appendingPathComponent("private/record.json")
    try WorkSessionLinks.chatWrite(file, data: Data("one".utf8), expected: nil)
    do { try WorkSessionLinks.chatWrite(file, data: Data("lost update".utf8), expected: nil); preconditionFailure("CAS accepted stale write") } catch {}
    let stored = try WorkSessionLinks.chatRead(file)
    precondition(stored == Data("one".utf8))
    let unsafe = root.appendingPathComponent("private/unsafe.json")
    try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: file)
    do { _ = try WorkSessionLinks.chatRead(unsafe); preconditionFailure("Symlink accepted") } catch {}

    let handoff = WorkHandoffStore(isolated: true, storageURL: root.appendingPathComponent("sample.json"), transport: { _,_ in preconditionFailure("No provider calls in sample") })
    handoff.sessions = sessions
    for id in ids { precondition(handoff.confirmSessionCard(sessionID: id, source: source)) }
    let chat = WorkTaskChatStore(); chat.open(source: source, handoff: handoff); chat.setDraft("Review copy and code independently")
    await chat.send(source: source, handoff: handoff)
    precondition(chat.record?.rounds.count == 1 && chat.record?.rounds[0].state == "Dispatched")
    precondition(handoff.receipts.count == 2 && Set(handoff.receipts.compactMap(\.sessionID)) == Set(ids.prefix(2)))
    precondition(Set(handoff.receipts.compactMap(\.orchestrationRunID)).count == 1)
    let id = handoff.receipts[0].id
    await handoff.submit(source: source, mode: .continueSession, session: sessions[0], model: nil, prompt: "Duplicate", orchestrationRunID: chat.record!.rounds[0].id, intentID: id)
    precondition(handoff.receipts.count == 2, "A duplicate intent or target cannot dispatch twice")
    let relaunched = WorkTaskChatStore(); relaunched.open(source: source, handoff: handoff)
    precondition(relaunched.record?.rounds.first?.assignments.map(\.receiptID) == chat.record?.rounds.first?.assignments.map(\.receiptID), "Chat survives restart with exact receipts")
    chat.setDraft("Do more")
    await chat.send(source: source, handoff: handoff)
    precondition(handoff.receipts.count == 2 && chat.record?.rounds.last?.state == "Needs attention", "Foreign active run blocks more sends")
    for n in handoff.receipts.indices { handoff.receipts[n].status = "completed"; handoff.receipts[n].result = "Result for " + handoff.receipts[n].provider }
    await chat.refresh(source: source, handoff: handoff)
    precondition(chat.record?.rounds[0].assignments.allSatisfy { !$0.result.isEmpty } == true, "Earlier rounds still receive independent updates")
    let saved = WorkContributorProjection.rows(workID: source.id, links: handoff.confirmedSessionCards, receipts: [], observed: [], remembered: sessions)
    precondition(saved.allSatisfy { $0.session == nil && $0.title.hasPrefix("Exact ") }, "Remembered identity cannot imply live status")

    // Real-path fake transport proves task revision drift and double clicks stop BEFORE native delivery.
    let fixture = WorkChatFixture(ids)
    let real = WorkHandoffStore(storageURL: root.appendingPathComponent("real.json"), transport: { args,data in try await fixture.run(args,data) })
    for id in ids.prefix(2) { precondition(real.confirmSessionCard(sessionID: id, source: source)) }
    await real.refresh()
    let candidate = WorkTaskChatStore(); candidate.enabled = true; candidate.open(source: source, handoff: real); candidate.setDraft("Review independent checks")
    let first = Task { await candidate.send(source: source, handoff: real) }
    try await Task.sleep(for: .milliseconds(50))
    await candidate.send(source: source, handoff: real)
    let other = WorkSource(id: "task:quilt:bbbbbbbbbbbb", title: "Other", revision: source.revision, project: "quilt", context: "")
    candidate.open(source: other, handoff: real)
    precondition(candidate.record?.workID == source.id, "Navigation cannot redirect an in-flight request")
    await first.value
    let calls = await fixture.seen()
    precondition(calls.filter { $0 == "work-chat" }.count == 1 && real.receipts.isEmpty && candidate.record?.rounds.first?.state == "Needs attention", "Changed task stops all dispatch; double Send produces one plan")
    print("PASS Work orchestration: exact target policy, private CAS/symlinks, shared distinct-target run, duplicate/foreign-run fences, durable history, all-round provenance, navigation/double-send/task-revision drift; zero provider sends")
}
