import CryptoKit
import Darwin
import Foundation

// 0.5.247 (Miles, 2026-09-29): "there should be a status update when the user has sent something to a session and
// it's been confirmed ... If a session is responsible for completing multiple tasks and we have evidence of the
// session receiving the context necessary to complete that task (as well as a confirmation that it has), then we want
// to be moving those tasks through the Kanban as well automatically."
//
// His choices: automatic moves go as far as QA and never to Complete; done needs the session's own status line, with
// Jev reading the reply as the fallback; every automatic move says why and can be undone.
//
// Tracking lives in its own optional receipt field. The server validates the handoff journal (work-activity.ts) and
// refuses the whole file on a receipt status it does not know, so progress is never written as a new status. Codable
// ignores the field in 0.5.246 and earlier; a rollback keeps the cards where they are and drops the timeline.

/// One step in a handoff's life, shown in the item's Progress timeline.
struct WorkProgressEvent: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case sent, received, working, done, needsInput, blocked, jev, moved, undone, note
        /// A kind this build does not know (written by a newer Control) reads as a note, so one new kind can never make
        /// the whole journal unreadable.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .note
        }
    }
    var id: String
    var at: Double
    var kind: Kind
    var text: String
    var fromStage: String? = nil
    var toStage: String? = nil
    /// Set when you undo this move.
    var undoneAt: Double? = nil
}

/// What COS knows about one handoff beyond its delivery status.
struct WorkProgress: Codable, Equatable, Sendable {
    /// The id the agent writes in its status line (`COS-WORK <tag>: ...`).
    var tag: String
    var events: [WorkProgressEvent] = []
    /// The newest report for this handoff: done, needs input or blocked, and who made it ("session" or "jev").
    var reported: WorkProgressEvent.Kind? = nil
    var reportedBy: String? = nil
    var evidence: String? = nil
    /// When the session was seen to have the work, and first replied after it. Flags rather than an event scan: the
    /// timeline keeps only its newest events.
    var receivedAt: Double? = nil
    var workingAt: Double? = nil
    /// When the session's transcript shows this handoff's instruction arriving. Replies before it answered earlier
    /// work (a busy session's previous turn), so they never count for this handoff.
    var promptAt: Double? = nil
    /// Replies already read (digests), so a reply is recorded once however often it is polled.
    var seenReplies: [String] = []
    /// Untimed replies (Cursor writes no times) already in the session when tracking first read it. They answered
    /// earlier work.
    var baseline: [String]? = nil
    /// 0.5.249: the same for your own untimed messages, so a note you send yourself in Terminal is recognised when it
    /// arrives (WorkProgress.untimedArrival).
    var promptBaseline: [String]? = nil
    /// Replies Jev has judged (digests), at most `maxJevAsks`.
    var jevAsked: [String]? = nil
    /// You undid an automatic move, or moved the card back yourself: this handoff never moves the card again.
    var paused: Bool? = nil
    /// A move decided but not yet made (the board was busy, read-only or unreachable), retried on later passes.
    var pendingStage: String? = nil
    var moveAttempts: Int? = nil
    /// Notifications already posted (received, done, needs input or blocked with its reply digest).
    var notified: [String] = []

    nonisolated static let maxEvents = 24
    nonisolated static let maxSeen = 40
    nonisolated static let maxNotified = 20
    nonisolated static let maxText = 280
    nonisolated static let maxJevAsks = 2
    nonisolated static let maxMoveAttempts = 5
    /// Days a handoff stays tracked. After that a quiet session is left alone.
    nonisolated static let trackedDays = 14.0
    /// Room kept in every prompt for the instruction below (316 characters with a 12-character tag).
    nonisolated static let instructionReserve = 480
    /// Jev's probability of done needed to move a card: read against the task's Done when, or, with no Done when
    /// (most tasks), against the task itself, which asks for more.
    nonisolated static let jevDoneAt = 0.8
    nonisolated static let jevTaskDoneAt = 0.85

    init(tag: String, events: [WorkProgressEvent] = []) { self.tag = tag; self.events = events }

    var finished: Bool { reported == .done }

    mutating func record(_ kind: WorkProgressEvent.Kind, _ text: String, at: Double, from: String? = nil, to: String? = nil,
                         id: String = UUID().uuidString.lowercased()) {
        guard !events.contains(where: { $0.id == id }) else { return }   // a replayed write records once
        events.append(WorkProgressEvent(id: id, at: at, kind: kind, text: Self.clip(text), fromStage: from, toStage: to))
        if events.count > Self.maxEvents {
            // Keep the first (sent) and the newest; the middle is the least useful. Undo never needs a trimmed move:
            // it is offered only on the newest one.
            events = [events[0]] + events.suffix(Self.maxEvents - 1)
        }
    }
    mutating func markSeen(_ digest: String) {
        guard !seenReplies.contains(digest) else { return }
        seenReplies.append(digest)
        if seenReplies.count > Self.maxSeen { seenReplies.removeFirst(seenReplies.count - Self.maxSeen) }
    }
    mutating func markNotified(_ key: String) {
        guard !notified.contains(key) else { return }
        notified.append(key)
        if notified.count > Self.maxNotified { notified.removeFirst(notified.count - Self.maxNotified) }
    }

    // MARK: - The status line

    /// The id for a Work item: a board task's own 12-hex work identity, else the first 12 hex of the id's SHA-256.
    nonisolated static func tag(forWorkID id: String) -> String {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        if parts.count == 3, parts[0] == "task", parts[2].range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil {
            return parts[2]
        }
        return String(SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// Appended to every handoff when it is sent, so it cannot be edited out of a draft. Appended, not prepended: a
    /// provider titles a new session by its first prompt line. The agent's line goes at the TOP of its reply, in plain
    /// text: the server keeps a reply's first 4,000 characters and drops fenced code.
    nonisolated static func instruction(tag: String) -> String {
        "\n\nWhen you finish this task, or if you need input or are blocked, make this the first line of your reply, in plain text (not bold, not in a code block), so COS can track it:\n"
            + "COS-WORK \(tag): <done, needs input or blocked>: <one sentence of evidence>\n"
            + "Use done only when the work is finished and checked. If you are handling several COS tasks, give one line per task."
    }

    struct Report: Equatable, Sendable {
        let tag: String
        let kind: WorkProgressEvent.Kind
        let evidence: String
    }

    /// Every status line in a reply. A line needs a 12-hex id, one state and evidence after it, so the template itself
    /// (`<done, needs input or blocked>`), a placeholder (`<one sentence…>`) and a bare "done" never count. Emphasis
    /// and code marks anywhere in the line are ignored (`**COS-WORK <id>:** done: …`).
    nonisolated static func reports(in text: String) -> [Report] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = String(raw).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
            while let first = line.first, "*_>#-•".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
            while let last = line.last, "*_".contains(last) { line.removeLast() }
            let pattern = #"^COS-WORK\s+([a-fA-F0-9]{12})\s*:\s*(done|needs[ _-]input|blocked)\s*[:\-\x{2013}\x{2014}]\s*(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let tagRange = Range(match.range(at: 1), in: line), let stateRange = Range(match.range(at: 2), in: line),
                  let evidenceRange = Range(match.range(at: 3), in: line) else { return nil }
            let evidence = line[evidenceRange].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_")))
            guard evidence.count >= 3, !evidence.hasPrefix("<") else { return nil }
            let state = line[stateRange].lowercased()
            let kind: WorkProgressEvent.Kind = state == "done" ? .done : state == "blocked" ? .blocked : .needsInput
            return Report(tag: line[tagRange].lowercased(), kind: kind, evidence: clip(evidence))
        }
    }

    /// A message read from the session, newest last. `at` is missing where the provider writes no timestamp (Cursor).
    struct Reply: Equatable, Sendable {
        let text: String
        let at: Double?
        var digest: String { WorkProgress.digest(text + "|" + (at.map { String($0) } ?? "")) }
    }

    /// The replies that can belong to this handoff: timed ones at or after `floor`, and untimed ones that were not in
    /// the session when tracking first read it.
    nonisolated static func eligible(_ replies: [Reply], floor: Double, baseline: [String]) -> [Reply] {
        replies.filter { reply in reply.at.map { $0 >= floor } ?? !baseline.contains(reply.digest) }
    }

    /// The newest status line for `tag` among `replies` (already filtered with `eligible`).
    nonisolated static func latestReport(tag: String, replies: [Reply]) -> (report: Report, reply: Reply)? {
        var found: (Report, Reply)?
        for reply in replies {
            if let report = reports(in: reply.text).last(where: { $0.tag == tag }) { found = (report, reply) }
        }
        return found
    }

    /// When the session's transcript shows this prompt arriving: the earliest user message at or after `since` that
    /// starts like it. Cleaning (the server drops fenced code and tags, and keeps 4,000 characters) makes an exact
    /// match impossible, so the first 60 letters and digits are compared.
    nonisolated static func promptArrival(prompt: String, messages: [Reply], since: Double) -> Double? {
        let head = promptKey(prompt)
        guard head.count >= 12 else { return nil }
        return messages.compactMap { message -> Double? in
            guard let at = message.at, at >= since - 5, promptKey(message.text) == head else { return nil }
            return at
        }.min()
    }
    /// 0.5.249: a note you send yourself in Terminal (Continue on a Cursor chat its app owns). Cursor writes no message
    /// times, so it arrives when an untimed message that starts like it appears that was not in the chat when tracking
    /// first read it (`promptBaseline`).
    nonisolated static func untimedArrival(prompt: String, messages: [Reply], baseline: [String]) -> Bool {
        let head = promptKey(prompt)
        guard head.count >= 12 else { return false }
        return messages.contains { $0.at == nil && !baseline.contains($0.digest) && promptKey($0.text) == head }
    }
    nonisolated static func promptKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(60).map(Character.init))
    }

    /// An ISO 8601 time from the server (with or without fractional seconds) as seconds since 1970.
    nonisolated static func parseStamp(_ raw: String) -> Double? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw))?.timeIntervalSince1970
    }
    nonisolated static func stamp(_ seconds: Double) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    nonisolated static func digest(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    nonisolated static func clip(_ text: String, _ limit: Int = maxText) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Delivery and stages

    /// The server confirms the session has the work: a Continue turn or queued turn it took, a fork holding the
    /// instruction, or a New session run it confirmed. Accepted-but-unconfirmed ("running" on a turn) is not delivery.
    /// The tracker also counts the session's own transcript showing the prompt (WorkProgress.promptArrival).
    nonisolated static func deliveryConfirmed(_ receipt: WorkHandoffReceipt) -> Bool {
        if receipt.clearedUnconfirmed { return false }
        if receipt.channel == "job" {
            return receipt.status == "completed" || (receipt.status == "running" && receipt.sessionID != nil)
        }
        return ["delivered", "reviewed", "completed"].contains(receipt.status)
    }

    /// The session doing this handoff's work, once there is one. A Fork names its parent until the fork exists, and
    /// the parent is not where the work happens.
    nonisolated static func workingSession(_ receipt: WorkHandoffReceipt) -> String? {
        guard let id = receipt.sessionID, !(receipt.mode == .fork && id == receipt.sourceSessionID) else { return nil }
        return id
    }

    /// Handoffs this Control sent with a status-line instruction, still within the tracking window, and not refused,
    /// failed, canceled, unresolved or already reported done. The tracker also drops a handoff a newer one replaced
    /// and one whose task is complete (WorkProgressTracker.candidates).
    nonisolated static func tracked(_ receipt: WorkHandoffReceipt, now: Double) -> Bool {
        guard let progress = receipt.progress, !progress.finished,
              now - receipt.createdAt < trackedDays * 86_400,
              !["refused", "failed", "canceled", "unknown"].contains(receipt.status), !receipt.clearedUnconfirmed else { return false }
        return true
    }

    /// A board task's domain and work identity, or nil (meeting reviews and samples have no stage to move).
    nonisolated static func boardTask(_ workID: String) -> (domain: String, identity: String)? {
        let parts = workID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "task", parts[2].range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil else { return nil }
        return (parts[1], parts[2])
    }

    /// Where an automatic move takes a card: received goes to Draft, done goes to QA. Nothing goes to Complete.
    nonisolated static func target(for kind: WorkProgressEvent.Kind) -> String? {
        switch kind { case .received: return "draft"; case .done: return "qa"; default: return nil }
    }
    /// Forward only, never out of Complete, never into it.
    nonisolated static func advances(from current: String, to target: String) -> Bool {
        let order = TaskRow.workStages
        guard let from = order.firstIndex(of: current), let to = order.firstIndex(of: target),
              current != "complete", target != "complete" else { return false }
        return to > from
    }
    /// You moved the card back yourself: it now sits before a stage COS moved it to (and you did not undo that move).
    nonisolated static func movedBackByYou(_ progress: WorkProgress, currentStage: String) -> Bool {
        progress.events.contains { $0.kind == .moved && $0.undoneAt == nil && ($0.toStage.map { advances(from: currentStage, to: $0) } ?? false) }
    }
    /// Undo is offered while the card still sits where COS put it and the move was not already undone.
    nonisolated static func canUndo(_ event: WorkProgressEvent, currentStage: String?) -> Bool {
        event.kind == .moved && event.undoneAt == nil && event.fromStage != nil && event.toStage != nil
            && currentStage == event.toStage
    }

    nonisolated static func stageTitle(_ stage: String) -> String { stage == "qa" ? "QA" : stage.capitalized }

    /// The timeline line for a confirmed delivery.
    nonisolated static func receivedText(_ receipt: WorkHandoffReceipt, fromTranscript: Bool) -> String {
        if fromTranscript { return "Received. The session\u{2019}s conversation shows your instruction." }
        switch receipt.mode {
        case .continueSession: return "Received. The session took the turn."
        case .fork: return "Received. The fork has the instruction."
        case .newSession: return "Received. The new session started with it."
        }
    }
}

extension WorkHandoffReceipt {
    /// The newest automatic move still sitting where COS put it, for the card's why-line and the Undo.
    var lastAutomaticMove: WorkProgressEvent? {
        progress?.events.last { $0.kind == .moved && $0.undoneAt == nil }
    }
    /// Only an explicit acknowledgment settles a question; opening its review does not answer it.
    var handledByYou: Bool { acknowledgedAt != nil }
}

/// Jev's answer to "does this reply show the task finished?" (server 6.58.0, POST /work-board/completion-check).
struct WorkCompletionVerdict: Equatable, Sendable {
    /// done, not_done or unclear.
    let verdict: String
    /// Jev's probability for `verdict`.
    let confidence: Double
    /// What the reply was read against: the task's Done when ("done_when"), or the task itself ("task").
    let basis: String
    init?(details: [String: JSONValue]) {
        guard details["provider"]?.string == "jev", let verdict = details["verdict"]?.string,
              ["done", "not_done", "unclear"].contains(verdict), let confidence = details["confidence"]?.double,
              confidence.isFinite, (0...1).contains(confidence) else { return nil }
        self.verdict = verdict; self.confidence = confidence
        basis = details["basis"]?.string == "done_when" ? "done_when" : "task"
    }
    /// Moves a card only on a confident done; more confident when there was no Done when to read against.
    var movesCard: Bool { verdict == "done" && confidence >= (basis == "done_when" ? WorkProgress.jevDoneAt : WorkProgress.jevTaskDoneAt) }
    var text: String {
        let percent = Int((confidence * 100).rounded())
        let against = basis == "done_when" ? "the task\u{2019}s Done when" : "the task (it has no Done when)"
        switch verdict {
        case "done" where movesCard: return "Jev read the reply as done (\(percent)%), against \(against)."
        case "done": return "Jev: probably done (\(percent)%), not sure enough to move it. Open the session to check."
        case "not_done": return "Jev: not done yet (\(percent)%). Left where it is."
        default: return "Jev: not sure (\(percent)%). Left where it is. Open the session to check."
        }
    }
}

// MARK: - 0.5.262: cards follow their threads and move on evidence
//
// Miles, 2026-10-07: "A card being worked in a thread follows that thread. When the evidence says it's finished, it moves
// to QA on its own, and the board tells him what moved and why." Plan v2 (PLAN_work_cards_follow_evidence_v2_2026-10-07)
// and the server contract (CONTRACT_work_evidence_check_2026-10-07, `POST /api/work-board/evidence-check`).
//
// Three files beside the handoff journal, each under its own lock, none of them the journal: the server validates the
// journal and refuses it whole on anything it does not know, so a follow is never a fake receipt (validation B1).
// - work-follows.json: which sessions each card follows, and each card's pause and newest verdicts.
// - work-moves.jsonl: every stage move Control makes, append-only, with `undo` and `ack` lines that point at a move.
// - work-tracker.lease: held by the one Control process that evaluates (a stable app and a review candidate share App
//   Support, validation W3).

/// The finish line: a task's Done when, split into the parts COS checks one by one.
enum WorkFinishLine {
    nonisolated static let maxClauses = 6
    nonisolated static let maxClauseLength = 300
    /// The Done when field's own limit (the 0.5.260 editor: under 501 characters).
    nonisolated static let maxLength = 500
    /// The server's square-bracket markers (task_rows.py `_MARKER_BODY`). The server refuses them in user text
    /// (task_write.reject_marker_text); the editor says so before a save is tried.
    nonisolated static let markerPattern = #"\[(?:run \d{4}-\d{2}-\d{2} \d{2}:\d{2}|agent running|agent #\d+ (?:done|failed)|agent failed|stage (?:planning|active|review))\]"#

    /// Split on `;` and on new lines, nothing else (" and " splits clauses wrongly, Skeptic W4). Each part is trimmed;
    /// empty parts go. No words are ever dropped.
    nonisolated static func clauses(_ doneWhen: String) -> [String] {
        doneWhen.split(whereSeparator: { $0 == ";" || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    nonisolated static func joined(_ clauses: [String]) -> String {
        clauses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "; ")
    }
    /// What the editor saves: parts on separate lines are stored `;`-joined; a line with no new line is kept as typed.
    nonisolated static func normalized(_ doneWhen: String) -> String {
        doneWhen.contains(where: \.isNewline) ? joined(clauses(doneWhen)) : doneWhen
    }
    /// Why this finish line cannot be saved or checked, or nil.
    nonisolated static func problem(_ doneWhen: String) -> String? {
        let saved = normalized(doneWhen).trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.utf16.count > maxLength { return "Keep the finish line under 501 characters." }
        if saved.range(of: markerPattern, options: .regularExpression) != nil {
            return "The finish line can't contain a square-bracket run, agent or stage marker."
        }
        if saved.lowercased().contains("**done when:**") || saved.lowercased().contains("**source:**") {
            return "The finish line can't contain a Done when or Source label."
        }
        let parts = clauses(saved)
        if parts.count > maxClauses { return "COS checks at most 6 parts. Join some with a comma." }
        if parts.contains(where: { $0.count > maxClauseLength }) { return "Keep each part under 301 characters." }
        return nil
    }
}

/// Who made a stage move: you (a drag, a menu, an Undo) or COS.
enum WorkMoveActor: String, Codable, Sendable { case you, cos }

/// One clause of a move, as the move log keeps it: what was checked and the evidence it rested on.
struct WorkMoveClause: Codable, Equatable, Sendable {
    var text: String
    var verdict: String
    var kind: String? = nil
    var source: String? = nil
    var ref: String? = nil
    var excerpt: String? = nil
    var at: String? = nil
    var deterministic: Bool? = nil
}

/// What a stage change carries into the move log.
struct WorkStageMove: Sendable {
    var by: WorkMoveActor
    var why: String
    var clauses: [WorkMoveClause] = []
    var judgedRevision: String? = nil
    /// A move the 0.5.247 receipt path made: its handoff and Progress event, so Undo from Moved for you goes through it.
    var receiptID: String? = nil
    var eventID: String? = nil
    /// The line's id, chosen before the move so the tracker can point at it.
    var id: String = UUID().uuidString.lowercased()
    nonisolated static let you = WorkStageMove(by: .you, why: "You moved it")
}

/// One line of work-moves.jsonl. Nothing is edited in place: an Undo or a Got it is its own line naming a move.
struct WorkMoveLine: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case move, undo, ack, pause }
    var type: Kind
    var id: String
    var at: Double
    var workID: String
    var from: String? = nil
    var to: String? = nil
    var by: WorkMoveActor? = nil
    /// A would-move: shadow mode logged it and moved nothing.
    var shadow: Bool? = nil
    var judgedRevision: String? = nil
    var clauses: [WorkMoveClause]? = nil
    var why: String? = nil
    var title: String? = nil
    var receiptID: String? = nil
    var eventID: String? = nil
    /// For `undo` and `ack`: the move this line answers.
    var move: String? = nil
}

/// A move with what happened to it since.
struct WorkMoveEntry: Identifiable, Equatable, Sendable {
    let line: WorkMoveLine
    var undoneAt: Double?
    var ackedAt: Double?
    var id: String { line.id }
    var shadow: Bool { line.shadow == true }
    var byCOS: Bool { line.by == .cos }
    /// Still in Moved for you and on the card: COS moved it (or would have), and you neither undid it nor said Got it.
    var open: Bool { byCOS && undoneAt == nil && ackedAt == nil }

    /// "Moved by COS · 2h ago", or "COS would move this · 2h ago" in shadow mode.
    func mark(now: Double) -> String {
        (shadow ? "COS would move this" : "Moved by COS") + " \u{00B7} " + WorkMoveEntry.ago(line.at, now: now)
    }
    /// "Moved to QA by COS · page is live (200, 16:31) + ads are running (Slack, 17:05)".
    var history: String {
        let to = WorkProgress.stageTitle(line.to ?? "")
        let head = shadow ? "COS would move this to \(to)" : (byCOS ? "Moved to \(to) by COS" : "You moved it to \(to)")
        let parts = (line.clauses ?? []).filter { $0.verdict == "met" }.map(WorkMoveEntry.clauseLabel)
        // Your own move needs no reason ("You moved it to Built"); an Undo says it was one.
        let why = byCOS || line.why != WorkStageMove.you.why ? (line.why ?? "") : ""
        let reason = parts.isEmpty ? why : parts.joined(separator: " + ")
        return reason.isEmpty ? head : head + " \u{00B7} " + reason
    }
    nonisolated static func clauseLabel(_ clause: WorkMoveClause) -> String {
        var where_: [String] = []
        switch clause.source {
        case "url"?: where_.append(clause.excerpt.flatMap { $0.split(separator: " ").first.map(String.init) }.flatMap { Int($0) != nil ? $0 : nil } ?? "page")
        case "slack"?: where_.append("Slack")
        case "session"?: where_.append("session")
        case "meeting"?: where_.append("meeting")
        case "file"?: where_.append("file")
        case let other?: where_.append(other)
        case nil: break
        }
        if let at = clause.at.flatMap(WorkProgress.parseStamp) { where_.append(WorkTracking.clock(at)) }
        let text = WorkSendPlan.clip(clause.text, 48)
        return where_.isEmpty ? text : text + " (" + where_.joined(separator: ", ") + ")"
    }
    nonisolated static func ago(_ at: Double, now: Double) -> String {
        let seconds = max(0, now - at)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

/// Opens `path` and takes an exclusive flock on it, waiting at most `wait` seconds (a short, bounded wait: the other
/// holder is a synchronous write). Nil when the lock stays busy.
nonisolated func workLockFile(_ path: String, wait: Double) -> Int32? {
    let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return nil }
    let deadline = Date().addingTimeInterval(wait)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard Date() < deadline else { close(fd); return nil }
        usleep(5_000)
    }
    return fd
}
nonisolated func workUnlockFile(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }

/// work-moves.jsonl. Append-only under a lock with a bounded wait; a line that finds the lock busy waits in `queued` and
/// is written on the next append or `flush()` (the tracker flushes every pass), so no line is ever dropped. At 20 MB the
/// file moves to `.1.jsonl` (replacing the previous one) and a new file starts; reads take both.
@MainActor final class WorkMoveLog: ObservableObject {
    nonisolated static let rotateAt = 20_000_000
    nonisolated static let lockWait = 0.25
    let url: URL?
    @Published private(set) var lines: [WorkMoveLine] = [] { didSet { epoch &+= 1 } }
    private(set) var epoch = 0
    private(set) var queued: [WorkMoveLine] = []
    /// Test hook: the lock is held elsewhere for these appends.
    var lockOverride: (() -> Bool)?

    init(url: URL?) { self.url = url; reload() }
    var rotatedURL: URL? { url.map { $0.deletingPathExtension().appendingPathExtension("1.jsonl") } }

    func reload() {
        guard let url else { return }
        var read: [WorkMoveLine] = []
        for file in [rotatedURL, url].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: file) else { continue }
            for raw in data.split(separator: UInt8(ascii: "\n")) where !raw.isEmpty {
                if let line = try? JSONDecoder().decode(WorkMoveLine.self, from: Data(raw)) { read.append(line) }
            }
        }
        let known = Set(read.map { $0.type.rawValue + $0.id })
        lines = read + queued.filter { !known.contains($0.type.rawValue + $0.id) }
    }

    /// Appends one line. True when it reached the file now; false when it waits for the lock (it is kept, never lost).
    @discardableResult func append(_ line: WorkMoveLine) -> Bool {
        guard !lines.contains(where: { $0.type == line.type && $0.id == line.id }) else { return true }
        queued.append(line)
        lines.append(line)
        return flush()
    }
    /// Writes every queued line. True when nothing waits any more.
    @discardableResult func flush() -> Bool {
        guard !queued.isEmpty else { return true }
        guard let url else { queued = []; return true }
        if let lockOverride, !lockOverride() { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return false }
        guard let fd = workLockFile(url.path + ".lock", wait: Self.lockWait) else { return false }
        defer { workUnlockFile(fd) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size >= Self.rotateAt, let rotated = rotatedURL {
            try? FileManager.default.removeItem(at: rotated)
            do { try FileManager.default.moveItem(at: url, to: rotated) } catch { return false }
        }
        var data = Data()
        for line in queued { if let encoded = try? JSONEncoder().encode(line) { data.append(encoded); data.append(UInt8(ascii: "\n")) } }
        let fd2 = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd2 >= 0 else { return false }
        defer { close(fd2) }
        let written = data.withUnsafeBytes { write(fd2, $0.baseAddress, $0.count) }
        guard written == data.count else { return false }
        fsync(fd2)
        queued = []
        return true
    }

    /// Every move, with its undo and ack.
    var entries: [WorkMoveEntry] {
        var undone: [String: Double] = [:], acked: [String: Double] = [:]
        for line in lines {
            guard let move = line.move else { continue }
            if line.type == .undo { undone[move] = undone[move] ?? line.at }
            if line.type == .ack { acked[move] = acked[move] ?? line.at }
        }
        return lines.filter { $0.type == .move }.map { WorkMoveEntry(line: $0, undoneAt: undone[$0.id], ackedAt: acked[$0.id]) }
    }
    /// Moved for you: COS's moves and would-moves nobody answered, newest first.
    var movedForYou: [WorkMoveEntry] { entries.filter(\.open).sorted { $0.line.at > $1.line.at } }
    /// The card's marker: its newest open COS move.
    func mark(workID: String) -> WorkMoveEntry? { movedForYou.first { $0.line.workID == workID } }
    func history(workID: String) -> [WorkMoveEntry] { entries.filter { $0.line.workID == workID }.sorted { $0.line.at > $1.line.at } }

    /// Got it: one `ack` line per open COS move on this card (opening the card acknowledges it).
    func acknowledge(workID: String, at: Double) {
        for entry in movedForYou where entry.line.workID == workID { acknowledge(moveID: entry.id, at: at) }
    }
    func acknowledge(moveID: String, at: Double) {
        guard let entry = entries.first(where: { $0.id == moveID }), entry.ackedAt == nil else { return }
        append(WorkMoveLine(type: .ack, id: "ack-" + moveID, at: at, workID: entry.line.workID, move: moveID))
    }
    func recordUndo(moveID: String, at: Double) {
        guard let entry = entries.first(where: { $0.id == moveID }), entry.undoneAt == nil else { return }
        append(WorkMoveLine(type: .undo, id: "undo-" + moveID, at: at, workID: entry.line.workID, move: moveID))
    }
    /// The COS move a 0.5.247 receipt move wrote, by its Progress event.
    func move(receiptID: String, eventID: String) -> WorkMoveEntry? {
        entries.first { $0.line.receiptID == receiptID && $0.line.eventID == eventID }
    }
}

/// One session a card follows.
struct WorkFollow: Codable, Equatable, Sendable, Identifiable {
    enum Origin: String, Codable, Sendable { case receipt, link, follow }
    var workID: String
    /// "provider:native".
    var sessionID: String
    var provider: String
    var origin: Origin
    var startedAt: Double
    /// The server's opaque read position for this session (evidence-check `cursors`). Nil reads from `since`.
    var cursor: String? = nil
    var paused: Bool = false
    /// The receipt this follow came from (origin receipt). The receipt itself is never changed.
    var receiptID: String? = nil
    /// Fallback only (no evidence check on the server): newest replies the completion check already read, at most 2.
    var judged: [String]? = nil
    var id: String { workID + "|" + sessionID }
}

/// The newest verdict for one clause, with the evidence it rested on.
struct WorkClauseState: Codable, Equatable, Sendable {
    var text: String
    var verdict: String
    var confidence: Double
    var kind: String
    var evidence: WorkMoveClause? = nil
    var deterministic: Bool = false
    var at: Double
    var met: Bool { verdict == "met" && kind == "fact" && evidence != nil }
}

/// A move the evidence decided on and could not write yet.
struct WorkPendingMove: Codable, Equatable, Sendable {
    var to: String
    var judgedRevision: String
    var why: String
    var clauses: [WorkMoveClause]
    var attempts: Int = 0
}

/// Per card: its pause, its newest check and verdicts, and a move waiting to be written.
struct WorkCardFollowState: Codable, Equatable, Sendable {
    var pausedAt: Double? = nil
    /// The stage the card sat in when it was paused. Moving it past this yourself starts the follows again.
    var pausedStage: String? = nil
    var pausedWhy: String? = nil
    /// When evidence checks ran that called Jev, for the 8-a-day cap.
    var checks: [Double] = []
    var checkedAt: Double? = nil
    var checkedRevision: String? = nil
    var checkedActivity: Double? = nil
    var basis: String? = nil
    var clauses: [WorkClauseState]? = nil
    var pending: WorkPendingMove? = nil
    /// The newest would-move logged in shadow mode, so one verdict is logged once.
    var shadowKey: String? = nil
    /// Why the card is not checked (a finish line in too many parts).
    var note: String? = nil
    var paused: Bool { pausedAt != nil }
    /// "1 of 2 met" while some parts of the finish line are met and some are not.
    var partial: (met: Int, of: Int)? {
        guard basis == "clauses", let clauses, clauses.count >= 2 else { return nil }
        let met = clauses.filter(\.met).count
        return met > 0 && met < clauses.count ? (met, clauses.count) : nil
    }
    /// "1 of 2 met · waiting: Facebook ads are running".
    var partialLine: String? {
        guard let partial, let waiting = clauses?.first(where: { !$0.met }) else { return nil }
        return "\(partial.met) of \(partial.of) met \u{00B7} waiting: " + WorkSendPlan.clip(waiting.text, 60)
    }
}

/// work-follows.json under its own lock (`.lock`, bounded wait). A change is made in memory at once; if the file is
/// busy it is kept and replayed over the file on the next write or `flush()`, so a pause is never lost.
@MainActor final class WorkFollowStore: ObservableObject {
    struct File: Codable, Equatable, Sendable {
        var version = 1
        var follows: [WorkFollow] = []
        var cards: [String: WorkCardFollowState] = [:]
    }
    nonisolated static let lockWait = 0.25
    nonisolated static let maxFollows = 4
    let url: URL?
    @Published private(set) var file = File() { didSet { epoch &+= 1 } }
    private(set) var epoch = 0
    private var pendingChanges: [(inout File) -> Bool] = []
    var lockOverride: (() -> Bool)?

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), data.count < 5_000_000, let read = try? JSONDecoder().decode(File.self, from: data) { file = read }
    }
    var follows: [WorkFollow] { file.follows }
    var waitingWrites: Int { pendingChanges.count }

    /// One change: applied now in memory, and written under the lock (or kept for the next write).
    @discardableResult func update(_ change: @escaping (inout File) -> Bool) -> Bool {
        var next = file
        guard change(&next) else { return false }
        file = next
        pendingChanges.append(change)
        flush()
        return true
    }
    /// Replays waiting changes over the file as it is on disk (another process may have written it), then saves.
    @discardableResult func flush() -> Bool {
        guard !pendingChanges.isEmpty else { return true }
        guard let url else { pendingChanges = []; return true }
        if let lockOverride, !lockOverride() { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let fd = workLockFile(url.path + ".lock", wait: Self.lockWait) else { return false }
        defer { workUnlockFile(fd) }
        var disk = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
        for change in pendingChanges { _ = change(&disk) }
        guard let data = try? JSONEncoder().encode(disk), (try? data.write(to: url, options: .atomic)) != nil else { return false }
        pendingChanges = []
        file = disk
        return true
    }

    func follows(for workID: String) -> [WorkFollow] { file.follows.filter { $0.workID == workID } }
    func card(_ workID: String) -> WorkCardFollowState { file.cards[workID] ?? WorkCardFollowState() }
    func isPaused(_ workID: String) -> Bool { file.cards[workID]?.paused == true }
    /// The sessions a card follows, unpaused, newest first, at most the 4 the server reads.
    func active(for workID: String) -> [WorkFollow] {
        guard !isPaused(workID) else { return [] }
        return Array(follows(for: workID).filter { !$0.paused }.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxFollows))
    }

    /// Adds a follow once per card and session. A paused card's new follow starts paused too.
    @discardableResult func add(workID: String, sessionID: String, origin: WorkFollow.Origin, startedAt: Double, receiptID: String? = nil) -> Bool {
        let provider = String(sessionID.split(separator: ":").first ?? "")
        guard sessionID.contains(":"), !provider.isEmpty, WorkProgress.boardTask(workID) != nil else { return false }
        return update { file in
            guard !file.follows.contains(where: { $0.workID == workID && $0.sessionID == sessionID }) else { return false }
            file.follows.append(WorkFollow(workID: workID, sessionID: sessionID, provider: provider, origin: origin, startedAt: startedAt,
                                           paused: file.cards[workID]?.pausedAt != nil, receiptID: receiptID))
            return true
        }
    }
    /// Undo, a move back, or Stop following: every follow on the card stops until you move it forward yourself.
    func pause(workID: String, stage: String, why: String, at: Double) {
        update { file in
            var card = file.cards[workID] ?? WorkCardFollowState()
            card.pausedAt = at; card.pausedStage = stage; card.pausedWhy = why; card.pending = nil
            file.cards[workID] = card
            for index in file.follows.indices where file.follows[index].workID == workID { file.follows[index].paused = true }
            return true
        }
    }
    func resume(workID: String) {
        update { file in
            guard file.cards[workID]?.pausedAt != nil else { return false }
            file.cards[workID]?.pausedAt = nil; file.cards[workID]?.pausedStage = nil; file.cards[workID]?.pausedWhy = nil
            for index in file.follows.indices where file.follows[index].workID == workID { file.follows[index].paused = false }
            return true
        }
    }
    /// A paused card you moved forward past where it was paused follows again.
    func resumeIfMovedForward(workID: String, currentStage: String) {
        guard let card = file.cards[workID], card.paused, let stage = card.pausedStage,
              WorkProgress.advances(from: stage, to: currentStage) else { return }
        resume(workID: workID)
    }
    /// Every stage change Control makes: one you made backward pauses the card's follows; one you made forward past a
    /// pause starts them again. COS's own moves change nothing here.
    func noteStageChange(workID: String, from: String, to: String, by: WorkMoveActor, at: Double) {
        guard by == .you, from != to, !follows(for: workID).isEmpty else { return }
        if WorkProgress.advances(from: from, to: to) || (to == "complete") {
            if to != "complete" { resumeIfMovedForward(workID: workID, currentStage: to) }
        } else {
            pause(workID: workID, stage: to, why: "You moved it back to \(WorkProgress.stageTitle(to)).", at: at)
        }
    }
    func setCard(_ workID: String, _ change: @escaping (inout WorkCardFollowState) -> Void) {
        update { file in
            var card = file.cards[workID] ?? WorkCardFollowState()
            let before = card
            change(&card)
            guard card != before else { return false }
            file.cards[workID] = card
            return true
        }
    }
    func setCursor(workID: String, sessionID: String, cursor: String?) {
        update { file in
            guard let index = file.follows.firstIndex(where: { $0.workID == workID && $0.sessionID == sessionID }),
                  file.follows[index].cursor != cursor else { return false }
            file.follows[index].cursor = cursor
            return true
        }
    }
    func markJudged(workID: String, sessionID: String, digest: String) {
        update { file in
            guard let index = file.follows.firstIndex(where: { $0.workID == workID && $0.sessionID == sessionID }) else { return false }
            var judged = file.follows[index].judged ?? []
            guard !judged.contains(digest) else { return false }
            judged.append(digest)
            file.follows[index].judged = Array(judged.suffix(WorkProgress.maxJevAsks))
            return true
        }
    }
    /// Follows on complete cards and on cards no longer on the board go; the rest are kept however old (a follow does
    /// not expire at 14 days while its card is open).
    func prune(openWorkIDs: Set<String>) {
        update { file in
            let kept = file.follows.filter { openWorkIDs.contains($0.workID) }
            guard kept.count != file.follows.count else { return false }
            file.follows = kept
            return true
        }
    }
}

extension WorkFollowStore {
    /// The receipts a card follows: every one with a session doing its work, except a send that never reached it
    /// (refused, canceled, cleared unconfirmed). A failed send is followed only once its session's transcript shows
    /// activity after the failure (`revivable`, then `add` by the tracker).
    nonisolated static func followable(_ receipt: WorkHandoffReceipt) -> Bool {
        WorkProgress.boardTask(receipt.workID) != nil && WorkProgress.workingSession(receipt) != nil
            && !["refused", "canceled", "failed"].contains(receipt.status) && !receipt.clearedUnconfirmed
    }
    nonisolated static func revivable(_ receipt: WorkHandoffReceipt) -> Bool {
        WorkProgress.boardTask(receipt.workID) != nil && WorkProgress.workingSession(receipt) != nil && receipt.status == "failed"
    }
    /// When a failed send failed: the newest moment the receipt records.
    nonisolated static func failedAt(_ receipt: WorkHandoffReceipt) -> Double {
        max(receipt.createdAt, receipt.progress?.events.map(\.at).max() ?? receipt.createdAt)
    }
    /// The transcript shows activity after the failure: a timed reply or message of yours after it.
    nonisolated static func activityAfter(_ floor: Double, replies: [WorkProgress.Reply], prompts: [WorkProgress.Reply]) -> Bool {
        (replies + prompts).contains { ($0.at ?? 0) > floor }
    }
}

/// Jev's verdict for one clause (server evidence-check).
struct WorkClauseVerdict: Equatable, Sendable {
    var text: String
    var verdict: String
    var confidence: Double
    var kind: String
    var evidence: WorkMoveClause?
    var deterministic: Bool
    /// Met with fact evidence at the bar: 0.80, or a deterministic pass.
    func metForMove(threshold: Double) -> Bool {
        verdict == "met" && kind == "fact" && evidence != nil && (confidence >= threshold || deterministic)
    }
    var moveClause: WorkMoveClause {
        var clause = evidence ?? WorkMoveClause(text: text, verdict: verdict)
        clause.text = text; clause.verdict = verdict; clause.kind = kind; clause.deterministic = deterministic
        return clause
    }
}

/// The server's answer to `POST /api/work-board/evidence-check` (contract 2026-10-07).
struct WorkEvidenceResult: Equatable, Sendable {
    struct Cursor: Equatable, Sendable { var provider: String; var sessionId: String; var cursor: String }
    var basis: String
    var clauses: [WorkClauseVerdict]
    var sources: [String]
    var cursors: [Cursor]
    var truncated: Bool
    var cached: Bool
    var skipped: String?

    nonisolated static let verdicts: Set<String> = ["met", "not_met", "unclear"]
    nonisolated static let kinds: Set<String> = ["fact", "intent", "draft", "none"]
    /// Clause path: every clause met with fact evidence at 0.80 or deterministic. Title path: 0.90 and 2 sources.
    nonisolated static let clauseBar = 0.80
    nonisolated static let titleBar = 0.90

    /// Nil unless the answer is Jev's and well formed; a clause path answer must judge exactly the clauses sent, a title
    /// path answer exactly one.
    init?(details: [String: JSONValue], sent: Int) {
        guard details["provider"]?.string == "jev", let basis = details["basis"]?.string, ["clauses", "title"].contains(basis),
              let rows = details["clauses"]?.array else { return nil }
        var clauses: [WorkClauseVerdict] = []
        for row in rows {
            guard let o = row.object, let text = o["text"]?.string, let verdict = o["verdict"]?.string, Self.verdicts.contains(verdict),
                  let confidence = o["confidence"]?.double, confidence.isFinite, (0...1).contains(confidence),
                  let kind = o["kind"]?.string, Self.kinds.contains(kind) else { return nil }
            var evidence: WorkMoveClause?
            if let e = o["evidence"]?.object, let source = e["source"]?.string, !source.isEmpty {
                evidence = WorkMoveClause(text: text, verdict: verdict, kind: kind, source: source, ref: e["ref"]?.string,
                                          excerpt: e["excerpt"]?.string.map { WorkProgress.clip($0, 200) }, at: e["at"]?.string)
            }
            clauses.append(WorkClauseVerdict(text: text, verdict: verdict, confidence: confidence, kind: kind, evidence: evidence,
                                             deterministic: o["deterministic"]?.bool == true))
        }
        guard basis == "clauses" ? (clauses.count == sent && sent > 0) : (clauses.count == 1 && sent == 0) else { return nil }
        self.basis = basis; self.clauses = clauses
        sources = (details["sources"]?.array ?? []).compactMap(\.string)
        cursors = (details["cursors"]?.array ?? []).compactMap(\.object).compactMap { o in
            guard let provider = o["provider"]?.string, let session = o["sessionId"]?.string, let cursor = o["cursor"]?.string else { return nil }
            return Cursor(provider: provider, sessionId: session, cursor: cursor)
        }
        truncated = details["truncated"]?.bool == true
        cached = details["cached"]?.bool == true
        skipped = details["skipped"]?.string
    }

    enum Decision: Equatable, Sendable { case move, partial(met: Int, of: Int), hold }
    /// Control's policy (contract, Control section). The server never moves a card.
    var decision: Decision {
        if truncated { return .hold }   // a read that stopped short is unclear
        if basis == "title" {
            guard let clause = clauses.first, clause.verdict == "met", clause.kind == "fact", let evidence = clause.evidence,
                  clause.confidence >= Self.titleBar,
                  Set(sources + [evidence.source ?? ""]).subtracting([""]).count >= 2 else { return .hold }
            return .move
        }
        let met = clauses.filter { $0.metForMove(threshold: Self.clauseBar) }.count
        if met == clauses.count && met > 0 { return .move }
        return .partial(met: met, of: clauses.count)
    }
    /// The why-line for a move.
    var why: String {
        basis == "title" ? "the evidence shows the task finished (Jev, two sources)" : "every part of the finish line is met"
    }
}

// MARK: - 0.5.262: the Work background model (Settings)
//
// Miles, 2026-10-07: the end-of-day Slack sweep for Work evidence is a standing, unattended token cost, so he picks its
// model in Settings. COS's `operations/scripts/work_slack_sweep.py` reads `slackSweepModel` from this file; an unknown
// value falls back to Haiku there and here.

enum WorkSweepModel: String, CaseIterable, Sendable, Hashable {
    case haiku, sonnet
    var title: String { self == .haiku ? "Haiku (Recommended)" : "Sonnet" }
}

enum WorkEvidenceSettings {
    nonisolated static let key = "slackSweepModel"
    /// ~/Library/Application Support/COS Control/work-evidence.json, or the checks' own home.
    nonisolated static func defaultURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] {
            return URL(fileURLWithPath: home).appendingPathComponent("work-evidence.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/COS Control/work-evidence.json")
    }
    nonisolated static func read(_ url: URL) -> WorkSweepModel {
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object[key] as? String else { return .haiku }
        return WorkSweepModel(rawValue: raw) ?? .haiku
    }
    /// Writes the choice atomically and keeps every other key in the file. A file that is not a JSON object is refused,
    /// never overwritten.
    nonisolated static func write(_ model: WorkSweepModel, to url: URL) throws {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw HelperClientError.commandFailed("work-evidence.json is not a settings file. It was left as it is.")
                }
                object = read
            }
        }
        object[key] = model.rawValue
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
