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
        let session = sessions.first { $0.id == receipt.sessionID && $0.provider == receipt.provider }
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
        items.compactMap { item -> WorkBoardSessionCard? in
            guard domain == nil || item.domain == domain else { return nil }
            var activity = item.activity, earlier = false
            if activity == nil, let receipt = receipts.filter({ $0.workID == item.sourceID }).max(by: { $0.createdAt < $1.createdAt }) {
                activity = WorkActivity(receipt: receipt, session: sessions.first { $0.id == receipt.sessionID && $0.provider == receipt.provider })
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
    @Published var scope: WorkWorkspaceScope = .all { didSet { intakeOpen = false; startItemID = nil } }
    @Published var domain: String? { didSet { if domain != nil { intakeOpen = false }; startItemID = nil } }
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
    @Published var previewStages: [String: String] = [:]
    /// Work → Intake (server 6.57.0). Its own route flag: the Intake row or toggle opens it, and choosing a view
    /// or a domain closes it (the observers above), so no opener can leave Intake covering the board.
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

    static func items(tasks: [TaskRow], reviews: [WorkReviewRecord], receipts: [WorkHandoffReceipt], sessions: [WorkSession] = []) -> [WorkWorkspaceItem] {
        let taskItems = tasks.map { task in
            let source = WorkSource.taskSnapshot(task)
            let activity = WorkActivityProjection.latest(workID: source.id, revision: source.revision, receipts: receipts, sessions: sessions)
            let running = activity?.inProgress == true
            let attention = activity?.needsAttention == true && activity?.sessionRunning != true
            let tracking = WorkTracking.latest(workID: source.id, receipts: receipts)
            let label = task.checked ? "Completed task" : task.agentState == "done" ? "Agent finished · task still open" : WorkBoardStage.stage(for: task).title
            return WorkWorkspaceItem(id: source.id, title: task.text.isEmpty ? task.title : task.text, domain: task.domain,
                searchText: source.context, subtitle: label, task: task, review: nil,
                needsAttention: !task.checked && (task.failed == true || task.missed == true || attention || task.agentState == "done" || task.stage == "review"
                                                  || tracking?.asksForYou == true),
                inProgress: task.agentState == "running" || running, completed: task.checked, activity: activity, tracking: tracking)
        }
        let meetingItems = reviews.map { review in
            let activity = WorkActivityProjection.latest(workID: review.source.id, revision: review.source.revision, receipts: receipts, sessions: sessions)
            let tracking = WorkTracking.latest(workID: review.source.id, receipts: receipts)
            return WorkWorkspaceItem(id: "meeting-review:" + review.id, title: review.title, domain: review.domain,
                searchText: review.title + " " + review.markdown + " " + review.source.context,
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
            return l == r ? left.offset < right.offset : l < r
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

    static func filter(_ items: [WorkWorkspaceItem], scope: WorkWorkspaceScope, domain: String?, query: String) -> [WorkWorkspaceItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard domain == nil || item.domain == domain else { return false }
            if !needle.isEmpty && !(item.title + " " + item.domain + " " + item.searchText).localizedCaseInsensitiveContains(needle) { return false }
            switch scope {
            case .all: return true
            case .attention: return item.needsAttention
            case .progress: return item.inProgress
            case .completed: return item.completed
            }
        }
    }
}

struct WorkWorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: ControllerModel
    @ObservedObject var handoffStore: WorkHandoffStore
    @ObservedObject var reviewStore: WorkReviewStore
    @ObservedObject var state: WorkWorkspaceState
    var onOpenSession: (String) -> Void
    var onEditTask: (TaskRow) -> Void
    var onReviewMeeting: (LibraryMeeting) -> Void
    var onOpenMeeting: (WorkMeetingReference) -> Void = { _ in }

    private var items: [WorkWorkspaceItem] {
        WorkWorkspaceProjection.items(tasks: handoffStore.isolated ? WorkWorkspaceProjection.previewRows(handoffStore.previewTasks, stages: state.previewStages) : model.workTasks, reviews: reviewStore.reviews, receipts: handoffStore.receipts, sessions: handoffStore.observedSessions())
    }
    private var visible: [WorkWorkspaceItem] { WorkWorkspaceProjection.filter(items, scope: state.scope, domain: state.domain, query: state.query) }
    private var selected: WorkWorkspaceItem? { items.first { $0.id == state.selectedID } }
    private var domains: [String] { Array(Set(model.domainOptions.map(\.name) + items.map(\.domain))).filter { !$0.isEmpty }.sorted() }
    private var hasDetail: Bool { state.selectedID != nil || state.meetingPicker || reviewStore.selectedMeeting != nil }
    @AppStorage("cos.workLayout") private var layoutRaw = WorkLayout.board.rawValue
    @AppStorage("cos.workSessionsRowCollapsed") private var sessionsCollapsed = false
    @State private var startDropTargeted = false
    @State private var columnTarget: WorkBoardStage?
    /// Width of the session row, measured, so the pinned Start work column casts its edge only when cards run under it.
    @State private var sessionsRowWidth: CGFloat = 0
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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                activitySummary
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
                } else if geometry.size.width >= 900 {
                    HStack(spacing: 0) {
                        sidebar.frame(width: 148)
                        Divider()
                        if state.intakeOpen {
                            WorkIntakeView(model: model, onOpenMeeting: onOpenMeeting)
                        } else if layout == .board {
                            boardSurface
                        } else {
                            focusSurface
                        }
                    }
                } else {
                    compactNavigation
                    Divider()
                    if state.intakeOpen { WorkIntakeView(model: model, onOpenMeeting: onOpenMeeting) }
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
        }
        .task {
            if let id = handoffStore.selectedWorkID { state.selectedID = WorkWorkspaceProjection.rowID(forSourceID: id, currentID: state.selectedID, items: items) ?? id }
            guard !handoffStore.isolated else { return }
            await model.loadDomains()
            await model.loadWorkTasks()
            await reviewStore.refresh()
            await model.loadWorkIntake()
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
            Picker("Layout", selection: layoutBinding) {
                ForEach(WorkLayout.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
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
            Button { Task { await model.loadWorkTasks(); await reviewStore.refresh(); await handoffStore.refreshActivity(); await handoffStore.refreshReceipts() } } label: { Image(systemName: "arrow.clockwise") }
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
                TextField("What needs to be done?", text: $state.captureText).textFieldStyle(.roundedBorder).disabled(state.captureBusy)
                Picker("Domain", selection: $state.captureDomain) {
                    Text("Choose domain").tag("")
                    ForEach(model.domainOptions) { Text($0.label).tag($0.name) }
                }.frame(maxWidth: 200).disabled(state.captureBusy)
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
                if !handoffStore.isolated && model.workIntakeVisible {
                    navigationRow(intakeTitle, selected: state.intakeOpen) {
                        state.intakeOpen = true; state.domain = nil; returnToList()
                    }
                }
                Divider().padding(.vertical, 12)
                Text("Domains").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted).padding(.horizontal, 10)
                ForEach(domains, id: \.self) { domain in
                    navigationRow(domainLabel(domain), selected: state.domain == domain && !state.intakeOpen) {
                        state.domain = domain; state.scope = .all; state.intakeOpen = false; state.focusOverride = false; returnToList()
                    }
                }
            }.padding(10)
        }.background(COSPalette.raised.opacity(0.55))
    }

    private var intakeTitle: String {
        let count = model.workIntake.openCount
        if !model.workIntake.available || model.workIntakeError != nil { return "Intake · !" }
        return count > 0 ? "Intake · \(count)" : "Intake"
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
            Picker("View", selection: Binding(get: { state.scope }, set: { value in
                state.scope = value; state.intakeOpen = false; state.focusOverride = false; returnToList()
            })) {
                ForEach(WorkWorkspaceScope.allCases) { Text($0.title).tag($0) }
            }
            if !handoffStore.isolated && model.workIntakeVisible {
                Toggle(intakeTitle, isOn: $state.intakeOpen).toggleStyle(.button)
            }
            Picker("Domain", selection: Binding(get: { state.domain ?? "" }, set: { state.domain = $0.isEmpty ? nil : $0; returnToList() })) {
                Text("All domains").tag("")
                ForEach(domains, id: \.self) { Text(domainLabel($0)).tag($0) }
            }
            Spacer(minLength: 0)
        }.font(COSType.body(12)).padding(.horizontal, 18).padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(boardName).font(COSType.display(23, weight: .medium))
                    Text("\(visible.filter { $0.task != nil }.count) tasks · Drag a card to change its stage, or onto Start work to put a session on it")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                Spacer(minLength: 8)
                TextField(state.domain == nil ? "Search work" : "Search this domain", text: $state.query).textFieldStyle(.plain)
                    .font(COSType.body(12)).padding(10).frame(maxWidth: 240)
                    .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.line))
            }.padding(18)
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
            let reviews = visible.filter { $0.review != nil }
            if !reviews.isEmpty {
                HStack {
                    Text("Meeting reviews").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                    Menu("\(reviews.count) recorded") { ForEach(reviews) { item in Button(item.title + " · " + (item.review?.status ?? "")) { select(item) } } }
                        .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }.padding(.horizontal, 18).padding(.bottom, 10)
            }
            latestMoveStrip
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(WorkBoardStage.allCases) { stage in boardColumn(stage) }
                }.padding(.horizontal, 18).padding(.bottom, 18)
            }.frame(minHeight: 220)
            Text(handoffStore.isolated ? "Sample stages reset when this preview closes." : "Stages reflect your decisions. Moving a card does not run an agent or publish changes. Start work asks before anything is sent.")
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).padding(.horizontal, 18).padding(.bottom, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(COSPalette.panel)
    }

    private var sessionsRow: some View {
        let allCards = WorkBoardSessionsProjection.cards(items, receipts: handoffStore.receipts, sessions: handoffStore.observedSessions(), domain: state.domain)
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
            let overflowing = showCards && WorkBoardSessionCard.rowOverflows(cards: cards.count, width: sessionsRowWidth)
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
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                guard let item = WorkWorkspaceProjection.startable(id: id, items: items) else {
                    if items.contains(where: { $0.id == id }) { state.mutationError = "Only open board cards can be started. A completed card or a meeting review is started from its own page." }
                    return false
                }
                openStart(item)
                return true
            } isTargeted: { startDropTargeted = $0 }
            .background(GeometryReader { box in
                Color.clear.onAppear { sessionsRowWidth = box.size.width }
                    .onChange(of: box.size.width) { _, width in sessionsRowWidth = width }
            })
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func sessionCard(_ card: WorkBoardSessionCard) -> some View {
        let receipt = card.activity.receipt, state = card.state
        let held = receipt.progress == nil ? [] : WorkProgress.workingSession(receipt).map { sessionID in
            WorkTracking.forSession(sessionID, receipts: handoffStore.receipts)
                .filter { tracking in items.first { $0.sourceID == tracking.receipt.workID }?.completed != true }
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
                (Text("On ") + Text(inlineTitle(card.item.title)).foregroundColor(.primary)
                    + Text(" · " + (card.item.task.map { WorkBoardStage.stage(for: $0).title } ?? "Meeting review")
                           + (card.earlierRevision ? " · an earlier version of the card" : "")))
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
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
                if let sessionID = receipt.sessionID {
                    Button("Open session") { handoffStore.selectedWorkID = card.item.sourceID; onOpenSession(sessionID) }
                        .buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                }
                if receipt.acknowledgeable && state.offersAcknowledge {
                    Button(WorkHandoffView.acknowledgeTitle(receipt)) { handoffStore.markReviewed(receiptID: receipt.id) }
                        .buttonStyle(COSQuietButtonStyle()).controlSize(.small).disabled(handoffStore.busy)
                }
                Button(card.item.review != nil ? "Open review" : "Open card") { select(card.item) }
                    .buttonStyle(COSTextButtonStyle()).controlSize(.small)
            }
        }.padding(12).frame(width: WorkBoardSessionCard.cardWidth, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(state.tint.opacity(0.4)))
    }

    /// One task on a session card: its title, and its tracked state and stage.
    private func heldTaskRow(_ tracking: WorkTracking) -> some View {
        let item = items.first { $0.sourceID == tracking.receipt.workID }
        let stage = item?.task.map { WorkBoardStage.stage(for: $0).title } ?? (item?.review != nil ? "Review" : "")
        return Button { if let item { select(item) } } label: {
            HStack(spacing: 8) {
                WorkTrackingDot(phase: tracking.phase, tint: tracking.tint)
                Text(inlineTitle(item?.title ?? tracking.receipt.workTitle)).font(COSType.body(12)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                Text(tracking.shortLabel + (stage.isEmpty ? "" : " · " + stage)).font(COSType.mono(10.5)).foregroundStyle(tracking.tint)
                    .lineLimit(1).fixedSize()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(item == nil).help(item == nil ? "This task is not on this board" : "Open this task")
    }

    /// 0.5.247 (3A): the newest automatic move, over the columns (WorkLatestMoveStrip observes the tracker).
    @ViewBuilder private var latestMoveStrip: some View {
        if let tracker = model.workTracker {
            WorkLatestMoveStrip(tracker: tracker, store: handoffStore, lookup: { workID in
                items.first { $0.sourceID == workID }.map { ($0.title, $0.task.map { WorkBoardStage.stage(for: $0).rawValue }) }
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
            if !compact {
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

    private func boardColumn(_ stage: WorkBoardStage) -> some View {
        let cards = visible.filter { $0.task.map { WorkBoardStage.stage(for: $0) == stage } ?? false }
        let targeted = columnTarget == stage
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(stage.title).font(COSType.body(13, weight: .semibold))
                Spacer()
                Text("\(cards.count)").font(COSType.mono(11)).foregroundStyle(COSPalette.muted)
            }.padding(.horizontal, 12).padding(.top, 13)
            Text(stage.subtitle).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 13)
            Divider().overlay(COSPalette.line)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if cards.isEmpty { Text(targeted ? "Drop to move here" : "No tasks here").font(COSType.body(12)).foregroundStyle(COSPalette.muted).padding(12) }
                    ForEach(cards) { item in boardCard(item) }
                }.padding(10)
            }
        }.frame(width: 234).frame(maxHeight: .infinity, alignment: .top)
            .background(targeted ? COSPalette.gold.opacity(0.08) : COSPalette.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(targeted ? COSPalette.gold.opacity(0.8) : COSPalette.line))
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let task = WorkWorkspaceProjection.stageDrop(id: id, items: items, to: stage) else { return false }
                guard canChangeStage(task) else {
                    state.mutationError = model.workBoardWritable || handoffStore.isolated
                        ? "That card can't move right now. Wait for the current change to finish, or refresh."
                        : "Board is read-only. Stage changes need the connected Work service."
                    return false
                }
                // Completing is the one stage change that asks first: a drag is easy to mistake.
                if stage == .complete { state.pendingComplete = task } else { move(task, to: stage) }
                return true
            } isTargeted: { over in
                if over { columnTarget = stage } else if columnTarget == stage { columnTarget = nil }
            }
    }

    private func boardCard(_ item: WorkWorkspaceItem) -> some View {
        let handoff = item.activity.map { WorkHandoffState($0) }
        let running = handoff == .running
        let tracking = item.tracking
        let stageRaw = item.task.map { WorkBoardStage.stage(for: $0).rawValue }
        let autoMove = tracking?.undoableMove(currentStage: stageRaw)
        let asking = tracking?.asksForYou == true
        return VStack(alignment: .leading, spacing: 0) {
            cardTapArea(item, handoff: handoff, running: running)
            // Outside the tap area: its Undo is its own control, not part of the card's single action.
            if let autoMove, let tracking { cardWhyLine(tracking, autoMove).padding(.horizontal, 12).padding(.bottom, 10) }
            if let task = item.task {
                ForEach(task.meetingRefs.prefix(2)) { meeting in
                    Button { onOpenMeeting(meeting) } label: {
                        Label(meeting.title, systemImage: "calendar").font(COSType.body(10.5)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(COSPalette.accent).padding(.horizontal, 12).padding(.bottom, 10)
                }
                Divider().overlay(COSPalette.line)
                HStack { stageMenu(task); Spacer(minLength: 0) }.padding(.horizontal, 10).padding(.vertical, 6)
            }
        }.background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Self.cardStroke(asking: asking, running: running, moved: autoMove != nil)))
            .overlay(alignment: .leading) { cardRule(asking: asking, running: running) }
            .draggable(item.id) {
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
    private func cardTapArea(_ item: WorkWorkspaceItem, handoff: WorkHandoffState?, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(inlineTitle(item.title)).font(COSType.body(13, weight: .medium)).multilineTextAlignment(.leading).lineLimit(5)
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
    nonisolated static func cardStroke(asking: Bool, running: Bool, moved: Bool) -> Color {
        asking ? COSPalette.amber.opacity(0.6) : running ? COSPalette.green.opacity(0.6) : moved ? COSPalette.gold.opacity(0.45) : COSPalette.line
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
            if let item = items.first(where: { $0.id == id }), let task = item.task, !item.completed || state.startSending {
                GeometryReader { box in
                    ZStack {
                        // A tap outside closes it, except while a send is being handed over.
                        Color.black.opacity(0.28).contentShape(Rectangle()).onTapGesture { if !state.startSending { state.startItemID = nil } }
                        WorkStartSheet(store: handoffStore, title: (task.text.isEmpty ? task.title : task.text).replacingOccurrences(of: "**", with: ""),
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
        } label: { Label(WorkBoardStage.stage(for: task).title, systemImage: "arrow.left.arrow.right") }
            .font(COSType.body(11)).menuStyle(.borderlessButton).fixedSize()
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
            TextField("Search work", text: $state.query).textFieldStyle(.plain)
                .help("Search full task text, finish lines, source evidence, and review context")
                .font(COSType.body(12)).padding(10).background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.line)).padding(12)
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
            GeometryReader { box in
                // 400 pt of workspace plus about 360 pt to read in (the default 920 pt window leaves 771); 452 from 1,100.
                if box.size.width >= 760 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) { itemHeader(item); itemBody(item) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                        }.frame(maxWidth: .infinity)
                        Divider().overlay(COSPalette.line)
                        ScrollView { itemWorkspace(item).padding(18) }
                            .frame(width: box.size.width >= 1100 ? 452 : 400).frame(maxHeight: .infinity).background(COSPalette.card.opacity(0.55))
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            itemHeader(item)
                            itemWorkspace(item).padding(16)
                                .background(COSPalette.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line))
                            itemBody(item)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                    }
                }
            }.id(item.id)
        } else if let id = state.selectedID, !handoffStore.receipts(for: id).isEmpty {
            ScrollView { receiptFallback(id).padding(22) }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(state.selectedID == nil ? "Choose what to work on" : "This work is not currently available").font(COSType.display(25, weight: .medium))
                Text(state.selectedID == nil ? "Select a task to see its goal, source, agent destination, and history. Or review a saved meeting for follow-up." : "Refresh or choose another item. The original task or meeting has not been recreated.").font(COSType.body(13)).foregroundStyle(COSPalette.muted)
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func itemHeader(_ item: WorkWorkspaceItem) -> some View {
        if let task = item.task { taskHeader(task) } else if let review = item.review { reviewHeader(review) }
    }
    @ViewBuilder private func itemBody(_ item: WorkWorkspaceItem) -> some View {
        if let task = item.task { taskBody(task) } else if let review = item.review { reviewBody(review) }
    }
    @ViewBuilder private func itemWorkspace(_ item: WorkWorkspaceItem) -> some View {
        if let task = item.task {
            WorkHandoffView(store: handoffStore, source: .taskSnapshot(task), isPreview: handoffStore.isolated, onOpenSession: onOpenSession,
                            currentStage: WorkBoardStage.stage(for: task).rawValue,
                            onUndoMove: model.workTracker == nil ? nil : { receiptID, eventID in undoMove(receiptID, eventID) },
                            onMarkComplete: task.checked || !canChangeStage(task) ? nil : { move(task, to: .complete) },
                            onSentBack: { if [.built, .qa].contains(WorkBoardStage.stage(for: task)) { move(task, to: .draft) } })
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
                }
            }
            Text(domainLabel(task.domain) + " · " + (task.checked ? "Completed task" : WorkBoardStage.stage(for: task).title))
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            HStack {
                stageMenu(task)
                if state.mutationBusy { ProgressView().controlSize(.small) }
                Spacer()
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
                Picker("Review model", selection: $state.reviewModelID) {
                    Text("Choose a model").tag("")
                    ForEach(reviewStore.models) { choice in Text(choice.title + (choice.available ? "" : " · unavailable")).tag(choice.id) }
                }
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
        VStack(alignment: .leading, spacing: 10) {
            Text(inlineTitle(review.title)).font(COSType.display(25, weight: .medium)).textSelection(.enabled)
            Text("Meeting review · " + review.status.replacingOccurrences(of: "_", with: " ") + " · " + domainLabel(review.domain))
                .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            if let reference = WorkMeetingReference(.object(review.descriptor.merging(["recordId": review.canonicalMeetingId, "title": review.title]) { _, new in new }.mapValues { .string($0) })) {
                Button { onOpenMeeting(reference) } label: { Label("Open source meeting", systemImage: "calendar") }.buttonStyle(COSQuietButtonStyle())
            }
        }
    }

    /// Reviews longer than this open folded, with Show the full review.
    private static let foldedReviewCharacters = 1_400

    private func reviewBody(_ review: WorkReviewRecord) -> some View {
        let notes = (review.inputTruncated ? ["The source was too long to include in full. Review may omit details."] : []) + review.contextWarnings
        let notesOpen = state.expandedNotes.contains(review.id)
        let long = review.markdown.count > Self.foldedReviewCharacters
        let open = !long || state.expandedReviews.contains(review.id)
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
            if !review.markdown.isEmpty {
                if open {
                    COSMarkdownView(text: review.markdown)
                } else {
                    COSMarkdownView(text: review.markdown).frame(maxHeight: 300, alignment: .top).clipped()
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                }
                if long {
                    Button(open ? "Show less" : "Show the full review") {
                        if open { state.expandedReviews.remove(review.id) } else { state.expandedReviews.insert(review.id) }
                    }.buttonStyle(COSQuietButtonStyle())
                }
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
            WorkHandoffView(store: handoffStore, source: review.source, isPreview: handoffStore.isolated, onOpenSession: onOpenSession,
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
    var onOpenMeeting: (WorkMeetingReference) -> Void
    @State private var confirmSkipOlder = false

    var body: some View {
        let snapshot = model.workIntake
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Intake").font(COSType.display(19, weight: .medium))
                Text("From your meetings, not on the board yet").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                Spacer()
                if model.workIntakeLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.loadWorkIntake() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(COSIconButtonStyle()).help("Refresh Intake")
            }.padding(.horizontal, 18).padding(.vertical, 12)
            if let error = model.workIntakeError {
                Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider().overlay(COSPalette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !snapshot.available {
                        Text(snapshot.message ?? "Intake is unavailable on this server.")
                            .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                    } else if snapshot.openCount == 0 {
                        Text("Nothing waiting. When a saved meeting has Work that is not on the board yet, it appears here.")
                            .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                    } else {
                        group("Review", snapshot.reviews, note: "Yours to check: from an older meeting, or not clear enough to add on its own.",
                              accessory: skipOlder(snapshot)) { review($0, snapshot) }
                        group("Suggested links", snapshot.suggestedLinks, note: "Existing tasks these meetings probably worked on.") { suggestion($0, snapshot) }
                        group("Asks from others", snapshot.asks, note: "Other people's action items. Take one on when you are positioned to do it.") { ask($0, snapshot) }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 0, minHeight: 88, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.loadWorkIntake() }
    }

    /// Skip every Review item from an older meeting at once, after one confirm. There is no undo.
    @ViewBuilder
    private func skipOlder(_ snapshot: WorkIntakeSnapshot) -> some View {
        let older = snapshot.reviews.filter { $0.reason == "outside_window" }
        if older.count > 1 {
            HStack(spacing: 8) {
                if confirmSkipOlder {
                    Text("Skip \(older.count) from older meetings? This can't be undone.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
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
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)  // short rows stay flush left when stacked
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
                   actions: actions(item, snapshot, accept: "Keep as card", enabled: snapshot.cardCreation, dismiss: "Skip"))
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
