import Foundation
import os

/// 0.5.333 lens plans: work-lens category, ids and states only (never a question, answer or prompt).
private let lensLog = Logger(subsystem: "com.gotcos.control", category: "work-lens")

/// 0.5.333 lens plans (server 6.83.0 `lensPlans: 1`; WorkLensPlans.swift for the rules). While COS Control runs, every 5 s,
/// and only when the server advertises lensPlans: pull the lens inbox, write each round into its card's Work chat history,
/// perform each send request through the card's own Send (`WorkTaskChatStore.sendLensRequest`, which is `dispatch` and
/// `WorkHandoffStore.submit`), run each stop request through the existing Stop, and report every assignment's result
/// until it is final. A card open in a Work chat view is written and sent through that view's store (one writer per card).
/// An older server (no lensPlans) gets the capability read only: no inbox poll, no write, no send.
@MainActor final class WorkLensPlansPump {
    struct Tracked: Equatable { let workID: String; let roundID: String; let ids: [String]; var last: [String: String] }
    private let handoff: WorkHandoffStore
    private let sources: () -> [WorkSource]
    private let defaults: UserDefaults
    /// The store for cards no Work chat view has open, shared with the queue pump (one background writer per card).
    private let own: WorkTaskChatStore
    private var loop: Task<Void, Never>?
    var now: () -> Date = Date.init
    /// How long a picked-up send waits for its card to be free (and for its round to reach history) before it is refused.
    var sendPatience: TimeInterval = 600
    var idleWait: Duration = .seconds(20)
    private(set) var offered = false
    private var checkedAt: Date?
    private(set) var cursor = 0
    private(set) var pendingSends: [(send: WorkLensPlans.SendRequest, since: Date)] = []
    private(set) var tracked: [String: Tracked] = [:]
    /// Lens rounds in history and not sent yet, with the card Auto-send last reported for them.
    private(set) var autoSendPosted: [String: (workID: String, on: Bool?)] = [:]
    private var progressAt: Date?
    private var seeded = false
    /// Lens rounds Miles sent from the Mac (his own Send), to report through mac-send; then followed until final.
    private(set) var macPending: [String: String] = [:]
    private(set) var macTracked: [String: Tracked] = [:]
    /// 0.5.337 (loop audit W11): the first time a lens round lands in its card's history, a Work notice says so.
    var onNotice: ((WorkProgressNotice) -> Void)?
    private var noticed: Set<String> = []

    init(handoff: WorkHandoffStore, sources: @escaping () -> [WorkSource], enabled: Bool, defaults: UserDefaults = .standard, store: WorkTaskChatStore = WorkTaskChatStore()) {
        self.handoff = handoff; self.sources = sources; self.defaults = defaults; self.own = store; own.enabled = enabled
        WorkTaskChatStore.onLensMacSend = { [weak self] workID, roundID in self?.macPending[roundID] = workID }
    }
    func start(interval: Duration = .seconds(WorkLensPlans.pollSeconds)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.pass()
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    /// This card's Auto-send on this Mac (its own switch, else Settings › Work › Send plans without review).
    func cardAutoSend(_ workID: String) -> Bool {
        WorkOrchestrator.autoSend(workID: workID, raw: defaults.string(forKey: WorkOrchestrator.autoSendCardsKey) ?? "",
                                  settingDefault: defaults.object(forKey: WorkChatPolicy.autoSendKey) as? Bool ?? WorkChatPolicy.autoSendDefault)
    }

    /// One pass. Never throws; a failure waits for the next pass.
    func pass() async {
        guard !handoff.isolated, handoff.taskChatServerID != nil else { return }
        let at = now()
        if checkedAt == nil || at.timeIntervalSince(checkedAt!) >= WorkLensPlans.capabilitySeconds {
            if let caps = try? await handoff.taskChatCall(["work-chat-capabilities"]) {
                let was = offered
                offered = caps["lensPlans"]?.bool == true; checkedAt = at
                if offered != was { lensLog.info("lens plans \(self.offered ? "offered" : "not offered", privacy: .public) by this server") }
            }
        }
        guard offered else { return }
        if !seeded { seed(); seeded = true }
        let global = defaults.object(forKey: WorkChatPolicy.autoSendKey) as? Bool ?? WorkChatPolicy.autoSendDefault
        guard let details = try? await handoff.taskChatCall(["work-lens-inbox", "--since", String(cursor), "--auto-send", global ? "1" : "0"]),
              details["available"]?.bool == true, let data = try? JSONEncoder().encode(details), let box = WorkLensPlans.inbox(data) else { return }
        var allWritten = true
        for round in box.rounds { if !(await writeHistory(round)) { allWritten = false } }
        cursor = WorkLensPlans.nextCursor(current: cursor, answered: box.cursor, allWritten: allWritten)
        for send in box.sends where !pendingSends.contains(where: { $0.send.sendRequestId == send.sendRequestId }) { pendingSends.append((send, now())) }
        for stop in box.stops { await runStop(stop) }
        await runSends()
        await reportMacSends()
        await repostAutoSend()
        await reportProgress()
    }

    /// The card's store, open on the card: the view's when a Work chat view shows it, else the shared background store.
    /// Synchronous, so a caller that acts on it before its first suspension acts on this card.
    private func store(for workID: String) -> (WorkTaskChatStore, WorkSource)? {
        guard let source = sources().first(where: { $0.id == workID }) else { return nil }
        if let shown = WorkTaskChatStore.shown(workID) { return (shown, source) }
        own.open(source: source, handoff: handoff)
        guard own.record?.workID == workID else { return nil }
        return (own, source)
    }
    /// Waits until the store that will serve this card is free, then opens it on the card (no suspension in between).
    private func acquire(_ workID: String) async -> (WorkTaskChatStore, WorkSource)? {
        let target = WorkTaskChatStore.shown(workID) ?? own
        guard await target.waitIdle(upTo: idleWait) else { return nil }
        return store(for: workID)
    }

    /// Writes one round into its card's history and tells the server. True when the server knows it is in history.
    private func writeHistory(_ round: WorkLensPlans.Round) async -> Bool {
        guard let (chat, source) = await acquire(round.workID) else {
            lensLog.error("lens round \(round.roundId, privacy: .public) not written into history yet")
            return false
        }
        chat.syncFromDisk()
        let already = chat.record?.rounds.contains(where: { $0.lensRoundID == round.roundId }) == true
        guard await chat.recordLensRound(round, source: source, handoff: handoff) else {
            lensLog.error("lens round \(round.roundId, privacy: .public) not written into history yet")
            return false
        }
        let on = cardAutoSend(round.workID)
        // Only a round written into history now, on a card that waits for review (Auto-send off).
        if !already, !noticed.contains(round.roundId), !on {
            noticed.insert(round.roundId)
            let notice = WorkChatBoardCounts.lensNotice(roundID: round.roundId, title: source.title)
            onNotice?(WorkProgressNotice(key: notice.key, receiptID: "lens-" + round.roundId, workID: round.workID, title: "Work", body: notice.body))
        }
        guard await postHistory(round.roundId, autoSendCard: on) else { return false }
        autoSendPosted[round.roundId] = (round.workID, on)
        return true
    }
    private func postHistory(_ roundID: String, autoSendCard: Bool) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: ["state": "in_history", "autoSendCard": autoSendCard]),
              let answer = try? await handoff.taskChatCall(["work-lens-history", "--round-id", roundID], data: body) else { return false }
        if answer["reason"]?.string == "unknown_round" { autoSendPosted[roundID] = nil }
        return answer["accepted"]?.bool == true
    }

    /// The card's switch changed on the Mac since it was last reported: report it, so the lens's 428 rule reads it.
    private func repostAutoSend() async {
        for (roundID, entry) in autoSendPosted {
            let on = cardAutoSend(entry.workID)
            guard entry.on != on else { continue }
            if await postHistory(roundID, autoSendCard: on), autoSendPosted[roundID] != nil { autoSendPosted[roundID] = (entry.workID, on) }
        }
    }

    private func runSends() async {
        var keep: [(send: WorkLensPlans.SendRequest, since: Date)] = []
        for item in pendingSends {
            let send = item.send, waited = now().timeIntervalSince(item.since)
            guard sources().contains(where: { $0.id == send.workID }) else {
                await report(send.sendRequestId, refusedAll(send, "This card is not on COS Control's Work board."))
                continue
            }
            guard let (first, source) = await acquire(send.workID) else { if waited >= sendPatience { await report(send.sendRequestId, refusedAll(send, WorkLensPlans.busy)) } else { keep.append(item) }; continue }
            var chat = first
            first.syncFromDisk()
            if first.record?.rounds.contains(where: { $0.lensRoundID == send.roundId }) != true, let round = send.round,
               await first.recordLensRound(round, source: source, handoff: handoff) {
                let on = cardAutoSend(send.workID)
                if await postHistory(round.roundId, autoSendCard: on) { autoSendPosted[round.roundId] = (send.workID, on) }
                guard let again = await acquire(send.workID) else { keep.append(item); continue }
                chat = again.0
            }
            guard chat.record?.rounds.contains(where: { $0.lensRoundID == send.roundId }) == true else {
                // 0.5.337 (loop audit W15): a full card says so, at once (waiting cannot free a round).
                let full = WorkLensPlans.isFull(rounds: chat.record?.rounds.count ?? 0)
                if waited >= sendPatience || full { await report(send.sendRequestId, refusedAll(send, WorkLensPlans.notSavedReason(rounds: chat.record?.rounds.count ?? 0))) } else { keep.append(item) }
                continue
            }
            guard let results = await chat.sendLensRequest(send, source: source, handoff: handoff, cardAutoSend: cardAutoSend(send.workID)) else {
                if waited >= sendPatience { await report(send.sendRequestId, refusedAll(send, WorkLensPlans.busy)) } else { keep.append(item) }
                continue
            }
            await report(send.sendRequestId, results)
            if results.contains(where: { !WorkLensPlans.final.contains($0.state) }) {
                tracked[send.sendRequestId] = Tracked(workID: send.workID, roundID: send.roundId, ids: send.assignmentIds,
                                                      last: Dictionary(results.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }))
            }
        }
        pendingSends = keep
    }
    private func refusedAll(_ send: WorkLensPlans.SendRequest, _ why: String) -> [WorkLensPlans.Result] {
        send.assignmentIds.map { WorkLensPlans.Result(id: $0, state: "refused", receiptId: nil, detail: why, sessionID: nil) }
    }

    private func runStop(_ stop: WorkLensPlans.StopRequest) async {
        // A send still waiting here for its card never sends what the wearer stopped.
        if let i = pendingSends.firstIndex(where: { $0.send.roundId == stop.roundId }) {
            let send = pendingSends[i].send
            let stopped = send.assignmentIds.filter { stop.assignmentIds.contains($0) }
            if !stopped.isEmpty {
                await report(send.sendRequestId, stopped.map { WorkLensPlans.Result(id: $0, state: "stopped", receiptId: nil, detail: "Stopped from the lens before it was sent.", sessionID: nil) })
                let rest = send.assignmentIds.filter { !stop.assignmentIds.contains($0) }
                if rest.isEmpty { pendingSends.remove(at: i) }
                else { pendingSends[i].send = WorkLensPlans.SendRequest(sendRequestId: send.sendRequestId, roundId: send.roundId, workID: send.workID, assignmentIds: rest, confirm: send.confirm, autoSend: send.autoSend, round: send.round) }
            }
        }
        guard let sendID = stop.sendRequestId, let (chat, _) = await acquire(stop.workID) else { return }
        let results = await chat.stopLensAssignments(stop, handoff: handoff)
        guard !results.isEmpty else { return }
        await report(sendID, results)
        if var t = tracked[sendID] { for r in results { t.last[r.id] = r.state }; tracked[sendID] = t }
    }

    /// Miles's own Send of a lens round on the Mac: the assignments that left (held, sent, delivered, failed, stopped) are
    /// reported on the round, so the lens can never send them again; then followed like a lens send until final.
    private func reportMacSends() async {
        for (roundID, workID) in macPending {
            guard let (chat, _) = store(for: workID) else { continue }
            chat.syncFromDisk()
            let rows = macRows(chat, roundID)
            guard !rows.isEmpty else { macPending[roundID] = nil; continue }
            let answer = await postMac(roundID, rows)
            if answer == "accepted" || answer == "unknown_round" { macPending[roundID] = nil }
            if answer == "accepted" {
                let open = rows.filter { !WorkLensPlans.final.contains($0.state) }
                macTracked[roundID] = open.isEmpty ? nil : Tracked(workID: workID, roundID: roundID, ids: rows.map(\.id), last: Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }))
            }
        }
    }
    private func macRows(_ chat: WorkTaskChatStore, _ roundID: String, ids: [String]? = nil) -> [WorkLensPlans.Result] {
        chat.lensResults(lensRoundID: roundID, lensIDs: ids, handoff: handoff, macOnly: true).filter { !["pending", "refused"].contains($0.state) }
    }
    private func postMac(_ roundID: String, _ rows: [WorkLensPlans.Result]) async -> String {
        guard let body = try? JSONSerialization.data(withJSONObject: ["assignments": rows.prefix(3).map(\.json)]),
              let answer = try? await handoff.taskChatCall(["work-lens-mac-send", "--round-id", roundID], data: body) else { return "unreachable" }
        let summary = rows.map { "\($0.id):\($0.state)" }.joined(separator: " ")
        if answer["accepted"]?.bool == true { lensLog.info("lens round \(roundID, privacy: .public) Mac send reported \(summary, privacy: .public)"); return "accepted" }
        let reason = answer["reason"]?.string ?? "no answer"
        lensLog.error("lens round \(roundID, privacy: .public) Mac send not taken: \(reason, privacy: .public)")
        return reason
    }

    /// Each tracked send's assignments, re-read from the journal every 15 s; only changes are reported. A send stops being
    /// tracked when every assignment is final, or the server no longer knows it.
    private func reportProgress() async {
        guard !tracked.isEmpty || !macTracked.isEmpty else { return }
        if let at = progressAt, now().timeIntervalSince(at) < 15 { return }
        progressAt = now()
        await handoff.refreshReceipts()
        for (sendID, t) in tracked {
            guard let (chat, _) = store(for: t.workID) else { continue }
            chat.syncFromDisk()
            let results = chat.lensResults(lensRoundID: t.roundID, lensIDs: t.ids, handoff: handoff, attempted: Set(t.ids))
            let changed = results.filter { t.last[$0.id] != $0.state }
            if !changed.isEmpty, await report(sendID, changed) == false { continue }
            var next = t; for r in results { next.last[r.id] = r.state }
            // Done when every assignment is final; a round no longer in this card's history has nothing left to report.
            tracked[sendID] = results.isEmpty || results.allSatisfy({ WorkLensPlans.final.contains($0.state) }) ? nil : next
        }
        for (roundID, t) in macTracked {
            guard let (chat, _) = store(for: t.workID) else { continue }
            chat.syncFromDisk()
            let rows = macRows(chat, roundID, ids: t.ids)
            let changed = rows.filter { t.last[$0.id] != $0.state }
            if !changed.isEmpty, await postMac(roundID, changed) != "accepted" { continue }
            var next = t; for r in rows { next.last[r.id] = r.state }
            macTracked[roundID] = rows.isEmpty || rows.allSatisfy({ WorkLensPlans.final.contains($0.state) }) ? nil : next
        }
    }

    @discardableResult private func report(_ sendID: String, _ results: [WorkLensPlans.Result]) async -> Bool {
        guard !results.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["assignments": results.prefix(3).map(\.json)]) else { return false }
        let answer = try? await handoff.taskChatCall(["work-lens-result", "--send-id", sendID], data: body)
        let summary = results.map { "\($0.id):\($0.state)" }.joined(separator: " ")
        if answer?["accepted"]?.bool == true { lensLog.info("lens send \(sendID, privacy: .public) reported \(summary, privacy: .public)"); return true }
        let reason = answer?["reason"]?.string ?? "no answer"
        lensLog.error("lens send \(sendID, privacy: .public) result not taken: \(reason, privacy: .public)")
        if reason == "unknown_send" { tracked[sendID] = nil }
        return false
    }

    /// After a restart: lens sends from the last 14 days are reported again until final, and unsent lens rounds get their
    /// card's Auto-send reported again. Reads the saved histories only.
    private func seed() {
        guard let server = handoff.taskChatServerID else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: WorkTaskChatStore.historyFolder(), includingPropertiesForKeys: nil)) ?? []
        let marker = Data("\"lensRoundID\"".utf8), horizon = now().timeIntervalSince1970 - 14 * 86_400
        for file in files where file.pathExtension == "json" {
            guard let data = try? WorkSessionLinks.chatRead(file), data.range(of: marker) != nil,
                  let saved = try? JSONDecoder().decode(WorkChatRecord.self, from: data), saved.serverID == server else { continue }
            for round in saved.rounds {
                guard let roundID = round.lensRoundID, (round.lensAt ?? round.at) >= horizon else { continue }
                let sends = Set(round.assignments.compactMap(\.lensSendID))
                if sends.isEmpty { autoSendPosted[roundID] = (saved.workID, nil) }
                for sendID in sends where tracked.count < 200 {
                    let ids = round.assignments.filter { $0.lensSendID == sendID }.compactMap(\.lensID)
                    tracked[sendID] = Tracked(workID: saved.workID, roundID: roundID, ids: ids, last: [:])
                }
            }
        }
    }
}
