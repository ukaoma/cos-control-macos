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
need("Self.sessionQuestionsMinSeconds" in load and "static let sessionQuestionsMinSeconds: TimeInterval = 10" in model,
     "[polling] at most every 10 seconds")
answer = body(model, "    func answerSessionQuestion(", "\n    }\n")
need("sessionQuestionAnswerIDs[question.key] ?? " in answer and "if case .failed = outcome {} else { sessionQuestionAnswerIDs[question.key] = nil }" in answer,
     "[answer] one answer id per question until settled, so a retry replays")
need("session-questions" not in win, "[window] the window never names the route; it goes through the model")
need(win.count("await model.loadSessionQuestionsIfWaiting()") == 2, "[polling] two readers: Today's tick and the open session view")

if fails:
    for f in fails: print("FAIL:", f, file=sys.stderr)
    sys.exit(1)
print("session question pins: %d passed" % 12)
