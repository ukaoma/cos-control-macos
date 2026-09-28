import Foundation

private actor ActivityTransport {
    var unavailable = false
    var calls: [[String]] = []
    func fail() { unavailable = true }
    func recorded() -> [[String]] { calls }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        calls.append(args)
        precondition(args == ["claude-sessions", "--fresh"] && data == nil, "Activity must only read session inventory")
        try await Task.sleep(for: .milliseconds(30))
        if unavailable { throw HelperClientError.commandFailed("Fixture offline") }
        return HelperResponse(ok: true, message: "Fixture", details: ["sessions": .array([
            .object(["sessionId": .string("target"), "id": .string("target"), "provider": .string("codex"),
                     "name": .string("Website"), "state": .string("running"), "workspace": .string("Website")])])])
    }
}

@MainActor func runWorkActivityChecks() async throws {
    let task = TaskRow(.object(["id": .string("one"), "domain": .string("quilt"), "text": .string("Check homepage"), "checked": .bool(false)]))!
    let source = WorkSource.taskSnapshot(task)
    let target = WorkSession(id: "codex:target", nativeID: "target", provider: "codex", title: "Website", summary: "Homepage", project: "Website", status: "running")
    var receipt = WorkHandoffReceipt(id: "latest", workID: source.id, workTitle: source.title, sourceRevision: source.revision,
        mode: .continueSession, provider: "codex", modelID: "existing-session", sessionID: target.id,
        sessionTitle: target.title, status: "delivered", detail: "Delivered", prompt: "Check homepage", createdAt: 20)
    func projected(_ receipts: [WorkHandoffReceipt], _ sessions: [WorkSession]) -> WorkWorkspaceItem {
        WorkWorkspaceProjection.items(tasks: [task], reviews: [], receipts: receipts, sessions: sessions)[0]
    }
    let active = projected([receipt], [target])
    precondition(active.inProgress && !active.completed && !active.needsAttention && active.activity?.title == "Session running")
    var idle = target; idle.status = "recent"
    let stopped = projected([receipt], [idle])
    precondition(!stopped.inProgress && !stopped.completed && stopped.needsAttention && stopped.activity?.title == "Sent to session", "Idle is not proof of completion")
    var waiting = target; waiting.status = "waiting"; waiting.waitingDetail = "Permission requested"
    precondition(projected([receipt], [waiting]).activity?.title == "Session needs your input")
    var failed = target; failed.status = "error"; failed.failure = "Rate limited"
    precondition(projected([receipt], [failed]).needsAttention && projected([receipt], [failed]).activity?.session?.failure == "Rate limited")
    let sameName = WorkSession(id: "claude:target", nativeID: "target", provider: "claude", title: target.title, summary: "Homepage", project: "Website", status: "running")
    precondition(projected([receipt], [sameName]).activity?.session == nil, "Titles and native IDs across providers cannot link work")
    precondition(!projected([receipt], []).inProgress && projected([receipt], []).activity?.sessionState == "Live status unavailable")
    var old = receipt; old.id = "old"; old.createdAt = 1; old.status = "failed"
    receipt.status = "completed"
    let ready = projected([old, receipt], [target])
    precondition(ready.needsAttention && !ready.inProgress && !ready.completed && ready.activity?.title == "Response ready for review", "Later session activity cannot turn a finished handoff back into work running")
    var revised = receipt; revised.sourceRevision = "different"
    precondition(projected([revised], [target]).activity == nil, "A changed source must not claim the previous revision's result")
    var otherDomain = receipt; otherDomain.workID = "task:personal:one"
    precondition(projected([otherDomain], [target]).activity == nil)
    print("PASS Work activity: exact provider/work/revision association, current receipt, waiting/errors, completion independence")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-activity-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ActivityTransport()
    let store = WorkHandoffStore(storageURL: root.appendingPathComponent("journal.json"), transport: { args, data in try await transport.run(args, data) })
    var draft = store.draft(for: source); draft.prompt = "Unsent operator edits"
    precondition(store.updateDraft(draft, for: source))
    let bytes = try Data(contentsOf: root.appendingPathComponent("journal.json"))
    store.receipts = [receipt]
    async let first: Void = store.refreshActivity()
    async let second: Void = store.refreshActivity()
    _ = await (first, second)
    let calls = await transport.recorded()
    precondition(calls.count == 1, "Concurrent observers share one discovery request")
    precondition(!store.busy && store.observedSessions().first?.status == "running")
    precondition(store.observedSessions(now: Date().addingTimeInterval(46)).isEmpty, "Expired observations cannot appear live")
    precondition(store.receipts[0].status == "completed" && store.draft(for: source).prompt == draft.prompt)
    await transport.fail(); await store.refreshActivity()
    precondition(store.activityError != nil && store.observedSessions().isEmpty && !store.busy)
    let after = try Data(contentsOf: root.appendingPathComponent("journal.json"))
    precondition(bytes == after && store.receipts[0].status == "completed", "Read-only observation cannot mutate drafts, handoffs or tasks")
    let legacy = Data(#"{"id":"codex:target","nativeID":"target","provider":"codex","title":"Website","summary":"","project":"Website","status":"idle"}"#.utf8)
    let decoded = try JSONDecoder().decode(WorkSession.self, from: legacy)
    precondition(decoded.failure == nil)
    print("PASS Work activity: read-only/coalesced refresh, expiry/offline truth, editor and journal preservation, legacy decoding")
}
