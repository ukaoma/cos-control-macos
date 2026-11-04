import AppKit
import SwiftUI

/// 0.5.366: renaming a live recording with the whole app compiled, against a stand-in helper (Tests/run-title-steer.sh).
///
///   check <fake helper>          the model executed: Rename is hidden on a server that does not advertise the route and on
///                                an iPhone microphone recording, open on a live Mac recording and glasses meeting, locked once
///                                the recording stops or its file is gone; the header's title is the steer over a calendar
///                                title; beginning reads the server's revision, Save writes it with the title on stdin and
///                                never in the arguments, and the answer lands in the live feed; a 409 title_changed adopts the
///                                server's title; Escape closes the open field and is taken; a Mac save sends the steer as the
///                                title; the title text reaches no argument of any call.
///   render <dir> <fake helper>   PNGs, light and dark: the mock's states (before any rename, editing, renamed with a second live
///                                recording in the switcher), then the field over the limit, a refusal under the field, and
///                                Rename disabled while a save is out.
///
/// The stand-in answers from files the check writes beside it; nothing reaches the real helper, the server or the active-sessions
/// folder. All text is invented. No window is ordered in, no event is sent, nothing becomes active.
@main @MainActor struct TitleSteerRender {
    static let mac = "mac_43879e59-3039-4f2c-9cd2-4fcc59486d71"
    static let glasses = "meeting_1792098620540_yeuti0"
    static var passed = 0

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "check":
            guard args.count > 1 else { fatalError("usage: check <fake helper>") }
            await check(Stand(URL(fileURLWithPath: args[1])))
        case "render":
            guard args.count > 2 else { fatalError("usage: render <dir> <fake helper>") }
            let out = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try await renderAll(out, stand: Stand(URL(fileURLWithPath: args[2])))
        default: fatalError("usage: check <fake helper> | render <dir> <fake helper>")
        }
    }

    static func fail(_ behaviour: String, _ detail: String) -> Never {
        print("title steer wiring check FAILED [\(behaviour)]: \(detail)")
        exit(1)
    }

    static func expect(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
        guard condition else { fail(behaviour, detail()) }
        passed += 1
    }

    struct Stand {
        let helper: URL
        var dir: URL { helper.deletingLastPathComponent() }
        init(_ helper: URL) { self.helper = helper }
        func write(_ name: String, _ text: String) { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        func lines(_ name: String) -> [String] { read(name).split(separator: "\n").map(String.init) }
        func clearLogs() { for name in ["calls.log", "args.log", "stdin.log"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) } }
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

    static let title = "Polling accuracy chat"

    static func status(titleSteer: Bool, live: Int = 1) -> ServerStatus {
        ServerStatus([
            "installed": .bool(true), "running": .bool(true), "runtimeState": .string("managedHealthy"),
            "activeTranscriptionSessions": .number(Double(live)), "liveTranscriptionSessions": .number(Double(live)),
            "liveMeetingProtocol": .number(1), "liveMeetingMacLiveCues": .bool(true), "liveMeetingProvisional": .bool(true),
            "liveCueKinds": .array(LiveMeeting.knownKinds.map { .string($0) }), "liveCuesOn": .bool(true),
            "meetingTitleSteer": .bool(titleSteer),
        ])
    }

    static func ms(_ date: Date) -> String { String(format: "%.0f", date.timeIntervalSince1970 * 1000) }

    static let lines = [
        ("Miles", "Fixture opening line about the polling plan."),
        ("Jordan", "Fixture reply about the weighting and the sample."),
        ("Miles", "Fixture follow up about how the accuracy is judged."),
    ]

    /// One reply: every listed session is a file; one is read in full (the turns, and the steer when it has one).
    static func reply(files: [(id: String, start: Date)], read id: String, steer: String?, now: Date) -> LiveTranscriptReply {
        let rows = files.map { "{\"sessionId\":\"\($0.id)\",\"mtimeMs\":\(ms(now)),\"stamp\":\"1\"}" }.joined(separator: ",")
        let start = files.first { $0.id == id }!.start
        let turns = lines.enumerated().map { "{\"i\":\($0.offset),\"elapsedMs\":\($0.offset * 6000 + 2000),\"speaker\":\"\($0.element.0)\",\"text\":\"\($0.element.1)\"}" }.joined(separator: ",")
        let steerKey = steer.map { ",\"titleSteer\":\"\($0)\"" } ?? ""
        let json = """
        {"dataDir":"/tmp/cos-title-steer-fixture","sessions":[\(rows)],"read":{"sessionId":"\(id)","ended":false,"unchanged":false,"stamp":"1","startTime":\(ms(start)),
        "lastActivityAt":\(ms(now)),"settledThrough":2,"turns":[\(turns)]\(steerKey)}}
        """
        return LiveTranscriptReply.decode(Data(json.utf8))!
    }

    /// The stand-in's live-transcript answer while a pane is drawn: the same files, the open one unchanged.
    static func holdStill(_ stand: Stand, files: [(id: String, start: Date)], open: String, now: Date) {
        let rows = files.map { "{\"sessionId\":\"\($0.id)\",\"mtimeMs\":\(ms(now)),\"stamp\":\"1\"}" }.joined(separator: ",")
        stand.write("live-transcript.json", "{\"ok\":true,\"message\":\"x\",\"details\":{\"dataDir\":\"/tmp/cos-title-steer-fixture\",\"sessions\":[\(rows)],\"read\":{\"sessionId\":\"\(open)\",\"ended\":false,\"unchanged\":true,\"stamp\":\"1\"}}}")
    }

    static func answers(_ stand: Stand, read: String? = nil, write: String? = nil) {
        stand.write("title-steer-read.json", read ?? "{\"ok\":true,\"message\":\"x\",\"details\":{\"transport\":\"answered\",\"httpStatus\":200,\"title\":null,\"revision\":0,\"updatedAt\":null}}")
        stand.write("title-steer-write.json", write ?? "{\"ok\":true,\"message\":\"x\",\"details\":{\"transport\":\"answered\",\"httpStatus\":200,\"title\":\"\(title)\",\"revision\":1,\"updatedAt\":\"2026-11-03T21:05:00.000Z\"}}")
    }

    static func model(_ stand: Stand, titleSteer: Bool, live: Int = 1) -> ControllerModel {
        let defaults = UserDefaults(suiteName: "title-steer-render-\(UUID().uuidString)")!
        defaults.set(true, forKey: LiveTranscript.enabledKey)
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: stand.helper))
        model.liveTranscriptDefaults = defaults
        model.status = status(titleSteer: titleSteer, live: live)
        return model
    }

    // MARK: check

    static func check(_ stand: Stand) async {
        let now = Date()
        // The glasses meeting began 40 minutes ago: far enough from the Mac recording that the calendar event named for it is not the Mac's.
        let macStart = now.addingTimeInterval(-3 * 60), glassesStart = now.addingTimeInterval(-40 * 60)
        let files = [(id: mac, start: macStart), (id: glasses, start: glassesStart)]
        answers(stand)
        holdStill(stand, files: files, open: mac, now: now)

        // An older server: no capability, no Rename.
        let older = model(stand, titleSteer: false, live: 2)
        older.applyLiveTranscript(reply(files: files, read: mac, steer: nil, now: now), now: now)
        older.applyLiveTranscript(reply(files: files, read: glasses, steer: nil, now: now), now: now)
        expect(!older.liveMeetingCapability.titleSteer && older.titleSteerAvailability(mac) == .hidden && older.titleSteerAvailability(glasses) == .hidden,
               "a server that does not advertise the route shows no Rename on either recording")
        stand.clearLogs()
        older.beginTitleSteer(mac)
        expect(older.titleSteer.editing == nil && stand.lines("calls.log").isEmpty, "begin on an older server opens nothing and spawns nothing")

        // A server that advertises it.
        let newer = model(stand, titleSteer: true, live: 2)
        expect(newer.titleSteerAvailability(mac) == .hidden, "no read of the recording yet: no Rename")
        newer.applyLiveTranscript(reply(files: files, read: mac, steer: nil, now: now), now: now)
        newer.applyLiveTranscript(reply(files: files, read: glasses, steer: nil, now: now), now: now)
        expect(newer.liveMeetingCapability.titleSteer && newer.titleSteerAvailability(mac) == .open && newer.titleSteerAvailability(glasses) == .open,
               "a Mac recording and a glasses meeting both open Rename")
        expect(newer.titleSteerAvailability(nil) == .hidden && newer.titleSteerAvailability("meeting_unknown_x") == .hidden, "no session, or one never read: no Rename")
        expect(newer.titleSteerAvailability("phone_abc123") == .hidden, "an iPhone microphone recording: no Rename")

        // The header's title: the steer over the calendar's, and the calendar's returns when it is cleared.
        newer.liveMeetingCalendarEvent = TodayHome.NextEvent(title: "Fixture planning sync", start: glassesStart.addingTimeInterval(120))
        expect(newer.liveMeetingTitle(glasses, start: glassesStart) == "Fixture planning sync", "fixture: the calendar names an unnamed glasses meeting")
        newer.applyLiveTranscript(reply(files: files, read: glasses, steer: "Quarterly numbers with Acme", now: now), now: now)
        expect(newer.liveMeetingTitle(glasses, start: glassesStart) == "Quarterly numbers with Acme", "the steer beats the calendar title")
        expect(newer.liveMeetingFileInfo(glasses).title == "Quarterly numbers with Acme", "files dropped on the meeting are filed under the steer")
        newer.applyLiveTranscript(reply(files: files, read: glasses, steer: nil, now: now), now: now)
        expect(newer.liveMeetingTitle(glasses, start: glassesStart) == "Fixture planning sync", "cleared, the calendar title is back")
        expect(newer.liveMeetingTitle(mac, start: macStart).hasPrefix("Mac recording "), "an unnamed Mac recording reads as it did")

        // Begin reads the revision; Save writes it with the title on stdin only, and the answer lands in the feed.
        stand.clearLogs()
        newer.beginTitleSteer(mac)
        expect(newer.titleSteer.editing == mac, "begin opens the field on the Mac recording")
        expect(newer.titleSteer.initialDraft.hasPrefix("Mac recording "), "the field opens on the title on screen")
        await until("the revision read") { stand.lines("args.log").contains("meeting-title-steer --session \(mac)") }
        newer.saveTitleSteer(draft: title)
        await until("the rename to land") { newer.titleSteer.editing == nil && !newer.titleSteer.busy }
        let args = stand.lines("args.log")
        expect(args.last == "meeting-title-steer --session \(mac) --revision 0 --title-stdin", "Save writes with the revision it read", "\(args)")
        expect(stand.read("stdin.log").contains("\"title\"") && stand.read("stdin.log").contains(title), "the title went on stdin")
        expect(!stand.read("args.log").contains("Polling") && !stand.read("calls.log").contains("Polling"), "the title is in no argument of any call")
        expect(newer.liveTranscriptFeeds[mac]?.titleSteer == title, "the server's answer is in the live feed", "\(String(describing: newer.liveTranscriptFeeds[mac]?.titleSteer))")
        expect(newer.liveMeetingTitle(mac, start: macStart) == title, "the header's title is the steer at once")
        expect(newer.macRecording.steerTitle?(mac) == title && newer.macRecording.steerTitle?(glasses) == nil, "a Mac save reads the steer from the live feed, by recording")
        expect(MacRecordingNotice.saveTitle(recording: "Mac recording 9:05 PM", steer: title) == title
               && MacRecordingNotice.saveTitle(recording: "Mac recording 9:05 PM", steer: nil) == "Mac recording 9:05 PM"
               && MacRecordingNotice.saveTitle(recording: "Zoom meeting 2:05 PM", steer: "  ") == "Zoom meeting 2:05 PM", "a Mac save sends the steer as its title, else the recording's own")
        expect(LiveTranscript.switcherLabel(mac, start: macStart, steer: newer.liveTranscriptFeeds[mac]?.titleSteer) == title, "the switcher uses the steer")

        // The next read of the file keeps it (unchanged), and a full read without the key clears it (renamed elsewhere, cleared).
        newer.openLiveTranscript(mac)
        await newer.pollLiveTranscriptOnce()
        expect(newer.liveTranscriptFeeds[mac]?.titleSteer == title, "an unchanged poll keeps the steer")
        newer.applyLiveTranscript(reply(files: files, read: mac, steer: nil, now: now), now: now)
        expect(newer.liveTranscriptFeeds[mac]?.titleSteer == nil && newer.macRecording.steerTitle?(mac) == nil, "a full read with no steer clears it, and so the Mac save's")

        // Another device renamed it first: theirs is adopted.
        answers(stand, read: "{\"ok\":true,\"message\":\"x\",\"details\":{\"transport\":\"answered\",\"httpStatus\":200,\"title\":null,\"revision\":4,\"updatedAt\":null}}",
                write: "{\"ok\":true,\"message\":\"x\",\"details\":{\"transport\":\"answered\",\"httpStatus\":409,\"error\":\"title_changed\",\"current\":{\"title\":\"Renamed on the phone\",\"revision\":5,\"updatedAt\":null}}}")
        newer.beginTitleSteer(glasses)
        await until("the revision read") { stand.lines("args.log").last == "meeting-title-steer --session \(glasses)" }
        newer.saveTitleSteer(draft: "Mine")
        await until("the conflict") { newer.titleSteer.editing == nil && !newer.titleSteer.busy }
        expect(newer.liveTranscriptFeeds[glasses]?.titleSteer == "Renamed on the phone" && newer.titleSteer.message == "Renamed on another device." && newer.titleSteer.messageSession == glasses,
               "409 title_changed: the server's title is the feed's, and the line says so")
        expect(stand.lines("args.log").last == "meeting-title-steer --session \(glasses) --revision 4 --title-stdin", "the write named the revision it read")

        // Escape closes an open field and is taken; with none open it is not.
        answers(stand)
        newer.beginTitleSteer(mac)
        expect(newer.titleSteer.editing == mac && newer.titleSteer.escape() && newer.titleSteer.editing == nil, "Escape closes the open field and is taken")
        expect(!newer.titleSteer.escape(), "Escape with no field open is the window's own")

        // The recording stops with the field open: Save is refused at the click, the field closes, and nothing is written.
        newer.beginTitleSteer(glasses)
        expect(newer.titleSteer.editing == glasses, "fixture: the field is open on the glasses meeting")
        stand.clearLogs()
        newer.glassesMeetingStop = G2MeetingStopProgress(sessionId: glasses, phase: .stopping)
        newer.saveTitleSteer(draft: "Too late")
        await sleep(0.2)
        expect(newer.titleSteer.editing == nil && !stand.read("args.log").contains("--title-stdin"), "Save after the recording stopped writes nothing and closes the field", stand.read("args.log"))
        newer.glassesMeetingStop = nil
        answers(stand)

        // Locked once the recording stops: a glasses stop in progress, and a file that is gone.
        newer.glassesMeetingStop = G2MeetingStopProgress(sessionId: glasses, phase: .stopping)
        expect(newer.titleSteerAvailability(glasses) == .locked && newer.titleSteerAvailability(mac) == .open, "a glasses stop in progress locks that meeting's Rename and no other")
        newer.beginTitleSteer(glasses)
        expect(newer.titleSteer.editing == nil, "begin on a locked recording opens nothing")
        newer.glassesMeetingStop = nil
        var ended = newer.liveTranscriptFeeds[mac]!
        ended.markEnded(now: now)
        newer.liveTranscriptFeeds[mac] = ended
        expect(newer.titleSteerAvailability(mac) == .locked, "a recording whose file is gone is locked")
        newer.closeLiveTranscript()
        for model in [older, newer] {
            model.liveTranscriptViewer("meetings", visible: false)
            model.liveTranscriptViewer("live-pane", visible: false)
            await until("a quiet model") { !model.liveTranscriptPollRunning }
        }
        print("title steer wiring checks: \(passed) passed")
        print("PASS: title steer wiring checks complete")
    }

    // MARK: render

    static func renderAll(_ out: URL, stand: Stand) async throws {
        let now = Date()
        let macStart = now.addingTimeInterval(-3 * 60), glassesStart = now.addingTimeInterval(-25 * 60)
        let files = [(id: mac, start: macStart), (id: glasses, start: glassesStart)]
        answers(stand)
        holdStill(stand, files: files, open: mac, now: now)

        /// A model with both recordings live and the Mac one open. `steer` is the name the Mac recording already has.
        func make(steer: String?, second: Bool = false, open: String = mac) -> ControllerModel {
            let model = model(stand, titleSteer: true, live: second ? 2 : 1)
            let listed = second ? files : [files[0]]
            if second { model.applyLiveTranscript(reply(files: listed, read: glasses, steer: nil, now: now), now: now) }
            model.applyLiveTranscript(reply(files: listed, read: mac, steer: steer, now: now), now: now)
            holdStill(stand, files: listed, open: open, now: now)
            model.openLiveTranscript(open)
            return model
        }
        let run: (ControllerModel) -> TitleSteerStore.Run = { model in { args, stdin in try await model.runHelper(args, timeout: 5, stdinData: stdin) } }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // 1. Recording, before any rename.
            let before = make(steer: nil)
            try pane(before, appearance: appearance, name: "1-recording-before-rename", out: out)

            // 2. Editing: the mock's typed text. The field opens on the text given as `shown`.
            let editing = make(steer: nil)
            editing.titleSteer.begin(session: mac, steer: nil, shown: title, run: run(editing))
            try pane(editing, appearance: appearance, name: "2-editing", out: out)

            // 3. Renamed, a second recording live so the switcher shows.
            let renamed = make(steer: title, second: true)
            try pane(renamed, appearance: appearance, name: "3-renamed-with-switcher", out: out)

            // 5. The field over the limit.
            let over = make(steer: nil)
            over.titleSteer.begin(session: mac, steer: nil, shown: String(repeating: "Polling accuracy chat and weighting. ", count: 4), run: run(over))
            try pane(over, appearance: appearance, name: "5-editing-over-the-limit", out: out)

            // 6. A refusal under the open field (the recording is saving).
            answers(stand, write: "{\"ok\":true,\"message\":\"x\",\"details\":{\"transport\":\"answered\",\"httpStatus\":409,\"error\":\"save_in_progress\"}}")
            let refused = make(steer: nil)
            refused.titleSteer.begin(session: mac, steer: nil, shown: "Mac recording", run: run(refused))
            await refused.titleSteer.save(draft: title, run: run(refused), apply: { _, _ in })
            try pane(refused, appearance: appearance, name: "6-refused-while-saving", out: out)
            answers(stand)

            // 7. Rename disabled while a glasses stop is out.
            let locked = make(steer: nil, second: true, open: glasses)
            locked.glassesMeetingStop = G2MeetingStopProgress(sessionId: glasses, phase: .stopping)
            try pane(locked, appearance: appearance, name: "7-rename-disabled-while-saving", out: out)
            for model in [before, editing, renamed, over, refused, locked] {
                model.closeLiveTranscript()
                model.liveTranscriptViewer("meetings", visible: false)
                model.liveTranscriptViewer("live-pane", visible: false)
            }
        }
    }

    // MARK: drawing

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    static func pane(_ model: ControllerModel, appearance: NSAppearance.Name, name: String, out: URL) throws {
        let width: CGFloat = 1180, height: CGFloat = 430
        let host = NSHostingView(rootView: LiveTranscriptPane(model: model).frame(width: width, height: height, alignment: .top).background(COSPalette.panel))
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
