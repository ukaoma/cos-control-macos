import Foundation

/// 0.5.278: the live meeting transcript's pure pieces (Sources/LiveTranscript.swift) and the status fields it reads
/// (Sources/Models.swift), executed. Compiled against those two files alone by Tests/run-live-transcript.sh (lane
/// "models"). Prints "live transcript checks: N passed".
@main struct LiveTranscriptChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("live transcript check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    static func chunk(_ i: Int, _ speaker: String, _ text: String, ms: Int? = nil) -> LiveTranscriptChunk {
        LiveTranscriptChunk(i: i, elapsedMs: ms ?? i * 6000, speaker: speaker, text: text)
    }

    static func read(_ chunks: [LiveTranscriptChunk], id: String = "s1", settled: Int? = nil, stamp: String = "1.0.10",
                     start: Double? = 1_791_635_349_988, last: Double? = nil) -> LiveTranscriptRead {
        LiveTranscriptRead(sessionId: id, ended: false, unchanged: false, stamp: stamp, startTime: start, lastActivityAt: last,
                           settledThrough: settled, turns: chunks)
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_791_636_000)
        // ── The reply, through the same path the model takes: the helper's JSON, HelperResponse, details re-encoded.
        let helperJSON = #"""
        {"ok":true,"message":"Live transcript","details":{"dataDir":"/tmp/d","sessions":[{"sessionId":"s1","mtimeMs":1791635401200,"size":4096,"stamp":"1791635401.2.4096"}],
         "read":{"sessionId":"s1","ended":false,"unchanged":false,"stamp":"1791635401.2.4096","startTime":1791635349988,"lastActivityAt":1791635401200,
          "maxIndex":7,"settledThrough":5,"chunkCount":3,"turns":[{"i":0,"elapsedMs":0,"speaker":"Miles","text":"one"},
          {"i":3,"elapsedMs":18000,"speaker":"Zoë","text":"café"},{"i":7,"elapsedMs":42000,"speaker":"Unknown","text":"seven"}]}}}
        """#
        let response = try! JSONDecoder().decode(HelperResponse.self, from: Data(helperJSON.utf8))
        let reply = LiveTranscriptReply.decode(try! JSONEncoder().encode(response.details))
        check(reply?.sessions.first?.stamp == "1791635401.2.4096" && reply?.dataDir == "/tmp/d", "the reply decodes after the JSONValue round trip")
        check(reply?.read?.turns?.map(\.i) == [0, 3, 7] && reply?.read?.settledThrough == 5 && reply?.read?.turns?[1].speaker == "Zo\u{eb}",
              "chunks, the cursor and non-ASCII text survive the round trip")
        let endedJSON = #"{"ok":true,"message":"x","details":{"sessions":[],"read":{"sessionId":"s1","ended":true,"unchanged":false}}}"#
        let endedReply = LiveTranscriptReply.decode(try! JSONEncoder().encode(try! JSONDecoder().decode(HelperResponse.self, from: Data(endedJSON.utf8)).details))
        check(endedReply?.read?.ended == true && endedReply?.sessions.isEmpty == true, "an ended read decodes")
        check(LiveTranscriptReply.decode(Data("{\"sessions\":[{\"sessionId\":1}]}".utf8)) == nil, "a malformed reply is refused, not half read")

        // ── The reducer.
        var feed = LiveTranscriptFeed(sessionId: "s1")
        check(feed.apply(read([chunk(2, "Jordan", "two"), chunk(0, "Miles", "zero")], settled: 0), now: now), "a first read changes the feed")
        check(feed.turns.map(\.id) == [0, 2] && feed.turns.map(\.text) == ["zero", "two"], "chunks arriving out of order are drawn in index order")
        feed.apply(read([chunk(1, "Miles", "one")], settled: 2), now: now)
        check(feed.turns.map(\.id) == [0, 2] && feed.turns[0].text == "zero one" && feed.turns[0].lastIndex == 1,
              "a late chunk from the same speaker joins its turn, and the turn keeps its first index as id")
        feed.apply(read([chunk(0, "Miles", "zero"), chunk(1, "Miles", "one")], settled: 2), now: now)
        check(feed.chunkCount == 3 && feed.turns.count == 2 && feed.turns[0].text == "zero one", "a second copy of an index is deduped")
        feed.apply(read([chunk(1, "Miles", "one corrected")], settled: 2), now: now)
        check(feed.turns[0].text == "zero one corrected", "the newer read of an index wins (the file is the truth)")
        feed.apply(read([chunk(5, "Jordan", "five")], settled: 5), now: now)
        check(feed.turns.map(\.id) == [0, 2] && feed.turns[1].text == "two five",
              "a missing index (3, 4) is never drawn as loss: the same speaker on both sides is still one turn")
        check(!feed.turns.contains { $0.text.contains("[") || $0.text.lowercased().contains("missing") || $0.text.contains("…") },
              "no gap marker is ever written into the text")
        // A turn keeps its id when a late chunk lands BEFORE its first one (QA W3), and a split turn keeps it on its
        // first half while the second half and the late voice get new ids.
        var stable = LiveTranscriptFeed(sessionId: "s1")
        stable.apply(read([chunk(2, "Miles", "two"), chunk(3, "Miles", "three")]), now: now)
        let firstID = stable.turns.first?.id
        stable.apply(read([chunk(1, "Miles", "one")]), now: now)
        check(stable.turns.map(\.id) == [firstID!] && stable.turns[0].text == "one two three" && stable.turns[0].firstIndex == 1,
              "a late lower-index chunk joins the turn and the turn keeps its id")
        stable.apply(read([chunk(0, "Jordan", "zero")]), now: now)
        check(stable.turns.map(\.id) == [0, firstID!], "a new turn before it takes its own id; the old turn keeps its id")
        var split = LiveTranscriptFeed(sessionId: "s1")
        split.apply(read([chunk(4, "Miles", "four"), chunk(6, "Miles", "six")]), now: now)
        let splitID = split.turns[0].id
        split.apply(read([chunk(5, "Jordan", "five")]), now: now)
        check(split.turns.map(\.speaker) == ["Miles", "Jordan", "Miles"] && split.turns[0].id == splitID
              && Set(split.turns.map(\.id)).count == 3, "a turn split by a late voice keeps its id on the first half; ids stay unique")
        let secondHalf = split.turns[2].id
        split.apply(read([chunk(7, "Miles", "seven")]), now: now)
        check(split.turns.map(\.id) == [splitID, split.turns[1].id, secondHalf] && split.turns[2].text == "six seven",
              "the second half keeps its new id as it grows")
        var merged = LiveTranscriptFeed(sessionId: "s1")
        merged.apply(read([chunk(0, "Miles", "a"), chunk(1, "Jordan", "b"), chunk(2, "Miles", "c")]), now: now)
        merged.apply(read([chunk(1, "Miles", "b again")]), now: now)
        check(merged.turns.map(\.id) == [0] && merged.turns[0].text == "a b again c", "turns joined by a corrected speaker keep the first id")
        feed.apply(read([chunk(6, "", "six"), chunk(7, "Unknown", "seven"), chunk(8, "Zo\u{eb}", "eight")], settled: 4), now: now)
        check(feed.cursor == 5, "the --since cursor is never lowered by a later read")
        check(feed.turns.map(\.speaker) == ["Miles", "Jordan", "Speaker", "Zo\u{eb}"] && feed.turns[2].text == "six seven",
              "an empty and an Unknown label are both Speaker, and merge as one unknown voice")
        feed.apply(read([chunk(9, "Miles", "   ")], settled: 9), now: now)
        check(feed.turns.count == 4, "whitespace-only text never makes a turn")
        let before = feed
        check(!feed.apply(LiveTranscriptRead(sessionId: "s1", ended: false, unchanged: true, stamp: "1.0.10"), now: now) && feed == before,
              "an unchanged read changes nothing")
        check(!feed.apply(read([chunk(20, "Miles", "x")], id: "other"), now: now) && feed == before, "a read for another session is ignored")
        check(feed.startTime == Date(timeIntervalSince1970: 1_791_635_349.988), "the start time comes from the read")
        check(feed.apply(LiveTranscriptRead(sessionId: "s1", ended: true, unchanged: false), now: now) && feed.ended && feed.phase == .finalizing
              && feed.endedAt == now, "the file gone ends the feed and starts finalizing")
        check(feed.turns.count == 4, "the transcript is kept after the file is gone (Copy works while it finalizes)")
        check(!feed.apply(LiveTranscriptRead(sessionId: "s1", ended: true, unchanged: false), now: now.addingTimeInterval(9)) && feed.endedAt == now,
              "a second ended read keeps the first end time")
        feed.apply(read([chunk(10, "Miles", "back")], settled: 10), now: now)
        check(!feed.ended && feed.phase == .live && feed.turns.last?.text.hasSuffix("back") == true,
              "a file that comes back (the server restored the session) is live again")
        // 1,500 chunks: built once, merged by speaker, in order.
        var long = LiveTranscriptFeed(sessionId: "long")
        long.apply(read((0..<1500).map { chunk($0, $0 % 10 < 5 ? "Miles" : "Jordan", "w\($0)") }, id: "long", settled: 1499), now: now)
        check(long.chunkCount == 1500 && long.turns.count == 300 && long.turns.first?.id == 0 && long.turns.last?.id == 1495,
              "1,500 chunks fold into 300 turns, each keyed by its first index")
        check(Set(long.turns.map(\.id)).count == long.turns.count, "turn ids are unique")

        // ── The quiet clock follows the file too (QA N1), and never moves back.
        var quietFeed = LiveTranscriptFeed(sessionId: "q")
        quietFeed.apply(read([chunk(0, "Miles", "x")], id: "q", last: 1_791_635_000_000), now: now)
        check(quietFeed.noteFileActivity(Date(timeIntervalSince1970: 1_791_635_900)) && quietFeed.lastActivityAt == Date(timeIntervalSince1970: 1_791_635_900)
              && !quietFeed.noteFileActivity(Date(timeIntervalSince1970: 1_791_635_100)), "a newer file mtime moves the quiet clock forward, an older one does not")

        // ── The copy format (golden).
        let goldenTurns = LiveTranscriptFeed.turns(from: [
            0: chunk(0, "Miles", "Kicking off.", ms: 0),
            1: chunk(1, "Unknown", "Who is this?", ms: 65_000),
            4: chunk(4, "Zo\u{eb}", "Past the hour.", ms: 3_660_000),
        ])
        let golden = LiveTranscript.copyText(turns: goldenTurns, startTime: Date(timeIntervalSince1970: 1_791_635_349.988),
                                             timeZone: TimeZone(identifier: "America/Chicago")!)
        let expected = """
        COS preliminary transcript · 2026-10-10 7:29 AM
        [0:00:00] Miles: Kicking off.
        [0:01:05] Speaker: Who is this?
        [1:01:00] Zo\u{eb}: Past the hour.
        """
        check(golden == expected, "the copy golden: header, an unknown Speaker, and one [h:mm:ss] format once past an hour\n\(golden)")
        let shortGolden = LiveTranscript.copyText(turns: Array(goldenTurns.prefix(2)), startTime: Date(timeIntervalSince1970: 1_791_635_349.988),
                                                  timeZone: TimeZone(identifier: "America/Chicago")!)
        check(shortGolden == "COS preliminary transcript · 2026-10-10 7:29 AM\n[0:00] Miles: Kicking off.\n[1:05] Speaker: Who is this?",
              "the copy golden under an hour: [m:ss] throughout\n\(shortGolden)")
        check(LiveTranscript.copyText(turns: goldenTurns, startTime: Date(timeIntervalSince1970: 1_791_635_349.988),
                                      timeZone: TimeZone(identifier: "America/Chicago")!, twentyFourHour: true).hasPrefix("COS preliminary transcript · 2026-10-10 07:29\n"),
              "a 24-hour clock writes the header in 24 hours")
        check(LiveTranscript.copyText(turns: [], startTime: nil) == "COS preliminary transcript", "no start time: the header alone")
        check(LiveTranscript.stamp(59_999, hours: false) == "0:59" && LiveTranscript.stamp(3_599_000, hours: false) == "59:59"
              && LiveTranscript.stamp(3_600_000, hours: true) == "1:00:00" && LiveTranscript.stamp(65_000, hours: true) == "0:01:05"
              && LiveTranscript.stamp(-5, hours: false) == "0:00", "the two stamp formats")
        check(!LiveTranscript.usesHours(Array(goldenTurns.prefix(2))) && LiveTranscript.usesHours(goldenTurns), "the transcript switches at the hour")
        check(!golden.contains("\u{2014}") && !golden.contains("\u{2192}") && !LiveTranscript.header.contains("\u{2014}")
              && LiveTranscript.header == "Live transcript · preliminary · may change when saved",
              "no em dash or arrow in the copied text or the header")

        // ── Polling gate: the setting off, nobody looking, or no live meeting never polls.
        check(!LiveTranscript.shouldPoll(enabled: false, visible: true, serverLive: 2, pendingHandoff: true), "the setting off never polls")
        check(!LiveTranscript.shouldPoll(enabled: true, visible: false, serverLive: 2, pendingHandoff: true), "nobody looking never polls")
        check(!LiveTranscript.shouldPoll(enabled: true, visible: true, serverLive: 0, pendingHandoff: false)
              && !LiveTranscript.shouldPoll(enabled: true, visible: true, serverLive: nil, pendingHandoff: false), "no live meeting never polls")
        check(LiveTranscript.shouldPoll(enabled: true, visible: true, serverLive: 1, pendingHandoff: false)
              && LiveTranscript.shouldPoll(enabled: true, visible: true, serverLive: 0, pendingHandoff: true), "a live meeting, or a hand-off waiting, polls")
        let defaults = UserDefaults(suiteName: "live-transcript-checks-\(UUID().uuidString)")!
        check(LiveTranscript.enabled(defaults), "the setting is on until someone turns it off")
        defaults.set(false, forKey: LiveTranscript.enabledKey)
        check(!LiveTranscript.enabled(defaults), "the setting off reads off")

        // ── Rows: liveness is the server's.
        let files = [LiveTranscriptFileRow(sessionId: "a", mtimeMs: 1_791_635_990_000, stamp: "a"),
                     LiveTranscriptFileRow(sessionId: "stale1", mtimeMs: 1_791_634_000_000, stamp: "b"),
                     LiveTranscriptFileRow(sessionId: "strand", mtimeMs: 1_791_635_000_000, stamp: "c"),
                     LiveTranscriptFileRow(sessionId: "b", mtimeMs: 1_791_635_995_000, stamp: "d")]
        var feeds: [String: LiveTranscriptFeed] = [:]
        var fa = LiveTranscriptFeed(sessionId: "a"); fa.apply(read([chunk(0, "Miles", "x")], id: "a", start: 1_791_635_000_000), now: now); feeds["a"] = fa
        var fb = LiveTranscriptFeed(sessionId: "b"); fb.apply(read([chunk(0, "Miles", "x")], id: "b", start: 1_791_635_900_000), now: now); feeds["b"] = fb
        let rows = LiveTranscript.rows(files: files, feeds: feeds, serverLive: 2, stale: ["stale1"], stranded: ["strand"], now: now)
        check(rows.map(\.sessionId) == ["b", "a"] && rows.allSatisfy { $0.phase == .live }, "stale and stranded sessions get no row; newest start first")
        check(rows.first?.id == "live:b", "the row id is live:<sessionId>")
        check(LiveTranscript.rows(files: files, feeds: feeds, serverLive: 0, stale: [], stranded: [], now: now).isEmpty
              && LiveTranscript.rows(files: files, feeds: feeds, serverLive: nil, stale: [], stranded: [], now: now).isEmpty,
              "no row while the server reports no live session, whatever files are there")
        var fc = LiveTranscriptFeed(sessionId: "c"); fc.apply(read([chunk(0, "Miles", "x")], id: "c"), now: now); fc.markEnded(now: now); feeds["c"] = fc
        let withEnded = LiveTranscript.rows(files: files, feeds: feeds, serverLive: 0, stale: [], stranded: [], now: now)
        check(withEnded.map(\.sessionId) == ["c"] && withEnded.first?.phase == .finalizing, "a session that just ended keeps a Finalizing row")
        feeds["c"]?.phase = .saved
        check(LiveTranscript.rows(files: [], feeds: feeds, serverLive: 0, stale: [], stranded: [], now: now).isEmpty, "a saved hand-off leaves no row")
        feeds["c"]?.phase = .endedUnsaved
        check(LiveTranscript.rows(files: [], feeds: feeds, serverLive: 0, stale: [], stranded: [], now: now).first?.phase == .endedUnsaved
              && LiveTranscript.rows(files: [], feeds: feeds, serverLive: 0, stale: [], stranded: [], now: now.addingTimeInterval(601)).isEmpty,
              "Recording ended without saving stays ten minutes")
        feeds["c"]?.phase = .finalizing
        check(LiveTranscript.rows(files: [], feeds: feeds, serverLive: 0, stale: [], stranded: ["c"], now: now).isEmpty,
              "an ended session the stranded banner lists is not listed twice")
        let fresh = LiveTranscript.rows(files: [LiveTranscriptFileRow(sessionId: "n", mtimeMs: 1_791_635_999_000, stamp: "n")], feeds: [:],
                                        serverLive: 1, stale: [], stranded: [], now: now)
        check(fresh.count == 1 && fresh.first?.startTime == nil && fresh.first?.lastActivity == Date(timeIntervalSince1970: 1_791_635_999),
              "a file not read yet has a row, its quiet clock from the file's mtime")

        // ── Hand-off.
        let ended = now
        check(LiveTranscript.handoff(serverState: "saved", endedAt: ended, now: now.addingTimeInterval(5), savedRowFound: true) == .saved,
              "the saved row found opens it")
        check(LiveTranscript.handoff(serverState: "saved", endedAt: ended, now: now.addingTimeInterval(179), savedRowFound: false) == .finalizing
              && LiveTranscript.handoff(serverState: "saved", endedAt: ended, now: now.addingTimeInterval(180), savedRowFound: false) == .notFoundYet,
              "saved but no row: Finalizing until 3 minutes, then Saved meeting not found yet")
        check(LiveTranscript.handoff(serverState: "closed", endedAt: ended, now: now.addingTimeInterval(19), savedRowFound: false) == .finalizing
              && LiveTranscript.handoff(serverState: "closed", endedAt: ended, now: now.addingTimeInterval(20), savedRowFound: false) == .endedUnsaved
              && LiveTranscript.handoff(serverState: "missing", endedAt: ended, now: now.addingTimeInterval(30), savedRowFound: false) == .endedUnsaved,
              "closed or missing after a short grace: Recording ended without saving")
        check(LiveTranscript.handoff(serverState: nil, endedAt: ended, now: now.addingTimeInterval(60), savedRowFound: false) == .finalizing
              && LiveTranscript.handoff(serverState: nil, endedAt: ended, now: now.addingTimeInterval(200), savedRowFound: false) == .notFoundYet
              && LiveTranscript.handoff(serverState: "active", endedAt: ended, now: now.addingTimeInterval(60), savedRowFound: false) == .finalizing,
              "no answer, or still active, waits until the deadline")
        check(LiveTranscript.phaseLabel(.finalizing) == "Finalizing" && LiveTranscript.phaseLabel(.endedUnsaved) == "Recording ended without saving"
              && LiveTranscript.phaseLabel(.notFoundYet) == "Saved meeting not found yet" && LiveTranscript.phaseLabel(.live) == nil, "the phase words")
        check(LiveTranscript.handoffDays(start: Date(timeIntervalSince1970: 1_791_694_000), now: Date(timeIntervalSince1970: 1_791_700_000),
                                         timeZone: TimeZone(identifier: "America/Chicago")!) == ["2026-10-10", "2026-10-11"],
              "a meeting across midnight looks under both days")

        // ── Quiet and duration.
        check(LiveTranscript.quietLabel(lastActivity: now.addingTimeInterval(-119), now: now) == nil
              && LiveTranscript.quietLabel(lastActivity: now.addingTimeInterval(-120), now: now) == "No audio for 2m"
              && LiveTranscript.quietLabel(lastActivity: now.addingTimeInterval(-245), now: now) == "No audio for 4m"
              && LiveTranscript.quietLabel(lastActivity: nil, now: now) == nil, "No audio for Xm from two minutes of quiet")
        check(LiveTranscript.durationLabel(start: now.addingTimeInterval(-30), now: now) == "Just started"
              && LiveTranscript.durationLabel(start: now.addingTimeInterval(-12 * 60), now: now) == "12 min"
              && LiveTranscript.durationLabel(start: now.addingTimeInterval(-65 * 60), now: now) == "1 h 5 min"
              && LiveTranscript.durationLabel(start: now.addingTimeInterval(-120 * 60), now: now) == "2 h", "durations")
        check(LiveTranscript.durationLabel(start: now.addingTimeInterval(-40 * 60), now: now, endedAt: now.addingTimeInterval(-30 * 60)) == "10 min"
              && LiveTranscript.durationLabel(start: now.addingTimeInterval(-40 * 60), now: now, endedAt: nil) == "40 min",
              "the duration stops when the recording ended (QA W2)")
        check(LiveTranscript.rows(files: [], feeds: ["e": { var f = LiveTranscriptFeed(sessionId: "e"); f.markEnded(now: now); return f }()],
                                  serverLive: 0, stale: [], stranded: [], now: now).first?.endedAt == now, "an ended row carries its end time")
        let twoFiles = [LiveTranscriptFileRow(sessionId: "old", mtimeMs: 1_791_635_990_000, stamp: "o")]
        var staleRead = LiveTranscriptFeed(sessionId: "old"); staleRead.apply(read([chunk(0, "Miles", "x")], id: "old", last: 1_791_635_000_000), now: now)
        check(LiveTranscript.rows(files: twoFiles, feeds: ["old": staleRead], serverLive: 2, stale: [], stranded: [], now: now).first?.lastActivity
              == Date(timeIntervalSince1970: 1_791_635_990), "a row's quiet clock is the later of its last read and its file (QA N1)")

        // ── Reason codes: only [a-z0-9_] survives.
        check(LiveTranscript.reasonCode(fromMessage: "Live transcript unavailable (parse_failed)") == "parse_failed", "a refusal's code")
        check(LiveTranscript.reasonCode(fromMessage: "boom (the meeting said secret things)") == "unavailable"
              && LiveTranscript.reasonCode(fromMessage: "no code here") == "unavailable"
              && LiveTranscript.reasonCode(fromMessage: "x (UPPER)") == "unavailable", "anything else is unavailable, never text")

        // ── Speakers.
        check(LiveTranscript.displaySpeaker("  Miles ") == "Miles" && LiveTranscript.displaySpeaker("unknown") == "Speaker"
              && LiveTranscript.displaySpeaker("") == "Speaker" && LiveTranscript.displaySpeaker("Zo\u{eb}") == "Zo\u{eb}", "speaker labels")

        // ── Auto-scroll.
        var follow = LiveTranscriptFollow()
        check(follow.contentChanged(now: now), "new text scrolls while following")
        follow.bottomDisappeared(now: now.addingTimeInterval(0.2))
        check(follow.following, "the bottom leaving because the text grew is not the reader scrolling up")
        follow.bottomDisappeared(now: now.addingTimeInterval(2))
        check(!follow.following && !follow.contentChanged(now: now.addingTimeInterval(3)), "scrolled up: auto-scroll pauses")
        follow.bottomAppeared()
        check(follow.following, "scrolling back to the bottom resumes")
        follow.selectionBegan()
        check(!follow.following && !follow.contentChanged(now: now.addingTimeInterval(4)), "a selection pauses auto-scroll")
        follow.bottomAppeared()
        check(!follow.following, "reaching the bottom while text is selected does not resume")
        follow.tapped(atBottom: false)
        check(!follow.following && !follow.selecting, "a click away from the bottom clears the selection but stays put")
        let jumps = follow.jumpRequests
        follow.jumpToLive(now: now.addingTimeInterval(5))
        check(follow.following && follow.jumpRequests == jumps + 1 && follow.contentChanged(now: now.addingTimeInterval(6)), "Jump to live resumes")
        check(LiveTranscriptFollow.signature(feed.turns) != LiveTranscriptFollow.signature(Array(feed.turns.dropLast())), "the signature sees a new turn")

        // ── Status: the server's live/stale split reaches the model.
        let status = ServerStatus(["running": .bool(true), "activeTranscriptionSessions": .number(2), "liveTranscriptionSessions": .number(1),
                                   "staleTranscriptionSessionIds": .array([.string("old_one")])])
        check(status.liveTranscriptionSessions == 1 && status.staleTranscriptionSessionIds == ["old_one"] && status.activeTranscriptionSessions == 2,
              "status carries live and stale apart from the total")
        let older = ServerStatus(["running": .bool(true), "activeTranscriptionSessions": .number(1)])
        check(older.liveTranscriptionSessions == nil && older.staleTranscriptionSessionIds.isEmpty, "an older server leaves live unknown")

        print("live transcript checks: \(passed) passed")
    }
}
