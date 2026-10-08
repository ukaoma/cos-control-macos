import Foundation
import os

private let trackingLog = Logger(subsystem: "com.gotcos.control", category: "work-tracking")

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
/// 0.5.253 (QA, deferred from 0.5.252): which read of the board the rows on record come from. Each load takes a
/// generation when it starts; a load a newer one superseded records nothing. A caller that marks `started` before it
/// reloads, and waits while a newer load is still to finish, reads OK only when the result on record is from a load
/// that started after its mark, and that load read the board: the rows are that read's, never an earlier one's.
struct WorkBoardReads: Equatable, Sendable {
    /// The newest load started, the load whose result is on record, and whether that load read the board.
    private(set) var started = 0
    private(set) var recorded = 0
    private(set) var recordedOK = false
    mutating func begin() -> Int { started += 1; return started }
    /// Whether `generation` is still the newest load (only the newest records its result).
    func current(_ generation: Int) -> Bool { generation == started }
    /// Records a load's result; false (and nothing recorded) when a newer load superseded it.
    @discardableResult mutating func record(_ generation: Int, ok: Bool) -> Bool {
        guard current(generation) else { return false }
        recorded = generation; recordedOK = ok
        return true
    }
    /// A load started and not recorded yet.
    var pending: Bool { started > recorded }
    /// Whether the result on record is from a load that started after `mark` and read the board.
    func readOK(since mark: Int) -> Bool { recorded > mark && recordedOK }
}

@MainActor final class WorkProgressTracker: ObservableObject {
    /// What the tracker needs from the board. Closures, so checks can run it against a fake board.
    struct Board {
        var tasks: () -> [TaskRow]
        var writable: () -> Bool
        var reload: () async -> Void
        /// Next release: the move carries who made it and why, for the move log (ControllerModel.setWorkStage).
        var move: (TaskRow, String, WorkStageMove) async throws -> Void
        /// 0.5.252: a glasses request is checked only against a board that was just read; a failed read leaves the old
        /// rows in `tasks`. 0.5.253 (QA, deferred from 0.5.252): reloads the board and says whether the rows now come
        /// from a read that began after this call and read the board (WorkBoardReads). An older read that failed, or one
        /// a newer read superseded, never counts as read because a newer one ran.
        var readFresh: () async -> Bool
        /// Next release: the server has `POST /api/work-board/evidence-check` (`capabilities.evidenceCheck`). Without it the
        /// tracker falls back to the completion check.
        var evidenceCheck: () -> Bool = { false }
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
    /// Next release: shadow mode (Settings, on by default): evidence-path moves are logged as would-moves and never made.
    private let shadow: () -> Bool
    /// Only the Control process holding this lease follows cards and moves them (the follow pass, the evidence and done-line
    /// moves, and the handoff path's board moves). Every Control still records its own sends, opens its own apps and links
    /// its own Cursor chats (QA W7: the lease once stopped a second Control from tracking anything).
    let lease: WorkTrackerLease
    /// Whether this pass holds the lease.
    private var holdsLease = false
    private var leaseNoted = false
    /// The server said the evidence check is off or out of budget: until when, and whether the completion check stands in.
    private var evidenceOff: (until: Date, fallback: Bool, reason: String)?
    /// Session reads made this pass, shared by the handoffs and the follows.
    private var passReads: [String: SessionRead] = [:]
    /// Per card: when an evidence or completion check last got no answer. Retried at most every 10 minutes.
    private var evidenceTriedAt: [String: Date] = [:]
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
    /// 0.5.252: the glasses request inbox (WorkHandoffStore.swift). It sends through the store like the Agent workspace,
    /// so it holds the journal during a send; the tracker's own passes never do, and it runs on its own loop.
    let requests: WorkRequestInbox

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
    /// Next release: evidence checks that call Jev, per card per day (plan v2 section 7). A cached answer costs nothing and
    /// does not count.
    nonisolated static let maxChecksPerDay = 8
    /// A quiet card is checked again after this long (a page can go live with no new reply).
    nonisolated static let evidenceRecheck: Double = 4 * 3_600
    /// Cards checked for the first time in one pass, at most (QA W3: the first launch checked every old card at once).
    nonisolated static let firstChecksPerPass = 3
    /// Done reports remembered per card.
    nonisolated static let actedDoneKept = 8

    init(store: WorkHandoffStore, board: Board, notify: @escaping (WorkProgressNotice) -> Void, now: @escaping () -> Date = Date.init,
         shadow: @escaping () -> Bool = { true }, lease: WorkTrackerLease? = nil) {
        self.store = store; self.board = board; self.notify = notify; self.now = now; self.shadow = shadow
        self.lease = lease ?? WorkTrackerLease(url: store.leaseURL)
        requests = WorkRequestInbox(store: store, board: board, now: now)
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
        // 0.5.252: the glasses request inbox lists for as long as COS Control runs.
        requests.start()
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
        store.moves.flush(); store.follows.flush()
        // One process follows cards and moves them; another Control (a review candidate beside the stable app) still
        // tracks its own sends, and leaves their moves pending for the holder.
        holdsLease = lease.acquire()
        if !holdsLease, !leaseNoted { trackingLog.notice("tracker lease held by another COS Control; this one follows and moves no card") }
        leaseNoted = !holdsLease
        passReads = [:]
        let start = now().timeIntervalSince1970
        // Moves decided earlier that could not be made yet.
        if holdsLease {
            for row in store.receipts where row.progress?.pendingStage != nil && isNewest(row)
                && start - row.createdAt < WorkProgress.trackedDays * 86_400 {
                await attemptMove(row.id)
            }
        }
        postFailures()
        let open = candidates(now: start)
        if !open.isEmpty { await trackPass(open, start: start) }
        // Next release: cards follow their sessions, and move on evidence.
        if holdsLease { await followPass(start: start, tracked: Set(open.map(\.id))) }
        // 0.5.249: a New session whose first reply is done opens in its app, tracked or not (a done first reply ends
        // tracking), once, and never while its run is going.
        await store.openReadyApps()
        // 0.5.253: a Cursor chat filled in for you is found once you sent it; an Open in Claude made while a glasses send
        // held the journal is written.
        await store.linkCursorPrefills()
        store.writeOpenedMeanwhile()
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
                passReads[sessionID] = read
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
        // Next release: with the server's evidence check, the card's follows are judged there (followPass); the completion
        // check is the fallback for a server without it, or with it switched off (evidence_disabled).
        guard evidenceRoute(now()) == .fallback else { return }
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
        // Shadow mode gates this path too (QA W2): on a server without the evidence check, a Jev "done" is a would-move.
        let shadowed = moves && shadow()
        let target = progress.paused != true && !shadowed ? WorkProgress.target(for: .done) : nil
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
        if shadowed {
            trackingLog.notice("decision receipt=\(id, privacy: .public) decision=would-move (shadow, completion check)")
            if let card = board.tasks().first(where: { $0.domain == task.domain && $0.workIdentity == task.identity }), !store.follows.isPaused(row.workID) {
                await moveOnEvidence(card, why: "Jev read the reply as done", clauses: [], live: false, at: at)
            }
        } else if moves {
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
        // Only the lease holder moves cards; the move stays pending in the journal for it.
        guard holdsLease, let row = store.receipts.first(where: { $0.id == id }), let progress = row.progress,
              let target = progress.pendingStage, let identity = WorkProgress.boardTask(row.workID) else { return }
        if boardReadAt.map({ now().timeIntervalSince($0) > Self.boardFreshness }) ?? true {
            await board.reload(); boardReadAt = now()
        }
        guard let task = board.tasks().first(where: { $0.domain == identity.domain && $0.workIdentity == identity.identity }) else {
            moveFailed(id, target, "the card is not on the board right now"); return
        }
        let current = task.checked ? "complete" : task.workStage
        // Next release: a card paused by an Undo, a move back or Stop following moves for no handoff (validation W6).
        if store.follows.isPaused(row.workID) {
            write(id) { row in guard row.progress?.pendingStage != nil else { return false }; row.progress?.pendingStage = nil; return true }
            return
        }
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
            try await board.move(task, target, WorkStageMove(by: .cos, why: reason, receiptID: id, eventID: eventID))
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
        do { try await board.move(task, from, WorkStageMove(by: .you, why: "Undo of COS\u{2019}s move")) } catch where Self.savedButRefreshFailed(error) {
        } catch {
            return error.localizedDescription
        }
        boardReadAt = nil
        let at = now().timeIntervalSince1970
        // Next release: the move log says it was undone, and every follow on the card stops until you move it forward.
        if let logged = store.moves.move(receiptID: receiptID, eventID: eventID) { store.moves.recordUndo(moveID: logged.id, at: at) }
        if !store.follows.isPaused(row.workID) {
            store.pauseCard(workID: row.workID, stage: from, why: "You undid COS\u{2019}s move.", at: at)
        }
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

    // MARK: - Follows and evidence (next release)

    /// Idle from the transcript, never from a job's status: untouched for `quietBeforeJev`, not generating, not waiting.
    nonisolated static func transcriptIdle(_ read: SessionRead, now: Double) -> Bool {
        guard let last = read.lastActivityAt, now - last >= quietBeforeJev, !read.runningActive,
              !["running", "waiting"].contains(read.agentState) else { return false }
        return true
    }

    /// Where a card's evidence goes this pass: the server's evidence check, the completion check standing in for it (no
    /// capability, or the check switched off or without a key), or nowhere until the cap or the breaker clears.
    enum EvidenceRoute: Equatable { case evidence, fallback, wait }
    func evidenceRoute(_ date: Date) -> EvidenceRoute {
        guard board.evidenceCheck() else { return .fallback }
        if let off = evidenceOff {
            if date < off.until { return off.fallback ? .fallback : .wait }
            evidenceOff = nil
        }
        return .evidence
    }
    /// What the server's refusal means for the next checks (contract v2): switched off or no key, the completion check
    /// stands in until tomorrow; the day's cap waits for its `retryAt` (the next UTC midnight); the breaker for its own.
    func noteEvidenceUnavailable(_ reason: String, retryAt: Double?) {
        let date = now()
        let tomorrow = Calendar.current.startOfDay(for: date).addingTimeInterval(86_400)
        // A retryAt in the past or more than two days out is not believed.
        let given = retryAt.map(Date.init(timeIntervalSince1970:)).flatMap { $0 > date && $0.timeIntervalSince(date) <= 2 * 86_400 ? $0 : nil }
        switch reason {
        case "evidence_disabled", "jev_not_configured": evidenceOff = (tomorrow, true, reason)
        case "jev_cap": evidenceOff = (given ?? Self.nextUTCMidnight(date), false, reason)
        case "jev_breaker": evidenceOff = (given ?? date.addingTimeInterval(3_600), false, reason)
        default: return
        }
        trackingLog.notice("evidence check off reason=\(reason, privacy: .public) until=\(WorkProgress.stamp(self.evidenceOff?.until.timeIntervalSince1970 ?? 0), privacy: .public)")
    }
    nonisolated static func nextUTCMidnight(_ date: Date) -> Date {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return utc.startOfDay(for: date).addingTimeInterval(86_400)
    }
    /// One decision, logged and kept on the card, so the shadow week can be read back (QA W11).
    private func decided(_ workID: String, _ decision: String) {
        trackingLog.notice("decision card=\(workID, privacy: .public) decision=\(decision, privacy: .public)")
        store.follows.setCard(workID) { $0.lastDecision = decision }
    }
    /// The same, for a state that repeats every pass (not idle, a cap, a wait): logged when it starts, not every 30 s.
    private func decidedOnce(_ workID: String, _ decision: String) {
        guard store.follows.card(workID).lastDecision != decision else { return }
        decided(workID, decision)
    }

    /// One pass over the cards that follow sessions: new follows from receipts and links, failed sends you picked up
    /// again, a card moved back outside Control, then each open card before QA is judged.
    private func followPass(start: Double, tracked: Set<String>) async {
        let follows = store.follows
        var open: [String: TaskRow] = [:]
        for task in board.tasks() where !task.checked && task.workStage != "complete" && open[task.workSourceID] == nil { open[task.workSourceID] = task }
        for row in store.receipts where open[row.workID] != nil && WorkFollowStore.followable(row, now: start, tracked: tracked.contains(row.id)) {
            if let session = WorkProgress.workingSession(row) {
                follows.add(workID: row.workID, sessionID: session, origin: .receipt, startedAt: row.createdAt, receiptID: row.id)
            }
        }
        // A link made by another Control process, or before this build.
        for (sessionID, links) in store.confirmedSessionCards {
            for link in links where open[link.workID] != nil { follows.add(workID: link.workID, sessionID: sessionID, origin: .link, startedAt: link.at) }
        }
        for (workID, task) in open where follows.isPaused(workID) { follows.resumeIfMovedForward(workID: workID, currentStage: task.workStage) }
        // A card COS moved that now sits before where COS put it was moved back outside Control (the lens, the CLI, the
        // server, or before this build): it is paused, once per move (QA blocker 3).
        for (workID, task) in open.sorted(by: { $0.key < $1.key }) where !follows.follows(for: workID).isEmpty {
            await pauseIfMovedBack(task, at: start)
        }
        var revivals: [(receipt: WorkHandoffReceipt, session: String)] = []
        for row in store.receipts where open[row.workID] != nil && WorkFollowStore.revivable(row, now: start) {
            guard let session = WorkProgress.workingSession(row), !follows.follows(for: row.workID).contains(where: { $0.sessionID == session }) else { continue }
            revivals.append((row, session))
        }
        var cards = open.values.filter { task in
            WorkProgress.advances(from: task.workStage, to: "qa")
                && (!follows.active(for: task.workSourceID).isEmpty || revivals.contains { $0.receipt.workID == task.workSourceID })
        }.sorted { $0.workSourceID < $1.workSourceID }
        // At most a few cards are checked for the first time per pass, newest follow first; the rest wait their turn.
        let fresh = cards.filter { follows.card($0.workSourceID).checkedAt == nil && follows.card($0.workSourceID).clauses == nil }
            .sorted { (follows.follows(for: $0.workSourceID).map(\.startedAt).max() ?? 0) > (follows.follows(for: $1.workSourceID).map(\.startedAt).max() ?? 0) }
        let waiting = Set(fresh.dropFirst(Self.firstChecksPerPass).map(\.workSourceID))
        if !waiting.isEmpty { trackingLog.notice("first checks deferred cards=\(waiting.count, privacy: .public) (at most \(Self.firstChecksPerPass, privacy: .public) a pass)") }
        cards = cards.filter { !waiting.contains($0.workSourceID) }
        revivals = revivals.filter { !waiting.contains($0.receipt.workID) }
        guard !cards.isEmpty else { return }
        let sessions = Set(cards.flatMap { follows.active(for: $0.workSourceID).map(\.sessionID) } + revivals.map(\.session))
        for sessionID in sessions.sorted() where passReads[sessionID] == nil && shouldRead(sessionID) {
            do {
                let read = try await store.sessionRead(sessionID: sessionID, turns: Self.turnsPerRead)
                passReads[sessionID] = read
                noteRead(sessionID, read)
            } catch {
                trackingLog.notice("follow read failed session=\(sessionID, privacy: .public)")
            }
        }
        // A failed send is followed once you wrote in its session after the failure (W1, QA W4). The receipt itself stays
        // as it is.
        for revival in revivals {
            let floor = WorkFollowStore.failedAt(revival.receipt)
            guard let read = passReads[revival.session], read.hasHistory, WorkFollowStore.activityAfter(floor, prompts: read.prompts) else { continue }
            if follows.add(workID: revival.receipt.workID, sessionID: revival.session, origin: .receipt, startedAt: floor, receiptID: revival.receipt.id) {
                trackingLog.notice("revived failed send receipt=\(revival.receipt.id, privacy: .public)")
            }
        }
        for task in cards { await evaluate(task, now: start, tracked: tracked) }
    }

    /// A card COS moved (the newest real, not undone COS move in the log) that now sits before that move's stage: you
    /// moved it back somewhere Control did not see. The board is read again first, so a stale read never pauses a card.
    private func pauseIfMovedBack(_ task: TaskRow, at: Double) async {
        let workID = task.workSourceID, follows = store.follows
        // Once per move: the pause below is logged, and a logged pause after the move is something Control saw.
        guard let latest = store.moves.latestCOSMove(workID: workID), let to = latest.line.to,
              Self.movedBack(current: task.checked ? "complete" : task.workStage, cosMovedTo: to),
              !store.moves.seenSince(workID: workID, at: latest.line.at, except: latest.id) else { return }
        guard await board.readFresh(), let identity = WorkProgress.boardTask(workID),
              let fresh = board.tasks().first(where: { $0.domain == identity.domain && $0.workIdentity == identity.identity }) else { return }
        boardReadAt = now()
        let current = fresh.checked ? "complete" : fresh.workStage
        guard Self.movedBack(current: current, cosMovedTo: to) else { return }
        follows.setCard(workID) { $0.pending = nil }
        if !follows.isPaused(workID) {
            store.pauseCard(workID: workID, stage: current, why: "You moved it back to \(WorkProgress.stageTitle(current)).", at: at)
        }
        decided(workID, "paused: moved back to \(current) outside Control")
    }
    /// The card sits before the stage COS moved it to.
    nonisolated static func movedBack(current: String, cosMovedTo: String) -> Bool {
        current != cosMovedTo && current != "complete" && WorkProgress.advances(from: current, to: cosMovedTo)
    }

    /// Whether the 0.5.247 handoff path already reads this follow (its receipt is tracked): its done line and Jev check
    /// stay there, so a card is never judged twice for one reply.
    private func handledByHandoff(_ follow: WorkFollow, tracked: Set<String>) -> Bool {
        follow.origin == .receipt && follow.receiptID.map(tracked.contains) == true
    }

    /// Whether this done report was already acted on: by this follow (its digest), or by any COS move of the card to QA
    /// made after the reply (the move log, or a 0.5.247 handoff's own Progress, which predates the log).
    private func doneActedOn(_ workID: String, digest: String, replyAt: Double) -> Bool {
        if store.follows.card(workID).actedDone?.contains(digest) == true { return true }
        if store.moves.cosMoved(workID: workID, to: "qa", since: replyAt) { return true }
        return store.receipts.contains { row in
            row.workID == workID && (row.progress?.events.contains { $0.kind == .moved && $0.toStage == "qa" && $0.at >= replyAt } ?? false)
        }
    }

    private func evaluate(_ task: TaskRow, now at: Double, tracked: Set<String>) async {
        let workID = task.workSourceID, follows = store.follows
        guard !follows.isPaused(workID) else { return }
        if follows.card(workID).pending != nil { await attemptFollowMove(workID); return }
        let active = follows.active(for: workID)
        guard !active.isEmpty else { return }
        // The session's own done line, from any followed session: it moves the card as it always has (never shadowed,
        // never vetoed), and once per report. Only lines tagged with this card's id count, so a thread following two
        // cards moves neither on an untagged "done".
        let tag = WorkProgress.tag(forWorkID: workID)
        for follow in active where !handledByHandoff(follow, tracked: tracked) {
            guard let read = passReads[follow.sessionID], read.hasHistory else { continue }
            let replies = read.replies.filter { ($0.at ?? 0) >= follow.startedAt }
            guard let found = WorkProgress.latestReport(tag: tag, replies: replies), found.report.kind == .done else { continue }
            let digest = found.reply.digest
            if doneActedOn(workID, digest: digest, replyAt: found.reply.at ?? follow.startedAt) {
                if follows.card(workID).actedDone?.contains(digest) != true {
                    follows.setCard(workID) { $0.actedDone = Array((($0.actedDone ?? []) + [digest]).suffix(Self.actedDoneKept)) }
                }
                decidedOnce(workID, "hold: done line already acted on")
                continue
            }
            follows.setCard(workID) { $0.actedDone = Array((($0.actedDone ?? []) + [digest]).suffix(Self.actedDoneKept)) }
            decided(workID, "move: the done line")
            await moveOnEvidence(task, why: "the session reported done: \u{201C}\(WorkProgress.clip(found.report.evidence, 140))\u{201D}",
                                 clauses: [], live: true, at: at)
            return
        }
        if let tried = evidenceTriedAt[workID], now().timeIntervalSince(tried) < Self.jevRetryAfter { return }
        switch evidenceRoute(now()) {
        case .evidence: await checkEvidence(task, active: active, at: at)
        case .wait: decidedOnce(workID, "hold: " + (evidenceOff?.reason ?? "evidence check off"))
        case .fallback:
            // The handoff path asks Jev about its own receipts as it did in 0.5.261; the fallback reads linked and
            // followed sessions, and a failed send's session once it came back to life.
            let failed = Set(store.receipts.filter { $0.status == "failed" }.map(\.id))
            await completionFallback(task, active: active.filter { $0.origin != .receipt || $0.receiptID.map(failed.contains) == true }, at: at)
        }
    }

    /// The evidence check (contract 2026-10-07, v2), when every followed session that could be read is idle and something
    /// changed since the last check: a new reply, an edit to the card, or four quiet hours.
    private func checkEvidence(_ task: TaskRow, active: [WorkFollow], at: Double) async {
        let workID = task.workSourceID, follows = store.follows
        guard let identity = WorkProgress.boardTask(workID) else { return }
        let reads = active.compactMap { passReads[$0.sessionID] }
        guard !reads.isEmpty, reads.allSatisfy({ Self.transcriptIdle($0, now: at) }) else {
            decidedOnce(workID, reads.isEmpty ? "wait: no session read" : "wait: not idle")
            return
        }
        let card = follows.card(workID)
        let activity = reads.compactMap(\.lastActivityAt).max()
        let due = card.checkedAt == nil || card.checkedRevision != task.workRevision
            || (activity ?? 0) > (card.checkedActivity ?? 0) || at - (card.checkedAt ?? 0) >= Self.evidenceRecheck
        guard due else { return }
        guard card.checks.filter({ at - $0 < 86_400 }).count < Self.maxChecksPerDay else {
            decidedOnce(workID, "hold: 8 checks today")
            return
        }
        if let problem = WorkFinishLine.problem(task.doneWhen) {
            follows.setCard(workID) { $0.note = problem }
            return
        }
        let clauses = WorkFinishLine.clauses(task.doneWhen)
        let since = Self.cardCreated(task) ?? active.map(\.startedAt).min() ?? at
        let body: [String: Any] = [
            "domain": identity.domain, "id": identity.identity,
            "follows": active.map { follow -> [String: Any] in
                ["provider": follow.provider, "sessionId": WorkHandoffStore.nativeID(follow.sessionID) ?? follow.sessionID,
                 "cursor": follow.cursor.flatMap { (1...WorkFinishLine.maxCursorLength).contains($0.utf16.count) ? $0 : nil }.map { $0 as Any } ?? NSNull()]
            },
            "clauses": clauses, "since": WorkProgress.stamp(since)]
        let judged = task.workRevision
        trackingLog.notice("evidence check card=\(workID, privacy: .public) clauses=\(clauses.count, privacy: .public)")
        let answer = await store.evidenceCheck(body, sent: clauses.count)
        func keep(_ cursors: [WorkEvidenceResult.Cursor]) {
            for cursor in cursors { follows.setCursor(workID: workID, sessionID: cursor.provider + ":" + cursor.sessionId, cursor: cursor.cursor) }
        }
        guard let result = answer.result else {
            // No verdict. A `no_evidence` answer read the sessions: its cursors are kept. The card is not asked again
            // until something changes (QA W2: a failure retried every 10 minutes, re-reading up to 24 MB each time).
            keep(answer.cursors)
            let reason = answer.reason ?? "unavailable"
            noteEvidenceUnavailable(reason, retryAt: answer.retryAt)
            evidenceTriedAt[workID] = now()
            follows.setCard(workID) { card in
                card.checkedAt = at; card.checkedRevision = judged; card.checkedActivity = activity
                card.lastDecision = "no answer: " + reason
            }
            trackingLog.notice("decision card=\(workID, privacy: .public) decision=no answer reason=\(reason, privacy: .public)")
            return
        }
        evidenceTriedAt[workID] = nil
        // A v2 server's truncated read returns a cursor inside the gap: kept, so the next call walks on. A v1 cursor from a
        // truncated read pointed past the gap, and is not kept.
        if !result.truncated || result.v2 { keep(result.cursors) }
        let previousCheckedAt = card.checkedAt
        if result.truncated {
            // Partial: the kept verdicts stay, nothing moves, and the card is checked again soon (in 10 minutes). It does
            // not count against the 8 a day.
            evidenceTriedAt[workID] = now()
            follows.setCard(workID) { card in
                card.checkedAt = at; card.checkedRevision = judged; card.checkedActivity = nil; card.note = nil
                card.lastDecision = "hold: the read stopped short"
            }
            trackingLog.notice("decision card=\(workID, privacy: .public) decision=hold (truncated)")
            return
        }
        let merged = WorkEvidencePolicy.merge(previous: card.clauses, previousBasis: card.basis, fresh: result.clauses, basis: result.basis, at: at)
        let decision = WorkEvidencePolicy.decision(basis: result.basis, states: merged, expected: clauses.count)
        // A cached or skipped answer repeats verdicts judged before you last moved the card yourself: never a move.
        let stale = (result.cached || result.skipped != nil)
            && (store.moves.lastMoveByYou(workID: workID).map { $0 > (previousCheckedAt ?? 0) } ?? false)
        let line: String
        switch decision {
        case .move: line = stale ? "hold: cached verdict predates your move" : (shadow() ? "would move" : "move")
        case .partial(let met, let of): line = "partial: \(met) of \(of) met"
        case .hold: line = "hold"
        }
        follows.setCard(workID) { card in
            card.checkedAt = at; card.checkedRevision = judged; card.checkedActivity = activity; card.note = nil
            card.checks = card.checks.filter { at - $0 < 86_400 }
            if !result.cached && result.skipped == nil { card.checks.append(at) }
            card.basis = result.basis
            card.clauses = merged
            card.lastDecision = line + (result.cached ? " (cached)" : "")
        }
        trackingLog.notice("decision card=\(workID, privacy: .public) decision=\(line, privacy: .public) cached=\(result.cached, privacy: .public)")
        guard decision == .move, !stale else { return }
        let moveClauses = merged.map { state -> WorkMoveClause in
            var clause = state.evidence ?? WorkMoveClause(text: state.text, verdict: state.verdict)
            clause.text = state.text; clause.verdict = state.verdict; clause.kind = state.kind; clause.deterministic = state.deterministic
            return clause
        }
        await moveOnEvidence(task, why: result.why, clauses: moveClauses, live: false, at: at)
    }

    /// No evidence check on this server (or it is switched off): the 0.5.247 completion check reads the newest reply of
    /// a linked or followed session (a handoff's own sessions are read by the handoff path). At most twice per follow,
    /// once per reply.
    private func completionFallback(_ task: TaskRow, active: [WorkFollow], at: Double) async {
        guard let identity = WorkProgress.boardTask(task.workSourceID) else { return }
        for follow in active {
            guard let read = passReads[follow.sessionID], read.hasHistory, Self.transcriptIdle(read, now: at),
                  let newest = read.replies.last(where: { ($0.at ?? 0) >= follow.startedAt }) else { continue }
            let judged = follow.judged ?? []
            guard !judged.contains(newest.digest), judged.count < WorkProgress.maxJevAsks else { continue }
            let answer = await store.completionCheck(domain: identity.domain, identity: identity.identity, sessionID: follow.sessionID, after: follow.startedAt)
            guard let verdict = answer.verdict else {
                if Self.finalJevReasons.contains(answer.reason ?? "") {
                    store.follows.markJudged(workID: task.workSourceID, sessionID: follow.sessionID, digest: newest.digest)
                } else { evidenceTriedAt[task.workSourceID] = now() }
                trackingLog.notice("decision card=\(task.workSourceID, privacy: .public) decision=no answer (completion check) reason=\(answer.reason ?? "", privacy: .public)")
                return
            }
            store.follows.markJudged(workID: task.workSourceID, sessionID: follow.sessionID, digest: newest.digest)
            if verdict.movesCard {
                decided(task.workSourceID, shadow() ? "would move (completion check)" : "move (completion check)")
                await moveOnEvidence(task, why: verdict.text, clauses: [], live: false, at: at)
                return
            }
            trackingLog.notice("decision card=\(task.workSourceID, privacy: .public) decision=hold (completion check: not done)")
        }
    }

    /// A move the evidence decided on. In shadow mode an evidence-path move (`live` false) is logged once as a would-move
    /// and nothing moves; the session's done line (`live`) always moves.
    private func moveOnEvidence(_ task: TaskRow, why: String, clauses: [WorkMoveClause], live: Bool, at: Double) async {
        let workID = task.workSourceID, follows = store.follows
        if !live && shadow() {
            let key = WorkProgress.digest(WorkSource.taskSnapshot(task).revision + "|qa|" + why + "|"
                + clauses.map { $0.text + "=" + $0.verdict + "@" + ($0.ref ?? "") }.joined(separator: ";"))
            guard follows.card(workID).shadowKey != key else { return }
            follows.setCard(workID) { $0.shadowKey = key }
            store.recordStageMove(workID: workID, title: task.text.isEmpty ? task.title : task.text, from: task.workStage, to: "qa",
                                  move: WorkStageMove(by: .cos, why: why, clauses: clauses, judgedRevision: task.workRevision), shadow: true, at: at)
            trackingLog.notice("would move card=\(workID, privacy: .public) (shadow)")
            return
        }
        follows.setCard(workID) { $0.pending = WorkPendingMove(to: "qa", judgedRevision: task.workRevision, why: why, clauses: clauses) }
        await attemptFollowMove(workID)
    }

    /// Writes a card's pending move when every rule allows it. A card whose revision changed since it was judged is not
    /// moved: the move is dropped and the card checked again (validation B3).
    private func attemptFollowMove(_ workID: String) async {
        let follows = store.follows
        guard holdsLease, let pending = follows.card(workID).pending, let identity = WorkProgress.boardTask(workID) else { return }
        if boardReadAt.map({ now().timeIntervalSince($0) > Self.boardFreshness }) ?? true {
            await board.reload(); boardReadAt = now()
        }
        func failed(_ reason: String) {
            trackingLog.notice("follow move failed card=\(workID, privacy: .public) reason=\(reason, privacy: .public)")
            follows.setCard(workID) { card in
                guard var next = card.pending else { return }
                next.attempts += 1
                card.pending = next.attempts >= WorkProgress.maxMoveAttempts ? nil : next
            }
        }
        guard let task = board.tasks().first(where: { $0.domain == identity.domain && $0.workIdentity == identity.identity }) else {
            failed("the card is not on the board right now"); return
        }
        guard !follows.isPaused(workID) else { follows.setCard(workID) { $0.pending = nil }; return }
        guard task.workRevision == pending.judgedRevision else {
            trackingLog.notice("follow move dropped card=\(workID, privacy: .public): the card changed since it was judged")
            follows.setCard(workID) { $0.pending = nil; $0.checkedAt = nil; $0.checkedRevision = nil }
            return
        }
        let current = task.checked ? "complete" : task.workStage
        guard WorkProgress.advances(from: current, to: pending.to) else { follows.setCard(workID) { $0.pending = nil }; return }
        guard board.writable(), task.workMetadataError == nil else { failed(task.workMetadataError ?? "the board is read-only right now"); return }
        let move = WorkStageMove(by: .cos, why: pending.why, clauses: pending.clauses, judgedRevision: pending.judgedRevision)
        do {
            try await board.move(task, pending.to, move)
        } catch where Self.savedButRefreshFailed(error) {
        } catch {
            failed(error.localizedDescription); return
        }
        boardReadAt = nil
        follows.setCard(workID) { $0.pending = nil }
        trackingLog.notice("follow moved card=\(workID, privacy: .public) to=\(pending.to, privacy: .public)")
    }

    /// The card's creation day (the board's `createdAt`, YYYY-MM-DD) as the start of the evidence look-back:
    /// deterministic sources look back to it (Skeptic W5).
    nonisolated static func cardCreated(_ task: TaskRow) -> Double? {
        let raw = String(task.createdAt.prefix(10))
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        return format.date(from: raw)?.timeIntervalSince1970
    }

    /// Undo from Moved for you or the card's history: moves the card back and stops every follow on it. A move the
    /// handoff path made goes through `undo(receiptID:eventID:)`, which also pauses that handoff.
    func undo(moveID: String) async -> String? {
        guard let entry = store.moves.entries.first(where: { $0.id == moveID }), entry.byCOS, !entry.shadow, entry.undoneAt == nil,
              let from = entry.line.from, let to = entry.line.to, let identity = WorkProgress.boardTask(entry.line.workID) else {
            return "That move is no longer on record."
        }
        if let receiptID = entry.line.receiptID, let eventID = entry.line.eventID, store.receipts.contains(where: { $0.id == receiptID }) {
            return await undo(receiptID: receiptID, eventID: eventID)
        }
        guard !undoing.contains(moveID) else { return nil }
        undoing.insert(moveID); defer { undoing.remove(moveID) }
        await board.reload(); boardReadAt = now()
        guard let task = board.tasks().first(where: { $0.domain == identity.domain && $0.workIdentity == identity.identity }),
              (task.checked ? "complete" : task.workStage) == to else { return "The card has moved since. Nothing was changed." }
        do { try await board.move(task, from, WorkStageMove(by: .you, why: "Undo of COS\u{2019}s move")) } catch where Self.savedButRefreshFailed(error) {
        } catch { return error.localizedDescription }
        boardReadAt = nil
        let at = now().timeIntervalSince1970
        store.moves.recordUndo(moveID: moveID, at: at)
        if !store.follows.isPaused(entry.line.workID) {
            store.pauseCard(workID: entry.line.workID, stage: from, why: "You undid COS\u{2019}s move to \(WorkProgress.stageTitle(to)).", at: at)
        }
        trackingLog.notice("undo move=\(moveID, privacy: .public)")
        return nil
    }

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
    /// Failure receipts often have no progress block. They must not use post(), which requires one.
    private func postFailures() {
        let date = now(), calendar = Calendar.current
        let hour = calendar.component(.hour, from: date), weekday = calendar.component(.weekday, from: date)
        guard hour >= 7 && hour < 18 && weekday != 1 && weekday != 7 else { return }
        let url = store.notificationLedgerURL
        var ledger: [String: WorkFailureStamp] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  let read = try? JSONDecoder().decode([String: WorkFailureStamp].self, from: data) else {
                trackingLog.error("Failure notification ledger unreadable; preserving it")
                return
            }
            ledger = read
        }
        for row in store.receipts.sorted(by: { $0.createdAt > $1.createdAt }) where ["failed", "refused"].contains(row.status)
            && date.timeIntervalSince1970 - row.createdAt < 14 * 86400 {
            if let prior = ledger[row.workID], prior.receiptID == row.id || row.createdAt <= prior.receiptAt || date.timeIntervalSince1970 - prior.notifiedAt < 1800 { continue }
            ledger[row.workID] = WorkFailureStamp(receiptID: row.id, receiptAt: row.createdAt, notifiedAt: date.timeIntervalSince1970)
            do {
                let data = try JSONEncoder().encode(ledger)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { trackingLog.error("Failure notification save failed"); return }
            notify(WorkProgressNotice(key: "failed", receiptID: row.id, workID: row.workID, title: "Work needs a look", body: row.workTitle + ": " + String(row.detail.prefix(240))))
        }
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

private struct WorkFailureStamp: Codable {
    let receiptID: String
    let receiptAt: Double
    let notifiedAt: Double
}

/// Next release: an exclusive flock held for as long as this Control evaluates (validation W3). A stable app and a review
/// candidate share App Support; the second one to start reads but never moves a card. Released when the tracker goes.
final class WorkTrackerLease: @unchecked Sendable {
    let url: URL
    private var fd: Int32 = -1
    init(url: URL) { self.url = url }
    var held: Bool { fd >= 0 }
    /// Takes the lease if it is free (never waits). True while this process holds it.
    func acquire() -> Bool {
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let handle = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard handle >= 0 else { return false }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { close(handle); return false }
        fd = handle
        return true
    }
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }
    deinit { release() }
}
