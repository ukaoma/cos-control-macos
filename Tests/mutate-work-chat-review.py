#!/usr/bin/env python3
"""0.5.308 mutation lane for Work chat review-before-send, pre-flight and planner choice. SERIAL: one compile at a time.

    python3 Tests/mutate-work-chat-review.py <control worktree> [name ...]   (run by hand, never by a gate)

Proves the unmutated Tests/run-work-session-hub.sh green first, then applies each mutant (target must appear exactly once),
runs the lane, records the first "Precondition failed" line, and restores the file byte-exact. A mutant that lands and
passes is a finding.
"""
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve(); only = set(sys.argv[2:])
C = "Sources/WorkTaskChat.swift"; S = "Sources/WorkHandoffStore.swift"
MUTANTS = [
 ("plan dispatches state", C, 'answer.assignments.isEmpty ? "Answered" : "Ready to send"', 'answer.assignments.isEmpty ? "Answered" : "Dispatched"'),
 ("no pre-flight before planning", C, 'guard held.isEmpty else { blockers = held; error = WorkChatPreflight.heading; return }', 'if !held.isEmpty { blockers = held }'),
 ("no pre-flight before a send", C, 'guard held.isEmpty else { blockers = held; error = WorkChatPreflight.heading; break sending }', 'if !held.isEmpty { blockers = held }'),
 ("no revision check (isolated)", C, 'guard source.revision == round.revision else { return nil }', ''),
 ("no revision check (live)", C, 'fresh["workRevision"]?.string == round.revision else { return nil }', 'true else { return nil }'),
 ("no attachment check", C, 'guard attachments.digest == round.attachmentDigest else { return nil }', ''),
 ("no links check", C, 'guard try WorkChatPolicy.linksDigest(handoff.confirmedSessionCards,workID:source.id) == round.linkDigest else { return nil }', ''),
 ("Not now still sends", C, 'let index = record.rounds.firstIndex(where: { $0.id == roundID }), record.rounds[index].state == "Ready to send" else { return }', 'let index = record.rounds.firstIndex(where: { $0.id == roundID }) else { return }'),
 ("sent state guard", C, '                  self.record?.rounds[index].assignments[n].state == "Not sent",\n', ''),
 ("sent receipt guard (expected survivor: state guard and submit intent id back it up)", C, '                  !handoff.receipts.contains(where: { $0.id == assignmentID }) else { continue }', '                  true else { continue }'),
 ("edit unvalidated", C, 'guard WorkChatPolicy.validPrompt(text) else {', 'guard true else {'),
 ("edit not trimmed", C, 'let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard WorkChatPolicy.validPrompt', 'let text = prompt\n        guard WorkChatPolicy.validPrompt'),
 ("valid prompt allows blank", C, '!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.count <= 2000', 'prompt.count <= 2000'),
 ("refusal stops the rest", C, '                    self.record?.rounds[index].assignments[n].detail = receipt.detail\n', '                    self.record?.rounds[index].assignments[n].detail = receipt.detail\n                    if receipt.status == "refused" { break sending }\n'),
 ("refusal reason dropped", C, '                    self.record?.rounds[index].assignments[n].detail = receipt.detail\n', ''),
 ("reviewed state ignores Not sent", C, 'if assignments.contains(where: { ["Not sent", "Sending"].contains($0.state) }) { return "Ready to send" }', 'if assignments.contains(where: { ["Sending"].contains($0.state) }) { return "Ready to send" }'),
 ("all skipped reads dispatched", C, 'return assignments.contains(where: { $0.state != "Skipped" }) ? "Dispatched" : "Not sent"', 'return "Dispatched"'),
 ("planner key always sent", C, 'if let planner { body["planner"] = planner }', 'body["planner"] = planner ?? "sonnet"'),
 ("planner key never sent", C, 'if let planner { body["planner"] = planner }', ''),
 ("planner ignores choice", C, 'if let choice, offered.contains(choice) { return choice }', ''),
 ("planner trusts unknown", C, 'let offered = planners.filter { advertised.contains($0) }', 'let offered = advertised'),
 ("planners not filtered", C, 'planners = WorkChatPolicy.planners.filter { advertised.contains($0) }', 'planners = advertised'),
 ("fence: no run exemption", C, '        if orchestrationRunID != nil, row.orchestrationRunID == orchestrationRunID, row.sessionID != sessionID,\n', '        if false, row.orchestrationRunID == orchestrationRunID, row.sessionID != sessionID,\n'),
 ("fence: same session exempt", C, 'row.orchestrationRunID == orchestrationRunID, row.sessionID != sessionID,', 'row.orchestrationRunID == orchestrationRunID,'),
 ("fence: unknown exempt in run", C, '           ["running", "queued", "delivered"].contains(row.status) { return false }', '           ["running", "queued", "delivered", "unknown"].contains(row.status) { return false }'),
 ("fence: no continuation", C, 'if let proof = continuations[row.id], proof == (try? WorkChatPolicy.continuationKey(row)) { return false }', ''),
 ("fence: stale continuation accepted", C, 'if let proof = continuations[row.id], proof == (try? WorkChatPolicy.continuationKey(row)) { return false }', 'if continuations[row.id] != nil { return false }'),
 ("fence: no replacing", C, 'if row.id == replacing && row.status == "delivered" { return false }', ''),
 ("fence: terminal holds", C, '        guard row.blocksNewHandoff else { return false }\n', ''),
 ("blockers other cards", C, 'rows.filter { $0.workID == workID && holds(', 'rows.filter { holds('),
 ("blockers oldest first", C, '.sorted { $0.createdAt > $1.createdAt }\n    }\n    /// "Session title', '.sorted { $0.createdAt < $1.createdAt }\n    }\n    /// "Session title'),
 ("submit bypasses fence", S, 'guard recovery != nil || !receipts(for: source.id).contains(where: { WorkChatPreflight.holds(', 'guard true || !receipts(for: source.id).contains(where: { WorkChatPreflight.holds('),
 ("submit drops continuations", S, '            if orchestrationRunID != nil { continuations = await taskChatContinuations(source: source) }\n', ''),
]
def run():
    r = subprocess.run(["zsh", str(root / "Tests/run-work-session-hub.sh")], cwd=root, capture_output=True, text=True)
    out = r.stdout + r.stderr
    why = next((l.strip() for l in out.splitlines() if "Precondition failed" in l or "Fatal error" in l), "")
    if not why and "error:" in out: why = "COMPILE: " + next(l.strip() for l in out.splitlines() if "error:" in l)
    return r.returncode, why, out
code, why, out = run()
if code != 0: sys.exit("baseline is not green; refusing to mutate:\n" + out[-3000:])
print("baseline green")
for name, f, a, b in MUTANTS:
    if only and name not in only: continue
    p = root / f; src = p.read_text()
    if src.count(a) != 1: print(f"MISSING  {name}: target appears {src.count(a)} times"); continue
    p.write_text(src.replace(a, b))
    try: code, why, _ = run()
    finally: p.write_text(src)
    print(("KILLED   " if code != 0 else "SURVIVED ") + name + (f"  [{why}]" if why else ""))
