import Foundation

private actor ReviewProjectionTransport {
    var replies: [HelperResponse]
    var calls: [([String], Data?)] = []
    init(_ replies: [HelperResponse]) { self.replies = replies }
    func run(_ args: [String], _ data: Data?) throws -> HelperResponse {
        calls.append((args, data))
        guard !replies.isEmpty else { throw NSError(domain: "fixture", code: 1) }
        return replies.removeFirst()
    }
}

@MainActor func runWorkReviewStoreChecks() async throws {
    let unavailable = HelperResponse(ok: true, message: "Update required", details: ["capabilities": .object(["manualReview": .bool(false)]), "reviews": .array([])])
    let record: JSONValue = .object(["id": .string("review-one"), "canonicalMeetingId": .string("split:piece-one"), "status": .string("ready"), "markdown": .string("A review with evidence"), "source": .object(["title": .string("QA review"), "domain": .string("personal"), "revision": .string("revision-one"), "inputTruncated": .bool(true)]), "contextWarnings": .array([.string("Task context unavailable")])])
    let available = HelperResponse(ok: true, message: "Ready", details: ["capabilities": .object(["manualReview": .bool(true), "automaticAfterSync": .bool(false), "reviewModels": .array([.object(["id": .string("ollama"), "provider": .string("ollama"), "available": .bool(true)])])]), "reviews": .array([record])])
    let fixture = ReviewProjectionTransport([unavailable, available, HelperResponse(ok: true, message: "reused", details: ["review": record])])
    let store = WorkReviewStore(transport: { args, data in try await fixture.run(args, data) })
    let initialCalls = await fixture.calls
    precondition(initialCalls.isEmpty, "Opening the model must not send anything")
    await store.refresh()
    precondition(!store.available && store.error != nil, "An unavailable server must keep its visible explanation")
    await store.refresh()
    precondition(store.available && !store.automaticAfterSync && store.error == nil)
    precondition(store.reviews.count == 1 && store.reviews[0].inputTruncated && store.reviews[0].contextWarnings.count == 1)
    let meeting = LibraryMeeting(.object(["recordId": .string("split:piece-one"), "sessionId": .string("shared-parent"), "domain": .string("personal"), "month": .string("2026-09"), "filename": .string("QA meeting.md")]))!
    await store.review(meeting: meeting, modelID: "unavailable")
    let unavailableCalls = await fixture.calls
    precondition(unavailableCalls.count == 2, "Unavailable providers must not admit reviews")
    await store.review(meeting: meeting, modelID: "ollama")
    precondition(store.reviews.count == 1 && store.selectedReviewID == "review-one", "Replayed reviews retain one identity")
    let calls = await fixture.calls
    let payload = try JSONSerialization.jsonObject(with: calls[2].1!) as! [String: Any]
    let ref = payload["meeting"] as! [String: String]
    precondition(ref["recordId"] == "split:piece-one" && ref["filename"] == "QA meeting.md" && ref["sessionId"] == nil)
    await store.refresh() // failed read retains already known review
    precondition(store.error != nil && store.reviews.count == 1 && !store.available && store.models.isEmpty)
    let failedCalls = await fixture.calls.count
    await store.review(meeting: meeting, modelID: "ollama")
    let afterFailureCalls = await fixture.calls.count
    precondition(failedCalls == afterFailureCalls, "Failed capability refresh disables admission")
    var wrong = record.object!
    wrong["canonicalMeetingId"] = .string("other-meeting")
    let identityFixture = ReviewProjectionTransport([available, HelperResponse(ok: true, message: "wrong", details: ["review": .object(wrong)])])
    let guarded = WorkReviewStore(transport: { args, data in try await identityFixture.run(args, data) })
    await guarded.refresh()
    await guarded.review(meeting: meeting, modelID: "ollama")
    precondition(guarded.selectedReviewID == nil && guarded.error != nil, "Wrong-meeting response must never take over selection")
    let staleFixture = ReviewProjectionTransport([available])
    let stale = WorkReviewStore(transport: { args, data in try await staleFixture.run(args, data) })
    await stale.refresh()
    let permitted = await stale.validateForHandoff(stale.reviews[0])
    precondition(!permitted && stale.error != nil && stale.reviews.count == 1, "Stale cached ready output must not authorize a handoff")
    let freshFixture = ReviewProjectionTransport([available, available])
    let fresh = WorkReviewStore(transport: { args, data in try await freshFixture.run(args, data) })
    await fresh.refresh()
    let allowed = await fresh.validateForHandoff(fresh.reviews[0])
    precondition(allowed, "An exactly revalidated ready source may proceed")
    print("PASS Work review model: capability errors, no implicit admission, exact saved source, idempotent projection, retained state")
}
