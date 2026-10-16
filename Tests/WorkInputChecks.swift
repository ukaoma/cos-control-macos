import AppKit
import SwiftUI
import Combine

/// Offscreen production controls; disposable journals, no user events or provider calls.
@MainActor func runWorkInputChecks(root: URL) async throws {
    try runIdleCostChecks(root: root)
    let source = WorkSource(id: "task:quilt:aaaaaaaaaaaa", title: "Input regression", revision: "r1", project: "quilt", context: "Fixture meeting context")
    let journal = root.appendingPathComponent("typing-journal.json")
    let store = WorkHandoffStore(isolated: true, storageURL: journal, transport: { _, _ in
        preconditionFailure("Typing checks cannot dispatch to a provider")
    })
    let draft = WorkHandoffPromptState()
    let host = NSHostingView(rootView: ScrollView { WorkHandoffView.typingFixture(store: store, source: source, draft: draft).padding(20) })
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
    func editors(_ view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        var found: [NSTextView] = []
        for child in view.subviews { found.append(contentsOf: editors(child)) }
        return found
    }
    guard let native = editors(host).first(where: { $0.isEditable && $0.string == draft.text }) else {
        preconditionFailure("The production Context to send native editor must render")
    }
    let before = try? Data(contentsOf: journal)
    var invalidations = 0
    let observed = store.objectWillChange.sink { invalidations += 1 }
    WorkBoardMetrics.handoffBodies = 0
    var samples: [Double] = []
    for _ in 0..<200 {
        let start = Date()
        native.string += "x"
        native.didChangeText()
        // The native delegate must update the draft immediately, before any debounce or redraw.
        precondition(draft.text == native.string)
        pumpWorkInputRunLoop()
        host.layoutSubtreeIfNeeded()
        samples.append(Date().timeIntervalSince(start) * 1000)
    }
    precondition(WorkBoardMetrics.handoffBodies == 0, "Typing cannot rebuild session recommendations, timeline or file manifests")
    precondition(invalidations == 0 && (try? Data(contentsOf: journal)) == before, "Keystrokes cannot publish or write the handoff journal")
    samples.sort(); let p95 = samples[189]
    precondition(p95 < 16, "Context edit and layout p95 must fit a 16ms frame")
    let latest = draft.text
    try await Task.sleep(for: .milliseconds(500))
    precondition(store.draft(for: source).prompt == latest, "Idle save must preserve every character")
    // Pending edits flush on navigation; no last-character loss before the timer.
    native.string += " final edit"; native.didChangeText()
    let flushText = draft.text
    window.contentView = NSView()
    for _ in 0..<15 { try await Task.sleep(for: .milliseconds(10)) }
    precondition(store.draft(for: source).prompt == flushText, "Closing the composer must flush the latest draft")
    observed.cancel(); window.close()
    let reloaded = WorkHandoffStore(isolated: true, storageURL: journal)
    precondition(reloaded.draft(for: source).prompt == flushText, "Restart must restore the exact context")

    let state = WorkWorkspaceState()
    let model = ControllerModel(startBackgroundWork: false)
    model.domainOptions = [DomainOption(.object(["name": .string("quilt")]))!]
    state.captureDraft.domain = "quilt"
    var boardSignals = 0
    let boardObserved = state.objectWillChange.sink { boardSignals += 1 }
    let captureHost = NSHostingView(rootView: WorkTaskCaptureForm(model: model, draft: state.captureDraft, isolated: true, close: {}, openWaiting: {}))
    captureHost.setFrameSize(NSSize(width: 900, height: 140))
    for _ in 0..<1000 { state.captureDraft.text += "x" }
    precondition(boardSignals == 0 && state.captureDraft.text.count == 1000, "Add task typing cannot invalidate board navigation")
    boardObserved.cancel()
    print(String(format: "PASS Work inputs: 200 native Context edits + layout, p95 %.3fms, 0 workspace redraws, 0 burst journal writes; idle/close/restart exact; 1000 capture edits, 0 board signals", p95))
}

@MainActor private func pumpWorkInputRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}

/// 0.5.313 (idle CPU, 2026-10-15): an idle Work tab spent a third of the main thread rebuilding session recommendations,
/// re-reading session dates inside a sort, and re-parsing intake dates. Same answers, computed once.
@MainActor private func runIdleCostChecks(root: URL) throws {
    func session(_ id: String, title: String = "", project: String = "other", updated: String? = nil) -> WorkSession {
        WorkSession(id: id, nativeID: id, provider: "claude", title: title, summary: "", project: project, status: "idle", updatedAt: updated)
    }
    precondition(WorkHandoffStore.ranked([(session("b"), 3), (session("a"), 3), (session("c"), 0), (session("d"), 100)]).map(\.id) == ["d", "a", "b"],
                 "Highest score first, ties by id, zero is not a recommendation")
    precondition(WorkHandoffStore.ranked((0..<8).map { (session("x\($0)"), 1) }).count == 5, "At most five")
    let old = session("old", updated: "2026-10-01T00:00:00Z"), new = session("new", updated: "2026-10-15T00:00:00.500Z"), undated = session("none")
    precondition(WorkHandoffStore.shortlist(advised: nil, matches: [], sessions: [old, undated, new]).map(\.id) == ["new", "old", "none"],
                 "The shortlist still fills newest first, undated last")
    precondition(WorkHandoffStore.shortlist(advised: "old", matches: [undated], sessions: [old, undated, new]).map(\.id) == ["old", "none", "new"])
    let store = WorkHandoffStore(isolated: true, storageURL: root.appendingPathComponent("recommendations.json"), transport: { _, _ in
        preconditionFailure("Recommendation checks cannot dispatch")
    })
    let source = WorkSource(id: "task:quilt:bbbbbbbbbbbb", title: "Launch pricing page", revision: "r1", project: "quilt", context: "Pricing launch checklist audit")
    store.sessions = [session("claude:words", title: "Pricing launch checklist")]
    precondition(store.recommendations(for: source).map(\.id) == ["claude:words"] && store.recommendations(for: source).map(\.id) == ["claude:words"])
    store.sessions.append(session("claude:project", project: "quilt"))
    precondition(store.recommendations(for: source).map(\.id) == ["claude:project", "claude:words"], "A changed session list is never answered from the cache")
    store.sessions[0].title = "Unrelated notes"
    precondition(store.recommendations(for: source).map(\.id) == ["claude:project"], "An edited session is scored again")
    let other = WorkSource(id: "task:quilt:cccccccccccc", title: "Pricing launch checklist", revision: "r1", project: "", context: "")
    precondition(store.recommendations(for: other).isEmpty, "Another card is never answered from this card's cache")
    precondition(WorkIntakeItem.stamp("2026-10-15T22:30:00.250Z") != nil && WorkIntakeItem.stamp("2026-10-15T22:30:00Z") != nil && WorkIntakeItem.stamp("yesterday") == nil,
                 "Intake dates read with or without fractions, once, at decode")
    precondition(DictationSoundPlayer.stopsAfter(finished: 3, newest: 3) && !DictationSoundPlayer.stopsAfter(finished: 2, newest: 3),
                 "Only the newest sound's end stops the output engine")
    print("PASS idle cost: recommendations scored once and cached by card and epochs, shortlist dates read once, intake dates parsed at decode, sound engine stops after its sound")
}
