import AppKit
import QuickLook
import SwiftUI

/// 0.5.247: what the board and the Agent workspace show for a tracked handoff.
///
/// Found by work id, never by revision: a task's revision hashes its whole tasks file, so COS's own stage moves (and any
/// other edit to that file) change it, and a revision-matched lookup would drop the handoff off the card right after
/// COS moved it.
struct WorkTracking {
    enum Phase: Int, Comparable {
        case sent, received, working, done, needsInput, blocked
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }
    let receipt: WorkHandoffReceipt
    let progress: WorkProgress
    let phase: Phase

    /// The newest handoff for this work, when it asked for a status line and did not fail. A failed, refused or
    /// canceled newest handoff shows nothing here: the existing handoff state already explains it.
    static func latest(workID: String, receipts: [WorkHandoffReceipt], sessionID: String? = nil) -> WorkTracking? {
        let mine = receipts.filter { $0.workID == workID && (sessionID == nil || WorkProgress.workingSession($0)?.lowercased() == sessionID?.lowercased()) }
        if let question = mine.filter({ row in
            guard !row.handledByYou, !["failed", "refused", "canceled"].contains(row.status),
                  row.progress?.reported == .needsInput || row.progress?.reported == .blocked else { return false }
            let at = row.progress?.receivedAt ?? row.createdAt
            return !mine.contains { next in next.id != row.id && WorkProgress.workingSession(next)?.lowercased() == WorkProgress.workingSession(row)?.lowercased() && next.createdAt > at && (["delivered", "running", "completed"].contains(next.status) || (next.status == "reviewed" && next.progress?.receivedAt != nil)) }
        }).max(by: { $0.createdAt < $1.createdAt }), let progress = question.progress {
            return WorkTracking(receipt: question, progress: progress, phase: phase(question, progress))
        }
        guard let receipt = mine.max(by: { $0.createdAt < $1.createdAt }),
              let progress = receipt.progress, !["refused", "failed", "canceled"].contains(receipt.status), !receipt.clearedUnconfirmed
        else { return nil }
        return WorkTracking(receipt: receipt, progress: progress, phase: phase(receipt, progress))
    }
    static func phase(_ receipt: WorkHandoffReceipt, _ progress: WorkProgress) -> Phase {
        switch progress.reported {
        case .done?: return .done
        case .needsInput?: return .needsInput
        case .blocked?: return .blocked
        default: break
        }
        if progress.workingAt != nil { return .working }
        if progress.receivedAt != nil || WorkProgress.deliveryConfirmed(receipt) { return .received }
        return .sent
    }
    /// The tracked tasks a session holds now, oldest first: newest handoff per task, still with this session, and not
    /// done more than a day ago. The card shows the first `cardRows`.
    static func forSession(_ sessionID: String, receipts: [WorkHandoffReceipt], now: Double = Date().timeIntervalSince1970) -> [WorkTracking] {
        var newest: [String: WorkHandoffReceipt] = [:]
        for receipt in receipts where WorkProgress.workingSession(receipt)?.lowercased() == sessionID.lowercased() && receipt.progress != nil
            && (newest[receipt.workID]?.createdAt ?? -1) < receipt.createdAt { newest[receipt.workID] = receipt }
        return newest.values.sorted { $0.createdAt < $1.createdAt }.compactMap { latest(workID: $0.workID, receipts: receipts, sessionID: sessionID) }
            .filter { WorkProgress.workingSession($0.receipt)?.lowercased() == sessionID.lowercased() }
            .filter { $0.phase != .done || now - ($0.progress.events.last?.at ?? $0.receipt.createdAt) < 86_400 }
    }
    nonisolated static let cardRows = 4

    var label: String {
        switch phase {
        case .sent: "Sent"
        case .received: "Received"
        case .working: "Working"
        case .done: "Done"
        case .needsInput: receipt.handledByYou ? "Handled" : receipt.status == "reviewed" ? "Reviewed, not answered" : "Needs your input"
        case .blocked: receipt.handledByYou ? "Handled" : "Blocked"
        }
    }
    /// For a session card's task rows.
    var shortLabel: String { phase == .needsInput && !receipt.handledByYou ? "Needs input" : label }
    var tint: Color {
        switch phase {
        case .sent: COSPalette.muted
        case .received, .working: COSPalette.green
        case .done: COSPalette.accent
        case .needsInput: receipt.handledByYou ? COSPalette.muted : COSPalette.amber
        case .blocked: receipt.handledByYou ? COSPalette.muted : COSPalette.danger
        }
    }
    /// A reported state that says more than the live handoff line can. A question you already handled (you reviewed
    /// or acknowledged the reply) no longer leads.
    var reported: Bool { phase == .done || asksForYou }
    var asksForYou: Bool { (phase == .needsInput || phase == .blocked) && !receipt.handledByYou }
    var evidence: String? { reported ? progress.evidence : nil }
    /// Done came from Jev's reading, not from the session's own line: never shown as the session's words.
    var byJev: Bool { progress.reportedBy == "jev" }
    var decisionProvider: DecisionProvider? { progress.reportedBy.flatMap(DecisionProvider.init(rawValue:)) }
    var byDecisionModel: Bool { decisionProvider != nil }

    /// The automatic move this card can still undo: the newest one, while the card sits where COS put it.
    func undoableMove(currentStage: String?) -> WorkProgressEvent? {
        guard progress.paused != true, let move = receipt.lastAutomaticMove, WorkProgress.canUndo(move, currentStage: currentStage) else { return nil }
        return move
    }
    nonisolated static func whyLine(_ move: WorkProgressEvent) -> String {
        "Moved here at " + clock(move.at) + ": " + move.text + "."
    }
    nonisolated static func clock(_ at: Double) -> String {
        Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)
    }
}

/// "● Done · Launch copy review" on a Kanban card or a session card's task row.
struct WorkTrackingLine: View {
    let tracking: WorkTracking
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            WorkTrackingDot(phase: tracking.phase, tint: tracking.tint)
            Text(tracking.label + " · " + tracking.receipt.sessionTitle)
                .font(COSType.body(10.5, weight: .semibold)).foregroundStyle(tracking.tint).lineLimit(2)
        }
    }
}

/// Solid for a state the session reported or is acting on; hollow while it has only received the work.
struct WorkTrackingDot: View {
    let phase: WorkTracking.Phase
    let tint: Color
    var body: some View {
        Group {
            if phase == .sent || phase == .received { Circle().strokeBorder(tint, lineWidth: 1.5) } else { Circle().fill(tint) }
        }.frame(width: 7, height: 7)
    }
}

/// The Progress timeline in the Agent workspace: every step of the newest tracked handoff, with Undo on moves.
struct WorkProgressTimeline: View {
    let tracking: WorkTracking
    /// The card's stage now; nil for work with no stage (a meeting review).
    let currentStage: String?
    /// Nil where no tracker runs (previews): no Undo, and no promise about moves.
    var onUndo: ((String, String) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Progress").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted).padding(.bottom, 8)
            let events = tracking.progress.events.filter { $0.kind != .moved }
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                let moves = movesAfter(event)
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        marker(event.kind).padding(.top, 4)
                        if index < events.count - 1 { Rectangle().fill(COSPalette.line).frame(width: 1).frame(maxHeight: .infinity) }
                    }.frame(width: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.text).font(COSType.body(12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        ForEach(moves) { move in moveLine(move) }
                        Text(WorkTracking.clock(event.at)).font(COSType.mono(10)).foregroundStyle(COSPalette.muted)
                    }.padding(.bottom, 12)
                }
            }
            if currentStage != nil && onUndo != nil {
                Text(tracking.progress.paused == true ? "COS leaves this card where you put it."
                                                      : "COS moves this card as far as QA. Complete is yours.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel("Progress")
    }

    /// Moves recorded after this event and before the next shown one sit under it, where they happened.
    private func movesAfter(_ event: WorkProgressEvent) -> [WorkProgressEvent] {
        let all = tracking.progress.events
        guard let start = all.firstIndex(where: { $0.id == event.id }) else { return [] }
        var out: [WorkProgressEvent] = []
        for next in all[(start + 1)...] {
            if next.kind == .moved { out.append(next) } else { break }
        }
        return out
    }
    private func moveLine(_ move: WorkProgressEvent) -> some View {
        HStack(spacing: 6) {
            Text("Moved from " + WorkProgress.stageTitle(move.fromStage ?? "") + " to " + WorkProgress.stageTitle(move.toStage ?? ""))
                .font(COSType.body(11)).foregroundStyle(move.undoneAt == nil ? COSPalette.accent : COSPalette.muted)
                .strikethrough(move.undoneAt != nil)
            if let onUndo, tracking.progress.paused != true, move.id == tracking.receipt.lastAutomaticMove?.id,
               WorkProgress.canUndo(move, currentStage: currentStage) {
                Button("Undo") { onUndo(tracking.receipt.id, move.id) }.buttonStyle(COSTextButtonStyle()).controlSize(.small)
                    .accessibilityLabel("Undo the move to " + WorkProgress.stageTitle(move.toStage ?? ""))
                    .help("Move the card back to " + WorkProgress.stageTitle(move.fromStage ?? "") + ". COS will not move it again for this handoff.")
            }
        }
    }
    private func marker(_ kind: WorkProgressEvent.Kind) -> some View {
        let tint: Color = switch kind {
        case .sent, .note: COSPalette.muted
        case .received, .working: COSPalette.green
        case .done, .jev: COSPalette.accent
        case .needsInput: COSPalette.amber
        case .blocked: COSPalette.danger
        case .moved, .undone: COSPalette.accent
        }
        return Group {
            if kind == .sent || kind == .received || kind == .note { Circle().strokeBorder(tint, lineWidth: 1.5) } else { Circle().fill(tint) }
        }.frame(width: 9, height: 9)
    }
}

/// 0.5.247 (3A): the newest automatic move, over the columns, while it can still be undone and for 30 minutes. Observes
/// the tracker, so Dismiss and a new move show at once, and re-checks the 30 minutes every minute.
struct WorkLatestMoveStrip: View {
    @ObservedObject var tracker: WorkProgressTracker
    @ObservedObject var store: WorkHandoffStore
    /// The item's title and its card's stage now, by work id.
    let lookup: (String) -> (title: String, stage: String?)?
    let onUndo: (String, String) -> Void
    nonisolated static let shownFor: Double = 30 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let shown = Self.shown(latest: tracker.latestMove, receipts: store.receipts, lookup: lookup,
                                      now: context.date.timeIntervalSince1970) {
                HStack(spacing: 10) {
                    Self.text(shown).font(COSType.body(12)).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Undo") { onUndo(shown.receipt.id, shown.move.id) }.buttonStyle(COSTextButtonStyle()).controlSize(.small)
                        .help("Move it back to " + WorkProgress.stageTitle(shown.move.fromStage ?? "") + ". COS will not move it again for this handoff.")
                        .accessibilityLabel("Undo the move to " + WorkProgress.stageTitle(shown.move.toStage ?? ""))
                    Button("Dismiss") { tracker.dismissLatestMove() }.buttonStyle(COSTextButtonStyle()).controlSize(.small)
                        .help("Hide this line. The card keeps its note and Undo.")
                }.padding(.horizontal, 12).padding(.vertical, 8)
                    .background(COSPalette.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.gold.opacity(0.3)))
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
    }

    struct Shown { let receipt: WorkHandoffReceipt; let move: WorkProgressEvent; let title: String }
    /// The move to show: the tracker's newest, under 30 minutes old, not paused, on a card still where COS put it.
    nonisolated static func shown(latest: (receiptID: String, eventID: String)?, receipts: [WorkHandoffReceipt],
                                  lookup: (String) -> (title: String, stage: String?)?, now: Double) -> Shown? {
        guard let latest, let receipt = receipts.first(where: { $0.id == latest.receiptID }), receipt.progress?.paused != true,
              let move = receipt.progress?.events.first(where: { $0.id == latest.eventID }), now - move.at < shownFor,
              let item = lookup(receipt.workID), WorkProgress.canUndo(move, currentStage: item.stage) else { return nil }
        return Shown(receipt: receipt, move: move, title: item.title)
    }
    /// "Moved “Draft the homepage CTA” to QA. The session reported done: “Updated the hero CTA…”"
    nonisolated static func text(_ shown: Shown) -> Text {
        let plain: String = shown.title.replacingOccurrences(of: "**", with: "")
        let title: String = "\u{201C}" + WorkSendPlan.clip(plain, 60) + "\u{201D}"
        let reason: String = shown.move.text.prefix(1).uppercased() + String(shown.move.text.dropFirst())
        // The session's own words belong to a move its done line made; Jev's reading is not quoted as the session's.
        let quote = shown.move.toStage == "qa" && shown.receipt.progress?.reportedBy == "session"
        var evidence: String = "."
        if quote, let said = shown.receipt.progress?.evidence { evidence = ": \u{201C}" + WorkProgress.clip(said, 140) + "\u{201D}" }
        let tail: String = " to " + WorkProgress.stageTitle(shown.move.toStage ?? "") + ". " + reason + evidence
        return Text("Moved ") + Text(title).fontWeight(.semibold) + Text(tail)
    }
}

// MARK: - 0.5.312 Connections: context, outputs, changes (design/work-context-mock.html, right column)

/// What the helper's `work-session-meter` returned for one linked session. Paths and counts only.
struct WorkSessionMeterSnapshot: Equatable {
    struct Output: Equatable, Identifiable {
        let path: String
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var image: Bool { WorkSessionMeter.isImage(path) }
    }
    var context: WorkSessionMeter.Context?
    var outputs: [Output] = []
    var outputsTotal = 0
    var outputsPartial = false
    var cwd: String?
    /// Nil until the handoff time and the working folder are both known; then git's answer (not a repo reads as no changes).
    var changes: WorkSessionMeter.Changes?
    var changesKnown = false
    var perFile: [WorkSessionMeter.FileChange] = []

    /// `known: false` (no transcript, an unsupported provider) is nil: the card shows nothing, never 0%.
    static func parse(_ details: [String: JSONValue]) -> Self? {
        guard details["known"]?.bool == true else { return nil }
        var snapshot = Self()
        if let context = details["context"]?.object, let used = context["used"]?.int, let window = context["window"]?.int, used > 0, window > 0 {
            snapshot.context = WorkSessionMeter.Context(used: used, window: window, model: context["model"]?.string ?? "")
        }
        snapshot.outputs = details["outputs"]?.array?.compactMap { $0.object?["path"]?.string }.filter { $0.hasPrefix("/") }.map { Output(path: $0) } ?? []
        snapshot.outputsTotal = max(details["outputsTotal"]?.int ?? 0, snapshot.outputs.count)
        snapshot.outputsPartial = details["outputsPartial"]?.bool == true
        snapshot.cwd = details["cwd"]?.string
        if let changes = details["changes"]?.object {
            snapshot.changesKnown = changes["failed"]?.bool != true
            if changes["repo"]?.bool == true, changes["failed"]?.bool != true {
                snapshot.changes = WorkSessionMeter.Changes(files: changes["files"]?.int ?? 0, insertions: changes["insertions"]?.int ?? 0,
                                                            deletions: changes["deletions"]?.int ?? 0)
                snapshot.perFile = changes["perFile"]?.array?.compactMap { row -> WorkSessionMeter.FileChange? in
                    guard let item = row.object, let path = item["path"]?.string else { return nil }
                    return WorkSessionMeter.FileChange(path: path, insertions: item["insertions"]?.int, deletions: item["deletions"]?.int)
                } ?? []
            }
        }
        return snapshot
    }
}

/// Backs the Connections cards' meters, and the assignment meters through `sessionContextWindow`.
/// Read through the helper (bounded transcript tail, read-only git), cached for `ttl`, refreshed while a card is visible.
@MainActor final class WorkSessionMeterStore: ObservableObject {
    static let shared = WorkSessionMeterStore()
    static let ttl: TimeInterval = 30
    typealias Transport = @Sendable ([String]) async throws -> HelperResponse
    @Published private(set) var snapshots: [String: WorkSessionMeterSnapshot] = [:]
    /// Newest context per session, whatever handoff it was read for.
    @Published private(set) var contexts: [String: WorkSessionMeter.Context] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let transport: Transport

    init(transport: Transport? = nil) {
        let helper = HelperClient()
        self.transport = transport ?? { args in try await helper.run(args, timeout: 15) }
    }

    static func key(_ sessionID: String, since: Double?) -> String {
        sessionID.lowercased() + "|" + (since.map { String(Int($0)) } ?? "-")
    }

    func snapshot(_ sessionID: String, since: Double?) -> WorkSessionMeterSnapshot? { snapshots[Self.key(sessionID, since: since)] }

    /// SHARED API (0.5.312): how full a linked session's context is, as an estimate from its own transcript, or nil when
    /// unknown (never a guessed 0). `sessionID` is the Work contributor id, "claude:<uuid>" or "codex:<uuid>".
    /// Call `refresh(sessionID:since:)` to load it; this only reads what is cached.
    func sessionContextWindow(_ sessionID: String) -> (used: Int, window: Int)? {
        contexts[sessionID.lowercased()].map { ($0.used, $0.window) }
    }

    func refresh(sessionID: String, since: Double?, force: Bool = false) async {
        let id = sessionID.lowercased()
        let key = Self.key(id, since: since)
        guard !inFlight.contains(key) else { return }
        if !force, let at = fetchedAt[key], Date().timeIntervalSince(at) < Self.ttl { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        var args = ["work-session-meter", "--session", id]
        if let since, since.isFinite, since > 0 { args += ["--since", String(format: "%.3f", since)] }
        guard let response = try? await transport(args), response.ok else { return }
        fetchedAt[key] = Date()
        let snapshot = WorkSessionMeterSnapshot.parse(response.details)
        if snapshots[key] != snapshot { snapshots[key] = snapshot }
        if let context = snapshot?.context { contexts[id] = context } else if snapshot == nil { contexts[id] = nil }
    }
}

/// Context, Outputs and Changes on one linked session card. Every section is hidden while unknown: no transcript, no
/// usage line, or a provider COS cannot read never shows 0%.
struct WorkSessionMeterSections: View {
    @ObservedObject var store: WorkSessionMeterStore
    let sessionID: String
    /// The handoff time (receipt or link), epoch seconds. Outputs and Changes are scoped to it.
    let since: Double?
    @State private var showAllOutputs = false
    @State private var reviewing = false
    @State private var preview: URL?

    private var snapshot: WorkSessionMeterSnapshot? { store.snapshot(sessionID, since: since) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = snapshot?.context { contextSection(context) }
            if let snapshot, !snapshot.outputs.isEmpty { outputsSection(snapshot) }
            if let snapshot, since != nil, snapshot.cwd != nil, snapshot.changesKnown { changesSection(snapshot) }
        }
        .quickLookPreview($preview)
        // Refresh while the card is on screen; the task ends when it leaves.
        .task(id: WorkSessionMeterStore.key(sessionID, since: since)) {
            while !Task.isCancelled {
                await store.refresh(sessionID: sessionID, since: since)
                try? await Task.sleep(for: .seconds(WorkSessionMeterStore.ttl))
            }
        }
    }

    private func header(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(COSType.body(12.5, weight: .semibold))
            Spacer(minLength: 6)
            if let value { Text(value).font(COSType.mono(11)).foregroundStyle(COSPalette.muted) }
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(COSPalette.line).frame(height: 1) }
    }

    /// "24% · 124k / 512k" and a bar; orange with the compacting line at 85% and above (mock, second card).
    private func contextSection(_ context: WorkSessionMeter.Context) -> some View {
        section {
            header("Context", context.label)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(WorkSessionMeterColors.free)
                    Capsule().fill(context.nearlyFull ? WorkSessionMeterColors.warn : WorkSessionMeterColors.used)
                        .frame(width: max(2, geo.size.width * context.fraction))
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Context \(context.percent) percent used")
            if context.nearlyFull {
                Text(WorkSessionMeter.compactingNote)
                    .font(COSType.body(12, weight: .semibold)).foregroundStyle(WorkSessionMeterColors.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("An estimate from this session's own transcript: what its last turn held, against its model's window.")
    }

    /// Newest first, three, then Show N more. Click opens the file; Space or the menu previews it with Quick Look.
    private func outputsSection(_ snapshot: WorkSessionMeterSnapshot) -> some View {
        let shown = showAllOutputs ? snapshot.outputs : Array(snapshot.outputs.prefix(3))
        return section {
            header("Outputs", "\(snapshot.outputsTotal)")
            ForEach(shown) { output in
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: output.path)) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: output.image ? "photo" : "doc.text").font(.system(size: 11)).foregroundStyle(COSPalette.muted)
                            .frame(width: 13)
                        Text(output.name).font(COSType.body(12.5)).lineLimit(1).truncationMode(.middle)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(output.path)
                .onKeyPress(.space) { preview = URL(fileURLWithPath: output.path); return .handled }
                .contextMenu {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: output.path)) }
                    Button("Quick Look") { preview = URL(fileURLWithPath: output.path) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output.path)]) }
                }
            }
            if snapshot.outputs.count > 3 {
                Button(showAllOutputs ? "Show fewer" : "Show \(snapshot.outputs.count - 3) more") { showAllOutputs.toggle() }
                    .buttonStyle(COSTextButtonStyle()).font(COSType.body(12))
            }
            if snapshot.outputsPartial {
                Text("Earlier files from this handoff are not listed.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
        }
    }

    /// "+1,284 −312 · 9 files · since this handoff" with Review changes, or the quiet line (mock).
    private func changesSection(_ snapshot: WorkSessionMeterSnapshot) -> some View {
        section {
            header("Changes", nil)
            HStack(spacing: 10) {
                if let changes = snapshot.changes, !changes.isEmpty {
                    Text("+" + Self.grouped(changes.insertions)).foregroundStyle(WorkSessionMeterColors.added)
                    Text("−" + Self.grouped(changes.deletions)).foregroundStyle(WorkSessionMeterColors.removed)
                    Text("\(changes.files) \(changes.files == 1 ? "file" : "files") · since this handoff").foregroundStyle(COSPalette.muted)
                    Spacer(minLength: 6)
                    Button(reviewing ? "Hide changes" : "Review changes") { reviewing.toggle() }.buttonStyle(COSQuietButtonStyle()).controlSize(.small)
                } else {
                    Text(WorkSessionMeter.noChanges).foregroundStyle(COSPalette.muted)
                }
            }
            .font(COSType.mono(12.5, weight: .semibold))
            // Work overlays are inline, never sheets (Tests/run.sh): the review opens in the card.
            if reviewing, let changes = snapshot.changes, !changes.isEmpty { reviewList(snapshot) }
        }
    }

    private func reviewList(_ snapshot: WorkSessionMeterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(snapshot.perFile, id: \.path) { row in
                        HStack(spacing: 8) {
                            Text(row.insertions.map { "+\($0)" } ?? "bin").foregroundStyle(WorkSessionMeterColors.added).frame(width: 52, alignment: .trailing)
                            Text(row.deletions.map { "−\($0)" } ?? "").foregroundStyle(WorkSessionMeterColors.removed).frame(width: 52, alignment: .trailing)
                            Text(row.path).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        }
                        .font(COSType.mono(11))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(180, CGFloat(max(1, snapshot.perFile.count)) * 17 + 4))
            HStack(spacing: 8) {
                Text("Read-only: git diff since this handoff, including uncommitted work in this folder.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                Spacer(minLength: 6)
                if let cwd = snapshot.cwd {
                    Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd, isDirectory: true)) }
                        .buttonStyle(COSTextButtonStyle()).font(COSType.body(11.5))
                }
            }
        }
        .padding(8)
        .background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}

/// The mock's meter colors (blue used, orange near full, green and red diff counts), light and dark.
enum WorkSessionMeterColors {
    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let used = adaptive((0.247, 0.455, 0.784), (0.427, 0.608, 0.902))
    static let warn = adaptive((0.710, 0.337, 0.173), (0.878, 0.478, 0.290))
    static let free = adaptive((0.890, 0.851, 0.784), (0.208, 0.173, 0.141))
    static let added = adaptive((0.184, 0.541, 0.290), (0.361, 0.761, 0.478))
    static let removed = adaptive((0.753, 0.224, 0.169), (0.925, 0.420, 0.361))
}
