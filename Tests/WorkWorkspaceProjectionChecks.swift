import Foundation

@MainActor func runWorkWorkspaceProjectionChecks() {
    func task(_ id: String, _ domain: String, checked: Bool = false, agent: String = "", tail: String = "") -> TaskRow {
        TaskRow(.object(["id": .string(id), "domain": .string(domain), "title": .string("Lens title"),
                         "text": .string("Complete task " + tail), "checked": .bool(checked),
                         "column": .string(agent == "done" ? "done" : "planning"), "agentState": .string(agent),
                         "doneWhen": .string("Verified outcome"), "source": .string("Canonical meeting")]))!
    }
    let rows = (0..<65).map { task(String($0), $0.isMultiple(of: 2) ? "quilt" : "personal", tail: "unique-\($0)") }
        + [task("same", "quilt", checked: true), task("same", "personal", agent: "done"), task("active", "quilt", agent: "running")]
    let items = WorkWorkspaceProjection.items(tasks: rows, reviews: [], receipts: [])
    precondition(items.count == 68, "Workspace projection must not inherit legacy lens caps")
    precondition(items.first?.needsAttention == true && items.last?.completed == true, "Attention and active work must precede completed history")
    precondition(items.filter { !$0.completed && !$0.needsAttention && !$0.inProgress }.first?.id == "task:quilt:0", "Ordering within each work state remains stable")
    precondition(Set(items.map(\.id)).count == 68, "Domain namespaces must preserve distinct legacy IDs")
    precondition(WorkWorkspaceProjection.filter(items, scope: .all, domain: nil, query: "unique-64").count == 1,
                 "Search covers full source text beyond the legacy first 30/50 rows")
    let completed = WorkWorkspaceProjection.filter(items, scope: .completed, domain: nil, query: "")
    precondition(completed.count == 1 && completed[0].domain == "quilt", "Agent done never marks a task completed")
    let openDone = items.first { $0.id == "task:personal:same" }!
    precondition(!openDone.completed && openDone.needsAttention && openDone.subtitle.contains("still open"))
    precondition(WorkWorkspaceProjection.filter(items, scope: .progress, domain: "quilt", query: "").count == 1)
    precondition(WorkWorkspaceProjection.filter(items, scope: .all, domain: "missing", query: "").isEmpty)
    func review(_ id: String, revision: String, status: String) -> WorkReviewRecord {
        WorkReviewRecord(.object(["id": .string(id), "status": .string(status), "markdown": .string("Reviewed decision"),
            "canonicalMeetingId": .string("canonical-record"), "source": .object([
                "title": .string("Same meeting title"), "domain": .string("quilt"), "revision": .string(revision),
                "descriptor": .object(["recordId": .string("canonical-record")])])]))!
    }
    let reviews = [review("revision-one", revision: "one", status: "ready"), review("revision-two", revision: "two", status: "running")]
    let projected = WorkWorkspaceProjection.items(tasks: [], reviews: reviews, receipts: [])
    precondition(Set(projected.map(\.id)).count == 2, "Changed source revisions retain separate review rows")
    precondition(Set(projected.map(\.sourceID)).count == 1, "Review revisions share work history and draft fences")
    precondition(WorkWorkspaceProjection.rowID(forSourceID: "meeting:canonical-record", currentID: "meeting-review:revision-one", items: projected) == "meeting-review:revision-one", "Selecting historical review must not jump to another revision")
    precondition(WorkWorkspaceProjection.filter(projected, scope: .completed, domain: nil, query: "").isEmpty,
                 "Review output is not a completed task")
    precondition(WorkWorkspaceProjection.filter(projected, scope: .attention, domain: nil, query: "").count == 1)
    precondition(reviews[0].canPrepare && !reviews[1].canPrepare, "Only successfully reviewed source may feed preparation")
    print("PASS Work workspace: uncapped source text, domain identity, independent completion, review revisions")
}


@MainActor func runWorkWorkspaceReviewSelectionChecks() async {
    let meeting = LibraryMeeting(.object(["recordId": .string("piece-one"), "sessionId": .string("shared-capture"),
        "domain": .string("personal"), "month": .string("2026-09"), "filename": .string("meeting.md")]))!
    let record: JSONValue = .object(["id": .string("already-reviewed"), "canonicalMeetingId": .string("piece-one"),
        "status": .string("ready"), "markdown": .string("Verified review"),
        "source": .object(["title": .string("Review"), "domain": .string("personal"), "revision": .string("one")])])
    let store = WorkReviewStore(transport: { _, _ in HelperResponse(ok: true, message: "Existing review", details: ["review": record]) })
    store.available = true
    store.models = [WorkModelChoice(id: "fixture", provider: "fixture", title: "Fixture", available: true, reason: nil)]
    store.selectedReviewID = "already-reviewed"
    store.selectedMeeting = meeting
    let state = WorkWorkspaceState()
    let reopened = await state.requestReview(meeting: meeting, modelID: "fixture", store: store)
    precondition(store.selectedReviewID == "already-reviewed", "Server reused the same review identity")
    precondition(reopened?.id == "already-reviewed" && state.selectedID == "meeting-review:already-reviewed",
                 "Explicit admission must reopen the row even when onChange has no changed ID")
    let failed = WorkReviewStore(transport: { _, _ in HelperResponse(ok: false, message: "Source unavailable", details: [:]) })
    failed.available = true; failed.models = store.models
    failed.selectedReviewID = "already-reviewed"; failed.reviews = store.reviews; failed.selectedMeeting = meeting
    state.selectedID = nil
    let result = await state.requestReview(meeting: meeting, modelID: "fixture", store: failed)
    precondition(result == nil && state.selectedID == nil && failed.selectedMeeting?.recordId == meeting.recordId,
                 "A failed review must retain intake and cannot reopen an older unrelated result")
    print("PASS Work workspace: same-review reopen and failed-admission intake retention")
}
