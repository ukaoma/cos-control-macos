import Foundation
import AppKit
import Combine
import CryptoKit

private actor WorkChatFixture {
    let ids: [String]
    let planners: [String]?
    var calls: [String] = []
    var contextReads = 0
    var chatBodies: [[String: Any]] = []
    init(_ ids: [String], planners: [String]? = ["sonnet", "opus"]) { self.ids = ids; self.planners = planners }
    func seen() -> [String] { calls }
    func plannerSent() -> [String?] { chatBodies.map { $0["planner"] as? String } }
    func plannerKeySent() -> [Bool] { chatBodies.map { $0["planner"] != nil } }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        let name = args.first ?? ""; calls.append(name)
        var out: [String: JSONValue] = [:]
        switch name {
        case "work-models": out = ["serverInstanceId": .string("fixture-server"), "models": .array([])]
        case "claude-sessions": out = ["sessions": .array(ids.prefix(2).map { id in .object([
            "id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])),
            "name": .string("Exact " + id), "workspace": .string("/tmp/fixture"), "state": .string("recent")]) })]
        case "work-context":
            contextReads += 1
            out = ["contextText": .string("Fixture task evidence"), "workRevision": .string(String(repeating: contextReads == 1 ? "a" : "b", count: 64)), "task": .object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")])]
        case "work-chat-capabilities":
            out = ["protocolVersion": .number(1)]
            if let planners { out["planners"] = .array(planners.map { .string($0) }) }
        case "work-chat":
            if let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { chatBodies.append(body) }
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
    precondition(chat.record?.rounds.count == 1 && chat.record?.rounds[0].state == "Ready to send", "Planning stops at review")
    precondition(handoff.receipts.isEmpty, "Planning never dispatches: nothing is sent before Miles reviews it")
    precondition(chat.record?.draftRTF == nil, "A planned draft clears its local rich text")
    let planned = chat.record!.rounds[0]
    precondition(planned.assignments.count == 2 && planned.assignments.allSatisfy { $0.state == "Not sent" })
    let reopened = WorkTaskChatStore(); reopened.open(source: source, handoff: handoff)
    precondition(reopened.record?.rounds[0].state == "Ready to send" && reopened.record?.rounds[0].assignments.map(\.receiptID) == planned.assignments.map(\.receiptID), "Reviewed drafts survive restart with their intent ids")
    let firstID = planned.assignments[0].receiptID
    for bad in [String(repeating: "x", count: 2001), "   ", "COS-**WORK** abc: done"] {
        precondition(!chat.editAssignment(roundID: planned.id, assignmentID: firstID, prompt: bad), "An edit gets the planner's validation")
    }
    precondition(chat.record?.rounds[0].assignments[0].prompt == planned.assignments[0].prompt, "A refused edit changes nothing")
    precondition(chat.editAssignment(roundID: planned.id, assignmentID: firstID, prompt: "  Review the header copy only. Do not publish.  "))
    precondition(chat.record?.rounds[0].assignments[0].prompt == "Review the header copy only. Do not publish.")
    chat.holdForLater(roundID: planned.id)
    await chat.sendAssignment(roundID: planned.id, assignmentID: firstID, source: source, handoff: handoff)
    await chat.sendAll(roundID: planned.id, source: source, handoff: handoff)
    precondition(handoff.receipts.isEmpty && chat.record?.rounds[0].state == "Saved as drafts", "Not now keeps drafts and sends nothing")
    let heldRelaunch = WorkTaskChatStore(); heldRelaunch.open(source: source, handoff: handoff)
    precondition(heldRelaunch.record?.rounds[0].state == "Saved as drafts" && heldRelaunch.record?.rounds[0].assignments[0].prompt == "Review the header copy only. Do not publish.", "Saved drafts and edits survive restart")
    chat.reviewDrafts(roundID: planned.id)
    await chat.sendAssignment(roundID: planned.id, assignmentID: firstID, source: source, handoff: handoff)
    precondition(handoff.receipts.count == 1 && handoff.receipts[0].id == firstID && handoff.receipts[0].prompt.contains("Review the header copy only. Do not publish."), "Send dispatches exactly the reviewed, edited assignment")
    precondition(chat.record?.rounds[0].state == "Ready to send" && chat.record?.rounds[0].assignments[1].state == "Not sent", "One send leaves the other assignment sendable")
    await chat.sendAssignment(roundID: planned.id, assignmentID: firstID, source: source, handoff: handoff)
    precondition(handoff.receipts.count == 1, "A second click on a sent assignment never resends")
    await chat.sendAll(roundID: planned.id, source: source, handoff: handoff)
    precondition(chat.record?.rounds[0].state == "Dispatched", "Send all sends what is left")
    precondition(handoff.receipts.count == 2 && Set(handoff.receipts.compactMap(\.sessionID)) == Set(ids.prefix(2)))
    precondition(Set(handoff.receipts.compactMap(\.orchestrationRunID)).count == 1)
    let id = handoff.receipts[0].id
    await handoff.submit(source: source, mode: .continueSession, session: sessions[0], model: nil, prompt: "Duplicate", orchestrationRunID: chat.record!.rounds[0].id, intentID: id)
    precondition(handoff.receipts.count == 2, "A duplicate intent or target cannot dispatch twice")
    let relaunched = WorkTaskChatStore(); relaunched.open(source: source, handoff: handoff)
    precondition(relaunched.record?.rounds.first?.assignments.map(\.receiptID) == chat.record?.rounds.first?.assignments.map(\.receiptID), "Chat survives restart with exact receipts")
    chat.setDraft("Do more")
    await chat.send(source: source, handoff: handoff)
    precondition(handoff.receipts.count == 2 && chat.record?.rounds.count == 1, "Earlier unresolved handoffs stop planning")
    precondition(chat.record?.draft == "Do more", "A held card keeps the request in the composer")
    precondition(Set(chat.blockers.map(\.id)) == Set(handoff.receipts.map(\.id)) && chat.error == WorkChatPreflight.heading, "The pre-flight lists every receipt holding the card")
    // A request refused before 0.5.308 (Needs attention, nothing sent) still restores for review.
    chat.setDraft("")
    var refusedRound = WorkChatRound(question: "Do more"); refusedRound.state = "Needs attention"
    refusedRound.assignments = [WorkChatAssignment(sessionID: ids[0], prompt: "Do more work")]
    chat.record?.rounds.append(refusedRound)
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
    await chat.recheckBlockers(source: source, handoff: handoff)
    precondition(chat.blockers.isEmpty && chat.error == nil, "Resolved receipts release the card")
    // Each send re-checks the plan's task revision; a change stops the round before any dispatch.
    chat.setDraft("Third request"); await chat.send(source: source, handoff: handoff)
    let third = chat.record!.rounds.last!
    precondition(third.state == "Ready to send" && third.assignments.count == 2 && handoff.receipts.count == 2)
    let changed = WorkSource(id: source.id, title: source.title, revision: source.revision + "-changed", project: source.project, context: source.context)
    await chat.sendAll(roundID: third.id, source: changed, handoff: handoff)
    precondition(handoff.receipts.count == 2 && chat.record?.rounds.last?.state == "Needs a new plan" && chat.error == WorkChatPolicy.staleMessage, "A changed task is never sent from a stale plan")
    await chat.sendAssignment(roundID: third.id, assignmentID: third.assignments[0].receiptID, source: source, handoff: handoff)
    precondition(handoff.receipts.count == 2, "A stale round stays unsendable")
    chat.restoreUnsentRequest(roundID: third.id)
    precondition(chat.record?.draft == "Third request", "Plan again restores the request for a new plan")
    await chat.send(source: source, handoff: handoff)
    let fourth = chat.record!.rounds.last!
    precondition(fourth.id != third.id && fourth.state == "Ready to send")
    // A receipt that appears after planning holds the next send; the assignment stays sendable.
    var stray = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: source.id, workTitle: source.title, sourceRevision: source.revision, mode: .continueSession, provider: "claude", modelID: "existing", sessionID: ids[0], sessionTitle: "Exact stray", status: "unknown", detail: "Delivery was interrupted.", prompt: "Stray", createdAt: Date().timeIntervalSince1970 - 300)
    stray.orchestrationRunID = fourth.id
    handoff.receipts.append(stray)
    await chat.sendAssignment(roundID: fourth.id, assignmentID: fourth.assignments[1].receiptID, source: source, handoff: handoff)
    precondition(handoff.receipts.count == 3 && !handoff.receipts.contains { $0.id == fourth.assignments[1].receiptID } && chat.blockers.map(\.id) == [stray.id]
        && chat.record?.rounds.last?.assignments[1].state == "Not sent", "An unknown receipt holds even the same round's other session; nothing is submitted")
    handoff.receipts.removeAll { $0.id == stray.id }
    chat.skipAssignment(roundID: fourth.id, assignmentID: fourth.assignments[0].receiptID)
    precondition(chat.record?.rounds.last?.state == "Ready to send", "Skipping one leaves the other under review")
    await chat.sendAssignment(roundID: fourth.id, assignmentID: fourth.assignments[0].receiptID, source: source, handoff: handoff)
    precondition(chat.record?.rounds.last?.assignments[0].state == "Skipped" && handoff.receipts.count == 2, "A skipped assignment is never sent")
    chat.skipAssignment(roundID: fourth.id, assignmentID: fourth.assignments[1].receiptID)
    precondition(chat.record?.rounds.last?.state == "Not sent" && handoff.receipts.count == 2, "Skipping every assignment sends nothing")
    // A session link changed since planning stops the send.
    chat.setDraft("Fifth request"); await chat.send(source: source, handoff: handoff)
    let fifth = chat.record!.rounds.last!
    precondition(fifth.state == "Ready to send")
    let removeRevision = try WorkSessionLinks.revision(handoff.confirmedSessionCards[ids[2]]!)
    precondition(handoff.removeSessionCard(sessionID: ids[2], workID: source.id, expected: removeRevision))
    await chat.sendAll(roundID: fifth.id, source: source, handoff: handoff)
    precondition(handoff.receipts.count == 2 && chat.record?.rounds.last?.state == "Needs a new plan" && chat.error == WorkChatPolicy.staleMessage, "Changed session links since planning stop the send")
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
    precondition(withFiles.receipts.isEmpty && filesChat.record?.rounds[0].state == "Ready to send")
    // A file added after planning makes the plan stale; nothing goes out until it is planned again.
    let laterURL = root.appendingPathComponent("later-notes.txt")
    try Data("Added after planning.".utf8).write(to:laterURL)
    await fileStore.intake(urls:[laterURL],source:attachmentSource)
    await filesChat.sendAll(roundID:filesChat.record!.rounds[0].id,source:attachmentSource,handoff:withFiles)
    precondition(withFiles.receipts.isEmpty && filesChat.record?.rounds[0].state == "Needs a new plan", "Attachments changed since planning stop the send")
    filesChat.restoreUnsentRequest(roundID:filesChat.record!.rounds[0].id)
    await filesChat.send(source:attachmentSource,handoff:withFiles)
    precondition(filesChat.record?.rounds.count == 2 && filesChat.record?.rounds[1].state == "Ready to send")
    await filesChat.sendAll(roundID:filesChat.record!.rounds[1].id,source:attachmentSource,handoff:withFiles)
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
    await candidate.loadPlanners(handoff: real)
    precondition(candidate.planners == ["sonnet", "opus"], "The advertised planners are offered")
    let first = Task { await candidate.send(source: source, handoff: real, planner: "opus") }
    try await Task.sleep(for: .milliseconds(50))
    await candidate.send(source: source, handoff: real)
    let other = WorkSource(id: "task:quilt:bbbbbbbbbbbb", title: "Other", revision: source.revision, project: "quilt", context: "")
    candidate.open(source: other, handoff: real)
    precondition(candidate.record?.workID == source.id, "Navigation cannot redirect an in-flight request")
    await first.value
    let calls = await fixture.seen()
    precondition(calls.filter { $0 == "work-chat" }.count == 1, "Double Send produces one plan: \(calls)")
    precondition(real.receipts.isEmpty, "Planning never dispatches: \(real.receipts.map(\.status))")
    precondition(candidate.record?.rounds.first?.state == "Ready to send", "A plan waits for review: \(candidate.record?.rounds.map(\.state) ?? []) \(candidate.error ?? "")")
    let sentPlanner = await fixture.plannerSent()
    precondition(sentPlanner == ["opus"] && candidate.record?.rounds.first?.planner == "opus", "The chosen planner reaches the server and is recorded on the round")
    await candidate.sendAll(roundID: candidate.record!.rounds[0].id, source: source, handoff: real)
    let afterSend = await fixture.seen()
    precondition(real.receipts.isEmpty && candidate.record?.rounds.first?.state == "Needs a new plan" && candidate.error == WorkChatPolicy.staleMessage
        && afterSend.filter { $0 == "work-context" }.count == 2, "A task changed since planning stops every send before native delivery")
    // An older server advertises no planners: no picker, and the planner key is never sent (6.73.9 refuses unknown keys).
    let oldFixture = WorkChatFixture(ids, planners: nil)
    let oldServer = WorkHandoffStore(storageURL: root.appendingPathComponent("old-server.json"), transport: { args,data in try await oldFixture.run(args,data) })
    for id in ids.prefix(2) { precondition(oldServer.confirmSessionCard(sessionID: id, source: source)) }
    await oldServer.refresh()
    let oldChat = WorkTaskChatStore(); oldChat.enabled = true; oldChat.open(source: source, handoff: oldServer); oldChat.setDraft("Review on an older server")
    await oldChat.loadPlanners(handoff: oldServer)
    precondition(oldChat.planners.isEmpty, "An older server offers no planner choice")
    await oldChat.send(source: source, handoff: oldServer, planner: "opus")
    let oldKeys = await oldFixture.plannerKeySent()
    precondition(oldKeys == [false] && oldChat.record?.rounds.last?.planner == "sonnet" && oldServer.receipts.isEmpty, "An older server plans with Sonnet and never receives the planner key")
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
    try runWorkChatPreflightChecks(source: source, sessions: sessions)
    try await runWorkChatPartialRefusalChecks(source: source, ids: ids, root: root)
    try await runWorkContinuationChecks(source: source, session: sessions[0], root: root)
    try await runWorkIndependentRecoveryChecks(source: source, sessions: sessions, root: root)
    try await runWorkChatTypingChecks(source: source, handoff: handoff, root: root)
    print("PASS Work orchestration: exact target policy, private CAS/symlinks, plan-then-review (edit, Not now, per-assignment Send, Skip, Send all), shared distinct-target run, duplicate/foreign-run fences and pre-flight, durable history, all-round provenance, navigation/double-send/task-revision drift; zero provider sends")
}

/// 0.5.308: one assignment's session refuses at delivery; Send all still sends the other (2026-10-15: the first refusal
/// threw and the second assignment was never tried). Real store, real submit, fake transport; no live provider.
private actor WorkPartialSendFixture {
    let ids: [String]
    private var sends: [String] = []
    init(_ ids: [String]) { self.ids = ids }
    func sent() -> [String] { sends }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        var out: [String: JSONValue] = [:]
        let thread = args.firstIndex(of: "--thread-id").map { args[$0 + 1] } ?? ""
        switch args.first ?? "" {
        case "work-models": out = ["serverInstanceId": .string("partial-server"), "models": .array([])]
        case "claude-sessions": out = ["sessions": .array(ids.prefix(2).map { id in .object([
            "id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])),
            "name": .string("Exact " + id), "workspace": .string("/tmp/fixture"), "state": .string("recent")]) })]
        case "work-context": out = ["contextText": .string("Fixture task evidence"), "workRevision": .string(String(repeating: "c", count: 64)), "task": .object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")])]
        case "work-chat": out = ["protocolVersion": .number(1), "answer": .string("Two independent checks."),
            "assignments": .array(ids.prefix(2).map { .object(["sessionID": .string($0), "prompt": .string("Report checks; do not publish.")]) })]
        // The first session refuses at delivery; the second accepts.
        case "session-chat-attachability": out = ["attachable": .bool(!ids[0].hasSuffix(thread)), "reasonCopy": .string("Fixture refusal: this session cannot be continued.")]
        case "session-chat-attach": out = ["state": .string("attached"), "bindingId": .string("partial-fixture"), "epoch": .number(1), "boundTo": .string("exact-target")]
        case "session-chat-send": sends.append(thread); out = ["state": .string("completed")]
        default: preconditionFailure("Partial-send fixture must not reach \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@MainActor private func runWorkChatPartialRefusalChecks(source: WorkSource, ids: [String], root: URL) async throws {
    let fixture = WorkPartialSendFixture(ids)
    let store = WorkHandoffStore(storageURL: root.appendingPathComponent("partial.json"), transport: { args, data in try await fixture.run(args, data) })
    for id in ids.prefix(2) { precondition(store.confirmSessionCard(sessionID: id, source: source)) }
    await store.refresh()
    let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: source, handoff: store); chat.setDraft("Run both checks")
    await chat.send(source: source, handoff: store)
    let round = chat.record!.rounds.last!
    precondition(round.state == "Ready to send" && store.receipts.isEmpty)
    await chat.sendAll(roundID: round.id, source: source, handoff: store)
    let sent = await fixture.sent()
    let after = chat.record!.rounds.last!
    precondition(after.assignments[0].state == "refused" && after.assignments[0].detail.contains("Fixture refusal"), "A refusal marks only its own assignment, with its reason")
    precondition(sent == [String(ids[1].split(separator: ":")[1])] && after.assignments[1].state == "delivered", "A refusal never stops the other assignment from being sent")
    precondition(after.state == "Dispatched" && store.receipts.count == 2)
    print("PASS Work chat partial refusal: one refused delivery, the other sent, both recorded")
}

/// 0.5.308: the one fence submit and the task chat's pre-flight share, the planner choice, and the review rules.
@MainActor private func runWorkChatPreflightChecks(source: WorkSource, sessions: [WorkSession]) throws {
    let run = UUID().uuidString.lowercased()
    func row(_ status: String, session: Int, at: Double = 100) -> WorkHandoffReceipt {
        var r = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: source.id, workTitle: source.title, sourceRevision: source.revision, mode: .continueSession, provider: sessions[session].provider, modelID: "existing", sessionID: sessions[session].id, sessionTitle: sessions[session].title, status: status, detail: "", prompt: "Fixture", createdAt: at)
        r.orchestrationRunID = run; r.channel = "turn"; return r
    }
    let running = row("running", session: 0)
    precondition(WorkChatPreflight.holds(running, continuations: [:]), "A running handoff holds the card")
    precondition(!WorkChatPreflight.holds(running, continuations: [:], orchestrationRunID: run, sessionID: sessions[1].id), "One round's live delivery never holds its other session")
    precondition(WorkChatPreflight.holds(running, continuations: [:], orchestrationRunID: run, sessionID: sessions[0].id), "The same session in the same round would be a second writer")
    precondition(WorkChatPreflight.holds(running, continuations: [:], orchestrationRunID: "another-run", sessionID: sessions[1].id), "Another round's delivery holds the card")
    precondition(WorkChatPreflight.holds(row("unknown", session: 0), continuations: [:], orchestrationRunID: run, sessionID: sessions[1].id), "An unconfirmed delivery holds even its own round")
    for status in ["completed", "failed", "refused", "canceled", "reviewed"] { precondition(!WorkChatPreflight.holds(row(status, session: 0), continuations: [:]), "Terminal \(status) never holds") }
    var continued = row("delivered", session: 0); continued.continuedBy = "next"
    precondition(!WorkChatPreflight.holds(continued, continuations: [:]))
    let delivered = row("delivered", session: 0)
    precondition(WorkChatPreflight.holds(delivered, continuations: [:]), "A delivered reply holds until checked")
    let deliveredKey = try WorkChatPolicy.continuationKey(delivered)
    precondition(!WorkChatPreflight.holds(delivered, continuations: [delivered.id: deliveredKey]), "An idle exact reply lets the chat continue")
    var edited = delivered; edited.detail = "Changed since the read"
    precondition(WorkChatPreflight.holds(edited, continuations: [delivered.id: deliveredKey]), "A changed receipt voids the idle proof")
    precondition(!WorkChatPreflight.holds(delivered, continuations: [:], replacing: delivered.id), "The reply a send answers never holds it")
    var other = row("running", session: 0, at: 300); other.workID = "task:quilt:ffffffffffff"
    let older = row("queued", session: 1, at: 50), newer = row("unknown", session: 0, at: 200)
    precondition(WorkChatPreflight.blockers([older, other, newer, row("completed", session: 0)], workID: source.id, continuations: [:]).map(\.id) == [newer.id, older.id], "Blockers are this card's, newest first")
    precondition(WorkChatPreflight.line(newer, now: 200 + 7_200) == sessions[0].title + " · unknown · 2 h ago")
    precondition(WorkChatPreflight.line(newer, now: 230) == sessions[0].title + " · unknown · just now")
    precondition(WorkChatPolicy.planner(nil, advertised: []) == nil && WorkChatPolicy.planner("opus", advertised: []) == nil, "An older server gets no planner key")
    precondition(WorkChatPolicy.planner("opus", advertised: ["sonnet", "opus"]) == "opus" && WorkChatPolicy.planner("sonnet", advertised: ["sonnet", "opus"]) == "sonnet")
    precondition(WorkChatPolicy.planner("opus", advertised: ["sonnet"]) == "sonnet" && WorkChatPolicy.planner(nil, advertised: ["sonnet", "opus"]) == "sonnet", "An unoffered choice falls back to Sonnet")
    precondition(WorkChatPolicy.planner("haiku", advertised: ["sonnet", "opus", "haiku"]) == "sonnet", "Only the planners Control knows are ever requested")
    precondition(WorkChatPolicy.plannerName("opus") == "Opus" && WorkChatPolicy.plannerName(nil) == "Sonnet")
    func a(_ state: String) -> WorkChatAssignment { var x = WorkChatAssignment(sessionID: sessions[0].id, prompt: "p"); x.state = state; return x }
    precondition(WorkChatPolicy.reviewedState([a("delivered"), a("Not sent")]) == "Ready to send", "A refused-before-receipt assignment stays sendable")
    precondition(WorkChatPolicy.reviewedState([a("delivered"), a("Skipped")]) == "Dispatched" && WorkChatPolicy.reviewedState([a("Skipped"), a("Skipped")]) == "Not sent")
    precondition(WorkChatPolicy.reviewedState([a("Sending")]) == "Ready to send")
    precondition(WorkChatPolicy.validPrompt("Review copy.") && !WorkChatPolicy.validPrompt(" \n ") && !WorkChatPolicy.validPrompt(String(repeating: "x", count: 2001)) && !WorkChatPolicy.validPrompt("cos-`work` x: done"))
    print("PASS Work chat pre-flight: one shared fence (run/session exemption, unknown, continuation proof, replacing, terminal), card blockers newest first, planner choice and fallback, review states, prompt validation")
}

private actor WorkRecoveryFixture {
    let available: Bool
    private var calls: [String] = []
    init(available: Bool = true) { self.available = available }
    func seen() -> [String] { calls }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        calls.append(args.first ?? "")
        let out: [String: JSONValue]
        switch args.first {
        case "session-chat-attachability": out = ["attachable": .bool(available), "reason": .string("probe_failed"), "reasonCopy": .string("Native transport unavailable; original history retained.")]
        case "session-chat-attach": out = ["state": .string("attached"), "bindingId": .string("recovery-fixture"), "epoch": .number(1), "boundTo": .string("exact-target")]
        case "session-chat-send":
            precondition(String(data: data!, encoding: .utf8)!.contains("Independent read-only diagnosis"))
            out = ["state": .string("completed")]
        default: preconditionFailure("Recovery must use only the exact native Continue path: \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@MainActor private func runWorkIndependentRecoveryChecks(source: WorkSource, sessions: [WorkSession], root: URL) async throws {
    struct Journal: Encodable { var version = 2; var receipts: [WorkHandoffReceipt]; var sessions: [WorkSession] }
    let encoder = JSONEncoder()
    var held = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: source.id, workTitle: source.title, sourceRevision: source.revision, mode: .continueSession, provider: sessions[1].provider, modelID: "existing", sessionID: sessions[1].id, sessionTitle: sessions[1].title, status: "running", detail: "Accepted; delivery not confirmed", prompt: "Earlier work, do not duplicate", createdAt: 100)
    held.channel = "turn"
    let frozen = try WorkChatPolicy.continuationKey(held)
    let proof = WorkIndependentRecovery(workID: source.id, revision: source.revision, receipts: [held.id: frozen], assignmentID: "blocked-assignment")
    precondition(WorkIndependentRecovery.permits(proof, source: source, mode: .continueSession, sessionID: sessions[0].id, rows: [held]))
    precondition(!WorkIndependentRecovery.permits(proof, source: source, mode: .continueSession, sessionID: held.sessionID, rows: [held]), "Approval cannot create a second writer on the original target")
    precondition(WorkIndependentRecovery.permits(proof, source: source, mode: .fork, sessionID: held.sessionID, rows: [held]), "An explicitly confirmed fork creates a separate child")
    precondition(WorkIndependentRecovery.permits(proof, source: source, mode: .newSession, sessionID: nil, rows: [held]))
    var changed = held; changed.status = "unknown"
    precondition(!WorkIndependentRecovery.permits(proof, source: source, mode: .newSession, sessionID: nil, rows: [changed]), "Receipt changes expire confirmation")
    var extra = held; extra.id = UUID().uuidString.lowercased(); extra.sessionID = sessions[0].id
    precondition(!WorkIndependentRecovery.permits(proof, source: source, mode: .continueSession, sessionID: sessions[0].id, rows: [held, extra]))
    var unbound = held; unbound.sessionID = nil
    let unboundProof = WorkIndependentRecovery(workID: source.id, revision: source.revision, receipts: [unbound.id: try WorkChatPolicy.continuationKey(unbound)], assignmentID: nil)
    precondition(!WorkIndependentRecovery.permits(unboundProof, source: source, mode: .continueSession, sessionID: sessions[0].id, rows: [unbound]))

    for scenario in ["approved", "ordinary", "same", "changed", "unavailable"] {
        let file = root.appendingPathComponent("recovery-" + scenario + ".json")
        try encoder.encode(Journal(receipts: [held], sessions: sessions)).write(to: file)
        let fixture = WorkRecoveryFixture(available: scenario != "unavailable")
        let store = WorkHandoffStore(storageURL: file, transport: { args, data in try await fixture.run(args, data) })
        precondition(store.prepareIndependentRecovery(source: source, prompt: "Independent read-only diagnosis", assignmentID: "blocked-assignment"))
        let prepared = store.independentRecovery!
        let beforeReceipt = try WorkChatPolicy.continuationKey(store.receipts[0])
        precondition(beforeReceipt == frozen, "Preparing never clears an earlier receipt")
        let before = await fixture.seen(); precondition(before.isEmpty, "Destination preparation sends no provider message")
        if scenario == "changed" { try encoder.encode(Journal(receipts: [changed], sessions: sessions)).write(to: file) }
        let target = scenario == "same" ? sessions[1] : sessions[0]
        let id = UUID().uuidString.lowercased()
        await store.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Independent read-only diagnosis", intentID: id, recovery: scenario == "ordinary" ? nil : prepared)
        let calls = await fixture.seen()
        precondition(calls.filter { $0 == "session-chat-send" }.count == (scenario == "approved" ? 1 : 0), "Independent recovery admission: \(scenario)")
        if scenario == "approved" || scenario == "unavailable" {
            let recovered = store.receipts.first { $0.id == id }!
            precondition(recovered.recoveryOf == [held.id] && recovered.recoveryAssignmentID == "blocked-assignment")
            precondition(recovered.status == (scenario == "approved" ? "delivered" : "refused"))
            let originalAfter = try WorkChatPolicy.continuationKey(store.receipts.first { $0.id == held.id }!)
            precondition(originalAfter == frozen)
            let relaunched = WorkHandoffStore(storageURL: file, transport: { _,_ in preconditionFailure("Restart cannot send") })
            precondition(relaunched.independentRecovery == nil, "Confirmation is local and never survives relaunch")
            precondition(relaunched.receipts.first { $0.id == id }?.recoveryOf == [held.id], "Recovery lineage survives restart")
            await store.submit(source: source, mode: .continueSession, session: target, model: nil, prompt: "Independent read-only diagnosis", intentID: id, recovery: prepared)
            let again = await fixture.seen(); precondition(again.filter { $0 == "session-chat-send" }.count == (scenario == "approved" ? 1 : 0), "A confirmed intent is never dispatched twice")
        } else { precondition(!store.receipts.contains { $0.id == id }) }
    }

    for mode in [WorkHandoffMode.fork, .newSession] {
        let file = root.appendingPathComponent("recovery-child-" + mode.rawValue + ".json")
        try encoder.encode(Journal(receipts: [held], sessions: sessions)).write(to: file)
        let store = WorkHandoffStore(isolated: true, storageURL: file, transport: { _,_ in preconditionFailure("Child fixture has no provider") })
        precondition(store.prepareIndependentRecovery(source: source, prompt: "Independent read-only diagnosis"))
        store.cancelIndependentRecovery()
        precondition(store.receipts.count == 1 && store.independentRecovery == nil, "Cancel creates no chat or receipt")
        precondition(store.prepareIndependentRecovery(source: source, prompt: "Independent read-only diagnosis"))
        let prepared = store.independentRecovery!
        let id = UUID().uuidString.lowercased()
        await store.submit(source: source, mode: mode, session: mode == .fork ? sessions[1] : nil, model: mode == .newSession ? store.models.first(where: { $0.available }) : nil, prompt: "Independent read-only diagnosis", intentID: id, recovery: prepared)
        let child = store.receipts.first { $0.id == id }!
        precondition(child.sessionID != held.sessionID && child.recoveryOf == [held.id], "Fork/New retains a distinct exact child and lineage")
        let childOriginal = try WorkChatPolicy.continuationKey(store.receipts.first { $0.id == held.id }!)
        precondition(childOriginal == frozen)
    }
    print("PASS independent recovery: explicit proof, unchanged pending outcome, distinct native target/child, unavailable transport, stale journal, duplicate intent, cancellation and durable lineage; zero live messages")
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
