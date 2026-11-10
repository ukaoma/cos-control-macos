#!/usr/bin/env python3
"""0.5.388 (D4 item 7) wiring pins for COS Control's question card.

Polling GET /api/session-questions with an answering `client` makes the server count the poller as live, which
changes WHEN it holds a question for every user (routes/permission-broker.ts notePoll). Control must never do that:
it lists without `client` and answers only a question the server already holds.
"""
import re, sys
root = sys.argv[1]
def read(p): return open(f"{root}/{p}").read()
helper, model, win = read("HelperSources/main.swift"), read("Sources/ControllerModel.swift"), read("Sources/ActivityWindow.swift")
fails = []
def need(cond, label):
    if not cond: fails.append(label)
def body(text, start, end):
    i = text.find(start); j = text.find(end, i + 1) if i >= 0 else -1
    return text[i:j] if i >= 0 and j > i else ""

fn = body(helper, "    /// 0.5.388 (D4 item 7, X1 contract v1): COS Control's question card.", "\n    private func emitWorkIntakeResolve() throws {")
need(fn != "", "[helper] emitSessionQuestions exists where expected")
need(helper.count('case "session-questions": try emitSessionQuestions(args: args)') == 1, "[helper] one dispatch line")
need(len(re.findall(r"session-questions", helper)) == len(re.findall(r"session-questions", fn)) + 1,
     "[helper] /api/session-questions is reached only from emitSessionQuestions")
code = "\n".join(l for l in fn.splitlines() if not l.strip().startswith("///"))
need("client" not in code.replace("clientAnswerId", ""), "[no live client] the list never sends `client`, so Control never changes when questions are held")
need('request("/api/session-questions", method: "GET"' in fn, "[list] a plain GET of the list")
need('["waiting": body["waiting"]' in fn and '"items"' not in fn, "[list] only waiting[] is passed on")
need(r'id.range(of: #"\Apq_[0-9a-f]{24}\z"#' in fn, "[answer] only a held item's id is posted to")
need('Set(body.keys) == ["clientAnswerId", "answers"]' in fn and "isSubset(of: [\"labels\", \"other\"])" in fn,
     "[answer] the body is a question answer and nothing else")
need(all(w not in fn for w in ["handBack", "\"decision\"", "/confirm", "presenceAgeMs"]), "[answer] never an approval, a hand-back or a web confirm")

load = body(model, "    func loadSessionQuestionsIfWaiting(force: Bool = false) async {", "\n    func answerSessionQuestion(")
need("TodayHome.isWaiting($0)" in load and "guard waiting else" in load, "[polling] read only while a Claude session waits")
need("Date().timeIntervalSince(last) < sessionQuestionsDelay" in load
     and 'sessionQuestionsDelay = TodayHome.questionsReadDelay(listPresent: response.details["present"]?.bool == true)' in load,
     "[polling] at most every 10 seconds, and every 5 minutes when the server sends no list")
need('"present": body["waiting"] is [Any]' in fn and '"present": false' in fn, "[polling] the helper says whether the server sent the list")
answer = body(model, "    func answerSessionQuestion(", "\n    }\n")
need("TodayHome.reusableAnswerID(sessionQuestionAnswerIDs[question.key], answers: answers)" in answer
     and "if case .failed = outcome {} else { sessionQuestionAnswerIDs[question.key] = nil }" in answer,
     "[answer] the same answers retry under one id until settled; new picks get a new id")
need('reason: response.details["reason"]?.string, place: place)' in answer and '"reason": reason ?? NSNull()' in fn,
     "[answer] the outcome reads the server's reason and names the app holding the prompt")
need(".id(shown.key)" in win and ".id(questionCard.key)" in win and "picks = TodayHome.picks(picks, keptFor: picksKey, question: question)" in win,
     "[picks] a new question starts with nothing picked, at both places the card is drawn")
need("composerWaitsLine" not in win and "composerWaitsLine" not in read("Sources/Models.swift"),
     "[copy] no unverified line about what a message does while a question waits")
need("session-questions" not in win, "[window] the window never names the route; it goes through the model")
need(win.count("await model.loadSessionQuestionsIfWaiting()") == 2, "[polling] two readers: Today's tick and the open session view")

if fails:
    for f in fails: print("FAIL:", f, file=sys.stderr)
    sys.exit(1)
checks = sum(1 for l in open(__file__).read().splitlines() if l.startswith("need("))
print("session question pins: %d passed" % checks)
