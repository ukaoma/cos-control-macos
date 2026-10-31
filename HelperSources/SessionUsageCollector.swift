import Foundation
import SQLite3
import CryptoKit

/// Incremental, transactionally checkpointed import of the current Mac user's session logs.
/// The database retains measurements even if a source session is archived/deleted later.
final class SessionUsageCollector {
    struct Cursor: Codable {
        var offset: UInt64 = 0
        var prefix: String = ""
        var model = "Unknown model"
        var provider = "Unknown provider"
        var session = ""
        var cumulative: [String: Int64] = [:]
        var malformed = 0
        var gaps = 0
        var scannedAt: Double = 0
        var waitingForAppend = false
        var oversizedRows = 0
        var skippingLongLine: Bool? // Optional so existing checkpoints decode unchanged.
        /// A compressed log only: "done" or "failed", nil while it is still being read. Its `offset` counts decoded bytes.
        var compressedEnd: String?
        /// A compressed log only: passes in a row that ran out of time with no progress.
        var compressedStalls: Int?
    }
    struct Event {
        var id: String
        var timestamp: String
        var provider: String
        var model: String
        var counts: SessionUsageCounts
        var oneHour: Int64 = 0
        /// What the source itself says the request cost at model rates. Wins over the local rate card.
        var reportedUSD: Double? = nil
    }
    /// Why Keychain gave no answer, as opposed to a person saying no. Carries no part of the sign-in.
    enum KeychainMiss: Equatable, Sendable {
        case timedOut, launchFailed, exit(Int32)
        var word: String {
            switch self {
            case .timedOut: return "timed out"
            case .launchFailed: return "could not start"
            case .exit(let code): return "exit \(code)"
            }
        }
    }
    /// Cursor's sign-in, read only for the moment of a request. Never stored, logged or put in an argument.
    /// `blocked` is a real denial and keeps the exit code that said so; `unavailable` is a read that got no answer.
    enum CursorFeedToken: Equatable { case token(String), missing, expired, blocked(exit: Int32), unavailable(KeychainMiss) }
    /// status 0 means the request never got an answer.
    struct CursorFeedReply { var status: Int; var body: Data? }
    struct CursorFeedState: Codable {
        var state = SessionUsageCursorFeedStatus.State.backfilling
        var backfillDone = false
        /// The window being read, 0 when no run is open. Pages stay stable because its end stays fixed while new
        /// usage arrives.
        var runStartMs: Int64 = 0
        var runEndMs: Int64 = 0
        var nextPage = 1
        var runSeen = 0
        var runTotal = 0
        var watermarkMs: Int64 = 0
        var nextAllowedAt: Double = 0
        var failures = 0
        var lastSuccessAt: Double?
        /// Keychain reads in a row with no answer. Optional so existing checkpoints decode unchanged.
        var keychainMisses: Int?
    }
    static let cursorFeedStartMs: Int64 = 1_577_836_800_000 // 2020-01-01, before any account history
    static let cursorPageSize = 500
    static let cursorPageLimit = 400
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private var db: OpaquePointer?
    private let home: URL
    private var zone: TimeZone = .current
    /// Beside the database. Times and causes only, so a support question can be answered without any token.
    private let feedLog: URL
    /// Node binaries that may decompress older Codex logs, in the order to try them. Empty reads none of them.
    var compressedLogNodes: [String] = []
    private let dayFormatter = DateFormatter()
    private let iso = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(home: URL, database: URL? = nil, timeZone: TimeZone = .current) throws {
        self.home = home
        let file = database ?? home.appendingPathComponent("Library/Application Support/COS Control/usage/session-usage-v1.sqlite")
        feedLog = file.deletingLastPathComponent().appendingPathComponent("cursor-feed.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Failure(message: "Could not open the local usage history.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        sqlite3_busy_timeout(db, 1500)
        try Self.execute(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, size INTEGER NOT NULL, modified REAL NOT NULL, state TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, usd REAL, pricing TEXT NOT NULL); CREATE INDEX IF NOT EXISTS usage_day ON events(day);")
        let existing = try query("SELECT value FROM meta WHERE key='timezone'").first?.first
        zone = existing.flatMap(TimeZone.init(identifier:)) ?? timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian); dayFormatter.timeZone = zone; dayFormatter.dateFormat = "yyyy-MM-dd"
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try run("INSERT OR IGNORE INTO meta VALUES('timezone',?)", [zone.identifier])
    }
    deinit { sqlite3_close(db) }
    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: "Usage history is busy or could not be written.") }
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw Failure(message: "Could not query usage history.") }
        for (i, value) in values.enumerated() { sqlite3_bind_text(s, Int32(i+1), value, -1, transient) }
        return s
    }
    private func run(_ sql: String, _ values: [String] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Failure(message: "Could not save usage history.") }
    }
    private func query(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        var rows: [[String]] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Failure(message: "Could not read usage history.") }
            rows.append((0..<sqlite3_column_count(s)).map { i in
                // SQLite's text conversion rounds REAL values to fifteen digits.
                // Preserve the stored Double so unchanged file mtimes compare exactly;
                // rounding them can reset every large-file checkpoint on each pass.
                if sqlite3_column_type(s,i) == SQLITE_FLOAT { return String(sqlite3_column_double(s,i)) }
                return sqlite3_column_text(s,i).map { String(cString: $0) } ?? ""
            })
        }
        return rows
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func record(_ event: Event) throws {
        guard event.counts.total > 0, let date = fractional.date(from: event.timestamp) ?? iso.date(from: event.timestamp) else { return }
        let c = event.counts
        let cost = event.reportedUSD ?? SessionUsagePricing.estimate(provider: event.provider, model: event.model, counts: c, oneHour: event.oneHour)
        // A streamed Claude message repeats its usage per content block. Keep the most complete observation.
        try run("""
            INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            input=excluded.input, output=excluded.output, cache_read=excluded.cache_read, cache_write=excluded.cache_write,
            usd=excluded.usd, pricing=excluded.pricing
            WHERE excluded.input+excluded.output+excluded.cache_read+excluded.cache_write > events.input+events.output+events.cache_read+events.cache_write
            """, [event.id, dayFormatter.string(from: date), event.provider, event.model, String(c.input), String(c.output), String(c.cacheRead), String(c.cacheWrite), cost.map { String($0) } ?? "", event.reportedUSD != nil ? "cursor-reported-v1" : SessionUsagePricing.version])
        // Binding a missing price as text keeps the SQL simple; normalize to NULL before aggregation.
        if cost == nil { try run("UPDATE events SET usd=NULL WHERE id=? AND usd=''", [event.id]) }
    }

    static func event(_ row: [String: Any], source: String, cursor: inout Cursor) -> Event? {
        let n = SessionUsageCounts.number
        if source == "claude" {
            guard row["type"] as? String == "assistant", let m = row["message"] as? [String: Any],
                  let u = m["usage"] as? [String: Any], let id = m["id"] as? String, !id.isEmpty,
                  let timestamp = row["timestamp"] as? String else { return nil }
            let model = m["model"] as? String ?? "Unknown model"
            guard model != "<synthetic>" else { return nil }
            let c = SessionUsageCounts(input: n(u["input_tokens"]), output: n(u["output_tokens"]), cacheRead: n(u["cache_read_input_tokens"]), cacheWrite: n(u["cache_creation_input_tokens"]))
            let creation = u["cache_creation"] as? [String: Any] ?? [:]
            return Event(id: digest("claude|"+id), timestamp: timestamp, provider: "Anthropic", model: model, counts: c, oneHour: n(creation["ephemeral_1h_input_tokens"]))
        }
        guard let p = row["payload"] as? [String: Any] else { return nil }
        if row["type"] as? String == "session_meta" {
            cursor.session = p["id"] as? String ?? cursor.session
            let provider = p["model_provider"] as? String ?? "unknown"
            cursor.provider = provider == "openai" ? "OpenAI" : provider == "ollama" ? "Ollama" : provider == "unknown" ? "Unknown provider" : provider
        }
        if row["type"] as? String == "turn_context" { cursor.model = p["model"] as? String ?? "Unknown model" }
        guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
              let cumulative = info["total_token_usage"] as? [String: Any], let timestamp = row["timestamp"] as? String else { return nil }
        let keys = ["input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens"]
        let next = Dictionary(uniqueKeysWithValues: keys.map { ($0, n(cumulative[$0])) })
        if next == cursor.cumulative { return nil } // repeated rate-limit/status event
        let last = info["last_token_usage"] as? [String: Any]
        let reset = keys.contains { next[$0,default:0] < cursor.cumulative[$0,default:0] }
        let first = cursor.cumulative.isEmpty
        var delta = Dictionary(uniqueKeysWithValues: keys.map { ($0, max(0,next[$0,default:0]-cursor.cumulative[$0,default:0])) })
        if first || reset {
            // A resumed/forked log may begin with inherited cumulative totals. Only its last usage is attributable.
            if let last {
                delta = Dictionary(uniqueKeysWithValues: keys.map { ($0,n(last[$0])) })
                if first && delta != next { cursor.gaps += 1 }
            } else { cursor.gaps += 1; cursor.cumulative = next; return nil }
        }
        cursor.cumulative = next
        let cached = min(delta["input_tokens",default:0],delta["cached_input_tokens",default:0])
        let write = min(max(0,delta["input_tokens",default:0]-cached),delta["cache_write_input_tokens",default:0])
        let c = SessionUsageCounts(input: max(0,delta["input_tokens",default:0]-cached-write), output: delta["output_tokens",default:0], cacheRead: cached, cacheWrite: write)
        // Copied fork history retains timestamps and counters; omit the new file/session id from this identity.
        let key = "codex|" + timestamp + "|" + cursor.provider + "|" + cursor.model + "|" + keys.map { String(next[$0,default:0]) }.joined(separator: ":")
        return Event(id: digest(key), timestamp: timestamp, provider: cursor.provider, model: cursor.model, counts: c)
    }

    /// One row of Cursor's usage feed. Only counts, the date, the model and a hash of the event id are kept: the
    /// feed's conversation id, owning user and email never leave this function. Zero-token rows (old request-based
    /// billing) are dropped by `record`.
    static func cursorEvent(_ row: [String: Any], iso: ISO8601DateFormatter) -> Event? {
        let stamp = (row["timestamp"] as? String).flatMap(Int64.init) ?? (row["timestamp"] as? NSNumber)?.int64Value ?? 0
        guard stamp > 0 else { return nil }
        let u = row["tokenUsage"] as? [String: Any] ?? [:]
        let n = SessionUsageCounts.number
        let c = SessionUsageCounts(input: n(u["inputTokens"]), output: n(u["outputTokens"]), cacheRead: n(u["cacheReadTokens"]), cacheWrite: n(u["cacheWriteTokens"]))
        let model = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown model"
        let identity = (row["usageEventId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(stamp)|\(model)|\(c.input)|\(c.output)|\(c.cacheRead)|\(c.cacheWrite)"
        let cents = (u["totalCents"] as? NSNumber)?.doubleValue
        let usd = cents.flatMap { $0.isFinite && $0 >= 0 ? $0 / 100 : nil }
        return Event(id: digest("cursor|" + identity), timestamp: iso.string(from: Date(timeIntervalSince1970: Double(stamp) / 1000)),
                     provider: "Cursor", model: model, counts: c, reportedUSD: usd)
    }

    /// Cursor's command line keeps its sign-in in the login Keychain. The app's own database copy is encrypted.
    /// `patient` is a manual Refresh, where a person may be answering a Keychain prompt.
    static func keychainCursorToken(patient: Bool) -> CursorFeedToken {
        keychainRead(tool: "/usr/bin/security", seconds: patient ? 20 : 5)
    }
    /// `security` exits with the low byte of its OSStatus: 44 is errSecItemNotFound, 51 errSecAuthFailed and 128
    /// errSecUserCanceled. Those last two are a person saying no. Anything else (a locked keychain is 36) got no answer.
    static func keychainRead(tool: String, seconds: TimeInterval) -> CursorFeedToken {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["find-generic-password", "-s", "cursor-access-token", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable(.launchFailed) }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return .unavailable(.timedOut) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        switch process.terminationStatus {
        case 0: break
        case 44: return .missing
        case 51, 128: return .blocked(exit: process.terminationStatus)
        default: return .unavailable(.exit(process.terminationStatus))
        }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .missing }
        return cursorTokenExpired(token, now: Date()) ? .expired : .token(token)
    }
    /// Reads only the expiry claim. A token that is not a JWT is left for the server to judge.
    static func cursorTokenExpired(_ token: String, now: Date) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let expiry = (claims["exp"] as? NSNumber)?.doubleValue else { return false }
        return expiry <= now.timeIntervalSince1970
    }

    private final class ReplyBox: @unchecked Sendable { var reply = CursorFeedReply(status: 0, body: nil) }
    /// The sign-in goes to one host. A redirect is not followed, so it comes back as a failed status.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    /// The same call Cursor's app makes for its usage page. Not a published API: an unexpected answer stops the sync.
    static func liveCursorFetch(token: String, start: Int64, end: Int64, page: Int) -> CursorFeedReply {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let body: [String: Any] = ["teamId": 0, "startDate": String(start), "endDate": String(end), "page": page, "pageSize": cursorPageSize]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            box.reply = CursorFeedReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return box.reply
    }

    private func loadCursorFeedState() throws -> CursorFeedState {
        guard let raw = try query("SELECT value FROM meta WHERE key='cursor_feed'").first?.first, let data = raw.data(using: .utf8),
              let state = try? JSONDecoder().decode(CursorFeedState.self, from: data) else { return CursorFeedState() }
        return state
    }
    private func saveCursorFeedState(_ state: CursorFeedState) throws {
        try run("INSERT OR REPLACE INTO meta VALUES('cursor_feed',?)", [String(decoding: try JSONEncoder().encode(state), as: UTF8.self)])
    }

    /// Bounded and idempotent. A request only happens when the person turned the feed on, and a failure backs off
    /// instead of retrying every pass. `force` is a manual Refresh. A run keeps one date window and its next page
    /// across passes, so a long window finishes instead of rereading its newest page forever.
    func syncCursorFeed(force: Bool, now: Date = Date(), seconds: TimeInterval = 12,
                        readToken: (Bool) -> CursorFeedToken = SessionUsageCollector.keychainCursorToken,
                        fetch: (String, Int64, Int64, Int) -> CursorFeedReply = { SessionUsageCollector.liveCursorFetch(token: $0, start: $1, end: $2, page: $3) }) throws {
        var state = try loadCursorFeedState()
        let clock = now.timeIntervalSince1970
        guard force || clock >= state.nextAllowedAt else { return }
        let started = Date()
        let token: String
        // A run in progress keeps the patient wait, so one unanswered prompt cannot strand a backfill.
        let read = readToken(force || state.runEndMs != 0)
        if case .unavailable = read {} else { state.keychainMisses = nil }
        switch read {
        case .token(let value): token = value
        case .missing: state.state = .signIn; state.nextAllowedAt = clock + 3600; try saveCursorFeedState(state); return
        case .expired: state.state = .expired; state.nextAllowedAt = clock + 3600; try saveCursorFeedState(state); return
        // A person said no, so the question must not come back every hour. A manual Refresh asks again.
        case .blocked(let exit):
            noteFeedLog("Keychain denied, exit \(exit)", now: now)
            stopAskingKeychain(&state, clock: clock)
            try saveCursorFeedState(state)
            return
        // No answer is not a no: a busy or locked keychain retries soon.
        case .unavailable(let miss):
            noteKeychainMiss(miss, &state, clock: clock, now: now)
            try saveCursorFeedState(state)
            return
        }
        if state.runEndMs == 0 {
            state.runEndMs = Int64(clock * 1000)
            state.runStartMs = state.backfillDone ? max(Self.cursorFeedStartMs, state.watermarkMs - 2*86_400_000) : Self.cursorFeedStartMs
            state.nextPage = 1
            state.runSeen = 0
            state.runTotal = 0
        }
        // A slow Keychain read comes out of this pass's budget, so the helper stays inside its own timeout.
        let deadline = Date().addingTimeInterval(min(seconds, max(1, 24 - Date().timeIntervalSince(started))))
        var drained = false
        var pages = 0
        while pages < 8 && Date() < deadline {
            guard state.nextPage <= Self.cursorPageLimit else {
                // The server is not ending the list. Stop rather than page forever.
                state.state = .changed; state.nextAllowedAt = clock + 6*3600; state.runEndMs = 0
                try saveCursorFeedState(state)
                return
            }
            let reply = fetch(token, state.runStartMs, state.runEndMs, state.nextPage)
            pages += 1
            guard reply.status == 200 else {
                if reply.status == 401 || reply.status == 403 {
                    state.state = .expired; state.nextAllowedAt = clock + 6*3600
                } else {
                    noteCursorFailure(&state, as: .failed, clock: clock)
                }
                try saveCursorFeedState(state)
                return
            }
            guard let body = reply.body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                noteCursorFailure(&state, as: .changed, clock: clock)
                try saveCursorFeedState(state)
                return
            }
            if let total = (object["totalUsageEventsCount"] as? NSNumber)?.intValue { state.runTotal = total }
            // The feed omits empty fields: an empty window answers {} and a page past the end has no list.
            let rows = object["usageEventsDisplay"] as? [[String: Any]] ?? []
            if rows.isEmpty {
                // An empty page while the total says more is a server hiccup. Finishing here would mark older rows
                // as read when they never were, and nothing would ever go back for them.
                if state.runSeen < state.runTotal {
                    noteCursorFailure(&state, as: .failed, clock: clock)
                    try saveCursorFeedState(state)
                    return
                }
                drained = true; break
            }
            let events = rows.compactMap { Self.cursorEvent($0, iso: iso) }
            if events.isEmpty {
                // Rows came back and none can be read. That is a changed feed, never zero usage.
                noteCursorFailure(&state, as: .changed, clock: clock)
                try saveCursorFeedState(state)
                return
            }
            state.nextPage += 1
            state.runSeen += rows.count
            try Self.execute(db, "BEGIN IMMEDIATE")
            do {
                for event in events { try record(event) }
                try saveCursorFeedState(state)
                try Self.execute(db, "COMMIT")
            } catch { try? Self.execute(db, "ROLLBACK"); throw error }
            // The count decides when it is known, so a page shorter than asked for cannot end a run early.
            if state.runTotal > 0 {
                if state.runSeen >= state.runTotal { drained = true; break }
            } else if rows.count < Self.cursorPageSize { drained = true; break }
        }
        if drained {
            state.backfillDone = true
            state.watermarkMs = state.runEndMs
            state.runEndMs = 0
            state.state = .ready
            state.nextAllowedAt = clock + 600
        } else {
            // Budget ran out with more to read. The next pass continues this run.
            state.state = .backfilling
            state.nextAllowedAt = clock
        }
        state.failures = 0
        state.lastSuccessAt = clock
        try saveCursorFeedState(state)
    }
    private func stopAskingKeychain(_ state: inout CursorFeedState, clock: Double) {
        state.state = .blocked
        state.nextAllowedAt = clock + 30*86_400
    }
    /// Retries at 15 minutes, doubling to 6 hours. A timeout can be a prompt on screen with nobody there, so four in a
    /// row stop asking the way a denial does. A launch failure or an odd exit shows no prompt and keeps retrying.
    private func noteKeychainMiss(_ miss: KeychainMiss, _ state: inout CursorFeedState, clock: Double, now: Date) {
        let misses = (state.keychainMisses ?? 0) + 1
        state.keychainMisses = misses
        noteFeedLog("Keychain \(miss.word), \(misses) in a row", now: now)
        if miss == .timedOut && misses >= 4 {
            stopAskingKeychain(&state, clock: clock)
            return
        }
        state.state = .keychainBusy
        state.nextAllowedAt = clock + min(6*3600, 900 * pow(2, Double(min(misses, 8) - 1)))
    }
    /// Appends one line. Callers pass fixed words and numbers, never the sign-in or a reply. Starts over past 64 KB.
    private func noteFeedLog(_ line: String, now: Date) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: feedLog.path))?[.size] as? Int, size > 64*1024 {
            try? FileManager.default.removeItem(at: feedLog)
        }
        if !FileManager.default.fileExists(atPath: feedLog.path) {
            FileManager.default.createFile(atPath: feedLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: feedLog) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((iso.string(from: now) + " " + line + "\n").utf8))
    }
    /// Backs off, and after repeated failures closes the run: one bad page must not stop new usage being read.
    /// The next run starts at the newest page again, and rereading never double counts.
    private func noteCursorFailure(_ state: inout CursorFeedState, as outcome: SessionUsageCursorFeedStatus.State, clock: Double) {
        state.failures += 1
        state.state = outcome
        state.nextAllowedAt = clock + min(6*3600, 1800 * pow(2, Double(min(state.failures, 8) - 1)))
        if state.failures >= 4 { state.runEndMs = 0 }
    }
    /// `readOnly` is a paused pass. It never syncs, so nothing here may promise that a refresh or a retry will happen.
    private func cursorFeedStatus(enabled: Bool, syncFailed: Bool, readOnly: Bool) throws -> SessionUsageCursorFeedStatus {
        guard enabled else { return SessionUsageCursorFeedStatus(state: .off) }
        var state = try loadCursorFeedState()
        if syncFailed { state.state = .failed }
        let afterSignIn = readOnly ? "resume tracking" : "refresh"
        let retry = readOnly ? "COS will try again once tracking resumes." : "COS will try again."
        let message: String?
        switch state.state {
        case .off, .ready: message = nil
        case .backfilling: message = readOnly ? "Cursor is waiting until tracking resumes." : "Reading your Cursor usage."
        case .signIn: message = "This Mac has no Cursor command line sign-in. Run cursor-agent login in Terminal, then \(afterSignIn)."
        case .expired: message = "Cursor's sign-in on this Mac has expired. Run cursor-agent login in Terminal, then \(afterSignIn)."
        case .blocked: message = readOnly ? "macOS did not let COS read Cursor's sign-in from Keychain. Resume tracking, then allow it when asked." : "macOS did not let COS read Cursor's sign-in from Keychain. Allow it when asked, then refresh."
        case .keychainBusy: message = "macOS Keychain did not answer, so Cursor's numbers may be behind. " + retry
        case .failed: message = "Cursor did not answer, so its numbers may be behind. " + retry
        case .changed: message = "Cursor changed how it reports usage, so new Cursor usage is not being counted."
        }
        return SessionUsageCursorFeedStatus(state: state.state, message: message, lastSuccessAt: state.lastSuccessAt.map { iso.string(from: Date(timeIntervalSince1970: $0)) })
    }

    // MARK: Compressed logs

    /// Codex compresses older rollouts. Control ships Node, whose zlib can read them, so no zstd binary is needed.
    static func isCompressedLog(_ file: URL) -> Bool { file.lastPathComponent.hasSuffix(".jsonl.zst") }
    /// A decoded byte costs far less than a parsed one, because the filter hands over only usage rows. Measured on real
    /// rollouts with the bundled Node: 4.6 GB decoded in 6.3 seconds, leaving 6.4 MB of rows, about one part in 700.
    static let compressedDecodeFactor = 64
    private static let compressedStallLimit = 3
    /// The first of `nodes` whose zlib can read zstd (Node 22.15 and later), or nil.
    static func compressedDecoder(_ nodes: [String]) -> String? {
        nodes.first { node in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = ["-e", "process.exit(typeof require('zlib').createZstdDecompress==='function'?0:69)"]
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { process.terminate(); return false }
            return process.terminationStatus == 0
        }
    }
    /// Runs inside Node, with no shell. Streams a log and writes only the rows the usage reader looks at, so nothing holds
    /// a whole file and the rows of images never cross the pipe. Control lines start with byte 1: `at`, `more` or `end`,
    /// then the decoded offset of a line boundary with every row before it already written, and the oversized row count.
    /// It walks the frame headers first, because the decoder stops silently at the end of one frame and takes a cut-off
    /// file for a short one. Node's stdout pipe is not blocking, so a reader slower than the rows gives EAGAIN, and 15 of
    /// 1,127 real logs died on it until `out` waited and tried again. Exits 0 at the end, 3 at the limit and 65 on a file it
    /// cannot trust.
    static let compressedFilter = #"""
    const fs=require('fs'),zlib=require('zlib');
    const [,file,skipArg,limitArg]=process.argv;
    const skip=Number(skipArg),limit=Number(limitArg),maxLine=8388608,tick=16777216;
    const marks=['"token_count"','"turn_context"','"session_meta"'].map(m=>Buffer.from(m));
    const hit=b=>marks.some(m=>b.includes(m));
    const fail=()=>process.exit(65);
    const rest=new Int32Array(new SharedArrayBuffer(4));
    const out=b=>{let o=0;while(o<b.length){try{o+=fs.writeSync(1,b,o,b.length-o);}catch(e){if(e.code!=='EAGAIN')throw e;Atomics.wait(rest,0,0,2);}}};
    function walk(){
      const fd=fs.openSync(file,'r'),size=fs.fstatSync(fd).size,h=Buffer.alloc(18),frames=[];
      let at=0;
      while(at<size){
        if(fs.readSync(fd,h,0,18,at)<4)fail();
        const magic=h.readUInt32LE(0);
        if(((magic&0xFFFFFFF0)>>>0)===0x184D2A50){if(at+8>size)fail();at+=8+h.readUInt32LE(4);if(at>size)fail();continue;}
        if(magic!==0xFD2FB528)fail();
        const d=h[4],fcs=d>>6,single=(d>>5)&1;
        let p=at+5+(single?0:1)+[0,1,2,4][d&3]+(fcs===0?(single?1:0):[0,2,4,8][fcs]);
        for(;;){
          if(p+3>size)fail();
          fs.readSync(fd,h,0,3,p);
          const v=h[0]|h[1]<<8|h[2]<<16;
          p+=3+(((v>>1)&3)===1?1:v>>3);
          if(p>size)fail();
          if(v&1)break;
        }
        if((d>>2)&1){p+=4;if(p>size)fail();}
        frames.push([at,p]);
        at=p;
      }
      fs.closeSync(fd);
      return frames;
    }
    let frames;try{frames=walk();}catch{fail();}
    let at=0,mark=skip,next=skip+tick,oversized=0,pieces=[],held=0,over=false,marked=false,index=0;
    const say=c=>out(Buffer.from(`\x01${c} ${mark} ${oversized}\n`));
    function take(chunk){
      let from=0;
      if(at+chunk.length<=skip){at+=chunk.length;return;}
      if(at<skip)from=skip-at;
      const base=at;
      at+=chunk.length;
      for(;;){
        const nl=chunk.indexOf(10,from),end=nl<0?chunk.length:nl;
        if(!over&&held+end-from>maxLine){over=true;marked=pieces.some(hit);pieces=[];held=0;}
        if(over){if(!marked&&hit(chunk.subarray(from,end)))marked=true;}
        else if(end>from){pieces.push(chunk.subarray(from,end));held+=end-from;}
        if(nl<0)return;
        if(over){if(marked)oversized++;over=false;marked=false;}
        else{const line=pieces.length===1?pieces[0]:Buffer.concat(pieces,held);if(held>0&&hit(line)){out(line);out(Buffer.from('\n'));}pieces=[];held=0;}
        from=nl+1;
        mark=base+from;
        if(mark-skip>=limit){say('more');process.exit(3);}
        if(mark>=next){next=mark+tick;say('at');}
      }
    }
    function finish(){
      if(held>0&&!over){const line=Buffer.concat(pieces,held);if(hit(line)){out(line);out(Buffer.from('\n'));}}
      else if(over&&marked)oversized++;
      mark=at;
      say('end');
      process.exit(0);
    }
    function nextFrame(){
      if(index===frames.length)return finish();
      const [start,end]=frames[index++];
      const read=fs.createReadStream(file,{start,end:end-1,highWaterMark:1048576});
      read.on('error',fail);
      const stream=read.pipe(zlib.createZstdDecompress({chunkSize:1048576}));
      stream.on('error',fail);
      stream.on('data',take);
      stream.on('end',nextFrame);
    }
    nextFrame();
    """#
    private struct CompressedPass { var decoded: UInt64; var finished: Bool }
    /// One compressed log, as far as this pass's bytes and time allow. The file never changes, so there is no append
    /// logic, and the rows are read from its start exactly as a plain log's are: a rollout seen first as .jsonl gets the
    /// same event ids here and is not counted twice. Each `at` line commits, so a slow file still moves forward.
    private func readCompressedLog(_ file: URL, source: String, size: Int, modified: Double, node: String, known: Cursor?, decodeLimit: Int, deadline: Date, seconds: TimeInterval) throws -> CompressedPass {
        var cursor = known ?? Cursor()
        var saved = cursor
        let started = cursor.offset, oversizedBefore = cursor.oversizedRows
        func save(_ value: Cursor) throws {
            var stamped = value
            stamped.scannedAt = Date().timeIntervalSince1970
            try run("INSERT OR REPLACE INTO files VALUES(?,?,?,?)", [file.path, String(size), String(modified), String(decoding: try JSONEncoder().encode(stamped), as: UTF8.self)])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", Self.compressedFilter, file.path, String(cursor.offset), String(decodeLimit)]
        // Its own environment: a NODE_OPTIONS meant for something else must not change how this runs.
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        // Not a mark against the file: the decoder is what failed, so the next pass tries again.
        guard (try? process.run()) != nil else { return CompressedPass(decoded: 0, finished: false) }
        let pid = process.processIdentifier
        let timeLeft = deadline.timeIntervalSinceNow
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.05, timeLeft), execute: watchdog)
        defer { watchdog.cancel() }
        var terminal = ""
        var buffer = Data()
        let reader = pipe.fileHandleForReading
        // Closed by hand: left to the pool, one handle per file ran a real pass out of its 256 and failed the rest.
        defer { try? reader.close() }
        try Self.execute(db, "BEGIN IMMEDIATE")
        do {
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                buffer.append(chunk)
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 10) {
                    let line = buffer[start..<newline]
                    start = newline + 1
                    if line.first == 1 {
                        let parts = String(decoding: line.dropFirst(), as: UTF8.self).split(separator: " ")
                        guard parts.count == 3, let offset = UInt64(parts[1]), let oversized = Int(parts[2]) else { continue }
                        terminal = String(parts[0])
                        cursor.offset = offset
                        cursor.oversizedRows = oversizedBefore + oversized
                        try save(cursor)
                        try Self.execute(db, "COMMIT")
                        try Self.execute(db, "BEGIN IMMEDIATE")
                        saved = cursor
                    } else if let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                        if let event = Self.event(row, source: source, cursor: &cursor) { try record(event) }
                    } else { cursor.malformed += 1 }
                }
                buffer = Data(buffer[start...])
            }
            process.waitUntilExit()
            // A log swapped under its saved place, same size and date, can end before that place.
            let decoded = saved.offset > started ? saved.offset - started : 0
            switch (terminal, process.terminationReason) {
            case ("end", _):
                saved.compressedEnd = "done"
                saved.compressedStalls = nil
                try save(saved)
                try Self.execute(db, "COMMIT")
                return CompressedPass(decoded: decoded, finished: true)
            case ("more", _):
                saved.compressedStalls = nil
                try save(saved)
                try Self.execute(db, "COMMIT")
                return CompressedPass(decoded: decoded, finished: false)
            case (_, .exit) where process.terminationStatus == 65:
                // A file it cannot trust. Rows before the failure were real usage, so they stay.
                cursor.compressedEnd = "failed"
                try save(cursor)
                try Self.execute(db, "COMMIT")
                return CompressedPass(decoded: decoded, finished: true)
            default:
                // Out of time, or the decoder crashed, which says nothing about the file. What arrived after the last `at`
                // is read again next pass. A file that cannot move even with most of a pass to itself would hold the page
                // in a hurry forever, so it stops being tried.
                try Self.execute(db, "ROLLBACK")
                let hadTheTime = process.terminationReason == .exit || timeLeft >= seconds / 2
                saved.compressedStalls = decoded == 0 && hadTheTime ? (saved.compressedStalls ?? 0) + 1 : nil
                if (saved.compressedStalls ?? 0) >= Self.compressedStallLimit { saved.compressedEnd = "failed" }
                try save(saved)
                return CompressedPass(decoded: decoded, finished: saved.compressedEnd != nil)
            }
        } catch {
            kill(pid, SIGKILL)
            process.waitUntilExit()
            try? Self.execute(db, "ROLLBACK")
            throw error
        }
    }

    /// Bounded slices keep the helper and desktop responsive. The next pass resumes all partial files.
    func refresh(maxBytes: Int = 64*1024*1024, seconds: TimeInterval = 12, cursorEnabled: Bool = false, cursorSyncFailed: Bool = false, readOnly: Bool = false) throws -> SessionUsageReport {
        let fm = FileManager.default
        let roots = [("claude", home.appendingPathComponent(".claude/projects")), ("codex", home.appendingPathComponent(".codex/sessions")), ("codex", home.appendingPathComponent(".codex/archived_sessions"))]
        var files: [(String, URL, Int, Double)] = []; var unreadable = 0
        for (source, root) in roots where fm.fileExists(atPath: root.path) {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey], options: [], errorHandler: { _,_ in unreadable += 1; return true }) else { unreadable += 1; continue }
            for case let file as URL in walk where file.pathExtension == "jsonl" || (source == "codex" && Self.isCompressedLog(file)) {
                do {
                    let v = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
                    guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                    files.append((source, file, v.fileSize ?? 0, v.contentModificationDate?.timeIntervalSince1970 ?? 0))
                } catch { unreadable += 1 }
            }
        }
        let known = try query("SELECT path,size,modified,state FROM files")
        let state = Dictionary(uniqueKeysWithValues: known.map { ($0[0],$0) })
        var pending = files.filter { f in
            guard let old = state[f.1.path], let data = old[3].data(using: .utf8), let c = try? JSONDecoder().decode(Cursor.self, from:data) else { return true }
            if Self.isCompressedLog(f.1) { return Int(old[1]) != f.2 || Double(old[2]) != f.3 || c.compressedEnd == nil }
            return Int(old[1]) != f.2 || Double(old[2]) != f.3 || (c.offset < UInt64(f.2) && !c.waitingForAppend)
        }
        // Fair rotation: a continuously growing hot session must not starve older history.
        let scanned = Dictionary(uniqueKeysWithValues: known.map { row in
            (row[0], row[3].data(using:.utf8).flatMap { try? JSONDecoder().decode(Cursor.self,from:$0) }?.scannedAt ?? 0)
        })
        pending.sort {
            let a = scanned[$0.1.path,default:0], b = scanned[$1.1.path,default:0]
            return a == b ? $0.3 > $1.3 : a < b
        }
        var remaining = maxBytes; let deadline = Date().addingTimeInterval(seconds); var completed = 0
        // Fail closed per file: with no decoder a compressed log is a counted gap, and not something to keep hurrying for.
        // A read-only pass (no budget) starts no process and leaves them waiting.
        var decoder: String?
        var decoderMissing = false
        if maxBytes > 0, pending.contains(where: { Self.isCompressedLog($0.1) }) {
            decoder = Self.compressedDecoder(compressedLogNodes)
            if decoder == nil {
                decoderMissing = true
                unreadable += pending.filter { Self.isCompressedLog($0.1) }.count
                pending.removeAll { Self.isCompressedLog($0.1) }
            }
        }
        for (source,file,size,modified) in pending {
            if remaining <= 0 || Date() >= deadline { break }
            if Self.isCompressedLog(file), let decoder {
                let known = state[file.path].flatMap { old -> Cursor? in
                    guard Int(old[1]) == size, Double(old[2]) == modified, let data = old[3].data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(Cursor.self, from: data)
                }
                // Its own pool, as a pass can start hundreds of processes before anything else would drain one.
                let pass = try autoreleasepool {
                    try readCompressedLog(file, source: source, size: size, modified: modified, node: decoder, known: known,
                                          decodeLimit: remaining * Self.compressedDecodeFactor, deadline: deadline, seconds: seconds)
                }
                remaining -= max(1, Int(pass.decoded / UInt64(Self.compressedDecodeFactor)))
                if pass.finished { completed += 1 }
                continue
            }
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom:file) } catch { unreadable += 1; completed += 1; continue }
            defer { try? handle.close() }
            var cursor = state[file.path].flatMap { $0[3].data(using:.utf8) }.flatMap { try? JSONDecoder().decode(Cursor.self,from:$0) } ?? Cursor()
            let prefix = try handle.read(upToCount: min(size,256)) ?? Data()
            let signature = Self.digest(prefix.base64EncodedString())
            let rewritten = state[file.path].map { size <= (Int($0[1]) ?? 0) && modified != Double($0[2]) } ?? false
            if cursor.offset > UInt64(size) || rewritten || (!cursor.prefix.isEmpty && cursor.prefix != signature) { cursor = Cursor() }
            cursor.prefix = signature
            cursor.waitingForAppend = false
            try handle.seek(toOffset: cursor.offset)
            // Bound memory even for image-heavy JSONL rows. A budget boundary is not EOF.
            let rowLimit = 8*1024*1024
            var bytes = try handle.read(upToCount:min(rowLimit,remaining)) ?? Data()
            remaining -= bytes.count
            if cursor.skippingLongLine == true {
                if let newline = bytes.firstIndex(of:10) {
                    let skipped = newline + 1
                    cursor.offset += UInt64(skipped)
                    bytes = Data(bytes.dropFirst(skipped))
                    cursor.skippingLongLine = false
                } else {
                    cursor.offset += UInt64(bytes.count)
                    bytes = Data()
                }
            }
            guard let end = bytes.lastIndex(of:10) else {
                let atEOF = cursor.offset + UInt64(bytes.count) >= UInt64(size)
                if bytes.count >= rowLimit {
                    cursor.oversizedRows += 1
                    cursor.skippingLongLine = true
                    cursor.offset += UInt64(bytes.count)
                }
                // Leave a short budget-cut row at its start for the next full slice. Only a
                // genuine incomplete EOF waits for an append. Oversized rows are skipped
                // through their newline across passes so later usage remains reachable.
                cursor.waitingForAppend = atEOF
                cursor.scannedAt = Date().timeIntervalSince1970
                let encoded = String(decoding:try JSONEncoder().encode(cursor),as:UTF8.self)
                try run("INSERT OR REPLACE INTO files VALUES(?,?,?,?)",[file.path,String(size),String(modified),encoded])
                if atEOF { completed += 1 }
                continue
            }
            let full = bytes.prefix(through:end)
            try Self.execute(db,"BEGIN IMMEDIATE")
            do {
                for line in full.split(separator:10) {
                    guard let row = (try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] else { cursor.malformed += 1; continue }
                    if let e = Self.event(row,source:source,cursor:&cursor) { try record(e) }
                }
                cursor.offset += UInt64(full.count)
                cursor.scannedAt = Date().timeIntervalSince1970
                let encoded = String(decoding:try JSONEncoder().encode(cursor),as:UTF8.self)
                try run("INSERT OR REPLACE INTO files VALUES(?,?,?,?)",[file.path,String(size),String(modified),encoded])
                try Self.execute(db,"COMMIT")
                if cursor.offset >= UInt64(size) { completed += 1 }
            } catch { try? Self.execute(db,"ROLLBACK"); throw error }
        }
        let rows = try query("SELECT day,provider,model,SUM(input),SUM(output),SUM(cache_read),SUM(cache_write),COUNT(*),COUNT(usd),COALESCE(SUM(usd),0) FROM events GROUP BY day,provider,model ORDER BY day,provider,model")
        let buckets = rows.map { r in SessionUsageBucket(day:r[0],provider:r[1],model:r[2],counts:SessionUsageCounts(input:Int64(r[3]) ?? 0,output:Int64(r[4]) ?? 0,cacheRead:Int64(r[5]) ?? 0,cacheWrite:Int64(r[6]) ?? 0),events:Int(r[7]) ?? 0,pricedEvents:Int(r[8]) ?? 0,estimatedUSD:Double(r[9]) ?? 0) }
        let cursors = try query("SELECT state FROM files").compactMap { $0[0].data(using:.utf8) }.compactMap { try? JSONDecoder().decode(Cursor.self,from:$0) }
        // Only a file still on disk: a failed log that has since been deleted is no longer a gap to report.
        let present = Set(files.map { $0.1.path })
        unreadable += try query("SELECT path,state FROM files").filter { present.contains($0[0]) && Self.isCompressedLog(URL(fileURLWithPath: $0[0])) && $0[1].data(using: .utf8).flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) }?.compressedEnd == "failed" }.count
        return SessionUsageReport(buckets:buckets,updatedAt:iso.string(from:Date()),timeZone:zone.identifier,filesIndexed:cursors.count,pendingFiles:max(0,pending.count-completed),unreadableFiles:unreadable+cursors.reduce(0){$0+$1.oversizedRows},malformedRows:cursors.reduce(0){$0+$1.malformed},missingBaselineEvents:cursors.reduce(0){$0+$1.gaps},coverage:["Claude Code and Codex local session logs, including archived and compressed sessions and subagents."] + (decoderMissing ? ["Compressed Codex logs could not be read, because this Mac has no Node that can open them. They are counted as unreadable."] : []) + [cursorEnabled ? "Cursor usage comes from your Cursor account, using the sign-in its command line keeps in this Mac's Keychain. Only counts, dates, model names and each request's reported cost are stored." : "Cursor is counted only after you turn it on. Its token counts are kept on Cursor's servers.","Browser-only chats, other Macs and providers without token records are not included.","History starts at the earliest usage still present on this Mac. Deleted logs cannot be backfilled. Incomplete final lines wait for the next write; rows larger than 8 MiB are skipped and reported as coverage gaps.","Input, cache read, cache write and output are disjoint. Reasoning is included in output."],pricingVersion:SessionUsagePricing.version,cursorFeed:try cursorFeedStatus(enabled:cursorEnabled,syncFailed:cursorSyncFailed,readOnly:readOnly))
    }
}
