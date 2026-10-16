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
assert "await dispatch(roundID: roundID, assignmentIDs: answer.assignments.map(\\.receiptID), source: source, handoff: handoff)" in auto and "submit(" not in auto, "Plan and send uses the guarded send path, never submit directly"
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
assert "contextFileIDs:fileIDs)" in dispatch and "include: contextFileIDs" in store, "the send lists only the assignment's files"
assert '"contextItems": body["contextItems"] as? Bool == true' in helper, "the helper passes the server's context-items capability"
import re
logged = re.findall(r'workChatLog\.\w+\("((?:[^"\\]|\\.)*)"', chat)
assert len(logged) >= 8 and not any(re.search(r'\\\((?:prompt|built|question|context|text|assignment\.prompt|round\.question)\b', line) for line in logged), "the work-chat log never carries prompt, question or context text"
print("PASS Work context meter wiring: collapsed by default and remembered per Mac, Quick Look for files, per-assignment prompt and files")
PY
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "${SOURCES[@]}" "$ROOT/Tests/WorkInputChecks.swift" "$ROOT/Tests/WorkSessionHubChecks.swift" "$ROOT/Tests/WorkActivityChecks.swift" "$ROOT/Tests/WorkOrchestrationChecks.swift" "$ROOT/Tests/WorkBoardCacheChecks.swift" "$OUT/ContextChecks.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$OUT/hub-checks"
"$OUT/hub-checks" --render "$OUT/renders"
