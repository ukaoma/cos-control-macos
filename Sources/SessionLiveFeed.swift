import Foundation

// The live Activity feed for a session pane (0.5.233).
//
// The glasses-server streams one JSON event per line for a session (SSE
// `/api/agent-sessions/:provider/:id/stream`, read through the helper's `session-stream`
// verb): `status` with the server's derived state, `prompt`, `tool`, `prose`, `heartbeat`.
// This is the pure reducer from those lines to what the pane draws: the current prompt,
// the last eight tool lines, the state line with its clock, and the model. Pure so the
// contract executes it on recorded lines; the view only paints it.
//
// CLEAR ON RESEED. The server seeds every new connection (the opening status, the
// newest prompt, the last steps), so a reconnect that appends would show each tool line
// twice. A reconnect passes the last `id` so the server replays only what was missed;
// when it seeds instead (the ring had nothing, the server restarted), `seq` restarts at
// 1 and the feed clears. The lens has the same rule.

struct SessionLiveEvent: Equatable, Sendable {
    let seq: Int
    let at: Date
    let kind: String
    /// `<epoch>.<cursor>` from the SSE id line; absent on seeded and heartbeat frames.
    let id: String?
    let state: String?
    let agentState: String?
    let stateSource: String?
    let stateSince: Date?
    let waitingKind: String?
    let waitingDetail: String?
    let failure: String?
    let lastReply: String?
    let text: String?
    let verb: String?
    let target: String?
    let detail: String?

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = raw["kind"] as? String,
              let seq = raw["seq"] as? Int else { return nil }
        self.seq = seq
        self.kind = kind
        self.at = (raw["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        self.id = raw["id"] as? String
        self.state = raw["state"] as? String
        self.agentState = raw["agent_state"] as? String
        self.stateSource = raw["state_source"] as? String
        self.stateSince = (raw["state_since"] as? String).flatMap(SessionLiveEvent.parseISO)
        self.waitingKind = raw["waiting_kind"] as? String
        self.waitingDetail = raw["waiting_detail"] as? String
        self.failure = raw["failure"] as? String
        self.lastReply = raw["last_reply"] as? String
        self.text = raw["text"] as? String
        self.verb = raw["verb"] as? String
        self.target = raw["target"] as? String
        self.detail = raw["detail"] as? String
    }

    static func parseISO(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: text)
    }
}

struct SessionLiveToolLine: Equatable, Identifiable, Sendable {
    let seq: Int
    let verb: String
    let target: String
    var id: Int { seq }
    /// "Read src/SignIn.tsx", "Ran npx prisma validate": the verb as a past-tense word.
    var line: String {
        let word: String = switch verb {
        case "read": "Read"
        case "edit", "write": "Edited"
        case "bash", "run": "Ran"
        case "search", "grep", "glob": "Searched"
        case "fetch", "web": "Fetched"
        case "agent", "task": "Delegated"
        default: verb.prefix(1).uppercased() + verb.dropFirst()
        }
        return target.isEmpty ? word : "\(word) \(target)"
    }
}

struct SessionLiveFeed: Equatable, Sendable {
    static let toolWindow = 8

    /// Transport state: `working | idle | done`.
    var state: String = "idle"
    /// The server's derived state when the stream carries it (server 6.48.1+).
    var agentState: String? = nil
    var stateSource: String? = nil
    var stateSince: Date? = nil
    var waitingKind: String? = nil
    var waitingDetail: String? = nil
    var failure: String? = nil
    var lastReply: String? = nil
    var prompt: String = ""
    var tools: [SessionLiveToolLine] = []
    var lastSeq: Int = 0
    var lastID: String? = nil
    var lastEventAt: Date? = nil
    /// Frames the connection missed (a `seq` gap), for the honest little counter.
    var missed: Int = 0
    var connected: Bool = false
    /// Set when the stream fell back to the polled turns and why.
    var fallbackReason: String? = nil

    /// Apply one event. Returns the feed after it; a reseed (`seq` 1 after anything
    /// else) clears what the previous connection drew.
    func applying(_ event: SessionLiveEvent) -> SessionLiveFeed {
        var next = self
        if event.seq == 1, lastSeq > 0 {
            next = SessionLiveFeed()
            next.connected = connected
            next.missed = 0
        } else if event.seq > next.lastSeq + 1, next.lastSeq > 0 {
            next.missed += event.seq - next.lastSeq - 1
        }
        next.lastSeq = event.seq
        next.lastEventAt = event.at
        if let id = event.id { next.lastID = id }
        switch event.kind {
        case "status":
            if let state = event.state { next.state = state }
            if let agentState = event.agentState {
                next.agentState = agentState
                next.stateSource = event.stateSource
                next.stateSince = event.stateSince
                next.waitingKind = event.waitingKind
                next.waitingDetail = event.waitingDetail
                next.failure = event.failure
                if let reply = event.lastReply { next.lastReply = reply }
            }
        case "prompt":
            next.prompt = event.text ?? ""
            // A new prompt is a new turn: the tool lines below it belong to that turn.
            next.tools = []
        case "tool":
            let line = SessionLiveToolLine(seq: event.seq, verb: event.verb ?? "tool", target: event.target ?? "")
            next.tools.append(line)
            if next.tools.count > SessionLiveFeed.toolWindow { next.tools.removeFirst(next.tools.count - SessionLiveFeed.toolWindow) }
        case "prose", "heartbeat":
            break
        default:
            break
        }
        return next
    }

    /// The state line: the word, then what it waits on or why it failed.
    var stateWord: String {
        switch agentState ?? state {
        case "running", "working": return "Working"
        case "waiting": return "Waiting"
        case "failed": return "Failed"
        case "ended", "done": return "Done"
        default: return "Idle"
        }
    }

    var stateDetail: String {
        switch agentState {
        case "waiting":
            let detail = (waitingDetail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch waitingKind {
            case "permission": return detail.isEmpty ? "Permission" : "Permission: \(detail)"
            case "question": return "Question"
            case "plan": return "Plan approval"
            case "mcp_input": return "Input"
            default: return detail
            }
        case "failed":
            return (failure ?? "").replacingOccurrences(of: "_", with: " ")
        case "idle":
            let reply = (lastReply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return reply.isEmpty ? "" : "last reply: \(reply)"
        default:
            return ""
        }
    }

    /// "4m 12s" since the state began; the view ticks it once a second.
    func elapsed(now: Date = Date()) -> String {
        guard let since = stateSince ?? lastEventAt else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
