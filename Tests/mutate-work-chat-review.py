#!/usr/bin/env python3
"""0.5.308/0.5.310 mutation gate for Work chat review-before-send, pre-flight, honest round states and planner choice.

    python3 Tests/mutate-work-chat-review.py <control worktree> [name ...]   (run by hand, never by a gate)

SERIAL by design: one hub compile at a time, each through Tests/compile-guard.sh (never parallel; see the 2026-10-07
kernel panics). Works on a scratch copy of Sources/, Tests/ and HelperSources/ (the hub runner pins read the helper), so an interrupted run never leaves the checkout mutated.
A GREEN baseline is required before the first mutant. Each mutant must land exactly once and make the hub checks FAIL.
Exits non-zero on any MISSING target or any SURVIVOR other than the one documented expected survivor below.
"""
import os
import pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]).resolve(); only = set(sys.argv[2:])
C = "Sources/WorkTaskChat.swift"; S = "Sources/WorkHandoffStore.swift"; M = "Sources/WorkContextMeter.swift"; F = "Sources/WorkCardFiles.swift"
# Defense in depth: the "Not sent" state guard and submit's intent-id refusal both stop a resend, so removing this one
# guard alone cannot change behaviour. Any other survivor fails the gate.
EXPECTED_SURVIVORS = {"sent receipt guard (expected survivor: state guard and submit intent id back it up)"}
MUTANTS = [
 ("plan dispatches state", C, 'answer.assignments.isEmpty ? "Answered" : "Ready to send"', 'answer.assignments.isEmpty ? "Answered" : "Dispatched"'),
 ("no pre-flight before planning", C, 'guard held.isEmpty || hold != .stop else { blockers = held; error = WorkChatPreflight.heading; return }', 'if !held.isEmpty { blockers = held }'),
 # 0.5.317: the held branch is a switch on WorkChatHold; .stop is today's fence.
 ("no pre-flight before a send", C, '                guard held.isEmpty else {\n                    if wasQueued {', '                guard held.isEmpty || hold == .stop else {\n                    if wasQueued {'),
 ("no revision check (isolated)", C, 'guard source.revision == round.revision else { return nil }', ''),
 ("no revision check (live)", C, 'fresh["workRevision"]?.string == round.revision else { return nil }', 'true else { return nil }'),
 ("no attachment check", C, 'guard attachments.digest == round.attachmentDigest else { return nil }', ''),
 ("no links check", C, 'guard try WorkChatPolicy.linksDigest(handoff.confirmedSessionCards,workID:source.id) == round.linkDigest else { return nil }', ''),
 ("Not now still sends", C, 'let index = record.rounds.firstIndex(where: { $0.id == roundID }),\n              ["Ready to send", WorkChatHold.queuedState].contains(record.rounds[index].state) else { return }', 'let index = record.rounds.firstIndex(where: { $0.id == roundID }) else { return }'),
 ("sent state guard", C, 'let current = self.record?.rounds[index].assignments[n], ["Not sent", WorkChatHold.queuedState].contains(current.state),', 'let current = self.record?.rounds[index].assignments[n],'),
 ("sent receipt guard (expected survivor: state guard and submit intent id back it up)", C, '                  !handoff.receipts.contains(where: { $0.id == assignmentID }) else { continue }', '                  true else { continue }'),
 ("edit unvalidated", C, 'guard WorkChatPolicy.validPrompt(text) else {', 'guard true else {'),
 ("edit not trimmed", C, 'let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard WorkChatPolicy.validPrompt', 'let text = prompt\n        guard WorkChatPolicy.validPrompt'),
 ("valid prompt allows blank", C, '!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.count <= 2000', 'prompt.count <= 2000'),
 ("refusal stops the rest", C, '                    self.record?.rounds[index].assignments[n].detail = receipt.detail\n', '                    self.record?.rounds[index].assignments[n].detail = receipt.detail\n                    if receipt.status == "refused" { break sending }\n'),
 ("refusal reason dropped", C, '                    self.record?.rounds[index].assignments[n].detail = receipt.detail\n', ''),
 ("reviewed state ignores Not sent", C, 'if assignments.contains(where: { ["Not sent", "Sending"].contains($0.state) }) { return "Ready to send" }', 'if assignments.contains(where: { ["Sending"].contains($0.state) }) { return "Ready to send" }'),
 ("all skipped reads not delivered", C, 'return assignments.allSatisfy { $0.state == "Skipped" } ? "Not sent" : "Not delivered"', 'return "Not delivered"'),
 ("refused reads dispatched (0.5.309 lie)", C, 'if assignments.contains(where: { reachedSession.contains($0.state) }) { return "Dispatched" }', 'if assignments.contains(where: { $0.state != "Skipped" }) { return "Dispatched" }'),
 ("unknown reads not delivered", C, '        if assignments.contains(where: { ["unknown", "No delivery receipt"].contains($0.state) }) { return "Delivery uncertain" }\n', ''),
 ("refused rounds become results", C, 'if sent.contains(where: { WorkChatPolicy.reachedSession.contains($0.state) }) && !["Ready to send"', 'if !sent.isEmpty && !["Ready to send"'),
 ("request claimed as ran", C, '        if reported.hasSuffix("(requested)") || (reported.isEmpty && requested != nil) {', '        if reported.isEmpty && requested != nil {'),
 ("no report claims the request", C, '        if reported.hasSuffix("(requested)") || (reported.isEmpty && requested != nil) {', '        if reported.hasSuffix("(requested)") {'),
 ("server model not recorded", C, 'self.record?.rounds[index].plannerModel = handoff.isolated ? nil : answer.model.map { String($0.prefix(100)) }', 'self.record?.rounds[index].plannerModel = nil'),
 ("discovery not retried", C, '                    do { try await Task.sleep(for: retryDelay) } catch {', '                    do { try await Task.sleep(for: retryDelay); break } catch {'),
 # 0.5.316 (Miles 2026-10-16 14:29): cancelled discovery, a backoff that swallowed cancellation, Plan not re-reading.
 ("cancelled discovery reads as a failure", C, '                if error is CancellationError || Task.isCancelled {', '                if false {'),
 ("backoff swallows cancellation", C, 'the planner choice is left as it was")\n                        return\n', 'the planner choice is left as it was")\n'),
 ("Plan never re-reads discovery", C, '        if !handoff.isolated, enabled, discovery != .loaded {', '        if false {'),
 ("discovery never marked loaded", C, '                discovery = .loaded\n                return\n', '                return\n'),
 # 0.5.316: the server runs one Work chat call at a time (409 work_chat_busy); Plan waits for an in-flight summary.
 ("Plan ignores the Work chat gate", C, '                guard await gate.acquire(waitingUpTo: busyWait) else {', '                guard true else {'),
 ("gate taken twice", C, '        guard !inFlight else { return false }\n', ''),
 ("gate kept after a plan", C, 'do { response = try await handoff.taskChatCall(["work-chat"],data:data); gate.release() }', 'do { response = try await handoff.taskChatCall(["work-chat"],data:data) }'),
 ("summary skips the gate", C, '                guard gate.tryAcquire() else { return }\n', ''),
 ("discovery failure hidden", C, 'handoff.referencesOffered = false; plannerNotice = WorkChatPolicy.plannerUnavailable', 'handoff.referencesOffered = false; plannerNotice = nil'),
 ("effort key always sent", C, 'if let effort { body["effort"] = effort }', 'body["effort"] = effort ?? "high"'),
 ("effort key never sent", C, 'if let effort { body["effort"] = effort }', ''),
 ("effort ignores choice", C, '        if let choice, offered.contains(choice) { return choice }\n        return offered.contains("high") ? "high" : nil', '        return offered.contains("high") ? "high" : nil'),
 ("effort trusts unknown", C, 'let offered = efforts.filter { advertised.contains($0) }', 'let offered = advertised'),
 ("efforts not filtered", C, 'efforts = WorkChatPolicy.efforts.filter { levels.contains($0) }', 'efforts = levels'),
 ("effort not sent with Plan", C, 'mode:"plan",planner:planner,effort:effort,items:chooses ? items : nil,open:', 'mode:"plan",planner:planner,items:chooses ? items : nil,open:'),
 ("reported effort not recorded", C, 'self.record?.rounds[index].plannerEffort = handoff.isolated ? nil : answer.effort.flatMap { WorkChatPolicy.efforts.contains($0) ? $0 : nil }', 'self.record?.rounds[index].plannerEffort = nil'),
 ("requested effort claimed", C, 'self.record?.rounds[index].plannerEffort = handoff.isolated ? nil : answer.effort.flatMap { WorkChatPolicy.efforts.contains($0) ? $0 : nil }', 'self.record?.rounds[index].plannerEffort = handoff.isolated ? nil : effort'),
 ("unknown effort shown", C, '        guard let effort, efforts.contains(effort) else { return base }', '        guard let effort else { return base }'),
 # 0.5.312 Work Context Meter
 ("text estimate rounds down", M, 'static func textTokens(_ text: String) -> Int { (text.count + 3) / 4 }', 'static func textTokens(_ text: String) -> Int { text.count / 4 }'),
 ("claude image ignores the 1568 edge", M, '        let edge = min(1, 1568 / max(w, h)); w *= edge; h *= edge\n', ''),
 ("claude image ignores the area cap", M, '        let area = min(1, (1_150_000 / (w * h)).squareRoot()); w *= area; h *= area\n', ''),
 ("codex image uses claude's rule", M, '        if provider == "codex" {\n            let fit', '        if provider == "none" {\n            let fit'),
 ("codex tiles ignore the short side", M, '            let short = min(1, 768 / min(w, h)); w *= short; h *= short\n', ''),
 ("video frames ignored", M, 'case "video": body = (frames ?? 0) * imageTokens(', 'case "video": body = 0 * imageTokens('),
 ("file line not counted", M, '        return body + fileLineTokens\n', '        return body\n'),
 ("duplicate files listed twice", M, 'for input in files where seen.insert(input.file.id).inserted {', 'for input in files where seen.insert(UUID().uuidString).inserted {'),
 ("empty prior results listed", M, 'for prior in priors where !prior.result.isEmpty {', 'for prior in priors {'),
 ("meetings not split", M, '            guard line.hasPrefix("- ") else { continue }\n', '            guard line.hasPrefix("+ ") else { continue }\n'),
 ("selection forgets the fixed items", M, '        let chosen = Set(ids).union(fixedIDs)\n        return items.filter', '        let chosen = Set(ids)\n        return items.filter'),
 ("no choice sends only the fixed items", M, '        guard let ids else { return items.map(\\.id) }', '        guard let ids else { return fixedIDs }'),
 ("unknown ids accepted", M, '        return Set(ids).count == ids.count && ids.allSatisfy(known.contains) && fixedIDs.allSatisfy(ids.contains)', '        return Set(ids).count == ids.count && fixedIDs.allSatisfy(ids.contains)'),
 ("fixed items removable", M, '        guard let item = items.first(where: { $0.id == itemID }), !item.fixed else { return nil }', '        guard let item = items.first(where: { $0.id == itemID }) else { return nil }'),
 ("codex sends use claude counts", M, '        provider == "codex" ? (item.codexTokens ?? item.estTokens) : item.estTokens', '        item.estTokens'),
 ("skipped assignments counted", M, '        assignments.filter { $0.state != "Skipped" }.reduce(0) {', '        assignments.reduce(0) {'),
 ("canary rounds wrong way", M, 'linked > 0 ? Int((Double(sent) / Double(linked) * 100).rounded()) : 0', 'linked > 0 ? Int(Double(sent) / Double(linked) * 100) - 1 : 0'),
 ("window guessed when unknown", M, '        guard let window, window.windowTokens > 0 else { return nil }', '        guard let window, window.windowTokens > 0 else { return ("0.0% of this session\'s window", false) }'),
 ("full session not warned", M, '        if used >= 0.85 {', '        if used >= 0.95 {'),
 ("prompt sends unselected meetings", M, '        let meetings = picked.filter { $0.kind == .meet }.compactMap(\\.text)', '        let meetings = items.filter { $0.kind == .meet }.compactMap(\\.text)'),
 ("prompt drops priors", M, '        if !priors.isEmpty { context +=', '        if priors.isEmpty { context +='),
 ("prompt lists unselected files", M, '        return (text, Set(picked.compactMap(\\.fileID)))', '        return (text, Set(items.compactMap(\\.fileID)))'),
 ("lists start expanded", M, 'static func isExpanded(_ stored: String, _ id: String) -> Bool { stored.split(separator: ",").contains { $0 == id } }', 'static func isExpanded(_ stored: String, _ id: String) -> Bool { !stored.split(separator: ",").contains { $0 == id } }'),
 ("memory unbounded", M, '        return ids.suffix(40).joined(separator: ",")', '        return ids.joined(separator: ",")'),
 ("server choice ignored", C, 'var a = a; a.contextItemIDs = WorkContextMeter.selection(chooses ? a.contextItemIDs : nil, items: items); return a', 'var a = a; a.contextItemIDs = WorkContextMeter.selection(nil, items: items); return a'),
 ("items sent to an older server", C, 'let chooses = !handoff.isolated && contextItemsOffered && items.count <= WorkContextMeter.maxItems', 'let chooses = !handoff.isolated && items.count <= WorkContextMeter.maxItems'),
 ("capability ignored", C, '                contextItemsOffered = caps["contextItems"]?.bool == true', '                contextItemsOffered = false'),
 ("edits not persisted", C, '        record?.rounds[r].assignments[n].contextItemIDs = next\n        return persist()', '        record?.rounds[r].assignments[n].contextItemIDs = next\n        return true'),
 ("edits allowed after sending", C, 'let n = record?.rounds[r].assignments.firstIndex(where: { $0.receiptID == assignmentID && $0.state == "Not sent" }),\n              let current = record?.rounds[r].assignments[n].contextItemIDs,', 'let n = record?.rounds[r].assignments.firstIndex(where: { $0.receiptID == assignmentID }),\n              let current = record?.rounds[r].assignments[n].contextItemIDs,'),
 ("send ignores the selection", C, '                    prompt = built.text; fileIDs = built.fileIDs', '                    fileIDs = built.fileIDs'),
 ("send lists every file", C, 'orchestrationRunID:round.id,intentID:assignment.receiptID,contextFileIDs:fileIDs,sessionFence:parallel)', 'orchestrationRunID:round.id,intentID:assignment.receiptID,contextFileIDs:nil,sessionFence:parallel)'),
 ("stale selection sent", C, '                    guard WorkContextMeter.validSelection(selected, items: items),', '                    guard true,'),
 ("file filter ignored", F, 'files(for: workID).filter { include?.contains($0.id) ?? true }', 'files(for: workID)'),
 ("meeting file filter ignored", F, '        if let include { groups = groups.map', '        if false, let include { groups = groups.map'),
 # 0.5.312 Plan and send
 ("send without review on by default", C, '    static let autoSendDefault = false\n', '    static let autoSendDefault = true\n'),
 ("first Plan and send not confirmed", C, '        if WorkChatPolicy.confirmBeforeAutoSend(acknowledged: autoSendAcknowledged) { confirmAutoSend = true; return }\n', ''),
 ("confirm rule never asks", C, 'static func confirmBeforeAutoSend(acknowledged: Bool) -> Bool { !acknowledged }', 'static func confirmBeforeAutoSend(acknowledged: Bool) -> Bool { false }'),
 ("acknowledgement not remembered", C, '                autoSendAcknowledged = true\n', ''),
 ("Plan and send bypasses the guards", C, 'await dispatch(roundID: roundID, assignmentIDs: answer.assignments.map(\\.receiptID), source: source, handoff: handoff, hold: hold)',
  'for a in answer.assignments { if let s = targets(handoff, source: source).first(where: { $0.id == a.sessionID }) { await handoff.submit(source: source, mode: .continueSession, session: s, model: nil, prompt: a.prompt, orchestrationRunID: roundID, intentID: a.receiptID) } }'),
 ("Plan and send never sends", C, '            if autoSend, !answer.assignments.isEmpty, let roundID', '            if false, autoSend, !answer.assignments.isEmpty, let roundID'),
 ("sent without review not recorded", C, '                self.record?.rounds[index].sentWithoutReview = true\n', ''),
 ("old server warned", C, 'planners = WorkChatPolicy.planners.filter { advertised.contains($0) }; plannerNotice = nil', 'planners = WorkChatPolicy.planners.filter { advertised.contains($0) }; plannerNotice = advertised.isEmpty ? WorkChatPolicy.plannerUnavailable : nil'),
 ("planner key always sent", C, 'if let planner { body["planner"] = planner }', 'body["planner"] = planner ?? "sonnet"'),
 ("planner key never sent", C, 'if let planner { body["planner"] = planner }', ''),
 ("planner ignores choice", C, '        if let choice, offered.contains(choice) { return choice }\n        return offered.contains("sonnet") ? "sonnet" : nil', '        return offered.contains("sonnet") ? "sonnet" : nil'),
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
 ("blockers oldest first", C, '.sorted { $0.createdAt > $1.createdAt }\n    }\n    /// 0.5.317: the handoffs that write', '.sorted { $0.createdAt < $1.createdAt }\n    }\n    /// 0.5.317: the handoffs that write'),
 ("submit bypasses fence", S, 'guard recovery != nil || !receipts(for: source.id).contains(where: { WorkChatPreflight.holds(', 'guard true || !receipts(for: source.id).contains(where: { WorkChatPreflight.holds('),
 ("submit drops continuations", S, '            if orchestrationRunID != nil { continuations = await taskChatContinuations(source: source) }\n', ''),
]

def idle():
    """Never start a compile while any other swift-frontend runs on this Mac (2026-10-07 panics)."""
    import time
    while subprocess.run(["pgrep", "-x", "swift-frontend"], capture_output=True).returncode == 0: time.sleep(15)

def run(work: pathlib.Path):
    idle()
    r = subprocess.run(["/bin/zsh", str(work / "Tests/run-work-session-hub.sh")], cwd=work, capture_output=True, text=True)
    out = r.stdout + r.stderr
    why = next((l.strip() for l in out.splitlines() if "Precondition failed" in l or "Fatal error" in l), "")
    if not why and "error:" in out: why = "COMPILE: " + next(l.strip() for l in out.splitlines() if "error:" in l)
    return r.returncode, why, out

work = pathlib.Path(tempfile.mkdtemp(prefix="cos-work-chat-mutants-", dir="/private/tmp"))
# Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    for folder in ("Sources", "Tests", "HelperSources"): shutil.copytree(root / folder, work / folder, ignore=shutil.ignore_patterns("__pycache__"))
    code, why, out = run(work)
    if code != 0: sys.exit("baseline is not green; refusing to mutate:\n" + out[-3000:])
    print("baseline green")
    missing, survivors = [], []
    for name, f, a, b in MUTANTS:
        if only and name not in only: continue
        p = work / f; src = p.read_text()
        if src.count(a) != 1: print(f"MISSING  {name}: target appears {src.count(a)} times"); missing.append(name); continue
        p.write_text(src.replace(a, b))
        try: code, why, _ = run(work)
        finally: p.write_text(src)
        print(("KILLED   " if code != 0 else "SURVIVED ") + name + (f"  [{why}]" if why else ""))
        if code == 0 and name not in EXPECTED_SURVIVORS: survivors.append(name)
    if missing or survivors: sys.exit(f"gate failed: missing={missing} survivors={survivors}")
    print("PASS Work chat mutation gate: every mutant killed except the documented expected survivor")
finally:
    shutil.rmtree(work, ignore_errors=True)
