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

@MainActor func runWorkBoardChecks() {
    precondition(WorkBoardStage.allCases.map(\.rawValue) == ["mentioned", "planned", "draft", "built", "qa", "complete"])
    let samples = WorkWorkspaceProjection.previewRows(Control2PreviewTask.samples)
    precondition(Set(samples.map { WorkBoardStage.stage(for: $0) }) == Set(WorkBoardStage.allCases), "Every stage has a fixture")
    let projected = WorkWorkspaceProjection.items(tasks: samples, reviews: [], receipts: [])
    let filtered = WorkWorkspaceProjection.filter(projected, scope: .all, domain: "Website", query: "")
    let allLanes = WorkBoardStage.allCases.flatMap { stage in filtered.filter { $0.task.map { WorkBoardStage.stage(for: $0) == stage } ?? false } }
    precondition(allLanes.count == samples.count && Set(allLanes.map(\.id)).count == samples.count, "Every task appears exactly once")
    for stage in WorkBoardStage.allCases {
        let task = TaskRow(.object(["id": .string("t"), "domain": .string("d"), "workStage": .string(stage.rawValue), "checked": .bool(true)]))!
        precondition(WorkBoardStage.stage(for: task) == .complete, "Canonical completion wins")
    }
    for legacy in ["planning": "planned", "active": "draft", "review": "qa"] {
        let task = TaskRow(.object(["id": .string("t"), "stage": .string(legacy.key), "agentState": .string("done")]))!
        precondition(WorkBoardStage.stage(for: task).rawValue == legacy.value, "Legacy stage remains visible; agent finished is not task completed")
    }
    let renamed = TaskRow(.object(["id": .string("new-hash"), "workIdentity": .string("original-hash"), "domain": .string("d"), "text": .string("renamed")]))!
    precondition(WorkSource.taskSnapshot(renamed).id == "task:d:original-hash", "Canonical work identity retains receipt history through text edits")
    let narrow = WorkWorkspaceProjection.filter(projected, scope: .all, domain: "Website", query: "navigation build")
    precondition(narrow.count == 1 && WorkBoardStage.stage(for: narrow[0].task!) == .built)
    let override = WorkWorkspaceProjection.previewRows(Control2PreviewTask.samples, stages: ["sample-task-website": "draft"])
    precondition(WorkBoardStage.stage(for: override.first { $0.id == "sample-task-website" }!) == .draft)
    print("PASS Work board: six lanes, exact membership, legacy mappings, completion authority, rename identity and domain search")
}

/// 0.5.244: the board's session row, the shared send plan, the one-click Start work rule, the Continue shortlist,
/// untrusted drops, and acknowledging a finished or failed handoff.
@MainActor func runWorkDashboardChecks() async throws {
    func task(_ id: String, _ domain: String, stage: String = "planned", checked: Bool = false) -> TaskRow {
        TaskRow(.object(["id": .string(id), "domain": .string(domain), "text": .string("Task " + id), "checked": .bool(checked),
                         "workStage": .string(stage)]))!
    }
    let tasks = [task("run", "quilt"), task("reply", "quilt"), task("seen", "quilt"), task("fail", "personal"), task("wait", "quilt"),
                 task("queue", "quilt"), task("idle", "quilt"), task("done", "quilt", checked: true)]
    let sessions = ["run": "running", "reply": "recent", "seen": "recent", "fail": "recent", "wait": "waiting", "queue": "recent"]
        .map { WorkSession(id: "claude:" + $0.key, nativeID: $0.key, provider: "claude", title: "Session " + $0.key, summary: "Summary " + $0.key,
                           project: "COS", status: $0.value, updatedAt: "2026-09-29T04:00:00Z") }
    func receipt(_ id: String, status: String, at: Double) -> WorkHandoffReceipt {
        let source = WorkSource.taskSnapshot(tasks.first { $0.id == id }!)
        return WorkHandoffReceipt(id: "r-" + id, workID: source.id, workTitle: source.title, sourceRevision: source.revision,
            mode: .continueSession, provider: "claude", modelID: "existing-session", sessionID: "claude:" + id,
            sessionTitle: "Session " + id, status: status, detail: "", prompt: "p", createdAt: at, result: status == "delivered" ? "The reply" : nil)
    }
    let receipts = [receipt("run", status: "delivered", at: 1), receipt("reply", status: "delivered", at: 5), receipt("seen", status: "reviewed", at: 9),
                    receipt("fail", status: "failed", at: 3), receipt("wait", status: "delivered", at: 2), receipt("queue", status: "queued", at: 4)]
    let items = WorkWorkspaceProjection.items(tasks: tasks, reviews: [], receipts: receipts, sessions: sessions)
    let all = WorkBoardSessionsProjection.cards(items, domain: nil)
    precondition(all.map(\.item.task!.id) == ["run", "wait", "fail", "reply", "queue"],
                 "Running, waiting on you, needs attention, reply ready, queued; reviewed and untouched cards stay off the row")
    precondition(all.map(\.state) == [.running, .waiting, .attention, .replyReady, .queued])
    precondition(WorkBoardSessionsProjection.cards(items, domain: "quilt").map(\.item.task!.id) == ["run", "wait", "reply", "queue"], "The row follows the board's domain")
    precondition(WorkBoardSessionsProjection.summary(all) == "1 running · 1 waiting for you · 1 needs attention · 1 reply ready · 1 queued")
    precondition(WorkBoardSessionsProjection.summary([]) == "None right now")
    precondition(WorkBoardSessionsProjection.summary(all + all).hasPrefix("2 running · 2 waiting for you · 2 need attention · 2 replies ready"), "Plurals")

    // State precedence: live session state wins over the receipt, and "Running" needs proof.
    func activity(_ status: String, _ session: String?, mode: WorkHandoffMode = .continueSession, acknowledged: Bool = false) -> WorkActivity {
        var r = receipts[1]; r.status = status; r.mode = mode; r.acknowledgedAt = acknowledged ? 1 : nil
        return WorkActivity(receipt: r, session: session.map { WorkSession(id: r.sessionID!, nativeID: "reply", provider: "claude", title: "S", summary: "", project: "", status: $0) })
    }
    let table: [(WorkActivity, WorkHandoffState, String)] = [
        (activity("running", "waiting"), .waiting, "a turn accepted while the session waits on you"),
        (activity("delivered", "error"), .attention, "a delivered turn whose session errored"),
        (activity("running", "recent"), .awaiting, "an accepted Continue turn with an idle session is not proven running"),
        (activity("running", nil, mode: .newSession), .running, "a New session job the server runs"),
        (activity("delivered", "running"), .running, "a delivered turn the session is working on"),
        (activity("delivered", nil), .sent, "no observed session: sent, not reply ready"),
        (activity("delivered", "recent"), .replyReady, "delivered and the session went quiet"),
        (activity("completed", nil), .replyReady, "a finished job"),
        (activity("sending", nil), .running, "a send in progress"),
        (activity("queued", "recent"), .queued, "queued behind a turn"),
        (activity("unknown", nil), .attention, "unconfirmed delivery"),
        (activity("refused", nil), .attention, "refused"),
        (activity("canceled", nil), .settled, "canceled is terminal"),
        (activity("completed", nil, acknowledged: true), .settled, "an acknowledged reply is settled"),
        (activity("reviewed", "recent"), .settled, "reviewed"),
    ]
    for (value, expected, why) in table { precondition(WorkHandoffState(value) == expected, "state: " + why) }
    precondition(!WorkHandoffState.running.offersAcknowledge && !WorkHandoffState.waiting.offersAcknowledge && !WorkHandoffState.awaiting.offersAcknowledge
                 && WorkHandoffState.replyReady.offersAcknowledge && WorkHandoffState.attention.offersAcknowledge, "Live work is never acknowledged from a card")

    // A card edited since its handoff keeps its session on the row; a completed card only while still in progress.
    let editedTask = TaskRow(.object(["id": .string("run"), "domain": .string("quilt"), "text": .string("Task run, edited"), "checked": .bool(false), "workStage": .string("planned")]))!
    let edited = WorkWorkspaceProjection.items(tasks: [editedTask], reviews: [], receipts: receipts, sessions: sessions)
    precondition(edited[0].activity == nil, "the board item's activity is revision-bound")
    let editedCards = WorkBoardSessionsProjection.cards(edited, receipts: receipts, sessions: sessions, domain: nil)
    precondition(editedCards.count == 1 && editedCards[0].earlierRevision && editedCards[0].state == .running, "…but its running session stays on the row")
    var doneReply = receipt("done", status: "delivered", at: 7); doneReply.sessionID = nil
    let doneItems = WorkWorkspaceProjection.items(tasks: tasks, reviews: [], receipts: [doneReply], sessions: [])
    precondition(WorkBoardSessionsProjection.cards(doneItems, domain: nil).isEmpty, "A completed card with a finished reply leaves the row")
    var doneRunning = receipt("done", status: "sending", at: 7); doneRunning.sessionID = nil
    precondition(WorkBoardSessionsProjection.cards(WorkWorkspaceProjection.items(tasks: tasks, reviews: [], receipts: [doneRunning], sessions: []), domain: nil).count == 1,
                 "…unless it is still in progress")
    var acknowledgedReply = receipts[1]; acknowledgedReply.status = "completed"; acknowledgedReply.acknowledgedAt = 5
    let ackItems = WorkWorkspaceProjection.items(tasks: tasks, reviews: [], receipts: [acknowledgedReply], sessions: sessions)
    precondition(WorkBoardSessionsProjection.cards(ackItems, domain: nil).isEmpty && !ackItems.contains(where: \.needsAttention),
                 "Acknowledging a completed reply clears it from the row and from Needs attention")
    // Ages: while running, time since sent; once quiet, time since the session was active.
    let running = all[0]
    precondition(running.ageText(now: Date(timeIntervalSince1970: 1 + 42 * 60)) == "sent 42 min ago")
    let quiet = all.first { $0.state == .replyReady }!
    precondition(quiet.ageText(now: quiet.activity.session!.updatedDate!.addingTimeInterval(3 * 3_600)) == "active 3 h ago")

    // Overlay close rule: never on the saved intent; close once delivered or running; stay on a refusal to show why.
    func newest(_ id: String, _ status: String) -> WorkHandoffReceipt { var r = receipts[1]; r.id = id; r.status = status; return r }
    precondition(WorkStartOutcome.after(openedWith: nil, newest: nil) == .waiting)
    precondition(WorkStartOutcome.after(openedWith: "old", newest: newest("old", "delivered")) == .waiting, "an older receipt is not this send")
    precondition(WorkStartOutcome.after(openedWith: "old", newest: newest("new", "sending")) == .waiting, "the intent row is not a delivery")
    precondition(WorkStartOutcome.after(openedWith: nil, newest: newest("new", "delivered")) == .close)
    precondition(WorkStartOutcome.after(openedWith: "old", newest: newest("new", "running")) == .close)
    precondition(WorkStartOutcome.after(openedWith: "old", newest: newest("new", "refused")) == .showResult)
    precondition(WorkStartOutcome.after(openedWith: "old", newest: newest("new", "unknown")) == .showResult)
    precondition(WorkBoardSessionCard.excerpt(receipt: receipts[1], session: nil) == "The reply")
    precondition(WorkBoardSessionCard.excerpt(receipt: receipts[5], session: sessions.first { $0.id == "claude:queue" }) == "Summary queue")
    precondition(WorkBoardSessionCard.shortAge(30) == "now" && WorkBoardSessionCard.shortAge(240) == "4 min" && WorkBoardSessionCard.shortAge(3 * 3_600 + 5) == "3 h"
                 && WorkBoardSessionCard.shortAge(2 * 86_400) == "2 d")
    precondition(sessions[0].updatedDate != nil && WorkSession(id: "a", nativeID: "a", provider: "claude", title: "", summary: "", project: "", status: "").updatedDate == nil)

    // Send plan: one resolver for the composer and the overlay.
    let claude = WorkSession(id: "claude:c", nativeID: "c", provider: "claude", title: "Claude work", summary: "", project: "", status: "recent")
    let cursor = WorkSession(id: "cursor:k", nativeID: "k", provider: "cursor", title: "Cursor work", summary: "", project: "", status: "recent")
    let ollama = WorkSession(id: "ollama:o", nativeID: "o", provider: "ollama", title: "Local", summary: "", project: "", status: "recent")
    let models = [WorkModelChoice(id: "opus", provider: "claude", title: "Opus", available: true, reason: nil),
                  WorkModelChoice(id: "gone", provider: "claude", title: "Gone", available: false, reason: "offline"),
                  WorkModelChoice(id: "frontier", provider: "codex", title: "Frontier", available: true, reason: nil)]
    let pool = [claude, cursor, ollama]
    func draft(_ mode: WorkHandoffMode, session: String = "", provider: String = "", model: String = "", prompt: String = "Do it") -> WorkHandoffDraft {
        WorkHandoffDraft(sourceID: "s", sourceRevision: "r", mode: mode, sessionID: session, provider: provider, modelID: model, prompt: prompt)
    }
    func plan(_ d: WorkHandoffDraft) -> WorkSendPlan? { WorkHandoffStore.sendPlan(draft: d, sessions: pool, models: models) }
    precondition(plan(draft(.newSession, provider: "claude", model: "opus"))?.label == "Start new Claude session")
    precondition(plan(draft(.newSession, provider: "claude", model: "gone")) == nil, "An unavailable model cannot send")
    precondition(plan(draft(.newSession, provider: "codex", model: "opus")) == nil, "Model and provider must match")
    precondition(plan(draft(.continueSession, session: "claude:c"))?.label == "Send to \u{201C}Claude work\u{201D}")
    precondition(WorkSendPlan.clip("Retail Liquor Summit Campaign Launch Follow-up Pack") == "Retail Liquor Summit Campaign Launch Fo\u{2026}"
                 && WorkSendPlan.clip("Short") == "Short" && WorkSendPlan.clip(String(repeating: "a", count: 40)).count == 40,
                 "Titles clip at 40 characters so the send button stays on one line")
    precondition(plan(draft(.continueSession, session: "cursor:k")) != nil && plan(draft(.continueSession, session: "ollama:o")) == nil)
    precondition(plan(draft(.continueSession)) == nil && plan(draft(.continueSession, session: "claude:missing")) == nil)
    precondition(plan(draft(.fork, session: "claude:c"))?.crossPlatform == false && plan(draft(.fork, session: "cursor:k")) == nil,
                 "A native fork needs a Claude or Codex session")
    let cross = plan(draft(.fork, session: "cursor:k", provider: "codex", model: "frontier"))
    precondition(cross?.crossPlatform == true && cross?.label == "Fork to Codex (OpenAI)" && cross?.model?.id == "frontier")
    precondition(plan(draft(.fork, session: "ollama:o", provider: "codex", model: "frontier")) == nil, "Ollama has no transcript to carry over")
    let codexDown = [WorkModelChoice(id: "frontier", provider: "codex", title: "Frontier", available: false, reason: "signed out")]
    precondition(WorkHandoffStore.sendPlan(draft: draft(.fork, session: "cursor:k", provider: "codex", model: "frontier"), sessions: pool, models: codexDown) == nil,
                 "A fork to another platform needs its target model available")
    precondition(plan(draft(.continueSession, session: "claude:c", prompt: "   ")) == nil)
    // 0.5.247: a draft leaves room for the tracking line every send adds, so the sent prompt stays within 32,000.
    precondition(plan(draft(.continueSession, session: "claude:c", prompt: String(repeating: "x", count: WorkHandoffStore.draftLimit + 1))) == nil)
    precondition(plan(draft(.continueSession, session: "claude:c", prompt: String(repeating: "x", count: WorkHandoffStore.draftLimit))) != nil)
    precondition(WorkHandoffStore.draftLimit + WorkProgress.instruction(tag: "0123456789ab").utf16.count <= 32_000,
                 "The instruction fits the room kept for it")

    // Start work: one click only for a complete saved draft, or Continue/Fork advice at its bar, on work with no history.
    func advice(_ action: String, _ session: String?, _ confidence: Double) -> SessionAdvice {
        var details: [String: JSONValue] = ["provider": .string("jev"), "action": .string(action), "confidence": .number(confidence), "reason": .string("Same work.")]
        if let session { details["sessionId"] = .string(session) }
        return SessionAdvice(details: details)!
    }
    func start(_ d: WorkHandoffDraft, _ a: SessionAdvice?, history: Bool = false) -> (plan: WorkSendPlan, fromAdvice: Bool)? {
        WorkHandoffStore.startPlan(draft: d, advice: a, sessions: pool, models: models, hasHistory: history)
    }
    let blank = draft(.continueSession)
    precondition(start(blank, nil) == nil, "Nothing says where it goes: full chooser")
    let saved = start(draft(.continueSession, session: "claude:c"), advice("continue", "cursor:k", 0.9))
    precondition(saved?.fromAdvice == false && saved?.plan.session?.id == "claude:c", "A destination you chose wins over a suggestion")
    let suggested = start(blank, advice("continue", "cursor:k", WorkHandoffStore.oneClickContinue))
    precondition(suggested?.fromAdvice == true && suggested?.plan.session?.id == "cursor:k")
    precondition(start(blank, advice("continue", "cursor:k", WorkHandoffStore.oneClickContinue - 0.01)) == nil, "A weak suggestion opens the chooser")
    precondition(start(blank, advice("fork", "claude:c", WorkHandoffStore.oneClickFork))?.plan.mode == .fork)
    precondition(start(blank, advice("fork", "claude:c", WorkHandoffStore.oneClickFork - 0.01)) == nil)
    precondition(start(blank, advice("new", nil, 0.95)) == nil, "New advice is never one click")
    precondition(start(draft(.continueSession, provider: "claude", model: "opus"), advice("new", nil, 0.99)) == nil,
                 "New advice stays a chooser even when a leftover model would make the draft complete")
    precondition(start(draft(.newSession, provider: "codex", model: "frontier"), advice("fork", "claude:c", 0.9))?.plan.mode == .newSession)
    precondition(start(draft(.continueSession, session: "claude:c"), advice("continue", "claude:c", 0.95), history: true) == nil,
                 "Work that already has a handoff never gets one click: its draft may be the one already sent")
    // A drop runs by itself only when every criterion holds (Miles 2026-09-29).
    func auto(_ d: WorkHandoffDraft, _ a: SessionAdvice?, history: Bool = false, pool p: [WorkSession] = pool) -> WorkSendPlan? {
        WorkHandoffStore.autoStartPlan(draft: d, advice: a, sessions: p, models: models, hasHistory: history)
    }
    precondition(auto(draft(.continueSession, session: "claude:c"), nil)?.session?.id == "claude:c", "saved destination, idle session, no history: runs")
    precondition(auto(blank, advice("continue", "cursor:k", WorkHandoffStore.oneClickContinue))?.session?.id == "cursor:k", "confident suggestion: runs")
    precondition(auto(blank, nil) == nil && auto(blank, advice("continue", "cursor:k", WorkHandoffStore.oneClickContinue - 0.01)) == nil, "nothing certain: asks")
    precondition(auto(draft(.continueSession, session: "claude:c"), nil, history: true) == nil, "work with a handoff already: asks")
    precondition(auto(blank, advice("new", nil, 0.99)) == nil, "New advice names no model: asks")
    for busy in ["running", "working", "waiting"] {
        var s = claude; s.status = busy
        precondition(auto(draft(.continueSession, session: "claude:c"), nil, pool: [s, cursor, ollama]) == nil, "a busy Continue target (\(busy)) asks")
        precondition(auto(draft(.fork, session: "claude:c"), nil, pool: [s, cursor, ollama])?.mode == .fork, "forking a busy session copies it without interrupting: runs")
    }
    precondition(plan(draft(.continueSession, session: "claude:c"))?.verb == "Send" && plan(draft(.fork, session: "claude:c"))?.verb == "Fork and send"
                 && cross?.verb == "Fork to Codex (OpenAI)" && plan(draft(.newSession, provider: "claude", model: "opus"))?.verb == "Start session")

    // Shortlist: Jev's pick, word matches, then most recent; no repeats; at most three.
    var recentA = claude; recentA.updatedAt = "2026-09-29T03:00:00Z"
    var recentB = cursor; recentB.updatedAt = "2026-09-29T04:00:00Z"
    var old = ollama; old.updatedAt = "2026-09-01T00:00:00Z"
    let extra = WorkSession(id: "codex:x", nativeID: "x", provider: "codex", title: "Extra", summary: "", project: "", status: "recent", updatedAt: "2026-09-29T05:00:00Z")
    let list = WorkHandoffStore.shortlist(advised: "ollama:o", matches: [recentA], sessions: [recentA, recentB, old, extra])
    precondition(list.map(\.id) == ["ollama:o", "claude:c", "codex:x"])
    precondition(WorkHandoffStore.shortlist(advised: "missing", matches: [], sessions: [recentA, recentB]).map(\.id) == ["cursor:k", "claude:c"])
    // Half a second later than recentB's 04:00:00Z, yet "." sorts before "Z", so a raw string sort would put it second.
    var fractional = recentA; fractional.updatedAt = "2026-09-29T04:00:00.500Z"
    precondition("2026-09-29T04:00:00.500Z" < "2026-09-29T04:00:00Z", "fixture: string order must disagree with date order")
    precondition(WorkHandoffStore.shortlist(advised: nil, matches: [], sessions: [recentB, fractional]).map(\.id) == ["claude:c", "cursor:k"],
                 "Recency compares dates, not ISO strings with and without fractions")

    // Drops are untrusted text.
    precondition(WorkWorkspaceProjection.startable(id: "task:quilt:nope", items: items) == nil)
    precondition(WorkWorkspaceProjection.startable(id: items.first { $0.task?.id == "done" }!.id, items: items) == nil, "A completed card cannot be started")
    precondition(WorkWorkspaceProjection.startable(id: items.first { $0.task?.id == "idle" }!.id, items: items)?.task?.id == "idle")
    let idleID = items.first { $0.task?.id == "idle" }!.id
    precondition(WorkWorkspaceProjection.stageDrop(id: idleID, items: items, to: .planned) == nil, "Dropping on its own column is not a move")
    precondition(WorkWorkspaceProjection.stageDrop(id: idleID, items: items, to: .draft)?.id == "idle")
    precondition(WorkWorkspaceProjection.stageDrop(id: "random text", items: items, to: .draft) == nil)
    // The pinned Start work column casts its edge only when cards run under it (derived from the layout constants).
    let fits = WorkBoardSessionCard.pinnedColumnWidth + 2 * WorkBoardSessionCard.cardWidth + WorkBoardSessionCard.cardGap
    precondition(!WorkBoardSessionCard.rowOverflows(cards: 2, width: fits), "two cards that fit beside the column stay flat")
    precondition(WorkBoardSessionCard.rowOverflows(cards: 2, width: fits - 1), "one point short runs under it")
    precondition(WorkBoardSessionCard.rowOverflows(cards: 3, width: fits), "a third card runs under it")
    precondition(!WorkBoardSessionCard.rowOverflows(cards: 0, width: 400) && !WorkBoardSessionCard.rowOverflows(cards: 3, width: 0), "no cards, or not measured yet: flat")
    precondition(WorkLayout(rawValue: "board") == .board && WorkLayout(rawValue: "focus") == .focus && WorkLayout(rawValue: "junk") == nil)
    let writable = TaskRow(.object(["id": .string("w"), "domain": .string("quilt"), "workRevision": .string("rev-1")]))!
    let noRevision = TaskRow(.object(["id": .string("n"), "domain": .string("quilt")]))!
    precondition(WorkWorkspaceProjection.canChangeStage(writable, isolated: false, writable: true, busy: false))
    precondition(!WorkWorkspaceProjection.canChangeStage(writable, isolated: false, writable: false, busy: false), "Read-only board")
    precondition(!WorkWorkspaceProjection.canChangeStage(writable, isolated: false, writable: true, busy: true), "Another write in flight")
    precondition(!WorkWorkspaceProjection.canChangeStage(noRevision, isolated: false, writable: true, busy: false), "No revision to compare-and-set")
    precondition(WorkWorkspaceProjection.canChangeStage(noRevision, isolated: true, writable: false, busy: false), "The preview always moves")

    // A finished New session ("completed") and a failure can be acknowledged; in-flight work cannot.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-dashboard-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for (status, expectOK) in [("completed", true), ("failed", true), ("refused", true), ("canceled", true), ("delivered", true),
                               ("running", false), ("unknown", false), ("queued", false), ("reviewed", false)] {
        var row = receipts[1]; row.id = "ack-" + status; row.status = status; row.detail = "Original detail for " + status
        let url = root.appendingPathComponent(status + "/journal.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row))
        try JSONSerialization.data(withJSONObject: ["version": 2, "receipts": [encoded], "sessions": [], "drafts": []]).write(to: url)
        let store = WorkHandoffStore(storageURL: url, transport: { _, _ in HelperResponse(ok: true, message: "", details: [:]) })
        precondition(store.receipts.first?.id == row.id, "fixture journal loads")
        precondition(row.acknowledgeable == expectOK, "acknowledgeable \(status)")
        store.markReviewed(receiptID: row.id)
        let reread = WorkHandoffStore(storageURL: url, transport: { _, _ in HelperResponse(ok: true, message: "", details: [:]) }).receipts.first!
        if !expectOK {
            precondition(reread.status == status && reread.acknowledgedAt == nil, "\(status) cannot be acknowledged")
        } else if status == "delivered" {
            precondition(reread.status == "reviewed" && !reread.blocksNewHandoff, "a delivered reply becomes reviewed, as in 0.5.243")
        } else {
            // History is kept: the status and the reason stay, so a refusal never reads as a delivery.
            precondition(reread.status == status && reread.detail == row.detail && reread.acknowledgedAt != nil && !reread.acknowledgeable,
                         "\(status) keeps its status and detail when acknowledged")
        }
    }
    // A refused handoff that was acknowledged still never names its session as doing the work.
    var refused = receipts[1]; refused.status = "refused"; refused.acknowledgedAt = 1
    precondition(WorkHandoffStore.latestReceipt(forSession: refused.sessionID!, in: [refused]) == nil)
    // Canceled never blocks; unknown does, until cleared after a check.
    precondition(!newest("c", "canceled").blocksNewHandoff && newest("u", "unknown").blocksNewHandoff)
    let unknownURL = root.appendingPathComponent("unknown-clear/journal.json")
    try FileManager.default.createDirectory(at: unknownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var unknown = receipts[1]; unknown.id = "u1"; unknown.status = "unknown"; unknown.detail = "Turn receipt unavailable."
    try JSONSerialization.data(withJSONObject: ["version": 2, "receipts": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown))], "sessions": [], "drafts": []]).write(to: unknownURL)
    let unknownStore = WorkHandoffStore(storageURL: unknownURL, transport: { _, _ in HelperResponse(ok: true, message: "", details: [:]) })
    unknownStore.markReviewed(receiptID: "u1")
    precondition(unknownStore.receipts.first?.status == "unknown", "Mark reviewed does not clear an unconfirmed delivery")
    unknownStore.clearUnresolved(receiptID: "u1")
    let cleared = WorkHandoffStore(storageURL: unknownURL, transport: { _, _ in HelperResponse(ok: true, message: "", details: [:]) }).receipts.first!
    precondition(cleared.status == "reviewed" && !cleared.blocksNewHandoff && cleared.detail.hasSuffix("Turn receipt unavailable."),
                 "Clearing after a check unblocks the work and keeps the earlier detail")
    precondition(cleared.clearedUnconfirmed && WorkHandoffStore.latestReceipt(forSession: cleared.sessionID!, in: [cleared]) == nil,
                 "A cleared unknown never names its session as having received the work")
    var reviewedReply = receipts[1]; reviewedReply.status = "reviewed"
    precondition(!reviewedReply.clearedUnconfirmed && WorkHandoffStore.latestReceipt(forSession: reviewedReply.sessionID!, in: [reviewedReply])?.id == reviewedReply.id,
                 "A reviewed reply still does")
    // Server job states: terminal ones are completed, failed, canceled and interrupted (recorded as failed).
    for (state, expected) in [("completed", "completed"), ("failed", "failed"), ("canceled", "canceled"), ("interrupted", "failed"),
                              ("accepted", "running"), ("starting", "running"), ("queued", "running"), ("running", "running"),
                              ("answer_ready", "running"), ("mystery", "unknown")] {
        precondition(WorkHandoffReceipt.receiptStatus(forJobState: state) == expected, "job state " + state)
    }
    print("PASS Work dashboard: session row and states, precedence, earlier-revision cards, send plan, one-click rule, overlay close, shortlist, drops, acknowledge keeps history")
}
