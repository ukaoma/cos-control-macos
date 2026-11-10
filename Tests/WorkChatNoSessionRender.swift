import AppKit
import SwiftUI

/// 0.5.386, run by hand (Tests/run-work-chat-no-session-render.sh <folder>): Work chat and the Agent workspace on a card
/// with no session, drawn off screen to PNGs. The real WorkTaskChatStore and WorkHandoffStore against a fake transport (no
/// server, no provider): an empty card whose plan is one New Claude session at Ready to send; the same card when the
/// planner answered without one (the one-click button); a plan that failed before planning (Plan again); and the Agent
/// workspace with "Start a new session" preselected and another card's suggestion offered, not selected.
/// Windows are never ordered in, the process can never become active, and nothing is clicked, typed or dragged.
private actor NoSessionFixture {
    let linked = "claude:32386d7e-f751-41c5-a185-a0d731416a01"
    var plan: [JSONValue] = []
    var failInput = false
    func setPlan(_ value: [JSONValue]) { plan = value }
    func setFailInput(_ value: Bool) { failInput = value }
    func run(_ args: [String], _ data: Data?) async throws -> HelperResponse {
        var out: [String: JSONValue] = [:]
        switch args.first ?? "" {
        case "work-models": out = ["serverInstanceId": .string("render"), "models": .array([
            .object(["id": .string("sonnet"), "provider": .string("claude"), "title": .string("Claude · Sonnet"), "available": .bool(true)]),
            .object(["id": .string("opus"), "provider": .string("claude"), "title": .string("Claude · Opus"), "available": .bool(true)]),
            .object(["id": .string("codex-frontier"), "provider": .string("codex"), "title": .string("OpenAI / Codex · Frontier"), "available": .bool(true)])])]
        case "claude-sessions": out = ["sessions": .array([.object(["id": .string(String(linked.split(separator: ":")[1])), "provider": .string("claude"),
                                                                    "name": .string("SubQ pricing page rewrite"), "workspace": .string("/tmp/render"), "state": .string("recent")])])]
        case "work-chat-capabilities": out = ["protocolVersion": .number(1), "planners": .array([.string("sonnet"), .string("opus")]), "efforts": .array([.string("high")]), "orchestrator": .bool(true)]
        case "work-context": out = ["contextText": .string("Draft the Q4 thrift industry one-pager from the survey results."), "workRevision": .string(String(repeating: "d", count: 64)),
            "task": .object(["id": .string("b1b2c3d4e5f6"), "workIdentity": .string("b1b2c3d4e5f6"), "domain": .string("quilt"), "title": .string("Thrift industry one-pager"), "text": .string("Thrift industry one-pager"), "source": .string("Render fixture")])]
        case "work-orchestrator-input":
            if failInput { throw HelperClientError.commandFailed("COS could not read the session list on this Mac (one session had an id COS cannot use). Server reason: invalid_snapshot, invalid_live_row (HTTP 400).") }
            out = ["protocolVersion": .number(1), "workID": .string("task:quilt:b1b2c3d4e5f6"), "now": .string("2026-11-09T22:30:00Z"), "rows": .array([]), "leftOut": .array([]),
                   "usage": .array([]), "discovered": .number(0), "snapshotAgeSec": .number(0), "liveListAgeSec": .number(1), "logScanComplete": .bool(true)]
        case "work-chat":
            out = ["protocolVersion": .number(1), "model": .string("claude:opus"), "effort": .string("high"), "assignments": .array(plan),
                   "answer": .string(plan.isEmpty ? "This task has no session yet. The survey results and the brief are on the card." : "No session works on this task yet, so I planned one new Claude session to draft the one-pager from the survey results and the brief on the card.")]
        case "work-session-recommend":
            out = ["provider": .string("subq"), "action": .string("continue"), "sessionId": .string(linked), "confidence": .number(0.73), "reason": .string("Its pricing work overlaps this request.")]
        default: throw HelperClientError.commandFailed("Render fixture has no \(args.first ?? "")")
        }
        return HelperResponse(ok: true, message: "Fixture", details: out)
    }
}

@main @MainActor struct WorkChatNoSessionRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cos-no-session-render-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("COS_CONTROL_TEST_HOME", root.appendingPathComponent("home").path, 1)

        let fixture = NoSessionFixture()
        let other = WorkSource.taskSnapshot(TaskRow(.object(["id": .string("a1a2a3a4a5a6"), "workIdentity": .string("a1a2a3a4a5a6"), "domain": .string("quilt"),
                                                            "title": .string("SubQ pricing"), "text": .string("SubQ pricing"), "source": .string("Render fixture")]))!)
        let card = WorkSource.taskSnapshot(TaskRow(.object(["id": .string("b1b2c3d4e5f6"), "workIdentity": .string("b1b2c3d4e5f6"), "domain": .string("quilt"),
                                                           "title": .string("Thrift industry one-pager"), "text": .string("Thrift industry one-pager"), "source": .string("Render fixture")]))!)
        let store = WorkHandoffStore(storageURL: root.appendingPathComponent("journal.json"), transport: { args, data in try await fixture.run(args, data) })
        // The suggested session works on ANOTHER card, as SubQ's 73 percent pick did on 2026-11-09.
        precondition(store.confirmSessionCard(sessionID: fixture.linked, source: other))
        await store.refresh()

        // 1. Work chat on the empty card: one New Claude session, stopped at Ready to send.
        let chat = WorkTaskChatStore(); chat.enabled = true; chat.open(source: card, handoff: store)
        await chat.loadPlanners(handoff: store, retryDelay: .zero)
        await fixture.setPlan([.object(["mode": .string("newSession"), "provider": .string("claude"),
                                        "prompt": .string("Draft the Q4 thrift industry one-pager from the survey results and the brief on the card. Report the draft and open questions. Do not publish.")])])
        chat.setDraft("Draft the thrift one-pager from the survey results.")
        await chat.send(source: card, handoff: store, planner: "opus", effort: "high")
        print("round 1: \(chat.record?.rounds.last?.state ?? "none") · \(chat.record?.rounds.last?.sessionsNote ?? "") · error \(chat.error ?? "none")")
        try render(chatView(chat, store, card), width: 760, name: "work-chat-empty-card-ready-to-send", out: out)
        try render(chatView(chat, store, card), width: 390, name: "work-chat-empty-card-ready-to-send-390pt", out: out)

        // 2. The planner answered without one: the round offers the one click.
        await fixture.setPlan([])
        chat.setDraft("What should happen on this card first?")
        await chat.send(source: card, handoff: store, planner: "opus", effort: "high")
        print("round 2: \(chat.record?.rounds.last?.state ?? "none") · offer \(chat.record?.rounds.last?.offerNewSession ?? "none")")
        // 3. A plan that failed before planning: Plan again, and the honest error.
        await fixture.setFailInput(true)
        chat.setDraft("Pick the one-pager back up.")
        await chat.send(source: card, handoff: store, planner: "opus", effort: "high")
        print("round 3: \(chat.record?.rounds.last?.state ?? "none") · error \(chat.error ?? "none")")
        try render(chatView(chat, store, card), width: 760, name: "work-chat-offer-and-plan-again", out: out)

        // 4. The Agent workspace on the empty card: Start a new session preselected (Claude Opus), SubQ's pick offered.
        await store.loadAdvice(for: card)
        let draft = store.draft(for: card)
        print("workspace: mode \(draft.mode) provider \(draft.provider) model \(draft.modelID) · advice \(store.advice(for: card).map { "\($0.action) \($0.percent)" } ?? "none")")
        try render(WorkHandoffView(store: store, source: card, isPreview: true, onOpenSession: { _ in }).padding(18), width: 440, name: "agent-workspace-empty-card", out: out)
        print("wrote PNGs to \(out.path)")
    }

    static func chatView(_ chat: WorkTaskChatStore, _ store: WorkHandoffStore, _ card: WorkSource) -> some View {
        WorkTaskChatView(chat: chat, handoff: store, source: card, onOpenSession: { _ in }).padding(18)
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width).frame(height: height).background(COSPalette.panel))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height ?? 1600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            let size = height.map { NSSize(width: width, height: $0) } ?? host.fittingSize
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(size.height, 40)))
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
