import Foundation
import AppKit
import SwiftUI
import CoreText

@main struct WorkSessionHubChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/tmp/cos-hub-canary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let map = root.appendingPathComponent("hub.session-cards.json")
        let work = "task:quilt:aaaaaaaaaaaa"
        let ids = ["claude:abcdefab-0000-4000-8000-000000000001", "codex:abcdefab-0000-4000-8000-000000000002", "cursor:abcdefab-0000-4000-8000-000000000003"]
        let link = WorkSessionCardLink(workID: work, title: "IT Retail website launch", sourceRevision: "revision", at: 1)
        for id in ids { _ = try WorkSessionLinks.associate(map, sessionID: id, link: link, expected: "none") }
        let firstRead = try WorkSessionLinks.load(map); precondition(firstRead.count == 3)
        _ = try WorkSessionLinks.associate(map, sessionID: "codex:ABCDEFAB-0000-4000-8000-000000000002", link: link, expected: "none")
        let secondRead = try WorkSessionLinks.load(map); precondition(secondRead.count == 3, "Uppercase UUID must not create a second contributor")
        do { _ = try WorkSessionLinks.remove(map, sessionID: ids[0], workID: work, expected: String(repeating: "0", count: 64)); preconditionFailure("Stale removal accepted") } catch {}
        let links = try WorkSessionLinks.remove(map, sessionID: ids[0], workID: work, expected: WorkSessionLinks.revision(link))
        precondition(links.count == 2 && links[ids[1]] != nil && links[ids[2]] != nil)
        _ = try WorkSessionLinks.associate(map, sessionID: ids[0], link: link, expected: "none")
        func receipt(_ n: Int, report: WorkProgressEvent.Kind, status: String = "completed") -> WorkHandoffReceipt {
            var row = WorkHandoffReceipt(id: "receipt-\(n)", workID: work, workTitle: link.title, sourceRevision: "revision",
                mode: .continueSession, provider: String(ids[n].split(separator: ":")[0]), modelID: "existing", sessionID: ids[n],
                sessionTitle: ["Copy review", "Implementation", "Mobile layout"][n], status: status, detail: "Original warning", prompt: "", createdAt: Double(n + 1))
            var progress = WorkProgress(tag: "test"); progress.receivedAt = 1; progress.reported = report; progress.evidence = "Canary evidence"; row.progress = progress
            return row
        }
        let rows = [receipt(0, report: .needsInput), receipt(1, report: .done), receipt(2, report: .working, status: "running")]
        precondition(WorkTracking.forSession(ids[0], receipts: rows, now: 20).first?.phase == .needsInput, "B finishing must not suppress A's question")
        precondition(WorkTracking.forSession(ids[1], receipts: rows, now: 20).first?.phase == .done)
        let contributors = WorkContributorProjection.rows(workID: work, links: try WorkSessionLinks.load(map), receipts: rows, observed: [])
        precondition(contributors.count == 3 && contributors.allSatisfy { $0.session == nil }, "Saved progress must not masquerade as fresh activity")
        for outcome in ["canceled", "refused", "failed", "reviewed"] {
            var success = rows[1]; success.result = "Earlier implementation result"
            var terminal = success; terminal.id = "later-" + outcome; terminal.createdAt = 10
            terminal.status = outcome; terminal.result = nil
            if outcome == "reviewed" { terminal.acknowledgedAt = 11 }
            let projected = WorkContributorProjection.rows(workID: work, links: [:], receipts: [success, terminal], observed: [])
            precondition(projected.count == 1 && projected[0].receipt?.id == terminal.id,
                "Latest terminal outcome must never fall back to an obsolete successful receipt")
            precondition(projected[0].historicalResult == success.result,
                "Earlier successful output must be explicitly classified as history")
            precondition(WorkTracking.latest(workID: work, receipts: [success, terminal], sessionID: ids[1]) == nil)
        }
        let observed = WorkSession(id: ids[2], nativeID: String(ids[2].split(separator: ":")[1]), provider: "cursor",
            title: "Independent mobile work", summary: "Adjusted the launch layout", project: "/tmp/example", status: "working")
        let external = WorkContributorProjection.rows(workID: work, links: [ids[2]: link], receipts: [], observed: [observed])
        precondition(external.first?.session?.summary == observed.summary && external.first?.receipt == nil,
            "External contributor observations cannot create a delivery or completion receipt")
        var parent = rows[0]; parent.mode = .fork; parent.sourceSessionID = parent.sessionID
        precondition(WorkContributorProjection.rows(workID: work, links: [:], receipts: [parent], observed: []).isEmpty)
        parent.sessionID = ids[1]
        precondition(WorkContributorProjection.rows(workID: work, links: [:], receipts: [parent], observed: []).map(\.id) == [ids[1]])
        let other = WorkSessionCardLink(workID: "task:quilt:bbbbbbbbbbbb", title: "Other task", sourceRevision: "revision", at: 2)
        let moved = try WorkSessionLinks.associate(map, sessionID: ids[0], link: other, expected: WorkSessionLinks.revision(link))
        precondition(WorkContributorProjection.rows(workID: work, links: moved, receipts: rows, observed: []).first { $0.id == ids[0] }?.historical == true)

        let store = WorkHandoffStore(storageURL: root.appendingPathComponent("hub.json"), transport: { _, _ in
            preconditionFailure("Hub canary must never dispatch a provider request")
        })
        store.receipts = rows
        try store.reloadSessionCards()
        let epoch = store.sessionCardsEpoch
        for _ in 0..<20 { try store.reloadSessionCards() }
        precondition(store.sessionCardsEpoch == epoch, "Unchanged polling cannot invalidate the board")
        var unknown = rows[0]; unknown.status = "unknown"
        store.setNoticeHidden(unknown, hidden: true)
        precondition(store.noticeHidden(unknown) && unknown.status == "unknown" && unknown.acknowledgedAt == nil)
        unknown.detail = "An unchanged polling explanation"
        precondition(store.noticeHidden(unknown), "Polling copy should not resurface a notice")
        unknown.result = "A new result"
        precondition(!store.noticeHidden(unknown), "Material evidence must resurface")
        unknown.result = nil
        let restarted = WorkHandoffStore(storageURL: root.appendingPathComponent("hub.json"), transport: { _, _ in preconditionFailure("No provider") })
        precondition(restarted.noticeHidden(unknown), "Hide survives restart")
        restarted.setNoticeHidden(unknown, hidden: false)
        precondition(!restarted.noticeHidden(unknown) && unknown.status == "unknown")
        _ = try WorkSessionLinks.remove(map, sessionID: ids[0], workID: other.workID, expected: WorkSessionLinks.revision(other))
        _ = try WorkSessionLinks.remove(map, sessionID: ids[2], workID: work, expected: WorkSessionLinks.revision(link))
        try store.reloadSessionCards()
        var queued = rows[1]; queued.progress?.pendingStage = "qa"; store.receipts = [queued]
        // Add the second contributor during the awaited board reload, after the move was queued.
        let task = TaskRow(.object(["id": .string("aaaaaaaaaaaa"), "workIdentity": .string("aaaaaaaaaaaa"),
            "domain": .string("quilt"), "text": .string("IT Retail launch"), "workStage": .string("draft")]))!
        var moves = 0
        let tracker = WorkProgressTracker(store: store, board: .init(tasks: { [task] }, writable: { true }, reload: {
            _ = store.confirmSessionCard(sessionID: ids[2], source: WorkSource(id: work, title: "IT Retail launch", revision: "revision", project: "quilt", context: ""))
        }, move: { _, _ in moves += 1 }, readFresh: { true }), notify: { _ in }, now: { Date(timeIntervalSince1970: 20) })
        await tracker.tick()
        precondition(moves == 0 && store.receipts.first?.progress?.pendingStage == nil, "A queued single-session move cannot move a shared task")
        try await runWorkActivityChecks()
        try await runWorkBoardCacheChecks()
        try WorkTaskContextChecks.main()
        if CommandLine.arguments.contains("--render") { try renderPreview(root: root) }
        print("PASS hub canaries: three providers, exact identity, independent states, latest terminal outcomes, external observations, fork child, history, CAS unlink, restart, notice truth, unchanged epochs, queued shared-stage guard")
    }
    @MainActor static func renderPreview(root: URL) throws {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
        for name in ["Fraunces", "Fraunces-Italic", "DMSans", "JetBrainsMono"] {
            CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(name + ".ttf") as CFURL, .process, nil)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        setenv("COS_CONTROL_TEST_HOME", root.path, 1)
        setenv("COS_WORK_SESSION_HUB_PREVIEW", "1", 1)
        defer { unsetenv("COS_CONTROL_TEST_HOME"); unsetenv("COS_WORK_SESSION_HUB_PREVIEW") }
        let model = ControllerModel(startBackgroundWork: false, allowActivityLoads: false)
        let store = WorkHandoffStore(isolated: true, storageURL: root.appendingPathComponent("render.json"))
        let reviews = WorkWorkspaceProjection.previewReviewStore()
        let state = WorkWorkspaceState()
        let out = URL(fileURLWithPath: CommandLine.arguments.last!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func view() -> some View {
            WorkWorkspaceView(model: model, handoffStore: store, reviewStore: reviews, state: state,
                onOpenSession: { _ in }, onEditTask: { _ in }, onReviewMeeting: { _ in })
        }
        for (name, detail, width) in [("review", false, 1280), ("contributors", true, 1440), ("compact", false, 820)] {
            state.selectedID = detail ? "task:Website:abcdef123456" : nil
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: view())
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: CGFloat(width), height: 1040),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                host.appearance = NSAppearance(named: appearance); window.appearance = host.appearance
                window.contentView = host
                let until = Date().addingTimeInterval(0.8)
                while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
                host.cacheDisplay(in: host.bounds, to: rep)
                let theme = appearance == .aqua ? "light" : "dark"
                try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + "-" + theme + ".png"))
                window.close()
            }
        }
        print("PASS offscreen native render · no window ordered or provider contacted")
    }

}
