import AppKit
import SwiftUI

/// 0.5.357, run by hand (Tests/run-voice-display-render.sh <folder>): the Speakers surface at the real 390 pt panel width, light and
/// dark, with invented names and words, in the shape of the real call: 7 groups, 4 singles, Ext, 2 names and a fold of 24. The review
/// loads through the real path from a stand-in helper; states past that are set on the model. No window is ordered in and nothing is
/// clicked.
@main @MainActor struct VoiceDisplayRender {
    static let sid = "mac_11111111-1111-4111-8111-111111111111"
    static let revision = String(repeating: "a", count: 64)

    static func words(_ n: Int) -> String {
        let lines = ["Let's move the rollout to the second week.", "I can send the pricing sheet after this.", "Which stores are on the older terminals?",
                     "That was before the warehouse move.", "Can we see it on the demo account?", "I'll check with the team and come back."]
        return lines[n % lines.count]
    }
    static func voice(_ label: String, segments: Int, named: Bool = false) -> [String: Any] {
        ["label": label, "segments": segments, "speakingMs": 0, "nameAsserted": named, "reliability": named ? "confident" : "unattributed",
         "meanSimilarity": named ? 0.86 : NSNull(),
         "phrases": [["text": words(segments), "atMs": segments * 41_000, "chunkIndex": NSNull()]]]
    }
    static func json(_ o: Any) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: o)) }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let fixturesPath = ProcessInfo.processInfo.environment["COS_RENDER_FIXTURES"], let helperPath = ProcessInfo.processInfo.environment["COS_RENDER_HELPER"] else {
            fputs("run Tests/run-voice-display-render.sh\n", stderr); exit(2)
        }
        let fixtures = URL(fileURLWithPath: fixturesPath, isDirectory: true)
        // 7 groups of 30 labels, 4 singles, a fold of 24.
        let sizes = [13, 6, 3, 2, 2, 2, 2]
        var next = 1, groups: [[String: Any]] = []
        for (index, size) in sizes.enumerated() {
            groups.append(["id": "g\(index + 1)", "labels": (next..<(next + size)).map { "Voice \($0)" }, "seconds": 900 - index * 110])
            next += size
        }
        let singles: [[String: Any]] = (next..<(next + 4)).enumerated().map { ["label": "Voice \($1)", "seconds": 88 - $0 * 17] }
        next += 4
        let short: [[String: Any]] = (next..<(next + 24)).enumerated().map { ["label": "Voice \($1)", "seconds": 14.2 - Double($0) * 0.5] }
        var voices: [[String: Any]] = [voice("Ext", segments: 300), voice("Avery Stone", segments: 42, named: true), voice("Blake Moss", segments: 31, named: true)]
        for n in 1...58 { voices.append(voice("Voice \(n)", segments: 60 - n)) }
        let review: [String: Any] = ["sessionId": sid, "title": "Quarterly planning call", "recordId": "ops:quilt:2026-10:fixture.md", "sourceRevision": revision, "reviewIdentityVersion": 1,
            "segments": 783, "attributed": true, "mutable": true, "voices": voices, "durationMs": 3_600_000,
            "timeline": [["speaker": "Avery Stone", "startMs": 0, "endMs": 900_000], ["speaker": "Voice 1", "startMs": 900_000, "endMs": 1_500_000], ["speaker": "Blake Moss", "startMs": 1_500_000, "endMs": 2_400_000], ["speaker": "Ext", "startMs": 2_400_000, "endMs": 3_600_000]],
            "voiceDisplay": ["source": "speaker-shadow", "recordedAt": "2026-10-30T16:09:00Z", "foldUnderSeconds": 15, "groups": groups, "singles": singles, "short": short]]
        func answer(_ name: String, _ details: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["ok": true, "message": "fixture", "details": details]).write(to: fixtures.appendingPathComponent("\(name).json"))
        }
        try answer("meeting-speakers", ["review": review])
        try answer("meeting-content", ["content": ["sessionId": sid, "title": "Quarterly planning call", "scribeAvailable": false, "sourceRevision": revision, "recordId": "ops:quilt:2026-10:fixture.md"]])
        try answer("meeting-speaker-policy", ["mode": "high-confidence", "revision": "fixture", "message": ""])
        try answer("voice-profiles", ["profiles": [["name": "Dana Reyes", "embeddings": 40], ["name": "Avery Stone", "embeddings": 22]]])
        let rule: [String: Any] = ["rule": ["floor": 0.7, "margin": 0.05], "modelSpace": "192d", "sourceRevision": revision]
        try answer("meeting-voice-suggestions", ["job": rule.merging(["state": "idle"]) { _, new in new }])
        try answer("meeting-voice-batch", ["batches": []])

        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: URL(fileURLWithPath: helperPath)))
        model.openSpeakerReview(sessionId: sid)
        for _ in 0..<400 where model.openReview == nil || model.reviewLoading || !model.voiceSuggestions.probed || !model.voiceBatch.probed {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(model.openReview?.voiceDisplayLayout != nil, "the stand-in helper did not load the review: \(model.reviewError ?? "?")")
        precondition(model.voiceSuggestions.probed && model.voiceBatch.probed, "the probes did not land")
        func pane() -> some View { SpeakerReviewPane(model: model, showsBackButton: false) }

        // (a) the list, collapsed.
        try render(pane(), height: 1900, name: "a-rows-and-fold-collapsed", out: out)
        // (b) a merged row expanded, so its words are one click away.
        model.voiceDisplayExpandedRows = ["group:g3"]
        try render(pane(), height: 2100, name: "b-merged-row-expanded", out: out)
        model.voiceDisplayExpandedRows = []
        // (c) the fold expanded.
        model.voiceDisplayShortExpanded = true
        try render(pane(), height: 4300, name: "c-fold-expanded", out: out)
        model.voiceDisplayShortExpanded = false
        // (d) Suggest names running.
        func apply(_ job: [String: Any]) { model.voiceSuggestions = VoiceSuggestionState().applying(["job": json(rule.merging(job) { _, new in new })]) }
        apply(["state": "running", "progress": ["done": 120, "total": 753]])
        try render(pane(), height: 520, name: "d-suggest-running", out: out)
        // (e) suggestions with Use this name: high and middling scores, on merged and single rows.
        func suggestion(_ labels: [String], _ name: String, _ score: Double, high: Bool) -> [String: Any] {
            ["labels": labels, "name": name, "score": score, "margin": 0.12, "units": 12, "kept": 10, "requiresConfirmation": true, "highConfidence": high]
        }
        let done: [[String: Any]] = [
            suggestion((1...9).map { "Voice \($0)" }, "Dana Reyes", 0.91, high: true),
            suggestion((10...11).map { "Voice \($0)" }, "Taylor Brooks", 0.72, high: false),
            suggestion((14...19).map { "Voice \($0)" }, "Jordan Ellis Montgomery-Whitfield", 0.86, high: true),
            suggestion((20...22).map { "Voice \($0)" }, "Casey Lin", 0.74, high: false),
            suggestion(["Voice 31"], "Riley Park", 0.83, high: true),
            suggestion(["Voice 32"], "Morgan Hale", 0.71, high: false)]
        apply(["state": "done", "progress": ["done": 753, "total": 753], "suggestions": done])
        try render(pane(), height: 1100, name: "e-suggestions-use-this-name", out: out)
        // (f) the batch preview, one row unticked.
        let offered = model.voiceBatchCandidates
        precondition(offered.count == 3, "expected three high rows, got \(offered.map(\.title))")
        model.voiceBatch.previewOpen = true
        model.voiceBatch.unticked = [offered[1].id]
        try render(pane(), height: 760, name: "f-batch-preview-one-unticked", out: out)
        model.voiceBatch.previewOpen = false
        model.voiceBatch.unticked = []
        // (g) all named, with Undo.
        func row(_ labels: [String], _ name: String, reason: String? = nil) -> [String: Any] {
            var o: [String: Any] = ["labels": labels, "name": name, "samplesAdded": 6]
            if let reason { o["reason"] = reason }
            return o
        }
        let undoable = json(["x": [["batchId": "b1", "at": "2026-10-30T20:00:00Z", "state": "applied", "named": [], "undoAvailable": true]]]).object!["x"]!
        model.voiceSuggestions = VoiceSuggestionState().applying(["job": json(rule.merging(["state": "idle"]) { _, new in new })])
        model.voiceBatch = model.voiceBatch.applyingList(["batches": undoable])
        model.voiceBatch.result = VoiceBatchResult(json(["batchId": "b1", "state": "applied", "undoAvailable": true, "notNamed": [],
            "named": (1...9).map { row(["Voice \($0)"], "Dana Reyes") }]))
        try render(pane(), height: 520, name: "g-all-named-with-undo", out: out)
        // (h) stopped partway.
        model.voiceBatch.result = VoiceBatchResult(json(["batchId": "b1", "state": "partial", "undoAvailable": true,
            "named": (1...5).map { row(["Voice \($0)"], "Dana Reyes") },
            "notNamed": [row(["Voice 12"], "Riley Park", reason: "That name is already used differently in this recording."),
                         row((14...19).map { "Voice \($0)" }, "Jordan Ellis Montgomery-Whitfield", reason: "recording_active"), row(["Voice 31"], "Morgan Hale", reason: "recording_active")]]))
        try render(pane(), height: 560, name: "h-stopped-partway", out: out)
        // (i) what an undo reports, partial included.
        model.voiceBatch.result = nil
        model.voiceBatch.undoResult = VoiceBatchUndoResult(json(["state": "partial", "reverted": [row(["Voice 1"], "Dana Reyes"), row(["Voice 2"], "Dana Reyes")],
            "left": [row(["Voice 3", "Voice 4"], "Dana Reyes", reason: "label_changed_by_person")], "samplesRemoved": 12]))
        try render(pane(), height: 520, name: "i-undo-partial", out: out)
        model.voiceBatch.undoResult = nil
        // (l) a review opened later: what the Undo would take back, and an interrupted batch said plainly.
        func listed(_ rows: [[String: Any]]) { model.voiceBatch = VoiceBatchState(probed: true).applyingList(["batches": json(["x": rows]).object!["x"]!]) }
        listed([["batchId": "b1", "at": "2026-10-30T20:05:00.000Z", "state": "applied", "undoAvailable": true, "named": [row(["Voice 1"], "Dana Reyes"), row(["Voice 2", "Voice 3"], "Riley Park")]]])
        try render(pane(), height: 520, name: "l-reopened-undo", out: out)
        listed([["batchId": "b1", "at": "2026-10-30T20:05:00.000Z", "state": "interrupted", "undoAvailable": true, "named": [row(["Voice 1"], "Dana Reyes")]]])
        try render(pane(), height: 520, name: "m-reopened-interrupted", out: out)
        model.voiceBatch = VoiceBatchState(probed: true)
        // (j) a merged row's own naming: the chooser, its one Save, and a refusal partway.
        model.namingVoice = "group:g1"
        try render(pane(), height: 640, name: "j-merged-row-naming", out: out)
        model.namingVoice = nil
        let correction = PendingCorrection(from: "Voice 1", to: "Dana Reyes", scope: .thisMeeting, message: "", surfaces: CorrectionSurfaces(json(["sidecar": 4, "transcript": 3])), similarity: nil,
            refused: false, forceable: false, proseStale: false, isNameAssignment: true, createsProfile: false, wouldRetract: 0, untraceable: 0,
            macAssignment: MacVoiceAssignment(json(["person": "Dana Reyes", "enrolled": 3, "attempted": 3, "groupSize": 3, "groupSec": 30, "similarity": 0.8, "gates": []])))
        model.pendingVoiceGroupName = PendingVoiceGroupName(rowId: "group:g1", sessionId: sid, recordId: "r", revision: revision, to: "Dana Reyes", corrections: Array(repeating: correction, count: 13))
        model.voiceGroupNamingOutcome = VoiceGroupNamingOutcome(to: "Dana Reyes", labels: (1...13).map { "Voice \($0)" }, namedCount: 4, stoppedAt: "Voice 5", reason: "That name is already used differently in this recording.")
        try render(pane(), height: 760, name: "k-merged-row-save-and-refusal", out: out)
    }

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    static func render<V: View>(_ view: V, height: CGFloat, name: String, out: URL) throws {
        let width: CGFloat = 390
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top).background(COSPalette.panel))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            settle(host, seconds: 1.5)
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
            window.close()
        }
    }
}
