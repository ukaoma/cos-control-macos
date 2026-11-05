#!/usr/bin/env python3
"""0.5.370 Drop it: the mutation pass. Serial, every compile through Tests/compile-guard.sh, never run by Tests/run.sh (a wiring
mutant compiles the whole app; a helper mutant compiles the helper).

Usage: mutate-drop-it.py [<repo root>]. A green baseline of every suite the chosen mutants use comes first, and the run stops on
a red one. Each mutant must be applied exactly once, must land, must fail its suite, and is attributed to the check or pin that
names the behaviour ("[<behaviour>]" in the failure line, or the helper check's own words). Sources are restored after each,
and the run says so. MUTATE_ONLY="a|b" runs only the mutants whose names contain one of the parts (the baseline still runs).
"""
import os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
scratch = tempfile.mkdtemp(prefix="cos-mutate-drop-it-", dir="/tmp")
os.environ.setdefault("COS_TEST_KIT_DIR", os.path.join(scratch, "kits"))
env = dict(os.environ)
import signal
# 0.5.370: a lane that runs past its limit is stopped (its whole process group) and counts as a kill: a hang is caught, not a
# survivor. The 0.5.369 pass hung for three hours on M9, whose mutant made a held call wait forever.
LIMITS = {"pins": 300, "models": 600, "wiring": 1800, "helper": 900}
def sh(cmd, limit=1800):
    proc = subprocess.Popen(cmd, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, shell=True, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=limit)
        return proc.returncode, out
    except subprocess.TimeoutExpired:
        try: os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: out, _ = proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            try: os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            out, _ = proc.communicate()
        return None, (out or "") + f"\n[hang: stopped after {limit} s]"
def lane(cmd): return next(k for k in LIMITS if f"COS_DROP_IT_LANE={k} " in cmd)
PINS = "COS_DROP_IT_LANE=pins zsh Tests/run-drop-it.sh"
MODELS = "COS_DROP_IT_LANE=models zsh Tests/run-drop-it.sh"
WIRING = "COS_DROP_IT_LANE=wiring zsh Tests/run-drop-it.sh"
HELPER = "COS_DROP_IT_LANE=helper zsh Tests/run-drop-it.sh"
D, V, M, W, CM, S, VW, H = ("Sources/DropIt.swift", "Sources/DropItViews.swift", "Sources/Models.swift", "Sources/ActivityWindow.swift",
                            "Sources/ControllerModel.swift", "Sources/SetupAssistant.swift", "Sources/Views.swift", "HelperSources/main.swift")
mutants = [
 # The rules and the store (Tests/DropItChecks.swift).
 ("M1 off reads as answered", D, '        case "off": return .off\n', "", MODELS, "[reply off]"),
 ("M2 an unknown code is shown raw", D, '        if let message, !message.isEmpty, message.count <= 300, !message.contains("\\n") { return message }',
  '        if let code { return code }', MODELS, "[refusal line]"),
 ("M3 a multi-line message is shown", D, ', message.count <= 300, !message.contains("\\n") { return message }', ', message.count <= 300 { return message }', MODELS, "[refusal line]"),
 ("M4 the words go in the arguments", D, '        return (call("submit"), data)', '        return (call("submit", [words]), data)', MODELS, "[submit stdin]"),
 ("M5 a separator every hour", D, "    static let separatorGap: TimeInterval = 10 * 60", "    static let separatorGap: TimeInterval = 60 * 60", MODELS, "[separators]"),
 ("M6 the N new line under its separator", D,
  '            if item.id == firstNew, newCount > 0 { rows.append(.newLine(id: "new-" + item.id, count: newCount)) }\n            let time',
  '            let time', MODELS, "[new line]"),
 ("M7 Undo and Move doubled as primary", D, "        return (primary, plain.filter { $0 != primary })", "        return (primary, plain)", MODELS, "[buttons]"),
 ("M8 a superseded receipt keeps its buttons", D, "        guard item.live else { return (nil, []) }\n", "", MODELS, "[buttons]"),
 ("M9 two drops at once", D, "        guard !sending else { return nil }\n", "", MODELS, "[send once]"),
 ("M10 a double tap undoes twice", D, "        guard !busyThreads.contains(thread) else { return false }\n", "", MODELS, "[undo once]"),
 ("M11 a late History answer wins", D, "        guard generation == historyGeneration else { return }\n", "", MODELS, "[history generation]"),
 ("M12 every read marks read", D, "        if fresh.contains(where: { $0.readAt == nil }), let last = fresh.last { await markRead(through: last.id) }",
  "        if let last = fresh.last { await markRead(through: last.id) }", MODELS, "[mark read]"),
 ("M13 an ask that did not start says nothing", D, "else { line = DropIt.askHeldLine; return }", "else { return }", MODELS, "[ask held]"),
 ("M14 turning it off keeps the chat", D, "        if !now.enabled { items = []; loaded = false; summary = DropIt.Summary(); newMark = nil }\n", "", MODELS, "[settings off]"),
 ("M15 any protocol is supported", M, "    var supported: Bool { protocolVersion == 1 }", "    var supported: Bool { protocolVersion != nil }", MODELS, "[capability]"),
 ("M16 an em dash in the words (checks)", D, 'static let footNothingOut = "A drop never sends anything to anyone."', 'static let footNothingOut = "A drop never sends anything — to anyone."', MODELS, "[copy]"),
 ("R1 the rail mark shows with Drop it off", D, "        guard available else { return .none }\n", "", MODELS, "[rail mark]"),
 ("R2 unread shows as a number", D, "        return summary.unread > 0 ? .dot : .none", "        return summary.unread > 0 ? .count(summary.unread) : .none", MODELS, "[rail mark]"),
 ("R3 an absent waiting reads as zero", D, 'waiting: details["waiting"]?.int.map { max(0, $0) })', 'waiting: details["waiting"]?.int ?? 0)', MODELS, "[rail mark]"),
 # The model, ⌘K and Settings with the whole app (Tests/DropItRender.swift check).
 ("W1 the chat opens with Drop it off", CM, "    func openDropItChat() {\n        guard status.dropIt.available else { return }\n", "    func openDropItChat() {\n", WIRING, "[route gate]"),
 ("W2 the route ignores the server", CM, "        dropItChatOpen && status.dropIt.available\n", "        dropItChatOpen\n", WIRING, "[route gate]"),
 ("W3 Settings off leaves the chat open", CM, "        if !now { closeDropItChat() }\n", "", WIRING, "[settings off]"),
 ("W4 ⌘K says Drop it with it off", S, '            if s.dropIt, let index = rows.lastIndex(where: { $0.id == "file" }) { rows[index] = dropRow }',
  '            if let index = rows.lastIndex(where: { $0.id == "file" }) { rows[index] = dropRow }', WIRING, "[command row off]"),
 ("W5 History's Back closes the chat", CM, "    func closeDropItHistory() {\n        dropItHistoryOpen = false\n", "    func closeDropItHistory() {\n        dropItHistoryOpen = false\n        dropItChatOpen = false\n", WIRING, "[history back]"),
 # Wiring pins (Tests/drop-it-pins.py).
 ("P1 the pinned row in Archive", W, "            if messagesSubview == .recent, model.status.dropIt.available {\n", "            if model.status.dropIt.available {\n", PINS, "[pinned row gate]"),
 ("P2 the pinned row with Drop it off", W, "            if messagesSubview == .recent, model.status.dropIt.available {\n", "            if messagesSubview == .recent {\n", PINS, "[pinned row gate]"),
 ("P3 the Recent list changes", W, "                                selectedTurnID = turn.id\n", "                                selectedTurnID = turn.id; model.dropIt.line = nil\n", PINS, "[messages unchanged]"),
 ("P4 File to Work's note changes", W, 'today.runNote = "Filed to the Work inbox."', 'today.runNote = "Filed."', PINS, "[messages unchanged]"),
 ("P5 the chat grows a sheet", V, "        .onDisappear { store.closed() }\n", "        .onDisappear { store.closed() }\n        .sheet(isPresented: .constant(false)) { EmptyView() }\n", PINS, "[inline]"),
 ("P6 a drop logs its words", D, "        sending = true\n", "        sending = true\n        print(text)\n", PINS, "[no logs]"),
 ("P7 Back skips History", W, "        } else if section == .messages, model.dropItHistoryRouteActive {\n            model.closeDropItHistory()\n", "", PINS, "[back]"),
 ("P8 a tab switch keeps the chat", W, "        // 0.5.370: the COS chat and History are Messages routes; a tab switch closes them like any detail.\n        model.closeDropItChat()\n", "", PINS, "[tab switch]"),
 ("P9 Option-Return drops on a server with it off", W, "guard model.status.dropIt.available else { todaySubmitAsk(words); return }", "guard model.status.dropIt.supported else { todaySubmitAsk(words); return }", PINS, "[command action]"),
 ("P10 the switch for every server", VW, "if model.status.dropIt.supported { DropItSettingRow(model: model, store: model.dropIt) }", "DropItSettingRow(model: model, store: model.dropIt)", PINS, "[settings row]"),
 ("P11 Back to the chat shows on the chat", W, ", !showingSettings, !(section == .messages && model.dropItChatRouteActive) {", ", !showingSettings {", PINS, "[deep links]"),
 ("P12 the release build lacks the new files", "scripts/build-release.sh", ' "$ROOT/Sources/DropIt.swift" "$ROOT/Sources/DropItViews.swift"', "", PINS, "[source lists]"),
 ("P13 an em dash in the words (pins)", D, 'static let footNothingOut = "A drop never sends anything to anyone."', 'static let footNothingOut = "A drop never sends anything — to anyone."', PINS, "[copy]"),
 ("P15 the rail reads the summary with Drop it off", W, ".task(id: model.status.dropIt.available ? Int(now.timeIntervalSince1970 / 30) : -1) {\n            if model.status.dropIt.available { await model.dropIt.refreshSummary() }",
  ".task(id: Int(now.timeIntervalSince1970 / 30)) {\n            await model.dropIt.refreshSummary()", PINS, "[rail mark]"),
 ("P14 the words on stdin no more", D, '        return (call("history"), data)', '        return (call("history", [words]), data)', PINS, "[stdin]"),
 # The helper (Tests/drop-it-helper-checks.py against the compiled helper).
 ("H5 the helper drops waiting", H, '            if let waiting = dropItInt(body["waiting"]) { out["waiting"] = max(0, waiting) }\n', "", HELPER, "summary carries waiting"),
 ("H1 the helper reads no words for a drop", H, 'let takesStdin: Set<String> = ["submit", "history", "move"]', 'let takesStdin: Set<String> = ["history", "move"]', HELPER, "submit posts exactly"),
 ("H2 drop_it_off reads as answered", H, '?["code"] as? String == "drop_it_off" ? "off" : "answered"', '?["code"] as? String == "drop_it_off" ? "answered" : "answered"', HELPER, "drop_it_off is off"),
 ("H3 a drop's route crosses", H, '                                  "canUndo": dropItBool(raw["canUndo"]) ?? false]\n',
  '                                  "canUndo": dropItBool(raw["canUndo"]) ?? false, "route": raw["route"] ?? NSNull()]\n', HELPER, "the drop keeps only the contract keys"),
 ("H4 control characters reach the server", H, "        guard !text.isEmpty, dropItPlain(text, max: dropItTextMax, newlines: true) != nil else { return nil }",
  "        guard !text.isEmpty else { return nil }", HELPER, "submit refuses"),
]
only = [part for part in os.environ.get("MUTATE_ONLY", "").split("|") if part]
if only: mutants = [m for m in mutants if any(part in m[0] for part in only)]
needed = {m[4] for m in mutants}
for name, cmd in (("pins", PINS), ("models", MODELS), ("wiring", WIRING), ("helper", HELPER)):
    if cmd not in needed: continue
    code, out = sh(cmd, LIMITS[name])
    if code != 0: print(f"BASELINE RED ({name}):\n{out[-3000:]}"); sys.exit(1)
    print(f"baseline {name}: green ({out.strip().splitlines()[-1][:120]})", flush=True)
results = []
files = sorted({m[1] for m in mutants})
before = {f: (root / f).read_text() for f in files}
for name, path, old, new, cmd, expect in mutants:
    p = root / path; src = p.read_text()
    n = src.count(old)
    if n != 1: results.append((name, f"NOT APPLIED (found {n}x)")); print(results[-1], flush=True); continue
    mutated = src.replace(old, new)
    p.write_text(mutated)
    landed = p.read_text() == mutated and mutated != src
    try:
        code, out = sh(cmd, LIMITS[lane(cmd)])
    finally:
        p.write_text(src)
    killed = code != 0
    hung = code is None
    by = expect in out or "[timeout]" in out or hung
    verdict = ("KILLED" if killed else "SURVIVED") + (" by a hang (timeout)" if hung else f" by {expect}" if killed and expect in out else " by [timeout]" if killed and by else " (other failure)" if killed else "") + ("" if landed else " (MUTATION DID NOT LAND)")
    results.append((name, verdict))
    print(f"{verdict:70s} {name}", flush=True)
    if killed and not by: print(out[-1500:])
print("\nsummary:")
for name, r in results: print(f"{r:70s} {name}")
print("sources restored:", all((root / f).read_text() == text for f, text in before.items()))
killed = sum(1 for _, r in results if r.startswith("KILLED by") and "DID NOT LAND" not in r)
print(f"mutants: {killed} of {len(results)} killed by their named check")
sys.exit(0 if killed == len(results) else 1)
