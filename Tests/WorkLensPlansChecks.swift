import Foundation

/// 0.5.333 lens plans, pure rules (compiled alone with Sources/WorkLensPlans.swift by Tests/run-work-lens-plans.sh).
@main struct WorkLensPlansChecks {
    static func check(_ ok: Bool, _ name: String) { if !ok { print("FAIL " + name); exit(1) }; passed += 1 }
    nonisolated(unsafe) static var passed = 0
    static func main() {
        let sbu = "claude:32386d7e-f751-41c5-a185-a0d731416a01"
        func round(_ assignments: [WorkLensPlans.Assignment], id: String = "lr_0123456789abcdef", question: String = "Ship it") -> WorkLensPlans.Round {
            .init(roundId: id, workID: "task:quilt:420a0114f1a9", question: question, answer: "Plan", planner: "opus", effort: "high", orchestrator: true,
                  createdAt: "2026-10-21T14:20:00.000Z", recordedAt: "2026-10-21T14:20:05.123Z", assignments: assignments)
        }
        func a(_ id: String, _ mode: String, session: String? = nil, provider: String? = nil, prompt: String = "Do it") -> WorkLensPlans.Assignment {
            .init(id: id, mode: mode, sessionID: session, provider: provider, prompt: prompt, contextItemIDs: ["req", "task"])
        }

        // The inbox decodes the server's shape; anything else is no inbox.
        let json = """
        {"v":1,"cursor":7,"available":true,"rounds":[{"roundId":"lr_0123456789abcdef","workID":"task:quilt:420a0114f1a9","clientRoundId":"lens-x","question":"Q","answer":"A","planner":"opus","effort":"high","orchestrator":true,"createdAt":"2026-10-21T14:20:00.000Z","recordedAt":"2026-10-21T14:20:05.000Z","assignments":[{"id":"a1","mode":"continue","sessionID":"\(sbu)","provider":"claude","prompt":"P","contextItemIDs":["req"]}]}],
         "sends":[{"sendRequestId":"ls_0123456789abcdef","roundId":"lr_0123456789abcdef","workID":"task:quilt:420a0114f1a9","assignmentIds":["a1"],"confirm":"two-step","confirmedAt":"2026-10-21T14:21:00.000Z","autoSend":false,"requestedAt":"x"}],
         "stops":[{"stopRequestId":"lst_0123456789abcdef","roundId":"lr_0123456789abcdef","workID":"task:quilt:420a0114f1a9","assignmentIds":["a1"],"sendRequestId":null,"requestedAt":"x"}]}
        """
        let box = WorkLensPlans.inbox(Data(json.utf8))
        check(box?.cursor == 7 && box?.rounds.first?.assignments.first?.sessionID == sbu && box?.sends.first?.confirm == "two-step" && box?.stops.first?.sendRequestId == nil, "the inbox decodes the server's shape")
        check(WorkLensPlans.inbox(Data(json.replacingOccurrences(of: "\"v\":1", with: "\"v\":2").utf8)) == nil, "another inbox version is no inbox")
        check(WorkLensPlans.inbox(Data("{}".utf8)) == nil, "an empty answer is no inbox")

        // Rounds Control may write.
        check(WorkLensPlans.valid(round([a("a1", "continue", session: sbu), a("a2", "newSession", provider: "codex"), a("a3", "fork", session: sbu)])), "Continue, New session and Fork are writable")
        check(!WorkLensPlans.valid(round([a("a2", "continue", session: sbu)])), "ids are a1..aN in answer order")
        check(!WorkLensPlans.valid(round([a("a1", "continue")])), "a Continue names its session")
        check(!WorkLensPlans.valid(round([a("a1", "newSession", provider: "cursor")])), "a New session starts on Claude or Codex only")
        check(!WorkLensPlans.valid(round([a("a1", "newSession", session: sbu, provider: "claude")])), "a New session names no session")
        check(!WorkLensPlans.valid(round([a("a1", "teleport", session: sbu)])), "an unknown mode is never written")
        check(!WorkLensPlans.valid(round((1...4).map { a("a\($0)", "continue", session: sbu) })), "at most three assignments")
        check(!WorkLensPlans.valid(round([], id: "lr_x")), "a round id is lr_ and 16 hex")
        check(!WorkLensPlans.valid(round([], question: "  ")), "a blank question is never written")
        check(WorkLensPlans.chatMode("continue") == nil && WorkLensPlans.chatMode("fork") == "fork" && WorkLensPlans.chatMode("newSession") == "newSession", "a lens Continue is a nil mode, as every Mac Continue")

        // The cursor moves only when every round of the answer is in history.
        check(WorkLensPlans.nextCursor(current: 3, answered: 7, allWritten: true) == 7, "the cursor moves past written rounds")
        check(WorkLensPlans.nextCursor(current: 3, answered: 7, allWritten: false) == 3, "a round not written is listed again")
        check(WorkLensPlans.nextCursor(current: 9, answered: 7, allWritten: true) == 9, "the cursor never moves back")

        // The per-card rule: two-step confirm, or the card's Auto-send.
        check(WorkLensPlans.maySend(confirm: "two-step", cardAutoSend: false), "a confirmed send goes")
        check(WorkLensPlans.maySend(confirm: nil, cardAutoSend: true), "Auto-send on: an unconfirmed send goes")
        check(!WorkLensPlans.maySend(confirm: nil, cardAutoSend: false), "Auto-send off and no confirm: refused")
        check(!WorkLensPlans.maySend(confirm: "one-step", cardAutoSend: false), "only the two-step confirm counts")

        // Lens states from Control's states.
        let s = { (chat: String, attempted: Bool) in WorkLensPlans.lensState(chatState: chat, attempted: attempted) }
        check(s("Queued", true) == "held", "a queued assignment is held")
        check(s("Not sent", false) == "pending" && s("Not sent", true) == "refused", "Not sent is a wait before a send and a refusal after one")
        check(s("Sending", true) == "pending", "sending is still pending")
        check(s("queued", true) == "sent" && s("running", true) == "sent", "a parked turn or a running job reached the server")
        check(s("unknown", true) == "sent" && s("No delivery receipt", true) == "sent", "an unconfirmed delivery is never offered again as unsent")
        check(["delivered", "completed", "reviewed", "Session reported done", "Needs your input", "Reply available for review"].allSatisfy { s($0, true) == "delivered" }, "a delivered assignment is delivered")
        check(s("refused", true) == "refused" && s("failed", true) == "failed", "refused and failed stay apart")
        check(s("Skipped", true) == "stopped" && s("canceled", true) == "stopped", "Stop and a canceled job are stopped")
        check(WorkLensPlans.final == ["delivered", "failed", "refused", "stopped"], "the final states")

        // Details: the reason, never the prompt; a refusal always says something.
        check(WorkLensPlans.detail(state: "refused", chatDetail: "", fallback: "Earlier handoffs need a check first") == "Earlier handoffs need a check first", "a refusal carries why")
        check(WorkLensPlans.detail(state: "refused", chatDetail: "", fallback: nil) == "COS Control did not send it.", "a refusal is never silent")
        check(WorkLensPlans.detail(state: "sent", chatDetail: String(repeating: "x", count: 300), fallback: nil)?.count == 200, "details are short")
        check(WorkLensPlans.detail(state: "delivered", chatDetail: "", fallback: "x") == nil, "delivered needs no words")
        let r = WorkLensPlans.Result(id: "a1", state: "sent", receiptId: "rcpt", detail: "", sessionID: nil).json
        check(r["id"] as? String == "a1" && r["receiptId"] as? String == "rcpt" && r["detail"] == nil && r["sessionID"] == nil, "a result leaves out what it does not know")

        // From glasses, with the time.
        let utc = TimeZone(identifier: "UTC")!, at = Date(timeIntervalSince1970: 1_792_592_400) // 2026-10-21 14:20 UTC
        check(WorkLensPlans.fromGlassesLabel(at: at, now: at.addingTimeInterval(3600), timeZone: utc) == "From glasses · 2:20 PM", "today: the time")
        check(WorkLensPlans.fromGlassesLabel(at: at, now: at.addingTimeInterval(86_400), timeZone: utc) == "From glasses · Oct 21, 2:20 PM", "another day: the date and time")
        check(abs(WorkLensPlans.roundTime(round([]), now: Date()).timeIntervalSince1970 - 1_792_592_405.123) < 0.01, "the server's recordedAt is the round's time")
        let noRecorded = WorkLensPlans.Round(roundId: "lr_0123456789abcdef", workID: "task:quilt:420a0114f1a9", question: "Q", answer: "", planner: nil, effort: nil, orchestrator: nil, createdAt: "2026-10-21T14:20:00Z", recordedAt: nil, assignments: [])
        check(WorkLensPlans.roundTime(noRecorded, now: Date()).timeIntervalSince1970 == 1_792_592_400, "else the lens's createdAt")
        print("PASS work lens plans: \(passed) checks (inbox shape, writable rounds, cursor, two-step or card Auto-send, lens states, short details, From glasses label)")
    }
}
