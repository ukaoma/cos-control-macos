#!/usr/bin/env python3
"""0.5.387 (D4) view wiring pins, from Q1's review: the pure checks prove the rules; these prove the views use them."""
import sys
root = sys.argv[1]
def read(p): return open(f"{root}/{p}").read()
work, win, ask = read("Sources/WorkWorkspaceView.swift"), read("Sources/ActivityWindow.swift"), read("Sources/MeetingAsk.swift")
fails = []
def need(cond, label):
    if not cond: fails.append(label)
need("if let missing = WorkLoopSupport.cardActionsLine(batchAvailable: model.workBatchAvailable) {" in work
     and "}.disabled(model.workBatchBusy)" in work and "disabled(!model.workBatchAvailable" not in work,
     "[item 6] Sort's card row shows the line, not three greyed controls, when the server takes no card batch")
need("Text(WorkLoopSupport.listMissing(dropped: dropped))" in work and "need a newer COS server" not in work and "needs a newer COS server" not in work,
     "[item 6] Waiting on / Dropped say not available, never a newer server")
need("TodayHome.answerAtPrompt(live, host: host)" in win and "Text(TodayHome.promptPendingLine)" in win
     and 'accessibilityIdentifier("session-answer-at-prompt")' in win and "model.openSessionInPlatform(live)" in win,
     "[item 5B] the session view's pending line and its Answer in ... button")
need('if row.answersAtPrompt, let session = row.session {' in win and 'todayOpen(.inSessions(session.id))' in win,
     "[item 5B] Needs you's second button opens Control's Sessions view")
need("host: openSessionHost)" in win and "private var openSessionHost: TodayHome.Host? { model.openClaudeRow.flatMap { today.hosts[$0.id] } }" in win,
     "[item 5B] the pane's host comes from the store, outside activityContent's shadowing `today` parameter")
need("Dictionary(uniqueKeysWithValues:" not in ask, "[item 1] Meeting Ask's cache merge never traps on a repeated id")
if fails:
    for f in fails: print("FAIL:", f, file=sys.stderr)
    sys.exit(1)
print("stability d4 pins: 6 passed")
