import AppKit
import SwiftUI

@main @MainActor struct SessionUsageRender {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = SessionUsageStore()
        // 0.5.394: the page's plan ruler never starts the helper here; every page shows the 2026-11-14 reading, closed.
        let planPane = try JSONDecoder().decode(PlanPane.self, from: Data(planFixture.utf8))
        let contractPane = try JSONDecoder().decode(PlanPane.self, from: Data(planFixture
            .replacingOccurrences(of: #""closest":"codex""#, with: #""closest":"claude""#)
            .replacingOccurrences(of: #""state":"failed","usedPct":null"#, with: #""state":"failed","usedPct":40"#).utf8))
        guard contractPane.lines[0].usedPct == 40, contractPane.closest == "claude", !contractPane.lines[0].hasRuler else { fatalError("plan: the contract payload did not build") }
        // Server 7.0.45 (lead 20:58): a Cursor line exactly as the server sends it, switched on. The Mac draws it with no
        // Mac change: it decodes, it is the closest, and it has a ruler.
        let cursorPane = try JSONDecoder().decode(PlanPane.self, from: Data(cursorFixture.utf8))
        guard cursorPane.closest == "cursor", let cursorTop = PlanRulerPresentation.closest(cursorPane), cursorTop.provider == "cursor", cursorTop.hasRuler,
              cursorTop.usedPct == 97, cursorPane.lines.filter(\.hasRuler).map(\.provider) == ["codex", "cursor"] else { fatalError("plan: the Cursor line did not draw") }
        PlanRulerStore.shared.offscreen = true
        PlanRulerStore.shared.pane = planPane
        PlanRulerStore.shared.open = false
        let monthFormat = DateFormatter(); monthFormat.dateFormat = "yyyy-MM"
        let month = monthFormat.string(from: Date())
        var rows: [SessionUsageBucket] = []
        for day in 1...25 {
            for (index, model) in ["claude-opus-5-5", "gpt-6-astra", "unpriced-model"].enumerated() {
                rows.append(SessionUsageBucket(day: month + String(format: "-%02d", day), provider: index == 0 ? "Anthropic" : "OpenAI", model: model,
                    counts: SessionUsageCounts(input: Int64(day*2300), output: Int64(day*900), cacheRead: Int64(day*70000), cacheWrite: Int64(day*3100)),
                    events: 10, pricedEvents: index == 2 ? 0 : 10, estimatedUSD: index == 2 ? 0 : Double(day)*0.21))
            }
            // Partially priced: Codex cache writes leave some records unpriced, so the cost split must leave this out.
            rows.append(SessionUsageBucket(day: month + String(format: "-%02d", day), provider: "OpenAI", model: "gpt-6.1-sol",
                counts: SessionUsageCounts(input: Int64(day*800), output: Int64(day*300), cacheRead: Int64(day*9000), cacheWrite: Int64(day*1200)),
                events: 6, pricedEvents: 4, estimatedUSD: Double(day)*0.05))
        }
        let historyRows = rows.map { row -> SessionUsageBucket in
            var copy = row
            copy.day = "2026-08-" + row.day.suffix(2)
            return copy
        }
        rows += historyRows
        store.report = SessionUsageReport(buckets: rows, updatedAt: "2026-10-25T21:00:00Z", timeZone: "America/Chicago", filesIndexed: 120, pendingFiles: 0, unreadableFiles: 0, malformedRows: 0, missingBaselineEvents: 0,
            coverage: ["Claude Code and Codex local session logs, including archived and compressed sessions and subagents.", "Cursor, browser-only chats and other Macs are not included."], pricingVersion: SessionUsagePricing.version)
        let plainReport = store.report!
        // Hand-run only: a local aggregate file renders the page on real numbers. It is never read in the suite.
        if let path = ProcessInfo.processInfo.environment["COS_USAGE_RENDER_BUCKETS"] {
            rows = try JSONDecoder().decode([SessionUsageBucket].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            store.report?.buckets = rows
            store.report?.filesIndexed = 3140
            store.report?.unreadableFiles = 157
        }
        let fixtureReport = store.report!
        struct PageCase {
            var name: String
            var period = "Last 30 days"
            var inspection: String? = nil
            var cost = false
            var cacheExcluded = false
            var expanded = false
            var reversed = false
            var empty = false
            var failed = false
            var pending = false
            var minimumOnly = false
            var scale: SessionUsageTimeScale? = nil
            var measure: SessionUsageMeasure? = nil
            var series: SessionUsageSeries = .providers
            var lineChart = false
            var cursorFeed: SessionUsageCursorFeedStatus? = nil
            var cursorOn = false
            var notes = false
            var provider = SessionUsagePresentation.allProviders
            var model = "All models"
            var modelSort: SessionUsageModelSort = .tokens
            var daySort: SessionUsageDaySort = .date
            var loading = false
            var columns: [SessionUsageView.TableColumn]? = nil
            var paused = false
            var historyWeeks = 0
            /// A real file in the test home, so the page's own check finds it.
            var cursorCLI = false
        }
        let cases: [PageCase] = [
            PageCase(name: "range"),
            PageCase(name: "weekly-categories", scale: .weekly, series: .categories),
            PageCase(name: "filtered", minimumOnly: true, provider: "Anthropic"),
            PageCase(name: "lines", lineChart: true),
            PageCase(name: "selected", period: "Last 90 days", inspection: "2026-10-19"),
            PageCase(name: "new-tokens", period: "Last 90 days", cacheExcluded: true),
            PageCase(name: "models-week", period: "Last 90 days", inspection: nil, series: .models),
            PageCase(name: "notes", cursorFeed: SessionUsageCursorFeedStatus(state: .off), notes: true),
            PageCase(name: "cursor-sign-in", cursorFeed: SessionUsageCursorFeedStatus(state: .signIn, message: "This Mac has no Cursor command line sign-in. Run cursor-agent login in Terminal, then refresh."), cursorOn: true, cursorCLI: true),
            PageCase(name: "cursor-no-cli", cursorFeed: SessionUsageCursorFeedStatus(state: .signIn, message: "This Mac has no Cursor command line sign-in. Run cursor-agent login in Terminal, then refresh."), cursorOn: true),
            PageCase(name: "paused", paused: true),
            PageCase(name: "paused-backfill", pending: true, paused: true),
            PageCase(name: "paused-empty", empty: true, paused: true),
            PageCase(name: "paused-cursor-off", cursorFeed: SessionUsageCursorFeedStatus(state: .off), paused: true),
            PageCase(name: "paused-cursor-waits", cursorFeed: SessionUsageCursorFeedStatus(state: .backfilling, message: "Cursor is waiting until tracking resumes."), cursorOn: true, paused: true, cursorCLI: true),
            PageCase(name: "two-years", period: "All history", scale: .monthly, historyWeeks: 105),
            PageCase(name: "long-history", period: "All history", cost: true, scale: .monthly, historyWeeks: 200),
            PageCase(name: "one-year", period: "All history", scale: .monthly, historyWeeks: 53),
            PageCase(name: "cursor-failed", cursorFeed: SessionUsageCursorFeedStatus(state: .failed, message: "Cursor did not answer, so its numbers may be behind. COS will try again."), cursorOn: true),
            PageCase(name: "history", period: "All history", inspection: "2026-08"),
            PageCase(name: "custom", period: "Custom dates", inspection: month + "-24"),
            PageCase(name: "90days", period: "Last 90 days"),
            PageCase(name: "30days-value", cost: true),
            PageCase(name: "columns-none", minimumOnly: true, columns: []),
            PageCase(name: "columns-all", minimumOnly: true, columns: SessionUsageView.TableColumn.allCases),
            PageCase(name: "unpriced-model", period: "Last 90 days", cost: true, minimumOnly: true, provider: "OpenAI", model: ProcessInfo.processInfo.environment["COS_USAGE_RENDER_BUCKETS"] == nil ? "unpriced-model" : "gpt-5.5"),
            PageCase(name: "history-value", period: "All history", cost: true),
            PageCase(name: "empty", empty: true, minimumOnly: true),
            PageCase(name: "empty-cost", cost: true, empty: true, minimumOnly: true),
            PageCase(name: "error", failed: true, minimumOnly: true),
            PageCase(name: "backfill", pending: true, minimumOnly: true),
            PageCase(name: "reversed-custom", period: "Custom dates", cost: true, reversed: true, minimumOnly: true),
            PageCase(name: "api-cost", inspection: month + "-24", cost: true, minimumOnly: true),
            PageCase(name: "cache-excluded", inspection: month + "-24", cacheExcluded: true, minimumOnly: true),
            PageCase(name: "expanded-days", expanded: true, minimumOnly: true),
            // The state a Peak day or Daily breakdown click lands in from All history (Monthly): Daily, day inspected.
            PageCase(name: "history-day-inspect", period: "All history", inspection: "2026-08-12", scale: .daily),
            PageCase(name: "narrow-slice", inspection: month + "-24", cacheExcluded: true, minimumOnly: true, provider: "OpenAI", model: "gpt-6-astra"),
            PageCase(name: "sorted", expanded: true, minimumOnly: true, modelSort: .cost, daySort: .cost),
            PageCase(name: "cost-categories", cost: true, minimumOnly: true, series: .categories),
            PageCase(name: "first-load", empty: true, minimumOnly: true, loading: true),
        ]
        // Hand-run only: name the cases to render instead of all of them.
        let only = ProcessInfo.processInfo.environment["COS_USAGE_RENDER_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        if let only, !only.isSubset(of: Set(cases.map(\.name))) { fatalError("COS_USAGE_RENDER_ONLY names a case that does not exist: \(only)") }
        if let only, only.isEmpty { fatalError("COS_USAGE_RENDER_ONLY is set but names no case, so nothing would render.") }
        let cliFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cursor-agent")
        for width in [1200.0, 800.0, 760.0] {
            for dark in [false, true] {
              for fixture in cases where (!fixture.minimumOnly || width == 760) && (only?.contains(fixture.name) ?? true) {
                let pageStore = SessionUsageStore()
                // The Cursor states are about a Mac with no Cursor rows yet, so they stay on the invented fixture.
                var report = fixture.name.hasPrefix("cursor-") || fixture.name.hasPrefix("paused-cursor") || fixture.name == "notes" ? plainReport : fixtureReport
                if fixture.historyWeeks > 0 {
                    let monday = SessionUsageDay(SessionUsagePresentation.dayFormatter(timeZone: .current).string(from: Date()))!.monday
                    var long: [SessionUsageBucket] = []
                    for week in 0..<fixture.historyWeeks {
                        for day in 0..<5 {
                            let counts = SessionUsageCounts(input: Int64(1000 + week * 20), output: 900, cacheRead: Int64(80_000 + (week % 13) * 9000), cacheWrite: 3100)
                            long.append(SessionUsageBucket(day: monday.adding(day - 7 * week).key, provider: "Anthropic", model: "claude-opus-5-5", counts: counts, events: 10, pricedEvents: 10, estimatedUSD: Double(1 + week % 9)))
                        }
                    }
                    report.buckets = long
                }
                if ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] != nil {
                    try? FileManager.default.removeItem(at: cliFile)
                    if fixture.cursorCLI {
                        try FileManager.default.createDirectory(at: cliFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: cliFile.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
                    }
                }
                report.cursorFeed = fixture.cursorFeed
                pageStore.cursorEnabled = fixture.cursorOn
                pageStore.enabled = !fixture.paused
                if fixture.empty { report.buckets = []; report.filesIndexed = 0 }
                if fixture.pending { report.pendingFiles = 37 }
                pageStore.report = fixture.loading ? nil : report
                // refresh() returns at once while loading is set, so the first-load case never calls the helper.
                pageStore.loading = fixture.loading
                if fixture.failed { pageStore.error = "Usage could not refresh: fixture helper unavailable. Showing the last recorded history." }
                let dates = fixture.reversed ? (Date(), Calendar.current.date(byAdding: .day, value: -1, to: Date())!) : nil
                let height = fixture.expanded ? 3400.0 : 2200.0
                let page = SessionUsageView(store: pageStore, initialPeriod: fixture.period, initialInspection: fixture.inspection,
                    initialDates: dates, initialCostChart: fixture.cost, initialExcludeCacheReads: fixture.cacheExcluded,
                    initialDayBreakdownExpanded: fixture.expanded, initialTimeScale: fixture.scale,
                    initialMeasure: fixture.measure, initialSeries: fixture.series,
                    initialLineChart: fixture.lineChart, initialProvider: fixture.provider, initialModel: fixture.model,
                    initialModelSort: fixture.modelSort, initialDaySort: fixture.daySort, initialShowNotes: fixture.notes, initialColumns: fixture.columns)
                let host = NSHostingView(rootView: page.cosControlTheme().frame(width: width, height: height).background(COSPalette.panel))
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                if only != nil {
                    let started = Date(); host.layoutSubtreeIfNeeded()
                    print("first layout \(Int(width)) \(fixture.name): \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                }
                let until = Date().addingTimeInterval(1)
                while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), let data = {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    return rep.representation(using: .png, properties: [:])
                }() else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: out.appendingPathComponent("usage-\(Int(width))-\(dark ? "dark" : "light")-\(fixture.name).png"))
                window.close()
              }
            }
        }
        // 0.5.394 plan ruler (Miles: "Collapsed, tap to open"), drawn to round 2 tap-mac: closed, open, a failed read and
        // reading, light and dark, wide and narrow. Same reading as the web harness.
        var planHeights: [String: Int] = [:]
        for dark in [false, true] {
            for width in [1200.0, 760.0] {
                for state in ["closed", "open", "failed", "reading", "contract-closed", "contract", "cursor-closed", "cursor"] {
                    let plan = PlanRulerStore()
                    plan.offscreen = true
                    plan.open = !state.hasSuffix("closed")
                    // contract: a payload the server should never send (Claude failed, yet with 40% and named closest).
                    plan.pane = state == "failed" ? nil : state.hasPrefix("contract") ? contractPane : state.hasPrefix("cursor") ? cursorPane : planPane
                    plan.failed = state == "failed"
                    plan.loading = state == "reading"
                    let view = PlanRulerView(plan: plan, narrow: width < 944).padding(24).frame(width: width, alignment: .top).background(COSPalette.panel).cosControlTheme()
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.appearance = window.appearance
                    window.contentView = host
                    host.frame = NSRect(x: 0, y: 0, width: width, height: max(60, host.fittingSize.height))
                    let until = Date().addingTimeInterval(0.4)
                    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                    host.frame.size.height = max(60, host.fittingSize.height)
                    planHeights["\(Int(width)) \(dark ? "dark" : "light") \(state)"] = Int(host.frame.height)
                    print("plan \(Int(width)) \(dark ? "dark" : "light") \(state): \(Int(host.frame.height)) pt tall")
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("plan bitmap unavailable") }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("usage-plan-\(Int(width))-\(dark ? "dark" : "light")-\(state).png"))
                    window.close()
                }
            }
        }
        // A refresh never changes the height: reading and a failed read take the open height, closed is one row everywhere.
        let closed = Set(planHeights.filter { $0.key.hasSuffix("closed") }.values)
        guard planHeights.count == 32, closed.count == 1, let closedHeight = closed.first else { fatalError("plan: closed heights differ \(planHeights)") }
        for width in [1200, 760] { for theme in ["light", "dark"] {
            let open = planHeights["\(width) \(theme) open"]!
            guard ["failed", "reading", "contract"].allSatisfy({ planHeights["\(width) \(theme) \($0)"] == open }), open > closedHeight,
                  planHeights["\(width) \(theme) cursor"]! > closedHeight else {
                fatalError("plan: \(width) \(theme) open, failed and reading differ \(planHeights)")
            }
        } }
        // Lead 13:44: the store itself, run here because this harness compiles the view. Two triggers while a read is in
        // flight send one request; a failed read keeps nothing from before; an offscreen store never reads.
        @MainActor final class PlanProbe { var calls: [Bool] = []; var fail = false; var release = false; var done = false; var returned = 0 }
        let probe = PlanProbe()
        let live = PlanRulerStore(read: { refresh in
            probe.calls.append(refresh)
            while !probe.release { try await Task.sleep(nanoseconds: 10_000_000) }
            if probe.fail { throw CocoaError(.fileReadUnknown) }
            return planPane
        })
        let quiet = PlanRulerStore(read: { _ in probe.calls.append(true); return planPane })
        quiet.offscreen = true
        Task { @MainActor in
            let first = Task { @MainActor in await live.load(refresh: false) }
            while probe.calls.isEmpty { await Task.yield() }
            // Not awaited: without the in-flight guard each would block inside the held read, and the check below would
            // never run (run 5 at 15:20 caught that mutant only as "did not finish"). Wait until both triggers returned
            // or a second request went out, whichever comes first.
            let second = Task { @MainActor in await live.load(refresh: true); probe.returned += 1 }   // the page's Refresh while the open's read is in flight
            let third = Task { @MainActor in await live.load(refresh: false); probe.returned += 1 }   // and Usage appearing again
            var spins = 0
            while probe.returned < 2 && probe.calls.count < 2 && spins < 200_000 { await Task.yield(); spins += 1 }
            guard probe.calls == [false], probe.returned == 2, live.loading else { fatalError("plan: two triggers in flight sent \(probe.calls)") }
            probe.release = true; await first.value; await second.value; await third.value
            guard live.pane == planPane, !live.failed, !live.loading else { fatalError("plan: a read did not land") }
            probe.fail = true
            await live.load(refresh: true)
            guard probe.calls == [false, true], live.pane == nil, live.failed else { fatalError("plan: a failed read kept numbers from before") }
            await quiet.load(refresh: true)
            guard probe.calls == [false, true] else { fatalError("plan: an offscreen store read") }
            probe.done = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !probe.done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard probe.done else { fatalError("plan: the store run did not finish") }
        print("PASS: plan store executed: two triggers in flight send one request; a failed read keeps nothing; offscreen never reads")
        print("PASS: plan ruler heights: closed \(closedHeight) pt everywhere; open, failed and reading equal at each width and theme")
        print("PASS: plan Cursor line (server 7.0.45 output, switched on) decodes, is the closest, draws its ruler, and keeps the closed row's height")
        for dark in [false, true] {
            let detail = SessionUsageInspector(title: "Saturday, Oct 24, 2026", rows: rows.filter { $0.day == month + "-24" }, excludingCacheReads: false, measure: .tokens,
                isPeriod: true, canGoEarlier: true, canGoLater: false, comparison: nil, onStep: { _ in }, onClear: {}, onInspectDay: { _ in })
            let host = NSHostingView(rootView: detail.frame(width: 320).background(COSPalette.panel).cosControlTheme())
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 620)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("inspector bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("usage-inspector-\(dark ? "dark" : "light").png"))
        }
        // Render the actual chart overlay with a selected hover period, without sending any event.
        let zone = TimeZone(identifier: "America/Chicago")!
        let calendar = SessionUsagePresentation.reportingCalendar(zone)
        let chartRows = rows.filter { $0.day.hasPrefix(month) }
        let chartPoints = chartRows.map { row in
            SessionUsageView.Point(date: SessionUsagePresentation.noon(of: row.day, calendar: calendar)!, series: row.model, tokens: row.counts.total, usd: row.estimatedUSD, key: row.day)
        }
        for dark in [false, true] {
          // Pointer x in the 756 pt chart: the right-edge case must flip the padded card left of the pointer.
          for (lines, hover, x) in [(false, "-24", 560.0), (true, "-24", 560.0), (true, "-03", 60.0), (false, "-25", 720.0)] {
            let chart = SessionUsageChart(points: chartPoints, rows: chartRows, monthly: false, costChart: false,
                excludeCacheReads: false, timeZone: zone, inspectedPeriod: .constant(nil), initialHover: month + hover, lineChart: lines, initialHoverX: CGFloat(x))
            let host = NSHostingView(rootView: chart.padding(22).frame(width: 800, height: 480, alignment: .top).background(COSPalette.panel).cosControlTheme())
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.appearance = window.appearance
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            let until = Date().addingTimeInterval(1)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("chart overlay bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("usage-chart-hover-\(dark ? "dark" : "light")-\(lines ? "lines" : "bars")\(hover).png"))
            window.close()
          }
        }
        print(only.map { "PASS: offscreen renders of \($0.sorted().joined(separator: ", ")) only" } ?? "PASS: offscreen light/dark Usage renders at 760, 800 and 1200 points, including first load/empty/error/backfill/reversed dates/API/cache/day/slice/sort/history-inspect/paused/long calendar states")
    }
}

/// Server 7.0.45 with COS_CURSOR_PLAN_USAGE=1: planPane() output (claude-server cursor-plan.ts + plan-pane.ts, U1 2026-11-14),
/// Cursor Auto 97% of a Nov 1 to Dec 1 billing period. Generated by the server code, pasted byte for byte.
let cursorFixture = #"""
{"protocolVersion":1,"now":"2026-11-14T16:03:55.000Z","readAt":"2026-11-14T16:03:55.000Z","closest":"cursor","others":"Claude read failed. Codex 96% used.","lines":[{"provider":"claude","name":"Claude","readAt":null,"lastGoodAt":null,"reason":"no_limits","estimate":null,"usedPct":null,"gonePct":null,"windowStart":null,"resetsAt":null,"state":"failed","windowWords":"Week not known","short":"Read failed, refused by Claude","shortLong":"Read failed, refused by Claude","long":"Read failed: refused by Claude. No number is shown until a read succeeds.","quiet":"Claude read failed"},{"provider":"codex","name":"Codex","readAt":"2026-11-14T16:03:55.000Z","lastGoodAt":"2026-11-14T16:03:55.000Z","reason":null,"estimate":{"text":"At this week's average pace, Codex reaches its limit about 4:30 PM, before it resets tonight 10:31 PM.","arithmetic":"Worked out from 96% used in 6 days 11.5 hours of 7 days, about 0.6% an hour."},"usedPct":96,"gonePct":92.6,"windowStart":"2026-11-08T04:31:03.000Z","resetsAt":"2026-11-15T04:31:03.000Z","state":"fresh","windowWords":"Nov 7, 10:31 PM to Nov 14, 10:31 PM","short":"96% used, resets tonight","shortLong":"96% used, resets tonight 10:31 PM","long":"96% used. 93% of the week gone.","quiet":"Codex 96% used"},{"provider":"cursor","name":"Cursor","readAt":"2026-11-14T16:03:55.000Z","lastGoodAt":"2026-11-14T16:03:55.000Z","reason":null,"estimate":{"text":"At this billing period's average pace, Cursor reaches its limit about 8:00 PM, before it resets Dec 1, 2:00 AM.","arithmetic":"Worked out from 97% used in 13 days 8 hours of 30 days, about 0.3% an hour."},"usedPct":97,"gonePct":44.5,"windowStart":"2026-11-01T08:00:00.000Z","resetsAt":"2026-12-01T08:00:00.000Z","state":"fresh","windowWords":"Nov 1, 2:00 AM to Dec 1, 2:00 AM","short":"97% used, resets Dec 1","shortLong":"97% used, resets Dec 1, 2:00 AM","long":"97% used. The bar is the Auto bucket, the higher of the two (API 10%). Total used: 41%. 45% of the billing period gone.","quiet":"Cursor 97% used"}]}
"""#

/// The server's plan answer on 2026-11-14 (the same reading as the web harness and Tests/SessionUsageChecks.swift).
let planFixture = """
{"protocolVersion":1,"now":"2026-11-14T16:03:55.000Z","readAt":"2026-11-14T16:03:55.000Z","closest":"codex","others":"Claude read failed. Cursor no plan reading.","lines":[
{"provider":"claude","name":"Claude","state":"failed","usedPct":null,"gonePct":null,"windowWords":"Week not known","short":"Read failed, refused by Claude","shortLong":"Read failed, refused by Claude","long":"Read failed: refused by Claude. No number is shown until a read succeeds.","quiet":"Claude read failed","readAt":null,"estimate":null},
{"provider":"codex","name":"Codex","state":"fresh","usedPct":96,"gonePct":92.6,"windowWords":"Nov 7, 10:31 PM to Nov 14, 10:31 PM","short":"96% used, resets tonight","shortLong":"96% used, resets tonight 10:31 PM","long":"96% used. 93% of the week gone.","quiet":"Codex 96% used","readAt":"2026-11-14T16:03:55.000Z","estimate":{"text":"At this week's average pace, Codex reaches its limit about 4:30 PM, before it resets tonight 10:31 PM.","arithmetic":"Worked out from 96% used in 6 days 11.5 hours of 7 days, about 0.6% an hour."}},
{"provider":"cursor","name":"Cursor","state":"no_plan","usedPct":null,"gonePct":null,"windowWords":"","short":"No plan reading","shortLong":"No plan reading","long":"No plan reading. Cursor does not report its plan to COS.","quiet":"Cursor no plan reading","readAt":null,"estimate":null}]}
"""
