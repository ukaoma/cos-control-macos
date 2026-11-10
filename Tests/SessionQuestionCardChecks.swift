import AppKit
import Foundation

/// 0.5.388 (D4 item 7): COS Control's question card, against X1's contract v1 for GET /api/session-questions
/// `waiting[]` and POST /api/session-questions/:id/answer. Compiled with Sources/Models.swift only
/// (Tests/run-session-question-card.sh). Fictional sessions and words.
@main
struct SessionQuestionCardChecks {
    static func entry(_ state: String, session: String = "9644b527-da59-4c1e-9d0a-111122223333", key: String = "k1",
                      held: String? = "pq_0123456789abcdef01234567", answerable: Bool = true, multi: Bool = false,
                      questions: Int = 1, options: Int = 2, askedAt: String = "2026-11-10T14:00:00Z") -> JSONValue {
        var o: [String: JSONValue] = [
            "key": .string(key), "sessionId": .string(session), "provider": .string("claude"), "toolUseId": .string("toolu_1"),
            "state": .string(state), "answerable": .bool(answerable), "askedAt": .string(askedAt),
            "questions": .array((0..<questions).map { q in .object([
                "question": .string("Which page first \(q)?"), "header": .string("Page"), "multiSelect": .bool(multi),
                "options": .array((0..<options).map { .object(["label": .string("Option \($0)"), "description": .string("Detail \($0)")]) }),
            ]) }),
        ]
        o["heldId"] = held.map(JSONValue.string) ?? .null
        return .object(o)
    }
    static func session(_ native: String, state: String = "waiting", provider: String = "claude") -> ClaudeSession {
        ClaudeSession(.object(["id": .string(native), "provider": .string(provider), "name": .string("Footer"), "state": .string(state),
                               "alive": .bool(true), "waitingKind": .string("question"), "workspace": .string("cos")]))!
    }

    static func checkParse() {
        let held = TodayHome.SessionQuestion(entry("held"))
        precondition(held?.answerable == true && held?.heldId == "pq_0123456789abcdef01234567" && held?.questions.count == 1
            && held?.questions[0].options.map(\.label) == ["Option 0", "Option 1"], "a held, answerable question parses with its options")
        precondition(TodayHome.SessionQuestion(entry("at_mac", held: nil, answerable: false))?.answerable == false, "at the Mac: words, not answerable")
        precondition(TodayHome.SessionQuestion(entry("held", answerable: false))?.answerable == false, "held but not answerable: the server's word wins")
        precondition(TodayHome.SessionQuestion(entry("at_mac", answerable: true))?.answerable == false, "only a held question is answerable")
        precondition(TodayHome.SessionQuestion(entry("held", held: "pq_short")) == nil, "a malformed held id is refused, never posted to")
        precondition(TodayHome.SessionQuestion(entry("answered"))?.questions.isEmpty == true, "an answered question keeps no words")
        precondition(TodayHome.SessionQuestion(entry("held", questions: 9))?.answerable == false, "more questions than the card shows: not answerable here")
        precondition(TodayHome.SessionQuestion(entry("held", options: 41))?.answerable == false, "more options than the card shows: not answerable here")
        var codex = entry("held"); if case .object(var o) = codex { o["provider"] = .string("codex"); codex = .object(o) }
        precondition(TodayHome.SessionQuestion(codex) == nil, "only Claude sessions")
        precondition(TodayHome.SessionQuestion(entry("bogus")) == nil, "an unknown state is refused")
    }

    static func checkMatch() {
        let list = [entry("at_mac", key: "a", held: nil, answerable: false, askedAt: "2026-11-10T14:05:00Z"),
                    entry("held", key: "b", askedAt: "2026-11-10T14:00:00Z"),
                    entry("held", session: "other-session-0000", key: "c")].compactMap(TodayHome.SessionQuestion.init)
        precondition(TodayHome.question(for: session("9644b527-da59-4c1e-9d0a-111122223333"), in: list)?.key == "b",
            "a held, answerable question comes first for its session, even when an at-the-Mac one is newer")
        precondition(TodayHome.question(for: session("9644b527"), in: list)?.key == "b", "the 8-character short id matches its full id")
        precondition(TodayHome.question(for: session("9644b52"), in: list) == nil, "fewer than 8 characters never matches")
        precondition(TodayHome.question(for: session("9644b527-da59-4c1e-9d0a-111122223333", provider: "codex"), in: list) == nil, "never a Codex session")
        precondition(TodayHome.question(for: session("unrelated-session"), in: list) == nil, "no question for another session")
    }

    static func checkAnswerBody() {
        let single = TodayHome.SessionQuestion(entry("held"))!
        let multi = TodayHome.SessionQuestion(entry("held", multi: true, questions: 2))!
        typealias P = TodayHome.QuestionPick
        let one = TodayHome.answerBody(single, picks: [P(labels: ["Option 1"])], clientAnswerId: "control-1")
        precondition((one?["clientAnswerId"] as? String) == "control-1"
            && ((one?["answers"] as? [[String: Any]])?.first?["labels"] as? [String]) == ["Option 1"], "one label, sent exactly")
        precondition(TodayHome.answerBody(single, picks: [P()], clientAnswerId: "control-1") == nil, "nothing picked: no body")
        precondition(TodayHome.answerBody(single, picks: [P(labels: ["Option 0", "Option 1"])], clientAnswerId: "control-1") == nil,
            "single select takes exactly one")
        precondition(TodayHome.answerBody(single, picks: [P(labels: ["Option 0"], other: "and this")], clientAnswerId: "control-1") == nil,
            "single select: a label and Other together is two")
        precondition(TodayHome.answerBody(single, picks: [P(labels: ["Made up"])], clientAnswerId: "control-1") == nil, "an unknown label is never sent")
        precondition(TodayHome.answerBody(single, picks: [P(other: "   ")], clientAnswerId: "control-1") == nil, "whitespace alone is no answer")
        let other = TodayHome.answerBody(single, picks: [P(other: "  Use the draft  ")], clientAnswerId: "control-1")
        precondition(((other?["answers"] as? [[String: Any]])?.first?["other"] as? String) == "  Use the draft  ", "Other is sent as written")
        precondition(TodayHome.answerBody(single, picks: [P(other: String(repeating: "x", count: 2_001))], clientAnswerId: "control-1") == nil,
            "Other over 2,000 characters is refused before it is sent")
        precondition(TodayHome.answerBody(single, picks: [P(labels: ["Option 1"])], clientAnswerId: "bad id") == nil, "a malformed answer id is refused")
        let both = TodayHome.answerBody(multi, picks: [P(labels: ["Option 1", "Option 0"]), P(labels: ["Option 0"], other: "and more")], clientAnswerId: "control-2")
        let rows = both?["answers"] as? [[String: Any]]
        precondition(rows?.count == 2 && (rows?[0]["labels"] as? [String]) == ["Option 0", "Option 1"] && (rows?[1]["other"] as? String) == "and more",
            "multi select: labels in option order, Other beside them, one entry per question")
        precondition(TodayHome.answerBody(multi, picks: [P(labels: ["Option 0"])], clientAnswerId: "control-2") == nil, "every question must be answered")
        let atMac = TodayHome.SessionQuestion(entry("at_mac", held: nil, answerable: false))!
        precondition(TodayHome.answerBody(atMac, picks: [P(labels: ["Option 0"])], clientAnswerId: "control-3") == nil,
            "a question at the Mac is never posted from here")
    }

    static func checkOutcome() {
        precondition(TodayHome.answerOutcome(status: 200, error: nil) == .answered, "200: answered")
        precondition(TodayHome.answerOutcome(status: 409, error: "already_answered") == .settled("Already answered, here or at the Mac."), "409 already answered")
        precondition(TodayHome.answerOutcome(status: 409, error: "handed_to_desk") == .settled("Left for the Mac. Answer it in Claude."), "409 handed to the desk")
        precondition(TodayHome.answerOutcome(status: 409, error: "expired") == .settled("This question can no longer be answered here. Answer it in Claude."), "409 expired")
        precondition(TodayHome.answerOutcome(status: 410, error: "hook_gone") == .settled("This question can no longer be answered here. Answer it in Claude."), "410")
        precondition(TodayHome.answerOutcome(status: 404, error: "not_found") == .settled("This question is gone. The session may have moved on."), "404")
        precondition(TodayHome.answerOutcome(status: 400, error: "invalid_answer") == .failed("COS did not take that answer. Check the choices and send it again."), "400")
        precondition(TodayHome.answerOutcome(status: 0, error: nil) == .failed(TodayHome.answerUnconfirmed), "no answer from the server: unconfirmed")
        precondition(TodayHome.heldLine == "Answer here or at your Mac. The first answer counts."
            && TodayHome.composerWaitsLine == "A message here waits until this question is answered." && TodayHome.answeredLine == "Answered.", "copy")
        let lines = [TodayHome.heldLine, TodayHome.composerWaitsLine, TodayHome.answeredLine, TodayHome.answerUnconfirmed]
        precondition(lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2192}") }, "no em dash or arrow in the card's copy")
    }

    static func checkPendingWords() {
        let held = TodayHome.SessionQuestion(entry("held"))!
        let atMacEmpty = TodayHome.SessionQuestion(entry("at_mac", held: nil, answerable: false, questions: 0))!
        let bare = session("9644b527-da59-4c1e-9d0a-111122223333")
        let worded = ClaudeSession(.object(["id": .string("w1"), "provider": .string("claude"), "name": .string("Footer"), "state": .string("waiting"),
                                            "alive": .bool(true), "waitingKind": .string("question"), "waitingDetail": .string("Ship the footer now?")]))!
        precondition(TodayHome.pendingWords(bare, card: held) == .card(held), "a held question shows its card")
        precondition(TodayHome.pendingWords(worded, card: nil) == .words("Ship the footer now?"), "no card: the row's words (the server's first 80 characters)")
        precondition(TodayHome.pendingWords(worded, card: atMacEmpty) == .words("Ship the footer now?"), "a card with no words falls back to the row's words")
        precondition(TodayHome.pendingWords(bare, card: nil) == .none, "no card and no words: the plain line, never invented words")
        precondition(TodayHome.wordsUnavailableLine == "COS cannot read this question's words. They are on the session's own prompt.", "copy")
    }

    static func main() {
        checkParse()
        checkMatch()
        checkAnswerBody()
        checkOutcome()
        checkPendingWords()
        print("SessionQuestionCardChecks: parse, match, answer body, outcome and pending words PASS")
    }
}
