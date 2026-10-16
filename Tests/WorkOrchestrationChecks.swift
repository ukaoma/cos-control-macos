import Foundation
import AppKit
import SwiftUI
import CoreText
import Combine
import CryptoKit

private actor WorkChatFixture {
    let ids: [String]
    let planners: [String]?
    var calls: [String] = []
    var contextReads = 0
    var chatBodies: [[String: Any]] = []
    let model: String
    var capabilityFailures = 0
    init(_ ids: [String], planners: [String]? = ["sonnet", "opus"], model: String = "claude:opus-fixture-model") { self.ids = ids; self.planners = planners; self.model = model }
    func failCapabilities(_ times: Int) { capabilityFailures = times }
    var echoEffort = true
    func stopEchoingEffort() { echoEffort = false }
    func seen() -> [String] { calls }
    func plannerSent() -> [String?] { chatBodies.map { $0["planner"] as? String } }
    func plannerKeySent() -> [Bool] { chatBodies.map { $0["planner"] != nil } }
    func effortSent() -> [String?] { chatBodies.map { $0["effort"] as? String } }
    func itemsSent() -> [Bool] { chatBodies.map { $0["items"] != nil } }
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
            if capabilityFailures > 0 { capabilityFailures -= 1; throw HelperClientError.commandFailed("Task chat planner discovery got no answer from the server.") }
            out = ["protocolVersion": .number(1)]
            // A planners-advertising fixture is a 6.73.12 server, which also advertises efforts.
            if let planners { out["planners"] = .array(planners.map { .string($0) }); out["efforts"] = .array(["low", "medium", "high"].map { .string($0) }) }
        case "work-chat":
            var ranEffort: String? = planners == nil ? nil : "high"
            if let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { chatBodies.append(body); ranEffort = (body["effort"] as? String) ?? ranEffort }
            // Let a second Send and a navigation change race with planning.
            try await Task.sleep(for: .milliseconds(100))
            out = ["protocolVersion": .number(1), "answer": .string("Review independent copy and code checks."), "model": .string(model),
                "assignments": .array(ids.prefix(2).map { .object(["sessionID": .string($0), "prompt": .string("Report checks; do not publish.")]) })]
            if let ranEffort, echoEffort { out["effort"] = .string(ranEffort) }
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
    precondition(candidate.efforts == ["low", "medium", "high"], "The advertised efforts are offered")
    let first = Task { await candidate.send(source: source, handoff: real, planner: "opus", effort: "medium") }
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
    precondition(candidate.record?.rounds.first?.plannerModel == "claude:opus-fixture-model", "The round keeps the model the server reports ran")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: candidate.record?.rounds.first?.plannerModel) == "planned with opus-fixture-model", "Only the server's report becomes \"planned with\"")
    let sentEffort = await fixture.effortSent()
    precondition(sentEffort == ["medium"] && candidate.record?.rounds.first?.plannerEffort == "medium", "The chosen effort reaches the server and the reported effort is recorded")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: candidate.record?.rounds.first?.plannerModel, effort: candidate.record?.rounds.first?.plannerEffort) == "planned with opus-fixture-model · medium effort", "The round names the model and effort the server reports")
    await candidate.sendAll(roundID: candidate.record!.rounds[0].id, source: source, handoff: real)
    let afterSend = await fixture.seen()
    precondition(real.receipts.isEmpty && candidate.record?.rounds.first?.state == "Needs a new plan" && candidate.error == WorkChatPolicy.staleMessage
        && afterSend.filter { $0 == "work-context" }.count == 2, "A task changed since planning stops every send before native delivery")
    // An older server advertises no planners: no picker, and the planner key is never sent (6.73.9 refuses unknown keys).
    let oldFixture = WorkChatFixture(ids, planners: nil, model: "claude:sonnet (requested)")
    let oldServer = WorkHandoffStore(storageURL: root.appendingPathComponent("old-server.json"), transport: { args,data in try await oldFixture.run(args,data) })
    for id in ids.prefix(2) { precondition(oldServer.confirmSessionCard(sessionID: id, source: source)) }
    await oldServer.refresh()
    let oldChat = WorkTaskChatStore(); oldChat.enabled = true; oldChat.open(source: source, handoff: oldServer); oldChat.setDraft("Review on an older server")
    await oldChat.loadPlanners(handoff: oldServer)
    precondition(oldChat.planners.isEmpty && oldChat.efforts.isEmpty && oldChat.plannerNotice == nil, "An older server offers no planner or effort choice, and that is not a failure")
    await oldChat.send(source: source, handoff: oldServer, planner: "opus", effort: "high")
    let oldKeys = await oldFixture.plannerKeySent()
    let oldEffort = await oldFixture.effortSent()
    precondition(oldEffort == [nil] && oldChat.record?.rounds.last?.plannerEffort == nil, "An older server never receives the effort key, and no effort is claimed")
    precondition(oldKeys == [false] && oldChat.record?.rounds.last?.planner == "sonnet" && oldServer.receipts.isEmpty, "An older server plans with Sonnet and never receives the planner key")
    // 0.5.312: an older server never receives items; every assignment sends every item, and the round says so.
    let oldItemsSent = await oldFixture.itemsSent()
    let oldRound = oldChat.record!.rounds.last!
    precondition(oldItemsSent == [false] && oldRound.contextChosen == false && oldRound.contextItems?.isEmpty == false
        && oldRound.assignments.allSatisfy { $0.contextItemIDs == oldRound.contextItems?.map(\.id) }, "An older server falls back to every item, honestly marked")
    precondition(WorkChatPolicy.plannerLabel(requested: oldChat.record?.rounds.last?.planner, ran: oldChat.record?.rounds.last?.plannerModel) == "requested Sonnet (not confirmed)", "A requested model is never shown as the one that ran")
    // 0.5.310: a server that fails planner discovery is retried once, then named, never silently hidden.
    await fixture.failCapabilities(1)
    let retried = WorkTaskChatStore(); retried.enabled = true
    await retried.loadPlanners(handoff: real, retryDelay: .zero)
    precondition(retried.planners == ["sonnet", "opus"] && retried.efforts == ["low", "medium", "high"] && retried.plannerNotice == nil, "One failed discovery is retried and recovers")
    await fixture.failCapabilities(2)
    let unavailable = WorkTaskChatStore(); unavailable.enabled = true
    await unavailable.loadPlanners(handoff: real, retryDelay: .zero)
    precondition(unavailable.planners.isEmpty && unavailable.efforts.isEmpty && unavailable.plannerNotice == WorkChatPolicy.plannerUnavailable, "Two failed discoveries say the choice is unavailable and Sonnet is used")
    // A server that took the effort but did not report one: the round claims no effort.
    await fixture.stopEchoingEffort()
    let unreported = WorkTaskChatStore(); unreported.enabled = true; unreported.open(source: source, handoff: real)
    await unreported.loadPlanners(handoff: real, retryDelay: .zero)
    unreported.setDraft("Plan without a reported effort")
    await unreported.send(source: source, handoff: real, planner: "opus", effort: "low")
    let lastEffort = await fixture.effortSent().last ?? nil
    precondition(lastEffort == "low" && unreported.record?.rounds.last?.state == "Ready to send" && unreported.record?.rounds.last?.plannerEffort == nil, "A requested effort is never recorded as the one that ran")
    let capabilityCalls = await fixture.seen().filter { $0 == "work-chat-capabilities" }.count
    precondition(capabilityCalls == 6, "Discovery asks once, retries once, and no more: \(capabilityCalls)")
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
    try runWorkContextMeterPureChecks(sessions: sessions)
    try await runWorkContextMeterChecks(source: source, ids: ids, sessions: sessions, root: root)
    try await runWorkChatPartialRefusalChecks(source: source, ids: ids, root: root, autoSend: true)
    try await runWorkChatAutoSendChecks(source: source, ids: ids, sessions: sessions, root: root)
    try await runWorkChatPartialRefusalChecks(source: source, ids: ids, root: root)
    try await runWorkChatPartialRefusalChecks(source: source, ids: ids, root: root, refuseAll: true)
    // A round whose every assignment was refused or failed never becomes "Results available" on a poll.
    var undelivered = WorkChatRound(question: "Nothing arrived"); undelivered.state = "Not delivered"
    var refusedOne = WorkChatAssignment(sessionID: ids[0], prompt: "One"); refusedOne.state = "refused"
    var failedOne = WorkChatAssignment(sessionID: ids[1], prompt: "Two"); failedOne.state = "failed"
    undelivered.assignments = [refusedOne, failedOne]; legacyChat.record?.rounds.append(undelivered)
    await legacyChat.refresh(source: legacySource, handoff: handoff, automatic: true)
    precondition(legacyChat.record?.rounds.last?.state == "Not delivered", "Refused and failed assignments are never reported as results")
    try await runWorkContinuationChecks(source: source, session: sessions[0], root: root)
    try await runWorkIndependentRecoveryChecks(source: source, sessions: sessions, root: root)
    try await runWorkChatTypingChecks(source: source, handoff: handoff, root: root)
    try await runWorkChatQueueChecks(ids: ids, sessions: sessions, root: root)
    print("PASS Work orchestration: exact target policy, private CAS/symlinks, plan-then-review (edit, Not now, per-assignment Send, Skip, Send all), shared distinct-target run, duplicate/foreign-run fences and pre-flight, durable history, all-round provenance, navigation/double-send/task-revision drift; zero provider sends")
}

/// 0.5.308: one assignment's session refuses at delivery; Send all still sends the other (2026-10-15: the first refusal
/// threw and the second assignment was never tried). Real store, real submit, fake transport; no live provider.
private actor WorkPartialSendFixture {
    let ids: [String]
    let refuseAll: Bool
    let server: String
    private var sends: [String] = []
    init(_ ids: [String], refuseAll: Bool = false, server: String? = nil) { self.ids = ids; self.refuseAll = refuseAll; self.server = server ?? (refuseAll ? "refuse-all-server" : "partial-server") }
    func sent() -> [String] { sends }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        var out: [String: JSONValue] = [:]
        let thread = args.firstIndex(of: "--thread-id").map { args[$0 + 1] } ?? ""
        switch args.first ?? "" {
        case "work-models": out = ["serverInstanceId": .string(server), "models": .array([])]
        case "claude-sessions": out = ["sessions": .array(ids.prefix(2).map { id in .object([
            "id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])),
            "name": .string("Exact " + id), "workspace": .string("/tmp/fixture"), "state": .string("recent")]) })]
        case "work-context": out = ["contextText": .string("Fixture task evidence"), "workRevision": .string(String(repeating: "c", count: 64)), "task": .object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")])]
        case "work-chat": out = ["protocolVersion": .number(1), "answer": .string("Two independent checks."),
            "assignments": .array(ids.prefix(2).map { .object(["sessionID": .string($0), "prompt": .string("Report checks; do not publish.")]) })]
        // The first session refuses at delivery; the second accepts.
        case "session-chat-attachability": out = ["attachable": .bool(!refuseAll && !ids[0].hasSuffix(thread)), "reasonCopy": .string("Fixture refusal: this session cannot be continued.")]
        case "session-chat-attach": out = ["state": .string("attached"), "bindingId": .string("partial-fixture"), "epoch": .number(1), "boundTo": .string("exact-target")]
        case "session-chat-send": sends.append(thread); out = ["state": .string("completed")]
        default: preconditionFailure("Partial-send fixture must not reach \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@MainActor private func runWorkChatPartialRefusalChecks(source: WorkSource, ids: [String], root: URL, refuseAll: Bool = false, autoSend: Bool = false) async throws {
    let fixture = WorkPartialSendFixture(ids, refuseAll: refuseAll, server: autoSend ? "partial-auto-server" : nil)
    let store = WorkHandoffStore(storageURL: root.appendingPathComponent(autoSend ? "partial-auto.json" : refuseAll ? "refuse-all.json" : "partial.json"), transport: { args, data in try await fixture.run(args, data) })
    for id in ids.prefix(2) { precondition(store.confirmSessionCard(sessionID: id, source: source)) }
    await store.refresh()
    let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: source, handoff: store); chat.setDraft("Run both checks")
    if autoSend {
        // 0.5.312: Plan and send uses the same per-assignment path; a refusal on one never stops the other.
        await chat.send(source: source, handoff: store, autoSend: true)
        precondition(chat.record!.rounds.last!.sentWithoutReview == true, "The round records it was sent without review")
    } else {
        await chat.send(source: source, handoff: store)
        let round = chat.record!.rounds.last!
        precondition(round.state == "Ready to send" && store.receipts.isEmpty)
        await chat.sendAll(roundID: round.id, source: source, handoff: store)
    }
    let sent = await fixture.sent()
    let after = chat.record!.rounds.last!
    if refuseAll {
        // 0.5.310: an all-refused round read "Dispatched".
        precondition(sent.isEmpty && after.assignments.allSatisfy { $0.state == "refused" && $0.detail.contains("Fixture refusal") } && store.receipts.count == 2, "Every assignment keeps its own refusal")
        precondition(after.state == "Not delivered", "A round with nothing delivered never reads Dispatched: \(after.state)")
        print("PASS Work chat all refused: Not delivered, each reason kept, nothing sent")
        return
    }
    precondition(after.assignments[0].state == "refused" && after.assignments[0].detail.contains("Fixture refusal"), "A refusal marks only its own assignment, with its reason")
    precondition(sent == [String(ids[1].split(separator: ":")[1])] && after.assignments[1].state == "delivered", "A refusal never stops the other assignment from being sent")
    precondition(after.state == "Dispatched" && store.receipts.count == 2)
    print("PASS Work chat partial refusal\(autoSend ? " (Plan and send)" : ""): one refused delivery, the other sent, both recorded")
}

/// 0.5.312: a 6.73.13 server that chooses each assignment's context items. Records what it was told and what was sent.
private actor WorkContextFixture {
    let ids: [String]
    private(set) var chatBody: [String: Any] = [:]
    private(set) var prompts: [String: String] = [:]
    init(_ ids: [String]) { self.ids = ids }
    /// Sendable copy for the checks: each item's keys and its values as text (estTokens included), so it can leave the actor.
    func items() -> [[String: String]] { (chatBody["items"] as? [[String: Any]] ?? []).map { $0.mapValues { "\($0)" } } }
    func prompt(_ native: String) -> String { prompts[native] ?? "" }
    static let context = "Canonical Work ID: task:quilt:aaaaaaaaaaaa\nTask: Launch fixture\nDomain: quilt\nStage: draft\nDone when: Launch reviewed\nSource: Fixture evidence\n"
        + WorkContextMeter.meetingsHeader + "\n- Oct 14 meeting | canonical ID: g2:onboarding14 | domain: quilt | month: 2026-10 | file: a.md"
        + "\n- Oct 15 call | canonical ID: g2:recording15 | domain: quilt | month: 2026-10 | file: b.md"
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        var out: [String: JSONValue] = [:]
        let thread = args.firstIndex(of: "--thread-id").map { args[$0 + 1] } ?? ""
        switch args.first ?? "" {
        case "work-models": out = ["serverInstanceId": .string("context-server"), "models": .array([])]
        case "claude-sessions": out = ["sessions": .array(ids.prefix(2).map { id in .object([
            "id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])),
            "name": .string("Exact " + id), "workspace": .string("/tmp/fixture"), "state": .string("recent")]) })]
        case "work-chat-capabilities": out = ["protocolVersion": .number(1), "planners": .array([.string("sonnet"), .string("opus")]), "efforts": .array([.string("high")]), "contextItems": .bool(true)]
        case "work-context": out = ["contextText": .string(Self.context), "workRevision": .string(String(repeating: "d", count: 64)), "task": .object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")])]
        case "work-chat":
            chatBody = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            // The onboarding session needs only the Oct 14 meeting; the server leaves the recording session's choice out,
            // which means every item.
            out = ["protocolVersion": .number(1), "answer": .string("Two independent checks."), "assignments": .array([
                .object(["sessionID": .string(ids[0]), "prompt": .string("Onboarding only."), "contextItemIDs": .array(["req", "task", "cos", WorkContextMeter.itemID("meet", "g2:onboarding14")].map { .string($0) })]),
                .object(["sessionID": .string(ids[1]), "prompt": .string("Recording only.")])])]
        case "session-chat-attachability": out = ["attachable": .bool(true)]
        case "session-chat-attach": out = ["state": .string("attached"), "bindingId": .string("context-fixture"), "epoch": .number(1), "boundTo": .string("exact-target")]
        case "session-chat-send": prompts[thread] = data.map { String(decoding: $0, as: UTF8.self) } ?? ""; out = ["state": .string("completed")]
        // The first delivery is checked for an idle reply before the second send; no history means no exemption is claimed.
        case "session-recent-replies": throw HelperClientError.commandFailed("Fixture has no session history")
        default: preconditionFailure("Context fixture must not reach \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@MainActor private func runWorkContextMeterChecks(source: WorkSource, ids: [String], sessions: [WorkSession], root: URL) async throws {
    // Real path: the server chooses, Miles edits, the send carries only the assignment's items.
    let fixture = WorkContextFixture(ids)
    let store = WorkHandoffStore(storageURL: root.appendingPathComponent("context.json"), transport: { args, data in try await fixture.run(args, data) })
    for id in ids.prefix(2) { precondition(store.confirmSessionCard(sessionID: id, source: source)) }
    await store.refresh()
    let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: source, handoff: store)
    await chat.loadPlanners(handoff: store)
    precondition(chat.contextItemsOffered, "A 6.73.13 server offers context items")
    chat.setDraft("Split onboarding and recording")
    await chat.send(source: source, handoff: store, planner: "opus", effort: "high")
    let told = await fixture.items()
    let round = chat.record!.rounds.last!
    let meet14 = WorkContextMeter.itemID("meet", "g2:onboarding14"), meet15 = WorkContextMeter.itemID("meet", "g2:recording15")
    precondition(round.state == "Ready to send" && round.contextChosen == true, "The server chose: \(round.state) \(String(describing: round.contextChosen))")
    precondition(told.map { $0["id"] ?? "" } == ["req", "task", meet14, meet15, "cos"], "The planner is told every linked item in order")
    precondition(told.allSatisfy { Set($0.keys) == ["id", "kind", "label", "estTokens"] }, "Items carry ids, kinds, labels and estimates only, never contents")
    precondition(round.assignments[0].contextItemIDs == ["req", "task", meet14, "cos"], "The planner's choice, in the card's order")
    precondition(round.assignments[1].contextItemIDs == ["req", "task", meet14, meet15, "cos"], "No choice from the planner means every item")
    // Edits: a fixed item never leaves; an added item persists across a restart.
    precondition(!chat.toggleContextItem(roundID: round.id, assignmentID: round.assignments[0].receiptID, itemID: "req"), "Your request is never removed")
    precondition(chat.toggleContextItem(roundID: round.id, assignmentID: round.assignments[0].receiptID, itemID: meet15))
    let reopened = WorkTaskChatStore(); reopened.open(source: source, handoff: store)
    precondition(reopened.record?.rounds.last?.assignments[0].contextItemIDs == ["req", "task", meet14, meet15, "cos"], "An edit survives restart")
    precondition(chat.toggleContextItem(roundID: round.id, assignmentID: round.assignments[0].receiptID, itemID: meet15), "Undo puts it back")
    precondition(chat.toggleContextItem(roundID: round.id, assignmentID: round.assignments[1].receiptID, itemID: meet14))
    await chat.sendAll(roundID: round.id, source: source, handoff: store)
    let first = await fixture.prompt(String(ids[0].split(separator: ":")[1])), second = await fixture.prompt(String(ids[1].split(separator: ":")[1]))
    precondition(chat.record?.rounds.last?.state == "Dispatched", "Both sent: \(chat.record?.rounds.last?.state ?? "")")
    precondition(first.contains("g2:onboarding14") && !first.contains("g2:recording15"), "The onboarding send carries only its meeting")
    precondition(second.contains("g2:recording15") && !second.contains("g2:onboarding14"), "A removed item never goes")
    precondition([first, second].allSatisfy { $0.contains("Task: Launch fixture") && $0.contains(WorkContextMeter.cosText) && $0.contains("Split onboarding and recording") }, "The fixed items always go")

    // Isolated card with two files: removing one from an assignment keeps it out of that send's file list only.
    let fileStore = WorkCardFileStore(root: root.appendingPathComponent("meter-files"), isolated: true)
    let handoff = WorkHandoffStore(isolated: true, storageURL: root.appendingPathComponent("meter.json"), transport: { _,_ in preconditionFailure("No provider calls in the meter check") }, cardFiles: fileStore)
    handoff.sessions = sessions
    let card = WorkSource.taskSnapshot(TaskRow(.object(["id": .string("eeeeeeeeeeee"), "workIdentity": .string("eeeeeeeeeeee"), "domain": .string("quilt"), "title": .string("Meter fixture"), "text": .string("Meter fixture"), "source": .string("Evidence")]))!)
    for id in ids { precondition(handoff.confirmSessionCard(sessionID: id, source: card)) }
    let keepURL = root.appendingPathComponent("keep-notes.txt"), dropURL = root.appendingPathComponent("drop-notes.txt")
    try Data(String(repeating: "keep ", count: 80).utf8).write(to: keepURL); try Data(String(repeating: "drop ", count: 80).utf8).write(to: dropURL)
    await fileStore.intake(urls: [keepURL, dropURL], source: card)
    let meter = WorkTaskChatStore(); meter.open(source: card, handoff: handoff); meter.setDraft("Use the notes")
    await meter.send(source: card, handoff: handoff)
    let planned = meter.record!.rounds.last!
    let items = planned.contextItems ?? []
    let drop = items.first { $0.label == "drop-notes.txt" }!
    precondition(planned.contextChosen == false && items.filter { $0.kind == .files }.count == 2, "The sample plan does not choose; both files are linked")
    precondition(planned.assignments.allSatisfy { $0.contextItemIDs == items.map(\.id) }, "Without a choice every assignment sends every item")
    precondition(meter.toggleContextItem(roundID: planned.id, assignmentID: planned.assignments[0].receiptID, itemID: drop.id))
    precondition(meter.editAssignment(roundID: planned.id, assignmentID: planned.assignments[0].receiptID, prompt: "Use only the keep notes."))
    let restarted = WorkTaskChatStore(); restarted.open(source: card, handoff: handoff)
    let kept = restarted.record!.rounds.last!.assignments[0]
    precondition(kept.prompt == "Use only the keep notes." && kept.contextItemIDs?.contains(drop.id) == false, "An edited prompt and a trimmed context both survive restart")
    let shown = WorkContextMeter.sendTokens(items: items, selected: meter.record!.rounds.last!.assignments[0].contextItemIDs!, provider: "claude")
    precondition(shown == WorkContextMeter.linkedTokens(items) - drop.estTokens, "Removing an item lowers that send by its estimate")
    await meter.sendAll(roundID: planned.id, source: card, handoff: handoff)
    let firstSend = handoff.receipts.first { $0.id == planned.assignments[0].receiptID }?.prompt ?? ""
    let secondSend = handoff.receipts.first { $0.id == planned.assignments[1].receiptID }?.prompt ?? ""
    precondition(firstSend.contains("keep-notes.txt") && !firstSend.contains("drop-notes.txt"), "A removed file is not in that send's file list")
    precondition(firstSend.contains("Use only the keep notes."), "The edited prompt is what was sent")
    precondition(secondSend.contains("keep-notes.txt") && secondSend.contains("drop-notes.txt"), "The other assignment still sends both")
    print("PASS Work context meter: planner choice, fixed items, persisted edits and undo, per-assignment prompts and file lists, older-server fallback")
}

/// 0.5.312 (Miles 2026-10-15): Plan and send. Off by default, asks once, and goes through every guard a manual send has.
@MainActor private func runWorkChatAutoSendChecks(source: WorkSource, ids: [String], sessions: [WorkSession], root: URL) async throws {
    precondition(WorkChatPolicy.autoSendDefault == false, "Send plans without review is off by default")
    precondition(WorkChatPolicy.confirmBeforeAutoSend(acknowledged: false) && !WorkChatPolicy.confirmBeforeAutoSend(acknowledged: true), "The first Plan and send asks once")
    let handoff = WorkHandoffStore(isolated: true, storageURL: root.appendingPathComponent("auto.json"), transport: { _,_ in preconditionFailure("No provider calls in the sample") })
    handoff.sessions = sessions
    let card = WorkSource.taskSnapshot(TaskRow(.object(["id": .string("ffffffffffff"), "workIdentity": .string("ffffffffffff"), "domain": .string("quilt"), "title": .string("Auto fixture"), "text": .string("Auto fixture"), "source": .string("Evidence")]))!)
    for id in ids { precondition(handoff.confirmSessionCard(sessionID: id, source: card)) }
    let chat = WorkTaskChatStore(); chat.open(source: card, handoff: handoff); chat.setDraft("Ship both checks")
    await chat.send(source: card, handoff: handoff, autoSend: true)
    let round = chat.record!.rounds.last!
    precondition(round.sentWithoutReview == true && round.state == "Dispatched" && handoff.receipts.count == round.assignments.count && round.assignments.count == 2,
                 "Plan and send dispatches every assignment: \(round.state), \(handoff.receipts.count)")
    precondition(round.assignments.allSatisfy { a in handoff.receipts.contains { $0.id == a.receiptID && $0.orchestrationRunID == round.id } }, "Through the same receipts and run as Send all")
    precondition(round.contextItems != nil && round.assignments.allSatisfy { $0.contextItemIDs != nil }, "The meter still records what each assignment received")
    chat.setDraft("Again, straight away")
    await chat.send(source: card, handoff: handoff, autoSend: true)
    precondition(chat.record!.rounds.count == 1 && handoff.receipts.count == 2 && chat.record?.draft == "Again, straight away" && chat.error == WorkChatPreflight.heading,
                 "Earlier unresolved handoffs stop Plan and send before it plans; the request stays")
    // A guard that trips after planning stops the send and leaves the round for review, as a manual send would.
    let fixture = WorkChatFixture(ids)
    let real = WorkHandoffStore(storageURL: root.appendingPathComponent("auto-real.json"), transport: { args, data in try await fixture.run(args, data) })
    for id in ids.prefix(2) { precondition(real.confirmSessionCard(sessionID: id, source: source)) }
    await real.refresh()
    let stale = WorkTaskChatStore(); stale.enabled = true; stale.open(source: source, handoff: real); stale.setDraft("Plan and send on a changing task")
    await stale.send(source: source, handoff: real, autoSend: true)
    let stopped = stale.record!.rounds.last!
    precondition(stopped.sentWithoutReview == true && stopped.state == "Needs a new plan" && stale.error == WorkChatPolicy.staleMessage && real.receipts.isEmpty,
                 "A task changed between planning and sending stops Plan and send before any delivery: \(stopped.state)")
    print("PASS Plan and send: off by default, asks once, dispatches every assignment through the same guards, stops on earlier handoffs and on a changed task")
}

/// 0.5.312: estimates, the context split, selection rules, totals and the canary, formatting, the disclosure memory.
@MainActor private func runWorkContextMeterPureChecks(sessions: [WorkSession]) throws {
    precondition(WorkContextMeter.textTokens("") == 0 && WorkContextMeter.textTokens("abcd") == 1 && WorkContextMeter.textTokens("abcde") == 2, "Text is about 4 characters a token, rounded up")
    precondition(WorkContextMeter.imageTokens(width: 1000, height: 1000, provider: "claude") == 1334, "Claude: width x height / 750")
    precondition((1530...1536).contains(WorkContextMeter.imageTokens(width: 3000, height: 2000, provider: "claude")), "Claude scales to 1568 px and about 1.15 MP first")
    precondition(WorkContextMeter.imageTokens(width: 1024, height: 1024, provider: "codex") == 765 && WorkContextMeter.imageTokens(width: 2356, height: 2680, provider: "codex") == 765, "Codex: 512 px tiles after fitting")
    precondition(WorkContextMeter.imageTokens(width: 512, height: 512, provider: "codex") == 255, "Codex never scales a small image up: one 512 px tile is 85 + 170")
    precondition(WorkContextMeter.imageTokens(width: 0, height: 0, provider: "claude") == 1600 && WorkContextMeter.imageTokens(width: 0, height: 0, provider: "codex") == 765, "Unknown size reads as a full image")
    precondition(WorkContextMeter.fileTokens(kind: "text", pixelWidth: nil, pixelHeight: nil, pages: nil, frames: nil, frameWidth: nil, frameHeight: nil, textChars: 400, bytes: 9999, provider: "claude") == 125)
    precondition(WorkContextMeter.fileTokens(kind: "pdf", pixelWidth: nil, pixelHeight: nil, pages: 3, frames: nil, frameWidth: nil, frameHeight: nil, textChars: nil, bytes: 0, provider: "claude") == 1525)
    precondition(WorkContextMeter.fileTokens(kind: "folder", pixelWidth: nil, pixelHeight: nil, pages: nil, frames: nil, frameWidth: nil, frameHeight: nil, textChars: nil, bytes: 0, provider: "claude") == 25, "A folder or link is its line only")
    precondition(WorkContextMeter.fileTokens(kind: "video", pixelWidth: nil, pixelHeight: nil, pages: nil, frames: 3, frameWidth: 1000, frameHeight: 1000, textChars: nil, bytes: 0, provider: "claude") == 3 * 1334 + 25, "Video counts its frames")
    let split = WorkContextMeter.split(context: "Task: A\nSource: B\n" + WorkContextMeter.meetingsHeader + "\n- Oct 14 | canonical ID: g2:x | domain: q\n- Oct 15 | canonical ID: g2:y | domain: q")
    precondition(split.task == "Task: A\nSource: B" && split.meetings.map(\.key) == ["g2:x", "g2:y"] && split.meetings.map(\.label) == ["Oct 14", "Oct 15"], "The task block and one item per meeting line")
    precondition(WorkContextMeter.split(context: "Task: only").meetings.isEmpty)
    let file = WorkContextFile(id: "f_aaaaaaaaaaaa", display: "Shot.png", stored: "01-shot.png", sha256: "s", bytes: 1, sniffed: "image/png", kind: "image", pixelWidth: 1000, pixelHeight: 1000, source: "finder", addedAt: 0, state: "ready", seq: 1)
    let items = WorkContextMeter.items(question: "Do it", context: "Task: A\n" + WorkContextMeter.meetingsHeader + "\n- M | canonical ID: g2:x | d\n- M again | canonical ID: g2:x | d",
                                       files: [.init(file: file), .init(file: file)], priors: [.init(sessionID: sessions[0].id, title: "S", status: "done", result: "Shipped"), .init(sessionID: sessions[1].id, title: "T", status: "idle", result: "")],
                                       statusInstructionChars: 40)
    precondition(items.map(\.kind) == [.req, .task, .files, .meet, .prior, .cos], "One item per thing, duplicates and empty results left out: \(items.map(\.kind))")
    precondition(items[2].estTokens == 1334 + 25 && items[2].codexTokens == 765 + 25 && items[2].fileID == "f_aaaaaaaaaaaa", "A file carries both providers' estimates")
    precondition(items.last!.estTokens == WorkContextMeter.textTokens(WorkContextMeter.cosText) + 10 && items.filter(\.fixed).map(\.id) == ["req", "task", "cos"])
    precondition(items.allSatisfy { $0.id.range(of: "^(req|task|cos|(file|meet|prior):[a-f0-9]{12})$", options: .regularExpression) != nil }, "Every id matches the server's pattern")
    let all = items.map(\.id), file1 = items[2].id, meet = items[3].id, prior = items[4].id
    precondition(WorkContextMeter.selection(nil, items: items) == all && WorkContextMeter.selection([], items: items) == ["req", "task", "cos"], "No choice is every item; an empty choice is the fixed three")
    precondition(WorkContextMeter.selection([prior, "file:000000000000", file1], items: items) == ["req", "task", file1, prior, "cos"], "Unknown ids drop; the card's order holds")
    precondition(WorkContextMeter.validSelection(["req", "task", "cos"], items: items) && !WorkContextMeter.validSelection(["req", "task"], items: items)
        && !WorkContextMeter.validSelection(["req", "task", "cos", "cos"], items: items) && !WorkContextMeter.validSelection(["req", "task", "cos", "meet:000000000000"], items: items), "A send needs the fixed three, each id once, all known")
    precondition(WorkContextMeter.toggled(all, itemID: "task", items: items) == nil && WorkContextMeter.toggled(all, itemID: "file:000000000000", items: items) == nil, "Fixed and unknown items never toggle")
    precondition(WorkContextMeter.toggled(all, itemID: meet, items: items) == ["req", "task", file1, prior, "cos"] && WorkContextMeter.toggled(["req", "task", "cos"], itemID: meet, items: items) == ["req", "task", meet, "cos"])
    precondition(WorkContextMeter.sendTokens(items: items, selected: ["req", "task", file1, "cos"], provider: "codex") == items[0].estTokens + items[1].estTokens + 765 + 25 + items[5].estTokens, "Codex sends count Codex image tokens")
    precondition(WorkContextMeter.byKind(items: items, selected: ["req", "task", "cos"], provider: "claude").map(\.kind) == [.req, .task, .cos], "The bar has only the kinds sent")
    var a = WorkChatAssignment(sessionID: sessions[1].id, prompt: "x"); a.contextItemIDs = ["req", "task", file1, "cos"]
    var skipped = a; skipped.state = "Skipped"
    precondition(WorkContextMeter.roundTokens(items: items, assignments: [a, skipped]) == WorkContextMeter.sendTokens(items: items, selected: a.contextItemIDs!, provider: "codex"), "A round counts its assignments by their own provider; skipped ones are left out")
    precondition(WorkContextMeter.canaryPercent(sent: 50, linked: 200) == 25 && WorkContextMeter.canaryPercent(sent: 0, linked: 0) == 0 && WorkContextMeter.canaryPercent(sent: 300, linked: 200) == 150, "Over 100 means items go to several sessions")
    precondition(WorkContextMeter.format(950) == "≈ 950" && WorkContextMeter.format(18_400) == "≈ 18.4k")
    precondition(WorkContextMeter.windowLine(send: 10_000, window: nil) == nil, "No window: no share, never a guess")
    precondition(WorkContextMeter.windowLine(send: 18_400, window: WorkSessionWindow(usedTokens: 100_000, windowTokens: 512_000))?.text == "3.6% of this session's 512k window")
    let full = WorkContextMeter.windowLine(send: 1_000, window: WorkSessionWindow(usedTokens: 466_000, windowTokens: 512_000))
    precondition(full?.warn == true && full?.text == "Session is 91% full · may compact soon")
    let sent = WorkContextMeter.prompt(question: "Q", assignment: "P", items: items, selected: ["req", "task", file1, "cos"])
    precondition(sent.fileIDs == ["f_aaaaaaaaaaaa"] && !sent.text.contains(WorkContextMeter.meetingsHeader) && !sent.text.contains("Shipped") && sent.text.hasSuffix(WorkContextMeter.cosText), "Only selected items are in the prompt")
    let withMeet = WorkContextMeter.prompt(question: "Q", assignment: "P", items: items, selected: ["req", "task", meet, prior, "cos"])
    precondition(withMeet.fileIDs.isEmpty && withMeet.text.contains(WorkContextMeter.meetingsHeader + "\n- M | canonical ID: g2:x") && withMeet.text.contains("Shipped"))
    precondition(!WorkContextMeter.isExpanded("", "r1"), "Collapsed by default")
    let opened = WorkContextMeter.toggleExpanded("", "r1")
    precondition(WorkContextMeter.isExpanded(opened, "r1") && !WorkContextMeter.isExpanded(WorkContextMeter.toggleExpanded(opened, "r1"), "r1"))
    let many = (0..<45).reduce("") { WorkContextMeter.toggleExpanded($0, "r\($1)") }
    precondition(many.split(separator: ",").count == 40 && !WorkContextMeter.isExpanded(many, "r0") && WorkContextMeter.isExpanded(many, "r44"), "The memory keeps the 40 newest")
    // 0.5.313 (QA): the server's item contract, so one odd item never fails a whole plan. Bounds from the shipped constants.
    let emoji = String(repeating: "👩‍💻", count: 120)
    let clamped = WorkContextMeter.plannerLabel(emoji, kind: "file")
    precondition(emoji.count <= 200 && emoji.utf16.count > WorkContextMeter.plannerLabelUTF16, "fixture: fits 200 Characters, not 200 UTF-16 units")
    precondition(clamped.utf16.count <= WorkContextMeter.plannerLabelUTF16 && !clamped.isEmpty && emoji.hasPrefix(clamped), "Label clamps by UTF-16, whole characters only")
    precondition(WorkContextMeter.plannerLabel("   ", kind: "meeting") == "meeting", "A blank label names its kind (the server refuses a blank one)")
    precondition(WorkContextMeter.plannerLabel("Report.pdf", kind: "file") == "Report.pdf")
    let huge = WorkContextMeter.plannerItems([WorkContextItem(id: "f_bbbbbbbbbbbb", kind: .files, label: "big.log", estTokens: WorkContextMeter.plannerMaxEstTokens * 3)])
    precondition((huge.first?["estTokens"] as? Int) == WorkContextMeter.plannerMaxEstTokens, "An estimate past the server cap is sent at the cap")
    print("PASS Work context meter rules: estimates by provider, context split, selection and edits, totals and canary, window share, prompt, disclosure memory, planner item contract")
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
    precondition(WorkChatPolicy.reviewedState([a("refused"), a("refused")]) == "Not delivered", "All refused is not Dispatched")
    precondition(WorkChatPolicy.reviewedState([a("failed"), a("failed")]) == "Not delivered", "All failed is not Dispatched")
    precondition(WorkChatPolicy.reviewedState([a("refused"), a("Skipped")]) == "Not delivered" && WorkChatPolicy.reviewedState([a("refused"), a("delivered")]) == "Dispatched")
    precondition(WorkChatPolicy.reviewedState([a("unknown"), a("refused")]) == "Delivery uncertain", "An unconfirmed delivery is not a refusal and not a send")
    precondition(WorkChatPolicy.reviewedState([a("Session reported done")]) == "Dispatched")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: "claude:claude-opus-4-8") == "planned with claude-opus-4-8")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: "claude:opus (requested)") == "requested Opus (not confirmed)", "A requested model is never claimed")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: nil) == "requested Opus (not confirmed)", "No report is not a confirmation")
    precondition(WorkChatPolicy.plannerLabel(requested: nil, ran: "claude:sonnet (requested)") == "requested Sonnet (not confirmed)")
    precondition(WorkChatPolicy.plannerLabel(requested: nil, ran: nil) == nil && WorkChatPolicy.plannerLabel(requested: nil, ran: "  ") == nil)
    precondition(WorkChatPolicy.effort(nil, advertised: []) == nil && WorkChatPolicy.effort("high", advertised: []) == nil, "An older server gets no effort key")
    precondition(WorkChatPolicy.effort("low", advertised: ["low", "medium", "high"]) == "low" && WorkChatPolicy.effort("medium", advertised: ["low", "medium", "high"]) == "medium")
    precondition(WorkChatPolicy.effort(nil, advertised: ["low", "medium", "high"]) == "high" && WorkChatPolicy.effort("max", advertised: ["low", "medium", "high", "max"]) == "high", "Unknown or unoffered levels fall back to high, never xhigh or max")
    precondition(WorkChatPolicy.effort("low", advertised: ["high"]) == "high")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: "claude:claude-opus-4-8", effort: "high") == "planned with claude-opus-4-8 · high effort")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: "claude:claude-opus-4-8", effort: nil) == "planned with claude-opus-4-8", "No reported effort is never claimed")
    precondition(WorkChatPolicy.plannerLabel(requested: "opus", ran: "claude:claude-opus-4-8", effort: "max") == "planned with claude-opus-4-8", "Only known levels are shown")
    precondition(WorkChatPolicy.plannerLabel(requested: nil, ran: nil, effort: "high") == nil)
    precondition(WorkChatPolicy.effortName("medium") == "Medium")
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

/// 0.5.316 (Miles 2026-10-16): Queue it, Send in parallel, Check first. A server that advertises queueRounds, the real
/// store, real submit and a fake transport: an earlier handoff on the first session runs until the check says otherwise.
private actor WorkQueueFixture {
    let ids: [String]
    let queue: Bool
    let server: String
    /// 0.5.316 reference links: the server takes `references` (6.73.15).
    let refs: Bool
    /// The sessions the planner assigns to (default: the first two fixture sessions).
    private(set) var assign: [String]
    private(set) var turn = "pending"
    private(set) var revision = String(repeating: "e", count: 64)
    private var sends: [String] = []
    private var prompts: [String: String] = [:]
    private var bodies: [[String: Any]] = []
    func prompt(_ thread: String) -> String { prompts[thread] ?? "" }
    /// 0.5.317: a summary call takes this long, and at most one Work chat call may be on the wire (as on the server).
    private(set) var summaryDelay: Duration = .zero
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var summaries = 0
    func setSummaryDelay(_ value: Duration) { summaryDelay = value }
    init(_ ids: [String], server: String, queue: Bool = true, refs: Bool = false) { self.ids = ids; self.server = server; self.queue = queue; self.refs = refs; assign = Array(ids.prefix(2)) }
    func setAssign(_ value: [String]) { assign = value }
    func referencesSent() -> [[String]?] { bodies.map { ($0["references"] as? [[String: Any]])?.compactMap { $0["id"] as? String } } }
    func sessionsSent() -> [[String]] { bodies.map { ($0["sessions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } } }
    func setTurn(_ state: String) { turn = state }
    func setRevision(_ value: String) { revision = value }
    func sent() -> [String] { sends }
    /// Each plan's sessions as the planner saw them: openWork per session, nil when the key was left out.
    func openWork() -> [[Bool?]] { bodies.map { ($0["sessions"] as? [[String: Any]] ?? []).map { $0["openWork"] as? Bool } } }
    func openWorkKeys() -> [Bool] { bodies.map { ($0["sessions"] as? [[String: Any]] ?? []).contains { $0["openWork"] != nil } } }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        var out: [String: JSONValue] = [:]
        let thread = args.firstIndex(of: "--thread-id").map { args[$0 + 1] } ?? ""
        switch args.first ?? "" {
        case "work-models": out = ["serverInstanceId": .string(server), "models": .array([])]
        case "claude-sessions": out = ["sessions": .array(ids.prefix(2).map { id in .object([
            "id": .string(String(id.split(separator: ":")[1])), "provider": .string(String(id.split(separator: ":")[0])),
            "name": .string("Exact " + id), "workspace": .string("/tmp/fixture"), "state": .string("recent")]) })]
        case "work-chat-capabilities":
            out = ["protocolVersion": .number(1), "planners": .array([.string("sonnet"), .string("opus")]), "efforts": .array([.string("high")])]
            if queue { out["queueRounds"] = .bool(true) }
            if refs { out["references"] = .bool(true); out["contextItems"] = .bool(true) }
        case "work-context": out = ["contextText": .string("Fixture task evidence"), "workRevision": .string(revision), "task": .object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")])]
        case "work-chat":
            inFlight += 1; maxInFlight = max(maxInFlight, inFlight); defer { inFlight -= 1 }
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if body?["mode"] as? String == "summary" {
                summaries += 1
                try await Task.sleep(for: summaryDelay)
                out = ["protocolVersion": .number(1), "answer": .string("Summary of observed results."), "assignments": .array([])]
                return HelperResponse(ok: true, message: "Fixture", details: out)
            }
            if let body { bodies.append(body) }
            out = ["protocolVersion": .number(1), "answer": .string("Two independent checks."),
                "assignments": .array(assign.map { .object(["sessionID": .string($0), "prompt": .string("Next idea; do not publish.")]) })]
        // The earlier handoff on the first session: still running until the fixture says its turn completed.
        case "session-chat-turn": out = ["state": .string(turn)]
        case "session-chat-attachability": out = ["attachable": .bool(true)]
        case "session-chat-attach": out = ["state": .string("attached"), "bindingId": .string("queue-fixture"), "epoch": .number(1), "boundTo": .string("exact-target")]
        case "session-chat-send": sends.append(thread); prompts[thread] = data.map { String(decoding: $0, as: UTF8.self) } ?? ""; out = ["state": .string("completed")]
        // No reply history: a delivered turn is never proven idle here, so it holds until it is marked reviewed.
        case "session-recent-replies": throw HelperClientError.commandFailed("Fixture has no session history")
        default: preconditionFailure("Queue fixture must not reach \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@MainActor private func runWorkChatQueueChecks(ids: [String], sessions: [WorkSession], root: URL) async throws {
    struct Journal: Encodable { var version = 2; var receipts: [WorkHandoffReceipt]; var sessions: [WorkSession] }
    // Settings › Work › When earlier work is still open: Queue it by default, Ask each time on request.
    precondition(WorkChatHold.settingDefault == WorkChatHold.queueSetting && WorkChatHold.queueSetting == "queue", "Queue it is the default")
    let fresh = UserDefaults(suiteName: "cos-queue-check-" + UUID().uuidString)!
    precondition(WorkChatHold.storedSetting(fresh) == "queue", "An unset Mac reads Queue it")
    fresh.set("ask", forKey: WorkChatHold.settingKey)
    precondition(WorkChatHold.storedSetting(fresh) == "ask")
    precondition(WorkChatHold.onHold(setting: "queue", autoSend: false, offered: true) == .queue && WorkChatHold.onHold(setting: "ask", autoSend: false, offered: true) == .ask)
    precondition(WorkChatHold.onHold(setting: "ask", autoSend: true, offered: true) == .queue && WorkChatHold.onHold(setting: "queue", autoSend: true, offered: true) == .queue, "Plan and send queues; it never asks and never skips the fence")
    precondition(WorkChatHold.onHold(setting: "queue", autoSend: true, offered: false) == .stop && WorkChatHold.onHold(setting: "ask", autoSend: false, offered: false) == .stop, "An older server keeps the check-first fence")
    precondition(WorkChatHold.queuedLine(titles: []) == "Queued behind earlier work on this card" && WorkChatHold.queuedLine(titles: ["Copy", "Copy"]) == "Queued behind \u{201C}Copy\u{201D}"
        && WorkChatHold.queuedLine(titles: ["A", "B"]) == "Queued behind \u{201C}A\u{201D} and \u{201C}B\u{201D}" && WorkChatHold.queuedLine(titles: ["A", "B", "C"]) == "Queued behind \u{201C}A\u{201D} and 2 more")
    // 0.5.317 (Miles 2026-10-16 14:28): Complete is the last board column again, latest completions first.
    precondition(WorkBoardStage.boardColumns == [.planned, .draft, .built, .qa, .complete], "Planned, Draft, Built, QA, Complete")
    let completedAt = ["b": Date(timeIntervalSince1970: 2), "c": Date(timeIntervalSince1970: 5), "e": Date(timeIntervalSince1970: 5)]
    precondition(WorkBoardStage.recentFirst(["a", "b", "c", "d", "e"], id: { $0 }, moves: completedAt) == ["c", "e", "b", "a", "d"],
                 "Newest completion first, ties and unknown dates in board order")
    // The store path below reads this Mac's setting (whenHeld nil); start from an unset Mac.
    UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey)
    defer { UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey) }

    func earlier(_ card: WorkSource, session: Int = 0) -> WorkHandoffReceipt {
        var row = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: card.id, workTitle: card.title, sourceRevision: card.revision, mode: .continueSession, provider: sessions[session].provider, modelID: "existing", sessionID: sessions[session].id, sessionTitle: "Copy review", status: "running", detail: "Provider turn accepted.", prompt: "Earlier work", createdAt: Date().timeIntervalSince1970 - 60)
        row.channel = "turn"; row.bindingID = "earlier-binding"; row.orchestrationRunID = UUID().uuidString.lowercased(); return row
    }
    func setup(_ name: String, queue: Bool = true, held: Bool = true) async throws -> (WorkQueueFixture, WorkHandoffStore, WorkTaskChatStore, WorkSource, WorkHandoffReceipt) {
        let task = TaskRow(.object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")]))!
        let card = WorkSource.taskSnapshot(task)
        let blocker = earlier(card)
        let file = root.appendingPathComponent("queue-" + name + ".json")
        try JSONEncoder().encode(Journal(receipts: held ? [blocker] : [], sessions: sessions)).write(to: file)
        let fixture = WorkQueueFixture(ids, server: "queue-" + name, queue: queue)
        let store = WorkHandoffStore(storageURL: file, transport: { args, data in try await fixture.run(args, data) })
        for id in ids.prefix(2) { precondition(store.confirmSessionCard(sessionID: id, source: card)) }
        await store.refresh()
        let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: card, handoff: store)
        await chat.loadPlanners(handoff: store, retryDelay: .zero)
        return (fixture, store, chat, card, blocker)
    }
    let firstThread = String(ids[0].split(separator: ":")[1]), secondThread = String(ids[1].split(separator: ":")[1])

    // 1. Queue it (the default). Planning goes ahead while earlier work runs; Send queues; it sends once that work resolves.
    do {
        let (fixture, store, chat, card, blocker) = try await setup("queue")
        precondition(chat.queueOffered && !chat.serverQueueMissing, "A 6.73.15 server offers the queue")
        chat.setDraft("A new idea while the copy review runs")
        await chat.send(source: card, handoff: store)
        let round = chat.record!.rounds.last!
        precondition(round.state == "Ready to send" && chat.blockers.isEmpty && chat.error == nil, "Earlier open work no longer stops planning: \(round.state) \(chat.error ?? "")")
        let seen = await fixture.openWork()
        precondition(seen == [[true, false]], "The planner is told which session has earlier work open: \(seen)")
        await chat.sendAll(roundID: round.id, source: card, handoff: store)
        var after = chat.record!.rounds.last!
        let none = await fixture.sent()
        precondition(none.isEmpty && after.state == WorkChatHold.queuedState && after.assignments.allSatisfy { $0.state == WorkChatHold.queuedState && $0.waitingOn == [blocker.id] && $0.parallel == false },
                     "With Queue it, a held Send queues every assignment behind the earlier handoff: \(after.state) \(after.assignments.map(\.state))")
        precondition(chat.blockers.isEmpty && chat.pendingHold == nil && chat.error == nil, "Queue it never shows the wall or asks")
        precondition(WorkChatHold.waitingTitles(after, receipts: store.receipts) == ["Copy review", "Copy review"], "The card names the session it waits on")
        try renderQueueStates(chat: chat, handoff: store, source: card, round: after, name: "queued")
        let relaunched = WorkTaskChatStore(); relaunched.enabled = true; relaunched.open(source: card, handoff: store)
        precondition(relaunched.record?.rounds.last?.assignments.allSatisfy { $0.state == WorkChatHold.queuedState && $0.waitingOn == [blocker.id] } == true, "A queued round survives a restart")
        // Still running: nothing goes. Delivered but not checked: still nothing.
        await chat.pumpQueued(source: card, handoff: store)
        await fixture.setTurn("completed")
        await chat.pumpQueued(source: card, handoff: store)
        let stillNone = await fixture.sent()
        precondition(stillNone.isEmpty && store.error == nil && store.receipts.first { $0.id == blocker.id }?.status == "delivered" && chat.record?.rounds.last?.state == WorkChatHold.queuedState,
                     "A queued round never sends while its earlier handoff is running or delivered and unchecked: \(stillNone)")
        // The app-wide pump leaves a card a Work chat view has open to that view.
        store.markReviewed(receiptID: blocker.id)
        let pump = WorkChatQueuePump(handoff: store, sources: { [card] })
        WorkChatQueuePump.show(card.id)
        await pump.pass()
        let whileShown = await fixture.sent()
        precondition(whileShown.isEmpty, "The app-wide pump never sends a card that is open in a Work chat view")
        WorkChatQueuePump.hide(card.id)
        // Marked reviewed: the app-wide pump sends both, once, with every send check again.
        await pump.pass()
        let both = await fixture.sent()
        chat.syncFromDisk()
        after = chat.record!.rounds.last!
        precondition(both.sorted() == [firstThread, secondThread].sorted() && after.state == "Dispatched" && after.assignments.allSatisfy { $0.state == "delivered" && $0.waitingOn == nil },
                     "Once the earlier handoff resolves, the queue sends each assignment once: \(both) \(after.state)")
        precondition(after.assignments.allSatisfy { a in store.receipts.contains { $0.id == a.receiptID && $0.orchestrationRunID == round.id } }, "Through the same receipts and run as Send all")
        await pump.pass(); await chat.pumpQueued(source: card, handoff: store)
        let again = await fixture.sent()
        precondition(again.count == 2, "A sent queue never sends twice: \(again)")
        // Cancel puts waiting assignments back for review; nothing is sent.
        let blocker2 = earlier(card)
        try JSONEncoder().encode(Journal(receipts: store.receipts + [blocker2], sessions: sessions)).write(to: root.appendingPathComponent("queue-queue.json"))
        await fixture.setTurn("pending")
        chat.setDraft("Another idea"); await chat.send(source: card, handoff: store)
        let next = chat.record!.rounds.last!
        let nextSeen = await fixture.openWork()
        precondition(nextSeen.last == [true, true], "Each session with a delivered reply not yet checked counts as open work: \(nextSeen)")
        await chat.sendAll(roundID: next.id, source: card, handoff: store)
        precondition(chat.record!.rounds.last!.state == WorkChatHold.queuedState)
        chat.cancelQueued(roundID: next.id)
        let canceled = chat.record!.rounds.last!
        let afterCancel = await fixture.sent()
        precondition(canceled.state == "Ready to send" && canceled.assignments.allSatisfy { $0.state == "Not sent" && $0.waitingOn == nil } && afterCancel.count == 2, "Cancel sends nothing and returns the plan for review")
        print("PASS Work chat Queue it: plans while held, queues on Send, survives restart, never sends while running or unchecked, app-wide pump skips an open card, sends once on resolve, Cancel")
    }

    // 2. A task changed while queued: at the moment it would dispatch, the round reads Needs a new plan and sends nothing.
    do {
        let (fixture, store, chat, card, blocker) = try await setup("stale")
        chat.setDraft("Queue then change the task"); await chat.send(source: card, handoff: store)
        let round = chat.record!.rounds.last!
        await chat.sendAll(roundID: round.id, source: card, handoff: store)
        precondition(chat.record!.rounds.last!.state == WorkChatHold.queuedState)
        await fixture.setTurn("completed"); await chat.refresh(source: card, handoff: store)
        store.markReviewed(receiptID: blocker.id)
        await fixture.setRevision(String(repeating: "f", count: 64))
        await chat.pumpQueued(source: card, handoff: store)
        let after = chat.record!.rounds.last!
        let sent = await fixture.sent()
        precondition(sent.isEmpty && after.state == "Needs a new plan" && chat.error == WorkChatPolicy.staleMessage && after.assignments.allSatisfy { $0.state == "Not sent" && $0.waitingOn == nil },
                     "A task that changed while queued is never sent from the old plan: \(after.state) \(after.assignments.map(\.state)) \(sent)")
        await chat.pumpQueued(source: card, handoff: store)
        let later = await fixture.sent()
        precondition(later.isEmpty, "A stale round stays unsent")
        print("PASS Work chat queue re-checks: a task changed while queued reads Needs a new plan and sends nothing")
    }

    // 3. Ask each time: three choices. Send in parallel sends the free session now; the busy one waits for its own session.
    do {
        UserDefaults.standard.set(WorkChatHold.askSetting, forKey: WorkChatHold.settingKey)
        defer { UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey) }
        let (fixture, store, chat, card, blocker) = try await setup("parallel")
        chat.setDraft("Route around the busy session"); await chat.send(source: card, handoff: store)
        let round = chat.record!.rounds.last!
        await chat.sendAll(roundID: round.id, source: card, handoff: store)
        let none = await fixture.sent()
        precondition(none.isEmpty && chat.pendingHold == PendingHoldCheck.expect(round) && chat.blockers.map(\.id) == [blocker.id]
            && chat.record!.rounds.last!.assignments.allSatisfy { $0.state == "Not sent" }, "Ask each time asks before anything is sent")
        try renderQueueStates(chat: chat, handoff: store, source: card, round: chat.record!.rounds.last!, name: "ask")
        // Check first: today's fence, nothing sent, the plan stays.
        await chat.resolveHold(.stop, source: card, handoff: store)
        precondition(chat.pendingHold == nil && chat.error == WorkChatPreflight.heading && chat.blockers.map(\.id) == [blocker.id] && chat.record!.rounds.last!.state == "Ready to send", "Check first is the old check")
        await chat.sendAll(roundID: round.id, source: card, handoff: store)
        await chat.resolveHold(.parallel, source: card, handoff: store)
        var after = chat.record!.rounds.last!
        let firstSends = await fixture.sent()
        precondition(firstSends == [secondThread] && after.assignments[1].state == "delivered", "Send in parallel sends the free session now: \(firstSends)")
        precondition(after.assignments[0].state == WorkChatHold.queuedState && after.assignments[0].parallel == true && after.assignments[0].waitingOn == [blocker.id] && after.state == WorkChatHold.queuedState,
                     "The busy session's assignment waits behind its own session: \(after.assignments.map(\.state))")
        try renderQueueStates(chat: chat, handoff: store, source: card, round: after, name: "parallel")
        // The one rule: a session with an open handoff never gets a second instruction, whichever path tries.
        await chat.pumpQueued(source: card, handoff: store)
        let direct = UUID().uuidString.lowercased()
        await store.submit(source: card, mode: .continueSession, session: store.sessions.first { $0.id == ids[0] }!, model: nil, prompt: "Second writer", orchestrationRunID: UUID().uuidString, intentID: direct, sessionFence: true)
        let guarded = await fixture.sent()
        precondition(guarded == [secondThread] && !store.receipts.contains { $0.id == direct }, "Parallel never sends into a session that still has a running handoff: \(guarded)")
        await fixture.setTurn("completed"); await chat.refresh(source: card, handoff: store)
        await chat.pumpQueued(source: card, handoff: store)
        let unchecked = await fixture.sent()
        precondition(unchecked == [secondThread], "Nor while its delivered reply is unchecked")
        store.markReviewed(receiptID: blocker.id)
        await chat.pumpQueued(source: card, handoff: store)
        after = chat.record!.rounds.last!
        let all = await fixture.sent()
        precondition(all.filter { $0 == firstThread }.count == 1 && all.count == 2 && after.state == "Dispatched", "Its own session resolved: it goes, once: \(all)")
        // A second parallel round: each session now holds its own delivered reply, so both wait, and nothing is sent twice.
        chat.setDraft("One more idea"); await chat.send(source: card, handoff: store)
        let third = chat.record!.rounds.last!
        await chat.sendAll(roundID: third.id, source: card, handoff: store)
        await chat.resolveHold(.parallel, source: card, handoff: store)
        let held = await fixture.sent()
        precondition(held.count == 2 && chat.record!.rounds.last!.assignments.allSatisfy { $0.state == WorkChatHold.queuedState && $0.parallel == true }, "A delivered reply not yet checked holds its session in parallel too: \(held)")
        print("PASS Work chat parallel: asks first, Check first unchanged, free session now, busy session waits for its own work, never a second instruction into a held session")
    }

    // 4. Plan and send with earlier work open queues, even with Ask each time: sending without review never skips the fence.
    do {
        UserDefaults.standard.set(WorkChatHold.askSetting, forKey: WorkChatHold.settingKey)
        defer { UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey) }
        let (fixture, store, chat, card, blocker) = try await setup("auto")
        chat.setDraft("Plan and send while earlier work runs")
        await chat.send(source: card, handoff: store, autoSend: true)
        let round = chat.record!.rounds.last!
        let sent = await fixture.sent()
        precondition(sent.isEmpty && round.sentWithoutReview == true && round.state == WorkChatHold.queuedState && chat.pendingHold == nil
            && round.assignments.allSatisfy { $0.state == WorkChatHold.queuedState && $0.parallel == false && $0.waitingOn == [blocker.id] }, "Plan and send queues instead of bypassing the fence: \(round.state) \(sent)")
        print("PASS Work chat Plan and send: queues behind earlier work, never asks, never bypasses")
    }

    try await runWorkReferenceChecks(ids: ids, sessions: sessions, root: root)
    try await runWorkChatClearedReceiptChecks(ids: ids, sessions: sessions, root: root)

    // 5. An older server (no queueRounds): today's behaviour, said plainly; never an openWork key.
    do {
        let (fixture, store, chat, card, blocker) = try await setup("old", queue: false)
        precondition(!chat.queueOffered && chat.serverQueueMissing, "An older server offers no queue, and Control knows why")
        chat.setDraft("Older server, earlier work open"); await chat.send(source: card, handoff: store)
        precondition(chat.record!.rounds.isEmpty && chat.blockers.map(\.id) == [blocker.id] && chat.error == WorkChatPreflight.heading && chat.record?.draft == "Older server, earlier work open",
                     "An older server keeps the check-first fence before planning")
        await fixture.setTurn("completed"); await store.refreshReceipts(); store.markReviewed(receiptID: blocker.id)
        await chat.recheckBlockers(source: card, handoff: store)
        await chat.send(source: card, handoff: store)
        let round = chat.record!.rounds.last!
        let keys = await fixture.openWorkKeys()
        precondition(round.state == "Ready to send" && keys == [false], "An older server never receives openWork: \(keys)")
        try JSONEncoder().encode(Journal(receipts: store.receipts + [earlier(card)], sessions: sessions)).write(to: root.appendingPathComponent("queue-old.json"))
        await fixture.setTurn("pending")
        await chat.sendAll(roundID: round.id, source: card, handoff: store)
        let sent = await fixture.sent()
        precondition(sent.isEmpty && chat.pendingHold == nil && chat.error == WorkChatPreflight.heading && chat.record!.rounds.last!.assignments.allSatisfy { $0.state == "Not sent" },
                     "On an older server a held Send shows the fence; nothing queues")
        print("PASS Work chat older server: check-first fence before planning and sending, no openWork key, nothing queued")
    }
}

private enum PendingHoldCheck {
    @MainActor static func expect(_ round: WorkChatRound) -> WorkTaskChatStore.PendingHold { .init(roundID: round.id, assignmentIDs: round.assignments.map(\.receiptID)) }
}

/// The queued line and the Ask each time choices, rendered offscreen from the real state above (light and dark).
@MainActor private func renderQueueStates(chat: WorkTaskChatStore, handoff: WorkHandoffStore, source: WorkSource, round: WorkChatRound, name: String) throws {
    guard CommandLine.arguments.contains("--render") else { return }
    let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
    for font in ["Fraunces", "Fraunces-Italic", "DMSans", "JetBrainsMono"] { CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(font + ".ttf") as CFURL, .process, nil) }
    NSApplication.shared.setActivationPolicy(.prohibited)
    let out = URL(fileURLWithPath: CommandLine.arguments.last!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let content = VStack(alignment: .leading, spacing: 10) {
            Text(round.question).font(COSType.body(14, weight: .semibold))
            ForEach(round.assignments) { a in
                HStack { Text(handoff.contributors(workID: source.id).first { $0.id == a.sessionID }?.title ?? a.sessionID).font(COSType.body(12)); Spacer(); Text(a.state).font(COSType.mono(10)) }
                    .padding(10).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            if chat.pendingHold?.roundID == round.id { WorkChatHoldChoices(chat: chat, handoff: handoff, source: source) }
            if round.assignments.contains(where: { $0.state == WorkChatHold.queuedState }) { WorkChatQueuedLine(chat: chat, handoff: handoff, source: source, round: round) }
        }.padding(14).frame(width: 560, alignment: .leading).background(COSPalette.card)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: max(200, host.fittingSize.height))
        let window = NSWindow(contentRect: host.frame.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.appearance = NSAppearance(named: appearance); window.appearance = host.appearance; window.contentView = host
        let until = Date().addingTimeInterval(0.5)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("work-chat-" + name + "-" + (appearance == .aqua ? "light" : "dark") + ".png"))
        window.close()
    }
}

/// 0.5.316 (Miles 2026-10-16 12:16): reference links. A session works on one task, and may be a read-only reference on any
/// number of others. A reference never receives a send, never holds the fence or the queue, never owns the stage, and its
/// summary reaches the planner within the bound. An older server: no references anywhere.
@MainActor private func runWorkReferenceChecks(ids: [String], sessions: [WorkSession], root: URL) async throws {
    struct Journal: Encodable { var version = 2; var receipts: [WorkHandoffReceipt]; var sessions: [WorkSession] }
    func card(_ hex: String, _ title: String) -> WorkSource {
        WorkSource.taskSnapshot(TaskRow(.object(["id": .string(hex), "workIdentity": .string(hex), "domain": .string("quilt"), "title": .string(title), "text": .string(title), "source": .string("Fixture evidence")]))!)
    }
    // The file store: the working-link rule is unchanged, references are many, idempotent, and never touch working links.
    let cards = root.appendingPathComponent("ref-store/handoffs.session-cards.json")
    let refsURL = WorkSessionLinks.referencesURL(cards: cards)
    precondition(refsURL.lastPathComponent == "handoffs.session-references.json")
    let itRetail = WorkSessionCardLink(workID: "task:quilt:111111111111", title: "IT Retail Gen 2 Modules", sourceRevision: "r1", at: 1)
    let organic = WorkSessionCardLink(workID: "task:quilt:222222222222", title: "Quilt organic cleanup", sourceRevision: "r2", at: 2)
    try WorkSessionLinks.associate(cards, sessionID: ids[0], link: itRetail, expected: "none")
    do { try WorkSessionLinks.associate(cards, sessionID: ids[0], link: organic, expected: "none"); preconditionFailure("A session works on one task at a time") } catch {}
    let workingBefore = try WorkSessionLinks.chatRead(cards)
    try WorkSessionLinks.addReference(refsURL, sessionID: ids[0], link: organic)
    try WorkSessionLinks.addReference(refsURL, sessionID: ids[0], link: organic)
    try WorkSessionLinks.addReference(refsURL, sessionID: ids[0].uppercased().replacingOccurrences(of: "CLAUDE", with: "claude"), link: WorkSessionCardLink(workID: "task:quilt:333333333333", title: "Third", sourceRevision: "r3", at: 3))
    let refs = try WorkSessionLinks.loadReferences(refsURL)
    precondition(refs[ids[0]]?.map(\.workID) == ["task:quilt:222222222222", "task:quilt:333333333333"], "A session may reference many tasks, each once: \(refs)")
    let workingAfter = try WorkSessionLinks.chatRead(cards), working = try WorkSessionLinks.load(cards)
    precondition(workingAfter == workingBefore && working[ids[0]]?.workID == itRetail.workID, "A reference never changes the working link")
    try WorkSessionLinks.removeReference(refsURL, sessionID: ids[0], workID: "task:quilt:333333333333")
    let left = try WorkSessionLinks.loadReferences(refsURL)
    precondition(left[ids[0]]?.map(\.workID) == ["task:quilt:222222222222"])
    do { try WorkSessionLinks.removeReference(refsURL, sessionID: ids[0], workID: "task:quilt:333333333333"); preconditionFailure("Removing a missing reference is a conflict") } catch {}

    // The live path. Card A: the IT Retail session works on the Gen 2 card (with a running handoff there); the organic card
    // links the Codex session as its working session and the IT Retail session as a reference.
    let organicCard = card("aaaaaaaaaaaa", "Launch fixture"), gen2 = card("cccccccccccc", "IT Retail Gen 2 Modules")
    var busy = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: gen2.id, workTitle: gen2.title, sourceRevision: gen2.revision, mode: .continueSession, provider: "claude", modelID: "existing", sessionID: ids[0], sessionTitle: "Gen 2 blog cleanup", status: "running", detail: "Provider turn accepted.", prompt: "Gen 2 work", createdAt: Date().timeIntervalSince1970 - 60)
    busy.channel = "turn"; busy.bindingID = "gen2-binding"
    let file = root.appendingPathComponent("refs-live.json")
    try JSONEncoder().encode(Journal(receipts: [busy], sessions: sessions)).write(to: file)
    let fixture = WorkQueueFixture(ids, server: "refs-live", refs: true)
    let store = WorkHandoffStore(storageURL: file, transport: { args, data in try await fixture.run(args, data) })
    precondition(store.confirmSessionCard(sessionID: ids[0], source: gen2) && store.confirmSessionCard(sessionID: ids[1], source: organicCard))
    precondition(!store.addReference(sessionID: ids[1], source: organicCard), "A session is never a reference on the task it works on")
    precondition(store.addReference(sessionID: ids[0], source: organicCard), "A session working elsewhere can be a reference here")
    precondition(store.confirmedSessionCards[ids[0]]?.workID == gen2.id, "Its working link stays with its own task")
    await store.refresh()
    let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: organicCard, handoff: store)
    await chat.loadPlanners(handoff: store, retryDelay: .zero)
    precondition(chat.referencesOffered, "A 6.73.15 server takes references")
    let referenced = ids[0]
    chat.referenceFacts = { id, _ in
        guard id == referenced else { return nil }
        return (outputs: ["blog-cleanup.md"], changes: "4 files, +120 -30")
    }
    precondition(store.referenceRows(workID: organicCard.id).map(\.id) == [ids[0]] && !store.contributorIDs(workID: organicCard.id).contains(ids[0]),
                 "A reference is listed apart, and never owns the card's stage")
    // The planner names the reference anyway: the plan is refused before anything is sent.
    await fixture.setAssign([ids[0]])
    chat.setDraft("Use the Gen 2 cleanup as the pattern")
    await chat.send(source: organicCard, handoff: store)
    let sent0 = await fixture.sent(), told = await fixture.referencesSent(), offered = await fixture.sessionsSent()
    precondition(told.last == [ids[0]] && offered.last == [ids[1]], "The planner gets the reference as evidence, never as a session: \(told) \(offered)")
    precondition(sent0.isEmpty && chat.record!.rounds.last!.state == "Needs attention" && store.receipts.allSatisfy { $0.workID != organicCard.id }, "A reference never receives a send, even when the planner names it")
    // An assignment for the working session goes now: the reference's running work on Gen 2 never holds this card.
    await fixture.setAssign([ids[1]])
    chat.setDraft("Now the organic cleanup itself")
    await chat.send(source: organicCard, handoff: store)
    let round = chat.record!.rounds.last!
    let item = round.contextItems?.first { $0.label.hasPrefix("Reference: ") }
    precondition(item?.text?.contains("blog-cleanup.md") == true && item?.text?.contains("4 files, +120 -30") == true && item?.kind == .prior, "The reference rides as read-only evidence with its outputs and changes")
    await chat.sendAll(roundID: round.id, source: organicCard, handoff: store)
    let sent1 = await fixture.sent()
    precondition(sent1 == [String(ids[1].split(separator: ":")[1])] && chat.record!.rounds.last!.state == "Dispatched" && chat.pendingHold == nil && chat.blockers.isEmpty,
                 "A reference never holds the fence or the queue: \(sent1) \(chat.record!.rounds.last!.state)")
    // The bound: seven references, six reach the planner.
    for n in 0..<7 {
        let extra = "claude:abcdefab-0000-4000-8000-00000000010\(n)"
        precondition(store.addReference(sessionID: extra, source: organicCard))
    }
    await fixture.setAssign([])
    chat.setDraft("Summarize what the references did"); await chat.send(source: organicCard, handoff: store)
    let bounded = await fixture.referencesSent()
    precondition(bounded.last??.count == WorkChatPolicy.maxReferences && WorkChatPolicy.maxReferences == 6
        && (chat.record!.rounds.last!.contextItems ?? []).filter { $0.label.hasPrefix("Reference: ") }.count == 6, "At most six references reach the planner: \(String(describing: bounded.last))")
    // A manual handoff (the Agent workspace) carries the same read-only references, within the same bound.
    for receipt in store.receipts where receipt.workID == organicCard.id && receipt.status == "delivered" { store.markReviewed(receiptID: receipt.id) }
    let codex = store.sessions.first { $0.id == ids[1] }!
    let lastExtra = "claude:abcdefab-0000-4000-8000-000000000106"
    await sendWorkHandoff(store: store, source: organicCard, plan: WorkSendPlan(mode: .continueSession, session: codex, model: nil, crossPlatform: false, prompt: "Manual follow-up"),
                          referenceFacts: { id, _ in
                              guard id == lastExtra else { return nil }
                              return (outputs: ["extra-notes.md"], changes: "1 file, +3 -0")
                          })
    let manual = await fixture.prompt(String(ids[1].split(separator: ":")[1]))
    precondition(manual.contains("Manual follow-up") && manual.contains("Reference sessions (linked to this task as read-only reference points")
        && manual.components(separatedBy: "Reference session \u{201C}").count - 1 == WorkChatPolicy.maxReferences && manual.contains("extra-notes.md"),
                 "A manual handoff carries the card's references, read-only, at most six: \(manual.suffix(400))")
    // An older server: no references key, no reference items, and nothing offered.
    let oldFixture = WorkQueueFixture(ids, server: "refs-old", refs: false)
    let oldFile = root.appendingPathComponent("refs-old.json")
    try JSONEncoder().encode(Journal(receipts: [], sessions: sessions)).write(to: oldFile)
    let old = WorkHandoffStore(storageURL: oldFile, transport: { args, data in try await oldFixture.run(args, data) })
    precondition(old.confirmSessionCard(sessionID: ids[1], source: organicCard) && old.addReference(sessionID: ids[0], source: organicCard))
    await old.refresh()
    let oldChat = WorkTaskChatStore(); oldChat.enabled = true; oldChat.open(source: organicCard, handoff: old)
    await oldChat.loadPlanners(handoff: old, retryDelay: .zero)
    await oldFixture.setAssign([])
    oldChat.setDraft("Older server with a saved reference"); await oldChat.send(source: organicCard, handoff: old)
    let oldTold = await oldFixture.referencesSent()
    precondition(!oldChat.referencesOffered && oldTold == [nil] && oldChat.record!.rounds.last!.state == "Answered"
        && !(oldChat.record!.rounds.last!.contextItems ?? []).contains { $0.label.hasPrefix("Reference: ") }, "An older server never receives references: \(oldTold)")
    await sendWorkHandoff(store: old, source: organicCard, plan: WorkSendPlan(mode: .continueSession, session: old.sessions.first { $0.id == ids[1] }!, model: nil, crossPlatform: false, prompt: "Manual on an older server"))
    let oldManual = await oldFixture.prompt(String(ids[1].split(separator: ":")[1]))
    precondition(oldManual.contains("Manual on an older server") && !oldManual.contains("Reference session"), "An older server's manual handoff carries no references")
    print("PASS Work references: one working link per session kept, many references, never a send target, never holds the fence or queue, never owns the stage, planner evidence and manual handoffs within six, older server untouched")
}

/// 0.5.317 regression (Miles 2026-10-16 14:2x, IT Retail card): the Codex handoff he cleared after checking ("You checked the
/// session and cleared this unresolved handoff") and the Claude replies already continued must never hold the card. What
/// held it was the newest Claude reply, delivered and not yet checked: with the queue, his next message queues behind that
/// one alone, without asking; with nothing open it sends. A running update summary no longer disables Check again or Plan.
@MainActor private func runWorkChatClearedReceiptChecks(ids: [String], sessions: [WorkSession], root: URL) async throws {
    struct Journal: Encodable { var version = 2; var receipts: [WorkHandoffReceipt]; var sessions: [WorkSession] }
    let card = WorkSource.taskSnapshot(TaskRow(.object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"), "domain": .string("quilt"), "title": .string("Launch fixture"), "text": .string("Launch fixture"), "source": .string("Fixture evidence")]))!)
    let now = Date().timeIntervalSince1970, runA = UUID().uuidString.lowercased(), runB = UUID().uuidString.lowercased()
    func row(_ session: Int, _ status: String, run: String, at: Double, detail: String) -> WorkHandoffReceipt {
        var r = WorkHandoffReceipt(id: UUID().uuidString.lowercased(), workID: card.id, workTitle: card.title, sourceRevision: card.revision, mode: .continueSession, provider: sessions[session].provider, modelID: "existing-session", sessionID: sessions[session].id, sessionTitle: sessions[session].title, status: status, detail: detail, prompt: "Earlier assignment " + run, createdAt: at)
        r.channel = "turn"; r.bindingID = "binding-" + run; r.orchestrationRunID = run; return r
    }
    var codexCleared = row(1, "reviewed", run: runA, at: now - 2_700, detail: "You checked the session and cleared this unresolved handoff. Earlier: Delivery could not be confirmed. Inspect this session before another handoff.")
    codexCleared.acknowledgedAt = now - 1_800
    var claudeContinued = row(0, "delivered", run: runA, at: now - 2_700, detail: "Instruction delivered to the session. Inspect the response; this does not mark the task complete.")
    claudeContinued.continuedBy = UUID().uuidString.lowercased(); claudeContinued.result = "Copy pass done."
    let claudeOpen = row(0, "delivered", run: runB, at: now - 240, detail: "Instruction delivered to the session. Inspect the response; this does not mark the task complete.")
    precondition(codexCleared.clearedUnconfirmed && !codexCleared.blocksNewHandoff && !WorkChatPreflight.holds(codexCleared, continuations: [:]), "A cleared handoff never holds the card")
    precondition(!claudeContinued.blocksNewHandoff && !WorkChatPreflight.holds(claudeContinued, continuations: [:]), "A continued reply never holds the card")
    precondition(WorkChatPreflight.holds(claudeOpen, continuations: [:]) && WorkChatPreflight.blockers([claudeOpen, codexCleared, claudeContinued], workID: card.id, continuations: [:]).map(\.id) == [claudeOpen.id],
                 "Only the newest unchecked reply holds it")
    UserDefaults.standard.removeObject(forKey: WorkChatHold.settingKey)
    for open in [true, false] {
        let file = root.appendingPathComponent("cleared-" + (open ? "open" : "resolved") + ".json")
        try JSONEncoder().encode(Journal(receipts: (open ? [claudeOpen] : []) + [codexCleared, claudeContinued], sessions: sessions)).write(to: file)
        let fixture = WorkQueueFixture(ids, server: "cleared-" + (open ? "open" : "resolved"))
        let store = WorkHandoffStore(storageURL: file, transport: { args, data in try await fixture.run(args, data) })
        precondition(!store.refreshedOnce && !store.sessionsKnown, "Before the first session read, the card says it is loading")
        for id in ids.prefix(2) { precondition(store.confirmSessionCard(sessionID: id, source: card)) }
        await store.refresh()
        precondition(store.refreshedOnce && store.sessionsKnown, "After it, the card renders what it read")
        let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: card, handoff: store)
        await chat.loadPlanners(handoff: store, retryDelay: .zero)
        chat.setDraft("I had a question about one area here")
        await chat.send(source: card, handoff: store)
        let round = chat.record!.rounds.last!
        precondition(round.state == "Ready to send" && chat.blockers.isEmpty && chat.error == nil, "His message is planned, not walled: \(round.state) \(chat.error ?? "")")
        await chat.sendAll(roundID: round.id, source: card, handoff: store)
        let after = chat.record!.rounds.last!, sent = await fixture.sent()
        if open {
            precondition(sent.isEmpty && chat.pendingHold == nil && chat.blockers.isEmpty && after.assignments.allSatisfy { $0.state == WorkChatHold.queuedState && $0.waitingOn == [claudeOpen.id] },
                         "Genuinely open: it queues behind that reply alone, without asking: \(after.assignments.map { $0.waitingOn ?? [] })")
            store.markReviewed(receiptID: claudeOpen.id)
            await chat.pumpQueued(source: card, handoff: store)
            let later = await fixture.sent()
            precondition(later.count == 2 && chat.record!.rounds.last!.state == "Dispatched", "Then it sends by itself")
        } else {
            precondition(sent.count == 2 && after.state == "Dispatched" && chat.pendingHold == nil, "Nothing open: it just sends: \(sent)")
            // A summary on the wire keeps neither Check again nor Plan waiting on a disabled button, and never overlaps a plan.
            await fixture.setSummaryDelay(.milliseconds(600))
            chat.record?.rounds[chat.record!.rounds.count - 1].assignments[0].result = "QA done; two notes."
            let refreshing = Task { await chat.refresh(source: card, handoff: store) }
            var waited = 0
            while !chat.summarizing && waited < 100 { try await Task.sleep(for: .milliseconds(20)); waited += 1 }
            precondition(chat.summarizing && !chat.refreshing, "A summary in flight does not hold refreshing (Check again stays enabled)")
            chat.setDraft("Next while it summarizes")
            await chat.send(source: card, handoff: store)
            await refreshing.value
            let overlap = await fixture.maxInFlight, count = await fixture.summaries
            precondition(chat.record!.rounds.last!.question == "Next while it summarizes" && chat.record!.rounds.last!.state == "Ready to send" && overlap == 1 && count == 1,
                         "The plan waits for the one summary on the wire, then runs: \(chat.record!.rounds.last!.state) overlap \(overlap)")
        }
    }
    print("PASS Work chat cleared receipt (Miles 2026-10-16): cleared and continued handoffs never hold; an open reply queues his message without asking; nothing open sends; a running summary never disables Check again or Plan; loading until the first session read")
}
