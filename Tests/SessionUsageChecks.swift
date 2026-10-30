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
        check(SessionUsagePresentation.costLabel([pricedRow, nextRow]).contains("unknown"), "partial prices visible in tooltip")
        check(SessionUsagePresentation.costLabel([nextRow]) == "Unavailable" && SessionUsagePresentation.costLabel([]) == "Unavailable", "unknown cost never shown as free")
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
        check(openai.estimatedUSD == 3 && openai.costLabel.contains("unknown"), "provider summary preserves partial cost")
        let days = SessionUsagePresentation.summarize([pricedRow, nextRow, anotherProvider], by: \.day)
        check(days.count == 2 && days.first { $0.id == "2026-10-24" }?.events == 4, "daily breakdown sums across providers")
        check(SessionUsagePresentation.summarize([nextRow], by: \.provider).first?.costLabel == "Unavailable", "unpriced provider never appears free")
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
        check(P.costCell([nextRow]) == "No verified price" && P.costCell([pricedRow]) == "$3" && P.costCell([pricedRow, nextRow]) == "$3 + unknown", "cost cells stay honest about unpriced records")
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
        try feed.syncCursorFeed(force: false, now: t0.addingTimeInterval(60), readToken: { _ in feedCalls += 1; return .blocked }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
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
        try patient.syncCursorFeed(force: true, now: t0.addingTimeInterval(1000), readToken: { wait in patience.append(wait); return .blocked }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
        check(patience == [false, true, true], "a run in progress and a manual Refresh wait patiently for Keychain")
        var askedAgain = false
        try patient.syncCursorFeed(force: false, now: t0.addingTimeInterval(1000 + 7*86_400), readToken: { _ in askedAgain = true; return .blocked }, fetch: { _, _, _, _ in .init(status: 200, body: page([])) })
        check(!askedAgain, "an unanswered Keychain prompt is not repeated by automatic passes")
        check(try feed.refresh(cursorEnabled: true, cursorSyncFailed: true).cursorFeed?.state == .failed, "a sync that threw is reported, so the loop stops hurrying")
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

        print("PASS: weekly buckets, category USD mix, period comparisons, table sorting and CSV/JSON export")
        print("PASS: 30/90/custom dates, DST/leap/calendar boundaries, provider/day summaries and token mix")
        print("PASS: usage period boundaries, timezone, token/category shares, tooltip aggregation and unknown-price handling")
        print("PASS: usage parsing, deduplication, cache pricing, local dates, reset, partial append, retention and unknown coverage")
    }
}
