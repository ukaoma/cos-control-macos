import Foundation

@main struct Checks {
    static func main() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usage-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        func check(_ yes: Bool, _ label: String) { if !yes { fatalError(label) } }
        let file = home.appendingPathComponent(".claude/projects/project/a.jsonl")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        func line(_ r: [String:Any]) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:r),as:UTF8.self)+"\n" }
        func claude(_ id: String,_ time: String,_ output: Int = 20,_ model: String = "claude-opus-5-5") throws -> String {
            try line(["type":"assistant","timestamp":time,"message":["id":id,"model":model,"usage":["input_tokens":10,"output_tokens":output,"cache_read_input_tokens":100,"cache_creation_input_tokens":40,"cache_creation":["ephemeral_1h_input_tokens":30]],"content":[["text":"SECRET_PROMPT_NEVER_STORE"]]]])
        }
        let a = try claude("m1","2026-10-01T00:30:00Z")
        try (a+a).write(to:file,atomically:true,encoding:.utf8)
        let db = home.appendingPathComponent("history.sqlite")
        let ledger = try SessionUsageCollector(home:home,database:db,timeZone:TimeZone(identifier:"America/Chicago")!)
        let first = try ledger.refresh()
        check(first.buckets.count == 1,"one bucket")
        check(first.buckets[0].day == "2026-09-30","local month boundary")
        check(first.buckets[0].counts.total == 170,"Claude fragments deduplicated")
        check(abs(first.buckets[0].estimatedUSD-0.00075) < 0.0000001,"cache TTL priced separately")
        let again = try ledger.refresh(); check(again.buckets[0].counts.total == 170,"idempotent refresh")
        let h = try FileHandle(forWritingTo:file); try h.seekToEnd(); try h.write(contentsOf:Data(try claude("m1","2026-10-01T00:30:01Z",40).utf8)); try h.close()
        check(try ledger.refresh().buckets[0].counts.total == 190,"streamed usage revision replaces old value")
        let fork = file.deletingLastPathComponent().appendingPathComponent("fork.jsonl"); try FileManager.default.copyItem(at:file,to:fork)
        check(try ledger.refresh().buckets[0].counts.total == 190,"fork history not counted twice")
        try FileManager.default.removeItem(at:file); try FileManager.default.removeItem(at:fork)
        check(try ledger.refresh().buckets[0].counts.total == 190,"history retained after source deletion")
        var cursor = SessionUsageCollector.Cursor()
        _ = SessionUsageCollector.event(["type":"session_meta","payload":["id":"s1","model_provider":"openai"]],source:"codex",cursor:&cursor)
        _ = SessionUsageCollector.event(["type":"turn_context","payload":["model":"gpt-6.1-sol"]],source:"codex",cursor:&cursor)
        func codex(_ total: Int,_ output: Int,_ cached: Int,_ last: Int,_ stamp: String) -> [String:Any] {
            ["type":"event_msg","timestamp":stamp,"payload":["type":"token_count","info":["total_token_usage":["input_tokens":total,"output_tokens":output,"cached_input_tokens":cached,"reasoning_output_tokens":30],"last_token_usage":["input_tokens":last,"output_tokens":10,"cached_input_tokens":0]]]]
        }
        let r1 = codex(100,10,0,100,"2026-10-01T00:00:00Z")
        let e1 = SessionUsageCollector.event(r1,source:"codex",cursor:&cursor)!
        check(e1.counts.total == 110,"reasoning is not additive")
        check(SessionUsageCollector.event(r1,source:"codex",cursor:&cursor) == nil,"repeated cumulative suppressed")
        let e2 = SessionUsageCollector.event(codex(250,30,50,150,"2026-10-01T00:01:00Z"),source:"codex",cursor:&cursor)!
        check(e2.counts.total == 170 && e2.counts.input == 100 && e2.counts.cacheRead == 50,"incremental Codex counters")
        let reset = SessionUsageCollector.event(codex(30,10,0,30,"2026-10-01T00:02:00Z"),source:"codex",cursor:&cursor)!
        check(reset.counts.total == 40,"counter reset")
        var resumed = SessionUsageCollector.Cursor()
        check(SessionUsageCollector.event(codex(1000,100,0,20,"2026-10-01T00:03:00Z"),source:"codex",cursor:&resumed)!.counts.total == 30,"inherited first cumulative not invented usage")
        check(resumed.gaps == 1,"missing baseline surfaced")
        check(resumed.provider == "Unknown provider","missing provider metadata is not attributed to OpenAI")
        check(SessionUsagePricing.estimate(provider:"OpenAI",model:"unknown",counts:e1.counts) == nil,"unknown price")
        check(SessionUsageCounts.number(true) == 0 && SessionUsageCounts.number(-1) == 0,"invalid counts")
        // Partial writes must not lose their final line. A small append changes the prefix; dedup absorbs rescan.
        let b = try claude("m2","2026-10-03T13:00:00Z",50,"unpriced-new-model")
        try String(b.dropLast(5)).write(to:file,atomically:true,encoding:.utf8)
        check(try ledger.refresh().buckets.count == 1,"partial tail held")
        check(try ledger.refresh().pendingFiles == 0,"unchanged partial tail does not spin importer")
        let fh = try FileHandle(forWritingTo:file); try fh.seekToEnd(); try fh.write(contentsOf:Data(b.suffix(5).utf8)); try fh.close()
        let finished = try ledger.refresh()
        check(finished.buckets.count == 2 && finished.buckets.last!.pricedEvents == 0,"append completes unknown-priced record")
        // Real file import across active/archive roots, repeated copied history, and a model switch.
        let active = home.appendingPathComponent(".codex/sessions/session.jsonl")
        let archive = home.appendingPathComponent(".codex/archived_sessions/session.jsonl")
        try FileManager.default.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let meta = try line(["type":"session_meta","payload":["id":"session","model_provider":"openai"]])
        let context = try line(["type":"turn_context","payload":["model":"gpt-6.1-sol"]])
        let history = try meta + context + line(r1) + line(r1)
        try history.write(to: active, atomically: true, encoding: .utf8)
        try history.write(to: archive, atomically: true, encoding: .utf8)
        let imported = try ledger.refresh()
        check(imported.buckets.filter { $0.provider == "OpenAI" }.reduce(Int64(0)) { $0+$1.counts.total } == 110,"active/archive deduplication")
        let nextModel = try line(["type":"turn_context","payload":["model":"gpt-6-astra"]])
        try (history + nextModel + line(codex(250,30,50,150,"2026-10-02T12:00:00Z")) + "broken row\n").write(to: active, atomically: true, encoding: .utf8)
        let switched = try ledger.refresh()
        check(switched.buckets.contains { $0.model == "gpt-6-astra" && $0.counts.total == 170 },"model-specific delta accounting")
        check(switched.malformedRows == 1,"malformed rows surfaced without losing valid usage")
        let reopened = try SessionUsageCollector(home:home,database:db,timeZone:TimeZone(identifier:"Asia/Tokyo")!)
        check(try reopened.refresh(maxBytes:0).timeZone == "America/Chicago","time zone stable across restart")
        // A pass can exhaust its shared budget in the middle of a complete row.
        let boundedHome = home.appendingPathComponent("bounded")
        let boundedFile = boundedHome.appendingPathComponent(".claude/projects/p/log.jsonl")
        try FileManager.default.createDirectory(at:boundedFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try a.write(to:boundedFile,atomically:true,encoding:.utf8)
        let bounded = try SessionUsageCollector(home:boundedHome)
        check(try bounded.refresh(maxBytes:32).pendingFiles == 1,"budget boundary remains pending without a source write")
        check(try bounded.refresh().buckets.first?.counts.total == 170,"next pass resumes budget-cut row")
        // Image rows may exceed the memory bound. Later valid usage must remain reachable,
        // including after the collector restarts in the middle of the oversized row.
        let huge = String(repeating:"x",count:8*1024*1024+1024)
        try (huge + "\n" + claude("after-image","2026-10-04T12:00:00Z")).write(to:boundedFile,atomically:true,encoding:.utf8)
        let skipped = try bounded.refresh()
        check(skipped.pendingFiles == 1 && skipped.unreadableFiles == 1,"oversized row is a reported pending gap")
        let resumedLarge = try SessionUsageCollector(home:boundedHome)
        let afterLarge = try resumedLarge.refresh()
        check(afterLarge.buckets.reduce(0){$0+$1.events} == 2,"usage after oversized row imported across restart")
        check(afterLarge.unreadableFiles == 1 && afterLarge.pendingFiles == 0,"oversized gap counted once and scan finishes")
        // A same-size rewrite beyond the prefix is rescanned, without charging the first row twice.
        let rewrittenFile = boundedFile.deletingLastPathComponent().appendingPathComponent("rewrite.jsonl")
        try (a + claude("rewritten","2026-10-05T12:00:00Z",20)).write(to:rewrittenFile,atomically:true,encoding:.utf8)
        _ = try resumedLarge.refresh()
        try (a + claude("rewritten","2026-10-05T12:00:00Z",40)).write(to:rewrittenFile,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(2)],ofItemAtPath:rewrittenFile.path)
        let afterRewrite = try resumedLarge.refresh()
        check(afterRewrite.buckets.first{$0.day == "2026-10-05"}?.counts.total == 190,"same-size rewrite revises usage beyond prefix")
        // Existing checkpoints gain the optional large-row state without losing progress.
        var oldCheckpoint = try JSONSerialization.jsonObject(with:JSONEncoder().encode(cursor)) as! [String:Any]
        oldCheckpoint.removeValue(forKey:"skippingLongLine")
        let compatible = try JSONDecoder().decode(SessionUsageCollector.Cursor.self,from:JSONSerialization.data(withJSONObject:oldCheckpoint))
        check(compatible.cumulative == cursor.cumulative,"old checkpoint preserves accounting baseline")
        for path in [db, URL(fileURLWithPath:db.path+"-wal")] where FileManager.default.fileExists(atPath:path.path) {
            let raw = try Data(contentsOf:path)
            check(!String(decoding:raw,as:UTF8.self).contains("SECRET_PROMPT"),"database and journal are content-free")
        }
        print("PASS: usage parsing, deduplication, cache pricing, local dates, reset, partial append, retention and unknown coverage")
    }
}
