import AppKit
import SwiftUI

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
@main @MainActor struct LiveTranscriptRender {
    static let sid = "meeting_1791635349988_fx67ab"

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "check":
            guard args.count > 1 else { fatalError("usage: check <fake helper>") }
            await checkModel(Stand(URL(fileURLWithPath: args[1])))
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
        let saved = on.liveTranscriptHandoff!
        on.liveTranscriptHandoffTaken()
        on.openLibraryMeeting(saved)
        expect(!on.liveTranscriptRouteActive && on.openLibraryRow?.recordId == "merged" && on.liveTranscriptFeeds[sid] == nil,
               "the saved meeting opens in place of the live one")

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
        on.refreshLiveTranscriptHandoff(slow.sessionId)
        await until("Refresh to find the row") { on.liveTranscriptFeeds[slow.sessionId] == nil }
        expect(true, "Refresh asks again and a found row ends the hand-off")

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
        let live = make(short, last: now.addingTimeInterval(-8), settled: 5)
        let thousand = make(long, last: now.addingTimeInterval(-3), settled: 1499)
        let quiet = make(short, last: now.addingTimeInterval(-4 * 60 - 10), settled: 5)
        let finalizing = make(short, last: now.addingTimeInterval(-20), settled: 5, ended: true)
        finalizing.applyLiveTranscript(reply(endedAnswer), now: now)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
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
