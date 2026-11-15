#!/usr/bin/env python3
"""0.5.389 (D4) wiring pins for the turn-end ask (X1 CONTRACT v1)."""
import sys
root = sys.argv[1]
def read(p): return open(f"{root}/{p}").read()
helper, win, models = read("HelperSources/main.swift"), read("Sources/ActivityWindow.swift"), read("Sources/Models.swift")
controller = read("Sources/ControllerModel.swift")
fails = []
def need(cond, label):
    if not cond: fails.append(label)
def body(text, start, end):
    i = text.find(start); j = text.find(end, i + 1) if i >= 0 else -1
    return text[i:j] if i >= 0 and j > i else ""

keys = body(helper, "    static let serverStateKeys: [(wire: String, key: String)] = [", "\n    ]")
need('("waiting_source", "waitingSource"), ("waiting_choices", "waitingChoices")' in keys,
     "[server gated] the two additive keys ride the one server-row projection, so nothing appears unless the server sends them")
need("mcp__ccd_turn__wrap_up" not in helper and "wrap_up" not in models,
     "[server gated] Control never reads a transcript's wrap_up itself; the server's switch, latch and age-out decide")
gate = body(models, "    static func turnEndAsk(_ session: ClaudeSession) -> TurnEndAsk? {", "\n    }\n")
need('session.provider == "claude", isWaiting(session), session.waitingSource == turnEndSource' in gate,
     "[gate] Claude, waiting, and the server's turn_end source")
today = body(win, "    func todayTurnEndChoices(", "\n    func commandCanContinue(")
need("todayReplyInControl(session, words: TodayHome.turnEndReply(choice: choice), askID: ask.id)" in today
     and "todayReplyInControl(session, words: TodayHome.turnEndPrefix, askID: ask.id)" in today
     and "model.prefillTurnEndAnswer(words, askID: askID)" in today,
     "[today] a choice or Other opens the session with the attributed reply bound to the question shown")
need("sendChatMessage" not in today and "session-chat" not in today and "performChatSend" not in today,
     "[today] nothing is sent from Today")
need("!model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {" in today and "guard commandCanContinue(session) else {" in today,
     "[today] never over another session's unsent reply, and only where the composer can take a message")
block = body(win, "struct TurnEndAskBlock: View {", "\nstruct SessionQuestionCard: View {")
need("model.sendTurnEndAnswer(words, askID: ask.id)" in block
     and "model.sendChatMessage()" not in block,
     "[reader] a reply uses the question-bound send, never bypassing its identity guard")
sender = body(controller, "    func sendTurnEndAnswer(_ words: String, askID: String?) {", "\n    }\n")
need("prefillTurnEndAnswer(words, askID: askID)" in sender
     and "guard let askID = chatDraftAskID, openClaudeRow?.waitingAskID == askID else {" in sender
     and sender.count("sendChatMessage()") == 1
     and sender.index("guard let askID") < sender.index("sendChatMessage()"),
     "[reader] the captured question must still match before Continue runs")
need("send(TodayHome.turnEndReply(choice: choice))" in block and "if let words = TodayHome.turnEndReply(other: other)" in block,
     "[reader] choices and Other carry X1's attributed prefix")
need(block.count(".disabled(gate != nil || busy") == 3 and "Text(gate ?? TodayHome.turnEndHonestLine)" in block,
     "[reader] nothing sends while the composer is gated or busy, and the honest line shows")
need("if let turnEnd = TodayHome.turnEndAsk(live) {\n                        TurnEndAskBlock(" in win
     and "if let session = row.session, let turnEnd = TodayHome.turnEndAsk(session) {" in win,
     "[mounts] the reader and Today both show it")
need("&& row.session.flatMap(TodayHome.turnEndAsk) == nil))" in win, "[today] Answer in ... is quiet while the reply choices show")
if fails:
    for f in fails: print("FAIL:", f, file=sys.stderr)
    sys.exit(1)
print("turn-end ask pins: %d passed" % sum(1 for l in open(__file__).read().splitlines() if l.startswith("need(")))
