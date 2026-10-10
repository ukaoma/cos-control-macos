import Foundation

// The live meeting transcript in Meetings (0.5.278).
//
// While a glasses meeting records, the helper's `live-transcript` verb lists the server's live session files and reads
// one of them: the chunks after a cursor (`--since`), or `unchanged` when the file is what the last read saw. This is
// the pure part, in the shape of SessionLiveFeed.swift: the reply, the reducer from chunks to the turns the pane draws,
// which sessions get a "Live now" row, the hand-off once the file is gone, and the copied text. Pure Foundation, so
// Tests/LiveTranscriptChecks.swift executes it; the views only paint it.
//
// THE REDUCER. A chunk is keyed by its own index: a second copy of an index replaces the first (the file wins, and a
// later read is the file), the turns are in index order whatever order chunks arrive in, and an index that is not
// there is never drawn as loss (it is silence, a dropped hallucination, or a chunk still in Whisper). Consecutive
// chunks with the same speaker are one turn, whose id is its first index, so a turn keeps its identity while it grows.
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
    let size: Int
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
    var maxIndex: Int? = nil
    var settledThrough: Int? = nil
    var chunkCount: Int? = nil
    var turns: [LiveTranscriptChunk]? = nil
}

struct LiveTranscriptReply: Codable, Sendable {
    var dataDir: String? = nil
    var sessions: [LiveTranscriptFileRow] = []
    var read: LiveTranscriptRead? = nil

    static func decode(_ data: Data) -> LiveTranscriptReply? { try? JSONDecoder().decode(LiveTranscriptReply.self, from: data) }
}

/// Consecutive chunks from one speaker. `id` is the first chunk's index.
struct LiveTranscriptTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let speaker: String
    let elapsedMs: Int
    var text: String
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
    var phase: LiveTranscriptPhase = .live
    /// When the file was first seen gone.
    var endedAt: Date?
    var lastStatusCheck: Date?
    var serverState: String?

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
            turns = Self.turns(from: chunks)
            changed = true
        }
        return changed
    }

    @discardableResult
    mutating func markEnded(now: Date) -> Bool {
        guard endedAt == nil else { return false }
        endedAt = now
        if phase == .live { phase = .finalizing }
        return true
    }

    /// Index order, consecutive same-speaker chunks merged, a missing index skipped silently.
    static func turns(from chunks: [Int: LiveTranscriptChunk]) -> [LiveTranscriptTurn] {
        var out: [LiveTranscriptTurn] = []
        for index in chunks.keys.sorted() {
            guard let chunk = chunks[index] else { continue }
            let speaker = LiveTranscript.displaySpeaker(chunk.speaker)
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = out.last, last.speaker == speaker {
                last.text += " " + text
                last.lastIndex = index
                out[out.count - 1] = last
            } else {
                out.append(LiveTranscriptTurn(id: index, speaker: speaker, elapsedMs: chunk.elapsedMs, text: text, lastIndex: index))
            }
        }
        return out
    }
}

/// A "Live now" row, `live:<sessionId>`.
struct LiveTranscriptRow: Identifiable, Equatable, Sendable {
    let sessionId: String
    let startTime: Date?
    let lastActivity: Date?
    let phase: LiveTranscriptPhase
    let chunkCount: Int
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
                out.append(LiveTranscriptRow(sessionId: file.sessionId, startTime: feed?.startTime,
                                             lastActivity: feed?.lastActivityAt ?? Date(timeIntervalSince1970: file.mtimeMs / 1000),
                                             phase: .live, chunkCount: feed?.chunkCount ?? 0))
            }
        }
        for feed in feeds.values where !seen.contains(feed.sessionId) && feed.ended && !fileIDs.contains(feed.sessionId) {
            guard feed.phase != .saved, !stranded.contains(feed.sessionId) else { continue }
            if feed.phase == .endedUnsaved, let ended = feed.endedAt, now.timeIntervalSince(ended) > endedRowLifetime { continue }
            out.append(LiveTranscriptRow(sessionId: feed.sessionId, startTime: feed.startTime, lastActivity: feed.lastActivityAt,
                                         phase: feed.phase, chunkCount: feed.chunkCount))
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

    static func durationLabel(start: Date?, now: Date) -> String? {
        guard let start else { return nil }
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

    /// `[m:ss]`, or `[h:mm:ss]` from an hour in.
    static func stamp(_ elapsedMs: Int) -> String {
        let total = max(0, elapsedMs) / 1000
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

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
        return ([header] + turns.map { "[\(stamp($0.elapsedMs))] \($0.speaker): \($0.text)" }).joined(separator: "\n")
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
