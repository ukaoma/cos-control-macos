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
    static func latest(workID: String, receipts: [WorkHandoffReceipt]) -> WorkTracking? {
        let mine = receipts.filter { $0.workID == workID }
        if let question = mine.filter({ row in
            guard !row.handledByYou, !["failed", "refused", "canceled"].contains(row.status),
                  row.progress?.reported == .needsInput || row.progress?.reported == .blocked else { return false }
            let at = row.progress?.receivedAt ?? row.createdAt
            return !mine.contains { next in next.id != row.id && next.createdAt > at && (["delivered", "running", "completed"].contains(next.status) || (next.status == "reviewed" && next.progress?.receivedAt != nil)) }
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
        for receipt in receipts where WorkProgress.workingSession(receipt) == sessionID && receipt.progress != nil
            && (newest[receipt.workID]?.createdAt ?? -1) < receipt.createdAt { newest[receipt.workID] = receipt }
        return newest.values.sorted { $0.createdAt < $1.createdAt }.compactMap { latest(workID: $0.workID, receipts: receipts) }
            .filter { WorkProgress.workingSession($0.receipt) == sessionID }
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
