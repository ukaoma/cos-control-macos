import AppKit
import SwiftUI
import Vision

/// 0.5.327: the cue review and the Cues view as drawn, by hand (Tests/run-cue-verdicts.sh render <dir>). The whole app is
/// compiled; a stand-in helper written beside the binary answers `live-cues-history` and `live-cues-rate` from files this
/// harness rewrites, so nothing reaches the real helper or a server, and all text is invented.
///
///   - Memories → Cues to rate at 980 x 680, light and dark: the rail with its count and the week's line, the card with its
///     meeting, time, kind, score, cue, sources, what was said just before, the five keyed verdicts, the note and Skip,
///     and Next up; then Rated cues, and the older server's one line;
///   - the panel beside a meeting at 400 x 720: the switch with Live COS Ask and Cues N, the used line, a rated card and
///     unrated cards with their verdicts; and on an older server the Ask panel alone, with no switch.
///
/// Vision reads the words that must show whole on the pixels. No window is ordered in, no event is sent, nothing becomes
/// active. Prints "cue verdicts render: N passed".
@main @MainActor struct CueVerdictsRender {
    static var passed = 0
    static func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        guard condition else { print("cue verdicts render FAILED: \(what) \(detail())"); exit(1) }
        passed += 1
    }

    static let session = "meeting_1792400000000_abc123"
    static func row(_ id: String, minutes: Double, detail: String, verdict: String = "null", before: String = "") -> String {
        let at = 1_792_400_000_000.0 + minutes * 60_000
        return #"{"cueId":"\#(id)","sessionId":"\#(session)","meetingTitle":"Northwind weekly","createdAt":\#(at),"kind":"challenge","headline":"\#(detail.prefix(40))","detail":"\#(detail)","gate":0.94,"sources":[],"model":"claude-sonnet-5-5","before":"\#(before)","verdict":\#(verdict)}"#
    }
    static func history(_ rows: [String], total: Int, rated: Int) -> String {
        #"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":200,"v":1,"cues":[\#(rows.joined(separator: ","))],"counts":{"total":\#(total),"rated":\#(rated),"unrated":\#(total - rated),"byVerdict":{"useful":\#(rated)}}}}"#
    }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stand = FileManager.default.temporaryDirectory.appendingPathComponent("cos-cue-verdicts-stand-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stand, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stand) }
        let helper = stand.appendingPathComponent("helper")
        try """
        #!/bin/sh
        D="$(cd "$(dirname "$0")" && pwd)"
        f="$D/$1.json"
        if [ -f "$f" ]; then cat "$f"; printf '\\n'; exit 0; fi
        printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\\n' "$1"
        exit 1

        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        func answer(_ verb: String, _ text: String) { try? text.write(to: stand.appendingPathComponent(verb + ".json"), atomically: true, encoding: .utf8) }

        let unrated = [
            row("cue-0001-aaaa", minutes: 7, detail: "Anand agreed to move the oldest 100 rows into a legacy table instead of deleting. Settle the date and what the archive keeps.",
                before: "Ext: How does a separate table work? MU: we just move the oldest hundred into an old table."),
            row("cue-0002-bbbb", minutes: 8, detail: "The pages went to the design team with no deadline. Name who owns the date."),
        ]
        let rated = [row("cue-0003-cccc", minutes: 9, detail: "Nobody knows the status of the layout feedback. Name who chases it, and by when.",
                         verdict: #"{"verdict":"repeat","note":"same ask as 7:49"}"#)]
        answer("live-cues-history", history(unrated + rated, total: 31, rated: 3))
        answer("live-cues-rate", #"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":200,"ok":true,"verdict":"useful"}}"#)

        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        let store = model.meetingAsk.cueVerdicts
        let run = CueReviewPane.run(model)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = appearance == .darkAqua ? "dark" : "light"
            model.openCueReview(.toRate)
            await store.loadWeek(run)
            expect(store.queue.first?.id == "cue-0001-aaaa", "the queue's first cue is the oldest unrated")
            try draw(CueReviewPane(model: model, store: store, openMemories: { _ in }), size: CGSize(width: 980, height: 680), appearance: appearance,
                     name: "memories-cues-to-rate-\(theme)", out: out,
                     words: ["Cues to rate", "Rated cues", "To review", "Recent learning", "Ratings this week: 3 of 31.", "Northwind weekly", "7 min in",
                             "Challenge", "score 0.94", "Settle the date and what the archive keeps", "Sources: none, from the room only",
                             "What was said just before", "1 Useful", "2 Late", "3 Repeat", "4 Wrong", "5 Obvious", "Note (optional)", "Skip",
                             "Next up", CueVerdicts.keysLine])
            model.openCueReview(.rated)
            await store.loadRated(run)
            try draw(CueReviewPane(model: model, store: store, openMemories: { _ in }), size: CGSize(width: 980, height: 680), appearance: appearance,
                     name: "memories-rated-cues-\(theme)", out: out,
                     words: ["Rated cues", "Nobody knows the status of the layout feedback", "Rated Repeat", "same ask as 7:49", "Clear"])
            // Beside a meeting.
            await store.loadMeeting(session, days: CueVerdicts.liveDays, force: true, run: run)
            try draw(sidePanel(model, shown: true), size: CGSize(width: 400, height: 720), appearance: appearance, name: "meeting-cues-\(theme)", out: out,
                     words: ["Live COS Ask", "Cues 3", "3 of 25 used", "Rated Repeat", "Change", "Useful", "Obvious", "Not rated"])
        }
        // An older server: the review says so in one line; beside the meeting there is no switch, only Ask.
        answer("live-cues-history", #"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":404}}"#)
        model.openCueReview(.toRate)
        await store.loadWeek(run)
        expect(store.available == false, "a 404 hides the surfaces")
        try draw(CueReviewPane(model: model, store: store, openMemories: { _ in }), size: CGSize(width: 980, height: 400), appearance: .aqua,
                 name: "memories-older-server-light", out: out, words: ["Rating cues needs server 6.79.0. Update the server in Settings."])
        let older = try draw(sidePanel(model, shown: false), size: CGSize(width: 400, height: 300), appearance: .aqua, name: "meeting-older-server-light", out: out,
                             words: ["Ask stand-in"])
        expect(!flat(older).contains(flat("Cues")), "no Cues view on an older server", older)
        print("cue verdicts render: \(passed) passed")
        exit(0)
    }

    /// The panel with a stand-in for the Ask panel (its own render lives in Tests/LiveTranscriptRender.swift).
    static func sidePanel(_ model: ControllerModel, shown: Bool) -> some View {
        MeetingSidePanel(store: model.meetingAsk.cueVerdicts, model: model, session: session, live: true, showsCues: shown) {
            Text("Ask stand-in").font(COSType.body(13)).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @discardableResult
    static func draw(_ view: some View, size: CGSize, appearance: NSAppearance.Name, name: String, out: URL, words: [String]) throws -> String {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(COSPalette.panel).cosControlTheme())
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer { window.close() }
        settle(host, 1.0)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
        let read = ocr(rep)
        for text in words { expect(flat(read).contains(flat(text)), "\(name): reads whole on the pixels: \(text)", "read: \(read)") }
        print("\(name): \(Int(size.width)) x \(Int(size.height)) pt")
        return read
    }

    static func settle(_ host: NSView, _ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
    }

    static func ocr(_ rep: NSBitmapImageRep) -> String {
        guard let image = rep.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    static func flat(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
