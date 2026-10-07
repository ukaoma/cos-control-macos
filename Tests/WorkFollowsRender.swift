import AppKit
import SwiftUI

/// 0.5.262, run by hand (Tests/run-work-follows-render.sh <folder>): what COS moved, drawn off screen to PNGs. The
/// board with a "Moved by COS" card, a "COS would move this" card and a "1 of 2 met" card; Moved for you; the card
/// detail's finish line checklist and history; and the Settings rows (shadow mode and the Work background model). The
/// isolated preview store and a scratch home: no server, no provider. Windows are never ordered in, the process can
/// never become active, and nothing is clicked, typed or dragged.
@main @MainActor struct WorkFollowsRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = WorkHandoffStore(isolated: true)
        let rows = WorkWorkspaceProjection.previewRows(store.previewTasks)
        func card(_ id: String) -> TaskRow { rows.first { $0.id == id }! }
        let now = Date().timeIntervalSince1970
        let review = card("sample-task-review"), website = card("sample-task-website"), draft = card("sample-task-draft")
        let page = "https://bottlepos.com/october-switch-offer page is live"
        let ads = "Facebook ads are running against it, driving traffic there"
        func clause(_ text: String, _ verdict: String, _ source: String?, _ excerpt: String?, _ at: String?) -> WorkMoveClause {
            WorkMoveClause(text: text, verdict: verdict, kind: verdict == "met" ? "fact" : "intent", source: source,
                           ref: source == "url" ? "https://bottlepos.com/october-switch-offer" : nil, excerpt: excerpt, at: at, deterministic: source == "url")
        }
        let pageMet = clause(page, "met", "url", "200 \u{00B7} Switch to Bottle POS: $3,000 + Free Hardware", "2026-10-07T21:31:00Z")
        let adsMet = clause(ads, "met", "slack", "Ads are live on Meta and pointed at the offer page.", "2026-10-07T22:05:00Z")
        let adsWaiting = clause(ads, "not_met", "slack", "Ready to go live, just need your sign off.", "2026-10-07T16:52:00Z")
        // A move COS made two hours ago, and one it would make (shadow), on two cards.
        store.recordStageMove(workID: review.workSourceID, title: review.text, from: "built", to: "qa",
                              move: WorkStageMove(by: .cos, why: "every part of the finish line is met", clauses: [pageMet, adsMet], judgedRevision: "r"), at: now - 7_300)
        store.recordStageMove(workID: draft.workSourceID, title: draft.text, from: "draft", to: "qa",
                              move: WorkStageMove(by: .cos, why: "the evidence shows the task finished (Jev, two sources)",
                                                  clauses: [clause(draft.text, "met", "session", "Copy is in the review doc and checked at 390pt.", "2026-10-07T20:10:00Z")]),
                              shadow: true, at: now - 1_500)
        // A card whose finish line is half met: the page is live, the ads wait on a sign-off.
        store.follows.add(workID: website.workSourceID, sessionID: "claude:ff34d7bf-1111-4222-8333-944455556666", origin: .receipt, startedAt: now - 86_400)
        store.follows.setCard(website.workSourceID) { state in
            state.basis = "clauses"; state.checkedAt = now - 600
            state.clauses = [WorkClauseState(text: page, verdict: "met", confidence: 0.93, kind: "fact", evidence: pageMet, deterministic: true, at: now - 600),
                             WorkClauseState(text: ads, verdict: "not_met", confidence: 0.8, kind: "intent", evidence: adsWaiting, at: now - 600)]
        }
        // The board.
        let model = ControllerModel(startBackgroundWork: false)
        let board = WorkWorkspaceView(model: model, handoffStore: store, reviewStore: WorkWorkspaceProjection.previewReviewStore(),
                                      state: WorkWorkspaceState(), onOpenSession: { _ in }, onEditTask: { _ in }, onReviewMeeting: { _ in })
        try render(board, width: 1500, height: 900, name: "board-moved-and-partial", out: out)
        // Moved for you.
        try render(WorkMovedForYouView(moves: store.moves, follows: store.follows, shadow: false, lookup: { workID in
            rows.first { $0.workSourceID == workID }.map { ($0.text, $0.workStage) }
        }, onUndo: { _ in }, onOpen: { _ in }), width: 760, name: "moved-for-you", out: out)
        try render(WorkMovedForYouView(moves: store.moves, follows: store.follows, shadow: true, lookup: { workID in
            rows.first { $0.workSourceID == workID }.map { ($0.text, $0.workStage) }
        }, onUndo: { _ in }, onOpen: { _ in }), width: 760, name: "moved-for-you-shadow", out: out)
        // The card detail: Pete's card, 1 of 2 met, following two sessions, with a move COS made and you undid.
        let pete = TaskRow(.object(["id": .string("5755b516df8f"), "domain": .string("quilt"), "title": .string("October switch offer"),
            "text": .string("Launch the October switch offer page and drive traffic to it"),
            "doneWhen": .string(page + "; " + ads), "workStage": .string("built"), "workIdentity": .string("5755b516df8f"),
            "workRevision": .string(String(repeating: "a", count: 64))]))!
        store.follows.add(workID: pete.workSourceID, sessionID: "claude:ff34d7bf-1111-4222-8333-944455556666", origin: .receipt, startedAt: now - 86_400)
        store.follows.add(workID: pete.workSourceID, sessionID: "codex:1a2b3c4d-1111-4222-8333-944455556666", origin: .link, startedAt: now - 7_200)
        store.follows.setCard(pete.workSourceID) { state in
            state.basis = "clauses"; state.checkedAt = now - 600
            state.clauses = [WorkClauseState(text: page, verdict: "met", confidence: 0.93, kind: "fact", evidence: pageMet, deterministic: true, at: now - 600),
                             WorkClauseState(text: ads, verdict: "not_met", confidence: 0.8, kind: "intent", evidence: adsWaiting, at: now - 600)]
        }
        let early = WorkStageMove(by: .cos, why: "the session received it")
        store.recordStageMove(workID: pete.workSourceID, title: pete.text, from: "planned", to: "draft", move: early, at: now - 90_000)
        store.recordStageMove(workID: pete.workSourceID, title: pete.text, from: "draft", to: "built", move: .you, at: now - 80_000)
        try render(WorkFinishLineSection(moves: store.moves, follows: store.follows, task: pete, shadow: true, onUndo: { _ in },
                                         onEditTask: {}, onStopFollowing: {}).padding(22), width: 640, name: "card-detail-checklist", out: out)
        // The same card once every part is met and COS moved it.
        store.follows.setCard(pete.workSourceID) { state in state.clauses?[1] = WorkClauseState(text: ads, verdict: "met", confidence: 0.88, kind: "fact", evidence: adsMet, at: now) }
        let qa = TaskRow(.object(["id": .string("5755b516df8f"), "domain": .string("quilt"), "title": .string("October switch offer"),
            "text": .string(pete.text), "doneWhen": .string(pete.doneWhen), "workStage": .string("qa"), "workIdentity": .string("5755b516df8f"),
            "workRevision": .string(String(repeating: "a", count: 64))]))!
        store.recordStageMove(workID: pete.workSourceID, title: pete.text, from: "built", to: "qa",
                              move: WorkStageMove(by: .cos, why: "every part of the finish line is met", clauses: [pageMet, adsMet]), at: now - 300)
        try render(WorkFinishLineSection(moves: store.moves, follows: store.follows, task: qa, shadow: false, onUndo: { _ in },
                                         onEditTask: {}, onStopFollowing: {}).padding(22), width: 640, name: "card-detail-moved", out: out)
        // The card after it moved, on the board column's width.
        try render(VStack(alignment: .leading, spacing: 10) {
            WorkCardMoveMark(moves: store.moves, follows: store.follows, workID: review.workSourceID)
            WorkCardMoveMark(moves: store.moves, follows: store.follows, workID: draft.workSourceID)
            WorkCardMoveMark(moves: store.moves, follows: store.follows, workID: website.workSourceID)
        }.padding(12), width: 234, name: "card-marks", out: out)
        // Settings: shadow mode and the Work background model.
        try render(WorkEvidenceSettingsRows(model: model).padding(16), width: 390, name: "settings-work-evidence", out: out)
        // The task editor's finish line preview.
        try render(WorkFinishLinePreview(doneWhen: page + "; " + ads).padding(16), width: 560, name: "editor-finish-line-preview", out: out)
        print("wrote PNGs to \(out.path)")
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
