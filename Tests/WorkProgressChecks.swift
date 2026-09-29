import Darwin
import Foundation

// 0.5.247 Work tracking: the status-line protocol, the delivery and stage rules, the board projections, and the
// tracker end to end against a synthetic transport and board that answer in the real helper's shapes (a running turn
// is `{state: pending, httpStatus: 404}`, as the server's ledger holds only finished turns). No agent is contacted and
// no board is written.

private actor TrackingTransport {
    var calls: [[String]] = []
    var sentPrompts: [String] = []
    /// "pending" (the real shape of a turn still running) or "completed".
    var turnState = "pending"
    var replies: [JSONValue] = []
    var prompts: [JSONValue] = []
    var runningActive = false
    var agentState = "idle"
    var lastActivityAt: String = ""
    var readState = "turns"
    var completion: [String: JSONValue] = ["provider": .string("none"), "reason": .string("server_too_old")]
    var completionBodies: [[String: String]] = []
    var jobResult: String?
    var jobIdentity = ""
    /// A Claude New session whose session the server names only from the `sessionAfterReads`th `work-job` read on
    /// (0.5.247); the `work-new` answer itself never names it, as on 2026-09-29.
    var jobClaudeSession: String?
    var sessionAfterReads = 0
    var workJobReads = 0
    func setClaudeJob(session: String, afterReads: Int) { jobClaudeSession = session; sessionAfterReads = afterReads }
    func bodies() -> [[String: String]] { completionBodies }
    func setTurn(_ state: String) { turnState = state }
    func setRead(replies rows: [(String, String?)], prompts heads: [(String, String?)] = [], running: Bool = false,
                 agent: String = "idle", lastActivity: String = "", state: String = "turns") {
        func encode(_ list: [(String, String?)]) -> [JSONValue] {
            list.map { text, at in
                var row: [String: JSONValue] = ["text": .string(text)]
                if let at { row["at"] = .string(at) }
                return .object(row)
            }
        }
        replies = encode(rows); prompts = encode(heads); runningActive = running; agentState = agent
        lastActivityAt = lastActivity; readState = state
    }
    func setCompletion(_ details: [String: JSONValue]) { completion = details }
    func setJobResult(_ text: String?) { jobResult = text }
    func count(_ verb: String) -> Int { calls.filter { $0.first == verb }.count }
    func sent() -> [String] { sentPrompts }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        calls.append(args)
        var details: [String: JSONValue] = [:]
        switch args.first {
        case "session-chat-attachability": details = ["attachable": .bool(true)]
        case "session-chat-attach":
            details = ["state": .string("attached"), "bindingId": .string("binding-fixture"), "epoch": .number(1), "boundTo": .string("fixture")]
        case "session-chat-send":
            sentPrompts.append(String(decoding: data ?? Data(), as: UTF8.self))
            details = ["state": .string("queued")]
        case "session-chat-turn":
            details = turnState == "completed" ? ["state": .string("completed"), "httpStatus": .number(200)]
                                               : ["state": .string("pending"), "httpStatus": .number(404)]
        case "session-recent-replies":
            details = ["state": .string(readState), "replies": .array(replies), "prompts": .array(prompts),
                       "runningActive": .bool(runningActive), "agentState": .string(agentState), "lastActivityAt": .string(lastActivityAt)]
        case "work-completion-check":
            completionBodies.append((try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: String] ?? [:])
            details = completion
        case "work-new":
            let payload = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
            jobIdentity = payload["clientJobId"] as? String ?? ""
            details = job()
        case "work-job": workJobReads += 1; details = job()
        default: throw HelperClientError.commandFailed("Unexpected fixture command: \(args)")
        }
        return HelperResponse(ok: true, message: "Synthetic transport", details: details)
    }
    private func job() -> [String: JSONValue] {
        var job: [String: JSONValue] = ["clientJobId": .string(jobIdentity), "generation": .number(1), "jobId": .string("job-fixture"),
                                         "status": .string(jobResult == nil ? "running" : "completed"),
                                         "provider": .string(jobClaudeSession == nil ? "cursor" : "claude")]
        if let jobResult { job["response"] = .string(jobResult) }
        if let session = jobClaudeSession, workJobReads > 0, workJobReads >= sessionAfterReads {
            job["providerOwnershipConfirmedAt"] = .string("2026-09-29T18:46:57.717Z"); job["cliSessionId"] = .string(session)
        }
        return ["job": .object(job)]
    }
}

@MainActor private final class FakeBoard {
    var rows: [String: String] = [:]     // identity -> stage
    var writable = true
    var moves: [(String, String)] = []
    var failNext: String?
    var metadataError: String?
    /// Runs inside a move (to hold the journal while the tracker records it).
    var duringMove: (() -> Void)?
    var savedButRefreshFailsNext = false
    func task(_ identity: String) -> TaskRow {
        var row: [String: JSONValue] = ["id": .string(identity), "domain": .string("Quilt"), "title": .string("Homepage CTA"),
                                        "text": .string("Draft the homepage call to action " + identity), "doneWhen": .string(""),
                                        "workStage": .string(rows[identity] ?? "planned"), "workIdentity": .string(identity),
                                        "workRevision": .string(String(repeating: "a", count: 64))]
        if rows[identity] == "complete" { row["checked"] = .bool(true) }
        if let metadataError { row["workMetadataError"] = .string(metadataError) }
        return TaskRow(.object(row))!
    }
    var board: WorkProgressTracker.Board {
        .init(tasks: { self.rows.keys.sorted().map(self.task) },
              writable: { self.writable },
              reload: {},
              move: { task, stage in
                  if let failure = self.failNext { self.failNext = nil; throw HelperClientError.commandFailed(failure) }
                  self.moves.append((task.workIdentity, stage)); self.rows[task.workIdentity] = stage
                  self.duringMove?()
                  if self.savedButRefreshFailsNext {
                      self.savedButRefreshFailsNext = false
                      throw HelperClientError.commandFailed("Change saved, but refreshing Work failed: timeout")
                  }
              })
    }
}

@MainActor private final class Clock { var offset: Double = 0; func now() -> Date { Date().addingTimeInterval(offset) } }
@MainActor private final class NoticeBox { var items: [WorkProgressNotice] = [] }

private func stamp(_ seconds: Double) -> String { WorkProgress.stamp(seconds) }

@main struct WorkProgressChecks {
    @MainActor static func main() async throws {
        pureChecks()
        projectionChecks()
        try await trackerChecks()
        print("PASS: Work tracking (status line, delivery, stages, projections, tracker: pending turns, arrival, reports, several tasks, pause, moved back, retries, busy journal, Jev gating, baseline, job result, superseded, back-off, New session link, Work sessions not jobs)")
    }

    /// `precondition` takes an autoclosure, which cannot await.
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        if !condition { fatalError("check failed at line \(line): \(message())") }
    }
    private static func require<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { throw HelperClientError.commandFailed("required value missing at line \(line)") }
        return value
    }

    // MARK: - Pure rules

    @MainActor static func pureChecks() {
        precondition(WorkProgress.tag(forWorkID: "task:Quilt:0123456789ab") == "0123456789ab")
        let review = WorkProgress.tag(forWorkID: "review:wr_" + String(repeating: "c", count: 32))
        precondition(review.count == 12 && review.allSatisfy(\.isHexDigit))
        precondition(WorkProgress.tag(forWorkID: "task:Quilt:NOTHEX") != "NOTHEX")

        // The instruction and the parser agree: its own template never counts, and filled in as asked it parses.
        let instruction = WorkProgress.instruction(tag: "0123456789ab")
        precondition(instruction.hasPrefix("\n\n") && instruction.contains("first line of your reply") && instruction.contains("not in a code block"))
        precondition(WorkProgress.reports(in: instruction).isEmpty, "The template line must never count as a report")
        let filled = instruction.replacingOccurrences(of: "<done, needs input or blocked>", with: "done")
            .replacingOccurrences(of: "<one sentence of evidence>", with: "Shipped the CTA and checked it on a phone.")
        precondition(WorkProgress.reports(in: filled) == [.init(tag: "0123456789ab", kind: .done, evidence: "Shipped the CTA and checked it on a phone.")],
                     "The template, filled in as instructed, must parse")
        precondition(WorkProgress.instruction(tag: "0123456789ab").utf16.count <= WorkProgress.instructionReserve)

        func one(_ line: String) -> WorkProgress.Report? { WorkProgress.reports(in: line).first }
        precondition(one("COS-WORK 0123456789ab: done: Updated the hero CTA and checked it at 390pt.")?.evidence == "Updated the hero CTA and checked it at 390pt.")
        precondition(one("**COS-WORK 0123456789AB: done - shipped the copy**")?.evidence == "shipped the copy", "Bold around the line")
        precondition(one("**COS-WORK 0123456789ab:** done: shipped the copy")?.kind == .done, "A bold label before the state")
        precondition(one("`COS-WORK 0123456789ab: needs input: which price?`")?.kind == .needsInput, "Inline code marks")
        precondition(one("- COS-WORK 0123456789ab: needs input \u{2014} Which price should the FAQ quote?")?.kind == .needsInput)
        precondition(one("COS-WORK 0123456789ab: blocked: the staging login expired")?.kind == .blocked)
        precondition(one("COS-WORK 0123456789ab: done") == nil, "Done needs evidence")
        precondition(one("COS-WORK 0123456789ab: done: ok") == nil, "Evidence of under three characters does not count")
        precondition(one("COS-WORK 0123456789ab: done: <one sentence of evidence>") == nil, "An unfilled placeholder does not count")
        precondition(one("COS-WORK 0123456789ab: done | needs input | blocked - evidence") == nil)
        precondition(one("COS-WORK 0123456789a: done: short tag") == nil)
        precondition(one("Earlier I wrote COS-WORK 0123456789ab: done: inside a sentence") == nil, "Only a line that starts with it")
        precondition(one("COS-WORK 0123456789ab: working: still going") == nil)
        let many = WorkProgress.reports(in: "Summary\nCOS-WORK aaaaaaaaaaaa: done: first task shipped\n\nCOS-WORK bbbbbbbbbbbb: blocked: waiting on a login\n")
        precondition(many.map(\.tag) == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"] && many.map(\.kind) == [.done, .blocked])
        precondition((one("COS-WORK 0123456789ab: done: " + String(repeating: "x", count: 900))?.evidence.count ?? 0) <= WorkProgress.maxText)

        // Which replies count: timed ones from the floor on; untimed ones not in the baseline.
        let old = WorkProgress.Reply(text: "old", at: 100), new = WorkProgress.Reply(text: "new", at: 220)
        let untimedOld = WorkProgress.Reply(text: "untimed old", at: nil), untimedNew = WorkProgress.Reply(text: "untimed new", at: nil)
        precondition(WorkProgress.eligible([old, new, untimedOld, untimedNew], floor: 200, baseline: [untimedOld.digest]) == [new, untimedNew])
        let replies = [WorkProgress.Reply(text: "COS-WORK 0123456789ab: needs input: which price?", at: 210),
                       WorkProgress.Reply(text: "COS-WORK 0123456789ab: done: priced and shipped", at: 220)]
        precondition(WorkProgress.latestReport(tag: "0123456789ab", replies: replies)?.report.evidence == "priced and shipped")
        precondition(WorkProgress.latestReport(tag: "bbbbbbbbbbbb", replies: replies) == nil, "Another task's id never counts")

        // The prompt arriving: its opening words, ignoring markdown and spacing, from `since` (less 5 s) on.
        let prompt = "Prepare the next reviewable result for: **Homepage CTA**\n\nSource context..."
        let heads = [WorkProgress.Reply(text: "Prepare the next reviewable result for: Homepage CTA  Source context", at: 1_000),
                     WorkProgress.Reply(text: "Prepare the next reviewable result for: Homepage CTA", at: 500)]
        precondition(WorkProgress.promptArrival(prompt: prompt, messages: heads, since: 998) == 1_000)
        precondition(WorkProgress.promptArrival(prompt: prompt, messages: heads, since: 1_010) == nil, "Earlier copies never count")
        precondition(WorkProgress.promptArrival(prompt: "hi", messages: [.init(text: "hi", at: 1_000)], since: 0) == nil, "Too short to recognise")

        // Delivery, the working session, the tracking window.
        func receipt(_ status: String, channel: String?, session: String? = "claude:s") -> WorkHandoffReceipt {
            var row = WorkHandoffReceipt(id: UUID().uuidString, workID: "task:Quilt:0123456789ab", workTitle: "T", sourceRevision: "1",
                mode: .continueSession, provider: "claude", modelID: "existing-session", sessionID: session, sessionTitle: "S",
                status: status, detail: "", prompt: "p", createdAt: Date().timeIntervalSince1970)
            row.channel = channel; row.progress = WorkProgress(tag: "0123456789ab")
            return row
        }
        precondition(!WorkProgress.deliveryConfirmed(receipt("running", channel: "turn")))
        precondition(WorkProgress.deliveryConfirmed(receipt("delivered", channel: "turn")))
        precondition(WorkProgress.deliveryConfirmed(receipt("delivered", channel: "queue")) && !WorkProgress.deliveryConfirmed(receipt("queued", channel: "queue")))
        precondition(!WorkProgress.deliveryConfirmed(receipt("running", channel: "job", session: nil)))
        precondition(WorkProgress.deliveryConfirmed(receipt("running", channel: "job")))
        var cleared = receipt("reviewed", channel: "turn"); cleared.acknowledgedAt = 1
        precondition(!WorkProgress.deliveryConfirmed(cleared))
        var pendingFork = receipt("running", channel: "fork"); pendingFork.mode = .fork; pendingFork.sourceSessionID = "claude:s"
        precondition(WorkProgress.workingSession(pendingFork) == nil, "A fork's parent is not where its work happens")
        pendingFork.sessionID = "claude:child"
        precondition(WorkProgress.workingSession(pendingFork) == "claude:child")
        let now = Date().timeIntervalSince1970
        var edge = receipt("delivered", channel: "turn"); edge.createdAt = now - WorkProgress.trackedDays * 86_400 + 60
        precondition(WorkProgress.tracked(edge, now: now))
        edge.createdAt = now - WorkProgress.trackedDays * 86_400 - 60
        precondition(!WorkProgress.tracked(edge, now: now), "The window ends at trackedDays")
        var legacy = receipt("delivered", channel: "turn"); legacy.progress = nil
        precondition(!WorkProgress.tracked(legacy, now: now))
        var finished = receipt("delivered", channel: "turn"); finished.progress?.reported = .done
        precondition(!WorkProgress.tracked(finished, now: now))
        for status in ["refused", "failed", "canceled", "unknown"] { precondition(!WorkProgress.tracked(receipt(status, channel: "turn"), now: now)) }

        // Stages.
        precondition(WorkProgress.advances(from: "mentioned", to: "draft") && WorkProgress.advances(from: "built", to: "qa"))
        precondition(!WorkProgress.advances(from: "built", to: "draft") && !WorkProgress.advances(from: "qa", to: "qa"))
        precondition(!WorkProgress.advances(from: "complete", to: "qa") && !WorkProgress.advances(from: "qa", to: "complete"))
        precondition(!WorkProgress.advances(from: "bogus", to: "qa"))
        precondition(WorkProgress.target(for: .received) == "draft" && WorkProgress.target(for: .done) == "qa" && WorkProgress.target(for: .needsInput) == nil)
        var moved = WorkProgress(tag: "t")
        moved.record(.moved, "r", at: 1, from: "planned", to: "draft", id: "m1")
        precondition(WorkProgress.movedBackByYou(moved, currentStage: "planned") && !WorkProgress.movedBackByYou(moved, currentStage: "draft"))
        precondition(!WorkProgress.movedBackByYou(moved, currentStage: "qa"), "Moving it further on is not moving it back")
        moved.events[0].undoneAt = 2
        precondition(!WorkProgress.movedBackByYou(moved, currentStage: "planned"), "An undone move does not count")
        let move = WorkProgressEvent(id: "m", at: 1, kind: .moved, text: "r", fromStage: "planned", toStage: "draft")
        precondition(WorkProgress.canUndo(move, currentStage: "draft") && !WorkProgress.canUndo(move, currentStage: "qa"))

        // Jev's verdict, per basis.
        func verdict(_ v: String, _ p: Double, basis: String? = nil, provider: String = "jev") -> WorkCompletionVerdict? {
            var details: [String: JSONValue] = ["provider": .string(provider), "verdict": .string(v), "confidence": .number(p)]
            if let basis { details["basis"] = .string(basis) }
            return WorkCompletionVerdict(details: details)
        }
        precondition(verdict("done", WorkProgress.jevDoneAt, basis: "done_when")?.movesCard == true)
        precondition(verdict("done", WorkProgress.jevDoneAt - 0.001, basis: "done_when")?.movesCard == false)
        precondition(verdict("done", WorkProgress.jevTaskDoneAt, basis: "task")?.movesCard == true)
        precondition(verdict("done", WorkProgress.jevTaskDoneAt - 0.001, basis: "task")?.movesCard == false)
        precondition(verdict("done", 0.82)?.basis == "task", "No basis reads as the stricter task basis")
        precondition(verdict("not_done", 0.99, basis: "done_when")?.movesCard == false && verdict("unclear", 0.99)?.movesCard == false)
        precondition(verdict("done", 0.9, provider: "none") == nil && verdict("done", 1.2) == nil && verdict("maybe", 0.9) == nil)
        precondition(verdict("done", 0.9)?.text.contains("no Done when") == true)

        // A newer Control's event kind reads as a note, so the journal stays readable.
        let decoded = try? JSONDecoder().decode(WorkProgressEvent.self, from: Data(#"{"id":"x","at":1,"kind":"rewound","text":"t"}"#.utf8))
        precondition(decoded?.kind == .note)

        // Bounds.
        var progress = WorkProgress(tag: "t")
        progress.record(.sent, "Sent", at: 0)
        for i in 1...40 { progress.record(.note, "n\(i)", at: Double(i)) }
        precondition(progress.events.count == WorkProgress.maxEvents && progress.events.first?.kind == .sent && progress.events.last?.text == "n40")
        progress.record(.note, "again", at: 50, id: "fixed"); progress.record(.note, "again", at: 51, id: "fixed")
        precondition(progress.events.filter { $0.id == "fixed" }.count == 1, "A replayed record lands once")
        for i in 0..<60 { progress.markSeen("d\(i)"); progress.markNotified("k\(i)") }
        precondition(progress.seenReplies.count == WorkProgress.maxSeen && progress.notified.count == WorkProgress.maxNotified)

        // Idle, for Jev.
        func read(last: Double?, running: Bool = false, agent: String = "idle") -> WorkProgressTracker.SessionRead {
            .init(replies: [], prompts: [], runningActive: running, agentState: agent, lastActivityAt: last, hasHistory: true)
        }
        let quietAt = now - WorkProgressTracker.quietBeforeJev - 1, busyAt = now - WorkProgressTracker.quietBeforeJev + 5
        let done = receipt("delivered", channel: "turn")
        precondition(WorkProgressTracker.sessionIdle(row: done, read: read(last: quietAt), now: now))
        precondition(!WorkProgressTracker.sessionIdle(row: done, read: read(last: busyAt), now: now), "Recently written is not idle")
        precondition(!WorkProgressTracker.sessionIdle(row: done, read: read(last: nil), now: now), "No activity time, no Jev")
        precondition(!WorkProgressTracker.sessionIdle(row: done, read: read(last: quietAt, running: true), now: now))
        precondition(!WorkProgressTracker.sessionIdle(row: done, read: read(last: quietAt, agent: "running"), now: now))
        precondition(!WorkProgressTracker.sessionIdle(row: done, read: read(last: quietAt, agent: "waiting"), now: now))
        precondition(!WorkProgressTracker.sessionIdle(row: receipt("running", channel: "turn"), read: read(last: quietAt), now: now),
                     "A Continue whose turn has not finished is never judged")
        precondition(!WorkProgressTracker.sessionIdle(row: receipt("running", channel: "job"), read: read(last: quietAt), now: now))
        precondition(WorkProgressTracker.savedButRefreshFailed(HelperClientError.commandFailed("Change saved, but refreshing Work failed: x")))
        precondition(!WorkProgressTracker.savedButRefreshFailed(HelperClientError.commandFailed("The task changed")))
        var byJev = WorkProgress(tag: "t"); byJev.reported = .done; byJev.reportedBy = "jev"
        precondition(WorkProgressTracker.moveReason(byJev) == "Jev read the reply as done" && WorkProgressTracker.moveReason(WorkProgress(tag: "t")) == "the session received it")
    }

    // MARK: - Board projections

    @MainActor static func projectionChecks() {
        func receipt(_ id: String, work: String, session: String?, status: String = "delivered", created: Double = 1, tracked: Bool = true) -> WorkHandoffReceipt {
            var row = WorkHandoffReceipt(id: id, workID: "task:Quilt:" + work, workTitle: work, sourceRevision: "1", mode: .continueSession,
                provider: "claude", modelID: "existing-session", sessionID: session, sessionTitle: "S", status: status, detail: "",
                prompt: "p", createdAt: created)
            row.channel = "turn"
            if tracked { row.progress = WorkProgress(tag: work) }
            return row
        }
        let now = Date().timeIntervalSince1970
        var base = receipt("a", work: "aaaaaaaaaaaa", session: "claude:one", created: now)
        precondition(WorkTracking.latest(workID: base.workID, receipts: [base])?.phase == .received)
        base.progress?.workingAt = now
        precondition(WorkTracking.latest(workID: base.workID, receipts: [base])?.phase == .working)
        var asking = base; asking.progress?.reported = .needsInput; asking.progress?.evidence = "Which price?"
        precondition(WorkTracking.latest(workID: base.workID, receipts: [asking])?.asksForYou == true)
        var reviewed = asking; reviewed.status = "reviewed"
        let answered = WorkTracking.latest(workID: base.workID, receipts: [reviewed])
        precondition(answered?.asksForYou == false && answered?.reported == false && answered?.label == "Answered", "Reviewing clears the question")
        var acknowledged = asking; acknowledged.acknowledgedAt = 1
        precondition(WorkTracking.latest(workID: base.workID, receipts: [acknowledged])?.asksForYou == false)
        var jevDone = base; jevDone.progress?.reported = .done; jevDone.progress?.reportedBy = "jev"
        precondition(WorkTracking.latest(workID: base.workID, receipts: [jevDone])?.byJev == true)
        let newerFailed = receipt("b", work: "aaaaaaaaaaaa", session: "claude:one", status: "refused", created: now + 10)
        precondition(WorkTracking.latest(workID: base.workID, receipts: [base, newerFailed]) == nil)
        var withMove = jevDone; withMove.progress?.record(.moved, "Jev read the reply as done", at: now, from: "draft", to: "qa", id: "w")
        let movedTracking = WorkTracking.latest(workID: base.workID, receipts: [withMove])
        precondition(movedTracking?.undoableMove(currentStage: "qa")?.id == "w" && movedTracking?.undoableMove(currentStage: "built") == nil)
        withMove.progress?.paused = true
        precondition(WorkTracking.latest(workID: base.workID, receipts: [withMove])?.undoableMove(currentStage: "qa") == nil, "No Undo once paused")
        precondition(WorkTracking.whyLine(WorkProgressEvent(id: "x", at: 0, kind: .moved, text: "the session reported done")).hasSuffix(": the session reported done."))

        // A session's tasks: newest per task, still with it, not done over a day ago.
        let other = receipt("c", work: "bbbbbbbbbbbb", session: "claude:one", created: now + 1)
        let handedOn = receipt("d", work: "cccccccccccc", session: "claude:one", created: now + 2)
        let handedOnLater = receipt("e", work: "cccccccccccc", session: "codex:else", created: now + 3)
        var doneLongAgo = receipt("f", work: "dddddddddddd", session: "claude:one", created: now - 3 * 86_400)
        doneLongAgo.progress?.reported = .done; doneLongAgo.progress?.record(.done, "d", at: now - 2 * 86_400)
        let held = WorkTracking.forSession("claude:one", receipts: [base, other, handedOn, handedOnLater, doneLongAgo], now: now)
        precondition(held.map { $0.receipt.id } == ["a", "c"], "\(held.map { $0.receipt.id })")

        // One card per session, for tracked handoffs only.
        func card(_ row: WorkHandoffReceipt) -> WorkBoardSessionCard {
            let item = WorkWorkspaceItem(id: row.workID, title: row.workTitle, domain: "Quilt", searchText: "", subtitle: "", task: nil, review: nil,
                                         needsAttention: true, inProgress: false, completed: false)
            return WorkBoardSessionCard(item: item, activity: WorkActivity(receipt: row, session: nil))
        }
        var fork = receipt("g", work: "eeeeeeeeeeee", session: "claude:one"); fork.mode = .fork; fork.sourceSessionID = "claude:one"
        let legacyCard = receipt("h", work: "ffffffffffff", session: "claude:one", tracked: false)
        let grouped = WorkBoardSessionsProjection.onePerSession([card(base), card(other), card(legacyCard), card(fork),
                                                                 card(receipt("i", work: "999999999999", session: nil))])
        precondition(grouped.map(\.id) == ["a", "h", "g", "i"], "\(grouped.map(\.id))")

        // The strip: shown while undoable and under 30 minutes; the session's words quoted, Jev's not.
        var stripped = base; stripped.progress?.reported = .done; stripped.progress?.reportedBy = "session"; stripped.progress?.evidence = "Shipped it"
        stripped.progress?.record(.moved, "the session reported done", at: now, from: "draft", to: "qa", id: "s1")
        let lookup: (String) -> (title: String, stage: String?)? = { _ in ("Draft the homepage call to action", "qa") }
        let shown = WorkLatestMoveStrip.shown(latest: ("a", "s1"), receipts: [stripped], lookup: lookup, now: now + 60)
        precondition(shown != nil)
        precondition(WorkLatestMoveStrip.shown(latest: ("a", "s1"), receipts: [stripped], lookup: lookup, now: now + WorkLatestMoveStrip.shownFor + 1) == nil)
        precondition(WorkLatestMoveStrip.shown(latest: ("a", "s1"), receipts: [stripped], lookup: { _ in ("t", "draft") }, now: now) == nil)
        var pausedStrip = stripped; pausedStrip.progress?.paused = true
        precondition(WorkLatestMoveStrip.shown(latest: ("a", "s1"), receipts: [pausedStrip], lookup: lookup, now: now) == nil)
    }

    // MARK: - The tracker, end to end

    @MainActor static func trackerChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-progress-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = WorkSession(id: "claude:s-one", nativeID: "s-one", provider: "claude", title: "Launch copy review", summary: "", project: "Website", status: "idle")
        let two = WorkSession(id: "claude:s-two", nativeID: "s-two", provider: "claude", title: "Pricing review", summary: "", project: "Website", status: "idle")
        let idA = "0123456789ab", idB = "bbbbbbbbbbbb"
        func source(_ identity: String) -> WorkSource {
            WorkSource(id: "task:Quilt:" + identity, title: "Task " + identity, revision: "1", project: "Quilt", context: "Task " + identity)
        }
        func setUp(_ name: String) -> (WorkHandoffStore, TrackingTransport, FakeBoard, Clock, WorkProgressTracker, NoticeBox) {
            let transport = TrackingTransport()
            let store = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent(name + ".json"),
                                         transport: { args, data in try await transport.run(args, data) })
            store.sessions = [one, two]
            store.models = [WorkModelChoice(id: "cursor-model", provider: "cursor", title: "Cursor", available: true, reason: nil)]
            let board = FakeBoard(); board.rows[idA] = "planned"; board.rows[idB] = "planned"
            let clock = Clock(), notices = NoticeBox()
            let tracker = WorkProgressTracker(store: store, board: board.board, notify: { notices.items.append($0) }, now: { clock.now() })
            return (store, transport, board, clock, tracker, notices)
        }
        func row(_ store: WorkHandoffStore, _ identity: String) throws -> WorkHandoffReceipt { try require(store.receipts(for: "task:Quilt:" + identity).first) }
        func head(_ prompt: String) -> String { String(prompt.prefix(80)) }

        // 1. A running turn stays running; the transcript shows it arrive; stale and foreign lines are ignored; done
        //    moves to QA; the pass is idempotent; Undo moves back and pauses.
        do {
            let (store, transport, board, clock, tracker, notices) = setUp("status-line")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Draft the CTA")
            let sent = await transport.sent()
            check(sent.count == 1 && sent[0].hasPrefix("Draft the CTA") && sent[0].hasSuffix(WorkProgress.instruction(tag: idA)))
            var r = try row(store, idA)
            check(r.prompt == sent[0] && r.status == "running" && r.progress?.events.map(\.kind) == [.sent])
            let created = r.createdAt
            await transport.setRead(replies: [("COS-WORK \(idA): done: stale, from an earlier handoff", stamp(created - 60))])
            await tracker.tick()
            r = try row(store, idA)
            check(r.status == "running", "A running turn's pending 404 is not a lost turn: \(r.status)")
            check(board.moves.isEmpty && notices.items.isEmpty && r.progress?.receivedAt == nil)
            // The session's conversation shows the instruction arriving: received, before the turn finishes.
            await transport.setRead(replies: [("COS-WORK \(idA): done: stale, from an earlier handoff", stamp(created - 60))],
                                    prompts: [(head(sent[0]), stamp(created + 2))])
            await tracker.tick()
            r = try row(store, idA)
            check(r.status == "running" && r.progress?.receivedAt != nil && r.progress?.promptAt != nil, "Received from the transcript")
            check(board.moves.count == 1 && board.moves[0] == (idA, "draft"), "Received moves the card to Draft")
            check(notices.items.map(\.key) == ["received"] && notices.items[0].body.hasSuffix("Moved to Draft."))
            check(r.progress?.workingAt == nil && r.progress?.reported == nil, "A line from before the prompt arrived never counts")
            // A foreign task's line; then this task's line.
            await transport.setRead(replies: [("COS-WORK \(idB): done: a different task", stamp(created + 20))], prompts: [(head(sent[0]), stamp(created + 2))])
            await tracker.tick()
            r = try row(store, idA)
            check(r.progress?.workingAt != nil && r.progress?.reported == nil && board.moves.count == 1)
            await transport.setTurn("completed")
            await transport.setRead(replies: [("Here it is.\nCOS-WORK \(idA): done: Updated the hero CTA and checked it at 390pt.", stamp(created + 40))],
                                    prompts: [(head(sent[0]), stamp(created + 2))])
            await tracker.tick()
            r = try row(store, idA)
            check(r.status == "delivered" && r.progress?.reported == .done && r.progress?.reportedBy == "session")
            check(board.moves.count == 2 && board.moves[1] == (idA, "qa"), "Done moves the card to QA")
            check(notices.items.map(\.key) == ["received", "done"] && notices.items[1].body.hasSuffix("Moved to QA."))
            check(tracker.latestMove?.receiptID == r.id && r.lastAutomaticMove?.toStage == "qa" && r.lastAutomaticMove?.text == "the session reported done")
            let events = r.progress?.events.count
            clock.offset += 600; await tracker.tick()
            r = try row(store, idA)
            check(r.progress?.events.count == events && board.moves.count == 2 && notices.items.count == 2)
            let doneMove = try require(r.lastAutomaticMove)
            check(await tracker.undo(receiptID: r.id, eventID: doneMove.id) == nil)
            r = try row(store, idA)
            check(board.rows[idA] == "draft" && r.progress?.paused == true && r.progress?.events.last?.kind == .undone)
            check(await tracker.undo(receiptID: r.id, eventID: doneMove.id) != nil, "An undone move cannot be undone twice")
            check(tracker.latestMove == nil)
            let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("status-line.json"))) as! [String: Any]
            let statuses = Set((journal["receipts"] as! [[String: Any]]).map { $0["status"] as! String })
            check(statuses.isSubset(of: ["preparing", "sending", "queued", "running", "delivered", "completed", "failed", "refused", "reviewed", "canceled", "unknown"]))
        }

        // 2. Several tasks in one session: one reply reports both.
        do {
            let (store, transport, board, _, tracker, notices) = setUp("several")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Task A")
            await store.submit(source: source(idB), mode: .continueSession, session: one, model: nil, prompt: "Task B")
            await transport.setTurn("completed")
            let created = try row(store, idB).createdAt
            await transport.setRead(replies: [("COS-WORK \(idA): done: A shipped and checked\nCOS-WORK \(idB): needs input: Which price for B?", stamp(created + 30))])
            await tracker.tick()
            check(board.rows[idA] == "qa" && board.rows[idB] == "draft", "\(board.rows)")
            check(try row(store, idB).progress?.reported == .needsInput)
            check(notices.items.contains { $0.key == "done" && $0.workID.hasSuffix(idA) })
            check(notices.items.contains { $0.key.hasPrefix("needsInput:") && $0.workID.hasSuffix(idB) })
            check(WorkTracking.forSession(one.id, receipts: store.receipts).count == 2)
            // Idle, and B's newest reply carries its own line: Jev is not asked about a reply that already reports.
            await transport.setRead(replies: [("COS-WORK \(idA): done: A shipped and checked\nCOS-WORK \(idB): needs input: Which price for B?", stamp(created + 30))],
                                    lastActivity: stamp(created - 600))
            await tracker.tick()
            check(await transport.count("work-completion-check") == 0, "A reply that reports is never judged")
            // Still tracked (B waits on you): another reply without a line records nothing new and notifies nothing.
            let events = try row(store, idB).progress?.events.count, count = notices.items.count
            await transport.setRead(replies: [("COS-WORK \(idA): done: A shipped and checked\nCOS-WORK \(idB): needs input: Which price for B?", stamp(created + 30)),
                                              ("Still waiting on the price.", stamp(created + 60))], agent: "waiting")
            await tracker.tick()
            check(try row(store, idB).progress?.events.count == events && notices.items.count == count, "One report, one notice")
        }

        // 3. Paused by Undo: a later done moves nothing. 4. Moved back by you: the same.
        for (name, byYou) in [("paused", false), ("moved-back", true)] {
            let (store, transport, board, _, tracker, _) = setUp(name)
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await transport.setRead(replies: [])
            await tracker.tick()
            check(board.rows[idA] == "draft", "\(name): received moved it")
            var r = try row(store, idA)
            if byYou { board.rows[idA] = "planned" } else {
                check(await tracker.undo(receiptID: r.id, eventID: try require(r.lastAutomaticMove).id) == nil)
            }
            await transport.setRead(replies: [("COS-WORK \(idA): done: all shipped and checked", stamp(r.createdAt + 30))])
            await tracker.tick()
            r = try row(store, idA)
            check(board.rows[idA] == "planned" && r.progress?.paused == true && r.progress?.pendingStage == nil, "\(name): stays where you put it")
            if byYou { check(r.progress?.events.contains { $0.text.hasPrefix("You moved it back to Planned") } == true) }
        }

        // 3b. A move queued behind a read-only board, then Undo of the earlier move: the queued move is dropped, not made.
        do {
            let (store, transport, board, _, tracker, _) = setUp("paused-queue")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await transport.setRead(replies: [])
            await tracker.tick()
            var r = try row(store, idA)
            check(board.rows[idA] == "draft")
            board.writable = false
            await transport.setRead(replies: [("COS-WORK \(idA): done: all shipped and checked", stamp(r.createdAt + 30))])
            await tracker.tick()
            r = try row(store, idA)
            check(r.progress?.pendingStage == "qa" && board.rows[idA] == "draft", "The done move waits for the board")
            check(await tracker.undo(receiptID: r.id, eventID: try require(r.lastAutomaticMove).id) == nil)
            board.writable = true
            await tracker.tick()
            r = try row(store, idA)
            check(board.rows[idA] == "planned" && r.progress?.pendingStage == nil, "The queued move is dropped after Undo: \(board.rows)")
        }

        // 5. Rules: a card you set further on stays; complete work is not followed at all.
        do {
            let (store, transport, board, _, tracker, notices) = setUp("rules")
            board.rows[idA] = "built"
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await tracker.tick()
            try check(board.moves.isEmpty && notices.items.map(\.key) == ["received"] && (row(store, idA)).progress?.pendingStage == nil)
            board.rows[idA] = "complete"
            let reads = await transport.count("session-recent-replies")
            await transport.setRead(replies: [("COS-WORK \(idA): needs input: which?", stamp((try row(store, idA)).createdAt + 5))])
            await tracker.tick()
            check(await transport.count("session-recent-replies") == reads && notices.items.count == 1, "Complete work is not read or notified")
        }

        // 5b. A handoff with no tracking (sent before 0.5.247) is never polled by the tracker, even beside a tracked one.
        do {
            let (store, transport, _, _, tracker, _) = setUp("legacy-in-flight")
            await store.submit(source: source(idB), mode: .continueSession, session: two, model: nil, prompt: "Legacy")
            let legacyID = try row(store, idB).id
            check(store.updateReceipt(legacyID) { $0.progress = nil; return true })
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Tracked")
            await tracker.tick()
            let polled = await transport.calls.filter { $0.first == "session-chat-turn" }.compactMap { $0.last }
            check(!polled.isEmpty && !polled.contains(legacyID), "Only tracked handoffs are polled: \(polled)")
        }

        // 6. A read-only board, a failed move and a card-level error: noted once, kept, retried; then made.
        do {
            let (store, transport, board, _, tracker, _) = setUp("retry")
            board.writable = false
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await tracker.tick()
            var r = try row(store, idA)
            check(board.moves.isEmpty && r.progress?.pendingStage == "draft" && r.progress?.moveAttempts == 1)
            check(r.progress?.events.filter { $0.text.hasPrefix("Could not move it to Draft yet: the board is read-only") }.count == 1)
            board.writable = true; board.failNext = "The task changed while you were moving it"
            await tracker.tick()
            r = try row(store, idA)
            check(board.moves.isEmpty && r.progress?.moveAttempts == 2 && r.progress?.pendingStage == "draft")
            await tracker.tick()
            r = try row(store, idA)
            check(board.rows[idA] == "draft" && r.progress?.pendingStage == nil && r.lastAutomaticMove?.toStage == "draft", "Retried and made")
        }
        do {
            let (store, transport, board, _, tracker, _) = setUp("give-up")
            board.metadataError = "Invalid Work identity. Refresh before changing this task."
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            for _ in 0..<WorkProgress.maxMoveAttempts { await tracker.tick() }
            let r = try row(store, idA)
            check(board.moves.isEmpty && r.progress?.pendingStage == nil && r.progress?.events.last?.text.hasPrefix("Stopped trying") == true)
        }

        // 7. Saved but the refresh failed: the card did move, so it is recorded as moved.
        do {
            let (store, transport, board, _, tracker, _) = setUp("saved-refresh")
            board.savedButRefreshFailsNext = true
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await tracker.tick()
            try check(board.rows[idA] == "draft" && (row(store, idA)).lastAutomaticMove?.toStage == "draft")
        }

        // 8. A busy journal: the whole pass waits (nothing recorded, nothing moved); a journal held across the move itself
        //    keeps the record and writes it on the next pass, so the card never loses its why-line.
        do {
            let (store, transport, board, _, tracker, notices) = setUp("busy")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            let lockPath = root.appendingPathComponent("busy.json").path + ".lock"
            var fd: Int32 = -1
            board.duringMove = {
                fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
                precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
            }
            await tracker.tick()
            check(board.rows[idA] == "draft" && tracker.deferredCount > 0, "The move happened; its record waits")
            check((try row(store, idA)).lastAutomaticMove == nil && notices.items.map(\.key) == ["received"])
            flock(fd, LOCK_UN); close(fd); board.duringMove = nil
            await tracker.tick()
            try check(tracker.deferredCount == 0 && (row(store, idA)).lastAutomaticMove?.toStage == "draft", "The record landed on the next pass")
            check((try row(store, idA)).progress?.notified.contains("received") == true && notices.items.count == 1, "Notified once")
        }

        // 9. Jev: never while the session works; once idle, about the replies since the handoff arrived; a transient
        //    failure retries later; a final one does not; a second new reply may be judged; never a third.
        do {
            let (store, transport, board, clock, tracker, _) = setUp("jev")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Draft the CTA")
            let sent = await transport.sent()[0]
            let created = try row(store, idA).createdAt
            let arrived = created + 2
            func setReply(_ texts: [(String, Double)], lastActivity: Double, running: Bool = false, agent: String = "idle") async {
                await transport.setRead(replies: texts.map { ($0.0, stamp($0.1)) }, prompts: [(head(sent), stamp(arrived))],
                                        running: running, agent: agent, lastActivity: stamp(lastActivity))
            }
            // The turn has not finished: never judged, however quiet.
            await setReply([("I rewrote the hero copy and checked it.", created + 10)], lastActivity: created + 10)
            clock.offset = 600; await tracker.tick()
            check(await transport.count("work-completion-check") == 0, "A Continue whose turn is still running is not judged")
            await transport.setTurn("completed")
            // Still working (transcript written recently, or marked running): not judged.
            let t = clock.now().timeIntervalSince1970
            await setReply([("I rewrote the hero copy and checked it.", created + 10)], lastActivity: t - 5)
            await tracker.tick()
            await setReply([("I rewrote the hero copy and checked it.", created + 10)], lastActivity: t - 600, running: true)
            await tracker.tick()
            await setReply([("I rewrote the hero copy and checked it.", created + 10)], lastActivity: t - 600, agent: "running")
            await tracker.tick()
            check(await transport.count("work-completion-check") == 0, "A working session is never judged")
            // Idle: asked, about replies since the handoff arrived. A transient failure does not use it up.
            await transport.setCompletion(["provider": .string("none"), "reason": .string("unreachable")])
            await setReply([("I rewrote the hero copy and checked it.", created + 10)], lastActivity: t - 600)
            await tracker.tick()
            check(await transport.count("work-completion-check") == 1)
            check(await transport.bodies().last == ["domain": "Quilt", "id": idA, "provider": "claude", "sessionId": "s-one", "after": stamp(arrived)])
            await tracker.tick()
            check(await transport.count("work-completion-check") == 1, "Not retried before jevRetryAfter")
            await transport.setCompletion(["provider": .string("jev"), "verdict": .string("done"), "confidence": .number(0.82), "basis": .string("task")])
            clock.offset += WorkProgressTracker.jevRetryAfter + 1
            await tracker.tick()
            var r = try row(store, idA)
            check(await transport.count("work-completion-check") == 2, "Retried after a transient failure")
            check(board.rows[idA] == "draft" && r.progress?.reported == nil && r.progress?.events.last?.kind == .jev, "0.82 on the task alone does not move it")
            await tracker.tick()
            check(await transport.count("work-completion-check") == 2, "The same reply is judged once")
            // A new reply: judged again, and now done enough.
            await transport.setCompletion(["provider": .string("jev"), "verdict": .string("done"), "confidence": .number(0.9), "basis": .string("task")])
            let t2 = clock.now().timeIntervalSince1970
            await setReply([("I rewrote the hero copy and checked it.", created + 10), ("All checked on a phone too.", created + 30)], lastActivity: t2 - 600)
            await tracker.tick()
            r = try row(store, idA)
            check(await transport.count("work-completion-check") == 3 && board.rows[idA] == "qa" && r.progress?.reportedBy == "jev")
            check(r.lastAutomaticMove?.text == "Jev read the reply as done")
        }
        do {
            let (store, transport, _, clock, tracker, _) = setUp("jev-final")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await transport.setCompletion(["provider": .string("none"), "reason": .string("task_not_found")])
            let created = try row(store, idA).createdAt
            clock.offset = 600
            await transport.setRead(replies: [("Working on it.", stamp(created + 10))], lastActivity: stamp(clock.now().timeIntervalSince1970 - 600))
            await tracker.tick()
            clock.offset += WorkProgressTracker.jevRetryAfter + 1
            await tracker.tick()
            check(await transport.count("work-completion-check") == 1, "A final reason uses up that reply")
            _ = store
        }
        do {
            // Only replies from before the handoff arrived: no "Replied", no Jev.
            let (store, transport, _, clock, tracker, _) = setUp("jev-pre")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Draft the CTA")
            let sent = await transport.sent()[0]
            await transport.setTurn("completed")
            let created = try row(store, idA).createdAt
            clock.offset = 600
            await transport.setRead(replies: [("Earlier answer about something else.", stamp(created - 30))],
                                    prompts: [(head(sent), stamp(created + 2))], lastActivity: stamp(clock.now().timeIntervalSince1970 - 600))
            await tracker.tick()
            try check(await transport.count("work-completion-check") == 0 && (row(store, idA)).progress?.workingAt == nil)
        }

        // 10. Untimed replies (Cursor): those present at the first read are the baseline and never count.
        do {
            let (store, transport, board, _, tracker, _) = setUp("baseline")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setRead(replies: [("COS-WORK \(idA): done: from an earlier handoff", nil)])
            await tracker.tick()
            await transport.setTurn("completed")
            await tracker.tick()
            try check(board.rows[idA] == "draft" && (row(store, idA)).progress?.reported == nil, "The baseline line does not count")
            await transport.setRead(replies: [("COS-WORK \(idA): done: from an earlier handoff", nil), ("COS-WORK \(idA): done: new work shipped", nil)])
            await tracker.tick()
            check(board.rows[idA] == "qa")
        }
        // No history from the server: nothing inferred.
        do {
            let (store, transport, board, _, tracker, _) = setUp("no-history")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await transport.setRead(replies: [])
            await tracker.tick()   // the baseline is taken, and it is empty
            await transport.setRead(replies: [("COS-WORK \(idA): done: newest reply, no time", nil)], state: "no_history")
            await tracker.tick(); await tracker.tick()
            try check(board.rows[idA] == "draft" && (row(store, idA)).progress?.reported == nil)
        }

        // 11. A run with no session of its own reports through its result.
        do {
            let (store, transport, board, _, tracker, _) = setUp("job")
            let model = WorkModelChoice(id: "cursor-model", provider: "cursor", title: "Cursor", available: true, reason: nil)
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: model, prompt: "Go")
            await transport.setJobResult("COS-WORK \(idA): done: answered in full")
            await tracker.tick()
            check(board.rows[idA] == "qa", "\(board.rows)")
            check((try row(store, idA)).progress?.events.contains { $0.text == "Received. The new session started with it." } == true)
        }

        // 13. A New session names its session a moment after it starts (2026-09-29: 0.17 s). The receipt links it
        //     within seconds, with no tracker pass and no window open, and stops reading once it has. Sessions then
        //     shows the run as work: the helper calls every run the COS server starts a "COS server" job.
        do {
            let (store, transport, _, _, _, _) = setUp("link")
            store.newSessionLinkDelays = [.zero, .zero, .zero]
            let opus = WorkModelChoice(id: "opus", provider: "claude", title: "Opus", available: true, reason: nil)
            store.models = [opus]
            await transport.setClaudeJob(session: "e836fff6", afterReads: 2)
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
            check((try row(store, idA)).sessionID == nil, "the first answer names no session")
            await store.newSessionLink?.value
            let linked = try row(store, idA)
            check(linked.sessionID == "claude:e836fff6" && linked.status == "running", "\(String(describing: linked.sessionID)) \(linked.status)")
            let reads = await transport.count("work-job")
            check(reads == 2, "stops reading once linked: \(reads)")
            let run = try require(ClaudeSession(.object(["id": .string("e836fff6"), "name": .string("Prepare the next reviewable result"),
                "origin": .string("job"), "jobLabel": .string("COS server"), "jobScript": .string("index.ts"), "state": .string("running")])))
            let archive = try require(ClaudeSession(.object(["id": .string("aaaa1111"), "name": .string("Archive summary"),
                "origin": .string("job"), "jobLabel": .string("COS server"), "jobScript": .string("index.ts")])))
            let marked = ClaudeSession.markingWork([run, archive], workSessionIDs: Set(store.receipts.compactMap(\.sessionID)))
            check(!marked[0].isScheduledJob && marked[0].title == "Prepare the next reviewable result", "\(marked[0].title)")
            check(marked[1].isScheduledJob && marked[1].title == "COS server", "a run Work did not send stays a job")
            check(ClaudeSession.markingWork(marked, workSessionIDs: []).allSatisfy(\.isScheduledJob), "the mark follows the receipts")
            // The card says where a New session runs, since it is never a tab in the provider's app.
            var note = linked
            check(WorkHandoffView.whereItRunsNote(note)?.hasSuffix("Open session to follow it.") == true)
            note.sessionID = nil
            check(WorkHandoffView.whereItRunsNote(note)?.hasSuffix("Its session shows here in a moment.") == true)
            note.sessionID = "claude:e836fff6"; note.status = "completed"
            check(WorkHandoffView.whereItRunsNote(note) == "Ran on this Mac through COS. Open session, then Open in platform, to keep going in the Claude app.")
            note.provider = "cursor"
            check(WorkHandoffView.whereItRunsNote(note) == nil, "Cursor and Ollama runs have no session to open")
            check(WorkHandoffView.whereItRunsNote(try row(store, idA)).map { !$0.contains("\u{2014}") } == true)
            var continued = linked; continued.mode = .continueSession; continued.channel = "turn"
            check(WorkHandoffView.whereItRunsNote(continued) == nil)
        }

        // 14. The link gives up after its last wait when no session is named, and a run that finished stops it at once.
        do {
            let (store, transport, _, _, _, _) = setUp("link-never")
            store.newSessionLinkDelays = [.zero, .zero, .zero]
            let opus = WorkModelChoice(id: "opus", provider: "claude", title: "Opus", available: true, reason: nil)
            store.models = [opus]
            await transport.setClaudeJob(session: "e836fff6", afterReads: 99)
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
            await store.newSessionLink?.value
            let reads = await transport.count("work-job")
            check((try row(store, idA)).sessionID == nil && reads == 3, "bounded: \(reads)")

            let (done, doneTransport, _, _, _, _) = setUp("link-done")
            done.newSessionLinkDelays = [.zero, .zero, .zero]
            done.models = [opus]
            await doneTransport.setClaudeJob(session: "e836fff6", afterReads: 99)
            await done.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
            await doneTransport.setJobResult("finished")
            await done.newSessionLink?.value
            let doneReads = await doneTransport.count("work-job")
            check((try row(done, idA)).status == "completed" && doneReads == 1, "a finished run is recorded once: \(doneReads)")
        }

        // 12. A newer handoff replaces the older: the older one's session no longer moves the card.
        do {
            let (store, transport, board, _, tracker, _) = setUp("superseded")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "First")
            await transport.setTurn("completed")
            await tracker.tick()
            let first = try row(store, idA)
            store.markReviewed(receiptID: first.id)
            await store.submit(source: source(idA), mode: .continueSession, session: two, model: nil, prompt: "Second")
            check(store.receipts(for: "task:Quilt:" + idA).count == 2)
            await transport.setRead(replies: [("COS-WORK \(idA): done: the first session says so", stamp(first.createdAt + 60))])
            let before = board.moves.count
            await tracker.tick()
            // Both sessions read the same fixture; only the newest handoff (session two) may act on it.
            let second = try row(store, idA)
            check(second.id != first.id && second.progress?.reported == .done && store.receipts.first { $0.id == first.id }?.progress?.reported == nil)
            check(board.moves.count == before + 1)
        }

        // 13. Back-off: a session quiet for over an hour is read every 5 minutes, not every pass.
        do {
            let (store, transport, _, clock, tracker, _) = setUp("backoff")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Go")
            await transport.setTurn("completed")
            await transport.setRead(replies: [])
            await tracker.tick()
            clock.offset = 3_700
            await tracker.tick()
            let reads = await transport.count("session-recent-replies")
            clock.offset += 60; await tracker.tick()
            check(await transport.count("session-recent-replies") == reads, "Not read again within 5 minutes")
            clock.offset += 300; await tracker.tick()
            check(await transport.count("session-recent-replies") == reads + 1)
            _ = store
        }

        // 15. Not done yet: the reply is reviewed, the same session continues with what is missing, the send-back is on
        //     the old handoff's timeline, and the new handoff is tracked (the old done line cannot finish it).
        do {
            let (store, transport, board, clock, tracker, _) = setUp("send-back")
            await store.submit(source: source(idA), mode: .continueSession, session: one, model: nil, prompt: "Draft the CTA")
            await transport.setTurn("completed")
            let created = try row(store, idA).createdAt
            // Stamped just after the first handoff and before the send-back, as a real reply would be.
            await transport.setRead(replies: [("COS-WORK \(idA): done: Updated the hero CTA and checked it.", stamp(created + 0.001))])
            await tracker.tick()
            try await Task.sleep(for: .milliseconds(30))
            let old = try row(store, idA)
            check(board.rows[idA] == "qa" && old.status == "delivered" && store.sendBackSession(for: old)?.id == one.id)
            check(await store.sendBack(receiptID: old.id, source: source(idA), missing: "   ") == false, "Nothing to say, nothing sent")
            clock.offset = 120
            check(await store.sendBack(receiptID: old.id, source: source(idA), missing: "The mobile layout is not checked."))
            let reviewed = try require(store.receipts.first { $0.id == old.id })
            check(reviewed.status == "reviewed" && reviewed.progress?.events.last?.text == "You sent it back: \u{201C}The mobile layout is not checked.\u{201D}")
            let fresh = try row(store, idA)
            check(fresh.id != old.id && fresh.mode == .continueSession && fresh.sessionID == one.id && fresh.progress != nil)
            check(fresh.prompt.hasPrefix("Not done yet. Your status line said: \u{201C}Updated the hero CTA and checked it.\u{201D}\nWhat is missing: The mobile layout is not checked.")
                  && fresh.prompt.hasSuffix(WorkProgress.instruction(tag: idA)), fresh.prompt)
            await tracker.tick()
            check(try row(store, idA).progress?.reported == nil, "The old done line never finishes the new handoff")
            check(WorkTracking.latest(workID: "task:Quilt:" + idA, receipts: store.receipts)?.receipt.id == fresh.id)
            // Where it is not offered: nothing reported done yet, a turn still in flight, a run with no session.
            check(store.sendBackSession(for: fresh) == nil)
            var inFlight = old; inFlight.status = "running"
            check(store.sendBackSession(for: inFlight) == nil)
            var noSession = old; noSession.sessionID = nil
            check(store.sendBackSession(for: noSession) == nil)
            check(!WorkHandoffStore.sendBackPrompt(missing: "x", evidence: "Jev read the reply as done (91%).", reportedBy: "jev").contains("status line said"),
                  "Jev's reading is never quoted back as the session's own line")
        }

        check(!WorkHandoffStore.sendBackPrompt(missing: "x", evidence: "Jev read the reply as done (90%)", reportedBy: "jev").contains("status line"),
              "Jev's reading is never quoted as the session's status line")

        // 14. A journal unreadable at launch recovers without a relaunch.
        do {
            let url = root.appendingPathComponent("recover.json")
            try Data("not json".utf8).write(to: url)
            let store = WorkHandoffStore(isolated: false, storageURL: url, transport: { _, _ in throw HelperClientError.commandFailed("none") })
            check(store.error != nil)
            try FileManager.default.removeItem(at: url)
            store.retryJournalIfUnavailable()
            check(store.error == nil, "Readable again")
        }
    }
}
