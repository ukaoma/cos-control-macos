import AppKit
import SwiftUI

/// Offscreen PNGs of the COS cost page: every state at 1200 and 760 points, light and dark. Hand-run with
/// Tests/run-cos-cost-render.sh. COS_COST_RENDER_REPORT adds the page on a real report (counts only), with
/// COS_COST_RENDER_USAGE_TOTAL as Usage's total for its window. The store is frozen, so the helper never runs.
@main @MainActor struct CosCostRender {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func base() -> CosUsageReport {
            var r = CosUsageReport(windowStart: "2026-10-02", windowEnd: "2026-10-31", timeZone: "America/Chicago", updatedAt: "2026-10-31T17:00:00Z", auditFound: true, runLedgersFound: true, gistLedgerFound: true)
            r.work = CosWorkSummary(handoffsFound: true, runs: 12, measuredUSD: 41.2, measuredTokens: 92_000_000, widerUSD: 214.6, widerTokens: 480_000_000, unprovenRuns: 1)
            return r
        }
        func row(_ c: CosCostCategory, calls: Int, measured: Int = 0, usd: Double = 0, tokens: Int64 = 0, floor: Double = 0, floorTokens: Int64 = 0, adds: Double = 0) -> CosCostRow {
            var r = CosCostRow(category: c)
            r.calls = calls; r.measuredCalls = measured; r.measuredUSD = usd; r.measuredTokens = tokens
            r.estimatedCalls = calls - measured; r.estimatedUSD = floor; r.estimatedPricedCalls = floor > 0 ? calls - measured : 0
            r.estimatedTokens = floorTokens; r.addsToTotalUSD = adds
            return r
        }
        var measured = base()
        measured.rows = [row(.dictation, calls: 1685, measured: 1685, usd: 3.92, tokens: 1_940_000, adds: 3.92),
                         row(.transcription, calls: 547, measured: 547, usd: 6.48, tokens: 3_120_000, adds: 6.48),
                         row(.meetingNotes, calls: 212, measured: 212, usd: 11.2, tokens: 4_100_000, adds: 11.2),
                         row(.answers, calls: 138, measured: 138, usd: 212.4, tokens: 340_000_000),
                         row(.liveAndUpkeep, calls: 1428, measured: 1428, usd: 24.8, tokens: 21_000_000, adds: 24.8)]
        var mixed = base()
        mixed.rows = [row(.dictationBeforeSplit, calls: 1319, floor: 0.28, floorTokens: 64_000),
                      row(.dictation, calls: 363, floor: 0.17, floorTokens: 50_000),
                      row(.transcription, calls: 547, floor: 0.11, floorTokens: 18_000),
                      row(.meetingNotes, calls: 1070, floor: 13.38, floorTokens: 8_450_000),
                      row(.answers, calls: 374, measured: 101, usd: 147.49, tokens: 243_000_000, floor: 5.91, floorTokens: 1_920_000),
                      row(.liveAndUpkeep, calls: 1429, measured: 696, usd: 20.55, tokens: 20_700_000, floor: 2.09, floorTokens: 860_000, adds: 4.35),
                      row(.memoryIndexing, calls: 2987, floor: 44.07, floorTokens: 11_260_000),
                      row(.other, calls: 8, floorTokens: 12_000)]
        var bg = row(.work, calls: 860, floor: 1.41, floorTokens: 14_100_000); bg.estimatedCalls = 860
        mixed.rows.append(bg)
        var publicServer = base()
        publicServer.gistLedgerFound = false
        publicServer.work = CosWorkSummary(handoffsFound: true, runs: 0)
        publicServer.rows = [row(.dictation, calls: 1685, floor: 0.44, floorTokens: 220_000),
                             row(.transcription, calls: 214, floor: 0.09, floorTokens: 41_000),
                             row(.answers, calls: 96, floor: 2.1, floorTokens: 610_000),
                             row(.liveAndUpkeep, calls: 402, floor: 0.71, floorTokens: 180_000)]
        var noLedger = CosUsageReport(windowStart: "2026-10-02", windowEnd: "2026-10-31", timeZone: "America/Chicago", updatedAt: "2026-10-31T17:00:00Z")
        noLedger.work = CosWorkSummary(handoffsFound: false)
        var noUsage = base()
        noUsage.work = CosWorkSummary(handoffsFound: true, runs: 0)
        var reading = mixed
        reading.sessions = CosSliceProgress(tracked: 87, stillReading: 6, noLogs: 2, compressed: 11)
        struct Case {
            var name: String
            var report: CosUsageReport?
            var usageTotal = 17_209.61
            var pending = 0
            var paused = false
            var price = ""
            var notes = false
            var failed = false
        }
        var cases = [
            Case(name: "nothing-measured", report: publicServer, usageTotal: 2_140),
            Case(name: "real-rows", report: measured),
            Case(name: "mixed", report: mixed),
            Case(name: "no-ledger", report: noLedger, usageTotal: 0),
            Case(name: "usage-paused", report: mixed, paused: true),
            Case(name: "usage-importing", report: mixed, pending: 37),
            Case(name: "still-reading", report: reading),
            Case(name: "price-entered", report: mixed, price: "$200"),
            Case(name: "no-cos-usage", report: noUsage, usageTotal: 1_204),
            Case(name: "how-counted", report: mixed, notes: true),
            Case(name: "first-load", report: nil),
            Case(name: "helper-failed", report: nil, failed: true),
        ]
        let env = ProcessInfo.processInfo.environment
        if let path = env["COS_COST_RENDER_REPORT"] {
            let real = try JSONDecoder().decode(CosUsageReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let total = Double(env["COS_COST_RENDER_USAGE_TOTAL"] ?? "") ?? 0
            cases = [Case(name: "real-data", report: real, usageTotal: total), Case(name: "real-data-price", report: real, usageTotal: total, price: "$200"), Case(name: "real-data-how-counted", report: real, usageTotal: total, notes: true)]
        }
        for width in [1200.0, 760.0] {
            for dark in [false, true] {
                for fixture in cases {
                    let usage = SessionUsageStore()
                    usage.enabled = !fixture.paused
                    usage.report = SessionUsageReport(buckets: [SessionUsageBucket(day: "2026-10-30", provider: "Anthropic", model: "claude-opus-5-5", counts: SessionUsageCounts(input: 1), events: 1, pricedEvents: 1, estimatedUSD: fixture.usageTotal)],
                        updatedAt: "2026-10-31T17:00:00Z", timeZone: "America/Chicago", filesIndexed: 3140, pendingFiles: fixture.pending, unreadableFiles: 0, malformedRows: 0, missingBaselineEvents: 0, coverage: [], pricingVersion: SessionUsagePricing.version)
                    let store = CosCostStore()
                    store.frozen = true
                    store.report = fixture.report
                    store.monthlyPrice = fixture.price
                    if fixture.failed { store.error = "COS cost could not refresh: the helper did not answer." }
                    let height = 1180.0
                    let page = CosCostView(usage: usage, store: store, showNotes: fixture.notes)
                    let host = NSHostingView(rootView: page.cosControlTheme().frame(width: width, height: height, alignment: .top).background(COSPalette.panel))
                    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.appearance = window.appearance
                    window.contentView = host
                    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    let until = Date().addingTimeInterval(0.8)
                    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), let data = {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        return rep.representation(using: .png, properties: [:])
                    }() else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: out.appendingPathComponent("cost-\(Int(width))-\(dark ? "dark" : "light")-\(fixture.name).png"))
                    window.close()
                }
            }
        }
        print("PASS: offscreen COS cost renders at 760 and 1200 points, light and dark")
    }
}
