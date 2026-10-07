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

// MARK: - 0.5.262: what COS moved, on the card and in Moved for you

/// The persistent mark on a board card (Miles, 2026-10-07: "the visual cue that we leave on the card to let the user
/// know, when they come back, what's been automated or moved"). It stays until you open the card or say Got it:
/// "Moved by COS · 2h ago", "COS would move this · 2h ago" in shadow mode, and "1 of 2 met · waiting: …" while the
/// finish line is partly met. Observes the move log and the follows itself, so a new move marks one card and never
/// rebuilds the board.
struct WorkCardMoveMark: View {
    @ObservedObject var moves: WorkMoveLog
    @ObservedObject var follows: WorkFollowStore
    let workID: String
    var now: Date = Date()

    var body: some View {
        let mark = moves.mark(workID: workID)
        let partial = follows.card(workID).partialLine
        if mark != nil || partial != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let mark {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        WorkMoveMarkDot(shadow: mark.shadow)
                        Text(mark.mark(now: now.timeIntervalSince1970))
                            .font(COSType.body(10.5, weight: .semibold)).foregroundStyle(mark.shadow ? COSPalette.muted : COSPalette.accent).lineLimit(1)
                    }
                    .help(mark.history)
                }
                if let partial {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        WorkPartialGlyph(met: follows.card(workID).partial?.met ?? 0, of: follows.card(workID).partial?.of ?? 0)
                        Text(partial).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).lineLimit(2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Solid gold for a move COS made; a hollow ring for one it would make (shadow mode).
struct WorkMoveMarkDot: View {
    let shadow: Bool
    var body: some View {
        Group {
            if shadow { Circle().strokeBorder(COSPalette.muted, lineWidth: 1.5) } else { Circle().fill(COSPalette.gold) }
        }.frame(width: 7, height: 7)
    }
}

/// "1 of 2": one small tick per part, filled when met.
struct WorkPartialGlyph: View {
    let met: Int
    let of: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<max(of, 0), id: \.self) { index in
                RoundedRectangle(cornerRadius: 1).fill(index < met ? COSPalette.accent : COSPalette.line).frame(width: 6, height: 6)
            }
        }
    }
}

/// One clause's evidence line: "200 · Switch to Bottle POS: $3,000 + Free Hardware · url · 4:31 PM".
enum WorkClauseText {
    static func state(_ clause: WorkClauseState?) -> String {
        guard let clause else { return "Not checked yet" }
        if clause.met { return "Met" }
        switch clause.verdict {
        case "met": return clause.kind == "fact" ? "Met, without evidence COS can point to" : "Said, not shown (\(clause.kind))"
        case "not_met": return "Not met yet"
        default: return "Not clear yet"
        }
    }
    static func evidence(_ clause: WorkClauseState?) -> String? {
        guard let evidence = clause?.evidence else { return nil }
        var parts: [String] = []
        if let excerpt = evidence.excerpt, !excerpt.isEmpty { parts.append("\u{201C}" + WorkProgress.clip(excerpt, 140) + "\u{201D}") }
        parts.append(source(evidence.source))
        if let at = evidence.at.flatMap(WorkProgress.parseStamp) { parts.append(WorkTracking.clock(at)) }
        return parts.joined(separator: " \u{00B7} ")
    }
    static func source(_ raw: String?) -> String {
        switch raw {
        case "url": return "the page"
        case "session": return "the session"
        case "slack": return "Slack"
        case "meeting": return "a linked meeting"
        case "file": return "a card file"
        case let other?: return other
        case nil: return "no source"
        }
    }
}

/// The card detail's finish line: each part with its state and evidence, what COS moved and why, and which sessions the
/// card follows. Replaces the plain Done when line.
struct WorkFinishLineSection: View {
    @ObservedObject var moves: WorkMoveLog
    @ObservedObject var follows: WorkFollowStore
    let task: TaskRow
    let shadow: Bool
    /// Nil where no tracker runs (previews): no Undo.
    var onUndo: ((String) -> Void)?
    var onEditTask: (() -> Void)?
    var onStopFollowing: (() -> Void)?
    var now: Date = Date()

    private var workID: String { task.workSourceID }

    var body: some View {
        let clauses = WorkFinishLine.clauses(task.doneWhen)
        let card = follows.card(workID)
        let following = follows.follows(for: workID)
        VStack(alignment: .leading, spacing: 10) {
            Text("Done when").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
            if clauses.isEmpty {
                Text("No finish line recorded. Use Edit task to define one.").font(COSType.body(13))
                if !following.isEmpty {
                    HStack(spacing: 8) {
                        Text("Add a finish line so COS can move this on evidence. Until then it needs the task itself shown done in two places.")
                            .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                        if let onEditTask { Button("Add a finish line") { onEditTask() }.buttonStyle(COSTextButtonStyle()) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(clauses.enumerated()), id: \.offset) { index, text in
                        clauseRow(text, Self.state(for: text, at: index, card: card))
                    }
                }
                if let partial = card.partial {
                    Text("\(partial.met) of \(partial.of) met").font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted)
                }
            }
            if let note = card.note { Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
            let history = moves.history(workID: workID).prefix(4)
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(history)) { entry in historyRow(entry) }
                }.padding(.top, 4)
            }
            followLine(following, card: card)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel("Finish line")
    }

    /// The newest verdict for this part: by its text, else by its place (the server may tidy the text it echoes).
    nonisolated static func state(for text: String, at index: Int, card: WorkCardFollowState) -> WorkClauseState? {
        guard card.basis == "clauses", let clauses = card.clauses else { return nil }
        return clauses.first { $0.text == text } ?? (clauses.indices.contains(index) ? clauses[index] : nil)
    }

    private func clauseRow(_ text: String, _ state: WorkClauseState?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if state?.met == true { Circle().fill(COSPalette.accent) } else { Circle().strokeBorder(COSPalette.muted, lineWidth: 1.5) }
            }.frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(COSType.body(13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(WorkClauseText.state(state) + (WorkClauseText.evidence(state).map { " \u{00B7} " + $0 } ?? ""))
                    .font(COSType.body(11)).foregroundStyle(state?.met == true ? COSPalette.accent : COSPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func historyRow(_ entry: WorkMoveEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            WorkMoveMarkDot(shadow: entry.shadow).opacity(entry.byCOS ? 1 : 0.4)
            Text(entry.history + " \u{00B7} " + WorkMoveEntry.ago(entry.line.at, now: now.timeIntervalSince1970)
                 + (entry.undoneAt != nil ? " \u{00B7} undone" : ""))
                .font(COSType.body(11.5)).foregroundStyle(entry.undoneAt != nil ? COSPalette.muted : Color.primary)
                .strikethrough(entry.undoneAt != nil).fixedSize(horizontal: false, vertical: true)
            if let onUndo, entry.byCOS, !entry.shadow, entry.undoneAt == nil,
               entry.line.to == (task.checked ? "complete" : task.workStage) {
                Button("Undo") { onUndo(entry.id) }.buttonStyle(COSTextButtonStyle()).controlSize(.small)
                    .help("Move it back to " + WorkProgress.stageTitle(entry.line.from ?? "") + ". COS stops following this card until you move it forward.")
            }
        }
    }

    @ViewBuilder private func followLine(_ following: [WorkFollow], card: WorkCardFollowState) -> some View {
        if !following.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if card.paused {
                    Text((card.pausedWhy.map { $0 + " " } ?? "") + "COS stopped following this card. Move it forward yourself to start again.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Following " + (following.count == 1 ? "1 session" : "\(following.count) sessions")
                         + (shadow ? ". COS shows what it would move and moves nothing." : ". COS moves it to QA when every part is met."))
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                    if let onStopFollowing { Button("Stop following") { onStopFollowing() }.buttonStyle(COSTextButtonStyle()).controlSize(.small) }
                }
            }
        }
    }
}

/// Moved for you: every move COS made, and every one it would have made in shadow mode, that you have not undone or
/// acknowledged. Read from the move log (work-moves.jsonl), never from receipts, so a move stays here however long ago it
/// was made.
struct WorkMovedForYouView: View {
    @ObservedObject var moves: WorkMoveLog
    @ObservedObject var follows: WorkFollowStore
    let shadow: Bool
    /// The card's title and stage now, by work id.
    let lookup: (String) -> (title: String, stage: String?)?
    var onUndo: ((String) -> Void)?
    let onOpen: (String) -> Void
    var now: Date = Date()

    var body: some View {
        let entries = moves.movedForYou
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Moved for you").font(COSType.display(23, weight: .medium))
                Text(shadow ? "Shadow mode is on: COS lists what it would move and moves nothing. Turn it off in Settings when these look right."
                            : "What COS moved since you last looked, and why. Undo puts a card back, and COS stops following it until you move it forward.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                if entries.isEmpty {
                    Text("Nothing new. Moves COS makes on evidence show here until you open the card or say Got it.")
                        .font(COSType.body(12.5)).foregroundStyle(COSPalette.muted).padding(.top, 6)
                }
                ForEach(entries) { entry in row(entry) }
            }.frame(maxWidth: 720, alignment: .leading).padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ entry: WorkMoveEntry) -> some View {
        let item = lookup(entry.line.workID)
        let title = (item?.title ?? entry.line.title ?? "A card no longer on the board").replacingOccurrences(of: "**", with: "")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WorkMoveMarkDot(shadow: entry.shadow)
                Text(entry.mark(now: now.timeIntervalSince1970)).font(COSType.body(11, weight: .semibold))
                    .foregroundStyle(entry.shadow ? COSPalette.muted : COSPalette.accent)
                Spacer(minLength: 8)
                Text(WorkProgress.stageTitle(entry.line.from ?? "") + " to " + WorkProgress.stageTitle(entry.line.to ?? ""))
                    .font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted)
            }
            Button { onOpen(entry.line.workID) } label: {
                Text(title).font(COSType.body(13.5, weight: .medium)).multilineTextAlignment(.leading).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open this card")
            if let why = entry.line.why, !why.isEmpty {
                Text(why.prefix(1).uppercased() + why.dropFirst() + ".").font(COSType.body(12)).fixedSize(horizontal: false, vertical: true)
            }
            if let clauses = entry.line.clauses, !clauses.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(clauses.enumerated()), id: \.offset) { _, clause in
                        HStack(alignment: .top, spacing: 8) {
                            Group {
                                if clause.verdict == "met" { Circle().fill(COSPalette.accent) } else { Circle().strokeBorder(COSPalette.muted, lineWidth: 1.5) }
                            }.frame(width: 7, height: 7).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(clause.text).font(COSType.body(12)).fixedSize(horizontal: false, vertical: true)
                                Text(evidenceLine(clause)).font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let onUndo, !entry.shadow, entry.byCOS, item?.stage == entry.line.to {
                    Button("Undo") { onUndo(entry.id) }.buttonStyle(COSTextButtonStyle())
                        .help("Move it back to " + WorkProgress.stageTitle(entry.line.from ?? "") + ". COS stops following this card until you move it forward.")
                }
                Button("Got it") { moves.acknowledge(moveID: entry.id, at: Date().timeIntervalSince1970) }.buttonStyle(COSTextButtonStyle())
                    .help("Clear this from Moved for you and from the card")
                Spacer(minLength: 0)
            }
        }.padding(14)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(entry.shadow ? COSPalette.line : COSPalette.gold.opacity(0.45)))
    }

    private func evidenceLine(_ clause: WorkMoveClause) -> String {
        var parts: [String] = [clause.verdict == "met" ? "Met" : clause.verdict == "not_met" ? "Not met" : "Not clear"]
        if let excerpt = clause.excerpt, !excerpt.isEmpty { parts.append("\u{201C}" + WorkProgress.clip(excerpt, 140) + "\u{201D}") }
        if clause.source != nil { parts.append(WorkClauseText.source(clause.source)) }
        if let at = clause.at.flatMap(WorkProgress.parseStamp) { parts.append(WorkTracking.clock(at)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// 0.5.262, in Settings: shadow mode for moves on evidence (on until Miles has reviewed a week of would-moves), and the
/// Work background model, the one the end-of-day Slack sweep uses (a standing, unattended cost).
struct WorkEvidenceSettingsRows: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Only show what COS would move", isOn: Binding(get: { model.workEvidenceShadow }, set: { model.workEvidenceShadow = $0 }))
                .toggleStyle(COSSwitchStyle())
                .help("COS checks the evidence on the cards it follows and lists what it would move to QA under Moved for you, without moving anything. Turn this off to let it move cards. A session's own done line moves a card either way")
            VStack(alignment: .leading, spacing: 6) {
                COSDropdown("Work background model", selection: Binding(get: { model.workSweepModel }, set: { model.workSweepModel = $0 }),
                            options: WorkSweepModel.allCases.map { COSDropdownOption($0, $0.title) })
                Text("Runs once each weekday at 4:30 PM to collect Slack evidence for your Work cards. Haiku only gathers messages; Jev makes the call, so the cheaper model is enough.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                if let error = model.workSweepModelError { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
            }
        }
    }
}
