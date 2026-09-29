import CryptoKit
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
    /// You reviewed or acknowledged it: a question the session asked is no longer waiting on you.
    var handledByYou: Bool { acknowledgedAt != nil || status == "reviewed" }
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
