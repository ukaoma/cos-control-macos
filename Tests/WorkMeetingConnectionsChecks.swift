import Foundation

@MainActor func runWorkMeetingConnectionsChecks() {
    let descriptor: [String: JSONValue] = ["recordId": .string("split:piece-one"), "domain": .string("personal"),
        "month": .string("2026-09"), "filename": .string("meeting-one.md"), "title": .string("Same title")]
    let reference = WorkMeetingReference(.object(descriptor))!
    let meeting = reference.libraryMeeting!
    precondition(reference.matches(meeting) && meeting.recordId == "split:piece-one")
    for (key, bad) in [("recordId", ""), ("domain", "../personal"), ("month", "2026-13"), ("filename", "../meeting.md"), ("filename", "a\\b.md")] {
        var invalid = descriptor; invalid[key] = .string(bad)
        precondition(WorkMeetingReference(.object(invalid)) == nil, "Unsafe or incomplete saved-meeting reference accepted")
    }
    var missing = descriptor; missing.removeValue(forKey: "month")
    precondition(WorkMeetingReference(.object(missing)) == nil, "A title/record ID alone cannot open a file")
    var otherDescriptor = descriptor; otherDescriptor["recordId"] = .string("split:piece-two"); otherDescriptor["filename"] = .string("meeting-two.md")
    let otherMeeting = WorkMeetingReference(.object(otherDescriptor))!.libraryMeeting!
    precondition(otherMeeting.title == meeting.title && !reference.matches(otherMeeting), "Equal titles cannot link split pieces")
    var staleDescriptor = descriptor; staleDescriptor["filename"] = .string("different-file.md")
    precondition(!WorkMeetingReference(.object(staleDescriptor))!.matches(meeting), "A conflicting descriptor must not claim the canonical meeting")

    func task(_ id: String, domain: String = "personal", identity: String = "original", refs: [JSONValue] = [], stage: String = "planning", checked: Bool = false) -> TaskRow {
        TaskRow(.object(["id": .string(id), "domain": .string(domain), "title": .string("Title"), "text": .string("Original task text"),
            "workIdentity": .string(identity), "workRevision": .string("file-revision"), "meetingRefs": .array(refs),
            "stage": .string(stage), "checked": .bool(checked)]))!
    }
    let original = task("before-rename", refs: [reference.jsonValue])
    let renamed = task("after-rename", refs: [reference.jsonValue])
    precondition(original.id != renamed.id && WorkSource.taskSnapshot(original).id == WorkSource.taskSnapshot(renamed).id,
                 "Raw legacy ID changes must retain Work identity and receipt links")
    precondition(original.meetingRefs == renamed.meetingRefs)
    let linkedSnapshot = WorkSource.taskSnapshot(original)
    precondition(linkedSnapshot.context.contains(reference.recordId) && linkedSnapshot.context.contains("personal/2026-09/meeting-one.md"))
    precondition(linkedSnapshot.context.contains("transcript evidence is not included"))
    precondition(linkedSnapshot.revision != WorkSource.taskSnapshot(task("before-rename")).revision, "Changing confirmed meeting context invalidates the prior handoff draft revision")
    let helperEnvelope = TaskRow(.object(["id": .string("helper-row"), "domain": .string("personal"), "title": .string("Title"),
        "workStage": .string("planned"), "workRevision": .string("revision"), "workMetadataError": .string(""), "meetingRefs": .array([])]))!
    precondition(helperEnvelope.workMetadataError == nil, "An empty helper metadata error must not disable valid board writes")
    precondition(task("legacy-active", stage: "active").workStage == "draft")
    precondition(task("legacy-review", stage: "review").workStage == "qa")
    precondition(task("legacy-planned").workStage == "planned")
    precondition(task("legacy-done", checked: true).workStage == "complete")
    let malformed = task("bad", refs: [.object(["recordId": .string("missing-descriptor")])])
    precondition(malformed.workMetadataError != nil && malformed.meetingRefs.isEmpty)
    let otherDomain = task("after-rename", domain: "quilt", refs: [reference.jsonValue])
    precondition(renamed.workSourceID != otherDomain.workSourceID)
    func review(_ id: String, record: String) -> WorkReviewRecord {
        WorkReviewRecord(.object(["id": .string(id), "canonicalMeetingId": .string(record), "status": .string("ready"),
            "markdown": .string("Reviewed evidence"), "source": .object(["title": .string("Same title"), "domain": .string("personal"), "revision": .string("one")])]))!
    }
    func receipt(_ id: String, work: String, session: String?, provider: String = "codex") -> WorkHandoffReceipt {
        WorkHandoffReceipt(id: id, workID: work, workTitle: "Linked task", sourceRevision: "one", mode: .continueSession,
            provider: provider, modelID: "existing", sessionID: session, sessionTitle: "Same session title", status: "delivered",
            detail: "Sent", prompt: "Review", createdAt: 1)
    }
    let receipts = [receipt("task-session", work: renamed.workSourceID, session: "codex:exact"),
        receipt("meeting-session", work: "meeting:" + meeting.recordId, session: "codex:review"),
        receipt("wrong-provider", work: renamed.workSourceID, session: "claude:exact"),
        receipt("unbound-fork", work: renamed.workSourceID, session: nil),
        receipt("other-piece", work: "meeting:" + otherMeeting.recordId, session: "codex:other")]
    let links = MeetingWorkConnections.project(meeting: meeting, tasks: [renamed, otherDomain, task("unlinked")],
        reviews: [review("one", record: meeting.recordId), review("two", record: otherMeeting.recordId)],
        receipts: receipts, sessions: [WorkSession(id: "codex:exact", nativeID: "exact", provider: "codex", title: "Target", summary: "", project: "personal", status: "idle")], loading: false, complete: false, errors: ["Inventory incomplete"])
    precondition(links.tasks.count == 2 && Set(links.tasks.map(\.workSourceID)).count == 2)
    precondition(links.reviews.map(\.id) == ["one"], "Only canonical meeting identity establishes a review link")
    precondition(Set(links.receipts.map(\.id)) == ["task-session", "meeting-session"], "Provider mismatch, parent-only fork and another meeting must not become links")
    let destination = links.sessionDestination(for: receipts[0])
    precondition(destination?.sessionID == "codex:exact" && destination?.workID == renamed.workSourceID,
        "Meeting-to-session navigation must carry the receipt work backlink, not a previous task selection")
    precondition(links.sessionDestination(for: receipts[1]) == nil, "Unavailable sessions cannot fabricate a target")
    precondition(!links.complete && links.errors == ["Inventory incomplete"], "Read failures must not be presented as no linked work")
    print("PASS Work meeting links: strict descriptors, stable rename identity, legacy phase projection, exact backlinks and qualified sessions")
}
