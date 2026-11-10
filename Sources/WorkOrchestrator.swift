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

    /// 0.5.386 (Work chat "no session", Miles 2026-11-09): the server's `SID`. A full session id: provider, a colon and a
    /// UUID. The live list gives a running Claude CLI session by its first 8 characters (a privacy redaction), and one such
    /// row made the server refuse the whole snapshot (400 invalid_snapshot, invalid_live_row), so Plan failed on every card.
    static func validSessionID(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, ["claude", "codex", "cursor"].contains(String(parts[0])) else { return false }
        let groups = parts[1].split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }
    }
    /// The server's `WORK_ID`, within its 256 UTF-16 unit bound.
    static func validWorkID(_ value: String) -> Bool {
        guard value.utf16.count <= 256, let colon = value.firstIndex(of: ":") else { return false }
        let kind = value[..<colon], rest = value[value.index(after: colon)...]
        guard let first = kind.unicodeScalars.first, ("a"..."z").contains(first), kind.unicodeScalars.count <= 31,
              kind.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else { return false }
        return (1...250).contains(rest.utf16.count) && !rest.unicodeScalars.contains { $0.value < 0x20 }
    }
    /// The server's `str(v, n)`: at most `n` UTF-16 units (JavaScript's `length`, not Swift's characters) and no control
    /// character but tab, line feed and carriage return. This drops those characters, then cuts at the last whole
    /// character that fits, so an emoji is never split into half a surrogate pair.
    static func clamp(_ value: String, _ limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: value.unicodeScalars.filter { $0.value >= 0x20 || [0x09, 0x0a, 0x0d].contains($0.value) })
        let clean = String(scalars)
        guard clean.utf16.count > limit else { return clean }
        var out = "", units = 0
        for character in clean {
            let size = String(character).utf16.count
            if units + size > limit { break }
            out.append(character); units += size
        }
        return out
    }
    static let modes: Set<String> = ["continueSession", "fork", "newSession"]

    /// 0.5.386: what Control pushes and how many entries it left out because the server would refuse them.
    struct Snapshot {
        let body: [String: Any]
        let droppedLive: Int, droppedLinks: Int, droppedReceipts: Int
        var dropped: Int { droppedLive + droppedLinks + droppedReceipts }
    }

    /// The snapshot body, newest receipts first, each list bounded. `live` is nil when the session list could not be read.
    static func snapshot(links: [Link], receipts: [Receipt], live: [LiveRow]?, liveCheckedAt: Date?, controlVersion: String, now: Date) -> [String: Any] {
        checkedSnapshot(links: links, receipts: receipts, live: live, liveCheckedAt: liveCheckedAt, controlVersion: controlVersion, now: now).body
    }
    /// 0.5.386: every entry the server's `parseSnapshot` would refuse is left out here and counted, so one odd row never
    /// fails the plan. A live row needs a full session id; a link a full session id and a card id; a receipt a card id
    /// and a known mode (a session id it names that is not a full one goes as null, as the server reads it). Text is
    /// clamped in UTF-16 units, the way the server counts.
    static func checkedSnapshot(links: [Link], receipts: [Receipt], live: [LiveRow]?, liveCheckedAt: Date?, controlVersion: String, now: Date) -> Snapshot {
        func opt(_ s: String?) -> Any { s ?? NSNull() }
        func sid(_ s: String?) -> Any { s.flatMap { validSessionID($0) ? $0.lowercased() : nil } ?? NSNull() }
        let goodLinks = links.filter { validSessionID($0.sessionID) && validWorkID($0.workID) && $0.at.isFinite && $0.at > 0 }
        let goodReceipts = receipts.filter { validWorkID($0.workID) && modes.contains($0.mode) && $0.createdAt.isFinite && $0.createdAt > 0 && !clamp($0.id, 64).isEmpty }
        var body: [String: Any] = [
            "version": 1, "controlVersion": clamp(controlVersion, 40), "sentAt": now.timeIntervalSince1970,
            "links": goodLinks.sorted { $0.at > $1.at }.prefix(maxLinks).map { ["sessionID": $0.sessionID.lowercased(), "workID": $0.workID, "at": $0.at] as [String: Any] },
            "receipts": goodReceipts.sorted { $0.createdAt > $1.createdAt }.prefix(maxReceipts).map {
                ["id": clamp($0.id, 64), "workID": $0.workID, "mode": $0.mode, "provider": clamp($0.provider, 20),
                 "sessionID": sid($0.sessionID), "sourceSessionID": sid($0.sourceSessionID), "forkChildID": sid($0.forkChildID),
                 "status": clamp($0.status, 40), "createdAt": $0.createdAt] as [String: Any]
            },
            "live": NSNull(),
        ]
        var droppedLive = 0
        if let live, let checked = liveCheckedAt {
            let usable = live.filter { validSessionID($0.id) }
            droppedLive = live.count - usable.count
            let rows = usable.filter { !isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }.prefix(maxLive).map {
                ["id": $0.id.lowercased(), "title": clamp($0.title, 300), "status": clamp($0.status, 100),
                 "updatedAt": opt($0.updatedAt.flatMap { clamp($0, 40) == $0 ? $0 : nil }),
                 "busy": $0.busy, "waitingOnUser": $0.waitingOnUser, "appOwned": $0.appOwned, "summary": clamp($0.summary, 2000)] as [String: Any]
            }
            body["live"] = ["checkedAt": checked.timeIntervalSince1970, "rows": Array(rows)] as [String: Any]
        }
        return Snapshot(body: body, droppedLive: droppedLive, droppedLinks: links.count - goodLinks.count, droppedReceipts: receipts.count - goodReceipts.count)
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

    // MARK: An empty card (0.5.386, Miles 2026-11-09)

    /// Providers a New session may start on: one with an available model whose plan usage is not used up.
    static func newSessionProviders(available: Set<String>, usage: [Usage]) -> [String] {
        ["claude", "codex"].filter { p in available.contains(p) && usage.first(where: { $0.provider == p })?.state != "exhausted" }
    }
    /// The one provider an empty card's New session starts on: Claude (Opus), and Codex when Claude's usage is low or
    /// used up (a used-up provider is not offered at all). Nil when neither is offered.
    static func emptyCardProvider(offered: [String], usage: [Usage]) -> String? {
        let claudeLow = usage.first(where: { $0.provider == "claude" })?.state == "low"
        if offered.contains("claude") && !(claudeLow && offered.contains("codex")) { return "claude" }
        return offered.contains("codex") ? "codex" : nil
    }
    /// True when no row the planner sees can take a Continue or a Fork: the card has nothing to pick up.
    static func nothingToContinue(rows: [Row], automaticIDs: Set<String>, forkProviders: Set<String>) -> Bool {
        !rows.contains { automaticIDs.contains($0.id) || ($0.forkable && forkProviders.contains($0.provider)) }
    }
    /// The model a New session starts on: Claude's Opus when it is available, else the provider's first available model.
    static func preferredModel(provider: String, models: [(id: String, available: Bool)]) -> String? {
        let open = models.filter(\.available).map(\.id)
        if provider == "claude", let opus = open.first(where: { $0 == "opus" }) ?? open.first(where: { $0.lowercased().contains("opus") }) { return opus }
        return open.first
    }
    /// At most one New session per round on an empty card: the first is kept, any later one is left out.
    static func oneNewSession<T>(_ items: [T], isNew: (T) -> Bool) -> [T] {
        var seen = false
        return items.filter { item in
            guard isNew(item) else { return true }
            defer { seen = true }
            return !seen
        }
    }
    /// What the round says while it plans, and the one button it offers when the planner still answers without one.
    static func emptyCardPhase(_ provider: String) -> String { "No session on this task yet. Planning a new \(providerTitle(provider)) session\u{2026}" }
    static func emptyCardNote(_ provider: String) -> String { "No session on this task yet. COS will start a new \(providerTitle(provider)) session when you press Send." }
    static func startNewSessionTitle(_ provider: String) -> String { "Start a new \(providerTitle(provider)) session with this request" }
    static func providerTitle(_ provider: String) -> String { provider == "codex" ? "Codex" : provider == "cursor" ? "Cursor" : "Claude" }

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
        case .cancelQueued: return "Stop: take it out of the session's queue before it is sent"
        case .unavailable(let why): return why
        case .none: return ""
        }
    }
    enum StopAction: Equatable, Sendable {
        case unqueue, cancelJob(String), cancelTurn(provider: String, threadID: String)
        /// 0.5.337 (loop audit W7): parked in a busy session's queue (channel "queue"); session-chat-queue-cancel takes it out.
        case cancelQueued(provider: String, threadID: String, clientTurnID: String)
        case unavailable(String), none
    }
    /// What Stop does for one auto-sent assignment, from its state and receipt. `receiptID` is a queued turn's client turn
    /// id and `queueSessionID` the session it waits on (0.5.337).
    static func stopAction(state: String, queuedState: String, receiptStatus: String?, channel: String?, jobID: String?, sessionID: String?,
                           receiptID: String? = nil, queueSessionID: String? = nil) -> StopAction {
        if state == queuedState || state == "Not sent" { return .unqueue }
        guard let status = receiptStatus, ["running", "queued", "sending"].contains(status) else { return .none }
        switch channel {
        case "job": return jobID.map { .cancelJob($0) } ?? .unavailable("The job has no id yet. Try again in a moment.")
        case "turn":
            guard let id = sessionID, let colon = id.firstIndex(of: ":") else { return .unavailable("The session is not known yet.") }
            return .cancelTurn(provider: String(id[..<colon]), threadID: String(id[id.index(after: colon)...]))
        case "queue":
            guard let id = queueSessionID ?? sessionID, let colon = id.firstIndex(of: ":"), let turn = receiptID, !turn.isEmpty else {
                return .unavailable("The session it waits on is not known yet. Try again in a moment.")
            }
            return .cancelQueued(provider: String(id[..<colon]), threadID: String(id[id.index(after: colon)...]), clientTurnID: turn)
        case "fork": return .unavailable("A fork in progress cannot be stopped from here. Stop its copy in Sessions once it appears.")
        default: return .unavailable("This handoff cannot be stopped from here.")
        }
    }
    /// 0.5.337 (loop audit W6): a round sent after review gets Stop too, but only for what is running (a job, a turn, a
    /// queued turn). Its unsent rows keep their own Send and review, and a "cannot stop" line is not offered there.
    static func stopOffered(_ action: StopAction, sentWithoutReview: Bool) -> StopAction? {
        if action == .none { return nil }
        if sentWithoutReview { return action }
        switch action {
        case .cancelJob, .cancelTurn, .cancelQueued: return action
        default: return nil
        }
    }
    /// The queue cancel's answer (`state`): only "cancelled" stopped it; the rest say why, in plain words.
    static func queueCancelLine(state: String) -> (stopped: Bool, line: String) {
        switch state {
        case "cancelled": return (true, "Stopped. It was taken out of the session's queue and was not sent.")
        case "already_delivering": return (false, "Too late to stop: the session already has it.")
        case "unknown_turn": return (false, "It is no longer in the session's queue. Check the session.")
        default: return (false, "The server could not take it out of the queue. Update the COS server, or stop it in Sessions.")
        }
    }
}
