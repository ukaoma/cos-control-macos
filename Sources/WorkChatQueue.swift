import SwiftUI
import Foundation

/// 0.5.317 (Miles 2026-10-16 12:02, approved design): keep feeding a card while its earlier work runs. When the handoff
/// fence would hold a send, it can queue (send by itself once the earlier work resolves, after every send check again),
/// go in parallel (send now; a session with its own open handoff still waits), or check first (the 0.5.308 fence).
///
/// Where it lives: the queue is the round's own saved history (task-chat/<card>.json, beside the work journal), and a
/// queued assignment is sent by the same `dispatch` and `WorkHandoffStore.submit` as a Send, which itself parks behind a
/// busy native turn on the server (session-chat-queue). The server's parked turn cannot wait for a review or re-check the
/// task, so the wait for earlier work is Control's: queued work sends while COS Control runs, and waits while it is closed.
enum WorkChatHold: Equatable {
    /// The fence: the card lists what holds it and nothing is sent (an older server, a sample card, or Check first).
    case stop
    /// Ask each time: the card offers Queue it, Send in parallel and Check first.
    case ask
    case queue
    case parallel

    static let queuedState = "Queued"
    /// Settings › Work › When earlier work is still open, per Mac like cos.workChatSendWithoutReview.
    static let settingKey = "cos.workChatWhenEarlierOpen"
    static let queueSetting = "queue"
    static let askSetting = "ask"
    /// Queue it by default (Miles 2026-10-16: safest, never blocks).
    static let settingDefault = queueSetting
    static let settingOptions = [(queueSetting, "Queue it"), (askSetting, "Ask each time")]
    static func storedSetting(_ defaults: UserDefaults = .standard) -> String { defaults.string(forKey: settingKey) ?? settingDefault }
    /// What a held send does. Plan and send always queues: sending without review never bypasses the fence and never picks
    /// parallel for you. A server without `queueRounds` keeps the check-first fence.
    static func onHold(setting: String, autoSend: Bool, offered: Bool) -> WorkChatHold {
        guard offered else { return .stop }
        if autoSend { return .queue }
        return setting == askSetting ? .ask : .queue
    }
    static let olderServer = "This COS server cannot queue work or send it in parallel yet, so COS checks first. Update the COS server to keep sending while earlier work runs."
    static let whileClosed = "Queued work sends while COS Control is open. If it is closed, it waits, and sends after the same checks once COS Control opens again."
    static let settingHelp = "Queue it: a send that earlier work would hold waits, then sends by itself once that work is resolved, after the same checks. Ask each time: choose Queue it, Send in parallel or Check first. " + whileClosed
    /// "Queued behind “Copy review”", naming at most one session and counting the rest.
    static func queuedLine(titles: [String]) -> String {
        let named = titles.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard let first = named.first else { return "Queued behind earlier work on this card" }
        let quoted = "\u{201C}" + WorkSendPlan.clip(first) + "\u{201D}"
        switch named.count {
        case 1: return "Queued behind " + quoted
        case 2: return "Queued behind " + quoted + " and \u{201C}" + WorkSendPlan.clip(named[1]) + "\u{201D}"
        default: return "Queued behind " + quoted + " and \(named.count - 1) more"
        }
    }
    /// The session titles a round's queued assignments wait on, from the journal's receipts.
    static func waitingTitles(_ round: WorkChatRound, receipts: [WorkHandoffReceipt]) -> [String] {
        round.assignments.filter { $0.state == queuedState }.flatMap { $0.waitingOn ?? [] }
            .compactMap { id in receipts.first { $0.id == id }?.sessionTitle }
    }
}

/// 0.5.317: sends queued work for cards whose Work chat is not open, while COS Control runs. A card open in a Work chat
/// view is pumped by that view's own store, so one card's history has one writer at a time.
@MainActor final class WorkChatQueuePump {
    /// Cards a Work chat view has open (counted: two windows may show one card).
    private static var shown: [String: Int] = [:]
    static func show(_ workID: String) { shown[workID, default: 0] += 1 }
    static func hide(_ workID: String) { shown[workID] = max(0, (shown[workID] ?? 1) - 1) }
    static func isShown(_ workID: String) -> Bool { (shown[workID] ?? 0) > 0 }

    private let handoff: WorkHandoffStore
    private let sources: () -> [WorkSource]
    private let store: WorkTaskChatStore
    private var loop: Task<Void, Never>?
    /// 0.5.333: `store` is shared with the lens plans pump, so a card not open in a view has one background writer.
    init(handoff: WorkHandoffStore, sources: @escaping () -> [WorkSource], store: WorkTaskChatStore = WorkTaskChatStore()) {
        self.handoff = handoff; self.sources = sources; self.store = store; store.enabled = true
    }
    func start(interval: Duration = .seconds(15)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.pass()
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    /// One pass: each saved card chat holding a queued assignment, for this server, whose card is on the board and not
    /// open in a Work chat view. Reads only; a send happens in the card's store, through the card's own checks.
    func pass() async {
        guard handoff.canSendQueued else { return }
        let server = handoff.isolated ? "sample" : handoff.taskChatServerID
        guard let server else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: WorkTaskChatStore.historyFolder(), includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        let cards = Dictionary(sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let marker = Data("\"\(WorkChatHold.queuedState)\"".utf8)
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let data = try? WorkSessionLinks.chatRead(file), data.range(of: marker) != nil,
                  let saved = try? JSONDecoder().decode(WorkChatRecord.self, from: data), saved.serverID == server,
                  !Self.isShown(saved.workID), let source = cards[saved.workID] else { continue }
            store.open(source: source, handoff: handoff)
            store.syncFromDisk()
            await store.pumpQueued(source: source, handoff: handoff)
            guard handoff.canSendQueued else { return }
        }
    }
}

/// Ask each time: the held send's three choices, in the round it belongs to. Nothing has been sent for it yet.
struct WorkChatHoldChoices: View {
    @ObservedObject var chat: WorkTaskChatStore
    @ObservedObject var handoff: WorkHandoffStore
    let source: WorkSource
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Earlier work on this card is still open").font(COSType.body(13, weight: .semibold))
            ForEach(chat.blockers) { receipt in
                Text(WorkChatPreflight.line(receipt, now: Date().timeIntervalSince1970)).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
            }
            HStack(spacing: 8) {
                Button("Queue it") { Task { await chat.resolveHold(.queue, source: source, handoff: handoff) } }
                    .buttonStyle(COSPrimaryButtonStyle()).accessibilityIdentifier("work-chat-queue-it")
                Button("Send in parallel") { Task { await chat.resolveHold(.parallel, source: source, handoff: handoff) } }
                    .buttonStyle(COSQuietButtonStyle()).accessibilityIdentifier("work-chat-send-parallel")
                Button("Check first") { Task { await chat.resolveHold(.stop, source: source, handoff: handoff) } }
                    .buttonStyle(COSTextButtonStyle()).accessibilityIdentifier("work-chat-check-first")
            }.disabled(chat.busy || chat.refreshing || handoff.busy)
            Text("Queue it sends by itself once that work is resolved. Send in parallel sends now to sessions that are free; a session that still has earlier work open gets its assignment after that work. Check first sends nothing.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A round with queued assignments: what they wait on, and Cancel.
struct WorkChatQueuedLine: View {
    @ObservedObject var chat: WorkTaskChatStore
    @ObservedObject var handoff: WorkHandoffStore
    let source: WorkSource
    let round: WorkChatRound
    private var queued: [WorkChatAssignment] { round.assignments.filter { $0.state == WorkChatHold.queuedState } }
    var body: some View {
        let parallel = queued.allSatisfy { $0.parallel == true }
        VStack(alignment: .leading, spacing: 6) {
            Text(WorkChatHold.queuedLine(titles: WorkChatHold.waitingTitles(round, receipts: handoff.receipts)))
                .font(COSType.body(13, weight: .semibold)).accessibilityIdentifier("work-chat-queued-line")
            Text(parallel ? "Sent in parallel. Each waiting assignment goes once its own session's earlier work is resolved. Cancel to choose another destination."
                          : "Sends by itself once that work is resolved, after the same checks. If the task changed meanwhile, it asks for a new plan instead.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            Text(WorkChatHold.whileClosed).font(COSType.body(11)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { chat.cancelQueued(roundID: round.id) }.buttonStyle(COSQuietButtonStyle()).accessibilityIdentifier("work-chat-cancel-queue")
                if !parallel, chat.queueOffered {
                    Button("Send in parallel") { Task { await chat.sendQueuedInParallel(roundID: round.id, source: source, handoff: handoff) } }
                        .buttonStyle(COSTextButtonStyle())
                }
            }.disabled(chat.busy || chat.refreshing)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Under a round waiting for review: what Send will do while earlier work on the card is open.
struct WorkChatHeldNote: View {
    @AppStorage(WorkChatHold.settingKey) private var whenHeld = WorkChatHold.settingDefault
    var body: some View {
        Text(whenHeld == WorkChatHold.askSetting ? "Earlier work on this card is still open. Send asks whether to queue it or send in parallel."
                                                 : "Earlier work on this card is still open. Send queues behind it.")
            .font(COSType.body(11)).foregroundStyle(COSPalette.muted)
    }
}
