import Foundation
import SQLite3

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
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_792_987_063.1234567)],ofItemAtPath:boundedFile.path)
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
        // Presentation keeps token comparisons separate from provider allowance and API pricing.
        let displayCounts = SessionUsageCounts(input: 10, output: 20, cacheRead: 900, cacheWrite: 70)
        check(SessionUsagePresentation.tokenCount(displayCounts, excludingCacheReads: false) == 1000, "all token categories retained")
        check(SessionUsagePresentation.tokenCount(displayCounts, excludingCacheReads: true) == 100, "exclude only cache reads, retain cache writes")
        check(SessionUsagePricing.tokens(34_102_960_000) == "34.10B", "billions remain readable")
        check(SessionUsagePricing.tokens(989_390_000) == "989.39M", "million precision retained")
        check(SessionUsagePresentation.share(310_000_000, of: 400_000_000) == "77.5%", "synthetic provider denominator")
        check(SessionUsagePresentation.share(1, of: 10000) == "<0.1%", "small recorded use not rounded to zero")
        check(SessionUsagePresentation.share(0, of: 0) == "Unavailable", "missing denominator is not zero usage")
        let utc = ISO8601DateFormatter()
        let monday = utc.date(from: "2026-10-26T13:23:00Z")!
        let chicago = TimeZone(identifier: "America/Chicago")!
        func inside(_ day: String, _ period: String, _ now: Date = monday) -> Bool {
            SessionUsagePresentation.includes(day: day, period: period, now: now, timeZone: chicago)
        }
        check(inside("2026-10-24", "Last weekend") && inside("2026-10-25", "Last weekend") && !inside("2026-10-23", "Last weekend") && !inside("2026-10-26", "Last weekend"), "last completed weekend boundaries")
        check(inside("2026-10-18", "Last weekend", utc.date(from: "2026-10-25T15:00:00Z")!) && !inside("2026-10-24", "Last weekend", utc.date(from: "2026-10-25T15:00:00Z")!), "Sunday uses previous completed weekend")
        check(inside("2026-10-20", "Last 7 days") && !inside("2026-10-19", "Last 7 days") && !inside("2026-10-27", "Last 7 days"), "seven days includes today, excludes future")
        check(!inside("2026-10-26", "Last 7 days", utc.date(from: "2026-10-26T04:30:00Z")!), "reporting timezone controls day rollover")
        check(inside("2026-09-20", "All history") && !inside("2026-09-20", "2026-10"), "history and month selection")
        let pricedRow = SessionUsageBucket(day: "2026-10-24", provider: "OpenAI", model: "gpt-6-astra", counts: displayCounts, events: 2, pricedEvents: 2, estimatedUSD: 3)
        var nextRow = pricedRow; nextRow.day = "2026-10-25"; nextRow.pricedEvents = 0; nextRow.estimatedUSD = 0
        var outsideWeekend = pricedRow; outsideWeekend.day = "2026-10-23"
        let weekendRows = SessionUsagePresentation.selectPeriod([pricedRow, nextRow, outsideWeekend], period: "Last weekend", now: monday, timeZone: chicago)
        check(weekendRows.map(\.day) == ["2026-10-24", "2026-10-25"], "batch selection uses the same completed weekend")
        let groups = SessionUsagePresentation.aggregate([pricedRow, nextRow])
        check(groups.count == 1 && groups[0].counts.total == 2000 && groups[0].events == 4 && groups[0].pricedEvents == 2, "period tooltip aggregates days and partial pricing")
        check(SessionUsagePresentation.costLabel([pricedRow, nextRow]).hasSuffix("+"), "partial prices visible in tooltip")
        check(SessionUsagePresentation.costLabel([nextRow]) == "No price" && SessionUsagePresentation.costLabel([]) == "No price", "unknown cost never shown as free")
        var anotherProvider = pricedRow; anotherProvider.provider = "Other provider"
        check(SessionUsagePresentation.aggregate([pricedRow, anotherProvider]).count == 2, "same model across providers not merged")
        var outputHeavy = pricedRow; outputHeavy.model = "output-heavy"; outputHeavy.counts = SessionUsageCounts(input: 100, output: 200)
        check(SessionUsagePresentation.aggregate([pricedRow, outputHeavy]).first?.model == "gpt-6-astra", "all-token ranking includes cache")
        check(SessionUsagePresentation.aggregate([pricedRow, outputHeavy], excludingCacheReads: true).first?.model == "output-heavy", "cache-free ranking uses same measure as bars and shares")
        check(inside("2026-09-27", "Last 30 days") && !inside("2026-09-26", "Last 30 days") && inside("2026-10-26", "Last 30 days") && !inside("2026-10-27", "Last 30 days"), "thirty calendar dates cross month boundary")
        check(inside("2026-07-29", "Last 90 days") && !inside("2026-07-28", "Last 90 days"), "ninety calendar dates cross months")
        let afterDST = utc.date(from: "2026-11-02T14:00:00Z")!
        check(inside("2026-10-04", "Last 30 days", afterDST) && !inside("2026-10-03", "Last 30 days", afterDST), "calendar window survives fall DST rather than subtracting seconds")
        let leapDay = utc.date(from: "2024-03-01T14:00:00Z")!
        check(inside("2024-02-01", "Last 30 days", leapDay) && !inside("2024-01-31", "Last 30 days", leapDay), "thirty calendar dates across leap February")
        let customStart = utc.date(from: "2026-10-24T23:30:00Z")!, customEnd = utc.date(from: "2026-10-25T06:00:00Z")!
        let customRows = SessionUsagePresentation.selectPeriod([pricedRow, nextRow, outsideWeekend], period: "Custom dates", now: monday, timeZone: chicago, customStart: customStart, customEnd: customEnd)
        check(customRows.map(\.day) == ["2026-10-24", "2026-10-25"], "custom dates include both reporting-zone boundary days")
        let sameDayEarlier = utc.date(from: "2026-10-24T06:00:00Z")!
        check(SessionUsagePresentation.selectPeriod([pricedRow], period: "Custom dates", now: monday, timeZone: chicago, customStart: customStart, customEnd: sameDayEarlier).count == 1, "same calendar day remains valid regardless of hidden picker time")
        check(SessionUsagePresentation.selectPeriod([pricedRow], period: "Custom dates", now: monday, timeZone: chicago, customStart: customEnd, customEnd: customStart).isEmpty, "reversed custom dates return no records")
        check(SessionUsagePresentation.selectPeriod([pricedRow], period: "Custom dates", now: monday, timeZone: chicago).isEmpty, "incomplete custom dates are not all history")
        let providerSummary = SessionUsagePresentation.summarize([pricedRow, nextRow, anotherProvider], by: \.provider)
        let openai = providerSummary.first { $0.id == "OpenAI" }!
        check(providerSummary.count == 2 && openai.counts.total == 2000 && openai.events == 4 && openai.pricedEvents == 2, "provider totals retain records and pricing coverage without inventing sessions")
        check(openai.estimatedUSD == 3 && openai.costLabel.hasSuffix("+"), "provider summary preserves partial cost")
        let days = SessionUsagePresentation.summarize([pricedRow, nextRow, anotherProvider], by: \.day)
        check(days.count == 2 && days.first { $0.id == "2026-10-24" }?.events == 4, "daily breakdown sums across providers")
        check(SessionUsagePresentation.summarize([nextRow], by: \.provider).first?.costLabel == "No price", "unpriced provider never appears free")
        typealias P = SessionUsagePresentation
        let categoryNames = ["Uncached input", "Output", "Cache read", "Cache write"]
        let mix = P.tokenMix(displayCounts, excludingCacheReads: false)
        let noReads = P.tokenMix(displayCounts, excludingCacheReads: true)
        check(mix.map(\.id) == categoryNames && mix.reduce(0) { $0 + $1.count } == displayCounts.total && !mix.contains { $0.excludedFromTokens }, "token mix is disjoint and reconciles to total")
        check(noReads.map(\.id) == categoryNames && noReads.filter { $0.excludedFromTokens }.map(\.id) == ["Cache read"]
              && noReads.filter { !$0.excludedFromTokens }.reduce(0) { $0 + $1.count } == 100, "exclusion flags only cache reads, keeps them listed for API value, and reconciles the displayed denominator")

        // Weekly keys are civil-date arithmetic: DST days, year ends and leap days never shift a week.
        check(P.periodKey(for: "2026-10-24", scale: .weekly) == "2026-10-19", "Saturday maps to Monday of its week")
        check(P.periodKey(for: "2026-10-25", scale: .weekly) == "2026-10-19", "Sunday stays in the same Monday to Sunday week")
        check(P.periodKey(for: "2026-10-26", scale: .weekly) == "2026-10-26", "Monday starts a new week")
        check(P.periodKey(for: "2026-11-01", scale: .weekly) == "2026-10-26" && P.periodKey(for: "2026-11-02", scale: .weekly) == "2026-11-02"
              && P.periodKey(for: "2026-03-08", scale: .weekly) == "2026-03-02" && P.periodKey(for: "2026-03-09", scale: .weekly) == "2026-03-09", "weekly keys across US DST change days")
        check(P.periodKey(for: "2026-01-01", scale: .weekly) == "2025-12-29" && P.periodKey(for: "2024-03-01", scale: .weekly) == "2024-02-26", "weeks cross year ends and leap days")
        check(SessionUsageDay("2026-02-30") == nil && SessionUsageDay("2026-13-01") == nil && SessionUsageDay("2024-02-29")?.key == "2024-02-29", "invalid dates rejected, leap day kept")
        check(P.periodKeyMap([pricedRow, nextRow], scale: .weekly) == ["2026-10-24": "2026-10-19", "2026-10-25": "2026-10-19"], "day to week map built once")
        for (zone, day) in [("America/Havana", "2026-03-08"), ("America/Santiago", "2026-09-06"), ("America/Chicago", "2026-03-08"), ("America/Chicago", "2026-11-01")] {
            let calendar = P.reportingCalendar(TimeZone(identifier: zone)!)
            check(P.noon(of: day, calendar: calendar).map { P.dayKey(for: $0, calendar: calendar) } == day, "chart date for \(day) in \(zone) stays on its date")
        }
        check(P.periodTitle(for: "2026-10-19", scale: .weekly) == "Week of Oct 19 – Oct 25, 2026", "weekly title spans Monday through Sunday")
        check(P.periodTitle(for: "2026-10-19", scale: .weekly, within: "2026-10-22"..."2026-11-20") == "Oct 22 – Oct 25, 2026 (partial week)", "boundary week title clamps to the selection")
        check(P.periodTitle(for: "2026-12-28", scale: .weekly) == "Week of Dec 28, 2026 – Jan 3, 2027", "week across a year end names both years")
        check(P.periodTitle(for: "2026-10", scale: .monthly) == "October 2026" && P.periodTitle(for: "2026-10", scale: .monthly, within: "2026-09-29"..."2026-10-28") == "October 2026 (Oct 1 – Oct 28)", "boundary month title clamps")
        check(P.periodTitle(for: "2026-10-24", scale: .daily) == "Saturday, Oct 24, 2026", "daily title")
        check(P.selectionBounds(period: "2026-02", now: monday, timeZone: chicago) == "2026-02-01"..."2026-02-28" && P.selectionBounds(period: "All history", now: monday, timeZone: chicago) == nil, "selection bounds for months and history")

        // An inspection belongs to the scale it was chosen on.
        let dayInspection = SessionUsageInspection(key: "2026-10-24", scale: .daily)
        check(P.reconcile(dayInspection, to: .daily, keys: ["2026-10-23", "2026-10-24"]) == dayInspection, "inspection set together with a switch to Daily survives the scale change")
        check(P.reconcile(dayInspection, to: .weekly, keys: ["2026-10-19"]) == SessionUsageInspection(key: "2026-10-19", scale: .weekly), "an inspected day carries into its week")
        check(P.reconcile(dayInspection, to: .monthly, keys: ["2026-10"]) == SessionUsageInspection(key: "2026-10", scale: .monthly), "an inspected day carries into its month")
        check(P.reconcile(SessionUsageInspection(key: "2026-10-19", scale: .weekly), to: .daily, keys: ["2026-10-19"]) == nil, "a week never turns into its Monday")
        check(P.reconcile(dayInspection, to: .daily, keys: ["2026-10-23"]) == nil && P.reconcile(nil, to: .daily, keys: []) == nil, "a vanished period closes")

        // Only All history defaults to Monthly; leaving restores the scale in use before.
        let toHistory = P.timeScale(afterChangingTo: "All history", current: .weekly, remembered: nil)
        check(toHistory.scale == .monthly && toHistory.remembered == .weekly, "All history opens on Monthly and remembers Weekly")
        let back = P.timeScale(afterChangingTo: "Last 7 days", current: .monthly, remembered: .weekly)
        check(back.scale == .weekly && back.remembered == nil, "leaving All history restores the remembered scale")
        let keep = P.timeScale(afterChangingTo: "Last 90 days", current: .weekly, remembered: nil)
        check(keep.scale == .weekly && keep.remembered == nil, "other period changes keep the chosen scale")

        // Model clicks restore the provider filter that was in force before.
        var slice = SessionUsageSlice()
        slice.toggleModel(provider: "OpenAI", model: "gpt-6-astra")
        check(slice.provider == "OpenAI" && slice.model == "gpt-6-astra", "model click narrows provider and model")
        slice.toggleModel(provider: "OpenAI", model: "gpt-6-astra")
        check(slice.provider == P.allProviders && slice.model == P.allModels, "second model click restores All providers")
        slice.choose(provider: "Anthropic"); slice.toggleModel(provider: "Anthropic", model: "claude-opus-5-5"); slice.toggleModel(provider: "Anthropic", model: "claude-opus-5-5")
        check(slice.provider == "Anthropic" && slice.model == P.allModels, "clearing a model keeps a provider chosen before it")
        slice.reset(); slice.toggleModel(provider: "OpenAI", model: "gpt-6-astra"); slice.toggleModel(provider: "OpenAI", model: "gpt-6.1-sol"); slice.toggleModel(provider: "OpenAI", model: "gpt-6.1-sol")
        check(slice.provider == P.allProviders, "switching models keeps the original provider to restore")
        slice.toggleProvider("OpenAI"); slice.toggleProvider("OpenAI")
        check(slice == SessionUsageSlice(), "provider click toggles back to all")

        // Records count whole observations, so they never offer Categories.
        check(P.seriesOptions(for: .records) == [.providers, .models] && P.series(.categories, for: .records) == .providers
              && P.series(.categories, for: .tokens) == .categories && P.seriesOptions(for: .cost) == SessionUsageSeries.allCases, "Records hides Categories")

        // Category cost split: exact rates, 1-hour premium capped, partial buckets excluded, Haiku 5.5 tier scaled.
        let opusBucket = first.buckets[0]
        let opusCat = SessionUsagePricing.categoryUSD(for: opusBucket)!
        check(abs(opusCat.total - opusBucket.estimatedUSD) < 1e-12, "category USD reconciles to stored bucket estimatedUSD")
        check(abs(opusCat.input - 40e-6) < 1e-12 && abs(opusCat.output - 400e-6) < 1e-12 && abs(opusCat.cacheRead - 20e-6) < 1e-12 && abs(opusCat.cacheWrite - 290e-6) < 1e-12,
              "exact rates per category; the 1-hour write premium lands on cache write only")
        let allOneHour = SessionUsageBucket(day: "2026-10-01", provider: "Anthropic", model: "claude-opus-5-5", counts: SessionUsageCounts(input: 1_000_000, cacheWrite: 1_000_000), events: 1, pricedEvents: 1, estimatedUSD: 12)
        let atCap = SessionUsagePricing.categoryUSD(for: allOneHour)!
        check(abs(atCap.input - 4) < 1e-9 && abs(atCap.cacheWrite - 8) < 1e-9, "every write at the 1-hour rate is the cap and still splits exactly")
        var rateDecrease = allOneHour; rateDecrease.estimatedUSD = 24
        let overCap = SessionUsagePricing.categoryUSD(for: rateDecrease)!
        check(abs(overCap.input - 32.0 / 3) < 1e-9 && abs(overCap.cacheWrite - 40.0 / 3) < 1e-9, "a remainder above the 1-hour cap scales instead of loading cache write")
        let haikuLong = SessionUsageBucket(day: "2026-10-01", provider: "Anthropic", model: "claude-haiku-5-5", counts: SessionUsageCounts(input: 150_000, output: 1_000, cacheWrite: 10_000), events: 1, pricedEvents: 1,
            estimatedUSD: SessionUsagePricing.estimate(provider: "Anthropic", model: "claude-haiku-5-5", counts: SessionUsageCounts(input: 150_000, output: 1_000, cacheWrite: 10_000))!)
        let haikuCat = SessionUsagePricing.categoryUSD(for: haikuLong)!
        check(abs(haikuLong.estimatedUSD - 0.08375) < 1e-12 && abs(haikuCat.input - 0.075) < 1e-12 && abs(haikuCat.output - 0.0025) < 1e-12 && abs(haikuCat.cacheWrite - 0.00625) < 1e-12,
              "Haiku 5.5 >100K prompt tier scales every category")
        let partialOpenAI = SessionUsageBucket(day: "2026-10-01", provider: "OpenAI", model: "gpt-6.1-sol", counts: SessionUsageCounts(input: 1000, output: 100, cacheRead: 0, cacheWrite: 5000), events: 3, pricedEvents: 2, estimatedUSD: 0.5)
        check(SessionUsagePricing.categoryUSD(for: partialOpenAI) == nil && SessionUsagePricing.categoryUSD(for: nextRow) == nil, "partial and unpriced buckets are never split")
        let split = P.costSplit([opusBucket, partialOpenAI, nextRow])
        check(abs(split.splitUSD - opusBucket.estimatedUSD) < 1e-12 && abs(split.pricedUSD - (opusBucket.estimatedUSD + 0.5)) < 1e-12 && split.unsplitRecords == 3 && !split.isComplete,
              "split covers fully priced records and reports what it left out")
        let splitMix = P.tokenMix(opusBucket.counts + partialOpenAI.counts, excludingCacheReads: false, rows: [opusBucket, partialOpenAI])
        check(abs(splitMix[3].estimatedUSD - 290e-6) < 1e-12, "never-charged OpenAI cache writes get no dollars")
        check(P.costSplit([opusBucket]).isComplete, "fully priced selection splits completely")

        // Bars and hover card geometry.
        let widths = P.segmentWidths([0.98, 0.005, 0.015], total: 100, spacing: 1, minimum: 2)
        check(abs(widths[0] - 94) < 1e-9 && widths[1] == 2 && widths[2] == 2 && abs(widths.reduce(0, +) + 2 - 100) < 1e-9, "slivers get the minimum and the bar never overflows")
        let gapped = P.segmentWidths([0.5, 0, 0.5], total: 100, spacing: 1, minimum: 2)
        check(gapped == [49.5, 0, 49.5], "zero segments take no room or gap")
        check(P.tooltipX(pointer: 100, cardWidth: 388, containerWidth: 700) == 118, "card sits right of a left-side pointer")
        let leftX = P.tooltipX(pointer: 600, cardWidth: 388, containerWidth: 700)
        check(leftX == 194 && leftX + 388 + 18 <= 600, "padded card flips left without covering the pointer")
        check(P.tooltipX(pointer: 690, cardWidth: 388, containerWidth: 700) + 388 <= 692 && P.tooltipX(pointer: 300, cardWidth: 388, containerWidth: 700) + 388 <= 692, "card never runs past the right edge")

        // Sorting: every measure orders the fixture differently. Unpriced models stay last both ways.
        func model(_ provider: String, _ name: String, total: Int64, read: Int64, events: Int, priced: Int, usd: Double) -> SessionUsageBucket {
            SessionUsageBucket(day: "2026-10-20", provider: provider, model: name, counts: SessionUsageCounts(input: total - read, cacheRead: read), events: events, pricedEvents: priced, estimatedUSD: usd)
        }
        var alphaLater = model("Anthropic", "alpha", total: 600, read: 60, events: 3, priced: 3, usd: 5); alphaLater.day = "2026-10-21"
        let sortRows = [model("Anthropic", "alpha", total: 400, read: 40, events: 2, priced: 2, usd: 4), alphaLater,
                        model("OpenAI", "bravo", total: 3000, read: 2700, events: 1, priced: 1, usd: 2),
                        model("OpenAI", "charlie", total: 2000, read: 1000, events: 9, priced: 4, usd: 5),
                        model("Anthropic", "delta", total: 500, read: 0, events: 3, priced: 0, usd: 0),
                        model("OpenAI", "echo", total: 4000, read: 400, events: 7, priced: 0, usd: 0)]
        let twins = [model("OpenAI", "same", total: 100, read: 0, events: 1, priced: 1, usd: 1), model("Anthropic", "same", total: 100, read: 0, events: 1, priced: 1, usd: 1)]
        check(P.sortModels(twins, by: .tokens).map(\.provider) == ["Anthropic", "OpenAI"] && P.sortModels(twins, by: .tokens, ascending: true).map(\.provider) == ["Anthropic", "OpenAI"], "ties break on provider|model in both directions")
        func order(_ sort: SessionUsageModelSort, _ ascending: Bool) -> [String] { P.sortModels(sortRows, by: sort, ascending: ascending).map(\.model) }
        check(order(.tokens, false) == ["echo", "bravo", "charlie", "alpha", "delta"] && order(.tokens, true) == ["delta", "alpha", "charlie", "bravo", "echo"], "sort by tokens both ways")
        check(order(.cost, false) == ["alpha", "charlie", "bravo", "delta", "echo"], "API value descending, unpriced last")
        check(order(.cost, true) == ["bravo", "charlie", "alpha", "delta", "echo"], "API value ascending, unpriced still last")
        check(order(.records, false) == ["charlie", "echo", "alpha", "delta", "bravo"] && order(.records, true) == ["bravo", "delta", "alpha", "echo", "charlie"], "sort by records both ways")
        check(order(.cacheShare, false) == ["bravo", "charlie", "alpha", "echo", "delta"] && order(.cacheShare, true) == ["delta", "alpha", "echo", "charlie", "bravo"], "cache share ties break on provider|model")
        check(order(.model, true) == ["alpha", "bravo", "charlie", "delta", "echo"] && order(.model, false) == ["echo", "delta", "charlie", "bravo", "alpha"], "sort by model name both ways")
        check(P.defaultAscending(.model) && !P.defaultAscending(.tokens) && P.directionLabel(SessionUsageModelSort.model, ascending: true) == "A to Z"
              && P.directionLabel(SessionUsageModelSort.cost, ascending: false) == "Highest first" && P.directionLabel(SessionUsageDaySort.date, ascending: false) == "Newest first", "sort direction defaults and labels")
        check(P.aggregate(sortRows).first { $0.model == "alpha" }?.day == "" && P.aggregate(sortRows).first { $0.model == "alpha" }?.counts.total == 1000, "aggregate spans days without an arbitrary day id")
        func day(_ d: String, _ total: Int64, _ events: Int, _ priced: Int, _ usd: Double) -> SessionUsageBucket {
            SessionUsageBucket(day: d, provider: "OpenAI", model: "gpt-6-astra", counts: SessionUsageCounts(input: total), events: events, pricedEvents: priced, estimatedUSD: usd)
        }
        let dayRows = [day("2026-10-01", 300, 2, 2, 1), day("2026-10-02", 100, 1, 1, 5), day("2026-10-03", 200, 9, 0, 0)]
        check(P.sortDays(dayRows, by: .cost).map(\.id) == ["2026-10-02", "2026-10-01", "2026-10-03"] && P.sortDays(dayRows, by: .cost, ascending: true).map(\.id) == ["2026-10-01", "2026-10-02", "2026-10-03"], "unpriced days sort last on API value both ways")
        check(P.sortDays(dayRows, by: .tokens, ascending: true).map(\.id) == ["2026-10-02", "2026-10-03", "2026-10-01"] && P.sortDays(dayRows, by: .date).map(\.id) == ["2026-10-03", "2026-10-02", "2026-10-01"], "day sorts by tokens and date")

        // Peak day follows the active measure; ties go to the earlier date.
        check(P.peakDay(dayRows, measure: .tokens)?.id == "2026-10-01" && P.peakDay(dayRows, measure: .cost)?.id == "2026-10-02" && P.peakDay(dayRows, measure: .records)?.id == "2026-10-03", "peak day ranks by tokens, API value or records")
        check(P.peakDay([day("2026-10-05", 100, 1, 1, 1), day("2026-10-04", 100, 1, 1, 1)], measure: .tokens)?.id == "2026-10-04", "peak tie goes to the earlier date")
        check(P.peakDay([nextRow], measure: .cost) == nil, "no priced day, no API value peak")

        // Period comparison: like-for-like windows, explicit ranges, partial coverage.
        let priorRow = SessionUsageBucket(day: "2026-10-17", provider: "OpenAI", model: "gpt-6-astra", counts: SessionUsageCounts(input: 5, output: 10, cacheRead: 450, cacheWrite: 35), events: 1, pricedEvents: 1, estimatedUSD: 1.5)
        let cmp = P.comparePeriod(allRows: [priorRow, pricedRow, nextRow], selectedRows: [pricedRow, nextRow], period: "Last 7 days", now: monday, timeZone: chicago)
        check(cmp.dailyAvgTokens == 1000 && cmp.dailyAvgRecords == 2, "daily averages divide by recorded days")
        check(cmp.currentRange == "2026-10-20"..."2026-10-26" && cmp.priorRange == "2026-10-13"..."2026-10-19" && cmp.includesToday && cmp.hasPriorBaseline, "prior 7-day window aligned; current window flags today")
        check(cmp.tokenDeltaLabel == "+300.0%" && cmp.recordsDeltaLabel == "+300.0%" && cmp.costDeltaLabel == "+100.0%", "deltas compare current to prior window")
        check(cmp.costDeltaPartial && cmp.priorPriced && cmp.priorUSD == 1.5, "API value delta marked partial when a window has unpriced records; prior dollars kept")
        let fullyPriced = P.comparePeriod(allRows: [priorRow, pricedRow], selectedRows: [pricedRow], period: "Last 7 days", now: monday, timeZone: chicago)
        check(!fullyPriced.costDeltaPartial, "fully priced windows are not partial")
        let noPrior = P.comparePeriod(allRows: [pricedRow], selectedRows: [pricedRow], period: "Last 7 days", now: monday, timeZone: chicago)
        check(!noPrior.hasPriorBaseline && noPrior.tokenDeltaLabel == "Unavailable", "absent prior window is Unavailable, never +infinity")
        let marchMTD = P.comparisonWindows(period: "2026-03", now: utc.date(from: "2026-03-30T17:00:00Z")!, timeZone: chicago)
        check(marchMTD?.current == "2026-03-01"..."2026-03-30" && marchMTD?.prior == "2026-02-01"..."2026-02-28", "month to date compares the same elapsed dates, clamped to a shorter month")
        let octoberMTD = P.comparisonWindows(period: "2026-10", now: monday, timeZone: chicago)
        check(octoberMTD?.current == "2026-10-01"..."2026-10-26" && octoberMTD?.prior == "2026-09-01"..."2026-09-26", "month in progress is not compared with a whole month")
        let september = P.comparisonWindows(period: "2026-09", now: monday, timeZone: chicago)
        check(september?.current == "2026-09-01"..."2026-09-30" && september?.prior == "2026-08-01"..."2026-08-31", "completed month compares with the whole previous month")
        check(P.comparisonWindows(period: "Last weekend", now: monday, timeZone: chicago)?.prior == "2026-10-17"..."2026-10-18" && P.comparisonWindows(period: "All history", now: monday, timeZone: chicago) == nil, "weekend and history windows")
        check(P.dateRangeTitle("2026-10-13"..."2026-10-19") == "Oct 13 – Oct 19, 2026" && P.dateRangeTitle("2026-10-13"..."2026-10-13") == "Oct 13, 2026", "range titles")

        // Exports: the active slice, escaped and neutralized CSV, parsed JSON.
        let weekRows = [pricedRow, nextRow, outsideWeekend]
        check(P.exportRows(weekRows, inspection: SessionUsageInspection(key: "2026-10-24", scale: .daily)).map(\.day) == ["2026-10-24"], "export narrows to the inspected day")
        check(P.exportRows(weekRows, inspection: SessionUsageInspection(key: "2026-10-19", scale: .weekly)).count == 3 && P.exportRows(weekRows, inspection: nil).count == 3, "export keeps a whole inspected week, or everything without inspection")
        var partialRow = pricedRow; partialRow.day = "2026-10-23"; partialRow.pricedEvents = 1
        let csv = P.exportCSV([pricedRow, nextRow, partialRow], excludingCacheReads: true)
        check(csv.contains("\n2026-10-24,OpenAI,gpt-6-astra,100,1000,10,20,900,70,2,2,3.000000,priced\n"), "CSV includes both displayed and all tokens")
        check(csv.contains("\n2026-10-25,OpenAI,gpt-6-astra,100,1000,10,20,900,70,2,0,,unpriced\n"), "CSV leaves unpriced USD blank rather than 0")
        check(csv.contains("\n2026-10-23,OpenAI,gpt-6-astra,100,1000,10,20,900,70,2,1,3.000000,partial\n"), "CSV marks partially priced rows")
        check(P.csvField("a,b") == "\"a,b\"" && P.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"" && P.csvField("line\nbreak") == "\"line\nbreak\"" && P.csvField("cr\rhere") == "\"cr\rhere\"", "CSV quotes commas, quotes, newlines and carriage returns")
        check(P.csvField("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"" && P.csvField("+1") == "'+1" && P.csvField("-2") == "'-2" && P.csvField("@cmd") == "'@cmd" && P.csvField("plain-model") == "plain-model", "CSV neutralizes formula-leading characters only")
        var hostile = pricedRow; hostile.model = "=cmd|' /C calc'!A0"
        check(P.exportCSV([hostile], excludingCacheReads: false).contains(",'=cmd|' /C calc'!A0,"), "hostile model name exported as text")
        let exportContext = P.ExportContext(period: "Custom dates", customStart: "2026-10-20", customEnd: "2026-10-26", provider: "OpenAI", model: P.allModels,
            excludingCacheReads: true, timeScale: .weekly, inspection: SessionUsageInspection(key: "2026-10-19", scale: .weekly),
            inspectedTitle: "Oct 20 – Oct 25, 2026 (partial week)", timeZone: "America/Chicago", pricingVersion: SessionUsagePricing.version)
        let parsed = try JSONSerialization.jsonObject(with: Data(P.exportJSON([pricedRow, nextRow], context: exportContext).utf8)) as! [String: Any]
        check(parsed["displayedTokens"] as? Int == 200 && parsed["allTokens"] as? Int == 2000 && parsed["hasUnpricedRecords"] as? Bool == true
              && parsed["usageRecords"] as? Int == 4 && parsed["pricedRecords"] as? Int == 2 && parsed["estimatedUSD"] as? Double == 3, "JSON totals reconcile the slice")
        check(parsed["customStart"] as? String == "2026-10-20" && parsed["customEnd"] as? String == "2026-10-26" && parsed["timeScale"] as? String == "Weekly"
              && parsed["inspectedPeriod"] as? String == "2026-10-19" && parsed["inspectedPeriodScale"] as? String == "Weekly"
              && parsed["inspectedPeriodTitle"] as? String == "Oct 20 – Oct 25, 2026 (partial week)" && parsed["providerFilter"] as? String == "OpenAI" && parsed["excludeCacheReads"] as? Bool == true, "JSON names the period, dates, scale, inspection and filters")
        let jsonBuckets = parsed["buckets"] as! [[String: Any]]
        check(jsonBuckets.map { $0["pricingStatus"] as? String } == ["priced", "unpriced"] && jsonBuckets[1]["estimatedUSD"] is NSNull && jsonBuckets[0]["estimatedUSD"] as? Double == 3, "JSON buckets carry pricing status and null unknown cost")
        var noInspection = exportContext; noInspection.inspection = nil; noInspection.inspectedTitle = nil; noInspection.customStart = nil
        let plain = try JSONSerialization.jsonObject(with: Data(P.exportJSON([pricedRow], context: noInspection).utf8)) as! [String: Any]
        check(plain["inspectedPeriod"] is NSNull && plain["customStart"] is NSNull, "absent inspection and dates are null, not omitted")

        // Tools and names.
        check(P.toolName("Anthropic") == "Claude Code" && P.toolName("OpenAI") == "Codex" && P.toolName("Cursor") == "Cursor", "tools are named for what people run")
        check(P.toolName("Ollama") == "Codex (Ollama)", "a Codex log's other provider stays distinct and traceable")
        for (id, name) in [("claude-opus-5-5", "Opus 5.5"), ("claude-opus-5", "Opus 5"), ("claude-haiku-4-5-20251001", "Haiku 4.5"), ("claude-opus-5-thinking-high", "Opus 5 thinking high"),
                           ("claude-4.5-opus-high-thinking", "Opus 4.5 high thinking"), ("gpt-6.1-sol", "GPT-6.1 Sol"), ("gpt-5.6-sol-xhigh", "GPT-5.6 Sol xhigh"), ("gpt-5.5", "GPT-5.5"),
                           ("cursor-grok-4.6-xhigh-fast", "Grok 4.6 xhigh fast"), ("composer-2.5-fast", "Composer 2.5 fast"), ("codex-auto-review", "Codex auto review"), ("Unknown model", "Unknown model"), ("default", "default")] {
            check(P.modelName(id) == name, "model name \(id) reads \(name), got \(P.modelName(id))")
        }
        check(P.spokenTokens(78_000_000_000) == "78.0 billion" && P.spokenTokens(459_000_000) == "459 million" && P.spokenTokens(85_700_000) == "85.7 million" && P.spokenTokens(900) == "900", "spoken token sizes")
        check(P.shortTokens(74_020_000_000) == "74.02B" && P.shortTokens(601_640_000) == "602M" && P.shortTokens(50_400_000) == "50.4M" && P.shortTokens(358_100) == "358K" && P.shortTokens(1_500) == "1.5K" && P.shortTokens(12) == "12", "table token sizes scan")
        check(P.dollars(75.04) == "$75" && P.dollars(0.04) == "<$1" && P.dollars(0) == "$0", "whole dollars, and a small amount never rounds to nothing")
        check(P.costCell([nextRow]) == "No price" && P.costCell([pricedRow]) == "$3" && P.costCell([pricedRow, nextRow]) == "$3+", "cost cells stay honest about unpriced records")
        // 0.5.358: the figures row, the calendar and the partial bars.
        func usageRow(_ day: String, usd: Double, events: Int = 2, priced: Int = 2, provider: String = "Anthropic", model: String = "m", new: Int64 = 1_000_000) -> SessionUsageBucket {
            SessionUsageBucket(day: day, provider: provider, model: model, counts: SessionUsageCounts(input: new, output: 0, cacheRead: 500, cacheWrite: 0), events: events, pricedEvents: priced, estimatedUSD: usd)
        }
        check(P.partialPeriods(["2026-10-19", "2026-10-26"], scale: .weekly, firstDay: "2026-10-19", lastDay: "2026-10-31") == ["2026-10-26"], "a week today cuts short is partial and a full one is not")
        check(P.partialPeriods(["2026-10-19"], scale: .weekly, firstDay: "2026-10-20", lastDay: "2026-10-31") == ["2026-10-19"], "a week the selection starts inside is partial")
        check(P.partialPeriods(["2026-10-19"], scale: .weekly, firstDay: "2026-10-19", lastDay: "2026-10-25") == [], "a week ending on the last day is whole")
        check(P.partialPeriods(["2026-09", "2026-10"], scale: .monthly, firstDay: "2026-09-01", lastDay: "2026-10-30") == ["2026-10"], "a month with a day left is partial")
        check(P.partialPeriods(["2026-09"], scale: .monthly, firstDay: "2026-09-02", lastDay: "2026-09-30") == ["2026-09"], "a month starting late is partial")
        check(P.partialPeriods(["2026-10-19"], scale: .daily, firstDay: "2026-10-20", lastDay: "2026-10-18") == [], "a day is never partial")
        check(P.periodAverage(["a": 2, "b": 4, "c": 6, "d": 8, "e": 100], partial: ["e"]) == 5, "the average leaves out a partial period")
        check(P.periodAverage(["a": 2, "b": 4, "c": 6, "d": 100], partial: ["d"]) == nil, "under four full periods there is no average")
        check(P.dailyValueLabel([usageRow("2026-10-19", usd: 100), usageRow("2026-10-20", usd: 0, priced: 0)]) == "$100", "a day with no price is left out of the daily value, not counted as $0")
        check(P.dailyValueLabel([usageRow("2026-10-19", usd: 0, priced: 0)]) == "No price", "no priced day has no daily value, never $0")
        check(P.dailyValueLabel([usageRow("2026-10-19", usd: 100, priced: 1)]) == "$100+", "a partly priced day marks the daily value")
        check(P.valuePerMillionNew([usageRow("2026-10-19", usd: 10, new: 2_000_000)]) == "$5.00", "value per million new tokens")
        check(P.valuePerMillionNew([usageRow("2026-10-19", usd: 5, priced: 1, new: 2_000_000)]) == "No price", "a partly priced row cannot divide part of its value by all of its tokens")
        check(P.valuePerMillionNew([usageRow("2026-10-19", usd: 10, new: 2_000_000), usageRow("2026-10-19", usd: 5, priced: 1, model: "other", new: 9_000_000)]) == "$5.00", "only wholly priced rows count")
        check(P.valuePerMillionNew([usageRow("2026-10-19", usd: 0, priced: 0)]) == "No price", "an unpriced row has no value per token")
        let everyDay = P.weekdayAverages([usageRow("2026-10-19", usd: 100), usageRow("2026-10-26", usd: 0, priced: 0)], counted: { $0.pricedEvents > 0 }, value: { $0.estimatedUSD })
        check(everyDay[0] == 100 && everyDay[1...].allSatisfy { $0 == 0 }, "an unpriced Monday does not halve the Monday average, and the other weekdays stay empty")
        check(P.weekdayAverages([usageRow("2026-10-19", usd: 100), usageRow("2026-10-26", usd: 50)], counted: { _ in true }, value: { $0.estimatedUSD })[0] == 75, "a weekday averages its days")
        check(P.weekdayAverages([usageRow("2026-10-25", usd: 7)], counted: { _ in true }, value: { $0.estimatedUSD })[6] == 7, "Sunday is the last row")
        let thirtyDays = P.calendarWeeks([usageRow("2026-10-14", usd: 1)], bounds: "2026-10-02"..."2026-11-30", today: "2026-10-31")
        check(thirtyDays.first?.id == "2026-09-28" && thirtyDays.last?.id == "2026-10-26" && thirtyDays.allSatisfy { $0.days.count == 7 }, "columns run from the selection's Monday to today's, never into the future")
        check(thirtyDays[0].days[3].inRange == false && thirtyDays[0].days[4].inRange == true && thirtyDays.last?.days[5].inRange == true && thirtyDays.last?.days[6].inRange == false, "days outside the selection or after today are out of range")
        check(thirtyDays[2].days[2].summary?.estimatedUSD == 1 && thirtyDays[2].days[3].summary == nil && thirtyDays[2].days[3].inRange, "a day in range with no records stays empty, not zero")
        check(P.calendarWeeks([], bounds: "2026-05-29"..."2026-06-30", today: "2026-10-31").compactMap(\.monthLabel) == ["Jun"], "a stub first column does not run its label into the next")
        check(P.calendarWeeks([], bounds: "2026-09-28"..."2026-10-31", today: "2026-10-31").compactMap(\.monthLabel) == ["Sep", "Oct"], "a full first column keeps its label, then each month once")
        check(P.calendarWeeks([], bounds: nil, today: "2026-10-31").isEmpty && P.calendarWeeks([], bounds: "2026-11-01"..."2026-11-30", today: "2026-10-31").isEmpty, "no history, or a month not started, gives no calendar")
        let longLabels = P.calendarWeeks([usageRow("2025-07-07", usd: 1)], bounds: nil, today: "2026-10-31").compactMap(\.monthLabel)
        check(longLabels.first == "Jul 2025" && longLabels.contains("Jan 2026") && longLabels.contains("Jul") && !longLabels.contains("Jul 2026"), "a calendar over a year long names the year at its start and each January")
        check(P.weekdayDay("2026-10-24", thisYear: 2026) == "Sat, Oct 24" && P.weekdayDay("2025-10-24", thisYear: 2026) == "Fri, Oct 24, 2025", "a date outside this year says so")
        check(P.shortDay("2026-10-24", thisYear: 2026) == "Oct 24" && P.shortDay("2025-10-24", thisYear: 2026) == "Oct 24, 2025", "a compact date outside this year says so")
        check(P.lastUsed([usageRow("2026-10-19", usd: 1), usageRow("2026-10-21", usd: 1), usageRow("2026-10-20", usd: 1)])["Anthropic|m"] == "2026-10-21", "last used is the latest day")
        let paceZone = TimeZone(identifier: "UTC")!
        let paceClock = { (day: String) in P.noon(of: day, calendar: P.reportingCalendar(paceZone))! }
        let pace = P.monthPace([usageRow("2026-10-01", usd: 10), usageRow("2026-10-10", usd: 90), usageRow("2026-09-30", usd: 999)], now: paceClock("2026-10-10"), timeZone: paceZone)
        check(pace?.usd == 100 && pace?.complete == true && pace?.lastDay == "Oct 31" && pace?.projectedUSD == 100 + 10 * 21, "the month counts only its own days and projects a straight line")
        check(P.monthPace([usageRow("2026-10-20", usd: 30)], now: paceClock("2026-10-22"), timeZone: paceZone)?.projectedUSD == 30 + 10 * 9, "usage that started mid-month projects from its start")
        check(P.monthPace([usageRow("2026-10-01", usd: 30)], now: paceClock("2026-10-02"), timeZone: paceZone)?.projectedUSD == nil, "under three days has no projection")
        check(P.monthPace([usageRow("2026-10-01", usd: 30)], now: paceClock("2026-10-31"), timeZone: paceZone)?.projectedUSD == nil, "the last day has nothing left to project")
        check(P.monthPace([usageRow("2026-10-01", usd: 0, priced: 0)], now: paceClock("2026-10-10"), timeZone: paceZone)?.hasPrice == false, "an unpriced month has no value to show")
        check(P.monthPace([usageRow("2026-10-01", usd: 5, priced: 1)], now: paceClock("2026-10-10"), timeZone: paceZone)?.complete == false, "a partly priced month says so")
        let futureEnd = P.comparisonWindows(period: P.customDates, now: paceClock("2026-10-31"), timeZone: paceZone, customStart: paceClock("2026-10-15"), customEnd: paceClock("2026-11-15"))
        check(futureEnd?.current == "2026-10-15"..."2026-10-31" && futureEnd?.prior == "2026-09-28"..."2026-10-14", "a range past today compares like for like")
        check(P.comparisonWindows(period: P.customDates, now: paceClock("2026-10-31"), timeZone: paceZone, customStart: paceClock("2026-11-02"), customEnd: paceClock("2026-11-15")) == nil, "a range entirely in the future has nothing to compare")
        check(P.axisLabel(for: "2026-10-19") == "Oct 19" && P.axisLabel(for: "2026-10") == "Oct" && P.axisLabel(for: "2026-01") == "Jan 2026", "axis labels are short dates")
        check(P.axisKeys(["a", "b", "c"]) == ["a", "b", "c"] && P.axisKeys((1...30).map(String.init)).count <= 8 && P.axisKeys((1...30).map(String.init)).first == "1" && P.axisKeys((1...25).map(String.init)).last != "25", "about seven axis labels, starting at the first period and never clipping the last")
        check(P.seriesOrder(["small": 1, "big": 9, "mid": 5]) == ["big", "mid", "small"] && P.seriesOrder(["b": 1, "a": 1]) == ["a", "b"], "the largest series comes first, ties by name")
        check(P.valueShare([pricedRow], of: 6) == "50.0%" && P.valueShare([nextRow], of: 6) == "Unavailable", "the share of value is priced records only")
        check(P.defaultScale(for: "Last 30 days") == .daily && P.defaultScale(for: "Last 90 days") == .weekly && P.defaultScale(for: "All history") == .monthly && P.defaultScale(for: "2026-10") == .daily, "each period opens on a readable scale")
        check(P.niceAxisTop(13_000) == 16_000 && P.niceAxisTop(459) == 600 && P.niceAxisTop(5736) == 6000 && P.niceAxisTop(0) == 1, "axis tops land on four round steps")
        let cursorRow = SessionUsageBucket(day: "2026-10-24", provider: "Cursor", model: "grok-4.7", counts: SessionUsageCounts(input: 1, output: 1, cacheRead: 5000, cacheWrite: 0), events: 1, pricedEvents: 1, estimatedUSD: 2)
        let groups2 = P.toolGroups([pricedRow, anotherProvider, cursorRow, nextRow], by: .tokens)
        check(Set(groups2.map(\.id)) == Set([pricedRow.provider, anotherProvider.provider, "Cursor"]) && groups2.first(where: { $0.id == "Cursor" })?.tool == "Cursor", "one group per tool")
        check(groups2.reduce(0) { $0 + $1.models.count } == P.aggregate([pricedRow, anotherProvider, cursorRow, nextRow]).count, "every model lands in exactly one tool")
        let byNew = P.sortModels([SessionUsageBucket(day: "2026-10-24", provider: "A", model: "reads", counts: SessionUsageCounts(input: 1, output: 0, cacheRead: 9000, cacheWrite: 0), events: 1, pricedEvents: 1, estimatedUSD: 1),
                                  SessionUsageBucket(day: "2026-10-24", provider: "A", model: "writes", counts: SessionUsageCounts(input: 50, output: 50, cacheRead: 0, cacheWrite: 0), events: 1, pricedEvents: 1, estimatedUSD: 1)], by: .newTokens)
        check(byNew.first?.model == "writes", "New tokens sort ignores cache reads")

        // 0.5.359 QA: paused says so, "never $0" lives here, and the legend promises only the line the chart draws.
        check(!P.hasFigure(.cost, pricedEvents: 0) && P.hasFigure(.cost, pricedEvents: 1) && P.hasFigure(.tokens, pricedEvents: 0) && P.hasFigure(.records, pricedEvents: 0), "only the value measure needs a price")
        let noPriceDay = P.Summary(id: "2026-10-05", counts: SessionUsageCounts(input: 5), events: 2, pricedEvents: 0, estimatedUSD: 0)
        check(!P.dayCounted(noPriceDay, measure: .cost) && P.dayCounted(noPriceDay, measure: .tokens), "a day with no price is not counted on value")
        func portion(_ key: String, priced: Int = 1, value: Double = 10) -> P.PeriodPortion { P.PeriodPortion(key: key, pricedEvents: priced, value: value) }
        let fourPeriods = ["2026-01-05", "2026-01-12", "2026-01-19", "2026-01-26"].map { portion($0) }
        check(P.chartAverage(fourPeriods + [portion("", value: 500)], measure: .cost, partial: [], lineChart: false) == 10, "four priced periods draw their average, and a point with no period is not one")
        let threeAndUnpriced = Array(fourPeriods.dropLast()) + [portion("2026-01-26", priced: 0, value: 0)]
        check(P.chartAverage(threeAndUnpriced, measure: .cost, partial: [], lineChart: false) == nil && P.chartAverage(fourPeriods + [portion("2026-02-02", priced: 0, value: 0)], measure: .cost, partial: [], lineChart: false) == 10, "a period with no price stays out of the average")
        check(P.chartAverage(threeAndUnpriced, measure: .tokens, partial: [], lineChart: false) != nil, "on tokens every period counts")
        check(P.chartAverage(fourPeriods, measure: .cost, partial: [], lineChart: true) == nil, "lines draw no average")
        check(P.partialBarsNote(scaleWord: "week", averageDrawn: false) == "Lighter bars cover part of a week." && P.partialBarsNote(scaleWord: "week", averageDrawn: true) == "Lighter bars cover part of a week and are left out of the average.", "the partial note promises the average only when one is drawn")
        let pausedPace = P.monthPace([usageRow("2026-10-01", usd: 30)], now: paceClock("2026-10-10"), timeZone: paceZone, tracking: false)
        check(pausedPace?.projectedUSD == nil && pausedPace?.usd == 30, "a paused month shows its value and no estimate")
        check(P.helperArguments(importNew: true, tracking: false, cursorEnabled: false, cursorNow: false) == ["session-usage", "--read-only"], "paused never imports, whoever asks")
        check(P.helperArguments(importNew: true, tracking: false, cursorEnabled: true, cursorNow: true) == ["session-usage", "--read-only", "--cursor"], "paused never asks Cursor for a sync")
        check(P.helperArguments(importNew: true, tracking: true, cursorEnabled: true, cursorNow: true) == ["session-usage", "--cursor", "--cursor-now"] && P.helperArguments(importNew: false, tracking: true, cursorEnabled: true, cursorNow: false) == ["session-usage", "--read-only", "--cursor"], "tracking imports, and Cursor syncs only when asked")
        check(P.helperArguments(importNew: true, tracking: true, cursorEnabled: false, cursorNow: true) == ["session-usage"], "Cursor off is never named")
        check(P.freshnessLabel(tracking: false, updatedTime: "9:00 AM") == "Paused" && P.freshnessLabel(tracking: true, updatedTime: "9:00 AM") == "Updated 9:00 AM" && P.freshnessLabel(tracking: true, updatedTime: nil) == nil, "a paused page never says Updated")
        check(P.pendingNotes(tracking: false, pendingFiles: 37, feedMessage: "Reading your Cursor usage.").isEmpty, "paused promises no growing totals")
        check(P.pendingNotes(tracking: true, pendingFiles: 37, feedMessage: "Reading your Cursor usage.") == ["Reading older history: 37 files remaining. Totals will grow until it finishes.", "Reading your Cursor usage. Totals will grow until it finishes."] && P.pendingNotes(tracking: true, pendingFiles: 0, feedMessage: nil).isEmpty, "tracking says what is still being read")
        check(P.pausedLine(pendingFiles: 0).hasPrefix("Tracking is paused") && !P.pausedLine(pendingFiles: 0).contains("waiting") && P.pausedLine(pendingFiles: 1).hasSuffix("1 log file is still waiting.") && P.pausedLine(pendingFiles: 37).hasSuffix("37 log files are still waiting."), "the paused line counts what waits")
        check(P.pausedLine(pendingFiles: 0, hasHistory: false) == "Tracking is paused, so no logs are being read." && P.pausedLine(pendingFiles: 2, hasHistory: false).hasSuffix("2 log files are still waiting."), "a paused page with nothing to show mentions no numbers")
        check(!P.emptyWords(tracking: false, hasReport: true).contains("once their logs are read") && !P.emptyWords(tracking: false, hasReport: false).contains("Refresh reads") && P.emptyWords(tracking: false, hasReport: true).contains("resume tracking") && P.emptyWords(tracking: true, hasReport: true).contains("once their logs are read"), "the paused empty page promises only what resuming does")
        let backfilling = SessionUsageCursorFeedStatus(state: .backfilling, message: "Cursor is waiting until tracking resumes.")
        let signingIn = SessionUsageCursorFeedStatus(state: .signIn, message: "Run cursor-agent login in Terminal, then refresh.")
        let outage = SessionUsageCursorFeedStatus(state: .failed, message: "Cursor did not answer.")
        let cliPath = "/fake/.local/bin/cursor-agent"
        check(P.cursorWords(on: true, tracking: false, feed: backfilling, commandLine: cliPath) == P.cursorWaiting && P.cursorWords(on: true, tracking: false, feed: SessionUsageCursorFeedStatus(state: .ready), commandLine: cliPath) == P.cursorWaiting && P.cursorWords(on: true, tracking: false, feed: nil, commandLine: cliPath) == P.cursorWaiting, "a paused Cursor row says it waits")
        check(P.cursorWords(on: true, tracking: true, feed: SessionUsageCursorFeedStatus(state: .ready), commandLine: cliPath) == "Cursor reports no token usage for this account." && P.cursorWords(on: true, tracking: true, feed: nil, commandLine: cliPath) == "Reading your Cursor usage.", "a tracking Cursor row says what it read")
        check(P.cursorWords(on: false, tracking: false, feed: nil, commandLine: cliPath).hasSuffix("it waits until tracking resumes.") && !P.cursorWords(on: false, tracking: true, feed: nil, commandLine: cliPath).contains("waits"), "the paused offer says turning it on only saves the choice")
        check(P.cursorProblem(signingIn, commandLine: cliPath, tracking: true) == signingIn.message && P.cursorProblem(outage, commandLine: nil, tracking: true) == outage.message && P.cursorProblem(backfilling, commandLine: nil, tracking: true) == nil, "the helper's words stand while the command line is there or does not matter")
        let getCLI = P.cursorProblem(signingIn, commandLine: nil, tracking: true) ?? ""
        check(getCLI.contains(P.cursorInstallCommand) && getCLI.hasSuffix("then refresh.") && (P.cursorProblem(SessionUsageCursorFeedStatus(state: .expired), commandLine: nil, tracking: false) ?? "").hasSuffix("then resume tracking."), "no command line says how to get it")
        let cliHome = home.appendingPathComponent("cli home")
        let cliBin = cliHome.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: cliBin, withIntermediateDirectories: true)
        check(P.cursorCommandLine(home: cliHome.path, systemFolders: []) == nil, "no command line on a Mac with only the app")
        try FileManager.default.createDirectory(at: cliBin.appendingPathComponent("cursor-agent"), withIntermediateDirectories: true)
        check(P.cursorCommandLine(home: cliHome.path, systemFolders: []) == nil, "a folder is not the command line")
        try FileManager.default.removeItem(at: cliBin.appendingPathComponent("cursor-agent"))
        FileManager.default.createFile(atPath: cliBin.appendingPathComponent("agent").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])
        check(P.cursorCommandLine(home: cliHome.path, systemFolders: []) == nil, "a file that cannot run is not the command line")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliBin.appendingPathComponent("agent").path)
        check(P.cursorCommandLine(home: cliHome.path, systemFolders: []) == cliBin.appendingPathComponent("agent").path, "its other name counts")
        FileManager.default.createFile(atPath: cliBin.appendingPathComponent("cursor-agent").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let foundCLI = P.cursorCommandLine(home: cliHome.path, systemFolders: [])
        check(foundCLI == cliBin.appendingPathComponent("cursor-agent").path, "the name the copy uses comes first")
        check(P.cursorSignInCommand(cliPath) == "/fake/.local/bin/cursor-agent login" && P.cursorSignInCommand(foundCLI ?? "") == "'\(foundCLI ?? "")' login", "the sign-in command runs from any Terminal, spaces and all")
        // Long calendars. 524 is the grid at the narrowest page: 716 of content less the names and the margin.
        func historyWeeks(_ count: Int) -> [P.CalendarWeek] {
            let monday = SessionUsageDay("2026-10-26")!
            return P.calendarWeeks((0..<count).map { usageRow(monday.adding(-7 * $0).key, usd: 1) }, bounds: nil, today: "2026-10-31")
        }
        check(historyWeeks(105).count == 105, "the long fixture has the weeks it asks for")
        let twoYears = P.calendarFit(historyWeeks(105), width: 524)
        check(twoYears.weeks.count == 105 && twoYears.spacing == 1 && twoYears.cell >= P.calendarMinimumCell, "two years fit at the minimum cell, gaps tightened")
        check(P.calendarFit(historyWeeks(52), width: 524).spacing == 3 && P.calendarFit(historyWeeks(53), width: 524).spacing == 1, "a year keeps its gaps, and past that they tighten")
        let longest = historyWeeks(180)
        let recent = P.calendarFit(longest, width: 524)
        check(recent.weeks.count == 105 && recent.weeks.last?.id == longest.last?.id && recent.weeks.first?.id == longest[75].id, "the most recent weeks that fit stay")
        check(recent.weeks.first?.monthLabel?.hasSuffix(" " + String(recent.weeks[0].id.prefix(4))) == true, "a cut calendar's first column says where it starts")
        for (count, width) in [(180, 524.0), (300, 524.0), (300, 964.0), (60, 100.0), (2, 2.0)] {
            check(P.calendarFit(historyWeeks(count), width: width).cell >= (width >= P.calendarMinimumCell ? P.calendarMinimumCell : 0), "no square goes under the minimum")
        }
        for (count, width) in [(4, 524.0), (13, 524.0), (30, 524.0), (52, 524.0), (53, 524.0), (105, 524.0), (180, 524.0), (52, 964.0), (105, 964.0), (300, 964.0), (105, 1500.0)] {
            let fit = P.calendarFit(historyWeeks(count), width: width)
            let pitch = (width + fit.spacing) / Double(fit.weeks.count)
            var end = -Double.infinity
            for (index, week) in fit.weeks.enumerated() {
                guard let label = week.monthLabel else { continue }
                check(Double(index) * pitch >= end, "labels never overlap")
                end = Double(index) * pitch + P.calendarLabelWidth(label)
                check(end <= width + 8, "the last label stays out of the average column")
            }
            check(fit.weeks.contains { $0.monthLabel != nil }, "a calendar always names at least one month")
        }
        // The two labels with a year only compete with each other: Oct 2024 starts the row, and Jan 2025 sits too close to it.
        let yearsKept = P.calendarFit(historyWeeks(105), width: 524).weeks.compactMap(\.monthLabel).filter { $0.contains(" ") }
        check(yearsKept == ["Oct 2024", "Jan 2026"], "a month never pushes out a year")
        check(P.calendarFit(historyWeeks(5), width: 1000).carriesNumbers && !P.calendarFit(historyWeeks(30), width: 524).carriesNumbers, "only a wide square carries its number")
        // A month that starts in the last column has no room for its name before the average column.
        let lateStart = P.calendarWeeks([usageRow("2025-11-03", usd: 1)], bounds: nil, today: "2026-11-02")
        check(lateStart.last?.monthLabel == "Nov" && P.calendarFit(lateStart, width: 524).weeks.last?.monthLabel == nil, "the last label stays out of the average column")
        let unmeasured = P.calendarFit(longest, width: 0)
        check(unmeasured.weeks.count == 180 && !unmeasured.carriesNumbers, "before it is measured everything stays")

        // A prior window is complete only when every tool in the selection reaches back that far.
        let oldCursor = SessionUsageBucket(day: "2025-07-01", provider: "Cursor", model: "m", counts: SessionUsageCounts(input: 1, output: 1, cacheRead: 1, cacheWrite: 1), events: 1, pricedEvents: 1, estimatedUSD: 1)
        let newClaude = SessionUsageBucket(day: "2026-10-20", provider: "Anthropic", model: "m", counts: SessionUsageCounts(input: 1, output: 1, cacheRead: 1, cacheWrite: 1), events: 1, pricedEvents: 1, estimatedUSD: 1)
        let priorCursor = SessionUsageBucket(day: "2026-09-20", provider: "Cursor", model: "m", counts: SessionUsageCounts(input: 1, output: 1, cacheRead: 1, cacheWrite: 1), events: 1, pricedEvents: 1, estimatedUSD: 1)
        let newCursor = SessionUsageBucket(day: "2026-10-21", provider: "Cursor", model: "m", counts: SessionUsageCounts(input: 1, output: 1, cacheRead: 1, cacheWrite: 1), events: 1, pricedEvents: 1, estimatedUSD: 1)
        let everyone = [oldCursor, priorCursor, newCursor, newClaude]
        check(P.comparePeriod(allRows: everyone, selectedRows: [newClaude, newCursor], period: "Last 30 days", now: monday, timeZone: chicago).partialPriorHistory, "old Cursor history cannot vouch for Claude Code's prior window")
        check(!P.comparePeriod(allRows: everyone, selectedRows: [newCursor], period: "Last 30 days", provider: "Cursor", now: monday, timeZone: chicago).partialPriorHistory, "a tool with old history has a complete prior window")

        // The Cursor feed: parsing, privacy, paging, failure and resume, all against fakes.
        let feedHome = home.appendingPathComponent("feed")
        try FileManager.default.createDirectory(at: feedHome, withIntermediateDirectories: true)
        let feedDB = feedHome.appendingPathComponent("feed.sqlite")
        let feed = try SessionUsageCollector(home: feedHome, database: feedDB, timeZone: TimeZone(identifier: "America/Chicago")!)
        func feedRow(_ id: String?, _ stamp: String = "1793372502953", model: String = "grok-4.7", input: Int = 10, cents: Double? = 250) -> [String: Any] {
            var usage: [String: Any] = ["inputTokens": input, "outputTokens": 5, "cacheReadTokens": 1000, "cacheWriteTokens": 2]
            if let cents { usage["totalCents"] = cents }
            var row: [String: Any] = ["timestamp": stamp, "model": model, "tokenUsage": usage, "conversationId": "SECRET_CONVERSATION", "owningUser": "SECRET_OWNER", "userEmail": "secret@example.com"]
            if let id { row["usageEventId"] = id }
            return row
        }
        func page(_ rows: [[String: Any]], total: Int? = nil) -> Data { try! JSONSerialization.data(withJSONObject: ["totalUsageEventsCount": total ?? rows.count, "usageEventsDisplay": rows]) }
        let feedIso = ISO8601DateFormatter()
        let parsed0 = SessionUsageCollector.cursorEvent(feedRow("event-1"), iso: feedIso)!
        check(parsed0.provider == "Cursor" && parsed0.counts.input == 10 && parsed0.counts.output == 5 && parsed0.counts.cacheRead == 1000 && parsed0.counts.cacheWrite == 2, "feed counts map to disjoint categories")
        check(parsed0.reportedUSD == 2.5, "feed cost is its reported cents as dollars")
        check(SessionUsageCollector.cursorEvent(feedRow("x", "not-a-time"), iso: feedIso) == nil && SessionUsageCollector.cursorEvent(["model": "m"], iso: feedIso) == nil, "a row without a time is dropped")
        check(SessionUsageCollector.cursorEvent(feedRow("a"), iso: feedIso)!.id != SessionUsageCollector.cursorEvent(feedRow("b"), iso: feedIso)!.id, "the event id is the identity")
        check(SessionUsageCollector.cursorEvent(feedRow(nil), iso: feedIso)!.id == SessionUsageCollector.cursorEvent(feedRow(nil), iso: feedIso)!.id, "old rows without an id still dedupe")
        check(SessionUsageCollector.cursorEvent(feedRow("n", cents: nil), iso: feedIso)!.reportedUSD == nil, "a row with no cost stays unpriced")
        let sessionish = "h." + Data(#"{"exp":100}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        check(SessionUsageCollector.cursorTokenExpired(sessionish, now: Date(timeIntervalSince1970: 200)), "an expired sign-in is not sent")
        check(!SessionUsageCollector.cursorTokenExpired(sessionish, now: Date(timeIntervalSince1970: 50)), "a current sign-in is used")
        check(!SessionUsageCollector.cursorTokenExpired("opaque", now: Date()), "a token that is not a JWT is left for the server")

        let t0 = Date(timeIntervalSince1970: 1_793_400_000)
        // Off means no request at all: refresh never reaches the feed, and the report says off.
        var feedCalls = 0
        check(try feed.refresh(cursorEnabled: false).cursorFeed?.state == .off, "the feed is off until turned on")
        check(try feed.refresh(cursorEnabled: false).buckets.isEmpty, "off counts nothing")

        // Missing and expired sign-ins never reach the network, and say what to do.
        try feed.syncCursorFeed(force: true, now: t0, readToken: { _ in .missing }, fetch: { _, _, _, _ in feedCalls += 1; return .init(status: 200, body: page([])) })
        check(feedCalls == 0, "no sign-in, no request")
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .signIn, "a missing sign-in is reported")
        try feed.syncCursorFeed(force: true, now: t0, readToken: { _ in .expired }, fetch: { _, _, _, _ in feedCalls += 1; return .init(status: 200, body: page([])) })
        check(try feedCalls == 0 && feed.refresh(cursorEnabled: true).cursorFeed?.state == .expired, "an expired sign-in is reported without a request")
        try feed.syncCursorFeed(force: false, now: t0.addingTimeInterval(60), readToken: { _ in feedCalls += 1; return .blocked(exit: 51) }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
        check(feedCalls == 0, "a failed sign-in read backs off until forced")

        // A full page then a short page drains, stores content-free rows, and dedupes on the next pass.
        var seenPages: [Int] = [], seenTokens: Set<String> = [], seenStarts: [Int64] = [], seenEnds: [Int64] = []
        let full = (0..<SessionUsageCollector.cursorPageSize).map { feedRow("full-\($0)") }
        let replies = [1: page(full, total: full.count + 2), 2: page([feedRow("last"), feedRow("zero", input: 0, cents: 0)], total: full.count + 2)]
        func scripted(_ token: String, _ start: Int64, _ end: Int64, _ number: Int) -> SessionUsageCollector.CursorFeedReply {
            seenPages.append(number); seenTokens.insert(token); seenStarts.append(start); seenEnds.append(end)
            return .init(status: 200, body: replies[number] ?? page([]))
        }
        try feed.syncCursorFeed(force: true, now: t0, readToken: { _ in .token("SECRET_TOKEN") }, fetch: scripted)
        check(seenPages == [1, 2] && seenTokens == ["SECRET_TOKEN"], "pages until the reported total is read")
        let afterFeed = try feed.refresh(cursorEnabled: true)
        let cursorRows = afterFeed.buckets.filter { $0.provider == "Cursor" }
        check(cursorRows.reduce(0) { $0 + $1.events } == SessionUsageCollector.cursorPageSize + 2, "every row with tokens is stored")
        check(cursorRows.reduce(0) { $0 + $1.pricedEvents } == SessionUsageCollector.cursorPageSize + 2 && abs(cursorRows.reduce(0) { $0 + $1.estimatedUSD } - Double(SessionUsageCollector.cursorPageSize + 1) * 2.5) < 0.001, "reported cost is stored as priced value")
        check(afterFeed.cursorFeed?.state == .ready && afterFeed.cursorFeed?.lastSuccessAt != nil, "a drained feed is ready")
        for suffix in ["", "-wal", "-shm"] {
            if let raw = try? Data(contentsOf: URL(fileURLWithPath: feedDB.path + suffix)) {
                let text = String(decoding: raw, as: UTF8.self)
                check(!text.contains("SECRET_"), "the database holds no token, conversation or owner")
                check(!text.contains("secret@example.com"), "the database holds no email")
            }
        }
        // Inside the quiet interval nothing is asked; after it, only a recent window with overlap, and no double count.
        seenPages = []
        try feed.syncCursorFeed(force: false, now: t0.addingTimeInterval(60), readToken: { _ in .token("t") }, fetch: scripted)
        check(seenPages.isEmpty, "the feed stays quiet between syncs")
        seenPages = []; seenStarts = []
        try feed.syncCursorFeed(force: false, now: t0.addingTimeInterval(700), readToken: { _ in .token("t") }, fetch: { token, start, end, number in
            scripted(token, start, end, number == 1 ? 2 : number)
        })
        check(seenStarts.first == Int64(t0.timeIntervalSince1970 * 1000) - 2*86_400_000, "a live sync rereads two days past its watermark")
        check(try feed.refresh(cursorEnabled: true).buckets.filter { $0.provider == "Cursor" }.reduce(0) { $0 + $1.events } == SessionUsageCollector.cursorPageSize + 2, "rereading never double counts")

        // Failure keeps history and backs off; a rejected sign-in says so; a changed answer never counts as finished.
        let keptEvents = try feed.refresh(cursorEnabled: true).buckets.reduce(0) { $0 + $1.events }
        let t1 = t0.addingTimeInterval(4000)
        seenPages = []
        try feed.syncCursorFeed(force: true, now: t1, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 500, body: nil) })
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .failed, "a server failure is reported")
        try feed.syncCursorFeed(force: false, now: t1.addingTimeInterval(60), readToken: { _ in .token("t") }, fetch: { t, s, e, n in scripted(t, s, e, n) })
        check(seenPages.isEmpty, "a failure backs off instead of retrying every pass")
        try feed.syncCursorFeed(force: true, now: t1, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 0, body: nil) })
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .failed, "no answer at all is a failure")
        try feed.syncCursorFeed(force: true, now: t1, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 401, body: nil) })
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .expired, "a rejected sign-in asks for a new one")
        // The real feed answers an empty window with {} and a page past the end with only a total.
        try feed.syncCursorFeed(force: true, now: t1, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 200, body: Data("{}".utf8)) })
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .ready, "an empty answer is a quiet window, not a changed feed")
        try feed.syncCursorFeed(force: true, now: t1, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 200, body: Data(#"{"totalUsageEventsCount":0}"#.utf8)) })
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .ready, "a total of zero with no list is a quiet window")
        try feed.syncCursorFeed(force: true, now: t1, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 200, body: page([["model": "m", "newShape": 1]])) })
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .changed, "rows the feed can no longer read are reported, not treated as no usage")
        try feed.syncCursorFeed(force: true, now: t1, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 200, body: Data("not json".utf8)) })
        check(try feed.refresh(cursorEnabled: true).cursorFeed?.state == .changed, "an unreadable answer is reported")
        check(try feed.refresh(cursorEnabled: true).buckets.reduce(0) { $0 + $1.events } == keptEvents, "failures keep what was counted")
        // Turning the feed off keeps history and reports off, even with a problem on record.
        let offReport = try feed.refresh(cursorEnabled: false)
        check(offReport.cursorFeed?.state == .off && offReport.buckets.reduce(0) { $0 + $1.events } == keptEvents, "off keeps history")

        // A backfill cut by its budget resumes at the next page with the same end date.
        let resumeHome = home.appendingPathComponent("resume")
        try FileManager.default.createDirectory(at: resumeHome, withIntermediateDirectories: true)
        let resume = try SessionUsageCollector(home: resumeHome, database: resumeHome.appendingPathComponent("r.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        seenPages = []; seenEnds = []
        let longPage = page((0..<SessionUsageCollector.cursorPageSize).map { feedRow("long-\($0)") }, total: SessionUsageCollector.cursorPageSize + 1)
        let lastPage = page([feedRow("long-last")], total: SessionUsageCollector.cursorPageSize + 1)
        try resume.syncCursorFeed(force: true, now: t0, seconds: 0.001, readToken: { _ in .token("t") }, fetch: { _, _, end, number in
            seenPages.append(number); seenEnds.append(end); Thread.sleep(forTimeInterval: 0.01); return .init(status: 200, body: longPage)
        })
        check(try seenPages == [1] && resume.refresh(cursorEnabled: true).cursorFeed?.pending == true, "a budget cut leaves the backfill pending")
        try resume.syncCursorFeed(force: false, now: t0.addingTimeInterval(15), readToken: { _ in .token("t") }, fetch: { _, _, end, number in
            seenPages.append(number); seenEnds.append(end); return .init(status: 200, body: lastPage)
        })
        check(seenPages == [1, 2], "the backfill resumes at the next page")
        check(Set(seenEnds).count == 1, "backfill pages keep one end date so new usage cannot shift them")
        check(try resume.refresh(cursorEnabled: true).cursorFeed?.state == .ready, "the resumed backfill finishes")
        // A live window cut by its budget continues too, with the same dates, so older rows in it are reached.
        seenPages = []; seenStarts = []; seenEnds = []
        let t2 = t0.addingTimeInterval(90 * 86_400)
        try resume.syncCursorFeed(force: false, now: t2, seconds: 0.001, readToken: { _ in .token("t") }, fetch: { _, start, end, number in
            seenPages.append(number); seenStarts.append(start); seenEnds.append(end); Thread.sleep(forTimeInterval: 0.01); return .init(status: 200, body: longPage)
        })
        check(try seenPages == [1] && resume.refresh(cursorEnabled: true).cursorFeed?.pending == true, "a long live window stays pending")
        try resume.syncCursorFeed(force: false, now: t2.addingTimeInterval(1), readToken: { _ in .token("t") }, fetch: { _, start, end, number in
            seenPages.append(number); seenStarts.append(start); seenEnds.append(end); return .init(status: 200, body: lastPage)
        })
        check(seenPages == [1, 2] && Set(seenStarts).count == 1 && Set(seenEnds).count == 1, "a long live window continues at its next page with the same dates")
        check(seenStarts[0] < Int64(t0.timeIntervalSince1970 * 1000), "a long live window reaches back past its gap")
        // An empty page before the total is reached never finishes a run: older rows would be lost for good.
        let gapHome = home.appendingPathComponent("gap")
        try FileManager.default.createDirectory(at: gapHome, withIntermediateDirectories: true)
        let gap = try SessionUsageCollector(home: gapHome, database: gapHome.appendingPathComponent("g.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        var gapPages: [Int] = []
        try gap.syncCursorFeed(force: true, now: t0, readToken: { _ in .token("t") }, fetch: { _, _, _, number in
            gapPages.append(number)
            return .init(status: 200, body: number == 1 ? page((0..<SessionUsageCollector.cursorPageSize).map { feedRow("g-\($0)") }, total: 700) : Data(#"{"totalUsageEventsCount":700}"#.utf8))
        })
        check(try gapPages == [1, 2] && gap.refresh(cursorEnabled: true).cursorFeed?.state == .failed, "an empty page before the total is reported, and the run stays open")
        gapPages = []
        try gap.syncCursorFeed(force: true, now: t0.addingTimeInterval(1), readToken: { _ in .token("t") }, fetch: { _, _, _, number in
            gapPages.append(number); return .init(status: 200, body: page((0..<200).map { feedRow("h-\($0)") }, total: 700))
        })
        check(try gapPages == [2] && gap.refresh(cursorEnabled: true).cursorFeed?.state == .ready, "the run retries the page that came back empty and then finishes")
        // A page that keeps failing closes the run, so new usage is still read.
        let stuckHome = home.appendingPathComponent("stuck")
        try FileManager.default.createDirectory(at: stuckHome, withIntermediateDirectories: true)
        let stuck = try SessionUsageCollector(home: stuckHome, database: stuckHome.appendingPathComponent("k.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        var stuckPages: [Int] = []
        func stuckReply(_ number: Int) -> SessionUsageCollector.CursorFeedReply {
            stuckPages.append(number)
            return number == 1 ? .init(status: 200, body: page((0..<SessionUsageCollector.cursorPageSize).map { feedRow("k-\($0)") }, total: 5000)) : .init(status: 500, body: nil)
        }
        for attempt in 0..<5 {
            try stuck.syncCursorFeed(force: true, now: t0.addingTimeInterval(Double(attempt)), readToken: { _ in .token("t") }, fetch: { _, _, _, number in stuckReply(number) })
        }
        check(stuckPages == [1, 2, 2, 2, 2, 1, 2], "a page that keeps failing closes the run and starts again at the newest page")
        // An automatic pass waits patiently for Keychain only while a run is open.
        var patience: [Bool] = []
        let patientHome = home.appendingPathComponent("patient")
        try FileManager.default.createDirectory(at: patientHome, withIntermediateDirectories: true)
        let patient = try SessionUsageCollector(home: patientHome, database: patientHome.appendingPathComponent("p.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        try patient.syncCursorFeed(force: false, now: t0, seconds: 0.001, readToken: { wait in patience.append(wait); return .token("t") }, fetch: { _, _, _, _ in
            Thread.sleep(forTimeInterval: 0.01); return .init(status: 200, body: longPage)
        })
        try patient.syncCursorFeed(force: false, now: t0.addingTimeInterval(15), readToken: { wait in patience.append(wait); return .token("t") }, fetch: { _, _, _, _ in .init(status: 200, body: lastPage) })
        try patient.syncCursorFeed(force: true, now: t0.addingTimeInterval(1000), readToken: { wait in patience.append(wait); return .blocked(exit: 51) }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
        check(patience == [false, true, true], "a run in progress and a manual Refresh wait patiently for Keychain")
        var askedAgain = false
        try patient.syncCursorFeed(force: false, now: t0.addingTimeInterval(1000 + 7*86_400), readToken: { _ in askedAgain = true; return .blocked(exit: 51) }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
        check(!askedAgain, "an unanswered Keychain prompt is not repeated by automatic passes")
        check(try feed.refresh(cursorEnabled: true, cursorSyncFailed: true).cursorFeed?.state == .failed, "a sync that threw is reported, so the loop stops hurrying")
        // Keychain: a real denial stops asking, no answer retries soon, and either way the cause reaches a local log.
        let fakeTools = home.appendingPathComponent("fake-security")
        try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        func fakeSecurity(_ body: String) -> String {
            let path = fakeTools.appendingPathComponent(UUID().uuidString).path
            FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8), attributes: [.posixPermissions: 0o755])
            return path
        }
        check(SessionUsageCollector.keychainRead(tool: fakeSecurity("exit 51"), seconds: 5) == .blocked(exit: 51) && SessionUsageCollector.keychainRead(tool: fakeSecurity("exit 128"), seconds: 5) == .blocked(exit: 128), "a denial keeps its exit code")
        check(SessionUsageCollector.keychainRead(tool: fakeSecurity("exit 44"), seconds: 5) == .missing, "no item means no sign-in")
        check(SessionUsageCollector.keychainRead(tool: fakeSecurity("printf 'abc.def'; exit 0"), seconds: 5) == .token("abc.def"), "a good read is the token")
        check(SessionUsageCollector.keychainRead(tool: fakeSecurity("exit 36"), seconds: 5) == .unavailable(.exit(36)), "an odd exit is no answer")
        check(SessionUsageCollector.keychainRead(tool: fakeSecurity("exec sleep 5"), seconds: 0.2) == .unavailable(.timedOut), "a timeout is no answer")
        check(SessionUsageCollector.keychainRead(tool: fakeTools.appendingPathComponent("not-there").path, seconds: 5) == .unavailable(.launchFailed), "a launch failure is no answer")
        let keyHome = home.appendingPathComponent("keychain")
        try FileManager.default.createDirectory(at: keyHome, withIntermediateDirectories: true)
        let keyLog = keyHome.appendingPathComponent("cursor-feed.log")
        let keyFeed = try SessionUsageCollector(home: keyHome, database: keyHome.appendingPathComponent("k.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        var keyAsks = 0
        func keyPass(_ seconds: TimeInterval, _ answer: SessionUsageCollector.CursorFeedToken, force: Bool = false) throws {
            try keyFeed.syncCursorFeed(force: force, now: t0.addingTimeInterval(seconds), readToken: { _ in keyAsks += 1; return answer }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
        }
        try keyPass(0, .unavailable(.launchFailed))
        let afterMiss = try keyFeed.refresh(cursorEnabled: true).cursorFeed?.state
        check(afterMiss == .keychainBusy && keyAsks == 1, "no answer from Keychain is reported as that")
        check(try keyFeed.refresh(cursorEnabled: true).cursorFeed?.isProblem == true, "no answer from Keychain shows on the page")
        keyAsks = 0
        try keyPass(840, .unavailable(.launchFailed))
        check(keyAsks == 0, "no answer waits a little before the next try")
        try keyPass(960, .unavailable(.exit(36)))
        check(keyAsks == 1, "no answer from Keychain retries within minutes")
        var keyWords = (try? String(contentsOf: keyLog, encoding: .utf8)) ?? ""
        check(keyWords.contains("Keychain could not start, 1 in a row") && keyWords.contains("Keychain exit 36, 2 in a row"), "the cause reaches the local log")
        // A good read starts the count over, and the sign-in never reaches the log, even on a rejected request.
        let keyToken = "SECRET_SIGN_IN_NEVER_LOGGED"
        let dayOne: TimeInterval = 86_400, dayTwo: TimeInterval = 172_800, dayFour: TimeInterval = 345_600
        try keyPass(dayOne, .token(keyToken))
        try keyPass(dayTwo, .unavailable(.timedOut))
        keyWords = (try? String(contentsOf: keyLog, encoding: .utf8)) ?? ""
        check(keyWords.contains("Keychain timed out, 1 in a row"), "a good read starts the count over")
        keyAsks = 0
        let secondTry = dayTwo + 960, thirdTry = secondTry + 1860, fourthTry = thirdTry + 3660
        try keyPass(secondTry, .unavailable(.timedOut))
        try keyPass(thirdTry, .unavailable(.timedOut))
        let afterThree = try keyFeed.refresh(cursorEnabled: true).cursorFeed?.state
        check(keyAsks == 2 && afterThree == .keychainBusy, "a timeout retries soon")
        try keyPass(fourthTry, .unavailable(.timedOut))
        check(try keyFeed.refresh(cursorEnabled: true).cursorFeed?.state == .blocked, "four timeouts in a row stop asking")
        keyAsks = 0
        try keyPass(dayFour, .unavailable(.timedOut))
        check(keyAsks == 0, "after that an automatic pass does not bring the prompt back")
        try keyPass(dayFour, .blocked(exit: 128), force: true)
        keyWords = (try? String(contentsOf: keyLog, encoding: .utf8)) ?? ""
        check(keyAsks == 1 && keyWords.contains("Keychain denied, exit 128"), "the denial reaches the local log")
        check(!keyWords.contains(keyToken), "the sign-in never reaches the log")
        // Only timeouts in a row stop asking. Three odd exits and a timeout are not four timeouts, and any other answer breaks a run of them.
        func mixRun(_ answers: [SessionUsageCollector.CursorFeedToken]) throws -> (state: SessionUsageCursorFeedStatus.State?, asks: Int) {
            let dir = home.appendingPathComponent("keychain-mixed-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let feed = try SessionUsageCollector(home: dir, database: dir.appendingPathComponent("m.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
            var asks = 0
            for (index, answer) in answers.enumerated() {
                try feed.syncCursorFeed(force: false, now: t0.addingTimeInterval(Double(index + 1) * 86_400), readToken: { _ in asks += 1; return answer }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
            }
            return (try feed.refresh(cursorEnabled: true).cursorFeed?.state, asks)
        }
        let timeout = SessionUsageCollector.CursorFeedToken.unavailable(.timedOut), oddExit = SessionUsageCollector.CursorFeedToken.unavailable(.exit(36)), noStart = SessionUsageCollector.CursorFeedToken.unavailable(.launchFailed)
        let mixed = try mixRun([timeout, oddExit, timeout, oddExit, timeout, oddExit, timeout])
        check(mixed.state == .keychainBusy && mixed.asks == 7, "four timeouts with odd exits between them keep retrying")
        check(try mixRun([timeout, timeout, timeout]).state == .keychainBusy, "three timeouts in a row are not four")
        check(try mixRun([timeout, timeout, timeout, timeout]).state == .blocked, "four timeouts in a row stop asking")
        check(try mixRun([timeout, timeout, timeout, noStart, timeout]).state == .keychainBusy, "a launch failure breaks a run of timeouts")
        check(try mixRun([timeout, timeout, timeout, .token("SECRET_SIGN_IN_NEVER_LOGGED"), timeout]).state == .keychainBusy, "a good read starts the timeouts over")
        // A history another command holds comes out of a Cursor sync as a busy Failure, which the helper does not report as Cursor not answering.
        let syncDir = home.appendingPathComponent("cursor-sync-busy")
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let syncDB = syncDir.appendingPathComponent("s.sqlite")
        let syncFeed = try SessionUsageCollector(home: syncDir, database: syncDB, timeZone: TimeZone(identifier: "America/Chicago")!)
        var syncHolder: OpaquePointer?
        check(sqlite3_open(syncDB.path, &syncHolder) == SQLITE_OK && sqlite3_exec(syncHolder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "the test holds the write lock during a Cursor sync")
        var syncWasBusy = false
        do { try syncFeed.syncCursorFeed(force: true, now: t0, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) }) }
        catch let failure as SessionUsageCollector.Failure { syncWasBusy = failure.busy } catch {}
        sqlite3_exec(syncHolder, "COMMIT", nil, nil, nil); sqlite3_close(syncHolder)
        check(syncWasBusy, "a history another command holds comes out of a Cursor sync as busy")
        let oversized = String(repeating: "x", count: 70_000)
        try oversized.write(to: keyLog, atomically: true, encoding: .utf8)
        try keyPass(dayFour, .unavailable(.launchFailed), force: true)
        keyWords = (try? String(contentsOf: keyLog, encoding: .utf8)) ?? ""
        check(keyWords.utf8.count < 1000 && keyWords.contains("could not start"), "the log stays small")
        // A paused pass never syncs, so its words cannot lean on a refresh or a retry.
        func pausedWords(_ answer: SessionUsageCollector.CursorFeedToken, status: Int = 200) throws -> (String?, String?) {
            let wordsHome = home.appendingPathComponent("words-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: wordsHome, withIntermediateDirectories: true)
            let words = try SessionUsageCollector(home: wordsHome, database: wordsHome.appendingPathComponent("w.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
            try words.syncCursorFeed(force: true, now: t0, readToken: { _ in answer }, fetch: { _, _, _, _ in .init(status: status, body: nil) })
            return (try words.refresh(maxBytes: 0, cursorEnabled: true, readOnly: true).cursorFeed?.message, try words.refresh(maxBytes: 0, cursorEnabled: true).cursorFeed?.message)
        }
        for (answer, status) in [(SessionUsageCollector.CursorFeedToken.missing, 200), (.expired, 200), (.blocked(exit: 51), 200), (.unavailable(.launchFailed), 200), (.token("t"), 500)] {
            let (paused, tracking) = try pausedWords(answer, status: status)
            let lowered = (paused ?? "").lowercased()
            check(paused != tracking && lowered.contains("resume") && !lowered.contains("then refresh") && !lowered.hasSuffix("cos will try again."), "a paused pass never promises a refresh")
        }
        let unstarted = try SessionUsageCollector(home: home, database: home.appendingPathComponent("unstarted.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        check(try unstarted.refresh(maxBytes: 0, cursorEnabled: true, readOnly: true).cursorFeed?.message == "Cursor is waiting until tracking resumes.", "a paused Cursor that never ran is waiting, not reading")
        check(try unstarted.refresh(maxBytes: 0, cursorEnabled: true).cursorFeed?.message == "Reading your Cursor usage.", "a Cursor that never ran is reading")

        // Compressed Codex logs, against real .jsonl.zst files made here by the same Node that reads them.
        // COS_USAGE_TEST_NODE names one binary, such as the bundled one, and then only that binary is used.
        let namedNode = ProcessInfo.processInfo.environment["COS_USAGE_TEST_NODE"]
        let zstNodes = namedNode.map { [$0] } ?? (["/opt/homebrew/bin/node", "/usr/local/bin/node"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { $0 + "/node" }).filter { FileManager.default.isExecutableFile(atPath: $0) }
        var compressedChecksSkipped = false
        if let zstNode = SessionUsageCollector.compressedDecoder(zstNodes) {
            let zstRoot = home.appendingPathComponent("zst")
            try FileManager.default.createDirectory(at: zstRoot, withIntermediateDirectories: true)
            /// Compresses each part as its own frame, so one part is the ordinary single-frame file.
            func writeZst(_ parts: [String], to file: URL, keep: Int? = nil) throws {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                var made = Data()
                for part in parts {
                    let input = zstRoot.appendingPathComponent(UUID().uuidString), output = zstRoot.appendingPathComponent(UUID().uuidString)
                    try part.write(to: input, atomically: true, encoding: .utf8)
                    let maker = Process()
                    maker.executableURL = URL(fileURLWithPath: zstNode)
                    maker.arguments = ["-e", "const f=require('fs'),z=require('zlib');f.writeFileSync(process.argv[2],z.zstdCompressSync(f.readFileSync(process.argv[1])))", input.path, output.path]
                    try maker.run(); maker.waitUntilExit()
                    check(maker.terminationStatus == 0, "the fixture compresses")
                    made.append(try Data(contentsOf: output))
                }
                try (keep.map { made.prefix($0) } ?? made).write(to: file)
            }
            let noise = String(repeating: "SECRET_PROMPT_NEVER_STORE ", count: 200)
            func rolloutLines(_ steps: Int) throws -> [String] {
                var lines = [try line(["type": "session_meta", "payload": ["id": "zst-one", "model_provider": "openai"]]), try line(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]])]
                for step in 1...steps {
                    lines.append(try line(["type": "response_item", "payload": ["text": noise]]))
                    lines.append(try line(codex(step * 100, step * 10, 0, 100, String(format: "2026-10-%02dT12:00:00Z", 1 + step % 27))))
                }
                return lines
            }
            func zstLedger(_ name: String, nodes: [String]? = nil) throws -> (SessionUsageCollector, URL) {
                let place = zstRoot.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: place.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
                let ledger = try SessionUsageCollector(home: place, database: place.appendingPathComponent("z.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
                ledger.compressedLogNodes = nodes ?? [zstNode]
                return (ledger, place.appendingPathComponent(".codex/sessions"))
            }
            func totals(_ report: SessionUsageReport) -> [String] {
                report.buckets.map { "\($0.day) \($0.provider) \($0.model) \($0.counts.total) \($0.events) \($0.pricedEvents)" }
            }
            let steps = try rolloutLines(40)
            let whole = steps.joined()
            // The reference: the same rows read as a plain log.
            let (plainLedger, plainFolder) = try zstLedger("plain")
            try whole.write(to: plainFolder.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
            let reference = try plainLedger.refresh()
            check(reference.buckets.count > 1 && reference.pendingFiles == 0, "the compressed fixture has usage to compare")
            let (zipLedger, zipFolder) = try zstLedger("compressed")
            try writeZst([whole], to: zipFolder.appendingPathComponent("rollout.jsonl.zst"))
            let unread = try zipLedger.refresh(maxBytes: 0)
            check(unread.buckets.isEmpty && unread.pendingFiles == 1 && unread.unreadableFiles == 0, "a read-only pass reads no compressed log")
            let compressedRead = try zipLedger.refresh()
            check(totals(compressedRead) == totals(reference), "a compressed rollout is read")
            check(compressedRead.buckets.allSatisfy { $0.provider == "OpenAI" && $0.model == "gpt-6.1-sol" }, "the provider and model reach the compressed read")
            let zipDatabase = try Data(contentsOf: zipFolder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("z.sqlite"))
            check(zipDatabase.range(of: Data("SECRET_PROMPT".utf8)) == nil, "no log text reaches the ledger")
            // Finished means finished: with no decoder there is nothing left to want one for.
            zipLedger.compressedLogNodes = []
            let finished = try zipLedger.refresh()
            check(finished.pendingFiles == 0 && finished.unreadableFiles == 0 && totals(finished) == totals(reference), "a finished compressed log is not read again")
            // A rollout read as .jsonl and later compressed: the same events, not new ones.
            let (movedLedger, movedFolder) = try zstLedger("moved")
            try whole.write(to: movedFolder.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
            _ = try movedLedger.refresh()
            try FileManager.default.removeItem(at: movedFolder.appendingPathComponent("rollout.jsonl"))
            try writeZst([whole], to: movedFolder.appendingPathComponent("rollout.jsonl.zst"))
            check(totals(try movedLedger.refresh()) == totals(reference), "a rollout read as plain then compressed is not counted twice")
            // Read while it was still growing, then compressed whole: only the rest is new.
            let (partLedger, partFolder) = try zstLedger("part")
            try steps.prefix(steps.count / 2 + 1).joined().write(to: partFolder.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
            _ = try partLedger.refresh()
            try FileManager.default.removeItem(at: partFolder.appendingPathComponent("rollout.jsonl"))
            try writeZst([whole], to: partFolder.appendingPathComponent("rollout.jsonl.zst"))
            check(totals(try partLedger.refresh()) == totals(reference), "a rollout read part way then compressed adds only the rest")
            // Both at once.
            let (bothLedger, bothFolder) = try zstLedger("both")
            try whole.write(to: bothFolder.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
            try writeZst([whole], to: bothFolder.appendingPathComponent("rollout.jsonl.zst"))
            check(totals(try bothLedger.refresh()) == totals(reference), "a rollout present both ways is one rollout")
            // A byte budget reads it in slices, resuming where the last pass stopped, and arrives at the same totals.
            let (sliceLedger, sliceFolder) = try zstLedger("slices")
            try writeZst([whole], to: sliceFolder.appendingPathComponent("rollout.jsonl.zst"))
            var sliced = try sliceLedger.refresh(maxBytes: 64)
            let firstSlice = sliced.buckets.reduce(0) { $0 + $1.events }
            var slicePasses = 1
            while sliced.pendingFiles > 0 && slicePasses < 100 {
                sliced = try sliceLedger.refresh(maxBytes: 64)
                slicePasses += 1
            }
            check(firstSlice < reference.buckets.reduce(0) { $0 + $1.events } && slicePasses > 2 && slicePasses < 100 && sliced.pendingFiles == 0 && totals(sliced) == totals(reference), "a small budget reads a compressed log in slices")
            // That read comes out of the pass, so a second log waits for the next one rather than having the budget again.
            let (chargeLedger, chargeFolder) = try zstLedger("charge")
            for name in ["one", "two"] { try writeZst([whole], to: chargeFolder.appendingPathComponent("\(name).jsonl.zst")) }
            check(try chargeLedger.refresh(maxBytes: 64).filesIndexed == 1, "a compressed log's read is charged to the pass")
            // A log swapped under a saved place, with the same size and date, ends before that place. It must not take the
            // pass down. Not a mutant: without the guard this traps on the subtraction, which no check label can name.
            let (swapLedger, swapFolder) = try zstLedger("swap")
            let swapFile = swapFolder.appendingPathComponent("rollout.jsonl.zst")
            try writeZst([whole], to: swapFile)
            let swapDate = try FileManager.default.attributesOfItem(atPath: swapFile.path)[.modificationDate] as? Date ?? t0
            let swapSize = try Data(contentsOf: swapFile).count
            check(try swapLedger.refresh(maxBytes: 64).pendingFiles == 1, "the swap starts part way through a log")
            try writeZst([steps.prefix(2).joined()], to: swapFile)
            var padded = try Data(contentsOf: swapFile)
            let padding = swapSize - padded.count - 8
            check(padding >= 0, "the swapped log fits under the old size")
            padded.append(contentsOf: [0x50, 0x2A, 0x4D, 0x18])
            padded.append(contentsOf: withUnsafeBytes(of: UInt32(padding).littleEndian) { Array($0) })
            padded.append(Data(count: padding))
            try padded.write(to: swapFile)
            try FileManager.default.setAttributes([.modificationDate: swapDate], ofItemAtPath: swapFile.path)
            check(try swapLedger.refresh().pendingFiles == 0, "a log swapped under its saved place does not take the pass down")
            // A log replaced part way through starts over. Carrying on from the old place would skip its first rows.
            let (replacedLedger, replacedFolder) = try zstLedger("replaced")
            let replacedFile = replacedFolder.appendingPathComponent("rollout.jsonl.zst")
            try writeZst([whole], to: replacedFile)
            _ = try replacedLedger.refresh(maxBytes: 64)
            var other = Array(steps.prefix(2))
            for step in 1...3 { other.append(try line(codex(step * 700, step * 70, 0, 700, "2026-10-20T12:00:00Z"))) }
            try writeZst([other.joined()], to: replacedFile)
            let (replacedPlainLedger, replacedPlainFolder) = try zstLedger("replaced-plain")
            try other.joined().write(to: replacedPlainFolder.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
            let replacedReference = try replacedPlainLedger.refresh()
            var replacedRead = try replacedLedger.refresh()
            while replacedRead.pendingFiles > 0 { replacedRead = try replacedLedger.refresh() }
            let replacedDay = replacedRead.buckets.first { $0.day == "2026-10-20" }?.counts.total
            check(replacedDay != nil && replacedDay == replacedReference.buckets.first { $0.day == "2026-10-20" }?.counts.total, "a log replaced part way through starts over")
            // A log of more than one frame, which the decoder alone would stop reading after the first.
            let (framesLedger, framesFolder) = try zstLedger("frames")
            try writeZst([steps.prefix(30).joined(), steps.dropFirst(30).joined()], to: framesFolder.appendingPathComponent("rollout.jsonl.zst"))
            check(totals(try framesLedger.refresh()) == totals(reference), "a log of two frames is read whole")
            // More rows than the pipe holds, faster than they can be parsed: the writer has to wait, not die.
            let (burstLedger, burstFolder) = try zstLedger("burst")
            var burst = try rolloutLines(1)
            for step in 2...20_000 { burst.append(try line(codex(step * 100, step * 10, 0, 100, "2026-10-05T12:00:00Z"))) }
            let (burstPlainLedger, burstPlainFolder) = try zstLedger("burst-plain")
            try burst.joined().write(to: burstPlainFolder.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
            try writeZst([burst.joined()], to: burstFolder.appendingPathComponent("rollout.jsonl.zst"))
            let burstRead = try burstLedger.refresh()
            let burstReference = try burstPlainLedger.refresh()
            check(burstRead.pendingFiles == 0 && burstRead.unreadableFiles == 0 && totals(burstRead) == totals(burstReference), "more rows than the pipe holds are read whole")
            // Unreadable files are counted and never stop the pass, and a replaced file gets another try.
            let (badLedger, badFolder) = try zstLedger("bad")
            try whole.write(to: badFolder.appendingPathComponent("good.jsonl"), atomically: true, encoding: .utf8)
            let junk = badFolder.appendingPathComponent("junk.jsonl.zst")
            try Data("not a zstd file".utf8).write(to: junk)
            let afterJunk = try badLedger.refresh()
            check(afterJunk.unreadableFiles == 1 && totals(afterJunk) == totals(reference), "a corrupt compressed log counts as unreadable")
            check(afterJunk.pendingFiles == 0, "a corrupt compressed log does not keep the page waiting")
            try writeZst([whole], to: junk, keep: 200)
            let afterCut = try badLedger.refresh()
            check(afterCut.unreadableFiles == 1 && afterCut.pendingFiles == 0, "a truncated compressed log counts as unreadable")
            try writeZst([whole], to: junk, keep: 6)
            let afterHeader = try badLedger.refresh()
            check(afterHeader.unreadableFiles == 1 && afterHeader.pendingFiles == 0, "a log cut off in its first block header counts as unreadable")
            try writeZst([whole], to: junk)
            let afterFix = try badLedger.refresh()
            check(afterFix.unreadableFiles == 0 && totals(afterFix) == totals(reference), "a replaced log is read again")
            try Data("not a zstd file".utf8).write(to: junk)
            check(try badLedger.refresh().unreadableFiles == 1, "a log that goes bad is reported again")
            try FileManager.default.removeItem(at: junk)
            check(try badLedger.refresh().unreadableFiles == 0, "a deleted log is no longer a gap")
            // No decoder fails closed for each file, says why, and is not remembered once one turns up.
            let (bareLedger, bareFolder) = try zstLedger("bare", nodes: [])
            try writeZst([whole], to: bareFolder.appendingPathComponent("rollout.jsonl.zst"))
            let bareOff = try bareLedger.refresh(maxBytes: 0)
            check(bareOff.pendingFiles == 1 && bareOff.unreadableFiles == 0, "a read-only pass asks nothing of the decoder")
            let bare = try bareLedger.refresh()
            // filesIndexed: with no decoder the file never reaches the plain reader, which would take it for text.
            check(bare.filesIndexed == 0 && bare.unreadableFiles == 1 && bare.pendingFiles == 0 && bare.buckets.isEmpty && bare.coverage.contains { $0.hasPrefix("Compressed Codex logs could not be read") }, "with no decoder, compressed logs count as unreadable")
            bareLedger.compressedLogNodes = [zstNode]
            let dressed = try bareLedger.refresh()
            check(dressed.unreadableFiles == 0 && totals(dressed) == totals(reference) && !dressed.coverage.contains { $0.hasPrefix("Compressed Codex logs could not be read") }, "a decoder that turns up later reads them")
            func fakeNode(_ body: String) throws -> String {
                let path = zstRoot.appendingPathComponent(UUID().uuidString).path
                FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8), attributes: [.posixPermissions: 0o755])
                return path
            }
            let tooOld = try fakeNode("exit 69")
            check(SessionUsageCollector.compressedDecoder([tooOld, zstRoot.appendingPathComponent("not-there").path, zstNode]) == zstNode && SessionUsageCollector.compressedDecoder([tooOld]) == nil, "a Node without the decoder is passed over")
            // A log that never moves stops being tried, so the page does not stay in a hurry for it.
            let hung = try fakeNode("case \"$2\" in process.exit*) exit 0 ;; esac\nexec sleep 30")
            let (hungLedger, hungFolder) = try zstLedger("hung", nodes: [hung])
            try writeZst([whole], to: hungFolder.appendingPathComponent("rollout.jsonl.zst"))
            let hungStart = Date()
            // A whole second: under load the Node probe can use up a shorter pass, and then a stall rightly does not count.
            let hungOnce = try hungLedger.refresh(seconds: 1)
            check(Date().timeIntervalSince(hungStart) < 5, "a hung decoder is stopped at the deadline")
            check(hungOnce.pendingFiles == 1 && hungOnce.unreadableFiles == 0, "a log out of time waits for the next pass")
            _ = try hungLedger.refresh(seconds: 1)
            let hungThrice = try hungLedger.refresh(seconds: 1)
            check(hungThrice.pendingFiles == 0 && hungThrice.unreadableFiles == 1, "a log that never moves stops being tried")
            // A decoder that crashes says nothing about the file, so one crash does not write it off.
            let crashing = try fakeNode("case \"$2\" in process.exit*) exit 0 ;; esac\nexit 1")
            let (crashLedger, crashFolder) = try zstLedger("crash", nodes: [crashing])
            try writeZst([whole], to: crashFolder.appendingPathComponent("rollout.jsonl.zst"))
            let crashOnce = try crashLedger.refresh()
            check(crashOnce.pendingFiles == 1 && crashOnce.unreadableFiles == 0, "one decoder crash does not write the file off")
            _ = try crashLedger.refresh()
            check(try crashLedger.refresh().unreadableFiles == 1, "a decoder that keeps crashing ends in a counted gap")
            crashLedger.compressedLogNodes = [zstNode]
            // Many files in one pass, past what a process may hold open if each one kept a handle.
            let (manyLedger, manyFolder) = try zstLedger("many")
            for index in 0..<12 { try writeZst([steps.prefix(4).joined()], to: manyFolder.appendingPathComponent("r\(index).jsonl.zst")) }
            let handlesBefore = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
            let manyRead = try manyLedger.refresh()
            let handlesAfter = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
            check(manyRead.pendingFiles == 0 && manyRead.unreadableFiles == 0 && handlesAfter <= handlesBefore + 1, "reading compressed logs keeps no file handles")
            // Too long to hand over: only a row that held usage is a gap, and the rows after it still count.
            let (hugeLedger, hugeFolder) = try zstLedger("huge")
            let imageRow = try line(["type": "response_item", "payload": ["image": String(repeating: "A", count: 9_000_000)]])
            let longUsage = try line(["type": "event_msg", "payload": ["type": "token_count", "pad": String(repeating: "B", count: 9_000_000)]])
            try writeZst([steps.prefix(4).joined() + imageRow + longUsage + steps.dropFirst(4).joined()], to: hugeFolder.appendingPathComponent("rollout.jsonl.zst"))
            let hugeRead = try hugeLedger.refresh()
            check(hugeRead.unreadableFiles == 1, "only an oversized row that held usage is a gap")
            check(totals(hugeRead) == totals(reference), "the rows after an oversized one still count")
            // A last line with no newline is still a line. A plain log waits for one, because it may be growing.
            let (tailLedger, tailFolder) = try zstLedger("tail")
            try writeZst([String(whole.dropLast())], to: tailFolder.appendingPathComponent("rollout.jsonl.zst"))
            check(totals(try tailLedger.refresh()) == totals(reference), "a last line with no newline still counts")
            // Claude Code does not compress its logs, so a file with that name there is not one of them.
            let (claudeLedger, claudeFolder) = try zstLedger("claude")
            let claudeRoot = claudeFolder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".claude/projects/p")
            try writeZst([whole], to: claudeRoot.appendingPathComponent("a.jsonl.zst"))
            let claudeRead = try claudeLedger.refresh()
            check(claudeRead.filesIndexed == 0 && claudeRead.pendingFiles == 0 && claudeRead.unreadableFiles == 0, "only Codex logs are read compressed")
        } else {
            compressedChecksSkipped = true
            FileHandle.standardError.write(Data("SKIPPED, NOT A PASS: no Node here can read zstd (22.15 or later), so the compressed log checks did not run.\n".utf8))
        }

        // A page shorter than asked for cannot end a run while the total says there is more.
        let shortHome = home.appendingPathComponent("short")
        try FileManager.default.createDirectory(at: shortHome, withIntermediateDirectories: true)
        let short = try SessionUsageCollector(home: shortHome, database: shortHome.appendingPathComponent("s.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        seenPages = []
        try short.syncCursorFeed(force: true, now: t0, readToken: { _ in .token("t") }, fetch: { _, _, _, number in
            seenPages.append(number)
            return .init(status: 200, body: number == 1 ? page([feedRow("s1")], total: 2) : page([feedRow("s2")], total: 2))
        })
        check(seenPages == [1, 2], "a short page does not end a run the total says is unfinished")
        // A server that ignores the page number ends at the total instead of paging forever.
        seenPages = []
        try short.syncCursorFeed(force: true, now: t0.addingTimeInterval(700), readToken: { _ in .token("t") }, fetch: { _, _, _, number in
            seenPages.append(number); return .init(status: 200, body: page((0..<SessionUsageCollector.cursorPageSize).map { feedRow("same-\($0)") }, total: 500))
        })
        check(seenPages == [1], "the total ends a run even if pages repeat")
        // A list that never ends stops at the page limit and says so.
        let endless = try SessionUsageCollector(home: shortHome, database: shortHome.appendingPathComponent("e.sqlite"), timeZone: TimeZone(identifier: "America/Chicago")!)
        var endlessCalls = 0
        for pass in 0..<(SessionUsageCollector.cursorPageLimit / 8 + 1) {
            try endless.syncCursorFeed(force: true, now: t0.addingTimeInterval(Double(pass)), seconds: 100, readToken: { _ in .token("t") }, fetch: { _, _, _, _ in
                endlessCalls += 1; return .init(status: 200, body: page([feedRow("loop")], total: Int.max / 2))
            })
        }
        check(try endless.refresh(cursorEnabled: true).cursorFeed?.state == .changed && endlessCalls == SessionUsageCollector.cursorPageLimit, "a list that never ends stops at the page limit")
        // An older helper's report, with no feed field, still decodes.
        let oldJSON = try JSONSerialization.data(withJSONObject: ["buckets": [], "updatedAt": "x", "timeZone": "UTC", "filesIndexed": 0, "pendingFiles": 0, "unreadableFiles": 0, "malformedRows": 0, "missingBaselineEvents": 0, "coverage": [], "pricingVersion": "v"])
        check(try JSONDecoder().decode(SessionUsageReport.self, from: oldJSON).cursorFeed == nil, "a report without the feed field decodes")
        print("PASS: tool names, model names, default scales, per-tool prior windows and the Cursor feed (parsing, privacy, paging, backoff, resume)")
        try cosCostChecks(home: home)
        if try !cosCompressedChecks(home: home, nodes: zstNodes) { compressedChecksSkipped = true }

        print("PASS: weekly buckets, category USD mix, period comparisons, table sorting and CSV/JSON export")
        print("PASS: 30/90/custom dates, DST/leap/calendar boundaries, provider/day summaries and token mix")
        print("PASS: usage period boundaries, timezone, token/category shares, tooltip aggregation and unknown-price handling")
        print("PASS: usage parsing, deduplication, cache pricing, local dates, reset, partial append, retention and unknown coverage")
        if compressedChecksSkipped {
            print("INCOMPLETE: the compressed log checks were skipped. Set COS_USAGE_ALLOW_ZSTD_SKIP=1 to accept that on a Mac with no suitable Node.")
            if ProcessInfo.processInfo.environment["COS_USAGE_ALLOW_ZSTD_SKIP"] != "1" { exit(3) }
        } else {
            print("PASS: compressed Codex logs (real .jsonl.zst: idempotent re-import, slices, frames, corrupt and truncated files, no decoder)")
        }
    }
}

// MARK: - COS cost. Fixtures for each data rule, then the reader on a scratch home and database.
extension Checks {
    /// COS cost over compressed rollouts: the same Work runs, read plain and compressed, give the same figures. False when
    /// no Node here can read zstd, so the caller can say these checks did not run.
    static func cosCompressedChecks(home: URL, nodes: [String]) throws -> Bool {
        func check(_ yes: Bool, _ label: String) { if !yes { fatalError(label) } }
        guard let node = SessionUsageCollector.compressedDecoder(nodes) else { return false }
        let chicago = TimeZone(identifier: "America/Chicago")!
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: CosCostRules.epoch("2026-10-31T12:00:00Z")!)
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n" }
        // A real task_complete row carries the last answer, so this one does too. It may pass the filter, and it must stop at counts.
        func event(_ kind: String, _ time: String) throws -> String { try json(["type": "event_msg", "timestamp": time, "payload": ["type": kind, "last_agent_message": "SECRET_PROMPT_NEVER_STORE"]]) }
        func tokens(_ time: String, _ total: Int) throws -> String {
            try json(["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "output_tokens": 0, "cached_input_tokens": 0], "last_token_usage": ["input_tokens": 1000, "output_tokens": 0, "cached_input_tokens": 0]]]])
        }
        let noise = try json(["type": "response_item", "payload": ["text": String(repeating: "SECRET_PROMPT_NEVER_STORE ", count: 200)]])
        func rollout(_ id: String, _ body: String) throws -> String {
            try json(["type": "session_meta", "payload": ["id": id, "model_provider": "openai"]]) + json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]]) + noise + body
        }
        // Moved on by a person's next turn; ended by its last finished turn; ended by an aborted turn.
        let movedOn = "aaaaaaaa-1111-1111-1111-111111111111", finished = "bbbbbbbb-2222-2222-2222-222222222222", aborted = "cccccccc-3333-3333-3333-333333333333"
        let threads: [(id: String, start: String, text: String)] = [
            (movedOn, "2026-10-30T13:00:00Z", try rollout(movedOn, try event("task_started", "2026-10-30T13:00:03Z") + tokens("2026-10-30T13:00:10Z", 1000) + event("task_complete", "2026-10-30T13:00:20Z")
                + noise + event("task_started", "2026-10-30T13:30:00Z") + tokens("2026-10-30T13:30:10Z", 2000) + event("task_complete", "2026-10-30T13:30:20Z"))),
            (finished, "2026-10-30T14:00:00Z", try rollout(finished, try event("task_started", "2026-10-30T14:00:03Z") + tokens("2026-10-30T14:00:10Z", 1000) + event("task_complete", "2026-10-30T14:00:20Z"))),
            (aborted, "2026-10-30T15:00:00Z", try rollout(aborted, try event("task_started", "2026-10-30T15:00:03Z") + tokens("2026-10-30T15:00:10Z", 1000) + event("turn_aborted", "2026-10-30T15:00:20Z"))),
        ]
        func rolloutFile(_ root: URL, _ id: String, compressed: Bool) -> URL {
            root.appendingPathComponent(".codex/sessions/2026/10/30/rollout-2026-10-30T13-00-00-\(id).jsonl" + (compressed ? ".zst" : ""))
        }
        func place(_ name: String, compressed: Bool, only: String? = nil) throws -> (reader: SessionUsageCollector, root: URL) {
            let root = home.appendingPathComponent("cos-zst-\(name)")
            let chosen = threads.filter { only == nil || $0.id == only }
            for thread in chosen {
                let file = rolloutFile(root, thread.id, compressed: false)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try thread.text.write(to: file, atomically: true, encoding: .utf8)
                guard compressed else { continue }
                let maker = Process()
                maker.executableURL = URL(fileURLWithPath: node)
                maker.arguments = ["-e", "const f=require('fs'),z=require('zlib');f.writeFileSync(process.argv[1]+'.zst',z.zstdCompressSync(f.readFileSync(process.argv[1])));f.unlinkSync(process.argv[1])", file.path]
                try maker.run(); maker.waitUntilExit()
                check(maker.terminationStatus == 0, "the fixture compresses")
            }
            let handoffs = root.appendingPathComponent("Library/Application Support/COS Control/work-handoffs/handoffs.json")
            try fm.createDirectory(at: handoffs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(try json(["receipts": chosen.map { ["createdAt": CosCostRules.epoch($0.start)!, "sessionID": "codex:\($0.id)", "provider": "codex", "status": "completed", "channel": "job"] }]).utf8).write(to: handoffs)
            let reader = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-zst-\(name).sqlite"), timeZone: chicago)
            reader.compressedLogNodes = compressed ? [node] : []
            return (reader, root)
        }
        func fakeNode(_ root: URL, _ rest: String) throws -> String {
            let file = root.appendingPathComponent("fake-node-\(UUID().uuidString)")
            try "#!/bin/sh\ncase \"$2\" in process.exit*) exit 0 ;; esac\n\(rest)\n".write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        func pass(_ reader: SessionUsageCollector, seconds: TimeInterval = SessionUsageCollector.cosPassSeconds) throws -> CosUsageReport {
            try reader.cosUsage(plistScripts: "/nonexistent", dataDirectory: nil, importSessions: true, seconds: seconds, now: now)
        }

        let plain = try pass(try place("plain", compressed: false).reader)
        check(plain.work.measuredTokens == 3000 && plain.work.widerTokens == 4000 && plain.work.unprovenRuns == 0 && plain.sessions.stillReading == 0, "the plain reference has three runs with provable ends")
        let (zipped, _) = try place("zipped", compressed: true)
        let read = try pass(zipped)
        check(read.sessions.compressed == 0 && read.sessions.stillReading == 0 && read.sessions.noLogs == 0, "a compressed Work log is read, not reported as unread")
        check(read.work.unprovenRuns == 0, "a compressed Work run has the provable end a plain one has")
        check(read.work.measuredTokens == plain.work.measuredTokens && read.work.widerTokens == plain.work.widerTokens, "a compressed Work run counts what the plain log counts")
        check(!(try Data(contentsOf: home.appendingPathComponent("cos-zst-zipped.sqlite"))).contains(Data("SECRET_PROMPT_NEVER_STORE".utf8)), "no words from a compressed log reach the usage history")
        // Finished is finished: with no decoder at all the next pass still has its figures and says nothing is unread.
        zipped.compressedLogNodes = []
        let again = try pass(zipped)
        check(again.sessions.compressed == 0 && again.work.measuredTokens == plain.work.measuredTokens, "a finished compressed log starts no decoder")
        // A small budget moves line by line, resumes where it stopped, and counts each row once.
        let (sliced, _) = try place("sliced", compressed: true, only: movedOn)
        var slices = 0, leftOpen = 1
        while leftOpen > 0 && slices < 25 {
            slices += 1
            leftOpen = try sliced.cosReadSessionSlices([SessionUsageCollector.CosSliceTarget(provider: "codex", id: movedOn)], fileBytes: 1, now: now).stillReading
        }
        check(slices > 3 && slices < 25 && leftOpen == 0, "a small budget reads a compressed Work log in slices, from where it stopped")
        let slicedRead = try pass(sliced)
        check(slicedRead.work.measuredTokens == 1000 && slicedRead.work.widerTokens == 2000, "a compressed Work log read in slices counts each row once")
        // No decoder: said, and nothing else on the page moves.
        let (bare, _) = try place("bare", compressed: true)
        bare.compressedLogNodes = []
        let unread = try pass(bare)
        check(unread.sessions.compressed == 3 && unread.sessions.stillReading == 0 && unread.work.measuredTokens == 0, "with no decoder each compressed session is said")
        // A file it cannot trust: said each pass, and it does not keep the page hurrying.
        let (corrupt, corruptRoot) = try place("corrupt", compressed: true, only: finished)
        try Data("not really zstd".utf8).write(to: rolloutFile(corruptRoot, finished, compressed: true))
        let spoiled = try pass(corrupt)
        check(spoiled.sessions.compressed == 1 && spoiled.sessions.stillReading == 0, "a corrupt compressed session is said and does not keep the page waiting")
        check(try pass(corrupt).sessions.compressed == 1, "a corrupt compressed session is still said on the next pass, with no new try")
        // Out of time: still reading, not failed, and no decoder starts for it.
        let (late, lateRoot) = try place("late", compressed: true)
        let started = lateRoot.appendingPathComponent("decoder-started")
        late.compressedLogNodes = [try fakeNode(lateRoot, "touch '\(started.path)'\nexit 1")]
        let noTime = try pass(late, seconds: 0)
        check(noTime.sessions.stillReading == 3 && noTime.sessions.compressed == 0, "a pass with no time left leaves compressed logs still being read")
        check(!fm.fileExists(atPath: started.path), "a pass with no time left starts no decoder")
        // A decoder that hangs is killed at the deadline, and a log that never moves stops being tried.
        let (stuck, stuckRoot) = try place("stuck", compressed: true, only: finished)
        stuck.compressedLogNodes = [try fakeNode(stuckRoot, "exec sleep 30")]
        let clock = Date()
        // Compressed logs get half a pass, and under load the Node probe can use up a shorter one.
        let firstStall = try pass(stuck, seconds: 2), secondStall = try pass(stuck, seconds: 2)
        check(Date().timeIntervalSince(clock) < 15, "a hung decoder is killed at the pass's deadline")
        check(firstStall.sessions.stillReading == 1 && secondStall.sessions.stillReading == 1 && secondStall.sessions.compressed == 0, "a stalled compressed log gets more than one try")
        let thirdStall = try pass(stuck, seconds: 2)
        check(thirdStall.sessions.stillReading == 0 && thirdStall.sessions.compressed == 1, "a compressed log that never moves stops being tried, and says so")
        print("PASS: COS cost over compressed rollouts (provable ends, parity with plain, slices, no decoder, corrupt, out of time, hung decoder)")
        return true
    }

    static func cosCostChecks(home: URL) throws {
        func check(_ yes: Bool, _ label: String) { if !yes { fatalError(label) } }
        let chicago = TimeZone(identifier: "America/Chicago")!
        let R = CosCostRules.self, P = CosCostPresentation.self
        // Timestamps. Python writes -0500, Node writes Z, and one file holds both.
        check(R.epoch("2026-10-30T12:00:00-0500") == 1_793_379_600, "a -0500 stamp is that instant")
        check(R.epoch("2026-10-30T12:00:00-05:00") == 1_793_379_600, "a -05:00 stamp is that instant")
        check(R.epoch("2026-10-30T17:00:00Z") == 1_793_379_600, "a Z stamp is that instant")
        check(R.epoch("2026-10-30T17:00:00.500Z") == 1_793_379_600.5, "a stamp keeps its fraction")
        check(R.epoch("2026-10-30T12:00:00.250-0500") == 1_793_379_600.25, "a fraction before a zone is read")
        check(R.epoch("2026-10-30T22:30:00+0530") == 1_793_379_600, "a positive offset is that instant")
        check(R.epoch("2026-10-30T12:00:00") == nil && R.epoch("2026-10-30T12:00:00.500") == nil, "a stamp with no zone names no instant")
        check(R.epoch("") == nil && R.epoch("yesterday afternoon at 3pm") == nil && R.epoch("2026-13-30T12:00:00Z") == nil && R.epoch("2026-10-30T12:00:00Zjunk") == nil && R.epoch("2026-10-30T25:00:00Z") == nil, "a stamp that is not a date is nil")
        check(R.dayKey(epoch: R.epoch("2026-10-31T00:30:00Z")!, timeZone: chicago) == "2026-10-30", "the day is the reporting zone's day")
        check(R.dayKey(epoch: R.epoch("2026-10-31T00:30:00-0500")!, timeZone: chicago) == "2026-10-31", "a -0500 stamp after local midnight is the next day")
        // Classification. A shared source does not win over a caller, and anything unknown stays visible.
        check(R.category(source: "g2-dictation-autoclean", caller: "dictation_autoclean_message", day: "2026-10-25") == .dictation, "message polish is dictation")
        check(R.category(source: "g2-dictation-autoclean", caller: "dictation_autoclean_prompt_draft", day: "2026-10-25") == .dictation, "a prompt draft is dictation")
        check(R.category(source: "", caller: "prompt_edit", day: "2026-10-25") == .dictation, "a prompt edit is dictation")
        check(R.category(source: "g2-dictation-autoclean", caller: "dictation_autoclean_meeting", day: "2026-10-25") == .transcription, "meeting polish is transcription cleanup")
        check(R.category(source: "x", caller: "transcript-cleanup", day: "2026-10-25") == .transcription, "transcript cleanup is transcription cleanup")
        check(R.category(source: "g2-dictation-autoclean", caller: "dictation_autoclean", day: "2026-10-19") == .dictationBeforeSplit, "a plain polish row before the split is its own row")
        check(R.category(source: "g2-dictation-autoclean", caller: "dictation_autoclean", day: "2026-10-20") == .dictation, "a plain polish row from the split on is dictation")
        check(R.category(source: "g2-archive", caller: "chat_summary", day: "2026-10-25") == .meetingNotes, "a chat summary is meeting notes")
        check(R.category(source: "cos-script", caller: "domain_intel_extract", day: "2026-10-25") == .meetingNotes, "meeting extraction is meeting notes")
        check(R.category(source: "g2-query", caller: "full_query", day: "2026-10-25") == .answers, "a G2 query is an answer")
        check(R.category(source: "meeting-ask-web", caller: "meeting_ask_web", day: "2026-10-25") == .answers, "Ask is an answer")
        check(R.category(source: "g2-query", caller: "routine:morning-brief", day: "2026-10-25") == .liveAndUpkeep, "a routine is upkeep even with a G2 source")
        check(R.category(source: "live-cues-v2", caller: "live-cues-v2", day: "2026-10-25") == .liveAndUpkeep, "cues are live help")
        check(R.category(source: "x", caller: "live-cues-lightrag", day: "2026-10-25") == .liveAndUpkeep, "a cue's memory lookup is live help, not indexing")
        check(R.category(source: "g2-lens-gist", caller: "lens_gist", day: "2026-10-25") == .liveAndUpkeep, "a gist is upkeep")
        check(R.category(source: "g2-prewarm", caller: "prewarm", day: "2026-10-25") == .liveAndUpkeep, "prewarm is upkeep")
        check(R.category(source: "cos-script", caller: "lightrag", day: "2026-10-25") == .memoryIndexing, "LightRAG is memory indexing")
        check(R.category(source: "cos-script", caller: "memory-tier-judge", day: "2026-10-25") == .memoryIndexing, "a memory job is memory indexing")
        check(R.category(source: "meeting-ask", caller: "work_chat_summary", day: "2026-10-25") == .work, "Work chat is Work even with an Ask source")
        check(R.category(source: "jev", caller: "work-intake-jev", day: "2026-10-25") == .work, "Work intake is Work")
        check(R.category(source: "g2-query", caller: "dispatch_task", day: "2026-10-25") == .work && R.category(source: "g2-query", caller: "work_review", day: "2026-10-25") == .work, "dispatch and review are Work even with a G2 source")
        check(R.category(source: "g2-attached", caller: "attached_turn", day: "2026-10-25") == .work && R.category(source: "g2-attached", caller: "attached_turn:timeout", day: "2026-10-25") == .work, "an attached turn is Work, failed or not")
        check(R.category(source: "g2-fork", caller: "fork_thread", day: "2026-10-25") == .work && R.category(source: "g2-fork", caller: "fork_thread:denied", day: "2026-10-25") == .work, "a fork is Work, failed or not")
        check(R.category(source: "cos-script", caller: "", day: "2026-04-01") == .other, "a blank caller goes to Other")
        check(R.category(source: "brand-new-source", caller: "brand_new_caller", day: "2026-10-25") == .other, "an unknown source goes to Other")
        // Session-log flags. These decide what the total adds, so a row cannot be in the total twice.
        check(R.inSessionLogs(source: "g2-query", caller: "full_query") && R.inSessionLogs(source: "g2-prewarm", caller: "prewarm") && R.inSessionLogs(source: "g2-archive", caller: "chat_summary"), "G2, prewarm and archive are in session logs")
        check(!R.inSessionLogs(source: "g2-dictation-autoclean", caller: "dictation_autoclean_message") && !R.inSessionLogs(source: "g2-lens-gist", caller: "lens_gist")
              && !R.inSessionLogs(source: "meeting-ask", caller: "meeting_ask") && !R.inSessionLogs(source: "cos-script", caller: "lightrag"), "polish, gist, Ask and scripts are not in session logs")
        check(!R.inSessionLogs(source: "g2-query", caller: "dispatch_task"), "a dispatch keeps no session log even with a G2 source")
        check(R.inSessionLogs(source: "g2-attached", caller: "attached_turn") && R.inSessionLogs(source: "g2-fork", caller: "fork_thread"), "attached and fork turns are in session logs")
        check(!R.inSessionLogs(source: "g2-query", caller: "work_review", model: "claude-opus-5-5") && R.inSessionLogs(source: "g2-query", caller: "work_review", model: "gpt-6.1-sol"), "a Claude review keeps no session log and a Codex one does")
        check(R.baseCaller("full_query:late_result") == "full_query" && R.baseCaller("routine:morning-brief") == "routine:morning-brief" && R.isLate("full_query:late_result") && !R.isLate("full_query"), "only the late suffix comes off a caller")
        check(R.runsThroughCursor(model: "cursor-grok") && R.runsThroughCursor(model: "cursor:grok-4.7-low-fast") && R.runsThroughCursor(model: "luna-5.6-fast") && !R.runsThroughCursor(model: "claude:claude-sonnet-5-5"), "Cursor and Luna run through Cursor")
        // Rates. Unknown is No price, never $0, and an alias maps through one table.
        let rates = CosCostRates.self
        check(rates.resolve("opus")?.model == "claude-opus-5-5" && rates.resolve("sonnet")?.model == "claude-sonnet-5-5" && rates.resolve("haiku")?.model == "claude-haiku-5-5", "a bare alias maps to today's model")
        check(rates.resolve("claude:claude-sonnet-5-5")?.model == "claude-sonnet-5-5" && rates.resolve("claude-opus-5-5[1m]")?.model == "claude-opus-5-5", "a harness prefix and a context suffix are stripped")
        check(rates.resolve("codex:gpt-5.6-terra")?.provider == "OpenAI" && rates.resolve("codex:gpt-5.6-terra")?.model == "gpt-5.6-terra", "a Codex model resolves to OpenAI")
        check(rates.resolve("codex:sonnet") == nil && rates.resolve("codex-frontier") == nil && rates.resolve("cursor-grok") == nil && rates.resolve("luna-5.6-fast") == nil && rates.resolve("ollama:qwen3.8:27b") == nil, "a tier, a router or a local model has no price")
        check(abs(rates.usd(provider: "OpenAI", model: "gpt-5.6-terra", counts: SessionUsageCounts(input: 100_000, output: 100_000, cacheRead: 100_000))! - 1.42) < 1e-9, "terra is $2, $0.20 and $12 per million")
        check(abs(rates.usd(provider: "OpenAI", model: "gpt-5.5", counts: SessionUsageCounts(input: 100_000, output: 100_000, cacheRead: 100_000))! - 3.55) < 1e-9, "GPT-5.5 is $5, $0.50 and $30 per million")
        let sol = SessionUsageCounts(input: 100_000, output: 100_000, cacheRead: 100_000)
        check(abs(rates.usd(provider: "OpenAI", model: "gpt-5.6-sol", counts: sol, on: R.epoch("2026-10-31T12:00:00Z"))! - 2.44) < 1e-9, "5.6 Sol is $4, $0.40 and $20 per million")
        // Sol's price is promotional, verified through 2026-11-21. Usage after that day has no price here, not the old one.
        check(rates.usd(provider: "OpenAI", model: "gpt-5.6-sol", counts: sol, on: R.epoch("2026-11-21T23:59:00Z")) != nil, "the promotional rate holds through its last day")
        check(rates.usd(provider: "OpenAI", model: "gpt-5.6-sol", counts: sol, on: R.epoch("2026-11-22T00:00:00Z")) == nil && rates.usd(provider: "OpenAI", model: "gpt-5.6-sol", counts: sol, on: R.epoch("2027-01-15T12:00:00Z")) == nil, "after its last day the promotional rate prices nothing")
        check(rates.usd(provider: "OpenAI", model: "gpt-5.6-terra", counts: sol, on: R.epoch("2027-01-15T12:00:00Z")) != nil && rates.usd(provider: "OpenAI", model: "gpt-5.5", counts: sol, on: R.epoch("2027-01-15T12:00:00Z")) != nil, "a rate with no end date never lapses")
        check(rates.estimateUSD(ledgerModel: "codex:gpt-5.6-sol", input: 1000, output: 100, on: R.epoch("2026-12-01T00:00:00Z")) == nil && rates.estimateUSD(ledgerModel: "codex:gpt-5.6-sol", input: 1000, output: 100, on: R.epoch("2026-11-01T00:00:00Z")) != nil, "an estimate follows the same end date")
        check(rates.usd(provider: "OpenAI", model: "gpt-5.6-terra", counts: SessionUsageCounts(input: 300_000)) == nil, "a verified rate stops at 272K of context")
        check(rates.usd(provider: "OpenAI", model: "gpt-5.6-terra", counts: SessionUsageCounts(input: 10, cacheWrite: 5)) == nil, "a verified rate does not price cache writes")
        check(SessionUsagePricing.estimate(provider: "OpenAI", model: "gpt-5.6-terra", counts: SessionUsageCounts(input: 10)) == nil, "stored Usage rates do not change")
        check(rates.usd(provider: "OpenAI", model: "gpt-made-up", counts: SessionUsageCounts(input: 10)) == nil, "an unknown model has no price")
        check(abs(rates.estimateUSD(ledgerModel: "jev-1.13.0", input: 1_000_000_000, output: 500)! - 42) < 1e-9, "Jev is $42 a billion input tokens")
        check(abs(rates.estimateUSD(ledgerModel: "sonnet", input: 1_000_000, output: 1_000_000)! - 12) < 1e-9, "an estimate uses the plain input and output rates")
        check(rates.estimateUSD(ledgerModel: "cursor-grok", input: 1000, output: 1000) == nil, "an estimate on an unpriced model has no dollars")
        // A real row beside the card: claude-sonnet-5-5 through the command line, all input written to a one-hour cache.
        let gistCard = rates.usd(provider: "Anthropic", model: "claude-sonnet-5-5", counts: SessionUsageCounts(output: 66_732, cacheWrite: 1_043_971), oneHour: 1_043_971)!
        check(abs(gistCard - 4.8401) / 4.8401 < 0.002, "the card matches what the command line reported on real gist rows")
        // Paths and the one key read out of .env.
        check(R.auditPaths(plistScripts: "/a", envScripts: "/b", home: "/h") == ["/a/.cos_token_audit.jsonl", "/b/.cos_token_audit.jsonl", "/h/.cos-glasses/token-audit.jsonl"], "the plist comes before .env and .env before home")
        check(R.envValue("# COS_SCRIPTS_DIR=/no\nOTHER=1\nexport COS_SCRIPTS_DIR=\"/yes it is\"\n", key: "COS_SCRIPTS_DIR") == "/yes it is", ".env handles comments, export and quotes")
        check(R.envValue("OTHER=1\nCOS_SCRIPTS_DIR=\n", key: "COS_SCRIPTS_DIR") == nil, "an empty .env value is no value")
        check(R.dailyLedgers.allSatisfy { $0.file.hasSuffix("-usage.json") }, "the day ledgers are named usage files, never a key file")
        check(R.dataFiles.allSatisfy { !$0.lowercased().contains("key") }, "no file on the helper's list is a key file")
        check(R.dataFiles.allSatisfy { R.dataFileAllowed($0) }, "every file on the helper's list is allowed")
        check(!R.dataFileAllowed("subq-key.json") && !R.dataFileAllowed("jev-key.json") && !R.dataFileAllowed("some-new-key.json"), "the door refuses a key file")
        check(!R.dataFileAllowed("subq-key.json", list: ["subq-key.json"]), "a key file is refused even if someone lists it")
        check(!R.dataFileAllowed("anything-else.json") && !R.dataFileAllowed("../.env") && !R.dataFileAllowed(".cos-profile.json"), "the door refuses anything not on the list")

        // The accumulator.
        let window = "2026-10-02"..."2026-10-31"
        func audit(_ stamp: String, source: String = "g2-dictation-autoclean", caller: String = "dictation_autoclean_message", model: String = "sonnet", input: Int64 = 1000, output: Int64 = 100, kind: String = "estimated", run: String = "") -> CosAuditRow {
            var row = CosAuditRow()
            row.stamp = stamp; row.source = source; row.caller = caller; row.model = model
            row.estimatedInput = input; row.estimatedOutput = output; row.usageKind = kind; row.runID = run
            return row
        }
        func make(gist: [CosGistRun] = [], runs: [CosRun] = [], work: [String: Double] = [:], events: [CosSliceEvent] = [], handoffs: [CosWorkRun]? = nil, marks: [CosSliceMark] = []) -> CosCostAccumulator {
            CosCostAccumulator(window: window, timeZone: chicago, gistRuns: gist, runs: runs, workStarts: work, events: events,
                               workRuns: handoffs ?? work.map { CosWorkRun(session: $0.key, start: $0.value) }, marks: marks)
        }
        func finish(_ a: inout CosCostAccumulator) -> [CosCostCategory: CosCostRow] {
            Dictionary(uniqueKeysWithValues: a.finish(handoffsFound: true, workRuns: 0, workRunsWithoutLogs: 0).rows.map { ($0.category, $0) })
        }
        var a = make()
        a.add(audit("not a date at all"))
        a.add(audit("2026-10-30T12:00:00"))
        a.add(audit("2026-10-30T12:00:00-0500"))
        a.add(audit("2026-10-01T23:00:00-0500")) // the day before the window
        a.add(audit("2026-10-02T00:30:00-0500")) // the window's first day
        check(a.undated == 2, "a row with no parseable date is counted, not dropped")
        var rows = finish(&a)
        check(rows[.dictation]?.calls == 2, "a -0500 row lands on its local day and the day before the window is out")
        check(rows[.dictation]?.estimatedCalls == 2 && rows[.dictation]?.measuredCalls == 0 && rows[.dictation]?.measuredUSD == 0, "a character-count row is an estimate and adds no measured dollars")
        check(abs((rows[.dictation]?.estimatedUSD ?? 0) - 2 * (1000*2.0 + 100*10.0)/1_000_000) < 1e-12, "an estimate's floor is its tokens at the model's rate")
        a = make()
        a.add(audit("2026-10-30T12:00:00Z", source: "cos-script", caller: "", model: "haiku"))
        rows = finish(&a)
        check(rows[.other]?.calls == 1, "a blank caller row is visible in Other")
        // provider_final wins over an estimate.
        var final = audit("2026-10-30T12:00:00Z", model: "sonnet", kind: "provider_final")
        final.real = SessionUsageCounts(input: 1000, output: 100); final.realUSD = 5
        a = make(); a.add(final); rows = finish(&a)
        check(rows[.dictation]?.measuredCalls == 1 && rows[.dictation]?.estimatedCalls == 0 && rows[.dictation]?.measuredUSD == 5, "a provider_final row wins over its estimate and its cost wins over the card")
        check(rows[.dictation]?.addsToTotalUSD == 5, "measured polish adds to the total, because Usage cannot see it")
        final.realUSD = nil
        a = make(); a.add(final); rows = finish(&a)
        check(abs((rows[.dictation]?.measuredUSD ?? 0) - 0.003) < 1e-12, "a provider_final row with no cost uses the card")
        final.model = "cursor-composer"
        a = make(); a.add(final); rows = finish(&a)
        check(rows[.dictation]?.measuredCalls == 1 && rows[.dictation]?.measuredUSD == 0 && rows[.dictation]?.unpricedMeasuredCalls == 1, "a measured row with no rate is unpriced, never $0 of spend")
        check(rows[.dictation]?.addsUnlessCursorFeedUSD == 0 && rows[.dictation]?.addsToTotalUSD == 0, "an unpriced row adds nothing to the total")
        // The row's own day decides whether a promotional rate applies, so old rows keep their price and later ones have none.
        var promo = audit("2026-10-30T12:00:00Z", model: "codex:gpt-5.6-sol", kind: "provider_final")
        promo.real = SessionUsageCounts(input: 1000, output: 100)
        a = make(); a.add(promo); rows = finish(&a)
        check((rows[.dictation]?.measuredUSD ?? 0) > 0 && rows[.dictation]?.unpricedMeasuredCalls == 0, "a Sol row inside the promotion is priced")
        let lateWindow = "2026-11-02"..."2026-12-01"
        var late = CosCostAccumulator(window: lateWindow, timeZone: chicago, gistRuns: [], runs: [], workStarts: [:], events: [])
        promo.stamp = "2026-11-25T12:00:00Z"
        late.add(promo)
        let lateRows = Dictionary(uniqueKeysWithValues: late.finish(handoffsFound: true, workRuns: 0, workRunsWithoutLogs: 0).rows.map { ($0.category, $0) })
        check(lateRows[.dictation]?.measuredUSD == 0 && lateRows[.dictation]?.unpricedMeasuredCalls == 1, "a Sol row after the promotion has no price, and says so")
        // Gist rows dedupe against their ledger, and the measured source wins.
        func gistRun(_ at: String, model: String = "claude-sonnet-5-5", cost: Double? = 0.25, engine: String = "claude") -> CosGistRun {
            var usage: [String: Any] = ["inputTokens": 1000, "outputTokens": 100]
            if let cost { usage["costUsd"] = cost }
            return CosGistRun(json: ["engine": engine, "model": model, "at": at, "usage": usage])!
        }
        check(CosGistRun(json: ["engine": "claude", "model": "x", "at": "2026-10-30T12:00:00Z", "ok": false]) == nil, "a gist run with no usage is not a measurement")
        let gistRow = audit("2026-10-30T12:00:00.010Z", source: "g2-lens-gist", caller: "lens_gist", model: "claude:claude-sonnet-5-5")
        a = make(gist: [gistRun("2026-10-30T12:00:00.020Z")]); a.add(gistRow); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.calls == 1 && rows[.liveAndUpkeep]?.measuredCalls == 1 && rows[.liveAndUpkeep]?.estimatedCalls == 0, "an audit gist row and its run are one measured call")
        check(rows[.liveAndUpkeep]?.measuredUSD == 0.25 && rows[.liveAndUpkeep]?.addsToTotalUSD == 0.25, "a gist run's own cost is measured and adds to the total")
        // A gist run through the Cursor engine is in Usage's total whenever the Cursor feed is on, so it follows the Cursor rule.
        a = make(gist: [gistRun("2026-10-30T12:00:00Z", model: "composer-2", engine: "cursor")]); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.measuredUSD == 0.25 && rows[.liveAndUpkeep]?.addsToTotalUSD == 0 && rows[.liveAndUpkeep]?.addsUnlessCursorFeedUSD == 0.25, "a Cursor gist run is held apart from the plain additions")
        let cursorGistRows = Array(rows.values)
        a = make(gist: [gistRun("2026-10-30T12:00:00Z", model: "luna-5.6-fast", engine: "codex")]); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.addsUnlessCursorFeedUSD == 0.25 && rows[.liveAndUpkeep]?.addsToTotalUSD == 0, "a Luna gist run follows the Cursor rule too")
        a = make(gist: [gistRun("2026-10-30T12:01:00Z")]); a.add(gistRow); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.calls == 2 && rows[.liveAndUpkeep]?.estimatedCalls == 1, "a gist row too far from a run stays an estimate")
        a = make(gist: [gistRun("2026-10-30T12:00:00Z", model: "claude-opus-5-5")]); a.add(gistRow); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.estimatedCalls == 1, "a gist row with another model does not match")
        a = make(gist: [gistRun("2026-10-30T12:00:00Z")])
        a.add(gistRow); a.add(gistRow); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.measuredCalls == 1 && rows[.liveAndUpkeep]?.estimatedCalls == 1, "one gist run absorbs one audit row")
        a = make(gist: [gistRun("2026-10-30T12:00:00Z", cost: nil)]); rows = finish(&a)
        check(abs((rows[.liveAndUpkeep]?.measuredUSD ?? 0) - 0.003) < 1e-12, "a gist run with no cost of its own uses the card")
        a = make(gist: [gistRun("2026-10-30T12:00:00Z", model: "brand-new-model", cost: nil)]); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.measuredUSD == 0 && rows[.liveAndUpkeep]?.unpricedMeasuredCalls == 1, "a gist run with no cost and no rate stays unpriced")
        a = make(gist: [gistRun("2026-09-01T12:00:00Z")]); rows = finish(&a)
        check(rows[.liveAndUpkeep] == nil, "a gist run outside the window is out")
        // G2 runs and their session slices.
        func run(_ id: String, session: String = "claude:s1", model: String = "opus", start: String = "2026-10-30T12:00:00Z", end: String = "2026-10-30T12:01:00Z") -> CosRun {
            var r = CosRun(runID: id, provider: "claude")
            r.apply(patch: ["cliSessionId": String(session.split(separator: ":").last!), "model": model, "createdAt": start, "updatedAt": end])
            r.session = session
            return r
        }
        func event(_ at: String, session: String = "claude:s1", input: Int64 = 1000, model: String = "claude-opus-5-5", provider: String = "Anthropic") -> CosSliceEvent {
            CosSliceEvent(session: session, at: R.epoch(at)!, provider: provider, model: model, counts: SessionUsageCounts(input: input))
        }
        let g2Row = audit("2026-10-30T12:01:00Z", source: "g2-query", caller: "full_query", model: "opus", input: 5000)
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z")]); a.add(g2Row); rows = finish(&a)
        check(rows[.answers]?.calls == 1 && rows[.answers]?.measuredCalls == 1 && rows[.answers]?.estimatedCalls == 0, "a G2 row with a run and a slice is one measured answer, not two")
        check(abs((rows[.answers]?.measuredUSD ?? 0) - 0.004) < 1e-12, "a run's dollars come from its session slice")
        check(rows[.answers]?.approximateMatches == 1, "a time and model match is labelled approximate")
        check(rows[.answers]?.addsToTotalUSD == 0, "a slice Usage has priced adds nothing to the total")
        // A run with a priced event and an unpriced one has dollars, and they leave the unpriced one out, so the row says so.
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z"), event("2026-10-30T12:00:40Z", model: "claude-made-up-9")]); a.add(g2Row); rows = finish(&a)
        check((rows[.answers]?.measuredUSD ?? 0) > 0 && rows[.answers]?.unpricedMeasuredCalls == 1 && P.measuredPartial({ var r = report([]); r.rows = [rows[.answers]!]; return r }()), "a mixed run is partial: its dollars end in +")
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z")]); a.add(audit("2026-10-30T12:01:00Z", source: "g2-query", caller: "full_query", model: "opus", run: "r1")); rows = finish(&a)
        check(rows[.answers]?.approximateMatches == 0 && rows[.answers]?.measuredCalls == 1, "a row carrying its run id is an exact match")
        // A row names its session bare (`cli_session_id`) and the collector keys the runs provider:id. With no run id and another
        // model, the session is the only way to its run.
        var bySession = g2Row; bySession.sessionID = "s1"
        a = make(runs: [run("r1", model: "sonnet")], events: [event("2026-10-30T12:00:30Z")]); a.add(bySession); rows = finish(&a)
        check(rows[.answers]?.calls == 1 && rows[.answers]?.measuredCalls == 1 && rows[.answers]?.approximateMatches == 0, "a row finds its run by session, in the key shape the collector builds")
        var otherSession = g2Row; otherSession.sessionID = "s2"
        a = make(runs: [run("r1", model: "sonnet")], events: [event("2026-10-30T12:00:30Z")]); a.add(otherSession); rows = finish(&a)
        check(rows[.answers]?.calls == 2 && rows[.answers]?.estimatedCalls == 1, "another session is not this run")
        var codexSession = g2Row; codexSession.sessionID = "t1"
        var codexRun = run("r1", session: "codex:t1", model: "sonnet"); codexRun.provider = "codex"
        a = make(runs: [codexRun], events: [event("2026-10-30T12:00:30Z", session: "codex:t1")]); a.add(codexSession); rows = finish(&a)
        check(rows[.answers]?.calls == 1 && rows[.answers]?.measuredCalls == 1 && rows[.answers]?.approximateMatches == 0, "a Codex run is found by its session too")
        a = make(runs: [run("r1", model: "sonnet")], events: [event("2026-10-30T12:00:30Z")]); a.add(g2Row); rows = finish(&a)
        check(rows[.answers]?.calls == 2 && rows[.answers]?.estimatedCalls == 1, "a G2 row with another model does not match a run")
        a = make(runs: [run("r1")]); a.add(g2Row); rows = finish(&a)
        check(rows[.answers]?.estimatedCalls == 1 && rows[.answers]?.measuredCalls == 0, "a G2 row whose session has no log stays an estimate")
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z")]); rows = finish(&a)
        check(rows[.answers]?.calls == 1 && rows[.answers]?.measuredCalls == 1, "a run with no audit row still counts as a call")
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:30:00Z")]); rows = finish(&a)
        check(rows[.answers] == nil, "a turn outside any run in the same session is not COS's")
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z")])
        a.add(audit("2026-10-30T12:01:00Z", source: "g2-query", caller: "routine:morning-brief", model: "opus")); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.measuredCalls == 1 && rows[.answers] == nil, "a routine's run lands on the routine's row")
        // 6.97 rows. A real row wins for its run, and the slice is for older rows only.
        func real(_ stamp: String, source: String = "g2-query", caller: String = "full_query", model: String = "opus", resolved: String = "", run: String = "", session: String = "", usd: Double? = nil, input: Int64 = 1000, output: Int64 = 0, read: Int64 = 0, write: Int64 = 0, oneHour: Int64? = nil) -> CosAuditRow {
            var json: [String: Any] = ["ts": stamp, "source": source, "caller": caller, "model": model, "est_input_tokens": 1, "est_output_tokens": 1, "usage_kind": "provider_final", "input_tokens": input, "output_tokens": output, "cache_read_tokens": read, "cache_write_tokens": write]
            if !resolved.isEmpty { json["resolved_model"] = resolved }
            if !run.isEmpty { json["run_id"] = run }
            if !session.isEmpty { json["cli_session_id"] = session }
            if let usd { json["cost_usd"] = usd }
            if let oneHour { json["cache_write_1h_tokens"] = oneHour }
            return CosAuditRow(json: json)
        }
        let parsedReal = real("2026-10-30T12:00:00Z", resolved: "claude-opus-5-5", run: "r9", session: "s9", usd: 1.5, input: 1, output: 2, read: 3, write: 4, oneHour: 2)
        check(parsedReal.real == SessionUsageCounts(input: 1, output: 2, cacheRead: 3, cacheWrite: 4) && parsedReal.realOneHour == 2 && parsedReal.realUSD == 1.5 && parsedReal.resolvedModel == "claude-opus-5-5" && parsedReal.runID == "r9" && parsedReal.sessionID == "s9", "a real row's fields are read by name")
        var legacySession = CosAuditRow(json: ["session_id": "older", "usage_kind": "estimated", "input_tokens": 5])
        check(legacySession.sessionID == "older" && legacySession.real == nil, "an estimated row is not real whatever else it carries")
        legacySession = CosAuditRow(json: ["session_id": "cos", "cli_session_id": "provider"])
        check(legacySession.sessionID == "provider", "the provider's session id wins over COS's")
        check(real("2026-10-30T12:00:00Z", input: 0).isMeasured, "a real zero is still a measurement")
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z", input: 500_000)])
        a.add(real("2026-10-30T12:01:00Z", run: "r1", usd: 2)); rows = finish(&a)
        check(rows[.answers]?.calls == 1 && rows[.answers]?.measuredUSD == 2, "a real G2 row is not counted again from its session slice")
        check(rows[.answers]?.measuredTokens == 1000 && rows[.answers]?.addsToTotalUSD == 0, "a real G2 row's tokens stand alone and Usage already holds its dollars")
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z")])
        a.add(real("2026-10-30T12:01:00Z", run: "r1", usd: 2))
        a.add(real("2026-10-30T12:01:01Z", caller: "full_query:late_result", run: "r1", usd: 3, input: 500)); rows = finish(&a)
        check(rows[.answers]?.calls == 1 && rows[.answers]?.measuredCalls == 1, "a late result is not another call")
        check(rows[.answers]?.measuredUSD == 5 && rows[.answers]?.measuredTokens == 1500, "a late result sums into its run")
        a = make(runs: [run("r1")], events: [event("2026-10-30T12:00:30Z")])
        a.add(g2Row)
        a.add(real("2026-10-30T12:01:01Z", caller: "full_query:late_result", run: "r1", usd: 3, input: 500)); rows = finish(&a)
        check(abs((rows[.answers]?.measuredUSD ?? 0) - 0.004) < 1e-12 && rows[.answers]?.calls == 1, "a slice already holding a run's late result does not add it twice")
        a = make(); a.add(real("2026-10-30T12:01:01Z", caller: "full_query:late_result", run: "gone", usd: 3)); rows = finish(&a)
        check(rows[.answers]?.calls == 0 && rows[.answers]?.measuredUSD == 3 && rows[.answers]?.unpricedMeasuredCalls == 0, "a late result whose first row aged out adds dollars and no call")
        var lateEstimate = audit("2026-10-30T12:01:01Z", source: "g2-query", caller: "full_query:late_result", model: "opus", input: 1, output: 1); lateEstimate.runID = "gone"
        a = make(); a.add(lateEstimate); rows = finish(&a)
        check(rows[.answers] == nil, "a late result with no real numbers adds nothing")
        // Attached and fork: no run id, the provider's name as model.
        a = make(); a.add(real("2026-10-30T12:00:00Z", source: "g2-attached", caller: "attached_turn", model: "claude", resolved: "claude-sonnet-5-5", session: "s-other")); rows = finish(&a)
        check(rows[.work]?.measuredCalls == 1 && abs((rows[.work]?.measuredUSD ?? 0) - 0.002) < 1e-12, "an attached turn is priced from its resolved model")
        check(rows[.work]?.addsToTotalUSD == 0, "an attached turn is in session logs, so the total does not add it")
        var attachedEstimate = audit("2026-10-30T12:00:00Z", source: "g2-attached", caller: "attached_turn", model: "codex"); attachedEstimate.resolvedModel = ""
        a = make(); a.add(attachedEstimate); rows = finish(&a)
        check(rows[.work]?.estimatedCalls == 1 && rows[.work]?.estimatedUSD == 0, "an estimated attached turn has only a provider name, so no price")
        let workStartAttached = R.epoch("2026-10-30T11:00:00Z")!
        a = make(work: ["claude:s-w": workStartAttached], events: [event("2026-10-30T12:00:00Z", session: "claude:s-w")])
        a.add(real("2026-10-30T12:00:00Z", source: "g2-attached", caller: "attached_turn", model: "claude", resolved: "claude-opus-5-5", session: "s-w", usd: 9))
        var attachedFinish = a.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0)
        check(attachedFinish.rows.isEmpty && abs(attachedFinish.work.widerUSD - 0.004) < 1e-12, "a real row inside a Work session's slice is not counted twice")
        a = make(runs: [run("rd", session: "claude:s-d", start: "2026-10-30T12:00:00Z")], work: ["claude:s-d": workStartAttached])
        a.add(real("2026-10-30T12:01:00Z", caller: "dispatch_task", model: "sonnet", resolved: "claude-sonnet-5-5", run: "rd", session: "s-d", usd: 4))
        a.add(real("2026-10-30T12:01:01Z", caller: "dispatch_task:late_result", model: "sonnet", run: "rd", session: "s-d", usd: 1))
        attachedFinish = a.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0)
        check(attachedFinish.rows.first { $0.category == .work }?.measuredUSD == 5 && attachedFinish.rows.first { $0.category == .work }?.calls == 1, "a dispatch has no log, so its real row and late result are what Work has")
        check(attachedFinish.rows.first { $0.category == .work }?.addsToTotalUSD == 5, "a dispatch adds to the total, because no log holds it")
        // Gist and Ask real rows are the only record: no session is ever opened for them.
        a = make(); a.add(real("2026-10-30T12:00:00Z", source: "meeting-ask", caller: "meeting_ask", model: "claude:claude-sonnet-5-5", session: "ask-session", usd: 0.5)); rows = finish(&a)
        check(rows[.answers]?.measuredUSD == 0.5 && rows[.answers]?.addsToTotalUSD == 0.5, "a real Ask row is measured and adds to the total")
        a = make(gist: [gistRun("2026-10-30T12:00:00Z")]); a.add(real("2026-10-30T12:00:00.010Z", source: "g2-lens-gist", caller: "lens_gist", model: "claude:claude-sonnet-5-5", session: "gist-session", usd: 0.25)); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.calls == 1 && rows[.liveAndUpkeep]?.measuredUSD == 0.25, "a real gist row and its run are one call")
        a = make(); a.add(real("2026-10-30T12:00:00Z", source: "g2-lens-gist", caller: "lens_gist", model: "claude:claude-sonnet-5-5", session: "gist-session", usd: 0.25)); rows = finish(&a)
        check(rows[.liveAndUpkeep]?.measuredUSD == 0.25 && rows[.liveAndUpkeep]?.addsToTotalUSD == 0.25, "a real gist row with no run in the ledger still counts")
        // Work starts own the session from then on, and a dollar is in one place.
        let workStart = R.epoch("2026-10-30T12:10:00Z")!
        a = make(runs: [run("r1")], work: ["claude:s1": workStart], events: [event("2026-10-30T12:00:30Z"), event("2026-10-30T12:05:00Z"), event("2026-10-30T12:20:00Z", input: 2000)])
        a.add(g2Row)
        var finished = a.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0)
        rows = Dictionary(uniqueKeysWithValues: finished.rows.map { ($0.category, $0) })
        check(abs(finished.work.widerUSD - 0.008) < 1e-12 && finished.work.widerTokens == 2000, "Work counts only from the moment the run started")
        check(abs((rows[.answers]?.measuredUSD ?? 0) - 0.004) < 1e-12, "a G2 turn before Work started stays an answer")
        check(finished.work.runs == 1 && finished.work.handoffsFound, "the Work line carries its run count")
        a = make(runs: [run("r2", start: "2026-10-30T12:15:00Z", end: "2026-10-30T12:16:00Z")], work: ["claude:s1": workStart], events: [event("2026-10-30T12:15:30Z")])
        a.add(audit("2026-10-30T12:16:00Z", source: "g2-query", caller: "full_query", model: "opus"))
        finished = a.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0)
        rows = Dictionary(uniqueKeysWithValues: finished.rows.map { ($0.category, $0) })
        check(rows[.answers] == nil && abs(finished.work.widerUSD - 0.004) < 1e-12, "a dispatch's audit row is not also an answer")
        a = make(work: ["codex:t1": workStart], events: [event("2026-10-30T12:20:00Z", session: "codex:t1", input: 100_000, model: "gpt-5.6-terra", provider: "OpenAI"), event("2026-10-30T12:21:00Z", session: "codex:t1", input: 1000, model: "gpt-made-up", provider: "OpenAI")])
        finished = a.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0)
        check(abs(finished.work.widerUSD - 0.2) < 1e-9 && abs(finished.work.addsToTotalUSD - 0.2) < 1e-9, "a slice priced only by a new rate adds to the total, because Usage has no price for it")
        check(finished.work.widerUnpricedEvents == 1, "a Work event with no rate is counted, so the wider figure can say it leaves it out")
        // The Work run itself, as against what the person did later in the session.
        let handoff = R.epoch("2026-10-30T12:00:00Z")!
        func mark(_ at: String, _ kind: CosMarkKind, session: String = "claude:s1") -> CosSliceMark { CosSliceMark(session: session, at: R.epoch(at)!, kind: kind) }
        func workTurns(_ marks: [CosSliceMark], handoffs: [CosWorkRun]? = nil) -> CosWorkSummary {
            var w = make(work: ["claude:s1": handoff], events: [event("2026-10-30T11:59:00Z", input: 1), event("2026-10-30T12:00:10Z", input: 100), event("2026-10-30T12:05:00Z", input: 200), event("2026-10-30T12:10:00Z", input: 400)], handoffs: handoffs, marks: marks)
            return w.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0).work
        }
        var turn = workTurns([mark("2026-10-30T12:00:03Z", .handedIn), mark("2026-10-30T12:05:30Z", .typed)])
        check(turn.measuredTokens == 300, "a typed turn ends the run's window")
        check(turn.widerTokens == 700, "what came after the typed turn stays in the wider figure")
        check(turn.unprovenRuns == 0, "a typed turn is a provable end")
        turn = workTurns([mark("2026-10-30T12:00:03Z", .handedIn)])
        check(turn.measuredTokens == 0 && turn.unprovenRuns == 1 && turn.widerTokens == 700, "a run with no provable end is said and stays out of the lead figure")
        turn = workTurns([mark("2026-10-30T12:00:03Z", .handedIn), mark("2026-10-30T12:05:30Z", .end)])
        check(turn.measuredTokens == 300 && turn.unprovenRuns == 0, "with no typed turn, the last finished turn is the end")
        turn = workTurns([mark("2026-10-30T12:00:03Z", .handedIn), mark("2026-10-30T12:04:00Z", .end), mark("2026-10-30T12:05:30Z", .end)])
        check(turn.measuredTokens == 300, "a background task's turn is still the run")
        turn = workTurns([mark("2026-10-30T12:00:00Z", .peer), mark("2026-10-30T12:00:30Z", .typed)])
        check(turn.measuredTokens == 100, "a resumed session: the handed-in message is passed over and the person's first typed turn ends it")
        turn = workTurns([mark("2026-10-30T12:00:03Z", .handedIn), mark("2026-10-30T12:05:30Z", .peer)])
        check(turn.measuredTokens == 300, "another session's message ends the run")
        turn = workTurns([mark("2026-10-30T11:59:30Z", .typed), mark("2026-10-30T12:00:03Z", .handedIn), mark("2026-10-30T12:05:30Z", .typed)])
        check(turn.measuredTokens == 300, "a resumed session: turns before the handoff are not the run's")
        turn = workTurns([mark("2026-10-30T12:08:00Z", .handedIn), mark("2026-10-30T12:10:30Z", .end)])
        check(turn.measuredTokens == 300, "a row long after the handoff is not the run's own prompt")
        turn = workTurns([mark("2026-10-30T12:00:30Z", .typed), mark("2026-10-30T12:05:30Z", .typed)])
        check(turn.measuredTokens == 100, "a person typing right after a handoff ends the run, because their words are not its prompt")
        turn = workTurns([mark("2026-10-30T12:00:20Z", .typed), mark("2026-10-30T12:05:30Z", .typed)], handoffs: [CosWorkRun(session: "claude:s1", start: handoff, openedInApp: true)])
        check(turn.measuredTokens == 300, "a prompt opened in the app and sent by the person is the run's own")
        // The person sends it when they get to it, so there is no delivery limit: five minutes later is still the run's own prompt.
        turn = workTurns([mark("2026-10-30T12:04:00Z", .typed), mark("2026-10-30T12:09:30Z", .typed)], handoffs: [CosWorkRun(session: "claude:s1", start: handoff, openedInApp: true)])
        check(turn.measuredTokens == 300, "a prompt the person sent minutes after opening it in the app is still the run's own")
        turn = workTurns([mark("2026-10-30T12:04:00Z", .typed), mark("2026-10-30T12:09:30Z", .typed)])
        check(turn.measuredTokens == 100, "a typed turn minutes after a handed-in run is the person moving on")
        // A Codex rollout has no typed marker: the turn the person sent opens with task_started, which reads as handed in.
        turn = workTurns([mark("2026-10-30T12:04:00Z", .handedIn), mark("2026-10-30T12:09:30Z", .handedIn)], handoffs: [CosWorkRun(session: "claude:s1", start: handoff, openedInApp: true)])
        check(turn.measuredTokens == 300, "a Codex turn the person sent minutes after opening it in the app is the run's own prompt")
        turn = workTurns([mark("2026-10-30T12:04:00Z", .handedIn), mark("2026-10-30T12:09:30Z", .handedIn)])
        check(turn.measuredTokens == 100, "a Codex turn minutes after a handed-in run is not its prompt")
        turn = workTurns([mark("2026-10-30T12:00:03Z", .handedIn), mark("2026-10-30T12:04:00Z", .handedIn), mark("2026-10-30T12:04:03Z", .end), mark("2026-10-30T12:09:00Z", .end)],
                         handoffs: [CosWorkRun(session: "claude:s1", start: handoff), CosWorkRun(session: "claude:s1", start: R.epoch("2026-10-30T12:03:59Z")!)])
        check(turn.measuredTokens == 300 && turn.widerTokens == 700, "two runs in one session do not count a turn twice")
        var silent = make(work: ["claude:s1": handoff], events: [event("2026-10-30T11:59:00Z", input: 1)])
        check(silent.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 2).work.runsWithoutLogs == 3, "a run with no rows after its start is said as having no log")
        // Row types only. Tool results and system rows are not a person typing.
        func userRow(_ content: Any, origin: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
            var row: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            if let origin { row["origin"] = ["kind": origin] }
            return row.merging(extra) { $1 }
        }
        check(R.claudeMark(userRow("hello", origin: "human")) == .typed && R.claudeMark(userRow([["type": "text", "text": "hello"]], origin: "human")) == .typed && R.claudeMark(userRow([["type": "image"]], origin: "human")) == .typed, "a human row with text or an image is typed")
        check(R.claudeMark(userRow([["type": "tool_result", "content": "x"]])) == nil && R.claudeMark(userRow([["type": "tool_result"], ["type": "text"]], origin: "human")) == nil, "a tool result is never a typed turn")
        check(R.claudeMark(userRow("the words tool_result are in this text", origin: "human")) == .typed, "words in a message do not change its type")
        check(R.claudeMark(userRow("notice", origin: "task-notification")) == nil, "a background task's notice is not a typed turn")
        check(R.claudeMark(userRow("injected", extra: ["isMeta": true])) == nil && R.claudeMark(userRow("summary", extra: ["isCompactSummary": true])) == nil && R.claudeMark(userRow("agent", extra: ["isSidechain": true])) == nil, "system rows and subagent rows are not typed turns")
        check(R.claudeMark(userRow("hi", origin: "peer", extra: ["isMeta": true])) == .peer, "another session's message is its own kind")
        check(R.claudeMark(userRow("prompt")) == .handedIn, "a row with no origin is handed in")
        check(R.claudeMark(["type": "assistant", "message": ["stop_reason": "end_turn"]]) == .end && R.claudeMark(["type": "assistant", "message": ["stop_reason": "tool_use"]]) == nil, "only a finished turn ends one")
        check(R.claudeMark(["type": "assistant", "isSidechain": true, "message": ["stop_reason": "end_turn"]]) == nil, "a subagent finishing is not the run finishing")
        check(R.codexMark(["type": "event_msg", "payload": ["type": "task_started"]]) == .handedIn && R.codexMark(["type": "event_msg", "payload": ["type": "task_complete"]]) == .end && R.codexMark(["type": "event_msg", "payload": ["type": "turn_aborted"]]) == .end, "Codex turns open and close by event type")
        check(R.codexMark(["type": "event_msg", "payload": ["type": "token_count"]]) == nil && R.codexMark(["type": "response_item", "payload": ["type": "message", "role": "user"]]) == nil, "other Codex rows do not move a run")
        check(finished.work.unpricedEvents == 0, "an unpriced row outside a proven window is not in the lead figure")
        // A message copied into a second session happened once, whichever session is read first.
        var copyA = event("2026-10-30T12:00:30Z", session: "claude:s1"); copyA.id = "same-message"
        var copyB = event("2026-10-30T12:00:30Z", session: "claude:s2"); copyB.id = "same-message"
        a = make(runs: [run("r1"), run("r2", session: "claude:s2")], events: [copyA, copyB]); rows = finish(&a)
        let firstOrder = rows[.answers]?.measuredTokens
        a = make(runs: [run("r1"), run("r2", session: "claude:s2")], events: [copyB, copyA]); rows = finish(&a)
        check(firstOrder == 1000 && rows[.answers]?.measuredTokens == 1000, "a message copied into a second session counts once in either order")
        a = make(runs: [run("r2", session: "claude:s2")], work: ["claude:s1": R.epoch("2026-10-30T12:00:00Z")!], events: [copyB, copyA])
        finished = a.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0)
        check(finished.work.widerTokens == 1000 && !finished.rows.contains { $0.category == .answers }, "a copied message goes to Work over a G2 run")
        // The same with the Work session sorting after the G2 one, so plain session order cannot be what decides it.
        a = make(runs: [run("r1")], work: ["claude:s2": R.epoch("2026-10-30T12:00:00Z")!], events: [copyA, copyB])
        finished = a.finish(handoffsFound: true, workRuns: 1, workRunsWithoutLogs: 0)
        check(finished.work.widerTokens == 1000 && !finished.rows.contains { $0.category == .answers }, "a copied message goes to Work over a G2 run")
        // A day ledger with no price at all leaves its tokens out of the dollars, and the row says so.
        a = make()
        a.addDailyTokens(1_000_000, category: .liveAndUpkeep, priced: true, day: "2026-10-30")
        a.addDailyTokens(2_000_000, category: .liveAndUpkeep, priced: false, day: "2026-10-30")
        a.addDailyTokens(5_000_000, category: .other, priced: false, day: "2026-10-30")
        a.addDailyTokens(3_000_000, category: .work, priced: false, day: "2026-10-30")
        rows = finish(&a)
        check(rows[.liveAndUpkeep]?.unpricedLedgerTokens == 2_000_000 && rows[.other]?.unpricedLedgerTokens == 5_000_000 && rows[.liveAndUpkeep]?.measuredTokens == 3_000_000, "unpriced ledger tokens are counted and flagged")
        let ledgerReport: CosUsageReport = { var r = CosUsageReport(windowStart: "2026-10-02", windowEnd: "2026-10-31", timeZone: "America/Chicago", updatedAt: "x", auditFound: true, runLedgersFound: true); r.rows = CosCostCategory.allCases.compactMap { rows[$0] }; return r }()
        check(P.measuredPartial(ledgerReport) && P.rowLine(rows[.liveAndUpkeep]!).figure.hasSuffix("+") && P.rowLine(rows[.liveAndUpkeep]!).mix?.contains("tokens counted by the day have no verified price") == true, "a row with priced and unpriced ledger tokens ends in + and says why")
        check(P.rowLine(rows[.other]!).figure == "No price" && P.measuredPartial(ledgerReport), "a row of unpriced ledger tokens is No price, and the headline figure ends in +")
        check(a.finish(handoffsFound: true, workRuns: 0, workRunsWithoutLogs: 0).work.unpricedEvents > 0, "unpriced ledger tokens in Work make its line end in +")
        // Day ledgers add tokens and dollars, never calls.
        a = make()
        a.addDailyTokens(1_000_000, category: .liveAndUpkeep, priced: true, day: "2026-10-30")
        a.addDailyTokens(1_000_000, category: .liveAndUpkeep, priced: false, day: "2026-10-30")
        a.addDailyTokens(1_000_000, category: .liveAndUpkeep, priced: true, day: "2026-09-01")
        rows = finish(&a)
        check(rows[.liveAndUpkeep]?.calls == 0 && rows[.liveAndUpkeep]?.measuredTokens == 2_000_000, "a day ledger adds tokens and no calls, and only inside the window")
        check(abs((rows[.liveAndUpkeep]?.measuredUSD ?? 0) - 0.042) < 1e-9, "only a priced day ledger adds dollars")

        // The denominator, and the Cursor rule spelled out.
        func report(_ rows: [CosCostRow], work: CosWorkSummary = CosWorkSummary(), stillReading: Int = 0, auditFound: Bool = true) -> CosUsageReport {
            var r = CosUsageReport(windowStart: "2026-10-02", windowEnd: "2026-10-31", timeZone: "America/Chicago", updatedAt: "x", auditFound: auditFound, runLedgersFound: true)
            r.rows = rows; r.work = work; r.sessions.stillReading = stillReading
            return r
        }
        func bucket(_ day: String, _ usd: Double) -> SessionUsageBucket {
            SessionUsageBucket(day: day, provider: "Anthropic", model: "claude-opus-5-5", counts: SessionUsageCounts(input: 1), events: 1, pricedEvents: 1, estimatedUSD: usd)
        }
        var cursorFinal = audit("2026-10-30T12:00:00Z", model: "cursor-grok", kind: "provider_final")
        cursorFinal.realUSD = 7
        a = make(); a.add(cursorFinal); var cursorRows = a.finish(handoffsFound: true, workRuns: 0, workRunsWithoutLogs: 0).rows
        check(cursorRows[0].addsToTotalUSD == 0 && cursorRows[0].addsUnlessCursorFeedUSD == 7, "Cursor spend is held apart from the plain additions")
        var cursorReport = report(cursorRows)
        check(P.ranUSD(usageBuckets: [bucket("2026-10-30", 100)], report: cursorReport, cursorFeedOn: true) == 100, "with the feed on, Usage already holds Cursor spend")
        check(P.ranUSD(usageBuckets: [bucket("2026-10-30", 100)], report: cursorReport, cursorFeedOn: false) == 107, "with the feed off, the total adds Cursor spend")
        check(P.measuredUSD(cursorReport) == 7, "the numerator counts Cursor spend once with the feed on or off")
        cursorFinal.model = "luna-5.6-fast"
        a = make(); a.add(cursorFinal); cursorRows = a.finish(handoffsFound: true, workRuns: 0, workRunsWithoutLogs: 0).rows
        cursorReport = report(cursorRows)
        check(P.ranUSD(usageBuckets: [], report: cursorReport, cursorFeedOn: true) == 0 && P.ranUSD(usageBuckets: [], report: cursorReport, cursorFeedOn: false) == 7, "Luna follows the Cursor rule")
        let cursorGistReport = report(cursorGistRows)
        check(P.ranUSD(usageBuckets: [bucket("2026-10-30", 100)], report: cursorGistReport, cursorFeedOn: true) == 100 && P.ranUSD(usageBuckets: [bucket("2026-10-30", 100)], report: cursorGistReport, cursorFeedOn: false) == 100.25,
              "a Cursor gist run is added to the total only while the feed is off")
        // What the denominator may lean on, from what Usage last reported.
        func usageReport(pending: Int = 0, feed: SessionUsageCursorFeedStatus? = nil, buckets: [SessionUsageBucket] = []) -> SessionUsageReport {
            SessionUsageReport(buckets: buckets, updatedAt: "x", timeZone: "UTC", filesIndexed: 0, pendingFiles: pending, unreadableFiles: 0, malformedRows: 0, missingBaselineEvents: 0, coverage: [], pricingVersion: "x", cursorFeed: feed)
        }
        check(P.usageState(tracking: false, report: usageReport()) == .paused, "paused comes from the switch, whatever the last report said")
        check(P.usageState(tracking: true, report: nil) == .unavailable, "no report yet is no total")
        check(P.usageState(tracking: true, report: usageReport(pending: 3)) == .importing(files: 3), "a log still being read is a total that will grow")
        check(P.usageState(tracking: true, report: usageReport(feed: .init(state: .backfilling))) == .importing(files: 0), "a Cursor read under way is a total that will grow")
        check(P.usageState(tracking: true, report: usageReport(feed: .init(state: .ready))) == .ready, "a finished read is a total to divide by")
        check(P.usageNote(.importing(files: 0))?.contains("Cursor") == true && P.usageNote(.importing(files: 2))?.contains("2 log files") == true, "the note says which read is under way")
        check(P.usageNote(.paused)?.hasPrefix("Tracking is paused") == true && P.usageNote(.paused)?.contains("last read") == true, "the paused words match Usage's bar")
        let readFeed = SessionUsageCursorFeedStatus(state: .ready, lastSuccessAt: "2026-10-30T12:00:00Z")
        check(P.usageHoldsCursor(feedOn: true, usage: usageReport(feed: readFeed), report: cursorReport), "a feed that has read holds Cursor spend")
        check(!P.usageHoldsCursor(feedOn: true, usage: usageReport(feed: .init(state: .keychainBusy)), report: cursorReport), "a feed turned on that has never read holds nothing, so Cursor spend still adds")
        check(!P.usageHoldsCursor(feedOn: false, usage: usageReport(feed: readFeed), report: cursorReport), "a feed turned off with no rows in the window holds nothing")
        func cursorBucket(_ day: String) -> SessionUsageBucket { SessionUsageBucket(day: day, provider: "Cursor", model: "composer-2", counts: SessionUsageCounts(input: 1), events: 1, pricedEvents: 1, estimatedUSD: 7) }
        check(P.usageHoldsCursor(feedOn: false, usage: usageReport(buckets: [cursorBucket("2026-10-30")]), report: cursorReport), "Cursor rows read before the feed was turned off stay in the total")
        check(!P.usageHoldsCursor(feedOn: false, usage: usageReport(buckets: [cursorBucket("2026-08-01")]), report: cursorReport), "Cursor rows outside the window hold nothing for it")
        var adds = CosCostRow(category: .liveAndUpkeep); adds.addsToTotalUSD = 3
        var workAdds = CosWorkSummary(); workAdds.addsToTotalUSD = 2
        check(P.ranUSD(usageBuckets: [bucket("2026-10-30", 100), bucket("2026-10-01", 900)], report: report([adds], work: workAdds), cursorFeedOn: false) == 105, "the total is Usage's window plus what it cannot see")
        // The share never exceeds what it divides, and never divides by a total still moving.
        check(P.share(measured: 5, ran: 100, usage: .ready) == 0.05, "a share is measured over the total")
        check(P.share(measured: 200, ran: 100, usage: .ready) == nil, "a share never exceeds what it divides")
        check(P.share(measured: 5, ran: 100, usage: .paused) == nil, "a paused Usage has no share")
        check(P.share(measured: 5, ran: 100, usage: .importing(files: 3)) == nil, "an importing Usage has no share")
        check(P.share(measured: 5, ran: 0, usage: .ready) == nil && P.share(measured: 0, ran: 100, usage: .ready) == nil, "no total or no measurement has no share")
        check(P.share(measured: 5, ran: 100, usage: .ready, auditUnreadable: true) == nil && P.share(measured: 5, ran: 100, usage: .ready, auditUnreadable: false) == 0.05, "an audit that would not open leaves calls out of the numerator, so there is no share")
        // The headline, literally.
        var m = CosCostRow(category: .answers); m.calls = 10; m.measuredCalls = 10; m.measuredUSD = 284
        var e = CosCostRow(category: .dictation); e.calls = 1685; e.estimatedCalls = 1685; e.estimatedUSD = 0.44
        check(P.headline(report: report([m, e]), ran: 18_612, usage: .ready) == "Measured: COS used $284 of the $18,612 you ran in the last 30 days. 1,685 more calls have only character counts, so the real figure is higher.", "the mixed headline says measured, total and the calls left out")
        check(P.headline(report: report([m]), ran: 18_612, usage: .ready) == "Measured: COS used $284 of the $18,612 you ran in the last 30 days.", "a fully measured headline has no second sentence")
        check(P.headline(report: report([e]), ran: 18_612, usage: .ready) == "COS made 1,685 calls in the last 30 days. This server doesn't measure their cost yet.", "with nothing measured the headline names no dollars")
        check(!P.headline(report: report([e]), ran: 18_612, usage: .ready).contains("$"), "an estimate never reaches the headline's dollars")
        check(P.headline(report: report([]), ran: 0, usage: .ready) == "COS made no calls in the last 30 days.", "no calls says so")
        check(P.headline(report: report([], auditFound: false), ran: 0, usage: .ready).hasPrefix("COS has no record"), "no ledger says so")
        check(P.headline(report: report([m]), ran: 18_612, usage: .paused) == "Measured: COS used $284 in the last 30 days.", "a paused Usage drops the total from the headline")
        check(P.headline(report: report([m]), ran: 18_612, usage: .importing(files: 3)) == "Measured: COS used $284 of the $18,612 read so far in the last 30 days.", "an importing Usage says so far")
        check(P.headline(report: report([m], stillReading: 2), ran: 18_612, usage: .ready).hasPrefix("Measured so far: COS used $284"), "sessions still being read say so far")
        check(P.headline(report: report([m]), ran: 100, usage: .ready) == "Measured: COS used $284 in the last 30 days.", "a figure bigger than the total drops the total")
        var one = CosCostRow(category: .answers); one.calls = 1; one.estimatedCalls = 1
        check(P.headline(report: report([one]), ran: 1, usage: .ready) == "COS made 1 call in the last 30 days. This server doesn't measure their cost yet.", "one call is singular")
        var unpriced = CosCostRow(category: .answers); unpriced.calls = 4; unpriced.measuredCalls = 4; unpriced.unpricedMeasuredCalls = 4; unpriced.measuredTokens = 1000
        check(P.headline(report: report([unpriced]), ran: 1, usage: .ready).contains("no verified price"), "measured calls with no rate say so instead of $0")
        check(P.overhead(report([m, CosCostRow(category: .work, calls: 9, estimatedCalls: 9)])).count == 1 && P.calls(report([m, CosCostRow(category: .work, calls: 9, estimatedCalls: 9)])) == 10, "Work stays out of COS's own figure")
        // A figure that leaves out calls with no rate ends in +, as Usage's do, and the row says how many.
        var partialRow = m; partialRow.unpricedMeasuredCalls = 2
        check(P.rowLine(partialRow).figure == "$284+" && P.rowLine(partialRow).mix == "2 measured calls have no verified price, so the dollars are a floor.", "a row that leaves out calls with no rate says so")
        partialRow.unpricedMeasuredCalls = 1
        check(P.rowLine(partialRow).mix == "1 measured call has no verified price, so the dollars are a floor.", "one call is singular")
        check(P.rowLine(m).figure == "$284" && P.rowLine(m).mix == nil, "a fully priced row has no +")
        check(P.headline(report: report([partialRow]), ran: 18_612, usage: .ready) == "Measured: COS used $284+ of the $18,612 you ran in the last 30 days.", "the headline's measured figure ends in + when calls were left out")
        check(P.headline(report: report([m]), ran: 18_612, usage: .ready, ranPartial: true) == "Measured: COS used $284 of the $18,612+ you ran in the last 30 days.", "the total ends in + when some of the person's own usage has no price")
        check(P.headline(report: report([m]), ran: 18_612, usage: .importing(files: 2), ranPartial: true).contains("$18,612+ read so far"), "an importing total ends in + too")
        // Usage's own buckets decide whether the total leaves something out.
        func partialBucket(_ day: String, events: Int, priced: Int) -> SessionUsageBucket { SessionUsageBucket(day: day, provider: "OpenAI", model: "gpt-made-up", counts: SessionUsageCounts(input: 1), events: events, pricedEvents: priced, estimatedUSD: 0) }
        check(P.ranPartial(usageBuckets: [bucket("2026-10-30", 5), partialBucket("2026-10-30", events: 3, priced: 0)], report: report([m]), usage: .ready), "a bucket with no price in the window makes the total partial")
        check(P.ranPartial(usageBuckets: [partialBucket("2026-10-30", events: 3, priced: 2)], report: report([m]), usage: .ready), "a bucket with some events unpriced makes the total partial")
        check(!P.ranPartial(usageBuckets: [bucket("2026-10-30", 5)], report: report([m]), usage: .ready), "a fully priced window is not partial")
        check(!P.ranPartial(usageBuckets: [partialBucket("2026-08-01", events: 3, priced: 0)], report: report([m]), usage: .ready), "an unpriced bucket outside the window is not this window's")
        check(!P.ranPartial(usageBuckets: [partialBucket("2026-10-30", events: 3, priced: 0)], report: report([m]), usage: .paused) && !P.ranPartial(usageBuckets: [partialBucket("2026-10-30", events: 3, priced: 0)], report: report([m]), usage: .unavailable), "a total that is not shown has nothing to qualify")
        check(P.compareLine(share: 0.015, price: 200, lean: .ceiling) == "Up to about 1.5% of your usage, so up to $3.00 of your $200.", "a share against a partial total is a ceiling")
        // A model with no price sits in both figures, so with both partial the share is not a ceiling and not a floor.
        check(P.shareLean(ranPartial: true, measuredPartial: false) == .ceiling && P.shareLean(ranPartial: true, measuredPartial: true) == .either && P.shareLean(ranPartial: false, measuredPartial: true) == .plain && P.shareLean(ranPartial: false, measuredPartial: false) == .plain, "only a partial total beside complete calls is a ceiling")
        let either = P.compareLine(share: 0.015, price: 200, lean: .either) ?? ""
        check(either.hasPrefix("About 1.5% of your usage") && !either.contains("Up to") && either.hasSuffix("the true share can be higher or lower.") && either.contains("Both figures leave something out"), "with both partial the words say it can go either way")
        // A ceiling needs COS's side complete: calls with only character counts, logs not read, logs gone or unreadable all shorten it.
        check(P.shareLean(report([m]), ranPartial: true) == .ceiling, "a partial total beside a complete COS side is a ceiling")
        check(P.shareLean(report([m, e]), ranPartial: true) == .either, "estimated calls shorten COS's side, so no ceiling")
        for (label, change) in [("compressed logs not read", { (r: inout CosUsageReport) in r.sessions.compressed = 1 }), ("sessions with no log", { (r: inout CosUsageReport) in r.sessions.noLogs = 1 }),
                                ("sessions still being read", { (r: inout CosUsageReport) in r.sessions.stillReading = 1 }), ("a busy pass", { (r: inout CosUsageReport) in r.sessions.busy = true })] {
            var short = report([m]); change(&short)
            check(P.shareLean(short, ranPartial: true) == .either && P.shareLean(short, ranPartial: false) == .plain, "\(label) shorten COS's side, so no ceiling")
        }
        check(P.sessionNotes(report([m, e]), ranPartial: true).contains { $0.hasSuffix("so the share can be higher or lower.") } && P.sessionNotes(report([m]), ranPartial: true).contains { $0.contains("COS's share of it is lower") }, "the footer reads the same rule as the figure")
        // A sum under a cent has no 'roughly' or 'up to' in front of it.
        check(P.compareLine(share: 0.05, price: 0.1) == "About 5.0% of your usage, under 1¢ of your $0.10." && P.compareLine(share: 0.05, price: 0.1, lean: .ceiling) == "Up to about 5.0% of your usage, so under 1¢ of your $0.10.", "a small sum is a bound, not roughly under")
        check(P.compareLine(share: 0.0004, price: 0.5) == "Under 0.1% of your usage, so under 1¢ of your $0.50.", "under a tenth of a percent of a small price is under a cent, not under under")
        check(P.compareLine(share: 0.0004, price: 200) == "Under 0.1% of your usage, so under $0.20 of your $200." && !(P.compareLine(share: 0.0004, price: 200, lean: .ceiling) ?? "").contains("about under"), "a share under a tenth of a percent has no 'about under'")
        var bothPartial = report([m]); bothPartial.rows[0].unpricedMeasuredCalls = 1
        check(P.sessionNotes(bothPartial, ranPartial: true).contains { $0.hasPrefix("Some of your own sessions use models with no verified price, and COS's own figure leaves some calls out too.") && $0.hasSuffix("the share can be higher or lower.") } && !P.sessionNotes(bothPartial, ranPartial: true).contains { $0.contains("COS's share of it is lower") }, "the footer does not claim the share is lower when both figures are partial")
        check(P.sessionNotes(report([m]), ranPartial: true).contains { $0.hasPrefix("Some of your own sessions use models with no verified price") } && !P.sessionNotes(report([m])).contains { $0.hasPrefix("Some of your own sessions") }, "one line says the total is low when it is")
        check(P.method(report([m])).contains { $0.contains("ends in a +") }, "the method says what a + means")
        // Estimated calls with a price for only some of them do not say "the rest".
        var mixSome = CosCostRow(category: .liveAndUpkeep); mixSome.calls = 1433; mixSome.measuredCalls = 694; mixSome.measuredUSD = 4.31; mixSome.measuredTokens = 989_491; mixSome.estimatedCalls = 739; mixSome.estimatedPricedCalls = 300; mixSome.estimatedUSD = 1.1
        check(P.rowLine(mixSome).mix == "694 measured, at least $1.10 estimated for 300 of the 739 others.", "a mix that prices only some of the rest says how many")
        var mixAll = mixSome; mixAll.estimatedPricedCalls = 739
        check(P.rowLine(mixAll).mix == "694 measured, at least $1.10 estimated for the rest.", "a mix that prices all of the rest says the rest")
        // Work and day ledgers hold usage with no call behind it, so the headline does not say there were no calls.
        var daily = CosCostRow(category: .liveAndUpkeep); daily.measuredTokens = 5_000_000
        check(P.headline(report: report([daily]), ran: 100, usage: .ready) == "COS made no counted calls in the last 30 days. Its Work and background usage is below.", "day-ledger usage with no calls is not no usage")
        var workOnlyReport = report([]); workOnlyReport.work.measuredTokens = 100; workOnlyReport.work.measuredUSD = 3
        check(P.headline(report: workOnlyReport, ran: 100, usage: .ready) == "COS made no counted calls in the last 30 days. Its Work and background usage is below.", "Work usage with no calls is not no usage")
        var widerOnlyReport = report([]); widerOnlyReport.work.widerTokens = 100
        check(P.headline(report: widerOnlyReport, ran: 100, usage: .ready).hasPrefix("COS made no counted calls"), "the wider Work figure is usage too")
        // Nothing measured: the words say why, and blame the server only when nothing else could be the reason.
        check(P.headline(report: report([e]), ran: 18_612, usage: .paused) == "COS made 1,685 calls in the last 30 days. Tracking is paused, so the session logs that could hold their cost are not being read.", "a paused page does not blame the server")
        check(P.headline(report: report([e], stillReading: 2), ran: 18_612, usage: .ready) == "COS made 1,685 calls in the last 30 days. Still reading the session logs that could hold their cost.", "sessions still being read are the reason, not the server")
        var busyE = report([e]); busyE.sessions.busy = true
        check(P.headline(report: busyE, ran: 18_612, usage: .ready).hasSuffix("Still reading the session logs that could hold their cost."), "a busy history is the same")
        // A busy pass keeps no progress, and still counts as reading.
        var busyM = report([m]); busyM.sessions.busy = true
        check(CosSliceProgress(busy: true).reading && CosSliceProgress(stillReading: 1).reading && !CosSliceProgress().reading, "reading is progress or a busy pass")
        check(P.headline(report: busyM, ran: 18_612, usage: .ready).hasPrefix("Measured so far: COS used $284"), "a busy pass says so far")
        check(P.stillReadingNote(busyM).hasPrefix("Still reading. The usage history was busy") && !P.stillReadingNote(busyM).contains("0 sessions"), "a busy pass says still reading, with no count it does not have")
        check(P.sessionNotes(busyM).contains("The usage history was busy, so this pass read nothing new. COS tries again soon."), "the footer promises no number the loop may not keep")
        var failedM = report([m]); failedM.sessions.failed = true
        check(!failedM.sessions.reading && !failedM.sessions.busy, "a failed read is not reading and not busy")
        check(P.sessionNotes(failedM).contains("COS could not read the usage history, so this pass read nothing new. It tries again in \(P.slowSeconds / 60) minutes."), "a failed read says so, with the pace the loop keeps")
        check(P.headline(report: failedM, ran: 18_612, usage: .ready).hasPrefix("Measured so far: COS used $284"), "a failed read says so far")
        var failedE = report([e]); failedE.sessions.failed = true
        check(P.headline(report: failedE, ran: 18_612, usage: .ready).hasSuffix("COS could not read the usage history, so the session logs that could hold their cost are missing from this pass."), "a failed read says why nothing is measured")
        // An audit that is there and cannot be opened is said, in the headline.
        var unreadableNone = report([]); unreadableNone.auditUnreadable = true
        check(P.headline(report: unreadableNone, ran: 0, usage: .ready) == "COS could not read its record of calls, so there is no count to show.", "an unreadable audit does not read as no calls")
        var unreadableSome = report([m, e]); unreadableSome.auditUnreadable = true
        check(P.headline(report: unreadableSome, ran: 18_612, usage: .ready).hasSuffix(" COS could not read its record of calls, so some are missing here."), "an unreadable audit with other calls says some are missing")
        check(P.headline(report: report([m, e]), ran: 18_612, usage: .ready) == P.headline(report: unreadableSome, ran: 18_612, usage: .ready).replacingOccurrences(of: " COS could not read its record of calls, so some are missing here.", with: ""), "nothing else changes")
        // Rows.
        check(P.atLeast(0.44) == "at least $0.44" && P.atLeast(0.001) == "at least a fraction of 1¢", "a floor under a cent does not contradict itself")
        check(P.money(0.444) == "$0.44" && P.money(284.4) == "$284" && P.money(18612) == "$18,612" && P.money(0.001) == "under 1¢", "money keeps cents only when they matter")
        let measuredLine = P.rowLine(m)
        check(measuredLine.evidence == .measured && measuredLine.figure == "$284" && measuredLine.mix == nil, "a measured row shows measured dollars")
        let estimatedLine = P.rowLine(e)
        check(estimatedLine.evidence == .estimated && estimatedLine.figure == "Estimated" && estimatedLine.detail == "at least $0.44" && estimatedLine.count == "1,685 dictations", "an estimated row says Estimated, at least, with its noun")
        var mix = CosCostRow(category: .liveAndUpkeep); mix.calls = 1433; mix.measuredCalls = 694; mix.measuredUSD = 4.31; mix.measuredTokens = 989_491; mix.estimatedCalls = 739; mix.estimatedUSD = 1.1
        check(P.rowLine(mix).mix == "694 measured, at least $1.10 estimated for the rest.", "a row with a mix says how many calls were measured")
        var mixNoRate = mix; mixNoRate.estimatedUSD = 0
        check(P.rowLine(mixNoRate).mix == "694 measured, no verified price for the rest.", "a mix with no rate for the rest says so")
        var noRate = CosCostRow(category: .other); noRate.calls = 8; noRate.estimatedCalls = 8; noRate.estimatedTokens = 12_000
        check(P.rowLine(noRate).evidence == .noPrice && P.rowLine(noRate).figure == "No price" && P.rowLine(noRate).detail == "12.0K tokens", "a model with no rate shows tokens and No price")
        check(P.rowLine(CosCostRow(category: .transcription)).count == "None in the last 30 days" && P.rowLine(CosCostRow(category: .transcription)).evidence == .none, "an empty row says none")
        var bigFloor = CosCostRow(category: .memoryIndexing); bigFloor.calls = 2725; bigFloor.estimatedCalls = 2725; bigFloor.estimatedUSD = 900
        var small = CosCostRow(category: .answers); small.calls = 3; small.measuredCalls = 3; small.measuredUSD = 2
        let lines = P.rowLines(report([bigFloor, small, noRate]))
        check(lines.map(\.id) == [.answers, .memoryIndexing, .other, .dictation, .transcription], "estimated rows sort below measured ones, then No price, then empty")
        check(lines[0].measuredFraction > 0 && lines[0].estimatedFraction == 0 && lines[1].estimatedFraction == 1 && lines[1].measuredFraction == 0, "a bar keeps measured and estimated apart")
        // What you pay.
        check(P.monthlyPrice("$200") == 200 && P.monthlyPrice(" 1,200.50 ") == 1200.5, "a price reads with a dollar sign and commas")
        check(P.monthlyPrice("") == nil && P.monthlyPrice("free") == nil && P.monthlyPrice("0") == nil && P.monthlyPrice("-5") == nil, "anything else is no price")
        check(P.compareLine(share: 0.015, price: 200) == "About 1.5% of your usage, roughly $3.00 of your $200.", "the comparison is share times price")
        check(P.compareLine(share: nil, price: 200) == nil && P.compareLine(share: 0.015, price: nil) == nil, "no share or no price compares nothing")
        // Notes and the Work words.
        var progress = report([m]); progress.sessions = CosSliceProgress(tracked: 9, stillReading: 2, noLogs: 1, compressed: 3, busy: true); progress.undatedCalls = 4; progress.unreadableRows = 1
        let notes = P.sessionNotes(progress)
        check(P.stillReadingNote(progress).hasPrefix("Still reading 2 sessions") && notes.contains { $0.hasPrefix("3 sessions are compressed") } && notes.contains { $0.hasPrefix("1 session has no log") }, "the page says what is not in yet")
        check(P.headlineParts(report: report([m, e]), ran: 18_612, usage: .ready).caveat == " 1,685 more calls have only character counts, so the real figure is higher.", "the caveat is its own part of the headline")
        check(P.showsDollars(report([m])) && P.showsDollars(report([e])) && !P.showsDollars(report([one])), "the page says what the dollars are only when it shows some")
        check(P.compareHint(share: nil, price: nil).contains("never sent") && P.compareHint(share: nil, price: 20).contains("needs a current Usage total") && P.compareHint(share: nil, price: nil, measured: false) == "There are no measured calls yet. Once COS has some, this shows its share of what you pay. Your price stays on this Mac.", "the price field says what it does and why it cannot yet")
        check(!P.compareHint(share: nil, price: nil, measured: false).contains("server"), "the price field promises nothing of a server")
        let unpricedHint = P.compareHint(share: nil, price: nil, measured: false, measuredCalls: 4)
        check(unpricedHint.hasPrefix("COS has measured calls, but none has a verified price") && !unpricedHint.contains("no measured calls") && !unpricedHint.contains("server"), "measured calls with no price are not 'no measured calls'")
        check(P.compareHint(share: nil, price: nil, measured: true, measuredCalls: 4).contains("never sent"), "a priced measured figure keeps its ordinary hint")
        var quietReport = report([]); quietReport.runLedgersFound = false
        check(P.sessionNotes(quietReport).isEmpty && !P.sessionNotes({ var r = report([m]); r.runLedgersFound = false; return r }()).isEmpty, "the run record note appears when there are answers for it to explain")
        check(P.sessionNotes({ var r = report([e]); r.runLedgersFound = false; return r }()).isEmpty, "the run record note is about the Answers row, so dictation alone does not get it")
        var approximate = report([m]); approximate.rows[0].approximateMatches = 3
        check(P.method(approximate).contains { $0.hasPrefix("3 calls were matched") } && !P.method(report([m])).contains { $0.contains("matched to") }, "the method says how many matches are approximate")
        check(notes.contains { $0.hasPrefix("4 calls have no readable date") } && notes.contains { $0.hasPrefix("1 line could not") }, "undated and unreadable rows are said, not dropped")
        check(P.workCount(CosWorkSummary()) == "This Mac has no record of Work runs." && P.workCount(CosWorkSummary(handoffsFound: true, runs: 27)) == "27 runs you started", "the Work line says how many runs, or that there is no record")
        var workMeasured = CosCostRow(category: .work); workMeasured.measuredUSD = 2; workMeasured.measuredTokens = 10; workMeasured.calls = 5; workMeasured.estimatedCalls = 4; workMeasured.estimatedUSD = 0.6
        var workReport = report([workMeasured]); workReport.work.measuredUSD = 300; workReport.work.measuredTokens = 100; workReport.work.widerUSD = 4002
        check(P.workUSD(workReport) == 302 && P.workTokens(workReport) == 110 && P.workFigure(workReport) == "$302", "the Work line adds its slices and its real rows")
        check(P.workWider(workReport) == "$4,004 if you count what you did later in those sessions.", "the wider figure is said plainly")
        var workPartialReport = workReport; workPartialReport.work.unpricedEvents = 2
        check(P.workFigure(workPartialReport) == "$302+" && P.workFigure(workReport) == "$302", "the Work figure ends in + when events had no rate")
        workPartialReport.work.widerUnpricedEvents = 1
        check(P.workWider(workPartialReport) == "$4,004+ if you count what you did later in those sessions.", "the wider figure ends in + when events had no rate")
        var workRowPartial = workReport; workRowPartial.rows[0].unpricedMeasuredCalls = 1
        check(P.workFigure(workRowPartial) == "$302+", "a real Work row with no rate marks the Work figure too")
        workReport.work.widerUSD = 300
        check(P.workWider(workReport) == nil, "with nothing later, there is no wider figure to say")
        check(P.workUnproven(CosWorkSummary(unprovenRuns: 2)) == "2 runs have no provable end, so they are only in the wider figure." && P.workUnproven(CosWorkSummary()) == nil, "runs with no provable end are said, not guessed")
        var withWork = report([m]); withWork.work.widerUSD = 9_000; withWork.work.measuredUSD = 8_000
        check(P.measuredUSD(withWork) == 284 && P.headline(report: withWork, ran: 18_612, usage: .ready).hasPrefix("Measured: COS used $284 of"), "neither Work figure reaches the headline or a share")
        check(P.workBackground(workReport) == "Plus 4 background calls, at least $0.60 estimated.", "Work's character-count rows sit beside the figure, not in it")
        for text in notes + P.method(approximate) + [P.workMethod, P.headline(report: report([m, e]), ran: 1000, usage: .ready), P.compareHint(share: 0.1, price: 20)] {
            check(!text.contains("\u{2014}") && !text.contains("\u{2192}") && !text.contains("->"), "page copy has no em dash or arrow")
        }

        // The reader, on a scratch home. Nothing here touches a real file.
        let root = home.appendingPathComponent("cos-cost-home")
        let fm = FileManager.default
        func write(_ relative: String, _ text: String) throws {
            let file = root.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n" }
        func claudeRow(_ id: String, _ time: String, session: String, output: Int = 20) throws -> String {
            try json(["type": "assistant", "timestamp": time, "sessionId": session, "message": ["id": id, "model": "claude-opus-5-5", "usage": ["input_tokens": 1000, "output_tokens": output, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0], "content": [["text": "SECRET_PROMPT_NEVER_STORE"]]]])
        }
        let now = R.epoch("2026-10-31T12:00:00Z").map { Date(timeIntervalSince1970: $0) }!
        let scripts = root.appendingPathComponent("scripts").path
        // Nothing there at all: a valid report that says so, no crash.
        let empty = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-empty.sqlite"), timeZone: chicago)
        let nothing = try empty.cosUsage(plistScripts: nil, dataDirectory: nil, importSessions: true, now: now)
        check(!nothing.auditFound && !nothing.runLedgersFound && !nothing.gistLedgerFound && !nothing.work.handoffsFound && nothing.rows.isEmpty && nothing.sessions.tracked == 0, "missing ledgers give a valid report that says so")
        check(nothing.windowStart == "2026-10-02" && nothing.windowEnd == "2026-10-31", "the window is the same 30 days Usage shows")
        try write(".claude/projects/p1/s-main.jsonl", try claudeRow("m1", "2026-10-30T12:00:30Z", session: "s-main") + claudeRow("m1", "2026-10-30T12:00:31Z", session: "s-main", output: 40)
            + claudeRow("copied", "2026-10-30T12:00:32Z", session: "someone-else") + "{not json at all but it says \"assistant\" and \"usage\"\n" + "{\"type\":\"user\",\"sessionId\":\"s-main\",\"message\":{\"content\":\"SECRET_PROMPT_NEVER_STORE\"}}\n")
        try write(".claude/projects/p1/s-main/subagents/agent-1.jsonl", try claudeRow("sub1", "2026-10-30T12:00:40Z", session: "s-main"))
        try write(".claude/projects/p2/s-work.jsonl", try claudeRow("w-before", "2026-10-30T10:00:00Z", session: "s-work") + claudeRow("w-after", "2026-10-30T13:00:00Z", session: "s-work"))
        try write(".claude/projects/p2/s-old.jsonl", try claudeRow("ancient", "2026-08-01T10:00:00Z", session: "s-old") + claudeRow("fresh", "2026-10-30T14:00:30Z", session: "s-old"))
        try write(".codex/sessions/2026/10/30/rollout-2026-10-30T12-00-00-11111111-1111-1111-1111-111111111111.jsonl",
            try json(["type": "session_meta", "payload": ["id": "11111111-1111-1111-1111-111111111111", "model_provider": "openai"]]) + json(["type": "turn_context", "payload": ["model": "gpt-5.6-terra"]])
            + json(["type": "event_msg", "timestamp": "2026-10-30T15:00:30Z", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 1_000, "output_tokens": 100, "cached_input_tokens": 0], "last_token_usage": ["input_tokens": 1_000, "output_tokens": 100, "cached_input_tokens": 0]]]]))
        try write(".codex/sessions/2026/10/30/rollout-2026-10-30T12-00-00-22222222-2222-2222-2222-222222222222.jsonl.zst", "not really zstd")
        func runLine(_ id: String, _ patch: [String: Any]) throws -> String { try json(["runId": id, "ts": "2026-10-30T12:00:00Z", "patch": patch]) }
        try write(".cos-glasses/data/claude-runs.jsonl", try runLine("r1", ["cliSessionId": "s-main", "model": "opus", "createdAt": "2026-10-30T12:00:00Z", "updatedAt": "2026-10-30T12:00:50Z", "cliCommand": "SECRET_PROMPT_NEVER_STORE"]) + runLine("r1", ["status": "completed", "updatedAt": "2026-10-30T12:01:00Z"])
            + runLine("r-old", ["cliSessionId": "s-old", "model": "opus", "createdAt": "2026-10-30T14:00:00Z", "updatedAt": "2026-10-30T14:01:00Z"])
            + runLine("r-gone", ["cliSessionId": "s-gone", "model": "opus", "createdAt": "2026-10-30T15:00:00Z", "updatedAt": "2026-10-30T15:01:00Z"])
            + runLine("r-ancient", ["cliSessionId": "s-ancient", "model": "opus", "createdAt": "2026-05-30T15:00:00Z", "updatedAt": "2026-05-30T15:01:00Z"]))
        try write(".cos-glasses/data/codex-runs.jsonl", try runLine("x1", ["codexThreadId": "11111111-1111-1111-1111-111111111111", "model": "codex-balanced", "createdAt": "2026-10-30T15:00:00Z", "updatedAt": "2026-10-30T15:01:00Z"])
            + runLine("x2", ["codexThreadId": "22222222-2222-2222-2222-222222222222", "model": "codex-frontier", "createdAt": "2026-10-30T16:00:00Z", "updatedAt": "2026-10-30T16:01:00Z"]))
        try write(".cos-glasses/data/lens-gist-runs.jsonl", try json(["engine": "claude", "model": "claude-sonnet-5-5", "ok": true, "ms": 900, "at": "2026-10-30T17:00:00.020Z", "kind": "session", "usage": ["inputTokens": 1000, "cachedInputTokens": 0, "outputTokens": 100, "costUsd": 0.25]]))
        try write(".cos-glasses/data/jev-cues-usage.json", try json(["2026-10-30": 1_000_000, "2026-08-01": 5_000_000]))
        try write(".cos-glasses/data/subq-completion-usage.json", try json(["2026-10-30": 3000]))
        // Shaped like a day ledger on purpose: if anything reads these, their tokens land on a row and the checks below fail.
        for name in ["subq-key.json", "jev-key.json", "subq-usage-key.json"] {
            try write(".cos-glasses/data/\(name)", try json(["2026-10-30": 777_000_000, "key": "SECRET_KEY_NEVER_READ"]))
        }
        try write("Library/Application Support/COS Control/work-handoffs/handoffs.json", try json(["receipts": [
            ["createdAt": R.epoch("2026-10-30T12:30:00Z")!, "sessionID": "claude:s-work", "provider": "claude", "status": "delivered", "prompt": "SECRET_PROMPT_NEVER_STORE"],
            ["createdAt": R.epoch("2026-10-30T12:40:00Z")!, "sessionID": "cursor:c1", "provider": "cursor", "status": "completed"],
            ["createdAt": R.epoch("2026-10-30T12:50:00Z")!, "sessionID": "claude:s-work", "provider": "claude", "status": "failed"],
            ["createdAt": R.epoch("2026-08-30T12:50:00Z")!, "sessionID": "claude:s-long-ago", "provider": "claude", "status": "delivered"],
        ], "sessions": [], "drafts": [], "version": 1]))
        let auditText = try json(["ts": "2026-10-30T12:00:55-0500", "source": "g2-dictation-autoclean", "model": "sonnet", "input_chars": 40, "output_chars": 40, "est_input_tokens": 1000, "est_output_tokens": 100, "caller": "dictation_autoclean_message"])
            + json(["ts": "2026-10-30T12:00:59.000Z", "source": "g2-query", "model": "opus", "est_input_tokens": 9000, "est_output_tokens": 100, "caller": "full_query", "duration_ms": 1])
            + json(["ts": "2026-10-30T17:00:00.010Z", "source": "g2-lens-gist", "model": "claude:claude-sonnet-5-5", "est_input_tokens": 300, "est_output_tokens": 30, "caller": "lens_gist"])
            + json(["ts": "not a date", "source": "cos-script", "model": "haiku", "est_input_tokens": 1, "est_output_tokens": 1, "caller": "lightrag"])
            + "{this line is torn\n"
            + json(["ts": "2026-10-30T12:00:00-0500", "source": "cos-script", "model": "codex:gpt-5.6-terra", "est_input_tokens": 1000, "est_output_tokens": 0, "caller": "lightrag"])
        try write("scripts/.cos_token_audit.jsonl", auditText + "{\"ts\":\"2026-10-30T12:00:00-0500\",\"source\":\"half a li")
        try write(".cos-glasses/token-audit.jsonl", try json(["ts": "2026-10-30T12:00:00-0500", "source": "cos-script", "model": "haiku", "est_input_tokens": 1, "est_output_tokens": 1, "caller": "home_file_row"]))
        let db = home.appendingPathComponent("cos-real.sqlite")
        let collector = try SessionUsageCollector(home: root, database: db, timeZone: chicago)
        let paused = try collector.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: false, now: now)
        check(paused.sessions.tracked == 6 && paused.rows.first { $0.category == .answers }?.measuredCalls == 0, "a paused Usage reads no session logs")
        var opened: [String] = []
        let full = try collector.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now, opened: { opened.append($0) })
        func row(_ c: CosCostCategory, _ r: CosUsageReport) -> CosCostRow { r.rows.first { $0.category == c } ?? CosCostRow(category: c) }
        check(!opened.contains { $0.lowercased().contains("key") }, "a pass never opens a key file")
        check(Set(opened) == Set(R.dataFiles + ["handoffs.json", ".cos_token_audit.jsonl"]), "a pass opens exactly the fixed file list")
        check(!opened.contains(".env"), "with the server's scripts folder known, .env is never opened")
        check(full.rows.reduce(Int64(0)) { $0 + $1.measuredTokens } + full.work.measuredTokens < 700_000_000, "a key file's numbers never reach a row")
        check(full.auditFound && full.runLedgersFound && full.gistLedgerFound && full.work.handoffsFound, "the reader finds each ledger")
        check(row(.other, full).calls == 0, "the server's audit is read and the home file does not mix in")
        check(full.undatedCalls == 1, "the reader counts an undated audit row")
        check(full.unreadableRows == 1, "a torn line is unreadable and a half-written last line waits")
        let answers = row(.answers, full)
        // s-main: m1 at its fullest (1040) plus the subagent (1020), not the other session's row. s-old: fresh only (1020). x1 is Codex (1100, priced by the new rate). s-gone and x2 have no readable log.
        check(answers.measuredTokens == 1040 + 1020 + 1020 + 1100, "a slice keeps one fragment per message, adds subagents and leaves another session's rows out")
        check(answers.calls == 3 && answers.measuredCalls == 3, "three runs with logs are three measured answers")
        check(abs(answers.addsToTotalUSD - (1000*2.0 + 100*12.0)/1_000_000) < 1e-9, "only the Codex slice on a new rate adds to the total")
        check(row(.dictation, full).estimatedCalls == 1, "polish stays an estimate")
        check(row(.liveAndUpkeep, full).measuredCalls == 1 && row(.liveAndUpkeep, full).estimatedCalls == 0, "the reader dedupes a gist row against its run")
        check(abs(row(.liveAndUpkeep, full).measuredUSD - (0.25 + 0.042)) < 1e-9, "a gist's cost and a priced day ledger add up, and the old day is out")
        check(row(.memoryIndexing, full).estimatedCalls == 1 && abs(row(.memoryIndexing, full).estimatedUSD - 0.002) < 1e-9, "LightRAG on terra has a floor at the verified rate")
        check(row(.other, full).measuredTokens == 3000 && row(.other, full).measuredUSD == 0, "a SubQ day ledger has tokens and no price")
        check(full.sessions.noLogs == 1 && full.sessions.compressed == 1 && full.sessions.stillReading == 0, "the reader says which sessions have no log and which are compressed")
        check(full.work.runs == 2 && full.work.runsWithoutLogs == 1, "failed and old receipts are out, and a Cursor run has no log to read")
        check(full.work.widerTokens == 1020 && full.work.measuredTokens == 0, "a continued Work session counts from the run's start, and with no ending it stays wider")
        check(full.work.unprovenRuns == 1, "the reader says a run has no provable end")
        check(try collector.cosStoredEventCount() == 6, "a row older than the window is not stored")
        // A Work run on real row shapes, from a scratch log: its prompt, a tool call, a tool result, a typed turn, then more.
        let turnsHome = root.appendingPathComponent("turns")
        func writeTurns(_ relative: String, _ text: String) throws {
            let file = turnsHome.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func assistant(_ id: String, _ time: String, stop: String) throws -> String {
            try json(["type": "assistant", "timestamp": time, "sessionId": "s-led", "message": ["id": id, "model": "claude-opus-5-5", "stop_reason": stop, "usage": ["input_tokens": 1000, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0], "content": [["type": "text", "text": "SECRET_PROMPT_NEVER_STORE"]]]])
        }
        func user(_ time: String, _ content: Any, origin: String? = nil, session: String = "s-led") throws -> String {
            var row: [String: Any] = ["type": "user", "timestamp": time, "sessionId": session, "message": ["role": "user", "content": content]]
            if let origin { row["origin"] = ["kind": origin] }
            return try json(row)
        }
        try writeTurns(".claude/projects/p9/s-led.jsonl",
            try user("2026-10-30T09:00:00Z", "SECRET_PROMPT_NEVER_STORE", origin: "human") + assistant("before", "2026-10-30T09:00:05Z", stop: "end_turn")
            + user("2026-10-30T12:00:03Z", "SECRET_PROMPT_NEVER_STORE") + assistant("a1", "2026-10-30T12:00:10Z", stop: "tool_use")
            + user("2026-10-30T12:00:20Z", [["type": "tool_result", "content": "SECRET_PROMPT_NEVER_STORE"]]) + assistant("a2", "2026-10-30T12:00:30Z", stop: "end_turn")
            + user("2026-10-30T12:05:00Z", "SECRET_PROMPT_NEVER_STORE", origin: "task-notification") + assistant("a3", "2026-10-30T12:05:10Z", stop: "end_turn")
            + user("2026-10-30T12:30:00Z", [["type": "text", "text": "SECRET_PROMPT_NEVER_STORE"]], origin: "human") + assistant("later", "2026-10-30T12:30:10Z", stop: "end_turn"))
        try writeTurns(".claude/projects/p9/s-led/subagents/agent-1.jsonl", try user("2026-10-30T12:02:00Z", "SECRET_PROMPT_NEVER_STORE", origin: "human") + assistant("sub", "2026-10-30T12:02:10Z", stop: "end_turn"))
        let codexThread = "33333333-3333-3333-3333-333333333333"
        func codexTurn(_ time: String, _ total: Int) throws -> String {
            try json(["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "output_tokens": 0, "cached_input_tokens": 0], "last_token_usage": ["input_tokens": 1000, "output_tokens": 0, "cached_input_tokens": 0]]]])
        }
        try writeTurns(".codex/sessions/2026/10/30/rollout-2026-10-30T12-00-00-\(codexThread).jsonl",
            try json(["type": "session_meta", "payload": ["id": codexThread, "model_provider": "openai"]]) + json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]])
            + json(["type": "event_msg", "timestamp": "2026-10-30T13:00:03Z", "payload": ["type": "task_started"]]) + codexTurn("2026-10-30T13:00:10Z", 1000)
            + json(["type": "event_msg", "timestamp": "2026-10-30T13:00:20Z", "payload": ["type": "task_complete"]])
            + json(["type": "event_msg", "timestamp": "2026-10-30T13:30:00Z", "payload": ["type": "task_started"]]) + codexTurn("2026-10-30T13:30:10Z", 2000))
        try writeTurns("Library/Application Support/COS Control/work-handoffs/handoffs.json", try json(["receipts": [
            ["createdAt": R.epoch("2026-10-30T12:00:00Z")!, "sessionID": "claude:s-led", "provider": "claude", "status": "completed", "channel": "turn"],
            ["createdAt": R.epoch("2026-10-30T13:00:00Z")!, "sessionID": "codex:\(codexThread)", "provider": "codex", "status": "completed", "channel": "job"],
            ["createdAt": R.epoch("2026-10-30T13:00:00Z")!, "sessionID": "claude:s-source", "forkChildID": "claude:s-led-child", "provider": "claude", "status": "completed", "channel": "fork"],
        ]]))
        try writeTurns(".claude/projects/p9/s-led-child.jsonl", try user("2026-10-30T13:00:03Z", "SECRET_PROMPT_NEVER_STORE", session: "s-led-child")
            + json(["type": "assistant", "timestamp": "2026-10-30T13:00:10Z", "sessionId": "s-led-child", "message": ["id": "fork-1", "model": "claude-opus-5-5", "stop_reason": "end_turn", "usage": ["input_tokens": 1000, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]]))
        try writeTurns(".claude/projects/p9/s-source.jsonl", try user("2026-10-30T13:10:00Z", "SECRET_PROMPT_NEVER_STORE", origin: "human", session: "s-source")
            + json(["type": "assistant", "timestamp": "2026-10-30T13:10:10Z", "sessionId": "s-source", "message": ["id": "source-1", "model": "claude-opus-5-5", "stop_reason": "end_turn", "usage": ["input_tokens": 9000, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]]))
        let turnsDB = home.appendingPathComponent("cos-turns.sqlite")
        let turnsReader = try SessionUsageCollector(home: turnsHome, database: turnsDB, timeZone: chicago)
        let turns = try turnsReader.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
        // Claude: a1, a2, the background notice's a3 and the subagent are the run. `before` and `later` are not. Codex: its first turn only.
        // The fork counts in its child, not the source. 4 Claude messages + 1 fork message + 1 Codex turn.
        check(turns.work.measuredTokens == 6000, "on real row shapes a tool result does not end a run and a typed turn does")
        check(turns.work.widerTokens == 8000, "the wider figure holds the later turns, from the run's start")
        check(turns.work.unprovenRuns == 0 && turns.work.runsWithoutLogs == 0 && turns.work.runs == 3, "each scratch run has a provable end")
        check(!Data(try Data(contentsOf: turnsDB)).contains(Data("SECRET_PROMPT_NEVER_STORE".utf8)), "no words from a typed turn reach the usage history")
        // A Codex note taken to the app: once delivered, the turn the person sent ten minutes later is the run's own and the later one
        // ends it. Still queued, nothing of it has reached the log, so the first turn there is not its prompt. A job is handed in.
        let appThread = "44444444-4444-4444-4444-444444444444"
        func appRun(_ channel: String, _ status: String) throws -> Int64 {
            let dir = root.appendingPathComponent("app-\(channel)-\(status)")
            func put(_ relative: String, _ text: String) throws {
                let file = dir.appendingPathComponent(relative)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            try put(".codex/sessions/2026/10/30/rollout-2026-10-30T13-00-00-\(appThread).jsonl",
                try json(["type": "session_meta", "payload": ["id": appThread, "model_provider": "openai"]]) + json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]])
                + json(["type": "event_msg", "timestamp": "2026-10-30T13:10:00Z", "payload": ["type": "task_started"]]) + codexTurn("2026-10-30T13:10:10Z", 1000)
                + json(["type": "event_msg", "timestamp": "2026-10-30T13:10:20Z", "payload": ["type": "task_complete"]])
                + json(["type": "event_msg", "timestamp": "2026-10-30T13:40:00Z", "payload": ["type": "task_started"]]) + codexTurn("2026-10-30T13:40:10Z", 2000))
            try put("Library/Application Support/COS Control/work-handoffs/handoffs.json", try json(["receipts": [
                ["createdAt": R.epoch("2026-10-30T13:00:00Z")!, "sessionID": "codex:\(appThread)", "provider": "codex", "status": status, "channel": channel]]]))
            let reader = try SessionUsageCollector(home: dir, database: dir.appendingPathComponent("a.sqlite"), timeZone: chicago)
            return try reader.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now).work.measuredTokens
        }
        check(try appRun("app", "delivered") == 1000, "a delivered app note: the turn the person sent is the run's own, and the next one ends it")
        check(try appRun("app", "queued") == 0, "a queued app note has not reached the log, so a turn there is not its prompt")
        check(try appRun("job", "completed") == 0, "a handed-in job keeps the delivery limit")
        // A log that grows is read from where it stopped, and its rows are not counted twice.
        let again = try collector.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
        check(row(.answers, again).measuredTokens == answers.measuredTokens, "a second pass over unchanged logs adds nothing")
        let grown = root.appendingPathComponent(".claude/projects/p1/s-main.jsonl")
        let h = try FileHandle(forWritingTo: grown); try h.seekToEnd(); try h.write(contentsOf: Data(try claudeRow("m2", "2026-10-30T12:00:45Z", session: "s-main").utf8)); try h.close()
        check(row(.answers, try collector.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)).measuredTokens == answers.measuredTokens + 1020, "an appended row is read on the next pass")
        // Privacy: the report and the tables hold counts only.
        let encoded = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
        for secret in ["s-main", "s-work", "r1", "11111111", SessionUsageCollector.digest("claude:s-main"), "SECRET"] {
            check(!encoded.contains(secret), "the report holds counts only, no ids, hashes or text")
        }
        // Stronger than looking for known secrets: the only strings a report can hold are dates, the zone and row names.
        func strings(_ value: Any) -> [String] {
            if let text = value as? String { return [text] }
            if let list = value as? [Any] { return list.flatMap(strings) }
            if let map = value as? [String: Any] { return map.values.flatMap(strings) }
            return []
        }
        let names = Set(CosCostCategory.allCases.map(\.rawValue))
        let reportStrings = strings(try JSONSerialization.jsonObject(with: Data(encoded.utf8)))
        check(reportStrings.allSatisfy { names.contains($0) || SessionUsageDay($0) != nil || $0 == "America/Chicago" || R.epoch($0) != nil }, "the report holds no free text, so it cannot carry key material")
        let stored = try Data(contentsOf: db)
        check(stored.range(of: Data("SECRET_PROMPT_NEVER_STORE".utf8)) == nil && stored.range(of: Data("SECRET_KEY_NEVER_READ".utf8)) == nil, "no prompt or key reaches the usage history")
        // Another command holding the write lock costs this pass its slices, never the page.
        let busyDB = home.appendingPathComponent("cos-busy.sqlite")
        let busy = try SessionUsageCollector(home: root, database: busyDB, timeZone: chicago)
        _ = try busy.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
        var holder: OpaquePointer?
        check(sqlite3_open(busyDB.path, &holder) == SQLITE_OK && sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "the test holds the write lock")
        let h2 = try FileHandle(forWritingTo: grown); try h2.seekToEnd(); try h2.write(contentsOf: Data(try claudeRow("m3", "2026-10-30T12:00:46Z", session: "s-main").utf8)); try h2.close()
        let held = try busy.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
        check(held.sessions.busy && held.auditFound && row(.answers, held).measuredCalls == 3, "a busy history keeps the page and says so")
        sqlite3_exec(holder, "COMMIT", nil, nil, nil); sqlite3_close(holder)
        let free = try busy.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
        check(!free.sessions.busy && row(.answers, free).measuredTokens == row(.answers, held).measuredTokens + 1020, "the pass after a busy one catches up")
        // Bounded and resumable: a pass with almost no budget stops, says so, and the next ones finish to the same total.
        let slow = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-slow.sqlite"), timeZone: chicago)
        let targets: Set<SessionUsageCollector.CosSliceTarget> = [.init(provider: "claude", id: "s-main"), .init(provider: "claude", id: "s-old")]
        var pass = try slow.cosReadSessionSlices(targets, seconds: 0, now: now)
        check(pass.stillReading == 2, "no time budget reads nothing and says the sessions are still to read")
        pass = try slow.cosReadSessionSlices(targets, fileBytes: 700, now: now)
        check(pass.stillReading > 0, "a byte budget stops a pass part way through a log")
        var passes = 1
        while pass.stillReading > 0 && passes < 30 { pass = try slow.cosReadSessionSlices(targets, fileBytes: 700, now: now); passes += 1 }
        check(pass.stillReading == 0 && passes > 1, "the next passes finish what a bounded one left")
        let oneShot = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-oneshot.sqlite"), timeZone: chicago)
        _ = try oneShot.cosReadSessionSlices(targets, now: now)
        let slowSum = row(.answers, try slow.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: false, now: now)).measuredTokens
        let oneSum = row(.answers, try oneShot.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: false, now: now)).measuredTokens
        check(slowSum == oneSum && slowSum > 0, "a slow read ends at the same total as a whole one")
        // A row longer than a chunk is skipped through its newline, and the usage after it is still reached.
        try write(".claude/projects/p3/s-long.jsonl", String(repeating: "x", count: 9*1024*1024) + "\n" + (try claudeRow("after-long", "2026-10-30T12:00:30Z", session: "s-long")))
        let longer = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-long.sqlite"), timeZone: chicago)
        var longPass = try longer.cosReadSessionSlices([.init(provider: "claude", id: "s-long")], now: now)
        var longTries = 0
        while longPass.stillReading > 0 && longTries < 10 { longPass = try longer.cosReadSessionSlices([.init(provider: "claude", id: "s-long")], now: now); longTries += 1 }
        check(longPass.stillReading == 0, "an oversized row does not stop the session finishing")
        // The fallback path: no plist means .env, no .env means home.
        let viaHome = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-home.sqlite"), timeZone: chicago).cosUsage(plistScripts: nil, dataDirectory: nil, importSessions: false, now: now)
        check(viaHome.auditFound && row(.other, viaHome).calls == 1, "with no scripts folder the home audit is read")
        try write(".cos-glasses/.env", "SOME_SECRET=abc\nCOS_SCRIPTS_DIR=\(scripts)\n")
        let viaEnv = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-env.sqlite"), timeZone: chicago).cosUsage(plistScripts: nil, dataDirectory: nil, importSessions: false, now: now)
        check(row(.other, viaEnv).calls == 0 && row(.dictation, viaEnv).calls == 1, ".env names the scripts folder when the plist does not")
        check(!String(decoding: try JSONEncoder().encode(viaEnv), as: UTF8.self).contains("abc"), "nothing else out of .env reaches the report")
        // A command opens a history that already exists while another command holds the write lock, as a compressed-log read does
        // through each decoder start. The meta row is there, so opening writes nothing and does not wait out the busy timeout.
        let lockedDB = home.appendingPathComponent("cos-locked-open.sqlite")
        _ = try SessionUsageCollector(home: root, database: lockedDB, timeZone: chicago)
        var lockHolder: OpaquePointer?
        check(sqlite3_open(lockedDB.path, &lockHolder) == SQLITE_OK && sqlite3_exec(lockHolder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "the test holds the write lock before the collector opens")
        let openStarted = Date()
        let openedWhileLocked = try? SessionUsageCollector(home: root, database: lockedDB, timeZone: chicago)
        check(openedWhileLocked != nil && Date().timeIntervalSince(openStarted) < 1.0, "a command opens an existing history while another holds the write lock, without waiting it out")
        if let openedWhileLocked {
            let lockedReport = try openedWhileLocked.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
            check(lockedReport.sessions.busy && lockedReport.sessions.reading && lockedReport.auditFound, "a locked history gives a busy page that counts as reading, never a failed command")
        }
        sqlite3_exec(lockHolder, "COMMIT", nil, nil, nil); sqlite3_close(lockHolder)
        // The first open of a new history still writes its time zone, and a stored one wins over the one asked for.
        let zoneDB = home.appendingPathComponent("cos-zone.sqlite")
        _ = try SessionUsageCollector(home: root, database: zoneDB, timeZone: chicago)
        let zoneAgain = try SessionUsageCollector(home: root, database: zoneDB, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        check(try zoneAgain.cosUsage(plistScripts: nil, dataDirectory: nil, importSessions: false, now: now).timeZone == "America/Chicago", "the stored time zone is kept when a later open asks for another")
        // An audit file that is there and will not open is not an empty one.
        let blockedScripts = home.appendingPathComponent("cos-blocked-scripts")
        try fm.createDirectory(at: blockedScripts, withIntermediateDirectories: true)
        let blockedAudit = blockedScripts.appendingPathComponent(".cos_token_audit.jsonl")
        try Data("{\"ts\":\"2026-10-30T12:00:00Z\",\"source\":\"g2-dictation-autoclean\",\"caller\":\"dictation_autoclean_message\",\"model\":\"sonnet\",\"est_input_tokens\":10,\"est_output_tokens\":1}\n".utf8).write(to: blockedAudit)
        let readable = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-readable.sqlite"), timeZone: chicago).cosUsage(plistScripts: blockedScripts.path, dataDirectory: nil, importSessions: false, now: now)
        check(readable.auditFound && !readable.auditUnreadable && row(.dictation, readable).calls == 1, "a readable audit is read and not flagged")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedAudit.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blockedAudit.path) }
        if getuid() != 0 {
            let blocked = try SessionUsageCollector(home: root, database: home.appendingPathComponent("cos-blocked.sqlite"), timeZone: chicago).cosUsage(plistScripts: blockedScripts.path, dataDirectory: nil, importSessions: false, now: now)
            check(blocked.auditFound && blocked.auditUnreadable && blocked.unreadableRows == 0, "an audit that will not open is flagged, not read as empty")
            let words = P.headline(report: blocked, ran: 0, usage: .ready)
            check(words.contains("could not read its record of calls") && !words.contains("no calls") && !words.contains(blockedAudit.path), "the headline says so, and never prints a path")
        }
        // A read that throws part way is not the end of the file: the rows read so far stand, and the caller is told it was cut short.
        let cutFile = home.appendingPathComponent("cos-cut-read.jsonl")
        try Data("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n".utf8).write(to: cutFile)
        var cutRows = 0, cutReads = 0
        let cut = SessionUsageCollector.cosForEachJSONLine(cutFile, { _ in cutRows += 1 }, read: { handle in
            cutReads += 1
            if cutReads == 1 { return try handle.read(upToCount: 9) }
            throw CocoaError(.fileReadUnknown)
        })
        check(cut == nil && cutRows == 1, "a read that fails part way is flagged, not taken for the end of the file")
        var wholeRows = 0
        check(SessionUsageCollector.cosForEachJSONLine(cutFile, { _ in wholeRows += 1 }) == 0 && wholeRows == 3, "the same file read to its end counts all three rows")
        // Busy means busy: SQLITE_BUSY and SQLITE_LOCKED, with or without an extended code, and nothing else.
        typealias F = SessionUsageCollector
        check([SQLITE_BUSY, SQLITE_LOCKED, SQLITE_BUSY | (1 << 8), SQLITE_LOCKED | (1 << 8)].allSatisfy { F.failure($0, busy: "b", other: "o").busy && F.failure($0, busy: "b", other: "o").message == "b" }, "busy and locked, extended or not, are a busy history")
        check(![SQLITE_ERROR, SQLITE_IOERR, SQLITE_FULL, SQLITE_CORRUPT, SQLITE_READONLY, SQLITE_CANTOPEN, SQLITE_NOMEM, SQLITE_NOTADB, SQLITE_IOERR | (5 << 8)].contains { F.failure($0, busy: "b", other: "o").busy || F.failure($0, busy: "b", other: "o").message != "o" }, "no other answer is called busy")
        // A history that fails for any other reason gets its own words, the slow pace and one fixed line in the log.
        let schemaDB = home.appendingPathComponent("cos-schema.sqlite")
        let schema = try SessionUsageCollector(home: root, database: schemaDB, timeZone: chicago)
        _ = try schema.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
        var schemaHandle: OpaquePointer?
        check(sqlite3_open(schemaDB.path, &schemaHandle) == SQLITE_OK && sqlite3_exec(schemaHandle, "ALTER TABLE cos_slice_files RENAME COLUMN state TO state_old", nil, nil, nil) == SQLITE_OK, "the test breaks the slice table's shape")
        sqlite3_close(schemaHandle)
        let notBusy = try? schema.cosUsage(plistScripts: scripts, dataDirectory: nil, importSessions: true, now: now)
        check(notBusy?.sessions.failed == true && notBusy?.sessions.busy == false && notBusy?.sessions.reading == false && notBusy?.auditFound == true, "a failure that is not a busy history is not called busy, and the page stands")
        let failureLog = (try? String(contentsOf: home.appendingPathComponent("cursor-feed.log"), encoding: .utf8)) ?? ""
        check(failureLog.contains("COS cost could not read the usage history") && !failureLog.contains(home.path) && !failureLog.contains("state_old"), "the log line is fixed words, no path or detail")
        // How soon each page reads again, and when it stops hurrying.
        typealias U = SessionUsagePresentation
        var wait = U.wait(pending: true, busy: false, busyPasses: 7)
        check(wait.seconds == U.pendingSeconds && wait.busyPasses == 0, "a pass that read something starts the count over")
        wait = U.wait(pending: true, busy: true, busyPasses: U.busyRetryLimit - 2)
        check(wait.seconds == U.pendingSeconds && wait.busyPasses == U.busyRetryLimit - 1, "a busy pass comes back soon")
        wait = U.wait(pending: true, busy: true, busyPasses: U.busyRetryLimit - 1)
        check(wait.seconds == U.slowSeconds, "a history busy for the whole limit is left alone for a while")
        check(U.isHeld(busyPasses: wait.busyPasses) && !U.isHeld(busyPasses: U.busyRetryLimit - 1) && U.heldNote.contains("\(U.slowSeconds / 60) minutes") && !U.heldNote.contains("\u{2014}"), "once Usage slows down for a held history, the page says why")
        check(U.wait(pending: false, busy: true, busyPasses: 0).seconds == U.slowSeconds, "nothing pending waits at the slow pace, busy or not")
        var costReport = CosUsageReport(windowStart: "2026-10-02", windowEnd: "2026-10-31", timeZone: "America/Chicago", updatedAt: "2026-10-31T12:00:00Z")
        costReport.sessions.stillReading = 3
        var cost = P.wait(tracking: true, report: costReport, failedToRefresh: false, quickTries: 9)
        check(cost.seconds == P.readingSeconds && cost.quickTries == 0, "reading is progress, and never counts against the limit")
        costReport.sessions = CosSliceProgress(busy: true)
        cost = P.wait(tracking: true, report: costReport, failedToRefresh: false, quickTries: P.quickTryLimit - 2)
        check(cost.seconds == P.readingSeconds && cost.quickTries == P.quickTryLimit - 1, "a busy history comes back at the reading pace")
        cost = P.wait(tracking: true, report: costReport, failedToRefresh: false, quickTries: P.quickTryLimit - 1)
        check(cost.seconds == P.slowSeconds, "a busy history stops being retried every 15 seconds")
        cost = P.wait(tracking: true, report: costReport, failedToRefresh: true, quickTries: 0)
        check(cost.seconds == P.failedSeconds && cost.quickTries == 1, "a failed pass tries again in a minute")
        cost = P.wait(tracking: true, report: costReport, failedToRefresh: true, quickTries: P.quickTryLimit - 1)
        check(cost.seconds == P.slowSeconds, "a failed pass that keeps failing slows down")
        cost = P.wait(tracking: true, report: nil, failedToRefresh: false, quickTries: 0)
        check(cost.seconds == P.readingSeconds && cost.quickTries == 1, "no report yet is the spinner on screen, which comes back at the reading pace")
        check(P.wait(tracking: true, report: nil, failedToRefresh: false, quickTries: P.quickTryLimit - 1).seconds == P.slowSeconds && P.wait(tracking: false, report: nil, failedToRefresh: false, quickTries: 0).seconds == P.slowSeconds, "no report for many passes, or a paused page, does not hurry")
        costReport.sessions = CosSliceProgress(failed: true)
        cost = P.wait(tracking: true, report: costReport, failedToRefresh: false, quickTries: 0)
        check(cost.seconds == P.slowSeconds && cost.quickTries == 0, "a history that cannot be read waits at the slow pace")
        costReport.sessions = CosSliceProgress(busy: true)
        check(P.wait(tracking: false, report: costReport, failedToRefresh: false, quickTries: 0).seconds == P.slowSeconds, "a paused page does not hurry")
        // Usage's own pass while another command holds the write lock, as COS cost does through each decoder start: no error,
        // nothing new, the file still pending, and the pass after it catches up.
        let usageBusyHome = home.appendingPathComponent("usage-busy-home")
        let usageBusyLog = usageBusyHome.appendingPathComponent(".claude/projects/p/a.jsonl")
        try fm.createDirectory(at: usageBusyLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try claudeRow("b1", "2026-10-30T12:00:00Z", session: "s-busy").write(to: usageBusyLog, atomically: true, encoding: .utf8)
        let usageBusyDB = usageBusyHome.appendingPathComponent("usage-busy.sqlite")
        let usageBusy = try SessionUsageCollector(home: usageBusyHome, database: usageBusyDB, timeZone: chicago)
        let usageFirst = try usageBusy.refresh()
        func total(_ r: SessionUsageReport) -> Int64 { r.buckets.reduce(0) { $0 + $1.counts.total } }
        check(total(usageFirst) == 1020 && usageFirst.historyBusy == nil, "Usage reads the first row")
        var usageHolder: OpaquePointer?
        check(sqlite3_open(usageBusyDB.path, &usageHolder) == SQLITE_OK && sqlite3_exec(usageHolder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "the test holds the write lock against Usage")
        let usageAppend = try FileHandle(forWritingTo: usageBusyLog); try usageAppend.seekToEnd(); try usageAppend.write(contentsOf: Data(try claudeRow("b2", "2026-10-30T12:01:00Z", session: "s-busy").utf8)); try usageAppend.close()
        let usageHeld = try? usageBusy.refresh()
        check(usageHeld?.historyBusy == true && usageHeld?.pendingFiles == 1 && usageHeld.map(total) == 1020, "a busy history is a pass with no progress, not a failed refresh")
        sqlite3_exec(usageHolder, "COMMIT", nil, nil, nil); sqlite3_close(usageHolder)
        let usageFree = try usageBusy.refresh()
        check(usageFree.historyBusy == nil && usageFree.pendingFiles == 0 && total(usageFree) == 2040, "the pass after a busy one catches up")
        // A busy history must not leave the decoder it started. This stand-in records its pid and waits.
        let standInHome = home.appendingPathComponent("usage-busy-decoder")
        let standInLog = standInHome.appendingPathComponent(".codex/sessions/2026/10/30/rollout-2026-10-30T12-00-00-33333333-3333-3333-3333-333333333333.jsonl.zst")
        try fm.createDirectory(at: standInLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not really zstd".utf8).write(to: standInLog)
        let standInPid = standInHome.appendingPathComponent("decoder.pid")
        let standIn = standInHome.appendingPathComponent("node")
        try "#!/bin/sh\ncase \"$2\" in process.exit*) exit 0;; esac\necho $$ > '\(standInPid.path)'\nexec sleep 30\n".write(to: standIn, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.path)
        let standInDB = standInHome.appendingPathComponent("stand-in.sqlite")
        let standInLedger = try SessionUsageCollector(home: standInHome, database: standInDB, timeZone: chicago)
        standInLedger.compressedLogNodes = [standIn.path]
        var standInHolder: OpaquePointer?
        check(sqlite3_open(standInDB.path, &standInHolder) == SQLITE_OK && sqlite3_exec(standInHolder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "the test holds the write lock before the decoder starts")
        let standInHeld = try? standInLedger.refresh()
        sqlite3_exec(standInHolder, "COMMIT", nil, nil, nil); sqlite3_close(standInHolder)
        check(standInHeld?.historyBusy == true && standInHeld?.pendingFiles == 1, "a compressed log under a busy history is pending, not an error")
        let decoderPid = Int32((try? String(contentsOf: standInPid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        check(decoderPid > 0, "the stand-in decoder started")
        var decoderAlive = true
        for _ in 0..<50 { if kill(decoderPid, 0) != 0 { decoderAlive = false; break }; Thread.sleep(forTimeInterval: 0.02) }
        if decoderAlive { kill(decoderPid, SIGKILL) }
        check(!decoderAlive, "a busy history ends the decoder it started")
        print("PASS: COS cost rules (dates, classification, session-log flags, rates, dedupe, Work, Cursor rule, denominator, headline, rows) and the bounded reader on a scratch home")
    }
}
