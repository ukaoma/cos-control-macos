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
// a chunk still in Whisper). Consecutive chunks with the same speaker form bounded reading sections (30 seconds or
// 600 characters). A turn's id is the first index it was ever drawn with, and it keeps that id when it grows at either end (a late chunk with a lower index included),
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
    var sourceType: String? = nil
    var speakerPolicy: String? = nil
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
    /// 0.5.339 (server 6.87.0): the newest chunks' levels from the file's `chunkLevels`, in index order. Two numbers a
    /// chunk, never text. nil when the file has none (an older server).
    var sourceType: String? = nil
    var speakerPolicy: String? = nil
    var levels: [LiveChunkLevel]? = nil
}

/// 0.5.339 (server 6.87.0): one live chunk's rough level, as the server's quiet gate measured it: `level` 0 to 1 (its RMS
/// on a dBFS scale) and `speechSec`, the Silero speech seconds (nil when the gate fell back to RMS).
struct LiveChunkLevel: Codable, Equatable, Sendable {
    let i: Int
    let level: Double
    var speechSec: Double? = nil
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
    /// 0.5.288: the server finished the session and Control cannot honestly say how (a leftover file it calls
    /// missing, closed or a state this build does not know, or a session quiet past the server's idle retention, by
    /// when the server auto-saves or closes it). No row; the open pane says only that the recording ended.
    case ended
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
    /// 0.5.288: the file is still on disk, but asked while it was quiet the server said it no longer holds the session
    /// (`missing`, `closed`, or a terminal state this build does not know, `unknown`) or saved it. The file is a leftover (a late chunk can rewrite a finished session's file and
    /// nothing deletes it), so the feed is ended as if the file were gone and takes the normal hand-off.
    var leftover = false

    init(sessionId: String) { self.sessionId = sessionId }

    var chunkCount: Int { chunks.count }
    var ended: Bool { endedAt != nil }

    /// Applies one read; true when anything the pane draws changed.
    @discardableResult
    mutating func apply(_ read: LiveTranscriptRead, now: Date) -> Bool {
        guard read.sessionId == sessionId else { return false }
        if read.ended { return markEnded(now: now) }
        if PhoneMeetingCapture.protected(sessionId, sourceType: read.sourceType) {
            guard PhoneMeetingCapture.validID(sessionId), read.sourceType == "iphone_microphone", read.speakerPolicy == "anonymous",
                  (read.turns ?? []).allSatisfy({ $0.speaker == "Ext" }) else { return false }
        }
        // A leftover's file is still there: a read of it is not the file coming back (see `fileWrittenAfterVerdict`).
        if leftover { return false }
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

    /// A leftover whose file was written after the server's answer goes back to live, and is asked again once quiet.
    @discardableResult
    mutating func fileWrittenAfterVerdict(_ mtime: Date) -> Bool {
        guard leftover, let endedAt, mtime > endedAt else { return false }
        leftover = false; self.endedAt = nil; phase = .live; serverState = nil; lastStatusCheck = nil
        return true
    }

    /// The server's answer for a present file that has been quiet: `missing`, `closed`, `saved` or `unknown` make it a
    /// leftover, ended now with that answer kept for the hand-off. `active` and no answer change nothing.
    @discardableResult
    mutating func applyQuietFileStatus(_ state: String?, now: Date) -> Bool {
        guard !ended, LiveTranscript.quietFileIsLeftover(serverState: state) else { return false }
        leftover = true
        serverState = state
        return markEnded(now: now)
    }

    @discardableResult
    mutating func markEnded(now: Date) -> Bool {
        guard endedAt == nil else { return false }
        endedAt = now
        if phase == .live { phase = .finalizing }
        return true
    }

    /// Index order, nearby same-speaker chunks merged into readable sections; missing indices stay silent.
    static func turns(from chunks: [Int: LiveTranscriptChunk]) -> [LiveTranscriptTurn] { build(chunks, previous: [:]).turns }

    /// The turns, and which turn id each chunk is in. A run whose chunks were drawn before takes the id of the first of
    /// them (in index order) that is still free; a run with none, or whose old ids are taken (a turn split by a late
    /// chunk from another voice), takes its first index, or a free negative id if that index is already given.
    static func build(_ chunks: [Int: LiveTranscriptChunk], previous: [Int: Int]) -> (turns: [LiveTranscriptTurn], map: [Int: Int]) {
        var runs: [(speaker: String, members: [LiveTranscriptChunk], characters: Int)] = []
        for index in chunks.keys.sorted() {
            guard let chunk = chunks[index], !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let speaker = LiveTranscript.displaySpeaker(chunk.speaker)
            let size = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            if let last = runs.last, last.speaker == speaker,
               chunk.elapsedMs >= last.members[0].elapsedMs,
               chunk.elapsedMs - last.members[0].elapsedMs < LiveTranscript.readingSectionMilliseconds,
               last.characters + 1 + size <= LiveTranscript.readingSectionCharacters {
                runs[runs.count - 1].members.append(chunk)
                runs[runs.count - 1].characters += 1 + size
            } else { runs.append((speaker, [chunk], size)) }
        }
        var used = Set<Int>()
        var out: [LiveTranscriptTurn] = []
        var map: [Int: Int] = [:]
        for run in runs {
            let first = run.members[0]
            let inherited = run.members.lazy.compactMap { previous[$0.i] }.first { !used.contains($0) }
            var id = inherited ?? first.i
            if used.contains(id) {
                id = -(first.i + 1)
                while used.contains(id) { id -= 1 }
            }
            used.insert(id)
            let text = run.members.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            out.append(LiveTranscriptTurn(id: id, speaker: run.speaker, elapsedMs: first.elapsedMs, text: LiveTranscript.readableText(text),
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
    /// This Mac's own capture, stopped while its audio still delivers (MacRecordingLiveRow): shown instead of "Live now".
    var deliveryLabel: String? = nil
    var id: String { LiveTranscript.rowID(sessionId) }
}

enum LiveTranscript {
    /// W-a: a failed post-recording helper cannot keep polling forever. Live recording is unaffected.
    static func errorPollingAllowed(serverLive: Int?, errorSince: Date?, now: Date) -> Bool {
        guard (serverLive ?? 0) == 0, let errorSince else { return true }
        return now.timeIntervalSince(errorSince) < 300
    }

    static let readingSectionMilliseconds = 30_000
    static let readingSectionCharacters = 600

    /// Layout only: keep every non-whitespace character in order, without rewriting speech or adding timestamps.
    /// A single oversized ASR chunk gets paragraph breaks too. Prefer sentence ends, then whitespace, then a
    /// grapheme boundary for text with no spaces. This runs only when chunks change, not on every view refresh.
    static func readableText(_ text: String) -> String {
        let characters = Array(text)
        let limit = 420
        var start = 0
        var paragraphs: [String] = []
        while start < characters.count {
            let end = min(start + limit, characters.count)
            var boundary = end
            if end < characters.count {
                var sentence: Int?
                var whitespace: Int?
                for index in start..<end {
                    if characters[index].isWhitespace { whitespace = index }
                    if index - start >= 160, ".!?。！？".contains(characters[index]),
                       index + 1 == characters.count || characters[index + 1].isWhitespace {
                        sentence = index + 1
                    }
                }
                boundary = sentence ?? whitespace.flatMap { $0 > start ? $0 : nil } ?? end
            }
            let paragraph = String(characters[start..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            start = boundary
            while start < characters.count, characters[start].isWhitespace { start += 1 }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// AppStorage: Settings, "Show live meeting transcript". Absent means on.
    static let enabledKey = "cos.liveTranscriptEnabled"
    static let pollSeconds = 1.5
    /// A session quiet for this long says "No audio for Xm", and while its file is still there Control asks the server
    /// (every `statusInterval`) whether it still holds the session. The server keeps a quiet session for up to
    /// `serverIdleRetention`, not 30 minutes.
    static let quietAfterSeconds: TimeInterval = 120
    /// The server's idle retention, LOCAL_FIRST_MEETING_IDLE_RETENTION_MS (4 h) in the server's
    /// server/lib/local-first-meetings-contract.ts. By then the server has auto-saved or closed a quiet session, so a
    /// file quiet this long is a leftover and never shows as Live now, whatever the server answers or if it cannot.
    static let serverIdleRetention: TimeInterval = 4 * 60 * 60
    /// Finalizing waits this long for the saved meeting, then says "Saved meeting not found yet".
    static let finalizingDeadline: TimeInterval = 180
    /// The save re-transcribes every chunk before the meeting exists (batch HQ, about 0.5 s per 6 s chunk measured on
    /// this Mac), so a long recording gets longer: 180 s plus a twelfth of its length (QA 2026-10-15: a 2 h capture
    /// needs ~600 s and would have said "Saved meeting not found yet" for 7 minutes).
    /// Mac recordings list in Meetings from server 6.73.14 (they skip the pipeline). On an older server their saved
    /// meeting can never be found, so the pane says to update rather than "not found yet" forever.
    static let macRecordingsListedFrom = [6, 73, 14]
    static func macHandoffNeedsServerUpdate(sessionId: String, serverVersion: String?) -> Bool {
        guard sessionId.hasPrefix("mac_"), let serverVersion else { return false }
        let parts = serverVersion.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (have, need) in zip(parts + [0, 0, 0], macRecordingsListedFrom) where have != need { return have < need }
        return false
    }
    static func finalizingDeadline(recorded: TimeInterval?) -> TimeInterval { finalizingDeadline + max(0, recorded ?? 0) / 12 }
    /// A session the server calls closed or missing this long after its file went is a recording ended without saving.
    static let unsavedGrace: TimeInterval = 20
    /// How often an ended session, or a quiet one whose file is still there, asks the server what happened.
    static let statusInterval: TimeInterval = 3
    /// How long a "Recording ended without saving" row stays.
    static let endedRowLifetime: TimeInterval = 600
    static let header = "Live transcript · preliminary · may change when saved"

    static func rowID(_ sessionId: String) -> String { "live:" + sessionId }

    /// 0.5.313: names a live source in the switcher: "Mac recording 10:39 PM" or "Glasses meeting 10:10 PM".
    static func sourceLabel(_ sessionId: String, start: Date?, timeZone: TimeZone = .current) -> String {
        let kind = PhoneMeetingCapture.protected(sessionId) ? "iPhone microphone" : sessionId.hasPrefix("mac_") ? "Mac recording" : "Glasses meeting"
        guard let start else { return kind }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "h:mm a"
        return kind + " " + f.string(from: start)
    }

    /// How long a listed file has been quiet: from the later of the last read's activity and the file's own mtime.
    static func quietFor(_ file: LiveTranscriptFileRow, feed: LiveTranscriptFeed?, now: Date) -> TimeInterval {
        let mtime = Date(timeIntervalSince1970: file.mtimeMs / 1000)
        return now.timeIntervalSince(max(feed?.lastActivityAt ?? mtime, mtime))
    }

    /// Past the server's idle retention: never Live now, and nothing asked.
    static func pastServerRetention(quiet: TimeInterval) -> Bool { quiet >= serverIdleRetention }

    /// A present file quiet past the "No audio" mark, and still inside the retention, asks the server about itself.
    static func asksQuietFileStatus(quiet: TimeInterval) -> Bool { quiet >= quietAfterSeconds && !pastServerRetention(quiet: quiet) }

    /// What the server's answer makes a quiet file still on disk. `active` keeps it live and no answer makes no new
    /// claim. Every other state is the server saying it is done with the session: `saved`, `missing`, `closed`, server
    /// 6.71.14's `receipted`, `recovered` and `quarantined`, and `unknown`, a state this build does not know (an older
    /// server without the route answers nil, see ControllerModel.liveTranscriptServerState). Not live, and never
    /// "ended without saving".
    static func quietFileIsLeftover(serverState: String?) -> Bool {
        guard let serverState else { return false }
        return serverState != "active"
    }

    /// States that end in a saved meeting: the hand-off looks for its row and opens it.
    static func savesMeeting(_ serverState: String?) -> Bool { serverState == "saved" || serverState == "recovered" }

    /// The last sign of audio was this long before the end, at or past the server's idle retention: the server has
    /// auto-saved or closed the session by then, so Control cannot know it went unsaved.
    static func endedPastRetention(lastActivity: Date?, endedAt: Date) -> Bool {
        guard let lastActivity else { return false }
        return pastServerRetention(quiet: endedAt.timeIntervalSince(lastActivity))
    }

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
    /// stale, never one already in the stranded captures banner, never a file quiet past the server's idle retention.
    /// An ended session (a leftover file included) keeps its row while it hands off.
    static func rows(files: [LiveTranscriptFileRow], feeds: [String: LiveTranscriptFeed], serverLive: Int?,
                     stale: Set<String>, stranded: Set<String>, now: Date) -> [LiveTranscriptRow] {
        var out: [LiveTranscriptRow] = []
        var seen = Set<String>()
        // A leftover's file is still listed; its feed is ended and takes the hand-off rows below.
        let fileIDs = Set(files.filter { feeds[$0.sessionId]?.leftover != true }.map(\.sessionId))
        if (serverLive ?? 0) > 0 {
            for file in files where !stale.contains(file.sessionId) && !stranded.contains(file.sessionId) {
                let feed = feeds[file.sessionId]
                if feed?.ended == true { continue }
                if pastServerRetention(quiet: quietFor(file, feed: feed, now: now)) { continue }
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
            guard feed.phase != .saved, feed.phase != .ended, !stranded.contains(feed.sessionId) else { continue }
            // 0.5.288: a leftover file shows a row only on its way to a saved meeting, and "Recording ended without
            // saving" never shows for a session quiet past the server's retention.
            if feed.leftover && !savesMeeting(feed.serverState) { continue }
            if feed.phase == .endedUnsaved, let ended = feed.endedAt,
               endedPastRetention(lastActivity: feed.lastActivityAt, endedAt: ended) { continue }
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
    /// 0.5.288: never "ended without saving" for a leftover file (the server finished it earlier, perhaps receipted
    /// with no speech) or for a session whose last audio was past the server's retention: those are `.ended`, no row.
    /// A leftover the server answers with a state this build does not know is `.ended` too.
    static func handoff(serverState: String?, endedAt: Date, now: Date, savedRowFound: Bool,
                        lastActivity: Date? = nil, leftover: Bool = false, recorded: TimeInterval? = nil) -> LiveTranscriptPhase {
        if savedRowFound { return .saved }
        let waited = now.timeIntervalSince(endedAt)
        if serverState == "closed" || serverState == "missing" {
            if leftover || endedPastRetention(lastActivity: lastActivity, endedAt: endedAt) { return .ended }
            return waited >= unsavedGrace ? .endedUnsaved : .finalizing
        }
        // Server 6.71.14: receipted is finished with no meeting (no speech, say), so there is nothing to wait for.
        if serverState == "receipted" { return .ended }
        if leftover, let serverState, serverState != "active", !savesMeeting(serverState) { return .ended }
        return waited >= finalizingDeadline(recorded: recorded) ? .notFoundYet : .finalizing
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

    /// The close control on a Live now row: a stopped Mac capture finishes delivering; a glasses recording with no audio
    /// for `quietAfterSeconds` can be ended and saved. A row still receiving audio, or no longer live, offers nothing.
    static func endActionTitle(row: LiveTranscriptRow, now: Date) -> String? {
        guard !PhoneMeetingCapture.protected(row.sessionId) else { return nil }
        guard row.phase == .live else { return nil }
        if row.deliveryLabel != nil { return "Finish saving" }
        guard let last = row.lastActivity, now.timeIntervalSince(last) >= quietAfterSeconds else { return nil }
        return "End and save"
    }

    static func phaseLabel(_ phase: LiveTranscriptPhase) -> String? {
        switch phase {
        case .live: nil
        case .finalizing: "Finalizing"
        case .saved: "Saved"
        case .endedUnsaved: "Recording ended without saving"
        case .notFoundYet: "Saved meeting not found yet"
        case .ended: "Recording ended"
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

// MARK: - Stop and save a glasses meeting (0.5.321)
//
// Kept in this file (not its own) so every lane and scripts/build-release.sh that lists the live meeting sources by name
// compiles it with them.

/// 0.5.321 (Miles, 2026-10-17): stop and save a G2 glasses meeting from COS Control.
///
/// COS Control never saves a live glasses meeting itself. A server-side save closes the session while the phone keeps
/// its microphone on, the lens keeps showing REC and every later chunk is refused, so the meeting would split in two.
/// Control ASKS instead: the helper's `meeting-stop-request` posts to the server's stop-request route, the server puts
/// `meeting_stop_requested` on the display bus, and the glasses companion (6.10.644) claims the request and runs its
/// own Stop, the same one the lens and the phone run. Control polls the request and says what happened in words.
///
/// The glasses can claim only within the server's claim window (10 s, on the server's clock). Control waits a little
/// past it before it says "Glasses not connected", so after that line nothing can stop the meeting behind the person's
/// back. Mac recordings are not this path: they stop from Record on Mac, unchanged.
///
/// Pure: the model runs the helper and the timers; everything here is decided from the helper's details and the clock,
/// so Tests/G2MeetingStopChecks.swift runs it.
enum G2MeetingStop {
    /// Seconds Control waits past the server's claim window before it gives up on the glasses.
    static let claimGraceSeconds: TimeInterval = 3
    /// Used when the server's answer does not carry its window (it always does from server 6.76.0).
    static let defaultClaimWindowSeconds: TimeInterval = 10
    /// After the glasses claimed, how long Control follows the save before it stops watching.
    static let saveWaitSeconds: TimeInterval = 180

    static let buttonLabel = "Stop and save"
    static let confirmTitle = "Stop and save this glasses meeting?"
    static let confirmMessage = "COS asks the glasses to stop recording and save the meeting. Nothing stops unless the glasses answer."
    static let confirmAction = "Stop and save"

    /// A glasses session COS Control may ask about: never a Mac recording (those stop from Record on Mac).
    static func isGlassesSession(_ sessionId: String) -> Bool {
        !PhoneMeetingCapture.protected(sessionId) && !sessionId.hasPrefix("mac_") && sessionId.range(of: "\\A[A-Za-z0-9:_-]{3,96}\\z", options: .regularExpression) != nil
    }

    enum Phase: Equatable, Sendable {
        /// The request is on its way, or the glasses have not answered yet.
        case asking
        /// The glasses claimed the request and are stopping; the save follows.
        case stopping
        /// The server is already saving this meeting.
        case finalizing
        case saved(filename: String?, minutes: Int?)
        case notConnected
        case notRecordingHere
        case otherMeeting
        case alreadyStopped
        case serverUnreachable
        case serverTooOld
        case unauthorized
        case stillSaving
        case serverRestarted
        case failed(status: Int)

        /// Control keeps polling while this holds.
        var isActive: Bool {
            switch self {
            case .asking, .stopping, .finalizing: true
            default: false
            }
        }

        /// True for the lines that say the meeting was not stopped.
        var nothingStopped: Bool {
            switch self {
            case .notConnected, .notRecordingHere, .otherMeeting, .serverUnreachable, .serverTooOld, .unauthorized, .serverRestarted, .failed: true
            default: false
            }
        }

        var line: String {
            switch self {
            case .asking: "Asking the glasses to stop…"
            case .stopping: "The glasses are stopping. Saving the meeting…"
            case .finalizing: "Saving the meeting…"
            case .saved(let filename, let minutes):
                switch (G2MeetingStop.displayName(filename), minutes) {
                case (let name?, let m?): "Saved: \(name), \(m) min."
                case (let name?, nil): "Saved: \(name)."
                case (nil, let m?): "Saved, \(m) min."
                case (nil, nil): "Saved."
                }
            case .notConnected: "Glasses not connected. Nothing was stopped. Stop it on the glasses (hold menu, Stop Meeting) or on the phone."
            case .notRecordingHere: "The glasses are not recording this meeting. Nothing was stopped."
            case .otherMeeting: "The glasses are recording a different meeting. Nothing was stopped."
            case .alreadyStopped: "This meeting already stopped."
            case .serverUnreachable: "COS server unreachable. Nothing was stopped."
            case .serverTooOld: "This COS server cannot stop glasses meetings yet. Update the server, or stop it on the glasses or phone."
            case .unauthorized: "Reconnect COS Control to the server. Nothing was stopped."
            case .stillSaving: "The glasses stopped. The save is still running; check Meetings in a minute."
            case .serverRestarted: "The COS server restarted before the glasses answered. Nothing was stopped."
            case .failed(let status): "The server could not ask the glasses (HTTP \(status)). Nothing was stopped."
            }
        }
    }

    /// `2026-10-17_G2_Recording_….md` reads without its extension.
    static func displayName(_ filename: String?) -> String? {
        guard let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty else { return nil }
        return filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
    }

    struct Request: Equatable, Sendable {
        let phase: Phase
        let requestId: String?
        let claimWindowSeconds: TimeInterval
    }

    /// The helper's details: `transport` is `answered` with `httpStatus` and `body`, or `unavailable`.
    private static func answer(_ details: [String: JSONValue]?) -> (status: Int, body: [String: JSONValue])? {
        guard let details, details["transport"]?.string == "answered", let status = details["httpStatus"]?.int else { return nil }
        return (status, details["body"]?.object ?? [:])
    }

    private static func savedPhase(_ body: [String: JSONValue]) -> Phase {
        let receipt = body["saveReceipt"]?.object
        return .saved(filename: receipt?["filename"]?.string, minutes: receipt?["durationMin"]?.int)
    }

    /// What the first answer means. `details` is nil when the helper itself failed.
    static func afterRequest(_ details: [String: JSONValue]?) -> Request {
        guard let (status, body) = answer(details) else { return Request(phase: .serverUnreachable, requestId: nil, claimWindowSeconds: 0) }
        let window = body["claimWindowMs"]?.double.map { $0 / 1000 } ?? defaultClaimWindowSeconds
        switch status {
        case 202:
            guard let requestId = body["requestId"]?.string, !requestId.isEmpty else { return Request(phase: .serverTooOld, requestId: nil, claimWindowSeconds: 0) }
            return Request(phase: .asking, requestId: requestId, claimWindowSeconds: window)
        case 200 where body["state"]?.string == "saved": return Request(phase: savedPhase(body), requestId: nil, claimWindowSeconds: 0)
        // Already saving: there is no request to follow, so this is the line it ends on.
        case 200 where body["state"]?.string == "finalizing": return Request(phase: .stillSaving, requestId: nil, claimWindowSeconds: 0)
        case 409 where body["reason"]?.string == "not_live": return Request(phase: .alreadyStopped, requestId: nil, claimWindowSeconds: 0)
        case 401, 403: return Request(phase: .unauthorized, requestId: nil, claimWindowSeconds: 0)
        // A server without the route answers 404 with no reason of its own.
        case 404: return Request(phase: .serverTooOld, requestId: nil, claimWindowSeconds: 0)
        default: return Request(phase: .failed(status: status), requestId: nil, claimWindowSeconds: 0)
        }
    }

    /// One poll. `elapsed` counts from the request; `claimed` is whether an earlier poll saw the glasses claim it.
    static func afterPoll(_ details: [String: JSONValue]?, elapsed: TimeInterval, claimWindowSeconds: TimeInterval, claimed: Bool) -> Phase {
        let deadline = claimWindowSeconds + claimGraceSeconds
        guard let (status, body) = answer(details) else {
            // The glasses claim through this server, so an unreachable server stopped nothing unless they already had.
            if claimed { return elapsed > saveWaitSeconds ? .stillSaving : .stopping }
            return elapsed > deadline ? .serverUnreachable : .asking
        }
        if status == 404 { return claimed ? .stillSaving : .serverRestarted }
        if status == 401 || status == 403 { return claimed ? .stillSaving : .unauthorized }
        guard (200..<300).contains(status) else { return claimed ? .stopping : (elapsed > deadline ? .failed(status: status) : .asking) }
        switch body["state"]?.string {
        case "saved": return savedPhase(body)
        case "claimed":
            if elapsed > saveWaitSeconds { return .stillSaving }
            return body["finalizing"]?.bool == true ? .finalizing : .stopping
        case "refused":
            switch body["refusal"]?.string {
            case "not_recording": return .notRecordingHere
            case "other_session": return .otherMeeting
            // Its own Stop is running: follow it to the save.
            case "stop_in_progress": return elapsed > saveWaitSeconds ? .stillSaving : .finalizing
            default: return .notConnected
            }
        case "expired": return .notConnected
        case "pending": return elapsed > deadline ? .notConnected : .asking
        default: return elapsed > deadline ? .notConnected : .asking
        }
    }
}

/// The stop Control is following, and where it got to. One at a time.
struct G2MeetingStopProgress: Equatable, Sendable {
    let sessionId: String
    var phase: G2MeetingStop.Phase
}

// MARK: - The live meeting view (0.5.336, server 6.86.0)
//
// Kept in this file (not its own) for the same reason as the stop above: every lane and scripts/build-release.sh that
// lists the live meeting sources by name compiles it with them.
//
// 0.5.336 (Miles, 2026-10-22 plan, decisions 09:35 and 15:21): the live meeting window shows the meeting's real title, a
// line that counts what the cue writer found so far, the voices heard, each cue under the turn it belongs to, a grey
// line for the words still being transcribed, and a bottom bar with the elapsed time and, for a Mac recording, an
// audiogram. This is the pure part: what the server advertises, the counts, the anchoring, the strip, the audiogram's
// history ring, the preview rate cap and the grey line's rules. Pure Foundation, so Tests/LiveMeetingChecks.swift runs it.
//
// CAPABILITY, NEVER STATUS CODE. Everything new is gated on what /api/health advertises (the helper's status forwards
// it): `capabilities.liveMeeting.protocol == 1`, `liveMeeting.macLiveCues`, `liveMeeting.provisional` and
// `capabilities.liveCues.kinds`. An older server (6.84, 6.85) advertises none of them, and the view is today's.
//
// SECRET BOUNDARY. Nothing here logs or prints. The grey text lives in memory only, for the one meeting on screen.

/// One grey line: the newest preview of the chunk still being transcribed.
struct LiveProvisionalLine: Equatable, Sendable {
    let chunkIndex: Int
    let previewGen: Int
    let text: String
}

/// A participant in the strip: initials and the name as the transcript shows it.
struct LiveMeetingParticipant: Equatable, Identifiable, Sendable {
    let name: String
    let initials: String
    /// Unattributed audio ("Speaker", "Ext", "Unidentified 2") shares one chip.
    /// A stable Voice N cluster is anonymous but distinct, so it retains its own chip.
    let unidentified: Bool
    var id: String { unidentified ? "?unidentified" : name }
    var anonymous: Bool { unidentified || MacVoiceLabel.isVoice(name) }
    var accessibilityName: String { MacVoiceLabel.isVoice(name) ? name + ", unnamed speaker" : name }
}

/// The Mac recording start's answer about live cues (server 6.86.0).
struct MacLiveCuesArm: Equatable, Sendable {
    let armed: Bool
    let reason: String?
}

/// The bottom bar's audiogram: the last `capacity` levels, 10 a second, oldest first. A level is 0 to 1 from
/// DictationLevelMeter (0 is at or under the room's own floor, drawn dotted as silence). Fixed size: pushing never grows it.
struct LiveAudiogramRing: Equatable, Sendable {
    /// 12 seconds at the capture drain's 10 Hz.
    static let capacity = 120
    /// At or under this a level draws as silence (a dotted segment).
    static let silence = 0.02
    private var storage = [Double](repeating: 0, count: LiveAudiogramRing.capacity)
    /// Where the next level goes; storage[next] is the oldest.
    private var next = 0
    private(set) var pushed = 0

    mutating func push(_ level: Double) {
        storage[next] = level.isFinite ? min(1, max(0, level)) : 0
        next = (next + 1) % Self.capacity
        pushed += 1
    }

    /// Oldest first, newest last, always `capacity` long (silence before the first push).
    var levels: [Double] { Array(storage[next...] + storage[..<next]) }
    var latest: Double { storage[(next + Self.capacity - 1) % Self.capacity] }
    static func isSilent(_ level: Double) -> Bool { level <= silence }
}

/// The Mac grey line's posts to POST /api/transcribe-stream/preview: at most one in flight, at least `interval` apart,
/// only with enough of the open chunk to read, and the newest `maximumBytes` of it. `previewGen` starts at 0 for each
/// chunk and rises with each post for that chunk; an answer older than one already shown is dropped. After
/// `breakerFailures` failed posts in a row the recording stops posting for `breakerPause`, then tries one post (the grey
/// line is cosmetic).
struct LiveMeetingPreviewGate: Equatable, Sendable {
    static let interval: TimeInterval = 2
    /// One second of 16 kHz mono PCM16.
    static let minimumBytes = 32_000
    /// 15 seconds of 16 kHz mono PCM16; with the 44-byte header it stays under the server's 512 KB.
    static let maximumBytes = 480_000
    static let breakerFailures = 3
    /// 0.5.337 (loop audit N14): an open breaker tries one post again after this long (it stopped for the whole recording).
    static let breakerPause: TimeInterval = 60
    private(set) var inFlight = false
    private(set) var lastPost: Date?
    private(set) var chunkIndex = -1
    private(set) var generation = -1
    private(set) var shownChunk = -1
    private(set) var shownGeneration = -1
    private(set) var failures = 0

    var open: Bool { failures < Self.breakerFailures }
    /// A post may be tried now: the breaker is closed, or its pause has passed (the loop asks before it reads any audio).
    func mayPost(now: Date) -> Bool { open || (lastPost.map { now.timeIntervalSince($0) >= Self.breakerPause } ?? false) }

    /// The previewGen for a post of `chunkIndex` with `bytes` of its audio, or nil when no post may go now.
    mutating func begin(chunkIndex: Int, bytes: Int, now: Date) -> Int? {
        if !open {
            // One post again after the pause; a failure opens the breaker again at once (failures goes back to the limit).
            guard let lastPost, now.timeIntervalSince(lastPost) >= Self.breakerPause else { return nil }
            failures = Self.breakerFailures - 1
        }
        guard open, !inFlight, chunkIndex >= 0, bytes >= Self.minimumBytes else { return nil }
        if let lastPost, now.timeIntervalSince(lastPost) < Self.interval { return nil }
        if chunkIndex != self.chunkIndex { self.chunkIndex = chunkIndex; generation = -1 }
        generation += 1
        inFlight = true
        lastPost = now
        return generation
    }

    /// The post came back: `answered` is false for a transport or server failure (a 204 miss is an answer).
    mutating func finish(answered: Bool) {
        inFlight = false
        failures = answered ? 0 : failures + 1
    }

    /// Whether an answer may replace what is shown: never older than the newest shown, by chunk then generation.
    mutating func accept(chunkIndex: Int, previewGen: Int) -> Bool {
        guard chunkIndex > shownChunk || (chunkIndex == shownChunk && previewGen > shownGeneration) else { return false }
        shownChunk = chunkIndex; shownGeneration = previewGen
        return true
    }

    /// The bytes a post sends: the newest `maximumBytes`, on a sample boundary.
    static func window(_ pcm: Data) -> Data {
        let even = pcm.count - pcm.count % 2
        let start = max(0, even - maximumBytes)
        return pcm.subdata(in: pcm.startIndex + start..<pcm.startIndex + even)
    }
}

/// 0.5.339: the glasses meeting's level strip (server 6.87.0, `capabilities.liveMeeting.chunkLevels`). One bar per chunk,
/// newest on the right, dotted where the chunk held almost no speech. It trails the room by a chunk (about 6 s) plus
/// transcription, which its VoiceOver label says.
enum LiveLevelStrip {
    /// Under this many Silero speech seconds a chunk draws dotted: the server's own quiet gate (QUIET_SPEECH_SEC).
    static let speechFloor = 0.5
    /// Without speech seconds (the gate fell back to RMS), at or under this level: about the gate's RMS 150.
    static let levelFloor = 0.27
    /// Points per chunk: a bar and its gap.
    static let step: Double = 5
    static let accessibilityLabel = "Audio level, a few seconds behind"

    static func isSilent(_ level: LiveChunkLevel) -> Bool {
        if let speech = level.speechSec { return speech < speechFloor }
        return level.level <= levelFloor
    }

    /// The levels a strip `width` points wide draws: the newest that fit, oldest first. The oldest are the ones clipped.
    static func visible(_ levels: [LiveChunkLevel], width: Double) -> [LiveChunkLevel] {
        guard width.isFinite, width >= step else { return [] }
        let fit = Int((width / step).rounded(.down))
        return levels.count > fit ? Array(levels.suffix(fit)) : levels
    }

    static func accessibilityValue(_ levels: [LiveChunkLevel]) -> String {
        guard let last = levels.last else { return "Waiting for the first chunk" }
        return isSilent(last) ? "Quiet" : "Speech"
    }
}

/// 0.5.339: the bottom bar's widths, from the approved mock (wk43 mock-339). The meter shrinks first, clipping its
/// oldest samples, down to `meterFloor`; under `labelWidth` of bar Add file is icon-only (its VoiceOver label stays "Add
/// file"); under `meterWidth` the still glyph takes the meter's place. The buttons never wrap.
enum LiveRecordingBarLayout {
    static let labelWidth: Double = 560
    static let meterWidth: Double = 340
    static let meterFloor: Double = 40
    static let addFileLabel = "Add file"

    struct Mode: Equatable, Sendable {
        let addFileLabelled: Bool
        let meter: Bool
    }

    static func mode(barWidth: Double) -> Mode {
        Mode(addFileLabelled: barWidth >= labelWidth, meter: barWidth >= meterWidth)
    }
}

/// 0.5.339: one place for files in the live pane. The Files row under the header: "Files · 2", the total size and a
/// chevron; hidden with no files (unless an Undo for a removed one is still offered).
enum LiveMeetingFiles {
    static let dropLabel = "Drop to add to this meeting"
    static let pasteLabel = "Paste screenshot"
    static let chooseLabel = "Choose files\u{2026}"
    static let note = "On this Mac only. COS keeps copies in ~/cos-data/meeting-context and saves them with the meeting."

    static func rowTitle(count: Int) -> String { "Files \u{00B7} \(count)" }
    static func showsRow(count: Int, pendingUndo: Int) -> Bool { count > 0 || pendingUndo > 0 }
}

enum LiveMeeting {
    /// The five kinds the 6.86.0 writer can write, in the server's spelling (shared/live-cues-v2.ts CUE_KINDS).
    static let knownKinds = ["reinforce", "challenge", "decision", "promise", "followUp"]
    /// The kinds the header counts: what was decided or promised in the meeting, not the coaching ones.
    static let countedKinds = ["decision", "promise", "followUp"]
    /// The inline cues re-ask the cue history this often; the history store's own 15 s floor decides when it reads.
    static let inlineCueCheckSeconds: TimeInterval = 5
    /// The grey line never shows more than this (the server keeps the last 600 characters).
    static let provisionalMaxCharacters = 600

    /// The inline line's prefix for a kind, or nil for a kind this build does not know (drawn as a plain cue).
    static func kindLabel(_ kind: String) -> String? {
        switch kind {
        case "decision": "Decision"
        case "promise": "Promise"
        case "followUp": "Follow-up"
        case "challenge": "Challenge"
        case "reinforce": "Reinforce"
        default: nil
        }
    }

    /// "2 decisions, 1 promise and 1 follow-up", or nil when none of the counted kinds is there yet.
    static func countsPhrase(kinds: [String]) -> String? {
        let words: [(kind: String, one: String, many: String)] = [("decision", "decision", "decisions"), ("promise", "promise", "promises"),
                                                                    ("followUp", "follow-up", "follow-ups")]
        let parts = words.compactMap { word -> String? in
            let n = kinds.filter { $0 == word.kind }.count
            return n == 0 ? nil : "\(n) " + (n == 1 ? word.one : word.many)
        }
        return joined(parts)
    }

    /// "a", "a and b", "a, b and c".
    static func joined(_ parts: [String]) -> String? {
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// The line under the title. Live: "Recording on this Mac · 2 decisions and 1 promise so far". Ended: the counts
    /// alone, or nil. `kinds` is nil when the server does not list its kinds: then no counts at all.
    static func statusLine(sessionId: String, ended: Bool, kinds: [String]?) -> String? {
        guard PhoneMeetingCapture.protected(sessionId) else { return statusLine(mac: sessionId.hasPrefix("mac_"), ended: ended, kinds: kinds) }
        let counts = kinds.flatMap(countsPhrase)
        if ended { return counts.map { "iPhone microphone · " + $0 } ?? "iPhone microphone recording ended" }
        return counts.map { "Recording on iPhone microphone · " + $0 + " so far" } ?? "Recording on iPhone microphone"
    }

    static func statusLine(mac: Bool, ended: Bool, kinds: [String]?) -> String? {
        let counts = kinds.flatMap(countsPhrase)
        if ended { return counts }
        let source = mac ? "Recording on this Mac" : "Recording on the glasses"
        return counts.map { source + " · " + $0 + " so far" } ?? source
    }

    /// Whether a Mac recording's title is the automatic one ("Mac recording 2:05 PM", "Zoom meeting 2:05 PM").
    static func isAutomaticTitle(_ title: String) -> Bool {
        title == "Mac recording" || title.range(of: "\\A(Mac recording|.{1,40} meeting) [0-9]{1,2}:[0-9]{2} (AM|PM)\\z", options: .regularExpression) != nil
    }

    /// A calendar event is this meeting's when it starts within this of the recording's start.
    static let calendarMatchSeconds: TimeInterval = 20 * 60

    /// The header's title: a typed Mac title, else the calendar event that started near the recording, else the Mac
    /// recording's automatic title, else "Glasses meeting 10:10 AM".
    static func title(sessionId: String, macTitle: String?, calendar: (title: String, start: Date)?, start: Date?,
                      timeZone: TimeZone = .current) -> String {
        if let macTitle = macTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !macTitle.isEmpty, !isAutomaticTitle(macTitle) { return macTitle }
        if let calendar, let start, abs(calendar.start.timeIntervalSince(start)) <= calendarMatchSeconds {
            let name = calendar.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return String(name.prefix(160)) }
        }
        if let macTitle = macTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !macTitle.isEmpty { return macTitle }
        return LiveTranscript.sourceLabel(sessionId, start: start, timeZone: timeZone)
    }

    /// A speaker label that is not a recognized voice.
    static func unidentified(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["", "speaker", "ext", "unknown", "unidentified", "?"].contains(lower) || lower.hasPrefix("unidentified ")
            || lower.hasPrefix("speaker ")
    }

    /// "Priya Raman" is "PR", "Jordan" is "J".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// The strip: each voice heard so far, in the order first heard, and which one spoke last. On a Mac recording "You"
    /// never shows (the global tap leaves the microphone out). Unattributed audio shares one chip;
    /// stable Voice N clusters retain their labels without being presented as recognized identities.
    static func participants(_ turns: [LiveTranscriptTurn], mac: Bool) -> (people: [LiveMeetingParticipant], lastHeard: String?) {
        var people: [LiveMeetingParticipant] = []
        var seen = Set<String>()
        var lastHeard: String?
        for turn in turns {
            let name = turn.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            if mac, name.lowercased() == "you" { continue }
            let person = unidentified(name) ? LiveMeetingParticipant(name: "Unidentified", initials: "?", unidentified: true)
                                            : LiveMeetingParticipant(name: name, initials: MacVoiceLabel.isVoice(name) ? String(name.dropFirst(6)) : initials(name), unidentified: false)
            lastHeard = person.id
            if seen.insert(person.id).inserted { people.append(person) }
        }
        // The unidentified chip goes last, after the named voices, which keep the order they were first heard in.
        return (people.filter { !$0.unidentified } + people.filter(\.unidentified), lastHeard)
    }

    /// Each cue under the turn it belongs to: the last turn that had started by the cue's `createdAt` (the turn in
    /// progress when it was written). A cue from before the first turn goes under the first. Nothing anchors without the
    /// meeting's start or any turn; those cues stay in the Cues tab only. Within a turn, oldest first.
    /// 0.5.337 (performance audit W7): each turn's cues, looked up once per redraw. The rows filtered every cue for every
    /// turn (turns x cues). In the anchored order; a cue the anchoring did not place is left out, as before.
    static func cuesByTurn<Cue>(_ cues: [Cue], id: (Cue) -> String, anchored: [Int: [String]]) -> [Int: [Cue]] {
        var turnOf: [String: Int] = [:]
        for (turn, ids) in anchored { for cue in ids { turnOf[cue] = turn } }
        var out: [Int: [Cue]] = [:]
        for cue in cues { if let turn = turnOf[id(cue)] { out[turn, default: []].append(cue) } }   // the history's order
        return out
    }

    static func anchor(cues: [(id: String, createdAt: Date)], turns: [LiveTranscriptTurn], start: Date?) -> [Int: [String]] {
        guard let start, let first = turns.first else { return [:] }
        var out: [Int: [String]] = [:]
        for cue in cues.sorted(by: { $0.createdAt < $1.createdAt }) {
            let offset = cue.createdAt.timeIntervalSince(start) * 1000
            let turn = turns.last { Double($0.elapsedMs) <= offset } ?? first
            out[turn.id, default: []].append(cue.id)
        }
        return out
    }

    /// The highest chunk index the transcript holds as final: the chunks read or the helper's settled cursor.
    static func lastFinalChunk(_ feed: LiveTranscriptFeed?) -> Int {
        guard let feed else { return -1 }
        return max(feed.cursor, feed.chunks.keys.max() ?? -1)
    }

    /// The grey text to show, or nil: only for a chunk past the last final one, never empty, at most 600 characters
    /// (the newest ones).
    static func visibleProvisional(_ line: LiveProvisionalLine?, lastFinalChunk: Int) -> String? {
        guard let line, line.chunkIndex > lastFinalChunk else { return nil }
        let text = line.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > provisionalMaxCharacters ? "…" + String(text.suffix(provisionalMaxCharacters)) : text
    }

    /// The helper's `live-provisional` details: nil when the read did not answer in the contract; otherwise whether the
    /// server holds the meeting and the line (nil when nothing is grey).
    static func provisional(_ details: [String: JSONValue], sessionId: String) -> (live: Bool, line: LiveProvisionalLine?)? {
        guard details["transport"]?.string == "answered", details["httpStatus"]?.int == 200, let live = details["live"]?.bool else { return nil }
        guard let object = details["provisional"]?.object else { return (live, nil) }
        guard let index = object["chunkIndex"]?.int, index >= 0, let gen = object["previewGen"]?.int, gen >= 0,
              let text = object["text"]?.string else { return (live, nil) }
        return (live, LiveProvisionalLine(chunkIndex: index, previewGen: gen, text: text))
    }

    /// The Mac preview post's answer: the line, or nil for a miss (204) or anything outside the contract.
    static func previewAnswer(_ details: [String: JSONValue], chunkIndex: Int, previewGen: Int) -> LiveProvisionalLine? {
        guard details["miss"]?.bool != true, details["chunkIndex"]?.int == chunkIndex, details["previewGen"]?.int == previewGen,
              let text = details["text"]?.string else { return nil }
        return LiveProvisionalLine(chunkIndex: chunkIndex, previewGen: previewGen, text: text)
    }

    /// The Mac start answer's `liveCues`, or nil when the server did not say (an older server, or the flag not sent).
    static func arm(_ value: JSONValue?) -> MacLiveCuesArm? {
        guard let object = value?.object, let armed = object["armed"]?.bool else { return nil }
        let reason = object["reason"]?.string.flatMap { $0.range(of: "\\A[a-z][a-z0-9_]{0,63}\\z", options: .regularExpression) != nil ? $0 : nil }
        return MacLiveCuesArm(armed: armed, reason: armed ? nil : reason)
    }

    /// "Cues off: the Live cues switch is off" for a refusal; nil when armed or not asked. Never a recording error.
    static func armLine(_ arm: MacLiveCuesArm?) -> String? {
        guard let arm, !arm.armed else { return nil }
        return "Cues off: " + reasonWords(arm.reason)
    }

    /// 0.5.337 (loop audit W9): the refusal a key in Settings fixes.
    static func needsDecisionKey(_ arm: MacLiveCuesArm?) -> Bool {
        guard let arm, !arm.armed else { return false }
        return arm.reason == "decision_not_configured" || arm.reason == "jev_not_configured"
    }

    static func reasonWords(_ code: String?) -> String {
        switch code {
        case "master_flag_off": "the Live cues switch is off"
        case "mac_cues_off": "cues for Mac recordings are off on the server"
        case "meeting_ended": "the meeting has ended"
        // 0.5.337 (loop audit W9): the server's words for these (LiveCues.reasonLine): the budget is weekly, and each one
        // says when it lifts.
        case "budget_exhausted": "this week's live cues limit is used up, and cues start again next week"
        case "jev_cap_reached", "decision_cap_reached": "the decision model's limit is used up, and cues start again by themselves"
        case "jev_breaker_open", "decision_breaker_open": "the decision model failed several times, and cues start again by themselves after a pause"
        case "decision_not_configured", "jev_not_configured": "no decision model key is set"
        case "decision_invalid_provider": "the decision model setting is not valid"
        case "claude_not_found": "the server cannot find Claude"
        case "api_key_in_env": "the server has an API key in its environment"
        case let code?: code.replacingOccurrences(of: "_", with: " ")
        case nil: "unavailable"
        }
    }

    /// The bottom bar's and the rail's elapsed time: "0:07", "12:04", "1:02:03".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
