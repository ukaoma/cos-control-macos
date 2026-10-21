import Foundation

/// 0.5.333 (Work orchestrator M1, server 6.83.0, docs/work-orchestrator.md in cos-glasses-server).
///
/// Phase A: Control owns the Work journal and pushes the server a bounded snapshot (ids, modes, statuses, times; never a
/// prompt, result or file name) right before each plan. The server answers the card's planner rows: every session it
/// found for the card, how, whether it is in the session list Control just read, a redacted pick-up note, and why it can
/// or cannot take a Continue now, plus plan usage per provider. Control still owns every send: `automatic` is Control's
/// decision, and Continue, Fork and New session all go through `WorkHandoffStore.submit` with its fences and receipts.
///
/// Pure value logic only (Foundation), so `Tests/WorkOrchestratorChecks.swift` compiles it alone.
enum WorkOrchestrator {
    /// Server 6.83.0 advertises `orchestrator: 1` on GET /api/work/chat.
    static let protocolVersion = 1

    // MARK: Snapshot (what Control pushes)

    struct Link: Equatable, Sendable { let sessionID: String; let workID: String; let at: Double }
    struct Receipt: Equatable, Sendable {
        let id: String; let workID: String; let mode: String; let provider: String
        let sessionID: String?; let sourceSessionID: String?; let forkChildID: String?; let status: String; let createdAt: Double
    }
    struct LiveRow: Equatable, Sendable {
        let id: String; let title: String; let status: String; let updatedAt: String?; let busy: Bool; let waitingOnUser: Bool; let appOwned: Bool; let summary: String
    }
    static let maxLinks = 4000, maxReceipts = 4000, maxLive = 400

    /// Codex guardian review threads (canary C3: 17 in the live list on 2026-10-20) are never work sessions.
    static func isGuardian(id: String, title: String, summary: String) -> Bool {
        id.hasPrefix("codex:") && (title.trimmingCharacters(in: .whitespaces) == "Guardian review"
            || summary.hasPrefix("The following is the Codex agent history"))
    }

    /// The snapshot body, newest receipts first, each list bounded. `live` is nil when the session list could not be read.
    static func snapshot(links: [Link], receipts: [Receipt], live: [LiveRow]?, liveCheckedAt: Date?, controlVersion: String, now: Date) -> [String: Any] {
        func opt(_ s: String?) -> Any { s ?? NSNull() }
        var body: [String: Any] = [
            "version": 1, "controlVersion": String(controlVersion.prefix(40)), "sentAt": now.timeIntervalSince1970,
            "links": links.sorted { $0.at > $1.at }.prefix(maxLinks).map { ["sessionID": $0.sessionID, "workID": $0.workID, "at": $0.at] as [String: Any] },
            "receipts": receipts.sorted { $0.createdAt > $1.createdAt }.prefix(maxReceipts).map {
                ["id": String($0.id.prefix(64)), "workID": $0.workID, "mode": $0.mode, "provider": String($0.provider.prefix(20)),
                 "sessionID": opt($0.sessionID), "sourceSessionID": opt($0.sourceSessionID), "forkChildID": opt($0.forkChildID),
                 "status": String($0.status.prefix(40)), "createdAt": $0.createdAt] as [String: Any]
            },
            "live": NSNull(),
        ]
        if let live, let checked = liveCheckedAt {
            let rows = live.filter { !isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }.prefix(maxLive).map {
                ["id": $0.id, "title": String($0.title.prefix(300)), "status": String($0.status.prefix(100)), "updatedAt": opt($0.updatedAt),
                 "busy": $0.busy, "waitingOnUser": $0.waitingOnUser, "appOwned": $0.appOwned, "summary": String($0.summary.prefix(2000))] as [String: Any]
            }
            body["live"] = ["checkedAt": checked.timeIntervalSince1970, "rows": Array(rows)] as [String: Any]
        }
        return body
    }

    // MARK: Input (what the server answers)

    struct Row: Decodable, Equatable, Sendable {
        let id: String; let title: String; let summary: String; let status: String
        let discoveredBy: [String]; let linked: Bool; let member: Bool
        let lastTouchedCard: String?; let lastActivity: String?
        let live: Bool; let busy: Bool; let pickup: String
        let available: Bool; let reason: String?; let forkable: Bool
        var provider: String { String(id.split(separator: ":").first ?? "") }
        var nativeID: String { String(id.split(separator: ":", maxSplits: 1).last ?? "") }
    }
    struct LeftOut: Decodable, Equatable, Sendable { let id: String; let title: String; let reason: String }
    /// One provider's plan usage as the server read it; passed to the planner as is.
    struct Usage: Codable, Equatable, Sendable {
        let provider: String; let state: String; let headroomPct: Double?; let resetsAt: String?; let ageSec: Int?
        let source: String; let plan: String?; let stale: Bool; let note: String
        /// The planner's copy: every key present, a missing value as JSON null (the server's schema requires each key).
        var json: [String: Any] {
            ["provider": provider, "state": state, "headroomPct": headroomPct.map { $0 as Any } ?? NSNull(), "resetsAt": resetsAt.map { $0 as Any } ?? NSNull(),
             "ageSec": ageSec.map { $0 as Any } ?? NSNull(), "source": String(source.prefix(40)), "plan": plan.map { String($0.prefix(40)) as Any } ?? NSNull(),
             "stale": stale, "note": String(note.prefix(200))]
        }
    }
    struct Input: Decodable, Sendable {
        let protocolVersion: Int; let workID: String; let now: String
        let rows: [Row]; let leftOut: [LeftOut]; let usage: [Usage]; let discovered: Int
        let snapshotAgeSec: Int?; let liveListAgeSec: Int?; let logScanComplete: Bool
    }

    /// Whether Control lets the planner Continue into a row: Claude or Codex, in the list just read, nothing the server
    /// says stops it, and Control's own rule (not owned by its app) agrees. Unchanged meaning: the only Continue gate.
    static func automatic(_ row: Row, controlAllows: Bool) -> Bool {
        ["claude", "codex"].contains(row.provider) && row.live && row.reason == nil && controlAllows
    }

    /// The planner's session rows, in the server's order, at most 12. `openWork` only when the server takes it.
    static func plannerRows(_ input: Input, controlAllows: (String) -> Bool, openWork: ((String) -> Bool)?) -> [[String: Any]] {
        input.rows.prefix(12).map { r in
            var row: [String: Any] = ["id": r.id, "title": String(r.title.prefix(300)), "summary": String(r.summary.prefix(2000)),
                "status": String(r.status.prefix(100)), "automatic": automatic(r, controlAllows: controlAllows(r.id)),
                "discoveredBy": r.discoveredBy, "linked": r.linked, "member": r.member,
                "lastTouchedCard": r.lastTouchedCard.map { $0 as Any } ?? NSNull(), "lastActivity": r.lastActivity.map { $0 as Any } ?? NSNull(),
                "live": r.live, "busy": r.busy, "pickup": String(r.pickup.prefix(1500)), "available": r.available,
                "forkable": r.forkable && ["claude", "codex"].contains(r.provider)]
            if let reason = r.reason { row["reason"] = reason }
            if let openWork { row["openWork"] = openWork(r.id) }
            return row
        }
    }

    static func reasonText(_ reason: String?) -> String {
        switch reason {
        case "not_in_session_list": return "not in the session list just read (fork it or start new)"
        case "app_owned": return "open in its app (continue it there)"
        case "cursor": return "Cursor (send in its app)"
        case "plan_limit": return "its plan usage is used up"
        case "on_another_card": return "working on another task now"
        case nil: return "available"
        default: return reason!
        }
    }

    /// 0.5.333 (Miles 2026-10-20: never plan from an empty list silently). Nil when at least one session can take a
    /// Continue; otherwise one plain line saying why, which the round shows above the plan.
    static func emptyExplanation(rows: [Row], leftOut: [LeftOut], automaticIDs: Set<String>, listFailed: Bool) -> String? {
        if rows.contains(where: { automaticIDs.contains($0.id) }) { return nil }
        let list = listFailed ? " The session list could not be read just now." : ""
        if rows.isEmpty && leftOut.isEmpty {
            return "COS found no session for this task (no link, receipt or COS-WORK handoff).\(list) The planner can still start a new session."
        }
        let named = rows.prefix(4).map { "\u{201C}\(String($0.title.prefix(40)))\u{201D} (\(reasonText($0.reason)))" }
        let more = rows.count + leftOut.count - named.count
        return "COS found \(rows.count + leftOut.count) session\(rows.count + leftOut.count == 1 ? "" : "s") for this task, none can take a Continue now: "
            + named.joined(separator: "; ") + (more > 0 ? "; and \(more) more" : "") + ".\(list) The planner can fork one or start a new session."
    }

    /// The same check for an older server (no orchestrator): the planner only ever sees linked sessions in a fresh list.
    static func legacyEmptyExplanation(linkedCount: Int, inList: Int, listFailed: Bool) -> String? {
        guard inList == 0 else { return nil }
        if listFailed { return "The session list could not be read just now, so the planner saw no sessions. Refresh and plan again." }
        if linkedCount > 0 { return "This task's \(linkedCount) linked session\(linkedCount == 1 ? " is" : "s are") not in the session list just read, so the planner saw none." }
        return "No session is linked to this task yet, so the planner saw none."
    }

    // MARK: Assignments

    enum Kind: Equatable, Sendable { case continueSession, fork, newSession(String) }
    /// An orchestrator assignment's kind from the server's `mode` and `provider`. Anything else is a Continue.
    static func kind(mode: String?, provider: String?) -> Kind? {
        switch mode {
        case nil, "continue": return .continueSession
        case "fork": return .fork
        case "newSession": return ["claude", "codex"].contains(provider ?? "") ? .newSession(provider!) : nil
        default: return nil
        }
    }
    /// A New session assignment has no session yet; this stands in for its id so each assignment stays distinct.
    static func newSessionID(provider: String, receiptID: String) -> String { "new:\(provider):\(receiptID.prefix(8))" }
    static func isNewSessionID(_ id: String) -> Bool { id.hasPrefix("new:") }

    /// Every assignment of an orchestrator plan names a target the planner was allowed: a Continue an automatic row, a
    /// Fork a forkable row, a New session an offered provider. At most three, distinct, each prompt valid.
    static func valid(kinds: [(Kind?, String, String)], continueTargets: Set<String>, forkTargets: Set<String>, newProviders: Set<String>,
                      validPrompt: (String) -> Bool) -> Bool {
        guard kinds.count <= 3, Set(kinds.map(\.1)).count == kinds.count else { return false }
        return kinds.allSatisfy { kind, target, prompt in
            guard validPrompt(prompt) else { return false }
            switch kind {
            case .continueSession?: return continueTargets.contains(target)
            case .fork?: return forkTargets.contains(target)
            case .newSession(let p)?: return newProviders.contains(p) && isNewSessionID(target)
            case nil: return false
            }
        }
    }

    // MARK: Auto-send, per card (Miles Q1, 2026-10-20 21:55)

    /// A card's own choice, saved per Mac as JSON `{workID: Bool}`. A card with none follows Settings › Work.
    static let autoSendCardsKey = "cos.workChatAutoSendCards"
    static func overrides(_ raw: String) -> [String: Bool] {
        guard let data = raw.data(using: .utf8), let v = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return v
    }
    static func autoSend(workID: String, raw: String, settingDefault: Bool) -> Bool { overrides(raw)[workID] ?? settingDefault }
    /// Sets this card's choice. Choosing the Settings default removes the override, so the card follows Settings again.
    static func setting(workID: String, on: Bool, raw: String, settingDefault: Bool) -> String {
        var v = overrides(raw)
        if on == settingDefault { v.removeValue(forKey: workID) } else { v[workID] = on }
        guard v.count <= 2000, let data = try? JSONEncoder().encode(v), let text = String(data: data, encoding: .utf8) else { return raw }
        return v.isEmpty ? "" : text
    }

    // MARK: Stop

    static func stopHelp(_ action: StopAction) -> String {
        switch action {
        case .unqueue: return "Stop: this assignment is not sent"
        case .cancelJob: return "Stop the new session's run"
        case .cancelTurn: return "Stop the session's running turn"
        case .unavailable(let why): return why
        case .none: return ""
        }
    }
    enum StopAction: Equatable, Sendable { case unqueue, cancelJob(String), cancelTurn(provider: String, threadID: String), unavailable(String), none }
    /// What Stop does for one auto-sent assignment, from its state and receipt.
    static func stopAction(state: String, queuedState: String, receiptStatus: String?, channel: String?, jobID: String?, sessionID: String?) -> StopAction {
        if state == queuedState || state == "Not sent" { return .unqueue }
        guard let status = receiptStatus, ["running", "queued", "sending"].contains(status) else { return .none }
        switch channel {
        case "job": return jobID.map { .cancelJob($0) } ?? .unavailable("The job has no id yet. Try again in a moment.")
        case "turn":
            guard let id = sessionID, let colon = id.firstIndex(of: ":") else { return .unavailable("The session is not known yet.") }
            return .cancelTurn(provider: String(id[..<colon]), threadID: String(id[id.index(after: colon)...]))
        case "fork": return .unavailable("A fork in progress cannot be stopped from here. Stop its copy in Sessions once it appears.")
        default: return .unavailable("This handoff cannot be stopped from here.")
        }
    }
}
