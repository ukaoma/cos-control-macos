import Foundation

private actor HandoffTransport {
    struct Call: Sendable { let args: [String]; let data: Data? }
    enum Scenario: Sendable { case continueTurn, queue, dropped, fork, wrongFork, failedFork, newJob, refusedNew, staleEra, genericConflict, missingTurn, heldTurn }
    var scenario: Scenario
    var calls: [Call] = []
    var jobIdentity = ""
    var ownership = false
    var wrongJob = false
    var jobGeneration = 1
    var jobProvider = "codex"
    var queueDelivered = false
    var discovery: [JSONValue] = []
    private var hold: CheckedContinuation<Void, Never>?
    private var held = false
    init(_ scenario: Scenario) { self.scenario = scenario }
    func setOwnership(_ value: Bool) { ownership = value }
    func setWrongJob(_ value: Bool) { wrongJob = value }
    func setJobGeneration(_ value: Int) { jobGeneration = value }
    func setJobProvider(_ value: String) { jobProvider = value }
    func setQueueDelivered() { queueDelivered = true }
    func setDiscovery(_ rows: [JSONValue]) { discovery = rows }
    func isHeld() -> Bool { held }
    func release() { hold?.resume(); hold = nil }
    func recorded() -> [Call] { calls }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        calls.append(Call(args: args, data: data))
        var details: [String: JSONValue] = [:]
        switch args.first {
        case "work-models":
            details = ["serverInstanceId": .string("fixture-server"), "models": .array([
                .object(["id": .string("fixture-model"), "provider": .string("codex"), "title": .string("Fixture"), "available": .bool(true)])
            ])]
        case "claude-sessions": details = ["sessions": .array(discovery)]
        case "session-chat-attachability":
            details = scenario == .queue
                ? ["attachable": .bool(false), "reason": .string("native_thread_working")]
                : ["attachable": .bool(true)]
        case "session-chat-attach":
            details = ["state": .string("attached"), "bindingId": .string("binding-fixture"), "epoch": .number(1), "boundTo": .string("fixture-target")]
        case "session-chat-send":
            if scenario == .dropped { throw HelperClientError.commandFailed("Synthetic response lost after admission") }
            if scenario == .heldTurn {
                await withCheckedContinuation { continuation in
                    hold = continuation; held = true
                }
            }
            details = ["state": .string("queued")]
        case "session-chat-queue": details = ["state": .string("parked")]
        case "session-chat-queued":
            let sent = calls.first { $0.args.first == "session-chat-queue" }!.args
            let id = sent[sent.firstIndex(of: "--client-turn-id")! + 1]
            details = ["turns": .array([.object(["clientTurnId": .string(id), "status": .string(queueDelivered ? "delivered" : "waiting")])])]
        case "session-chat-turn": details = scenario == .missingTurn
            ? ["httpStatus": .number(404), "state": .string("refused")]
            : ["state": .string("completed")]
        case "session-chat-fork":
            details = scenario == .failedFork
                ? ["httpStatus": .number(500), "state": .string("refused"), "orphanPossible": .bool(false)]
                : ["state": .string("forked"), "forkSession": .object([
                "id": .string("child-fixture"), "provider": .string(scenario == .wrongFork ? "claude" : "codex"),
                "name": .string("Same display title"), "workspace": .string("Website"), "state": .string("recent")
            ])]
        case "work-new":
            let payload = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
            jobIdentity = payload["clientJobId"] as! String
            details = scenario == .refusedNew
                ? ["httpStatus": .number(400), "error": .object(["message": .string("Invalid fixture admission")])]
                : job()
            if scenario == .staleEra || scenario == .genericConflict {
                details = ["httpStatus": .number(409), "error": .object([
                    "code": .string(scenario == .staleEra ? "message_era_mismatch" : "unclassified_conflict"),
                    "message": .string("Synthetic conflict")])]
            }
        case "work-job": details = job()
        default: throw HelperClientError.commandFailed("Unexpected fixture command: \(args)")
        }
        return HelperResponse(ok: true, message: "Synthetic transport", details: details)
    }
    private func job() -> [String: JSONValue] {
        var job: [String: JSONValue] = ["clientJobId": .string(wrongJob ? "some-other-intent" : jobIdentity),
            "generation": .number(Double(jobGeneration)), "jobId": .string("job-fixture"), "status": .string("running"),
            "provider": .string(jobProvider), "codexThreadId": .string("new-child-fixture")]
        if ownership { job["providerOwnershipConfirmedAt"] = .string("2026-09-27T12:00:00Z") }
        return ["job": .object(job)]
    }
}

@main struct WorkHandoffTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-handoff-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = WorkSource(id: "work-a", title: "Homepage", revision: "1", project: "Website", context: "Synthetic context")
        let second = WorkSource(id: "work-b", title: "Homepage", revision: "2", project: "Website", context: "Different work")
        let target = WorkSession(id: "codex:target-a", nativeID: "target-a", provider: "codex", title: "Same display title", summary: "Homepage", project: "Website", status: "working")
        let other = WorkSession(id: "codex:target-b", nativeID: "target-b", provider: "codex", title: "Same display title", summary: "Homepage", project: "Other", status: "idle")
        let choice = WorkModelChoice(id: "fixture-model", provider: "codex", title: "Fixture", available: true, reason: nil)
        func make(_ name: String, _ mock: HandoffTransport, isolated: Bool = false) -> WorkHandoffStore {
            let store = WorkHandoffStore(isolated: isolated, storageURL: root.appendingPathComponent(name + ".json"), transport: { args, data in try await mock.run(args, data) })
            store.sessions = [target, other]; store.models = [choice]
            return store
        }
        func value(_ args: [String], _ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        // Exact identity wins over identical titles and changed UI selection.
        let direct = HandoffTransport(.continueTurn)
        let store = make("direct", direct)
        await store.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Inspect mobile")
        let first = try require(store.receipts(for: source.id).first)
        precondition(first.sourceSessionID == target.id && first.sessionID == target.id && first.status == "running")
        store.selectedWorkID = second.id; store.selectedSessionID = other.id
        await store.refreshReceipts()
        let final = try require(store.receipts(for: source.id).first)
        precondition(final.id == first.id && final.workID == source.id && final.sessionID == target.id && final.status == "delivered")
        precondition(store.receipts(for: second.id).isEmpty, "Navigation must not reassign a receipt")
        let directCalls = await direct.recorded()
        let send = try require(directCalls.first { $0.args.first == "session-chat-send" })
        precondition(value(send.args, "--thread-id") == target.nativeID && value(send.args, "--provider") == target.provider)
        precondition(value(send.args, "--client-turn-id") == first.id && String(data: send.data!, encoding: .utf8) == "Inspect mobile")
        let callsBeforeDuplicate = directCalls.count
        await store.submit(source: source, mode: .continueSession, session: other, model: nil, prompt: "Duplicate")
        let callsAfterDuplicate = await direct.recorded()
        precondition(callsAfterDuplicate.count == callsBeforeDuplicate && store.receipts(for: source.id).count == 1)
        store.markReviewed(receiptID: final.id)
        precondition(store.receipts(for: source.id).first?.status == "reviewed" && store.receipts(for: source.id).first?.blocksNewHandoff == false)
        await store.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Reviewed follow-up")
        precondition(store.receipts(for: source.id).count == 2 && store.receipts(for: source.id).first?.id != first.id)
        print("PASS: exact target, navigation-independent receipt, duplicate Work handoff refused")

        // An absent/corrupted target is rejected before any attach or provider call.
        let wrong = HandoffTransport(.continueTurn)
        let wrongStore = make("wrong", wrong)
        let impostor = WorkSession(id: target.id, nativeID: other.nativeID, provider: "codex", title: target.title, summary: "", project: "Website", status: "idle")
        await wrongStore.submit(source: source, mode: .continueSession, session: impostor, model: nil, prompt: "Must not send")
        let wrongCalls = await wrong.recorded()
        precondition(wrongCalls.isEmpty && wrongStore.receipts.isEmpty && wrongStore.error != nil)

        // Lost admission response remains unresolved after a fresh store loads disk.
        let lost = HandoffTransport(.dropped)
        let lostStore = make("lost", lost)
        await lostStore.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Only once")
        let lostReceipt = try require(lostStore.receipts.first)
        precondition(lostReceipt.status == "unknown" && lostReceipt.blocksNewHandoff)
        let beforeReload = await lost.recorded()
        let reloaded = make("lost", lost)
        precondition(reloaded.receipts.first?.id == lostReceipt.id && reloaded.receipts.first?.status == "unknown")
        reloaded.markReviewed(receiptID: lostReceipt.id)
        precondition(reloaded.receipts.first?.status == "unknown", "Review cannot clear unknown delivery")
        await reloaded.submit(source: source, mode: .fork, session: target, model: nil, prompt: "Unsafe second attempt")
        let afterReload = await lost.recorded()
        precondition(afterReload.count == beforeReload.count && reloaded.receipts.count == 1)
        print("PASS: wrong target denied; unknown delivery survives reload and blocks alternate-mode resubmit")

        let queue = HandoffTransport(.queue)
        let queuedStore = make("queue", queue)
        await queuedStore.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "After this turn")
        let queued = try require(queuedStore.receipts.first)
        precondition(queued.status == "queued" && queued.channel == "queue")
        let queueCalls = await queue.recorded()
        precondition(!queueCalls.contains { $0.args.first == "session-chat-send" || $0.args.first == "session-chat-attach" })
        let parked = try require(queueCalls.first { $0.args.first == "session-chat-queue" })
        precondition(value(parked.args, "--client-turn-id") == queued.id && value(parked.args, "--thread-id") == target.nativeID)
        await queue.setQueueDelivered(); await queuedStore.refreshReceipts()
        precondition(queuedStore.receipts.first?.status == "delivered" && queuedStore.receipts.first?.blocksNewHandoff == true)
        print("PASS: busy queue uses exact receipt identity; delivery is not task completion")

        let fork = HandoffTransport(.fork)
        let forkStore = make("fork", fork)
        await forkStore.submit(source: source, mode: .fork, session: target, model: nil, prompt: "Create a copy")
        let forkReceipt = try require(forkStore.receipts.first)
        precondition(forkReceipt.sourceSessionID == target.id && forkReceipt.sessionID == "codex:child-fixture" && forkReceipt.status == "delivered")
        precondition(forkStore.sessions.contains { $0.id == target.id } && forkStore.sessions.contains { $0.id == "codex:child-fixture" })
        let badFork = HandoffTransport(.wrongFork)
        let badForkStore = make("bad-fork", badFork)
        await badForkStore.submit(source: source, mode: .fork, session: target, model: nil, prompt: "Copy")
        precondition(badForkStore.receipts.first?.status == "unknown" && badForkStore.receipts.first?.sessionID == nil)
        print("PASS: fork retains source and exact child; wrong-provider child is not bound")

        let job = HandoffTransport(.newJob)
        let jobStore = make("new", job)
        await jobStore.refresh(); jobStore.sessions = [target, other]
        await jobStore.submit(source: source, mode: .newSession, session: nil, model: choice, prompt: "Fresh work")
        precondition(jobStore.receipts.first?.sessionID == nil, "Unconfirmed provider identity must not become a session link")
        await job.setWrongJob(true); await job.setOwnership(true); await jobStore.refreshReceipts()
        precondition(jobStore.receipts.first?.sessionID == nil && jobStore.receipts.first?.status == "unknown")
        await job.setWrongJob(false); await job.setJobGeneration(2); await jobStore.refreshReceipts()
        precondition(jobStore.receipts.first?.sessionID == nil && jobStore.receipts.first?.status == "unknown")
        await job.setJobGeneration(1); await job.setJobProvider("claude"); await jobStore.refreshReceipts()
        precondition(jobStore.receipts.first?.sessionID == nil && jobStore.receipts.first?.status == "unknown")
        await job.setJobProvider("codex"); await jobStore.refreshReceipts()
        precondition(jobStore.receipts.first?.sessionID == "codex:new-child-fixture")
        print("PASS: new job requires matching intent/generation and provider ownership before session binding")

        let failedFork = HandoffTransport(.failedFork)
        let failedForkStore = make("failed-fork", failedFork)
        await failedForkStore.submit(source: source, mode: .fork, session: target, model: nil, prompt: "Ambiguous fork")
        precondition(failedForkStore.receipts.first?.status == "unknown")
        await failedForkStore.submit(source: source, mode: .fork, session: target, model: nil, prompt: "Do not duplicate")
        let failedForkCalls = await failedFork.recorded()
        precondition(failedForkCalls.count == 1, "HTTP 500 must not release duplicate protection")
        let refusedNew = HandoffTransport(.refusedNew)
        let refusedNewStore = make("refused-new", refusedNew)
        await refusedNewStore.refresh()
        await refusedNewStore.submit(source: source, mode: .newSession, session: nil, model: choice, prompt: "Invalid admission")
        precondition(refusedNewStore.receipts.first?.status == "refused" && refusedNewStore.receipts.first?.sessionID == nil)
        for (scenario, name, expected) in [(HandoffTransport.Scenario.staleEra, "stale-era", "refused"), (.genericConflict, "generic-conflict", "unknown")] {
            let mock = HandoffTransport(scenario)
            let candidate = make(name, mock)
            await candidate.refresh()
            await candidate.submit(source: source, mode: .newSession, session: nil, model: choice, prompt: "Conflicting admission")
            precondition(candidate.receipts.first?.status == expected && candidate.receipts.first?.sessionID == nil,
                         "Only proven pre-admission conflicts may release the handoff fence")
        }
        let missingTurn = HandoffTransport(.missingTurn)
        let missingTurnStore = make("missing-turn", missingTurn)
        await missingTurnStore.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Receipt expires")
        await missingTurnStore.refreshReceipts()
        precondition(missingTurnStore.receipts.first?.status == "unknown" && missingTurnStore.receipts.first?.blocksNewHandoff == true)
        print("PASS: fork 500 and turn 404 remain unknown; initial new-job 400 is refused; review only releases delivered receipts")

        let held = HandoffTransport(.heldTurn)
        let holder = make("shared-lock", held)
        let competingTransport = HandoffTransport(.continueTurn)
        let contender = make("shared-lock", competingTransport)
        let inFlight = Task { @MainActor in
            await holder.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Hold journal lock")
        }
        for _ in 0..<100 {
            if await held.isHeld() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let lockReachedTransport = await held.isHeld()
        precondition(lockReachedTransport, "Positive control must reach suspended transport within two seconds")
        await contender.submit(source: second, mode: .continueSession, session: other, model: nil, prompt: "Blocked while first awaits")
        let competingCalls = await competingTransport.recorded()
        precondition(competingCalls.isEmpty && contender.error != nil)
        await held.release(); await inFlight.value
        precondition(holder.receipts.first?.workID == source.id && holder.receipts.first?.status == "running")
        print("PASS: journal lock spans transport await and excludes a second store instance")

        let discovered = HandoffTransport(.continueTurn)
        let discoveryStore = make("discovery", discovered)
        await discoveryStore.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Persist old catalog")
        await discovered.setDiscovery([.object(["id": .string("fresh-target"), "provider": .string("codex"),
            "name": .string("Newly discovered"), "workspace": .string("Website"), "state": .string("idle")])])
        await discoveryStore.refresh()
        let fresh = try require(discoveryStore.sessions.first { $0.nativeID == "fresh-target" })
        await discoveryStore.submit(source: second, mode: .continueSession, session: fresh, model: nil, prompt: "Use newly discovered target")
        precondition(discoveryStore.receipts(for: second.id).first?.sessionID == fresh.id)
        let freshCalls = await discovered.recorded()
        precondition(value(freshCalls.last!.args, "--thread-id") == "fresh-target", "Journal reload must not discard newly discovered sessions")
        print("PASS: fresh discovered target survives journal reload at submission")

        let isolated = HandoffTransport(.dropped)
        let isolatedStore = make("isolated", isolated, isolated: true)
        await isolatedStore.refresh()
        await isolatedStore.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Local simulation")
        await isolatedStore.refreshReceipts()
        let isolatedCalls = await isolated.recorded()
        precondition(isolatedCalls.isEmpty && isolatedStore.receipts.first?.status == "queued")
        isolatedStore.simulate(receiptID: isolatedStore.receipts[0].id, outcome: "running")
        precondition(isolatedStore.receipts[0].status == "running" && isolatedStore.sessions.first(where: { $0.id == target.id })?.status == "running")
        isolatedStore.simulate(receiptID: isolatedStore.receipts[0].id, outcome: "completed")
        precondition(isolatedStore.receipts[0].status == "completed" && isolatedStore.receipts[0].result != nil)
        precondition(isolatedStore.sessions.first(where: { $0.id == target.id })?.status == "completed")
        print("PASS: isolated refresh/submit/reconcile/simulation make zero transport calls")

        let badDisk = HandoffTransport(.continueTurn)
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("not a journal".utf8).write(to: corruptURL)
        let corrupt = make("corrupt", badDisk)
        await corrupt.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Never send")
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blockingFile)
        let unwritable = WorkHandoffStore(storageURL: blockingFile.appendingPathComponent("journal.json"), transport: { args, data in try await badDisk.run(args, data) })
        unwritable.sessions = [target]
        await unwritable.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Never send")
        let diskCalls = await badDisk.recorded()
        precondition(diskCalls.isEmpty && corrupt.error != nil && unwritable.error != nil)
        print("PASS: malformed journal and persistence failure prevent all transport calls")
    }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw HelperClientError.commandFailed("Expected fixture result was missing") }
        return value
    }
}
