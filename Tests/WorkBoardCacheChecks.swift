import Foundation

/// 0.5.254 resize pass: the Work board keeps its rows (WorkWorkspaceState.board) until one of their sources changes. A
/// stale row is a wrong board, so every source is changed here the way the app changes it (in place, by a reload, by a
/// session check) and the rows must follow; and nothing that leaves the data alone, such as a resize, may rebuild them.
/// Failures read "check failed [<behaviour>]" so the mutation lane (Tests/mutate-work-board-cache.py) can attribute
/// each kill. No window, no event, no server.
@MainActor func runWorkBoardCacheChecks() async throws {
    func check(_ ok: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
        if !ok { fatalError("check failed [\(behaviour)]: \(detail())") }
    }
    func task(_ id: String, _ domain: String = "quilt", stage: String = "planned", checked: Bool = false) -> TaskRow {
        TaskRow(.object(["id": .string(id), "domain": .string(domain), "text": .string("Task " + id), "checked": .bool(checked),
                         "workStage": .string(stage), "workRevision": .string("rev-" + id)]))!
    }
    func session(_ native: String, _ state: String) -> JSONValue {
        .object(["id": .string(native), "provider": .string("claude"), "name": .string("Session " + native), "state": .string(state),
                 "updatedAt": .string("2026-10-01T15:00:00Z")])
    }
    final class Rows: @unchecked Sendable { var value: [JSONValue] = [] }
    let rows = Rows()
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("cos-board-cache-\(UUID().uuidString.prefix(8)) é.d", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    // The live board: tasks from the model, the journal and the session check from the handoff store.
    let model = ControllerModel(startBackgroundWork: false)
    model.workTasks = [task("a"), task("b", stage: "draft"), task("c", "personal")]
    let handoff = WorkHandoffStore(storageURL: home.appendingPathComponent("handoffs.json"), transport: { args, _ in
        guard args.first == "claude-sessions" else { throw HelperClientError.invalidResponse("The cache check only lists sessions.") }
        return HelperResponse(ok: true, message: "", details: ["sessions": .array(rows.value)])
    })
    let reviews = WorkReviewStore(transport: { _, _ in throw HelperClientError.invalidResponse("The cache check never calls the helper.") })
    let state = WorkWorkspaceState()
    func board(now: Date = Date()) -> WorkBoardMemo { state.board(model: model, handoffStore: handoff, reviewStore: reviews, now: now) }
    func item(_ id: String) -> WorkWorkspaceItem? { board().items.first { $0.task?.id == id } }
    func column(_ stage: WorkBoardStage, domain: String? = nil, query: String = "") -> [String] {
        let memo = board()
        _ = memo.visible(scope: .all, domain: domain, query: query)
        return memo.column(stage).compactMap { $0.task?.id }
    }
    check(column(.planned) == ["a", "c"] && column(.draft) == ["b"], "board rows", "\(column(.planned)) \(column(.draft))")

    // Nothing changed (a resize, a hover, a redraw): the rows are not rebuilt, however often they are read.
    var built = WorkBoardMetrics.projections
    for _ in 0..<20 { _ = column(.planned); _ = column(.draft, query: "Task"); _ = board().item(sourceID: "x") }
    check(WorkBoardMetrics.projections == built, "unchanged data keeps the rows", "rebuilt \(WorkBoardMetrics.projections - built) times")

    // A stage move, in place and by a reload.
    model.workTasks[0] = task("a", stage: "qa")
    check(column(.qa) == ["a"] && column(.planned) == ["c"], "stale after a stage move", "qa \(column(.qa)) planned \(column(.planned))")
    model.workTasks = [task("a", stage: "qa"), task("b", stage: "built"), task("c", "personal")]
    check(column(.built) == ["b"] && column(.draft).isEmpty, "stale after a stage move", "a reload: built \(column(.built))")

    // A receipt: added, then changed in place.
    let source = WorkSource.taskSnapshot(model.workTasks[1])
    handoff.receipts.append(WorkHandoffReceipt(id: "r-b", workID: source.id, workTitle: source.title, sourceRevision: source.revision,
                                               mode: .continueSession, provider: "claude", modelID: "opus", sessionID: "claude:native-b",
                                               sessionTitle: "Session native-b", status: "delivered", detail: "", prompt: "p", createdAt: 1))
    check(item("b")?.activity?.receipt.status == "delivered", "stale after a receipt change", "added: \(String(describing: item("b")?.activity?.receipt.status))")
    handoff.receipts[0].status = "failed"
    check(item("b")?.activity?.receipt.status == "failed" && item("b")?.needsAttention == true, "stale after a receipt change",
          "changed in place: \(String(describing: item("b")?.activity?.receipt.status))")
    check(board().item(sourceID: source.id)?.activity?.receipt.status == "failed", "stale after a receipt change", "the lookup by work id")

    // The session check: a new session state shows; the same list again rebuilds nothing; a check 45 s old drops it.
    handoff.receipts[0].status = "delivered"
    rows.value = [session("native-b", "running")]
    await handoff.refreshActivity()
    check(item("b")?.activity?.session?.status == "running", "stale after a session change", "\(String(describing: item("b")?.activity?.session?.status))")
    rows.value = [session("native-b", "waiting")]
    await handoff.refreshActivity()
    check(item("b")?.activity?.session?.status == "waiting", "stale after a session change", "\(String(describing: item("b")?.activity?.session?.status))")
    built = WorkBoardMetrics.projections
    await handoff.refreshActivity()
    _ = column(.built)
    check(WorkBoardMetrics.projections == built, "an unchanged session check keeps the rows", "rebuilt \(WorkBoardMetrics.projections - built) times")
    check(board(now: Date().addingTimeInterval(46)).items.first { $0.task?.id == "b" }?.activity?.session == nil, "stale after the session check expires")
    check(item("b")?.activity?.session?.status == "waiting", "stale after the session check expires", "back within 45 s")

    // The session row's cards follow the journal and the board's domain.
    func cards(_ domain: String?) -> [String] {
        board().sessionCards(domain: domain) { WorkBoardSessionsProjection.cards($0, receipts: handoff.receipts, sessions: handoff.observedSessions(), domain: domain) }
            .compactMap { $0.item.task?.id }
    }
    check(cards(nil) == ["b"] && cards("personal").isEmpty && cards(nil) == ["b"], "session cards follow the domain", "\(cards(nil)) \(cards("personal"))")
    handoff.receipts[0].status = "reviewed"
    check(cards(nil).isEmpty, "stale session cards after a receipt change", "\(cards(nil))")

    // The filter: query, domain and scope each change what is visible.
    check(column(.qa, query: "Task a") == ["a"] && column(.qa, query: "nothing like it").isEmpty, "the filter follows the query")
    check(column(.planned, domain: "personal") == ["c"] && column(.planned, domain: "quilt").isEmpty, "the filter follows the domain")
    let memo = board()
    check(memo.visible(scope: .completed, domain: nil, query: "").isEmpty && memo.visible(scope: .all, domain: nil, query: "").count == 3,
          "the filter follows the scope")
    model.workTasks[2] = task("c", "personal", stage: "draft")
    check(column(.draft, domain: "personal") == ["c"], "stale after a stage move", "the same filter after a move: \(column(.draft, domain: "personal"))")

    // A meeting review.
    let review = WorkReviewRecord(.object([
        "id": .string("rv1"), "status": .string("ready"), "canonicalMeetingId": .string("m1"), "markdown": .string("Follow up."),
        "source": .object(["title": .string("Weekly review"), "domain": .string("quilt"), "revision": .string("1"),
            "descriptor": .object(["recordId": .string("m1"), "domain": .string("quilt"), "month": .string("2026-09"), "filename": .string("2026-09-30_Weekly.md")])])]))!
    reviews.reviews = [review]
    check(board().items.contains { $0.review?.id == "rv1" } && board().item(id: "meeting-review:rv1") != nil, "stale after a review change")

    // Another model, journal or review store on the same state never reads the first one's rows, even at equal epochs.
    let other = ControllerModel(startBackgroundWork: false)
    other.workTasks = [task("z")]
    while other.workTasksEpoch < model.workTasksEpoch { other.workTasks = other.workTasks }
    check(other.workTasksEpoch == model.workTasksEpoch, "stores in the key", "the epochs could not be matched")
    check(state.board(model: other, handoffStore: handoff, reviewStore: reviews).items.compactMap { $0.task?.id } == ["z"], "stores in the key")

    // The isolated preview: its sample tasks, their stages and its sample sessions.
    let preview = WorkHandoffStore(isolated: true)
    let previewState = WorkWorkspaceState()
    func previewBoard() -> WorkBoardMemo { previewState.board(model: model, handoffStore: preview, reviewStore: reviews) }
    let sample = preview.previewTasks.first { !$0.completed }!
    func previewItem() -> WorkWorkspaceItem? { previewBoard().items.first { $0.task?.id == sample.id } }
    check(previewItem()?.completed == false, "preview rows")
    preview.previewTasks[preview.previewTasks.firstIndex { $0.id == sample.id }!].completed = true
    check(previewItem()?.completed == true, "stale after a preview task change")
    preview.previewTasks[preview.previewTasks.firstIndex { $0.id == sample.id }!].completed = false
    // Read between the two changes: otherwise the task change's rebuild would also carry the stage (a mutant hid there).
    check(previewItem()?.completed == false && previewItem()?.task?.workStage != "built", "stale after a preview task change")
    previewState.previewStages[sample.id] = "built"
    check(previewItem()?.task?.workStage == "built", "stale after a preview stage move", "\(String(describing: previewItem()?.task?.workStage))")
    let previewSource = WorkSource.taskSnapshot(previewItem()!.task!)
    preview.receipts = [WorkHandoffReceipt(id: "pr", workID: previewSource.id, workTitle: previewSource.title, sourceRevision: previewSource.revision,
                                           mode: .continueSession, provider: "claude", modelID: "opus", sessionID: "claude:preview-native",
                                           sessionTitle: "Preview", status: "delivered", detail: "", prompt: "p", createdAt: 1)]
    preview.sessions = [WorkSession(id: "claude:preview-native", nativeID: "preview-native", provider: "claude", title: "Preview", summary: "",
                                    project: "", status: "running")]
    check(previewItem()?.activity?.session?.status == "running", "stale after a session change", "the preview's sessions")
    preview.sessions[0].status = "waiting"
    check(previewItem()?.activity?.session?.status == "waiting", "stale after a session change", "a preview session changed in place")

    // The session row's pinned column: the stored count of cards that fit says exactly what the measured width did.
    for card in 0...6 {
        for step in 0...6_000 {
            let width = CGFloat(step) / 2
            check(WorkBoardSessionCard.rowOverflows(cards: card, width: width) == (card > WorkBoardSessionCard.rowCapacity(width: width)),
                  "row capacity matches the overflow rule", "\(card) cards at \(width) pt")
        }
    }
    print("PASS: Work board rows are rebuilt only when tasks, receipts, the session check, reviews or the preview change (0.5.254)")
}
