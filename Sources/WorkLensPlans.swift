import Foundation

/// 0.5.333 lens plans (server 6.83.0 `lensPlans: 1`; contract CONTRACT_lens_plans_6.83.0_2026-10-21.md, Miles 2026-10-21
/// 09:11 "Add both"). The lens records a plan it made and may ask for it to be sent. The server only holds rounds and
/// requests; COS Control stays the owner of every send and of the Work chat journal. Control polls the lens inbox every
/// 5 s while it runs (only when the server advertises lensPlans), writes each round into the card's Work chat record
/// ("From glasses" with the time; the same WorkChatRound, so history, summaries and updates work), sends each request
/// through the same `dispatch` and `WorkHandoffStore.submit` as its own Send, and reports each assignment's result.
///
/// Pure value logic only (Foundation), so `Tests/WorkLensPlansChecks.swift` compiles it alone.
enum WorkLensPlans {
    static let pollSeconds: Double = 5
    /// How often Control asks the server whether it holds lens plans (GET /api/work/chat, no model call).
    static let capabilitySeconds: Double = 60
    /// A WorkChatRound's `origin` for a round written from the lens.
    static let origin = "glasses"

    // MARK: The inbox (what the server answers)

    struct Assignment: Decodable, Equatable, Sendable {
        let id: String; let mode: String; let sessionID: String?; let provider: String?; let prompt: String; let contextItemIDs: [String]?
    }
    struct Round: Decodable, Equatable, Sendable {
        let roundId: String; let workID: String; let question: String; let answer: String
        let planner: String?; let effort: String?; let orchestrator: Bool?; let createdAt: String; let recordedAt: String?
        let assignments: [Assignment]
    }
    struct SendRequest: Decodable, Equatable, Sendable {
        let sendRequestId: String; let roundId: String; let workID: String; let assignmentIds: [String]
        let confirm: String?; let autoSend: Bool?; let round: Round?
    }
    struct StopRequest: Decodable, Equatable, Sendable {
        let stopRequestId: String; let roundId: String; let workID: String; let assignmentIds: [String]; let sendRequestId: String?
    }
    struct Inbox: Decodable, Equatable, Sendable {
        let v: Int; let cursor: Int; let rounds: [Round]; let sends: [SendRequest]; let stops: [StopRequest]
    }

    static func validRoundID(_ id: String) -> Bool { id.range(of: "^lr_[a-f0-9]{16}$", options: .regularExpression) != nil }
    static func validSendID(_ id: String) -> Bool { id.range(of: "^ls_[a-f0-9]{16}$", options: .regularExpression) != nil }
    static func validWorkID(_ id: String) -> Bool { id.range(of: "^task:[a-z_]+:[a-f0-9]{12}$", options: .regularExpression) != nil }

    /// A round Control may write: ids a1..aN in answer order, at most three, each kind well formed.
    static func valid(_ round: Round) -> Bool {
        guard validRoundID(round.roundId), validWorkID(round.workID), !round.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              round.question.count <= 4000, round.answer.count <= 6000, round.assignments.count <= 3 else { return false }
        for (i, a) in round.assignments.enumerated() {
            guard a.id == "a\(i + 1)", a.prompt.count <= 6000 else { return false }
            switch a.mode {
            case "continue", "fork": guard let s = a.sessionID, s.range(of: "^(claude|codex|cursor):[0-9a-f-]{36}$", options: .regularExpression) != nil else { return false }
            case "newSession": guard ["claude", "codex"].contains(a.provider ?? ""), a.sessionID == nil else { return false }
            default: return false
            }
        }
        return true
    }

    /// The inbox, from the helper's JSON. A round that is not `valid` is never written (WorkTaskChatStore.recordLensRound).
    static func inbox(_ data: Data) -> Inbox? {
        guard let box = try? JSONDecoder().decode(Inbox.self, from: data), box.v == 1 else { return nil }
        return box
    }

    /// The WorkChatAssignment mode for a lens mode: a Continue is nil, as every Continue before 0.5.333 was.
    static func chatMode(_ lensMode: String) -> String? { lensMode == "continue" ? nil : lensMode }

    /// The cursor to send next: past this answer's rounds only when every one of them is now in history, so a round that
    /// could not be written is listed again on the next poll.
    static func nextCursor(current: Int, answered: Int, allWritten: Bool) -> Int { allWritten ? max(current, answered) : current }

    // MARK: Sending

    /// The per-card Auto-send rule: a send the wearer confirmed with the two-step tap, or any send on a card whose
    /// Auto-send is on. Control checks it again before it sends, whatever the server decided.
    static func maySend(confirm: String?, cardAutoSend: Bool) -> Bool { confirm == "two-step" || cardAutoSend }
    static let autoSendOff = "Auto-send is off for this card on the Mac. Confirm on the lens to send."
    static let notEnabled = "Work chat sending is not enabled in this COS Control."
    static let notInHistory = "COS Control could not save this plan into the card's Work chat. Nothing was sent."
    static let busy = "COS Control was busy with this card. Nothing was sent; send it again."

    struct Result: Equatable, Sendable {
        let id: String; let state: String; let receiptId: String?; let detail: String?; let sessionID: String?
        var json: [String: Any] {
            var o: [String: Any] = ["id": id, "state": state]
            if let receiptId { o["receiptId"] = receiptId }
            if let detail, !detail.isEmpty { o["detail"] = String(detail.prefix(200)) }
            if let sessionID { o["sessionID"] = sessionID }
            return o
        }
    }
    /// States after which the lens stops polling and Control stops reporting.
    static let final: Set<String> = ["delivered", "failed", "refused", "stopped"]

    /// The lens state of one assignment, from its Work chat state (a receipt's status once it has one). `attempted`: Control
    /// tried to send it for this request, so "Not sent" is a refusal, not a wait.
    static func lensState(chatState: String, attempted: Bool, queuedState: String = "Queued") -> String {
        switch chatState {
        case queuedState: return "held"
        case "Sending": return "pending"
        case "Not sent": return attempted ? "refused" : "pending"
        case "Skipped", "canceled": return "stopped"
        // The server accepted it (a parked turn or a running job), or delivery is not confirmed yet: never send it again.
        case "queued", "running", "sending", "unknown", "No delivery receipt": return "sent"
        case "delivered", "completed", "reviewed", "Session reported done", "Session reported blocked", "Needs your input", "Reply available for review": return "delivered"
        case "refused": return "refused"
        case "failed": return "failed"
        default: return "pending"
        }
    }
    /// Short plain text for the lens footer: the reason, never the prompt.
    static func detail(state: String, chatDetail: String, fallback: String?) -> String? {
        let text = chatDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(200)) }
        switch state {
        case "refused": return fallback.map { String($0.prefix(200)) } ?? "COS Control did not send it."
        case "held": return "Waits for earlier work on this card."
        default: return nil
        }
    }

    // MARK: History

    /// "From glasses · 9:14 AM" today, "From glasses · Oct 20, 9:14 AM" on another day.
    static func fromGlassesLabel(at: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = cal.isDate(at, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"
        return "From glasses · " + f.string(from: at)
    }
    /// When the lens made the round: the server's recordedAt, else the lens's createdAt, else now.
    static func roundTime(_ round: Round, now: Date) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for s in [round.recordedAt, round.createdAt].compactMap({ $0 }) {
            if let d = f.date(from: s) ?? plain.date(from: s) { return d }
        }
        return now
    }
}
