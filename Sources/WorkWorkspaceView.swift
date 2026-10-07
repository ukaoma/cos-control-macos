import AppKit
import SwiftUI

struct WorkActivity: Identifiable {
    let receipt: WorkHandoffReceipt
    let session: WorkSession?
    var id: String { receipt.id }
    var observingTurn: Bool { ["sending", "queued", "running", "delivered"].contains(receipt.status) }
    var sessionRunning: Bool { observingTurn && ["running", "working"].contains(session?.status ?? "") }
    var needsAttention: Bool {
        guard receipt.acknowledgedAt == nil else { return false }   // 0.5.244: acknowledged, status kept
        return ["unknown", "failed", "refused", "delivered", "completed"].contains(receipt.status)
            || (observingTurn && ["waiting", "error", "failed"].contains(session?.status ?? ""))
    }
    var inProgress: Bool { ["preparing", "sending", "queued", "running"].contains(receipt.status) || sessionRunning }
    var title: String {
        if receipt.acknowledgedAt != nil { return ["failed", "refused"].contains(receipt.status) ? "Failure acknowledged" : "Reviewed" }
        switch receipt.status {
        case "unknown": return "Delivery needs checking"
        case "failed", "refused": return "Needs attention"
        case "completed": return "Response ready for review"
        case "reviewed": return "Reviewed"
        case "canceled": return "Canceled"
        case "queued": return "Queued for session"
        default:
            if sessionRunning { return "Session running" }
            if observingTurn && session?.status == "waiting" { return "Session needs your input" }
            if observingTurn && ["error", "failed"].contains(session?.status ?? "") { return "Session needs attention" }
            if receipt.status == "delivered" { return "Sent to session" }
            return inProgress ? "Handoff in progress" : receipt.status.capitalized
        }
    }
    var glyph: String { inProgress ? "clock" : needsAttention ? "circle.dashed" : "checkmark.circle" }
    var sessionState: String {
        guard let session else { return "Live status unavailable" }
        switch session.status {
        case "running", "working": return "Running"
        case "waiting": return "Waiting for input"
        case "error", "failed": return "Needs attention"
        case "idle", "recent", "completed": return "Idle"
        default: return "Live status unknown"
        }
    }
}

enum WorkActivityProjection {
    static func latest(workID: String, revision: String, receipts: [WorkHandoffReceipt], sessions: [WorkSession]) -> WorkActivity? {
        guard let receipt = receipts.filter({ $0.workID == workID && $0.sourceRevision == revision })
            .sorted(by: { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }).first else { return nil }
        // Only a receipt establishes this association. A suggestion or matching
        // title must not paint somebody else's session as this task's activity.
        let session = WorkHandoffStore.listedSession(for: receipt, in: sessions)
        return WorkActivity(receipt: receipt, session: session)
    }
}

/// 0.5.244: Work opens as a Board (sessions working now over the Kanban) or in Focus (the list, with the Agent
/// workspace pinned beside the selected item). The choice is remembered.
enum WorkLayout: String, CaseIterable, Identifiable {
    case board, focus
    var id: String { rawValue }
    var title: String { self == .board ? "Board" : "Focus" }
}

/// One Work handoff on the board's session row: a session working on, or waiting on you for, one Work item.
struct WorkBoardSessionCard: Identifiable {
    let item: WorkWorkspaceItem
    let activity: WorkActivity
    /// The handoff was made on an earlier version of this card (it was edited or linked since).
    var earlierRevision = false
    var id: String { activity.receipt.id }
    var state: WorkHandoffState { WorkHandoffState(activity) }
    nonisolated static let cardWidth: CGFloat = 320
    nonisolated static let cardGap: CGFloat = 12
    nonisolated static let targetWidth: CGFloat = 240
    /// The pinned Start work column: the target plus the gap before it.
    nonisolated static let pinnedColumnWidth: CGFloat = targetWidth + cardGap
    /// Whether `cards` session cards run under the pinned column in a row `width` wide.
    nonisolated static func rowOverflows(cards: Int, width: CGFloat) -> Bool {
        guard cards > 0, width > 0 else { return false }
        return CGFloat(cards) * cardWidth + CGFloat(cards - 1) * cardGap > width - pinnedColumnWidth
    }
    /// The most cards a row `width` wide holds beside the pinned column: `rowOverflows(cards:width:)` is
    /// `cards > rowCapacity(width:)`. Unmeasured (0) holds any number, so nothing casts an edge before the first layout.
    nonisolated static func rowCapacity(width: CGFloat) -> Int {
        guard width > 0 else { return .max }
        var capacity = max(0, Int(((width - pinnedColumnWidth + cardGap) / (cardWidth + cardGap)).rounded(.down)))
        while capacity > 0 && rowOverflows(cards: capacity, width: width) { capacity -= 1 }   // floating point at the edge
        while !rowOverflows(cards: capacity + 1, width: width) { capacity += 1 }
        return capacity
    }
    /// "sent 42 min ago" while running or waiting on delivery, "active 3 h ago" once the session has gone quiet.
    func ageText(now: Date = Date()) -> String {
        let sent = Date(timeIntervalSince1970: activity.receipt.createdAt)
        if [.running, .awaiting, .queued].contains(state) { return "sent " + Self.shortAge(now.timeIntervalSince(sent)) + " ago" }
        guard let active = activity.session?.updatedDate else { return "sent " + Self.shortAge(now.timeIntervalSince(sent)) + " ago" }
        let age = Self.shortAge(now.timeIntervalSince(active))
        return age == "now" ? "active now" : "active " + age + " ago"
    }

    /// The reply or session summary, for a card that is waiting on a review.
    nonisolated static func excerpt(receipt: WorkHandoffReceipt, session: WorkSession?) -> String? {
        let text = (receipt.result?.isEmpty == false ? receipt.result : session?.summary)?
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(360))
    }
    /// "idle · 1 h", "running · 4 min" for session rows.
    nonisolated static func ageLabel(status: String, updated: Date?, now: Date = Date()) -> String {
        let state = ["running", "working"].contains(status) ? "running" : status == "waiting" ? "waiting"
            : ["error", "failed"].contains(status) ? "error" : "idle"
        guard let updated else { return state }
        return state + " · " + shortAge(now.timeIntervalSince(updated))
    }
    nonisolated static func shortAge(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "now" }   // under a minute
        if s < 3_600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3_600) h" }
        return "\(s / 86_400) d"
    }
}

enum WorkBoardSessionsProjection {
    /// The handoffs behind the board: sessions working on, or waiting on you for, the domain's items (all domains when
    /// nil). An item's current activity comes first; an item edited since its handoff still shows its newest unfinished
    /// receipt (any revision), marked as an earlier version. Completed cards drop off unless still in progress.
    /// The header counts differ on purpose: they also count task flags with no session (failed, missed, agent done).
    static func cards(_ items: [WorkWorkspaceItem], receipts: [WorkHandoffReceipt] = [], sessions: [WorkSession] = [],
                      domain: String?) -> [WorkBoardSessionCard] {
        let receiptsByWork = Dictionary(grouping: receipts, by: \.workID)
        return items.compactMap { item -> WorkBoardSessionCard? in
            guard domain == nil || item.domain == domain else { return nil }
            var activity = item.activity, earlier = false
            if activity == nil, let receipt = receiptsByWork[item.sourceID]?.max(by: { $0.createdAt < $1.createdAt }) {
                activity = WorkActivity(receipt: receipt, session: WorkHandoffStore.listedSession(for: receipt, in: sessions))
                earlier = true
            }
            guard let activity, activity.inProgress || activity.needsAttention else { return nil }
            if item.completed && !activity.inProgress { return nil }
            return WorkBoardSessionCard(item: item, activity: activity, earlierRevision: earlier)
        }.sorted { left, right in
            left.state.rank == right.state.rank ? left.activity.receipt.createdAt > right.activity.receipt.createdAt
                                                : left.state.rank < right.state.rank
        }
    }
    /// 0.5.247: one card per session for tracked handoffs. A session holding several tracked tasks lists them all on
    /// its first (highest ranked) tracked card (WorkTracking.forSession), so its other tracked cards would only repeat
    /// it. Handoffs sent before 0.5.247, and a Fork that has no session of its own yet, keep their own cards.
    static func onePerSession(_ cards: [WorkBoardSessionCard]) -> [WorkBoardSessionCard] {
        var seen = Set<String>()
        return cards.filter { card in
            let receipt = card.activity.receipt
            guard receipt.progress != nil, let session = WorkProgress.workingSession(receipt) else { return true }
            return seen.insert(session).inserted
        }
    }
    static func summary(_ cards: [WorkBoardSessionCard]) -> String {
        let order: [(WorkHandoffState, String, String)] = [(.running, "running", "running"), (.waiting, "waiting for you", "waiting for you"),
            (.attention, "needs attention", "need attention"), (.replyReady, "reply ready", "replies ready"), (.sent, "sent", "sent"),
            (.awaiting, "awaiting delivery", "awaiting delivery"), (.queued, "queued", "queued")]
        let parts = order.compactMap { state, one, many -> String? in
            let n = cards.filter { $0.state == state }.count
            return n == 0 ? nil : "\(n) " + (n == 1 ? one : many)
        }
        return parts.isEmpty ? "None right now" : parts.joined(separator: " · ")
    }
}

enum WorkBoardStage: String, CaseIterable, Identifiable {
    case mentioned, planned, draft, built, qa, complete
    var id: String { rawValue }
    var title: String { self == .qa ? "QA" : rawValue.capitalized }
    var subtitle: String {
        switch self {
        case .mentioned: "Captured for consideration"
        case .planned: "Ready to work on"
        case .draft: "First pass in progress"
        case .built: "Implementation prepared"
        case .qa: "Checks and review"
        case .complete: "Task marked complete"
        }
    }
    static func stage(for task: TaskRow) -> Self {
        if task.checked { return .complete }
        let value = Self(rawValue: task.workStage) ?? .planned
        return value == .complete ? .planned : value
    }
}

enum WorkWorkspaceScope: String, CaseIterable, Identifiable {
    case all, attention, progress, completed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All work"
        case .attention: "Needs attention"
        case .progress: "In progress"
        case .completed: "Completed"
        }
    }
}

@MainActor final class WorkWorkspaceState: ObservableObject {
    @Published var scope: WorkWorkspaceScope = .all { didSet { intakeOpen = false; waitingOpen = false; startItemID = nil } }
    @Published var domain: String? { didSet { startItemID = nil } }
    @Published var query = ""
    @Published var selectedID: String? { didSet { if oldValue != selectedID { personFocus = nil } } }
    /// The person card open under a source meeting: "<recordId>|<name>". Closes when another task is selected.
    @Published var personFocus: String?
    @Published var meetingPicker = false
    @Published var reviewModelID = ""
    @Published var captureOpen = false
    @Published var captureText = ""
    @Published var captureDomain = ""
    @Published var captureBusy = false
    @Published var captureError: String?
    @Published var mutationError: String?
    @Published var mutationBusy = false
    @Published var linkTarget: TaskRow?
    @Published var previewStages: [String: String] = [:] { didSet { previewStagesEpoch &+= 1 } }
    private(set) var previewStagesEpoch = 0
    /// 0.5.254 resize pass: the board's rows, kept until their data changes. Not published: filling it never redraws.
    let boardMemo = WorkBoardMemo()
    /// Work → Intake (server 6.57.0). Its own route flag: the Intake row or toggle opens it, and choosing a view
    /// or a domain closes it (the observers above), so no opener can leave Intake covering the board.
    @Published var waitingOpen = false
    @Published var intakeOpen = false
    /// 0.5.244: the item whose Start work overlay is open (a drop on Start work, or Start work… on a card).
    @Published var startItemID: String?
    @Published var startSending = false
    /// A count click shows its list in Focus for this visit without changing the remembered layout.
    @Published var focusOverride = false
    /// A card dropped on Complete waits here for one confirm.
    @Published var pendingComplete: TaskRow?
    /// Layout for the isolated preview, which never writes the real preference.
    @Published var previewLayout: WorkLayout = .board
    /// Meeting reviews whose full text is open, and whose notes are open, by review id.
    @Published var expandedReviews: Set<String> = []
    @Published var expandedNotes: Set<String> = []

    // 0.5.259 Work search and order (board 4 of the 10/6 mock).
    /// Jev's answer for the board's search. Read through `meaning(for:)`, so an answer for an older search never shows.
    @Published private(set) var meaning: WorkSearchMeaning?
    /// Answers dropped because the search changed while they were on the way (read by the checks).
    private(set) var staleMeaningDrops = 0
    /// The search a meaning answer is on its way for: the board says "Searching by meaning…" rather than "No matches".
    @Published private(set) var meaningPending: WorkSearchKey?
    /// The helper's `work-search` (server 6.65.0). Replaced in checks.
    var searchTransport: WorkSearch.Transport = WorkSearch.helperTransport()
    /// The isolated preview never asks the server; a render harness may give it a fake.
    var previewSearchTransport: WorkSearch.Transport?
    /// Jev is asked after this pause in typing.
    var searchPause: Duration = WorkSearch.pause
    /// The Best matches row ↓ ↑ have walked to (Return opens it).
    @Published var bandIndex = 0
    /// ⌘F bumps it; the search field takes the focus.
    @Published var searchFocusRequest = 0
    /// Order per board. The preview keeps its choices here only; the app also remembers them in `orderStore`.
    @Published private(set) var orders: [String: WorkBoardOrder] = [:]
    var orderStore: WorkBoardOrderStore = .standard

    var currentSearchKey: WorkSearchKey { WorkSearchKey(query: WorkSearch.normalized(query), scope: scope, domain: domain) }
    func meaning(for key: WorkSearchKey) -> WorkSearchMeaning? { meaning?.key == key ? meaning : nil }

    /// Asks Jev for the card the search means, after a pause in typing. Typing never waits on it: the board shows the
    /// title and word matches at once, and this answer joins them when it arrives, if the search is still the same.
    /// A passing failure keeps its explanation visible but never settles the search, and neither a kept cap
    /// nor breaker answer stops the next search asking again: only an answer that ran, or one that cannot change by asking
    /// again (WorkSearch.settled), ends the asking for its search. While an answer is on its way the board says so.
    func searchMeaning(_ request: WorkSearchRequest, isolated: Bool) async {
        guard request.wantsMeaning, let transport = isolated ? previewSearchTransport : searchTransport else { return }
        if let kept = meaning, kept.key == request.key, WorkSearch.settled(kept) { return }
        meaningPending = request.key
        defer { if meaningPending == request.key { meaningPending = nil } }
        do { try await Task.sleep(for: searchPause) } catch { return }
        let answer = await WorkSearch.ask(request, transport: transport)
        if !answer.available {
            // Every degrade leaves a trace (never the query's words).
            NSLog("COS Work search: meaning search unavailable (%@), %ld-character search", (answer.reason ?? "unknown") as NSString, request.length)
        }
        guard !Task.isCancelled, request.key == currentSearchKey else { staleMeaningDrops += 1; return }
        meaning = WorkSearch.keeps(answer) ? answer : nil
    }

    /// Escape on the board clears an active search before it navigates anywhere. False when there is nothing to clear
    /// or the board is not what is showing (a card, a meeting, Start work, Intake or Waiting on is open).
    func escapeClearsSearch() -> Bool {
        guard !query.isEmpty, selectedID == nil, !meetingPicker, startItemID == nil, !intakeOpen, !waitingOpen else { return false }
        query = ""; bandIndex = 0
        return true
    }

    func order(domain: String?, scope: WorkWorkspaceScope, isolated: Bool) -> WorkBoardOrder {
        let key = WorkBoardOrder.key(domain: domain, scope: scope)
        if let chosen = orders[key] { return chosen }
        return isolated ? .board : (orderStore.read(key).flatMap(WorkBoardOrder.init(rawValue:)) ?? .board)
    }
    func setOrder(_ order: WorkBoardOrder, domain: String?, scope: WorkWorkspaceScope, isolated: Bool) {
        let key = WorkBoardOrder.key(domain: domain, scope: scope)
        orders[key] = order
        if !isolated { orderStore.write(key, order.rawValue) }
    }

    /// 0.5.254 resize pass: the board's rows for these stores, rebuilt only when one of their sources changed
    /// (WorkBoardDataKey). The Work view reads every row through here.
    func board(model: ControllerModel, handoffStore: WorkHandoffStore, reviewStore: WorkReviewStore, now: Date = Date()) -> WorkBoardMemo {
        let key = WorkBoardDataKey(stores: [ObjectIdentifier(model), ObjectIdentifier(handoffStore), ObjectIdentifier(reviewStore)],
                                   isolated: handoffStore.isolated, tasks: model.workTasksEpoch, previewTasks: handoffStore.previewTasksEpoch,
                                   previewStages: previewStagesEpoch, reviews: reviewStore.reviewsEpoch, receipts: handoffStore.receiptsEpoch,
                                   sessions: handoffStore.isolated ? handoffStore.sessionsEpoch : handoffStore.activitySessionsEpoch,
                                   fresh: handoffStore.isolated || handoffStore.activityFresh(now: now))
        return boardMemo.refreshed(key) {
            WorkWorkspaceProjection.items(tasks: handoffStore.isolated ? WorkWorkspaceProjection.previewRows(handoffStore.previewTasks, stages: previewStages) : model.workTasks,
                                          reviews: reviewStore.reviews, receipts: handoffStore.receipts, sessions: handoffStore.observedSessions(now: now), titleOverrides: reviewStore.titleOverrides)
        }
    }

    /// Explicit transition after admission also handles a reused review ID, where
    /// SwiftUI onChange would not fire. Failure leaves the chosen intake visible.
    func requestReview(meeting: LibraryMeeting, modelID: String, store: WorkReviewStore) async -> WorkReviewRecord? {
        await store.review(meeting: meeting, modelID: modelID)
        guard store.selectedMeeting == nil, store.error == nil,
              let id = store.selectedReviewID, let review = store.reviews.first(where: { $0.id == id }) else { return nil }
        selectedID = "meeting-review:" + review.id
        meetingPicker = false
        return review
    }

}

struct WorkWorkspaceItem: Identifiable {
    let id: String
    let title: String
    let domain: String
    let searchText: String
    let subtitle: String
    let task: TaskRow?
    let review: WorkReviewRecord?
    let needsAttention: Bool
    let inProgress: Bool
    let completed: Bool
    var activity: WorkActivity? = nil
    /// 0.5.247: the newest tracked handoff for this work, found by work id (WorkTracking).
    var tracking: WorkTracking? = nil
    var sourceID: String { review?.source.id ?? id }
}

/// 0.5.254 resize pass: counts read by Tests/WorkBoardResizePerf.swift (how often the board's projection is built, the
/// Work view's body runs, and the board itself is evaluated, which a GeometryReader around the body would redo on every
/// step without running the body). Plain counters; nothing in the app reads them.
enum WorkBoardMetrics {
    nonisolated(unsafe) static var projections = 0
    nonisolated(unsafe) static var bodies = 0
    nonisolated(unsafe) static var boards = 0
    /// 0.5.259: how often the board's card dates were worked out (once per data change, never per redraw).
    nonisolated(unsafe) static var dates = 0
    nonisolated(unsafe) static var activityBodies = 0
    static func countActivityBody() { activityBodies += 1 }
    static func countBody() { bodies += 1 }
    static func countBoard() { boards += 1 }
}

/// 0.5.254 resize pass: what the board's rows are built from. Each count is an epoch its source bumps on every change
/// (ControllerModel.workTasksEpoch; WorkHandoffStore's receipts, sessions, activity sessions and preview tasks;
/// WorkReviewStore.reviewsEpoch; WorkWorkspaceState.previewStagesEpoch). A window resize changes none of them.
struct WorkBoardDataKey: Equatable {
    var stores: [ObjectIdentifier] = []
    var isolated = false
    var tasks = 0, previewTasks = 0, previewStages = 0, reviews = 0, receipts = 0, sessions = 0
    /// observedSessions() drops the live sessions once the last check is 45 seconds old.
    var fresh = false
}

/// 0.5.254 resize pass: the board's rows and what the board derives from them, built once per data change and once
/// per filter, never once per column, per lookup or per resize step. Every reader goes through `refreshed(_:build:)`,
/// so a changed key always rebuilds before anything is read.
@MainActor final class WorkBoardMemo {
    private struct Filter: Equatable { var scope: WorkWorkspaceScope; var domain: String?; var query: String; var files = 0 }
    private var key: WorkBoardDataKey?
    private(set) var items: [WorkWorkspaceItem] = []
    private var bySourceID: [String: WorkWorkspaceItem] = [:]
    private var byID: [String: WorkWorkspaceItem] = [:]
    private var filter: Filter?
    private var filtered: [WorkWorkspaceItem] = []
    private var columns: [WorkBoardStage: [WorkWorkspaceItem]] = [:]
    private var cardsDomain: String??
    private var cards: [WorkBoardSessionCard] = []
    /// 0.5.259: the board's search, kept until the search, Jev's answer, the rows or the card files change.
    private struct SearchKey: Equatable { var filter: Filter; var meaning: WorkSearchMeaning?; var files: Int }
    private var searchKey: SearchKey?
    private var searchResult = WorkSearchResult()
    /// Each card's words, made once per data change (and again when card files change).
    private var searchIndex: [String: WorkSearchFields] = [:]
    private var searchIndexFiles: Int?
    /// 0.5.259 (QA S-W5): each card's dates, kept until the rows, the card files or the stage-move journal change.
    private struct DatesKey: Equatable { var files: Int; var moves: Int }
    private var datesKey: DatesKey?
    private var dates: [String: WorkCardDates] = [:]

    @discardableResult func refreshed(_ key: WorkBoardDataKey, build: () -> [WorkWorkspaceItem]) -> WorkBoardMemo {
        guard key != self.key else { return self }
        items = build()
        self.key = key
        bySourceID = [:]; byID = [:]
        for item in items {
            if bySourceID[item.sourceID] == nil { bySourceID[item.sourceID] = item }
            if byID[item.id] == nil { byID[item.id] = item }
        }
        filter = nil; cardsDomain = nil
        searchKey = nil; searchIndex = [:]; searchIndexFiles = nil; datesKey = nil
        return self
    }

    /// 0.5.259: what a search finds on the board (`scope`, `domain`): the cards it keeps, the Best matches, the counts,
    /// and how many other domains' cards match. Built once per search, answer and data, never per column or redraw.
    func search(scope: WorkWorkspaceScope, domain: String?, query: String, meaning: WorkSearchMeaning?, filesEpoch: Int,
                fileNames: (String) -> [String]) -> WorkSearchResult {
        let next = SearchKey(filter: Filter(scope: scope, domain: domain, query: query), meaning: meaning, files: filesEpoch)
        if next == searchKey { return searchResult }
        if searchIndexFiles != filesEpoch { searchIndex = [:]; searchIndexFiles = filesEpoch }
        let onBoard = WorkWorkspaceProjection.filter(items, scope: scope, domain: domain, query: "").filter { $0.task != nil }
        let elsewhere = domain == nil ? [] : WorkWorkspaceProjection.filter(items, scope: scope, domain: nil, query: "")
            .filter { $0.task != nil && $0.domain != domain }
        searchResult = WorkSearch.result(query: query, board: onBoard, elsewhere: elsewhere, meaning: meaning) { item in
            if let ready = searchIndex[item.id] { return ready }
            let made = WorkSearch.fields(item, files: fileNames(item.sourceID))
            searchIndex[item.id] = made
            return made
        }
        searchKey = next
        return searchResult
    }
    /// The first row for a work id, as `items.first { $0.sourceID == id }` would find it.
    func item(sourceID: String) -> WorkWorkspaceItem? { bySourceID[sourceID] }
    func item(id: String?) -> WorkWorkspaceItem? { id.flatMap { byID[$0] } }
    func visible(scope: WorkWorkspaceScope, domain: String?, query: String, filesEpoch: Int = 0,
                 fileNames: (String) -> [String] = { _ in [] }) -> [WorkWorkspaceItem] {
        let next = Filter(scope: scope, domain: domain, query: query, files: filesEpoch)
        if next != filter {
            filtered = WorkWorkspaceProjection.filter(items, scope: scope, domain: domain, query: query, fileNames: fileNames)
            columns = Dictionary(grouping: filtered.filter { $0.task != nil }) { WorkBoardStage.stage(for: $0.task!) }
            filter = next
        }
        return filtered
    }
    /// The board's card dates (Order by date), worked out once per data change, never per redraw.
    func cardDates(filesEpoch: Int, movesEpoch: Int, build: ([WorkWorkspaceItem]) -> [String: WorkCardDates]) -> [String: WorkCardDates] {
        let next = DatesKey(files: filesEpoch, moves: movesEpoch)
        if next != datesKey {
            dates = build(items); datesKey = next
            WorkBoardMetrics.dates += 1
        }
        return dates
    }
    /// A column's cards, from the last `visible` (the board reads `visible` first).
    func column(_ stage: WorkBoardStage) -> [WorkWorkspaceItem] { columns[stage] ?? [] }
    func sessionCards(domain: String?, build: ([WorkWorkspaceItem]) -> [WorkBoardSessionCard]) -> [WorkBoardSessionCard] {
        if cardsDomain != .some(domain) { cards = build(items); cardsDomain = .some(domain) }
        return cards
    }
}

enum WorkWorkspaceProjection {
    static func previewRows(_ samples: [Control2PreviewTask], stages: [String: String] = [:]) -> [TaskRow] {
        samples.compactMap { row in TaskRow(.object([
            "id": .string(row.id), "domain": .string(row.domain), "title": .string(row.title), "text": .string(row.title),
            "checked": .bool(row.completed), "source": .string(row.source), "doneWhen": .string(row.finishLine),
            "stage": .string(row.stage.lowercased()),
            "workStage": .string(row.completed ? "complete" : stages[row.id] ?? ["planning": "planned", "review": "qa", "active": "draft"][row.stage.lowercased()] ?? row.stage.lowercased()),
            "meetingRefs": .array([.object(["recordId": .string("sample-meeting"), "domain": .string("Website"),
                "month": .string("2026-09"), "filename": .string("2026-09-27_Website_Review.md"), "title": .string("Website launch review · sample")])])
        ])) }
    }
    @MainActor static func previewReviewStore() -> WorkReviewStore {
        let store = WorkReviewStore(transport: { _, _ in
            throw HelperClientError.invalidResponse("Local sample review: live transport is disabled.")
        })
        if let review = WorkReviewRecord(.object([
            "id": .string("sample-review"), "status": .string("ready"), "canonicalMeetingId": .string("sample-meeting"),
            "markdown": .string("## Website follow-up\nPrepare a clearer homepage call to action. Check the mobile layout. Bring the changes back for review before publishing."),
            "source": .object(["title": .string("Website launch review · sample"), "domain": .string("Website"),
                "revision": .string("sample-1"), "descriptor": .object(["recordId": .string("sample-meeting"), "domain": .string("Website"), "month": .string("2026-09"), "filename": .string("2026-09-27_Website_Review.md")])])
        ])) { store.reviews = [review] }
        return store
    }

    static func items(tasks: [TaskRow], reviews: [WorkReviewRecord], receipts: [WorkHandoffReceipt], sessions: [WorkSession] = [], titleOverrides: [String: String] = [:]) -> [WorkWorkspaceItem] {
        WorkBoardMetrics.projections += 1
        // One pass over the journal: matching every task against every receipt was most of a rebuild's cost.
        let receiptsByWork = Dictionary(grouping: receipts, by: \.workID)
        let taskItems = tasks.map { task in
            let source = WorkSource.taskSnapshot(task)
            let mine = receiptsByWork[source.id] ?? []
            let activity = WorkActivityProjection.latest(workID: source.id, revision: source.revision, receipts: mine, sessions: sessions)
            let running = activity?.inProgress == true
            let attention = activity?.needsAttention == true && activity?.sessionRunning != true
            let tracking = WorkTracking.latest(workID: source.id, receipts: mine)
            let label = task.checked ? "Completed task" : task.agentState == "done" ? "Agent finished · task still open" : WorkBoardStage.stage(for: task).title
            return WorkWorkspaceItem(id: source.id, title: task.text.isEmpty ? task.title : task.text, domain: task.domain,
                searchText: source.context, subtitle: label, task: task, review: nil,
                needsAttention: !task.checked && (task.failed == true || task.missed == true || attention || task.agentState == "done" || task.stage == "review"
                                                  || tracking?.asksForYou == true),
                inProgress: task.agentState == "running" || running, completed: task.checked, activity: activity, tracking: tracking)
        }
        let meetingItems = reviews.map { review in
            let title = titleOverrides[review.id] ?? review.title
            let mine = receiptsByWork[review.source.id] ?? []
            let activity = WorkActivityProjection.latest(workID: review.source.id, revision: review.source.revision, receipts: mine, sessions: sessions)
            let tracking = WorkTracking.latest(workID: review.source.id, receipts: mine)
            return WorkWorkspaceItem(id: "meeting-review:" + review.id, title: title, domain: review.domain,
                searchText: title + " " + review.markdown + " " + review.source.context,
                subtitle: "Meeting review · " + review.status.replacingOccurrences(of: "_", with: " "),
                task: nil, review: review,
                needsAttention: (activity.map { $0.needsAttention && !$0.sessionRunning } ?? ["completed", "ready", "failed", "unknown", "needs_review"].contains(review.status))
                    || tracking?.asksForYou == true,
                inProgress: activity?.inProgress == true || ["preparing", "starting", "queued", "running", "accepted"].contains(review.status),
                completed: false, activity: activity, tracking: tracking)
        }
        return (taskItems + meetingItems).enumerated().sorted { left, right in
            func rank(_ item: WorkWorkspaceItem) -> Int {
                if item.completed { return 3 }
                if item.needsAttention { return 0 }
                if item.inProgress { return 1 }
                return 2
            }
            let l = rank(left.element), r = rank(right.element)
            if l != r { return l < r }
            func priority(_ item: WorkWorkspaceItem) -> Int {
                if item.task?.workStage == "qa" { return 0 }
                if item.task?.priority == "urgent" { return 1 }
                if let due = item.task?.dueDate, !due.isEmpty {
                    let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
                    if let day = format.date(from: due), day.timeIntervalSinceNow < 14 * 86400 { return 1 }
                }
                return 2
            }
            let lp = priority(left.element), rp = priority(right.element)
            if lp != rp { return lp < rp }
            let ld = left.element.task?.createdAt ?? "", rd = right.element.task?.createdAt ?? ""
            if ld != rd && !ld.isEmpty && !rd.isEmpty { return ld > rd }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Whether a stage change may be written: the preview always; live only on a writable board, outside another
    /// write, for a task with a known revision and readable metadata. Menus and drops share it.
    static func canChangeStage(_ task: TaskRow, isolated: Bool, writable: Bool, busy: Bool) -> Bool {
        !busy && (isolated || (writable && !task.workRevision.isEmpty && task.workMetadataError == nil))
    }
    /// A dragged string is untrusted (any app can drop text): it must name an open board task.
    static func startable(id: String, items: [WorkWorkspaceItem]) -> WorkWorkspaceItem? {
        guard let item = items.first(where: { $0.id == id }), item.task != nil, !item.completed else { return nil }
        return item
    }
    /// The task a drop onto `stage` would move, or nil when the id is unknown or the card is already there.
    static func stageDrop(id: String, items: [WorkWorkspaceItem], to stage: WorkBoardStage) -> TaskRow? {
        guard let task = items.first(where: { $0.id == id })?.task, WorkBoardStage.stage(for: task) != stage else { return nil }
        return task
    }

    /// A row identifies one review revision; its source identifies the work across revisions.
    static func rowID(forSourceID id: String, currentID: String?, items: [WorkWorkspaceItem]) -> String? {
        if let currentID, items.contains(where: { $0.id == currentID && $0.sourceID == id }) { return currentID }
        let matches = items.filter { $0.sourceID == id }
        let ordered = matches.sorted { left, right in
            let leftOld = ["superseded", "stale"].contains(left.review?.status ?? "")
            let rightOld = ["superseded", "stale"].contains(right.review?.status ?? "")
            if leftOld != rightOld { return !leftOld }
            return (left.review?.createdAt ?? "") > (right.review?.createdAt ?? "")
        }
        return ordered.first?.id
    }

    /// 0.5.259 (QA C7): a query matches by the board's own rule (WorkSearch: every word in the title, or any word in the
    /// task text, its source, its meetings' or files' names), so Focus and the board find the same cards. No Jev here.
    static func filter(_ items: [WorkWorkspaceItem], scope: WorkWorkspaceScope, domain: String?, query: String,
                       fileNames: (String) -> [String] = { _ in [] }) -> [WorkWorkspaceItem] {
        let words = WorkSearch.words(query)
        return items.filter { item in
            guard domain == nil || item.domain == domain else { return false }
            if !words.isEmpty && WorkSearch.fields(item, files: fileNames(item.sourceID)).match(words) == nil { return false }
            switch scope {
            case .all: return true
            case .attention: return item.needsAttention
            case .progress: return item.inProgress
            case .completed: return item.completed
            }
        }
    }
}

// MARK: - Work search and order (0.5.259, board 4 of the 10/6 mock)

/// How a card matched a board search. A card counts once, by its strongest local reason: every query word in its title,
/// else any query word anywhere on the card. Jev's meaning counts only for a card the words did not find.
enum WorkSearchKind: String, Sendable { case title, words, meaning }

struct WorkSearchHit: Equatable, Sendable {
    var kind: WorkSearchKind
    /// The query words found (all of them for a title match). None for a meaning match.
    var words: [String]
    /// Jev's probability for this card, when its answer named the card.
    var p: Double? = nil
}

/// The search an answer belongs to: the query (normalized) on one board.
struct WorkSearchKey: Hashable, Sendable {
    var query: String
    var scope: WorkWorkspaceScope
    var domain: String?
}

/// Jev's answer for one search (server 6.65.0 `POST /api/work/search`, through the helper's `work-search`).
struct WorkSearchMeaning: Equatable, Sendable {
    var key: WorkSearchKey
    var available: Bool
    /// Why it could not run (the server's reason, `server_too_old` for a server without the route, `unreachable`).
    var reason: String?
    /// Probability by board item id.
    var scores: [String: Double] = [:]
}

/// What the board asks: the view (scope, and the domain on a domain board) or, for a list only Control computes (Needs
/// attention, In progress), the cards' own ids. Control sends only the query and the view; the server reads the cards and
/// sends their text on to Jev (TypeSafe) with URLs, emails and secrets removed.
struct WorkSearchRequest: Sendable {
    var key: WorkSearchKey
    var body: [String: JSONValue]
    /// The query's length in code points, as the server counts it (for the log; never the words themselves).
    var length = 0
    /// A server row id to the board items it names.
    var lookup: [String: [String]]
    /// At least three characters and a word that is not a stopword, and a card list the server can hold.
    var wantsMeaning: Bool
}

/// One card's words for a search: its title, and everything else on it (task text, source label, meeting names, file names).
struct WorkSearchFields: Sendable {
    let title: [String]
    let other: [String]
    init(title: String, other: [String]) {
        self.title = WorkSearch.tokens(title)
        self.other = other.flatMap { WorkSearch.tokens($0) }
    }
    func match(_ words: [String]) -> WorkSearchHit? {
        guard !words.isEmpty else { return nil }
        if words.allSatisfy({ WorkSearch.found($0, in: title) }) { return WorkSearchHit(kind: .title, words: words) }
        let hit = words.filter { WorkSearch.found($0, in: title) || WorkSearch.found($0, in: other) }
        return hit.isEmpty ? nil : WorkSearchHit(kind: .words, words: hit)
    }
}

/// What a search found on a board.
struct WorkSearchResult: Equatable, Sendable {
    /// The query has a word to look for. Off: the board shows every card, as before.
    var active = false
    /// The matches the result line counts and the cards that get the gold border, by item id.
    var hits: [String: WorkSearchHit] = [:]
    /// The cards the columns keep: exactly the matches the result line counts (one threshold, 0.15 for meaning).
    var shown: Set<String> = []
    /// Best matches, at most three item ids.
    var band: [String] = []
    var titleCount = 0, wordsCount = 0, meaningCount = 0
    /// Other domains with matching cards, most first (domain boards only).
    var elsewhere: [WorkSearchElsewhere] = []
    /// One muted line when meaning search could not run and that matters.
    var note: String?

    /// "4 matches"
    var countText: String { hits.count == 1 ? "1 match" : "\(hits.count) matches" }
    /// The result line's lead: the count; with nothing found, that Jev's answer is on its way, else that nothing matched.
    func headline(pending: Bool) -> String { hits.isEmpty ? (pending ? "Searching by meaning\u{2026}" : "No matches on this board") : countText }
    /// "1 by title · 3 by meaning": the kinds that found something.
    var kindsText: String {
        [(titleCount, "by title"), (wordsCount, "by words"), (meaningCount, "by meaning")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}

struct WorkSearchElsewhere: Equatable, Sendable {
    var domain: String
    var count: Int
}

enum WorkSearch {
    typealias Transport = @Sendable ([String], Data?) async throws -> HelperResponse
    /// Words a search ignores. Not "it": IT Retail is a brand.
    nonisolated static let stopwords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "into", "is",
        "me", "my", "of", "on", "or", "our", "so", "that", "the", "their", "this", "to", "up", "was", "we", "with", "you", "your"]
    nonisolated static let bandLimit = 3
    /// Jev's answer counts as a meaning match from here: in Best matches, the counts and the columns alike. There is no
    /// lower tier (10/6 review): a card under it is not on the board while searching, so every count agrees.
    nonisolated static let bandThreshold = 0.15
    /// Jev is asked from this many characters, after `pause`.
    nonisolated static let meaningMinimum = 3
    nonisolated static let pause: Duration = .milliseconds(400)
    /// A Jev Choice holds 254 cards plus none.
    nonisolated static let maxCandidates = 254
    nonisolated static let maxQuery = 200

    nonisolated static func helperTransport() -> Transport {
        let helper = HelperClient()
        // Longer than the helper's own wait (25 s), which is longer than the server's wait for Jev (20 s).
        return { args, data in try await helper.run(args, timeout: 30, stdinData: data) }
    }

    /// Case, width and accents do not change what was asked.
    nonisolated static func fold(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    nonisolated static func normalized(_ query: String) -> String {
        fold(query).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// The runs of letters and digits in `text`, where they sit.
    nonisolated static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let letter = text[index].unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            if letter { if start == nil { start = index } }
            else if let open = start { ranges.append(open..<index); start = nil }
            index = text.index(after: index)
        }
        if let open = start { ranges.append(open..<text.endIndex) }
        return ranges
    }
    nonisolated static func tokens(_ text: String) -> [String] { wordRanges(text).map { fold(String(text[$0])) } }
    /// The words a query looks for: no stopwords, no single letters, each once.
    nonisolated static func words(_ query: String) -> [String] {
        var seen = Set<String>()
        return tokens(query).filter { $0.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }
    /// A query word is found where a word on the card starts with it: "launch" finds "launches", "ads" never finds "leads".
    nonisolated static func found(_ word: String, in tokens: [String]) -> Bool { tokens.contains { $0.hasPrefix(word) } }

    /// A card's words: the title, then the task text, its source, its meetings' names and its files' names.
    static func fields(_ item: WorkWorkspaceItem, files: [String]) -> WorkSearchFields {
        guard let task = item.task else { return WorkSearchFields(title: item.title, other: [item.review?.markdown ?? ""] + files) }
        return WorkSearchFields(title: WorkSource.plainTitle(item.title),
                                other: [task.text, task.title, task.source] + task.meetingRefs.map(\.title) + files)
    }

    /// The request for the board's search. `items` are the board's cards in board order.
    @MainActor static func request(key: WorkSearchKey, query: String, items: [WorkWorkspaceItem]) -> WorkSearchRequest {
        // Counted in code points, as the server counts (an emoji is one, never two).
        let whole = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(String.UnicodeScalarView(whole.unicodeScalars.prefix(maxQuery)))
        var body: [String: JSONValue] = ["query": .string(trimmed)]
        var lookup: [String: [String]] = [:]
        var ids: [String] = []
        for item in items {
            guard let task = item.task, task.id.range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil else { continue }
            if lookup[task.id] == nil { ids.append(task.id) }
            lookup[task.id, default: []].append(item.id)
        }
        var fits = true
        switch key.scope {
        case .attention, .progress:
            body["ids"] = .array(ids.map(JSONValue.string))
            fits = !ids.isEmpty && ids.count <= maxCandidates
        case .all, .completed:
            body["scope"] = .string(key.scope.rawValue)
            if let domain = key.domain { body["domain"] = .string(domain) }
        }
        return WorkSearchRequest(key: key, body: body, length: trimmed.unicodeScalars.count, lookup: lookup,
                                 wantsMeaning: fits && trimmed.unicodeScalars.count >= meaningMinimum && !words(trimmed).isEmpty)
    }

    /// Asks the helper. Never throws: a failure is an answer that says why, and the words keep working.
    nonisolated static func ask(_ request: WorkSearchRequest, transport: Transport) async -> WorkSearchMeaning {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let response = try await transport(["work-search"], try encoder.encode(JSONValue.object(request.body)))
            return parse(response, request: request)
        } catch {
            return WorkSearchMeaning(key: request.key, available: false, reason: "unreachable")
        }
    }
    nonisolated static func parse(_ response: HelperResponse, request: WorkSearchRequest) -> WorkSearchMeaning {
        guard response.ok else { return WorkSearchMeaning(key: request.key, available: false, reason: "unreachable") }
        guard response.details["available"]?.bool == true else {
            return WorkSearchMeaning(key: request.key, available: false, reason: response.details["reason"]?.string ?? "jev_unavailable")
        }
        var scores: [String: Double] = [:]
        for row in response.details["results"]?.array ?? [] {
            guard let id = row.object?["id"]?.string, let p = row.object?["p"]?.double, p.isFinite, p >= 0, p <= 1 else { continue }
            for item in request.lookup[id] ?? [] { scores[item] = max(scores[item] ?? 0, p) }
        }
        return WorkSearchMeaning(key: request.key, available: true, reason: nil, scores: scores)
    }

    /// The one line said when meaning search could not run, only where it matters: the breaker (an hour), the day's budget,
    /// too many cards, no TypeSafe key or one TypeSafe refused, a request Jev refused, and a server without the route.
    /// A temporary or unknown failure explains the word-only fallback. A switch deliberately turned off stays quiet.
    nonisolated static func note(_ reason: String?) -> String? {
        switch reason {
        case "jev_breaker_open": "Meaning search is paused for an hour"
        case "jev_cap_reached": "Meaning search has used today\u{2019}s budget"
        case "too_many_candidates": "Meaning search covers up to \(maxCandidates) cards. Pick a domain."
        case "jev_not_configured": "Meaning search needs a TypeSafe key in Settings"
        case "jev_key_rejected": "TypeSafe did not accept the saved key. Check it in Settings."
        case "jev_request_rejected": "Meaning search could not take this search"
        case "server_too_old": "Meaning search needs COS server 6.65"
        case "unreachable": "Could not reach COS server. Showing word matches."
        case "jev_unavailable": "Meaning search is temporarily unavailable. Showing word matches."
        case "search_off", nil: nil
        default: "Meaning search could not run. Showing word matches."
        }
    }
    /// Reasons that cannot change by asking again for the same search (a refused request is refused again). A key that
    /// TypeSafe refused is asked again, so a key fixed in Settings works at once.
    nonisolated static let definitiveReasons: Set<String> = ["search_off", "jev_not_configured", "server_too_old", "too_many_candidates", "jev_request_rejected"]
    /// An answer that ends the asking for its search: it ran, or its reason is definitive.
    nonisolated static func settled(_ meaning: WorkSearchMeaning) -> Bool { meaning.available || definitiveReasons.contains(meaning.reason ?? "") }
    /// An answer worth keeping at all: settled, or one that has a line to say (the cap or the breaker, asked again next
    /// time). Failure explanations remain visible without suppressing the next request.
    nonisolated static func keeps(_ meaning: WorkSearchMeaning) -> Bool { settled(meaning) || note(meaning.reason) != nil }

    /// Why a card is in Best matches.
    nonisolated static func why(_ hit: WorkSearchHit) -> String {
        switch hit.kind {
        case .title: "Title"
        case .words: "Words: " + hit.words.prefix(2).map { "\u{201C}" + $0 + "\u{201D}" }.joined(separator: ", ")
        case .meaning: "Similar meaning"
        }
    }

    /// Best matches: cards Jev rates at least 0.15 first (most likely first), then title matches, then word matches
    /// (most words first); board order breaks ties. At most three.
    nonisolated static func band(order: [String], hits: [String: WorkSearchHit]) -> [String] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func group(_ hit: WorkSearchHit) -> Int {
            if let p = hit.p, p >= bandThreshold { return 0 }
            return hit.kind == .title ? 1 : hit.kind == .words ? 2 : 3
        }
        return hits.sorted { left, right in
            let l = group(left.value), r = group(right.value)
            if l != r { return l < r }
            if l == 0, left.value.p != right.value.p { return (left.value.p ?? 0) > (right.value.p ?? 0) }
            if l == 2, left.value.words.count != right.value.words.count { return left.value.words.count > right.value.words.count }
            return (position[left.key] ?? .max, left.key) < (position[right.key] ?? .max, right.key)
        }.prefix(bandLimit).map(\.key)
    }

    /// The search over `board` (the board's cards, in board order), with Jev's `meaning` when it is for this search,
    /// and the local matches among `elsewhere` (other domains' cards) for "N more in".
    @MainActor static func result(query: String, board: [WorkWorkspaceItem], elsewhere: [WorkWorkspaceItem], meaning: WorkSearchMeaning?,
                       fields: (WorkWorkspaceItem) -> WorkSearchFields) -> WorkSearchResult {
        let words = words(query)
        guard !words.isEmpty else { return WorkSearchResult() }
        var result = WorkSearchResult(active: true)
        for item in board { if let hit = fields(item).match(words) { result.hits[item.id] = hit } }
        if let meaning {
            if meaning.available {
                let onBoard = Set(board.map(\.id))
                for (id, p) in meaning.scores where onBoard.contains(id) {
                    if var hit = result.hits[id] { hit.p = p; result.hits[id] = hit }
                    else if p >= bandThreshold { result.hits[id] = WorkSearchHit(kind: .meaning, words: [], p: p) }
                }
            } else { result.note = note(meaning.reason) }
        }
        // The columns show exactly what the result line counts.
        result.shown = Set(result.hits.keys)
        result.titleCount = result.hits.values.filter { $0.kind == .title }.count
        result.wordsCount = result.hits.values.filter { $0.kind == .words }.count
        result.meaningCount = result.hits.values.filter { $0.kind == .meaning }.count
        result.band = band(order: board.map(\.id), hits: result.hits)
        var counts: [String: Int] = [:]
        for item in elsewhere where fields(item).match(words) != nil { counts[item.domain, default: 0] += 1 }
        result.elsewhere = counts.map { WorkSearchElsewhere(domain: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.domain < $1.domain : $0.count > $1.count }
        return result
    }

    /// What an empty column says. Nothing is claimed while Jev's answer is on its way; on All work the meaning search
    /// covers open cards only (the server's rule), so the Complete column says only that the words found nothing.
    nonisolated static func emptyColumn(_ stage: WorkBoardStage, key: WorkSearchKey, active: Bool, pending: Bool) -> String {
        guard active else { return "No tasks here" }
        if pending { return "Searching\u{2026}" }
        return meaningCovers(stage, key: key) ? "No matches here" : "No word matches here"
    }
    /// Whether Jev's search covers a column: on All work it covers open cards, so never Complete.
    nonisolated static func meaningCovers(_ stage: WorkBoardStage, key: WorkSearchKey) -> Bool {
        !(key.scope == .all && key.domain == nil && stage == .complete)
    }

    /// What a list of cards keeps while searching (every card when not): the board line and each column use this one rule,
    /// so "N matches", "N of M tasks" and the columns' "n of m" always agree.
    nonisolated static func kept(_ cards: [WorkWorkspaceItem], _ result: WorkSearchResult) -> [WorkWorkspaceItem] {
        result.active ? cards.filter { result.shown.contains($0.id) } : cards
    }

    /// A count while searching: "2 of 5" (what the search kept of all there is); otherwise all there is.
    nonisolated static func countLabel(kept: Int, of all: Int, active: Bool) -> String { active ? "\(kept) of \(all)" : "\(all)" }

    /// "2 more in Personal", or "5 more in other domains" when several have matches. `elsewhere` carries display names.
    nonisolated static func elsewhereText(_ elsewhere: [WorkSearchElsewhere]) -> String? {
        guard let first = elsewhere.first else { return nil }
        let total = elsewhere.reduce(0) { $0 + $1.count }
        return elsewhere.count == 1 ? "\(total) more in " + first.domain : "\(total) more in other domains"
    }

    /// The title with the start of each word that matched underlined in gold.
    @MainActor static func underlined(_ title: AttributedString, words: [String]) -> AttributedString {
        guard !words.isEmpty else { return title }
        var out = title
        let plain = String(title.characters)
        for range in wordRanges(plain) {
            let token = fold(String(plain[range]))
            guard let word = words.first(where: { token.hasPrefix($0) }) else { continue }
            let offset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = min(word.count, plain.distance(from: range.lowerBound, to: range.upperBound))
            let start = out.characters.index(out.startIndex, offsetBy: offset)
            let end = out.characters.index(start, offsetBy: length)
            out[start..<end].underlineStyle = Text.LineStyle(pattern: .solid, color: COSPalette.gold)
        }
        return out
    }

    /// The keys a focused search answers.
    enum Key: Sendable { case down, up, open, clear }
    enum KeyAction: Equatable, Sendable { case highlight(Int), open(Int), clear, pass }
    /// ↓ ↑ walk Best matches (stopping at the ends), Return opens the row walked to (the first by default), Escape
    /// clears a search. With nothing to act on, the key goes on to the field and the window.
    nonisolated static func key(_ key: Key, query: String, highlighted: Int, bandCount: Int) -> KeyAction {
        switch key {
        case .clear: return query.isEmpty ? .pass : .clear
        case .down: return bandCount == 0 ? .pass : .highlight(min(max(highlighted, 0) + 1, bandCount - 1))
        case .up: return bandCount == 0 ? .pass : .highlight(max(min(highlighted, bandCount - 1) - 1, 0))
        case .open: return bandCount == 0 ? .pass : .open(min(max(highlighted, 0), bandCount - 1))
        }
    }
}

/// 0.5.259: how each column is ordered. "Order", not "Sort": the rail's "Sort · N new" already means triage.
enum WorkBoardOrder: String, CaseIterable, Identifiable, Sendable {
    case board, recent, newest, oldest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .board: "Board order"
        case .recent: "Recent activity"
        case .newest: "Newest"
        case .oldest: "Oldest"
        }
    }
    /// What each choice orders by. Newest and Oldest never claim a creation day: a card's date is its meeting's or its
    /// source's, else the day it first appeared in the task file.
    var help: String {
        switch self {
        case .board: "As you arranged each column"
        case .recent: "Last stage move, session, file or edit. Edits made outside Control show up when the task file is next committed. Cards with no date go last."
        case .newest, .oldest: "By the card\u{2019}s date: its meeting or source, else when it first appeared. Cards with no date go last."
        }
    }
    /// The remembered choice for one board.
    nonisolated static func key(domain: String?, scope: WorkWorkspaceScope) -> String {
        "cos.workOrder." + (domain.map { "domain:" + $0 } ?? "all") + "|" + scope.rawValue
    }
}

/// Where the Order choices are remembered (UserDefaults in the app; a dictionary in checks).
struct WorkBoardOrderStore: Sendable {
    var read: @Sendable (String) -> String?
    var write: @Sendable (String, String) -> Void
    static let standard = WorkBoardOrderStore(read: { UserDefaults.standard.string(forKey: $0) },
                                              write: { UserDefaults.standard.set($1, forKey: $0) })
}

/// A card's date and when it was last active.
struct WorkCardDates: Equatable, Sendable {
    /// The card's date: its meeting's or source's day, or (firstSeen) the day its line first appeared in git.
    var created: Date?
    /// The date is when the line first appeared in the task file's history, not a day the card carries.
    var firstSeen = false
    var active: Date?
    /// The newest activity is the created day, not a moment.
    var activeIsDay = false
}

enum WorkCardDating {
    /// A `YYYY-MM-DD` that is a real day, at the start of that day here.
    nonisolated static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.day, from: date) == parts[2], calendar.component(.month, from: date) == parts[1] else { return nil }
        return date
    }
    /// The first real `20YY-MM-DD` in a source label ("Manual entry 2026-10-06", "PR Strategy [2026-09-15]"), by the
    /// server's rule (task-dates.ts sourceDate): a link's target is not label text, only its words.
    nonisolated static func firstDay(in source: String, calendar: Calendar) -> Date? {
        let label = source.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        var rest = label[...]
        while let range = rest.range(of: #"20[0-9]{2}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) {
            if let date = day(String(rest[range]), calendar: calendar) { return date }
            rest = rest[range.upperBound...]
        }
        return nil
    }
    /// The server's day (`createdOn`, 6.65.0; first seen when it came from git), else the first day in the source label,
    /// else none.
    nonisolated static func created(_ task: TaskRow, calendar: Calendar) -> (day: Date, firstSeen: Bool)? {
        if let server = task.createdOn, let date = day(server, calendar: calendar) { return (date, task.createdFrom == "git") }
        return firstDay(in: task.source, calendar: calendar).map { ($0, false) }
    }
    /// Made once: a formatter per card cost about 60 ms a redraw on a 300-card board (QA S-W5).
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return format
    }()
    nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()
    nonisolated static func instant(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }
    /// Recent activity is the newest of: the line's last change (server 6.65.0), Control's own stage move, the last
    /// session Work started for the card, the last file added to it, and the day it was created.
    nonisolated static func dates(task: TaskRow, moved: Date?, session: Date?, file: Date?, calendar: Calendar) -> WorkCardDates {
        let dated = created(task, calendar: calendar)
        let created = dated?.day, firstSeen = dated?.firstSeen ?? false
        let moments = [instant(task.lineChangedAt), moved, session, file].compactMap { $0 }
        if let newest = moments.max(), created.map({ newest >= $0 }) ?? true {
            return WorkCardDates(created: created, firstSeen: firstSeen, active: newest, activeIsDay: false)
        }
        return WorkCardDates(created: created, firstSeen: firstSeen, active: created, activeIsDay: created != nil)
    }
    /// The last session Work started for each card: its newest handoff that was not refused, failed or canceled.
    nonisolated static func lastSessions(_ receipts: [WorkHandoffReceipt]) -> [String: Date] {
        var newest: [String: Double] = [:]
        for receipt in receipts where receipt.createdAt > 0 && !["refused", "failed", "canceled"].contains(receipt.status) {
            newest[receipt.workID] = max(newest[receipt.workID] ?? 0, receipt.createdAt)
        }
        return newest.mapValues { Date(timeIntervalSince1970: $0) }
    }
    /// Every column in `order`: newest or oldest first, cards with no date last; board order breaks ties.
    nonisolated static func sorted<Card>(_ cards: [Card], id: (Card) -> String, order: WorkBoardOrder, dates: [String: WorkCardDates]) -> [Card] {
        guard order != .board else { return cards }
        let keyed = cards.enumerated().map { (offset: $0.offset, card: $0.element,
                                              date: order == .recent ? dates[id($0.element)]?.active : dates[id($0.element)]?.created) }
        return keyed.sorted { left, right in
            switch (left.date, right.date) {
            case let (l?, r?) where l != r: return order == .oldest ? l < r : l > r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return left.offset < right.offset
            }
        }.map(\.card)
    }
    /// The date line a card shows while ordering by date: "active 2 h ago", "dated Sep 22" (its meeting's or source's
    /// day), "first seen May 23" (the day its line first appeared), "No date". Never "created": none of these is that.
    nonisolated static func line(_ dates: WorkCardDates?, order: WorkBoardOrder, now: Date, calendar: Calendar) -> String? {
        switch order {
        case .board: return nil
        case .recent:
            guard let active = dates?.active else { return "No date" }
            return "active " + age(active, isDay: dates?.activeIsDay == true, now: now, calendar: calendar)
        case .newest, .oldest:
            guard let created = dates?.created else { return "No date" }
            return (dates?.firstSeen == true ? "first seen " : "dated ") + shortDay(created, now: now, calendar: calendar)
        }
    }
    nonisolated static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    /// "Sep 22", or "Dec 30, 2025" in another year. No formatter: one per card was most of a redraw.
    nonisolated static func shortDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let text = months[max(0, min(11, (parts.month ?? 1) - 1))] + " \(parts.day ?? 1)"
        return parts.year == calendar.component(.year, from: now) ? text : text + ", \(parts.year ?? 0)"
    }
    /// "now", "12 min ago", "2 h ago", "yesterday", "5 days ago"; a day reads "today".
    nonisolated static func age(_ date: Date, isDay: Bool, now: Date, calendar: Calendar) -> String {
        let seconds = now.timeIntervalSince(date)
        if !isDay && seconds < 86_400 {
            if seconds < 60 { return "now" }
            if seconds < 3_600 { return "\(Int(seconds) / 60) min ago" }
            return "\(Int(seconds) / 3_600) h ago"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// 0.5.259: when Control last changed each card's stage, kept on this Mac for Recent activity
/// (Application Support/COS Control/work-activity.json, work id to ISO time). Written atomically on every stage change
/// Control makes (the board, Intake, Waiting on, and the tracker's own moves and Undo), bounded to the newest 2,000.
@MainActor final class WorkActivityJournal {
    nonisolated static let limit = 2_000
    let url: URL?
    private(set) var moves: [String: Date] = [:]
    /// Bumps on every move noted (the board's dates are kept until it changes).
    private(set) var epoch = 0

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) { moves = Self.decode(data) }
    }
    /// The app's file. Checks write under their own home; the resize harness and a model without background work write
    /// nothing, so no check can touch the real journal.
    nonisolated static func defaultURL(background: Bool) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let home = environment["COS_CONTROL_TEST_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent("work-activity.json") }
        guard background, environment["COS_PERF_FIXTURES"] == nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/COS Control/work-activity.json")
    }
    /// A stage change only: writing the stage a card already has (the identity stamp) is not activity.
    func recordStageChange(_ task: TaskRow, to stage: String, at date: Date = Date()) {
        guard let next = WorkBoardStage(rawValue: stage), next != WorkBoardStage.stage(for: task) else { return }
        record(task.workSourceID, at: date)
    }
    func record(_ workID: String, at date: Date = Date()) {
        var next = moves
        next[workID] = date
        moves = Self.bounded(next, limit: Self.limit)
        epoch &+= 1
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try Self.encode(moves).write(to: url, options: .atomic) }
        catch { NSLog("COS Work: the stage-move journal could not be saved: %@", error.localizedDescription as NSString) }
    }
    /// The newest `limit` moves (ties by id, so the cut is stable).
    nonisolated static func bounded(_ moves: [String: Date], limit: Int) -> [String: Date] {
        guard moves.count > limit else { return moves }
        let kept = moves.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
    nonisolated static func encode(_ moves: [String: Date]) -> Data {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body: [String: Any] = ["version": 1, "moves": moves.mapValues { format.string(from: $0) }]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
    /// What can be read of a file (a bad entry is skipped; a bad file reads as empty), bounded.
    nonisolated static func decode(_ data: Data) -> [String: Date] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = body["moves"] as? [String: Any] else { return [:] }
        var moves: [String: Date] = [:]
        for (id, value) in raw where !id.isEmpty && id.utf8.count <= 2_200 {
            if let date = WorkCardDating.instant(value as? String) { moves[id] = date }
        }
        return bounded(moves, limit: limit)
    }
}

/// Task page width, kept only at the two breaks that change the layout. The raw width is not stored, so a resize
/// between them does not rebuild the text field.
private struct DetailSpan: Equatable, Sendable {
    var sideBySide = true
    var roomy = false
}

/// A task named on a session card. It drags with the same card type a column accepts.
private struct SessionTaskDrag: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id {
            content.draggable(WorkCardDrag(id: id)) {
                Text("Move card").font(COSType.body(12, weight: .medium)).lineLimit(1).padding(8)
                    .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 7))
            }
        } else {
            content
        }
    }
}

/// 0.5.259: what one draw of the board passes to its columns: the search, the order and each card's dates.
private struct WorkBoardPass {
    var search: WorkSearchResult
    /// The search this draw shows, and whether Jev's answer for it is still on its way.
    var key: WorkSearchKey
    var pending: Bool
    var order: WorkBoardOrder
    var dates: [String: WorkCardDates]
    var now: Date
}

/// 0.5.259: the board's search box. Characters stay in this view; the board follows after a very short pause, so a burst
/// of typing redraws it once. ⌘F (the board's shortcut) focuses it; ↓ ↑ walk Best matches, Return opens one, Escape clears.
struct WorkBoardSearchField: View {
    var prompt: String
    @Binding var query: String
    var focusRequest: Int
    var onKey: (WorkSearch.Key) -> Bool
    @State private var text = ""
    @State private var primed = false
    @State private var wait: Task<Void, Never>?
    @FocusState private var focused: Bool
    nonisolated static let settle: Duration = .milliseconds(80)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(COSPalette.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onKeyPress(keys: [.downArrow, .upArrow, .return, .escape]) { press in
                    handle(press.key == .downArrow ? .down : press.key == .upArrow ? .up : press.key == .return ? .open : .clear) ? .handled : .ignored
                }
            if !text.isEmpty {
                Button("Esc") { clear() }.buttonStyle(.plain).font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted).help("Clear the search (Esc)")
            }
        }
        .font(COSType.body(13)).padding(.horizontal, 12).padding(.vertical, 8)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? COSPalette.gold.opacity(0.8) : COSPalette.line))
        .help("⌘F searches the board. Esc clears.")
        .onAppear { if !primed { text = query; primed = true } }
        .onChange(of: text) { _, value in
            wait?.cancel()
            wait = Task { @MainActor in
                try? await Task.sleep(for: Self.settle)
                guard !Task.isCancelled else { return }
                if query != value { query = value }
            }
        }
        .onChange(of: query) { _, value in if text != value { text = value } }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }

    /// A key acts on what is typed: the board's matches catch up first, then the board decides (WorkSearch.key).
    private func handle(_ key: WorkSearch.Key) -> Bool {
        if key == .clear {
            guard !text.isEmpty else { return false }
            clear(); return true
        }
        if query != text { wait?.cancel(); query = text }
        return onKey(key)
    }
    private func clear() { wait?.cancel(); text = ""; query = "" }
}

/// Debounce threshold changes while always cancelling an older pending layout.
@MainActor final class WorkLayoutCommit<Value: Equatable & Sendable> {
    private var pending: Task<Void, Never>?
    func schedule(current: Value, next: Value, apply: @escaping @MainActor (Value) -> Void) {
        pending?.cancel()
        guard next != current else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            apply(next)
        }
    }
    func cancel() { pending?.cancel() }
}

struct WorkWorkspaceView: View {
    @State private var yourMoveAnswerID: String?
    @State private var yourMoveAnswer = ""

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: ControllerModel
    @ObservedObject var handoffStore: WorkHandoffStore
    @ObservedObject var reviewStore: WorkReviewStore
    @ObservedObject var state: WorkWorkspaceState
    var onOpenSession: (String) -> Void
    /// Opens the running Claude, Codex, or Cursor session. The card stays on Work.
    var onOpenPlatform: (WorkSession) -> Void = { _ in }
    var onEditTask: (TaskRow) -> Void
    var onReviewMeeting: (LibraryMeeting) -> Void
    var onOpenMeeting: (WorkMeetingReference) -> Void = { _ in }

    /// 0.5.254 resize pass: the rows, rebuilt only when their data changes (WorkWorkspaceState.board), never on a resize.
    private var board: WorkBoardMemo { state.board(model: model, handoffStore: handoffStore, reviewStore: reviewStore) }
    private var items: [WorkWorkspaceItem] { board.items }
    /// The Focus list: the view's cards, narrowed by the board's own word rule.
    private var visible: [WorkWorkspaceItem] {
        board.visible(scope: state.scope, domain: state.domain, query: state.query, filesEpoch: cardFiles.manifestsEpoch,
                      fileNames: { workID in cardFiles.files(for: workID).map(\.display) })
    }
    private var selected: WorkWorkspaceItem? { board.item(id: state.selectedID) }
    private var domains: [String] { Array(Set(model.domainOptions.map(\.name) + items.map(\.domain))).filter { !$0.isEmpty }.sorted() }
    private var hasDetail: Bool { state.selectedID != nil || state.meetingPicker || reviewStore.selectedMeeting != nil }
    @AppStorage("cos.workLayout") private var layoutRaw = WorkLayout.board.rawValue
    @AppStorage("cos.workSessionsRowCollapsed") private var sessionsCollapsed = false
    @State private var startDropTargeted = false
    /// 0.5.254: a file is over the session row: Start work says where files go.
    @State private var startFileHover = false
    /// The files on each card (WorkCardFiles.swift).
    private var cardFiles: WorkCardFileStore { handoffStore.cardFiles }
    @State private var columnTarget: WorkBoardStage?
    /// Header, list, and card face share one drag. The count keeps the highlight up while any of them is still hovered.
    @State private var columnDrag = ColumnDragTrack()
    /// How many session cards fit beside the pinned Start work column, so it casts its edge only when cards run under
    /// it. 0.5.254 resize pass: the count, not the width, is kept: it changes about every 330 pt, where the width
    /// changed on every step of a resize and redrew the whole board each time.
    @State private var sessionsRowCapacity = Int.max
    /// The wide layout (the sidebar beside the board) from 900 pt. Flips only when the window crosses it.
    @State private var wideLayout = true
    /// Task page: workspace beside the writeup from 760 pt, and the wider 452 pt column from 1,100. Not the raw width.
    @State private var detailSpan = DetailSpan()
    /// The first measurement applies at once. A later flip waits until the drag pauses, so crossing 760 does not
    /// rebuild the review while the window is still moving.
    @State private var detailSpanSeen = false
    @State private var detailSpanCommit = WorkLayoutCommit<DetailSpan>()
    @State private var editingReviewID: String?
    @State private var reviewTitleDraft = ""
    @FocusState private var reviewTitleFocused: Bool
    /// The remembered layout (Board by default; an unknown stored value reads as Board). The isolated preview keeps
    /// its own, so trying Focus there never changes the real preference.
    private var storedLayout: WorkLayout { handoffStore.isolated ? state.previewLayout : (WorkLayout(rawValue: layoutRaw) ?? .board) }
    private var layout: WorkLayout { state.focusOverride ? .focus : storedLayout }
    private var layoutBinding: Binding<WorkLayout> {
        Binding(get: { layout }, set: { value in
            state.focusOverride = false; state.pendingComplete = nil
            if handoffStore.isolated { state.previewLayout = value } else { layoutRaw = value.rawValue }
            // Board opens on the board itself, not on an item left open in Focus.
            if value == .board { returnToList() }
        })
    }

    var body: some View {
        let _ = WorkBoardMetrics.countBody()
        VStack(spacing: 0) {
            header
            activitySummary
            yourMoveCard
            if state.captureOpen { captureForm }
            if let error = state.mutationError {
                HStack { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger); Spacer()
                    Button("Dismiss") { state.mutationError = nil }.buttonStyle(COSQuietButtonStyle())
                }.padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider().overlay(COSPalette.line)
            if state.meetingPicker {
                HStack {
                    Button { closePickerOrDetail() } label: { Label(state.linkTarget == nil ? "Back to work" : "Cancel linking", systemImage: "chevron.left") }
                        .buttonStyle(COSQuietButtonStyle())
                    Spacer()
                }.padding(.horizontal, 18).padding(.vertical, 8)
                detailPane
            } else if hasDetail && layout == .board {
                // The open review stays in this branch across the 900 pt break. Moving it between the wide and
                // compact trees rebuilt the writeup and the context field on the way in and the way back out.
                HStack(spacing: 0) {
                    if wideLayout {
                        sidebar.frame(width: 148)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        if !wideLayout {
                            compactNavigation
                            Divider()
                        }
                        backBar(state.domain == nil ? "Back to the board" : "Back to " + boardName + " board")
                        detailPane
                    }
                }
            } else if wideLayout {
                HStack(spacing: 0) {
                    sidebar.frame(width: 148)
                    Divider()
                    if state.waitingOpen {
                        WorkWaitingView(model: model)
                    } else if state.intakeOpen {
                        WorkIntakeView(model: model, domain: state.domain, onOpenMeeting: onOpenMeeting)
                    } else if layout == .board {
                        boardSurface
                    } else {
                        focusSurface
                    }
                }
            } else {
                compactNavigation
                Divider()
                if state.waitingOpen { WorkWaitingView(model: model) }
                else if state.intakeOpen { WorkIntakeView(model: model, domain: state.domain, onOpenMeeting: onOpenMeeting) }
                else if layout == .board { boardSurface }
                else if hasDetail {
                    HStack {
                        Button { returnToList() } label: { Label("Back to work list", systemImage: "chevron.left") }
                            .buttonStyle(COSQuietButtonStyle())
                        Spacer()
                    }.padding(.horizontal, 18).padding(.vertical, 8)
                    detailPane
                } else { workList }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(COSPalette.panel).clipped()
            .overlay { startOverlay }
        // 0.5.254 resize pass: no GeometryReader around the body (it re-ran the whole view on every step of a resize).
        // Only the layout choice is kept, and the action runs only when it flips (and once with the first size).
        .onGeometryChange(for: Bool.self) { $0.size.width >= 900 } action: { wideLayout = $0 }
        .task {
            if let id = handoffStore.selectedWorkID { state.selectedID = WorkWorkspaceProjection.rowID(forSourceID: id, currentID: state.selectedID, items: items) ?? id }
            cardFiles.loadIfNeeded()
            guard !handoffStore.isolated else { return }
            await model.loadDomains()
            await model.loadWorkTasks()
            await reviewStore.refresh()
            await model.loadWorkIntake()
            // 0.5.254: a card's folder 14 days after the card completes and its last file or handoff (never in the preview),
            // decided from the journal as it is on disk.
            if let receipts = handoffStore.receiptsOnDisk() {
                await cardFiles.cleanup(tasks: model.workTasks, inventoryComplete: model.workTasksComplete, receipts: receipts)
                // 0.5.258: a meeting file removed 14 days ago that no session was sent goes; nothing else does.
                await handoffStore.meetingFiles.cleanupMeetings(receipts: receipts)
            }
            if let id = handoffStore.selectedWorkID { state.selectedID = WorkWorkspaceProjection.rowID(forSourceID: id, currentID: state.selectedID, items: items) ?? id }
        }
        .task(id: scenePhase) {
            guard !handoffStore.isolated, scenePhase == .active else { return }
            while !Task.isCancelled {
                if !handoffStore.receipts.isEmpty {
                    await handoffStore.refreshActivity()
                    guard !Task.isCancelled else { return }
                    if handoffStore.receipts.contains(where: { $0.blocksNewHandoff && $0.status != "delivered" }) {
                        await handoffStore.refreshReceipts()
                    }
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .task(id: reviewStore.reviews.contains { ["preparing", "starting", "queued", "running", "accepted"].contains($0.status) }) {
            guard !handoffStore.isolated else { return }
            while !Task.isCancelled && reviewStore.reviews.contains(where: { ["preparing", "starting", "queued", "running", "accepted"].contains($0.status) }) {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled else { return }
                await reviewStore.refresh()
            }
        }
        .onExitCommand {
            if state.startItemID != nil { state.startItemID = nil }
            else if state.meetingPicker || hasDetail { closePickerOrDetail() }
        }
        .onChange(of: reviewStore.selectedReviewID) { _, id in
            if let id, let review = reviewStore.reviews.first(where: { $0.id == id }) {
                state.selectedID = "meeting-review:" + review.id; handoffStore.selectedWorkID = review.source.id
            }
        }
         .onChange(of: handoffStore.selectedWorkID) { _, id in
            if let id { state.selectedID = WorkWorkspaceProjection.rowID(forSourceID: id, currentID: state.selectedID, items: items) ?? id }
        }
        .onChange(of: reviewStore.selectedMeeting?.recordId) { _, id in
            if id != nil { state.selectedID = nil; state.meetingPicker = false }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Work").font(COSType.display(26, weight: .medium))
                Text(handoffStore.isolated ? "Local sample data. No task writes or agent calls." : model.workTasksComplete ? "Tasks, meeting follow-up, and the sessions doing the work." : "Showing available work. Task inventory is not confirmed complete.")
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            }
            Spacer(minLength: 8)
            COSViewSwitch("Layout", selection: layoutBinding, options: WorkLayout.allCases.map { COSViewOption($0, $0.title) })
                .fixedSize()
                .help("Board: the sessions working now over the Kanban. Focus: the list; an open item shows its Agent workspace beside it, or under its title in a narrow window.")
            Button("Add task") {
                state.captureOpen.toggle()
                if state.captureDomain.isEmpty { state.captureDomain = state.domain ?? model.domainOptions.first?.name ?? "" }
            }.buttonStyle(COSQuietButtonStyle()).disabled(handoffStore.isolated)
            Button(handoffStore.isolated ? "Sample meeting review" : "Review a meeting") {
                if handoffStore.isolated {
                    if let item = items.first(where: { $0.review != nil }) { select(item) }
                    return
                }
                state.linkTarget = nil; state.meetingPicker = true; state.selectedID = nil; reviewStore.selectedMeeting = nil
                Task { await model.loadLibraryMeetings() }
            }.buttonStyle(COSPrimaryButtonStyle())
            Button { Task { await model.loadWorkTasks(); await reviewStore.refresh(); await handoffStore.refreshActivity(); await handoffStore.refreshReceipts(asked: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(COSQuietButtonStyle()).disabled(handoffStore.isolated || model.workTasksLoading || reviewStore.busy).help("Refresh work")
        }.padding(18)
    }

    private var activitySummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { activityCounts; Spacer(minLength: 0); activityFreshness }
            VStack(alignment: .leading, spacing: 8) { HStack(spacing: 16) { activityCounts }; activityFreshness }
        }.font(COSType.body(11.5)).padding(.horizontal, 18).padding(.bottom, 14)
    }
    @ViewBuilder private var activityCounts: some View {
        let progress = items.filter(\.inProgress).count, attention = items.filter(\.needsAttention).count
        countLink("\(progress) in progress", count: progress, scope: .progress, tint: COSPalette.accent)
        countLink("\(attention) " + (attention == 1 ? "needs attention" : "need attention"), count: attention, scope: .attention, tint: Color.primary)
    }
    /// 0.5.244: each count opens its list in Focus, or the item itself when there is exactly one.
    private func countLink(_ text: String, count: Int, scope: WorkWorkspaceScope, tint: Color) -> some View {
        Button { openScope(scope) } label: {
            HStack(spacing: 3) {
                Text(text)
                if count > 0 { Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold)) }
            }.foregroundStyle(count > 0 ? tint : COSPalette.muted).padding(.bottom, 2)
                .overlay(alignment: .bottom) {
                    if count > 0 { Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2])).foregroundStyle(tint.opacity(0.55)).frame(height: 0.5) }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(count == 0).help(count == 0 ? "" : "Show " + text)
    }
    private func openScope(_ scope: WorkWorkspaceScope) {
        state.query = ""; state.domain = nil; state.scope = scope; returnToList()
        state.focusOverride = true   // this visit only; the remembered layout is unchanged
        let matches = WorkWorkspaceProjection.filter(items, scope: scope, domain: nil, query: "")
        if matches.count == 1, let only = matches.first { select(only) }
    }
    private var activityFreshness: some View {
        Group {
            if handoffStore.isolated { Text("Sample activity") }
            else if let error = handoffStore.activityError { Text(error) }
            else if handoffStore.activityRefreshing { Text("Checking session activity…") }
            else if let checked = handoffStore.activityCheckedAt {
                Text("Sessions checked \(checked, style: .relative) ago")
            } else { Text("Session activity appears after a handoff") }
        }.foregroundStyle(COSPalette.muted)
    }

    private var captureForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("What needs to be done?", text: $state.captureText).textFieldStyle(.plain).cosField().disabled(state.captureBusy)
                if !handoffStore.isolated && model.workBatchAvailable {
                Button("Waiting on / Dropped") { state.waitingOpen = true; state.intakeOpen = false; returnToList() }.buttonStyle(COSTextButtonStyle())
            }
            COSDropdown("Domain", selection: $state.captureDomain,
                            options: [COSDropdownOption("", "Choose domain", placeholder: true)]
                                + model.domainOptions.map { COSDropdownOption($0.name, $0.label) })
                    .frame(maxWidth: 200).disabled(state.captureBusy)
                Button(state.captureBusy ? "Adding…" : "Capture") {
                    guard !handoffStore.isolated else { return }
                    let text = state.captureText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let domain = state.captureDomain
                    state.captureBusy = true; state.captureError = nil
                    Task {
                        defer { state.captureBusy = false }
                        do {
                            try await model.captureTask(domain: domain, text: text)
                            state.captureText = ""; state.captureOpen = false
                            await model.loadWorkTasks()
                        } catch { state.captureError = error.localizedDescription }
                    }
                }.buttonStyle(COSPrimaryButtonStyle())
                    .disabled(state.captureBusy || state.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.domainOptions.contains { $0.name == state.captureDomain })
            }
            if let error = state.captureError { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
        }.padding(.horizontal, 18).padding(.bottom, 12)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(WorkWorkspaceScope.allCases) { scope in
                    navigationRow(scope.title, selected: state.scope == scope && state.domain == nil && !state.intakeOpen) {
                        state.scope = scope; state.domain = nil; state.intakeOpen = false; state.focusOverride = false; returnToList()
                    }
                }
                if model.workBatchAvailable {
                    navigationRow("Waiting on", selected: state.waitingOpen) {
                        state.waitingOpen = true; state.intakeOpen = false; returnToList()
                    }
                }
                if !handoffStore.isolated && model.workIntakeVisible {
                    navigationRow(intakeTitle, selected: state.intakeOpen) {
                        state.waitingOpen = false; state.intakeOpen = true; state.domain = nil; returnToList()
                    }
                }
                Divider().padding(.vertical, 12)
                Text("Domains").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted).padding(.horizontal, 10)
                ForEach(domains, id: \.self) { domain in
                    navigationRow(domainLabel(domain), selected: state.domain == domain && !state.intakeOpen) {
                        let sorting = state.intakeOpen
                        state.domain = domain; state.scope = .all; state.intakeOpen = sorting; state.focusOverride = false; returnToList()
                    }
                }
            }.padding(10)
        }.background(COSPalette.raised.opacity(0.55))
    }

    private var intakeTitle: String {
        let count = model.workIntake.newCount + WorkSortGroup.mentioned(model.workTasks, catchUp: false, domain: nil).count
        if !model.workIntake.available || model.workIntakeError != nil { return "Intake · !" }
        return count > 0 ? "Sort · \(count) new" : "Sort"
    }

    private func navigationRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle().fill(selected ? COSPalette.gold : .clear).frame(width: 2)
                Text(title).font(COSType.body(12, weight: selected ? .semibold : .regular)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.padding(.vertical, 9).padding(.trailing, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(selected ? Color.primary : COSPalette.muted)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var compactNavigation: some View {
        HStack(spacing: 18) {
            COSDropdown("View", selection: Binding(get: { state.scope }, set: { value in
                state.scope = value; state.intakeOpen = false; state.focusOverride = false; returnToList()
            }), options: WorkWorkspaceScope.allCases.map { COSDropdownOption($0, $0.title) })
                .fixedSize()
            if !handoffStore.isolated && model.workIntakeVisible {
                Toggle(intakeTitle, isOn: $state.intakeOpen).toggleStyle(COSChipToggleStyle())
            }
            COSDropdown("Domain", selection: Binding(get: { state.domain ?? "" }, set: { state.domain = $0.isEmpty ? nil : $0; returnToList() }),
                        options: [COSDropdownOption("", "All domains")] + domains.map { COSDropdownOption($0, domainLabel($0)) })
                .fixedSize()
            Spacer(minLength: 0)
        }.font(COSType.body(12)).padding(.horizontal, 18).padding(.vertical, 10)
    }

    @ViewBuilder private var yourMoveCard: some View {
        if model.workYourMoveAvailable && !model.workYourMove.isEmpty && !hasDetail {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your move").font(COSType.body(13, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.workYourMove) { row in yourMoveRow(row) }
                    }
                }.frame(maxHeight: 154)
            }.padding(12).background(COSPalette.card).padding(.horizontal, 18).padding(.bottom, 10)
        }
    }

    private func yourMoveSource(_ row: WorkYourMove) -> WorkSource? {
        guard let item = board.item(sourceID: row.workID) else { return nil }
        if let task = item.task { return .taskSnapshot(task) }
        return item.review?.source
    }

    private func openYourMove(_ row: WorkYourMove) {
        if row.action == "answer" { yourMoveAnswerID = row.id; yourMoveAnswer = ""; return }
        if row.action == "checkSession", let session = row.sessionID { onOpenSession(session); return }
        guard let item = board.item(sourceID: row.workID) else { return }
        if row.action == "startFresh", let source = yourMoveSource(row) {
            var draft = handoffStore.draft(for: source)
            draft.mode = .newSession; draft.sessionID = ""
            _ = handoffStore.updateDraft(draft, for: source)
        }
        select(item)
    }

    private func yourMoveRow(_ row: WorkYourMove) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.title).font(COSType.body(12)).lineLimit(2)
                Spacer(minLength: 8)
                Button(row.actionTitle) { openYourMove(row) }.buttonStyle(COSQuietButtonStyle())
                    .disabled(row.action != "checkSession" && yourMoveSource(row) == nil)
                yourMoveSecondary(row)
            }
            if yourMoveAnswerID == row.id { yourMoveComposer(row) }
        }
    }

    @ViewBuilder private func yourMoveSecondary(_ row: WorkYourMove) -> some View {
        if row.kind == "qa", let task = board.item(sourceID: row.workID)?.task {
            Button("Mark done") { move(task, to: .complete) }.buttonStyle(COSQuietButtonStyle()).disabled(!canChangeStage(task))
        } else {
            Button("No reply needed") {
                handoffStore.noReplyNeeded(receiptID: row.id)
                Task { await model.loadYourMove() }
            }.buttonStyle(COSQuietButtonStyle()).disabled(handoffStore.busy)
        }
    }

    private func yourMoveComposer(_ row: WorkYourMove) -> some View {
        HStack {
            TextField("Your answer", text: $yourMoveAnswer)
                .textFieldStyle(.plain)
            Button("Send") {
                guard let source = yourMoveSource(row) else { return }
                let answer = yourMoveAnswer
                Task {
                    if await handoffStore.reply(receiptID: row.id, source: source, answer: answer) { yourMoveAnswerID = nil; yourMoveAnswer = "" }
                    await model.loadYourMove()
                }
            }.buttonStyle(COSQuietButtonStyle()).disabled(handoffStore.busy || yourMoveAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { yourMoveAnswerID = nil }.buttonStyle(COSQuietButtonStyle())
        }
    }

    private var boardName: String { state.domain.map { domainLabel($0) } ?? state.scope.title }

    private func backBar(_ title: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { returnToList() } label: { Label(title, systemImage: "chevron.left") }.buttonStyle(COSQuietButtonStyle())
                Spacer()
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Divider().overlay(COSPalette.line)
        }
    }

    @ViewBuilder private var boardSurface: some View {
        if hasDetail {
            VStack(spacing: 0) {
                backBar(state.domain == nil ? "Back to the board" : "Back to " + boardName + " board")
                detailPane
            }
        } else { dashboard }
    }

    /// Focus (2A): the list; an open item takes the whole pane with its Agent workspace pinned beside it.
    @ViewBuilder private var focusSurface: some View {
        if state.selectedID != nil || reviewStore.selectedMeeting != nil {
            VStack(spacing: 0) {
                backBar("Back to " + boardName)
                detailPane
            }
        } else {
            HStack(spacing: 0) {
                workList.frame(width: 248)
                Divider()
                detailPane.frame(maxWidth: .infinity)
            }
        }
    }

    /// 0.5.244 Board: the sessions doing the work, then the Kanban. Cards drag between columns (stage) and onto
    /// Start work (confirm, then send). Nothing runs on a drop.
    private var dashboard: some View {
        WorkBoardMetrics.countBoard()
        // 0.5.259: the board's cards (every card in this view; the search narrows the columns, not this list), what the
        // search found, and the order each column follows. Worked out once here, never per column.
        let cards = boardCards
        let search = boardSearch()
        let order = boardOrder
        let key = state.currentSearchKey
        let pass = WorkBoardPass(search: search, key: key, pending: state.meaningPending == key, order: order,
                                 dates: order == .board ? [:] : board.cardDates(filesEpoch: cardFiles.manifestsEpoch, movesEpoch: model.workActivity.epoch) { cardDates($0) },
                                 now: Date())
        let taskCount = cards.filter { $0.task != nil }.count
        let shownCount = WorkSearch.kept(cards.filter { $0.task != nil }, search).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(boardName).font(COSType.display(23, weight: .medium))
                    Text(WorkSearch.countLabel(kept: shownCount, of: taskCount, active: search.active) + " tasks · Drag a card to change its stage, or onto Start work to put a session on it")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    WorkBoardSearchField(prompt: state.domain == nil && state.scope == .all ? "Search work" : "Search this board", query: $state.query,
                                         focusRequest: state.searchFocusRequest, onKey: { boardSearchKey($0) })
                        .frame(maxWidth: 360)
                    orderMenu(order)
                }
            }.padding(18)
            .background {
                // ⌘F: the search box takes the focus. Drawn nowhere; only its shortcut is live.
                Button("Search the board") { state.searchFocusRequest &+= 1 }.keyboardShortcut("f", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            if search.active { searchResults(search) }
            if !handoffStore.isolated && !model.workBoardWritable {
                Text("Board is read-only. Stage changes and meeting links need the connected Work service.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.muted).padding(.horizontal, 18).padding(.bottom, 10)
            }
            if let error = model.workTasksError { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger).padding(.horizontal, 18) }
            if let error = handoffStore.error {
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle").font(COSType.body(12)).foregroundStyle(COSPalette.danger)
                    Spacer()
                    Button("Dismiss") { handoffStore.error = nil }.buttonStyle(COSTextButtonStyle())
                }.padding(.horizontal, 18).padding(.bottom, 10)
            }
            if let task = state.pendingComplete {
                HStack(spacing: 10) {
                    Text("Mark \u{201C}" + String((task.text.isEmpty ? task.title : task.text).replacingOccurrences(of: "**", with: "").prefix(80)) + "\u{201D} complete?")
                        .font(COSType.body(12)).lineLimit(1)
                    Spacer()
                    Button("Mark complete") { state.pendingComplete = nil; move(task, to: .complete) }.buttonStyle(COSQuietButtonStyle())
                        .disabled(!canChangeStage(task))
                    Button("Cancel") { state.pendingComplete = nil }.buttonStyle(COSTextButtonStyle())
                }.padding(.horizontal, 18).padding(.bottom, 10)
            }
            sessionsRow
            // 0.5.254: a file dropped on a column or the session row says where files go, then fades.
            WorkCardFlashView(files: cardFiles, workID: nil).clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 18).padding(.bottom, 10)
            let words = WorkSearch.words(state.query)
            let reviews = cards.filter { $0.review != nil && (!search.active || WorkSearch.fields($0, files: []).match(words) != nil) }
            if !reviews.isEmpty {
                HStack {
                    Text("Meeting reviews").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                    Menu { ForEach(reviews) { item in Button(item.title + " · " + (item.review?.status ?? "")) { select(item) } } }
                        label: { COSMenuLabel(title: "\(reviews.count) recorded") }
                        .cosMenu().fixedSize()
                    Spacer()
                }.padding(.horizontal, 18).padding(.bottom, 10)
            }
            latestMoveStrip
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(WorkBoardStage.allCases) { stage in boardColumn(stage, pass: pass) }
                }.padding(.horizontal, 18).padding(.bottom, 18)
            }.frame(minHeight: 220)
            Text(handoffStore.isolated ? "Sample stages reset when this preview closes." : "Stages reflect your decisions. Moving a card does not run an agent or publish changes. Start work asks before anything is sent.")
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).padding(.horizontal, 18).padding(.bottom, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(COSPalette.panel)
        // 0.5.259: Jev is asked after a pause in typing; a new search cancels the wait (and drops a late answer).
        .task(id: state.currentSearchKey) {
            if state.bandIndex != 0 { state.bandIndex = 0 }   // a published write redraws the board, even of the same value
            await state.searchMeaning(WorkSearch.request(key: state.currentSearchKey, query: state.query, items: boardCards), isolated: handoffStore.isolated)
        }
    }

    // MARK: Work search and order (0.5.259)

    /// The board's cards for this view, before the search narrows the columns.
    private var boardCards: [WorkWorkspaceItem] { board.visible(scope: state.scope, domain: state.domain, query: "") }
    private var boardOrder: WorkBoardOrder { state.order(domain: state.domain, scope: state.scope, isolated: handoffStore.isolated) }
    private func boardSearch() -> WorkSearchResult {
        board.search(scope: state.scope, domain: state.domain, query: state.query, meaning: state.meaning(for: state.currentSearchKey),
                     filesEpoch: cardFiles.manifestsEpoch, fileNames: { workID in cardFiles.files(for: workID).map(\.display) })
    }
    /// Each card's created day and last activity (only while ordering by date).
    private func cardDates(_ cards: [WorkWorkspaceItem]) -> [String: WorkCardDates] {
        let calendar = Calendar.current
        let sessions = WorkCardDating.lastSessions(handoffStore.receipts)
        let moves = model.workActivity.moves
        var dates: [String: WorkCardDates] = [:]
        for item in cards {
            guard let task = item.task else { continue }
            let file = cardFiles.lastAdded(item.sourceID).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            dates[item.id] = WorkCardDating.dates(task: task, moved: moves[item.sourceID], session: sessions[item.sourceID], file: file, calendar: calendar)
        }
        return dates
    }

    /// ↓ ↑ Return and Escape from the search box (WorkSearch.key decides; this only applies it). The search is read
    /// again here, so a key pressed right after typing acts on what was typed.
    private func boardSearchKey(_ key: WorkSearch.Key) -> Bool {
        let search = boardSearch()
        switch WorkSearch.key(key, query: state.query, highlighted: state.bandIndex, bandCount: search.band.count) {
        case .highlight(let index): state.bandIndex = index; return true
        case .open(let index):
            if let item = board.item(id: search.band[index]) { select(item) }
            return true
        case .clear: state.query = ""; state.bandIndex = 0; return true
        case .pass: return false
        }
    }

    /// The result line, Best matches, and the one line about meaning search when it matters.
    private func searchResults(_ search: WorkSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(search.headline(pending: state.meaningPending == state.currentSearchKey)).font(COSType.body(12.5, weight: .semibold))
                if !search.hits.isEmpty { Text(search.kindsText).font(COSType.body(12)).foregroundStyle(COSPalette.muted) }
                Spacer(minLength: 8)
                if let more = WorkSearch.elsewhereText(search.elsewhere.map { WorkSearchElsewhere(domain: domainLabel($0.domain), count: $0.count) }) {
                    Button(more) { state.domain = nil; state.scope = .all; state.focusOverride = false }
                        .buttonStyle(COSTextButtonStyle()).help("Search all work")
                }
            }
            if !search.band.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(search.band.enumerated()), id: \.element) { index, id in
                        if let item = board.item(id: id), let hit = search.hits[id] {
                            bestMatchRow(item, hit: hit, highlighted: index == min(state.bandIndex, search.band.count - 1))
                            if index < search.band.count - 1 { Divider().overlay(COSPalette.line.opacity(0.6)) }
                        }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(COSPalette.line).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(COSPalette.line).frame(height: 1) }
            }
            if let note = search.note { Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.muted) }
        }.padding(.horizontal, 18).padding(.bottom, 12)
    }

    /// One Best match: its stage, its title with the found words underlined, and why it matched. A tap opens it.
    private func bestMatchRow(_ item: WorkWorkspaceItem, hit: WorkSearchHit, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(item.task.map { WorkBoardStage.stage(for: $0).title } ?? "Review").font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted)
                .frame(width: 76, alignment: .leading)
            Text(WorkSearch.underlined(AttributedString(WorkSource.plainTitle(item.title)), words: hit.words))
                .font(COSType.body(12.5)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Text(WorkSearch.why(hit)).font(COSType.body(11.5)).italic(hit.kind == .meaning)
                .foregroundStyle(hit.kind == .meaning ? COSPalette.gold.opacity(0.8) : COSPalette.accent).lineLimit(1)
                .frame(width: 180, alignment: .trailing)
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .background(highlighted ? COSPalette.gold.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { select(item) }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityAction { select(item) }
        .help("Open this card")
    }

    /// Order: the house dropdown beside the search, as the app's other sort menus (never a row of buttons).
    private func orderMenu(_ order: WorkBoardOrder) -> some View {
        COSDropdown("Order", selection: Binding(get: { order }, set: { choice in
            state.setOrder(choice, domain: state.domain, scope: state.scope, isolated: handoffStore.isolated)
        }), options: WorkBoardOrder.allCases.map { COSDropdownOption($0, $0.title) })
        .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
        .fixedSize()
        .help(order.help)
    }

    private var sessionsRow: some View {
        let allCards = board.sessionCards(domain: state.domain) {
            WorkBoardSessionsProjection.cards($0, receipts: handoffStore.receipts, sessions: handoffStore.observedSessions(), domain: state.domain)
        }
        let cards = WorkBoardSessionsProjection.onePerSession(allCards)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(state.domain == nil ? "Sessions working now" : "Sessions on this board").font(COSType.body(13, weight: .semibold))
                Text(WorkBoardSessionsProjection.summary(allCards)).font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                Spacer()
                if !cards.isEmpty {
                    Button(sessionsCollapsed ? "Show" : "Hide") { sessionsCollapsed.toggle() }.buttonStyle(COSTextButtonStyle())
                        .help(sessionsCollapsed ? "Show the session cards" : "Hide the session cards to give the board more room")
                }
            }
            // 0.5.245: Start work is a pinned column the session cards slide under, instead of a hard cut beside it.
            // Its leading shadow and hairline appear only when cards actually run under it, so a short row stays flat.
            let showCards = !sessionsCollapsed && !cards.isEmpty
            let overflowing = showCards && cards.count > sessionsRowCapacity
            // The column hangs off the row as an overlay, so it always takes the row's height: a ZStack let it
            // stretch to the window when the row was empty (0.5.245).
            Group {
                if showCards {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: WorkBoardSessionCard.cardGap) {
                            ForEach(cards) { sessionCard($0) }
                            // Room to scroll the last card fully clear of the pinned column.
                            Color.clear.frame(width: WorkBoardSessionCard.pinnedColumnWidth, height: 1)
                        }.padding(.vertical, 2)
                    }.scrollIndicators(overflowing ? .visible : .hidden)
                    // Cards fade out over 40 pt before they pass under the pinned column, instead of cutting mid-letter.
                    .mask(HStack(spacing: 0) {
                        Rectangle()
                        if overflowing {
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 40)
                            Color.clear.frame(width: WorkBoardSessionCard.pinnedColumnWidth)
                        }
                    })
                } else {
                    Color.clear.frame(height: sessionsCollapsed ? 40 : 96)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    startWorkTarget(empty: cards.isEmpty, compact: sessionsCollapsed)
                    Spacer(minLength: 0)
                }
                .padding(.leading, WorkBoardSessionCard.cardGap)
                .frame(width: WorkBoardSessionCard.pinnedColumnWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .leading) {
                    // A horizontal-only shade, so nothing bleeds onto the header above or the board below.
                    Rectangle().fill(COSPalette.panel)
                        .overlay(alignment: .leading) {
                            if overflowing {
                                // Deeper on the dark espresso, where a light shade disappears.
                                LinearGradient(colors: [.clear, .black.opacity(colorScheme == .dark ? 0.45 : 0.16)], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 18).offset(x: -18).allowsHitTesting(false)
                                Rectangle().fill(COSPalette.line).frame(width: 1)
                            }
                        }
                }
            }
            // 0.5.246: the whole row is the drop zone ("drag it into the working area"), and Start work lights up while
            // a card is over it. A drop destination inside `.overlay` never receives drops (measured with real mouse
            // drags on this board), which is why the pinned tile alone could not take one.
            // 0.5.254: it takes the private card type only. A file here is refused with a line and never starts anything.
            .contentShape(Rectangle())
            .onDrop(of: WorkCardFiles.boardDropTypes, delegate: WorkBoardDropDelegate(target: .sessionRow, onCard: { id in
                guard let item = WorkWorkspaceProjection.startable(id: id, items: items) else {
                    if items.contains(where: { $0.id == id }) { state.mutationError = "Only open board cards can be started. A completed card or a meeting review is started from its own page." }
                    return
                }
                openStart(item)
            }, onTargeted: { startDropTargeted = $0 }, onFileHover: { startFileHover = $0 }, onRefusedFiles: { cardFiles.flashBoard() }))
            .onGeometryChange(for: Int.self) { WorkBoardSessionCard.rowCapacity(width: $0.size.width) } action: { sessionsRowCapacity = $0 }
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func sessionCard(_ card: WorkBoardSessionCard) -> some View {
        let receipt = card.activity.receipt, state = card.state
        let held = receipt.progress == nil ? [] : WorkProgress.workingSession(receipt).map { sessionID in
            WorkTracking.forSession(sessionID, receipts: handoffStore.receipts)
                .filter { tracking in board.item(sourceID: tracking.receipt.workID)?.completed != true }
        } ?? []
        // A task waiting on you is the most urgent thing on the card, whatever the top handoff's own state.
        let asking = held.first(where: \.asksForYou)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if let asking {
                    WorkTrackingDot(phase: asking.phase, tint: asking.tint)
                    Text(asking.label).font(COSType.body(11.5, weight: .semibold)).foregroundStyle(asking.tint).lineLimit(1)
                } else {
                    WorkLiveDot(color: state.tint, live: state == .running)
                    // The row speaks in the summary's words ("1 running · 1 reply ready"); the item's status box adds detail.
                    Text(state.label).font(COSType.body(11.5, weight: .semibold)).foregroundStyle(state.tint).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(card.ageText()).font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted).lineLimit(1)
            }
            HStack(spacing: 8) {
                WorkProviderGlyph(provider: receipt.provider)
                Text(card.activity.session?.title ?? receipt.sessionTitle).font(COSType.body(13.5, weight: .semibold)).lineLimit(1)
            }
            if held.isEmpty {
                HStack(spacing: 8) {
                    (Text("On ") + Text(inlineTitle(card.item.title)).foregroundColor(.primary)
                        + Text(" · " + (card.item.task.map { WorkBoardStage.stage(for: $0).title } ?? "Meeting review")
                               + (card.earlierRevision ? " · an earlier version of the card" : "")))
                        .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
                    if let task = card.item.task { stageMenu(task) }
                }
                .modifier(SessionTaskDrag(id: card.item.task == nil ? nil : card.item.id))
            } else {
                // 0.5.247: every task this session holds, and where each one stands.
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(held.prefix(WorkTracking.cardRows), id: \.receipt.id) { tracking in heldTaskRow(tracking) }
                    if held.count > WorkTracking.cardRows {
                        Text("+\(held.count - WorkTracking.cardRows) more").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                }
                if let asking = held.last(where: \.asksForYou), let evidence = asking.evidence {
                    Text("\u{201C}" + evidence + "\u{201D}").font(COSType.body(11.5)).foregroundStyle(COSPalette.amber).lineLimit(2)
                }
            }
            if held.contains(where: \.asksForYou) {
                // The question above says what the session needs; the reply excerpt would repeat it.
            } else if state == .waiting, let waiting = card.activity.session?.waitingDetail, !waiting.isEmpty {
                Text(waiting).font(COSType.body(11.5)).foregroundStyle(COSPalette.amber).lineLimit(2)
            } else if state.showsReply, let excerpt = WorkBoardSessionCard.excerpt(receipt: receipt, session: card.activity.session) {
                Text(excerpt).font(COSType.body(11.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
                    .padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(COSPalette.line).frame(width: 2) }
            } else if !state.showsReply, !receipt.detail.isEmpty {
                Text(receipt.detail).font(COSType.body(11.5)).foregroundStyle(state == .attention ? COSPalette.danger : COSPalette.muted).lineLimit(2)
            }
            HStack(spacing: 6) {
                Button(openWithPlatformTitle(card)) { openCardAndPlatform(card, held: held) }
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                if receipt.acknowledgeable && state.offersAcknowledge {
                    Button(WorkHandoffView.acknowledgeTitle(receipt)) { handoffStore.markReviewed(receiptID: receipt.id) }
                        .buttonStyle(COSQuietButtonStyle()).controlSize(.small).disabled(handoffStore.busy)
                }
            }
        }.padding(12).frame(width: WorkBoardSessionCard.cardWidth, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(state.tint.opacity(0.4)))
    }

    /// The task Open selects: the one asking, otherwise the first one this session holds, otherwise the card itself.
    private func sessionTask(_ card: WorkBoardSessionCard, held: [WorkTracking]) -> WorkWorkspaceItem {
        let asking = held.first(where: \.asksForYou) ?? held.first
        if let asking, let item = board.item(sourceID: asking.receipt.workID) { return item }
        return card.item
    }

    /// The live check drops after 45 seconds. The receipt still names the provider and the session, so the button keeps both.
    private func platformSession(_ card: WorkBoardSessionCard) -> WorkSession? {
        card.activity.session ?? WorkHandoffStore.rememberedSession(for: card.activity.receipt)
    }

    private func openWithPlatformTitle(_ card: WorkBoardSessionCard) -> String {
        let base = card.item.review != nil ? "Open review" : "Open card"
        guard let provider = platformSession(card)?.provider, !provider.isEmpty else { return base }
        let name: String
        switch provider {
        case "claude": name = "Claude"
        case "codex": name = "Codex"
        case "cursor": name = "Cursor"
        default: name = WorkHandoffStore.providerName(provider)
        }
        return base + " and " + name
    }

    /// The card stays on Work. The provider app comes forward with the session the receipt names.
    private func openCardAndPlatform(_ card: WorkBoardSessionCard, held: [WorkTracking]) {
        select(sessionTask(card, held: held))
        if let session = platformSession(card) { onOpenPlatform(session) }
    }

    /// One task on a session card. It is a board card: tap opens it, the menu moves it, and a drag lands on a column.
    private func heldTaskRow(_ tracking: WorkTracking) -> some View {
        let item = board.item(sourceID: tracking.receipt.workID)
        let stage = item?.task.map { WorkBoardStage.stage(for: $0).title } ?? (item?.review != nil ? "Review" : "")
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                WorkTrackingDot(phase: tracking.phase, tint: tracking.tint)
                Text(inlineTitle(item?.title ?? tracking.receipt.workTitle)).font(COSType.body(12)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                Text(tracking.shortLabel + (stage.isEmpty ? "" : " · " + stage)).font(COSType.mono(10.5)).foregroundStyle(tracking.tint)
                    .lineLimit(1).fixedSize()
            }.contentShape(Rectangle())
                .onTapGesture { if let item { select(item) } }
                .help(item == nil ? "This task is not on this board" : "Open this task. Drag it to a column to move it.")
            if let task = item?.task { stageMenu(task) }
        }
        .modifier(SessionTaskDrag(id: item?.task == nil ? nil : item?.id))
    }

    /// 0.5.247 (3A): the newest automatic move, over the columns (WorkLatestMoveStrip observes the tracker).
    @ViewBuilder private var latestMoveStrip: some View {
        if let tracker = model.workTracker {
            WorkLatestMoveStrip(tracker: tracker, store: handoffStore, lookup: { workID in
                board.item(sourceID: workID).map { ($0.title, $0.task.map { WorkBoardStage.stage(for: $0).rawValue }) }
            }, onUndo: { receiptID, eventID in undoMove(receiptID, eventID) })
        }
    }

    private func undoMove(_ receiptID: String, _ eventID: String) {
        guard let tracker = model.workTracker else { return }
        state.mutationError = nil
        Task { if let problem = await tracker.undo(receiptID: receiptID, eventID: eventID) { state.mutationError = problem } }
    }

    private func startWorkTarget(empty: Bool, compact: Bool) -> some View {
        VStack(spacing: 6) {
            Text("Start work").font(COSType.body(12.5, weight: .semibold))
            if startFileHover {
                Text(WorkCardFiles.startTileRefusal)
                    .font(COSType.body(11)).foregroundStyle(COSPalette.amber).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else if !compact {
                Text(empty ? "Drop a card here to put a session on it. Only sessions Work sent are shown in this row."
                           : "Drop a card here to put a session on it")
                    .font(COSType.body(11)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }.foregroundStyle(COSPalette.accent).padding(12).frame(width: WorkBoardSessionCard.targetWidth).frame(minHeight: compact ? 40 : 96)
            .background(COSPalette.gold.opacity(startDropTargeted ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.gold.opacity(startDropTargeted ? 1 : 0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .accessibilityLabel("Start work drop target")
            .accessibilityHint("Drop a board card here, or use Start work in a card's context menu")
    }

    private func boardColumn(_ stage: WorkBoardStage, pass: WorkBoardPass) -> some View {
        let board = self.board
        _ = board.visible(scope: state.scope, domain: state.domain, query: "")
        let all = board.column(stage)
        // 0.5.259: a search keeps only its matches; Order sorts what is left.
        let kept = WorkSearch.kept(all, pass.search)
        let cards = WorkCardDating.sorted(kept, id: \.id, order: pass.order, dates: pass.dates)
        let targeted = columnTarget == stage
        // One decision for the header, the list, and a card face. The list is a scroll view, so a drop on the
        // column behind it never arrived. No size is measured here.
        let apply: (ColumnDragTrack) -> Void = { next in
            columnDrag = next
            columnTarget = next.stage.flatMap { WorkBoardStage(rawValue: $0) }
        }
        let mark: (Bool) -> Void = { over in
            var next = columnDrag
            if over { next.enter(stage.rawValue) } else { next.exit(stage.rawValue) }
            apply(next)
        }
        let takeColumn: () -> Bool = {
            var next = columnDrag
            let won = next.take(stage.rawValue)
            columnDrag = next
            return won
        }
        let finishColumn: () -> Void = {
            var next = columnDrag
            next.finish(stage.rawValue)
            apply(next)
        }
        let accept: (String) -> Void = { id in
            guard let task = WorkWorkspaceProjection.stageDrop(id: id, items: items, to: stage) else { return }
            guard canChangeStage(task) else {
                state.mutationError = model.workBoardWritable || handoffStore.isolated
                    ? "That card can't move right now. Wait for the current change to finish, or refresh."
                    : "Board is read-only. Stage changes need the connected Work service."
                return
            }
            // Completing is the one stage change that asks first: a drag is easy to mistake.
            if stage == .complete { state.pendingComplete = task } else { move(task, to: stage) }
        }
        let columnDrop = WorkBoardDropDelegate(target: .column, onCard: accept, onTargeted: mark, onRefusedFiles: { cardFiles.flashBoard() }, onTake: takeColumn, onFinish: finishColumn)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(stage.title).font(COSType.body(13, weight: .semibold))
                    Spacer()
                    Text(WorkSearch.countLabel(kept: cards.count, of: all.count, active: pass.search.active)).font(COSType.mono(11)).foregroundStyle(COSPalette.muted)
                }.padding(.horizontal, 12).padding(.top, 13)
                Text(stage.subtitle).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 13)
                Divider().overlay(COSPalette.line)
            }
            .contentShape(Rectangle())
            .onDrop(of: WorkCardFiles.boardDropTypes, delegate: columnDrop)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if cards.isEmpty {
                        Text(targeted ? "Drop to move here" : WorkSearch.emptyColumn(stage, key: pass.key, active: pass.search.active, pending: pass.pending))
                            .font(COSType.body(12)).foregroundStyle(COSPalette.muted).padding(12)
                    }
                    ForEach(cards) { item in
                        boardCard(item, hit: pass.search.hits[item.id], dateLine: WorkCardDating.line(pass.dates[item.id], order: pass.order, now: pass.now, calendar: .current),
                                  acceptColumn: accept, markColumn: mark, takeColumn: takeColumn, finishColumn: finishColumn)
                    }
                }.padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: WorkCardFiles.boardDropTypes, delegate: columnDrop)
        }.frame(width: 234).frame(maxHeight: .infinity, alignment: .top)
            .background(targeted ? COSPalette.gold.opacity(0.08) : COSPalette.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(targeted ? COSPalette.gold.opacity(0.8) : COSPalette.line))
    }

    private func boardCard(_ item: WorkWorkspaceItem, hit: WorkSearchHit? = nil, dateLine: String? = nil, acceptColumn: @escaping (String) -> Void, markColumn: @escaping (Bool) -> Void, takeColumn: @escaping () -> Bool, finishColumn: @escaping () -> Void) -> some View {
        let handoff = item.activity.map { WorkHandoffState($0) }
        let running = handoff == .running
        let tracking = item.tracking
        let stageRaw = item.task.map { WorkBoardStage.stage(for: $0).rawValue }
        let autoMove = tracking?.undoableMove(currentStage: stageRaw)
        let asking = tracking?.asksForYou == true
        return VStack(alignment: .leading, spacing: 0) {
            cardTapArea(item, handoff: handoff, running: running, hit: hit)
            // Outside the tap area: its Undo is its own control, not part of the card's single action.
            if let autoMove, let tracking { cardWhyLine(tracking, autoMove).padding(.horizontal, 12).padding(.bottom, 10) }
            if let task = item.task {
                ForEach(task.meetingRefs.prefix(2)) { meeting in
                    Button { onOpenMeeting(meeting) } label: {
                        Label(meeting.title, systemImage: "calendar").font(COSType.body(10.5)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(COSPalette.accent).padding(.horizontal, 12).padding(.bottom, 10)
                }
                // 0.5.259: under the card's source, only while ordering by date.
                if let dateLine {
                    Text(dateLine).font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted).frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 12).padding(.bottom, 9).padding(.top, task.meetingRefs.isEmpty ? -2 : -4)
                }
                Divider().overlay(COSPalette.line)
                // 0.5.254 (card face A): the file count sits in the footer that holds the stage menu.
                HStack { stageMenu(task); if !item.completed { Button("Start work") { openStart(item) }.buttonStyle(COSTextButtonStyle()) }; Spacer(minLength: 0); WorkCardFilesBadge(files: cardFiles, workID: item.sourceID) }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                WorkCardFlashView(files: cardFiles, workID: item.sourceID)
            }
        }.background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Self.cardStroke(asking: asking, running: running, moved: autoMove != nil, matched: hit != nil)))
            .overlay(alignment: .leading) { cardRule(asking: asking, running: running) }
            // 0.5.254: the whole card takes files (on the card itself; "Add to card" is drawn over it, never the target).
            // A work-card drag on this face is the column's move. The Files box never gets that callback.
            .modifier(WorkCardFileDrop(files: cardFiles, source: item.task.map(WorkSource.taskSnapshot), onColumnCard: acceptColumn, onColumnHover: markColumn, onTake: takeColumn, onFinish: finishColumn))
            .draggable(WorkCardDrag(id: item.id)) {
                Text(inlineTitle(item.title)).font(COSType.body(12, weight: .medium)).lineLimit(3).padding(10).frame(width: 210, alignment: .leading)
                    .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 7))
            }
            .contextMenu {
                if !item.completed { Button("Start work…") { openStart(item) } }
                if let task = item.task {
                    Divider()
                    ForEach(WorkBoardStage.allCases) { stage in
                        Button(stage == .complete ? "Mark complete" : "Move to " + stage.title) { move(task, to: stage) }
                            .disabled(WorkBoardStage.stage(for: task) == stage || !canChangeStage(task))
                    }
                }
            }
    }

    /// 0.5.246: a tap gesture, not a Button. A Button swallows the drag (measured with real mouse drags: a
    /// Button-wrapped card never dropped; a tap-gesture card dropped every time), so cards could not be dragged.
    private func cardTapArea(_ item: WorkWorkspaceItem, handoff: WorkHandoffState?, running: Bool, hit: WorkSearchHit? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(WorkSearch.underlined(inlineTitle(item.title), words: hit?.words ?? [])).font(COSType.body(13, weight: .medium)).multilineTextAlignment(.leading).lineLimit(5)
                cardStatus(item, handoff: handoff, running: running)
                if let task = item.task, task.meetingRefs.isEmpty {
                    Text(task.source.isEmpty ? "No meeting linked" : task.source).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.onTapGesture { select(item) }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityAction { select(item) }
            .help(item.title)
    }
    /// 0.5.247: what the session reported says more than the live handoff line; otherwise the live line wins, and a
    /// tracked handoff with no live line still says where it stands.
    @ViewBuilder private func cardStatus(_ item: WorkWorkspaceItem, handoff: WorkHandoffState?, running: Bool) -> some View {
        if let tracking = item.tracking, tracking.reported {
            WorkTrackingLine(tracking: tracking)
            if tracking.asksForYou, let evidence = tracking.evidence {
                Text("\u{201C}" + evidence + "\u{201D}").font(COSType.body(10.5)).italic().lineLimit(3)
            }
        } else if let activity = item.activity, let handoff, handoff != .settled {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WorkLiveDot(color: handoff.tint, live: running).scaleEffect(0.8)
                Text(handoff.label + " · " + (activity.session?.title ?? activity.receipt.sessionTitle))
                    .font(COSType.body(10.5, weight: .semibold)).foregroundStyle(handoff.tint).lineLimit(2)
            }
        } else if let tracking = item.tracking { WorkTrackingLine(tracking: tracking) }
        else if item.inProgress { Label("Session running", systemImage: "clock").font(COSType.body(10.5)).foregroundStyle(COSPalette.accent) }
        else if item.needsAttention { Label("Needs attention", systemImage: "circle.dashed").font(COSType.body(10.5)).foregroundStyle(COSPalette.accent) }
    }
    /// "Moved here at 9:52: the session reported done." with Undo, while the card sits where COS put it.
    private func cardWhyLine(_ tracking: WorkTracking, _ move: WorkProgressEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(WorkTracking.whyLine(move)).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(3)
            if model.workTracker != nil {
                Button("Undo") { undoMove(tracking.receipt.id, move.id) }.buttonStyle(COSTextButtonStyle()).controlSize(.small)
                    .help("Move it back to " + WorkProgress.stageTitle(move.fromStage ?? "") + ". COS will not move it again for this handoff.")
            }
        }
    }
    nonisolated static func cardStroke(asking: Bool, running: Bool, moved: Bool, matched: Bool = false) -> Color {
        asking ? COSPalette.amber.opacity(0.6) : running ? COSPalette.green.opacity(0.6) : moved ? COSPalette.gold.opacity(0.45)
            : matched ? COSPalette.gold.opacity(0.5) : COSPalette.line
    }
    @ViewBuilder private func cardRule(asking: Bool, running: Bool) -> some View {
        if asking || running { Rectangle().fill(asking ? COSPalette.amber : COSPalette.green).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)) }
    }

    private func canChangeStage(_ task: TaskRow) -> Bool {
        WorkWorkspaceProjection.canChangeStage(task, isolated: handoffStore.isolated, writable: model.workBoardWritable, busy: state.mutationBusy)
    }

    private func openStart(_ item: WorkWorkspaceItem) {
        guard item.task != nil, !item.completed else { return }
        state.startItemID = item.id
    }

    @ViewBuilder private var startOverlay: some View {
        if let id = state.startItemID {
            if let item = board.item(id: id), let task = item.task, !item.completed || state.startSending {
                GeometryReader { box in
                    ZStack {
                        // A tap outside closes it, except while a send is being handed over.
                        Color.black.opacity(0.28).contentShape(Rectangle()).onTapGesture { if !state.startSending { state.startItemID = nil } }
                        WorkStartSheet(store: handoffStore, files: handoffStore.cardFiles, title: (task.text.isEmpty ? task.title : task.text).replacingOccurrences(of: "**", with: ""),
                                       subtitle: domainLabel(task.domain) + " · " + WorkBoardStage.stage(for: task).title,
                                       source: .taskSnapshot(task), isPreview: handoffStore.isolated, maxHeight: max(260, box.size.height - 48),
                                       sending: $state.startSending, onOpenSession: { sessionID in state.startItemID = nil; onOpenSession(sessionID) },
                                       onClose: { state.startItemID = nil })
                    }.frame(width: box.size.width, height: box.size.height)
                }
            } else {
                // The card is gone (completed or removed on refresh): nothing to confirm.
                Color.clear.task { state.startItemID = nil }
            }
        }
    }

    private func stageMenu(_ task: TaskRow) -> some View {
        Menu {
            ForEach(WorkBoardStage.allCases) { stage in
                Button(stage == .complete ? "Mark complete" : "Move to " + stage.title) { move(task, to: stage) }
                    .disabled(WorkBoardStage.stage(for: task) == stage)
            }
        } label: { COSMenuLabel(title: WorkBoardStage.stage(for: task).title, icon: "arrow.left.arrow.right") }
            .cosMenu().fixedSize()
            .disabled(!canChangeStage(task))
            .help("Change task stage")
    }

    private func move(_ task: TaskRow, to stage: WorkBoardStage) {
        state.mutationError = nil
        if handoffStore.isolated {
            if let index = handoffStore.previewTasks.firstIndex(where: { $0.id == task.id }) {
                handoffStore.previewTasks[index].completed = stage == .complete
                if stage != .complete { state.previewStages[task.id] = stage.rawValue }
            }
            return
        }
        state.mutationBusy = true
        Task {
            defer { state.mutationBusy = false }
            do { try await model.setWorkStage(task, stage: stage.rawValue) }
            catch { state.mutationError = error.localizedDescription }
        }
    }

    private func sourceMeetings(_ task: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Source meetings").font(COSType.body(12, weight: .semibold))
                Spacer()
                Button("Link a meeting") {
                    state.linkTarget = task; state.meetingPicker = true; state.mutationError = nil
                    Task { await model.loadLibraryMeetings() }
                }.buttonStyle(COSQuietButtonStyle())
                    .disabled(handoffStore.isolated || !model.workBoardWritable || state.mutationBusy || task.workRevision.isEmpty || task.workMetadataError != nil)
            }
            if task.meetingRefs.isEmpty { Text("No confirmed meeting link. Attach a saved meeting to connect its tasks and sessions.").font(COSType.body(12)).foregroundStyle(COSPalette.muted) }
            ForEach(task.meetingRefs) { meeting in
                Button { onOpenMeeting(meeting) } label: { Label(meeting.title, systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(COSQuietButtonStyle())
                if !handoffStore.isolated { meetingPeople(meeting) }
            }
        }
    }

    /// Who the meeting involved (attendees and action-item owners). A name opens their card: their items from
    /// this meeting and where each stands, their other asks in Intake, and open tasks that mention them.
    @ViewBuilder private func meetingPeople(_ meeting: WorkMeetingReference) -> some View {
        if let people = model.workMeetingPeople[meeting.recordId] {
            if !people.people.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("People").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                        ForEach(people.people, id: \.self) { name in
                            let key = meeting.recordId + "|" + name, open = state.personFocus == key, count = people.items[name]?.count ?? 0
                            Button { state.personFocus = open ? nil : key } label: {
                                Text(name + (count > 0 ? " · \(count)" : "")).font(COSType.body(11, weight: open ? .semibold : .regular))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(open ? COSPalette.gold : COSPalette.line))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help(count > 0 ? "\(count) item\(count == 1 ? "" : "s") from this meeting" : "Attended")
                        }
                    }.padding(.vertical, 2)
                }
                if let focus = state.personFocus, focus.hasPrefix(meeting.recordId + "|") {
                    personCard(WorkPersonNetwork(name: String(focus.dropFirst(meeting.recordId.count + 1)), meeting: people,
                                                 intake: model.workIntake, tasks: model.workTasks), meeting: meeting)
                }
            }
        } else if model.workMeetingPeopleFailed.contains(meeting.recordId) {
            HStack(spacing: 8) {
                Text("People for this meeting could not be read.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                Button("Try again") { Task { await model.retryWorkMeetingPeople(meeting) } }
                    .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
            }
        } else {
            ProgressView().controlSize(.small).task { await model.loadWorkMeetingPeople(meeting) }
        }
    }

    private func personCard(_ person: WorkPersonNetwork, meeting: WorkMeetingReference) -> some View {
        let first = person.name.split(separator: " ").first.map(String.init) ?? person.name
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(person.name).font(COSType.body(13, weight: .semibold))
                Spacer()
                Button { state.personFocus = nil } label: { Image(systemName: "xmark") }.buttonStyle(COSIconButtonStyle()).help("Close")
            }
            if person.meetingItems.isEmpty {
                Text("No action items for \(first) in this meeting.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            } else {
                Text("From this meeting").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                ForEach(person.meetingItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).font(COSType.body(12)).fixedSize(horizontal: false, vertical: true)
                        switch item.state {
                        case .onBoard(let title): Text("On the board: \(title)").font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(1)
                        case .inIntake(let id): intakeActions(id)
                        case .untracked: Text("Not tracked").font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                        }
                    }
                }
            }
            if !person.otherAsks.isEmpty {
                Text("\(first)'s other open asks").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                ForEach(person.otherAsks.prefix(5)) { ask in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ask.text).font(COSType.body(12)).lineLimit(2)
                        HStack { Text(ask.meeting.title + (ask.meetingDate.isEmpty ? "" : " · " + ask.meetingDate)).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(1); Spacer(); intakeActions(ask.id) }
                    }
                }
            }
            if !person.mentions.isEmpty {
                Text("Open tasks mentioning \(first)").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                ForEach(person.mentions) { task in
                    Button {
                        // Same bookkeeping as select(): Work restores its selection from the handoff store.
                        let id = WorkSource.taskSnapshot(task).id
                        state.domain = nil; state.scope = .all; state.meetingPicker = false; reviewStore.selectedMeeting = nil
                        state.selectedID = id; handoffStore.selectedWorkID = id
                    } label: { Label(task.title, systemImage: "checklist").font(COSType.body(12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                }
            }
        }.padding(12).background(COSPalette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.line))
    }

    @ViewBuilder private func intakeActions(_ id: String) -> some View {
        if let item = model.workIntake.items.first(where: { $0.id == id }) {
            let busy = model.workIntakeBusyIDs.contains(id)
            HStack(spacing: 8) {
                Text("In Intake").font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                Button("Make it mine") { Task { await model.resolveWorkIntake(item, accept: true) } }
                    .buttonStyle(COSQuietButtonStyle()).disabled(busy || !model.workIntake.cardCreation)
                Button("Dismiss") { Task { await model.resolveWorkIntake(item, accept: false) } }
                    .buttonStyle(COSTextButtonStyle()).disabled(busy)
            }
        }
    }

    private func chooseMeeting(_ meeting: LibraryMeeting) {
        guard let target = state.linkTarget else { onReviewMeeting(meeting); return }
        guard !state.mutationBusy else { return }
        guard let reference = WorkMeetingReference(meeting: meeting) else {
            state.mutationError = "This meeting has no complete saved reference. Refresh the meeting library before linking."
            return
        }
        state.mutationBusy = true; state.mutationError = nil
        Task {
            defer { state.mutationBusy = false }
            do {
                try await model.linkWorkMeeting(target, meeting: reference)
                if state.linkTarget?.id == target.id && state.linkTarget?.domain == target.domain {
                    state.meetingPicker = false; state.linkTarget = nil
                }
            } catch { state.mutationError = error.localizedDescription }
        }
    }

    private var workList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 0.5.259 (QA C7): the board's search box and word rule, and ⌘F. Focus never asks Jev.
            WorkBoardSearchField(prompt: "Search work", query: $state.query, focusRequest: state.searchFocusRequest, onKey: { _ in false })
                .padding(12)
                .background {
                    Button("Search the list") { state.searchFocusRequest &+= 1 }.keyboardShortcut("f", modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            HStack {
                Text("\(visible.count) shown").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                Spacer()
                if model.workTasksLoading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 16).padding(.bottom, 8)
            if let error = model.workTasksError { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger).padding(12) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        Text(model.workTasksLoading ? "Loading work…" : "No work matches this view.")
                            .font(COSType.body(13)).foregroundStyle(COSPalette.muted).padding(18)
                    }
                    ForEach(visible) { item in
                        Button { select(item) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(inlineTitle(item.title)).font(COSType.body(13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                Text(domainLabel(item.domain) + " · " + item.subtitle).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                                if let activity = item.activity {
                                    // Same words and dot as the board's session row.
                                    let handoff = WorkHandoffState(activity)
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        WorkLiveDot(color: handoff.tint, live: handoff == .running).scaleEffect(0.8)
                                        Text(handoff == .settled ? activity.title : handoff.label).font(COSType.body(10.5, weight: .semibold)).foregroundStyle(handoff.tint)
                                    }
                                    Text(activity.session?.title ?? activity.receipt.sessionTitle).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
                                } else if item.inProgress { Label("In progress", systemImage: "clock").font(COSType.body(10)).foregroundStyle(COSPalette.accent) }
                                else if item.needsAttention { Label("Needs attention", systemImage: "circle.fill").font(COSType.body(10)).foregroundStyle(COSPalette.accent) }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(state.selectedID == item.id ? COSPalette.raised : Color.clear)
                            .accessibilityAddTraits(state.selectedID == item.id ? .isSelected : [])
                        Divider().overlay(COSPalette.line)
                    }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top).background(COSPalette.raised.opacity(0.3))
    }

    @ViewBuilder private var detailPane: some View {
        if state.meetingPicker {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a saved meeting").font(COSType.display(23, weight: .medium)).padding(.horizontal, 18)
                Text("Browse older months or search. Selecting a meeting does not start an agent.").font(COSType.body(12)).foregroundStyle(COSPalette.muted).padding(.horizontal, 18)
                if let target = state.linkTarget {
                    Text("Link to: " + target.text).font(COSType.body(12, weight: .medium)).padding(.horizontal, 18)
                }
                MeetingLibraryBody(model: model, selectionOnly: true, onOpen: chooseMeeting)
                    .disabled(state.mutationBusy)
            }.padding(.top, 18)
        } else if let meeting = reviewStore.selectedMeeting {
            ScrollView { meetingIntake(meeting).padding(22) }
        } else if let item = selected {
            // 0.5.244 (2A): the Agent workspace is pinned beside the item when there is room, else right under its title.
            // The width is read only when it crosses 760 or 1,100. A GeometryReader here rebuilt the text field on
            // every pixel of a resize.
            Group {
                if detailSpan.sideBySide {
                    HStack(alignment: .top, spacing: 0) {
                        detailScroll(item, workspace: false).frame(maxWidth: .infinity)
                        Divider().overlay(COSPalette.line)
                        ScrollView { itemWorkspace(item).padding(18) }
                            .frame(width: detailSpan.roomy ? 452 : 400).frame(maxHeight: .infinity).background(COSPalette.card.opacity(0.55))
                    }
                } else {
                    detailScroll(item, workspace: true)
                }
            }.id(item.id)
            .onGeometryChange(for: DetailSpan.self) { proxy in
                DetailSpan(sideBySide: proxy.size.width >= 760, roomy: proxy.size.width >= 1100)
            } action: { next in
                if !detailSpanSeen {
                    detailSpanSeen = true
                    detailSpan = next
                    return
                }
                detailSpanCommit.schedule(current: detailSpan, next: next) { detailSpan = $0 }
            }
            .onDisappear { detailSpanCommit.cancel() }
        } else if let id = state.selectedID, !handoffStore.receipts(for: id).isEmpty {
            ScrollView { receiptFallback(id).padding(22) }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(state.selectedID == nil ? "Choose what to work on" : "This work is not currently available").font(COSType.display(25, weight: .medium))
                Text(state.selectedID == nil ? "Select a task to see its goal, source, agent destination, and history. Or review a saved meeting for follow-up." : "Refresh or choose another item. The original task or meeting has not been recreated.").font(COSType.body(13)).foregroundStyle(COSPalette.muted)
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func detailScroll(_ item: WorkWorkspaceItem, workspace: Bool) -> some View {
        let blocks = item.review.map(reviewBlocks) ?? []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                itemHeader(item)
                if workspace {
                    itemWorkspace(item).padding(16)
                        .background(COSPalette.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line))
                }
                if let review = item.review { reviewNotes(review) }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    COSMarkdownBlockView(block: block)
                }
                if let review = item.review { reviewTail(review) }
                if let task = item.task { taskBody(task) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }
    }

    private func reviewBlocks(_ review: WorkReviewRecord) -> [COSMarkdownBlock] {
        let blocks = COSMarkdownCache.blocks(review.markdown)
        let long = review.markdown.count > Self.foldedReviewCharacters
        let open = !long || state.expandedReviews.contains(review.id)
        return open ? blocks : Array(blocks.prefix(8))
    }

    @ViewBuilder private func itemHeader(_ item: WorkWorkspaceItem) -> some View {
        if let task = item.task { taskHeader(task) } else if let review = item.review { reviewHeader(review) }
    }
    @ViewBuilder private func itemWorkspace(_ item: WorkWorkspaceItem) -> some View {
        if let task = item.task {
            WorkHandoffView(store: handoffStore, source: .taskSnapshot(task), isPreview: handoffStore.isolated, onOpenSession: onOpenSession,
                            currentStage: WorkBoardStage.stage(for: task).rawValue,
                            onUndoMove: model.workTracker == nil ? nil : { receiptID, eventID in undoMove(receiptID, eventID) },
                            onMarkComplete: task.checked || !canChangeStage(task) ? nil : { move(task, to: .complete) },
                            onSentBack: { if [.built, .qa].contains(WorkBoardStage.stage(for: task)) { move(task, to: .draft) } })
                .id(task.workSourceID)
        } else if let review = item.review {
            reviewWorkspace(review)
        }
    }

    private func taskHeader(_ task: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(inlineTitle(task.text.isEmpty ? task.title : task.text)).font(COSType.display(24, weight: .medium)).textSelection(.enabled)
                Spacer(minLength: 8)
                if handoffStore.isolated {
                    Button(task.checked ? "Reopen sample" : "Complete sample") {
                        if let index = handoffStore.previewTasks.firstIndex(where: { $0.id == task.id }) { handoffStore.previewTasks[index].completed.toggle() }
                    }.buttonStyle(COSQuietButtonStyle())
                } else {
                    Button("Edit task") { onEditTask(task) }.buttonStyle(COSQuietButtonStyle())
                    if !task.checked, let item = items.first(where: { $0.task?.id == task.id && $0.domain == task.domain }) {
                        Button("Start work") { openStart(item) }.buttonStyle(COSQuietButtonStyle())
                    }
                }
            }
            Text(domainLabel(task.domain) + " · " + (task.checked ? "Completed task" : WorkBoardStage.stage(for: task).title))
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            HStack {
                stageMenu(task)
                if state.mutationBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if model.workBatchAvailable && !task.checked { WorkDelegateControl(model: model, task: task) }
            Text([task.createdAt.isEmpty ? "Created date unknown" : "Created " + task.createdAt,
                  "Owner: " + (task.owner.isEmpty ? "Unknown" : task.owner), task.dueDate.isEmpty ? "" : "Due " + task.dueDate].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            ForEach(handoffStore.confirmedSessionCards.keys.filter { handoffStore.confirmedSessionCards[$0]?.workID == task.workSourceID }.sorted(), id: \.self) { sessionID in
                Button("Open linked session") { onOpenSession(sessionID) }.buttonStyle(COSTextButtonStyle())
            }
            if let error = task.workMetadataError { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger) }
        }
    }

    private func taskBody(_ task: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            sourceMeetings(task)
            fact("Done when", task.doneWhen.isEmpty ? "No finish line recorded. Use Edit task to define one." : task.doneWhen)
            if !task.source.isEmpty { fact("Source", task.source) }
            if !task.runAt.isEmpty { fact("Scheduled", task.runAt) }
            Text("Task editing, scheduling, and completion stay attached to the original task. Agent output does not change its completion state.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
        }
    }

    private func meetingIntake(_ meeting: LibraryMeeting) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review follow-up").font(COSType.display(25, weight: .medium))
            Text(meeting.title).font(COSType.body(16, weight: .semibold))
            Text(meeting.date + " · " + meeting.domainLabel).font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            Text("Review the canonical saved meeting for decisions and possible next steps. This does not create, complete, or send tasks automatically.")
                .font(COSType.body(13)).foregroundStyle(COSPalette.muted)
            if reviewStore.available {
                COSDropdown("Review model", selection: $state.reviewModelID,
                            options: [COSDropdownOption("", "Choose a model", placeholder: true)]
                                + reviewStore.models.map { COSDropdownOption($0.id, $0.title, note: $0.available ? nil : "unavailable", muted: !$0.available) })
                if let reason = reviewStore.models.first(where: { $0.id == state.reviewModelID })?.reason { Text(reason).font(COSType.body(11)).foregroundStyle(COSPalette.muted) }
                Button(reviewStore.busy ? "Reviewing…" : "Review this meeting") {
                    Task {
                        if let review = await state.requestReview(meeting: meeting, modelID: state.reviewModelID, store: reviewStore) {
                            handoffStore.selectedWorkID = review.source.id
                        }
                    }
                }.buttonStyle(COSPrimaryButtonStyle())
                    .disabled(reviewStore.busy || reviewStore.models.first(where: { $0.id == state.reviewModelID })?.available != true)
            } else {
                Text("Meeting review is unavailable on this server. Your saved meetings and tasks remain available.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                Button("Check availability") { Task { await reviewStore.refresh() } }.buttonStyle(COSQuietButtonStyle())
            }
            if let error = reviewStore.error { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger) }
            ForEach(reviewStore.reviews.filter { $0.descriptor["recordId"] == meeting.recordId && !meeting.recordId.isEmpty }) { review in
                Button("Open recorded review · \(review.status)") {
                    state.selectedID = "meeting-review:" + review.id; handoffStore.selectedWorkID = review.source.id; reviewStore.selectedMeeting = nil
                }.buttonStyle(COSQuietButtonStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewHeader(_ review: WorkReviewRecord) -> some View {
        let title = reviewStore.displayTitle(for: review)
        return VStack(alignment: .leading, spacing: 10) {
            if editingReviewID == review.id {
                TextField("Review title", text: $reviewTitleDraft)
                    .font(COSType.display(25, weight: .medium))
                    .textFieldStyle(.plain)
                    .focused($reviewTitleFocused)
                    .onSubmit { commitReviewTitle(review) }
                    .onExitCommand { editingReviewID = nil; reviewTitleFocused = false }
                    .onChange(of: reviewTitleFocused) { _, focused in
                        if !focused, editingReviewID == review.id { commitReviewTitle(review) }
                    }
            } else {
                Button {
                    reviewTitleDraft = title
                    editingReviewID = review.id
                    reviewTitleFocused = true
                } label: {
                    Text(inlineTitle(title)).font(COSType.display(25, weight: .medium)).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                    .help("Rename this review. The name is the subject of the work you send.")
            }
            Text("Meeting review · " + review.status.replacingOccurrences(of: "_", with: " ") + " · " + domainLabel(review.domain))
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            if let reference = WorkMeetingReference(.object(review.descriptor.merging(["recordId": review.canonicalMeetingId, "title": review.title]) { _, new in new }.mapValues { .string($0) })) {
                Button { onOpenMeeting(reference) } label: { Label("Open source meeting", systemImage: "calendar") }.buttonStyle(COSQuietButtonStyle())
            }
        }
    }

    /// Reviews longer than this open folded, with Show the full review.
    private static let foldedReviewCharacters = 1_400

    private func reviewNotes(_ review: WorkReviewRecord) -> some View {
        let notes = (review.inputTruncated ? ["The source was too long to include in full. Review may omit details."] : []) + review.contextWarnings
        let notesOpen = state.expandedNotes.contains(review.id)
        return VStack(alignment: .leading, spacing: 16) {
            if let error = review.error { Text(error).foregroundStyle(COSPalette.danger) }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if notesOpen { state.expandedNotes.remove(review.id) } else { state.expandedNotes.insert(review.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("\(notes.count) note\(notes.count == 1 ? "" : "s") on this review")
                            Text(notesOpen ? "Hide" : "Show").underline()
                        }.font(COSType.body(12)).foregroundStyle(COSPalette.danger).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if notesOpen {
                        ForEach(notes, id: \.self) { note in Text(note).font(COSType.body(12)).foregroundStyle(COSPalette.danger).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            if !handoffStore.isolated {
                Text("This review also appears in COS conversation history.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
        }
    }

    private func reviewTail(_ review: WorkReviewRecord) -> some View {
        let long = review.markdown.count > Self.foldedReviewCharacters
        let open = !long || state.expandedReviews.contains(review.id)
        return VStack(alignment: .leading, spacing: 16) {
            if long {
                Button(open ? "Show less" : "Show the full review") {
                    if open { state.expandedReviews.remove(review.id) } else { state.expandedReviews.insert(review.id) }
                }.buttonStyle(COSQuietButtonStyle())
            }
            if !review.taskLinks.isEmpty {
                Text("Possible existing task links").font(COSType.display(18, weight: .medium))
                Text("Suggestions only. No task has been created or completed.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                ForEach(Array(review.taskLinks.enumerated()), id: \.offset) { _, link in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.title).font(COSType.body(12, weight: .semibold))
                        Text(link.evidence).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                }
            }
        }
    }

    @ViewBuilder private func reviewWorkspace(_ review: WorkReviewRecord) -> some View {
        if review.canPrepare && (handoffStore.isolated || (reviewStore.available && reviewStore.error == nil)) {
            WorkHandoffView(store: handoffStore, source: reviewStore.source(for: review), isPreview: handoffStore.isolated, onOpenSession: onOpenSession,
                validateBeforeSend: {
                    if handoffStore.isolated { return true }
                    return await reviewStore.validateForHandoff(review)
                })
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Agent workspace").font(COSType.display(20, weight: .medium))
                if let error = reviewStore.error { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger) }
                Text(review.canPrepare ? "Refresh to verify this source before preparing work." : "Agent preparation becomes available after this review finishes successfully.").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                Button("Check review status") { Task { await reviewStore.refresh() } }.buttonStyle(COSQuietButtonStyle())
            }
        }
    }

    private func receiptFallback(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(handoffStore.receipts(for: id).first?.workTitle ?? "Saved work history").font(COSType.display(24, weight: .medium))
            Text("The original item is not in the current source inventory. Its saved handoffs remain here; no item has been recreated.").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            ForEach(handoffStore.receipts(for: id)) { receipt in
                Text(receipt.status.capitalized + " · " + receipt.detail).font(COSType.body(12))
                Text(receipt.prompt).font(COSType.body(12)).textSelection(.enabled)
                if let result = receipt.result { COSMarkdownView(text: result) }
                if let session = receipt.sessionID { Button("Open session") { onOpenSession(session) }.buttonStyle(COSQuietButtonStyle()) }
                Divider()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitReviewTitle(_ review: WorkReviewRecord) {
        let previous = reviewStore.displayTitle(for: review)
        let next = reviewTitleDraft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        editingReviewID = nil
        reviewTitleFocused = false
        guard !next.isEmpty, next != previous else { return }
        guard reviewStore.setTitle(next, for: review.id) else { editingReviewID = review.id; return }
        // The visible handoff is an explicit draft. Renaming a card never rewrites its approved text.
    }

    private func inlineTitle(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }

    private func fact(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
            Text(content).font(COSType.body(13)).textSelection(.enabled)
        }
    }
    private func domainLabel(_ domain: String) -> String { model.domainOptions.first { $0.name == domain }?.label ?? domain.replacingOccurrences(of: "_", with: " ").capitalized }
    private func select(_ item: WorkWorkspaceItem) {
        state.selectedID = item.id; state.meetingPicker = false; reviewStore.selectedMeeting = nil; handoffStore.selectedWorkID = item.sourceID
    }
    private func returnToList() { state.selectedID = nil; handoffStore.selectedWorkID = nil; state.meetingPicker = false; state.linkTarget = nil; reviewStore.selectedMeeting = nil }
    private func closePickerOrDetail() {
        if state.linkTarget != nil { state.meetingPicker = false; state.linkTarget = nil }
        else { returnToList() }
    }
}

/// TextEditor can consume SwiftUI's onExitCommand. This handler exists only while
/// an editor is mounted, and only intercepts Escape in its own Activity window.
struct WorkEditorEscapeHandler: NSViewRepresentable {
    var onEscape: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.action = onEscape
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard event.keyCode == 53, let coordinator,
                  let window = coordinator.view?.window, event.window === window else { return event }
            coordinator.action?()
            return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = onEscape }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var action: (() -> Void)?
    }
}

// MARK: - Work → Intake (server 6.57.0)
// Kept in this file on purpose: the app's source list is repeated in ten build and test scripts.

/// Inline markdown in task text (`**bold**` from meeting notes), as on the board.
fileprivate func intakeInlineText(_ value: String) -> AttributedString {
    (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
}

/// Work → Intake: what meetings produced that is not on the board yet (server 6.57.0).
///
/// Three groups, each answered in place, his own first:
/// - Review: his own items that need a look (from an older meeting, may not be a task, owner unclear).
///   "Keep as card" or "Skip"; the older-meeting ones can be skipped together after a confirm.
/// - Suggested links: an existing task probably worked on in a meeting. "Link" or "Dismiss".
/// - Asks from others: visible so Miles can take one on. An ask one of his recent sessions probably covers is
///   pulled to the top and names the session. "Make it mine" creates a card written "(from Name)".
/// Accepting writes on the server through the same task writer and locks as every other Work change.
struct WorkIntakeView: View {
    @ObservedObject var model: ControllerModel
    var domain: String? = nil
    var onOpenMeeting: (WorkMeetingReference) -> Void
    @State private var confirmSkipOlder = false
    @State private var catchUp = false
    @State private var expiredOpen = false
    @State private var groupIndex = 0
    @State private var keepingGroup = false
    @State private var sortStarted = Date()
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        let snapshot = model.workIntake.daily(catchUp: catchUp, domain: domain)
        let cards = WorkSortGroup.mentioned(model.workTasks, catchUp: catchUp, domain: domain)
        let groups = WorkSortGroup.groups(snapshot: snapshot, cards: cards)
        let selected = groups.isEmpty ? nil : groups[min(groupIndex, groups.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(catchUp ? "Catch up" : "Sort today").font(COSType.display(19, weight: .medium))
                Text(catchUp ? "Older items, at your pace" : "New since yesterday").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                Spacer()
                if model.workIntakeLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.loadWorkIntake() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(COSIconButtonStyle()).help("Refresh Intake")
            }.padding(.horizontal, 18).padding(.vertical, 12)
            HStack {
                Button("Today · \(model.workIntake.daily(catchUp: false, domain: domain).openCount + WorkSortGroup.mentioned(model.workTasks, catchUp: false, domain: domain).count) new") { catchUp = false; expiredOpen = false; groupIndex = 0 }.buttonStyle(COSQuietButtonStyle())
                Button("Catch up · \(model.workIntake.daily(catchUp: true, domain: domain).openCount + WorkSortGroup.mentioned(model.workTasks, catchUp: true, domain: domain).count)") { catchUp = true; expiredOpen = false; groupIndex = 0 }.buttonStyle(COSTextButtonStyle())
                Spacer()
                if model.workUndoBatch != nil { Button("Undo last decision") { Task { await model.undoWorkIntake() } }.buttonStyle(COSTextButtonStyle()) }
            }.padding(.horizontal, 18).padding(.bottom, 10)
            HStack {
                Button("Expired this week: \(model.workExpiredWeekly), \(model.workExpiredYours) yours") { expiredOpen.toggle(); Task { await model.loadWorkExpiry() } }.buttonStyle(COSTextButtonStyle())
                Text("Restore within 30 days").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }.padding(.horizontal, 18).padding(.bottom, 8)
            if let error = model.workLoopError { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger).padding(.horizontal, 18) }
            if let error = model.workIntakeError {
                Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider().overlay(COSPalette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if expiredOpen {
                        if model.workExpired.isEmpty { Text("No expired items to restore.") }
                        ForEach(model.workExpired) { item in
                            HStack { Text(item.text).font(COSType.body(12)); Spacer(); Button("Restore") { Task { await model.restoreExpiredWork(item) } } }
                        }
                    } else if !snapshot.available {
                        Text(snapshot.message ?? "Intake is unavailable on this server.")
                            .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                    } else if groups.isEmpty {
                        Text(catchUp ? "Catch up is clear." : "Today is clear. Older items stay in Catch up.")
                            .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                    } else {
                        if let selected {
                            HStack {
                                Text(selected.title).font(COSType.body(14, weight: .semibold))
                                Spacer()
                                Text("\(min(groupIndex + 1, groups.count)) of \(groups.count)").foregroundStyle(COSPalette.muted)
                            }
                            Text("j / k: next / previous meeting · s: decide later · e: keep first item").font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                            ForEach(selected.cards) { card in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(card.text).font(COSType.body(12.5, weight: .medium))
                                    Text([card.createdAt, card.owner, card.dueDate.isEmpty ? "" : "Due " + card.dueDate].filter { !$0.isEmpty }.joined(separator: " · ")).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                                    HStack {
                                        Button("Keep") { Task { _ = await model.changeWorkCard(card, action: "stage", fields: ["workStage": "planned"]) } }
                                        Button("Drop") { Task { _ = await model.changeWorkCard(card, action: "drop") } }
                                        WorkDelegateControl(model: model, task: card)
                                    }.disabled(!model.workBatchAvailable || model.workBatchBusy)
                                }.padding(12).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 9))
                            }
                            group("Items to decide", selected.items, note: "Keep what you own. Other people's asks can become cards when you take them on.") { item in
                                if item.isSuggestedLink { suggestion(item, snapshot) }
                                else if item.isAsk { ask(item, snapshot) }
                                else { review(item, snapshot) }
                            }
                            HStack {
                                Button("Previous") { groupIndex = max(0, groupIndex - 1) }.disabled(groupIndex == 0)
                                Button("Decide later") { groupIndex = groups.isEmpty ? 0 : (groupIndex + 1) % groups.count }
                                Spacer()
                                if !selected.items.isEmpty {
                                    Button("Dismiss remaining items") { Task { await model.dismissWorkIntake(selected.items) } }.disabled(keepingGroup || !model.workIntakeBusyIDs.isEmpty)
                                }
                            }.buttonStyle(COSTextButtonStyle())
                        }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 0, minHeight: 88, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { sortStarted = Date(); await model.loadWorkIntake(); await model.loadWorkExpiry(); keyboardFocus = true }
        .onDisappear { model.recordWorkObservation("sort", values: ["seconds": Date().timeIntervalSince(sortStarted), "catchUp": catchUp]) }
        .onChange(of: domain) { _, _ in groupIndex = 0 }
        .focusable().focused($keyboardFocus)
        .onKeyPress("j") { groupIndex = min(max(0, groups.count - 1), groupIndex + 1); return .handled }
        .onKeyPress("k") { groupIndex = max(0, groupIndex - 1); return .handled }
        .onKeyPress("s") { groupIndex = groups.isEmpty ? 0 : (groupIndex + 1) % groups.count; return .handled }
        .onKeyPress("e") {
            guard let selected else { return .ignored }
            if let card = selected.cards.first { Task { _ = await model.changeWorkCard(card, action: "stage", fields: ["workStage": "planned"]) } }
            else if let item = selected.items.first { Task { await model.resolveWorkIntake(item, accept: true) } }
            return .handled
        }
    }

    /// Skip older Review items after confirmation; the decision can be undone for seven days.
    @ViewBuilder
    private func skipOlder(_ snapshot: WorkIntakeSnapshot) -> some View {
        let older = snapshot.reviews.filter { $0.reason == "outside_window" }
        if older.count > 1 {
            HStack(spacing: 8) {
                if confirmSkipOlder {
                    Text("Drop \(older.count) from older meetings? Undo is available for 7 days.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    Button("Skip \(older.count)") { confirmSkipOlder = false; Task { await model.dismissWorkIntake(older) } }
                        .buttonStyle(COSQuietButtonStyle())
                    Button("Cancel") { confirmSkipOlder = false }.buttonStyle(COSTextButtonStyle())
                } else {
                    Button("Skip all \(older.count) from older meetings") { confirmSkipOlder = true }
                        .buttonStyle(COSTextButtonStyle()).disabled(!model.workIntakeBusyIDs.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [WorkIntakeItem], note: String, accessory: some View = EmptyView(),
                       @ViewBuilder row: @escaping (WorkIntakeItem) -> some View) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(COSType.body(13, weight: .semibold))
                    Text("\(items.count)").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    Spacer(minLength: 8)
                    accessory
                }
                Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item).onAppear { Task { _ = await model.workLoop("seen", body: ["ids": [item.id]]) } }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)  // short rows stay flush left when stacked
                        if item.id != items.last?.id { Divider().overlay(COSPalette.line) }
                    }
                }.padding(.horizontal, 12)
                    .background(COSPalette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.line))
            }
        }
    }

    private func source(_ item: WorkIntakeItem) -> some View {
        Button { onOpenMeeting(item.meeting) } label: {
            Label(item.meeting.title + (item.meetingDate.isEmpty ? "" : " · " + item.meetingDate), systemImage: "calendar")
                .font(COSType.body(10.5)).lineLimit(1).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(COSPalette.muted).help("Open the meeting")
    }

    private func actions(_ item: WorkIntakeItem, _ snapshot: WorkIntakeSnapshot, accept: String, enabled: Bool, dismiss: String) -> some View {
        let busy = model.workIntakeBusyIDs.contains(item.id)
        return HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Button(accept) { Task { await model.resolveWorkIntake(item, accept: true) } }
                .buttonStyle(COSQuietButtonStyle()).disabled(busy || !enabled)
                .help(enabled ? "" : (snapshot.bridgeUnavailable ? "The task bridge didn't answer. Refresh Intake."
                                      : item.kind == .link ? "This server can't write Work links." : "This server can't create Work cards yet."))
            Button(dismiss) { Task { await model.resolveWorkIntake(item, accept: false) } }
                .buttonStyle(COSTextButtonStyle()).disabled(busy)
        }
    }

    /// Source line and actions side by side, or stacked when the pane is narrow.
    private func footer(_ item: WorkIntakeItem, detail: String?, actions: some View) -> some View {
        let meta = HStack(spacing: 4) {
            source(item)
            if let detail { Text("· " + detail).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(1) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack { meta; Spacer(minLength: 8); actions }
            VStack(alignment: .leading, spacing: 6) { meta; actions }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func review(_ item: WorkIntakeItem, _ snapshot: WorkIntakeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(intakeInlineText(item.text)).font(COSType.body(12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            footer(item, detail: item.reasonLabel ?? (item.ownerIsMiles ? "probably yours" : item.owner),
                   actions: actions(item, snapshot, accept: "Keep as card", enabled: snapshot.cardCreation, dismiss: "Drop"))
        }
    }

    private func suggestion(_ item: WorkIntakeItem, _ snapshot: WorkIntakeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(intakeInlineText(item.text)).font(COSType.body(12.5, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            footer(item, detail: item.percent, actions: actions(item, snapshot, accept: "Link", enabled: snapshot.linkWrites, dismiss: "Dismiss"))
        }
    }

    private func ask(_ item: WorkIntakeItem, _ snapshot: WorkIntakeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(intakeInlineText(item.text)).font(COSType.body(12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let session = item.pullTitle {
                Label("Your session may already cover this" + (item.pullPercent.map { " (\($0))" } ?? "") + ": " + session,
                      systemImage: "arrow.up.forward.circle")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.accent)
            }
            footer(item, detail: item.owner, actions: actions(item, snapshot, accept: "Make it mine", enabled: snapshot.cardCreation, dismiss: "Dismiss"))
        }
    }
}


struct WorkDelegateControl: View {
    @ObservedObject var model: ControllerModel
    let task: TaskRow
    @State private var owner = ""
    @State private var checkIn = Date().addingTimeInterval(7 * 86400)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Waiting on whom?", text: $owner).textFieldStyle(.plain).cosField().frame(maxWidth: 220)
                DatePicker("Check in", selection: $checkIn, displayedComponents: .date)
                Button("Waiting on") {
                    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
                    Task { _ = await model.changeWorkCard(task, action: "delegate", fields: ["owner": owner, "checkIn": formatter.string(from: checkIn)]) }
                }.disabled(owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.workBatchBusy)
            }
            if let error = model.workLoopError { Text(error).foregroundStyle(COSPalette.danger) }
        }.font(COSType.body(12)).onAppear { if owner.isEmpty { owner = task.owner == "Miles" ? "" : task.owner } }
    }
}

struct WorkWaitingView: View {
    @ObservedObject var model: ControllerModel
    @State private var dates: [String: Date] = [:]
    @State private var dropped = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Waiting on").font(COSType.display(20)); Spacer(); Button("Refresh") { Task { await model.loadWaitingWork() } } }
            HStack {
                Button("Waiting on") { dropped = false }.buttonStyle(COSQuietButtonStyle())
                Button("Dropped cards") { dropped = true; Task { await model.loadDroppedWork() } }.buttonStyle(COSTextButtonStyle())
            }
            Text(dropped ? "Restore a dropped card with its identity and links intact." : "Follow up by person. These cards also appear in 1:1 prep.").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            if let error = model.workLoopError { Text(error).foregroundStyle(COSPalette.danger) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.waitingLoaded && model.waitingWork.isEmpty { Text("No open follow-ups.") }
                    ForEach((dropped ? model.droppedWork : model.waitingWork).compactMap(WorkWaitingRow.init).sorted { ($0.task.owner.lowercased(), $0.checkIn, $0.id) < ($1.task.owner.lowercased(), $1.checkIn, $1.id) }) { row in
                        if dropped {
                            HStack { Text(row.task.text); Spacer(); Button("Restore") { Task { _ = await model.changeWorkCard(row.task, action: "restore") } } }.padding(12)
                        } else { waitingRow(row) }
                    }
                }
            }
        }.padding(18).task { await model.loadWaitingWork() }
    }
    private func waitingRow(_ row: WorkWaitingRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.task.owner.isEmpty ? "Owner unknown" : row.task.owner).font(COSType.body(13, weight: .semibold))
            Text(row.task.text).font(COSType.body(12))
            Text(row.needsCheckIn ? "Still waiting?" : row.checkIn.isEmpty ? "Choose a check-in date" : "Check in " + row.checkIn).foregroundStyle(COSPalette.muted)
            HStack {
                Button("Done") { Task { _ = await model.changeWorkCard(row.task, action: "stage", fields: ["workStage": "complete"]) } }
                DatePicker("Next check-in", selection: Binding(get: { dates[row.id] ?? Date().addingTimeInterval(7 * 86400) }, set: { dates[row.id] = $0 }), displayedComponents: .date)
                Button("Still waiting") {
                    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
                    let next = formatter.string(from: dates[row.id] ?? Date().addingTimeInterval(7 * 86400))
                    Task { _ = await model.changeWorkCard(row.task, action: "checkIn", fields: ["checkIn": next]) }
                }
                Button("Drop") { Task { _ = await model.changeWorkCard(row.task, action: "drop") } }
            }.disabled(model.workBatchBusy)
        }.font(COSType.body(11)).padding(12).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }
}
struct WorkWaitingRow: Identifiable {
    let task: TaskRow
    let checkIn: String
    let needsCheckIn: Bool
    var id: String { task.workSourceID }
    init?(_ raw: JSONValue) {
        guard let task = TaskRow(raw) else { return nil }
        self.task = task
        checkIn = raw.object?["checkIn"]?.string ?? ""
        needsCheckIn = raw.object?["needsCheckIn"]?.bool == true
    }
}
