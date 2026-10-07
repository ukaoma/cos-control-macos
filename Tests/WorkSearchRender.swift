import AppKit
import SwiftUI

/// 0.5.259, run by hand (Tests/run-work-search-render.sh <folder>): the Work board with a search active and with Order
/// set to Recent activity, drawn off screen to PNGs for a side-by-side check against board 4 of
/// operations/personal/wk41_2026/MOCK_activity_work_search_2026-10-06.html. The mock's fifteen Quilt cards (and two in
/// Personal, for "2 more in Personal") come through the real load path from a stand-in helper; Jev is a fake that names
/// the cards the mock marks "by meaning". Windows are never ordered in, the process can never become active, and nothing
/// is clicked, typed or dragged.
@main @MainActor struct WorkSearchRender {
    static let meeting = "Deprioritize CityHive, Feature DoorDash Integrations (G2)"
    /// (stage, text, source, meeting title or nil, created (server), minutes since the last activity)
    static let cards: [(String, String, String, String?, String?, Double)] = [
        ("mentioned", "Make DoorDash the most prominent e-commerce integration and move CityHive to the lowest tier on the Bottle POS integrations module, e-comm page and integrations page", meeting, meeting, "2026-10-06", 12),
        ("mentioned", "Send Cort screenshots of the paid search campaigns Scotch is running, so the team can target the Bottle POS promo", meeting, meeting, "2026-10-06", 659),
        ("mentioned", "Decide with Niala the incentive budget for the Capterra review push to liquor store customers", meeting, meeting, "2026-10-06", 659),
        ("mentioned", "Review the Clover and Square funnel audit with Graham", "", nil, nil, 9_070),
        ("planned", "Launch the refreshed IT Retail site on Thursday, with the competitor pages and site refreshes", meeting, meeting, "2026-10-06", 470),
        ("planned", "Launch the refreshed CigarsPOS site at the start of next sprint", meeting, meeting, "2026-10-06", 684),
        ("planned", "Fix the Bottle POS website backlog left over from launch", meeting, meeting, "2026-10-06", 684),
        ("planned", "Finish the MarktPOS origins video for an October 23 final: animation polish and color grading", meeting, meeting, "2026-10-06", 3_550),
        ("planned", "Start a weekly review of the new website's session-to-contact rate and keyword rankings", "PR Strategy [2026-09-15]", "PR Strategy", nil, 10_810),
        ("draft", "October switch offer page for Bottle POS, the response to Scotch", "Manual entry 2026-10-06", nil, nil, 125),
        ("draft", "Small Business Season promo landing pages: review and sign off", "Launchpad Huddle [2026-09-29]", "Launchpad Huddle", nil, 510),
        ("built", "IT Retail 3D lane module on the sandbox homepage", "Manual entry 2026-10-03", nil, nil, 99),
        ("qa", "Bottle POS hardware expanding cards: rescan the pages before upload", "[2026-09-24]", nil, nil, 6_250),
        ("complete", "Bottle POS review scores read live from HubDB, refreshed weekly by a Cloudflare Worker", "Manual entry 2026-10-01", nil, nil, 1_750),
        ("complete", "Swap the RLS 2026 promo on Wednesday 9/30 at 11:59 PM ET", "Weatherford Weekly Sync [2026-09-28]", "Weatherford Weekly Sync", nil, 8_590),
    ]
    static func hex(_ n: Int) -> String { String(format: "b%011x", n) }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let fixtures = ProcessInfo.processInfo.environment["COS_SEARCH_FIXTURES"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            fputs("COS_SEARCH_FIXTURES is not set: run Tests/run-work-search-render.sh\n", stderr); exit(2)
        }
        let now = Date()
        var rows: [JSONValue] = []
        for (index, card) in cards.enumerated() {
            var row: [String: JSONValue] = ["id": .string(hex(index + 1)), "domain": .string("quilt"), "title": .string(String(card.1.prefix(44))), "text": .string(card.1),
                "source": .string(card.2), "checked": .bool(card.0 == "complete"), "workStage": .string(card.0), "workRevision": .string(String(repeating: "c", count: 64)),
                "column": .string("planning"), "section": .string("inbox"),
                "meetingRefs": .array(card.3.map { [.object(["recordId": .string("ops:quilt:2026-10:\(index).md"), "domain": .string("quilt"), "month": .string("2026-10"),
                                                             "filename": .string("2026-10-06_\(index).md"), "title": .string($0)])] } ?? [])]
            if let created = card.4 { row["createdOn"] = .string(created); row["createdFrom"] = .string("git") }
            rows.append(.object(row))
        }
        for (index, text) in ["Competitor ads for the pet store launch", "Check the ads competitor list for Rain"].enumerated() {
            rows.append(.object(["id": .string(hex(40 + index)), "domain": .string("personal"), "title": .string(text), "text": .string(text), "checked": .bool(false),
                                 "workStage": .string("planned"), "workRevision": .string(String(repeating: "c", count: 64)), "source": .string("")]))
        }
        let board: JSONValue = .object(["ok": .bool(true), "message": .string(""), "details": .object(["tasks": .array(rows), "complete": .bool(true),
            "capabilities": .object(["version": .number(1), "writable": .bool(true)])])])
        try JSONEncoder().encode(board).write(to: fixtures.appendingPathComponent("work-tasks.json"))

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let handoffStore = WorkHandoffStore(storageURL: home.appendingPathComponent("render-handoffs.json"), transport: { _, _ in
            throw HelperClientError.invalidResponse("The render harness lists no sessions.")
        })
        let reviewStore = WorkReviewStore(transport: { _, _ in
            HelperResponse(ok: true, message: "", details: ["capabilities": .object(["manualReview": .bool(true)]), "reviews": .array([])])
        })
        let model = ControllerModel(startBackgroundWork: false)
        await model.loadWorkTasks()
        precondition(model.workTasks.count == cards.count + 2, "the stand-in helper did not load the board: \(model.workTasksError ?? "?")")
        // Recent activity: the mock's times, noted as Control's own stage moves.
        for (index, card) in cards.enumerated() {
            model.workActivity.record("task:quilt:" + hex(index + 1), at: now.addingTimeInterval(-card.5 * 60))
        }
        final class Saved: @unchecked Sendable { var values: [String: String] = [:] }
        let saved = Saved()
        // Jev: the three cards the mock finds "by meaning" for "competitor ads".
        let meaning: [String: Double] = [hex(2): 0.62, hex(10): 0.41, hex(4): 0.18, hex(9): 0.06]
        func state(query: String, order: WorkBoardOrder, reason: String? = nil) -> WorkWorkspaceState {
            let state = WorkWorkspaceState()
            state.orderStore = WorkBoardOrderStore(read: { saved.values[$0] }, write: { saved.values[$0] = $1 })
            state.searchPause = .zero
            state.searchTransport = { _, body in
                if let reason { return HelperResponse(ok: true, message: "", details: ["available": .bool(false), "reason": .string(reason)]) }
                // The mock's "competitor ads"; any other search comes back empty, as Jev's does for a broad or unrelated one.
                let asked = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["query"] as? String
                return HelperResponse(ok: true, message: "", details: ["available": .bool(true),
                    "results": .array(asked == "competitor ads" ? meaning.map { .object(["id": .string($0.key), "p": .number($0.value)]) } : [])])
            }
            state.domain = "quilt"
            state.query = query
            state.setOrder(order, domain: "quilt", scope: .all, isolated: false)
            return state
        }
        func view(_ state: WorkWorkspaceState) -> some View {
            WorkWorkspaceView(model: model, handoffStore: handoffStore, reviewStore: reviewStore, state: state,
                              onOpenSession: { _ in }, onEditTask: { _ in }, onReviewMeeting: { _ in })
        }
        // A window that is never ordered in never runs a view's .task, so Jev's answer is asked here, with the request the
        // board's own task builds (Tests/work-search-pins.py pins that task).
        let onBoard = WorkWorkspaceProjection.filter(WorkWorkspaceProjection.items(tasks: model.workTasks, reviews: [], receipts: []),
                                                     scope: .all, domain: "quilt", query: "")
        func asked(_ state: WorkWorkspaceState) async -> WorkWorkspaceState {
            await state.searchMeaning(WorkSearch.request(key: state.currentSearchKey, query: state.query, items: onBoard), isolated: false)
            return state
        }
        try render(view(await asked(state(query: "competitor ads", order: .board))), width: 1500, height: 1250, name: "work-search-active", out: out)
        try render(view(state(query: "", order: .recent)), width: 1500, height: 1250, name: "work-order-recent", out: out)
        try render(view(await asked(state(query: "website launch", order: .recent))), width: 1500, height: 1250, name: "work-search-recent", out: out)
        try render(view(await asked(state(query: "competitor ads", order: .newest, reason: "server_too_old"))), width: 1500, height: 1250, name: "work-search-old-server", out: out)
        print("wrote PNGs to \(out.path)")
    }

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height).background(COSPalette.panel))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            settle(host, seconds: 2)
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
