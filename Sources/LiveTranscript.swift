import Foundation

// The live meeting transcript in Meetings (0.5.278).
//
// While a glasses meeting records, the helper's `live-transcript` verb lists the server's live session files and reads
// one of them: the chunks after a cursor (`--since`), or `unchanged` when the file is what the last read saw. This is
// the pure part, in the shape of SessionLiveFeed.swift: the reply, the reducer from chunks to the turns the pane draws,
// which sessions get a "Live now" row, the hand-off once the file is gone, and the copied text. Pure Foundation, so
// Tests/LiveTranscriptChecks.swift executes it; the views only paint it.
//
// THE REDUCER. A chunk is keyed by its own index, and a second copy of an index in a later read replaces the first.
// The helper re-sends only chunks after its settled cursor, so a chunk at or below the cursor is not read again: what
// was settled stays as first read (the saved meeting is the final text). The turns are in index order whatever order
// chunks arrive in, and an index that is not there is never drawn as loss (it is silence, a dropped hallucination, or
// a chunk still in Whisper). Consecutive chunks with the same speaker are one turn. A turn's id is the first index it
// was ever drawn with, and it keeps that id when it grows at either end (a late chunk with a lower index included),
// so the list never re-identifies a row the reader is looking at; only a turn new to the list takes a new id.
//
// SECRET BOUNDARY. Nothing here logs or prints, and no error carries text: a failure is a reason code.

struct LiveTranscriptChunk: Codable, Equatable, Sendable {
    let i: Int
    let elapsedMs: Int
    let speaker: String
    let text: String
}

/// One live session file, from a stat (the helper opens nothing for the list).
struct LiveTranscriptFileRow: Codable, Equatable, Sendable {
    let sessionId: String
    let mtimeMs: Double
    let stamp: String
}

/// One session read. `ended`: the file is gone. `unchanged`: the same file as `stamp` (no chunks).
struct LiveTranscriptRead: Codable, Equatable, Sendable {
    let sessionId: String
    let ended: Bool
    let unchanged: Bool
    var stamp: String? = nil
    var startTime: Double? = nil
    var lastActivityAt: Double? = nil
    var settledThrough: Int? = nil
    var turns: [LiveTranscriptChunk]? = nil
}

struct LiveTranscriptReply: Codable, Sendable {
    var dataDir: String? = nil
    var sessions: [LiveTranscriptFileRow] = []
    var read: LiveTranscriptRead? = nil

    static func decode(_ data: Data) -> LiveTranscriptReply? { try? JSONDecoder().decode(LiveTranscriptReply.self, from: data) }
}

/// Consecutive chunks from one speaker. `id` is stable (see THE REDUCER); `firstIndex` is its first chunk's index now.
struct LiveTranscriptTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let speaker: String
    let elapsedMs: Int
    var text: String
    var firstIndex: Int
    var lastIndex: Int
}

enum LiveTranscriptPhase: String, Equatable, Sendable {
    /// The file is there.
    case live
    /// The file is gone and the saved meeting is not found yet (or the server has not said what happened).
    case finalizing
    /// The saved meeting is found; Meetings opens it in place.
    case saved
    /// The server says the session closed without a save.
    case endedUnsaved
    /// Saved, or not answered, for longer than the deadline: Refresh asks again.
    case notFoundYet
}

/// Everything Control holds for one live session. The transcript stays here after the file is gone, so Copy works
/// while the meeting finalizes.
struct LiveTranscriptFeed: Equatable, Sendable {
    let sessionId: String
    var startTime: Date?
    var lastActivityAt: Date?
    var stamp: String?
    /// The `--since` the next read sends: the helper's `settledThrough`, never lowered.
    var cursor = -1
    private(set) var chunks: [Int: LiveTranscriptChunk] = [:]
    private(set) var turns: [LiveTranscriptTurn] = []
    /// Which turn id each chunk was drawn in, so a rebuilt turn keeps its id.
    private var turnOfChunk: [Int: Int] = [:]
    var phase: LiveTranscriptPhase = .live
    /// When the file was first seen gone.
    var endedAt: Date?
    var lastStatusCheck: Date?
    var serverState: String?
    /// Shown as live while the server counted it (the poll follows it to its end, even if the count drops first).
    var seenLive = false

    init(sessionId: String) { self.sessionId = sessionId }

    var chunkCount: Int { chunks.count }
    var ended: Bool { endedAt != nil }

    /// Applies one read; true when anything the pane draws changed.
    @discardableResult
    mutating func apply(_ read: LiveTranscriptRead, now: Date) -> Bool {
        guard read.sessionId == sessionId else { return false }
        if read.ended { return markEnded(now: now) }
        var changed = false
        if endedAt != nil {
            // The file is back (the server restored the session after a restart).
            endedAt = nil; phase = .live; serverState = nil; lastStatusCheck = nil
            changed = true
        }
        guard !read.unchanged else { return changed }
        stamp = read.stamp ?? stamp
        if let start = read.startTime.map({ Date(timeIntervalSince1970: $0 / 1000) }), start != startTime { startTime = start; changed = true }
        if let last = read.lastActivityAt.map({ Date(timeIntervalSince1970: $0 / 1000) }), last != lastActivityAt { lastActivityAt = last; changed = true }
        if let settled = read.settledThrough { cursor = max(cursor, settled) }
        var chunksChanged = false
        for chunk in read.turns ?? [] where chunk.i >= 0 && chunks[chunk.i] != chunk {
            chunks[chunk.i] = chunk
            chunksChanged = true
        }
        if chunksChanged {
            (turns, turnOfChunk) = Self.build(chunks, previous: turnOfChunk)
            changed = true
        }
        return changed
    }

    /// The file's own clock: a session not read this poll still shows when its file last changed. Never moves back.
    @discardableResult
    mutating func noteFileActivity(_ at: Date) -> Bool {
        guard lastActivityAt.map({ at > $0 }) ?? true else { return false }
        lastActivityAt = at
        return true
    }

    @discardableResult
    mutating func markEnded(now: Date) -> Bool {
        guard endedAt == nil else { return false }
        endedAt = now
        if phase == .live { phase = .finalizing }
        return true
    }

    /// Index order, consecutive same-speaker chunks merged, a missing index skipped silently.
    static func turns(from chunks: [Int: LiveTranscriptChunk]) -> [LiveTranscriptTurn] { build(chunks, previous: [:]).turns }

    /// The turns, and which turn id each chunk is in. A run whose chunks were drawn before takes the id of the first of
    /// them (in index order) that is still free; a run with none, or whose old ids are taken (a turn split by a late
    /// chunk from another voice), takes its first index, or -(first index + 1) if even that is an id already given.
    static func build(_ chunks: [Int: LiveTranscriptChunk], previous: [Int: Int]) -> (turns: [LiveTranscriptTurn], map: [Int: Int]) {
        var runs: [(speaker: String, members: [LiveTranscriptChunk])] = []
        for index in chunks.keys.sorted() {
            guard let chunk = chunks[index], !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let speaker = LiveTranscript.displaySpeaker(chunk.speaker)
            if let last = runs.last, last.speaker == speaker { runs[runs.count - 1].members.append(chunk) }
            else { runs.append((speaker, [chunk])) }
        }
        var used = Set<Int>()
        var out: [LiveTranscriptTurn] = []
        var map: [Int: Int] = [:]
        for run in runs {
            let first = run.members[0]
            let inherited = run.members.lazy.compactMap { previous[$0.i] }.first { !used.contains($0) }
            let id = inherited ?? (used.contains(first.i) ? -(first.i + 1) : first.i)
            used.insert(id)
            let text = run.members.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            out.append(LiveTranscriptTurn(id: id, speaker: run.speaker, elapsedMs: first.elapsedMs, text: text,
                                          firstIndex: first.i, lastIndex: run.members[run.members.count - 1].i))
            for member in run.members { map[member.i] = id }
        }
        return (out, map)
    }
}

/// A "Live now" row, `live:<sessionId>`.
struct LiveTranscriptRow: Identifiable, Equatable, Sendable {
    let sessionId: String
    let startTime: Date?
    let lastActivity: Date?
    let phase: LiveTranscriptPhase
    /// When the file went: the duration stops here.
    var endedAt: Date? = nil
    var id: String { LiveTranscript.rowID(sessionId) }
}

enum LiveTranscript {
    /// AppStorage: Settings, "Show live meeting transcript". Absent means on.
    static let enabledKey = "cos.liveTranscriptEnabled"
    static let pollSeconds = 1.5
    /// A session quiet for this long says "No audio for Xm" and keeps its row (the server keeps it live for 30 min).
    static let quietAfterSeconds: TimeInterval = 120
    /// Finalizing waits this long for the saved meeting, then says "Saved meeting not found yet".
    static let finalizingDeadline: TimeInterval = 180
    /// A session the server calls closed or missing this long after its file went is a recording ended without saving.
    static let unsavedGrace: TimeInterval = 20
    /// How often an ended session asks the server what happened.
    static let statusInterval: TimeInterval = 3
    /// How long a "Recording ended without saving" row stays.
    static let endedRowLifetime: TimeInterval = 600
    static let header = "Live transcript · preliminary · may change when saved"

    static func rowID(_ sessionId: String) -> String { "live:" + sessionId }

    static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

    /// Speaker labels are voiceprint guesses: an unrecognized one reads "Speaker".
    static func displaySpeaker(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unknown: Set<String> = ["", "unknown", "speaker", "unidentified", "?", "none", "null"]
        return unknown.contains(name.lowercased()) ? "Speaker" : name
    }

    /// Poll only while someone is looking, the setting is on, and the server says a meeting is live (or a session that
    /// just ended still waits for its saved meeting).
    static func shouldPoll(enabled: Bool, visible: Bool, serverLive: Int?, pendingHandoff: Bool) -> Bool {
        enabled && visible && ((serverLive ?? 0) > 0 || pendingHandoff)
    }

    /// Which sessions get a row. Liveness is the server's: none while it reports no live session, never one it calls
    /// stale, never one already in the stranded captures banner. An ended session keeps its row while it hands off.
    static func rows(files: [LiveTranscriptFileRow], feeds: [String: LiveTranscriptFeed], serverLive: Int?,
                     stale: Set<String>, stranded: Set<String>, now: Date) -> [LiveTranscriptRow] {
        var out: [LiveTranscriptRow] = []
        var seen = Set<String>()
        let fileIDs = Set(files.map(\.sessionId))
        if (serverLive ?? 0) > 0 {
            for file in files where !stale.contains(file.sessionId) && !stranded.contains(file.sessionId) {
                let feed = feeds[file.sessionId]
                if feed?.ended == true { continue }
                seen.insert(file.sessionId)
                // The quiet clock is the later of the last read's activity and the file's own mtime (a session not
                // read this poll still has a fresh file).
                let mtime = Date(timeIntervalSince1970: file.mtimeMs / 1000)
                out.append(LiveTranscriptRow(sessionId: file.sessionId, startTime: feed?.startTime,
                                             lastActivity: max(feed?.lastActivityAt ?? mtime, mtime),
                                             phase: .live))
            }
        }
        for feed in feeds.values where !seen.contains(feed.sessionId) && feed.ended && !fileIDs.contains(feed.sessionId) {
            guard feed.phase != .saved, !stranded.contains(feed.sessionId) else { continue }
            if feed.phase == .endedUnsaved, let ended = feed.endedAt, now.timeIntervalSince(ended) > endedRowLifetime { continue }
            out.append(LiveTranscriptRow(sessionId: feed.sessionId, startTime: feed.startTime, lastActivity: feed.lastActivityAt,
                                         phase: feed.phase, endedAt: feed.endedAt))
        }
        // The most recent first: a live one before an ended one, then by start.
        return out.sorted { a, b in
            if (a.phase == .live) != (b.phase == .live) { return a.phase == .live }
            let x = a.startTime ?? a.lastActivity ?? .distantPast, y = b.startTime ?? b.lastActivity ?? .distantPast
            return x != y ? x > y : a.sessionId < b.sessionId
        }
    }

    /// The hand-off once the file is gone. The saved row found wins. The server's `saved` waits for the row until the
    /// deadline; `closed` or `missing` after a short grace is a recording ended without saving; no answer waits too.
    static func handoff(serverState: String?, endedAt: Date, now: Date, savedRowFound: Bool) -> LiveTranscriptPhase {
        if savedRowFound { return .saved }
        let waited = now.timeIntervalSince(endedAt)
        if serverState == "closed" || serverState == "missing" { return waited >= unsavedGrace ? .endedUnsaved : .finalizing }
        return waited >= finalizingDeadline ? .notFoundYet : .finalizing
    }

    /// Whole minutes of quiet once it passes two minutes, else nil.
    static func quietMinutes(lastActivity: Date?, now: Date) -> Int? {
        guard let lastActivity else { return nil }
        let quiet = now.timeIntervalSince(lastActivity)
        return quiet >= quietAfterSeconds ? Int(quiet / 60) : nil
    }

    static func quietLabel(lastActivity: Date?, now: Date) -> String? {
        quietMinutes(lastActivity: lastActivity, now: now).map { "No audio for \($0)m" }
    }

    static func durationLabel(start: Date?, now: Date, endedAt: Date? = nil) -> String? {
        guard let start else { return nil }
        let now = endedAt.map { min($0, now) } ?? now
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        if minutes < 1 { return "Just started" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func phaseLabel(_ phase: LiveTranscriptPhase) -> String? {
        switch phase {
        case .live: nil
        case .finalizing: "Finalizing"
        case .saved: "Saved"
        case .endedUnsaved: "Recording ended without saving"
        case .notFoundYet: "Saved meeting not found yet"
        }
    }

    /// `[m:ss]`, or `[h:mm:ss]` when `hours` (one format for a whole transcript: see `usesHours`).
    static func stamp(_ elapsedMs: Int, hours: Bool) -> String {
        let total = max(0, elapsedMs) / 1000
        let h = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours ? String(format: "%d:%02d:%02d", h, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// The whole transcript switches to h:mm:ss once any turn starts an hour in.
    static func usesHours(_ turns: [LiveTranscriptTurn]) -> Bool { turns.contains { $0.elapsedMs >= 3_600_000 } }

    /// What Copy transcript puts on the clipboard: a one-line header, then one line per turn.
    static func copyText(turns: [LiveTranscriptTurn], startTime: Date?, timeZone: TimeZone = .current, twentyFourHour: Bool = false) -> String {
        var header = "COS preliminary transcript"
        if let startTime {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = twentyFourHour ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd h:mm a"
            header += " · " + formatter.string(from: startTime)
        }
        let hours = usesHours(turns)
        return ([header] + turns.map { "[\(stamp($0.elapsedMs, hours: hours))] \($0.speaker): \($0.text)" }).joined(separator: "\n")
    }

    /// The reason code inside a helper refusal, "Live transcript unavailable (parse_failed)", else `unavailable`.
    /// Only `[a-z0-9_]` survives, so no message text can ride along.
    static func reasonCode(fromMessage message: String) -> String {
        guard let open = message.lastIndex(of: "("), let close = message.lastIndex(of: ")"), open < close else { return "unavailable" }
        let code = String(message[message.index(after: open)..<close])
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        guard (1...40).contains(code.count), code.allSatisfy({ allowed.contains($0) }) else { return "unavailable" }
        return code
    }

    /// The local days a saved meeting could be filed under: the start's and today's.
    static func handoffDays(start: Date?, now: Date, timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [String] = []
        for date in [start, now].compactMap({ $0 }) {
            let day = formatter.string(from: date)
            if !days.contains(day) { days.append(day) }
        }
        return days
    }
}

/// Auto-scroll for the live pane. It follows new text while the reader sits at the bottom, and holds still once they
/// scroll up or drag to select; a click at the bottom, scrolling back down or Jump to live resumes it. The bottom
/// leaving the screen within `settle` of a content change or a jump is the text growing, not the reader scrolling.
struct LiveTranscriptFollow: Equatable, Sendable {
    static let settle: TimeInterval = 0.6
    private(set) var following = true
    private(set) var selecting = false
    private(set) var lastAutoScroll = Date.distantPast
    private(set) var lastContentChange = Date.distantPast
    /// Bumped by Jump to live; the pane scrolls on each change.
    private(set) var jumpRequests = 0

    /// New text arrived: true when the pane should scroll to the bottom.
    mutating func contentChanged(now: Date) -> Bool {
        lastContentChange = now
        guard following, !selecting else { return false }
        lastAutoScroll = now
        return true
    }

    mutating func bottomDisappeared(now: Date) {
        guard now.timeIntervalSince(lastAutoScroll) > Self.settle, now.timeIntervalSince(lastContentChange) > Self.settle else { return }
        following = false
    }

    mutating func bottomAppeared() {
        if !selecting { following = true }
    }

    mutating func selectionBegan() {
        selecting = true
        following = false
    }

    mutating func tapped(atBottom: Bool) {
        selecting = false
        if atBottom { following = true }
    }

    mutating func jumpToLive(now: Date) {
        selecting = false
        following = true
        lastAutoScroll = now
        jumpRequests += 1
    }

    /// What the pane watches for new text: the turn count, the last turn and its length.
    static func signature(_ turns: [LiveTranscriptTurn]) -> String {
        "\(turns.count):\(turns.last?.id ?? -1):\(turns.last?.lastIndex ?? -1):\(turns.last?.text.utf8.count ?? 0)"
    }
}
