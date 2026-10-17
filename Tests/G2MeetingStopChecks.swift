import Foundation

/// 0.5.321: Stop and save a glasses meeting from COS Control (G2MeetingStop in Sources/LiveTranscript.swift), executed. Compiled against
/// LiveTranscript.swift (where G2MeetingStop lives) and Models.swift alone by Tests/run-g2-meeting-stop.sh. Prints "g2 meeting stop checks: N passed".
@main struct G2MeetingStopChecks {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("g2 meeting stop check FAILED: \(what)"); exit(1) }
        passed += 1
    }

    /// The helper's details, through the same JSON round trip the model's HelperResponse takes.
    static func details(_ json: String) -> [String: JSONValue] {
        let wrapped = #"{"ok":true,"message":"x","details":"# + json + "}"
        return try! JSONDecoder().decode(HelperResponse.self, from: Data(wrapped.utf8)).details
    }
    static func answered(_ status: Int, _ body: String) -> [String: JSONValue] {
        details(#"{"transport":"answered","httpStatus":"# + "\(status)" + #","body":"# + body + "}")
    }
    static let unavailable = details(#"{"transport":"unavailable"}"#)

    static func main() {
        typealias P = G2MeetingStop.Phase
        // ── The request.
        let asked = G2MeetingStop.afterRequest(answered(202, #"{"sessionId":"g2_a","requestId":"stop_1","state":"pending","claimWindowMs":10000}"#))
        check(asked.phase == .asking && asked.requestId == "stop_1" && asked.claimWindowSeconds == 10, "202 asks and follows the request")
        check(G2MeetingStop.afterRequest(answered(202, #"{"state":"pending"}"#)).phase == .serverTooOld, "202 without a request id is not one to follow")
        check(G2MeetingStop.afterRequest(nil).phase == .serverUnreachable, "a helper that failed says the server is unreachable")
        check(G2MeetingStop.afterRequest(unavailable).phase == .serverUnreachable, "nothing answered: server unreachable")
        check(G2MeetingStop.afterRequest(answered(409, #"{"reason":"not_live","state":"closed"}"#)).phase == .alreadyStopped, "409 not_live: already stopped")
        check(G2MeetingStop.afterRequest(answered(401, "{}")).phase == .unauthorized && G2MeetingStop.afterRequest(answered(403, "{}")).phase == .unauthorized,
              "401 and 403 ask to reconnect")
        check(G2MeetingStop.afterRequest(answered(404, #"{"error":"Not found"}"#)).phase == .serverTooOld, "a server without the route says update")
        check(G2MeetingStop.afterRequest(answered(500, "{}")).phase == .failed(status: 500), "anything else names its status")
        let savedNow = G2MeetingStop.afterRequest(answered(200, #"{"state":"saved","saveReceipt":{"filename":"2026-10-17_G2_Recording_x.md","durationMin":12}}"#))
        check(savedNow.phase == .saved(filename: "2026-10-17_G2_Recording_x.md", minutes: 12) && savedNow.requestId == nil, "already saved answers saved, nothing to follow")
        check(G2MeetingStop.afterRequest(answered(200, #"{"state":"finalizing"}"#)).phase == .stillSaving, "already saving ends on that line")
        check(!G2MeetingStop.afterRequest(answered(409, #"{"reason":"not_live"}"#)).phase.isActive, "a refusal stops the poll")

        // ── The poll, with a 10 s window and the 3 s grace.
        func poll(_ d: [String: JSONValue]?, _ elapsed: TimeInterval, claimed: Bool = false) -> P {
            G2MeetingStop.afterPoll(d, elapsed: elapsed, claimWindowSeconds: 10, claimed: claimed)
        }
        check(G2MeetingStop.claimGraceSeconds == 3, "Control waits 3 s past the server's window")
        check(poll(answered(200, #"{"state":"pending"}"#), 12.9) == .asking, "pending inside window plus grace keeps asking")
        check(poll(answered(200, #"{"state":"pending"}"#), 13.1) == .notConnected, "pending past window plus grace: glasses not connected")
        check(poll(answered(200, #"{"state":"expired"}"#), 11) == .notConnected, "expired: glasses not connected")
        check(poll(answered(200, #"{"state":"claimed"}"#), 2) == .stopping, "claimed: the glasses are stopping")
        check(poll(answered(200, #"{"state":"claimed","finalizing":true}"#), 4, claimed: true) == .finalizing, "claimed and the server saving: saving")
        check(poll(answered(200, #"{"state":"claimed"}"#), 181, claimed: true) == .stillSaving, "claimed past the save wait: still saving")
        check(poll(answered(200, #"{"state":"saved","saveReceipt":{"filename":"m.md","durationMin":3}}"#), 9, claimed: true) == .saved(filename: "m.md", minutes: 3),
              "saved carries the receipt")
        check(poll(answered(200, #"{"state":"refused","refusal":"not_recording"}"#), 1) == .notRecordingHere, "not recording here")
        check(poll(answered(200, #"{"state":"refused","refusal":"other_session"}"#), 1) == .otherMeeting, "another meeting")
        check(poll(answered(200, #"{"state":"refused","refusal":"stop_in_progress"}"#), 1) == .finalizing, "the glasses' own Stop: follow it")
        check(poll(unavailable, 5) == .asking && poll(unavailable, 14) == .serverUnreachable, "an unreachable server before a claim never reads as stopping")
        check(poll(unavailable, 30, claimed: true) == .stopping, "after a claim, a lost poll keeps saying stopping")
        check(poll(answered(404, #"{"reason":"unknown_request"}"#), 3) == .serverRestarted, "a lost request before a claim: restarted, nothing stopped")
        check(poll(answered(404, "{}"), 3, claimed: true) == .stillSaving, "a lost request after a claim: still saving")
        check(poll(answered(401, "{}"), 3) == .unauthorized, "401 mid-poll asks to reconnect")
        check(poll(answered(500, "{}"), 5) == .asking && poll(answered(500, "{}"), 14) == .failed(status: 500), "a 5xx waits out the window, then names itself")

        // ── Words.
        let all: [P] = [.asking, .stopping, .finalizing, .saved(filename: "a.md", minutes: 2), .saved(filename: nil, minutes: nil), .notConnected,
                        .notRecordingHere, .otherMeeting, .alreadyStopped, .serverUnreachable, .serverTooOld, .unauthorized, .stillSaving,
                        .serverRestarted, .failed(status: 502)]
        for phase in all {
            let line = phase.line
            check(!line.isEmpty && !line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains("->"), "no em dash or arrow: \(line)")
        }
        check(P.notConnected.line == "Glasses not connected. Nothing was stopped. Stop it on the glasses (hold menu, Stop Meeting) or on the phone.",
              "the not-connected line says nothing stopped and where to stop it")
        check(P.serverUnreachable.line == "COS server unreachable. Nothing was stopped.", "server unreachable words")
        check(P.alreadyStopped.line == "This meeting already stopped.", "already stopped words")
        check(P.finalizing.line == "Saving the meeting…" && P.stopping.line == "The glasses are stopping. Saving the meeting…", "saving words")
        check(P.saved(filename: "2026-10-17_G2_Recording_x.md", minutes: 12).line == "Saved: 2026-10-17_G2_Recording_x, 12 min.", "saved names the meeting and its length")
        check(P.unauthorized.line.contains("Nothing was stopped") && P.serverRestarted.line.contains("Nothing was stopped")
              && P.failed(status: 500).line.contains("Nothing was stopped") && P.notRecordingHere.line.contains("Nothing was stopped")
              && P.otherMeeting.line.contains("Nothing was stopped"), "every refusal says nothing was stopped")
        check(all.filter(\.nothingStopped).allSatisfy { !$0.isActive } && P.asking.isActive && P.stopping.isActive && P.finalizing.isActive,
              "only asking, stopping and saving keep polling")
        check(G2MeetingStop.confirmTitle == "Stop and save this glasses meeting?" && G2MeetingStop.confirmAction == "Stop and save", "the confirmation's words")

        // ── Which sessions.
        check(G2MeetingStop.isGlassesSession("meeting_1791635349988_fx67ab"), "a glasses session id")
        check(!G2MeetingStop.isGlassesSession("mac_0123abcd-0123-4abc-8def-0123456789ab"), "a Mac recording is never asked about")
        check(!G2MeetingStop.isGlassesSession("a b") && !G2MeetingStop.isGlassesSession("../x") && !G2MeetingStop.isGlassesSession(""), "a bad id is refused")

        print("g2 meeting stop checks: \(passed) passed")
    }
}
