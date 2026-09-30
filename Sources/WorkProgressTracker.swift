import Foundation
import os

private let trackingLog = Logger(subsystem: "com.cos.control", category: "work-tracking")

/// A Mac notification the tracker asks for. Posted once per handoff and moment (WorkProgress.notified).
struct WorkProgressNotice: Equatable, Sendable {
    let key: String
    let receiptID: String
    let workID: String
    let title: String
    let body: String
}

/// 0.5.247: follows handoffs from sent to done, whether or not Activity is open, and moves board cards as far as QA.
///
/// Evidence, in order:
/// - Received (the card goes to Draft): the server's delivery receipt, or the session's own conversation showing the
///   instruction arriving.
/// - The session's status line (`COS-WORK <tag>: done ...`, the card goes to QA). Needs input and blocked notify you
///   and move nothing. Only replies after the instruction arrived count.
/// - Jev, when the session has gone idle and its newest reply since the handoff has no status line: it reads those
///   replies against the task (a confident done goes to QA). At most twice per handoff, once per reply.
///
/// Moves go forward only, never to Complete. Undo, or moving a card back yourself, stops automatic moves for that
/// handoff. A move that cannot be made now (a busy or read-only board) is kept and retried; a record that finds the
/// journal busy is kept and written on a later pass, so a moved card always gets its why-line and Undo.
@MainActor final class WorkProgressTracker: ObservableObject {
    /// What the tracker needs from the board. Closures, so checks can run it against a fake board.
    struct Board {
        var tasks: () -> [TaskRow]
        var writable: () -> Bool
        var reload: () async -> Void
        var move: (TaskRow, String) async throws -> Void
    }
    /// One read of a session: its recent replies and message openings, and whether it is still working.
    struct SessionRead {
        var replies: [WorkProgress.Reply]
        var prompts: [WorkProgress.Reply]
        var runningActive: Bool
        var agentState: String
        var lastActivityAt: Double?
        /// False when the server gave no message history (an older server, or its read failed): nothing is inferred.
        var hasHistory: Bool
        /// A run with no session of its own (a Cursor or Ollama answer): its one reply is the job's result, written
        /// after the handoff by definition.
        var fromJobResult = false
    }

    let store: WorkHandoffStore
    private let board: Board
    private let notify: (WorkProgressNotice) -> Void
    private let now: () -> Date
    /// The newest automatic move, for the board's strip: receipt and event id.
    @Published private(set) var latestMove: (receiptID: String, eventID: String)?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var ticking = false
    private var boardReadAt: Date?
    /// Records that found the journal busy, replayed at the start of every pass until they land.
    private var deferred: [(id: String, change: (inout WorkHandoffReceipt) -> Bool)] = []
    private var undoing: Set<String> = []
    /// The stage each handoff's latest successful move reached, for the notification's "Moved to …".
    private var movedTo: [String: String] = [:]
    /// Per session: when a new message last appeared, when it was last read, and what it held (for the back-off).
    private var sessionChangedAt: [String: Date] = [:]
    private var sessionReadAt: [String: Date] = [:]
    private var sessionDigest: [String: String] = [:]
    /// Per handoff: when Jev was last tried without an answer. Transient failures retry, at most every 10 minutes.
    private var jevTriedAt: [String: Date] = [:]

    /// Seconds between passes while something is tracked, and while nothing is.
    nonisolated static let activeInterval: Double = 30
    nonisolated static let idleInterval: Double = 120
    /// A card's stage is re-read when older than this, right before a move, so a move never works from a stale board.
    nonisolated static let boardFreshness: Double = 20
    /// Jev is asked only once the session's transcript has been still this long (tool calls write it too).
    nonisolated static let quietBeforeJev: Double = 90
    nonisolated static let jevRetryAfter: Double = 600
    /// Messages read per session: enough to hold a status line past a few more exchanges.
    nonisolated static let turnsPerRead = 24

    init(store: WorkHandoffStore, board: Board, notify: @escaping (WorkProgressNotice) -> Void, now: @escaping () -> Date = Date.init) {
        self.store = store; self.board = board; self.notify = notify; self.now = now
    }

    func start() {
        guard loop == nil else { return }
        store.onHandoffRecorded = { [weak self] in self?.poke() }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let busy = !self.candidates(now: self.now().timeIntervalSince1970).isEmpty || !self.deferred.isEmpty
                let seconds = busy ? Self.activeInterval : Self.idleInterval
                let nap = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
                self.sleeper = nap
                await nap.value
            }
        }
    }
    /// Run the next pass now (a handoff was just recorded).
    func poke() { sleeper?.cancel() }

    /// Handoffs being followed: tracked (WorkProgress.tracked), the newest for their work (a newer handoff replaces an
    /// older one), and on a task that is not complete.
    func candidates(now: Double) -> [WorkHandoffReceipt] {
        let complete = Set(board.tasks().filter { $0.checked || $0.workStage == "complete" }.map(\.workSourceID))
        return store.receipts.filter { row in
            WorkProgress.tracked(row, now: now) && !complete.contains(row.workID) && isNewest(row)
        }
    }
    private func isNewest(_ row: WorkHandoffReceipt) -> Bool {
        !store.receipts.contains { $0.workID == row.workID && $0.id != row.id && $0.createdAt > row.createdAt }
    }

    /// One pass. Safe to call at any time; overlapping calls are dropped.
    func tick() async {
        guard !ticking else { return }
        ticking = true; defer { ticking = false }
        store.retryJournalIfUnavailable()
        flushDeferred()
        let start = now().timeIntervalSince1970
        // Moves decided earlier that could not be made yet.
        for row in store.receipts where row.progress?.pendingStage != nil && isNewest(row)
            && start - row.createdAt < WorkProgress.trackedDays * 86_400 {
            await attemptMove(row.id)
        }
        let open = candidates(now: start)
        if !open.isEmpty { await trackPass(open, start: start) }
        // 0.5.249: a New session whose first reply is done opens in its app, tracked or not (a done first reply ends
        // tracking), once, and never while its run is going.
        await store.openReadyApps()
    }

    /// One pass over the handoffs being followed.
    private func trackPass(_ open: [WorkHandoffReceipt], start: Double) async {
        await store.reconcileForTracking(ids: Set(open.map(\.id)), now: start)

        // One read per session, backing off while a session stays quiet.
        var reads: [String: SessionRead] = [:]
        let sessions = Set(open.compactMap(WorkProgress.workingSession))
        for sessionID in sessions.sorted() {
            let waiting = open.contains { WorkProgress.workingSession($0) == sessionID && $0.progress?.receivedAt == nil }
            guard waiting || shouldRead(sessionID) else { continue }
            do {
                let read = try await store.sessionRead(sessionID: sessionID, turns: Self.turnsPerRead)
                reads[sessionID] = read
                noteRead(sessionID, read)
            } catch {
                trackingLog.notice("read failed session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        for stale in open.sorted(by: { $0.createdAt < $1.createdAt }) {
            // The receipt as it is now: the delivery read above may have changed it (a run that just completed).
            let row = store.receipts.first { $0.id == stale.id } ?? stale
            var read = WorkProgress.workingSession(row).flatMap { reads[$0] }
            if read == nil, row.channel == "job", row.sessionID == nil, row.status == "completed", let result = row.result, !result.isEmpty {
                read = SessionRead(replies: [.init(text: result, at: nil)], prompts: [], runningActive: false, agentState: "",
                                   lastActivityAt: nil, hasHistory: true, fromJobResult: true)
            }
            await advance(row.id, read: read)
        }
    }

    private func shouldRead(_ sessionID: String) -> Bool {
        guard let last = sessionReadAt[sessionID] else { return true }
        let quiet = now().timeIntervalSince(sessionChangedAt[sessionID] ?? last)
        let interval: Double = quiet < 3_600 ? 0 : quiet < 86_400 ? 300 : 1_800
        return now().timeIntervalSince(last) >= interval
    }
    private func noteRead(_ sessionID: String, _ read: SessionRead) {
        let digest = WorkProgress.digest((read.replies + read.prompts).map(\.digest).joined())
        if sessionDigest[sessionID] != digest { sessionDigest[sessionID] = digest; sessionChangedAt[sessionID] = now() }
        sessionReadAt[sessionID] = now()
    }

    /// Everything one pass learns about one handoff.
    private func advance(_ id: String, read: SessionRead?) async {
        guard let row = store.receipts.first(where: { $0.id == id }), let progress = row.progress, !progress.finished else { return }
        let at = now().timeIntervalSince1970

        // Untimed replies already in the session answered earlier work (Cursor writes no times).
        if let read, read.hasHistory, !read.fromJobResult, progress.baseline == nil {
            let untimed = read.replies.filter { $0.at == nil }.map(\.digest)
            let untimedPrompts = read.prompts.filter { $0.at == nil }.map(\.digest)
            guard store.updateReceipt(id, { current in
                guard var next = current.progress, next.baseline == nil else { return false }
                next.baseline = Array(untimed.suffix(WorkProgress.maxSeen))
                next.promptBaseline = Array(untimedPrompts.suffix(WorkProgress.maxSeen))
                current.progress = next; return true
            }) else { return }
        }
        // The session's own conversation shows the instruction arriving.
        var arrival: Double?
        if let read, read.hasHistory, progress.promptAt == nil, row.mode != .newSession {
            arrival = WorkProgress.promptArrival(prompt: row.prompt, messages: read.prompts, since: row.createdAt)
            // 0.5.249: a note you send yourself in Terminal (Cursor writes no times) arrives when it first appears.
            if arrival == nil, row.channel == "app", let seen = progress.promptBaseline,
               WorkProgress.untimedArrival(prompt: row.prompt, messages: read.prompts, baseline: seen) { arrival = at }
        }
        // 1. Received: record once, move to Draft, notify.
        if progress.receivedAt == nil && (WorkProgress.deliveryConfirmed(row) || arrival != nil) {
            let text = WorkProgress.receivedText(row, fromTranscript: arrival != nil && !WorkProgress.deliveryConfirmed(row))
            let target = WorkProgress.boardTask(row.workID) != nil && progress.paused != true ? WorkProgress.target(for: .received) : nil
            guard store.updateReceipt(id, { current in
                guard var next = current.progress, next.receivedAt == nil else { return false }
                next.receivedAt = arrival ?? at
                if let arrival { next.promptAt = arrival }
                next.record(.received, text, at: arrival ?? at)
                if let target, next.pendingStage == nil { next.pendingStage = target }
                current.progress = next
                // 0.5.249: a note you took to the app is delivered once its session shows it arriving.
                if current.channel == "app", current.status == "queued" {
                    current.status = "delivered"
                    current.detail = "Sent in \(WorkHandoffStore.openPlace(current.provider)). Work follows it from here."
                }
                return true
            }) else { return }
            trackingLog.notice("received receipt=\(id, privacy: .public) transcript=\(arrival != nil, privacy: .public)")
            await attemptMove(id)
            post(id, key: "received", title: "Received: " + row.workTitle,
                 body: (row.mode == .newSession ? "The new session has it." : "\u{201C}\(WorkSendPlan.clip(row.sessionTitle))\u{201D} has it.")
                    + movedSuffix(id, to: "draft"))
        } else if let arrival, progress.promptAt == nil {
            store.updateReceipt(id) { current in
                guard var next = current.progress, next.promptAt == nil else { return false }
                next.promptAt = arrival; current.progress = next; return true
            }
        }
        guard let read, read.hasHistory, let current = store.receipts.first(where: { $0.id == id }),
              let latest = current.progress, latest.receivedAt != nil else { return }
        await follow(current, latest, read)
    }

    /// Reads what the session wrote after the instruction arrived: a reply, a status line, and Jev's reading.
    private func follow(_ row: WorkHandoffReceipt, _ progress: WorkProgress, _ read: SessionRead) async {
        let id = row.id, at = now().timeIntervalSince1970
        let floor = progress.promptAt ?? row.createdAt
        let eligible = WorkProgress.eligible(read.replies, floor: floor, baseline: progress.baseline ?? [])
        let unseen = eligible.filter { !progress.seenReplies.contains($0.digest) }
        let report = WorkProgress.latestReport(tag: progress.tag, replies: eligible)
        let reportIsNew = report.map { progress.reported != $0.report.kind || progress.evidence != $0.report.evidence } ?? false
        if !unseen.isEmpty || reportIsNew {
            let target = WorkProgress.boardTask(row.workID) != nil && progress.paused != true ? WorkProgress.target(for: .done) : nil
            guard store.updateReceipt(id, { current in
                guard var next = current.progress, !next.finished else { return false }
                if next.workingAt == nil, let first = unseen.first ?? eligible.first {
                    next.workingAt = first.at ?? at
                    next.record(.working, "Replied", at: first.at ?? at)
                }
                if let report, next.reported != report.report.kind || next.evidence != report.report.evidence {
                    let label = report.report.kind == .done ? "Done" : report.report.kind == .blocked ? "Blocked" : "Needs your input"
                    next.record(report.report.kind, "\(label), from the session\u{2019}s status line: \u{201C}\(report.report.evidence)\u{201D}",
                                at: report.reply.at ?? at)
                    next.reported = report.report.kind; next.reportedBy = "session"; next.evidence = report.report.evidence
                    if report.report.kind == .done, let target, next.pendingStage == nil || next.pendingStage == "draft" { next.pendingStage = target }
                }
                unseen.forEach { next.markSeen($0.digest) }
                current.progress = next
                return true
            }) else { return }   // the journal was busy: read again next pass
        }
        if let report, reportIsNew {
            trackingLog.notice("report receipt=\(id, privacy: .public) kind=\(report.report.kind.rawValue, privacy: .public)")
            switch report.report.kind {
            case .done:
                await attemptMove(id)
                post(id, key: "done", title: "Done: " + row.workTitle,
                     body: "\u{201C}\(WorkProgress.clip(report.report.evidence, 160))\u{201D}" + movedSuffix(id, to: "qa"))
                return
            case .needsInput, .blocked:
                post(id, key: "\(report.report.kind.rawValue):\(report.reply.digest)",
                     title: (report.report.kind == .blocked ? "Blocked: " : "Needs your input: ") + row.workTitle,
                     body: "\u{201C}\(WorkProgress.clip(report.report.evidence, 160))\u{201D}")
            default: break
            }
        }
        await askJevIfDue(row.id, eligible: eligible, floor: floor, read: read)
    }

    /// Jev reads the replies after the handoff arrived against the task, when all of these hold:
    /// - it is a board task;
    /// - the newest of those replies has a time and carries no status line for this task;
    /// - Jev has not judged that reply, and has judged fewer than two;
    /// - the session is idle: its transcript untouched for 90 seconds, not running, and the turn or run finished.
    private func askJevIfDue(_ id: String, eligible: [WorkProgress.Reply], floor: Double, read: SessionRead) async {
        guard let row = store.receipts.first(where: { $0.id == id }), let progress = row.progress, !progress.finished,
              let task = WorkProgress.boardTask(row.workID), let sessionID = WorkProgress.workingSession(row),
              let newest = eligible.last, newest.at != nil,
              !WorkProgress.reports(in: newest.text).contains(where: { $0.tag == progress.tag }) else { return }
        let asked = progress.jevAsked ?? []
        guard !asked.contains(newest.digest), asked.count < WorkProgress.maxJevAsks else { return }
        let nowDate = now(), at = nowDate.timeIntervalSince1970
        guard Self.sessionIdle(row: row, read: read, now: at),
              jevTriedAt[id].map({ nowDate.timeIntervalSince($0) >= Self.jevRetryAfter }) ?? true else { return }
        jevTriedAt[id] = nowDate
        trackingLog.notice("jev ask receipt=\(id, privacy: .public)")
        let answer = await store.completionCheck(domain: task.domain, identity: task.identity, sessionID: sessionID, after: floor)
        guard let verdict = answer.verdict else {
            let reason = answer.reason ?? "unavailable"
            trackingLog.notice("jev no answer receipt=\(id, privacy: .public) reason=\(reason, privacy: .public)")
            let final = Self.finalJevReasons.contains(reason)
            let text = Self.jevUnavailableText(reason)
            let noteKey = "note:" + reason
            guard final || (text != nil && !progress.notified.contains(noteKey)) else { return }
            write(id) { current in
                guard var next = current.progress else { return false }
                if let text, !next.notified.contains(noteKey) { next.record(.note, text, at: at); next.markNotified(noteKey) }
                if final, !(next.jevAsked ?? []).contains(newest.digest) { next.jevAsked = (next.jevAsked ?? []) + [newest.digest] }
                current.progress = next; return true
            }
            return
        }
        jevTriedAt[id] = nil
        let moves = verdict.movesCard
        let target = progress.paused != true ? WorkProgress.target(for: .done) : nil
        write(id) { current in
            guard var next = current.progress, !(next.jevAsked ?? []).contains(newest.digest) else { return false }
            next.jevAsked = (next.jevAsked ?? []) + [newest.digest]
            next.record(.jev, verdict.text, at: at)
            if moves && !next.finished {
                next.reported = .done; next.reportedBy = "jev"; next.evidence = verdict.text
                if let target, next.pendingStage == nil || next.pendingStage == "draft" { next.pendingStage = target }
            }
            current.progress = next; return true
        }
        if moves {
            await attemptMove(id)
            post(id, key: "done", title: "Done: " + row.workTitle, body: verdict.text + movedSuffix(id, to: "qa"))
        }
    }

    /// Idle means the session is not working on the turn now: its transcript untouched for `quietBeforeJev`, not
    /// generating, and the turn (a Continue) or run (a New session) finished.
    nonisolated static func sessionIdle(row: WorkHandoffReceipt, read: SessionRead, now: Double) -> Bool {
        guard let last = read.lastActivityAt, now - last >= quietBeforeJev, !read.runningActive,
              !["running", "waiting"].contains(read.agentState) else { return false }
        switch row.channel {
        case "job": return row.status == "completed"
        case "turn", "queue": return WorkProgress.deliveryConfirmed(row)
        default: return true
        }
    }
    /// Reasons that will not change by asking again about the same reply.
    nonisolated static let finalJevReasons: Set<String> = ["task_not_found", "session_not_found", "no_reply", "invalid_completion_request", "no_done_when"]

    nonisolated static func jevUnavailableText(_ reason: String) -> String? {
        switch reason {
        case "server_too_old": return "The reply has no status line. Jev checks need server 6.58.0; open the session to check."
        case "jev_not_configured": return "The reply has no status line. Add a Jev key in Settings to have replies checked."
        case "task_not_found", "session_not_found", "invalid_completion_request": return nil
        default: return "The reply has no status line, and Jev could not check it just now. COS will try again."
        }
    }

    // MARK: - Moves

    /// Makes the move a handoff is waiting for, when every rule allows it, and records it with its reason. A move that
    /// cannot be made now stays pending and is tried again on later passes, up to `maxMoveAttempts`.
    private func attemptMove(_ id: String) async {
        // No move is ever queued on a paused handoff (every target is nil while paused, and Undo clears the queue in the
        // same write that pauses). An Undo whose record still waits on a busy journal is caught below: the card sits
        // before COS's unrecorded move, which reads as moved back by you.
        guard let row = store.receipts.first(where: { $0.id == id }), let progress = row.progress,
              let target = progress.pendingStage, let identity = WorkProgress.boardTask(row.workID) else { return }
        if boardReadAt.map({ now().timeIntervalSince($0) > Self.boardFreshness }) ?? true {
            await board.reload(); boardReadAt = now()
        }
        guard let task = board.tasks().first(where: { $0.domain == identity.domain && $0.workIdentity == identity.identity }) else {
            moveFailed(id, target, "the card is not on the board right now"); return
        }
        let current = task.checked ? "complete" : task.workStage
        if WorkProgress.movedBackByYou(progress, currentStage: current) {
            let at = now().timeIntervalSince1970
            write(id) { row in
                guard var next = row.progress, next.paused != true else { return false }
                next.paused = true; next.pendingStage = nil
                next.record(.note, "You moved it back to \(WorkProgress.stageTitle(current)), so COS leaves this card where you put it.", at: at)
                row.progress = next; return true
            }
            return
        }
        guard WorkProgress.advances(from: current, to: target) else {
            // The rules hold the card (you already moved it this far, or it is complete): nothing to do.
            write(id) { row in guard row.progress?.pendingStage != nil else { return false }; row.progress?.pendingStage = nil; return true }
            return
        }
        guard board.writable(), task.workMetadataError == nil else {
            moveFailed(id, target, task.workMetadataError ?? "the board is read-only right now"); return
        }
        let eventID = UUID().uuidString.lowercased()
        let reason = Self.moveReason(progress)
        do {
            try await board.move(task, target)
        } catch where Self.savedButRefreshFailed(error) {
            trackingLog.notice("move saved, refresh failed receipt=\(id, privacy: .public)")
        } catch {
            moveFailed(id, target, error.localizedDescription); return
        }
        boardReadAt = nil
        latestMove = (id, eventID)
        movedTo[id] = target
        trackingLog.notice("moved receipt=\(id, privacy: .public) from=\(current, privacy: .public) to=\(target, privacy: .public)")
        let at = now().timeIntervalSince1970
        write(id) { row in
            guard var next = row.progress else { return false }
            next.record(.moved, reason, at: at, from: current, to: target, id: eventID)
            if next.pendingStage == target { next.pendingStage = nil }
            next.moveAttempts = nil
            row.progress = next; return true
        }
    }
    private func moveFailed(_ id: String, _ target: String, _ reason: String) {
        trackingLog.notice("move failed receipt=\(id, privacy: .public) target=\(target, privacy: .public) reason=\(reason, privacy: .public)")
        let at = now().timeIntervalSince1970
        write(id) { row in
            guard var next = row.progress, next.pendingStage == target else { return false }
            let attempts = (next.moveAttempts ?? 0) + 1
            next.moveAttempts = attempts
            if attempts == 1 {
                next.record(.note, "Could not move it to \(WorkProgress.stageTitle(target)) yet: \(reason). COS will try again.", at: at)
            }
            if attempts >= WorkProgress.maxMoveAttempts {
                next.record(.note, "Stopped trying to move it to \(WorkProgress.stageTitle(target)): \(reason).", at: at)
                next.pendingStage = nil; next.moveAttempts = nil
            }
            row.progress = next; return true
        }
    }
    /// The board saved the change and only its refresh failed (ControllerModel.mutateWorkTask): the card did move.
    nonisolated static func savedButRefreshFailed(_ error: Error) -> Bool {
        error.localizedDescription.hasPrefix("Change saved, but refreshing Work failed")
    }
    nonisolated static func moveReason(_ progress: WorkProgress) -> String {
        guard progress.reported == .done else { return "the session received it" }
        return progress.reportedBy == "jev" ? "Jev read the reply as done" : "the session reported done"
    }

    /// Moves the card back to where it was and stops automatic moves for this handoff.
    func undo(receiptID: String, eventID: String) async -> String? {
        guard !undoing.contains(receiptID) else { return nil }
        undoing.insert(receiptID); defer { undoing.remove(receiptID) }
        guard let row = store.receipts.first(where: { $0.id == receiptID }),
              let event = row.progress?.events.first(where: { $0.id == eventID }),
              let from = event.fromStage, let identity = WorkProgress.boardTask(row.workID) else { return "That move is no longer on record." }
        await board.reload(); boardReadAt = now()
        guard let task = board.tasks().first(where: { $0.domain == identity.domain && $0.workIdentity == identity.identity }),
              WorkProgress.canUndo(event, currentStage: task.checked ? "complete" : task.workStage) else { return "The card has moved since. Nothing was changed." }
        do { try await board.move(task, from) } catch where Self.savedButRefreshFailed(error) {
        } catch {
            return error.localizedDescription
        }
        boardReadAt = nil
        let at = now().timeIntervalSince1970
        write(receiptID) { current in
            guard var next = current.progress, let index = next.events.firstIndex(where: { $0.id == eventID }),
                  next.events[index].undoneAt == nil else { return false }
            next.events[index].undoneAt = at
            next.paused = true; next.pendingStage = nil
            next.record(.undone, "You moved it back to \(WorkProgress.stageTitle(from)). COS will not move this card again for this handoff.", at: at)
            current.progress = next; return true
        }
        if latestMove?.eventID == eventID { latestMove = nil }
        trackingLog.notice("undo receipt=\(receiptID, privacy: .public)")
        return nil
    }
    func dismissLatestMove() { latestMove = nil }

    // MARK: - Records and notices

    /// Writes a record, or keeps it for the next pass when the journal is busy (a send or refresh holds it).
    private func write(_ id: String, _ change: @escaping (inout WorkHandoffReceipt) -> Bool) {
        switch store.tryUpdateReceipt(id, change) {
        case .written, .unchanged: return
        case .busy:
            deferred.append((id, change))
            trackingLog.notice("record deferred receipt=\(id, privacy: .public) pending=\(self.deferred.count, privacy: .public)")
        }
    }
    private func flushDeferred() {
        guard !deferred.isEmpty else { return }
        let waiting = deferred; deferred = []
        for item in waiting where store.tryUpdateReceipt(item.id, item.change) == .busy { deferred.append(item) }
    }
    /// Records still waiting for the journal (checks read this).
    var deferredCount: Int { deferred.count }

    /// " Moved to QA." only when this pass actually moved the card there.
    private func movedSuffix(_ id: String, to stage: String) -> String {
        movedTo[id] == stage ? " Moved to \(WorkProgress.stageTitle(stage))." : ""
    }
    private func post(_ id: String, key: String, title: String, body: String) {
        guard let row = store.receipts.first(where: { $0.id == id }), row.progress?.notified.contains(key) == false else { return }
        notify(WorkProgressNotice(key: key, receiptID: id, workID: row.workID, title: title, body: body))
        write(id) { current in
            guard var next = current.progress, !next.notified.contains(key) else { return false }
            next.markNotified(key); current.progress = next; return true
        }
    }
}
