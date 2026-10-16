#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/dist/work-session-hub-checks"
mkdir -p "$OUT"
sed 's/@main struct WorkTaskContextChecks/struct WorkTaskContextChecks/' "$ROOT/Tests/WorkTaskContextChecks.swift" > "$OUT/ContextChecks.swift"
# 0.5.310: a high-effort Work chat plan may run 180 s on server 6.73.12 (WORK_CHAT_DEADLINE_MS). The helper's wait
# (its timeout plus 2 s) must outlast that, and Control's wait for the helper must outlast the helper.
python3 - "$ROOT/HelperSources/main.swift" "$ROOT/Sources/WorkHandoffStore.swift" <<'PY'
import re, sys
helper, store = (open(p).read() for p in sys.argv[1:3])
chat = helper[helper.index("    private func emitWorkChat() throws {"):helper.index("    private func emitWorkChatCapabilities() throws {")]
h = int(re.search(r'request\("/api/work/chat", method: "POST".*?timeout: (\d+)\)', chat, re.S).group(1))
c = int(re.search(r'args\.first == "work-chat" \? (\d+)', store).group(1))
assert h >= 185, f"helper waits {h}s for a plan the server may run for 180s"
assert c >= h + 2 + 5, f"Control waits {c}s for a helper that may wait {h + 2}s"
print(f"PASS Work chat timeouts: server 180s < helper {h}s (+2) < Control {c}s")
# 0.5.316: the plan's failure words come from the server's answer (self-test-work runs workChatPlanFailure itself; the
# live POST cannot run in a check, so this pins that emitWorkChat uses it and never the old one-size message).
assert "if let failure = Self.workChatPlanFailure(status: response?.status, body: response?.body, elapsedMs: elapsedMs, timeoutSeconds: 190) {\n            throw HelperError.message(failure)" in chat, "emitWorkChat must say what the server answered"
assert "No assignment was sent." not in chat and chat.count("timeout: 190)") == 1, "no blanket 'unavailable' failure, and the mapping's timeout is the request's"
print("PASS Work chat plan failures: emitWorkChat maps the server's status, code and elapsed time")
PY
# 0.5.316: the update summary takes the same one-call gate as Plan (the execution check holds the gate by hand).
python3 - "$ROOT/Sources/WorkTaskChat.swift" <<'PY'
import sys
chat = open(sys.argv[1]).read()
refresh = chat[chat.index("    func refresh(source: WorkSource, handoff: WorkHandoffStore, automatic: Bool = false) async {"):]
refresh = refresh[:refresh.index("\nstruct WorkTaskChatView")]
assert refresh.index("guard gate.tryAcquire() else { return }") < refresh.index("defer { gate.release() }") < refresh.index('let response = try await handoff.taskChatCall(["work-chat"],data:data)'), "the summary takes the Work chat gate before its call"
print("PASS Work chat summary takes the one-call gate before calling the server")
PY
# 0.5.312: the Work Context Meter's wiring. Item lists start collapsed and their open state is remembered per Mac; a file
# previews in the native Quick Look panel on its local copy, a text item shows its exact excerpt; the send uses only the
# assignment's items and files; the helper passes the server's contextItems capability through.
python3 - "$ROOT/Sources/WorkContextMeter.swift" "$ROOT/Sources/WorkTaskChat.swift" "$ROOT/Sources/WorkHandoffStore.swift" "$ROOT/HelperSources/main.swift" "$ROOT/Sources/Views.swift" <<'PY'
import sys
meter, chat, store, helper, views = (open(p).read() for p in sys.argv[1:6])
# 0.5.312 Plan and send: off by default in both places that read it, asks once, and sends through the one guarded path.
assert "    static let autoSendDefault = false\n" in chat, "Send plans without review is off by default"
assert "@AppStorage(WorkChatPolicy.autoSendKey) private var autoSend = WorkChatPolicy.autoSendDefault" in chat, "the composer reads the default"
assert "@AppStorage(WorkChatPolicy.autoSendKey) private var workChatSendWithoutReview = WorkChatPolicy.autoSendDefault" in views and 'Toggle("Send plans without review", isOn: $workChatSendWithoutReview)' in views, "Settings › Work has the switch"
gate = chat[chat.index("    private func planAndSend() {"):chat.index("    var body: some View {", chat.index("    private func planAndSend() {"))]
assert gate.index("if WorkChatPolicy.confirmBeforeAutoSend(acknowledged: autoSendAcknowledged) { confirmAutoSend = true; return }") < gate.index("autoSend:true"), "the first Plan and send asks before sending"
dialog = chat[chat.index('.confirmationDialog("Send plans without review?"'):]
assert dialog.index("autoSendAcknowledged = true") < dialog.index("autoSend:true"), "confirming records the acknowledgement"
assert chat.count("autoSend:true") == 2 and chat.count('Button("Plan and send") { planAndSend() }') == 2, "both Plan and send buttons go through the gate"
auto = chat[chat.index("            if autoSend, !answer.assignments.isEmpty"):chat.index("        } catch {", chat.index("            if autoSend, !answer.assignments.isEmpty"))]
assert "await dispatch(roundID: roundID, assignmentIDs: answer.assignments.map(\\.receiptID), source: source, handoff: handoff, hold: hold)" in auto and "submit(" not in auto, "Plan and send uses the guarded send path, never submit directly"
assert '@AppStorage(WorkContextMeter.expandedKey) private var expanded = ""' in meter, "item lists must start collapsed (empty memory)"
assert 'static let expandedKey = "cos.workContextExpanded"' in meter, "the open state is remembered per Mac"
assert "private var isOpen: Bool { WorkContextMeter.isExpanded(expanded, assignment.receiptID) }" in meter and "if isOpen {" in meter, "the list shows only when opened"
preview = chat[chat.index("    private func openPreview("):chat.index("    @ViewBuilder private func contextMeter(")]
assert "if item.kind == .files, let url = chat.previewURL(for: item, source: source, handoff: handoff) { quickLook = url; return }" in preview, "a file opens in Quick Look"
assert ".quickLookPreview($quickLook)" in chat and chat.count(".quickLookPreview(") == 1, "one Quick Look presenter on the chat"
assert '.onKeyPress(.space) { onPreview(item); return .handled }' in meter, "Space previews the hovered or focused row"
assert ".onHover { inside in if inside { focusedRow = item.id }" in meter, "hovering a row makes Space reach it"
dispatch = chat[chat.index("    private func dispatch("):chat.index("    private func sendContext(")]
assert "WorkContextMeter.prompt(question: round.question, assignment: assignment.prompt, items: items, selected: selected)" in dispatch, "the send builds its prompt from the assignment's items"
assert "contextFileIDs:fileIDs,sessionFence:parallel)" in dispatch and "include: contextFileIDs" in store, "the send lists only the assignment's files"
assert '"contextItems": body["contextItems"] as? Bool == true' in helper, "the helper passes the server's context-items capability"
import re
logged = re.findall(r'workChatLog\.\w+\("((?:[^"\\]|\\.)*)"', chat)
assert len(logged) >= 8 and not any(re.search(r'\\\((?:prompt|built|question|context|text|assignment\.prompt|round\.question)\b', line) for line in logged), "the work-chat log never carries prompt, question or context text"
print("PASS Work context meter wiring: collapsed by default and remembered per Mac, Quick Look for files, per-assignment prompt and files")
PY
# 0.5.317: the Work chat queue's wiring the hub checks cannot execute: the helper passes the server's queueRounds through,
# Settings › Work has the switch with Queue it as its default, the app starts the app-wide pump, and an open card pumps its
# own queue and tells the app-wide pump to leave it alone.
python3 - "$ROOT/Sources/WorkTaskChat.swift" "$ROOT/HelperSources/main.swift" "$ROOT/Sources/Views.swift" "$ROOT/Sources/ControllerModel.swift" "$ROOT/Sources/WorkChatQueue.swift" "$ROOT/Sources/WorkWorkspaceView.swift" "$ROOT/Sources/WorkReferences.swift" <<'PY'
import sys
chat, helper, views, model, queue, workspace, refs = (open(p).read() for p in sys.argv[1:8])
# 0.5.317 reference links: offered only by a server that takes them, apart from the working sessions, with no send control.
assert '"references": body["references"] as? Bool == true' in helper, "the helper passes the server's references capability"
assert "if taskChat.referencesOffered, linked?.workID != task.workSourceID {" in workspace and 'Button("Link as reference")' in workspace, "Link as reference only when the server takes references"
assert "let references = taskChat.referencesOffered ? handoffStore.referenceRows(workID: task.workSourceID) : []" in workspace, "the References group only when offered"
assert "submit(" not in refs and 'Button("Send' not in refs and "sendAll(" not in refs, "the References group has no send control"
assert '"queueRounds": body["queueRounds"] as? Bool == true' in helper, "the helper passes the server's queueRounds capability"
assert "@AppStorage(WorkChatHold.settingKey) private var workChatWhenHeld = WorkChatHold.settingDefault" in views, "Settings reads the default"
assert 'COSDropdown("When earlier work is still open", selection: $workChatWhenHeld,' in views, "Settings › Work has the switch"
assert "    static let settingDefault = queueSetting\n" in queue, "Queue it is the default"
assert "let pump = WorkChatQueuePump(handoff: store, sources:" in model and "pump.start()" in model, "the app starts the app-wide pump"
loop = chat[chat.index("WorkChatQueuePump.show(source.id); defer { WorkChatQueuePump.hide(source.id) }"):chat.index('}.confirmationDialog("Check the connected session first"')]
assert "await chat.pumpQueued(source:source,handoff:handoff)" in loop and "chat.syncFromDisk()" in loop, "an open card pumps its own queue and reads the app-wide pump's writes"
# 0.5.317: loading states (the same line slot, no layout jump), early history, automatic re-check of shown blockers.
handoffview = open(sys.argv[1].replace("WorkTaskChat.swift", "WorkHandoffView.swift")).read()
assert 'Text(handoffStore.sessionsKnown ? "Each session keeps its own progress.' in workspace and '"Loading status\\u{2026}"' in workspace, "Sessions say they are loading until the first read"
assert 'if store.sessions.isEmpty && !store.sessionsKnown {' in handoffview, "the Agent workspace never reads as no sessions while loading"
assert 'Text("Loading Work chat history\\u{2026}")' in chat and ".frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)" in chat, "Work chat shows a placeholder until its history opens"
assert loop.index("chat.open(source:source,handoff:handoff) }") < loop.index("await handoff.refresh()"), "the history opens before the session read when the server is known"
assert "await chat.recheckBlockers(source:source,handoff:handoff,automatic:true)" in loop, "shown blockers are checked again by themselves"
# 0.5.317: Complete is a board column (a drop asks, then completes through move; a drag out un-completes through move),
# Mentioned is the only list above the board, and the Complete column leads with the latest completions.
assert "ForEach(WorkBoardStage.boardColumns) { stage in boardColumn(stage, pass: pass) }" in workspace, "the board draws boardColumns"
assert "ForEach([WorkBoardStage.mentioned]) { stage in" in workspace and "WorkBoardStage.mentioned, .complete" not in workspace, "no Complete dropdown above the board"
assert "if stage == .complete { state.pendingComplete = task } else { move(task, to: stage) }" in workspace, "a drop on Complete completes through the stage path"
assert "WorkBoardStage.recentFirst(ordered, id: \\.sourceID, moves: model.workActivity.moves)" in workspace and "LazyVStack(alignment: .leading, spacing: 10) {" in workspace, "Complete leads with recent completions, drawn lazily"
print("PASS Work chat queue and reference wiring: helper capabilities, Settings default Queue it, app-wide pump started, open card pumps itself, references gated and send-free")
PY
# 0.5.313: the idle CPU fixes stay in place (text pins; the behaviour is checked in WorkInputChecks).
/usr/bin/python3 "$ROOT/Tests/idle-cpu-pins.py" "$ROOT"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "${SOURCES[@]}" "$ROOT/Tests/WorkInputChecks.swift" "$ROOT/Tests/WorkSessionHubChecks.swift" "$ROOT/Tests/WorkActivityChecks.swift" "$ROOT/Tests/WorkOrchestrationChecks.swift" "$ROOT/Tests/WorkBoardCacheChecks.swift" "$OUT/ContextChecks.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$OUT/hub-checks"
"$OUT/hub-checks" --render "$OUT/renders"
