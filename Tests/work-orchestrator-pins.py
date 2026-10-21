#!/usr/bin/env python3
"""0.5.333 Work orchestrator wiring pins: what the execution checks cannot reach (the helper's HTTP side, the view, the
compile lists). Each pin names the behaviour it protects. Behaviour itself is executed in WorkOrchestratorChecks (pure)
and WorkOrchestratorStoreChecks (the real store against a fake transport)."""
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
read = lambda p: (root / p).read_text()
chat, store, helper, orch = read("Sources/WorkTaskChat.swift"), read("Sources/WorkHandoffStore.swift"), read("HelperSources/main.swift"), read("Sources/WorkOrchestrator.swift")
fails = []
def pin(ok, what):
    if not ok: fails.append(what)

# Helper: the server's capability passes through; the orchestrator input and Stop commands exist and are routed.
pin('"orchestrator": body["orchestrator"] as? Int == 1' in helper, "the helper passes the server's orchestrator capability")
for cmd, fn in [("work-orchestrator-input", "emitWorkOrchestratorInput()"), ("work-job-cancel", "emitWorkJobCancel(args: args)"), ("session-chat-cancel", "emitSessionChatCancel(args: args)")]:
    pin(f'case "{cmd}": try {fn}' in helper, f"helper routes {cmd}")
pin('request("/api/work/orchestrator/input", method: "POST"' in helper, "the input goes to the server's orchestrator route")
pin('request("/api/query-jobs/\\(id)/cancel", method: "POST"' in helper and '"{\\"generation\\":1}"' in helper, "a New session's Stop cancels its job, generation 1")
pin('request("/api/agent-sessions/\\(provider)/\\(threadId)/cancel", method: "POST"' in helper and '"clientCancelId": cancelID' in helper, "a Continue's Stop cancels its turn with a client cancel id")
work_chat = helper[helper.index("    private func emitWorkChat() throws {"):helper.index("    static func workChatPlanFailure(")]
pin('if orchestrator, row["linked"] as? Bool != true, let found = row["discoveredBy"] as? [String], !found.isEmpty { return true }' in work_chat,
    "an unlinked row passes the helper only as server-discovered orchestrator evidence")
pin(work_chat.count("return links[id]?.workID == workID") == 1, "every other row must still match the link file")
pin("guard orchestrator || data.count <= 100_000 else" in work_chat, "a non-orchestrator plan keeps the 100,000-byte bound")
# Timeouts: the server waits 20 s (scan) + 16 s (usage); the helper waits 50 s; Control waits 60 s for the helper.
h = int(re.search(r'request\("/api/work/orchestrator/input".*?timeout: (\d+)\)', helper, re.S).group(1))
c = int(re.search(r'args\.first == "work-orchestrator-input" \? (\d+)', store).group(1))
pin(h >= 40 and c >= h + 5, f"orchestrator input timeouts: helper {h}s, Control {c}s")

# Control: refresh right before planning, then the server's input, only when the server offers it.
send = chat[chat.index("    func send(source: WorkSource, handoff: WorkHandoffStore, planner choice:"):chat.index("    /// Sends one reviewed assignment.")]
pin("if !handoff.isolated, orchestratorOffered {" in send, "the orchestrator path runs only for a server that offers it")
block = send[send.index("if !handoff.isolated, orchestratorOffered {"):]
pin(block.index("await handoff.refreshActivity()") < block.index("orchestrated = try await orchestratorInput("), "the session list is refreshed right before the input is built")
pin('orchestratorOffered = caps["orchestrator"]?.bool == true' in chat, "the capability sets the flag")
pin(chat.count("; orchestratorOffered = false;") == 2, "the flag clears on a sample card and on a failed discovery")
payload = chat[chat.index("    private func payload("):chat.index("    /// 0.5.312: everything linked to the card, as context items")]
pin('if let o = orchestrated, mode == "plan" {' in payload and 'body["orchestrator"] = true' in payload, "orchestrator keys only with the server's input")
pin("WorkOrchestrator.emptyExplanation(" in send and "WorkOrchestrator.legacyEmptyExplanation(" in send, "an empty plan says why, on both servers")
pin('if let note = round.sessionsNote { Text(note)' in chat, "the round shows why")
# Sends: every kind through submit, never a direct helper call from the chat.
dispatch = chat[chat.index("    private func dispatch("):chat.index("    /// 0.5.317: what holds this assignment now.")]
pin("await handoff.submit(source:source,mode:sendMode,session:session,model:model," in dispatch and dispatch.count("handoff.submit(") == 1, "Continue, Fork and New session all go through submit")
pin("taskChatCall(" not in dispatch, "the dispatch never calls the helper directly")
pin("case .fork?:" in dispatch and "handoff.forkSource(id: row.id, title: row.title)" in dispatch and "$0.forkable" in dispatch, "a Fork only from a forkable row")
pin("case .newSession(let provider)?:" in dispatch and "round.newSessionProviders?.contains(provider) == true" in dispatch, "a New session only on an offered provider")
pin('workChatLog.info("assignment \\(aid, privacy: .public) sending as' in dispatch, "each send has a log line")
pin("!WorkOrchestrator.isGuardian(" in chat[chat.index("    private func targets("):chat.index("    /// 0.5.333: the card's Work snapshot")], "Guardian review rows are never targets")
# Fork child journaled in both places a child becomes known.
pin(store.count("row.forkChildID = child.id") == 1 and store.count("row.forkChildID = copy.id") == 1, "the fork child is journaled when it is known")
pin("var forkChildID: String? = nil" in store, "the receipt carries the fork child")
# Stop: visible only on rounds sent without review, on assignments that can stop.
pin('round.sentWithoutReview == true,' in chat[chat.index("    func stopAction(roundID"):chat.index("    /// Stop one assignment")], "Stop only on rounds sent without review")
pin('if let action = chat.stopAction(roundID: round.id, assignmentID: a.receiptID, handoff: handoff) {' in chat and 'accessibilityIdentifier("work-chat-stop")' in chat, "the Stop button is drawn from stopAction")
# Auto-send per card: the Settings switch stays the default; the composer reads the card's value everywhere it read Settings.
controls = chat[chat.index("private struct WorkChatSendControls: View {"):chat.index("// Native rich text stays local as RTF")]
pin("@AppStorage(WorkChatPolicy.autoSendKey) private var autoSend = WorkChatPolicy.autoSendDefault" in controls, "Settings is still the default")
pin("WorkOrchestrator.autoSend(workID: source.id, raw: autoSendCards, settingDefault: autoSend)" in controls, "a card with no choice follows Settings")
pin("if cardAutoSend {" in controls and "if autoSend {" not in controls and controls.count("cardAutoSend ?") == 2, "the composer reads the card's value")
pin('Toggle("Auto-send", isOn:' in controls, "the card has its switch")
# The new file is in every explicit compile list that has WorkTaskChat.swift.
for script in ["scripts/build-release.sh", "scripts/build-foundation-lab.sh", "Tests/run.sh", "Tests/run-held-ui.sh", "Tests/run-markdown-ui.sh", "Tests/run-merge-ui.sh", "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh"]:
    text = read(script)
    for line in text.splitlines():
        if '"$ROOT/Sources/WorkTaskChat.swift"' in line and "swift" in line and not line.lstrip().startswith(("python3", "/usr/bin/python3")):
            pin('"$ROOT/Sources/WorkOrchestrator.swift"' in line, f"{script} compiles WorkOrchestrator.swift with WorkTaskChat.swift")
if fails:
    print("FAIL work orchestrator pins:\n  " + "\n  ".join(fails)); sys.exit(1)
print("PASS work orchestrator pins: helper routes and timeouts, refresh before planning, every kind through submit, fork child journaled, Stop on auto-sent rounds, per-card Auto-send over the Settings default, compile lists")
