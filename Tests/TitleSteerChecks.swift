import Combine
import Foundation

/// The stand-in helper being down.
struct StandDown: Error {}

/// 0.5.366: renaming a live recording (TitleSteer and TitleSteerStore in Sources/MeetingAskCore.swift, the feed's titleSteer and
/// the status line in Sources/LiveTranscript.swift, the capability in Sources/Models.swift), executed. Compiled against those
/// three files alone by Tests/run-title-steer.sh, with a stand-in for the helper: no helper binary, no server, no window.
/// Prints "title steer checks: N passed". Every failure names its behaviour, which Tests/mutate-title-steer.py matches.
@main struct TitleSteerChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("title steer check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    /// The helper's details, through the same JSON round trip the app's HelperResponse takes.
    static func details(_ json: String) -> [String: JSONValue] {
        let wrapped = #"{"ok":true,"message":"x","details":"# + json + "}"
        return try! JSONDecoder().decode(HelperResponse.self, from: Data(wrapped.utf8)).details
    }
    static func answered(_ status: Int, _ body: String = "") -> [String: JSONValue] {
        details(#"{"transport":"answered","httpStatus":"# + "\(status)" + (body.isEmpty ? "" : "," + body) + "}")
    }
    static func view(_ title: String?, _ revision: Int) -> String {
        #""sessionId":"mac_x1","title":"# + (title.map { "\"" + $0 + "\"" } ?? "null") + #","revision":"# + "\(revision)" + #","updatedAt":"2026-11-03T21:05:00.000Z""#
    }

    static let session = "mac_43879e59-3039-4f2c-9cd2-4fcc59486d71"
    static let glasses = "meeting_1792098620540_yeuti0"

    @MainActor final class Stand {
        var log: [(args: [String], stdin: Data?)] = []
        /// What a read answers, what a write answers.
        var read: HelperResponse? = HelperResponse(ok: true, message: "x", details: answered(200, view(nil, 0)))
        var write: HelperResponse? = HelperResponse(ok: true, message: "x", details: answered(200, view("Polling accuracy chat", 1)))
        var hold: Bool = false
        var released = false
        var readHold = false
        var readReleased = false
        func run(_ args: [String], _ stdin: Data?) async throws -> HelperResponse {
            log.append((args, stdin))
            let writing = args.contains("--title-stdin")
            if writing, hold { while !released { try? await Task.sleep(for: .milliseconds(5)) } }
            if !writing, readHold { while !readReleased { try? await Task.sleep(for: .milliseconds(5)) } }
            guard let answer = writing ? write : read else { throw StandDown() }
            return answer
        }
        var writes: Int { log.filter { $0.args.contains("--title-stdin") }.count }
        var reads: Int { log.count - writes }
    }

    @MainActor static func main() async {
        words()
        cleaning()
        decisions()
        calls()
        outcomes()
        feed()
        capability()
        await store()
        await storeFailures()
        await storeConcurrency()
        print("title steer checks: \(passed) passed")
    }

    // MARK: words

    static func words() {
        let lines = [TitleSteer.hint, TitleSteer.note, TitleSteer.savingLine, TitleSteer.changedLine, TitleSteer.endedLine, TitleSteer.failedLine, TitleSteer.renameLabel]
        check(TitleSteer.hint == "COS keeps your words and may sharpen them when it saves the meeting.", "the hint under the field is the approved sentence")
        check(TitleSteer.note == "Your title. COS may sharpen it when it saves.", "the note under a renamed title is the approved sentence")
        check(TitleSteer.savingLine == "Saving now. Rename it after it's saved." && TitleSteer.changedLine == "Renamed on another device."
              && TitleSteer.endedLine == "This recording has ended." && TitleSteer.failedLine == "Could not rename. Try again.", "the four error lines are the briefed words")
        check(lines.allSatisfy { line in !line.contains("\u{2014}") && !line.contains("\u{2013}") && !line.contains("\u{2192}") && !line.contains("->") },
              "no em dash, en dash or arrow in any line")
        check(Set(lines).count == lines.count, "every line is its own")
        check(TitleSteer.maxScalars == 120, "the cap is the server's 120")
    }

    // MARK: cleaning and counting

    static func cleaning() {
        check(TitleSteer.count("Polling accuracy chat") == 21 && TitleSteer.counter("Polling accuracy chat") == "21/120", "the counter reads 21/120 for the mock's title")
        let flag = "\u{1F1FA}\u{1F1F8}"
        check(flag.count == 1 && flag.unicodeScalars.count == 2, "fixture: a flag is one Character and two code points")
        check(TitleSteer.count(flag) == 2 && TitleSteer.count(String(repeating: flag, count: 60)) == 120, "the count is in code points: a flag is 2, not 1")
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        check(family.count == 1 && TitleSteer.count(family) == 4, "the server drops the zero-width joiner, so a family emoji counts as its four people")
        check(TitleSteer.count("e\u{0301}") == 1, "NFKC first: e plus a combining accent is one code point")
        check(TitleSteer.count("\u{FB01}x") == 3, "NFKC first: the fi ligature is two")
        check(TitleSteer.clean("  a\tb\n  c  ") == "a b c", "whitespace collapses and trims")
        check(TitleSteer.clean("a\u{07}b") == "a b", "a control character becomes a space")
        check(TitleSteer.clean("a\u{200B}b\u{202E}c\u{FEFF}") == "abc", "zero-width and direction marks are dropped, not spaced")
        check(TitleSteer.clean("a\u{00A0}\u{00A0}b") == "a b", "a no-break space collapses with the rest")
        check(!TitleSteer.overLimit(String(repeating: "a", count: 120)) && TitleSteer.overLimit(String(repeating: "a", count: 121)), "120 fits, 121 does not")
        check(!TitleSteer.overLimit(String(repeating: "a", count: 120) + "     "), "trailing spaces do not count: the server trims first")
        check(!TitleSteer.overLimit(String(repeating: " ", count: 10) + String(repeating: "a", count: 120)), "leading spaces do not count")
        check(!TitleSteer.overLimit(String(repeating: flag, count: 60)) && TitleSteer.overLimit(String(repeating: flag, count: 61)),
              "61 flags are 122 code points: over, though 61 Characters")
        check(TitleSteer.capped(String(repeating: "a", count: 130)).unicodeScalars.count == 120, "a title from the server is cut on a code point to 120")
        check(TitleSteer.capped("Short title") == "Short title", "a short title from the server is as it is")
    }

    // MARK: decisions

    static func decisions() {
        typealias A = TitleSteer.Availability
        func a(_ capable: Bool = true, id: String = session, feed: Bool = true, ended: Bool = false, saving: Bool = false) -> A {
            TitleSteer.availability(capable: capable, sessionId: id, hasFeed: feed, ended: ended, saving: saving)
        }
        check(a() == .open && a(id: glasses) == .open, "a Mac recording and a glasses meeting can be renamed while they record")
        check(a(false) == .hidden, "a server that does not advertise the route shows no Rename at all")
        check(a(id: "phone_abc123") == .hidden, "an iPhone microphone recording is never renamed here")
        check(a(feed: false) == .hidden, "no read of the recording yet: no Rename")
        check(a(id: "a b") == .hidden && a(id: "") == .hidden, "a session id outside the server's grammar: no Rename")
        check(a(saving: true) == .locked && a(ended: true) == .locked, "a save in progress, or a recording that has ended, shows Rename disabled")
        check(a(false, ended: true) == .hidden && a(false, saving: true) == .hidden, "locked never shows without the capability")

        typealias C = TitleSteer.Change
        check(TitleSteer.change(draft: "Polling accuracy chat", steer: nil, shown: "Mac recording 9:05 PM") == C.set("Polling accuracy chat"), "a new name is set")
        check(TitleSteer.change(draft: "  Polling   accuracy chat ", steer: nil, shown: "x") == C.set("Polling accuracy chat"), "the name is set cleaned")
        check(TitleSteer.change(draft: "Mac recording 9:05 PM", steer: nil, shown: "Mac recording 9:05 PM") == C.none, "Save on the untouched automatic title sets nothing")
        check(TitleSteer.change(draft: "Weekly sync", steer: nil, shown: "Weekly sync") == C.none, "Save on the untouched calendar title sets nothing")
        check(TitleSteer.change(draft: "Weekly sync x", steer: nil, shown: "Weekly sync") == C.set("Weekly sync x"), "a nudged calendar title is a name")
        check(TitleSteer.change(draft: "Polling accuracy chat", steer: "Polling accuracy chat", shown: "Polling accuracy chat") == C.none, "Save on the unchanged steer sends nothing")
        check(TitleSteer.change(draft: "Polling  accuracy chat", steer: "Polling accuracy chat", shown: "x") == C.none, "spacing alone is not a change")
        check(TitleSteer.change(draft: "Polling and weighting", steer: "Polling accuracy chat", shown: "Polling accuracy chat") == C.set("Polling and weighting"), "a renamed steer is set")
        check(TitleSteer.change(draft: "", steer: "Polling accuracy chat", shown: "Polling accuracy chat") == C.clear, "an emptied field clears the steer")
        check(TitleSteer.change(draft: "   ", steer: "Polling accuracy chat", shown: "x") == C.clear, "a blank field clears the steer too")
        check(TitleSteer.change(draft: "", steer: nil, shown: "Mac recording 9:05 PM") == C.none, "an emptied field with no steer has nothing to clear")
        check(TitleSteer.change(draft: "Mac recording 9:05 PM", steer: "Polling accuracy chat", shown: "Polling accuracy chat") == C.set("Mac recording 9:05 PM"),
              "with a steer set, the automatic words are a name like any other")

        check(TitleSteer.prefill(steer: "Polling accuracy chat", shown: "Mac recording 9:05 PM") == "Polling accuracy chat", "the field opens on the steer")
        check(TitleSteer.prefill(steer: nil, shown: " Mac recording 9:05 PM ") == "Mac recording 9:05 PM", "with none it opens on the title on screen")
        check(TitleSteer.prefill(steer: "  ", shown: "Weekly sync") == "Weekly sync", "a blank steer is none")
        check(TitleSteer.displayTitle(steer: "Polling accuracy chat", otherwise: "Weekly sync") == "Polling accuracy chat", "the steer is the header's title")
        check(TitleSteer.displayTitle(steer: nil, otherwise: "Weekly sync") == "Weekly sync" && TitleSteer.displayTitle(steer: "   ", otherwise: "Weekly sync") == "Weekly sync",
              "with none the header is what it was")

        var chicago = Calendar(identifier: .gregorian); chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        let at = chicago.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 21, minute: 5))!
        let zone = TimeZone(identifier: "America/Chicago")!
        check(TitleSteer.startedClock(at, clock: .twelveHour, timeZone: zone) == "9:05 PM" && TitleSteer.startedClock(at, clock: .twentyFourHour, timeZone: zone) == "21:05",
              "the start reads 9:05 PM, or 21:05 on a 24-hour clock")
        check(LiveTranscript.switcherLabel(session, start: at, steer: "Polling accuracy chat", timeZone: zone) == "Polling accuracy chat", "the switcher uses the steer")
        check(LiveTranscript.switcherLabel(session, start: at, steer: nil, timeZone: zone) == "Mac recording 9:05 PM"
              && LiveTranscript.switcherLabel(glasses, start: at, steer: " ", timeZone: zone) == "Glasses meeting 9:05 PM", "with none the switcher is as it was")
        check(LiveMeeting.statusLine(sessionId: session, ended: false, kinds: nil, started: "9:05 PM") == "Recording on this Mac \u{00B7} started 9:05 PM", "a renamed Mac recording: the start joins the source")
        check(LiveMeeting.statusLine(sessionId: glasses, ended: false, kinds: nil, started: "9:05 PM") == "Recording on the glasses \u{00B7} started 9:05 PM", "a renamed glasses meeting says glasses")
        check(LiveMeeting.statusLine(sessionId: session, ended: false, kinds: ["decision", "decision", "promise"], started: "21:05")
              == "Recording on this Mac \u{00B7} started 21:05 \u{00B7} 2 decisions and 1 promise so far", "the start sits between the source and the counts")
        check(LiveMeeting.statusLine(sessionId: session, ended: false, kinds: nil) == "Recording on this Mac"
              && LiveMeeting.statusLine(sessionId: glasses, ended: false, kinds: []) == "Recording on the glasses", "no steer: the line is as it was")
        check(LiveMeeting.statusLine(sessionId: session, ended: true, kinds: ["promise"], started: "9:05 PM") == "1 promise"
              && LiveMeeting.statusLine(sessionId: session, ended: true, kinds: nil, started: "9:05 PM") == nil, "an ended recording shows its counts alone, the start or not")
        check(LiveMeeting.statusLine(sessionId: "phone_abc123", ended: false, kinds: nil, started: "9:05 PM") == "Recording on iPhone microphone", "an iPhone line never takes a start")
    }

    // MARK: the helper's calls

    static func calls() {
        check(TitleSteer.readCall(session: session) == ["meeting-title-steer", "--session", session], "a read is the verb and the session")
        check(TitleSteer.readCall(session: "a b") == nil && TitleSteer.readCall(session: "x") == nil && TitleSteer.readCall(session: "x&y=1") == nil, "a session outside the grammar makes no call")
        let secret = "Quarterly numbers with Acme"
        let write = TitleSteer.writeCall(session: session, title: secret, expectedRevision: 3)
        check(write?.arguments == ["meeting-title-steer", "--session", session, "--revision", "3", "--title-stdin"], "a write names the session and the revision and asks for stdin")
        check(write?.arguments.contains { $0.contains("Acme") } == false, "the title is never in the arguments")
        check((try? JSONSerialization.jsonObject(with: write?.stdin ?? Data())) as? [String: String] == ["title": secret], "the title goes on stdin as {title}")
        let clear = TitleSteer.writeCall(session: session, title: "", expectedRevision: 0)
        check((try? JSONSerialization.jsonObject(with: clear?.stdin ?? Data())) as? [String: String] == ["title": ""], "clearing sends an empty title")
        check(TitleSteer.writeCall(session: "a b", title: "x", expectedRevision: 0) == nil && TitleSteer.writeCall(session: session, title: "x", expectedRevision: -1) == nil,
              "a bad session or a negative revision makes no call")
        let quoted = TitleSteer.writeCall(session: session, title: "He said \"hi\" \\ there", expectedRevision: 1)
        check((try? JSONSerialization.jsonObject(with: quoted?.stdin ?? Data())) as? [String: String] == ["title": "He said \"hi\" \\ there"], "quotes and backslashes survive the JSON")
    }

    // MARK: the server's answers

    static func outcomes() {
        typealias O = TitleSteer.Outcome
        typealias S = TitleSteer.Snapshot
        let saved = TitleSteer.writeOutcome(answered(200, view("Polling accuracy chat", 4)))
        check(saved == O.saved(S(title: "Polling accuracy chat", revision: 4, updatedAt: "2026-11-03T21:05:00.000Z")), "a 200 is the stored title and the new revision")
        check(TitleSteer.writeOutcome(answered(200, view(nil, 5))) == O.saved(S(title: nil, revision: 5, updatedAt: "2026-11-03T21:05:00.000Z")), "a cleared steer is a save with no title")
        check(TitleSteer.writeOutcome(answered(200, #""sessionId":"x","title":"A","revision":-1"#)) == .failed, "a negative revision is not a view")
        check(TitleSteer.writeOutcome(answered(200, #""sessionId":"x","title":"A""#)) == .failed, "a 200 without a revision is not a save")
        check(TitleSteer.writeOutcome(answered(200, #""sessionId":"x","title":7,"revision":1"#)) == .failed, "a title that is not text is not a view")
        check(TitleSteer.writeOutcome(answered(200, #""sessionId":"x","revision":1"#)) == .failed, "a view with no title key is not a view")
        check(TitleSteer.writeOutcome(details(#"{"httpStatus":200,"sessionId":"x","title":"A","revision":1}"#)) == .failed, "no transport is no answer")
        let changed = TitleSteer.writeOutcome(answered(409, #""error":"title_changed","current":{"#.appending(view("Renamed on the phone", 7)).appending("}")))
        check(changed == O.changed(S(title: "Renamed on the phone", revision: 7, updatedAt: "2026-11-03T21:05:00.000Z")), "409 title_changed carries the server's current view")
        check(TitleSteer.writeOutcome(answered(409, #""error":"title_changed""#)) == O.changed(nil), "409 title_changed without a view is still a change")
        check(TitleSteer.writeOutcome(answered(409, #""error":"save_in_progress""#)) == .saving, "409 save_in_progress")
        check(TitleSteer.writeOutcome(answered(409)) == .failed && TitleSteer.writeOutcome(answered(409, #""error":"other_thing""#)) == .failed, "a 409 with another code is a failure")
        check(TitleSteer.writeOutcome(answered(404, #""error":"session_not_live""#)) == .ended, "404 session_not_live: this recording has ended")
        check(TitleSteer.writeOutcome(answered(404)) == .failed, "a 404 with no code is an older server, not an ended recording")
        check(TitleSteer.writeOutcome(details(#"{"transport":"unsupported","httpStatus":404}"#)) == .failed, "unsupported is a failure")
        check(TitleSteer.writeOutcome(answered(400, #""error":"invalid_title""#)) == .failed && TitleSteer.writeOutcome(answered(503, #""error":"steer_persistence_failed""#)) == .failed
              && TitleSteer.writeOutcome(answered(500)) == .failed, "400, 503 and 500 are failures")
        check(TitleSteer.writeOutcome(details(#"{"transport":"unavailable"}"#)) == .failed && TitleSteer.writeOutcome(details(#"{"transport":"no_token"}"#)) == .failed
              && TitleSteer.writeOutcome(nil) == .failed, "no server, no token and no answer are failures")
        let long = TitleSteer.writeOutcome(answered(200, #""sessionId":"x","title":"# + "\"" + String(repeating: "a", count: 130) + "\"" + #","revision":2"#))
        if case .saved(let view) = long { check(view.title?.unicodeScalars.count == 120, "a title the server returns over the cap is cut to it") } else { check(false, "a long title from the server still reads") }

        check(TitleSteer.readSnapshot(answered(200, view("A", 2))) == S(title: "A", revision: 2, updatedAt: "2026-11-03T21:05:00.000Z"), "a read is the view")
        check(TitleSteer.readSnapshot(answered(404)) == nil && TitleSteer.readSnapshot(details(#"{"transport":"unavailable"}"#)) == nil && TitleSteer.readSnapshot(nil) == nil, "a read that did not answer 200 has no view")
        check(TitleSteer.line(.saved(S(title: nil, revision: 1, updatedAt: nil))) == nil, "a save has no line")
        check(TitleSteer.line(.changed(nil)) == "Renamed on another device." && TitleSteer.line(.saving) == "Saving now. Rename it after it's saved."
              && TitleSteer.line(.ended) == "This recording has ended." && TitleSteer.line(.failed) == "Could not rename. Try again.", "each outcome has its line")
    }

    // MARK: the live feed

    static func feed() {
        func read(_ steer: String?, unchanged: Bool = false, id: String = session) -> LiveTranscriptRead {
            LiveTranscriptRead(sessionId: id, ended: false, unchanged: unchanged, stamp: "1", startTime: 1_792_400_400_000, lastActivityAt: nil,
                               settledThrough: nil, turns: unchanged ? nil : [], titleSteer: steer)
        }
        let now = Date(timeIntervalSince1970: 1_792_400_500)
        var live = LiveTranscriptFeed(sessionId: session)
        check(live.titleSteer == nil, "a new feed has no steer")
        check(live.apply(read("Polling accuracy chat"), now: now) && live.titleSteer == "Polling accuracy chat", "a read with a steer sets it, and the pane redraws")
        check(live.apply(read("Polling accuracy chat"), now: now) == false && live.titleSteer == "Polling accuracy chat", "the same steer again changes nothing")
        check(live.apply(read(nil, unchanged: true), now: now) == false && live.titleSteer == "Polling accuracy chat", "an unchanged read keeps the steer")
        check(live.apply(read("Renamed on the phone"), now: now) && live.titleSteer == "Renamed on the phone", "a read with another steer replaces it")
        check(live.apply(read(nil), now: now) && live.titleSteer == nil, "a full read with none clears it")
        _ = live.apply(read("  Spaced \u{200B} out  "), now: now)
        check(live.titleSteer == "Spaced out", "a steer from the file is cleaned")
        _ = live.apply(read("   "), now: now)
        check(live.titleSteer == nil, "a blank steer is none")
        let other = LiveTranscriptRead(sessionId: glasses, ended: false, unchanged: false, stamp: "1", titleSteer: "Not mine")
        check(live.apply(other, now: now) == false && live.titleSteer == nil, "another session's read never lands here")
        // The wire: the helper's JSON decodes into the read.
        let wire = Data(#"{"sessionId":"\#(session)","ended":false,"unchanged":false,"stamp":"2","turns":[],"titleSteer":"From the file"}"#.utf8)
        check((try? JSONDecoder().decode(LiveTranscriptRead.self, from: wire))?.titleSteer == "From the file", "the helper's titleSteer key decodes")
        let bare = Data(#"{"sessionId":"\#(session)","ended":false,"unchanged":false,"stamp":"2","turns":[]}"#.utf8)
        check((try? JSONDecoder().decode(LiveTranscriptRead.self, from: bare))?.titleSteer == nil, "a read from an older helper has none")
    }

    // MARK: capability

    static func capability() {
        check(LiveMeetingCapability(statusDetails: details(#"{"meetingTitleSteer":true}"#)).titleSteer, "the helper's meetingTitleSteer key opens Rename")
        check(!LiveMeetingCapability(statusDetails: details("{}")).titleSteer && !LiveMeetingCapability().titleSteer, "an older server does not")
        check(!LiveMeetingCapability(statusDetails: details(#"{"meetingTitleSteer":"true"}"#)).titleSteer && !LiveMeetingCapability(statusDetails: details(#"{"meetingTitleSteer":1}"#)).titleSteer
              && !LiveMeetingCapability(statusDetails: details(#"{"meetingTitleSteer":false}"#)).titleSteer, "only a real true counts")
        check(LiveMeetingCapability(statusDetails: details(#"{"meetingTitleSteer":true}"#)).available == false, "the capability stands alone: it is not the 6.86.0 live surface")
    }

    // MARK: the store

    /// What apply wrote, in order.
    @MainActor final class Applied { var rows: [(String, String?)] = []; func put(_ s: String, _ t: String?) { rows.append((s, t)) } }

    @MainActor static func store() async {
        let stand = Stand()
        let applied = Applied()
        let store = TitleSteerStore()
        check(store.editing == nil && !store.busy && store.message == nil && !store.escape(), "a new store is idle and Escape is not its to take")
        store.begin(session: session, steer: nil, shown: "Mac recording 9:05 PM", run: stand.run)
        check(store.editing == session && store.initialDraft == "Mac recording 9:05 PM", "begin opens the field on the title on screen")
        while stand.log.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        check(stand.log[0].args == ["meeting-title-steer", "--session", session], "begin reads the server's revision in the background")
        await store.save(draft: "Polling accuracy chat", run: stand.run, apply: applied.put)
        check(stand.writes == 1 && stand.log.last?.args == ["meeting-title-steer", "--session", session, "--revision", "0", "--title-stdin"], "Save writes once, with the revision it read")
        check(stand.reads == 1, "Save did not read again: the revision from begin was used")
        check((try? JSONSerialization.jsonObject(with: stand.log.last?.stdin ?? Data())) as? [String: String] == ["title": "Polling accuracy chat"], "the title went on stdin")
        check(applied.rows.count == 1 && applied.rows[0].0 == session && applied.rows[0].1 == "Polling accuracy chat", "the server's answer is written into the feed")
        check(store.editing == nil && !store.busy && store.message == nil && store.initialDraft == "", "a saved rename closes the field and says nothing")

        // The next rename begins from the steer, and sends the revision the server holds.
        stand.read = HelperResponse(ok: true, message: "x", details: answered(200, view("Polling accuracy chat", 1)))
        stand.write = HelperResponse(ok: true, message: "x", details: answered(200, view("Polling and weighting", 2)))
        store.begin(session: session, steer: "Polling accuracy chat", shown: "Polling accuracy chat", run: stand.run)
        check(store.initialDraft == "Polling accuracy chat", "a renamed recording's field opens on the steer")
        await store.save(draft: "Polling and weighting", run: stand.run, apply: applied.put)
        check(stand.log.last?.args == ["meeting-title-steer", "--session", session, "--revision", "1", "--title-stdin"] && applied.rows.last?.1 == "Polling and weighting", "the second rename sends revision 1 and lands")

        // Unchanged text sends nothing.
        let before = stand.writes
        store.begin(session: session, steer: "Polling and weighting", shown: "Polling and weighting", run: stand.run)
        await store.save(draft: "Polling and weighting", run: stand.run, apply: applied.put)
        check(stand.writes == before && store.editing == nil, "Save on the unchanged name sends nothing and closes")

        // Clearing sends an empty title and the cleared steer is applied.
        stand.read = HelperResponse(ok: true, message: "x", details: answered(200, view("Polling and weighting", 2)))
        stand.write = HelperResponse(ok: true, message: "x", details: answered(200, view(nil, 3)))
        store.begin(session: session, steer: "Polling and weighting", shown: "Polling and weighting", run: stand.run)
        await store.save(draft: "", run: stand.run, apply: applied.put)
        check((try? JSONSerialization.jsonObject(with: stand.log.last?.stdin ?? Data())) as? [String: String] == ["title": ""], "an emptied field sends an empty title")
        check(applied.rows.last?.0 == session && applied.rows.last?.1 == nil, "a cleared steer is written into the feed as none")

        // Over the cap: nothing leaves.
        let writes = stand.writes
        store.begin(session: session, steer: nil, shown: "Mac recording 9:05 PM", run: stand.run)
        await store.save(draft: String(repeating: "a", count: 121), run: stand.run, apply: applied.put)
        check(stand.writes == writes && store.editing == session, "121 code points are never sent, and the field stays open")
        check(applied.rows.count == 3, "nothing was applied for it")

        // Cancel and Escape.
        store.cancel()
        check(store.editing == nil && store.message == nil, "Cancel closes the field")
        store.begin(session: glasses, steer: nil, shown: "Glasses meeting 8:40 PM", run: stand.run)
        check(store.escape() && store.editing == nil, "Escape with the field open closes it and is taken")
        check(!store.escape(), "Escape with no field open is not taken")
        store.begin(session: session, steer: nil, shown: "x", run: stand.run)
        store.sessionChanged(to: session)
        check(store.editing == session, "the same session keeps its field")
        store.sessionChanged(to: glasses)
        check(store.editing == nil, "the pane moving to another recording closes the field")
        store.begin(session: "a b", steer: nil, shown: "x", run: stand.run)
        check(store.editing == nil, "a session outside the grammar opens nothing")
    }

    @MainActor static func storeFailures() async {
        let applied = Applied()
        func fresh(_ stand: Stand, steer: String? = nil, shown: String = "Mac recording 9:05 PM", id: String = session) -> TitleSteerStore {
            let store = TitleSteerStore()
            store.messageSeconds = 0.15
            store.begin(session: id, steer: steer, shown: shown, run: stand.run)
            return store
        }

        // Another device renamed it first (409 title_changed): theirs is adopted, and the line says so.
        let stand = Stand()
        stand.write = HelperResponse(ok: true, message: "x", details: answered(409, #""error":"title_changed","current":{"#.appending(view("Renamed on the phone", 7)).appending("}")))
        var store = fresh(stand)
        await store.save(draft: "Polling accuracy chat", run: stand.run, apply: applied.put)
        check(applied.rows.last?.1 == "Renamed on the phone" && store.message == "Renamed on another device." && store.messageSession == session && store.editing == nil,
              "409 title_changed adopts the server's current title, says so, and closes the field")
        try? await Task.sleep(for: .milliseconds(400))
        check(store.message == nil && store.messageSession == nil, "the line goes by itself")

        // The edit began on a name the server no longer holds: no write at all.
        let moved = Stand()
        moved.read = HelperResponse(ok: true, message: "x", details: answered(200, view("Renamed on the phone", 4)))
        store = fresh(moved, steer: "Polling accuracy chat")
        let movedApplied = Applied()
        await store.save(draft: "Polling and weighting", run: moved.run, apply: movedApplied.put)
        check(moved.writes == 0 && movedApplied.rows.last?.1 == "Renamed on the phone" && store.message == "Renamed on another device.", "a name that moved since the edit began is adopted without a write")

        // The recording is saving (409 save_in_progress): the field stays, with the line.
        let saving = Stand()
        saving.write = HelperResponse(ok: true, message: "x", details: answered(409, #""error":"save_in_progress""#))
        store = fresh(saving)
        let savingApplied = Applied()
        await store.save(draft: "Polling accuracy chat", run: saving.run, apply: savingApplied.put)
        check(store.message == "Saving now. Rename it after it's saved." && store.editing == session && !store.busy && savingApplied.rows.isEmpty, "save_in_progress keeps the field, says so, and applies nothing")

        // The recording has ended (404): the field closes.
        let ended = Stand()
        ended.write = HelperResponse(ok: true, message: "x", details: answered(404, #""error":"session_not_live""#))
        store = fresh(ended)
        await store.save(draft: "Polling accuracy chat", run: ended.run, apply: Applied().put)
        check(store.message == "This recording has ended." && store.editing == nil, "404 session_not_live: this recording has ended, the field closes")

        // Anything else: the generic line, the field stays so the text is not lost, and Save works again.
        let down = Stand()
        down.write = HelperResponse(ok: true, message: "x", details: details(#"{"transport":"unavailable"}"#))
        store = fresh(down)
        await store.save(draft: "Polling accuracy chat", run: down.run, apply: Applied().put)
        check(store.message == "Could not rename. Try again." && store.editing == session && !store.busy, "an unreachable server: the generic line, the field stays, nothing is stuck")
        down.write = HelperResponse(ok: true, message: "x", details: answered(200, view("Polling accuracy chat", 1)))
        let retryApplied = Applied()
        await store.save(draft: "Polling accuracy chat", run: down.run, apply: retryApplied.put)
        check(retryApplied.rows.last?.1 == "Polling accuracy chat" && store.editing == nil && store.message == nil, "Try again works, and the line is gone")

        // A newer line is not cleared by the older line's timer.
        let twice = Stand()
        twice.write = HelperResponse(ok: true, message: "x", details: details(#"{"transport":"unavailable"}"#))
        let twiceStore = fresh(twice)
        twiceStore.messageSeconds = 0.4
        await twiceStore.save(draft: "Polling accuracy chat", run: twice.run, apply: Applied().put)
        try? await Task.sleep(for: .milliseconds(250))
        await twiceStore.save(draft: "Polling accuracy chat", run: twice.run, apply: Applied().put)
        try? await Task.sleep(for: .milliseconds(250))
        check(twiceStore.message == "Could not rename. Try again.", "the first line's timer fired at 400 ms and left the newer line alone")
        try? await Task.sleep(for: .milliseconds(500))
        check(twiceStore.message == nil, "the newer line goes at its own time")

        // A helper that throws.
        let broken = Stand()
        broken.write = nil
        store = fresh(broken)
        await store.save(draft: "Polling accuracy chat", run: broken.run, apply: Applied().put)
        check(store.message == "Could not rename. Try again." && store.editing == session && !store.busy, "a helper that throws on the write: the generic line")

        // The read never answers: Save reads again, and fails closed.
        let noRead = Stand()
        noRead.read = nil
        store = fresh(noRead)
        await store.save(draft: "Polling accuracy chat", run: noRead.run, apply: Applied().put)
        check(noRead.writes == 0 && store.message == "Could not rename. Try again." && store.editing == session, "no revision: nothing is written, and the line says so")
        check(noRead.reads >= 2, "Save asked for the revision again")

        // 400 invalid_title is the generic line (the cap is enforced before it can happen).
        let invalid = Stand()
        invalid.write = HelperResponse(ok: true, message: "x", details: answered(400, #""error":"invalid_title""#))
        store = fresh(invalid)
        await store.save(draft: "Polling accuracy chat", run: invalid.run, apply: Applied().put)
        check(store.message == "Could not rename. Try again.", "400 is the generic line")

        // The message belongs to the edit that made it: the next edit's start clears it.
        check(store.message == "Could not rename. Try again.", "fixture: the last failure left its line")
        store.begin(session: session, steer: nil, shown: "x", run: invalid.run)
        check(store.message == nil && store.messageSession == nil, "beginning an edit clears the last line")

        // The title never reaches the arguments of any call.
        let calls = Stand()
        store = fresh(calls)
        await store.save(draft: "Acme quarterly numbers", run: calls.run, apply: Applied().put)
        check(calls.log.allSatisfy { !$0.args.joined(separator: " ").contains("Acme") }, "no call carries the title in its arguments")
    }

    @MainActor static func storeConcurrency() async {
        // One rename at a time: a second Save while the first is out sends nothing, and Cancel, Escape and begin wait.
        let stand = Stand()
        stand.hold = true
        let store = TitleSteerStore()
        let applied = Applied()
        store.begin(session: session, steer: nil, shown: "Mac recording 9:05 PM", run: stand.run)
        let first = Task { await store.save(draft: "Polling accuracy chat", run: stand.run, apply: applied.put) }
        while stand.writes == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        check(store.busy, "the store is busy while a rename is out")
        // Not awaited: with no single-flight guard this call would wait on the same latch and the check could never run.
        let second = Task { await store.save(draft: "Something else", run: stand.run, apply: applied.put) }
        try? await Task.sleep(for: .milliseconds(200))
        check(stand.writes == 1, "a second Save while one is out sends nothing")
        store.cancel()
        check(store.editing == session && store.busy, "Cancel waits while a rename is out")
        check(store.escape() && store.editing == session, "Escape is taken but does not close the field while a rename is out")
        store.begin(session: glasses, steer: nil, shown: "x", run: stand.run)
        check(store.editing == session, "begin waits while a rename is out")
        store.sessionChanged(to: glasses)
        check(store.editing == session, "moving to another recording does not drop a rename that is out")
        stand.released = true
        await first.value
        await second.value
        check(!store.busy && store.editing == nil && applied.rows.count == 1 && applied.rows[0].0 == session, "the rename that was out lands in its own recording, once")

        // The revision read is still out when Save is pressed: Save waits for it, and uses it.
        let slow = Stand()
        slow.readHold = true
        slow.read = HelperResponse(ok: true, message: "x", details: answered(200, view(nil, 9)))
        let slowStore = TitleSteerStore()
        slowStore.begin(session: session, steer: nil, shown: "Mac recording 9:05 PM", run: slow.run)
        let slowApplied = Applied()
        let saving = Task { await slowStore.save(draft: "Polling accuracy chat", run: slow.run, apply: slowApplied.put) }
        try? await Task.sleep(for: .milliseconds(100))
        check(slow.writes == 0 && slowStore.busy, "Save waits for the revision read")
        slow.readReleased = true
        await saving.value
        check(slow.log.last?.args == ["meeting-title-steer", "--session", session, "--revision", "9", "--title-stdin"] && slow.reads == 1, "Save used the revision the read returned, without reading again")
        check(slowApplied.rows.last?.1 == "Polling accuracy chat", "and the rename landed")
    }
}
