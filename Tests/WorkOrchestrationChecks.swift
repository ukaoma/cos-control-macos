import Foundation
import AppKit
import Combine
import CryptoKit

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
    var delivered = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: source.id, workTitle: source.title, sourceRevision: source.revision, mode: .continueSession, provider: "claude", modelID: "existing", sessionID: ids[0], sessionTitle: "Exact", status: "delivered", detail: "Delivered", prompt: "A distinctive original assignment to inspect this exact canary", createdAt: 100)
    delivered.channel = "turn"
    let nativeRead = WorkProgressTracker.SessionRead(replies: [.init(text: "Old seed", at: 99), .init(text: "Own native result", at: 102), .init(text: "Later turn result", at: 110)], prompts: [.init(text: delivered.prompt, at: 101), .init(text: "Different later request", at: 109)], runningActive: false, agentState: "ended", lastActivityAt: 110, hasHistory: true)
    precondition(WorkChatPolicy.nativeReplies(receipt: delivered, read: nativeRead).map(\.text) == ["Own native result"], "Native result must exclude seed and later turns")
    var idleRead = nativeRead; idleRead.runningActiveVerified = true
    precondition(WorkChatPolicy.canContinue(receipt: delivered, read: idleRead), "Exact completed native turn permits a follow-up without changing review status")
    var activeRead = idleRead; activeRead.runningActive = true
    precondition(!WorkChatPolicy.canContinue(receipt: delivered, read: activeRead), "A historical done report cannot override a current writer")
    var oldServerRead = idleRead; oldServerRead.runningActiveVerified = false
    precondition(!WorkChatPolicy.canContinue(receipt: delivered, read: oldServerRead), "Missing activity evidence must fail closed")
    var noHistory = idleRead; noHistory.hasHistory = false
    precondition(!WorkChatPolicy.canContinue(receipt: delivered, read: noHistory))
    var uncertain = delivered; uncertain.status = "unknown"
    precondition(!WorkChatPolicy.canContinue(receipt: uncertain, read: idleRead))
    let deliveredKey = try WorkChatPolicy.continuationKey(delivered)
    let uncertainKey = try WorkChatPolicy.continuationKey(uncertain)
    precondition(deliveredKey != uncertainKey, "A changed journal invalidates idle evidence")
    delivered.prompt = "Unmatched prompt must not claim any result"
    precondition(WorkChatPolicy.nativeReplies(receipt: delivered, read: nativeRead).isEmpty)
    precondition(!WorkChatPolicy.canContinue(receipt: delivered, read: idleRead), "Unrelated replies never release a receipt")
    let styled = NSMutableAttributedString(string: "Review the header", attributes: [.font: NSFont.systemFont(ofSize: 13)])
    styled.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 11, length: 6))
    let rich = WorkRichText.rtf(styled)
    precondition(WorkRichText.markdown(styled) == "Review the **header**")
    precondition(WorkRichText.markdown(WorkRichText.restored(rich, fallback: "lost")) == "Review the **header**", "Formatting survives RTF storage")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("cos-rich-check-" + UUID().uuidString))
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK1cAAAAASUVORK5CYII=")!
    pasteboard.setData(png, forType: .png)
    precondition(!WorkRichText.media(pasteboard).isEmpty, "Pasted image is routed to media intake, not into text")
    pasteboard.releaseGlobally()
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
    chat.setRichDraft("Review the **header**", rtf: rich)
    precondition(chat.flushDraft())
    let richRelaunch = WorkTaskChatStore(); richRelaunch.open(source:source,handoff:handoff)
    precondition(richRelaunch.record?.draftRTF == rich && richRelaunch.record?.draft == "Review the **header**")
    chat.setRichDraft(String(repeating:"x",count:2001),rtf:nil)
    precondition(chat.record?.draft == "Review the **header**", "Over-limit rich edit is not silently truncated")
    await chat.send(source: source, handoff: handoff)
    precondition(chat.record?.rounds.count == 1 && chat.record?.rounds[0].state == "Dispatched")
    precondition(chat.record?.draftRTF == nil, "A sent draft clears its local rich text")
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
    precondition(chat.record?.rounds.last?.assignments.allSatisfy { $0.state != "Sending" } == true, "A local refusal cannot remain Sending")
    let refusedRound = chat.record!.rounds.last!
    await chat.refresh(source: source, handoff: handoff, automatic: true)
    precondition(chat.record?.rounds.last?.assignments.allSatisfy { $0.state == "Not sent" } == true, "A known local refusal stays Not sent after polling")
    precondition(chat.record?.draft == "", "The saved failed question remains in durable history")
    chat.restoreUnsentRequest(roundID: refusedRound.id)
    precondition(chat.record?.draft == "Do more" && handoff.receipts.count == 2, "Restore only fills the composer, never dispatches")
    chat.setDraft("Keep this newer draft")
    chat.restoreUnsentRequest(roundID: refusedRound.id)
    precondition(chat.record?.draft == "Keep this newer draft", "Recovery cannot overwrite a newer user draft")
    chat.setDraft("")
    for n in handoff.receipts.indices { handoff.receipts[n].status = "completed"; handoff.receipts[n].result = "Result for " + handoff.receipts[n].provider }
    await chat.refresh(source: source, handoff: handoff)
    precondition(chat.record?.rounds[0].assignments.allSatisfy { !$0.result.isEmpty } == true, "Earlier rounds still receive independent updates")
    let fileStore = WorkCardFileStore(root:root.appendingPathComponent("rich-files"),isolated:true)
    let withFiles = WorkHandoffStore(isolated:true,storageURL:root.appendingPathComponent("with-files.json"),transport: { _,_ in preconditionFailure("No provider calls in attachment check") },cardFiles:fileStore)
    withFiles.sessions = sessions
    let attachmentSource = WorkSource.taskSnapshot(TaskRow(.object(["id":.string("bbbbbbbbbbbb"),"workIdentity":.string("bbbbbbbbbbbb"),"domain":.string("quilt"),"title":.string("Rich file fixture"),"text":.string("Rich file fixture"),"source":.string("Private evidence")]))!)
    for id in ids { precondition(withFiles.confirmSessionCard(sessionID:id,source:attachmentSource)) }
    let attachmentURL = root.appendingPathComponent("review-context.txt")
    try Data("Private context for the header review.".utf8).write(to:attachmentURL)
    await fileStore.intake(urls:[attachmentURL],source:attachmentSource)
    let filesChat = WorkTaskChatStore(); filesChat.open(source:attachmentSource,handoff:withFiles)
    filesChat.setDraft("Check the attached context independently")
    await filesChat.send(source:attachmentSource,handoff:withFiles)
    precondition(withFiles.receipts.count == 2, "Both independent assignments receive attachments")
    precondition(withFiles.receipts.allSatisfy { $0.prompt.contains("review-context.txt") && $0.context != nil }, "Actual handoff prompts and receipts retain saved file references")
    precondition(filesChat.record?.rounds[0].attachmentNames == ["review-context.txt"], "Question records its observed attachment names")
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
    let legacySource = WorkSource(id: "task:quilt:dddddddddddd", title: "Interrupted fixture", revision: source.revision, project: "quilt", context: "")
    let legacyChat = WorkTaskChatStore(); legacyChat.open(source: legacySource, handoff: handoff)
    var interrupted = WorkChatRound(question: "Review the 404 sheet")
    interrupted.state = "Needs attention"
    var unsaved = WorkChatAssignment(sessionID: ids[0], prompt: "Review the sheet only"); unsaved.state = "Sending"
    interrupted.assignments = [unsaved]; legacyChat.record?.rounds = [interrupted]
    await legacyChat.refresh(source: legacySource, handoff: handoff)
    precondition(legacyChat.record?.rounds[0].assignments[0].state == "No delivery receipt", "Old Sending badge cannot survive a failed pre-intent send")
    legacyChat.restoreUnsentRequest(roundID: interrupted.id)
    precondition(legacyChat.record?.draft == "", "A missing historical receipt needs a manual session check")
    legacyChat.restoreUnsentRequest(roundID: interrupted.id, checkedUnconfirmed: true)
    precondition(legacyChat.record?.draft == interrupted.question, "After checking, recovery fills the composer only")
    try await runWorkContinuationChecks(source: source, session: sessions[0], root: root)
    try await runWorkChatTypingChecks(source: source, handoff: handoff, root: root)
    print("PASS Work orchestration: exact target policy, private CAS/symlinks, shared distinct-target run, duplicate/foreign-run fences, durable history, all-round provenance, navigation/double-send/task-revision drift; zero provider sends")
}

@MainActor private func runWorkChatTypingChecks(source: WorkSource, handoff: WorkHandoffStore, root: URL) async throws {
    let chat = WorkTaskChatStore(); chat.open(source: source, handoff: handoff)
    // A long transcript makes accidental full-history saves/rebuilds visible.
    chat.record?.rounds = (0..<50).map { _ in
        var round = WorkChatRound(question: String(repeating: "question ", count: 100))
        round.answer = String(repeating: "answer ", count: 700); round.state = "Answered"
        return round
    }
    chat.setDraft("before typing"); precondition(chat.flushDraft())
    let key = SHA256.hash(data: Data(("sample\n" + source.id).utf8)).map { String(format: "%02x", $0) }.joined()
    let file = WorkSessionLinks.defaultURL().deletingLastPathComponent().appendingPathComponent("task-chat/" + key + ".json")
    let before = try WorkSessionLinks.chatRead(file)
    var historyInvalidations = 0
    let observation = chat.objectWillChange.sink { historyInvalidations += 1 }
    defer { observation.cancel() }
    let editor = WorkRichEditor(markdown: "", richText: nil, disabled: false, command: "", commandID: UUID(),
        onChange: { chat.setRichDraft($0, rtf: $1) }, onMedia: { _ in preconditionFailure("Typing cannot attach files") })
    let view = WorkContextTextView(frame: .zero)
    view.textStorage?.setAttributedString(NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
    let coordinator = editor.makeCoordinator(); coordinator.view = view
    var milliseconds: [Double] = []
    for _ in 0..<1200 {
        let start = CFAbsoluteTimeGetCurrent()
        view.textStorage?.append(NSAttributedString(string: "x", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        coordinator.changed()
        milliseconds.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    precondition(historyInvalidations == 0, "Typing cannot publish the transcript or attachment list")
    let duringBurst = try WorkSessionLinks.chatRead(file)
    precondition(duringBurst == before, "Typing burst cannot write/fsync the whole history")
    precondition(chat.record?.draft == String(repeating: "x", count: 1200), "Send sees the latest draft before debounce")
    try await Task.sleep(for: .milliseconds(500))
    let saved = try JSONDecoder().decode(WorkChatRecord.self, from: WorkSessionLinks.chatRead(file)!)
    precondition(saved.draft == chat.record?.draft && saved.draftRTF != nil, "Idle autosave retains the final rich draft")
    precondition(historyInvalidations == 0, "Autosave cannot invalidate the transcript")
    var editedDuringRefresh = false
    let refreshObservation = chat.$refreshing.sink { active in
        if active {
            precondition(!chat.busy, "Receipt refresh cannot disable the editor")
            chat.setDraft("draft typed during refresh"); editedDuringRefresh = true
        }
    }
    await chat.refresh(source: source, handoff: handoff, automatic: true)
    refreshObservation.cancel()
    precondition(editedDuringRefresh && chat.record?.draft == "draft typed during refresh", "Refresh cannot lose simultaneous draft edits")
    // Navigating during the debounce flushes the old task; it cannot leak into the next one.
    chat.setDraft("last edit before navigation")
    let next = WorkSource(id: "task:quilt:cccccccccccc", title: "Next task", revision: source.revision, project: "quilt", context: "")
    chat.open(source: next, handoff: handoff)
    precondition(chat.record?.draft == "")
    chat.open(source: source, handoff: handoff)
    precondition(chat.record?.draft == "last edit before navigation")
    // CAS is still enforced after a deferred save; another app's history is never overwritten.
    chat.setDraft("unsaved conflicted edit")
    let disk = try WorkSessionLinks.chatRead(file)!
    var foreign = try JSONDecoder().decode(WorkChatRecord.self, from: disk); foreign.draft = "another writer"
    let foreignBytes = try JSONEncoder().encode(foreign)
    try WorkSessionLinks.chatWrite(file, data: foreignBytes, expected: disk)
    precondition(!chat.flushDraft())
    let afterConflict = try WorkSessionLinks.chatRead(file)
    precondition(afterConflict == foreignBytes)
    milliseconds.sort()
    let p95 = milliseconds[Int(Double(milliseconds.count - 1) * 0.95)]
    precondition(p95 < 16, "Native rich-text edit callback must stay below a 16ms frame at p95")
    print(String(format: "PASS typing: 1200 native edits, p95 %.3fms, 0 history invalidations, 0 burst disk writes; idle save, navigation flush and CAS conflict preserved", p95))
}

// Exercise the actual submit/attach/send boundary using an isolated transport and on-disk journal.
// No provider or live task is touched.
private actor WorkContinuationFixture {
    let previous: WorkHandoffReceipt
    let active: Bool
    let verified: Bool
    let matching: Bool
    var latestPrompt: String
    var latestAt: Double
    var sends = 0
    init(_ previous: WorkHandoffReceipt, active: Bool = false, verified: Bool = true, matching: Bool = true) {
        self.previous = previous; self.active = active; self.verified = verified; self.matching = matching
        latestPrompt = previous.prompt; latestAt = previous.createdAt + 1
    }
    func count() -> Int { sends }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        let details: [String: JSONValue]
        switch args.first {
        case "session-recent-replies":
            precondition(args.contains("40"), "Continuation reads the full bounded history: a long native turn may have more than twelve assistant messages")
            details = ["state": .string("turns"), "runningActive": .bool(active), "runningActiveVerified": .bool(verified), "agentState": .string(active ? "working" : "ended"),
                "prompts": .array([.object(["text": .string(matching ? latestPrompt : "An unrelated earlier prompt"), "at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: latestAt)))])]),
                "replies": .array([.object(["text": .string("Draft work is done, nothing published."), "at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: latestAt + 1)))])])]
        case "session-chat-attachability": details = ["attachable": .bool(true)]
        case "session-chat-attach": details = ["state": .string("attached"), "bindingId": .string("continuation-fixture"), "epoch": .number(1), "boundTo": .string("fixture-target")]
        case "session-chat-send":
            sends += 1; latestPrompt = String(data: data!, encoding: .utf8)!; latestAt = ceil(Date().timeIntervalSince1970) + 1
            details = ["state": .string("completed")]
        default: preconditionFailure("Unexpected continuation fixture call: \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: details)
    }
}
@MainActor private func runWorkContinuationChecks(source: WorkSource, session: WorkSession, root: URL) async throws {
    struct Journal: Encodable { var version = 2; var receipts: [WorkHandoffReceipt]; var sessions: [WorkSession] }
    for scenario in ["idle", "active", "unknown", "plain", "changed", "unverified", "unrelated", "app"] {
        var previous = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: source.id, workTitle: source.title, sourceRevision: source.revision, mode: .continueSession, provider: session.provider, modelID: "existing", sessionID: session.id, sessionTitle: session.title, status: scenario == "unknown" ? "unknown" : "delivered", detail: "Prior delivered task", prompt: "A distinctive prior task whose exact native reply must be checked", createdAt: WorkProgress.parseStamp("2026-10-14T15:00:00Z")!)
        previous.channel = scenario == "app" ? "app" : "turn"
        let frozenPrevious = previous
        let file = root.appendingPathComponent("continue-" + scenario + ".json")
        try JSONEncoder().encode(Journal(receipts: [previous], sessions: [session])).write(to: file)
        let fixture = WorkContinuationFixture(previous, active: scenario == "active", verified: scenario != "unverified", matching: scenario != "unrelated")
        let store = WorkHandoffStore(storageURL: file, transport: { args, data in
            let response = try await fixture.run(args, data)
            if scenario == "changed", args.first == "session-recent-replies" {
                var changed = frozenPrevious; changed.status = "unknown"
                try JSONEncoder().encode(Journal(receipts: [changed], sessions: [session])).write(to: file)
            }
            return response
        })
        let newID = UUID().uuidString.lowercased()
        await store.submit(source: source, mode: .continueSession, session: session, model: nil, prompt: "Review this attached report read-only", orchestrationRunID: scenario == "plain" ? nil : UUID().uuidString, intentID: newID)
        let sends = await fixture.count()
        precondition(sends == (scenario == "idle" ? 1 : 0), "Continuation gate: \(scenario) sent \(sends)")
        if scenario == "idle" {
            precondition(store.receipts.first(where: { $0.id == newID })?.status == "delivered")
            precondition(store.receipts.first(where: { $0.id == previous.id })?.status == "delivered", "Follow-up never pretends the user reviewed the earlier answer")
            precondition(store.receipts.first(where: { $0.id == previous.id })?.continuedBy == newID, "Old exact turn is durably linked to its accepted follow-up")
            precondition(store.receipts.first(where: { $0.id == previous.id })?.blocksNewHandoff == false, "Old turns beyond the recent-history window cannot wedge later requests")
            await store.submit(source: source, mode: .continueSession, session: session, model: nil, prompt: "Duplicate intent", orchestrationRunID: UUID().uuidString, intentID: newID)
            let count = await fixture.count(); precondition(count == 1, "Exact intent must not be sent twice")
            let relaunched = WorkHandoffStore(storageURL: file, transport: { _,_ in preconditionFailure("Restart must not send") })
            precondition(relaunched.receipts.count == 2, "Both turns survive restart")
            for turn in 0..<3 {
                await store.submit(source: source, mode: .continueSession, session: session, model: nil, prompt: "Follow-up request \(turn)", orchestrationRunID: UUID().uuidString, intentID: UUID().uuidString.lowercased())
            }
            let repeatedCount = await fixture.count()
            precondition(repeatedCount == 4, "Repeated follow-ups work when older prompts fall out of the recent-turn window")
        } else { precondition(!store.receipts.contains { $0.id == newID }, "Refused handoff cannot create a delivery receipt") }
    }
    print("PASS follow-up delivery: idle exact native reply, active/unknown/refreshed-row fences, duplicate intent, unchanged review status, durable two-turn history")
}
