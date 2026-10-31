import AppKit
import SwiftUI

@main @MainActor struct SessionUsageRender {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = SessionUsageStore()
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
            coverage: ["Claude Code and Codex local session logs, including archived sessions and subagents.", "Cursor, browser-only chats and other Macs are not included."], pricingVersion: SessionUsagePricing.version)
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
            PageCase(name: "cursor-sign-in", cursorFeed: SessionUsageCursorFeedStatus(state: .signIn, message: "This Mac has no Cursor command line sign-in. Run cursor-agent login in Terminal, then refresh."), cursorOn: true),
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
        for width in [1200.0, 800.0, 760.0] {
            for dark in [false, true] {
              for fixture in cases where (!fixture.minimumOnly || width == 760) && (only?.contains(fixture.name) ?? true) {
                let pageStore = SessionUsageStore()
                // The Cursor states are about a Mac with no Cursor rows yet, so they stay on the invented fixture.
                var report = fixture.name.hasPrefix("cursor-") || fixture.name == "notes" ? plainReport : fixtureReport
                report.cursorFeed = fixture.cursorFeed
                pageStore.cursorEnabled = fixture.cursorOn
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
        print("PASS: offscreen light/dark Usage renders at 760, 800 and 1200 points, including first load/empty/error/backfill/reversed dates/API/cache/day/slice/sort/history-inspect states")
    }
}
