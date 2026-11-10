import AppKit
import Foundation

/// 0.5.389 (D4): a Claude session whose turn ended with the app's next-step box, against X1's CONTRACT v1
/// (COORD 07:18): row `agent_state` waiting, `waiting_kind` question, `waiting_detail` the ask, `waiting_source`
/// "turn_end", `waiting_choices` 0 to 2 labels. Compiled with Sources/Models.swift only (Tests/run-turn-end-ask.sh).
@main
struct TurnEndAskChecks {
    static func row(_ native: String = "9644b527-da59-4c1e-9d0a-111122223333", provider: String = "claude", state: String = "waiting",
                    source: String? = "turn_end", detail: String = "Where should the overnight mail intel show up first?",
                    choices: [JSONValue] = [.string("Good Morning + Today"), .string("COS Control pane")], job: String? = nil) -> ClaudeSession {
        var o: [String: JSONValue] = ["id": .string(native), "provider": .string(provider), "name": .string("Mail intel"), "state": .string(state),
                                      "alive": .bool(true), "waitingKind": .string("question"), "waitingDetail": .string(detail),
                                      "workspace": .string("cos"), "stateSource": .string("hook"), "waitingChoices": .array(choices)]
        if let source { o["waitingSource"] = .string(source) }
        if let job { o["origin"] = .string("job"); o["jobLabel"] = .string(job) }
        return ClaudeSession(.object(o))!
    }

    static func checkParse() {
        let s = row()
        precondition(s.waitingSource == "turn_end" && s.waitingChoices == ["Good Morning + Today", "COS Control pane"], "the two additive fields parse")
        let objects = row(choices: [.object(["label": .string("Red")]), .object(["label": .string("Blue")])])
        precondition(objects.waitingChoices == ["Red", "Blue"], "a label object reads as its label")
        let older = ClaudeSession(.object(["id": .string("o1"), "provider": .string("claude"), "name": .string("Old"), "state": .string("waiting"), "alive": .bool(true)]))!
        precondition(older.waitingSource.isEmpty && older.waitingChoices.isEmpty, "an older server's row carries neither")
    }

    static func checkGate() {
        let ask = TodayHome.turnEndAsk(row())
        precondition(ask == TodayHome.TurnEndAsk(ask: "Where should the overnight mail intel show up first?", choices: ["Good Morning + Today", "COS Control pane"]),
            "a turn-end row gives its ask and choices")
        precondition(TodayHome.turnEndAsk(row(source: nil)) == nil, "no waiting_source (feature off, older server): nothing changes")
        precondition(TodayHome.turnEndAsk(row(source: "broker")) == nil, "only waiting_source turn_end")
        precondition(TodayHome.turnEndAsk(row(state: "idle")) == nil, "only while the row is waiting")
        precondition(TodayHome.turnEndAsk(row(provider: "codex")) == nil, "only Claude sessions")
        precondition(TodayHome.turnEndAsk(row(job: "Meeting watcher")) == nil, "never a run only the COS server writes")
        let many = TodayHome.turnEndAsk(row(choices: [.string("A"), .string("A"), .string("Bash"), .string(String(repeating: "x", count: 60)), .string("C")]))
        precondition(many?.choices == ["A", String(repeating: "x", count: 40)], "at most two, no repeats, no bare tool name, each at most 40 characters")
        let wordsOff = TodayHome.turnEndAsk(row(detail: "", choices: []))
        precondition(wordsOff == TodayHome.TurnEndAsk(ask: nil, choices: []), "words switch off: still an ask, with no words and no choices")
    }

    static func checkReply() {
        let prefix = "Answer sent from COS Control on the Mac through COS, not typed at this Mac: "
        precondition(TodayHome.turnEndPrefix == prefix, "X1 CONTRACT v1's exact prefix for Control on the Mac")
        precondition(TodayHome.turnEndReply(choice: "Good Morning + Today") == prefix + "Good Morning + Today", "a choice: the prefix, then the label")
        precondition(TodayHome.turnEndReply(other: "  Use the pane  ") == prefix + "  Use the pane  ", "Other: the prefix, then the text as written")
        precondition(TodayHome.turnEndReply(other: "   ") == nil, "an empty Other sends nothing")
        let lines = [TodayHome.turnEndPrefix, TodayHome.turnEndHonestLine, TodayHome.turnEndTodayLine, TodayHome.turnEndAskedLine]
        precondition(lines.allSatisfy { !$0.contains("Miles") && !$0.contains("\u{2014}") && !$0.contains("\u{2192}") },
            "no name, em dash or arrow in the turn-end copy (the app is public)")
        precondition(TodayHome.turnEndHonestLine == "Your reply reaches the session as a message from COS, and the session may ask you to confirm.",
            "the honest line")
    }

    static func checkRowsAndMerge() {
        var input = TodayHome.NeedInputs()
        input.waiting = [row()]
        input.hosts = ["claude:9644b527-da59-4c1e-9d0a-111122223333": TodayHome.Host(app: "Claude", terminal: false)]
        let needs = TodayHome.things(input).filter { $0.kind == .session }
        precondition(needs.count == 1 && needs[0].quote == "Where should the overnight mail intel show up first?" && needs[0].openLabel == "Answer in Claude",
            "Needs you shows the ask, and Answer in Claude stays for the app's own box")
        precondition(TodayHome.question(for: row(), in: []) == nil, "no held-question card for a turn-end ask (hold switches unchanged)")
        // The pet's live row may lack the fields the list row has; the list's fill in.
        let live = row(source: nil, choices: [])
        let merged = TodayHome.liveSessions(list: [row()], live: [live])
        precondition(merged.first?.waitingSource == "turn_end" && merged.first?.waitingChoices.count == 2, "a live row keeps the list row's turn-end fields")
    }

    static func main() {
        checkParse()
        checkGate()
        checkReply()
        checkRowsAndMerge()
        print("TurnEndAskChecks: parse, gate, reply text, rows and merge PASS")
    }
}
