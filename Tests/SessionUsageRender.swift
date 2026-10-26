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
                    counts: SessionUsageCounts(input: Int64(day*2300), output: Int64(day*900), cacheRead: Int64(day*70000)),
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
        for width in [1200.0, 800.0] {
            for dark in [false, true] {
              for history in [false, true] {
                let host = NSHostingView(rootView: SessionUsageView(store: store, initialPeriod: history ? "All history" : nil, initialInspection: history ? "2026-08" : nil).cosControlTheme().frame(width: width, height: 1100).background(COSPalette.panel))
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
                let until = Date().addingTimeInterval(1)
                while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), let data = {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    return rep.representation(using: .png, properties: [:])
                }() else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: out.appendingPathComponent("usage-\(Int(width))-\(dark ? "dark" : "light")-\(history ? "history" : "month").png"))
                window.close()
              }
            }
        }
        for dark in [false, true] {
            let detail = SessionUsagePeriodDetail(title: "Saturday, Oct 24, 2026", rows: rows.filter { $0.day == month + "-24" }, excludingCacheReads: false, compact: true)
            let host = NSHostingView(rootView: detail.padding(14).frame(width: 418).background(COSPalette.card).cosControlTheme())
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 418, height: 340)
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
            let chart = SessionUsageChart(points: chartPoints, rows: chartRows, monthly: false, costChart: false,
                excludeCacheReads: false, timeZone: zone, inspectedPeriod: .constant(nil), initialHover: month + "-24")
            let host = NSHostingView(rootView: chart.padding(22).frame(width: 800, height: 480, alignment: .top).background(COSPalette.panel).cosControlTheme())
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.appearance = window.appearance
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            let until = Date().addingTimeInterval(1)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("chart overlay bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("usage-chart-hover-\(dark ? "dark" : "light").png"))
            window.close()
        }
        print("PASS: offscreen light/dark Usage renders at 800 and 1200 points")
    }
}
