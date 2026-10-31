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
    /// Cursor's sign-in, read only for the moment of a request. Never stored, logged or put in an argument.
    enum CursorFeedToken { case token(String), missing, expired, blocked }
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
    private let dayFormatter = DateFormatter()
    private let iso = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(home: URL, database: URL? = nil, timeZone: TimeZone = .current) throws {
        self.home = home
        let file = database ?? home.appendingPathComponent("Library/Application Support/COS Control/usage/session-usage-v1.sqlite")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "cursor-access-token", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .blocked }
        let deadline = Date().addingTimeInterval(patient ? 20 : 5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return .blocked }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 44 { return .missing } // errSecItemNotFound
        guard process.terminationStatus == 0 else { return .blocked }
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
        switch readToken(force || state.runEndMs != 0) {
        case .token(let value): token = value
        case .missing: state.state = .signIn; state.nextAllowedAt = clock + 3600; try saveCursorFeedState(state); return
        case .expired: state.state = .expired; state.nextAllowedAt = clock + 3600; try saveCursorFeedState(state); return
        // A prompt nobody answered must not come back every hour. A manual Refresh asks again.
        case .blocked: state.state = .blocked; state.nextAllowedAt = clock + 30*86_400; try saveCursorFeedState(state); return
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
    /// Backs off, and after repeated failures closes the run: one bad page must not stop new usage being read.
    /// The next run starts at the newest page again, and rereading never double counts.
    private func noteCursorFailure(_ state: inout CursorFeedState, as outcome: SessionUsageCursorFeedStatus.State, clock: Double) {
        state.failures += 1
        state.state = outcome
        state.nextAllowedAt = clock + min(6*3600, 1800 * pow(2, Double(min(state.failures, 8) - 1)))
        if state.failures >= 4 { state.runEndMs = 0 }
    }
    private func cursorFeedStatus(enabled: Bool, syncFailed: Bool) throws -> SessionUsageCursorFeedStatus {
        guard enabled else { return SessionUsageCursorFeedStatus(state: .off) }
        var state = try loadCursorFeedState()
        if syncFailed { state.state = .failed }
        let message: String?
        switch state.state {
        case .off, .ready: message = nil
        case .backfilling: message = "Reading your Cursor usage."
        case .signIn: message = "This Mac has no Cursor command line sign-in. Run cursor-agent login in Terminal, then refresh."
        case .expired: message = "Cursor's sign-in on this Mac has expired. Run cursor-agent login in Terminal, then refresh."
        case .blocked: message = "macOS did not let COS read Cursor's sign-in from Keychain. Allow it when asked, then refresh."
        case .failed: message = "Cursor did not answer, so its numbers may be behind. COS will try again."
        case .changed: message = "Cursor changed how it reports usage, so new Cursor usage is not being counted."
        }
        return SessionUsageCursorFeedStatus(state: state.state, message: message, lastSuccessAt: state.lastSuccessAt.map { iso.string(from: Date(timeIntervalSince1970: $0)) })
    }

    /// Bounded slices keep the helper and desktop responsive. The next pass resumes all partial files.
    func refresh(maxBytes: Int = 64*1024*1024, seconds: TimeInterval = 12, cursorEnabled: Bool = false, cursorSyncFailed: Bool = false) throws -> SessionUsageReport {
        let fm = FileManager.default
        let roots = [("claude", home.appendingPathComponent(".claude/projects")), ("codex", home.appendingPathComponent(".codex/sessions")), ("codex", home.appendingPathComponent(".codex/archived_sessions"))]
        var files: [(String, URL, Int, Double)] = []; var unreadable = 0
        for (source, root) in roots where fm.fileExists(atPath: root.path) {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey], options: [], errorHandler: { _,_ in unreadable += 1; return true }) else { unreadable += 1; continue }
            for case let file as URL in walk where file.pathExtension == "jsonl" {
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
        for (source,file,size,modified) in pending {
            if remaining <= 0 || Date() >= deadline { break }
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
        return SessionUsageReport(buckets:buckets,updatedAt:iso.string(from:Date()),timeZone:zone.identifier,filesIndexed:cursors.count,pendingFiles:max(0,pending.count-completed),unreadableFiles:unreadable+cursors.reduce(0){$0+$1.oversizedRows},malformedRows:cursors.reduce(0){$0+$1.malformed},missingBaselineEvents:cursors.reduce(0){$0+$1.gaps},coverage:["Claude Code and Codex local session logs, including archived sessions and subagents.",cursorEnabled ? "Cursor usage comes from your Cursor account, using the sign-in its command line keeps in this Mac's Keychain. Only counts, dates, model names and each request's reported cost are stored." : "Cursor is counted only after you turn it on. Its token counts are kept on Cursor's servers.","Browser-only chats, other Macs and providers without token records are not included.","History starts at the earliest usage still present on this Mac. Deleted logs cannot be backfilled. Incomplete final lines wait for the next write; rows larger than 8 MiB are skipped and reported as coverage gaps.","Input, cache read, cache write and output are disjoint. Reasoning is included in output."],pricingVersion:SessionUsagePricing.version,cursorFeed:try cursorFeedStatus(enabled:cursorEnabled,syncFailed:cursorSyncFailed))
    }
}

// MARK: - COS cost: the bounded reader behind `cos-usage` (0.5.359)
//
// Reads ledgers and session logs, writes only its own two tables, and returns counts. The rules are in SessionUsageCore.
// The audit is an unlocked append file that grows without rotation, so it is streamed a line at a time and nothing of it
// is held across passes. The session slice table exists because `events` has no session id and reimporting it would cost
// 25 GB of reading: it stores the same counts again, for Work and G2 sessions only, keyed by a digest of the session id.
extension SessionUsageCollector {
    /// Long enough for the ledgers plus a real slice of logs, inside the 45 seconds Control waits.
    static let cosPassSeconds: TimeInterval = 20
    static let cosPassBytes = 4*1024*1024*1024
    /// So one huge log cannot take a whole pass from the others. Time bounds the pass whatever this says.
    static let cosFileBytesPerPass = 1536*1024*1024
    private static let cosChunk = 8*1024*1024
    /// A little past the window, so a window edge never moves onto rows already thrown away.
    private static let cosRetentionSeconds = 32.0*86_400

    struct CosSliceTarget: Hashable {
        var provider: String // "claude" or "codex"
        var id: String
    }

    private func cosPrepareTables() throws {
        // Skips the write when they exist, so another command holding the lock costs nothing on an ordinary pass.
        if try query("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('cos_slice_events','cos_slice_marks')").first?.first == "2" { return }
        try Self.execute(db, "CREATE TABLE IF NOT EXISTS cos_slice_marks(session TEXT NOT NULL, at REAL NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(session, at, kind)); CREATE INDEX IF NOT EXISTS cos_slice_mark_at ON cos_slice_marks(at); CREATE TABLE IF NOT EXISTS cos_slice_files(path TEXT PRIMARY KEY, session TEXT NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL, state TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cos_slice_events(id TEXT PRIMARY KEY, event TEXT NOT NULL, session TEXT NOT NULL, at REAL NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, one_hour INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS cos_slice_at ON cos_slice_events(at);")
    }

    /// Lines of an append-only file, without holding it. Returns the count of lines that were not valid JSON objects. A
    /// final line with no newline may still be being written, so it is left for the next read rather than counted.
    private static func cosForEachJSONLine(_ file: URL, _ body: ([String: Any]) -> Void) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var unreadable = 0
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            guard let last = carry.lastIndex(of: 10) else { continue }
            autoreleasepool {
                for line in carry[carry.startIndex...last].split(separator: 10) {
                    if let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { body(row) } else { unreadable += 1 }
                }
            }
            carry = Data(carry[carry.index(after: last)...])
        }
        return unreadable
    }

    /// Where the Work and G2 logs are. One listing of each root per pass, so it costs the same for 5 sessions or 500.
    private func cosLocate(_ targets: Set<CosSliceTarget>) -> [CosSliceTarget: [URL]] {
        let fm = FileManager.default
        var found: [CosSliceTarget: [URL]] = [:]
        let claude = Dictionary(uniqueKeysWithValues: targets.filter { $0.provider == "claude" }.map { ($0.id, $0) })
        if !claude.isEmpty {
            let root = home.appendingPathComponent(".claude/projects")
            for project in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                let folder = root.appendingPathComponent(project)
                for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jsonl") {
                    guard let target = claude[String(name.dropLast(6))] else { continue }
                    found[target, default: []].append(folder.appendingPathComponent(name))
                    // A subagent's log carries its parent's session id, and its usage is the session's.
                    let agents = folder.appendingPathComponent(String(name.dropLast(6))).appendingPathComponent("subagents")
                    for agent in (try? fm.contentsOfDirectory(atPath: agents.path)) ?? [] where agent.hasSuffix(".jsonl") {
                        found[target, default: []].append(agents.appendingPathComponent(agent))
                    }
                }
            }
        }
        let codex = targets.filter { $0.provider == "codex" }
        if !codex.isEmpty {
            let ids = Dictionary(uniqueKeysWithValues: codex.map { ($0.id, $0) })
            for root in [".codex/sessions", ".codex/archived_sessions"] {
                guard let walk = fm.enumerator(at: home.appendingPathComponent(root), includingPropertiesForKeys: nil) else { continue }
                for case let file as URL in walk {
                    let name = file.lastPathComponent
                    guard name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"), name.count > 36 else { continue }
                    let stem = name.hasSuffix(".zst") ? String(name.dropLast(10)) : String(name.dropLast(6))
                    if let target = ids[String(stem.suffix(36))] { found[target, default: []].append(file) }
                }
            }
        }
        return found
    }

    /// For the tests: how many session rows the table holds, so a row past the window can be seen not to be stored.
    func cosStoredEventCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM cos_slice_events").first?.first ?? "") ?? 0
    }

    /// THE COMPRESSED LOG HOOK. Codex keeps most rollouts as `.jsonl.zst`, and `claude/usage-qa-fixes` brings the reader
    /// (`readCompressedLog` and `compressedFilter`, through the bundled Node). When that merges, this is the one place to
    /// plug it in: hand each usage row's bytes to `onLine` from decoded offset `skip`, stop at `limit` bytes or `deadline`,
    /// and return how far the decoder got. Nil means it cannot read them yet, and the page says so. Its filter must also pass
    /// `"task_started"`, `"task_complete"` and `"turn_aborted"` rows, or Codex Work runs have no provable end.
    private func cosReadCompressedRows(_ file: URL, skip: UInt64, limit: Int, deadline: Date, onLine: (Data) throws -> Void) throws -> (decodedTo: UInt64, finished: Bool)? {
        nil
    }

    /// The hook's caller. A compressed file never changes, so once it is finished it stays finished.
    private func cosReadCompressedSlice(_ target: CosSliceTarget, file: URL, known: [String]?, retainFrom: Double, deadline: Date, progress: inout CosSliceProgress, open: inout Set<CosSliceTarget>) throws {
        var cursor = known.flatMap { $0[3].data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) } ?? Cursor()
        if cursor.waitingForAppend { return }
        let sessionKey = Self.digest(target.provider + ":" + target.id)
        let pass = try cosReadCompressedRows(file, skip: cursor.offset, limit: Self.cosFileBytesPerPass, deadline: deadline) { line in
            try cosHandle(line: line, target: target, cursor: &cursor, sessionKey: sessionKey, retainFrom: retainFrom)
        }
        guard let pass else { progress.compressed += 1; return }
        cursor.offset = pass.decodedTo
        cursor.waitingForAppend = pass.finished
        cursor.scannedAt = Date().timeIntervalSince1970
        try run("INSERT OR REPLACE INTO cos_slice_files VALUES(?,?,0,0,?)", [file.path, sessionKey, String(decoding: try JSONEncoder().encode(cursor), as: UTF8.self)])
        if !pass.finished { open.insert(target) }
    }

    private func cosRecord(_ event: Event, sessionKey: String, oneHour: Int64, retainFrom: Double) throws {
        guard event.counts.total > 0, let at = CosCostRules.epoch(event.timestamp), at >= retainFrom else { return }
        let c = event.counts
        try run("""
            INSERT INTO cos_slice_events VALUES(?,?,?,CAST(? AS REAL),?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            input=excluded.input, output=excluded.output, cache_read=excluded.cache_read, cache_write=excluded.cache_write, one_hour=excluded.one_hour
            WHERE excluded.input+excluded.output+excluded.cache_read+excluded.cache_write > cos_slice_events.input+cos_slice_events.output+cos_slice_events.cache_read+cos_slice_events.cache_write
            """, [Self.digest(sessionKey + "|" + event.id), event.id, sessionKey, String(at), event.provider, event.model, String(c.input), String(c.output), String(c.cacheRead), String(c.cacheWrite), String(oneHour)])
    }

    /// One usage row out of a session log. Only rows whose own session id matches count: a fork or a resume copies its
    /// parent's rows forward under the parent's id. The filter looks at bytes first, so a row of pasted images or a long
    /// tool result is never parsed, and nothing but counts leaves here.
    private func cosHandle(line: some DataProtocol, target: CosSliceTarget, cursor: inout Cursor, sessionKey: String, retainFrom: Double, isSubagent: Bool = false) throws {
        let bytes = Data(line)
        func has(_ needle: StaticString) -> Bool {
            needle.withUTF8Buffer { n in bytes.withUnsafeBytes { b in memmem(b.baseAddress, b.count, n.baseAddress, n.count) != nil } }
        }
        func mark(_ kind: CosMarkKind?, _ stamp: Any?) throws {
            guard let kind, !isSubagent, let stamp = stamp as? String, let at = CosCostRules.epoch(stamp), at >= retainFrom else { return }
            try run("INSERT OR IGNORE INTO cos_slice_marks VALUES(?,CAST(? AS REAL),?)", [sessionKey, String(at), kind.rawValue])
        }
        if target.provider == "claude" {
            // An unescaped "type":"tool_result" can only be a real block, so these rows, the bulk of a log, skip the parser.
            if has("\"user\""), !has("\"type\":\"tool_result\""), let row = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
               row["type"] as? String == "user", row["sessionId"] as? String == target.id {
                try mark(CosCostRules.claudeMark(row), row["timestamp"])
                return
            }
            guard has("\"assistant\""), has("\"usage\"") else { return }
            guard let row = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { cursor.malformed += 1; return }
            guard row["sessionId"] as? String == target.id else { return }
            try mark(CosCostRules.claudeMark(row), row["timestamp"])
            guard let event = Self.event(row, source: "claude", cursor: &cursor) else { return }
            try cosRecord(event, sessionKey: sessionKey, oneHour: event.oneHour, retainFrom: retainFrom)
        } else {
            guard has("\"token_count\"") || has("\"turn_context\"") || has("\"session_meta\"") || has("\"task_started\"") || has("\"task_complete\"") || has("\"turn_aborted\"") else { return }
            guard let row = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { cursor.malformed += 1; return }
            if cursor.session.isEmpty || cursor.session == target.id { try mark(CosCostRules.codexMark(row), row["timestamp"]) }
            guard let event = Self.event(row, source: "codex", cursor: &cursor), cursor.session.isEmpty || cursor.session == target.id else { return }
            try cosRecord(event, sessionKey: sessionKey, oneHour: 0, retainFrom: retainFrom)
        }
    }

    /// The bounded pass. Files that have waited longest go first and each gets a share, so a 5 GB log and a growing hot
    /// session both move forward and neither stalls the rest. Every chunk commits, so a killed helper loses nothing.
    func cosReadSessionSlices(_ targets: Set<CosSliceTarget>, seconds: TimeInterval = SessionUsageCollector.cosPassSeconds, maxBytes: Int = SessionUsageCollector.cosPassBytes, fileBytes: Int = SessionUsageCollector.cosFileBytesPerPass, now: Date = Date()) throws -> CosSliceProgress {
        try cosPrepareTables()
        var progress = CosSliceProgress()
        progress.tracked = targets.count
        let located = cosLocate(targets)
        let known = Dictionary(uniqueKeysWithValues: try query("SELECT path,size,modified,state FROM cos_slice_files").map { ($0[0], $0) })
        struct Pending { var target: CosSliceTarget; var file: URL; var size: Int; var modified: Double; var cursor: Cursor }
        var pending: [Pending] = []
        var open = Set<CosSliceTarget>()
        let retainFrom = now.timeIntervalSince1970 - Self.cosRetentionSeconds
        let deadline = Date().addingTimeInterval(seconds)
        // Compressed rollouts share the pass, and plain logs always keep at least half of it.
        let compressedDeadline = Date().addingTimeInterval(seconds / 2)
        for target in targets {
            let files = located[target] ?? []
            if files.isEmpty { progress.noLogs += 1; continue }
            var compressedOnly = true
            for file in files {
                if file.lastPathComponent.hasSuffix(".zst") { continue }
                compressedOnly = false
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                let size = values.fileSize ?? 0, modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                var cursor = Cursor()
                if let row = known[file.path], let data = row[3].data(using: .utf8), let saved = try? JSONDecoder().decode(Cursor.self, from: data) { cursor = saved }
                if cursor.offset > UInt64(size) { cursor = Cursor() } // rewritten shorter: event ids keep a reread from counting twice
                if cursor.offset < UInt64(size) && !(cursor.waitingForAppend && known[file.path].map { Int($0[1]) == size } == true) {
                    pending.append(Pending(target: target, file: file, size: size, modified: modified, cursor: cursor))
                }
            }
            if compressedOnly, let file = files.first {
                try cosReadCompressedSlice(target, file: file, known: known[file.path], retainFrom: retainFrom, deadline: compressedDeadline, progress: &progress, open: &open)
            }
        }
        pending.sort { $0.cursor.scannedAt == $1.cursor.scannedAt ? $0.size < $1.size : $0.cursor.scannedAt < $1.cursor.scannedAt }
        var remaining = maxBytes
        for item in pending {
            let sessionKey = Self.digest(item.target.provider + ":" + item.target.id)
            var cursor = item.cursor
            var budget = min(remaining, fileBytes)
            if budget > 0 && Date() < deadline, let handle = try? FileHandle(forReadingFrom: item.file) {
                defer { try? handle.close() }
                try handle.seek(toOffset: cursor.offset)
                cursor.waitingForAppend = false
                while budget > 0 && Date() < deadline && cursor.offset < UInt64(item.size) {
                    let wanted = min(Self.cosChunk, budget)
                    var bytes = try handle.read(upToCount: wanted) ?? Data()
                    if bytes.isEmpty { break }
                    budget -= bytes.count
                    remaining -= bytes.count
                    if cursor.skippingLongLine == true {
                        if let newline = bytes.firstIndex(of: 10) {
                            cursor.offset += UInt64(newline - bytes.startIndex + 1)
                            bytes = Data(bytes[bytes.index(after: newline)...])
                            cursor.skippingLongLine = false
                        } else {
                            cursor.offset += UInt64(bytes.count)
                            continue
                        }
                    }
                    guard let end = bytes.lastIndex(of: 10) else {
                        if bytes.count >= Self.cosChunk {
                            cursor.oversizedRows += 1
                            cursor.skippingLongLine = true
                            cursor.offset += UInt64(bytes.count)
                            continue
                        }
                        // A short read with no newline is a final line still being written, or a budget cut. Either way
                        // the next pass starts from its first byte.
                        if cursor.offset + UInt64(bytes.count) >= UInt64(item.size) { cursor.waitingForAppend = true }
                        try handle.seek(toOffset: cursor.offset)
                        break
                    }
                    let whole = bytes[bytes.startIndex...end]
                    try Self.execute(db, "BEGIN IMMEDIATE")
                    do {
                        try autoreleasepool {
                            for line in whole.split(separator: 10) {
                                try cosHandle(line: line, target: item.target, cursor: &cursor, sessionKey: sessionKey, retainFrom: retainFrom, isSubagent: item.file.deletingLastPathComponent().lastPathComponent == "subagents")
                            }
                        }
                        cursor.offset += UInt64(whole.count)
                        cursor.scannedAt = Date().timeIntervalSince1970
                        try run("INSERT OR REPLACE INTO cos_slice_files VALUES(?,?,CAST(? AS INTEGER),CAST(? AS REAL),?)", [item.file.path, sessionKey, String(item.size), String(item.modified), String(decoding: try JSONEncoder().encode(cursor), as: UTF8.self)])
                        try Self.execute(db, "COMMIT")
                    } catch { try? Self.execute(db, "ROLLBACK"); throw error }
                    // A partial tail goes back on the file, so the bytes are read again as a whole line next time.
                    if end != bytes.index(before: bytes.endIndex) { try handle.seek(toOffset: cursor.offset) }
                }
                cursor.scannedAt = Date().timeIntervalSince1970
                try run("INSERT OR REPLACE INTO cos_slice_files VALUES(?,?,CAST(? AS INTEGER),CAST(? AS REAL),?)", [item.file.path, sessionKey, String(item.size), String(item.modified), String(decoding: try JSONEncoder().encode(cursor), as: UTF8.self)])
            }
            if cursor.offset < UInt64(item.size) && !cursor.waitingForAppend { open.insert(item.target) }
        }
        progress.stillReading = open.count
        try run("DELETE FROM cos_slice_events WHERE at < CAST(? AS REAL)", [String(retainFrom)])
        try run("DELETE FROM cos_slice_marks WHERE at < CAST(? AS REAL)", [String(retainFrom)])
        return progress
    }

    /// The one door into the server's data folder, which also holds API keys. It opens only the fixed list in
    /// CosCostRules, one name at a time, and the folder is never listed. Tests/run-session-usage.sh fails if any other
    /// line builds a path under it.
    private func cosDataFile(_ data: URL, _ name: String, opened: (String) -> Void) -> URL? {
        guard CosCostRules.dataFileAllowed(name) else { return nil }
        opened(name)
        return data.appendingPathComponent(name)
    }

    /// The whole report. `importSessions` is off when Usage is paused: the person turned off reading their logs.
    /// `opened` hears the name of each ledger as it is opened, so a test can pin the list. Session logs are found by id.
    func cosUsage(plistScripts: String?, dataDirectory: String?, importSessions: Bool, seconds: TimeInterval = SessionUsageCollector.cosPassSeconds, now: Date = Date(), opened: (String) -> Void = { _ in }) throws -> CosUsageReport {
        let fm = FileManager.default
        let window = CosCostRules.window(now: now, timeZone: zone)
        var report = CosUsageReport(windowStart: window.lowerBound, windowEnd: window.upperBound, timeZone: zone.identifier, updatedAt: iso.string(from: now))
        let data = dataDirectory.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".cos-glasses/data")
        let inWindow: (Double) -> Bool = { [zone] at in window.contains(CosCostRules.dayKey(epoch: at, timeZone: zone)) }

        // G2 runs: a run that started in the window, or ran into it.
        var merged: [String: CosRun] = [:]
        for (name, provider) in [("claude-runs.jsonl", "claude"), ("codex-runs.jsonl", "codex")] {
            guard let file = cosDataFile(data, name, opened: opened), fm.fileExists(atPath: file.path) else { continue }
            report.runLedgersFound = true
            report.unreadableRows += Self.cosForEachJSONLine(file) { line in
                guard let id = line["runId"] as? String, let patch = line["patch"] as? [String: Any] else { return }
                merged[id, default: CosRun(runID: id, provider: provider)].apply(patch: patch)
            } ?? 0
        }
        let runs = merged.values.filter { $0.start > 0 && (inWindow($0.start) || inWindow($0.end)) }.sorted { $0.start < $1.start }

        // Work: the receipts Control itself keeps, on any install. Only these fields are decoded.
        struct Receipt: Decodable { var createdAt: Double?; var sessionID: String?; var status: String?; var provider: String?; var forkChildID: String?; var channel: String? }
        struct Handoffs: Decodable { var receipts: [Receipt]? }
        let handoffsFile = home.appendingPathComponent("Library/Application Support/COS Control/work-handoffs/handoffs.json")
        opened("handoffs.json")
        let handoffs = (try? Data(contentsOf: handoffsFile)).flatMap { try? JSONDecoder().decode(Handoffs.self, from: $0) }
        var workRuns = 0
        var workStarts: [CosSliceTarget: Double] = [:]
        var workHandoffs: [CosWorkRun] = []
        var workWithoutSession = 0
        for receipt in handoffs?.receipts ?? [] {
            guard let at = receipt.createdAt, inWindow(at), !["failed", "canceled"].contains(receipt.status ?? "") else { continue }
            workRuns += 1
            var named = false
            // A fork runs in its child when the receipt knows it. The source session keeps going without it.
            if let value = receipt.forkChildID ?? receipt.sessionID {
                let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                let target = parts.count == 2 ? CosSliceTarget(provider: parts[0], id: parts[1]) : CosSliceTarget(provider: receipt.provider ?? "", id: value)
                if target.provider == "claude" || target.provider == "codex" {
                    workStarts[target] = min(workStarts[target] ?? at, at)
                    workHandoffs.append(CosWorkRun(session: target.provider + ":" + target.id, start: at, openedInApp: receipt.channel == "app"))
                    named = true
                }
            }
            if !named { workWithoutSession += 1 }
        }

        // The bounded read. A busy history means no new rows this pass, not a failed page.
        var targets = Set(workStarts.keys)
        for run in runs where !run.session.isEmpty { targets.insert(CosSliceTarget(provider: run.provider, id: run.session)) }
        report.sessions.tracked = targets.count
        if importSessions {
            do { report.sessions = try cosReadSessionSlices(targets, seconds: seconds, now: now) }
            catch { report.sessions.busy = true }
        }

        // Stored slices for the tracked sessions, under the same digests the reader wrote.
        let lowerEpoch = (CosCostRules.epoch(window.lowerBound + "T00:00:00Z") ?? 0) - 86_400
        let keyed = Dictionary(targets.map { (Self.digest($0.provider + ":" + $0.id), $0) }, uniquingKeysWith: { a, _ in a })
        var events: [CosSliceEvent] = []
        // No table yet, or no lock to make one, means no stored slices this pass. The rest of the page still stands.
        for row in (try? query("SELECT session,at,provider,model,input,output,cache_read,cache_write,one_hour,event FROM cos_slice_events WHERE at >= CAST(? AS REAL)", [String(lowerEpoch)])) ?? [] {
            guard let target = keyed[row[0]] else { continue }
            events.append(CosSliceEvent(id: row[9], session: target.provider + ":" + target.id, at: Double(row[1]) ?? 0, provider: row[2], model: row[3],
                counts: SessionUsageCounts(input: Int64(row[4]) ?? 0, output: Int64(row[5]) ?? 0, cacheRead: Int64(row[6]) ?? 0, cacheWrite: Int64(row[7]) ?? 0), oneHour: Int64(row[8]) ?? 0))
        }

        // What moved each session on: row types and times, with no words in them.
        var marks: [CosSliceMark] = []
        for row in (try? query("SELECT session,at,kind FROM cos_slice_marks WHERE at >= CAST(? AS REAL)", [String(lowerEpoch)])) ?? [] {
            guard let target = keyed[row[0]], let kind = CosMarkKind(rawValue: row[2]) else { continue }
            marks.append(CosSliceMark(session: target.provider + ":" + target.id, at: Double(row[1]) ?? 0, kind: kind))
        }

        // The gist ledger's real usage. Halves itself at 2 MB, and its size stays small.
        var gist: [CosGistRun] = []
        if let gistFile = cosDataFile(data, "lens-gist-runs.jsonl", opened: opened), fm.fileExists(atPath: gistFile.path) {
            report.gistLedgerFound = true
            report.unreadableRows += Self.cosForEachJSONLine(gistFile) { line in
                if let run = CosGistRun(json: line) { gist.append(run) }
            } ?? 0
        }

        var runsKeyed = runs
        for index in runsKeyed.indices where !runsKeyed[index].session.isEmpty {
            runsKeyed[index].session = runsKeyed[index].provider + ":" + runsKeyed[index].session
        }
        var accumulator = CosCostAccumulator(window: window, timeZone: zone, gistRuns: gist, runs: runsKeyed,
            workStarts: Dictionary(uniqueKeysWithValues: workStarts.map { ($0.key.provider + ":" + $0.key.id, $0.value) }), events: events,
            workRuns: workHandoffs, marks: marks)

        // The audit, streamed. The server's own path first, so a test file at the fallback never mixes in.
        var envScripts: String?
        if plistScripts == nil {
            // Only when the server's own settings do not say. One key comes out of this text and the rest is dropped here.
            opened(".env")
            envScripts = (try? String(contentsOf: home.appendingPathComponent(".cos-glasses/.env"), encoding: .utf8)).flatMap { CosCostRules.envValue($0, key: "COS_SCRIPTS_DIR") }
        }
        for path in CosCostRules.auditPaths(plistScripts: plistScripts, envScripts: envScripts, home: home.path) where fm.fileExists(atPath: path) {
            report.auditFound = true
            opened((path as NSString).lastPathComponent)
            report.unreadableRows += Self.cosForEachJSONLine(URL(fileURLWithPath: path)) { line in accumulator.add(CosAuditRow(json: line)) } ?? 0
            break
        }

        // Day ledgers, read one named file at a time. The same folder holds keys, so this is never a glob.
        for ledger in CosCostRules.dailyLedgers {
            guard let file = cosDataFile(data, ledger.file, opened: opened), let raw = try? Data(contentsOf: file),
                  let days = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            for (day, value) in days {
                accumulator.addDailyTokens(SessionUsageCounts.number(value), category: ledger.category, priced: ledger.priced, day: day)
            }
        }

        let finished = accumulator.finish(handoffsFound: handoffs != nil, workRuns: workRuns, workRunsWithoutLogs: workWithoutSession)
        report.rows = finished.rows
        report.work = finished.work
        report.undatedCalls = accumulator.undated
        return report
    }
}
