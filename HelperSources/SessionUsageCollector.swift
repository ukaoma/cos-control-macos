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
        var provider = "OpenAI"
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
    }
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
                sqlite3_column_text(s,i).map { String(cString: $0) } ?? ""
            })
        }
        return rows
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func record(_ event: Event) throws {
        guard event.counts.total > 0, let date = fractional.date(from: event.timestamp) ?? iso.date(from: event.timestamp) else { return }
        let c = event.counts
        let cost = SessionUsagePricing.estimate(provider: event.provider, model: event.model, counts: c, oneHour: event.oneHour)
        // A streamed Claude message repeats its usage per content block. Keep the most complete observation.
        try run("""
            INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            input=excluded.input, output=excluded.output, cache_read=excluded.cache_read, cache_write=excluded.cache_write,
            usd=excluded.usd, pricing=excluded.pricing
            WHERE excluded.input+excluded.output+excluded.cache_read+excluded.cache_write > events.input+events.output+events.cache_read+events.cache_write
            """, [event.id, dayFormatter.string(from: date), event.provider, event.model, String(c.input), String(c.output), String(c.cacheRead), String(c.cacheWrite), cost.map { String($0) } ?? "", SessionUsagePricing.version])
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

    /// Bounded slices keep the helper and desktop responsive. The next pass resumes all partial files.
    func refresh(maxBytes: Int = 64*1024*1024, seconds: TimeInterval = 12) throws -> SessionUsageReport {
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
            do { handle = try FileHandle(forReadingFrom:file) } catch { unreadable += 1; continue }
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
        return SessionUsageReport(buckets:buckets,updatedAt:iso.string(from:Date()),timeZone:zone.identifier,filesIndexed:cursors.count,pendingFiles:max(0,pending.count-completed),unreadableFiles:unreadable+cursors.reduce(0){$0+$1.oversizedRows},malformedRows:cursors.reduce(0){$0+$1.malformed},missingBaselineEvents:cursors.reduce(0){$0+$1.gaps},coverage:["Claude Code and Codex local session logs, including archived sessions and subagents.","Cursor, browser-only chats, other Macs and providers without token records are not included.","History starts at the earliest usage still present on this Mac. Deleted logs cannot be backfilled. Incomplete final lines wait for the next write; rows larger than 8 MiB are skipped and reported as coverage gaps.","Input, cache read, cache write and output are disjoint. Reasoning is included in output."],pricingVersion:SessionUsagePricing.version)
    }
}
