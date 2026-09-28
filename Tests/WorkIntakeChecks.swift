import Foundation

/// Work → Intake (server 6.57.0): the Control model decodes only well-formed items, groups them the way
/// the view promises, and never mistakes an older server for an empty Intake.
@MainActor func runWorkIntakeChecks() {
    let meeting: JSONValue = .object(["recordId": .string("ops:quilt:2026-09:2026-09-24_Bottle_QA.md"), "domain": .string("quilt"),
        "month": .string("2026-09"), "filename": .string("2026-09-24_Bottle_QA.md"), "title": .string("Bottle QA")])
    func id(_ n: Int) -> String { "wi_" + String(repeating: "0", count: 31) + String(n, radix: 16) }
    func item(_ n: Int, kind: String = "ask", status: String = "ask", confidence: Double = 0.9, text: String? = "Fix the H1",
              filename: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var m = meeting.object!
        if let filename { m["filename"] = .string(filename); m["recordId"] = .string("ops:quilt:2026-09:" + filename) }
        var row: [String: JSONValue] = ["id": .string(id(n)), "kind": .string(kind), "status": .string(status),
            "meeting": .object(m), "confidence": .number(confidence), "model": .string("jev-1.13.0")]
        if kind == "link" {
            row["task"] = .object(["domain": .string("quilt"), "id": .string(String(repeating: "a", count: 12)),
                "workIdentity": .string(String(repeating: "b", count: 12)), "text": text.map(JSONValue.string) ?? .null])
        } else if let text { row["text"] = .string(text) }
        return .object(row.merging(extra) { _, new in new })
    }

    // Decoding: every malformed field refuses the item instead of rendering a half row.
    precondition(WorkIntakeItem(item(1)) != nil && WorkIntakeItem(item(2, kind: "link", status: "suggested")) != nil)
    precondition(WorkIntakeItem(item(2, kind: "link", status: "suggested"))!.text == "Fix the H1", "A link row shows the task text")
    for bad in [item(1, extra: ["id": .string("wi_x")]), item(1, status: "maybe"), item(1, confidence: 1.2), item(1, text: ""),
                item(1, text: nil), item(1, kind: "link", status: "suggested", text: nil), item(1, extra: ["kind": .string("card")]),
                item(1, extra: ["meeting": .object(["title": .string("No file")])])] {
        precondition(WorkIntakeItem(bad) == nil, "Malformed intake item accepted")
    }

    // Review reasons: the three the producer sends read as short labels; anything else shows nothing.
    let labels = ["outside_window": "older meeting", "unclear_task": "may not be a task", "owner_uncertain": "owner unclear"]
    for (reason, label) in labels {
        precondition(WorkIntakeItem(item(3, status: "review", extra: ["reason": .string(reason)]))!.reasonLabel == label)
    }
    precondition(WorkIntakeItem(item(3, status: "review", extra: ["reason": .string("because")]))!.reasonLabel == nil)
    precondition(WorkIntakeItem(item(3, status: "review"))!.reasonLabel == nil)

    // Grouping: asks a session already covers first, then newest meeting; reviews newest first; links by
    // confidence; accepted and dismissed items never count as open.
    let pull: JSONValue = .object(["kind": .string("session"), "id": .string("claude:1"), "title": .string("Bottle launch"), "p": .number(0.7)])
    let details: [String: JSONValue] = ["available": .bool(true), "capabilities": .object(["cardCreation": .bool(true), "linkWrites": .bool(false)]),
        "items": .array([
            item(1, filename: "2026-09-20_Old.md"), item(2, filename: "2026-09-26_New.md"),
            item(3, filename: "2026-09-10_Oldest.md", extra: ["pull": pull]),
            item(10, filename: "2026-09-01_Older.md", extra: ["pull": .object(["kind": .string("session"), "id": .string("claude:b"),
                "title": .string("Hardware"), "p": .number(0.95)])]),
            item(4, status: "review", filename: "2026-09-02_A.md"), item(5, status: "review", filename: "2026-09-25_B.md"),
            item(6, kind: "link", status: "suggested", confidence: 0.62), item(7, kind: "link", status: "suggested", confidence: 0.84),
            item(8, status: "accepted"), item(9, kind: "link", status: "dismissed"), .string("junk"),
        ])]
    let snapshot = WorkIntakeSnapshot(details: details)
    precondition(snapshot.available && snapshot.cardCreation && !snapshot.linkWrites)
    precondition(snapshot.items.count == 10, "One malformed item is dropped, the rest survive")
    precondition(snapshot.asks.map(\.id) == [id(10), id(3), id(2), id(1)], "Likeliest session match first, then newest meeting")
    precondition(snapshot.asks[1].pullTitle == "Bottle launch" && snapshot.asks[1].pullPercent == "70%" && snapshot.asks[2].pullPercent == nil)
    precondition(snapshot.reviews.map(\.id) == [id(5), id(4)])
    precondition(snapshot.suggestedLinks.map(\.id) == [id(7), id(6)] && snapshot.suggestedLinks[0].percent == "84%")
    precondition(snapshot.openCount == 8, "Decided items are not open")
    precondition(WorkIntakeItem(item(2, filename: "2026-09-26_New.md"))!.meetingDate == "9/26")
    precondition(WorkIntakeItem(item(2, filename: "Sep_22_notes.md"))!.meetingDate == "")

    // An older server or a store that is down reads as unavailable, never as an empty Intake.
    let old = WorkIntakeSnapshot(details: ["available": .bool(false), "items": .array([])])
    precondition(!old.available && !old.cardCreation && !old.linkWrites && old.openCount == 0)
    precondition(WorkIntakeSnapshot(details: ["items": .array([])]).available, "A current server that omits the flag is available")
    precondition(!WorkIntakeSnapshot.unavailable.available)
    precondition(!old.storeUnavailable && !old.bridgeUnavailable)
    let down = WorkIntakeSnapshot(details: ["available": .bool(false), "storeUnavailable": .bool(true), "items": .array([])])
    precondition(down.storeUnavailable && !down.available)
    let hiccup = WorkIntakeSnapshot(details: ["items": .array([]), "capabilities": .object(["linkWrites": .bool(false), "cardCreation": .bool(false), "bridgeUnavailable": .bool(true)])])
    precondition(hiccup.bridgeUnavailable && hiccup.available && !hiccup.cardCreation)

    // Only an older server hides Intake; a store that is down or a failed load shows it with the reason.
    let model = ControllerModel(startBackgroundWork: false)
    precondition(!model.workIntakeVisible)
    model.workIntake = old; precondition(!model.workIntakeVisible)
    model.workIntake = down; precondition(model.workIntakeVisible)
    model.workIntake = old; model.workIntakeError = "Work intake was refused (HTTP 500)."; precondition(model.workIntakeVisible)
    model.workIntakeError = nil; model.workIntake = snapshot; precondition(model.workIntakeVisible)

    // Intake is its own route: choosing a view or a domain, from any opener, closes it.
    let state = WorkWorkspaceState()
    state.intakeOpen = true; state.domain = "quilt"; precondition(!state.intakeOpen, "Picking a domain must show that domain")
    state.intakeOpen = true; state.domain = nil; precondition(state.intakeOpen, "Clearing the domain alone keeps Intake open")
    state.intakeOpen = true; state.scope = .all; precondition(!state.intakeOpen, "Picking a view closes Intake")
}

/// People on source meetings, the person network, Jev advice and the Jev key status copy (6.57.0 / 0.5.241).
@MainActor func runWorkPeopleAndAdviceChecks() async throws {
    // People: owners with items first, then attendees; Miles and placeholders left out; one name per person.
    let people = WorkMeetingPeople(recordID: "ops:quilt:2026-09:m.md",
        attendees: ["**Ryan Hopkins** (ryan@quiltsoftware.com)", "Miles Ukaoma", "Gina Obert", "ryan hopkins", "Team"],
        actionItems: [(task: "Fix the H1", owner: "Gina Obert"), (task: "Send SVG logos", owner: "Ryan Hopkins, Vikas Kumar"),
                      (task: "Ship the strip", owner: "MU"), (task: "Someone", owner: "TBD")])
    precondition(people.people == ["Gina Obert", "Ryan Hopkins", "Vikas Kumar"], "\(people.people)")
    precondition(people.items["Ryan Hopkins"] == ["Send SVG logos"] && people.items["Vikas Kumar"] == ["Send SVG logos"])
    precondition(WorkMeetingPeople.cleanName("  **Ana** (ana@x.com)") == "Ana" && WorkMeetingPeople.cleanName("bo@x.com") == "bo")

    // Network: each of their items is on the board, in Intake, or not tracked; other asks; whole-word mentions.
    func row(_ id: String, _ text: String, refs: [JSONValue] = [], checked: Bool = false) -> TaskRow {
        TaskRow(.object(["id": .string(id), "domain": .string("quilt"), "title": .string(String(text.prefix(40))), "text": .string(text),
            "workIdentity": .string(id), "workRevision": .string("r"), "meetingRefs": .array(refs), "checked": .bool(checked)]))!
    }
    let ref: JSONValue = .object(["recordId": .string(people.recordID), "domain": .string("quilt"), "month": .string("2026-09"),
                                  "filename": .string("m.md"), "title": .string("Launch QA")])
    let tasks = [row("a", "Fix the mobile H1 sizing (from Gina Obert)", refs: [ref]), row("b", "Review copy with Gina before launch"),
                 row("c", "Reginald shots for the offsite"), row("d", "Gina closed item", checked: true)]
    func ask(_ n: Int, _ text: String, owner: String, record: String) -> JSONValue {
        .object(["id": .string("wi_" + String(repeating: "0", count: 31) + String(n)), "kind": .string("ask"), "status": .string("ask"),
                 "confidence": .number(0.9), "text": .string(text), "owner": .string(owner),
                 "meeting": .object(["recordId": .string(record), "domain": .string("quilt"), "month": .string("2026-09"),
                                     "filename": .string(record == people.recordID ? "m.md" : "n.md"), "title": .string("M")])])
    }
    let intake = WorkIntakeSnapshot(details: ["items": .array([
        ask(1, "Send the SVG logos", owner: "Ryan Hopkins", record: people.recordID),
        ask(2, "Book the venue for the offsite", owner: "Ryan Hopkins", record: "ops:quilt:2026-09:n.md"),
        ask(3, "Unrelated", owner: "Vikas Kumar", record: "ops:quilt:2026-09:n.md")])])
    let gina = WorkPersonNetwork(name: "Gina Obert", meeting: people, intake: intake, tasks: tasks)
    precondition(gina.meetingItems == [.init(text: "Fix the H1", state: .onBoard(taskTitle: tasks[0].title))], "\(gina.meetingItems)")
    precondition(gina.mentions.map(\.id) == ["a", "b"], "Whole-word first name, open tasks only: \(gina.mentions.map(\.id))")
    let ryan = WorkPersonNetwork(name: "Ryan Hopkins", meeting: people, intake: intake, tasks: tasks)
    precondition(ryan.meetingItems.first?.state == .inIntake(id: "wi_" + String(repeating: "0", count: 31) + "1"))
    precondition(ryan.otherAsks.map(\.text) == ["Book the venue for the offsite"], "The item shown above is not repeated")
    let vikas = WorkPersonNetwork(name: "Vikas Kumar", meeting: people, intake: .unavailable, tasks: tasks)
    precondition(vikas.meetingItems.first?.state == .untracked && vikas.otherAsks.isEmpty)

    // Advice: only a Jev answer with a coherent action; "new" never carries a session.
    precondition(SessionAdvice(details: ["provider": .string("none"), "reason": .string("jev_not_configured")]) == nil)
    precondition(SessionAdvice(details: ["provider": .string("jev"), "action": .string("continue"), "confidence": .number(0.9)]) == nil)
    let fresh = SessionAdvice(details: ["provider": .string("jev"), "action": .string("new"), "sessionId": .string("claude:x"), "confidence": .number(0.73)])!
    precondition(fresh.action == .newSession && fresh.sessionID == nil && fresh.percent == "73%")
    precondition(SessionAdvice(details: ["provider": .string("jev"), "action": .string("fork"), "sessionId": .string("claude:a"), "confidence": .number(1.2)]) == nil)

    // Jev key status reads honestly and never needs the key.
    precondition(JevStatus(details: ["available": .bool(false)]).summary == "Needs server 6.57.0 or later.")
    precondition(JevStatus(details: ["configured": .bool(false)]).summary.hasPrefix("Not set."))
    precondition(JevStatus(details: ["configured": .bool(true), "source": .string("env"), "usedToday": .number(12000), "dailyCap": .number(1000000)])
        .summary.contains("from the server environment"))

    // The workspace asks the server with the task's domain and Work identity, sends only its sessions, and hides
    // advice that names a session it no longer lists.
    final class Recorder: @unchecked Sendable { var calls: [([String], [String: Any])] = [] }
    let recorder = Recorder()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("advice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkHandoffStore(storageURL: root.appendingPathComponent("journal.json"), transport: { args, data in
        recorder.calls.append((args, (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]))
        return HelperResponse(ok: true, message: "", details: ["provider": .string("jev"), "action": .string("continue"),
            "sessionId": .string("claude:b"), "confidence": .number(0.91), "reason": .string("Already doing this task.")])
    })
    store.sessions = [.init(id: "claude:a", nativeID: "a", provider: "claude", title: "Morning brief for Miles Ukaoma. Friday, September 25, 2026", summary: "", project: "MU", status: "idle"),
                      .init(id: "claude:b", nativeID: "b", provider: "claude", title: "COS-glasses Server work", summary: "meeting links", project: "MU", status: "idle")]
    let source = WorkSource.taskSnapshot(row("0123456789ab", "Set up a recurring monthly 1:1 between Miles and this counterpart in 2026"))
    await store.loadAdvice(for: source)
    precondition(recorder.calls.count == 1 && recorder.calls[0].0 == ["work-session-recommend"])
    precondition(recorder.calls[0].1["domain"] as? String == "quilt" && recorder.calls[0].1["id"] as? String == "0123456789ab")
    precondition((recorder.calls[0].1["sessions"] as? [[String: Any]])?.count == 2)
    precondition(store.advice(for: source)?.sessionID == "claude:b")
    await store.loadAdvice(for: source)
    precondition(recorder.calls.count == 1, "One request per task revision")
    store.sessions.removeLast()
    precondition(store.advice(for: source) == nil, "Advice naming a session that is gone is not shown")
    // Without Jev, the word match no longer suggests a Morning brief because both mention "Miles" and "2026".
    precondition(store.recommendations(for: source).isEmpty, "\(store.recommendations(for: source).map(\.title))")
    store.sessions.append(.init(id: "claude:y", nativeID: "y", provider: "claude", title: "2025 and 2026 numbers", summary: "", project: "MU", status: "idle"))
    precondition(store.recommendations(for: WorkSource.taskSnapshot(row("0123456789ac", "Compare 2025 with 2026 spend"))).isEmpty,
                 "Shared years alone are not a topic")

    // Choosing another task closes a person card.
    let state = WorkWorkspaceState()
    state.selectedID = "task:quilt:a"; state.personFocus = people.recordID + "|Gina Obert"
    state.selectedID = "task:quilt:a"; precondition(state.personFocus != nil, "Re-selecting the same task keeps the card")
    state.selectedID = "task:quilt:b"; precondition(state.personFocus == nil)
}

@MainActor func runWorkPersonMatchChecks() {
    // Coverage of the item's key words, including short tokens with digits; filler words do not count.
    precondition(WorkPersonNetwork.similar("Fix the H1", "Fix the mobile H1 sizing (from Gina Obert)"))
    precondition(!WorkPersonNetwork.similar("Fix the H1", "Fix the footer links"), "H1 is a key word")
    precondition(!WorkPersonNetwork.similar("Send the SVG logos to Miles", "Send the recap"))
    precondition(WorkPersonNetwork.similar("Send SVG logos", "Send the SVG logos (from Ryan Hopkins) — Due: 2026-09-24"))
    precondition(!WorkPersonNetwork.similar("the and for", "the and for"), "Only filler: no match")
}
