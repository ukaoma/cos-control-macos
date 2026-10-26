import Foundation

/// 0.5.336 (server 6.86.0): the live meeting view's pure pieces (LiveMeeting and its types in Sources/LiveTranscript.swift,
/// LiveMeetingCapability in Sources/Models.swift), executed. Compiled against those two files alone by
/// Tests/run-live-meeting.sh (lane "models"). Every name is fictional. Prints "live meeting checks: N passed".
@main struct LiveMeetingChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("live meeting check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    static func turn(_ id: Int, _ speaker: String, ms: Int) -> LiveTranscriptTurn {
        LiveTranscriptTurn(id: id, speaker: speaker, elapsedMs: ms, text: "fixture words", firstIndex: id, lastIndex: id)
    }

    static func details(_ json: String) -> [String: JSONValue] {
        try! JSONDecoder().decode(HelperResponse.self, from: Data(json.utf8)).details
    }

    static func main() {
        let start = Date(timeIntervalSince1970: 1_791_635_349.988)

        // ── Capability gating: through the helper's status keys, as the model reads them. Never a status code.
        let full = ServerStatus(details(#"""
        {"ok":true,"message":"x","details":{"running":true,"liveMeetingProtocol":1,"liveMeetingMacLiveCues":true,"liveMeetingProvisional":true,
         "liveCueKinds":["reinforce","challenge","decision","promise","followUp"],"liveCuesOn":true}}
        """#)).liveMeeting
        check(full.available && full.inlineCues && full.counts && full.greyLine && full.sendsMacLiveCues && full.macCues,
              "a 6.86.0 server with Live cues on opens every part")
        check(full.cueKinds == LiveMeeting.knownKinds, "the five kinds in the server's spelling")
        let older = ServerStatus(details(#"{"ok":true,"message":"x","details":{"running":true,"liveTranscriptionSessions":1}}"#)).liveMeeting
        check(older == LiveMeetingCapability() && !older.available && !older.inlineCues && !older.counts && !older.greyLine
              && !older.sendsMacLiveCues && !older.macCues, "a 6.85.0 server (no keys) opens none of them")
        let nullProtocol = ServerStatus(details(#"{"ok":true,"message":"x","details":{"liveMeetingProtocol":null,"liveMeetingMacLiveCues":true,"liveMeetingProvisional":true,"liveCueKinds":["decision"],"liveCuesOn":true}}"#)).liveMeeting
        check(!nullProtocol.available && !nullProtocol.greyLine && !nullProtocol.sendsMacLiveCues && !nullProtocol.counts,
              "every part needs protocol 1, whatever else is sent")
        var cuesOff = full; cuesOff.liveCuesOn = false
        check(!cuesOff.sendsMacLiveCues && cuesOff.macCues && cuesOff.inlineCues, "Live cues off: no liveCues on a Mac start, the Cues tab still reads")
        var noMac = full; noMac.macLiveCues = false
        check(!noMac.sendsMacLiveCues && !noMac.macCues, "a server that does not take the flag gets no liveCues")
        var noKinds = full; noKinds.cueKinds = []
        check(!noKinds.counts && noKinds.inlineCues, "no kinds listed: no counts, inline cues still shown")
        var noRoute = full; noRoute.provisional = false
        check(!noRoute.greyLine && noRoute.available, "no provisional route: no grey line")
        var protocol2 = full; protocol2.protocolVersion = 2
        check(!protocol2.available, "a protocol this build does not know opens nothing")

        // ── Kind labels: the five, and a kind this build does not know draws as a plain cue (no label, never dropped).
        check(LiveMeeting.knownKinds.compactMap(LiveMeeting.kindLabel) == ["Reinforce", "Challenge", "Decision", "Promise", "Follow-up"], "the five labels")
        check(LiveMeeting.kindLabel("advice") == nil && LiveMeeting.kindLabel("FollowUp") == nil && LiveMeeting.kindLabel("") == nil, "unknown kinds have no label")

        // ── Counts: from the cue history's kinds, zero LLM.
        check(LiveMeeting.countsPhrase(kinds: ["decision", "promise", "decision", "followUp", "challenge", "reinforce"]) == "2 decisions, 1 promise and 1 follow-up",
              "the plan's example")
        check(LiveMeeting.countsPhrase(kinds: ["decision"]) == "1 decision", "one")
        check(LiveMeeting.countsPhrase(kinds: ["followUp", "followUp", "promise", "promise"]) == "2 promises and 2 follow-ups", "two kinds, plurals")
        check(LiveMeeting.countsPhrase(kinds: ["challenge", "reinforce", "advice"]) == nil && LiveMeeting.countsPhrase(kinds: []) == nil,
              "coaching cues and unknown kinds are not counted")
        check(LiveMeeting.statusLine(mac: true, ended: false, kinds: ["decision", "decision", "promise", "followUp"])
              == "Recording on this Mac · 2 decisions, 1 promise and 1 follow-up so far", "the Mac status line")
        check(LiveMeeting.statusLine(mac: false, ended: false, kinds: []) == "Recording on the glasses", "nothing counted yet: where it records, alone")
        check(LiveMeeting.statusLine(mac: true, ended: false, kinds: nil) == "Recording on this Mac", "no kinds listed: no counts at all")
        check(LiveMeeting.statusLine(mac: true, ended: true, kinds: ["promise"]) == "1 promise" && LiveMeeting.statusLine(mac: true, ended: true, kinds: nil) == nil,
              "ended: the counts alone, never Recording")
        check(LiveMeeting.joined(["a", "b"]) == "a and b" && LiveMeeting.joined(["a", "b", "c"]) == "a, b and c" && LiveMeeting.joined([]) == nil, "the list joins")

        // ── Anchoring: each cue under the turn in progress at its createdAt.
        let turns = [turn(0, "Priya Raman", ms: 0), turn(4, "Jordan", ms: 30_000), turn(-5, "Priya Raman", ms: 75_000)]
        let anchored = LiveMeeting.anchor(cues: [("c-late", start.addingTimeInterval(80)), ("c-mid", start.addingTimeInterval(45)),
                                                 ("c-edge", start.addingTimeInterval(30)), ("c-early", start.addingTimeInterval(-3)),
                                                 ("c-first", start.addingTimeInterval(10)), ("c-mid2", start.addingTimeInterval(40))],
                                          turns: turns, start: start)
        check(anchored[0] == ["c-early", "c-first"], "a cue before the first turn goes under the first, oldest first")
        check(anchored[4] == ["c-edge", "c-mid2", "c-mid"], "a cue at a turn's start belongs to it; oldest first within a turn")
        check(anchored[-5] == ["c-late"], "a cue after the last turn's start goes under the last (a negative turn id works)")
        check(anchored.values.reduce(0) { $0 + $1.count } == 6, "every cue anchored once")
        check(LiveMeeting.anchor(cues: [("c", start)], turns: turns, start: nil).isEmpty
              && LiveMeeting.anchor(cues: [("c", start)], turns: [], start: start).isEmpty, "no start or no turns: nothing anchors (the Cues tab keeps them)")

        // ── The strip: first-heard order, one chip for unidentified voices, never You on a Mac recording.
        let heard = [turn(0, "Priya Raman", ms: 0), turn(1, "Speaker", ms: 6000), turn(2, "Jordan", ms: 12_000), turn(3, "You", ms: 18_000),
                     turn(4, "Ext", ms: 24_000), turn(5, "Priya Raman", ms: 30_000)]
        let mac = LiveMeeting.participants(heard, mac: true)
        check(mac.people.map(\.name) == ["Priya Raman", "Jordan", "Unidentified"] && mac.people.map(\.initials) == ["PR", "J", "?"],
              "Mac: named voices in order, unidentified last, no You")
        check(mac.lastHeard == "Priya Raman", "the newest turn's voice is heard last")
        let glasses = LiveMeeting.participants(heard, mac: false)
        check(glasses.people.map(\.name) == ["Priya Raman", "Jordan", "You", "Unidentified"], "glasses: You is a voice like any other")
        check(LiveMeeting.participants([turn(0, "Ext", ms: 0)], mac: true).lastHeard == "?unidentified", "an unidentified voice last: the unidentified chip")
        check(LiveMeeting.participants([turn(0, "you", ms: 0)], mac: true).people.isEmpty, "only You on a Mac: an empty strip")
        check(LiveMeeting.initials("Zoë Ångström") == "ZÅ" && LiveMeeting.initials("  jordan ") == "J" && LiveMeeting.initials("Dr. Ada Okafor-Lee") == "DO",
              "initials: first and last word")
        check(["Speaker", "ext", "Unidentified 2", "speaker 3", "Unknown", ""].allSatisfy(LiveMeeting.unidentified) && !LiveMeeting.unidentified("Extra Person"),
              "unidentified labels")

        // Anonymous acoustic clusters must stay separate without being presented as named people.
        let clustered = LiveMeeting.participants([turn(0, "Voice 2", ms: 0), turn(1, "Ext", ms: 6_000),
            turn(2, "Voice 1", ms: 12_000), turn(3, "Voice 2", ms: 18_000)], mac: true)
        check(clustered.people.map(\.name) == ["Voice 2", "Voice 1", "Unidentified"],
              "distinct live voice clusters preserve first-heard order; unattributed audio stays separate")
        check(clustered.people.map(\.id) == ["Voice 2", "Voice 1", "?unidentified"] && clustered.lastHeard == "Voice 2",
              "repeated cluster reuses its chip and last-heard identity")
        check(clustered.people.allSatisfy(\.anonymous) && clustered.people.map(\.initials) == ["2", "1", "?"],
              "numbered clusters remain anonymous and have distinct badges")
        check(clustered.people.first?.accessibilityName == "Voice 2, unnamed speaker"
              && !mac.people[0].anonymous && mac.people[0].accessibilityName == "Priya Raman",
              "accessibility distinguishes an unnamed cluster from an identified person")

        // ── The title.
        let utc = TimeZone(identifier: "UTC")!
        let event = (title: "Quarterly planning with Northwind", start: start.addingTimeInterval(-5 * 60))
        check(LiveMeeting.title(sessionId: "mac_x", macTitle: "Vendor call", calendar: event, start: start) == "Vendor call", "a typed title wins")
        check(LiveMeeting.title(sessionId: "mac_x", macTitle: "Zoom meeting 2:05 PM", calendar: event, start: start) == "Quarterly planning with Northwind",
              "an automatic title gives way to the calendar event near its start")
        check(LiveMeeting.title(sessionId: "mac_x", macTitle: "Mac recording 2:05 PM", calendar: (event.title, start.addingTimeInterval(3 * 3600)), start: start)
              == "Mac recording 2:05 PM", "an event hours away is not this meeting")
        check(LiveMeeting.title(sessionId: "meeting_1", macTitle: nil, calendar: event, start: start) == "Quarterly planning with Northwind", "a glasses meeting takes the event")
        check(LiveMeeting.title(sessionId: "meeting_1", macTitle: nil, calendar: nil, start: start, timeZone: utc) == "Glasses meeting 12:29 PM", "else its source and time")
        check(LiveMeeting.title(sessionId: "meeting_1", macTitle: nil, calendar: (" ", start), start: start, timeZone: utc) == "Glasses meeting 12:29 PM", "a blank event title is skipped")
        check(LiveMeeting.isAutomaticTitle("Mac recording 11:59 AM") && LiveMeeting.isAutomaticTitle("Microsoft Teams meeting 9:00 PM")
              && !LiveMeeting.isAutomaticTitle("Board meeting") && !LiveMeeting.isAutomaticTitle("Mac recording notes"), "automatic titles")

        // ── The audiogram's history ring: fixed size, oldest first, clamped.
        var ring = LiveAudiogramRing()
        check(ring.levels.count == LiveAudiogramRing.capacity && ring.levels.allSatisfy { $0 == 0 } && ring.latest == 0, "silence before the first level")
        for i in 0..<(LiveAudiogramRing.capacity + 7) { ring.push(Double(i % 10) / 10) }
        check(ring.levels.count == LiveAudiogramRing.capacity && ring.pushed == LiveAudiogramRing.capacity + 7, "pushing never grows it")
        check(ring.latest == Double((LiveAudiogramRing.capacity + 6) % 10) / 10 && ring.levels.last == ring.latest, "the newest is last")
        check(ring.levels.first == Double(7 % 10) / 10, "the oldest kept is the eighth pushed (seven fell off)")
        ring.push(4); check(ring.latest == 1, "a level over 1 is clamped")
        ring.push(-1); check(ring.latest == 0, "a negative level is clamped")
        ring.push(.nan); check(ring.latest == 0, "NaN is silence")
        check(LiveAudiogramRing.isSilent(0) && LiveAudiogramRing.isSilent(0.02) && !LiveAudiogramRing.isSilent(0.03), "silence is drawn dotted")

        // ── The preview rate cap: one in flight, 2 s apart, enough audio, previewGen per chunk, never older than shown.
        var gate = LiveMeetingPreviewGate()
        let t0 = Date(timeIntervalSince1970: 1_791_640_000)
        check(gate.begin(chunkIndex: 3, bytes: 31_999, now: t0) == nil, "under one second of audio: no post")
        check(gate.begin(chunkIndex: 3, bytes: 64_000, now: t0) == 0, "the first post of a chunk is generation 0")
        check(gate.begin(chunkIndex: 3, bytes: 64_000, now: t0.addingTimeInterval(5)) == nil, "never two in flight")
        gate.finish(answered: true)
        check(gate.begin(chunkIndex: 3, bytes: 64_000, now: t0.addingTimeInterval(1.9)) == nil, "never sooner than 2 s after the last post")
        check(gate.begin(chunkIndex: 3, bytes: 64_000, now: t0.addingTimeInterval(2)) == 1, "the next post of the same chunk is generation 1")
        gate.finish(answered: true)
        check(gate.begin(chunkIndex: 4, bytes: 64_000, now: t0.addingTimeInterval(4)) == 0, "a new chunk starts again at 0")
        gate.finish(answered: true)
        check(gate.begin(chunkIndex: -1, bytes: 64_000, now: t0.addingTimeInterval(10)) == nil, "no chunk index: no post")
        check(gate.accept(chunkIndex: 4, previewGen: 0) && !gate.accept(chunkIndex: 4, previewGen: 0) && !gate.accept(chunkIndex: 3, previewGen: 9)
              && gate.accept(chunkIndex: 4, previewGen: 2) && !gate.accept(chunkIndex: 4, previewGen: 1) && gate.accept(chunkIndex: 5, previewGen: 0),
              "an answer older than one already shown is dropped")
        var breaker = LiveMeetingPreviewGate()
        for n in 0..<LiveMeetingPreviewGate.breakerFailures {
            check(breaker.begin(chunkIndex: n, bytes: 64_000, now: t0.addingTimeInterval(Double(n) * 3)) != nil, "posts while under the breaker")
            breaker.finish(answered: false)
        }
        check(!breaker.open && breaker.begin(chunkIndex: 9, bytes: 64_000, now: t0.addingTimeInterval(60)) == nil, "three failures in a row stop the previews")
        // 0.5.337 (loop audit N14): a minute after the last failed post it tries once more; that one failing pauses again.
        check(breaker.begin(chunkIndex: 9, bytes: 64_000, now: t0.addingTimeInterval(6 + LiveMeetingPreviewGate.breakerPause)) != nil,
              "a paused breaker tries one post again a minute later")
        breaker.finish(answered: false)
        check(!breaker.open && breaker.begin(chunkIndex: 10, bytes: 64_000, now: t0.addingTimeInterval(6 + LiveMeetingPreviewGate.breakerPause + 30)) == nil,
              "that post failing pauses it again")
        var recovered = LiveMeetingPreviewGate()
        _ = recovered.begin(chunkIndex: 0, bytes: 64_000, now: t0); recovered.finish(answered: false)
        _ = recovered.begin(chunkIndex: 0, bytes: 64_000, now: t0.addingTimeInterval(3)); recovered.finish(answered: false)
        _ = recovered.begin(chunkIndex: 0, bytes: 64_000, now: t0.addingTimeInterval(6)); recovered.finish(answered: true)
        check(recovered.open && recovered.failures == 0, "an answer (a 204 miss included) resets the count")
        let long = Data((0..<600_001).map { UInt8(truncatingIfNeeded: $0) })
        let window = LiveMeetingPreviewGate.window(long)
        check(window.count == LiveMeetingPreviewGate.maximumBytes && window == long.subdata(in: 600_000 - LiveMeetingPreviewGate.maximumBytes..<600_000),
              "the window is the newest 15 s, on a sample boundary")
        check(LiveMeetingPreviewGate.window(Data(count: 3)).count == 2, "an odd tail byte is dropped")
        check(LiveMeetingPreviewGate.maximumBytes + 44 <= 512 * 1024, "the WAV fits the server's 512 KB")

        // ── The grey line: only past the last final chunk, never empty, newest 600 characters.
        var feed = LiveTranscriptFeed(sessionId: "s1")
        check(LiveMeeting.lastFinalChunk(nil) == -1 && LiveMeeting.lastFinalChunk(feed) == -1, "nothing final yet")
        feed.apply(LiveTranscriptRead(sessionId: "s1", ended: false, unchanged: false, stamp: "1", startTime: 1, lastActivityAt: nil, settledThrough: 2,
                                      turns: [LiveTranscriptChunk(i: 0, elapsedMs: 0, speaker: "Jordan", text: "a"), LiveTranscriptChunk(i: 4, elapsedMs: 24_000, speaker: "Jordan", text: "b")]),
                   now: t0)
        check(LiveMeeting.lastFinalChunk(feed) == 4, "the newest chunk read is the last final one")
        var settledFeed = LiveTranscriptFeed(sessionId: "s2")
        settledFeed.apply(LiveTranscriptRead(sessionId: "s2", ended: false, unchanged: false, stamp: "1", startTime: 1, lastActivityAt: nil, settledThrough: 6,
                                             turns: [LiveTranscriptChunk(i: 4, elapsedMs: 24_000, speaker: "Jordan", text: "b")]), now: t0)
        check(LiveMeeting.lastFinalChunk(settledFeed) == 6, "a settled cursor past the chunks read counts as final (silent chunks)")
        check(LiveMeeting.visibleProvisional(LiveProvisionalLine(chunkIndex: 5, previewGen: 0, text: "  still  being\nsaid "), lastFinalChunk: 4) == "still being said",
              "a newer chunk shows, whitespace collapsed")
        check(LiveMeeting.visibleProvisional(LiveProvisionalLine(chunkIndex: 4, previewGen: 9, text: "settled"), lastFinalChunk: 4) == nil,
              "the final text for that chunk replaces it")
        check(LiveMeeting.visibleProvisional(LiveProvisionalLine(chunkIndex: 9, previewGen: 0, text: " \n "), lastFinalChunk: 4) == nil && LiveMeeting.visibleProvisional(nil, lastFinalChunk: 4) == nil,
              "nothing to show")
        let shown = LiveMeeting.visibleProvisional(LiveProvisionalLine(chunkIndex: 9, previewGen: 0, text: String(repeating: "x", count: 700) + " end"), lastFinalChunk: 4)
        check(shown?.count == 601 && shown?.hasSuffix(" end") == true && shown?.hasPrefix("…") == true, "at most the newest 600 characters")

        // ── The helper's answers, through the JSONValue round trip.
        let read = LiveMeeting.provisional(details(#"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":200,"live":true,"provisional":{"chunkIndex":7,"previewGen":3,"text":"fixture"}}}"#), sessionId: "s1")
        check(read?.live == true && read?.line == LiveProvisionalLine(chunkIndex: 7, previewGen: 3, text: "fixture"), "the provisional read")
        check(LiveMeeting.provisional(details(#"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":200,"live":true,"provisional":null}}"#), sessionId: "s1")?.line == nil,
              "null: nothing grey")
        check(LiveMeeting.provisional(details(#"{"ok":true,"message":"x","details":{"transport":"unsupported","httpStatus":404}}"#), sessionId: "s1") == nil
              && LiveMeeting.provisional(details(#"{"ok":true,"message":"x","details":{"transport":"unavailable"}}"#), sessionId: "s1") == nil
              && LiveMeeting.provisional(details(#"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":500}}"#), sessionId: "s1") == nil,
              "anything but an answered 200 changes nothing")
        check(LiveMeeting.provisional(details(#"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":500,"live":true,"provisional":{"chunkIndex":7,"previewGen":3,"text":"fixture"}}}"#), sessionId: "s1") == nil
              && LiveMeeting.provisional(details(#"{"ok":true,"message":"x","details":{"transport":"unsupported","httpStatus":200,"live":true,"provisional":{"chunkIndex":7,"previewGen":3,"text":"fixture"}}}"#), sessionId: "s1") == nil,
              "a line riding on a failed or unsupported answer is never shown")
        let preview = details(#"{"ok":true,"message":"x","details":{"httpStatus":200,"chunkIndex":4,"previewGen":2,"text":"fixture words"}}"#)
        check(LiveMeeting.previewAnswer(preview, chunkIndex: 4, previewGen: 2)?.text == "fixture words", "the Mac preview's line")
        check(LiveMeeting.previewAnswer(preview, chunkIndex: 4, previewGen: 3) == nil && LiveMeeting.previewAnswer(preview, chunkIndex: 5, previewGen: 2) == nil,
              "an answer for another post is not this one")
        check(LiveMeeting.previewAnswer(details(#"{"ok":true,"message":"x","details":{"httpStatus":204,"miss":true}}"#), chunkIndex: 4, previewGen: 2) == nil, "a miss")

        // ── The Mac start's live cues answer.
        check(LiveMeeting.arm(.object(["armed": .bool(true), "kinds": .array([])])) == MacLiveCuesArm(armed: true, reason: nil)
              && LiveMeeting.armLine(MacLiveCuesArm(armed: true, reason: nil)) == nil, "armed: nothing to say")
        let refused = LiveMeeting.arm(.object(["armed": .bool(false), "reason": .string("master_flag_off")]))
        check(refused == MacLiveCuesArm(armed: false, reason: "master_flag_off") && LiveMeeting.armLine(refused) == "Cues off: the Live cues switch is off",
              "a refusal says why, never as a recording error")
        check(LiveMeeting.armLine(LiveMeeting.arm(.object(["armed": .bool(false), "reason": .string("some_new_reason")]))) == "Cues off: some new reason",
              "an unknown reason reads as its words")
        check(LiveMeeting.armLine(LiveMeeting.arm(.object(["armed": .bool(false), "reason": .string("Bad <text>")]))) == "Cues off: unavailable",
              "a reason outside the code grammar never shows")
        check(LiveMeeting.arm(nil) == nil && LiveMeeting.arm(.object(["armed": .string("yes")])) == nil && LiveMeeting.armLine(nil) == nil, "not asked, or not said")

        // ── The elapsed clock.
        check(LiveMeeting.elapsed(0) == "0:00" && LiveMeeting.elapsed(7.9) == "0:07" && LiveMeeting.elapsed(724) == "12:04"
              && LiveMeeting.elapsed(3723) == "1:02:03" && LiveMeeting.elapsed(-5) == "0:00" && LiveMeeting.elapsed(.infinity) == "0:00", "the clock")

        // ── 0.5.339 (server 6.87.0): the glasses meeting's level strip, the bar's widths, the Files row.
        let levelled = ServerStatus(details(#"""
        {"ok":true,"message":"x","details":{"running":true,"liveMeetingProtocol":1,"liveMeetingMacLiveCues":true,"liveMeetingProvisional":true,"liveMeetingChunkLevels":true}}
        """#)).liveMeeting
        check(levelled.chunkLevels && levelled.levelStrip, "a 6.87.0 server's chunkLevels opens the level strip")
        check(!full.chunkLevels && !full.levelStrip && !older.levelStrip, "a 6.86.0 or older server keeps the still glyph")
        var levelsNoProtocol = levelled; levelsNoProtocol.protocolVersion = nil
        check(!levelsNoProtocol.levelStrip, "the strip needs protocol 1 too")
        let stringFlag = ServerStatus(details(#"{"ok":true,"message":"x","details":{"liveMeetingProtocol":1,"liveMeetingChunkLevels":"true"}}"#)).liveMeeting
        check(!stringFlag.levelStrip, "only a real true opens the strip")

        let levelRead = try! JSONDecoder().decode(LiveTranscriptRead.self, from: Data(#"""
        {"sessionId":"meeting_1","ended":false,"unchanged":false,"levels":[{"i":3,"level":0.71,"speechSec":3.2},{"i":4,"level":0.1,"speechSec":null},{"i":5,"level":0.4}]}
        """#.utf8))
        check(levelRead.levels == [LiveChunkLevel(i: 3, level: 0.71, speechSec: 3.2), LiveChunkLevel(i: 4, level: 0.1, speechSec: nil), LiveChunkLevel(i: 5, level: 0.4, speechSec: nil)],
              "a read carries the levels; null or absent speech seconds is nil")
        let noLevels = try! JSONDecoder().decode(LiveTranscriptRead.self, from: Data(#"{"sessionId":"meeting_1","ended":false,"unchanged":false}"#.utf8))
        check(noLevels.levels == nil, "an older server's read has no levels")

        check(LiveLevelStrip.isSilent(LiveChunkLevel(i: 0, level: 0.9, speechSec: 0.1)) && LiveLevelStrip.isSilent(LiveChunkLevel(i: 0, level: 0.9, speechSec: 0.49))
              && !LiveLevelStrip.isSilent(LiveChunkLevel(i: 0, level: 0.05, speechSec: 0.5)), "speech seconds decide: under the quiet gate's 0.5 s is dotted, whatever the level")
        check(LiveLevelStrip.isSilent(LiveChunkLevel(i: 0, level: 0.27, speechSec: nil)) && !LiveLevelStrip.isSilent(LiveChunkLevel(i: 0, level: 0.28, speechSec: nil)),
              "without speech seconds, the level at about the RMS gate decides")
        let many = (0..<50).map { LiveChunkLevel(i: $0, level: 0.5, speechSec: 2) }
        check(LiveLevelStrip.visible(many, width: 100).map(\.i) == Array(30..<50), "a narrow strip keeps the newest chunks, the oldest clipped")
        check(LiveLevelStrip.visible(many, width: 1000).count == 50 && LiveLevelStrip.visible(many, width: 4).isEmpty
              && LiveLevelStrip.visible(many, width: .nan).isEmpty && LiveLevelStrip.visible([], width: 300).isEmpty, "wide shows all; under one step or not a width shows none")
        check(LiveLevelStrip.visible(many, width: 40).count == 8, "the 40 pt floor still draws eight chunks")
        check(LiveLevelStrip.accessibilityLabel == "Audio level, a few seconds behind", "VoiceOver says the strip trails the room")
        check(LiveLevelStrip.accessibilityValue([]) == "Waiting for the first chunk" && LiveLevelStrip.accessibilityValue([LiveChunkLevel(i: 0, level: 0.6, speechSec: 3)]) == "Speech"
              && LiveLevelStrip.accessibilityValue([LiveChunkLevel(i: 0, level: 0.6, speechSec: 0)]) == "Quiet", "its value is the newest chunk")

        typealias Mode = LiveRecordingBarLayout.Mode
        let widths: [(Double, Mode)] = [(1000, Mode(addFileLabelled: true, meter: true)), (640, Mode(addFileLabelled: true, meter: true)),
                                        (600, Mode(addFileLabelled: true, meter: true)), (561, Mode(addFileLabelled: true, meter: true)),
                                        (560, Mode(addFileLabelled: true, meter: true)), (559.5, Mode(addFileLabelled: false, meter: true)),
                                        (520, Mode(addFileLabelled: false, meter: true)), (420, Mode(addFileLabelled: false, meter: true)),
                                        (360, Mode(addFileLabelled: false, meter: true)), (340, Mode(addFileLabelled: false, meter: true)),
                                        (339, Mode(addFileLabelled: false, meter: false)), (200, Mode(addFileLabelled: false, meter: false))]
        for (width, mode) in widths { check(LiveRecordingBarLayout.mode(barWidth: width) == mode, "the bar at \(width) pt, as the mock's ladder") }
        check(LiveRecordingBarLayout.meterFloor == 40 && LiveRecordingBarLayout.addFileLabel == "Add file", "the 40 pt floor; VoiceOver's Add file")

        check(LiveMeetingFiles.rowTitle(count: 2) == "Files \u{00B7} 2" && LiveMeetingFiles.rowTitle(count: 1) == "Files \u{00B7} 1", "the Files row's title")
        check(!LiveMeetingFiles.showsRow(count: 0, pendingUndo: 0) && LiveMeetingFiles.showsRow(count: 1, pendingUndo: 0)
              && LiveMeetingFiles.showsRow(count: 0, pendingUndo: 1), "no files: no row, unless an Undo is still offered")
        check(LiveMeetingFiles.dropLabel == "Drop to add to this meeting" && LiveMeetingFiles.pasteLabel == "Paste screenshot"
              && LiveMeetingFiles.chooseLabel == "Choose files\u{2026}" && LiveMeetingFiles.note.hasPrefix("On this Mac only."), "the mock's words")

        print("live meeting checks: \(passed) passed")
    }
}
