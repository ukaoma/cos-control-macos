import Combine
import Foundation
import ImageIO

// MARK: Drop it (0.5.371, server Drop it P1)
//
// Plan: operations/personal/wk45_2026/PLAN_drop_it_2026-11-04.md (Miles, 2026-11-04, all decided). Approved mock:
// operations/personal/wk45_2026/drop-it-mock. A pinned COS chat sits at the top of Messages: he texts COS (a drop), COS files it
// and texts back a receipt, asks one question when it is not sure, and posts the answer to a question. The rest of Messages is
// unchanged. Off by default on the server; with it off, or on a server without it (capabilities.dropIt), nothing here shows.
//
// This file is the rules and the store, Foundation only, so Tests/DropItChecks.swift runs it with Models.swift alone. The views
// are Sources/DropItViews.swift. The helper's `drop-it --op ...` reaches the server (HelperSources/main.swift).
//
// SECRET BOUNDARY. A drop's words, a chat line and a History search go to the helper on stdin (never argv) and come back in its
// answer to the chat. They reach no Logger, print, NSLog, notice or error: a failure is a fixed line or the server's own one-line
// reason, which never quotes the words.

enum DropIt {
    // MARK: Words (the mock's, verbatim where it has them)

    static let rowName = "COS"
    static let rowEmpty = "Text COS a thought, an ask or a reminder."
    static let pinNote = "Your drops, what COS did with them, and its pings live in the pinned chat. Everything below works as it always has."
    static let chatLine = "Text it anything: a thought, an ask, a reminder. It texts back."
    static let allMessages = "All messages"
    static let historyLink = "History"
    static let markAllRead = "Mark all read"
    static let placeholder = "Ask COS, or drop a thought, a task, a reminder"
    static let sendLabel = "Drop it"
    /// 0.5.371 option A (Miles, 2026-11-05): two buttons, as on the web. Ask (filled) gets an answer from COS; Drop (outlined)
    /// files it. Return asks, Option-Return drops, Shift-Return starts a new line.
    static let askLabel = "Ask"
    static let dropLabel = "Drop"
    static let askingLine = "Asking…"
    static let footReturn = "Return asks. Option-Return drops it."
    static let footNothingOut = "A drop never sends anything to anyone."
    static let chatEmpty = "Nothing here yet. Ask COS something, or drop a thought and COS files it."
    static let historyTitle = "History"
    static let historyLine = "Everything you dropped, where it went, and how it ended."
    static let backToChat = "Back to the COS chat"
    static let backToChatShort = "Back to the chat"
    static let cameBack = "Opened from your COS chat."
    static let cameBackCard = "Opened from your COS chat. The selected card is your drop."
    static let cameBackThread = "Opened from your COS chat. Your drop is a note on this thread."
    static let cameBackMemory = "Opened from your COS chat. Your drop waits in To review."
    static let historySearch = "Search what you said"
    static let historyEmpty = "Nothing dropped yet. What you drop in the COS chat is listed here."
    static let historyMiss = "No drop matches. Try fewer words, or another kind or status."
    static let historyFoot = "Undone drops stay here so you can find them again."
    static let moveTitle = "Move this to"
    static let moveFind = "Find a thread"
    static let moveHere = "Move here"
    static let moveCancel = "Cancel"
    static let moveNote = "Where it is now goes away. This reply keeps where it went."
    static let sendingLine = "Dropping…"
    static let dictateHelp = "Dictate into the box with Mac dictation"

    static let offLine = "Drop it is off on this server. Turn it on in Settings, Work and agents."
    static let oldServerLine = "Drop it needs a newer COS server."
    static let unreachableLine = "The COS server is not answering. Your words are still in the box."
    static let noTokenLine = "COS Control is not paired with the COS server yet."
    static let failedLine = "That did not go through. Try again."
    static let tooLongLine = "A drop is 1 to 2,000 characters."
    static let askHeldLine = "COS will answer here once Work runs from Today is on in Settings."
    static let sendSessionLine = "Opened the session. Send it from there; sending from the chat comes in a later update."
    static let notFoundLine = "COS could not find that here."

    /// Settings, Work and agents, Work chat (DROP-01).
    static let settingLabel = "Drop it"
    static let settingDetail = "A pinned COS chat at the top of Messages. Type a thought, an ask or a reminder, and COS files it and texts back. ⌘K's File to Work becomes Drop it."
    static let settingEnvLine = "The COS server's COS_DROP_IT setting decides this, so the switch here waits until that is removed."

    /// The server's DROP_LIMITS.text, in code points.
    static let textMax = 2_000

    // MARK: The contract's shapes

    struct Link: Equatable, Hashable, Sendable {
        var kind: String
        var id: String
        var label: String
        var domain: String?
    }
    struct Action: Equatable, Hashable, Sendable {
        var id: String
        var label: String
        var isChoice: Bool { id.hasPrefix("choose:") }
        var isOpen: Bool { id.hasPrefix("open_") || id == "send_to_session" }
    }
    struct Item: Identifiable, Equatable, Sendable {
        var id: String
        /// drop, receipt, question, followup, ping, answer.
        var kind: String
        var threadId: String
        var createdAt: Date
        var readAt: Date?
        /// mac, web, g2, telegram, cos.
        var source: String
        var title: String?
        var line: String
        var links: [Link]
        var actions: [Action]
        /// Its buttons work (live) or it was answered or superseded (done).
        var live: Bool
        var undoUntil: Date?
        /// His own words: a drop, or the choice he tapped.
        var fromYou: Bool { kind == "drop" || kind == "answer" }
        /// Counted on the pinned row until read (the server's summary counts the same three).
        var countsUnread: Bool { readAt == nil && (kind == "ping" || kind == "followup" || kind == "question") }
    }
    struct Target: Equatable, Hashable, Sendable {
        var id: String
        var label: String
        var domain: String?
    }
    struct Choice: Equatable, Sendable {
        var id: String
        var dest: String
        var label: String
        var detail: String
        var target: Target?
    }
    struct Drop: Identifiable, Equatable, Sendable {
        var id: String
        var text: String
        var source: String
        var createdAt: Date
        var state: String
        var dest: String?
        var kind: String
        /// open, in_progress, done, undone (History).
        var status: String
        var links: [Link]
        var undoUntil: Date?
        var canUndo: Bool
        var choices: [Choice]
        var holdLabel: String?
        var fileName: String?
    }
    struct Answer: Equatable, Sendable {
        var drop: Drop
        var items: [Item]
        var replayed: Bool
        /// The server's `next: {kind: 'ask', prompt}`: Control submits the existing Ask job, then links it (POST /drops/:id/ask).
        var askPrompt: String?
        /// 6.99.13: a drop with files that became a question carries them on (`next.attachmentIds`), so the Ask sees the files.
        var askAttachmentIds: [String] = []
    }
    struct Summary: Equatable, Sendable {
        var unread = 0
        var lastLine = ""
        var lastAt: Date?
        var version = 0
        /// 0.5.371 (plan section 12): COS questions he has not answered and pings that need a reply. Unread clears on open;
        /// waiting clears only when answered. nil on a server that does not send it: then the rail shows no number.
        var waiting: Int? = nil
    }
    struct Settings: Equatable, Sendable {
        var enabled: Bool
        /// COS_DROP_IT in the server's environment decides, so a saved switch does not change it.
        var envDecides: Bool
    }

    // MARK: Reading the helper's answers

    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.string else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
    static func link(_ value: JSONValue) -> Link? {
        guard let o = value.object, let kind = o["kind"]?.string, let id = o["id"]?.string, let label = o["label"]?.string else { return nil }
        return Link(kind: kind, id: id, label: label, domain: o["domain"]?.string)
    }
    static func item(_ value: JSONValue) -> Item? {
        guard let o = value.object, let id = o["id"]?.string, let kind = o["kind"]?.string, let thread = o["threadId"]?.string,
              let created = date(o["createdAt"]), let source = o["source"]?.string, let line = o["line"]?.string else { return nil }
        return Item(id: id, kind: kind, threadId: thread, createdAt: created, readAt: date(o["readAt"]), source: source,
                    title: o["title"]?.string, line: line, links: (o["links"]?.array ?? []).compactMap(link),
                    actions: (o["actions"]?.array ?? []).compactMap { a in
                        guard let id = a.object?["id"]?.string, let label = a.object?["label"]?.string else { return nil }
                        return Action(id: id, label: label)
                    },
                    live: o["state"]?.string == "live", undoUntil: date(o["undoUntil"]))
    }
    static func drop(_ value: JSONValue?) -> Drop? {
        guard let o = value?.object, let id = o["id"]?.string, let text = o["text"]?.string, let source = o["source"]?.string,
              let created = date(o["createdAt"]), let state = o["state"]?.string, let kind = o["kind"]?.string, let status = o["status"]?.string else { return nil }
        let choices: [Choice] = (o["choices"]?.array ?? []).compactMap { c in
            guard let c = c.object, let id = c["id"]?.string, let dest = c["dest"]?.string, let label = c["label"]?.string else { return nil }
            let target = c["target"]?.object.flatMap { t -> Target? in
                guard let tid = t["id"]?.string, let tl = t["label"]?.string else { return nil }
                return Target(id: tid, label: tl, domain: t["domain"]?.string)
            }
            return Choice(id: id, dest: dest, label: label, detail: c["detail"]?.string ?? "", target: target)
        }
        return Drop(id: id, text: text, source: source, createdAt: created, state: state, dest: o["dest"]?.string, kind: kind, status: status,
                    links: (o["links"]?.array ?? []).compactMap(link), undoUntil: date(o["undoUntil"]), canUndo: o["canUndo"]?.bool == true,
                    choices: choices, holdLabel: o["hold"]?.object?["label"]?.string, fileName: o["file"]?.object?["displayName"]?.string)
    }
    static func answer(_ details: [String: JSONValue]) -> Answer? {
        guard let drop = drop(details["drop"]) else { return nil }
        let prompt = details["next"]?.object.flatMap { $0["kind"]?.string == "ask" ? $0["prompt"]?.string : nil }
        let files = prompt == nil ? [] : (details["next"]?.object?["attachmentIds"]?.array ?? []).compactMap(\.string).filter(mediaIDValid)
        return Answer(drop: drop, items: (details["items"]?.array ?? []).compactMap(item), replayed: details["replayed"]?.bool == true, askPrompt: prompt,
                      askAttachmentIds: Array(files.prefix(maxAttachments)))
    }
    static func summary(_ details: [String: JSONValue]) -> Summary {
        Summary(unread: max(0, details["unread"]?.int ?? 0), lastLine: details["lastLine"]?.string ?? "", lastAt: date(details["lastAt"]),
                version: details["version"]?.int ?? 0, waiting: details["waiting"]?.int.map { max(0, $0) })
    }

    /// What the Messages rail item carries (plan section 12): a number for what COS is waiting on him to answer, else a dot for
    /// unread, else nothing. Nothing at all while Drop it is not available, and no number from a server that sends no `waiting`.
    enum RailMark: Equatable, Sendable { case none, dot, count(Int) }
    static func railMark(_ summary: Summary, available: Bool) -> RailMark {
        guard available else { return .none }
        if let waiting = summary.waiting, waiting > 0 { return .count(waiting) }
        return summary.unread > 0 ? .dot : .none
    }
    static func railMarkLabel(_ mark: RailMark) -> String? {
        switch mark {
        case .none: nil
        case .dot: "unread in your COS chat"
        case .count(let n): n == 1 ? "COS is waiting on 1 answer" : "COS is waiting on \(n) answers"
        }
    }

    /// What one helper answer means.
    enum Reply: Sendable {
        case ok([String: JSONValue])
        /// The server answered with a refusal: its code (or nil) and the line to show.
        case refused(code: String?, line: String)
        /// 404 drop_it_off: the switch is off on the server.
        case off
        /// No such route: a server from before Drop it.
        case unsupported
        case unreachable
        case noToken
    }

    static func reply(_ details: [String: JSONValue]?) -> Reply {
        guard let details else { return .unreachable }
        switch details["transport"]?.string {
        case "off": return .off
        case "unsupported": return .unsupported
        case "no_token": return .noToken
        case "answered": break
        default: return .unreachable
        }
        let status = details["httpStatus"]?.int ?? 0
        if status == 200 { return .ok(details) }
        let code = details["error"]?.string
        return .refused(code: code, line: refusalLine(code: code, message: details["message"]?.string, status: status))
    }

    /// The line a refusal shows: our own for the few codes Control words itself, else the server's plain one-line reason (the QA
    /// round adds codes this build does not know, and its message says what happened), else a fixed line. Never a raw code.
    static func refusalLine(code: String?, message: String?, status: Int) -> String {
        switch code {
        case "drop_it_off": return offLine
        case "invalid_text": return tooLongLine
        case "drop_not_found", "feed_item_not_found", "question_not_found": return notFoundLine
        default: break
        }
        if let message, !message.isEmpty, message.count <= 300, !message.contains("\n") { return message }
        if status == 404 { return oldServerLine }
        return failedLine
    }

    /// The line for a reply that is not `.ok`, or nil for `.ok`.
    static func line(_ reply: Reply) -> String? {
        switch reply {
        case .ok: nil
        case .refused(_, let line): line
        case .off: offLine
        case .unsupported: oldServerLine
        case .unreachable: unreachableLine
        case .noToken: noTokenLine
        }
    }

    /// ⌘K's line after a drop: what the receipt says, and where the rest is.
    static func commandNote(_ answer: Answer) -> String {
        let last = answer.items.last { !$0.fromYou }
        if last?.kind == "question" { return "COS is not sure where this goes. Answer it in your COS chat." }
        if answer.askPrompt != nil { return "Asking COS. The answer lands in your COS chat." }
        guard let title = last?.title, !title.isEmpty else { return "Dropped. It is in your COS chat." }
        return title + ". It is in your COS chat."
    }

    /// The link an open action follows on a chat item.
    static func link(for action: Action, in item: Item) -> Link? {
        let kind: String
        switch action.id {
        case "open_card": kind = "card"
        case "open_thread": kind = "thread"
        case "open_memory": kind = "memory"
        case "open_session", "send_to_session": kind = "session"
        default: return nil
        }
        return item.links.first { $0.kind == kind }
    }
    /// History's Open: the action its first link stands for, or nil to go back to the chat.
    static func openAction(for drop: Drop) -> String? {
        guard drop.state != "undone" else { return nil }
        switch drop.links.first?.kind {
        case "card": return "open_card"
        case "thread": return "open_thread"
        case "memory": return "open_memory"
        case "session": return "open_session"
        default: return nil
        }
    }

    // MARK: Calls (the helper's `drop-it`)

    static func call(_ op: String, _ extra: [String] = []) -> [String] { ["drop-it", "--op", op] + extra }

    static func json(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    /// The words, trimmed as the server trims them. nil when there is nothing to drop or it is too long.
    static func cleaned(_ text: String) -> String? {
        let words = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.unicodeScalars.count <= textMax else { return nil }
        return words
    }

    /// A drop: its id and the words on stdin, never in the arguments. 0.5.371: with files only for a server that takes them
    /// (`capabilities.dropIt.attachments`, 6.99.13); the store refuses before this on an older one.
    static func submitCall(dropId: String, text: String, attachmentIds: [String] = []) -> (arguments: [String], stdin: Data)? {
        guard let words = cleaned(text) else { return nil }
        var body: [String: Any] = ["dropId": dropId, "text": words]
        if !attachmentIds.isEmpty { body["attachmentIds"] = Array(attachmentIds.prefix(maxAttachments)) }
        guard let data = json(body) else { return nil }
        return (call("submit"), data)
    }

    /// History: the words on stdin; kind and status from the server's sets.
    static func historyCall(query: String, kind: String?, status: String?, limit: Int = 100) -> (arguments: [String], stdin: Data)? {
        var body: [String: Any] = ["limit": limit]
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { body["q"] = String(words.prefix(200)) }
        if let kind { body["kind"] = kind }
        if let status { body["status"] = status }
        guard let data = json(body) else { return nil }
        return (call("history"), data)
    }

    static func moveCall(dropId: String, dest: String, target: Target?) -> (arguments: [String], stdin: Data)? {
        var body: [String: Any] = ["dest": dest]
        if let target {
            var t: [String: Any] = ["id": target.id, "label": String(target.label.prefix(200))]
            if let domain = target.domain { t["domain"] = domain }
            body["target"] = t
        }
        guard let data = json(body) else { return nil }
        return (call("move", ["--drop", dropId]), data)
    }

    /// A new drop id: the server's DROP_ID is a lowercase UUID v4.
    static func newDropID() -> String { UUID().uuidString.lowercased() }

    // MARK: The chat's layout

    enum Row: Identifiable, Equatable, Sendable {
        /// The day and time above a cluster: `day` only where the day changes ("Today", "Yesterday", "Monday", "Oct 30").
        case separator(id: String, day: String?, time: String)
        /// "2 new" above the first item he had not read when the chat opened.
        case newLine(id: String, count: Int)
        case item(Item)
        var id: String {
            switch self {
            case .separator(let id, _, _), .newLine(let id, _): id
            case .item(let item): item.id
            }
        }
    }

    /// A new separator when the day changes, or after a gap of this long.
    static let separatorGap: TimeInterval = 10 * 60

    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        f.dateFormat = (0..<7).contains(days) ? "EEEE" : "MMM d"
        return f.string(from: date)
    }
    static func timeLabel(_ date: Date, calendar: Calendar, twentyFour: Bool = false) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = twentyFour ? "HH:mm" : "h:mm a"
        return f.string(from: date)
    }

    /// Oldest first, as the server sends them. `firstNew`: the item the "N new" line goes above (nil: none).
    static func rows(_ items: [Item], firstNew: String?, newCount: Int, now: Date, calendar: Calendar = .current, twentyFour: Bool = false) -> [Row] {
        var rows: [Row] = []
        var previous: Item?
        for item in items {
            if item.id == firstNew, newCount > 0 { rows.append(.newLine(id: "new-" + item.id, count: newCount)) }
            let time = timeLabel(item.createdAt, calendar: calendar, twentyFour: twentyFour)
            if let previous, calendar.isDate(previous.createdAt, inSameDayAs: item.createdAt) {
                if item.createdAt.timeIntervalSince(previous.createdAt) >= separatorGap {
                    rows.append(.separator(id: "sep-" + item.id, day: nil, time: time))
                }
            } else {
                rows.append(.separator(id: "sep-" + item.id, day: dayLabel(item.createdAt, now: now, calendar: calendar), time: time))
            }
            rows.append(.item(item))
            previous = item
        }
        return rows
    }

    /// The "N new" line: the first unread item and how many there are, from the chat as it opened.
    static func newMark(_ items: [Item]) -> (first: String, count: Int)? {
        let unread = items.filter(\.countsUnread)
        guard let first = unread.first else { return nil }
        return (first.id, unread.count)
    }

    /// Where his words came from, under his bubble.
    static func sourcePhrase(_ source: String) -> String {
        switch source {
        case "mac": "Typed on this Mac"
        case "web": "Typed on the phone"
        case "g2": "Dictated on the glasses"
        case "telegram": "Sent from Telegram"
        default: ""
        }
    }

    /// The glyph a COS card carries: by what it points at.
    enum Glyph: String, Sendable { case work, thread, memory, session, reminder, note, question, answer }
    static func glyph(_ item: Item) -> Glyph {
        if item.kind == "question" { return .question }
        switch item.links.first?.kind {
        case "card", "handoff": return .work
        case "thread": return .thread
        case "memory": return .memory
        case "session": return item.kind == "followup" ? .answer : .session
        case "reminder": return .reminder
        case "ask": return .answer
        default: return item.kind == "followup" ? .answer : .note
        }
    }

    /// The card's buttons: one primary (the first open), then quiet links. Choices are drawn as their own rows.
    static func buttons(_ item: Item) -> (primary: Action?, quiet: [Action]) {
        guard item.live else { return (nil, []) }
        let plain = item.actions.filter { !$0.isChoice }
        let primary = plain.first(where: \.isOpen)
        return (primary, plain.filter { $0 != primary })
    }

    /// The followup's quote of his drop: "You, 1:12 PM" and the words, one line.
    static func quote(for item: Item, in items: [Item], calendar: Calendar = .current) -> (who: String, words: String)? {
        guard item.kind == "followup" || item.kind == "ping", let drop = items.first(where: { $0.kind == "drop" && $0.threadId == item.threadId }) else { return nil }
        return ("You, " + timeLabel(drop.createdAt, calendar: calendar), drop.line)
    }

    // MARK: The pinned row

    /// "Today 2:00 PM", "Yesterday 5:40 PM", "Nov 2 4:10 PM".
    static func rowTime(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        return dayLabel(date, now: now, calendar: calendar) + " " + timeLabel(date, calendar: calendar)
    }
    static func rowLine(_ summary: Summary) -> String {
        let line = summary.lastLine.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? rowEmpty : line
    }
    static func unreadLabel(_ count: Int) -> String? { count > 0 ? (count > 99 ? "99+" : String(count)) : nil }

    // MARK: History

    /// The kinds History filters by, as the mock lists them (All first). The values are the server's kinds.
    static let historyKinds: [(value: String?, title: String)] = [(nil, "All"), ("idea", "Ideas"), ("task", "Tasks"), ("note", "Notes"),
                                                                    ("memory", "Memories"), ("file", "Files"), ("reminder", "Reminders")]
    static let historyStatuses: [(value: String?, title: String)] = [(nil, "Any"), ("open", "Open"), ("in_progress", "In progress"),
                                                                       ("done", "Done"), ("undone", "Undone")]
    static func statusTitle(_ status: String) -> String {
        historyStatuses.first { $0.value == status }?.title ?? "Open"
    }
    static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "idea": "Idea"
        case "task": "Task"
        case "note": "Note"
        case "memory": "Memory"
        case "file": "File"
        case "reminder": "Reminder"
        case "ask": "Question"
        default: "Note"
        }
    }
    /// "Task, typed on this Mac", "Idea, dictated on the glasses. You undid it."
    static func kindLine(_ drop: Drop) -> String {
        let phrase = sourcePhrase(drop.source)
        let head = kindTitle(drop.kind) + (phrase.isEmpty ? "" : ", " + phrase.prefix(1).lowercased() + phrase.dropFirst())
        return drop.status == "undone" ? head + ". You undid it." : head
    }
    /// "Where it went", from its links and destination.
    static func whereItWent(_ drop: Drop) -> String {
        if drop.state == "undone" { return "Nowhere now" }
        if drop.state == "asking" { return "Waiting for your answer" }
        let link = drop.links.first
        switch drop.dest {
        case "new_card", "existing_card": return "Work, " + (link?.label ?? "Inbox")
        case "thread": return (link?.label ?? "A") + " thread"
        case "memory": return "A memory, to review"
        case "session": return "Session, " + (drop.holdLabel ?? link?.label ?? "held")
        case "reminder": return "Reminder"
        case "ask": return "Asked COS"
        default: return drop.kind == "idea" ? "An idea" : "A plain note"
        }
    }
    static func glyph(for drop: Drop) -> Glyph {
        switch drop.dest {
        case "new_card", "existing_card": .work
        case "thread": .thread
        case "memory": .memory
        case "session": .session
        case "reminder": .reminder
        case "ask": .answer
        default: .note
        }
    }

    // MARK: Move

    /// One place Move offers.
    struct Destination: Identifiable, Equatable, Sendable {
        var dest: String
        var target: Target?
        var title: String
        var detail: String
        var glyph: Glyph
        var id: String { dest + ":" + (target?.id ?? "") }
    }

    /// What Move offers for a drop: each Work area as a new card, the threads he has (filtered by the search words, at most
    /// five), a memory, and a plain note. Where it is now is listed first and cannot be picked.
    static func destinations(domains: [(name: String, label: String)], threads: [(id: String, title: String)], search: String) -> [Destination] {
        var out: [Destination] = domains.prefix(4).map {
            Destination(dest: "new_card", target: Target(id: $0.name, label: $0.label, domain: $0.name), title: "Work, " + $0.label, detail: "a new card in the Inbox", glyph: .work)
        }
        let words = search.lowercased().split(separator: " ").map(String.init)
        let matching = threads.filter { thread in words.allSatisfy { thread.title.lowercased().contains($0) } }
        out += matching.prefix(5).map { Destination(dest: "thread", target: Target(id: $0.id, label: $0.title), title: $0.title, detail: "thread", glyph: .thread) }
        out.append(Destination(dest: "memory", target: nil, title: "A memory", detail: "", glyph: .memory))
        out.append(Destination(dest: "note", target: nil, title: "A plain note", detail: "", glyph: .note))
        return out
    }
    /// Whether a destination is where the drop is now (it shows "Here now" and cannot be picked).
    static func isCurrent(_ destination: Destination, drop: Drop?) -> Bool {
        guard let drop else { return false }
        switch destination.dest {
        case "new_card": return (drop.dest == "new_card" || drop.dest == "existing_card") && drop.links.first?.domain == destination.target?.domain
        case "thread": return drop.dest == "thread" && drop.links.first?.id == destination.target?.id
        case "memory", "note": return drop.dest == destination.dest
        default: return false
        }
    }
}

// MARK: Ask and attachments (0.5.371 option A, Miles 2026-11-05)
//
// "I like your recommendation so long as it includes the attachment functionality for rich media. Should work similar to the drag
// and drop on meetings with files." The composer takes photos, video, PDFs and documents by drop, paste or Add, up to five per
// message, with the limits the server's Ask uploads have (server/web-control/panes/cos-chat.js, 6.99.12, is the reference). Each
// file goes up at once (POST /api/media for a photo, resized here to a 1024 px JPEG; POST /api/media/file for the rest) through
// the helper's `drop-it --op upload`; Ask sends the media ids with the words through Control's existing Ask (a Today Work run,
// `work-new`, POST /api/query-jobs), and Drop sends them only to a server that says it takes them.

extension DropIt {
    /// MAX_ATTACHMENTS_PER_PROMPT, and the server's per-kind limits (image-safety.ts, rich-media-safety.ts).
    static let maxAttachments = 5
    static let photoMaxBytes: Int64 = 2 * 1024 * 1024
    static let docMaxBytes: Int64 = 64 * 1024 * 1024
    static let videoMaxBytes: Int64 = 100 * 1024 * 1024
    static let photoEdge = 1024
    static let photoQuality = 0.85
    /// An Ask's words: the composer's, up to what a Today run takes. A drop keeps its 2,000.
    static let askTextMax = 20_000

    static let attachHelp = "Attach photos or files"
    static let addLabel = "Add"
    static let pasteLabel = "Paste"
    static let dropZoneLine = "Drop photos, video, PDFs or documents here, or paste a screenshot."
    static let dropZoneTarget = "Drop to attach to this message"
    static let attachKinds = "COS takes photos, PDF, TXT, MD, CSV, JSON, XLSX, MP4 and MOV."
    static let dropWordsOnlyLine = "Drop takes words only on this server. Ask sends the files, or update the COS server."
    static let filesWaitLine = "Wait for the files to finish uploading, then send."
    static let fileFailedLine = "A file did not upload. Retry it or remove it, then send."
    static let askTooLongLine = "An ask is 1 to 20,000 characters."
    static let askSource = "Asked on this Mac"
    static let askWaiting = "COS is answering. It also lands in Messages."
    static let askFailedLine = "COS could not finish this answer. Ask again when you are ready."
    static let nothingToPasteLine = "There is no screenshot or file to paste."
    static let linkNotFileLine = "A link goes in the words, not as a file."

    static func mediaIDValid(_ id: String) -> Bool { id.range(of: "\\Am_[a-f0-9]{24}\\z", options: .regularExpression) != nil }

    /// What a file is to COS.
    enum FileKind: String, Sendable, Equatable { case photo, doc, video }
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff"]
    static let docTypes: [String: String] = ["pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown", "csv": "text/csv",
                                             "json": "application/json", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]
    static let videoTypes: [String: String] = ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime"]

    static func sizeText(_ bytes: Int64) -> String {
        if bytes >= 1_048_576 {
            let mb = Double(bytes) / 1_048_576
            return (mb >= 10 ? String(Int(mb.rounded())) : String(format: "%.1f", mb)) + " MB"
        }
        return String(max(1, Int((Double(bytes) / 1024).rounded()))) + " KB"
    }

    /// The kind and type a file goes up as, or the sentence that says why it cannot be attached. `secret`: the card files' rule
    /// (WorkCardFiles.looksSecret), so a key or an .env is never attached.
    static func classify(name: String, bytes: Int64, secret: Bool = false) -> Result<(kind: FileKind, mime: String), FileRefusal> {
        if secret { return .failure(FileRefusal(name + " looks like a secrets file, so it was not attached.")) }
        let ext = (name as NSString).pathExtension.lowercased()
        if photoExtensions.contains(ext) { return .success((.photo, "image/jpeg")) }
        if let mime = videoTypes[ext] {
            guard bytes <= videoMaxBytes else { return .failure(FileRefusal(name + " is " + sizeText(bytes) + ". The largest video COS takes is 100 MB.")) }
            return .success((.video, mime))
        }
        if let mime = docTypes[ext] {
            guard bytes <= docMaxBytes else { return .failure(FileRefusal(name + " is " + sizeText(bytes) + ". The largest file COS takes is 64 MB.")) }
            return .success((.doc, mime))
        }
        return .failure(FileRefusal(name + " cannot be attached. " + attachKinds))
    }
    /// A sent file's kind from its name, for its symbol.
    static func fileKind(name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        return photoExtensions.contains(ext) ? .photo : videoTypes[ext] != nil ? .video : .doc
    }
    struct FileRefusal: Error, Equatable, Sendable { var line: String; init(_ line: String) { self.line = line } }
    /// One file handed to the composer: where it is, its name, and whether the composer made the copy (and removes it).
    struct Incoming: Equatable, Sendable { var url: URL; var name: String; var owned: Bool }

    /// One file on the composer.
    struct Attachment: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable { case preparing, uploading, ready, failed }
        var id: String
        var name: String
        var kind: FileKind
        var mime: String
        var bytes: Int64
        /// What goes up: the file itself, or (a photo) its resized copy.
        var source: URL
        /// The photo's resized copy, for the thumbnail.
        var thumb: URL?
        var state: State = .preparing
        var mediaId: String?
        var error: String?
        /// Copies this composer made (a paste, a resized photo): removed with the attachment.
        var owned: [URL] = []
        var busy: Bool { state == .preparing || state == .uploading }
        var meta: String {
            switch state {
            case .preparing: kind == .photo ? "Resizing" : "Preparing"
            case .uploading: "Uploading"
            case .failed: error ?? "Did not upload"
            case .ready: sizeText(bytes)
            }
        }
    }

    /// Why Ask cannot go yet, or nil. The words are required (a Today run is words first); every file must be up.
    static func askBlock(text: String, files: [Attachment]) -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return "" }
        guard words.unicodeScalars.count <= askTextMax else { return askTooLongLine }
        if files.contains(where: \.busy) { return filesWaitLine }
        if files.contains(where: { $0.state == .failed }) { return fileFailedLine }
        return nil
    }

    /// Why Drop cannot take these files, or nil. A server that does not advertise `dropIt.attachments` takes words only: the
    /// drop is refused with the files, never sent without them.
    static func dropBlock(files: [Attachment], serverTakes: Int?) -> String? {
        guard !files.isEmpty else { return nil }
        guard let takes = serverTakes, takes > 0 else { return dropWordsOnlyLine }
        if files.count > takes { return "This COS server takes up to \(takes) files on a drop. Remove some, or Ask instead." }
        if files.contains(where: \.busy) { return filesWaitLine }
        if files.contains(where: { $0.state == .failed }) { return fileFailedLine }
        return nil
    }

    /// The media ids of the files that are up, in order, never more than five.
    static func readyIDs(_ files: [Attachment]) -> [String] {
        var out: [String] = []
        for id in files.filter({ $0.state == .ready }).compactMap(\.mediaId) where mediaIDValid(id) && !out.contains(id) { out.append(id) }
        return Array(out.prefix(maxAttachments))
    }

    /// The upload: the file's path and its name on stdin (never argv), and what it is.
    static func uploadCall(_ file: Attachment, capturedAt: Date) -> (arguments: [String], stdin: Data)? {
        let stamp = ISO8601DateFormatter().string(from: capturedAt)
        guard file.source.isFileURL, let data = json(["path": file.source.path, "name": String(file.name.prefix(120)), "kind": file.kind.rawValue,
                                                     "mime": file.mime, "capturedAt": stamp]) else { return nil }
        return (call("upload"), data)
    }

    /// The server's media id, or the chip's words for why it did not go up (web parity: UPLOAD_COPY).
    static func uploadResult(_ reply: Reply) -> Result<String, FileRefusal> {
        switch reply {
        case .ok(let details):
            guard let id = details["mediaId"]?.string, mediaIDValid(id) else { return .failure(FileRefusal("The Mac did not keep the file")) }
            return .success(id)
        case .refused(let code, _):
            switch code {
            case "batch_too_large": return .failure(FileRefusal("Too large for one upload"))
            case "too_many_images": return .failure(FileRefusal("Up to 5 attachments per message"))
            case "media_processing_unavailable": return .failure(FileRefusal("The Mac cannot read photos right now"))
            case "unsupported_kind", "unsupported_media_type": return .failure(FileRefusal("COS cannot read this kind of file"))
            case "file_too_large", "attachment_too_large", "payload_too_large": return .failure(FileRefusal("Too large for COS"))
            case "server_maintenance": return .failure(FileRefusal("The Mac is updating. Retry in a minute"))
            default: return .failure(FileRefusal("Did not upload"))
            }
        case .unsupported: return .failure(FileRefusal("This COS server takes no files. Update it"))
        case .unreachable: return .failure(FileRefusal("The COS server did not answer. Retry"))
        case .noToken: return .failure(FileRefusal("Not paired with the COS server"))
        case .off: return .failure(FileRefusal("Did not upload"))
        }
    }

    /// A photo at most 1024 px on its longest edge, as a JPEG at quality 0.85, transparency on white (web parity: resizePhoto).
    static func photoJPEG(_ source: URL) -> Data? {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: photoEdge]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let w = scaled.width, h = scaled.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(scaled, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: photoQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// An Ask from this Mac, as the chat shows it: his words and files on the right, the answer under it. In memory, like the web's.
    struct Ask: Identifiable, Equatable, Sendable {
        struct File: Equatable, Sendable { var name: String; var kind: FileKind; var thumb: URL? }
        var id: String
        var words: String
        var files: [File]
        var at: Date
        /// What the run says so far: its state, its words, and the Messages number the server gave it.
        var status = "running"
        var answer: String?
        var number: Int?
        var finished: Bool { ["completed", "failed", "canceled", "refused"].contains(status) }
    }
    /// What the window reads back for an Ask (the Work receipt behind it).
    struct AskState: Equatable, Sendable { var status: String; var answer: String?; var number: Int? }

    /// An Ask as a chat item, so it takes its place among the drops by time (kind "ask" is this Mac's own, never the server's).
    static func askItem(_ ask: Ask) -> Item {
        Item(id: "ask-" + ask.id, kind: "ask", threadId: ask.id, createdAt: ask.at, readAt: ask.at, source: "mac", title: nil, line: ask.words,
             links: [], actions: [], live: false, undoUntil: nil)
    }
    /// The chat's items with this Mac's Asks among them, oldest first.
    static func merged(_ items: [Item], asks: [Ask]) -> [Item] {
        guard !asks.isEmpty else { return items }
        return (items + asks.map(askItem)).enumerated().sorted { a, b in
            a.element.createdAt == b.element.createdAt ? a.offset < b.offset : a.element.createdAt < b.element.createdAt
        }.map(\.element)
    }
    /// The card title over an answer: its Messages number once the server gave one.
    static func askTitle(_ ask: Ask) -> String { ask.number.map { "Message #\($0)" } ?? "Asking COS" }
}

// MARK: The store

@MainActor
final class DropItStore: ObservableObject {
    typealias Run = @MainActor ([String], Data?) async throws -> HelperResponse

    /// The pinned row's numbers (GET /api/inbox/summary).
    @Published private(set) var summary = DropIt.Summary()
    /// The chat, oldest first (GET /api/inbox/feed).
    @Published private(set) var items: [DropIt.Item] = []
    /// The "N new" line, fixed as the chat opened so marking read does not move it.
    @Published private(set) var newMark: (first: String, count: Int)? = nil
    /// Drops this session knows in full (their choices, links and Undo window), by id.
    @Published private(set) var drops: [String: DropIt.Drop] = [:]
    /// The chat has loaded once.
    @Published private(set) var loaded = false
    /// A drop is out.
    @Published private(set) var sending = false
    /// One change is out on this drop or chat item (Undo, Move, a choice): its buttons wait.
    @Published private(set) var busyThreads: Set<String> = []
    /// The line under the composer: why something did not go. Cleared by the next change.
    @Published var line: String?
    /// The line on one chat item (why its Undo or Move did not go), by thread.
    @Published var itemLines: [String: String] = [:]
    /// History.
    @Published private(set) var history: [DropIt.Drop] = []
    @Published private(set) var historyMore = false
    @Published private(set) var historyLoading = false
    @Published private(set) var historyLine: String?
    /// The server's answer about the switch, after a read or a change.
    @Published private(set) var settings: DropIt.Settings?
    @Published private(set) var settingsBusy = false
    @Published private(set) var settingsLine: String?

    var run: Run
    /// The existing Ask job (a Today Work run with the words), started for a drop the server routes to an ask. Returns the
    /// run's clientJobId, or nil when it did not start (its own guard, the switch, no model). The third value is the drop's
    /// files (6.99.13 `next.attachmentIds`), which go with the question.
    var askRun: (@MainActor (String, String, [String]) async -> String?)?

    // MARK: Ask and attachments (0.5.371 option A)

    /// What starting an Ask came to: the run's clientJobId, or the line that says why it did not start.
    enum AskStart: Equatable, Sendable { case started(String), refused(String) }
    /// The composer's Ask: the same Today Work run (its guard, its switch, its model pick) with the words and the media ids.
    var askJob: (@MainActor (_ target: String, _ prompt: String, _ attachmentIds: [String]) async -> AskStart)?
    /// Reads the runs behind this Mac's Asks back (their receipts), by clientJobId.
    var askState: (@MainActor (_ ids: [String]) async -> [String: DropIt.AskState])?
    /// The files on the composer, in the order they were added.
    @Published private(set) var attachments: [DropIt.Attachment] = []
    /// This Mac's Asks, oldest first, with what their runs say so far.
    @Published private(set) var asks: [DropIt.Ask] = []
    /// An Ask is starting.
    @Published private(set) var asking = false
    /// `capabilities.dropIt.attachments` (6.99.13): how many files a drop takes. nil or 0: words only.
    var dropTakes: Int?
    /// The card files' secret-name rule (WorkCardFiles.looksSecret), set by the app.
    var isSecret: (String) -> Bool = { _ in false }
    /// Where resized photos and pasted screenshots wait to go up: this user's only, never iCloud.
    var stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cos-drop-it-attachments", isDirectory: true)
    /// When a file went up (the server's capturedAt), injectable for the checks.
    var now: () -> Date = Date.init
    /// How many history requests went out (the checks count them).
    private(set) var historyRequests = 0
    private var historyGeneration = 0

    init(run: @escaping Run = { _, _ in throw CancellationError() }) {
        self.run = run
    }

    private func ask(_ arguments: [String], _ stdin: Data? = nil) async -> DropIt.Reply {
        do {
            let response = try await run(arguments, stdin)
            return DropIt.reply(response.details)
        } catch {
            return .unreachable
        }
    }

    // MARK: The pinned row

    func refreshSummary() async {
        if case .ok(let details) = await ask(DropIt.call("summary")) { summary = DropIt.summary(details) }
    }

    // MARK: The chat

    /// Reads the chat. On the first read of an opening (`opening`), fixes the "N new" line, then marks everything read.
    func loadFeed(opening: Bool = false) async {
        let reply = await ask(DropIt.call("feed", ["--limit", "200"]))
        guard case .ok(let details) = reply else {
            if !loaded { line = DropIt.line(reply) }
            return
        }
        let fresh = (details["items"]?.array ?? []).compactMap(DropIt.item)
        if opening { newMark = DropIt.newMark(fresh) }
        items = fresh
        loaded = true
        if line == DropIt.unreachableLine { line = nil }
        if fresh.contains(where: { $0.readAt == nil }), let last = fresh.last { await markRead(through: last.id) }
    }

    /// Mark everything up to `through` read (POST /api/inbox/read).
    func markRead(through: String) async {
        guard case .ok(let details) = await ask(DropIt.call("read", ["--through", through])) else { return }
        let at = Date()
        if let index = items.firstIndex(where: { $0.id == through }) {
            for i in 0...index where items[i].readAt == nil { items[i].readAt = at }
        }
        summary.unread = max(0, details["unread"]?.int ?? 0)
    }

    func markAllRead() async {
        guard let last = items.last else { return }
        await markRead(through: last.id)
    }

    /// The chat closed: the next opening draws its own "N new" line.
    func closed() { newMark = nil }

    /// Take an answer's items into the chat, in place where they exist, in order after the rest.
    private func merge(_ answer: DropIt.Answer) {
        drops[answer.drop.id] = answer.drop
        for item in answer.items {
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
        }
        items.sort { $0.createdAt == $1.createdAt ? false : $0.createdAt < $1.createdAt }
        if let last = items.last { summary.lastAt = last.createdAt; summary.lastLine = last.title.map { last.fromYou ? last.line : $0 + ". " + last.line } ?? last.line }
    }

    /// Drop the words. Returns the answer (the composer clears on one), or nil with `line` saying why. A question for COS is
    /// handed to the existing Ask job, then linked back (POST /drops/:id/ask).
    @discardableResult
    func send(_ text: String) async -> DropIt.Answer? {
        guard !sending else { return nil }
        let dropId = DropIt.newDropID()
        // Files go with a drop only to a server that takes them; otherwise nothing is dropped and the files stay.
        if let block = DropIt.dropBlock(files: attachments, serverTakes: dropTakes) { line = block; return nil }
        let files = DropIt.readyIDs(attachments)
        guard let call = DropIt.submitCall(dropId: dropId, text: text, attachmentIds: files) else { line = DropIt.tooLongLine; return nil }
        sending = true
        defer { sending = false }
        line = nil
        let reply = await ask(call.arguments, call.stdin)
        guard case .ok(let details) = reply, let answer = DropIt.answer(details) else {
            line = DropIt.line(reply) ?? DropIt.failedLine
            return nil
        }
        merge(answer)
        if !files.isEmpty { attachments.removeAll { files.contains($0.mediaId ?? "") } }
        if let prompt = answer.askPrompt { await startAsk(dropId: answer.drop.id, prompt: prompt, files: answer.askAttachmentIds) }
        return answer
    }

    /// The existing Ask job, then the link. A run that does not start leaves the drop asked, with a line that says why.
    private func startAsk(dropId: String, prompt: String, files: [String] = []) async {
        guard let askRun, let job = await askRun(dropId, prompt, files) else { line = DropIt.askHeldLine; return }
        let reply = await ask(DropIt.call("ask", ["--drop", dropId, "--job", job, "--generation", "1"]))
        if case .ok(let details) = reply, let answer = DropIt.answer(details) { merge(answer) }
        else { line = DropIt.line(reply) }
    }

    /// Ask: the words and the files that are up, as one Today Work run (`work-new`, POST /api/query-jobs), so the answer lands
    /// in Messages with its number and here under his words. True when it started (the composer clears).
    @discardableResult
    func ask(_ text: String) async -> Bool {
        guard !asking, !sending else { return false }
        if let block = DropIt.askBlock(text: text, files: attachments) { if !block.isEmpty { line = block }; return false }
        guard let askJob else { line = DropIt.askHeldLine; return false }
        asking = true
        defer { asking = false }
        line = nil
        let words = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = DropIt.readyIDs(attachments)
        let sent = attachments.filter { ids.contains($0.mediaId ?? "") }
        switch await askJob("cos:ask:" + DropIt.newDropID(), words, ids) {
        case .started(let job):
            asks.append(DropIt.Ask(id: job, words: words, files: sent.map { DropIt.Ask.File(name: $0.name, kind: $0.kind, thumb: $0.thumb) }, at: now()))
            // The files went with the words; their copies stay for the thumbnails under his bubble.
            attachments.removeAll { ids.contains($0.mediaId ?? "") }
            return true
        case .refused(let reason):
            line = reason
            return false
        }
    }

    /// Reads back the runs of the Asks still going.
    func refreshAsks() async {
        let open = asks.filter { !$0.finished }.map(\.id)
        guard !open.isEmpty, let askState else { return }
        let states = await askState(open)
        for index in asks.indices {
            guard let state = states[asks[index].id] else { continue }
            asks[index].status = state.status
            if let answer = state.answer, !answer.isEmpty { asks[index].answer = answer }
            if let number = state.number { asks[index].number = number }
        }
    }

    /// Files from a drop, a paste or Add. Each goes up at once; past five, or a kind COS cannot read, it is refused with a line
    /// and never added. `owned`: copies this composer made, removed with the attachment.
    func attach(_ files: [(url: URL, name: String)], owned: Bool = false, refusals extra: [String] = []) {
        attach(files.map { DropIt.Incoming(url: $0.url, name: $0.name, owned: owned) }, refusals: extra)
    }
    /// The same, file by file: a drop can bring a Finder file (his, left alone) and a promise this composer copied (owned).
    func attach(_ files: [DropIt.Incoming], refusals extra: [String] = []) {
        var refusals = extra
        for file in files {
            let owned = file.owned
            guard attachments.count < DropIt.maxAttachments else {
                refusals.append("Up to 5 attachments per message. " + file.name + " was not added.")
                if owned { try? FileManager.default.removeItem(at: file.url) }
                continue
            }
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            switch DropIt.classify(name: file.name, bytes: bytes, secret: isSecret(file.name)) {
            case .failure(let refusal):
                refusals.append(refusal.line)
                if owned { try? FileManager.default.removeItem(at: file.url) }
            case .success(let what):
                let item = DropIt.Attachment(id: DropIt.newDropID(), name: file.name, kind: what.kind, mime: what.mime, bytes: bytes, source: file.url,
                                             owned: owned ? [file.url] : [])
                attachments.append(item)
                Task { await upload(item.id) }
            }
        }
        line = refusals.isEmpty ? nil : refusals.joined(separator: " ")
    }

    /// A pasted screenshot (PNG data), named for when it was pasted, as the meeting paste names it.
    func attachImage(_ png: Data, at date: Date = Date()) {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Pasted screenshot " + format.string(from: date) + ".png"
        guard let url = stage(png, ext: "png") else { line = DropIt.failedLine; return }
        attach([(url, name)], owned: true)
    }

    /// Writes bytes into the staging folder (0700, the file 0600). nil when it could not.
    func stage(_ data: Data, ext: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = stagingRoot.appendingPathComponent(DropIt.newDropID() + "." + ext)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { return nil }
    }

    func removeAttachment(_ id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        for url in attachments[index].owned { try? FileManager.default.removeItem(at: url) }
        attachments.remove(at: index)
        if line == DropIt.fileFailedLine || line == DropIt.filesWaitLine || line == DropIt.dropWordsOnlyLine { line = nil }
    }

    func retryAttachment(_ id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }), attachments[index].state == .failed else { return }
        attachments[index].state = .preparing
        attachments[index].error = nil
        Task { await upload(id) }
    }

    /// One file up: a photo is resized first. A file removed while it goes up is let go (its answer is dropped).
    private func upload(_ id: String) async {
        guard var file = attachments.first(where: { $0.id == id }) else { return }
        if file.kind == .photo, file.thumb == nil {
            let source = file.source
            let jpeg = await Task.detached { DropIt.photoJPEG(source) }.value
            guard attachments.contains(where: { $0.id == id }) else { return }
            guard let jpeg else { return fail(id, "This photo could not be read") }
            guard Int64(jpeg.count) <= DropIt.photoMaxBytes else { return fail(id, "Over 2 MB even after resizing") }
            guard let url = stage(jpeg, ext: "jpg") else { return fail(id, "Did not upload") }
            file.source = url; file.thumb = url; file.bytes = Int64(jpeg.count); file.owned.append(url)
        }
        file.state = .uploading
        set(file)
        guard let call = DropIt.uploadCall(file, capturedAt: now()) else { return fail(id, "Did not upload") }
        let reply = await ask(call.arguments, call.stdin)
        guard var current = attachments.first(where: { $0.id == id }) else { return }
        switch DropIt.uploadResult(reply) {
        case .success(let media): current.mediaId = media; current.state = .ready; current.error = nil
        case .failure(let refusal): current.state = .failed; current.error = refusal.line
        }
        set(current)
        if current.state == .ready, line == DropIt.filesWaitLine, !attachments.contains(where: \.busy) { line = nil }
    }
    private func set(_ file: DropIt.Attachment) {
        if let index = attachments.firstIndex(where: { $0.id == file.id }) { attachments[index] = file }
    }
    private func fail(_ id: String, _ why: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = .failed
        attachments[index].error = why
    }

    func isBusy(_ thread: String) -> Bool { busyThreads.contains(thread) }

    /// One change on a chat item (Undo, a choice), by its thread. The answer's items replace the old ones.
    private func change(thread: String, _ arguments: [String], _ stdin: Data? = nil) async -> Bool {
        guard !busyThreads.contains(thread) else { return false }
        busyThreads.insert(thread)
        defer { busyThreads.remove(thread) }
        itemLines[thread] = nil
        let reply = await ask(arguments, stdin)
        guard case .ok(let details) = reply, let answer = DropIt.answer(details) else {
            itemLines[thread] = DropIt.line(reply) ?? DropIt.failedLine
            return false
        }
        merge(answer)
        return true
    }

    /// Undo (POST /api/inbox/action {itemId, action: undo}).
    @discardableResult
    func undo(_ item: DropIt.Item) async -> Bool {
        await change(thread: item.threadId, DropIt.call("action", ["--item", item.id, "--action", "undo"]))
    }

    /// A one-question choice (POST /api/inbox/action {itemId, action: choose:<id>}).
    @discardableResult
    func choose(_ item: DropIt.Item, _ action: DropIt.Action) async -> Bool {
        guard action.isChoice else { return false }
        return await change(thread: item.threadId, DropIt.call("action", ["--item", item.id, "--action", action.id]))
    }

    /// Move (POST /api/drops/:id/move): Undo, then filing where he picked, with no Jev call.
    @discardableResult
    func move(thread: String, to destination: DropIt.Destination) async -> Bool {
        guard let call = DropIt.moveCall(dropId: thread, dest: destination.dest, target: destination.target) else { return false }
        return await change(thread: thread, call.arguments, call.stdin)
    }

    /// The drop behind a chat item, read once when Move or a choice needs it (GET /api/drops/:id).
    func loadDrop(_ id: String) async {
        guard drops[id] == nil, case .ok(let details) = await ask(DropIt.call("get", ["--drop", id])), let answer = DropIt.answer(details) else { return }
        drops[id] = answer.drop
    }

    // MARK: History

    func loadHistory(query: String, kind: String?, status: String?) async {
        guard let call = DropIt.historyCall(query: query, kind: kind, status: status) else { return }
        historyGeneration += 1
        let generation = historyGeneration
        historyLoading = true
        historyRequests += 1
        let reply = await ask(call.arguments, call.stdin)
        // A newer search went out while this one was away: its answer wins.
        guard generation == historyGeneration else { return }
        historyLoading = false
        guard case .ok(let details) = reply else { historyLine = DropIt.line(reply); return }
        historyLine = nil
        history = (details["drops"]?.array ?? []).compactMap { DropIt.drop($0) }
        historyMore = details["more"]?.bool == true
    }

    // MARK: Settings

    func readSettings() async {
        let reply = await ask(DropIt.call("settings"))
        guard case .ok(let details) = reply else { if case .unsupported = reply { settings = nil }; return }
        settings = DropIt.Settings(enabled: details["enabled"]?.bool == true, envDecides: details["source"]?.string == "env")
        // 6.99.13 says on its settings too how many files a drop takes; an older server says nothing and keeps what health said.
        if let files = details["attachments"]?.int { dropTakes = files }
    }

    /// PUT /api/drops/settings. Returns the switch as the server now has it, or nil when the change did not go.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool? {
        guard !settingsBusy else { return nil }
        settingsBusy = true
        defer { settingsBusy = false }
        settingsLine = nil
        let reply = await ask(DropIt.call("settings-set", ["--enabled", on ? "true" : "false"]))
        guard case .ok(let details) = reply else { settingsLine = DropIt.line(reply) ?? DropIt.failedLine; return nil }
        let now = DropIt.Settings(enabled: details["enabled"]?.bool == true, envDecides: details["source"]?.string == "env")
        settings = now
        if details["savedButEnvWins"]?.bool == true { settingsLine = DropIt.settingEnvLine }
        if !now.enabled { items = []; loaded = false; summary = DropIt.Summary(); newMark = nil }
        return now.enabled
    }

}
