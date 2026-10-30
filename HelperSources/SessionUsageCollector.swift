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
