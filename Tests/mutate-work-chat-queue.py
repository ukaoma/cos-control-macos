#!/usr/bin/env python3
"""0.5.316 mutation gate for the Work chat queue: Queue it, Send in parallel, Check first, the setting, Plan and send,
the app-wide pump and the older-server fallback.

    python3 Tests/mutate-work-chat-queue.py <control worktree> [name ...]   (run by hand, never by a gate)

SERIAL by design: one hub compile at a time, each through Tests/compile-guard.sh (never parallel; see the 2026-10-07
kernel panics). Works on a scratch copy of Sources/, Tests/ and HelperSources/, so an interrupted run never leaves the
checkout mutated. A GREEN baseline is required before the first mutant. Each mutant must land exactly once and make the
hub checks FAIL. Exits non-zero on any MISSING target or any SURVIVOR.
"""
import pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]).resolve(); only = set(sys.argv[2:])
C = "Sources/WorkTaskChat.swift"; S = "Sources/WorkHandoffStore.swift"; Q = "Sources/WorkChatQueue.swift"; H = "HelperSources/main.swift"; V = "Sources/Views.swift"
EXPECTED_SURVIVORS = set()
MUTANTS = [
 # Queue it: a queued assignment dispatches only after the blocker resolves.
 ("queued sends while held", C, '                let held = await heldBy(parallel: parallel, assignment: assignment, round: round, source: source, handoff: handoff)\n                guard held.isEmpty else {',
  '                let held = wasQueued ? [] : await heldBy(parallel: parallel, assignment: assignment, round: round, source: source, handoff: handoff)\n                guard held.isEmpty else {'),
 ("queue never sends", C, 'await dispatch(roundID: round.id, assignmentIDs: waiting, source: source, handoff: handoff, hold: .queue)', 'await dispatch(roundID: round.id, assignmentIDs: [], source: source, handoff: handoff, hold: .queue)'),
 ("queue does not hold the round", C, '        if assignments.contains(where: { $0.state == WorkChatHold.queuedState }) { return WorkChatHold.queuedState }\n', ''),
 ("queue does not survive restart", C, '        waitingOn = try c.decodeIfPresent([String].self, forKey: .waitingOn)\n', ''),
 ("queue skips its waiting list", C, '                        self.record?.rounds[index].assignments[n].waitingOn = held.map(\\.id)\n                        self.record?.rounds[index].assignments[n].parallel = parallel\n                        self.record?.rounds[index].assignments[n].detail = ""\n                        let id = assignment.receiptID\n                        workChatLog.info("assignment \\(id, privacy: .public) queued behind',
  '                        self.record?.rounds[index].assignments[n].parallel = parallel\n                        self.record?.rounds[index].assignments[n].detail = ""\n                        let id = assignment.receiptID\n                        workChatLog.info("assignment \\(id, privacy: .public) queued behind'),
 ("cancel keeps it queued", C, '            record?.rounds[r].assignments[n].state = "Not sent"; record?.rounds[r].assignments[n].waitingOn = nil', '            record?.rounds[r].assignments[n].waitingOn = nil'),
 ("pump ignores an open card", Q, '                  !Self.isShown(saved.workID), let source = cards[saved.workID] else { continue }', '                  let source = cards[saved.workID] else { continue }'),
 ("open card never reads the pump", C, '        bytes = disk; record = saved\n', '        bytes = disk\n'),
 # Re-checks at dispatch.
 ("queued skips the revision check", C, 'fresh["workRevision"]?.string == round.revision else { return nil }', '(fresh["workRevision"]?.string == round.revision || round.state == WorkChatHold.queuedState) else { return nil }'),
 ("stale plan keeps it queued", C, '        for n in record!.rounds[index].assignments.indices where record!.rounds[index].assignments[n].state == WorkChatHold.queuedState {\n            unqueue(index, n)\n', '        for n in record!.rounds[index].assignments.indices where record!.rounds[index].assignments[n].state == WorkChatHold.queuedState {\n'),
 # Send in parallel never sends twice into one busy session.
 ("parallel ignores its own session", C, '        if parallel { return await handoff.taskChatSessionBlockers(sessionID: assignment.sessionID, orchestrationRunID: round.id) }', '        if parallel { return [] }'),
 ("parallel waits for the whole card", C, '        if parallel { return await handoff.taskChatSessionBlockers(sessionID: assignment.sessionID, orchestrationRunID: round.id) }', '        if false { return [] }'),
 ("session blockers are the whole card", C, '        rows.filter { onSession($0, sessionID) && holds(', '        rows.filter { holds('),
 ("submit session fence open", S, 'guard !receipts.contains(where: { WorkChatPreflight.onSession($0, session.id) && WorkChatPreflight.holds(', 'guard true || !receipts.contains(where: { WorkChatPreflight.onSession($0, session.id) && WorkChatPreflight.holds('),
 ("parallel not sent with the session fence", C, 'contextFileIDs:fileIDs,sessionFence:parallel)', 'contextFileIDs:fileIDs,sessionFence:false)'),
 ("parallel choice queues instead", C, '        await dispatch(roundID: pending.roundID, assignmentIDs: pending.assignmentIDs, source: source, handoff: handoff, hold: choice)', '        await dispatch(roundID: pending.roundID, assignmentIDs: pending.assignmentIDs, source: source, handoff: handoff, hold: .queue)'),
 ("Check first queues", C, '        guard choice == .queue || choice == .parallel else { if !blockers.isEmpty { error = WorkChatPreflight.heading }; return }\n        busy = true; error = nil; blockers = []\n        defer { busy = false; phase = "" }\n        await dispatch(roundID: pending.roundID, assignmentIDs: pending.assignmentIDs, source: source, handoff: handoff, hold: choice)',
  '        guard choice != .ask else { return }\n        busy = true; error = nil; blockers = []\n        defer { busy = false; phase = "" }\n        await dispatch(roundID: pending.roundID, assignmentIDs: pending.assignmentIDs, source: source, handoff: handoff, hold: choice == .stop ? .queue : choice)'),
 ("onSession misses the session", C, '        if let id = row.sessionID, ClaudeSession.sameSession(id, sessionID) { return true }\n', ''),
 # The setting: Queue it by default; Ask each time asks; Check first is the old fence.
 ("default is Ask each time", Q, '    static let settingDefault = queueSetting\n', '    static let settingDefault = askSetting\n'),
 ("Queue it shows the wall", Q, '        return setting == askSetting ? .ask : .queue', '        return setting == askSetting ? .ask : .stop'),
 ("Ask each time never asks", Q, '        return setting == askSetting ? .ask : .queue', '        return .queue'),
 ("the store ignores the setting", C, 'WorkChatHold.onHold(setting: setting ?? WorkChatHold.storedSetting(), autoSend: autoSend', 'WorkChatHold.onHold(setting: setting ?? WorkChatHold.askSetting, autoSend: autoSend'),
 ("held send planned anyway on the fence", C, 'guard held.isEmpty || hold != .stop else { blockers = held; error = WorkChatPreflight.heading; return }', 'if !held.isEmpty && hold == .stop { blockers = held }'),
 # Plan and send queues instead of bypassing.
 ("Plan and send asks", Q, '        if autoSend { return .queue }\n', ''),
 ("Plan and send goes parallel", Q, '        if autoSend { return .queue }\n', '        if autoSend { return .parallel }\n'),
 # Older server: today's behaviour.
 ("old server offered the queue", C, '                queueOffered = caps["queueRounds"]?.bool == true; serverQueueMissing = !queueOffered', '                queueOffered = true; serverQueueMissing = false'),
 ("old server not named", C, '                queueOffered = caps["queueRounds"]?.bool == true; serverQueueMissing = !queueOffered', '                queueOffered = caps["queueRounds"]?.bool == true; serverQueueMissing = false'),
 ("openWork sent to an older server", C, 'open:hold == .stop ? nil : held)', 'open:held)'),
 ("openWork never true", C, '            if let open { row["openWork"] = open.contains { WorkChatPreflight.onSession($0, session.id) } }', '            if let open { row["openWork"] = open.isEmpty }'),
 ("queue on a sample card", C, 'offered: queueOffered && !handoff.isolated)', 'offered: queueOffered || handoff.isolated)'),
 # Reference links (Miles 2026-10-16 12:16).
 ("reference becomes a send target", C, 'handoff.observedSessions().filter { handoff.confirmedSessionCards[$0.id]?.workID == source.id }', 'handoff.observedSessions().filter { handoff.confirmedSessionCards[$0.id]?.workID == source.id || handoff.referenceLinks[$0.id.lowercased()]?.contains { r in r.workID == source.id } == true }'),
 ("references unbounded", S, '.suffix(WorkChatPolicy.maxReferences)', '.suffix(100)'),
 ("references sent to an older server", C, '        if referencesOffered, !handoff.isolated, mode == "plan" {', '        if !handoff.isolated, mode == "plan" {'),
 ("reference evidence ungated", S, '        guard referencesOffered, !isolated else { return [] }', '        guard !isolated else { return [] }'),
 ("manual handoff drops references", "Sources/WorkHandoffView.swift", '        sendingPrompt += store.referenceBlock(', '        _ = store.referenceBlock('),
 ("manual handoff never told the capability", C, 'referencesOffered = caps["references"]?.bool == true; handoff.referencesOffered = referencesOffered', 'referencesOffered = caps["references"]?.bool == true'),
 ("reference capability ignored", C, 'referencesOffered = caps["references"]?.bool == true; handoff.referencesOffered = referencesOffered', 'referencesOffered = true; handoff.referencesOffered = true'),
 ("references left out of the items", C, 'files: files, priors: priors + references,', 'files: files, priors: priors,'),
 ("reference outputs dropped", S, '            if let outputs = found?.outputs, !outputs.isEmpty { result.append(', '            if false, let outputs = found?.outputs, !outputs.isEmpty { result.append('),
 ("reference on its own working card", S, '        guard confirmedSessionCards[sessionID]?.workID != source.id else {', '        guard true else {'),
 ("working link rule open", "Sources/WorkSessionLinks.swift", '            guard current == expected else { throw Failure.conflict }\n            links[sessionID] = link', '            links[sessionID] = link'),
 ("reference added twice", "Sources/WorkSessionLinks.swift", '            if rows.contains(where: { $0.workID == link.workID }) { return refs }\n', ''),
 ("helper drops references", H, '"references": body["references"] as? Bool == true])', '"references": false])'),
 ("Link as reference ungated", "Sources/WorkWorkspaceView.swift", 'if taskChat.referencesOffered, linked?.workID != task.workSourceID {', 'if linked?.workID != task.workSourceID {'),
 # 0.5.317: the cleared-receipt report, the summary that held refreshing, loading states.
 ("cleared handoff holds the card", S, 'nonisolated static let terminalStatuses: Set<String> = ["completed", "failed", "refused", "canceled", "reviewed"]', 'nonisolated static let terminalStatuses: Set<String> = ["completed", "failed", "refused", "canceled"]'),
 ("summary holds refreshing", C, '        refreshing = false\n        summarizing = true; defer { summarizing = false }', '        summarizing = true; defer { summarizing = false }'),
 ("plan overlaps a summary", C, '        while summarizing { try? await Task.sleep(for: .milliseconds(250)) }\n', ''),
 ("loading flag never set", S, 'defer { busy = false; if !refreshedOnce { refreshedOnce = true } }', 'defer { busy = false }'),
 ("loading never shown", S, '    var sessionsKnown: Bool { refreshedOnce || activityCheckedAt != nil }', '    var sessionsKnown: Bool { true }'),
 ("no automatic re-check", C, '                await chat.recheckBlockers(source:source,handoff:handoff,automatic:true)\n', ''),
 ("history waits for the session read", C, '            if handoff.isolated || handoff.taskChatServerID != nil { chat.open(source:source,handoff:handoff) }\n', ''),
 # Wiring the hub checks cannot execute (pinned in run-work-session-hub.sh).
 ("helper drops queueRounds", H, '"queueRounds": body["queueRounds"] as? Bool == true,', '"queueRounds": false,'),
 ("Settings switch removed", V, 'COSDropdown("When earlier work is still open", selection: $workChatWhenHeld,', 'COSDropdown("When earlier work is open", selection: $workChatWhenHeld,'),
 ("open card never pumps", C, '                await chat.pumpQueued(source:source,handoff:handoff)\n', ''),
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

work = pathlib.Path(tempfile.mkdtemp(prefix="cos-work-queue-mutants-", dir="/private/tmp"))
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
    print("PASS Work chat queue mutation gate: every mutant killed")
finally:
    shutil.rmtree(work, ignore_errors=True)
