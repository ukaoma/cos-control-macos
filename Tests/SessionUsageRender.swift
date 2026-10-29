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
        }
        let historyRows = rows.map { row -> SessionUsageBucket in
            var copy = row
            copy.day = "2026-08-" + row.day.suffix(2)
            return copy
        }
        rows += historyRows
        store.report = SessionUsageReport(buckets: rows, updatedAt: "2026-10-25T21:00:00Z", timeZone: "America/Chicago", filesIndexed: 120, pendingFiles: 0, unreadableFiles: 0, malformedRows: 0, missingBaselineEvents: 0,
            coverage: ["Claude Code and Codex local session logs, including archived sessions and subagents.", "Cursor, browser-only chats and other Macs are not included."], pricingVersion: SessionUsagePricing.version)
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
            var lineChart = true
            var provider = "All providers"
        }
        let cases: [PageCase] = [
            PageCase(name: "range"),
            PageCase(name: "weekly-categories", scale: .weekly, series: .categories, lineChart: false),
            PageCase(name: "records-filtered", minimumOnly: true, measure: .records, provider: "Anthropic"),
            PageCase(name: "history", period: "All history", inspection: "2026-08"),
            PageCase(name: "custom", period: "Custom dates", inspection: month + "-24"),
            PageCase(name: "90days", period: "Last 90 days"),
            PageCase(name: "empty", empty: true, minimumOnly: true),
            PageCase(name: "empty-cost", cost: true, empty: true, minimumOnly: true),
            PageCase(name: "error", failed: true, minimumOnly: true),
            PageCase(name: "backfill", pending: true, minimumOnly: true),
            PageCase(name: "reversed-custom", period: "Custom dates", cost: true, reversed: true, minimumOnly: true),
            PageCase(name: "api-cost", inspection: month + "-24", cost: true, minimumOnly: true),
            PageCase(name: "cache-excluded", inspection: month + "-24", cacheExcluded: true, minimumOnly: true),
            PageCase(name: "expanded-days", expanded: true, minimumOnly: true),
        ]
        for width in [1200.0, 800.0, 760.0] {
            for dark in [false, true] {
              for fixture in cases where !fixture.minimumOnly || width == 760 {
                let pageStore = SessionUsageStore()
                var report = fixtureReport
                if fixture.empty { report.buckets = []; report.filesIndexed = 0 }
                if fixture.pending { report.pendingFiles = 37 }
                pageStore.report = report
                if fixture.failed { pageStore.error = "Usage could not refresh: fixture helper unavailable. Showing the last recorded history." }
                let dates = fixture.reversed ? (Date(), Calendar.current.date(byAdding: .day, value: -1, to: Date())!) : nil
                let height = fixture.expanded ? 3400.0 : 2200.0
                let page = SessionUsageView(store: pageStore, initialPeriod: fixture.period, initialInspection: fixture.inspection,
                    initialDates: dates, initialCostChart: fixture.cost, initialExcludeCacheReads: fixture.cacheExcluded,
                    initialDayBreakdownExpanded: fixture.expanded, initialTimeScale: fixture.scale,
                    initialMeasure: fixture.measure, initialSeries: fixture.series,
                    initialLineChart: fixture.lineChart, initialProvider: fixture.provider)
                let host = NSHostingView(rootView: page.cosControlTheme().frame(width: width, height: height).background(COSPalette.panel))
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
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
            let detail = SessionUsagePeriodDetail(title: "Saturday, Oct 24, 2026", rows: rows.filter { $0.day == month + "-24" }, excludingCacheReads: false, compact: true)
            let host = NSHostingView(rootView: detail.padding(14).frame(width: 418).background(COSPalette.card).cosControlTheme())
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 418, height: 440)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("tooltip bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("usage-tooltip-\(dark ? "dark" : "light").png"))
        }
        // Render the actual chart overlay with a selected hover period, without sending any event.
        let zone = TimeZone(identifier: "America/Chicago")!
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = zone
        let chartRows = rows.filter { $0.day.hasPrefix(month) }
        let chartPoints = chartRows.map { row in
            SessionUsageView.Point(date: formatter.date(from: row.day)!, series: row.model, tokens: row.counts.total, usd: row.estimatedUSD)
        }
        for dark in [false, true] {
          for lines in [false, true] {
            let chart = SessionUsageChart(points: chartPoints, rows: chartRows, monthly: false, costChart: false,
                excludeCacheReads: false, timeZone: zone, inspectedPeriod: .constant(nil), initialHover: month + "-24", lineChart: lines)
            let host = NSHostingView(rootView: chart.padding(22).frame(width: 800, height: 480, alignment: .top).background(COSPalette.panel).cosControlTheme())
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.appearance = window.appearance
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            let until = Date().addingTimeInterval(1)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("chart overlay bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("usage-chart-hover-\(dark ? "dark" : "light")-\(lines ? "lines" : "bars").png"))
            window.close()
          }
        }
        print("PASS: offscreen light/dark Usage renders at 760, 800 and 1200 points, including empty/error/backfill/reversed dates/API/cache/day states")
    }
}
