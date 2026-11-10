import Foundation
import SQLite3

/// 0.5.387 (D4): the usage summary never sorts through temp files.
/// Before: `SCAN events USING INDEX usage_day` + `USE TEMP B-TREE FOR GROUP BY`, 26.5 MB of temp writes per pass on a
/// 513,383-row copy of a real history. After: `SCAN events USING COVERING INDEX usage_rollup`, 0 bytes.
/// Compiled with Sources/SessionUsageCore.swift and HelperSources/SessionUsageCollector.swift (Tests/run-stability-d4.sh).
@main struct StabilityD4HelperChecks {
    static func check(_ yes: Bool, _ label: String) { if !yes { fatalError(label) } }

    static func sql(_ file: URL, _ text: String) -> [String] {
        var db: OpaquePointer?
        check(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, "open the test history")
        defer { sqlite3_close(db) }
        var s: OpaquePointer?
        check(sqlite3_prepare_v2(db, text, -1, &s, nil) == SQLITE_OK, "prepare: \(text)")
        defer { sqlite3_finalize(s) }
        var out: [String] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let last = sqlite3_column_count(s) - 1
            out.append(sqlite3_column_text(s, last).map { String(cString: $0) } ?? "")
        }
        return out
    }
    static func plan(_ file: URL) -> String { sql(file, "EXPLAIN QUERY PLAN " + SessionUsageCollector.rollupSQL).joined(separator: " | ") }
    static func hasIndex(_ file: URL) -> Bool {
        sql(file, "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='\(SessionUsageCollector.rollupIndex)'") == ["1"]
    }
    static func totals(_ report: SessionUsageReport) -> [String] {
        report.buckets.map { "\($0.day)|\($0.provider)|\($0.model)|\($0.counts.total)|\($0.events)|\($0.pricedEvents)|\($0.estimatedUSD)" }
    }

    static func main() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usage-d4-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".claude/projects/project/a.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = ""
        for (i, model) in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"].enumerated() {
            for day in 1...3 {
                let row: [String: Any] = ["type": "assistant", "timestamp": "2026-11-0\(day)T15:0\(i):00Z",
                    "message": ["id": "m\(i)-\(day)", "model": model,
                                "usage": ["input_tokens": 10 + i, "output_tokens": 20 * day, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 5]]]
                text += String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self) + "\n"
            }
        }
        try text.write(to: log, atomically: true, encoding: .utf8)
        let db = home.appendingPathComponent("history.sqlite")
        let ledger = try SessionUsageCollector(home: home, database: db, timeZone: TimeZone(identifier: "America/Chicago")!)

        // An importing pass builds the index, and the summary then reads it in order: no temp B-tree, no sort.
        let imported = try ledger.refresh()
        check(imported.buckets.count == 9, "fixture: 3 models x 3 days, got \(imported.buckets.count)")
        check(hasIndex(db), "an importing pass builds \(SessionUsageCollector.rollupIndex)")
        let after = plan(db)
        check(after.contains("COVERING INDEX \(SessionUsageCollector.rollupIndex)"), "the summary reads the covering index, plan: \(after)")
        check(!after.contains("TEMP B-TREE"), "the summary never sorts through a temp B-tree, plan: \(after)")

        // Without the index (a history from 0.5.385 or earlier) the old plan is what wrote to disk.
        _ = sql(db, "DROP INDEX \(SessionUsageCollector.rollupIndex)")
        check(plan(db).contains("TEMP B-TREE"), "fixture: with no rollup index the plan sorts, so the check above can fail")

        // A read-only (paused) pass never writes, so it does not build the index, and its totals are the same.
        let paused = try ledger.refresh(maxBytes: 0, readOnly: true)
        check(!hasIndex(db), "a read-only pass never creates the index")
        check(totals(paused) == totals(imported), "same totals with and without the index")

        // The next importing pass builds it again, once, with the same totals.
        let resumed = try ledger.refresh()
        check(hasIndex(db), "the next importing pass builds the index again")
        check(totals(resumed) == totals(imported), "same totals after the index returns")
        check(!plan(db).contains("TEMP B-TREE"), "and the plan stays sort-free")
        print("StabilityD4HelperChecks: usage summary reads the covering index, no temp sort PASS")
    }
}
