import SwiftUI
import CryptoKit

extension WorkSource {
    /// A task line without its inline markdown, as the server's `taskTitle` strips it (task-store.ts) before it cuts the
    /// display title: code ticks, links (their text stays), underscore emphasis around a word or phrase (never the
    /// underscore inside an identifier such as cos_python), every asterisk, and runs of whitespace.
    nonisolated static func plainTitle(_ line: String) -> String {
        var text = line
        for (pattern, template) in [("`([^`]*)`", "$1"), ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
                                    ("(^|[\\s(])_([^_]+)_(?=[\\s).,;:!?]|$)", "$1$2"), ("\\*+", "")] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A display snapshot fingerprint, not the canonical task writer's CAS revision.
    static func taskSnapshot(_ task: TaskRow) -> WorkSource {
        var context = "Task: \(task.text.isEmpty ? task.title : task.text)\nProject: \(task.domain)\nDone when: \(task.doneWhen)\nSource: \(task.source)"
        if !task.meetingRefs.isEmpty {
            let references = task.meetingRefs.map { reference in
                "- \(reference.title) | canonical ID: \(reference.recordId) | saved source: \(reference.domain)/\(reference.month)/\(reference.filename)"
            }.joined(separator: "\n")
            context += "\nConfirmed meeting references (explicit links; transcript evidence is not included):\n" + references
        }
        let revision = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        // 0.5.251: the session name comes from the whole title (`text`; `title` is the lens row's cap). 0.5.252: with the
        // inline markdown the server's own display title drops, not only `**`.
        let whole = plainTitle(task.text.isEmpty ? task.title : task.text)
        return WorkSource(id: "task:\(task.domain):\(task.workIdentity)", title: task.title, revision: revision, project: task.domain,
                          context: context, fullTitle: whole)
    }
}

/// Sends a resolved plan exactly as the Agent workspace does. Shared with the board's Start work overlay (0.5.244).
@MainActor func sendWorkHandoff(store: WorkHandoffStore, source sendingSource: WorkSource, plan: WorkSendPlan) async {
    let sendingSession = plan.session, sendingModel = plan.model, sendingPrompt = plan.prompt
    if plan.crossPlatform, let sendingSession, let sendingModel {
        await store.forkToPlatform(source: sendingSource, session: sendingSession, model: sendingModel, prompt: sendingPrompt)
    } else {
        // A plain New session has no source session (a stale selection must not read as a fork).
        await store.submit(source: sendingSource, mode: plan.mode, session: plan.mode == .newSession ? nil : sendingSession,
                           model: sendingModel, prompt: sendingPrompt)
    }
}

/// Provider initial in a small tile, as on the board's session cards.
struct WorkProviderGlyph: View {
    let provider: String
    var body: some View {
        Text(String(WorkHandoffStore.providerName(provider).prefix(1)).uppercased())
            .font(COSType.mono(10, weight: .semibold)).foregroundStyle(COSPalette.accent)
            .frame(width: 20, height: 20).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(WorkHandoffStore.providerName(provider))
    }
}

/// Status dot. A live session pulses unless Reduce Motion is on.
struct WorkLiveDot: View {
    let color: Color
    var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(color, lineWidth: 1.5).scaleEffect(pulse ? 2.3 : 1).opacity(pulse ? 0 : (live && !reduceMotion ? 0.7 : 0)))
            // Starts when the card becomes live (queued to running) and stops when it no longer is.
            .task(id: live && !reduceMotion) {
                pulse = false
                guard live, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// How a handoff reads on the board and in the workspace's status box (0.5.244). Live session state wins over the
/// receipt: a session waiting on you or in error says so even while its receipt still reads running or delivered.
/// "Running" needs proof: a session observed running, a send in progress, or a New session job the server runs.
enum WorkHandoffState: Equatable {
    case running, awaiting, queued, waiting, replyReady, sent, attention, settled
    init(_ activity: WorkActivity) {
        let receipt = activity.receipt, status = receipt.status
        let observed = activity.observingTurn ? activity.session?.status ?? "" : ""
        if receipt.acknowledgedAt != nil || ["reviewed", "canceled"].contains(status) { self = .settled }
        else if observed == "waiting" { self = .waiting }
        else if ["error", "failed"].contains(observed) { self = .attention }
        else if activity.sessionRunning || ["preparing", "sending"].contains(status)
                    || (status == "running" && receipt.mode == .newSession) { self = .running }
        else if status == "running" { self = .awaiting }
        else if status == "queued" { self = .queued }
        else if status == "completed" { self = .replyReady }
        else if status == "delivered" { self = activity.session == nil ? .sent : .replyReady }
        else if activity.needsAttention { self = .attention }
        else { self = .settled }
    }
    var label: String {
        switch self {
        case .running: "Running"
        case .awaiting: "Awaiting delivery"
        case .queued: "Queued"
        case .waiting: "Waiting for your input"
        case .replyReady: "Reply ready for review"
        case .sent: "Sent to session"
        case .attention: "Needs attention"
        case .settled: "Done"
        }
    }
    var tint: Color {
        switch self {
        case .running: COSPalette.green
        case .awaiting, .queued, .replyReady, .sent: COSPalette.accent
        case .waiting: COSPalette.amber
        case .attention: COSPalette.danger
        case .settled: COSPalette.muted
        }
    }
    var rank: Int {
        switch self { case .running: 0; case .waiting: 1; case .attention: 2; case .replyReady: 3; case .sent: 4; case .awaiting: 5; case .queued: 6; case .settled: 7 }
    }
    /// Cards that can be acknowledged from the board: finished replies and failures, never live work.
    var offersAcknowledge: Bool { [.replyReady, .sent, .attention].contains(self) }
    /// Replies show what the session said; everything else shows why it is in this state.
    var showsReply: Bool { [.replyReady, .sent].contains(self) }
}

struct WorkHandoffView: View {
    /// 0.5.247: where a New session runs. Miles looked for a background run in Claude's sidebar, found nothing and read
    /// the handoff as lost (2026-09-29). 0.5.249: it runs in the background, then opens in its app once the first reply
    /// is done, and the card says which of those it is at.
    /// 0.5.252: how Work's history marks a handoff the glasses asked for, and one of those that was left in the background.
    nonisolated static func glassesMark(_ receipt: WorkHandoffReceipt) -> String {
        guard receipt.requestedFrom == "glasses" else { return "" }
        let background = receipt.appOpen?.skipped == WorkRequestOrigin.staysInBackground && receipt.appOpen?.openedAt == nil
        return background ? " · from the glasses · not opened in its app" : " · from the glasses"
    }
    nonisolated static func whereItRunsNote(_ receipt: WorkHandoffReceipt) -> String? {
        // 0.5.253: Cursor opens its own window, filled in, for you to send; Work follows the chat once you have.
        if receipt.channel == "prefill" {
            if WorkHandoffStore.awaitingCursorSend(receipt) {
                return "Opened in Cursor for you to send. Nothing runs until you press Send there. Work follows the chat once you do."
            }
            return receipt.sessionID != nil ? "Runs in the Cursor app, where you sent it. Open session shows it here too." : nil
        }
        guard receipt.mode == .newSession else { return nil }
        if receipt.channel == "tab" {
            // A session started from a 0.5.248 tab, which the app owns. An unsent one reads as never started.
            guard receipt.sessionID != nil else { return nil }
            return "Runs in the \(WorkHandoffStore.appName(receipt.provider)) app, where you can work with it. Open session shows it here too."
        }
        guard receipt.channel == "job" else { return nil }
        if let open = receipt.appOpen {
            let place = WorkHandoffStore.openPlace(receipt.provider)
            if open.openedAt != nil { return WorkHandoffStore.openedText(receipt.provider) }
            if let skipped = open.skipped { return WorkHandoffStore.appSkipText(skipped, provider: receipt.provider) }
            if receipt.blocksNewHandoff { return "Running in the background. It opens in \(place) when the first reply is done." }
            return receipt.status == "completed" ? "The first reply is done. Opening it in \(place)." : nil
        }
        guard ["claude", "codex"].contains(receipt.provider) else { return nil }
        let app = receipt.provider == "codex" ? "Codex" : "Claude"
        if receipt.sessionID == nil {
            return receipt.blocksNewHandoff ? "Runs on this Mac through COS, not as a tab in the \(app) app. Its session shows here in a moment." : nil
        }
        return receipt.blocksNewHandoff
            ? "Runs on this Mac through COS, not as a tab in the \(app) app. Open session to follow it."
            : "Ran on this Mac through COS. Open session, then Open in platform, to keep going in the \(app) app."
    }
    /// 0.5.249: Continue on a session its app owns takes your note there; COS never sends a turn into it.
    nonisolated static func appOwnedNote(_ provider: String) -> String {
        provider == "codex"
            ? "This session is open in Codex. Continue opens it there with your note filled in, and you send it, so the app stays the only one writing to it."
            : "This session is open in \(WorkHandoffStore.openPlace(provider)). Continue opens it there and puts your note on the clipboard, and you send it, so the app stays the only one writing to it."
    }

    @ObservedObject var store: WorkHandoffStore
    let source: WorkSource
    var isPreview = false
    var onOpenSession: (String) -> Void
    var validateBeforeSend: (@MainActor () async -> Bool)? = nil
    /// Inside the Start work overlay the title row is the overlay's own, and the overlay loads sessions and advice.
    var embedded = false
    /// Tells the Start work overlay a send from this composer is being handed over, so nothing closes it mid-send.
    var onSendingChange: ((Bool) -> Void)? = nil
    /// 0.5.247: the card's stage now, so the Progress timeline offers Undo only while the card sits where COS put it.
    var currentStage: String? = nil
    var onUndoMove: ((String, String) -> Void)? = nil
    /// Offered once the session reports the task done: completing stays yours, from here or the board.
    var onMarkComplete: (() -> Void)? = nil
    /// After "Not done yet" sent the work back: the board moves the card back to Draft.
    var onSentBack: (() -> Void)? = nil
    @State private var validating = false
    @State private var historyOpen = false
    @State private var confirmClear = false
    @State private var sendBackOpen = false
    @State private var sendBackText = ""
    @State private var sendingBack = false
    private var draft: WorkHandoffDraft { store.draft(for: source) }
    private var mode: WorkHandoffMode { draft.mode }
    private var sessionID: String { draft.sessionID }
    private var modelID: String { draft.modelID }
    private var provider: String { draft.provider }
    private var prompt: String { draft.prompt }
    private func draftBinding<Value>(_ path: WritableKeyPath<WorkHandoffDraft, Value>) -> Binding<Value> {
        let boundSource = source
        return Binding(get: { store.draft(for: boundSource)[keyPath: path] }, set: { value in
            var next = store.draft(for: boundSource); next[keyPath: path] = value
            store.updateDraft(next, for: boundSource)
        })
    }

    private var recommended: [WorkSession] { store.recommendations(for: source) }
    private var selectedSession: WorkSession? { store.sessions.first { $0.id == sessionID } }
    private var selectedModel: WorkModelChoice? { store.models.first { $0.id == modelID && $0.provider == provider } }
    private var providers: [String] { Array(Set(store.models.map(\.provider))).sorted() }
    private var choices: [WorkModelChoice] { store.models.filter { $0.provider == provider } }
    private var plan: WorkSendPlan? { WorkHandoffStore.sendPlan(draft: draft, sessions: store.sessions, models: store.models) }
    private var blocking: WorkHandoffReceipt? { store.receipts(for: source.id).first(where: \.blocksNewHandoff) }
    /// 0.5.250: a Continue into a session the COS server is still running (a Work New session's first turn) waits.
    private var heldTarget: Bool {
        mode == .continueSession && selectedSession.map { WorkHandoffStore.serverHold(onSession: $0.id, in: store.receipts) != nil } == true
    }
    private var canSend: Bool { !validating && !store.busy && blocking == nil && plan != nil && !heldTarget }

    /// 0.5.243: a Fork with a target provider picked is a fork to another platform (a New session seeded with the
    /// conversation export). No provider means the native, same-platform fork.
    private var forkToPlatform: Bool { mode == .fork && WorkHandoffStore.crossPlatformTargets.contains(provider) && provider != selectedSession?.provider }

    /// 0.5.247: the newest tracked handoff for this work (sent with a status-line instruction).
    private var tracking: WorkTracking? { WorkTracking.latest(workID: source.id, receipts: store.receipts) }

    /// The newest handoff for this work, any revision: it is what blocks or explains the next send.
    private var latest: WorkActivity? {
        guard let receipt = store.receipts(for: source.id).first else { return nil }
        let session = WorkHandoffStore.listedSession(for: receipt, in: store.observedSessions())
        return WorkActivity(receipt: receipt, session: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if !embedded { Text("Agent workspace").font(COSType.display(20, weight: .medium)) }
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(COSQuietButtonStyle()).disabled(store.busy || validating).help("Refresh sessions and models")
            }
            if isPreview { Text("Local demonstration. No agent is contacted.").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted) }
            if let latest, WorkHandoffState(latest) != .settled || blocking != nil || tracking?.reported == true { statusBox(latest) }
            if let tracking { WorkProgressTimeline(tracking: tracking, currentStage: currentStage, onUndo: onUndoMove) }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(COSType.body(12)).foregroundStyle(COSPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let blocking {
                Text(blocking.status == "unknown" ? "Check the delivery status before sending this work anywhere else. Nothing is resent automatically."
                     : blocking.status == "delivered" ? "Once the session has replied and you mark it reviewed, you can send this work somewhere else."
                     : "This work has a handoff in flight. You can send it elsewhere once that finishes.")
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            } else {
                composer
            }
            historySection
        }
        .task(id: source) {
            guard !embedded else { return }
            await store.refresh()
            await store.loadAdvice(for: source)
        }
    }

    // MARK: status

    private func statusBox(_ activity: WorkActivity) -> some View {
        let state = WorkHandoffState(activity)
        let receipt = activity.receipt
        // 0.5.247: a status line the session reported leads the box: done, needs your input or blocked.
        let reported = tracking.flatMap { $0.receipt.id == receipt.id && $0.reported ? $0 : nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let reported {
                    WorkTrackingDot(phase: reported.phase, tint: reported.tint)
                    Text(reported.phase == .done ? (currentStage == nil ? "Done \u{00B7} ready for your review" : "Done \u{00B7} ready for your QA") : reported.label)
                        .font(COSType.body(12, weight: .semibold)).foregroundStyle(reported.tint)
                } else {
                    WorkLiveDot(color: state.tint, live: state == .running)
                    // The same words as the board, the Kanban and the Focus list.
                    Text(state == .settled ? activity.title : state.label).font(COSType.body(12, weight: .semibold)).foregroundStyle(state.tint)
                }
                Spacer(minLength: 6)
                Text(Date(timeIntervalSince1970: receipt.createdAt), format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted)
            }
            HStack(spacing: 8) {
                WorkProviderGlyph(provider: receipt.provider)
                Text(activity.session?.title ?? receipt.sessionTitle).font(COSType.body(13, weight: .semibold)).lineLimit(2)
            }
            Text(receipt.mode.title + " · " + WorkHandoffStore.providerName(receipt.provider) + " · session " + activity.sessionState.lowercased())
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            if let lineage = WorkHandoffStore.lineage(of: receipt, sessions: store.sessions) {
                Text(lineage).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            if let note = Self.whereItRunsNote(receipt) {
                Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let reported, let evidence = reported.evidence {
                Text(Self.reportedLine(reported, board: currentStage != nil))
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                // The session's own words are quoted; Jev's reading is not the session's, so it is not.
                Text(reported.byJev ? evidence : "\u{201C}" + evidence + "\u{201D}").font(COSType.body(11.5)).lineLimit(4).textSelection(.enabled)
                    .padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(reported.tint.opacity(0.6)).frame(width: 2) }
            }
            if let failure = activity.session?.failure, !failure.isEmpty { Text(failure).font(COSType.body(11.5)).foregroundStyle(COSPalette.danger) }
            if let waiting = activity.session?.waitingDetail, !waiting.isEmpty { Text(waiting).font(COSType.body(11.5)).foregroundStyle(COSPalette.amber) }
            if reported != nil {
                // The session's own status line, above, says what it did; the reply excerpt would repeat it.
            } else if state.showsReply, let excerpt = WorkBoardSessionCard.excerpt(receipt: receipt, session: activity.session) {
                Text(excerpt).font(COSType.body(11.5)).foregroundStyle(COSPalette.muted).lineLimit(4)
                    .padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(COSPalette.line).frame(width: 2) }
            } else if !receipt.detail.isEmpty {
                // Why it is in this state: a refusal reason, an unresolved delivery, a queue position.
                Text(receipt.detail).font(COSType.body(11.5)).foregroundStyle(state == .attention ? COSPalette.danger : COSPalette.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let sessionID = receipt.sessionID {
                    if state == .replyReady {
                        Button("Open session") { store.selectedWorkID = source.id; onOpenSession(sessionID) }.buttonStyle(COSPrimaryButtonStyle())
                    } else {
                        Button("Open session") { store.selectedWorkID = source.id; onOpenSession(sessionID) }.buttonStyle(COSQuietButtonStyle())
                    }
                }
                if reported?.phase == .done, let onMarkComplete {
                    Button("Mark complete") { onMarkComplete() }.buttonStyle(COSQuietButtonStyle())
                        .help("You agree it is finished. COS never marks work complete by itself.")
                }
                if reported?.phase == .done, !isPreview, !sendBackOpen, store.sendBackSession(for: receipt) != nil {
                    Button("Not done yet") { sendBackOpen = true }.buttonStyle(COSQuietButtonStyle())
                        .help("Send it back to the same session with what is missing")
                }
                if receipt.acknowledgeable && state.offersAcknowledge {
                    Button(WorkHandoffView.acknowledgeTitle(receipt)) { store.markReviewed(receiptID: receipt.id) }
                        .buttonStyle(COSQuietButtonStyle()).disabled(store.busy || validating)
                }
                if let open = WorkHandoffStore.appOpenButton(receipt) {
                    // 0.5.249: the same session in its app again (never while its run is going), or a note you took there.
                    Button(open) { Task { await store.reopenInApp(receiptID: receipt.id) } }
                        .buttonStyle(COSQuietButtonStyle()).disabled(isPreview)
                    if receipt.channel == "app" || receipt.channel == "prefill" {
                        Button("Not sending it") { store.cancelAppNote(receiptID: receipt.id) }
                            .buttonStyle(COSTextButtonStyle()).disabled(isPreview)
                    }
                } else if receipt.blocksNewHandoff && receipt.status != "delivered" {
                    Button("Check status") { Task { await store.refreshReceipts(asked: true) } }
                        .buttonStyle(COSTextButtonStyle()).disabled(store.busy || validating)
                }
            }
            if sendBackOpen, reported?.phase == .done, let session = store.sendBackSession(for: receipt) {
                sendBackControls(receipt, session: session)
            }
            if receipt.acknowledgeable && state.offersAcknowledge {
                Text(WorkHandoffView.acknowledgeHint(receipt)).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
            if receipt.status == "unknown" {
                // 0.5.246: COS sent it but never saw it land, so it may already be in the session. Continuing again is
                // allowed after one explicit confirm; the composer comes back set to the same session.
                let canContinue = receipt.sessionID != nil && WorkHandoffStore.continueProviders.contains(receipt.provider)
                if confirmClear {
                    Text(canContinue
                         ? "COS can\u{2019}t tell whether your last instruction arrived. If it did, sending again gives the session the same instruction twice. Open the session first if you want to check."
                         : "Clear it only after checking the session yourself. If the instruction did arrive, another handoff would send it twice.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if canContinue, let target = receipt.sessionID {
                            Button("Continue in this session") {
                                confirmClear = false
                                store.clearUnresolved(receiptID: receipt.id)
                                var next = draft; next.mode = .continueSession; next.sessionID = target
                                store.updateDraft(next, for: source)
                            }.buttonStyle(COSPrimaryButtonStyle()).disabled(store.busy || validating)
                        }
                        Button(canContinue ? "Clear without sending" : "Clear this handoff") { confirmClear = false; store.clearUnresolved(receiptID: receipt.id) }
                            .buttonStyle(COSQuietButtonStyle(tone: .destructive)).disabled(store.busy || validating)
                        Button("Cancel") { confirmClear = false }.buttonStyle(COSTextButtonStyle())
                    }
                } else {
                    Button(canContinue ? "Continue in this session\u{2026}" : "I checked the session. Clear this\u{2026}") { confirmClear = true }
                        .buttonStyle(COSQuietButtonStyle()).disabled(store.busy || validating)
                }
            }
            if isPreview && receipt.blocksNewHandoff {
                HStack {
                    Button("Show running") { store.simulate(receiptID: receipt.id, outcome: "running") }
                    Button("Show result") { store.simulate(receiptID: receipt.id, outcome: "completed") }
                    Button("Show failure") { store.simulate(receiptID: receipt.id, outcome: "failed") }
                }.buttonStyle(COSQuietButtonStyle()).controlSize(.small)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(state.tint.opacity(0.45)))
    }

    /// "Not done yet": what is missing, sent back to the same session. It becomes a new, tracked handoff.
    private func sendBackControls(_ receipt: WorkHandoffReceipt, session: WorkSession) -> some View {
        let empty = sendBackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = WorkSendPlan.clip(session.title)
        // 0.5.249: a session its app owns gets the note in the app, for you to send there.
        let how: String = WorkHandoffStore.appOwner(of: session.id, in: store.receipts) != nil
            ? "Opens \u{201C}\(title)\u{201D} in \(WorkHandoffStore.openPlace(session.provider)) with this note for you to send"
            : "Continues \u{201C}\(title)\u{201D} with this note"
        let then: String = currentStage == nil ? "." : " and moves the card back to Draft."
        return VStack(alignment: .leading, spacing: 6) {
            TextField("What\u{2019}s missing?", text: $sendBackText, axis: .vertical).lineLimit(2...5)
                .textFieldStyle(.plain).font(COSType.body(12)).padding(8)
                .background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.line))
                .accessibilityLabel("What is missing")
                .disabled(sendingBack)
            HStack(spacing: 8) {
                Button(sendingBack ? "Sending\u{2026}" : "Send back") { sendBack(receipt) }.buttonStyle(COSPrimaryButtonStyle())
                    .disabled(sendingBack || store.busy || empty)
                Button("Cancel") { sendBackOpen = false }.buttonStyle(COSTextButtonStyle()).disabled(sendingBack)
            }
            Text(how + then)
                .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
        }
    }
    private func sendBack(_ receipt: WorkHandoffReceipt) {
        let text = sendBackText
        sendingBack = true; onSendingChange?(true)
        Task {
            let sent = await store.sendBack(receiptID: receipt.id, source: source, missing: text)
            sendingBack = false; onSendingChange?(false)
            if sent { sendBackOpen = false; sendBackText = ""; onSentBack?() }
        }
    }

    /// What a reported state means for you, in the status box.
    nonisolated static func reportedLine(_ reported: WorkTracking, board: Bool) -> String {
        switch reported.phase {
        case .done:
            let who = reported.byJev ? "Jev read the session\u{2019}s reply as done." : "The session reported this done."
            return who + (board ? " Check the result, then mark it complete when you agree." : " Check the result.")
        case .blocked: return "The session is blocked on this."
        default: return "The session needs you before it can finish this."
        }
    }

    nonisolated static func acknowledgeTitle(_ receipt: WorkHandoffReceipt) -> String {
        ["failed", "refused", "canceled"].contains(receipt.status) ? "Acknowledge" : "Mark reviewed"
    }
    nonisolated static func acknowledgeHint(_ receipt: WorkHandoffReceipt) -> String {
        switch receipt.status {
        case "delivered": return "Mark reviewed clears it from Needs attention and lets you send this work again. The work itself stays as it is."
        case "completed": return "Mark reviewed clears it from Needs attention. The work itself stays as it is."
        default: return "Acknowledge clears it from Needs attention. The failure stays in history."
        }
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            adviceBlock
            VStack(alignment: .leading, spacing: 6) {
                Text("Where should it go?").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                VStack(spacing: 0) {
                    choiceRow(.continueSession, title: "Continue a session", detail: "Sends to an existing conversation, with its model and permissions. For Cursor, a new Cursor chat opens with your note filled in, and you press Send there.")
                    Divider().overlay(COSPalette.line)
                    choiceRow(.fork, title: "Fork a session", detail: "Copies a conversation first. Same platform, or to Claude or Codex.")
                    Divider().overlay(COSPalette.line)
                    choiceRow(.newSession, title: "Start a new session", detail: store.opensInApp ? "Claude and Codex run in the background with a model you pick, then open in their app when the first reply is done. Cursor opens its own window with the handoff filled in, and you press Send there. A local model stays in the background." : "Claude, Codex or a local model in the background, with a model you pick. Cursor opens its own window with the handoff filled in, and you press Send there.")
                }.overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.line))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Context to send").font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.muted)
                    Spacer()
                    Text(forkToPlatform ? "\(prompt.utf16.count.formatted()) / \(WorkHandoffStore.draftLimit.formatted()) · the conversation fills the rest"
                                        : "\(prompt.utf16.count.formatted()) / \(WorkHandoffStore.draftLimit.formatted())")
                        .font(COSType.body(10.5)).foregroundStyle(prompt.utf16.count > WorkHandoffStore.draftLimit ? COSPalette.danger : COSPalette.muted)
                    if prompt != source.suggestedPrompt {
                        Button("Reset") {
                            var next = draft; next.prompt = source.suggestedPrompt
                            store.updateDraft(next, for: source)
                        }.buttonStyle(COSTextButtonStyle()).disabled(store.busy || validating).help("Go back to the suggested context")
                    }
                }
                TextEditor(text: draftBinding(\.prompt)).font(COSType.body(12)).frame(minHeight: 120, maxHeight: 220)
                    .cosEditor()
                    .accessibilityLabel("Context to send")
                    .disabled(store.busy || validating)
                if prompt.utf16.count > WorkHandoffStore.draftLimit {
                    Text("Context exceeds \(WorkHandoffStore.draftLimit.formatted()) characters, the most a handoff carries with its tracking line. Shorten it before sending; nothing has been removed.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.danger)
                }
                if store.earlierDraftCount(for: source) > 0 {
                    Text("Earlier revision drafts are retained. This revision has its own context and destination.")
                        .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                }
            }
            Button {
                guard let sendingPlan = plan else { return }
                let sendingSource = source
                validating = true; onSendingChange?(true)
                Task {
                    defer { validating = false; onSendingChange?(false) }
                    if let validateBeforeSend, !(await validateBeforeSend()) { return }
                    await sendWorkHandoff(store: store, source: sendingSource, plan: sendingPlan)
                }
            } label: {
                Text(plan?.label ?? "Choose where it goes").lineLimit(1).frame(maxWidth: .infinity)
            }.buttonStyle(COSPrimaryButtonStyle()).disabled(!canSend)
            Text("Sending does not complete or publish this work.").font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                .frame(maxWidth: .infinity, alignment: .center)
            if store.busy || validating { ProgressView("Checking destination…").controlSize(.small) }
        }
    }

    private func setMode(_ value: WorkHandoffMode) {
        guard value != mode else { return }
        var next = draft; next.mode = value
        // A provider chosen for New session must not turn a Fork into a fork to another platform.
        if value == .fork && mode != .fork { next.provider = ""; next.modelID = "" }
        store.updateDraft(next, for: source)
    }

    private func choiceRow(_ value: WorkHandoffMode, title: String, detail: String) -> some View {
        let selected = mode == value
        return VStack(alignment: .leading, spacing: 8) {
            Button { setMode(value) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle().strokeBorder(selected ? COSPalette.gold : COSPalette.muted, lineWidth: 1.5)
                        .background(Circle().fill(selected ? COSPalette.gold : .clear).padding(3.5))
                        .frame(width: 14, height: 14).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(COSType.body(12.5, weight: .semibold)).foregroundStyle(.primary)
                        Text(detail).font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(store.busy || validating)
                .accessibilityAddTraits(selected ? .isSelected : [])
            if selected {
                Group {
                    if value == .newSession { newDestination } else { existingDestination }
                }.padding(.leading, 24)
            }
        }.padding(.horizontal, 11).padding(.vertical, 9)
            .background(selected ? COSPalette.gold.opacity(0.07) : .clear)
    }

    /// Jev's suggestion. "Use this" fills Destination and Session in one explicit click; sending stays separate.
    @ViewBuilder private var adviceBlock: some View {
        if let advice = store.advice(for: source) {
            let session = advice.sessionID.flatMap { id in store.sessions.first { $0.id == id } }
            let applied = mode == (advice.action == .continueSession ? .continueSession : advice.action == .fork ? .fork : .newSession)
                && (advice.action == .newSession || sessionID == advice.sessionID) && !(advice.action == .fork && !provider.isEmpty)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(COSPalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(adviceTitle(advice, session)).font(COSType.body(12.5, weight: .semibold))
                    Text("\(advice.reason) Jev · \(advice.percent)").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                Spacer(minLength: 8)
                Button(applied ? "Selected" : "Use this") {
                    store.updateDraft(WorkHandoffStore.applying(advice, to: draft), for: source)
                }.buttonStyle(COSQuietButtonStyle()).disabled(applied || store.busy || validating)
            }.padding(10).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 7))
        } else if let text = WorkHandoffStore.adviceUnavailableText(store.adviceUnavailableReason(for: source)) {
            Text(text).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
        }
    }

    private func adviceTitle(_ advice: SessionAdvice, _ session: WorkSession?) -> String {
        switch advice.action {
        case .continueSession: return "Continue in “\(session?.title ?? "session")”"
        case .fork: return "Fork “\(session?.title ?? "session")”"
        case .newSession: return "Start a new session"
        }
    }

    /// The likeliest sessions as rows (Jev's pick, word matches, then recent), plus every session in a menu.
    private var existingDestination: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.sessions.isEmpty {
                Text(sessionID.isEmpty ? "No sessions available. Refresh or choose a new session." : "Your saved session is unavailable. Refresh to resolve it or explicitly choose a new destination.")
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            } else {
                let advice = store.advice(for: source)
                // The tag marks Jev's pick for the mode it advised (a Fork suggestion is not a Continue pick).
                let advised = advice.flatMap { a in (a.action == .fork) == (mode == .fork) ? a.sessionID : nil }
                let shortlist = WorkHandoffStore.shortlist(advised: advised, matches: recommended, sessions: store.sessions)
                ForEach(shortlist) { session in sessionRow(session, advised: session.id == advised) }
                if let selectedSession, !shortlist.contains(where: { $0.id == selectedSession.id }) {
                    sessionRow(selectedSession, advised: selectedSession.id == advised)
                }
                if !sessionID.isEmpty && selectedSession == nil {
                    Text("Saved session unavailable. Refresh to resolve it or choose another.").font(COSType.body(11)).foregroundStyle(COSPalette.danger)
                }
                Menu {
                    ForEach(store.sessions) { session in
                        Button("\(session.title) · \(WorkHandoffStore.providerName(session.provider))") {
                            var next = draft; next.sessionID = session.id
                            store.updateDraft(next, for: source)
                        }
                    }
                } label: { COSMenuLabel(title: "Another session… (\(store.sessions.count))") }
                    .cosMenu().fixedSize().disabled(store.busy || validating)
                if mode == .fork { forkTarget }
                if let session = selectedSession {
                    if plan == nil && !forkToPlatform {
                        Text(mode == .fork
                             ? (WorkHandoffStore.exportableProviders.contains(session.provider)
                                ? "A \(WorkHandoffStore.providerName(session.provider)) session forks to Claude or Codex: choose one under Fork to."
                                : "This session cannot be forked. Choose a new session instead.")
                             : "This provider does not support continuing a session here.")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.danger)
                    }
                    Text("\(session.status.capitalized) · \(session.project.isEmpty ? "Workspace unavailable" : session.project)")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    if heldTarget {
                        Text("Still running its first turn on the COS server. You can continue it once that finishes.")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(forkToPlatform && store.opensInApp
                         ? "Starts a new \(WorkHandoffStore.providerName(provider)) session in the background with this context plus the conversation up to now from \u{201C}\(session.title)\u{201D}, read from its transcript (up to 32,000 characters in all), then opens it in \(WorkHandoffStore.appName(provider)) when the first reply is done. The original session is unchanged."
                         : mode == .continueSession && WorkHandoffStore.appOwner(of: session.id, in: store.receipts) != nil
                         ? Self.appOwnedNote(session.provider)
                         : forkToPlatform
                         ? "Starts a new \(WorkHandoffStore.providerName(provider)) session with this context plus the conversation up to now from \u{201C}\(session.title)\u{201D}, read from its transcript (up to 32,000 characters in all). It uses the server\u{2019}s configured workspace and permissions, not the original session\u{2019}s. The original session is unchanged."
                         : mode == .fork ? "Creates a copy with \(WorkHandoffStore.providerName(session.provider)); the original remains unchanged." : "Uses this session’s model and permissions. Busy sessions may queue or refuse.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sessionRow(_ session: WorkSession, advised: Bool) -> some View {
        let picked = session.id == sessionID
        return Button {
            var next = draft; next.sessionID = session.id
            store.updateDraft(next, for: source)
        } label: {
            HStack(spacing: 8) {
                WorkProviderGlyph(provider: session.provider)
                Text(session.title).font(COSType.body(12, weight: picked ? .semibold : .regular)).lineLimit(1)
                if advised { Text("JEV").font(COSType.mono(9.5, weight: .semibold)).foregroundStyle(COSPalette.accent) }
                Spacer(minLength: 6)
                Text(WorkBoardSessionCard.ageLabel(status: session.status, updated: session.updatedDate))
                    .font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .background(picked ? COSPalette.gold.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(picked ? COSPalette.gold.opacity(0.5) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.busy || validating)
            .help(advised ? session.summary : (recommended.contains(where: { $0.id == session.id })
                  ? store.recommendationReason(for: session, source: source) : (session.summary.isEmpty ? session.title : session.summary)))
            .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// The Provider rows: a placeholder, a saved provider no longer offered (muted), then the catalog's.
    private var providerOptions: [COSDropdownOption<String>] {
        var rows = [COSDropdownOption("", "Choose provider", placeholder: true)]
        if !provider.isEmpty && !providers.contains(provider) { rows.append(COSDropdownOption(provider, provider, note: "unavailable", muted: true)) }
        return rows + providers.map { COSDropdownOption($0, WorkHandoffStore.providerName($0)) }
    }

    /// The Model rows: a placeholder, a saved model gone from the catalog, then the catalog's; an unavailable
    /// model stays choosable (its reason shows once chosen), muted with its note.
    private var modelOptions: [COSDropdownOption<String>] {
        var rows = [COSDropdownOption("", "Choose model", placeholder: true)]
        if !modelID.isEmpty && selectedModel == nil { rows.append(COSDropdownOption(modelID, "Saved model unavailable", muted: true)) }
        return rows + choices.map { COSDropdownOption($0.id, $0.title, note: $0.available ? nil : "unavailable", muted: !$0.available) }
    }

    /// Fork to: the same platform (native copy of the conversation) or any catalog provider and model.
    private var forkTarget: some View {
        VStack(alignment: .leading, spacing: 8) {
            COSDropdown("Fork to", selection: Binding(get: { forkToPlatform ? provider : "" }, set: { value in
                var next = draft; next.provider = value; next.modelID = ""
                store.updateDraft(next, for: source)
            }), options: [COSDropdownOption("", "Same platform (copy the conversation)")]
                + providers.filter { WorkHandoffStore.crossPlatformTargets.contains($0) && $0 != selectedSession?.provider }
                    .map { COSDropdownOption($0, WorkHandoffStore.providerName($0)) },
                labelWidth: 56)
                .disabled(store.busy || validating)
            if forkToPlatform {
                COSDropdown("Model", selection: draftBinding(\.modelID), options: modelOptions, labelWidth: 56)
                    .disabled(store.busy || validating)
            }
        }
    }

    private var newDestination: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.models.isEmpty { Text("No configured models available.").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted) }
            COSDropdown("Provider", selection: Binding(get: { provider }, set: { value in
                var next = draft; next.provider = value; next.modelID = ""
                store.updateDraft(next, for: source)
            }), options: providerOptions, labelWidth: 56)
                .disabled(store.busy || validating)
            COSDropdown("Model", selection: draftBinding(\.modelID), options: modelOptions, labelWidth: 56)
                .disabled(store.busy || validating)
            if let reason = selectedModel?.reason, !reason.isEmpty {
                Text(reason).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            Text("Uses the server’s configured workspace and permissions. This chooser does not change them.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
        }
    }

    // MARK: history

    private var historySection: some View {
        let receipts = store.receipts(for: source.id)
        return VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(COSPalette.line)
            Button { historyOpen.toggle() } label: {
                HStack {
                    Text(receipts.isEmpty ? "History · none yet" : "History · \(receipts.count) handoff\(receipts.count == 1 ? "" : "s")")
                        .font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                    Spacer()
                    if !receipts.isEmpty {
                        Text(historyOpen ? "Hide" : "Show").font(COSType.body(11.5)).foregroundStyle(COSPalette.accent)
                        Image(systemName: historyOpen ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(COSPalette.accent)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(receipts.isEmpty)
            if historyOpen {
                ForEach(receipts) { receipt in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(receipt.status.capitalized + " · " + receipt.mode.title + Self.glassesMark(receipt))
                                .font(COSType.body(12, weight: .semibold))
                            Spacer()
                            Text(Date(timeIntervalSince1970: receipt.createdAt), format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted)
                        }
                        Text(WorkHandoffStore.providerName(receipt.provider) + " · " + receipt.sessionTitle).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        if let lineage = WorkHandoffStore.lineage(of: receipt, sessions: store.sessions) {
                            Text(lineage).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        }
                        Text(receipt.detail).font(COSType.body(11.5)).textSelection(.enabled)
                        if let result = receipt.result, !result.isEmpty { COSMarkdownView(text: result) }
                        if let sessionID = receipt.sessionID {
                            Button("Open session") { store.selectedWorkID = source.id; onOpenSession(sessionID) }.buttonStyle(COSQuietButtonStyle())
                        } else {
                            Text("Session link not yet confirmed.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        }
                    }.padding(10).background(COSPalette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("An unknown delivery outcome needs a status check; do not send another copy blindly. Session output does not approve or publish work.")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
            }
        }
    }
}

/// What the Start work overlay does after a send: keep waiting while the intent is only saved, close once the handoff
/// is in the session's hands, and stay open on the result when it was refused, failed or could not be confirmed.
enum WorkStartOutcome: Equatable {
    case waiting, close, showResult
    /// `newest` is this work's newest receipt; `openedWith` was the newest receipt id when the overlay opened.
    nonisolated static func after(openedWith: String?, newest: WorkHandoffReceipt?) -> Self {
        guard let newest, newest.id != openedWith else { return .waiting }
        switch newest.status {
        case "preparing", "sending": return .waiting
        case "refused", "failed", "unknown": return .showResult
        default: return .close
        }
    }
}

/// Board drop → confirm before anything runs (0.5.244). It first loads sessions and Jev's advice, then decides once:
/// a Continue or Fork suggestion at its bar, or a complete saved draft on work with no handoff yet, shows as one line
/// and one button; anything else opens the full Agent workspace chooser, which stays open once shown.
struct WorkStartSheet: View {
    enum Phase: Equatable { case checking, starting(WorkSendPlan, fromAdvice: Bool), confirm(WorkSendPlan, fromAdvice: Bool), chooser }
    @ObservedObject var store: WorkHandoffStore
    let title: String
    let subtitle: String
    let source: WorkSource
    var isPreview = false
    var maxHeight: CGFloat = 640
    @Binding var sending: Bool
    var onOpenSession: (String) -> Void
    var onClose: () -> Void
    @State private var phase: Phase = .checking
    @State private var openedWith: String?
    @State private var captured = false
    @State private var secondsLeft = WorkHandoffStore.autoStartDelay

    private var blocking: WorkHandoffReceipt? { store.receipts(for: source.id).first(where: \.blocksNewHandoff) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(blocking != nil && phase != .checking && !sending ? "This card already has a handoff" : "Start work on this card?")
                    .font(COSType.display(21, weight: .medium))
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(COSQuietButtonStyle()).help("Close")
                    .disabled(sending)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(COSType.body(12.5, weight: .medium)).lineLimit(3)
                Text(subtitle).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            switch phase {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking where this goes…").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                    Spacer()
                    Button("Choose myself") { phase = .chooser }.buttonStyle(COSTextButtonStyle())
                }
            case let .starting(plan, fromAdvice):
                // Every criterion holds: it runs by itself after a short countdown, then opens the session.
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: fromAdvice ? "sparkle" : "arrow.turn.down.right").foregroundStyle(COSPalette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.label).font(COSType.body(12.5, weight: .semibold))
                        Text(fromAdvice ? (store.advice(for: source).map { "\($0.reason) Jev · \($0.percent)" } ?? "Jev's suggestion.") : "Your saved destination for this card.")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 8) {
                    if sending || store.busy {
                        ProgressView().controlSize(.small)
                        Text("Sending…").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                    } else {
                        Text("Starting in \(secondsLeft) s, then opening the session.").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                    }
                    Spacer()
                    Button("Change where it goes") { phase = .chooser }.buttonStyle(COSQuietButtonStyle()).disabled(sending || store.busy)
                    Button("Cancel") { onClose() }.buttonStyle(COSQuietButtonStyle()).disabled(sending)
                    Button { startNow(plan) } label: { Text("Start now").lineLimit(1) }
                        .buttonStyle(COSPrimaryButtonStyle()).disabled(sending || store.busy)
                }
                if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").font(COSType.body(11.5)).foregroundStyle(COSPalette.danger) }
            case .chooser:
                ScrollView {
                    WorkHandoffView(store: store, source: source, isPreview: isPreview, onOpenSession: onOpenSession, embedded: true,
                                    onSendingChange: { sending = $0 })
                        .padding(.trailing, 6)
                }.frame(minHeight: 160, maxHeight: max(160, maxHeight - 170))
            case let .confirm(plan, fromAdvice):
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: fromAdvice ? "sparkle" : "arrow.turn.down.right").foregroundStyle(COSPalette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.label).font(COSType.body(12.5, weight: .semibold))
                        if fromAdvice, let advice = store.advice(for: source) {
                            Text("\(advice.reason) Jev · \(advice.percent)").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        } else {
                            Text("Your saved destination for this card.").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        }
                        if let session = plan.session {
                            Text("Session \(session.status.lowercased())" + (session.status == "running" || session.status == "working" ? ": it may queue behind the current turn." : "."))
                                .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                Text("Sends the card's context. Nothing is published, and the card stays in its column.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").font(COSType.body(11.5)).foregroundStyle(COSPalette.danger) }
                HStack(spacing: 8) {
                    if sending || store.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Change where it goes") { phase = .chooser }.buttonStyle(COSQuietButtonStyle()).disabled(sending || store.busy)
                    Button("Cancel") { onClose() }.buttonStyle(COSQuietButtonStyle()).disabled(sending)
                    Button { startNow(plan) } label: { Text(plan.verb).lineLimit(1) }
                    .buttonStyle(COSPrimaryButtonStyle()).disabled(sending || store.busy)
                }
            }
        }
        // Sized to its content; only the chooser's scroll area is capped (by maxHeight above), so a short confirm stays short.
        .padding(18).frame(width: 600, alignment: .leading)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.gold.opacity(0.45)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .onAppear { if !captured { captured = true; openedWith = store.receipts(for: source.id).first?.id } }
        .onChange(of: store.receipts(for: source.id).first.map { $0.id + "|" + $0.status }) { _, _ in
            switch WorkStartOutcome.after(openedWith: openedWith, newest: store.receipts(for: source.id).first) {
            case .waiting: break
            case .close:
                // The handoff reached the session: open it (a New session may not have one yet; the board shows it).
                if let sessionID = store.receipts(for: source.id).first?.sessionID { onOpenSession(sessionID) } else { onClose() }
            case .showResult: phase = .chooser   // the workspace's status box shows why, with Check status
            }
        }
        .task(id: phase) {
            guard case let .starting(plan, _) = phase else { return }
            secondsLeft = WorkHandoffStore.autoStartDelay
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, case .starting = phase else { return }
                secondsLeft -= 1
            }
            if !sending { startNow(plan) }
        }
        .task(id: source) {
            // Wait out a receipt poll in flight, so refresh actually loads sessions and models.
            for _ in 0..<50 where store.busy { try? await Task.sleep(for: .milliseconds(100)) }
            // A session list checked in the last minute is current enough to decide on; rescanning 60+ sessions is slow.
            let fresh = !store.models.isEmpty && (store.activityCheckedAt.map { Date().timeIntervalSince($0) < 60 } ?? false)
            if !fresh { await store.refresh() }
            await store.loadAdvice(for: source)
            guard phase == .checking else { return }
            let hasHistory = !store.receipts(for: source.id).isEmpty
            let draft = store.draft(for: source), advice = store.advice(for: source)
            if let start = WorkHandoffStore.startPlan(draft: draft, advice: advice, sessions: store.sessions, models: store.models, hasHistory: hasHistory) {
                let auto = WorkHandoffStore.autoStartPlan(draft: draft, advice: advice, sessions: store.sessions, models: store.models, hasHistory: hasHistory)
                phase = auto != nil ? .starting(start.plan, fromAdvice: start.fromAdvice) : .confirm(start.plan, fromAdvice: start.fromAdvice)
            } else {
                phase = .chooser
            }
        }
    }

    private func startNow(_ plan: WorkSendPlan) {
        guard !sending else { return }
        let sendingSource = source
        sending = true
        Task {
            defer { sending = false }
            await sendWorkHandoff(store: store, source: sendingSource, plan: plan)
        }
    }
}

struct WorkSessionsView: View {
    @ObservedObject var store: WorkHandoffStore
    var isPreview = false
    var onOpenWork: (String) -> Void
    var onOpenFullSession: ((WorkSession) -> Void)? = nil
    private var selected: WorkSession? { store.sessions.first { $0.id == store.selectedSessionID } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sessions").font(COSType.display(23, weight: .medium))
                    Text(isPreview ? "Shared preview conversations" : "Linked agent conversations").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    ForEach(store.sessions) { session in
                        Button { store.selectedSessionID = session.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.title).font(COSType.body(12, weight: .semibold))
                                Text("\(session.provider) · \(session.status)").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(store.selectedSessionID == session.id ? COSPalette.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                }.padding(18)
            }.frame(width: 250)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session = selected {
                        Text(session.title).font(COSType.display(25, weight: .medium))
                        Text("\(session.provider) · \(session.status)").font(COSType.body(12)).foregroundStyle(COSPalette.muted)
                        Text(session.summary).font(COSType.body(13))
                        if let open = onOpenFullSession, !isPreview {
                            Button("Open full session") { open(session) }.buttonStyle(COSPrimaryButtonStyle())
                        }
                        ForEach(store.receipts.filter { $0.sessionID == session.id }) { receipt in
                            VStack(alignment: .leading, spacing: 10) {
                                Button("Back to work: \(receipt.workTitle)") { onOpenWork(receipt.workID) }.buttonStyle(COSQuietButtonStyle())
                                Text(receipt.status.capitalized + " · " + receipt.detail).font(COSType.body(12))
                                Text(receipt.prompt).font(COSType.body(12)).textSelection(.enabled)
                                if let result = receipt.result { COSMarkdownView(text: result) }
                            }.padding(14).background(COSPalette.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Text("Choose a session").font(COSType.display(24, weight: .medium))
                        Text("A handoff links its exact conversation here. No title matching is used.").foregroundStyle(COSPalette.muted)
                    }
                    if isPreview { Text("Local demonstration only. These conversations do not contact a provider.").font(COSType.body(11)).foregroundStyle(COSPalette.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        }.background(COSPalette.panel).task { await store.refresh() }
            .task { await pollVisibleReceipts() }
    }

    private func pollVisibleReceipts() async {
        guard !isPreview else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            if !store.busy, store.receipts.contains(where: { $0.blocksNewHandoff && $0.status != "delivered" }) {
                await store.refreshReceipts()
            }
        }
    }
}
