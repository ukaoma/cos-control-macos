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
            for (index, model) in ["claude-opus-5-5", "gpt-6.1-sol", "unpriced-model"].enumerated() {
                rows.append(SessionUsageBucket(day: month + String(format: "-%02d", day), provider: index == 0 ? "Anthropic" : "OpenAI", model: model,
                    counts: SessionUsageCounts(input: Int64(day*2300), output: Int64(day*900), cacheRead: Int64(day*70000)),
                    events: 10, pricedEvents: index == 2 ? 0 : 10, estimatedUSD: index == 2 ? 0 : Double(day)*0.21))
            }
        }
        store.report = SessionUsageReport(buckets: rows, updatedAt: "2026-10-25T21:00:00Z", timeZone: "America/Chicago", filesIndexed: 120, pendingFiles: 0, unreadableFiles: 0, malformedRows: 0, missingBaselineEvents: 0,
            coverage: ["Claude Code and Codex local session logs, including archived sessions and subagents.", "Cursor, browser-only chats and other Macs are not included."], pricingVersion: SessionUsagePricing.version)
        for width in [1200.0, 800.0] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: SessionUsageView(store: store).frame(width: width, height: 1100).background(COSPalette.panel))
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
                try data.write(to: out.appendingPathComponent("usage-\(Int(width))-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
        print("PASS: offscreen light/dark Usage renders at 800 and 1200 points")
    }
}
