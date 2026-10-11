import AppKit
import SwiftUI
import Vision

/// 0.5.278: the live meeting transcript with the whole app compiled, against a stand-in helper (Tests/run-live-transcript.sh).
///
///   check <fake helper>          the model executed: the setting off spawns nothing; on, one read at a time, the data
///                                directory and the cursor passed back; Wake reads at once; nobody looking stops the
///                                poll; a failure keeps a reason code and never text; the saved hand-off finds the
///                                saved row by session id (a merged one by g2SessionIds), never by filename; Recording
///                                ended without saving; the 3-minute deadline; Copy from what Control holds.
///   render <dir> <fake helper>   PNGs, light and dark: the Meetings Live now row, the pane live (short), at 1,500 chunks,
///                                No audio for 4m, Finalizing, the saved hand-off, and the panel's Meetings chip dot.
///
/// The stand-in answers from files the check writes beside it; nothing reaches the real helper, the server or the
/// active-sessions folder. All text is invented. No window is ordered in, no event is sent, nothing becomes active,
/// and nothing is copied to the clipboard (the copy text is read from the model).
/// 0.5.281: a drop's information with only a pasteboard, so a check can hand the composer's own drop methods a payload
/// without a pointer, an event, a window ordered in, or the clipboard. Its pasteboard is a private named one.
@MainActor final class FixtureDrag: NSObject, NSDraggingInfo {
    static func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("cos-fixture-drag-" + UUID().uuidString))
        board.clearContents()
        return board
    }
    let board: NSPasteboard
    init(_ board: NSPasteboard) { self.board = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@main @MainActor struct LiveTranscriptRender {
    static let sid = "meeting_1791635349988_fx67ab"

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "check":
            guard args.count > 1 else { fatalError("usage: check <fake helper>") }
            await checkModel(Stand(URL(fileURLWithPath: args[1])))
        case "ask-canary":
            guard args.count > 2 else { fatalError("usage: ask-canary <dir> <fake helper>") }
            let out = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try await askShellCanary(out, stand: Stand(URL(fileURLWithPath: args[2])))
        case "render":
            guard args.count > 2 else { fatalError("usage: render <dir> <fake helper>") }
            let out = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try await renderAll(out, stand: Stand(URL(fileURLWithPath: args[2])))
        default: fatalError("usage: check <fake helper> | render <dir> <fake helper>")
        }
    }

    static func fail(_ behaviour: String, _ detail: String) -> Never {
        print("check failed [\(behaviour)]: \(detail)")
        exit(1)
    }

    static var passed = 0
    static func expect(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
        guard condition else { fail(behaviour, detail()) }
        passed += 1
    }

    /// The stand-in's folder: each verb answers `<verb>.json` (live-transcript answers by `live-mode`), and logs
    /// itself to calls.log and its arguments to args.log.
    struct Stand {
        let helper: URL
        var dir: URL { helper.deletingLastPathComponent() }
        init(_ helper: URL) { self.helper = helper }
        func write(_ name: String, _ text: String) { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func remove(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func calls(_ verb: String) -> Int { lines("calls.log").filter { $0 == verb }.count }
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func lastArgs(_ verb: String) -> [String] {
            (lines("args.log").last { $0.hasPrefix(verb + " ") || $0 == verb } ?? "").split(separator: " ").map(String.init)
        }
    }

    static func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    static func until(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async {
        let started = Date()
        while !condition() {
            if Date().timeIntervalSince(started) > timeout { fail("no hang", "waited \(timeout) s for \(what)") }
            await sleep(0.02)
        }
    }

    // MARK: fixtures (invented text)

    static let lines = [
        ("Miles", "Fixture opening line about the launch plan."),
        ("Miles", "Fixture follow up with a second thought."),
        ("Jordan", "Fixture reply about the timeline and budget."),
        ("Zoë Ångström", "Fixture note on the café partner and naïve pricing."),
        ("Unknown", "Fixture line from a voice nobody named yet."),
        ("Miles", "Fixture close for this part of the meeting."),
    ]

    static func chunkJSON(_ i: Int, _ speaker: String, _ text: String, ms: Int) -> String {
        "{\"i\":\(i),\"elapsedMs\":\(ms),\"speaker\":\"\(speaker)\",\"text\":\"\(text)\"}"
    }

    static func liveAnswer(sessionId: String = sid, chunks: [(Int, String, String, Int)], settled: Int, stamp: String,
                           start: Double = 1_791_635_349_988, last: Double? = nil, dataDir: String = "/tmp/cos-live-fixture-data") -> String {
        let turns = chunks.map { chunkJSON($0.0, $0.1, $0.2, ms: $0.3) }.joined(separator: ",")
        let lastText = last.map { String(format: "%.0f", $0) } ?? "null"
        return """
        {"ok":true,"message":"Live transcript","details":{"dataDir":"\(dataDir)","sessions":[{"sessionId":"\(sessionId)","mtimeMs":\(String(format: "%.0f", last ?? Date().timeIntervalSince1970 * 1000)),"size":4096,"stamp":"\(stamp)"}],
        "read":{"sessionId":"\(sessionId)","ended":false,"unchanged":false,"stamp":"\(stamp)","startTime":\(String(format: "%.0f", start)),"lastActivityAt":\(lastText),
        "maxIndex":\(chunks.map(\.0).max() ?? -1),"settledThrough":\(settled),"chunkCount":\(chunks.count),"turns":[\(turns)]}}}
        """
    }

    static let endedAnswer = #"{"ok":true,"message":"Live transcript","details":{"dataDir":"/tmp/cos-live-fixture-data","sessions":[],"read":{"sessionId":"meeting_1791635349988_fx67ab","ended":true,"unchanged":false}}}"#

    static func libraryRow(recordId: String, sessionId: String, filename: String, g2: [String] = [], title: String) -> String {
        let g2JSON = g2.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"recordId":"\(recordId)","sessionId":"\(sessionId)","title":"\(title)","date":"2026-10-10","time":"07:29","domain":"personal","domainAbbr":"P",
         "duration":"8 min","durationMinutes":8,"month":"2026-10","filename":"\(filename)","source":"g2","g2SessionIds":[\(g2JSON)]}
        """
    }

    static func liveStatus(_ live: Int, active: Int? = nil, stale: [String] = []) -> ServerStatus {
        ServerStatus([
            "installed": .bool(true), "running": .bool(true), "runtimeState": .string("managedHealthy"),
            "activeTranscriptionSessions": .number(Double(active ?? live)), "liveTranscriptionSessions": .number(Double(live)),
            "staleTranscriptionSessionIds": .array(stale.map { .string($0) }),
        ])
    }

    static func model(_ stand: Stand, enabled: Bool, helper: URL? = nil) -> (ControllerModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: "live-transcript-render-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: LiveTranscript.enabledKey)
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper ?? stand.helper))
        model.liveTranscriptDefaults = defaults
        model.status = liveStatus(1)
        return (model, defaults)
    }

    // MARK: check

    static func checkModel(_ stand: Stand) async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 150) {
            print("check failed [no hang]: the live transcript checks did not finish within 150 s")
            exit(1)
        }
        let firstChunks = lines.enumerated().map { ($0.offset, $0.element.0, $0.element.1, $0.offset * 6000) }
        stand.write("live-transcript.json", liveAnswer(chunks: firstChunks, settled: 5, stamp: "100.1.4096"))
        stand.write("live-mode", "normal")

        // ── The setting off: nothing anywhere spawns the helper.
        let (off, offDefaults) = model(stand, enabled: false)
        off.liveTranscriptViewer("meetings", visible: true)
        off.liveTranscriptKick()
        off.liveTranscriptWoke()
        off.openLiveTranscript(sid)
        await off.pollLiveTranscriptOnce()
        await off.checkLiveTranscriptHandoffs(now: Date())
        off.refreshLiveTranscriptHandoff(sid)
        // A session still finalizing from before the setting went off asks the server nothing either.
        var leftover = LiveTranscriptFeed(sessionId: "meeting_left_over_one")
        leftover.markEnded(now: Date())
        off.liveTranscriptFeeds[leftover.sessionId] = leftover
        await off.checkLiveTranscriptHandoffs(now: Date())
        off.refreshLiveTranscriptHandoff(leftover.sessionId)
        await sleep(2.0)
        expect(stand.calls("live-transcript") == 0 && stand.calls("live-transcript-status") == 0, "setting off spawns nothing",
               "calls: \(stand.lines("calls.log"))")
        expect(!off.liveTranscriptPollRunning && off.liveTranscriptRows.isEmpty && !off.liveTranscriptDot && off.liveTranscriptOpenID == nil
               && off.liveTranscriptFeeds[leftover.sessionId]?.lastStatusCheck == nil,
               "setting off shows nothing", "rows \(off.liveTranscriptRows.count) dot \(off.liveTranscriptDot)")
        _ = offDefaults

        // ── On: the poll runs, one read at a time, and hands back the data directory and the cursor.
        let (on, onDefaults) = model(stand, enabled: true)
        on.liveTranscriptViewer("meetings", visible: true)
        await until("the first read") { on.liveTranscriptFeeds[sid]?.turns.isEmpty == false }
        expect(on.liveTranscriptPollRunning, "the poll runs while Meetings is visible and a meeting is live")
        expect(on.liveTranscriptRows.map(\.id) == ["live:" + sid] && on.liveTranscriptRows.first?.phase == .live, "the Live now row")
        expect(on.liveTranscriptDot, "the live dot")
        expect(on.liveTranscriptFeeds[sid]?.turns.map(\.speaker) == ["Miles", "Jordan", "Zoë Ångström", "Speaker", "Miles"],
               "turns merge by speaker; Unknown reads Speaker", "\(on.liveTranscriptFeeds[sid]?.turns.map(\.speaker) ?? [])")
        // The first poll knows no file yet and only lists; the next one reads the listed session.
        await until("a read that names the session") {
            stand.lines("args.log").contains { $0.hasPrefix("live-transcript ") && $0.contains("--session \(sid)") }
        }
        await until("a second read") { stand.calls("live-transcript") >= 3 }
        let secondArgs = stand.lastArgs("live-transcript")
        expect(secondArgs.contains("--session") && secondArgs.contains(sid), "the read names the session", "\(secondArgs)")
        expect(secondArgs.contains("--data-dir") && secondArgs.contains("/tmp/cos-live-fixture-data"), "the data directory is looked up once per loop",
               "\(secondArgs)")
        if let i = secondArgs.firstIndex(of: "--since") { expect(secondArgs[i + 1] == "5", "the cursor is passed back", "\(secondArgs)") }
        else { fail("the cursor is passed back", "\(secondArgs)") }
        if let i = secondArgs.firstIndex(of: "--stamp") { expect(secondArgs[i + 1] == "100.1.4096", "the stamp is passed back", "\(secondArgs)") }
        else { fail("the stamp is passed back", "\(secondArgs)") }

        // ── A session that leaves the list ends, even on a poll that read another one.
        let (two, _) = model(stand, enabled: true)
        func listed(_ ids: [String]) -> String {
            ids.map { "{\"sessionId\":\"\($0)\",\"mtimeMs\":1,\"size\":1,\"stamp\":\"\($0)\"}" }.joined(separator: ",")
        }
        two.applyLiveTranscript(reply("{\"ok\":true,\"message\":\"x\",\"details\":{\"sessions\":[\(listed(["meeting_aaa", "meeting_bbb"]))],\"read\":{\"sessionId\":\"meeting_aaa\",\"ended\":false,\"unchanged\":true}}}"), now: Date())
        two.applyLiveTranscript(reply("{\"ok\":true,\"message\":\"x\",\"details\":{\"sessions\":[\(listed(["meeting_aaa"]))],\"read\":{\"sessionId\":\"meeting_aaa\",\"ended\":false,\"unchanged\":true}}}"), now: Date())
        expect(two.liveTranscriptFeeds["meeting_bbb"]?.ended == true && two.liveTranscriptFeeds["meeting_bbb"]?.phase == .finalizing
               && two.liveTranscriptFeeds["meeting_aaa"]?.ended == false, "a file that left the list ends")

        // ── Never a second read while one is in flight, whatever asks.
        stand.remove("overlap.log")
        stand.write("live-mode", "hold")
        await until("a held read") { stand.exists("inflight") }
        for _ in 0..<8 {
            on.liveTranscriptKick(); on.liveTranscriptWoke(); on.liveTranscriptViewer("live-pane", visible: true)
            await sleep(0.2)
        }
        stand.write("live-mode", "normal")
        stand.write("release", "")
        await until("the held read to finish") { !stand.exists("inflight") }
        expect(!stand.exists("overlap.log"), "one read at a time", "overlap: \(stand.lines("overlap.log"))")
        on.liveTranscriptViewer("live-pane", visible: false)

        // ── Wake reads at once (the tick is 1.5 s; three in a row under 0.7 s).
        for trial in 0..<3 {
            let before = stand.calls("live-transcript")
            await until("a read to land") { stand.calls("live-transcript") > before }
            await sleep(0.1)
            let after = stand.calls("live-transcript")
            let woke = Date()
            on.liveTranscriptWoke()
            await until("the wake read") { stand.calls("live-transcript") > after }
            expect(Date().timeIntervalSince(woke) < 0.7, "didWake reads at once", "trial \(trial): \(Date().timeIntervalSince(woke)) s")
        }

        // ── A failure is a reason code, never text.
        stand.write("live-mode", "secret")
        await until("the bad answer") { on.liveTranscriptReason != nil }
        expect(on.liveTranscriptReason == "invalid_response", "an invalid answer is a code", on.liveTranscriptReason ?? "nil")
        stand.write("live-mode", "refuse")
        await until("the refusal") { on.liveTranscriptReason == "parse_failed" }
        for text in [on.liveTranscriptReason ?? "", on.error ?? "", on.notice ?? ""] {
            expect(!text.contains("SECRET"), "no text in the error fields", text)
        }
        expect(on.error == nil, "a failed poll never raises the alert")
        stand.write("live-mode", "normal")
        await until("recovery") { on.liveTranscriptReason == nil }

        // ── The hand-off. The file goes; the server says nothing useful yet: Finalizing, and Copy still works.
        on.openLiveTranscript(sid)
        expect(on.liveTranscriptRouteActive && on.liveTranscriptOpenID == sid, "the pane opens on its own route")
        stand.write("live-transcript-status.json", #"{"ok":true,"message":"x","details":{"sessionId":"meeting_1791635349988_fx67ab","state":"unknown","reason":"route_absent"}}"#)
        stand.write("meetings-library.json", #"{"ok":true,"message":"x","details":{"meetings":[]}}"#)
        stand.write("live-mode", "ended")
        await until("finalizing") { on.liveTranscriptFeeds[sid]?.phase == .finalizing }
        expect(on.liveTranscriptRows.first?.phase == .finalizing, "the row says Finalizing")
        let copy = on.liveTranscriptCopyText ?? ""
        expect(copy.hasPrefix("COS preliminary transcript · 2026-10-10 ") && copy.contains("] Speaker: Fixture line from a voice nobody named yet.")
               && copy.split(separator: "\n").count == 6, "Copy works from what Control holds after the file is gone", copy)
        expect(on.liveTranscriptPollRunning, "a hand-off still waiting keeps the poll going")
        // The server says saved. A decoy row has the receipt's filename and another session: never matched. The merged
        // row holds this session in g2SessionIds: matched.
        stand.write("live-transcript-status.json", #"{"ok":true,"message":"x","details":{"sessionId":"meeting_1791635349988_fx67ab","state":"saved","savedFilename":"2026-10-10_G2_Recording_x.md"}}"#)
        stand.write("meetings-library.json", "{\"ok\":true,\"message\":\"x\",\"details\":{\"meetings\":[" +
                    libraryRow(recordId: "decoy", sessionId: "meeting_other_session", filename: "2026-10-10_G2_Recording_x.md", title: "Decoy") + "," +
                    libraryRow(recordId: "merged", sessionId: "meeting_first_capture", filename: "2026-10-10_Live_System_Test.md",
                               g2: ["meeting_first_capture", sid], title: "Saved test meeting") + "]}}")
        await until("the saved row") { on.liveTranscriptHandoff != nil }
        expect(on.liveTranscriptHandoff?.recordId == "merged", "the saved row is found by session id (here through g2SessionIds), never by filename",
               on.liveTranscriptHandoff?.recordId ?? "nil")
        expect(stand.lines("args.log").contains { $0.hasPrefix("meetings-library --day 2026-10-10") },
               "the saved row is read by day, whatever month Meetings shows")
        // What Activity's onChange applies (it only copies these fields into its selection; a pin holds that).
        let selection = on.acceptLiveTranscriptHandoff()
        expect(selection == ControllerModel.LiveTranscriptHandoffSelection(recordID: "merged"), "the hand-off selects the saved meeting in place",
               "\(String(describing: selection))")
        expect(selection?.returnWorkID == nil && selection?.returnToWork == false && selection?.returnSpeakerSessionID == nil
               && selection?.workLoaded == false, "the hand-off clears the way back to Work and Speakers")
        expect(!on.liveTranscriptRouteActive && on.openLibraryRow?.recordId == "merged" && on.liveTranscriptFeeds[sid] == nil,
               "the saved meeting opens in place of the live one")
        expect(on.liveTranscriptHandoff == nil && on.acceptLiveTranscriptHandoff() == nil, "a hand-off is taken once")

        // ── Recording ended without saving, and the 3-minute deadline (clocks set back rather than waited out).
        stand.write("live-transcript-status.json", #"{"ok":true,"message":"x","details":{"sessionId":"meeting_other_live_one","state":"closed"}}"#)
        var closed = LiveTranscriptFeed(sessionId: "meeting_other_live_one")
        closed.apply(LiveTranscriptRead(sessionId: "meeting_other_live_one", ended: false, unchanged: false, stamp: "1", startTime: 1_791_635_349_988,
                                        turns: [LiveTranscriptChunk(i: 0, elapsedMs: 0, speaker: "Miles", text: "Fixture.")]), now: Date())
        closed.markEnded(now: Date().addingTimeInterval(-30))
        on.liveTranscriptFeeds[closed.sessionId] = closed
        await on.checkLiveTranscriptHandoffs(now: Date())
        expect(on.liveTranscriptFeeds[closed.sessionId]?.phase == .endedUnsaved, "closed by the server: Recording ended without saving",
               "\(String(describing: on.liveTranscriptFeeds[closed.sessionId]?.phase))")
        stand.write("live-transcript-status.json", #"{"ok":true,"message":"x","details":{"sessionId":"meeting_slow_save_one","state":"saved"}}"#)
        stand.write("meetings-library.json", #"{"ok":true,"message":"x","details":{"meetings":[]}}"#)
        var slow = LiveTranscriptFeed(sessionId: "meeting_slow_save_one")
        slow.markEnded(now: Date().addingTimeInterval(-200))
        on.liveTranscriptFeeds[slow.sessionId] = slow
        await on.checkLiveTranscriptHandoffs(now: Date())
        expect(on.liveTranscriptFeeds[slow.sessionId]?.phase == .notFoundYet, "saved but no row after 3 minutes: Saved meeting not found yet")
        stand.write("meetings-library.json", "{\"ok\":true,\"message\":\"x\",\"details\":{\"meetings\":[" +
                    libraryRow(recordId: "slow", sessionId: "meeting_slow_save_one", filename: "slow.md", title: "Slow") + "]}}")
        let statusBefore = stand.calls("live-transcript-status")
        on.refreshLiveTranscriptHandoff(slow.sessionId)
        await until("Refresh to find the row") { on.liveTranscriptFeeds[slow.sessionId] == nil }
        expect(stand.calls("live-transcript-status") > statusBefore, "Refresh asks the server again, and the found row ends the hand-off")

        // ── Nobody looking: the poll stops and spawns nothing more.
        on.closeLiveTranscript()
        on.liveTranscriptViewer("meetings", visible: false)
        await until("the poll to stop") { !on.liveTranscriptPollRunning }
        let quiet = stand.calls("live-transcript")
        await sleep(2.0)
        expect(stand.calls("live-transcript") == quiet, "nobody looking spawns nothing")

        // ── No live meeting on the server: no poll even with Meetings open.
        stand.write("live-mode", "normal")
        on.status = liveStatus(0)
        on.liveTranscriptFeeds = [:]
        on.liveTranscriptViewer("meetings", visible: true)
        await sleep(1.0)
        expect(!on.liveTranscriptPollRunning && stand.calls("live-transcript") == quiet, "no live meeting: no poll")

        // ── QA B1: the status tick reports 0 (the server dropped the saved session) before any poll sees the file gone.
        // The poll must follow the live session to its end, not stop with the pane on "Live meeting".
        func quiesce(_ m: ControllerModel) async {
            m.closeLiveTranscript()
            m.liveTranscriptViewer("meetings", visible: false)
            m.liveTranscriptViewer("live-pane", visible: false)
            await until("a quiet model") { !m.liveTranscriptPollRunning }
        }
        let savedRow = "{\"ok\":true,\"message\":\"x\",\"details\":{\"meetings\":[" +
            libraryRow(recordId: "b1row", sessionId: sid, filename: "2026-10-10_Retitled.md", title: "Retitled") + "]}}"
        stand.write("live-mode", "normal")
        let (early, _) = model(stand, enabled: true)
        early.liveTranscriptViewer("meetings", visible: true)
        early.openLiveTranscript(sid)
        await until("the live read") { early.liveTranscriptFeeds[sid]?.turns.isEmpty == false && early.liveTranscriptFeeds[sid]?.seenLive == true }
        early.status = liveStatus(0)
        early.liveTranscriptKick()
        await sleep(2.0)
        expect(early.liveTranscriptPollRunning && early.liveTranscriptPendingHandoff,
               "the poll follows a live session after the server's count drops first (B1)")
        stand.write("live-transcript-status.json", #"{"ok":true,"message":"x","details":{"sessionId":"meeting_1791635349988_fx67ab","state":"saved"}}"#)
        stand.write("meetings-library.json", savedRow)
        stand.write("live-mode", "ended")
        await until("the hand-off after the count dropped") { early.liveTranscriptHandoff != nil }
        expect(early.acceptLiveTranscriptHandoff()?.recordID == "b1row", "the pane hands off although the count dropped first (B1)")
        await until("the poll to stop once nothing is held") { !early.liveTranscriptPollRunning }
        await quiesce(early)

        // B1, the other way: Meetings left mid-meeting, the meeting saved while nobody looked, then the pane reopened.
        stand.write("live-mode", "normal")
        let (left, _) = model(stand, enabled: true)
        left.liveTranscriptViewer("meetings", visible: true)
        await until("the live read") { left.liveTranscriptFeeds[sid]?.seenLive == true && left.liveTranscriptFeeds[sid]?.turns.isEmpty == false }
        await quiesce(left)
        stand.write("live-mode", "ended")
        left.status = liveStatus(0)
        let whileAway = stand.calls("live-transcript")
        await sleep(1.6)
        expect(stand.calls("live-transcript") == whileAway, "nobody looking spawns nothing, even with a session held")
        left.openLiveTranscript(sid)
        left.liveTranscriptViewer("meetings", visible: true)
        await until("the hand-off on reopening") { left.liveTranscriptHandoff != nil }
        expect(left.acceptLiveTranscriptHandoff()?.recordID == "b1row", "reopening after the save hands off to the saved meeting (B1)")
        await quiesce(left)

        // ── QA N4: polling only while the Activity window is on screen; back on screen reads at once.
        stand.write("live-mode", "normal")
        let (shown, _) = model(stand, enabled: true)
        shown.liveTranscriptViewer("meetings", visible: true)
        await until("the live read") { shown.liveTranscriptFeeds[sid]?.turns.isEmpty == false }
        shown.setLiveTranscriptWindowOnScreen(false)
        await sleep(2.0)
        expect(!shown.liveTranscriptPollRunning, "the poll stops off screen (N4)")
        let offScreen = stand.calls("live-transcript")
        await sleep(2.0)
        expect(stand.calls("live-transcript") == offScreen, "a minimized or covered window spawns nothing (N4)")
        await sleep(0.3)
        let back = Date()
        shown.setLiveTranscriptWindowOnScreen(true)
        await until("the read on coming back") { stand.calls("live-transcript") > offScreen }
        expect(Date().timeIntervalSince(back) < 0.7, "back on screen reads at once (N4)", "\(Date().timeIntervalSince(back)) s")
        let neverShown = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        neverShown.isReleasedWhenClosed = false
        expect(!ActivityWindowPresenter.onScreen(neverShown), "a window that is not shown is not on screen")
        await quiesce(shown)

        // ── A loop cancelled by the setting never clears the handle of the loop that replaced it (else a kick starts a
        // second loop beside it). Off and on in one turn, while the first loop's read is still running.
        stand.remove("overlap.log"); stand.remove("slow-started")
        on.status = liveStatus(1)
        on.liveTranscriptViewer("meetings", visible: true)
        stand.write("live-mode", "slowfree")
        await until("a slow read") { stand.exists("slow-started") }
        stand.write("live-mode", "hold")
        onDefaults.set(false, forKey: LiveTranscript.enabledKey)
        on.liveTranscriptSettingChanged()
        onDefaults.set(true, forKey: LiveTranscript.enabledKey)
        on.liveTranscriptSettingChanged()
        await until("the replacing loop's held read") { stand.exists("inflight") }
        for _ in 0..<10 { on.liveTranscriptKick(); await sleep(0.15) }
        stand.write("live-mode", "normal")
        stand.write("release", "")
        await until("the held read to finish") { !stand.exists("inflight") }
        expect(!stand.exists("overlap.log"), "a cancelled loop never lets a second one start", "overlap: \(stand.lines("overlap.log"))")

        // ── The setting turned off mid-meeting drops everything and stops.
        on.status = liveStatus(1)
        on.liveTranscriptKick()
        await until("polling again") { on.liveTranscriptFeeds[sid] != nil }
        onDefaults.set(false, forKey: LiveTranscript.enabledKey)
        on.liveTranscriptSettingChanged()
        let atOff = stand.calls("live-transcript")
        await sleep(2.0)
        expect(!on.liveTranscriptPollRunning && on.liveTranscriptFeeds.isEmpty && on.liveTranscriptRows.isEmpty
               && stand.calls("live-transcript") <= atOff + 1, "turning the setting off stops the poll and forgets the text")
        // Recording indicators use status even with the transcript preference off and every window hidden.
        let (recording, recordingDefaults) = model(stand, enabled: false)
        var badges: [String?] = []
        recording.recordingStatusChanged = { [weak recording] _ in badges.append(recording?.recordingDockBadge) }
        recording.status = liveStatus(1)
        expect(recording.recordingCount == 1 && badges.last! == "REC", "recording status without transcript opt-in")
        recording.status = liveStatus(2)
        expect(recording.recordingDockBadge == "REC 2", "multiple recording badge")
        recording.status = liveStatus(0, active: 3, stale: [sid])
        expect(recording.recordingDockBadge == nil, "stale sessions are not recording")
        recording.status = liveStatus(1)
        recording.status.running = false
        expect(recording.recordingCount == 0 && badges.last! == nil, "server failure clears recording badge")
        recording.status = liveStatus(1)
        var opened: ActivitySection?
        recording.openActivity = { opened = $0 }
        recording.showRecordingTranscript()
        expect(opened == nil, "disabled transcript shortcut respects preference")
        recordingDefaults.set(true, forKey: LiveTranscript.enabledKey)
        let beforeShortcut = stand.calls("live-transcript")
        recording.showRecordingTranscript()
        expect(opened == .meetings && recording.activityOpenRecording, "shortcut routes to Meetings")
        recording.beginRecordingTranscriptShortcut()
        expect(stand.calls("live-transcript") == beforeShortcut && !recording.liveTranscriptPollRunning,
               "shortcut waits for a visible Meetings viewer before reading text")
        let fresh = reply(liveAnswer(chunks: firstChunks, settled: 5, stamp: "100.1.4096"))
        recording.applyLiveTranscript(fresh, now: Date())
        expect(recording.liveTranscriptOpenID == sid, "shortcut opens the freshly listed active transcript")
        recording.closeLiveTranscript()
        recording.beginRecordingTranscriptShortcut()
        recording.closeLiveTranscript()
        recording.applyLiveTranscript(fresh, now: Date())
        expect(recording.liveTranscriptOpenID == nil, "navigation cancels pending shortcut")
        recording.beginRecordingTranscriptShortcut()
        recording.applyLiveTranscript(fresh, now: Date().addingTimeInterval(31))
        expect(recording.liveTranscriptOpenID == nil, "pending shortcut expires")
        recording.status = liveStatus(2)
        recording.beginRecordingTranscriptShortcut()
        recording.applyLiveTranscript(fresh, now: Date())
        expect(recording.liveTranscriptOpenID == nil, "multiple recordings stay in the chooser")
        recording.status = liveStatus(1)
        COSAppDelegate.recordingAvailable = { true }
        let delegate = COSAppDelegate()
        let dockMenu = COSAppDelegate.makeDockMenu(target: delegate)
        expect(dockMenu.items.first?.title == "View live transcript", "Dock menu has a direct recording action")
        var fired = false
        COSAppDelegate.onOpenRecording = { fired = true }
        delegate.dockOpenRecording()
        expect(fired, "Dock action invokes recording shortcut")
        COSAppDelegate.recordingAvailable = { false }
        expect(COSAppDelegate.makeDockMenu(target: delegate).items.map(\.title) == COSAppDelegate.dockMenuTitles,
               "idle Dock menu retains its existing actions")
        COSAppDelegate.recordingAvailable = nil
        COSAppDelegate.onOpenRecording = nil
        // V2: navigation/relaunch restores persisted history, and only submit spends model tokens.
        let askRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: askRoot) }
        let askState = MeetingAskStore(root: askRoot)
        var submits = 0
        var historyDelay = 0
        var historyReads = 0
        var fixtureServer = "fixture-server"
        var submittedCutoff = -1
        var loseNextReceipt = false
        var missingStatus = false
        var submittedPayloads: [Data] = []
        var retained: [[String: Any]] = []
        // 0.5.282: the fixture server offers two models and switches on `configure`, as PUT /api/meeting-ask/config does.
        var fixtureSelected: [String: Any] = ["engine": "claude", "model": "haiku"]
        var configures = 0
        let config: [String: Any] = ["protocolVersion": 2, "serverInstanceId": "fixture-server", "pairingContext": "fixture-pairing",
            "selected": ["engine": "claude", "model": "haiku"], "models": [["engine": "claude", "model": "haiku", "available": true], ["engine": "claude", "model": "sonnet", "available": true]]]
        let transport: (String, Data) async throws -> Data = { operation, data in
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let payload = envelope["payload"] as? [String: Any] ?? [:]
            var body: [String: Any]
            switch operation {
            case "identity": body = ["pairingContext": "fixture-pairing"]
            case "config": body = config; body["serverInstanceId"] = fixtureServer; body["selected"] = fixtureSelected
            case "configure":
                configures += 1
                fixtureSelected = ["engine": payload["engine"] as? String ?? "", "model": payload["model"] as? String ?? ""]
                body = config; body["serverInstanceId"] = fixtureServer; body["selected"] = fixtureSelected; body["pairingContext"] = nil
            case "history":
                historyReads += 1
                if historyDelay > 0 { try? await Task.sleep(for: .milliseconds(historyDelay)) }
                body = ["exchanges": retained.filter { ($0["sessionId"] as? String) == (payload["sessionId"] as? String) }, "files": []]
            case "files":
                try? await Task.sleep(for: .milliseconds(1200))
                body = ["files": []]
            case "status":
                if missingStatus { throw MeetingAskTransportFailure(status: 404, message: "Not admitted yet") }
                guard let row = retained.first(where: { $0["requestId"] as? String == payload["requestId"] as? String }) else { throw MeetingAskTransportFailure(status: 404, message: "Unknown") }
                body = ["exchange": row]
            case "submit":
                submits += 1
                submittedPayloads.append(try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys))
                if loseNextReceipt { loseNextReceipt = false; throw MeetingAskTransportFailure(status: 0, message: "Timed out before admission") }
                submittedCutoff = payload["elapsedMs"] as? Int ?? -1
                try? await Task.sleep(for: .milliseconds(100))
                let row: [String: Any] = ["requestId": payload["requestId"]!, "sessionId": payload["sessionId"]!, "serverInstanceId": "fixture-server", "action": payload["action"]!, "question": payload["question"]!, "status": "completed", "createdAt": "2026-10-10", "updatedAt": "2026-10-10", "selectedModel": ["engine": "claude", "model": "haiku"], "answer": "The draft is due Friday. [T1]", "sources": [["id": "T1", "kind": "transcript", "title": "Miles", "text": "Fixture words"]], "notices": [], "throughMs": 30000, "files": []]
                retained.append(row); body = ["exchange": row]
            default: throw HelperClientError.commandFailed("Unexpected fixture operation")
            }
            return try JSONSerialization.data(withJSONObject: body)
        }
        askState.injectedTransport = transport
        await askState.open(sid, model: recording)
        expect(submits == 0, "opening durable Ask burns no tokens")
        askState.setDraft("Keep draft", session: sid)
        expect(askState.flush(sid), "draft flush succeeds")
        var askFeed = LiveTranscriptFeed(sessionId: sid)
        askFeed.apply(reply(liveAnswer(chunks: firstChunks, settled: 5, stamp: "ask")).read!, now: Date())
        askFeed.startTime = Date().addingTimeInterval(-120)
        askState.ask(action: "summary", question: "Summarize so far", feed: askFeed, model: recording)
        expect(askState.draft(sid) == "Keep draft", "preset does not replace an independent composer draft")
        askState.ask(action: "summary", question: "Summarize so far", feed: askFeed, model: recording)
        askState.setDraft("Next question while waiting", session: sid)
        await askState.open("meeting_other", model: recording)
        await until("durable Ask answer") { !askState.running.contains(sid) }
        expect(submits == 1, "double clicking never submits twice")
        expect((120000...120400).contains(submittedCutoff), "question cutoff is pinned before delayed file registration")
        expect(askState.records[sid]?.exchanges.count == 1, "answer retained while another meeting opens")
        expect(askState.records["meeting_other"]?.exchanges.isEmpty == true, "no cross-meeting leakage")
        await askState.open(sid, model: recording)
        expect(askState.records[sid]?.exchanges.count == 1, "returning to meeting retains answer")
        expect(askState.records[sid]?.outbox == nil && askState.draft(sid) == "Next question while waiting", "admission clears only its submitted draft, preserving a newer follow-up")
        askState.setDraft("A follow-up", session: sid); _ = askState.flush(sid)
        let restarted = MeetingAskStore(root: askRoot); restarted.injectedTransport = transport
        await restarted.open(sid, model: recording)
        expect(restarted.draft(sid) == "A follow-up", "draft survives restart")
        expect(restarted.records[sid]?.exchanges.count == 1, "accepted answer survives restart")
        expect(submits == 1, "restart and navigation perform no inference")
        loseNextReceipt = true; missingStatus = true
        askState.ask(action: "ask", question: "Original uncertain request", feed: askFeed, model: recording)
        await until("uncertain admission") { !askState.running.contains(sid) }
        let original = askState.records[sid]?.outbox?.requestId
        expect(original != nil, "uncertain admission keeps frozen outbox")
        await askState.reconcile(sid, model: recording)
        expect(askState.records[sid]?.outbox?.requestId == original && submits == 2, "404 status never clears uncertain admission or replays automatically")
        askState.setDraft("Keep another draft", session: sid)
        askState.retryOutbox(sid, model: recording)
        await until("explicit same-question retry") { !askState.running.contains(sid) }
        expect(submits == 3 && submittedPayloads[1] == submittedPayloads[2], "explicit retry preserves request ID and exact frozen payload")
        expect(askState.records[sid]?.outbox == nil && askState.draft(sid) == "Keep another draft", "confirmed idempotent retry retains newer unsent draft")

        askState.ask(action: "summary", question: "Summarize so far", feed: askFeed, model: recording)
        await until("preset preserves composer") { !askState.running.contains(sid) }
        expect(askState.draft(sid) == "Keep another draft", "preset acceptance preserves the untouched composer draft")
        askState.ask(action: "ask", question: "Retry old answer", feed: askFeed, model: recording, retryOf: "old-attempt")
        await until("retry preserves composer") { !askState.running.contains(sid) }
        expect(askState.draft(sid) == "Keep another draft", "retrying an older answer preserves the independent composer draft")

        // 0.5.282: switching the model while a question is on its way. The question keeps the model it was asked with
        // (its request carries it; the server pins it), the pick runs configure once, and the next question carries the
        // new model.
        func submittedModel(_ index: Int) -> String {
            guard submittedPayloads.indices.contains(index), let row = try? JSONSerialization.jsonObject(with: submittedPayloads[index]) as? [String: Any],
                  let pick = row["model"] as? [String: Any] else { return "none" }
            return "\(pick["engine"] ?? ""):\(pick["model"] ?? "")"
        }
        let haikuModel = MeetingAskModel(engine: "claude", model: "haiku"), sonnetModel = MeetingAskModel(engine: "claude", model: "sonnet")
        expect(askState.modelLock == nil && askState.config?.selected == haikuModel, "the model control starts unlocked on the server's model",
               "lock \(askState.modelLock ?? "nil")")
        let beforeSwitch = submittedPayloads.count
        askState.ask(action: "summary", question: "Summarize so far", feed: askFeed, model: recording)
        expect(askState.running.contains(sid), "a question is on its way while the model changes")
        expect(askState.selectModel("claude:sonnet", model: recording), "a pick while a question is on its way starts one change")
        expect(askState.pendingModel == sonnetModel && askState.modelLock == "Switching to Claude · sonnet…",
               "the controls lock at once, naming the model", askState.modelLock ?? "nil")
        expect(!askState.selectModel("claude:haiku", model: recording), "a second pick while the first is with the server is refused")
        await until("model change answered") { askState.pendingModel == nil }
        await until("question asked before the switch") { !askState.running.contains(sid) }
        expect(configures == 1, "one pick runs configure exactly once", "configure ran \(configures) times")
        expect(askState.config?.selected == sonnetModel && askState.modelLock == nil && askState.modelError == nil,
               "after the switch both controls read the new model, unlocked", "\(String(describing: askState.config?.selected))")
        expect(submittedPayloads.count == beforeSwitch + 1 && submittedModel(beforeSwitch) == "claude:haiku",
               "the question asked before the switch keeps the model it was asked with", submittedModel(beforeSwitch))
        askState.ask(action: "summary", question: "Summarize so far", feed: askFeed, model: recording)
        await until("question after the switch") { !askState.running.contains(sid) }
        expect(submittedModel(beforeSwitch + 1) == "claude:sonnet", "the next question carries the new model", submittedModel(beforeSwitch + 1))
        expect(!askState.selectModel("claude:sonnet", model: recording) && configures == 1, "picking the model in use asks the server nothing")

        let importedStore = MeetingAskStore(root: askRoot.appendingPathComponent("imported"))
        let importedCopy = importedStore.captureCopy(title: "Imported meeting", transcript: "Imported words", sessions: [])!
        let importedText = await importedStore.prepareCopy(importedCopy, model: recording)
        expect(importedText?.contains("Imported words") == true, "imported meetings without capture keys copy local context without server capability")
        let copySnapshot = askState.captureCopy(title: "Meeting A", transcript: "Original meeting A transcript", sessions: [sid])!
        historyDelay = 200
        let initialHistoryReads = historyReads
        let copyTask = Task { await askState.prepareCopy(copySnapshot, model: recording) }
        await until("copy history read") { historyReads > initialHistoryReads }
        recording.openLiveTranscript("meeting_other")
        await askState.open("meeting_other", model: recording)
        let copied = await copyTask.value
        expect(copied?.contains("Original meeting A transcript") == true && copied?.contains("Original uncertain request") == true, "navigation while history loads keeps captured transcript and Ask from the same meeting")
        let identityReads = historyReads
        let identityTask = Task { await askState.prepareCopy(copySnapshot, model: recording) }
        await until("copy identity read") { historyReads > identityReads }
        fixtureServer = "replacement-server"
        await askState.refreshConfig(model: recording)
        let refusedCopy = await identityTask.value
        expect(refusedCopy == nil, "server change during full-context copy refuses mixed-context output")
        await quiesce(recording)
        print("live transcript wiring checks: \(passed) passed")
        print("PASS: live transcript wiring checks complete")
        exit(0)
    }

    // MARK: render

    /// A helper answer the way the model reads one: HelperResponse, then its details re-encoded.
    static func reply(_ answer: String) -> LiveTranscriptReply {
        let response = try! JSONDecoder().decode(HelperResponse.self, from: Data(answer.utf8))
        return LiveTranscriptReply.decode(try! JSONEncoder().encode(response.details))!
    }

    static func renderAll(_ out: URL, stand: Stand) async throws {
        stand.write("live-mode", "normal")
        stand.write("meeting-library-detail.json", """
        {"ok":true,"message":"x","details":{"recordId":"merged","title":"Saved test meeting","date":"2026-10-10","time":"07:29","domain":"personal","duration":"8 min",
         "summary":"Fixture summary of the saved meeting.","transcript":"Miles: Fixture opening line about the launch plan.\\n\\nJordan: Fixture reply about the timeline and budget."}}
        """)
        let now = Date()
        let start = now.addingTimeInterval(-12 * 60).timeIntervalSince1970 * 1000
        // While a pane is drawn its poll may run: these stand-ins hold each state still (the file unchanged, or gone),
        // and pass every other verb to the main stand-in.
        func standIn(_ name: String, _ liveAnswer: String) -> URL {
            let url = stand.dir.appendingPathComponent(name)
            let script = "#!/bin/sh\nD=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\nif [ \"$1\" = live-transcript ]; then cat <<'JSON'\n\(liveAnswer)\nJSON\nexit 0; fi\nexec \"$D/helper\" \"$@\"\n"
            try! script.write(to: url, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let still = standIn("helper-still", "{\"ok\":true,\"message\":\"x\",\"details\":{\"sessions\":[{\"sessionId\":\"\(sid)\",\"mtimeMs\":\(String(format: "%.0f", now.timeIntervalSince1970 * 1000)),\"size\":1,\"stamp\":\"1\"}],\"read\":{\"sessionId\":\"\(sid)\",\"ended\":false,\"unchanged\":true,\"stamp\":\"1\"}}}")
        let gone = standIn("helper-gone", endedAnswer)
        func make(_ chunks: [(Int, String, String, Int)], last: Date, settled: Int, ended: Bool = false) -> ControllerModel {
            let (m, _) = model(stand, enabled: true, helper: ended ? gone : still)
            m.status = liveStatus(1)
            m.applyLiveTranscript(reply(liveAnswer(chunks: chunks, settled: settled, stamp: "1", start: start,
                                                   last: last.timeIntervalSince1970 * 1000)), now: now)
            m.openLiveTranscript(sid)
            return m
        }
        let short = lines.enumerated().map { ($0.offset, $0.element.0, $0.element.1, $0.offset * 6000 + 2000) }
        let speakers = ["Miles", "Jordan", "Zoë Ångström", "Unknown"]
        let long = (0..<1500).map { i -> (Int, String, String, Int) in
            (i, speakers[(i / 4) % speakers.count], "Fixture sentence number \(i) in a long meeting, plain text only.", i * 2400)
        }
        let monologueChunks = (0..<130).map { i in
            (i, "Ext", "This is fixture sentence \(i) about the project. We reviewed the timing and agreed to revisit the next step after the meeting.", i * 6000)
        }
        let monologue = make(monologueChunks, last: now.addingTimeInterval(-3), settled: 129)
        let oversized = make([(0, "Ext", String(repeating: "This is a long fixture transcription chunk. It needs paragraph breaks while keeping every original word. ", count: 45), 0)],
                             last: now.addingTimeInterval(-3), settled: 0)
        let live = make(short, last: now.addingTimeInterval(-8), settled: 5)
        let thousand = make(long, last: now.addingTimeInterval(-3), settled: 1499)
        let quiet = make(short, last: now.addingTimeInterval(-4 * 60 - 10), settled: 5)
        let finalizing = make(short, last: now.addingTimeInterval(-20), settled: 5, ended: true)
        // Ended two minutes ago (inside the 3-minute deadline): the duration reads 10 min, not 12 (QA W2).
        finalizing.applyLiveTranscript(reply(endedAnswer), now: now.addingTimeInterval(-2 * 60))

        let savedText = "## Transcript\n\n[Ext]: " + String(repeating: "The saved recording now has readable sections. [Ext]: We keep the exact words while grouping short fragments. ", count: 12) + "[MU]: Can we confirm the next step?\n[MU]: The draft is due Friday.\n[Jordan]: I will review it."
        let previewAsk = MeetingAskStore(root: out.appendingPathComponent("ask-preview"))
        previewAsk.injectedTransport = { operation, _ in
            let body: [String: Any]
            switch operation {
            case "identity": body = ["pairingContext": "preview"]
            case "config": body = ["protocolVersion": 2, "serverInstanceId": "preview", "pairingContext": "preview", "selected": ["engine": "claude", "model": "haiku"], "models": [["engine": "claude", "model": "haiku", "available": true]]]
            case "history": body = ["exchanges": [["requestId": "preview-answer", "sessionId": "meeting_fixture", "serverInstanceId": "preview", "action": "summary", "question": "Summarize so far", "status": "completed", "createdAt": "2026-10-10", "updatedAt": "2026-10-10", "selectedModel": ["engine": "claude", "model": "haiku"], "answer": "**So what:** The team agreed to review the draft on Friday. [T1]\n\nPricing stays open until Jordan sees the numbers.\n\n- Starter holds at $59\n- Pro moves to $119\n\n**Decided:** Miles will prepare the draft.\n**Next:** Jordan will review it before the meeting.", "sections": [["label": "So what", "text": "The team agreed to review the draft on Friday. [T1]\n\nPricing stays open until Jordan sees the numbers.\n\n- Starter holds at $59\n- Pro moves to $119", "sources": ["T1"]], ["label": "Decided", "text": "Miles will prepare the draft.", "sources": []], ["label": "Next", "text": "Jordan will review it before the meeting.", "sources": []]], "sources": [["id": "T1", "kind": "transcript", "title": "Miles · 0:30", "text": "The draft is due Friday."]], "notices": [], "throughMs": 30000, "files": []]], "files": []]
            default: body = ["files": []]
            }
            return try JSONSerialization.data(withJSONObject: body)
        }
        await previewAsk.open("meeting_fixture", model: live)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try render(ScrollView { COSMarkdownView(text: savedText, meetingTranscript: true, bodySize: 14).padding(24).frame(maxWidth: 700) }, width: 900, height: 700, appearance: appearance, name: "saved-recording-readable", out: out)
            try render(LiveAskPanel(state: previewAsk, model: live, session: "meeting_fixture", feed: live.openLiveTranscriptFeed, jump: { _ in }), width: 362, height: 700, appearance: appearance, name: "live-ask-answer", out: out)
            for width in [280.0, 520.0] {
                try render(LiveAskPanel(state: previewAsk, model: live, session: "meeting_fixture", feed: live.openLiveTranscriptFeed), width: width, height: 700, appearance: appearance, name: "live-ask-width-\(Int(width))", out: out)
            }
            try render(LiveTranscriptPane(model: monologue), width: 900, height: 700, appearance: appearance, name: "pane-long-same-speaker", out: out)
            try render(LiveTranscriptPane(model: oversized), width: 900, height: 700, appearance: appearance, name: "pane-oversized-chunk", out: out)
            try render(LiveTranscriptPane(model: live), width: 900, height: 560, appearance: appearance, name: "pane-live-short", out: out)
            try render(LiveTranscriptPane(model: thousand), width: 900, height: 560, appearance: appearance, name: "pane-live-1500-chunks", out: out)
            try render(LiveTranscriptPane(model: quiet), width: 900, height: 560, appearance: appearance, name: "pane-no-audio-4m", out: out)
            try render(LiveNowRows(model: quiet), width: 900, height: 90, appearance: appearance, name: "row-no-audio-4m", out: out)
            try render(LiveNowRows(model: live), width: 900, height: 90, appearance: appearance, name: "row-live", out: out)
            try render(LiveTranscriptPane(model: finalizing), width: 900, height: 560, appearance: appearance, name: "pane-finalizing", out: out)
            try render(LiveNowRows(model: finalizing), width: 900, height: 90, appearance: appearance, name: "row-finalizing", out: out)
            try render(MeetingLibraryBody(model: live) { _ in }, width: 900, height: 420, appearance: appearance, name: "meetings-with-live-row", out: out)

            // The saved hand-off: the saved meeting open where the live one was.
            let handed = make(short, last: now.addingTimeInterval(-20), settled: 5)
            let row = LibraryMeeting(.object(try! JSONDecoder().decode([String: JSONValue].self, from: Data(libraryRow(recordId: "merged", sessionId: "meeting_first_capture",
                                     filename: "2026-10-10_Live_System_Test.md", g2: ["meeting_first_capture", sid], title: "Saved test meeting").utf8))))!
            handed.liveTranscriptHandoffTaken()
            handed.openLibraryMeeting(row)
            for _ in 0..<100 where handed.libraryDetail == nil { try await Task.sleep(for: .milliseconds(50)) }
            guard handed.libraryDetail != nil else { fatalError("render: the saved meeting did not load: \(handed.libraryDetailError ?? "?")") }
            try render(MeetingLibraryDetailPane(model: handed, onReviewVoices: { _, _ in }), width: 900, height: 420, appearance: appearance,
                       name: "saved-handoff", out: out)
            try panel(live, appearance: appearance, name: "panel-meetings-chip-dot", out: out)
        }
        print("wrote PNGs to \(out.path)")
    }

    /// The shipping Activity shell, never ordered in. Fixtures drive the same
    /// model routing that its menu/tab actions use; width changes use the same
    /// stored preference as the divider. This does NOT synthesize mouse drags.
    static func askShellCanary(_ out: URL, stand: Stand) async throws {
        guard NSHomeDirectory().contains("cos-live-transcript"),
              FileManager.default.homeDirectoryForCurrentUser.path.contains("cos-live-transcript") else {
            fatalError("ask-canary requires the runner's private home")
        }
        let (m, _) = model(stand, enabled: true)
        m.setLiveTranscriptWindowOnScreen(false)
        var submits = 0
        var reads = 0
        // 0.5.282: the models a real server lists (Claude's three, Codex not connected, Cursor not qualified), switched by
        // `configure` as PUT /api/meeting-ask/config does. `reachMode` makes the config read fail as offline or older.
        var selected: [String: Any] = ["engine": "claude", "model": "haiku"]
        var configures = 0
        var configureDelayMs = 0
        var reachMode = "online"
        var offlineAfterConfigure = false
        let models: [[String: Any]] = [["engine": "claude", "model": "sonnet", "available": true], ["engine": "claude", "model": "haiku", "available": true],
            ["engine": "claude", "model": "opus", "available": true], ["engine": "codex", "model": "gpt-5.5", "available": false, "reason": "provider_unavailable"],
            ["engine": "cursor", "model": "auto", "available": false, "reason": "meeting_adapter_not_qualified"]]
        func config() -> [String: Any] {
            ["protocolVersion": 2, "serverInstanceId": "shell-fixture", "pairingContext": "shell-fixture", "selected": selected, "models": models]
        }
        let exchange: [String: Any] = ["requestId": "shell-answer", "sessionId": sid, "serverInstanceId": "shell-fixture",
            "action": "summary", "question": "What did we decide about the draft?", "status": "completed",
            "createdAt": "2026-10-10", "updatedAt": "2026-10-10", "selectedModel": ["engine": "claude", "model": "haiku"],
            "answer": "The draft is due Friday. [T1]\n\n- Miles will prepare the draft.\n- Jordan will review it before the meeting.",
            "sources": [["id": "T1", "kind": "transcript", "title": "Miles · 0:30", "text": "The draft is due Friday."]],
            "notices": [], "throughMs": 30000, "files": []]
        m.meetingAsk.injectedTransport = { operation, data in
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let payload = envelope["payload"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch operation {
            case "identity": result = ["pairingContext": "shell-fixture"]
            case "config":
                if reachMode == "offline" { throw MeetingAskTransportFailure(status: 0, message: "Meeting assistant is offline. Your question is retained; nothing retries automatically.") }
                if reachMode == "outdated" { throw MeetingAskTransportFailure(status: 404, message: "Update the COS server to use saved meeting assistance.") }
                result = config()
            case "configure":
                configures += 1
                if configureDelayMs > 0 { try? await Task.sleep(for: .milliseconds(configureDelayMs)) }
                selected = ["engine": payload["engine"] as? String ?? "", "model": payload["model"] as? String ?? ""]
                if offlineAfterConfigure { reachMode = "offline" }
                var reply = config(); reply["pairingContext"] = nil
                result = reply
            case "history":
                reads += 1
                result = ["exchanges": payload["sessionId"] as? String == sid ? [exchange] : [], "files": []]
            case "files": result = ["files": []]
            case "submit": submits += 1; throw HelperClientError.commandFailed("Canary must never request inference")
            default: throw HelperClientError.commandFailed("Unexpected shell fixture operation")
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
        let chunks = lines.enumerated().map { ($0.offset, $0.element.0, $0.element.1, $0.offset * 6000) }
        m.applyLiveTranscript(reply(liveAnswer(chunks: chunks, settled: 5, stamp: "shell")), now: Date())
        m.activityOpenSection = .meetings
        let window = ActivityWindowPresenter.makeWindow(model: m)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.close() }
        guard let host = window.contentView else { fatalError("Activity shell has no content view") }
        host.layoutSubtreeIfNeeded()
        await until("initial shell Meetings route") { m.activityOpenSection == nil }
        m.openLiveTranscript(sid)
        await m.meetingAsk.open(sid, model: m)
        let draft = "Keep this unsent follow-up when I change tabs."
        m.meetingAsk.setDraft(draft, session: sid)
        expect(m.meetingAsk.flush(sid), "shell draft is durable before navigation")
        let oldWidth = UserDefaults.standard.object(forKey: "meetingAskPanelWidth")
        defer {
            if let oldWidth { UserDefaults.standard.set(oldWidth, forKey: "meetingAskPanelWidth") }
            else { UserDefaults.standard.removeObject(forKey: "meetingAskPanelWidth") }
        }
        func capture(_ name: String) async throws {
            await sleep(0.45)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            expect(!window.isVisible && NSApp.activationPolicy() == .prohibited, "canary never activates or displays a window")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("shell bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Encode only after cacheDisplay populates the bitmap.
            guard let rendered = bitmap.representation(using: .png, properties: [:]) else { fatalError("shell PNG unavailable") }
            try rendered.write(to: out.appendingPathComponent(name + ".png"))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            let theme = appearance == .darkAqua ? "dark" : "light"
            for (width, panel) in [(900.0, 280.0), (1180.0, 360.0), (1440.0, 520.0)] {
                UserDefaults.standard.set(panel, forKey: "meetingAskPanelWidth")
                window.setContentSize(NSSize(width: width, height: 800))
                try await capture("ask-shell-\(Int(width))-panel-\(Int(panel))-\(theme)")
            }
        }
        let savedCount = m.meetingAsk.records[sid]?.exchanges.count
        m.activityOpenSection = .messages
        await until("shell Messages route") { m.activityOpenSection == nil && m.liveTranscriptOpenID == nil }
        try await capture("ask-shell-navigated-away")
        m.activityOpenSection = .meetings
        await until("shell Meetings route") { m.activityOpenSection == nil }
        m.openLiveTranscript(sid)
        await m.meetingAsk.open(sid, model: m)
        expect(m.meetingAsk.records[sid]?.exchanges.count == savedCount && savedCount == 1,
               "production shell navigation retains accepted answer")
        expect(m.meetingAsk.draft(sid) == draft, "production shell navigation retains unsent draft")
        expect(submits == 0 && reads > 0, "shell resize and navigation read history without inference")
        try await capture("ask-shell-returned-with-history")
        // 0.5.281: the composer in the production shell is the AppKit text view, holds the durable draft, and a file
        // dropped on it never becomes its path. This shell has no meeting file store, so the drop must say so honestly.
        guard let composer = composerView(in: host) else { fail("production shell composer", "no MeetingAskComposerTextView in the Ask panel") }
        expect(composer.string == draft, "production shell composer shows the durable draft", composer.string)
        expect(composer.readablePasteboardTypes.contains(.png) && composer.registeredDraggedTypes.contains(.fileURL)
               && !composer.registeredDraggedTypes.contains(.init("com.apple.NSFilePromiseItemMetaData")),
               "production shell composer takes an image paste and a file drop", composer.registeredDraggedTypes.map(\.rawValue).joined(separator: ","))
        let field = composer.enclosingScrollView?.contentSize.width ?? -1
        expect(field > 0 && abs(composer.frame.width - field) < 1 && abs((composer.textContainer?.containerSize.width ?? -1) - field) < 1,
               "production shell composer wraps at the field's width", "text \(composer.frame.size) field \(field)")
        let shot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Screenshot 2026-10-10 at 7.23.21 PM.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shot)
        let board = FixtureDrag.board()
        defer { board.releaseGlobally() }
        board.writeObjects([shot as NSURL])
        expect(composer.draggingEntered(FixtureDrag(board)) == .copy, "production shell composer offers to copy a dragged file")
        expect(composer.performDragOperation(FixtureDrag(board)), "production shell composer takes the dropped file")
        await until("composer drop answers") { m.meetingAsk.attachNotes[sid] != nil }
        expect(m.meetingAsk.draft(sid) == draft && composer.string == draft, "a file dropped on the composer never types its path",
               composer.string)
        expect(m.meetingAsk.attachNotes[sid] == MeetingAskText.attachUnavailable, "without a file store the drop says nothing was attached",
               m.meetingAsk.attachNotes[sid] ?? "nil")
        expect(submits == 0, "a composer drop requests no inference")
        try await capture("ask-shell-composer-drop-no-store")

        // ── 0.5.282: the model control, in the production shell and in Settings (the menu-bar panel's Meeting assistant
        // card), against the one store. What each face says is read from the pixels (Vision), cropped to that face.
        let settings = Offscreen(MeetingAskSettings(store: m.meetingAsk, model: m), width: 390, height: 360)
        defer { settings.close() }
        await until("Settings reads the config") { m.meetingAsk.config != nil && m.meetingAsk.reach == .online }
        let haikuModel = MeetingAskModel(engine: "claude", model: "haiku"), sonnetModel = MeetingAskModel(engine: "claude", model: "sonnet")
        var shots = 9
        var panelBelow = "", settingsWords = ""
        /// The words on the Ask panel's model face (the dropdown under the composer) in the shell's current render.
        func panelFace(_ name: String) async throws -> String {
            try await capture(name); shots += 1
            guard let composer = composerView(in: host)?.enclosingScrollView else { fail("model control renders", "no composer in the shell") }
            let field = composer.convert(composer.bounds, to: host)
            let below = dropdownFaces(in: host).filter { host.isFlipped ? $0.minY >= field.maxY - 1 : $0.maxY <= field.minY + 1 }
            guard below.count == 1, let face = below.first else { fail("model control renders", "\(below.count) dropdown faces under the composer") }
            let panelLeft = host.bounds.width - CGFloat(UserDefaults.standard.double(forKey: "meetingAskPanelWidth"))
            expect(face.minX >= panelLeft + 16 && face.maxX <= host.bounds.width - 16 + 0.5 && face.width >= 120,
                   "the model face fits inside the Ask panel's padding", "face \(face) panel from \(panelLeft) to \(host.bounds.width)")
            // The lines under the face, across the panel: where the control says why it is locked.
            let strip = CGRect(x: panelLeft + 16, y: host.isFlipped ? face.maxY : face.minY - 36, width: host.bounds.width - panelLeft - 32, height: 36)
            panelBelow = ocr(host, strip)
            return ocr(host, face)
        }
        func settingsFace(_ name: String) throws -> String {
            let faces = settings.render(to: out.appendingPathComponent(name + ".png")); shots += 1
            guard faces.count == 1, let face = faces.first else { fail("Settings model control renders", "\(faces.count) dropdown faces in Settings") }
            settingsWords = ocr(settings.host, settings.host.bounds)
            return ocr(settings.host, face)
        }
        func faceReads(_ words: String, _ model: String) -> Bool {
            let w = words.lowercased()
            return w.contains("claude") && w.contains(model) && !["haiku", "sonnet", "opus"].filter { $0 != model }.contains { w.contains($0) }
        }
        // The sequence below is drawn light (the loop above left the shell dark); the last loop draws both themes.
        window.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set(280.0, forKey: "meetingAskPanelWidth")
        window.setContentSize(NSSize(width: 900, height: 800))
        var words = try await panelFace("ask-model-280-before-light")
        expect(faceReads(words, "haiku"), "the Ask panel's model control renders the current model (Claude · haiku)", words)
        words = try settingsFace("settings-model-before-light")
        expect(faceReads(words, "haiku"), "Settings shows the same model", words)
        expect(MeetingAskModelPicker.rows(m.meetingAsk.config!).map(\.id) == models.map { "\($0["engine"]!):\($0["model"]!)" }
               && MeetingAskModelPicker.rows(m.meetingAsk.config!).filter(\.enabled).count == 3, "the control lists every model the server lists, three choosable")
        // The open list, drawn as the dropdown draws it (COSDropdownList with the control's own options). The dropdown
        // opens it in a panel window, which a check never orders in, so it is drawn here in an offscreen host instead.
        let listOptions = MeetingAskModelControl.options(m.meetingAsk.config!)
        expect(listOptions.map(\.enabled) == [true, true, true, false, false] && listOptions.filter { !$0.enabled }.allSatisfy { $0.muted && $0.note != nil },
               "the open list mutes and disables each unavailable model, with its reason")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let list = Offscreen(COSDropdownList(options: listOptions, selection: MeetingAskModelPicker.selectedID(m.meetingAsk.config!), highlight: .constant(nil), framed: true) { _ in },
                                 width: 360, height: 260)
            list.window.appearance = NSAppearance(named: appearance)
            _ = list.render(to: out.appendingPathComponent("ask-model-list-\(appearance == .darkAqua ? "dark" : "light").png")); shots += 1
            let listed = ocr(list.host, list.host.bounds).lowercased()
            list.close()
            expect(["sonnet", "haiku", "opus", "codex", "not connected", "cursor", "not qualified"].allSatisfy { listed.contains($0) },
                   "the open list shows every model and each unavailable one's reason (\(appearance == .darkAqua ? "dark" : "light"))", listed)
        }

        // A pick, through the binding the control's dropdown writes (COSDropdown sets its selection; both surfaces bind
        // MeetingAskStore.modelSelection). The server is held for a moment so the lock can be seen.
        configureDelayMs = 900
        let panelBinding = m.meetingAsk.modelSelection(model: m)
        expect(panelBinding.wrappedValue == "claude:haiku", "the control's selection is the server's model", panelBinding.wrappedValue)
        panelBinding.wrappedValue = "claude:sonnet"
        expect(m.meetingAsk.pendingModel == sonnetModel && m.meetingAsk.modelLock == "Switching to Claude · sonnet…", "the pick locks both controls, naming the model",
               m.meetingAsk.modelLock ?? "nil")
        _ = try await panelFace("ask-model-280-switching-light")
        _ = try settingsFace("settings-model-switching-light")
        expect(panelBelow.lowercased().contains("switching to") && settingsWords.lowercased().contains("switching to"),
               "the pick locks both controls and both say so under the face", "panel: \(panelBelow) | settings: \(settingsWords)")
        panelBinding.wrappedValue = "claude:opus"
        await until("the model change") { m.meetingAsk.pendingModel == nil }
        expect(configures == 1, "one pick through the control runs configure exactly once (a second pick while locked is refused)", "configure ran \(configures) times")
        expect(m.meetingAsk.config?.selected == sonnetModel && panelBinding.wrappedValue == "claude:sonnet" && m.meetingAsk.modelLock == nil,
               "after the switch the control's selection is the new model, unlocked", panelBinding.wrappedValue)
        let cached = (try? m.meetingAsk.disk.readConfig(pairing: "shell-fixture")) ?? nil
        expect(cached?.selected == sonnetModel, "after a switch the cached config (used offline at launch) carries the new model",
               String(describing: cached?.selected))
        words = try await panelFace("ask-model-280-after-light")
        expect(faceReads(words, "sonnet"), "the Ask panel shows the new model", words)
        expect(!panelBelow.lowercased().contains("switching"), "unlocked, nothing is said under the face", panelBelow)
        words = try settingsFace("settings-model-after-light")
        expect(faceReads(words, "sonnet"), "Settings shows the model picked in the Ask panel", words)

        // The other way: a pick in Settings shows in the Ask panel.
        configureDelayMs = 0
        let settingsBinding = m.meetingAsk.modelSelection(model: m)
        settingsBinding.wrappedValue = "claude:haiku"
        await until("the second model change") { m.meetingAsk.pendingModel == nil }
        expect(configures == 2 && m.meetingAsk.config?.selected == haikuModel, "a pick in Settings runs configure once more", "configure ran \(configures) times")
        words = try await panelFace("ask-model-280-back-light")
        expect(faceReads(words, "haiku"), "the Ask panel shows the model picked in Settings", words)
        words = try settingsFace("settings-model-back-light")
        expect(faceReads(words, "haiku"), "Settings shows its own pick", words)
        settingsBinding.wrappedValue = "codex:gpt-5.5"
        settingsBinding.wrappedValue = "claude:haiku"
        expect(m.meetingAsk.pendingModel == nil && configures == 2, "an unavailable model, or the model in use, asks the server nothing")

        // The server takes the switch but the re-read after it fails: its answer to configure still shows in both.
        let opusModel = MeetingAskModel(engine: "claude", model: "opus")
        offlineAfterConfigure = true
        m.meetingAsk.modelSelection(model: m).wrappedValue = "claude:opus"
        await until("the switch whose re-read fails") { m.meetingAsk.pendingModel == nil }
        offlineAfterConfigure = false
        expect(configures == 3 && m.meetingAsk.config?.selected == opusModel && m.meetingAsk.reach == .offline && m.meetingAsk.modelError == nil,
               "a switch whose re-read fails still shows the new model", "\(String(describing: m.meetingAsk.config?.selected)) \(m.meetingAsk.reach)")
        words = try await panelFace("ask-model-280-reread-failed-light")
        expect(faceReads(words, "opus"), "a switch whose re-read fails shows the new model on the face", words)
        reachMode = "online"
        await m.meetingAsk.refreshConfig(model: m)
        m.meetingAsk.modelSelection(model: m).wrappedValue = "claude:haiku"
        await until("back to haiku") { m.meetingAsk.pendingModel == nil }
        expect(configures == 4 && m.meetingAsk.config?.selected == haikuModel, "back to haiku through the same binding")
        let switches = configures

        // Offline, then a server on another protocol: both controls lock with a short reason and a pick asks nothing.
        for (mode, reason) in [("offline", "Reconnect COS to switch models."), ("outdated", "Update COS to switch models.")] {
            reachMode = mode
            await m.meetingAsk.refreshConfig(model: m)
            expect(m.meetingAsk.modelLock == reason, "\(mode): both model controls lock with a short reason", m.meetingAsk.modelLock ?? "nil")
            m.meetingAsk.modelSelection(model: m).wrappedValue = "claude:opus"
            expect(m.meetingAsk.pendingModel == nil && configures == switches, "\(mode): a pick while locked asks the server nothing")
            _ = try await panelFace("ask-model-280-\(mode)-light")
            _ = try settingsFace("settings-model-\(mode)-light")
            let said = reason.lowercased().prefix(12)
            expect(panelBelow.lowercased().contains(said) && settingsWords.lowercased().contains(said),
                   "\(mode): both controls show the reason under the face", "panel: \(panelBelow) | settings: \(settingsWords)")
        }
        reachMode = "online"
        await m.meetingAsk.refreshConfig(model: m)
        expect(m.meetingAsk.modelLock == nil, "back online, the controls unlock")

        // Every width and both themes, with the control in place.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance); settings.window.appearance = NSAppearance(named: appearance)
            let theme = appearance == .darkAqua ? "dark" : "light"
            for (width, panel) in [(900.0, 280.0), (1440.0, 520.0)] {
                UserDefaults.standard.set(panel, forKey: "meetingAskPanelWidth")
                window.setContentSize(NSSize(width: width, height: 800))
                words = try await panelFace("ask-model-\(Int(panel))-\(theme)")
                expect(faceReads(words, "haiku"), "\(theme) at \(Int(panel)) pt: the model control reads Claude · haiku", words)
            }
            words = try settingsFace("settings-model-\(theme)")
            expect(faceReads(words, "haiku"), "\(theme): Settings reads Claude · haiku", words)
        }
        expect(submits == 0, "switching models requests no inference")
        let report: [String: Any] = ["passedChecks": passed, "historyReads": reads, "inferenceRequests": submits, "configureCalls": configures,
            "screenshots": shots, "productionShell": true, "pointerDragTested": false, "composerDropViaFixtureDraggingInfo": true,
            "modelPickThroughControlBinding": true, "modelFaceReadByVision": true,
            "limitations": "Offscreen production shell and model routing; persisted panel widths, not synthesized mouse gestures. The model pick writes the binding the dropdown writes; the dropdown's own list is never opened (it is a window). Inspect PNGs for CTA alignment and clipping."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("ask-shell-canary.json"))
        print("PASS: Meeting Ask production-shell canary; \(passed) checks; \(shots) screenshots; \(configures) configure calls; zero inference")
    }

    /// 0.5.282: a view in a borderless window that is never ordered in, kept alive so it follows the store, rendered on
    /// demand. The process cannot become active (.prohibited).
    @MainActor final class Offscreen {
        let host: NSView
        let window: NSWindow
        init<V: View>(_ view: V, width: CGFloat, height: CGFloat) {
            let hosting = NSHostingView(rootView: view.padding(16).frame(width: width, height: height, alignment: .top).background(COSPalette.panel))
            window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host = hosting
        }
        /// Writes a PNG and returns the dropdown faces in it (host coordinates).
        func render(to url: URL) -> [CGRect] {
            LiveTranscriptRender.settle(host, seconds: 0.6)
            host.displayIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])!.write(to: url)
            return LiveTranscriptRender.dropdownFaces(in: host)
        }
        func close() { window.close() }
    }

    /// Every COSDropdown face in a rendered tree, in `host` coordinates: each face carries an invisible anchor view
    /// (COSDropdownAnchor's `Anchor`) exactly its size.
    static func dropdownFaces(in host: NSView) -> [CGRect] {
        var faces: [CGRect] = [], queue: [NSView] = [host]
        while let view = queue.popLast() {
            if String(describing: type(of: view)) == "Anchor" { faces.append(view.convert(view.bounds, to: host)) }
            queue += view.subviews
        }
        return faces.filter { $0.width > 1 && $0.height > 1 }
    }

    /// The words Vision reads in `rect` (host coordinates) of the host's current drawing, joined by spaces.
    static func ocr(_ host: NSView, _ rect: CGRect) -> String {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "" }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let crop = CGRect(x: rect.minX * scale, y: top * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let image = rep.cgImage?.cropping(to: crop) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// The Ask composer's text view in a rendered view tree.
    static func composerView(in view: NSView) -> MeetingAskComposerTextView? {
        if let found = view as? MeetingAskComposerTextView { return found }
        for child in view.subviews { if let found = composerView(in: child) { return found } }
        return nil
    }

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, appearance: NSAppearance.Name, name: String, out: URL) throws {
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

    /// The whole menu-bar panel (its scroll document), to show the Meetings chip's dot.
    static func panel(_ model: ControllerModel, appearance: NSAppearance.Name, name: String, out: URL) throws {
        let host = NSHostingView(rootView: ControlPanel(model: model, openActivity: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 900)
        defer { window.close() }
        settle(host, seconds: 1.5)
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
    }
}
