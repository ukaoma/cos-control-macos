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
    /// 0.5.249 (start it, then open it): the provider the job runs on and the session it names, a run that fails, and what
    /// the helper's session-reveal says about a Claude session.
    var jobProvider: String?
    var jobFailed = false
    var revealReason = "import"
    var revealLink: String?
    func setJob(provider: String, session: String?, afterReads: Int = 1) {
        jobProvider = provider; jobClaudeSession = session; sessionAfterReads = afterReads
    }
    func setFailed(_ failed: Bool) { jobFailed = failed }
    /// A raw server job state to answer with (canceled, interrupted, answer_ready), whatever the result.
    var jobStateOverride: String?
    func setJobState(_ state: String?) { jobStateOverride = state }
    var revealFails = false
    func setReveal(_ reason: String, link: String? = nil, fails: Bool = false) { revealReason = reason; revealLink = link; revealFails = fails }
    /// 0.5.253: the live session list as raw rows (a Cursor chat carries its `createdAt`).
    func setLiveRows(_ rows: [JSONValue]) { liveSessions = rows }
    /// Whether any command line this transport was given carries `text` (a claim token must never).
    func argvCarries(_ text: String) -> Bool { calls.contains { $0.contains { $0.contains(text) } } }
    func args(_ verb: String) -> [[String]] { calls.filter { $0.first == verb } }
    /// 0.5.250: the `sessionName` each work-new request carried ("<none>" when it had none).
    var sessionNames: [String] = []
    func names() -> [String] { sessionNames }
    /// 0.5.252 (QA round 2): the query each work-new carried, as the agent would read it.
    var newQueries: [String] = []
    func queries() -> [String] { newQueries }
    func bodies() -> [[String: String]] { completionBodies }
    /// 0.5.252: the glasses request inbox, the model catalog and the live sessions, answered as the helper does.
    static let claimToken = String(repeating: "c", count: 32)
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
    var inboxRows: [JSONValue] = []
    var inboxReason: String?
    var claimRefusal: String?
    var claimExpiresIn: Double = 600
    var claimOmitsDeadline = false
    /// Requests already claimed (never listed as pending again, as on the real server): claimable only with the token.
    var claimedRows: [JSONValue] = []
    var claimTokens: [String] = []
    var catalogFails = false
    var attachable = true
    var attachReason: String?
    var delays: [String: Double] = [:]
    var claims: [String] = []
    var posted: [(id: String, body: [String: String])] = []
    var postAnswers: [[String: JSONValue]] = []
    var catalog: [JSONValue] = []
    var liveSessions: [JSONValue] = []
    var lists = 0
    var newHTTP: Int?
    /// A native fork the server made: the child session it names. Nil answers as a refused fork.
    var forkChild: JSONValue?
    func setFork(child: JSONValue?) { forkChild = child }
    func setInbox(_ rows: [JSONValue], reason: String? = nil) { inboxRows = rows; inboxReason = reason }
    func setClaim(refusal: String?, expiresIn: Double = 600, omitsDeadline: Bool = false) {
        claimRefusal = refusal; claimExpiresIn = expiresIn; claimOmitsDeadline = omitsDeadline
    }
    func setClaimed(_ rows: [JSONValue]) { claimedRows = rows }
    func setCatalogFails(_ fails: Bool) { catalogFails = fails }
    func setAttach(attachable: Bool, reason: String? = nil) { self.attachable = attachable; attachReason = reason }
    func setDelay(_ verb: String, seconds: Double) { delays[verb] = seconds }
    func queuePostAnswers(_ answers: [[String: JSONValue]]) { postAnswers = answers }
    func setNewAnswer(http: Int?) { newHTTP = http }
    func setCatalog(models: [WorkModelChoice], sessions: [WorkSession]) {
        catalog = models.map { .object(["id": .string($0.id), "provider": .string($0.provider), "title": .string($0.title),
                                        "available": .bool($0.available)]) }
        liveSessions = sessions.map { .object(["id": .string($0.nativeID), "provider": .string($0.provider), "name": .string($0.title),
                                               "workspace": .string($0.project), "state": .string($0.status)]) }
    }
    func inboxLog() -> (lists: Int, claims: [String], posted: [(id: String, body: [String: String])], claimTokens: [String]) {
        (lists, claims, posted, claimTokens)
    }
    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
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
        if let verb = args.first, let delay = delays[verb] { try? await Task.sleep(for: .seconds(delay)) }
        var details: [String: JSONValue] = [:]
        switch args.first {
        case "session-chat-attachability":
            details = ["attachable": .bool(attachable)]
            if let attachReason { details["reason"] = .string(attachReason) }
            if !attachable { details["reasonCopy"] = .string("Sample: this session cannot be continued now.") }
        case "session-chat-fork":
            if let forkChild { details = ["state": .string("forked"), "forkSession": forkChild] }
            else { details = ["state": .string("refused"), "httpStatus": .number(409), "reasonCopy": .string("Sample: the fork was refused.")] }
        case "session-chat-queue": details = ["state": .string("parked")]
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
            sessionNames.append(payload["sessionName"].map { $0 as? String ?? "<not text>" } ?? "<none>")
            newQueries.append(payload["query"] as? String ?? "<none>")
            details = job()
            if let newHTTP {
                details["httpStatus"] = .number(Double(newHTTP))
                details["error"] = .object(["code": .string("invalid_request"), "message": .string("Sample: refused at admission.")])
            }
        case "claude-session-detail": details = ["copyText": .string("YOU: build the page\nASSISTANT: built it")]
        case "work-job": workJobReads += 1; details = job()
        case "session-reveal":
            if revealFails { throw HelperClientError.commandFailed("Synthetic: the helper did not answer") }
            let id = args.last ?? ""
            let link = revealLink ?? (revealReason == "import" ? "claude://resume?session=" + id : nil)
            details = ["provider": .string("claude"), "sessionId": .string(id), "revealReason": .string(revealReason),
                       "deepLink": link.map(JSONValue.string) ?? .null]
        case "work-requests":
            lists += 1
            details = inboxReason.map { ["available": .bool(false), "reason": .string($0), "requests": .array([])] }
                ?? ["available": .bool(true), "requests": .array(inboxRows)]
        case "work-request-claim":
            // As the server: a pending request is claimed once and is never listed as pending again; a claimed one is
            // claimed again only under its token.
            let id = value(after: "--id", in: args) ?? ""
            // 0.5.253: a claim made again carries its token on standard input (`--again`), as the helper reads it.
            let again = args.contains("--again")
                ? ((try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: String])?["claimToken"] ?? "<no token on stdin>"
                : nil
            if let again { claimTokens.append(again) } else { claims.append(id) }
            func claimed(_ row: JSONValue) -> [String: JSONValue] {
                var o = row.object ?? [:]
                o["state"] = .string("claimed")
                if !claimOmitsDeadline { o["claimExpiresAt"] = .string(Self.iso(Date().addingTimeInterval(claimExpiresIn))) }
                return ["claimed": .bool(true), "claimToken": .string(Self.claimToken), "request": .object(o)]
            }
            if let refusal = claimRefusal {
                details = ["claimed": .bool(false), "reason": .string(refusal)]
            } else if let again {
                if again == Self.claimToken, let row = claimedRows.first(where: { $0.object?["clientRequestId"]?.string == id }) { details = claimed(row) }
                else { details = ["claimed": .bool(false), "reason": .string("already_claimed")] }
            } else if let index = inboxRows.firstIndex(where: { $0.object?["clientRequestId"]?.string == id }) {
                let row = inboxRows.remove(at: index)
                claimedRows.append(row)
                details = claimed(row)
            } else { details = ["claimed": .bool(false), "reason": .string("request_not_found")] }
        case "work-request-result":
            let body = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: String] ?? [:]
            posted.append((value(after: "--id", in: args) ?? "", body))
            details = postAnswers.isEmpty ? ["accepted": .bool(true)] : postAnswers.removeFirst()
        case "work-models":
            if catalogFails { throw HelperClientError.commandFailed("Synthetic: the catalog did not answer") }
            details = ["models": .array(catalog), "serverInstanceId": .string("fixture")]
        case "claude-sessions": details = ["sessions": .array(liveSessions)]
        default: throw HelperClientError.commandFailed("Unexpected fixture command: \(args)")
        }
        return HelperResponse(ok: true, message: "Synthetic transport", details: details)
    }
    private func job() -> [String: JSONValue] {
        // 0.5.253: a run with no session of its own is a local model's (Cursor runs nothing in the background now).
        let provider = jobProvider ?? (jobClaudeSession == nil ? "ollama" : "claude")
        var job: [String: JSONValue] = ["clientJobId": .string(jobIdentity), "generation": .number(1), "jobId": .string("job-fixture"),
                                         "status": .string(jobStateOverride ?? (jobFailed ? "failed" : jobResult == nil ? "running" : "completed")),
                                         "provider": .string(provider)]
        if let jobResult { job["response"] = .string(jobResult) }
        if jobFailed { job["error"] = .object(["code": .string("provider_failed"), "message": .string("Sample: the provider stopped.")]) }
        if let session = jobClaudeSession, workJobReads >= sessionAfterReads {
            job["providerOwnershipConfirmedAt"] = .string("2026-09-29T18:46:57.717Z")
            job[provider == "codex" ? "codexThreadId" : "cliSessionId"] = .string(session)
        }
        return ["job": .object(job)]
    }
}

@MainActor private final class FakeBoard {
    var rows: [String: String] = [:]     // identity -> stage
    /// 0.5.252: a row's whole title (`text`), when a check needs one; and a board read that fails.
    var texts: [String: String] = [:]
    var readable = true
    var checked: [String: Bool] = [:]
    var writable = true
    var moves: [(String, String)] = []
    var failNext: String?
    var metadataError: String?
    /// Runs inside a move (to hold the journal while the tracker records it).
    var duringMove: (() -> Void)?
    var savedButRefreshFailsNext = false
    func task(_ identity: String) -> TaskRow {
        var row: [String: JSONValue] = ["id": .string(identity), "domain": .string("Quilt"), "title": .string("Homepage CTA"),
                                        "text": .string(texts[identity] ?? "Draft the homepage call to action " + identity), "doneWhen": .string(""),
                                        "workStage": .string(rows[identity] ?? "planned"), "workIdentity": .string(identity),
                                        "workRevision": .string(String(repeating: "a", count: 64))]
        if let forced = checked[identity] { row["checked"] = .bool(forced) }
        else if rows[identity] == "complete" { row["checked"] = .bool(true) }
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
              },
              readFresh: { self.readable })
    }
}

@MainActor private final class Clock { var offset: Double = 0; func now() -> Date { Date().addingTimeInterval(offset) } }
@MainActor private final class NoticeBox { var items: [WorkProgressNotice] = [] }

private func stamp(_ seconds: Double) -> String { WorkProgress.stamp(seconds) }

@main struct WorkProgressChecks {
    @MainActor static func main() async throws {
        pureChecks()
        appChecks()
        sessionNameChecks()
        projectionChecks()
        try revisionParityChecks()
        try await trackerChecks()
        print("PASS: Work tracking (status line, delivery, stages, projections, tracker: pending turns, arrival, reports, several tasks, pause, moved back, retries, busy journal, Jev gating, baseline, job result, superseded, back-off, New session link, Work sessions not jobs, start it then open it in the app, named after the task and linked while it runs, glasses requests, revision parity with the server's 12 golden rows, a glasses Start never sends the Mac's draft, Mac actions told to wait during a glasses send, no session bound after the deadline; 0.5.253: Cursor filled in for you to send (New session and Continue, cut and clipboard, found once sent, never a guess, Not sending it, a 0.5.252 Cursor run), Cursor refused from the glasses, results posted one pass at a time, a shared, locked ledger, the claim token never on a command line, 401 and 403 retried, fresh board reads, Open in Claude recorded while the journal is held)")
    }

    /// `precondition` takes an autoclosure, which cannot await.
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        if !condition { fatalError("check failed at line \(line): \(message())") }
    }
    /// 0.5.252: the glasses send the task revision the server computed; Control refuses a request whose revision is not
    /// its own for that row. These are the server's 12 golden rows (glasses-server 6.59.0,
    /// server/lib/__fixtures__/control-task-snapshot), whose expected revisions were computed by Control's own
    /// taskSnapshot at 0.5.250. A change to taskSnapshot's format fails here, before it strands every glasses request.
    @MainActor static func revisionParityChecks() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/control-task-snapshot")
        let rows = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: folder.appendingPathComponent("rows.json")))
        let expected = try String(contentsOf: folder.appendingPathComponent("expected.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        check(rows.count == 12 && expected.count == 12, "12 golden rows: \(rows.count) rows, \(expected.count) expected")
        for (index, row) in rows.enumerated() {
            let task = try require(TaskRow(row))
            let snapshot = WorkSource.taskSnapshot(task)
            check(snapshot.id + " " + snapshot.revision == expected[index], "golden row \(index + 1): \(snapshot.id) \(snapshot.revision), expected \(expected[index])")
        }
        check(Set(expected.map { $0.split(separator: " ").last.map(String.init) ?? "" }).count >= 5, "the goldens are not one repeated value")
    }

    private static func require<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { throw HelperClientError.commandFailed("required value missing at line \(line)") }
        return value
    }

    // MARK: - Pure rules

    @MainActor static func pureChecks() {
        // 0.5.253 (QA, deferred from 0.5.252): the board read a glasses request is checked against. A newer read never makes
        // an older failed one read as OK, a superseded read records nothing, and a read that began before the mark is old.
        var reads = WorkBoardReads()
        let mark = reads.started
        let mine = reads.begin(), newer = reads.begin()
        precondition(!reads.record(mine, ok: false) && reads.pending && !reads.readOK(since: mark), "superseded: nothing recorded, not fresh")
        precondition(reads.record(newer, ok: true) && !reads.pending && reads.readOK(since: mark), "the newer read, once it read the board, is fresh")
        let mark2 = reads.started
        let failed = reads.begin()
        precondition(reads.record(failed, ok: false) && !reads.readOK(since: mark2), "a read that failed is never fresh")
        let good = reads.begin()
        precondition(reads.record(good, ok: true) && reads.readOK(since: mark2) && !reads.readOK(since: reads.started), "a read begun before the mark is not fresh")

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
        precondition(answered?.asksForYou == true && answered?.reported == true && answered?.label == "Reviewed, not answered", "Reviewing does not answer the question")
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

    // MARK: - Named after the task, found while it runs (0.5.250): the pure rules

    @MainActor static func sessionNameChecks() {
        func name(_ title: String) -> String? { WorkHandoffStore.claudeSessionName(title) }
        precondition(name("  Homepage\tCTA\n for the  launch  ") == "Homepage CTA for the launch", "whitespace collapsed")
        precondition(name("Fix\u{0}the\u{202E}footer\u{200B}links\u{FEFF}now\u{2066}ok\u{85}end") == "Fix the footer links now ok end",
                     "controls, direction marks and invisible spaces become spaces (as server 6.58.2 cleans them)")
        precondition(name("Plan \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467} trip \u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645} \u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}")
                     == "Plan \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467} trip \u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645} \u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
                     "joiners and tag characters stay: emoji and words hold together")
        precondition(name("Price\u{00A0}\u{00A0}list\u{2028}now") == "Price list now", "every whitespace run collapses")
        precondition(name("\u{200B}\u{FEFF}\u{0}\u{2066} ") == nil, "an all-invisible title is no name")
        precondition(name("Draft the brief: part one, two,") == "Draft the brief: part one, two", "no trailing comma")
        precondition(name("Why is it slow?!\u{2026}") == "Why is it slow", "no trailing marks")
        precondition(name("Pricing \u{2014}") == "Pricing" && name("Sales &") == "Sales" && name("A / ") == "A", "no dangling dash, ampersand or slash")
        precondition(name("Ship C++") == "Ship C++" && name("Port to C#") == "Port to C#" && name("Fix (mobile)") == "Fix (mobile)"
                     && name("Say \u{201C}hello\u{201D}") == "Say \u{201C}hello\u{201D}", "closing brackets, quotes and signs in names stay")
        precondition(name("Caf\u{E9} \u{E9}l\u{E9}gant menu") == "Caf\u{E9} \u{E9}l\u{E9}gant menu", "non-ASCII letters stay")
        precondition(name("  \n\t ") == nil && name("") == nil && name(" ... , ") == nil, "nothing left, no name")
        // Cut on a word boundary at 100 UTF-16 units, as the server counts, then without trailing punctuation.
        let words = (1...40).map { "word\($0)," }.joined(separator: " ")
        let cut = name(words)!
        precondition(cut.count <= 100 && words.hasPrefix(cut) && !cut.hasSuffix(",") && words.dropFirst(cut.count).hasPrefix(", "), cut)
        precondition(cut == "word1, word2, word3, word4, word5, word6, word7, word8, word9, word10, word11, word12, word13", cut)
        let exact = String(repeating: "a", count: 94) + " bcdef"
        precondition(exact.count == 100 && name(exact) == exact, "exactly 100 fits")
        precondition(name(exact + " g") == String(repeating: "a", count: 94), "past 100: cut at 100, then back to the last space (index 94)")
        precondition(name(String(repeating: "a", count: 95) + " bcdef") == String(repeating: "a", count: 95), "101 cuts back to the space")
        precondition(name("a " + String(repeating: "b", count: 120)) == "a " + String(repeating: "b", count: 98), "a space before index 50 is ignored: hard cut at 100")
        precondition(name(String(repeating: "x", count: 150)) == String(repeating: "x", count: 100), "one long word is cut inside it")
        precondition(name(String(repeating: "\u{1F600}", count: 60)) == String(repeating: "\u{1F600}", count: 60)
                     && name(String(repeating: "\u{1F600}", count: 150)) == String(repeating: "\u{1F600}", count: 100),
                     "counted in characters, as the server counts: never splits one")
        // A listed session by its short or full id, never another provider's, never a shorter prefix.
        let full = "claude:8f7a53b9-b478-4d88-88e4-4a915b256da5"
        precondition(ClaudeSession.sameSession(full, "claude:8f7a53b9") && ClaudeSession.sameSession("claude:8F7A53B9", full) && ClaudeSession.sameSession(full, full))
        precondition(!ClaudeSession.sameSession(full, "claude:8f7a53b") && !ClaudeSession.sameSession(full, "codex:8f7a53b9")
                     && !ClaudeSession.sameSession(full, "claude:8f7a53b9-0000") && !ClaudeSession.sameSession("claude:", "claude:")
                     && !ClaudeSession.sameSession(full, "8f7a53b9-b478-4d88-88e4-4a915b256da5"))
        let short = WorkSession(id: "claude:8f7a53b9", nativeID: "8f7a53b9", provider: "claude", title: "Homepage CTA", summary: "", project: "", status: "running")
        let other = WorkSession(id: "claude:11111111", nativeID: "11111111", provider: "claude", title: "Other", summary: "", project: "", status: "idle")
        var receipt = WorkHandoffReceipt(id: "r", workID: "task:Quilt:0123456789ab", workTitle: "T", sourceRevision: "1", mode: .newSession,
                                         provider: "claude", modelID: "opus", sessionID: full, sessionTitle: "T", status: "running",
                                         detail: "", prompt: "p", createdAt: 0, channel: "job")
        precondition(WorkHandoffStore.listedSession(for: receipt, in: [other, short])?.id == short.id, "the live list's short id is this session")
        let exactRow = WorkSession(id: full, nativeID: String(full.dropFirst(7)), provider: "claude", title: "Exact", summary: "", project: "", status: "running")
        precondition(WorkHandoffStore.listedSession(for: receipt, in: [short, exactRow])?.id == full, "the exact id wins")
        receipt.provider = "codex"
        precondition(WorkHandoffStore.listedSession(for: receipt, in: [short]) == nil, "never another provider's")
        receipt.sessionID = nil
        precondition(WorkHandoffStore.listedSession(for: receipt, in: [short]) == nil)
        // The Continue picker lists the session once, under the full id its receipt names.
        let canonical = WorkHandoffStore.canonicalSessions([short, other, exactRow], linked: [full])
        precondition(canonical.map(\.id) == [full, other.id] && canonical[0].nativeID == String(full.dropFirst(7))
                     && canonical[0].title == "Homepage CTA" && canonical[0].status == "running", "\(canonical.map(\.id))")
        precondition(WorkHandoffStore.canonicalSessions([short], linked: []).map(\.id) == [short.id], "no receipt, no change")
        // A session is app-owned, or held by the server, whichever id it is listed under.
        var opened = WorkHandoffReceipt(id: "o", workID: "task:Quilt:0123456789ab", workTitle: "T", sourceRevision: "1", mode: .newSession,
                                        provider: "claude", modelID: "opus", sessionID: full, sessionTitle: "T", status: "completed",
                                        detail: "", prompt: "p", createdAt: 0, channel: "job")
        opened.appOpen = WorkAppOpen(runEndedAt: 1, openedAt: 2)
        precondition(WorkHandoffStore.appOwner(of: "claude:8f7a53b9", in: [opened])?.id == "o", "app-owned by its short id too")
        var running = opened; running.appOpen = WorkAppOpen(); running.status = "running"
        precondition(WorkHandoffStore.serverHolds(running) && WorkHandoffStore.serverHold(onSession: "claude:8f7a53b9", in: [running])?.id == "o")
        for status in ["completed", "failed", "canceled", "refused"] {
            var ended = running; ended.status = status
            precondition(!WorkHandoffStore.serverHolds(ended), status)
        }
        var unlinked = running; unlinked.sessionID = nil
        var continued = running; continued.mode = .continueSession; continued.channel = "turn"
        precondition(!WorkHandoffStore.serverHolds(unlinked) && !WorkHandoffStore.serverHolds(continued))
        precondition(WorkHandoffStore.changesWorkSessions(from: unlinked, to: running) && WorkHandoffStore.changesWorkSessions(from: running, to: opened)
                     && !WorkHandoffStore.changesWorkSessions(from: running, to: running), "a link, and the end of the hold, change what Sessions shows")
        // Sessions and the pet: a Work session still running is held by the server (no Open in platform, no Continue).
        let liveRow = ClaudeSession(.object(["id": .string("8f7a53b9"), "name": .string("Homepage CTA"), "origin": .string("job"),
                                              "jobLabel": .string("COS server"), "state": .string("running")]))!
        let held = ClaudeSession.markingWork([liveRow], workSessionIDs: [full], runningWorkSessionIDs: [full])[0]
        let done = ClaudeSession.markingWork([liveRow], workSessionIDs: [full], runningWorkSessionIDs: [])[0]
        precondition(!held.isScheduledJob && held.workRunning && held.heldByServer && held.title == "Homepage CTA")
        precondition(!done.isScheduledJob && !done.workRunning && !done.heldByServer)
        precondition(ClaudeSession.markingWork([liveRow], workSessionIDs: [])[0].heldByServer, "a server job is always held")
        // A warm-up is known by its first prompt, never by a title someone gave the session.
        precondition(ClaudeSession(.object(["id": .string("r1"), "name": .string("Ready")]))!.isKeepWarm
                     && !ClaudeSession(.object(["id": .string("r2"), "name": .string("Ready"), "namedTitle": .bool(true)]))!.isKeepWarm)
    }

    // MARK: - Start it, then open it (0.5.249): the pure rules

    @MainActor static func appChecks() {
        let id = "9380e0d8-960f-4d68-b1f2-f604a6657ec6"
        // A session id reaches a link or a command only as a lowercase UUID.
        precondition(WorkHandoffStore.appSessionID(id) == id)
        for bad in [id.uppercased(), id + "\n", " " + id, String(id.dropLast()), id + "0", "../../etc/passwd", "abc; rm -rf ~",
                    "9380e0d8-960f-4d68-b1f2-f604a6657ec\u{E9}", "9380e0d8_960f_4d68_b1f2_f604a6657ec6", ""] {
            precondition(WorkHandoffStore.appSessionID(bad) == nil, bad)
        }
        // Codex, character by character: every reserved and non-ASCII character is encoded.
        precondition(WorkHandoffStore.codexThreadLink(threadID: id)?.absoluteString == "codex://threads/" + id)
        precondition(WorkHandoffStore.codexThreadLink(threadID: id, note: "caf\u{E9} & 100% #1 / ?x=y\nnext")?.absoluteString
                     == "codex://threads/\(id)?prompt=caf%C3%A9%20%26%20100%25%20%231%20%2F%20%3Fx%3Dy%0Anext")
        precondition(WorkHandoffStore.codexThreadLink(threadID: id, note: "")?.absoluteString == "codex://threads/" + id)
        precondition(WorkHandoffStore.codexThreadLink(threadID: "../" + id) == nil && WorkHandoffStore.codexThreadLink(threadID: id + "?prompt=x") == nil)
        // Claude: only the two links the helper gives, for this session.
        precondition(WorkHandoffStore.claudeAppLink("claude://resume?session=" + id, sessionID: id)?.absoluteString == "claude://resume?session=" + id)
        let tab = "claude://code/continue?session=local_2441104d-9cde-4948-a036-9cb4b7be8539"
        precondition(WorkHandoffStore.claudeAppLink(tab, sessionID: id)?.absoluteString == tab)
        let refused: [String?] = ["claude://resume?session=2441104d-9cde-4948-a036-9cb4b7be8539", "claude://resume?session=\(id)&q=send",
                                  "claude://code/new?folder=%2F&q=x", "claude://code/continue?session=local_\(id)&q=x",
                                  "claude://code/continue?session=\(id)", "https://claude.ai", nil]
        for bad in refused { precondition(WorkHandoffStore.claudeAppLink(bad, sessionID: id) == nil, bad ?? "nil") }
        precondition(WorkHandoffStore.claudeAppLink("claude://resume?session=../x", sessionID: "../x") == nil)
        // 0.5.253, Cursor filled in for you to send (Miles, 2026-09-30 13:27). The link, character by character; the box
        // is led by the task's first line; a handoff too long for Cursor's link is cut at the limit, never through a
        // character, keeps its status line and says so, and the whole goes on the clipboard.
        let tag = "0123456789ab", instruction = WorkProgress.instruction(tag: tag)
        precondition(WorkHandoffStore.cursorPrefillLink("caf\u{E9} & 100% #1 / ?x=y\nnext")?.absoluteString
                     == "cursor://anysphere.cursor-deeplink/prompt?text=caf%C3%A9%20%26%20100%25%20%231%20%2F%20%3Fx%3Dy%0Anext&mode=agent")
        precondition(WorkHandoffStore.cursorPrefillLink("") == nil)
        let short = "Check every heading" + instruction
        let filled = WorkHandoffStore.cursorPrefill(short, tag: tag, instruction: instruction)
        precondition(filled.whole == nil && filled.text == "COS Work handoff \(tag)\n\n" + short, filled.text)
        let long = String(repeating: "Tighten the pricing FAQ. ", count: 600) + instruction
        let cut = WorkHandoffStore.cursorPrefill(long, tag: tag, instruction: instruction)
        precondition(cut.text.utf16.count == WorkHandoffStore.cursorPrefillLimit, "\(cut.text.utf16.count)")
        precondition(cut.text.hasPrefix("COS Work handoff \(tag)\n\nTighten the pricing FAQ.") && cut.text.hasSuffix("\n\n" + WorkHandoffStore.cursorCutMarker + instruction))
        precondition(cut.whole == "COS Work handoff \(tag)\n\n" + long)
        let fits = String(repeating: "a", count: WorkHandoffStore.cursorPrefillLimit - 31 - instruction.utf16.count) + instruction
        precondition(WorkHandoffStore.cursorPrefill(fits, tag: tag, instruction: instruction).whole == nil, "exactly at the limit: not cut")
        precondition(WorkHandoffStore.cursorPrefill("b" + fits, tag: tag, instruction: instruction).whole != nil, "one over: cut")
        let faces = String(repeating: "\u{1F600}", count: 5_000) + instruction
        let cutFaces = WorkHandoffStore.cursorPrefill(faces, tag: tag, instruction: instruction)
        let keptFaces = cutFaces.text.dropFirst(31).prefix { $0 == "\u{1F600}" }
        precondition(cutFaces.text.utf16.count <= WorkHandoffStore.cursorPrefillLimit && !keptFaces.isEmpty
                     && cutFaces.text.utf16.count == 31 + keptFaces.utf16.count + ("\n\n" + WorkHandoffStore.cursorCutMarker + instruction).utf16.count,
                     "an emoji is kept whole or not at all")
        // The card says what was filled in, and how much of it when it was cut.
        precondition(WorkHandoffStore.cursorOpenedText(mode: .newSession, cut: nil) == "Opened in Cursor with the handoff filled in. Choose Create Chat, then press Send there.")
        precondition(WorkHandoffStore.cursorOpenedText(mode: .newSession, cut: (8_500, 15_031)).hasSuffix("so it holds the first 8,500 of 15,031: the whole handoff is on the clipboard. Paste it over the text there before you send."))
        // Which chat a filled-in handoff became: Cursor's, made once it opened (5 s slack), not another handoff's, oldest
        // first; and it is the one whose message carries the first line.
        let openedAt = 1_790_730_000.0
        func chatRow(_ id: String, _ provider: String = "cursor", at: Double) -> JSONValue {
            .object(["id": .string(id), "provider": .string(provider), "name": .string("Chat " + id), "createdAt": .string(WorkProgress.stamp(at))])
        }
        let chats = [chatRow("chat-new", at: openedAt + 10), chatRow("chat-old", at: openedAt - 60), chatRow("chat-claude", "claude", at: openedAt + 10),
                     chatRow("../x", at: openedAt + 10), chatRow("chat taken", at: openedAt + 3), chatRow("chat-taken", at: openedAt + 2),
                     chatRow("chat-early", at: openedAt - 4), .object(["id": .string("chat-untimed"), "provider": .string("cursor")])]
        precondition(WorkHandoffStore.cursorPrefillCandidates(chats, openedAt: openedAt, taken: ["cursor:chat-taken"]).map(\.id) == ["cursor:chat-early", "cursor:chat-new"],
                     "\(WorkHandoffStore.cursorPrefillCandidates(chats, openedAt: openedAt, taken: ["cursor:chat-taken"]).map(\.id))")
        precondition(WorkHandoffStore.carriesPrefill(tag: tag, prompts: [.init(text: "<user_query>\nCOS Work handoff \(tag)\n\nCheck", at: nil)]))
        precondition(!WorkHandoffStore.carriesPrefill(tag: tag, prompts: [.init(text: "COS Work handoff bbbbbbbbbbbb\n\nCheck", at: nil)]))
        precondition(!WorkHandoffStore.carriesPrefill(tag: tag, prompts: [.init(text: "Check every heading", at: nil)]))
        // When it opens: only once the first turn completed, after the settle, within the window, and once.
        let now = 1_790_730_000.0
        var r = WorkHandoffReceipt(id: "r", workID: "task:Quilt:0123456789ab", workTitle: "T", sourceRevision: "1", mode: .newSession,
                                   provider: "claude", modelID: "opus", sessionID: "claude:" + id, sessionTitle: "T", status: "running",
                                   detail: "", prompt: "p", createdAt: now - 100, channel: "job")
        precondition(WorkHandoffStore.appOpenStep(r, now: now) == nil, "never asked to open")
        r.appOpen = WorkAppOpen()
        precondition(WorkHandoffStore.appOpenStep(r, now: now) == .wait, "running: wait")
        // Still going waits even with an end time on record (the status decides, not the time alone).
        for status in ["running", "queued", "sending", "unknown"] {
            var x = r; x.status = status; x.appOpen?.runEndedAt = now - 60
            precondition(WorkHandoffStore.appOpenStep(x, now: now) == .wait, status)
        }
        r.status = "completed"
        precondition(WorkHandoffStore.appOpenStep(r, now: now) == .wait, "no end time yet")
        r.appOpen?.runEndedAt = now - 4
        precondition(WorkHandoffStore.appOpenStep(r, now: now) == .wait, "settling")
        precondition(WorkHandoffStore.appOpenStep(r, now: now + 1) == .open, "settled")
        precondition(WorkHandoffStore.appOpenStep(r, now: now - 4 + WorkHandoffStore.appOpenWindow + 1) == .skip("late"))
        var opened = r; opened.appOpen?.openedAt = now
        precondition(WorkHandoffStore.appOpenStep(opened, now: now + 1) == nil, "once")
        var skipped = r; skipped.appOpen?.skipped = "late"
        precondition(WorkHandoffStore.appOpenStep(skipped, now: now + 1) == nil)
        for status in ["failed", "refused", "canceled", "reviewed"] {
            var x = r; x.status = status
            precondition(WorkHandoffStore.appOpenStep(x, now: now + 1) == .skip("not_completed"), status)
        }
        var noSession = r; noSession.sessionID = nil
        precondition(WorkHandoffStore.appOpenStep(noSession, now: now + 1) == .skip("no_session"))
        // 0.5.253: Cursor runs nothing in the background, so no Cursor run opens (a 0.5.249 to 0.5.252 one included).
        noSession.provider = "cursor"
        precondition(WorkHandoffStore.appOpenStep(noSession, now: now + 1) == nil && !WorkHandoffStore.appProviders.contains("cursor"))
        var ollama = r; ollama.provider = "ollama"
        precondition(WorkHandoffStore.appOpenStep(ollama, now: now + 1) == nil)
        var turn = r; turn.mode = .continueSession
        precondition(WorkHandoffStore.appOpenStep(turn, now: now + 1) == nil)
        var tabbed = r; tabbed.channel = "tab"
        precondition(WorkHandoffStore.appOpenStep(tabbed, now: now + 1) == nil)
        // Who owns a session: one Work opened in its app, or one started from a 0.5.248 tab. Not one still running.
        precondition(WorkHandoffStore.appOwner(of: "claude:" + id, in: [r]) == nil, "not opened yet: the server may still continue it")
        precondition(WorkHandoffStore.appOwner(of: "claude:" + id, in: [opened])?.id == "r")
        precondition(WorkHandoffStore.appOwner(of: "claude:other", in: [opened]) == nil)
        tabbed.appOpen = nil
        precondition(WorkHandoffStore.appOwner(of: "claude:" + id, in: [tabbed])?.id == "r")
        // The card's button.
        precondition(WorkHandoffStore.appOpenButton(r) == nil && WorkHandoffStore.appOpenButton(opened) == "Open again")
        precondition(WorkHandoffStore.appOpenButton(skipped) == "Open in Claude")
        var running = opened; running.status = "running"
        precondition(WorkHandoffStore.appOpenButton(running) == nil, "never while running")
        var cursorSkipped = skipped; cursorSkipped.provider = "cursor"; cursorSkipped.appOpen?.folder = "/Users/x/Repo"
        precondition(WorkHandoffStore.appOpenButton(cursorSkipped) == nil, "no Terminal for a 0.5.249 to 0.5.252 Cursor run")
        var cursorOpened = opened; cursorOpened.provider = "cursor"
        precondition(WorkHandoffStore.appOpenButton(cursorOpened) == nil, "nor Open again")
        // A Cursor handoff filled in and not sent yet: Open again, until it is found.
        var waiting = r; waiting.channel = "prefill"; waiting.provider = "cursor"; waiting.appOpen = nil; waiting.status = "queued"; waiting.sessionID = nil
        precondition(WorkHandoffStore.awaitingCursorSend(waiting) && WorkHandoffStore.appOpenButton(waiting) == "Open again")
        var found = waiting; found.sessionID = "cursor:chat"; found.status = "delivered"
        precondition(!WorkHandoffStore.awaitingCursorSend(found) && WorkHandoffStore.appOpenButton(found) == nil)
        var closed = waiting; closed.status = "canceled"
        precondition(!WorkHandoffStore.awaitingCursorSend(closed) && WorkHandoffStore.appOpenButton(closed) == nil)
        var note = r; note.mode = .continueSession; note.channel = "app"; note.appOpen = nil; note.status = "queued"
        precondition(WorkHandoffStore.appOpenButton(note) == "Open again")
        note.status = "delivered"
        precondition(WorkHandoffStore.appOpenButton(note) == nil)
        // A note you send yourself in Terminal: an untimed message that newly appears.
        let text = "Now check the footer links, every one of them"
        precondition(WorkProgress.untimedArrival(prompt: text, messages: [.init(text: text, at: nil)], baseline: []))
        precondition(!WorkProgress.untimedArrival(prompt: text, messages: [.init(text: text, at: nil)], baseline: [WorkProgress.Reply(text: text, at: nil).digest]))
        precondition(!WorkProgress.untimedArrival(prompt: text, messages: [.init(text: text, at: 5)], baseline: []), "a timed message is promptArrival's")
        precondition(!WorkProgress.untimedArrival(prompt: text, messages: [.init(text: "Something else entirely, not the note", at: nil)], baseline: []))
        // Every line the card can show: plain, no em dash, no arrow.
        var lines = ["not_completed", "late", "no_session", "open_failed", WorkHandoffStore.cursorRetired, "unreachable", "claude:no_desktop", "claude:desktop_too_old",
                     "claude:archived", "claude:desktop_lineage", "claude:no_transcript", "other"].flatMap { code in
            ["claude", "codex", "cursor"].compactMap { WorkHandoffStore.appSkipText(code, provider: $0) } }
        lines += ["claude", "codex", "cursor"].flatMap { [WorkHandoffStore.openedText($0), WorkHandoffView.appOwnedNote($0)] }
        lines.append(WorkHandoffStore.unsentTabDetail)
        lines += [WorkHandoffStore.cursorOpenedText(mode: .newSession, cut: nil), WorkHandoffStore.cursorOpenedText(mode: .continueSession, cut: (1, 2)),
                  WorkHandoffView.whereItRunsNote(waiting) ?? "", WorkHandoffView.whereItRunsNote(found) ?? "", WorkRequestOrigin.cursorNeedsMac,
                  WorkHandoffStore.cursorCutMarker]
        for state in ["running", "completed"] { var x = r; x.status = state; x.appOpen?.runEndedAt = nil; lines += [WorkHandoffView.whereItRunsNote(x) ?? ""] }
        precondition(lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2192}") && !$0.contains("->") }, "\(lines)")
        precondition(WorkHandoffStore.appSkipText("no_session", provider: "cursor") == "COS could not find its Cursor chat, so nothing was opened.")
        precondition(WorkHandoffStore.openedText("cursor") == "Opened in Cursor. Continue there.")
        precondition(WorkHandoffStore.appSkipText(WorkHandoffStore.cursorRetired, provider: "cursor")
                     == "COS Control no longer opens Cursor chats in Terminal, so this one was not opened. Its reply is here. New Cursor work opens Cursor with the handoff filled in.")
    }

    // MARK: - The tracker, end to end

    @MainActor static func trackerChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-progress-checks-" + UUID().uuidString)
        let localModel = WorkModelChoice(id: "local-model", provider: "ollama", title: "Ollama", available: true, reason: nil)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = WorkSession(id: "claude:s-one", nativeID: "s-one", provider: "claude", title: "Launch copy review", summary: "", project: "Website", status: "idle")
        let two = WorkSession(id: "claude:s-two", nativeID: "s-two", provider: "claude", title: "Pricing review", summary: "", project: "Website", status: "idle")
        let idA = "0123456789ab", idB = "bbbbbbbbbbbb"
        func source(_ identity: String) -> WorkSource {
            WorkSource(id: "task:Quilt:" + identity, title: "Task " + identity, revision: "1", project: "Quilt", context: "Task " + identity)
        }
        /// A store in these checks never opens an app, runs Terminal or writes the clipboard of whoever uses the Mac: the
        /// app checks put recorders in place of these; anything else that reaches one fails here (0.5.252, measured
        /// that none did: every hook replaced by a print across this suite, run-work.sh and run-work-handoff.sh).
        func deskless(_ store: WorkHandoffStore) {
            store.openURL = { url in fatalError("a Work check reached the desktop: open \(url)") }
            store.copyToClipboard = { _ in fatalError("a Work check reached the desktop: the clipboard") }
        }
        func setUp(_ name: String) -> (WorkHandoffStore, TrackingTransport, FakeBoard, Clock, WorkProgressTracker, NoticeBox) {
            let transport = TrackingTransport()
            let store = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent(name + ".json"),
                                         transport: { args, data in try await transport.run(args, data) })
            store.sessions = [one, two]
            store.models = [localModel]
            deskless(store)
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
            store.opensInApp = false   // the background run (Settings off, or Ollama); opening in the app is test 15
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: localModel, prompt: "Go")
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
            store.opensInApp = false
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
            store.opensInApp = false
            let opus = WorkModelChoice(id: "opus", provider: "claude", title: "Opus", available: true, reason: nil)
            store.models = [opus]
            await transport.setClaudeJob(session: "e836fff6", afterReads: 99)
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
            await store.newSessionLink?.value
            let reads = await transport.count("work-job")
            check((try row(store, idA)).sessionID == nil && reads == 3, "bounded: \(reads)")

            let (done, doneTransport, _, _, _, _) = setUp("link-done")
            done.newSessionLinkDelays = [.zero, .zero, .zero]
            done.opensInApp = false
            done.models = [opus]
            await doneTransport.setClaudeJob(session: "e836fff6", afterReads: 99)
            await done.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
            await doneTransport.setJobResult("finished")
            await done.newSessionLink?.value
            let doneReads = await doneTransport.count("work-job")
            check((try row(done, idA)).status == "completed" && doneReads == 1, "a finished run is recorded once: \(doneReads)")
        }

        // 0.5.249, start it, then open it (Miles, 2026-09-29, "route 1"). The COS server runs the New session; once its
        // first reply is done Control opens it in its app, once, and never while the run is going.
        final class Opened { var urls: [URL] = []; var clipboard: [String] = [] }
        func appSetUp(_ name: String, passes: Int = 4) -> (WorkHandoffStore, TrackingTransport, FakeBoard, Clock, WorkProgressTracker, NoticeBox, Opened) {
            let (store, transport, board, clock, tracker, notices) = setUp(name)
            let opened = Opened()
            store.openURL = { opened.urls.append($0); return true }
            store.copyToClipboard = { opened.clipboard.append($0) }
            store.newSessionLinkDelays = [.zero]; store.appFollowDelay = .zero; store.appFollowPasses = passes; store.appOpenSettle = 0
            return (store, transport, board, clock, tracker, notices, opened)
        }
        let claudeID = "9380e0d8-960f-4d68-b1f2-f604a6657ec6", codexID = "01a0ef66-0b31-7c11-a469-464d5e725a01"
        let cursorID = "baf1968a-7f0e-4d58-9ebb-26d0dd1656c8"
        let opus = WorkModelChoice(id: "opus", provider: "claude", title: "Opus", available: true, reason: nil)
        let frontier = WorkModelChoice(id: "codex-frontier", provider: "codex", title: "Codex", available: true, reason: nil)
        let grok = WorkModelChoice(id: "cursor-grok", provider: "cursor", title: "Cursor", available: true, reason: nil)

        // 15. Claude: the background run starts (no tab, no link while it runs), the session opens once the first reply
        //     is done and the helper says the transcript is quiet, exactly once, and Open again focuses its tab.
        do {
            let (store, transport, board, _, tracker, _, opened) = appSetUp("app-claude")
            store.models = [opus]
            final class Links { var count = 0 }
            let links = Links()
            store.onWorkSessionsChanged = { links.count += 1 }
            await transport.setJob(provider: "claude", session: claudeID)
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Draft the CTA & ship it")
            var r = try row(store, idA)
            let workNew = await transport.count("work-new")
            check(workNew == 1 && r.channel == "job" && r.appOpen == WorkAppOpen(), "the COS server starts it: \(workNew) \(r.channel ?? "")")
            check(r.prompt.hasSuffix(WorkProgress.instruction(tag: idA)), "the handoff and its status line are unchanged")
            await store.newSessionLink?.value
            r = try row(store, idA)
            check(r.sessionID == "claude:" + claudeID && r.status == "running", "\(String(describing: r.sessionID)) \(r.status)")
            check(links.count == 1, "a link found by reading the job again is marked in Sessions at once: \(links.count)")
            check(WorkHandoffView.whereItRunsNote(r) == "Running in the background. It opens in Claude when the first reply is done.")
            await tracker.tick(); await tracker.tick()
            var reveals = await transport.count("session-reveal")
            check(opened.urls.isEmpty && reveals == 0, "never opened, nor asked about, while the run is going")
            check(WorkHandoffStore.appOpenButton(try row(store, idA)) == nil, "no Open again while it runs")
            // The first reply is done, but the helper still sees the transcript being written: wait.
            await transport.setReveal("running")
            await transport.setRead(replies: [("COS-WORK \(idA): done: drafted the CTA and checked it", stamp(r.createdAt + 5))])
            await transport.setJobResult("COS-WORK \(idA): done: drafted the CTA and checked it")
            await tracker.tick()
            r = try row(store, idA)
            reveals = await transport.count("session-reveal")
            check(r.status == "completed" && r.appOpen?.runEndedAt != nil && r.appOpen?.openedAt == nil && opened.urls.isEmpty && reveals == 1,
                  "never imported while the transcript is written: \(reveals)")
            check(WorkHandoffView.whereItRunsNote(r) == "The first reply is done. Opening it in Claude.")
            check(board.rows[idA] == "qa", "tracking is unchanged: \(board.rows)")
            // A second store on the same journal (another window), loaded before it opened.
            let (twin, twinTransport, _, _, _, _, twinOpened) = appSetUp("app-claude")
            // The helper does not answer: nothing opens, and it is asked again on the next pass (never given up on).
            await transport.setReveal("import", fails: true)
            await tracker.tick()
            r = try row(store, idA)
            check(opened.urls.isEmpty && r.appOpen?.skipped == nil && r.appOpen?.openedAt == nil, "\(String(describing: r.appOpen))")
            // Quiet: it imports as a Claude tab, once.
            await transport.setReveal("import")
            await tracker.tick()
            r = try row(store, idA)
            check(opened.urls.map(\.absoluteString) == ["claude://resume?session=" + claudeID], "\(opened.urls)")
            check(r.appOpen?.openedAt != nil && r.detail == "Opened in Claude. Continue there." && r.status == "completed")
            check(WorkHandoffView.whereItRunsNote(r) == "Opened in Claude. Continue there.")
            check(r.progress?.events.last?.text == "Opened in Claude. Continue there.", "the timeline says so")
            await tracker.tick(); await store.openReadyApps(); await store.followToApp(r.id)
            check(opened.urls.count == 1, "opened once: \(opened.urls.count)")
            // Open again focuses the Claude tab that now holds it.
            check(WorkHandoffStore.appOpenButton(r) == "Open again")
            let tab = "claude://code/continue?session=local_" + claudeID
            await transport.setReveal("desktop", link: tab)
            await store.reopenInApp(receiptID: r.id)
            check(opened.urls.map(\.absoluteString).last == tab && opened.urls.count == 2)
            // The other window still holds it as not opened, and the journal stops it opening it again.
            check(twin.receipts.first { $0.id == r.id }?.appOpen?.openedAt == nil)
            await twin.openReadyApps()
            let twinReveals = await twinTransport.count("session-reveal")
            check(twinOpened.urls.isEmpty && twinReveals == 1, "the journal records it opened: \(twinOpened.urls)")

            // Two passes at once (the follow loop and a tracker pass) open it once.
            let (race, raceTransport, _, _, _, _, raceOpened) = appSetUp("app-race", passes: 0)
            race.models = [opus]
            await raceTransport.setJob(provider: "claude", session: claudeID, afterReads: 0)
            await raceTransport.setJobResult("finished")
            await race.submit(source: source(idB), mode: .newSession, session: nil, model: opus, prompt: "Go")
            await race.newSessionLink?.value
            async let first: Void = race.openReadyApps()
            async let second: Void = race.openReadyApps()
            _ = await (first, second)
            let raceReveals = await raceTransport.count("session-reveal")
            check(raceOpened.urls.count == 1 && raceReveals == 1, "one open, and one check, for two passes: \(raceOpened.urls.count) \(raceReveals)")
        }

        // 16. Codex opens its thread once the run completed; a failed or refused run opens nothing; Settings off and
        //     Ollama stay in the background.
        do {
            let (store, transport, _, _, _, _, opened) = appSetUp("app-codex")
            store.models = [frontier]
            await transport.setJob(provider: "codex", session: codexID)
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: frontier, prompt: "Go")
            await store.newSessionLink?.value
            let stillRunning = try row(store, idA)
            check(opened.urls.isEmpty && stillRunning.status == "running", "running: nothing opened")
            await transport.setJobResult("done")
            await store.followToApp(try row(store, idA).id)
            let r = try row(store, idA)
            check(opened.urls.map(\.absoluteString) == ["codex://threads/" + codexID] && r.appOpen?.openedAt != nil, "\(opened.urls)")
            check(WorkHandoffView.whereItRunsNote(r) == "Opened in Codex. Continue there.")

            let (failed, failedTransport, _, _, _, _, failedOpened) = appSetUp("app-failed")
            failed.models = [frontier]
            await failedTransport.setJob(provider: "codex", session: codexID)
            await failedTransport.setFailed(true)
            await failed.submit(source: source(idA), mode: .newSession, session: nil, model: frontier, prompt: "Go")
            await failed.newSessionLink?.value
            let f = try row(failed, idA)
            check(f.status == "failed" && failedOpened.urls.isEmpty && f.appOpen?.skipped == "not_completed" && f.appOpen?.openedAt == nil,
                  "a failed run opens nothing: \(f.status)")
            check(WorkHandoffView.whereItRunsNote(f) == nil && WorkHandoffStore.appOpenButton(f) == nil, "the card shows the failure as before")

            let (off, offTransport, _, _, _, _, offOpened) = appSetUp("app-off")
            off.models = [frontier]; off.opensInApp = false
            await offTransport.setJob(provider: "codex", session: codexID, afterReads: 0)
            await offTransport.setJobResult("done")
            await off.submit(source: source(idA), mode: .newSession, session: nil, model: frontier, prompt: "Go")
            await off.newSessionLink?.value
            await off.openReadyApps()
            let offRow = try row(off, idA)
            check(offOpened.urls.isEmpty && offRow.appOpen == nil, "Settings off: background only, as in 0.5.247")
            check(WorkHandoffView.whereItRunsNote(try row(off, idA)) == "Ran on this Mac through COS. Open session, then Open in platform, to keep going in the Codex app.")

            let (local, localTransport, _, _, _, _, localOpened) = appSetUp("app-ollama")
            let ollama = WorkModelChoice(id: "local-model", provider: "ollama", title: "Ollama", available: true, reason: nil)
            local.models = [ollama]
            await localTransport.setJob(provider: "ollama", session: nil)
            await localTransport.setJobResult("done")
            await local.submit(source: source(idA), mode: .newSession, session: nil, model: ollama, prompt: "Go")
            await local.openReadyApps()
            let localRow = try row(local, idA)
            check(localOpened.urls.isEmpty && localRow.appOpen == nil && localRow.channel == "job", "Ollama has no app")
        }

        // 17. 0.5.253 (Miles, 2026-09-30 13:27: "If it just passes to the platform and opens the window so I can submit
        //     that is sufficient"): a Cursor New session runs nothing in the background. Cursor's own window opens with the
        //     handoff filled in, led by its first line; once it is sent the tracker finds that chat (one match, never a
        //     guess) and follows it: received moves the card to Draft, its done line to QA.
        do {
            let (store, transport, board, _, tracker, _, opened) = appSetUp("app-cursor")
            store.models = [grok]
            final class CursorLinks { var count = 0 }
            let cursorLinks = CursorLinks()
            store.onWorkSessionsChanged = { cursorLinks.count += 1 }
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: grok, prompt: "Check every heading")
            var r = try row(store, idA)
            let background = (await transport.count("work-new"), await transport.count("session-chat-send"), await transport.count("session-chat-attach"))
            check(background == (0, 0, 0), "nothing runs in the background: \(background)")
            let filled = "COS Work handoff \(idA)\n\n" + r.prompt
            check(r.prompt.hasSuffix(WorkProgress.instruction(tag: idA)), "the handoff and its status line are unchanged")
            check(opened.urls.map(\.absoluteString) == [try require(WorkHandoffStore.cursorPrefillLink(filled)).absoluteString] && opened.clipboard.isEmpty,
                  "\(opened.urls)")
            check(r.channel == "prefill" && r.status == "queued" && r.sessionID == nil && r.blocksNewHandoff && r.appOpen == nil, "\(r.channel ?? "") \(r.status)")
            check(r.detail == "Opened in Cursor with the handoff filled in. Choose Create Chat, then press Send there.", r.detail)
            check(r.progress?.events.first?.text == "Opened in Cursor, for you to send")
            check(WorkHandoffView.whereItRunsNote(r) == "Opened in Cursor for you to send. Nothing runs until you press Send there. Work follows the chat once you do.")
            check(WorkHandoffStore.appOpenButton(r) == "Open again")
            await store.reopenInApp(receiptID: r.id)
            check(opened.urls.count == 2 && opened.urls[1] == opened.urls[0], "Open again fills in the same words")
            // Not sent yet: no chat carries its first line, so nothing is linked.
            let created = r.createdAt
            func chat(_ id: String, at: Double) -> JSONValue {
                .object(["id": .string(id), "provider": .string("cursor"), "name": .string("Check every heading"), "workspace": .string("Website"),
                         "state": .string("idle"), "createdAt": .string(stamp(at))])
            }
            let otherChat = "11111111-2222-4333-8444-555555555555"
            await transport.setLiveRows([chat(cursorID, at: created + 20), chat(otherChat, at: created + 30)])
            await transport.setRead(replies: [], prompts: [("Something else entirely", nil)])
            await tracker.tick()
            r = try row(store, idA)
            check(r.status == "queued" && r.sessionID == nil && board.rows[idA] == "planned", "not sent yet: \(r.status)")
            // Two new chats carry it: never a guess. Then one (the other is older than the handoff).
            await transport.setRead(replies: [], prompts: [(String(filled.prefix(400)), nil)])
            await tracker.tick()
            r = try row(store, idA)
            check(r.sessionID == nil && cursorLinks.count == 0, "two chats with its first line: nothing linked")
            await transport.setLiveRows([chat(cursorID, at: created + 20), chat(otherChat, at: created - 60)])
            await tracker.tick()
            r = try row(store, idA)
            check(r.sessionID == "cursor:" + cursorID && r.status == "delivered" && r.detail == "Sent in Cursor. Work follows it from here."
                  && r.sessionTitle == "Check every heading" && cursorLinks.count == 1, "\(String(describing: r.sessionID)) \(r.status)")
            check(r.progress?.baseline == [] && store.sessions.contains { $0.id == "cursor:" + cursorID })
            check(WorkHandoffView.whereItRunsNote(r) == "Runs in the Cursor app, where you sent it. Open session shows it here too.")
            // Its reply (Cursor writes no times) is followed: received moves the card to Draft, the done line to QA.
            await transport.setRead(replies: [("COS-WORK \(idA): done: every heading checked", nil)], prompts: [(String(filled.prefix(400)), nil)])
            await tracker.tick(); await tracker.tick()
            r = try row(store, idA)
            check(r.progress?.receivedAt != nil && r.progress?.reported == .done && board.rows[idA] == "qa", "\(board.rows) \(String(describing: r.progress?.reported))")
            check(opened.urls.count == 2 && WorkHandoffStore.appOpenButton(r) == nil, "nothing else opens")
            // Not sending it: a Cursor chat filled in and never sent stops blocking the item.
            await store.submit(source: source(idB), mode: .newSession, session: nil, model: grok, prompt: "Another")
            let unsent = try row(store, idB)
            store.cancelAppNote(receiptID: unsent.id)
            let dropped = try row(store, idB)
            check(dropped.status == "canceled" && dropped.detail == "Not sent. You closed this Cursor chat before sending it." && !dropped.blocksNewHandoff, dropped.detail)
            // Cursor could not be opened: refused, nothing on the clipboard.
            let (shut, _, _, _, _, _, shutOpened) = appSetUp("app-cursor-shut")
            shut.models = [grok]
            shut.openURL = { _ in false }
            await shut.submit(source: source(idA), mode: .newSession, session: nil, model: grok, prompt: "Go")
            let refused = try row(shut, idA)
            check(refused.status == "refused" && refused.detail == "Cursor could not be opened. Nothing was sent." && shutOpened.clipboard.isEmpty, refused.detail)

            // A handoff too long for Cursor's link: the first 8,500 characters, led by its first line and ending with the cut
            // note and its status line; the whole goes on the clipboard, and the card says both.
            let (big, _, _, _, _, _, bigOpened) = appSetUp("app-cursor-long")
            big.models = [grok]
            await big.submit(source: source(idA), mode: .newSession, session: nil, model: grok, prompt: String(repeating: "Tighten the pricing FAQ. ", count: 600))
            let b = try row(big, idA)
            let shown = try require(bigOpened.urls.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value })
            let whole = "COS Work handoff \(idA)\n\n" + b.prompt
            check(shown.utf16.count == WorkHandoffStore.cursorPrefillLimit && shown.hasPrefix("COS Work handoff \(idA)\n\nTighten")
                  && shown.hasSuffix(WorkHandoffStore.cursorCutMarker + WorkProgress.instruction(tag: idA)), "\(shown.utf16.count)")
            check(bigOpened.clipboard == [whole], "the whole handoff is on the clipboard")
            check(b.status == "queued" && b.detail == WorkHandoffStore.cursorOpenedText(mode: .newSession, cut: (shown.count, whole.count))
                  && b.detail.contains("holds the first 8,500 of \(whole.count.formatted())"), b.detail)
            await big.reopenInApp(receiptID: b.id)
            check(bigOpened.urls.count == 2 && bigOpened.clipboard == [whole, whole], "Open again copies it again")
        }

        // 18. Continue on a session its app owns never sends a server turn: Claude and Cursor open it with the note on
        //     the clipboard, Codex with it filled in. The note is delivered when the session shows it arriving; a note
        //     you will not send can be dropped; Not done yet goes the same way.
        do {
            let (store, transport, board, _, tracker, _, opened) = appSetUp("app-continue")
            store.models = [opus]
            await transport.setJob(provider: "claude", session: claudeID, afterReads: 0)
            await transport.setJobResult("COS-WORK \(idA): done: drafted it")
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Draft the CTA")
            await store.newSessionLink?.value
            let first = try row(store, idA)
            let owned = try require(store.sessions.first { $0.id == "claude:" + claudeID })
            check(first.appOpen?.openedAt != nil && WorkHandoffStore.appOwner(of: owned.id, in: store.receipts)?.id == first.id)
            check(WorkHandoffView.appOwnedNote("claude").hasPrefix("This session is open in Claude. Continue opens it there"))
            let tab = "claude://code/continue?session=local_" + claudeID
            await transport.setReveal("desktop", link: tab)
            await store.submit(source: source(idB), mode: .continueSession, session: owned, model: nil, prompt: "Now the footer")
            var note = try row(store, idB)
            let turns = await transport.count("session-chat-attachability") + transport.count("session-chat-attach") + transport.count("session-chat-send") + transport.count("session-chat-queue")
            check(turns == 0, "no server turn into a session the app owns: \(turns)")
            check(note.channel == "app" && note.status == "queued" && note.detail == "Opened in Claude. Your note is on the clipboard. Paste it there.", note.detail)
            check(opened.urls.last?.absoluteString == tab && opened.clipboard == [note.prompt] && note.prompt.hasSuffix(WorkProgress.instruction(tag: idB)))
            check(note.blocksNewHandoff && WorkHandoffStore.appOpenButton(note) == "Open again")
            // You paste it and send it in Claude: the session shows it arriving. Delivered, received, Draft.
            await transport.setRead(replies: [("COS-WORK \(idA): done: drafted it", stamp(first.createdAt + 5))],
                                    prompts: [(String(note.prompt.prefix(80)), stamp(note.createdAt + 20))])
            await tracker.tick()
            note = try row(store, idB)
            check(note.status == "delivered" && note.detail == "Sent in Claude. Work follows it from here." && note.progress?.receivedAt != nil && board.rows[idB] == "draft",
                  "\(note.status) \(board.rows)")
            // Not done yet, on the app's session, goes the same way.
            check((try row(store, idA)).progress?.reported == .done && board.rows[idA] == "qa")
            check(await store.sendBack(receiptID: first.id, source: source(idA), missing: "The mobile layout is not checked."))
            let back = try row(store, idA)
            let turnsAfter = await transport.count("session-chat-send")
            check(back.channel == "app" && back.status == "queued" && turnsAfter == 0 && opened.clipboard.last == back.prompt, "\(back.channel ?? "") \(back.status)")
            // A note you will not send: dropped, and the item can take a new handoff.
            store.cancelAppNote(receiptID: back.id)
            check((try row(store, idA)).status == "canceled" && !store.receipts(for: "task:Quilt:" + idA).contains(where: \.blocksNewHandoff))

            // Codex: the note is filled in on the thread, nothing on the clipboard.
            let (codex, codexTransport, _, _, _, _, codexOpened) = appSetUp("app-continue-codex")
            codex.models = [frontier]
            await codexTransport.setJob(provider: "codex", session: codexID, afterReads: 0)
            await codexTransport.setJobResult("done")
            await codex.submit(source: source(idA), mode: .newSession, session: nil, model: frontier, prompt: "Go")
            await codex.newSessionLink?.value
            let thread = try require(codex.sessions.first { $0.id == "codex:" + codexID })
            await codex.submit(source: source(idB), mode: .continueSession, session: thread, model: nil, prompt: "caf\u{E9} & 100% #1 / ?x=y")
            let codexNote = try row(codex, idB)
            let encoded = try require(codexNote.prompt.addingPercentEncoding(withAllowedCharacters: WorkHandoffStore.linkQueryAllowed))
            check(codexOpened.urls.last?.absoluteString == "codex://threads/\(codexID)?prompt=" + encoded && codexOpened.clipboard.isEmpty)
            let codexTurns = await codexTransport.count("session-chat-send")
            check(codexNote.detail == "Opened in Codex with your note filled in. Press Send there." && codexTurns == 0)

            // Cursor (0.5.253): a Continue runs no turn. A new Cursor chat opens with the note filled in (Cursor's link cannot
            // open an existing chat); once it is sent there, the tracker finds that chat and follows it.
            let (cursor, cursorTransport, cursorBoard, _, cursorTracker, _, cursorOpened) = appSetUp("app-continue-cursor")
            cursor.models = [grok]
            let chat = WorkSession(id: "cursor:" + cursorID, nativeID: cursorID, provider: "cursor", title: "Mobile navigation fixes", summary: "",
                                   project: "Website", status: "idle")
            cursor.sessions.append(chat)
            await cursor.submit(source: source(idB), mode: .continueSession, session: chat, model: nil, prompt: "Now check the footer links")
            var cursorNote = try row(cursor, idB)
            let cursorTurns = await cursorTransport.count("session-chat-attachability") + cursorTransport.count("session-chat-send") + cursorTransport.count("session-chat-queue")
            check(cursorTurns == 0 && cursorNote.channel == "prefill" && cursorNote.status == "queued" && cursorNote.sessionID == nil
                  && cursorNote.sourceSessionID == chat.id && cursorNote.mode == .continueSession, "\(cursorTurns) \(cursorNote.status)")
            check(cursorNote.detail == "Opened a new Cursor chat with your note filled in (Cursor's link cannot open an existing chat). Choose Create Chat, then press Send there.",
                  cursorNote.detail)
            check(cursorNote.progress?.events.first?.text == "Opened a new Cursor chat with your note, for you to send")
            check(cursorOpened.urls.map(\.absoluteString) == [try require(WorkHandoffStore.cursorPrefillLink("COS Work handoff \(idB)\n\n" + cursorNote.prompt)).absoluteString]
                  && cursorOpened.clipboard.isEmpty, "\(cursorOpened.urls)")
            let newChat = "22222222-3333-4444-8555-666666666666"
            await cursorTransport.setLiveRows([.object(["id": .string(newChat), "provider": .string("cursor"), "name": .string("Footer links"),
                                                        "createdAt": .string(stamp(cursorNote.createdAt + 5))])])
            await cursorTransport.setRead(replies: [("COS-WORK \(idB): done: the footer links work", nil)],
                                          prompts: [("COS Work handoff \(idB)\n\nNow check the footer links", nil)])
            await cursorTracker.tick(); await cursorTracker.tick(); await cursorTracker.tick()
            cursorNote = try row(cursor, idB)
            check(cursorNote.sessionID == "cursor:" + newChat && cursorNote.status == "delivered" && cursorNote.sessionTitle == "Footer links"
                  && cursorNote.progress?.reported == .done && cursorBoard.rows[idB] == "qa",
                  "\(String(describing: cursorNote.sessionID)) \(cursorNote.status) \(String(describing: cursorNote.progress?.reported)) \(cursorBoard.rows)")
        }

        // 20. 0.5.250: a Claude New session is named after its task, and with server 6.58.2 its job names the session
        //     from the start. The receipt links it while the run is going (the link loop's first read, as in production),
        //     Sessions lists it as Work under its own title at once, and nothing else may write to it until the run
        //     finishes: no app open, no Continue. It opens in Claude once the run completed.
        do {
            let (store, transport, board, _, tracker, _, opened) = appSetUp("named-early")
            store.models = [opus, frontier, grok]
            final class Count { var changed = 0 }
            let count = Count()
            store.onWorkSessionsChanged = { count.changed += 1 }
            await transport.setJob(provider: "claude", session: claudeID, afterReads: 1)
            let titled = WorkSource(id: "task:Quilt:" + idA, title: "  Draft the homepage\n call to action, then ship it:  ",
                                    revision: "1", project: "Quilt", context: "Task")
            await store.submit(source: titled, mode: .newSession, session: nil, model: opus, prompt: "Go")
            var r = try row(store, idA)
            var names = await transport.names()
            check(names == ["Draft the homepage call to action, then ship it"], "\(names)")
            check(r.sessionID == nil && count.changed == 0, "the admission answer names no session")
            await store.newSessionLink?.value
            r = try row(store, idA)
            check(r.sessionID == "claude:" + claudeID && r.status == "running" && count.changed == 1, "linked by the first read, while it runs")
            await tracker.tick(); await tracker.tick()
            r = try row(store, idA)
            let reveals = await transport.count("session-reveal")
            check(opened.urls.isEmpty && reveals == 0 && r.appOpen?.openedAt == nil && r.appOpen?.runEndedAt == nil,
                  "a running job that names its session does not open the app")
            check(WorkHandoffView.whereItRunsNote(r) == "Running in the background. It opens in Claude when the first reply is done.")
            check(board.rows[idA] == "draft", "received: the job named its session")
            // Held by the server: Sessions marks it as Work (its own title), with no Open in platform and no Continue.
            let live = try require(ClaudeSession(.object(["id": .string(String(claudeID.prefix(8))), "name": .string("Draft the homepage call to action, then ship it"),
                                                          "origin": .string("job"), "jobLabel": .string("COS server"), "state": .string("running")])))
            let listed = ClaudeSession.markingWork([live], workSessionIDs: Set(store.receipts.compactMap(\.sessionID)),
                                                   runningWorkSessionIDs: Set(store.receipts.filter(WorkHandoffStore.serverHolds).compactMap(\.sessionID)))
            check(!listed[0].isScheduledJob && listed[0].heldByServer && listed[0].title == "Draft the homepage call to action, then ship it",
                  "Sessions: its own title, not COS server, and held")
            let running = try require(store.sessions.first { $0.id == "claude:" + claudeID })
            await store.submit(source: source("aaaaaaaaaaaa"), mode: .continueSession, session: running, model: nil, prompt: "More")
            let turns = await transport.count("session-chat-attachability") + transport.count("session-chat-send")
            check(store.receipts(for: "task:Quilt:aaaaaaaaaaaa").isEmpty && turns == 0 && store.error?.contains("still running its first turn") == true,
                  "no Continue into a session the server is still running: \(store.error ?? "")")
            await transport.setJobResult("done")
            await store.followToApp(r.id)
            check(opened.urls.map(\.absoluteString) == ["claude://resume?session=" + claudeID], "opens once the run completed")
            check(count.changed == 2 && WorkHandoffStore.serverHold(onSession: running.id, in: store.receipts) == nil,
                  "the end of the hold is marked at once: \(count.changed)")
            // Only Claude sessions carry a name: not Codex, not a fork to Codex. A fork to Claude is named after its task. (A
            // Cursor New session sends no job at all from 0.5.253: it opens Cursor, filled in.)
            await store.submit(source: source("cccccccccccc"), mode: .newSession, session: nil, model: frontier, prompt: "Go")
            await store.submit(source: source("dddddddddddd"), mode: .newSession, session: nil, model: grok, prompt: "Go")
            check(store.receipts(for: "task:Quilt:dddddddddddd").first?.channel == "prefill", "Cursor opens filled in")
            await store.forkToPlatform(source: source("eeeeeeeeeeee"), session: two, model: frontier, prompt: "Carry on")
            let codexSession = WorkSession(id: "codex:" + codexID, nativeID: codexID, provider: "codex", title: "Pricing thread", summary: "", project: "", status: "idle")
            store.sessions.append(codexSession)
            await store.forkToPlatform(source: source("ffffffffffff"), session: codexSession, model: opus, prompt: "Carry on")
            names = await transport.names()
            check(names.dropFirst() == ["<none>", "<none>", "Task ffffffffffff"], "\(names)")
        }

        // 20b. 0.5.251: the name is the task's WHOLE title. The 0.5.250 canary sent the board's 42-character display title
        //      ("Canary 0.5.250 Claude name: reply with the"). Through the real snapshot and send path: an 84-character
        //      title arrives whole; a 130-character one is cut by the same rules (100, back to the space, no trailing comma).
        do {
            let (store, transport, _, _, _, _, _) = appSetUp("named-whole")
            store.models = [opus]
            await transport.setJob(provider: "claude", session: claudeID, afterReads: 1)
            func task(_ identity: String, _ text: String) throws -> TaskRow {
                try require(TaskRow(.object(["id": .string(identity), "domain": .string("Quilt"), "title": .string(String(text.prefix(42))),
                                             "text": .string(text), "doneWhen": .string("It answers"),
                                             "workIdentity": .string(identity), "workRevision": .string(String(repeating: "a", count: 64))])))
            }
            let whole = "Canary 0.5.251 Claude name: reply with the single word ready, then wait for Miles ok"
            let long = "Canary 0.5.251 long name: reply with the single word ready, then keep this whole title as its name, and the tail past it is cut ok"
            check(whole.count == 84 && long.count == 130, "\(whole.count) \(long.count)")
            // The name drops the inline markdown the server's display title drops; an identifier keeps its underscore.
            check(WorkSource.plainTitle("**Ship** the `cos_python` fix, see [the plan](https://x.test/p) and _then_ *rest*  now")
                  == "Ship the cos_python fix, see the plan and then rest now")
            check(WorkSource.plainTitle("Run hermit_crabs_sync and keep snake_case; 2 * 3 stays plain") == "Run hermit_crabs_sync and keep snake_case; 2 3 stays plain",
                  "as the server: every asterisk goes, an underscore inside a word stays")
            let marked = WorkSource.taskSnapshot(try task("aaaaaaaaaaa0", "**Fix** the [footer links](https://x.test) in `nav.html`"))
            check(marked.sessionNameSource == "Fix the footer links in nav.html", marked.sessionNameSource)
            let first = WorkSource.taskSnapshot(try task("aaaaaaaaaaa1", whole))
            check(first.title == String(whole.prefix(42)) && first.sessionNameSource == whole, "the display title stays; the name source is whole")
            await store.submit(source: first, mode: .newSession, session: nil, model: opus, prompt: "Go")
            await store.submit(source: .taskSnapshot(try task("aaaaaaaaaaa2", long)), mode: .newSession, session: nil, model: opus, prompt: "Go")
            let names = await transport.names()
            check(names == [whole, "Canary 0.5.251 long name: reply with the single word ready, then keep this whole title as its name"],
                  "\(names)")
        }

        // 21. 0.5.250: a job that failed, was canceled or was interrupted is never linked, even when the server named its
        //     session; a job with its answer ready is. Check status links like any other read, and says so.
        do {
            for state in ["failed", "canceled", "interrupted", "answer_ready"] {
                let (store, transport, _, _, _, _, _) = appSetUp("link-" + state, passes: 0)
                store.models = [opus]; store.newSessionLinkDelays = []
                final class Marked { var count = 0 }
                let marked = Marked()
                store.onWorkSessionsChanged = { marked.count += 1 }
                await transport.setJob(provider: "claude", session: claudeID, afterReads: 0)
                await transport.setJobState(state)
                await store.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
                let r = try row(store, idA)
                check((r.sessionID != nil) == (state == "answer_ready") && marked.count == (state == "answer_ready" ? 1 : 0),
                      "\(state): \(String(describing: r.sessionID)) \(r.status) \(marked.count)")
            }
            let (store, transport, _, _, _, _, _) = appSetUp("link-check-status", passes: 0)
            store.models = [opus]; store.newSessionLinkDelays = []
            final class Seen { var changed = 0 }
            let seen = Seen()
            store.onWorkSessionsChanged = { seen.changed += 1 }
            await transport.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await store.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
            await store.newSessionLink?.value
            check((try row(store, idA)).sessionID == nil && seen.changed == 0)
            await store.refreshReceipts()
            check((try row(store, idA)).sessionID == "claude:" + claudeID && seen.changed == 1, "Check status marks the link at once: \(seen.changed)")
        }

        // 19. A 0.5.248 journal: an unsent tab reads as a handoff that never started (it no longer blocks the item), a tab
        //     it linked keeps its session, which the app owns, and neither has the new field.
        do {
            let linkedSession = "claude:" + claudeID
            let journal = """
            {"version":2,"sessions":[],"drafts":[],"receipts":[
             {"id":"aaaaaaaa-0000-4000-8000-000000000001","workID":"task:Quilt:\(idA)","workTitle":"Task","sourceRevision":"1","mode":"newSession",
              "provider":"claude","modelID":"opus","sessionTitle":"Task","status":"queued","detail":"Opened in Claude. Press Send there to start it.",
              "prompt":"Draft it","createdAt":1790720000,"channel":"tab",
              "progress":{"tag":"\(idA)","events":[{"id":"e1","at":1790720000,"kind":"sent","text":"Started a new Claude session"}],"seenReplies":[],"notified":[]}},
             {"id":"aaaaaaaa-0000-4000-8000-000000000002","workID":"task:Quilt:\(idB)","workTitle":"Task","sourceRevision":"1","mode":"newSession",
              "provider":"claude","modelID":"opus","sessionID":"\(linkedSession)","sessionTitle":"CTA draft","status":"delivered",
              "detail":"Started in Claude. Work follows it from here.","prompt":"Draft it","createdAt":1790720100,"channel":"tab",
              "progress":{"tag":"\(idB)","events":[],"seenReplies":[],"notified":[],"baseline":[]}}]}
            """
            let url = root.appendingPathComponent("from-0.5.248.json")
            try Data(journal.utf8).write(to: url)
            let transport = TrackingTransport()
            let store = WorkHandoffStore(isolated: false, storageURL: url, transport: { args, data in try await transport.run(args, data) })
            check(store.error == nil && store.receipts.count == 2, store.error ?? "")
            let unsent = try require(store.receipts.first { $0.workID == "task:Quilt:" + idA })
            check(unsent.status == "canceled" && unsent.detail == WorkHandoffStore.unsentTabDetail && !unsent.blocksNewHandoff && unsent.appOpen == nil)
            check(WorkHandoffView.whereItRunsNote(unsent) == nil && WorkHandoffStore.appOpenButton(unsent) == nil && !unsent.detail.contains("\u{2014}"))
            let linked = try require(store.receipts.first { $0.workID == "task:Quilt:" + idB })
            check(linked.status == "delivered" && WorkHandoffStore.appOwner(of: linkedSession, in: store.receipts)?.id == linked.id)
            check(WorkHandoffView.whereItRunsNote(linked) == "Runs in the Claude app, where you can work with it. Open session shows it here too.")
        }

        // 19b. 0.5.253: a 0.5.252 journal with a Cursor run still waiting to open in Terminal reads as never opening by itself,
        //      with no button (Terminal is not offered), and its reply stays; one it already opened keeps its note, with no
        //      Open again. Neither is ever asked about or opened.
        do {
            let journal = """
            {"version":2,"sessions":[],"drafts":[],"receipts":[
             {"id":"bbbbbbbb-0000-4000-8000-000000000001","workID":"task:Quilt:\(idA)","workTitle":"Task","sourceRevision":"1","mode":"newSession",
              "provider":"cursor","modelID":"cursor-grok","sessionTitle":"Task","status":"completed","detail":"Response ready for review.",
              "prompt":"Check it","createdAt":1790720000,"channel":"job","result":"COS-WORK \(idA): done: checked","appOpen":{"runEndedAt":1790720050}},
             {"id":"bbbbbbbb-0000-4000-8000-000000000002","workID":"task:Quilt:\(idB)","workTitle":"Task","sourceRevision":"1","mode":"newSession",
              "provider":"cursor","modelID":"cursor-grok","sessionID":"cursor:\(cursorID)","sessionTitle":"Task","status":"completed",
              "detail":"Opened in Terminal with cursor-agent. Continue there.","prompt":"Check it","createdAt":1790720100,"channel":"job",
              "appOpen":{"runEndedAt":1790720150,"openedAt":1790720160,"folder":"/Users/x/Repo"}}]}
            """
            let url = root.appendingPathComponent("from-0.5.252-cursor.json")
            try Data(journal.utf8).write(to: url)
            let transport = TrackingTransport()
            let store = WorkHandoffStore(isolated: false, storageURL: url, transport: { args, data in try await transport.run(args, data) })
            deskless(store)
            check(store.error == nil && store.receipts.count == 2, store.error ?? "")
            let waiting = try require(store.receipts.first { $0.workID == "task:Quilt:" + idA })
            check(waiting.appOpen?.skipped == WorkHandoffStore.cursorRetired && waiting.status == "completed" && waiting.result == "COS-WORK \(idA): done: checked")
            check(WorkHandoffStore.appOpenButton(waiting) == nil
                  && WorkHandoffView.whereItRunsNote(waiting) == WorkHandoffStore.appSkipText(WorkHandoffStore.cursorRetired, provider: "cursor"))
            let terminal = try require(store.receipts.first { $0.workID == "task:Quilt:" + idB })
            check(terminal.appOpen?.skipped == nil && terminal.appOpen?.openedAt != nil && WorkHandoffStore.appOpenButton(terminal) == nil)
            await store.openReadyApps()
            await store.reopenInApp(receiptID: waiting.id); await store.reopenInApp(receiptID: terminal.id)
            let asked = await transport.calls.count
            check(asked == 0, "never asked about or opened: \(asked)")
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

        // 22. 0.5.252: glasses requests (server 6.59.0 inbox). Control claims a pending request, re-reads the board row and
        //     its task revision, resolves the destination against its own live sessions and catalog, sends through the
        //     same paths as the Agent workspace, and reports the result under the claim token. Never twice, never late,
        //     never somewhere the request did not name.
        do {
            func request(_ id: String, identity: String = idA, revision: String? = nil, intent: String = "start",
                         mode: String = "newSession", session: String? = nil, model: String? = "opus", note: String? = nil,
                         replyTo: String? = nil, expiresIn: Double = 600, board: FakeBoard) -> JSONValue {
                var o: [String: JSONValue] = ["clientRequestId": .string(id), "domain": .string("Quilt"), "workIdentity": .string(identity),
                    "expectedTaskRevision": .string(revision ?? WorkSource.taskSnapshot(board.task(identity)).revision),
                    "intent": .string(intent), "mode": .string(mode), "destinationSource": .string("user"), "state": .string("pending"),
                    "createdAt": .string(TrackingTransport.iso(Date())), "expiresAt": .string(TrackingTransport.iso(Date().addingTimeInterval(expiresIn)))]
                if let session { o["sessionId"] = .string(session) }
                if let model { o["model"] = .string(model) }
                if let note { o["note"] = .string(note) }
                if let replyTo { o["replyTo"] = .string(replyTo) }
                return .object(o)
            }
            func live(_ transport: TrackingTransport, _ store: WorkHandoffStore) async {
                await transport.setCatalog(models: [opus, frontier, grok], sessions: [one, two])
                store.models = [opus, frontier, grok]
            }
            /// One pass of the inbox, and the send it started (the send runs in its own task).
            @discardableResult func pass(_ tracker: WorkProgressTracker) async -> Bool {
                let soon = await tracker.requests.tick()
                await tracker.requests.waitForSend()
                return soon
            }
            func lastPost(_ transport: TrackingTransport) async -> [String: String]? { await transport.inboxLog().posted.last?.body }
            let token = TrackingTransport.claimToken
            let r1 = "11111111-1111-4111-8111-111111111111", r2 = "22222222-2222-4222-8222-222222222222"
            let long = "Check the pricing table on mobile, then tighten the FAQ answers and the footer links for launch"
            // a. Start: a New session, with a note. Sent once, named after the task's whole title, recorded as from the
            //    glasses, and reported as sent with its receipt and the claim token. Nothing stays in the ledger.
            let (store, transport, board, _, tracker, _, opened) = appSetUp("glasses-start")
            board.texts[idA] = long
            await live(transport, store)
            await transport.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await transport.setInbox([request(r1, note: "Use the numbers from the 9/29 sheet.", board: board)])
            check(await pass(tracker) == true, "a request just taken lists again soon")
            let names = await transport.names()
            check(names == [long], "\(names)")
            let sent = try require(store.receipts.first { $0.requestId == r1 })
            check(sent.requestedFrom == "glasses" && sent.mode == .newSession && sent.provider == "claude" && sent.modelID == "opus")
            check(sent.prompt.contains("\n\nNote from the glasses: Use the numbers from the 9/29 sheet."), sent.prompt)
            var log = await transport.inboxLog()
            check(log.claims == [r1] && log.posted.count == 1 && log.posted[0].id == r1
                  && log.posted[0].body == ["state": "sent", "receiptId": sent.id, "claimToken": token], "\(log.posted)")
            check(opened.clipboard.isEmpty, "a glasses request never writes the Mac clipboard")
            check(tracker.requests.ledger.isEmpty && !FileManager.default.fileExists(atPath: store.requestLedgerURL.path), "a reported request leaves the ledger")
            // The receipt round-trips through the journal.
            let reread = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("glasses-start.json"),
                                          transport: { _, _ in throw HelperClientError.commandFailed("none") })
            let back = try require(reread.receipts.first { $0.id == sent.id })
            check(back.requestedFrom == "glasses" && back.requestId == r1, "requestedFrom and requestId are journaled")
            // c. Another claim won: nothing is sent and nothing is reported.
            await transport.setInbox([request(r2, identity: idB, board: board)])
            await transport.setClaim(refusal: "already_claimed")
            await pass(tracker)
            log = await transport.inboxLog()
            check(await transport.count("work-new") == 1 && log.posted.count == 1 && log.claims == [r1, r2] && tracker.requests.ledger.isEmpty,
                  "a lost claim race sends nothing")
            // d. Expired: past its expiry it is never claimed; a 410 at the claim sends nothing.
            await transport.setClaim(refusal: nil)
            await transport.setInbox([request(r2, identity: idB, expiresIn: -1, board: board)])
            await pass(tracker)
            check(await transport.inboxLog().claims == [r1, r2], "an expired request is never claimed")
            await transport.setClaim(refusal: "request_expired")
            await transport.setInbox([request(r2, identity: idB, board: board)])
            await pass(tracker)
            let postedAfter410 = await transport.inboxLog().posted.count
            check(await transport.count("work-new") == 1 && postedAfter410 == 1, "a 410 sends nothing")
            // e. Claimed too long ago, or a claim with no deadline at all: never sent.
            await transport.setClaim(refusal: nil, expiresIn: -1)
            await pass(tracker)
            var last = await lastPost(transport)
            check(await transport.count("work-new") == 1 && last == ["state": "refused", "reason": "Claimed too long ago; not sent", "claimToken": token],
                  "\(String(describing: last))")
            await transport.setClaim(refusal: nil, omitsDeadline: true)
            await transport.setInbox([request(r2, identity: idB, board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(await transport.count("work-new") == 1 && last?["reason"] == WorkRequestInbox.Refusal.noDeadline, "\(String(describing: last))")
            await transport.setClaim(refusal: nil)
            // f. The task changed after the glasses read it: refused, nothing sent. A board that could not be read is said
            //    so, never checked against the rows of an earlier read and never called a missing task.
            await transport.setInbox([request(r2, identity: idB, revision: String(repeating: "0", count: 64), board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(await transport.count("work-new") == 1 && last?["reason"] == WorkRequestInbox.Refusal.taskChanged)
            board.readable = false
            await transport.setInbox([request(r2, identity: idB, board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(await transport.count("work-new") == 1 && last?["reason"] == "COS Control could not read the board just now. Nothing was sent.",
                  "\(String(describing: last))")
            board.readable = true
            // g. The destination is gone: a session not on this Mac, a model not in the catalog.
            await transport.setInbox([request(r2, identity: idB, mode: "continueSession", session: "claude:s-gone", model: nil, board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(last?["reason"] == WorkRequestInbox.Refusal.sessionGone)
            await transport.setInbox([request(r2, identity: idB, model: "haiku", board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(last?["reason"] == WorkRequestInbox.Refusal.modelGone)
            //    A Fork to another platform whose model this Mac's catalog lacks is refused: never a copy on the session's
            //    own platform (the blocker QA found on 2026-09-30).
            await transport.setCatalog(models: [opus], sessions: [one, two])
            await transport.setInbox([request(r2, identity: idB, mode: "fork", session: one.id, model: "codex-frontier", board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            var forks = await transport.count("session-chat-fork")
            check(last?["reason"] == WorkRequestInbox.Refusal.modelGone && forks == 0 && store.receipts(for: "task:Quilt:" + idB).isEmpty,
                  "\(String(describing: last)) forks \(forks)")
            //    The same with an empty catalog, and with a catalog that could not be read (which is never an empty one).
            await transport.setCatalog(models: [], sessions: [one, two])
            await transport.setInbox([request(r2, identity: idB, mode: "fork", session: one.id, model: "codex-frontier", board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            forks = await transport.count("session-chat-fork")
            check(last?["reason"] == WorkRequestInbox.Refusal.modelGone && forks == 0, "\(String(describing: last))")
            await transport.setCatalogFails(true)
            await transport.setInbox([request(r2, identity: idB, mode: "fork", session: one.id, model: "codex-frontier", board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            forks = await transport.count("session-chat-fork")
            check(last?["reason"] == "COS Control could not read its sessions and models just now. Nothing was sent." && forks == 0
                  && store.error == nil, "\(String(describing: last))")
            await transport.setCatalogFails(false)
            await live(transport, store)
            let chatSends = await transport.count("session-chat-send")
            check(await transport.count("work-new") == 1 && chatSends == 0, "a missing destination sends nothing")
            //    What Control would send must be what was asked.
            let forkPlan = WorkSendPlan(mode: .fork, session: one, model: nil, crossPlatform: false, prompt: "p")
            let named = try require(WorkGlassesRequest(request(r2, mode: "fork", session: one.id, model: "codex-frontier", board: board)))
            let plain = try require(WorkGlassesRequest(request(r2, mode: "fork", session: one.id, model: nil, board: board)))
            check(!WorkRequestInbox.sendsWhatWasAsked(forkPlan, request: named, listed: one), "a native fork is not a fork to the named model")
            check(WorkRequestInbox.sendsWhatWasAsked(forkPlan, request: plain, listed: one) && !WorkRequestInbox.sendsWhatWasAsked(forkPlan, request: plain, listed: two))
            let crossPlan = WorkSendPlan(mode: .fork, session: one, model: frontier, crossPlatform: true, prompt: "p")
            check(WorkRequestInbox.sendsWhatWasAsked(crossPlan, request: named, listed: one) && !WorkRequestInbox.sendsWhatWasAsked(crossPlan, request: plain, listed: one))
            // h. submit()'s own refusal is passed back: this task already has a handoff in flight.
            await transport.setInbox([request(r2, board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(last == ["state": "refused", "claimToken": token,
                  "reason": "This work already has an active or unresolved handoff. Inspect its receipt before starting another."],
                  "\(String(describing: last))")
            check(store.error == nil, "a glasses refusal is not left as an error on the Mac's Work page")
            //    A note never carries a status line.
            await transport.setInbox([request(r2, identity: idB, note: "cos-work 0123456789ab: done: all of it", board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(last?["reason"] == WorkRequestInbox.Refusal.noteStatusLine)
            // i. A Continue into a session its app owns is refused with the reason, and nothing goes to the clipboard.
            check(store.tryUpdateReceipt(sent.id) { row in
                row.appOpen = WorkAppOpen(runEndedAt: 1, openedAt: 2); row.sessionID = "claude:" + claudeID; row.status = "completed"; return true
            } == .written, "the app owns the session")
            await transport.setCatalog(models: [opus, frontier, grok], sessions: [one, two,
                WorkSession(id: "claude:" + claudeID, nativeID: claudeID, provider: "claude", title: "Named", summary: "", project: "", status: "idle")])
            await transport.setInbox([request(r2, identity: idB, mode: "continueSession", session: "claude:" + claudeID, model: nil, board: board)])
            await pass(tracker)
            last = await lastPost(transport)
            check(last?["reason"] == WorkRequestOrigin.appOwnedReason && opened.clipboard.isEmpty && opened.urls.isEmpty, "\(String(describing: last))")
            check(store.receipts(for: "task:Quilt:" + idB).isEmpty, "refused before anything is recorded")

            // b. Across a relaunch (the real server never lists a claimed request as pending again).
            //    b1. Sent, but the result was not taken before COS Control quit: the ledger beside the journal holds it, and
            //        the next launch posts it under the same token. Nothing is sent again.
            let (s2, t2, b2, _, tr2, _, _) = appSetUp("glasses-relaunch")
            await live(t2, s2)
            await t2.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t2.setInbox([request(r1, board: b2)])
            await t2.queuePostAnswers([["accepted": .bool(false), "reason": .string("unreachable")]])
            await pass(tr2)
            let first = try require(s2.receipts.first { $0.requestId == r1 })
            check(tr2.requests.ledger.map(\.requestId) == [r1] && FileManager.default.fileExists(atPath: s2.requestLedgerURL.path), "kept on disk")
            let t2b = TrackingTransport()
            let s2b = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("glasses-relaunch.json"),
                                       transport: { args, data in try await t2b.run(args, data) })
            let laterClock = Clock(); laterClock.offset = 60
            let tr2b = WorkProgressTracker(store: s2b, board: b2.board, notify: { _ in }, now: { laterClock.now() })
            await t2b.setInbox([])
            await pass(tr2b)
            var relaunch = await t2b.inboxLog()
            var resent = await t2b.count("work-new")
            check(resent == 0 && relaunch.claims.isEmpty && relaunch.posted.map(\.body) == [["state": "sent", "receiptId": first.id, "claimToken": token]]
                  && tr2b.requests.ledger.isEmpty, "\(resent) \(relaunch.posted)")
            //    b2. Claimed, then COS Control quit before sending: the next launch claims it again under the stored token
            //        and sends it, once.
            func ledger(_ name: String, _ entries: [WorkRequestLedgerEntry]) throws {
                try JSONEncoder().encode(entries).write(to: root.appendingPathComponent(name + ".requests.json"))
            }
            try ledger("glasses-reclaim", [WorkRequestLedgerEntry(requestId: r2, claimToken: token, claimedAt: Date().timeIntervalSince1970)])
            let (s3c, t3c, b3c, _, tr3c, _, _) = appSetUp("glasses-reclaim")
            await live(t3c, s3c)
            await t3c.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t3c.setInbox([]); await t3c.setClaimed([request(r2, board: b3c)])
            await pass(tr3c)
            relaunch = await t3c.inboxLog()
            resent = await t3c.count("work-new")
            let reclaimed = try require(s3c.receipts.first { $0.requestId == r2 })
            check(resent == 1 && relaunch.claimTokens == [token] && relaunch.posted.map(\.body) == [["state": "sent", "receiptId": reclaimed.id, "claimToken": token]],
                  "\(resent) \(relaunch.claimTokens) \(relaunch.posted)")
            //    b3. Sent, then COS Control quit before it recorded the result: claimed again, found in the journal, reported,
            //        never sent twice (even though its first handoff finished and the task could take another).
            check(s3c.tryUpdateReceipt(reclaimed.id) { row in row.status = "completed"; row.appOpen = nil; return true } == .written)
            try ledger("glasses-reclaim", [WorkRequestLedgerEntry(requestId: r2, claimToken: token, claimedAt: Date().timeIntervalSince1970)])
            let t3d = TrackingTransport()
            let s3d = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("glasses-reclaim.json"),
                                       transport: { args, data in try await t3d.run(args, data) })
            let tr3d = WorkProgressTracker(store: s3d, board: b3c.board, notify: { _ in })
            await live(t3d, s3d)
            await t3d.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t3d.setInbox([]); await t3d.setClaimed([request(r2, board: b3c)])
            await pass(tr3d)
            resent = await t3d.count("work-new")
            last = await lastPost(t3d)
            check(resent == 0 && s3d.receipts(for: "task:Quilt:" + idA).count == 1 && last == ["state": "sent", "receiptId": reclaimed.id, "claimToken": token],
                  "never sent twice across a relaunch: \(resent) \(String(describing: last))")
            //    b4. The claim is gone by the next launch and nothing was sent: that is what is reported.
            try ledger("glasses-gone", [WorkRequestLedgerEntry(requestId: r1, claimToken: token, claimedAt: Date().timeIntervalSince1970)])
            let (s3e, t3e, _, _, tr3e, _, _) = appSetUp("glasses-gone")
            await live(t3e, s3e)
            await t3e.setInbox([])
            await pass(tr3e); await pass(tr3e)
            resent = await t3e.count("work-new")
            last = await lastPost(t3e)
            check(resent == 0 && last == ["state": "refused", "reason": WorkRequestInbox.Refusal.restarted, "claimToken": token], "\(String(describing: last))")

            // g2. A running Claude session the live list gives by its first 8 characters is the session the glasses named
            //     in full: the request goes to it.
            let (s9, t9, b9, _, tr9, _, _) = appSetUp("glasses-short-id")
            let fullID = "8f7a53b9-b478-4d88-88e4-4a915b256da5"
            let short = WorkSession(id: "claude:8f7a53b9", nativeID: "8f7a53b9", provider: "claude", title: "Homepage CTA", summary: "", project: "", status: "running")
            await t9.setCatalog(models: [opus], sessions: [short]); s9.models = [opus]
            await t9.setInbox([request(r2, mode: "continueSession", session: "claude:" + fullID, model: nil, board: b9)])
            await pass(tr9)
            let toShort = try require(s9.receipts.first { $0.requestId == r2 })
            check(toShort.sessionID == short.id && toShort.mode == .continueSession, "\(String(describing: toShort.sessionID))")
            last = await lastPost(t9)
            check(last?["state"] == "sent")

            // j. Not done yet, with replyTo: the same session continues with the note, and the reply it answers is marked
            //    reviewed only once that is on its way.
            let (s3, t3, b3, _, tr3, _, _) = appSetUp("glasses-not-done")
            await t3.setCatalog(models: [opus], sessions: [one, two]); s3.models = [opus]
            let snapshot = WorkSource.taskSnapshot(b3.task(idA))
            await s3.submit(source: snapshot, mode: .continueSession, session: one, model: nil, prompt: "Draft the CTA")
            await t3.setTurn("completed")
            let firstSend = try require(s3.receipts(for: snapshot.id).first)
            await t3.setRead(replies: [("COS-WORK \(idA): done: Updated the hero CTA.", stamp(firstSend.createdAt + 0.001))])
            await tr3.tick()
            let done = try require(s3.receipts(for: snapshot.id).first)
            check(done.progress?.reported == .done && done.status == "delivered", "\(done.status)")
            //    Refused (the session cannot be continued now): the old reply stays delivered and reported; nothing is lost.
            await t3.setAttach(attachable: false)
            await t3.setInbox([request(r1, intent: "notDone", mode: "continueSession", session: one.id, model: nil,
                                       note: "The mobile layout is not checked.", replyTo: done.id, board: b3)])
            await pass(tr3)
            let refusedTry = try require(s3.receipts.first { $0.requestId == r1 })
            let kept = try require(s3.receipts.first { $0.id == done.id })
            last = await lastPost(t3)
            check(refusedTry.status == "refused" && kept.status == "delivered" && kept.progress?.reported == .done
                  && last?["state"] == "refused" && last?["receiptId"] == refusedTry.id, "a refused send-back leaves the reply as it was: \(kept.status)")
            await t3.setAttach(attachable: true)
            //    (The refused try is now the task's newest handoff, so the Mac sends it back, through the same path.)
            check(await s3.sendBack(receiptID: done.id, source: snapshot, missing: "The mobile layout is not checked.",
                                    origin: WorkRequestOrigin(requestID: r2, deadline: Date().addingTimeInterval(600))))
            let fresh = try require(s3.receipts.first { $0.requestId == r2 })
            check(fresh.id != done.id && fresh.requestedFrom == "glasses" && fresh.sessionID == one.id
                  && fresh.prompt.hasPrefix("Not done yet. Your status line said: \u{201C}Updated the hero CTA.\u{201D}\nWhat is missing: The mobile layout is not checked."),
                  fresh.prompt)
            check(s3.receipts.first { $0.id == done.id }?.status == "reviewed", "reviewed once the send-back is on its way")
            //    Through the inbox, on a fresh task: sent, reviewed, reported.
            let (s3b, t3b, b3b, _, tr3b, _, _) = appSetUp("glasses-not-done-inbox")
            await t3b.setCatalog(models: [opus], sessions: [one, two]); s3b.models = [opus]
            let snapshotB = WorkSource.taskSnapshot(b3b.task(idA))
            await s3b.submit(source: snapshotB, mode: .continueSession, session: one, model: nil, prompt: "Draft the CTA")
            await t3b.setTurn("completed")
            let firstB = try require(s3b.receipts(for: snapshotB.id).first)
            await t3b.setRead(replies: [("COS-WORK \(idA): done: Updated the hero CTA.", stamp(firstB.createdAt + 0.001))])
            await tr3b.tick()
            let doneB = try require(s3b.receipts(for: snapshotB.id).first)
            await t3b.setInbox([request(r1, intent: "notDone", mode: "continueSession", session: one.id, model: nil,
                                        note: "The mobile layout is not checked.", replyTo: doneB.id, board: b3b)])
            await pass(tr3b)
            let freshB = try require(s3b.receipts(for: snapshotB.id).first)
            last = await lastPost(t3b)
            check(freshB.id != doneB.id && freshB.requestId == r1 && s3b.receipts.first { $0.id == doneB.id }?.status == "reviewed"
                  && last == ["state": "sent", "receiptId": freshB.id, "claimToken": token], "\(String(describing: last))")
            // j2. Reply by voice, on a session that asked a question: the answer goes back to that session, quoted with it.
            let (s8, t8, b8, _, tr8, _, _) = appSetUp("glasses-reply")
            await t8.setCatalog(models: [opus], sessions: [one, two]); s8.models = [opus]
            let asked = WorkSource.taskSnapshot(b8.task(idA))
            await s8.submit(source: asked, mode: .continueSession, session: one, model: nil, prompt: "Draft the FAQ")
            await t8.setTurn("completed")
            let question = try require(s8.receipts(for: asked.id).first)
            await t8.setRead(replies: [("COS-WORK \(idA): needs input: Which plan should the FAQ quote?", stamp(question.createdAt + 0.001))])
            await tr8.tick()
            let waiting = try require(s8.receipts(for: asked.id).first)
            check(waiting.progress?.reported == .needsInput && s8.replySession(for: waiting)?.id == one.id, "\(String(describing: waiting.progress?.reported))")
            await t8.setInbox([request(r2, intent: "reply", mode: "continueSession", session: one.id, model: nil,
                                       note: "The $29 plan.", replyTo: waiting.id, board: b8)])
            await pass(tr8)
            let answered = try require(s8.receipts(for: asked.id).first)
            check(answered.id != waiting.id && answered.requestId == r2 && answered.sessionID == one.id
                  && answered.prompt.hasPrefix("You asked: \u{201C}Which plan should the FAQ quote?\u{201D}\nMy answer: The $29 plan."), answered.prompt)
            let answeredOld = try require(s8.receipts.first { $0.id == waiting.id })
            check(answeredOld.status == "reviewed" && answeredOld.progress?.events.last?.text == "You replied: \u{201C}The $29 plan.\u{201D}")
            last = await lastPost(t8)
            check(last == ["state": "sent", "receiptId": answered.id, "claimToken": token])
            // A reply that names an older handoff sends nothing.
            await t8.setInbox([request(r1, intent: "reply", mode: "continueSession", session: one.id, model: nil,
                                       note: "Again.", replyTo: waiting.id, board: b8)])
            await pass(tr8)
            last = await lastPost(t8)
            check(last?["reason"] == WorkRequestInbox.Refusal.replyTarget)

            // k. An older server has no inbox (404): no banner, and no more lists until its version changes or ten minutes
            //    have passed (a server whose version is not on record is still asked again).
            let (s4, t4, _, clock4, tr4, _, _) = appSetUp("glasses-old-server")
            final class Version { var value = "6.58.2" }
            let version = Version()
            tr4.requests.serverVersion = { version.value }
            await t4.setInbox([], reason: "server_too_old")
            check(await pass(tr4) == false && s4.error == nil)
            await pass(tr4); await pass(tr4)
            check(await t4.inboxLog().lists == 1, "quiet while nothing changed")
            version.value = "6.59.0"
            await t4.setInbox([])
            await pass(tr4)
            check(await t4.inboxLog().lists == 2, "asked again after an update")
            version.value = "6.58.2"
            await t4.setInbox([], reason: "server_too_old")
            await pass(tr4); await pass(tr4)
            check(await t4.inboxLog().lists == 3, "a rollback is asked once, then quiet")
            clock4.offset += 599
            await pass(tr4)
            check(await t4.inboxLog().lists == 3, "still quiet at 9 minutes 59")
            clock4.offset += 2
            await pass(tr4)
            check(await t4.inboxLog().lists == 4, "asked again after ten minutes, whatever the version")
            check(WorkRequestInbox.asksAgain(offVersion: "", since: Date(), version: "", now: Date().addingTimeInterval(600))
                  && !WorkRequestInbox.asksAgain(offVersion: "", since: Date(), version: "", now: Date().addingTimeInterval(599)))

            // l. A result the server did not take is posted again with a growing wait (5 s, 10 s, ... at most 30 minutes),
            //    and dropped after a day.
            let (s5, t5, b5, clock5, tr5, _, _) = appSetUp("glasses-retry")
            await live(t5, s5)
            await t5.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t5.setInbox([request(r2, board: b5)])
            let unreachable: [String: JSONValue] = ["accepted": .bool(false), "reason": .string("unreachable")]
            await t5.queuePostAnswers([unreachable, unreachable, unreachable])
            await pass(tr5)
            await t5.setInbox([])
            check(tr5.requests.ledger.first?.attempts == 1, "kept for a later pass")
            await pass(tr5)
            var posts = await t5.inboxLog().posted.count
            check(posts == 1, "not posted again before its wait is over: \(posts)")
            clock5.offset += 6
            await pass(tr5)
            posts = await t5.inboxLog().posted.count
            check(posts == 2 && tr5.requests.ledger.first?.attempts == 2, "posted again after 5 s: \(posts)")
            clock5.offset += 6
            await pass(tr5)
            posts = await t5.inboxLog().posted.count
            check(posts == 2, "the second wait is 10 s: \(posts)")
            clock5.offset += 5
            await pass(tr5)
            posts = await t5.inboxLog().posted.count
            check(posts == 3 && tr5.requests.ledger.first?.attempts == 3, "\(posts)")
            clock5.offset += 21
            await pass(tr5)
            posts = await t5.inboxLog().posted.count
            let retriedNew = await t5.count("work-new")
            check(posts == 4 && retriedNew == 1 && tr5.requests.ledger.isEmpty, "taken on the fourth post, sent once: \(posts)")
            check(WorkRequestInbox.retryDelay(attempts: 1) == 5 && WorkRequestInbox.retryDelay(attempts: 2) == 10
                  && WorkRequestInbox.retryDelay(attempts: 9) == 1_280 && WorkRequestInbox.retryDelay(attempts: 10) == 1_800
                  && WorkRequestInbox.retryDelay(attempts: 60) == 1_800, "5 s, doubling, at most 30 minutes")
            //    After a day it is dropped, not posted.
            try ledger("glasses-stale", [WorkRequestLedgerEntry(requestId: r1, claimToken: token, claimedAt: Date().timeIntervalSince1970 - 86_401,
                                                                result: ["state": "sent", "receiptId": "r-old"])])
            let (_, t5b, _, _, tr5b, _, _) = appSetUp("glasses-stale")
            await t5b.setInbox([])
            await pass(tr5b)
            posts = await t5b.inboxLog().posted.count
            check(posts == 0 && tr5b.requests.ledger.isEmpty, "a day old: dropped")

            // m. A refused admission is refused with its receipt, never sent; an unknown delivery is unresolved.
            let (s6, t6, b6, _, tr6, _, _) = appSetUp("glasses-refused")
            await live(t6, s6)
            await t6.setNewAnswer(http: 422)
            await t6.setInbox([request(r2, board: b6)])
            await pass(tr6)
            let refusedRow = try require(s6.receipts.first { $0.requestId == r2 })
            let refusedPost = await lastPost(t6)
            check(refusedRow.status == "refused" && refusedPost == ["state": "refused", "reason": refusedRow.detail, "receiptId": refusedRow.id,
                  "claimToken": token], "\(refusedRow.status) \(String(describing: refusedPost))")
            let (s7, t7, b7, _, tr7, _, _) = appSetUp("glasses-unknown")
            await live(t7, s7)
            await t7.setJobState("mystery")
            await t7.setInbox([request(r2, board: b7)])
            await pass(tr7)
            let unknownRow = try require(s7.receipts.first { $0.requestId == r2 })
            let unknownPost = await lastPost(t7)
            check(unknownRow.status == "unknown" && unknownPost == ["state": "unresolved", "receiptId": unknownRow.id, "claimToken": token],
                  "\(unknownRow.status)")

            // n. The list keeps its rhythm while a send is in flight (it is what tells the server COS Control is here), and
            //    the send does not take the store's `busy`: the Agent workspace stays usable, a draft edit made meanwhile
            //    is kept, and a send from the Mac is told to wait.
            let (s10, t10, b10, _, tr10, _, _) = appSetUp("glasses-heartbeat")
            await live(t10, s10)
            await t10.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t10.setDelay("work-new", seconds: 0.5)
            await t10.setInbox([request(r1, board: b10), request(r2, identity: idB, board: b10)])
            await tr10.requests.tick()
            try await Task.sleep(for: .milliseconds(150))
            check(tr10.requests.sending && !s10.busy && s10.quietSend, "the send runs in its own task and does not take busy")
            await tr10.requests.tick()
            var beat = await t10.inboxLog()
            check(beat.lists == 2 && beat.claims == [r1], "listed again during the send; the next request waits: \(beat.lists) \(beat.claims)")
            let other = source("cccccccccccc")
            var edit = s10.draft(for: other); edit.prompt = "Typed while the glasses' send was on the wire"
            check(s10.updateDraft(edit, for: other) && s10.error == nil, "a draft edit during the send is kept: \(s10.error ?? "")")
            await s10.submit(source: other, mode: .newSession, session: nil, model: opus, prompt: "From the Mac")
            check(s10.error == WorkRequestOrigin.macBusyReason && s10.receipts(for: other.id).isEmpty, "a Mac send waits, and says so")
            await tr10.requests.waitForSend()
            check(s10.error == WorkRequestOrigin.macBusyReason, "and that line is still there once the glasses send reported (QA round 2): \(s10.error ?? "")")
            let kept10 = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("glasses-heartbeat.json"),
                                          transport: { _, _ in throw HelperClientError.commandFailed("none") })
            check(kept10.draft(for: other).prompt == "Typed while the glasses' send was on the wire", "and written once the send lets go")
            await pass(tr10)
            beat = await t10.inboxLog()
            check(beat.claims == [r1, r2] && s10.receipts.contains { $0.requestId == r2 }, "the waiting request is taken next")

            // p. A New session the glasses started stays in the background (Miles, 2026-09-30): its app is never opened by
            //    itself and its session is never asked about, so the server keeps it and the glasses can reply. The card's
            //    Open in Claude still opens it, and from then its app owns it. One started on the Mac still opens.
            let (s13, t13, b13, _, tr13, _, opened13) = appSetUp("glasses-background")
            await live(t13, s13)
            await t13.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t13.setInbox([request(r1, board: b13)])
            await pass(tr13)
            await s13.newSessionLink?.value
            await t13.setJobResult("done")
            let quietID = try require(s13.receipts.first { $0.requestId == r1 }).id
            await s13.followToApp(quietID)
            await tr13.tick(); await tr13.tick()
            var background = try require(s13.receipts.first { $0.id == quietID })
            var reveals = await t13.count("session-reveal")
            check(background.status == "completed" && background.sessionID == "claude:" + claudeID && opened13.urls.isEmpty && reveals == 0
                  && background.appOpen?.openedAt == nil, "not opened by itself: \(opened13.urls) reveals \(reveals) \(background.status)")
            check(WorkHandoffStore.appOwner(of: "claude:" + claudeID, in: s13.receipts) == nil, "the app does not own it, so the glasses can reply")
            check(WorkHandoffView.glassesMark(background) == " · from the glasses · not opened in its app"
                  && WorkHandoffView.whereItRunsNote(background) == "Started from the glasses, so it was not opened in its app."
                  && WorkHandoffStore.appOpenButton(background) == "Open in Claude", "\(String(describing: WorkHandoffStore.appOpenButton(background)))")
            await s13.reopenInApp(receiptID: quietID)
            background = try require(s13.receipts.first { $0.id == quietID })
            check(opened13.urls.map(\.absoluteString) == ["claude://resume?session=" + claudeID] && background.appOpen?.openedAt != nil
                  && WorkHandoffStore.appOwner(of: "claude:" + claudeID, in: s13.receipts)?.id == quietID
                  && WorkHandoffView.glassesMark(background) == " · from the glasses", "opened from the card: its app owns it from then")
            let (s14, t14, _, _, _, _, opened14) = appSetUp("mac-still-opens")
            s14.models = [opus]
            await t14.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await s14.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go")
            await s14.newSessionLink?.value
            await t14.setJobResult("done")
            await s14.followToApp(try row(s14, idA).id)
            reveals = await t14.count("session-reveal")
            check(opened14.urls.map(\.absoluteString) == ["claude://resume?session=" + claudeID] && reveals >= 1, "a Mac New session still opens: \(opened14.urls)")

            // o. The claim's deadline is checked again immediately before each wire send: work-new, a native fork, a turn,
            //    and a queued turn. Past it the receipt is refused and nothing goes on the wire.
            let (s11, t11, _, _, _, _, _) = appSetUp("glasses-wire-deadline")
            await live(t11, s11)
            let late = WorkRequestOrigin(requestID: r1, deadline: Date().addingTimeInterval(-1))
            await s11.submit(source: source("aaaaaaaaaaaa"), mode: .newSession, session: nil, model: opus, prompt: "Go", origin: late)
            await s11.submit(source: source("bbbbbbbbbbbb"), mode: .fork, session: one, model: nil, prompt: "Go", origin: late)
            await s11.submit(source: source("cccccccccccc"), mode: .continueSession, session: one, model: nil, prompt: "Go", origin: late)
            await t11.setAttach(attachable: false, reason: "native_thread_working")
            await s11.submit(source: source("dddddddddddd"), mode: .continueSession, session: two, model: nil, prompt: "Go", origin: late)
            let wire = (await t11.count("work-new"), await t11.count("session-chat-fork"), await t11.count("session-chat-send"), await t11.count("session-chat-queue"))
            check(wire == (0, 0, 0, 0), "nothing on the wire past the deadline: \(wire)")
            check(s11.receipts.count == 4 && s11.receipts.allSatisfy { $0.status == "refused" && $0.detail == "Claimed too long ago; not sent" && $0.requestedFrom == "glasses" },
                  "\(s11.receipts.map(\.status))")
            //    A late request never binds a session (QA round 2): past the deadline the session is not even asked about.
            let asked11 = (await t11.count("session-chat-attachability"), await t11.count("session-chat-attach"))
            check(asked11 == (0, 0), "a late request never asks about or attaches a session: \(asked11)")
            //    A deadline that passes while the session is being asked about stops the attach, or the queued turn; one
            //    that passes during the attach stops the turn.
            let (s25, t25, _, _, _, _, _) = appSetUp("glasses-deadline-mid-continue")
            await live(t25, s25)
            await t25.setDelay("session-chat-attachability", seconds: 0.4)
            await s25.submit(source: source("aaaaaaaaaaaa"), mode: .continueSession, session: one, model: nil, prompt: "Go",
                             origin: WorkRequestOrigin(requestID: "mid-1", deadline: Date().addingTimeInterval(0.2)))
            let afterAsk = (await t25.count("session-chat-attachability"), await t25.count("session-chat-attach"))
            check(afterAsk == (1, 0), "late once the session was asked about: no attach \(afterAsk)")
            await t25.setAttach(attachable: false, reason: "native_thread_working")
            await s25.submit(source: source("bbbbbbbbbbbb"), mode: .continueSession, session: two, model: nil, prompt: "Go",
                             origin: WorkRequestOrigin(requestID: "mid-2", deadline: Date().addingTimeInterval(0.2)))
            check(await t25.count("session-chat-queue") == 0, "late once the session was asked about: no queued turn")
            await t25.setAttach(attachable: true)
            await t25.setDelay("session-chat-attachability", seconds: 0)
            await t25.setDelay("session-chat-attach", seconds: 0.4)
            await s25.submit(source: source("cccccccccccc"), mode: .continueSession, session: one, model: nil, prompt: "Go",
                             origin: WorkRequestOrigin(requestID: "mid-3", deadline: Date().addingTimeInterval(0.2)))
            let mid = (await t25.count("session-chat-attachability"), await t25.count("session-chat-attach"),
                       await t25.count("session-chat-queue"), await t25.count("session-chat-send"))
            check(mid == (3, 1, 0, 0), "late during the attach: no turn \(mid)")
            check(s25.receipts.count == 3 && s25.receipts.allSatisfy { $0.status == "refused" && $0.detail == WorkRequestOrigin.lateReason },
                  "\(s25.receipts.map(\.status)) \(s25.receipts.map(\.detail))")
            //    In time, each of the four does go on the wire.
            let (s12, t12, _, _, _, _, _) = appSetUp("glasses-wire-in-time")
            await live(t12, s12)
            let inTime = WorkRequestOrigin(requestID: r2, deadline: Date().addingTimeInterval(600))
            await s12.submit(source: source("aaaaaaaaaaaa"), mode: .newSession, session: nil, model: opus, prompt: "Go", origin: inTime)
            await s12.submit(source: source("bbbbbbbbbbbb"), mode: .fork, session: one, model: nil, prompt: "Go", origin: inTime)
            await s12.submit(source: source("cccccccccccc"), mode: .continueSession, session: one, model: nil, prompt: "Go", origin: inTime)
            await t12.setAttach(attachable: false, reason: "native_thread_working")
            await s12.submit(source: source("dddddddddddd"), mode: .continueSession, session: two, model: nil, prompt: "Go", origin: inTime)
            let onWire = (await t12.count("work-new"), await t12.count("session-chat-fork"), await t12.count("session-chat-send"), await t12.count("session-chat-queue"))
            check(onWire == (1, 1, 1, 1), "\(onWire)")

            let r3 = "33333333-3333-4333-8333-333333333333", r4 = "44444444-4444-4444-8444-444444444444"
            // q. A request type this build does not know is refused, never read as Start; so is one that names none.
            let (s16, t16, b16, _, tr16, _, _) = appSetUp("glasses-unknown-intent")
            await live(t16, s16)
            await t16.setInbox([request(r1, intent: "archive", board: b16)])
            await pass(tr16)
            last = await lastPost(t16)
            var started = await t16.count("work-new")
            check(last == ["state": "refused", "reason": "COS Control does not know this request type. Nothing was sent.", "claimToken": token]
                  && started == 0 && s16.receipts.isEmpty, "an unknown intent is refused: \(String(describing: last)) \(started)")
            var bare = try require(request(r2, board: b16).object)
            bare["intent"] = nil
            await t16.setInbox([.object(bare)])
            await pass(tr16)
            last = await lastPost(t16)
            started = await t16.count("work-new")
            check(last?["reason"] == WorkRequestInbox.Refusal.unknownIntent && started == 0, "no intent is not Start: \(String(describing: last))")
            check(WorkRequestInbox.knownIntents == ["start", "reply", "notDone"])

            // r. A complete task takes nothing: a checked row, and a row in the Complete column. (The checked row sits in QA:
            //    a row with no stage of its own reads a check as Complete, which would test the column twice. The mutation
            //    gate found that on 2026-09-30.)
            b16.rows[idB] = "qa"; b16.checked[idB] = true
            await t16.setInbox([request(r3, identity: idB, board: b16)])
            await pass(tr16)
            last = await lastPost(t16)
            started = await t16.count("work-new")
            check(last == ["state": "refused", "reason": "This task is complete. Nothing was sent.", "claimToken": token] && started == 0,
                  "a checked task is refused: \(String(describing: last))")
            b16.rows[idB] = "complete"; b16.checked[idB] = false
            await t16.setInbox([request(r4, identity: idB, board: b16)])
            await pass(tr16)
            last = await lastPost(t16)
            started = await t16.count("work-new")
            check(last?["reason"] == WorkRequestInbox.Refusal.taskComplete && started == 0 && s16.receipts.isEmpty,
                  "a task in Complete is refused: \(String(describing: last))")

            // s. What is reported is the receipt's own state: failed, canceled and refused are refused (with the receipt);
            //    a send still going or not confirmed is unresolved; only one on its way is sent.
            var shape = sent
            for status in ["refused", "failed", "canceled"] {
                shape.status = status; shape.detail = "Why: " + status
                check(WorkRequestOutcome.from(shape) == .refused(reason: "Why: " + status, receiptID: sent.id), "\(status) is never reported as sent")
            }
            shape.detail = ""
            check(WorkRequestOutcome.from(shape) == .refused(reason: "Not sent.", receiptID: sent.id), "a refusal always carries words")
            for status in ["unknown", "sending"] {
                shape.status = status
                check(WorkRequestOutcome.from(shape) == .unresolved(receiptID: sent.id), "\(status) is unresolved, never sent")
            }
            for status in ["running", "queued", "delivered", "completed", "reviewed"] {
                shape.status = status
                check(WorkRequestOutcome.from(shape) == .sent(receiptID: sent.id), "\(status) is sent")
            }
            //    Through the inbox: a run the provider failed, and one that was canceled, are reported refused.
            for (name, state) in [("glasses-failed", "failed"), ("glasses-canceled", "canceled")] {
                let (sf, tf, bf, _, trf, _, _) = appSetUp(name)
                await live(tf, sf)
                await tf.setJob(provider: "claude", session: nil)
                if state == "failed" { await tf.setFailed(true) } else { await tf.setJobState(state) }
                await tf.setInbox([request(r1, board: bf)])
                await pass(trf)
                let ended = try require(sf.receipts.first { $0.requestId == r1 })
                let reported = await lastPost(tf)
                check(ended.status == state && reported?["state"] == "refused" && reported?["receiptId"] == ended.id,
                      "\(state): receipt \(ended.status), reported \(String(describing: reported))")
            }

            // t. A result the server could not take just now (5xx, 429) is posted again; one it never will take (the claim
            //    ended) is dropped at once and never posted again.
            let (s17, t17, b17, clock17, tr17, _, _) = appSetUp("glasses-result-status")
            await live(t17, s17)
            await t17.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t17.setInbox([request(r1, board: b17)])
            await t17.queuePostAnswers([
                ["accepted": .bool(false), "reason": .string("http_500"), "httpStatus": .number(500)],
                ["accepted": .bool(false), "reason": .string("rate_limited"), "httpStatus": .number(429)],
                ["accepted": .bool(false), "reason": .string("claim_token_mismatch"), "httpStatus": .number(409)],
            ])
            var lines17: [String] = []
            tr17.requests.onLog = { lines17.append($0) }
            await pass(tr17)
            await t17.setInbox([])
            check(tr17.requests.ledger.first?.attempts == 1, "a 500 is kept for another post")
            clock17.offset += 6
            await pass(tr17)
            var posts17 = await t17.inboxLog().posted.count
            check(posts17 == 2 && tr17.requests.ledger.first?.attempts == 2, "a 429 is kept for another post: \(posts17)")
            clock17.offset += 11
            await pass(tr17)
            posts17 = await t17.inboxLog().posted.count
            check(posts17 == 3 && tr17.requests.ledger.isEmpty && !FileManager.default.fileExists(atPath: s17.requestLedgerURL.path),
                  "a result the server will never take is given up: \(posts17) \(tr17.requests.ledger)")
            clock17.offset += 4_000
            await pass(tr17); await pass(tr17)
            posts17 = await t17.inboxLog().posted.count
            let sentOnce = await t17.count("work-new")
            check(posts17 == 3 && sentOnce == 1, "and never posted again: \(posts17)")
            check(WorkHandoffStore.resultCanPass(reason: "http_500", status: 500) && WorkHandoffStore.resultCanPass(reason: "http_503", status: 503)
                  && WorkHandoffStore.resultCanPass(reason: "rate_limited", status: 429) && WorkHandoffStore.resultCanPass(reason: "unreachable", status: 0)
                  && WorkHandoffStore.resultCanPass(reason: "server_too_old", status: 404))
            check(!WorkHandoffStore.resultCanPass(reason: "claim_token_mismatch", status: 409) && !WorkHandoffStore.resultCanPass(reason: "request_expired", status: 410)
                  && !WorkHandoffStore.resultCanPass(reason: "request_not_found", status: 404) && !WorkHandoffStore.resultCanPass(reason: "invalid_request", status: 400))
            //    Telemetry: the retries are one line, not one per post; the give-up is one line.
            let retryLines = lines17.filter { $0.contains("result not taken yet") }
            let goneLines = lines17.filter { $0.contains("not retried") }
            check(retryLines.count == 1 && retryLines[0].contains(r1) && retryLines[0].contains("http_500") && goneLines.count == 1
                  && goneLines[0].contains("claim_token_mismatch"), "\(lines17)")

            // u. Fork from the glasses. On the session's own platform: one native fork of that session, and the receipt
            //    names the child. To the other platform: the conversation is read and carried into a new session on the
            //    model the request named, and no native fork is made.
            let (s18, t18, b18, _, tr18, _, _) = appSetUp("glasses-fork-native")
            await live(t18, s18)
            await t18.setFork(child: .object(["id": .string("s-child"), "provider": .string("claude"), "name": .string("Fork of Launch copy review"),
                                              "workspace": .string("Website"), "state": .string("running")]))
            await t18.setInbox([request(r1, mode: "fork", session: one.id, model: nil, note: "Try the shorter headline.", board: b18)])
            await pass(tr18)
            let forkArgs = await t18.args("session-chat-fork")
            let forked = try require(s18.receipts.first { $0.requestId == r1 })
            last = await lastPost(t18)
            started = await t18.count("work-new")
            // 0.5.257: the receipt id goes with the fork as its client id (server 6.63.0 background forks).
            check(forkArgs == [["session-chat-fork", "--provider", "claude", "--thread-id", "s-one", "--client-fork-id", forked.id]] && started == 0, "\(forkArgs) \(started)")
            check(forked.mode == .fork && forked.sessionID == "claude:s-child" && forked.sourceSessionID == one.id && forked.requestedFrom == "glasses"
                  && forked.prompt.contains("Note from the glasses: Try the shorter headline."), "\(String(describing: forked.sessionID)) \(forked.mode)")
            check(last == ["state": "sent", "receiptId": forked.id, "claimToken": token], "\(String(describing: last))")
            let (s19, t19, b19, _, tr19, _, _) = appSetUp("glasses-fork-cross")
            await live(t19, s19)
            await t19.setJob(provider: "codex", session: codexID, afterReads: 1)
            await t19.setInbox([request(r2, mode: "fork", session: one.id, model: "codex-frontier", board: b19)])
            await pass(tr19)
            let crossed = try require(s19.receipts.first { $0.requestId == r2 })
            let readBack = await t19.args("claude-session-detail")
            let nativeForks = await t19.count("session-chat-fork")
            started = await t19.count("work-new")
            last = await lastPost(t19)
            check(readBack == [["claude-session-detail", "--session", "s-one", "--provider", "claude"]] && nativeForks == 0 && started == 1,
                  "\(readBack) forks \(nativeForks) new \(started)")
            check(crossed.provider == "codex" && crossed.modelID == "codex-frontier" && crossed.requestedFrom == "glasses"
                  && last == ["state": "sent", "receiptId": crossed.id, "claimToken": token], "\(crossed.provider) \(String(describing: last))")

            // v. The journal is read again from disk before a request is sent: another launch of COS Control already sent
            //    this one, and this launch (whose memory does not have that receipt) reports it and sends nothing.
            let (s20, t20, b20, _, tr20, _, _) = appSetUp("glasses-dedupe-disk")
            await live(t20, s20)
            check(s20.receipts.isEmpty, "this launch starts with an empty journal")
            let tOther = TrackingTransport()
            let other20 = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("glasses-dedupe-disk.json"),
                                           transport: { args, data in try await tOther.run(args, data) })
            other20.models = [opus]
            deskless(other20)
            await tOther.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await other20.submit(source: WorkSource.taskSnapshot(b20.task(idA)), mode: .newSession, session: nil, model: opus, prompt: "Go",
                                 origin: WorkRequestOrigin(requestID: r1, deadline: Date().addingTimeInterval(600)))
            let theirs = try require(other20.receipts.first { $0.requestId == r1 })
            check(!s20.receipts.contains { $0.requestId == r1 }, "this launch's memory does not have the other launch's receipt")
            await t20.setInbox([request(r1, board: b20)])
            await pass(tr20)
            started = await t20.count("work-new")
            last = await lastPost(t20)
            check(started == 0 && last == ["state": WorkRequestOutcome.from(theirs).body["state"] ?? "", "receiptId": theirs.id, "claimToken": token],
                  "found on disk, reported, not sent again: new \(started) \(String(describing: last))")
            //    Found before anything else was read: a request answered from the journal on disk reads no catalog and no
            //    sessions. (Without the re-read the send's own journal fence refused it and reported the same receipt, so
            //    only this tells the two apart; the mutation gate found that on 2026-09-30.)
            let readsAfterDedupe = (await t20.count("work-models"), await t20.count("claude-sessions"))
            check(readsAfterDedupe == (0, 0), "dedupe comes before any other read: \(readsAfterDedupe)")

            // w. start() runs the inbox: the tracker's start lists at once, takes a waiting request, and keeps listing
            //    (the list is the heartbeat the server reads as "COS Control is here").
            let (s21, t21, b21, _, tr21, _, _) = appSetUp("glasses-start-loop")
            await live(t21, s21)
            await t21.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t21.setInbox([request(r1, board: b21)])
            tr21.requests.interval = 0.05; tr21.requests.busyInterval = 0.05
            tr21.start()
            try await Task.sleep(for: .milliseconds(900))
            tr21.requests.stop()
            await tr21.requests.waitForSend()
            let looped = await t21.inboxLog()
            started = await t21.count("work-new")
            check(looped.lists >= 4 && looped.claims == [r1] && started == 1 && looped.posted.map(\.body["state"]) == ["sent"],
                  "start() lists, takes the request once, and keeps listing: lists \(looped.lists) claims \(looped.claims) new \(started)")
            let afterStop = looped.lists
            try await Task.sleep(for: .milliseconds(300))
            let settled = await t21.inboxLog().lists
            check(settled <= afterStop + 1, "stop() ends the loop: \(afterStop) then \(settled)")

            // x. Telemetry, once per change of state and never once per pass: a list that fails, an older server, a claim
            //    that is refused.
            let (s22, t22, b22, clock22, tr22, _, _) = appSetUp("glasses-telemetry")
            await live(t22, s22)
            var lines: [String] = []
            tr22.requests.onLog = { lines.append($0) }
            tr22.requests.serverVersion = { "6.58.2" }
            await t22.setInbox([], reason: "unreachable")
            await pass(tr22); await pass(tr22); await pass(tr22)
            check(lines == ["glasses requests: list failed (unreachable)"], "one line for three failed lists: \(lines)")
            await t22.setInbox([])
            await pass(tr22); await pass(tr22)
            check(lines.count == 2 && lines[1] == "glasses requests: listing", "one line when it lists again: \(lines)")
            await t22.setInbox([], reason: "server_too_old")
            await pass(tr22); await pass(tr22)
            clock22.offset += 601
            await pass(tr22); await pass(tr22)
            check(lines.count == 3 && lines[2].hasPrefix("glasses requests: this server (6.58.2) has no inbox"), "one line for the older-server latch, its re-probe included: \(lines)")
            await t22.setInbox([request(r1, expiresIn: 5_000, board: b22)])
            await t22.setClaim(refusal: "already_claimed")
            clock22.offset += 601
            await pass(tr22); await pass(tr22); await pass(tr22)
            let claimLines = lines.filter { $0.contains("not claimed") }
            check(claimLines == ["glasses request \(r1): not claimed (already_claimed)"], "one line for a claim refused three times: \(lines)")

            // y. A glasses Start sends the task's own prompt and the note, never the Mac's saved draft (QA round 2): drafts
            //    save on every keystroke, so a half-typed prompt on the Mac must never reach the agent unseen on the glasses.
            let (s23, t23, b23, _, tr23, _, _) = appSetUp("glasses-not-the-mac-draft")
            await live(t23, s23)
            await t23.setJob(provider: "claude", session: claudeID, afterReads: 1)
            let task23 = WorkSource.taskSnapshot(b23.task(idA))
            var half = s23.draft(for: task23); half.prompt = "Half-typed on the Mac: delete the old pricing pa"
            check(s23.updateDraft(half, for: task23) && s23.draft(for: task23).prompt == half.prompt, "a Mac draft is saved for this task")
            await t23.setInbox([request(r1, note: "Keep the FAQ as it is.", board: b23)])
            await pass(tr23)
            let started23 = try require(s23.receipts.first { $0.requestId == r1 })
            let expected23 = task23.suggestedPrompt + "\n\nNote from the glasses: Keep the FAQ as it is."
            let queries23 = await t23.queries()
            check(started23.prompt.hasPrefix(expected23) && !started23.prompt.contains("Half-typed"), started23.prompt)
            check(queries23.count == 1 && queries23[0].hasPrefix(expected23) && !queries23[0].contains("Half-typed"), "\(queries23)")
            check(s23.draft(for: task23).prompt == half.prompt, "the Mac's draft is left as it was")

            // z. While a glasses send holds the journal, a Mac action that needs it (Mark reviewed, Clear unresolved, Check
            //    status, Not sending it) is told why and to try again, never the lock's "Another COS window" error; the
            //    timed status poll says nothing; and the line is still on the Work page after the send reports back.
            let (s24, t24, b24, _, tr24, _, _) = appSetUp("glasses-mac-waits")
            await live(t24, s24)
            await t24.setNewAnswer(http: 422)
            await s24.submit(source: source("aaaaaaaaaaaa"), mode: .newSession, session: nil, model: opus, prompt: "Refused at admission")
            let refused24 = try row(s24, "aaaaaaaaaaaa")
            await t24.setNewAnswer(http: nil)
            await s24.submit(source: source("dddddddddddd"), mode: .continueSession, session: two, model: nil, prompt: "Left unresolved")
            let unknown24 = try row(s24, "dddddddddddd").id
            check(s24.updateReceipt(unknown24) { $0.status = "unknown"; return true })
            let appNote24 = try row(s24, "dddddddddddd").id
            check(refused24.status == "refused" && refused24.acknowledgeable, refused24.status)
            await t24.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t24.setDelay("work-new", seconds: 0.6)
            await t24.setInbox([request(r1, board: b24)])
            s24.error = "An earlier line on the Work page"
            await tr24.requests.tick()
            try await Task.sleep(for: .milliseconds(150))
            check(s24.quietSend, "the glasses send holds the journal")
            s24.markReviewed(receiptID: refused24.id)
            check(s24.error == WorkRequestOrigin.macBusyReason && s24.receipts.first { $0.id == refused24.id }?.acknowledgeable == true,
                  "Mark reviewed is told to wait: \(s24.error ?? "")")
            s24.error = nil
            s24.clearUnresolved(receiptID: unknown24)
            check(s24.error == WorkRequestOrigin.macBusyReason && s24.receipts.first { $0.id == unknown24 }?.status == "unknown",
                  "Clear unresolved is told to wait: \(s24.error ?? "")")
            s24.error = nil
            s24.cancelAppNote(receiptID: appNote24)
            check(s24.error == WorkRequestOrigin.macBusyReason, "Not sending it is told to wait: \(s24.error ?? "")")
            s24.error = nil
            await s24.refreshReceipts()
            check(s24.error == nil, "the timed status poll says nothing: \(s24.error ?? "")")
            await s24.refreshReceipts(asked: true)
            check(s24.error == WorkRequestOrigin.macBusyReason, "Check status is told to wait: \(s24.error ?? "")")
            check(WorkRequestOrigin.macBusyReason == "COS Control is sending work your glasses asked for. Try again in a moment.")
            await tr24.requests.waitForSend()
            check(!s24.quietSend && s24.error == WorkRequestOrigin.macBusyReason, "the line is still there once the send reported: \(s24.error ?? "")")
            check(await lastPost(t24)?["state"] == "sent", "the glasses are told the send's own outcome")
            s24.error = nil
            s24.markReviewed(receiptID: refused24.id)
            check(s24.error == nil && s24.receipts.first { $0.id == refused24.id }?.acknowledgeable == false, "once the send let go, Mark reviewed works")
            //    With no Mac action meanwhile, the page's own earlier line comes back, as before.
            await t24.setInbox([request(r2, identity: idB, board: b24)])
            s24.error = "An earlier line on the Work page"
            await pass(tr24)
            check(s24.receipts.contains { $0.requestId == r2 } && s24.error == "An earlier line on the Work page", "\(s24.error ?? "")")

            // ── 0.5.253 ──────────────────────────────────────────────────────────────────────────────────────────────
            // A. Cursor needs a person at the Mac to press Send (Miles, 2026-09-30 13:27), so a request whose destination is
            //    Cursor is refused before anything is recorded or opened: a New session on a Cursor model, a Continue into a
            //    Cursor chat, a reply to a Cursor chat that asked; and submit() refuses it for any caller that is not the Mac.
            let (sc, tc, bc, _, trc, _, openedC) = appSetUp("glasses-cursor")
            let cursorChat = WorkSession(id: "cursor:" + cursorID, nativeID: cursorID, provider: "cursor", title: "Mobile navigation fixes",
                                         summary: "", project: "Website", status: "idle")
            await tc.setCatalog(models: [opus, frontier, grok], sessions: [one, two, cursorChat]); sc.models = [opus, frontier, grok]
            await tc.setInbox([request(r1, model: "cursor-grok", board: bc)])
            await pass(trc)
            last = await lastPost(tc)
            check(last == ["state": "refused", "reason": "Cursor needs you at the Mac to press send. Start it from COS Control.", "claimToken": token]
                  && sc.receipts.isEmpty && openedC.urls.isEmpty && openedC.clipboard.isEmpty, "\(String(describing: last))")
            await tc.setInbox([request(r2, identity: idB, mode: "continueSession", session: cursorChat.id, model: nil, board: bc)])
            await pass(trc)
            last = await lastPost(tc)
            check(last?["reason"] == WorkRequestOrigin.cursorNeedsMac && sc.receipts.isEmpty && openedC.urls.isEmpty, "\(String(describing: last))")
            await sc.submit(source: source(idA), mode: .newSession, session: nil, model: grok, prompt: "Go",
                            origin: WorkRequestOrigin(requestID: r3, deadline: Date().addingTimeInterval(600)))
            check(sc.receipts.isEmpty && sc.error == WorkRequestOrigin.cursorNeedsMac && openedC.urls.isEmpty, sc.error ?? "")
            sc.error = nil
            //    A reply: the Mac sent a Cursor Continue, the chat asked a question; the glasses' answer is refused.
            let askedTask = WorkSource.taskSnapshot(bc.task(idA))
            await sc.submit(source: askedTask, mode: .continueSession, session: cursorChat, model: nil, prompt: "Draft the FAQ")
            let askedRow = try require(sc.receipts(for: askedTask.id).first)
            let replyChat = "33333333-4444-4555-8666-777777777777"
            await tc.setLiveRows([.object(["id": .string(replyChat), "provider": .string("cursor"), "name": .string("FAQ"),
                                           "createdAt": .string(stamp(askedRow.createdAt + 5))])])
            await tc.setRead(replies: [("COS-WORK \(idA): needs input: Which plan should the FAQ quote?", nil)],
                             prompts: [("COS Work handoff \(idA)\n\nDraft the FAQ", nil)])
            await trc.tick(); await trc.tick(); await trc.tick()
            let asking = try require(sc.receipts(for: askedTask.id).first)
            check(asking.sessionID == "cursor:" + replyChat && asking.progress?.reported == .needsInput, "\(String(describing: asking.sessionID)) \(String(describing: asking.progress?.reported))")
            let urlsBefore = openedC.urls.count
            await tc.setInbox([request(r4, intent: "reply", mode: "continueSession", session: "cursor:" + replyChat, model: nil,
                                       note: "The $29 plan.", replyTo: asking.id, board: bc)])
            await pass(trc)
            last = await lastPost(tc)
            check(last?["reason"] == WorkRequestOrigin.cursorNeedsMac && sc.receipts(for: askedTask.id).count == 1 && openedC.urls.count == urlsBefore,
                  "\(String(describing: last))")

            // B. Results post one pass at a time (QA, deferred from 0.5.252): a pass and a send that just finished both post,
            //    and two passes at once posted one result twice.
            try ledger("glasses-serial", [WorkRequestLedgerEntry(requestId: r1, claimToken: token, claimedAt: Date().timeIntervalSince1970,
                                                                 result: ["state": "sent", "receiptId": "r-one"])])
            let (_, tS, _, _, trS, _, _) = appSetUp("glasses-serial")
            trS.requests.syncLedger()
            check(trS.requests.ledger.map(\.requestId) == [r1], "the claim a gone launch left is taken over")
            await tS.setDelay("work-request-result", seconds: 0.3)
            async let firstPass: Void = trS.requests.postDueResults()
            async let secondPass: Void = trS.requests.postDueResults()
            _ = await (firstPass, secondPass)
            let serialPosts = await tS.inboxLog().posted.count
            check(serialPosts == 1 && trS.requests.ledger.isEmpty, "two passes at once post it once: \(serialPosts)")

            // C. The ledger is shared by every COS Control on this Mac (QA, deferred from 0.5.252): read, changed and written
            //    under one lock, fsynced; each launch posts only its own claims, and keeps the other's on disk.
            let (sA, tA, bA, clockA, trA, _, _) = appSetUp("glasses-shared")
            await live(tA, sA); await tA.setJob(provider: "claude", session: claudeID, afterReads: 1)
            let tB = TrackingTransport()
            let sB = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("glasses-shared.json"),
                                      transport: { args, data in try await tB.run(args, data) })
            deskless(sB)
            let clockB = Clock()
            let trB = WorkProgressTracker(store: sB, board: bA.board, notify: { _ in }, now: { clockB.now() })
            trA.requests.ownerAlive = { _ in true }; trB.requests.ownerAlive = { _ in true }   // two launches, both running
            check(trA.requests.owner != trB.requests.owner)
            func onDisk() throws -> [WorkRequestLedgerEntry] {
                guard FileManager.default.fileExists(atPath: sA.requestLedgerURL.path) else { return [] }
                return try JSONDecoder().decode([WorkRequestLedgerEntry].self, from: Data(contentsOf: sA.requestLedgerURL))
            }
            await tA.queuePostAnswers([["accepted": .bool(false), "reason": .string("unreachable")]])
            await tA.setInbox([request(r1, board: bA)])
            await pass(trA)
            let disk1 = try onDisk()
            check(disk1.map(\.requestId) == [r1] && disk1.first?.owner == trA.requests.owner, "A's claim is on disk, signed")
            await live(tB, sB); await tB.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await tB.queuePostAnswers([["accepted": .bool(false), "reason": .string("unreachable")]])
            await tB.setInbox([request(r2, identity: idB, board: bA)])
            await pass(trB)
            let bPosted = await tB.inboxLog().posted.map(\.id)
            let disk2 = try onDisk().map(\.requestId)
            check(Set(disk2) == [r1, r2] && trB.requests.ledger.map(\.requestId) == [r2] && bPosted == [r2],
                  "B keeps A's claim on disk and never posts it: \(disk2) \(bPosted)")
            clockA.offset += 6
            await pass(trA)
            let aPosted = await tA.inboxLog().posted.map(\.id)
            let disk3 = try onDisk().map(\.requestId)
            check(disk3 == [r2] && aPosted == [r1, r1], "A's result taken, B's claim left: \(disk3) \(aPosted)")
            //    While another COS Control holds the lock, a change waits in memory, and is written once the lock is free.
            let held = open(sA.requestLedgerURL.path + ".lock", O_RDWR)
            check(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "the test holds the ledger's lock")
            clockB.offset += 6
            await pass(trB)
            let disk4 = try onDisk().map(\.requestId)
            check(trB.requests.ledger.isEmpty && trB.requests.ledgerWaiting && disk4 == [r2], "kept out by the lock: \(disk4)")
            flock(held, LOCK_UN); close(held)
            await pass(trB)
            check(!trB.requests.ledgerWaiting && !FileManager.default.fileExists(atPath: sA.requestLedgerURL.path), "written once the lock is free")
            //    A launch that is gone: its claim is taken over; one still running keeps its own.
            try ledger("glasses-takeover", [
                WorkRequestLedgerEntry(requestId: r1, claimToken: token, claimedAt: Date().timeIntervalSince1970, result: ["state": "sent", "receiptId": "r-a"], owner: "1:gone"),
                WorkRequestLedgerEntry(requestId: r2, claimToken: token, claimedAt: Date().timeIntervalSince1970, result: ["state": "sent", "receiptId": "r-b"], owner: "2:running")])
            let (sT, tT, _, _, trT, _, _) = appSetUp("glasses-takeover")
            trT.requests.ownerAlive = { $0 == "2:running" }
            await tT.setInbox([])
            await pass(trT)
            let takenOver = await tT.inboxLog().posted.map(\.id)
            let left = try JSONDecoder().decode([WorkRequestLedgerEntry].self, from: Data(contentsOf: sT.requestLedgerURL))
            check(takenOver == [r1] && left.map(\.requestId) == [r2] && left[0].owner == "2:running", "\(takenOver) \(left.map(\.requestId))")
            check(!WorkRequestInbox.launchRunning("\(getpid()):an-earlier-launch") && !WorkRequestInbox.launchRunning("0:x") && !WorkRequestInbox.launchRunning("x"),
                  "this process's own earlier launch, and nonsense, are gone")

            // D. The claim token never rides on a command line (QA, deferred from 0.5.252): a claim made again passes it on
            //    standard input, and no command in this suite ever carried it.
            for each in [transport, t2, t2b, t3c, t3d, t3e, t5, t10, t17, tA, tB, tS, tT] {
                let carried = await each.argvCarries(token)
                check(!carried, "a command line carried the claim token")
            }
            let reclaimTokens = await t3c.inboxLog().claimTokens
            check(reclaimTokens == [token], "the re-claim's token arrived on standard input: \(reclaimTokens)")

            // E. A 401 or 403 on a result is posted again with the growing wait, never dropped (QA, deferred from 0.5.252).
            let (s27, t27, b27, clock27, tr27, _, _) = appSetUp("glasses-result-auth")
            await live(t27, s27)
            await t27.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t27.setInbox([request(r1, board: b27)])
            await t27.queuePostAnswers([["accepted": .bool(false), "reason": .string("unauthorized"), "httpStatus": .number(401)],
                                        ["accepted": .bool(false), "reason": .string("local_only"), "httpStatus": .number(403)]])
            await pass(tr27)
            await t27.setInbox([])
            check(tr27.requests.ledger.first?.attempts == 1, "a 401 is kept for another post")
            clock27.offset += 6
            await pass(tr27)
            check(tr27.requests.ledger.first?.attempts == 2, "a 403 is kept for another post")
            clock27.offset += 11
            await pass(tr27)
            let authPosts = await t27.inboxLog().posted.count
            check(authPosts == 3 && tr27.requests.ledger.isEmpty, "taken on the third post: \(authPosts)")
            check(WorkHandoffStore.resultCanPass(reason: "unauthorized", status: 401) && WorkHandoffStore.resultCanPass(reason: "local_only", status: 403)
                  && !WorkHandoffStore.resultCanPass(reason: "claim_token_mismatch", status: 409))

            // F. Open in Claude while a glasses send holds the journal (QA, deferred from 0.5.252): Claude opens, its note
            //    (the app owns the session from then) is on record in this window at once, and on disk once the send lets go.
            let (s26, t26, b26, _, tr26, _, opened26) = appSetUp("glasses-open-during-send")
            await live(t26, s26)
            await t26.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await t26.setInbox([request(r1, board: b26)])
            await pass(tr26)
            await s26.newSessionLink?.value
            await t26.setJobResult("done")
            let quiet26 = try require(s26.receipts.first { $0.requestId == r1 }).id
            await tr26.tick(); await tr26.tick()
            check(WorkHandoffStore.appOpenButton(try require(s26.receipts.first { $0.id == quiet26 })) == "Open in Claude")
            await t26.setDelay("session-chat-attachability", seconds: 0.6)
            await t26.setInbox([request(r2, identity: idB, mode: "continueSession", session: two.id, model: nil, board: b26)])
            await tr26.requests.tick()
            try await Task.sleep(for: .milliseconds(150))
            check(s26.quietSend, "the glasses send holds the journal")
            await s26.reopenInApp(receiptID: quiet26)
            check(opened26.urls.map(\.absoluteString) == ["claude://resume?session=" + claudeID], "Claude opens during the send: \(opened26.urls)")
            check(s26.receipts.first { $0.id == quiet26 }?.appOpen?.openedAt != nil
                  && WorkHandoffStore.appOwner(of: "claude:" + claudeID, in: s26.receipts)?.id == quiet26, "on record in this window at once")
            await tr26.requests.waitForSend()
            func onDisk26() throws -> WorkHandoffReceipt {
                let reread = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("glasses-open-during-send.json"),
                                              transport: { _, _ in throw HelperClientError.commandFailed("none") })
                return try require(reread.receipts.first { $0.id == quiet26 })
            }
            let written26 = try onDisk26()
            check(written26.appOpen?.openedAt != nil && written26.detail == "Opened in Claude. Continue there."
                  && written26.progress?.events.last?.text == "Opened in Claude. Continue there.", "and on disk once the send let go")
            //    Another COS Control holding the journal: the note waits, and the next tracker pass writes it.
            let (s28, t28, _, _, tr28, _, opened28) = appSetUp("mac-open-journal-held")
            s28.models = [opus]
            await t28.setJob(provider: "claude", session: claudeID, afterReads: 1)
            await s28.submit(source: source(idA), mode: .newSession, session: nil, model: opus, prompt: "Go",
                             origin: WorkRequestOrigin(requestID: r1, deadline: Date().addingTimeInterval(600)))
            await s28.newSessionLink?.value
            await t28.setJobResult("done")
            let id28 = try row(s28, idA).id
            await tr28.tick(); await tr28.tick()
            let journalLock = open(root.appendingPathComponent("mac-open-journal-held.json").path + ".lock", O_RDWR)
            check(journalLock >= 0 && flock(journalLock, LOCK_EX | LOCK_NB) == 0, "another COS Control holds the journal")
            await s28.reopenInApp(receiptID: id28)
            check(opened28.urls.count == 1 && s28.receipts.first { $0.id == id28 }?.appOpen?.openedAt != nil, "opened, and on record in memory")
            flock(journalLock, LOCK_UN); close(journalLock)
            let reread28 = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("mac-open-journal-held.json"),
                                            transport: { _, _ in throw HelperClientError.commandFailed("none") })
            check(reread28.receipts.first { $0.id == id28 }?.appOpen?.openedAt == nil, "not on disk while the journal was held")
            await tr28.tick()
            let written28 = WorkHandoffStore(isolated: false, storageURL: root.appendingPathComponent("mac-open-journal-held.json"),
                                             transport: { _, _ in throw HelperClientError.commandFailed("none") })
            check(written28.receipts.first { $0.id == id28 }?.appOpen?.openedAt != nil, "the next tracker pass writes it")
        }
    }
}
