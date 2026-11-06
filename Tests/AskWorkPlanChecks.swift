import Foundation

/// Real native stores, private disk state, and a closed fake-helper allowlist. No server or provider is contacted.
private let askSession = "claude:abcdefab-0000-4000-8000-000000000001"
private let askWorkID = "task:quilt:aaaaaaaaaaaa"
private let askRevision = String(repeating: "a", count: 64)
private let askQuestion = "Review the design and report findings."

private func askTaskValue() -> JSONValue {
    .object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"),
        "domain": .string("quilt"), "title": .string("Fixture design review"),
        "text": .string("Review the fixture design"), "source": .string("Fixture evidence"),
        "workRevision": .string(askRevision), "checked": .bool(false)])
}

private actor AskPlanFixture {
    private var calls: [String] = []
    private var bodies: [Data] = []
    private var server = "ask-fixture-server"
    private var revision = askRevision
    private var context = "Fixture design evidence"
    private var offered = true
    private var snapshotServer: String?
    private var answerWork = askWorkID
    private var sessionState = "recent"
    private var assignmentMode: String?
    private var gateCommand: String?
    private var gate: CheckedContinuation<Void, Never>?
    func setServer(_ value: String) { server = value }
    func setRevision(_ value: String) { revision = value }
    func setContext(_ value: String) { context = value }
    func setOffered(_ value: Bool) { offered = value }
    func setSnapshotServer(_ value: String) { snapshotServer = value }
    func setAnswerWork(_ value: String) { answerWork = value }
    func setSessionState(_ value: String) { sessionState = value }
    func setMode(_ value: String?) { assignmentMode = value }
    func pauseNext(_ command: String) { gateCommand = command }
    func paused() -> Bool { gate != nil }
    func resume() { let saved = gate; gate = nil; saved?.resume() }
    func seen() -> [String] { calls }
    func requests() -> [Data] { bodies }

    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        let name = args.first ?? ""; calls.append(name)
        if name == gateCommand {
            gateCommand = nil
            await withCheckedContinuation { gate = $0 }
        }
        let body = data.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        let out: [String: JSONValue]
        switch name {
        case "work-models":
            out = ["serverInstanceId": .string(server), "models": .array([])]
        case "claude-sessions":
            out = ["sessions": .array([.object(["id": .string(String(askSession.split(separator: ":")[1])),
                "provider": .string("claude"), "name": .string("Design reviewer"),
                "workspace": .string("/tmp/ask-fixture"), "state": .string(sessionState)])])]
        case "ask-work-plan-capabilities":
            out = offered ? ["protocolVersion": .number(1), "planOnly": .bool(true), "dispatch": .bool(false),
                "requiresExistingWork": .bool(true), "controlSnapshot": .number(1)] : ["available": .bool(false)]
        case "work-chat-capabilities":
            out = ["references": .bool(true), "contextItems": .bool(true), "queueRounds": .bool(true)]
        case "work-context":
            out = ["contextText": .string(context), "workRevision": .string(revision), "task": askTaskValue()]
        case "drop-it":
            precondition(args == DropIt.call("thread"), "Only a read of the conversation is allowed")
            out = ["protocol": .number(1), "thread": .object(["id": .string("conversation-fixture")])]
        case "ask-work-snapshot":
            precondition(Set(body.keys) == Set(["workID", "revision", "serverInstanceId", "snapshot"]))
            precondition(body["workID"]?.string == askWorkID && body["revision"]?.string == askRevision)
            precondition(body["snapshot"]?.object != nil)
            out = ["accepted": .bool(true), "serverInstanceId": .string(snapshotServer ?? server),
                "workID": .string(askWorkID), "revision": .string(revision)]
        case "ask-work-plan":
            if let data { bodies.append(data) }
            precondition(Set(body.keys) == Set(["workID", "revision", "question"]), "The caller must not inject context, sessions or approval")
            let target: JSONValue = .object(["id": .string(askSession), "title": .string("Design reviewer"),
                "automatic": .bool(true), "forkable": .bool(true)])
            let evidence: JSONValue = .object(["sessions": .array([target]),
                "eligibleContinueSessionIDs": .array([.string(askSession)]),
                "eligibleForkSessionIDs": .array([.string(askSession)]), "newSessionProviders": .array([])])
            var assignment: [String: JSONValue] = ["sessionID": .string(askSession), "prompt": .string("Review the design; report findings without publishing.")]
            if let assignmentMode { assignment["mode"] = .string(assignmentMode) }
            out = ["protocolVersion": .number(1), "planOnly": .bool(true), "proposalID": .string("awp_" + String(repeating: "b", count: 64)),
                "workID": .string(answerWork), "revision": .string(revision), "question": body["question"] ?? .null,
                "answer": .string("Have the existing reviewer inspect the design."), "assignments": .array([.object(assignment)]),
                "model": .string("claude:fixture"), "effort": .string("high"), "evidence": evidence, "revalidatedEvidence": evidence]
        default:
            preconditionFailure("A proposal/import must not send, run a planner fallback, probe usage, or reach any unmocked helper: \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@MainActor private struct AskHarness {
    let fixture: AskPlanFixture
    let handoff: WorkHandoffStore
    let chat: WorkTaskChatStore
    let source: WorkSource
    let journal: URL
    func reopened() -> WorkTaskChatStore {
        let value = WorkTaskChatStore(); value.enabled = true; value.open(source: source, handoff: handoff); return value
    }
    func prepare(conversation: Bool = false) async {
        await chat.prepareAskProposal(question: askQuestion, source: source, handoff: handoff, conversationEnabled: conversation)
    }
    func importFirst() async -> Bool {
        guard let round = chat.record?.rounds.first else { preconditionFailure("Expected a prepared proposal") }
        return await chat.importAskProposal(roundID: round.id, source: source, handoff: handoff)
    }
    func journalBytes() -> Data? { try? Data(contentsOf: journal) }
}

@MainActor private func askHarness(root: URL, name: String) async -> AskHarness {
    let home = root.appendingPathComponent(name)
    precondition(home.path.hasPrefix("/tmp/"), "WorkSessionLinks requires the safe /tmp test-home prefix")
    setenv("COS_CONTROL_TEST_HOME", home.path, 1)
    let fixture = AskPlanFixture()
    let journal = home.appendingPathComponent("work-handoffs/handoffs.json")
    let handoff = WorkHandoffStore(storageURL: journal, transport: { args, data in try await fixture.run(args, data) })
    let source = WorkSource.taskSnapshot(TaskRow(askTaskValue())!)
    precondition(source.id == askWorkID)
    precondition(handoff.confirmSessionCard(sessionID: askSession, source: source))
    await handoff.refresh()
    precondition(handoff.taskChatServerID == "ask-fixture-server" && handoff.activityFresh())
    let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: source, handoff: handoff)
    precondition(chat.record != nil && chat.record!.rounds.isEmpty)
    return AskHarness(fixture: fixture, handoff: handoff, chat: chat, source: source, journal: journal)
}

@MainActor private func waitForAskGate(_ fixture: AskPlanFixture) async throws {
    for _ in 0..<400 {
        if await fixture.paused() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    preconditionFailure("The real store did not reach the expected helper seam")
}

@main struct AskWorkPlanChecks {
    @MainActor static func main() async throws {
        // A runner must isolate defaults before launching us. Each case additionally isolates all Work files.
        guard let testHome = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"], testHome.hasPrefix("/tmp/"),
              ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.hasPrefix("/tmp/") == true else {
            preconditionFailure("Run with Tests/run-ask-work-plan.sh; never use the real Work journal or defaults")
        }
        let root = URL(fileURLWithPath: testHome).appendingPathComponent("ask-store-cases")
        defer { setenv("COS_CONTROL_TEST_HOME", testHome, 1) }
        let priorAutoSend = UserDefaults.standard.object(forKey: WorkChatPolicy.autoSendKey)
        UserDefaults.standard.set(true, forKey: WorkChatPolicy.autoSendKey)
        defer {
            if let priorAutoSend { UserDefaults.standard.set(priorAutoSend, forKey: WorkChatPolicy.autoSendKey) }
            else { UserDefaults.standard.removeObject(forKey: WorkChatPolicy.autoSendKey) }
        }

        // Real prepare + disk reload + explicit import. Auto-send is deliberately enabled and must be irrelevant.
        do {
            let h = await askHarness(root: root, name: "prepare-import")
            let before = h.journalBytes()
            await h.prepare(conversation: true)
            precondition(h.chat.error == nil, h.chat.error ?? "")
            let first = h.chat.record!.rounds.first!
            precondition(first.state == AskWorkPlan.pendingState && first.origin == "ask" && first.askImportedAt == nil)
            precondition(first.askConversationID == "conversation-fixture" && first.askEvidence != nil && first.askContextDigest?.count == 64)
            precondition(first.assignments.count == 1 && first.assignments.allSatisfy { $0.state == "Not sent" })
            let ids = first.assignments.map(\.receiptID)
            precondition(ids.allSatisfy { UUID(uuidString: $0) != nil } && first.sentWithoutReview != true)
            precondition(h.reopened().record!.rounds.first!.assignments.map(\.receiptID) == ids, "Reload preserves native receipt identities")
            await h.chat.pumpQueued(source: h.source, handoff: h.handoff)
            precondition(h.handoff.receipts.isEmpty, "The queue pump must ignore an unimported Ask proposal")
            await h.prepare(conversation: true)
            precondition(h.chat.record!.rounds.count == 1, "A repeated server proposal is not appended twice")
            precondition(h.chat.record!.rounds[0].assignments.map(\.receiptID) == ids)
            let imported = await h.importFirst()
            precondition(imported, h.chat.error ?? "Import refused")
            let saved = h.reopened().record!.rounds[0]
            precondition(saved.state == "Ready to send" && saved.askImportedAt != nil && saved.assignments.map(\.receiptID) == ids)
            precondition(saved.assignments.allSatisfy { $0.state == "Not sent" } && saved.sentWithoutReview != true)
            await h.chat.pumpQueued(source: h.source, handoff: h.handoff)
            precondition(h.handoff.receipts.isEmpty, "Import into Work review is not a queued send")
            let callsBeforeRepeat = await h.fixture.seen()
            let again = await h.importFirst()
            let callsAfterRepeat = await h.fixture.seen()
            precondition(again && callsAfterRepeat == callsBeforeRepeat, "A repeated import is a local idempotent result")
            precondition(h.handoff.receipts.isEmpty && h.journalBytes() == before, "Prepare/import never creates or rewrites dispatch receipts")
            let requests = await h.fixture.requests()
            precondition(requests.count == 2)
            let sent = try JSONDecoder().decode([String: JSONValue].self, from: requests[0])
            precondition(sent["revision"]?.string == askRevision && sent["workID"]?.string == askWorkID)
        }

        // A reference-bearing proposal captures the same context in Ask and a newly opened Work store.
        // This exercises the actual capability transition rather than presetting the private flag.
        do {
            let h = await askHarness(root: root, name: "reference-work-reopen")
            let reference = "claude:abcdefab-0000-4000-8000-000000000002"
            precondition(h.handoff.addReference(sessionID: reference, source: h.source))
            h.chat.referenceFacts = { _, _ in (["design-notes.md"], "1 file, +8 -2") }
            precondition(!h.chat.referencesOffered)
            await h.prepare()
            precondition(h.chat.error == nil, h.chat.error ?? "Reference preparation failed")
            let round = h.chat.record!.rounds[0]
            precondition(h.chat.referencesOffered && round.contextItems?.contains(where: { $0.note == "read-only reference" && $0.text?.contains("design-notes.md") == true }) == true,
                         "Ask must snapshot the existing Work reference items")
            let work = h.reopened()
            work.referenceFacts = h.chat.referenceFacts
            precondition(!work.referencesOffered)
            await work.loadPlanners(handoff: h.handoff)
            let imported = await work.importAskProposal(roundID: round.id, source: h.source, handoff: h.handoff)
            precondition(imported, work.error ?? "An unchanged reference-bearing proposal must survive the Work capability transition")
            precondition(work.record!.rounds[0].state == "Ready to send" && h.handoff.receipts.isEmpty)
            precondition(work.record!.rounds[0].assignments.map(\.receiptID) == round.assignments.map(\.receiptID))
        }

        // The same canonical revision with different local context must not silently import a stale proposal.
        for change in ["context", "revision", "busy"] {
            let h = await askHarness(root: root, name: "stale-" + change)
            await h.prepare()
            precondition(h.chat.record?.rounds.count == 1, h.chat.error ?? "No proposal")
            let ids = h.chat.record!.rounds[0].assignments.map(\.receiptID)
            if change == "context" { await h.fixture.setContext("Changed evidence with the same canonical revision") }
            if change == "revision" { await h.fixture.setRevision(String(repeating: "c", count: 64)) }
            if change == "busy" { await h.fixture.setSessionState("busy") }
            let imported = await h.importFirst()
            precondition(!imported && h.chat.error != nil, "Changed \(change) must refuse review import")
            let saved = h.reopened().record!.rounds[0]
            precondition(saved.askImportedAt == nil && saved.state == AskWorkPlan.pendingState && saved.assignments.map(\.receiptID) == ids)
            precondition(h.handoff.receipts.isEmpty)
        }

        // Unsupported server and exact server/card binding failures stop before a saved proposal or a sender.
        for refusal in ["older", "server", "snapshot", "answer", "mode"] {
            let h = await askHarness(root: root, name: "refuse-" + refusal)
            if refusal == "older" { await h.fixture.setOffered(false) }
            if refusal == "server" { await h.fixture.setServer("different-server") }
            if refusal == "snapshot" { await h.fixture.setSnapshotServer("different-server") }
            if refusal == "answer" { await h.fixture.setAnswerWork("task:quilt:bbbbbbbbbbbb") }
            if refusal == "mode" { await h.fixture.setMode("newSession") }
            await h.prepare()
            precondition(h.chat.record!.rounds.isEmpty && h.chat.error != nil, "Refuse \(refusal)")
            precondition(h.handoff.receipts.isEmpty)
            let seen = await h.fixture.seen()
            if !["answer", "mode"].contains(refusal) { precondition(!seen.contains("ask-work-plan")) }
            if refusal == "older" { precondition(!seen.contains("work-context") && !seen.contains("ask-work-snapshot")) }
        }
        do {
            let h = await askHarness(root: root, name: "import-wrong-server")
            await h.prepare(); await h.fixture.setServer("different-server"); await h.handoff.refresh()
            let imported = await h.importFirst()
            precondition(!imported && h.chat.record!.rounds[0].askImportedAt == nil && h.handoff.receipts.isEmpty)
        }
        do {
            let h = await askHarness(root: root, name: "fork-review")
            await h.fixture.setMode("fork"); await h.prepare()
            precondition(h.chat.record?.rounds.first?.assignments.first?.mode == "fork", h.chat.error ?? "Fork proposal missing")
            let ids = h.chat.record!.rounds[0].assignments.map(\.receiptID)
            let imported = await h.importFirst()
            precondition(imported && h.reopened().record!.rounds[0].assignments.map(\.receiptID) == ids)
            precondition(h.handoff.receipts.isEmpty, "A reviewed Fork must not spawn a session")
        }

        // Cancellation after the transport returns must still prevent local persistence, and never launch fallback work.
        for stage in ["prepare", "import"] {
            let h = await askHarness(root: root, name: "cancel-" + stage)
            if stage == "import" { await h.prepare() }
            await h.fixture.pauseNext(stage == "prepare" ? "ask-work-plan" : "ask-work-snapshot")
            let operation = Task { @MainActor in
                if stage == "prepare" { await h.prepare() } else { _ = await h.importFirst() }
            }
            try await waitForAskGate(h.fixture)
            operation.cancel(); await h.fixture.resume(); await operation.value
            precondition(!h.chat.busy && h.chat.error?.contains("canceled") == true)
            if stage == "prepare" { precondition(h.chat.record!.rounds.isEmpty) }
            else { precondition(h.reopened().record!.rounds[0].askImportedAt == nil) }
            precondition(h.handoff.receipts.isEmpty)
        }

        // A second real store writes while the first awaits transport: CAS must preserve the winner's bytes.
        for stage in ["prepare", "import"] {
            let h = await askHarness(root: root, name: "cas-" + stage)
            h.chat.setDraft("Original draft"); precondition(h.chat.flushDraft())
            if stage == "import" { await h.prepare() }
            await h.fixture.pauseNext(stage == "prepare" ? "ask-work-plan" : "ask-work-snapshot")
            let operation = Task { @MainActor in
                if stage == "prepare" { await h.prepare() } else { _ = await h.importFirst() }
            }
            try await waitForAskGate(h.fixture)
            let peer = h.reopened(); peer.setDraft("Keep the other window's draft"); precondition(peer.flushDraft())
            await h.fixture.resume(); await operation.value
            precondition(h.chat.error?.contains("changed or could not be saved") == true, h.chat.error ?? "CAS was not enforced")
            let disk = h.reopened().record!
            precondition(disk.draft == "Keep the other window's draft")
            if stage == "prepare" { precondition(disk.rounds.isEmpty) }
            else { precondition(disk.rounds[0].askImportedAt == nil && disk.rounds[0].state == AskWorkPlan.pendingState) }
            precondition(h.handoff.receipts.isEmpty)
        }
        print("PASS Ask Work real stores: prepare/import persist without sending, stable UUIDs, duplicate proposals/imports, context/revision/target staleness, server/card binding, cancellation, older server, and competing-writer CAS")
    }
}
