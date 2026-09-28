import AppKit
import SwiftUI

struct WorkActivity: Identifiable {
    let receipt: WorkHandoffReceipt
    let session: WorkSession?
    var id: String { receipt.id }
    var observingTurn: Bool { ["sending", "queued", "running", "delivered"].contains(receipt.status) }
    var sessionRunning: Bool { observingTurn && ["running", "working"].contains(session?.status ?? "") }
    var needsAttention: Bool {
        ["unknown", "failed", "refused", "delivered", "completed"].contains(receipt.status)
            || (observingTurn && ["waiting", "error", "failed"].contains(session?.status ?? ""))
    }
    var inProgress: Bool { ["preparing", "sending", "queued", "running"].contains(receipt.status) || sessionRunning }
    var title: String {
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
    @Published var scope: WorkWorkspaceScope = .all
    @Published var domain: String?
    @Published var query = ""
    @Published var selectedID: String?
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
            let label = task.checked ? "Completed task" : task.agentState == "done" ? "Agent finished · task still open" : WorkBoardStage.stage(for: task).title
            return WorkWorkspaceItem(id: source.id, title: task.text.isEmpty ? task.title : task.text, domain: task.domain,
                searchText: source.context, subtitle: label, task: task, review: nil,
                needsAttention: !task.checked && (task.failed == true || task.missed == true || attention || task.agentState == "done" || task.stage == "review"),
                inProgress: task.agentState == "running" || running, completed: task.checked, activity: activity)
        }
        let meetingItems = reviews.map { review in
            let activity = WorkActivityProjection.latest(workID: review.source.id, revision: review.source.revision, receipts: receipts, sessions: sessions)
            return WorkWorkspaceItem(id: "meeting-review:" + review.id, title: review.title, domain: review.domain,
                searchText: review.title + " " + review.markdown + " " + review.source.context,
                subtitle: "Meeting review · " + review.status.replacingOccurrences(of: "_", with: " "),
                task: nil, review: review,
                needsAttention: activity.map { $0.needsAttention && !$0.sessionRunning } ?? ["completed", "ready", "failed", "unknown", "needs_review"].contains(review.status),
                inProgress: activity?.inProgress == true || ["preparing", "starting", "queued", "running", "accepted"].contains(review.status),
                completed: false, activity: activity)
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
                        if state.domain != nil {
                            domainSurface
                        } else {
                            workList.frame(width: 248)
                            Divider()
                            detailPane.frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    compactNavigation
                    Divider()
                    if state.domain != nil { domainSurface }
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
        }
        .task {
            if let id = handoffStore.selectedWorkID { state.selectedID = WorkWorkspaceProjection.rowID(forSourceID: id, currentID: state.selectedID, items: items) ?? id }
            guard !handoffStore.isolated else { return }
            await model.loadDomains()
            await model.loadWorkTasks()
            await reviewStore.refresh()
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
        .onExitCommand { if state.meetingPicker || hasDetail { closePickerOrDetail() } }
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
        Text("\(items.filter(\.inProgress).count) in progress").foregroundStyle(COSPalette.accent)
        Text("\(items.filter(\.needsAttention).count) need attention").foregroundStyle(COSPalette.muted)
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
                    navigationRow(scope.title, selected: state.scope == scope && state.domain == nil) {
                        state.scope = scope; state.domain = nil; returnToList()
                    }
                }
                Divider().padding(.vertical, 12)
                Text("Domains").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted).padding(.horizontal, 10)
                ForEach(domains, id: \.self) { domain in
                    navigationRow(domainLabel(domain), selected: state.domain == domain) {
                        state.domain = domain; state.scope = .all; returnToList()
                    }
                }
            }.padding(10)
        }.background(COSPalette.raised.opacity(0.55))
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
            Picker("View", selection: $state.scope) {
                ForEach(WorkWorkspaceScope.allCases) { Text($0.title).tag($0) }
            }.onChange(of: state.scope) { _, _ in returnToList() }
            Picker("Domain", selection: Binding(get: { state.domain ?? "" }, set: { state.domain = $0.isEmpty ? nil : $0; returnToList() })) {
                Text("All domains").tag("")
                ForEach(domains, id: \.self) { Text(domainLabel($0)).tag($0) }
            }
            Spacer(minLength: 0)
        }.font(COSType.body(12)).padding(.horizontal, 18).padding(.vertical, 10)
    }

    @ViewBuilder private var domainSurface: some View {
        if hasDetail {
            VStack(spacing: 0) {
                HStack {
                    Button { returnToList() } label: { Label("Back to " + domainLabel(state.domain ?? "") + " board", systemImage: "chevron.left") }
                        .buttonStyle(COSQuietButtonStyle())
                    Spacer()
                }.padding(.horizontal, 18).padding(.vertical, 10)
                Divider().overlay(COSPalette.line)
                detailPane
            }
        } else { domainBoard }
    }

    private var domainBoard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(domainLabel(state.domain ?? "")).font(COSType.display(23, weight: .medium))
                    Text("\(visible.filter { $0.task != nil }.count) tasks · Select a card to see its meetings and sessions")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                Spacer(minLength: 8)
                TextField("Search this domain", text: $state.query).textFieldStyle(.plain)
                    .font(COSType.body(12)).padding(10).frame(maxWidth: 240)
                    .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.line))
            }.padding(18)
            if !handoffStore.isolated && !model.workBoardWritable {
                Text("Board is read-only. Stage changes and meeting links need the connected Work service.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.muted).padding(.horizontal, 18).padding(.bottom, 10)
            }
            if let error = model.workTasksError { Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger).padding(.horizontal, 18) }
            let reviews = visible.filter { $0.review != nil }
            if !reviews.isEmpty {
                HStack {
                    Text("Meeting reviews").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                    Menu("\(reviews.count) recorded") { ForEach(reviews) { item in Button(item.title + " · " + (item.review?.status ?? "")) { select(item) } } }
                    Spacer()
                }.padding(.horizontal, 18).padding(.bottom, 10)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(WorkBoardStage.allCases) { stage in boardColumn(stage) }
                }.padding(.horizontal, 18).padding(.bottom, 18)
            }
            Text(handoffStore.isolated ? "Sample stages reset when this preview closes." : "Stages reflect your decisions. Moving a card does not run an agent or publish changes.")
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).padding(.horizontal, 18).padding(.bottom, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(COSPalette.panel)
    }

    private func boardColumn(_ stage: WorkBoardStage) -> some View {
        let cards = visible.filter { $0.task.map { WorkBoardStage.stage(for: $0) == stage } ?? false }
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
                    if cards.isEmpty { Text("No tasks here").font(COSType.body(12)).foregroundStyle(COSPalette.muted).padding(12) }
                    ForEach(cards) { item in boardCard(item) }
                }.padding(10)
            }
        }.frame(width: 234).frame(maxHeight: .infinity, alignment: .top)
            .background(COSPalette.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.line))
    }

    private func boardCard(_ item: WorkWorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { select(item) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(inlineTitle(item.title)).font(COSType.body(13, weight: .medium)).multilineTextAlignment(.leading).lineLimit(5)
                    if let activity = item.activity {
                        Label(activity.title, systemImage: activity.glyph).font(COSType.body(10.5)).foregroundStyle(COSPalette.accent)
                        Text(activity.session?.title ?? activity.receipt.sessionTitle).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
                    } else if item.inProgress { Label("Session running", systemImage: "clock").font(COSType.body(10.5)).foregroundStyle(COSPalette.accent) }
                    else if item.needsAttention { Label("Needs attention", systemImage: "circle.dashed").font(COSType.body(10.5)).foregroundStyle(COSPalette.accent) }
                    if let task = item.task, task.meetingRefs.isEmpty {
                        Text(task.source.isEmpty ? "No meeting linked" : task.source).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(item.title)
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
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(COSPalette.line))
    }

    private func stageMenu(_ task: TaskRow) -> some View {
        Menu {
            ForEach(WorkBoardStage.allCases) { stage in
                Button(stage == .complete ? "Mark complete" : "Move to " + stage.title) { move(task, to: stage) }
                    .disabled(WorkBoardStage.stage(for: task) == stage)
            }
        } label: { Label(WorkBoardStage.stage(for: task).title, systemImage: "arrow.left.arrow.right") }
            .font(COSType.body(11)).menuStyle(.borderlessButton).fixedSize()
            .disabled(state.mutationBusy || (!handoffStore.isolated && (!model.workBoardWritable || task.workRevision.isEmpty || task.workMetadataError != nil)))
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
                                    Label(activity.title, systemImage: activity.glyph).font(COSType.body(10.5)).foregroundStyle(COSPalette.accent)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let task = item.task { taskDetail(task) }
                    else if let review = item.review { meetingDetail(review) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
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

    private func taskDetail(_ task: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 20) {
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
            workActivity(source: .taskSnapshot(task))
            sourceMeetings(task)
            fact("Done when", task.doneWhen.isEmpty ? "No finish line recorded. Use Edit task to define one." : task.doneWhen)
            if !task.source.isEmpty { fact("Source", task.source) }
            if !task.runAt.isEmpty { fact("Scheduled", task.runAt) }
            WorkHandoffView(store: handoffStore, source: .taskSnapshot(task), isPreview: handoffStore.isolated, onOpenSession: onOpenSession)
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

    private func meetingDetail(_ review: WorkReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(inlineTitle(review.title)).font(COSType.display(25, weight: .medium))
            Text("Meeting review · " + review.status.replacingOccurrences(of: "_", with: " ")).font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            if let reference = WorkMeetingReference(.object(review.descriptor.merging(["recordId": review.canonicalMeetingId, "title": review.title]) { _, new in new }.mapValues { .string($0) })) {
                Button { onOpenMeeting(reference) } label: { Label("Open source meeting", systemImage: "calendar") }.buttonStyle(COSQuietButtonStyle())
            }
            workActivity(source: review.source)
            if let error = review.error { Text(error).foregroundStyle(COSPalette.danger) }
            if review.inputTruncated {
                Label("The source was too long to include in full. Review may omit details.", systemImage: "exclamationmark.triangle")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.danger)
            }
            ForEach(review.contextWarnings, id: \.self) { warning in
                Text(warning).font(COSType.body(12)).foregroundStyle(COSPalette.danger)
            }
            if !handoffStore.isolated {
                Text("This review also appears in COS conversation history.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            if !review.markdown.isEmpty { COSMarkdownView(text: review.markdown) }
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
            if let error = reviewStore.error {
                Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger)
            }
            if review.canPrepare && (handoffStore.isolated || (reviewStore.available && reviewStore.error == nil)) {
                WorkHandoffView(store: handoffStore, source: review.source, isPreview: handoffStore.isolated, onOpenSession: onOpenSession,
                    validateBeforeSend: {
                        if handoffStore.isolated { return true }
                        return await reviewStore.validateForHandoff(review)
                    })
            } else {
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

    @ViewBuilder private func workActivity(source: WorkSource) -> some View {
        if let activity = WorkActivityProjection.latest(workID: source.id, revision: source.revision, receipts: handoffStore.receipts, sessions: handoffStore.observedSessions()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Activity").font(COSType.display(20, weight: .medium))
                    Spacer()
                    Label(activity.title, systemImage: activity.glyph).font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.accent)
                }
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(COSPalette.gold).frame(width: 7, height: 7).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(activity.receipt.mode.title + " · " + activity.receipt.provider.capitalized).font(COSType.body(12, weight: .semibold))
                        Text(activity.receipt.detail).font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                        Text(Date(timeIntervalSince1970: activity.receipt.createdAt), style: .date).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                    }
                }
                Divider().overlay(COSPalette.line)
                Text(activity.session?.title ?? activity.receipt.sessionTitle).font(COSType.body(13, weight: .medium))
                Text("Session: " + activity.sessionState).font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                if let session = activity.session {
                    if let failure = session.failure, !failure.isEmpty { Text(failure).font(COSType.body(12)).foregroundStyle(COSPalette.danger) }
                    if let waiting = session.waitingDetail, !waiting.isEmpty { Text(waiting).font(COSType.body(12)).foregroundStyle(COSPalette.accent) }
                    if !session.summary.isEmpty { Text(session.summary).font(COSType.body(12)).lineLimit(3) }
                }
                if let result = activity.receipt.result, !result.isEmpty {
                    Text(result).font(COSType.body(12)).lineLimit(4)
                }
                if let sessionID = activity.receipt.sessionID {
                    Button("Open session") { handoffStore.selectedWorkID = source.id; onOpenSession(sessionID) }.buttonStyle(COSQuietButtonStyle())
                }
                Text("Session activity is current context. The handoff result and task completion are tracked separately.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(COSPalette.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(COSPalette.line))
        }
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
