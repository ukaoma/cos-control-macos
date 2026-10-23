#!/usr/bin/env python3
"""0.5.333 mutation gate for lens plans (server 6.83.0 lensPlans: the inbox pump, history rounds From glasses, sends through
Send's own dispatch, results, the per-card Auto-send and two-step rule, Stop).

    python3 Tests/mutate-work-lens-plans.py <control worktree> [--tier pure|hub] [name ...]   (run by hand, never by a gate)

Two tiers, each on a scratch copy of Sources/, Tests/, HelperSources/ and scripts/ (an interrupted run never leaves the
checkout mutated), each with a GREEN baseline before its first mutant:
  pure  Tests/run-work-lens-plans.sh: WorkLensPlans.swift and its checks (a two-file compile) and the wiring pins.
  hub   Tests/run-work-session-hub.sh with the lens plans and orchestrator pins taken out of the copy, so a kill there is the
        real pump and stores failing an execution check (WorkLensPlansStoreChecks), not a text pin. One full compile at a
        time: each run waits until no other swift-frontend runs on this Mac (2026-10-07 kernel panics).
A kill must be NAMED: a "FAIL <check>" line, a pin's message, or a "Precondition failed: <message>" line. A compile error
is an invalid experiment, never a kill. Each target must appear exactly once. Exits non-zero on any MISSING, INVALID or
SURVIVED mutant.
"""
import pathlib, re, shutil, subprocess, sys, tempfile, time
args = sys.argv[1:]
root = pathlib.Path(args.pop(0)).resolve()
tier_only = None
if "--tier" in args: i = args.index("--tier"); tier_only = args[i + 1]; del args[i:i + 2]
only = set(args)
L = "Sources/WorkLensPlans.swift"; P = "Sources/WorkLensPlansPump.swift"; C = "Sources/WorkTaskChat.swift"; H = "HelperSources/main.swift"; M = "Sources/ControllerModel.swift"
MUTANTS = [
 # pure: the rules
 ("pure", "any confirm counts", L, '    static func maySend(confirm: String?, cardAutoSend: Bool) -> Bool { confirm == "two-step" || cardAutoSend }', '    static func maySend(confirm: String?, cardAutoSend: Bool) -> Bool { confirm != nil || cardAutoSend }'),
 ("pure", "card Auto-send ignored", L, '    static func maySend(confirm: String?, cardAutoSend: Bool) -> Bool { confirm == "two-step" || cardAutoSend }', '    static func maySend(confirm: String?, cardAutoSend: Bool) -> Bool { confirm == "two-step" }'),
 ("pure", "queued reads as sent", L, '        case queuedState: return "held"', '        case queuedState: return "sent"'),
 ("pure", "a refused send reads as waiting", L, '        case "Not sent": return attempted ? "refused" : "pending"', '        case "Not sent": return "pending"'),
 ("pure", "an unconfirmed delivery is offered again", L, '        case "queued", "running", "sending", "unknown", "No delivery receipt": return "sent"', '        case "queued", "running", "sending": return "sent"'),
 ("pure", "Stop reads as refused", L, '        case "Skipped", "canceled": return "stopped"', '        case "Skipped", "canceled": return "refused"'),
 ("pure", "cursor skips an unwritten round", L, "{ allWritten ? max(current, answered) : current }", "{ max(current, answered) }"),
 ("pure", "ids out of order written", L, '            guard a.id == "a\\(i + 1)", a.prompt.count <= 6000 else { return false }', '            guard a.prompt.count <= 6000 else { return false }'),
 ("pure", "New session on any provider", L, '            case "newSession": guard ["claude", "codex"].contains(a.provider ?? ""), a.sessionID == nil else { return false }', '            case "newSession": guard a.sessionID == nil else { return false }'),
 ("pure", "unknown mode written", L, "            default: return false\n", "            default: break\n"),
 ("pure", "a refusal says nothing", L, '        case "refused": return fallback.map { String($0.prefix(200)) } ?? "COS Control did not send it."', '        case "refused": return fallback'),
 ("pure", "details unbounded", L, "        if !text.isEmpty { return String(text.prefix(200)) }", "        if !text.isEmpty { return text }"),
 ("pure", "label never names the day", L, '        f.dateFormat = cal.isDate(at, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"', '        f.dateFormat = "h:mm a"'),
 # pure tier also runs the wiring pins
 ("pure", "helper drops the capability", H, '"lensPlans": body["lensPlans"] as? Int == 1])', '"lensPlans": false])'),
 ("pure", "inbox on the wrong path", H, 'return "/api/work/chat/lens-inbox?since=\\(since)&autoSend=\\(autoSend)"', 'return "/api/work/chat/lens-rounds?since=\\(since)&autoSend=\\(autoSend)"'),
 ("pure", "pump never started", M, "            lens.start()\n", ""),
 ("pure", "open card not registered", C, "            WorkTaskChatStore.register(chat, for: source.id); defer { WorkTaskChatStore.unregister(chat, for: source.id) }\n", ""),
 # hub: the real pump and stores against the fake helper (execution checks only)
 ("hub", "older server polled", P, "        guard offered else { return }\n", ""),
 ("hub", "lens send skips the card rule", C, "        guard WorkLensPlans.maySend(confirm: send.confirm, cardAutoSend: cardAutoSend) else {", "        guard true else {"),
 ("hub", "lens send never dispatched", C, "        await dispatch(roundID: current.rounds[index].id, assignmentIDs: ids, source: source, handoff: handoff, hold: holdChoice(nil, autoSend: true, handoff: handoff))", "        _ = ids"),
 ("hub", "held lens send never queues", C, "assignmentIDs: ids, source: source, handoff: handoff, hold: holdChoice(nil, autoSend: true, handoff: handoff))", "assignmentIDs: ids, source: source, handoff: handoff, hold: .stop)"),
 ("hub", "round not marked From glasses", C, "            round.origin = WorkLensPlans.origin; round.lensRoundID = lens.roundId", "            round.lensRoundID = lens.roundId"),
 ("hub", "round written twice", C, "        if current.rounds.contains(where: { $0.lensRoundID == lens.roundId }) { return true }\n", ""),
 ("hub", "round lacks the task revision", C, "            round.revision = revision; round.linkDigest =", "            round.linkDigest ="),
 ("hub", "plan's own targets missing", C, "            if lens.orchestrator == true {", "            if false {"),
 ("hub", "history never reported", P, "        guard await postHistory(round.roundId, autoSendCard: on) else { return false }", "        _ = on"),
 ("hub", "card switch never re-reported", P, "            guard entry.on != on else { continue }\n", "            continue\n"),
 ("hub", "results never reported", P, "            await report(send.sendRequestId, results)\n", ""),
 ("hub", "progress never reported", P, "            let changed = results.filter { t.last[$0.id] != $0.state }", "            let changed: [WorkLensPlans.Result] = []"),
 ("hub", "lens stop never reaches Stop", C, "            await self.stop(roundID: round.id, assignmentID: a.receiptID, handoff: handoff)", "            _ = a"),
 ("hub", "no Stop on rounds sent from the glasses", C, "round.sentWithoutReview == true || round.sentFromGlasses == true)", "round.sentWithoutReview == true)"),
 # QA on 6.10.651: Miles's own Send of a lens round on the Mac is reported, so the lens never sends it twice.
 ("hub", "Mac send never reported", C, "        if !lensDispatching, let lensRound = self.record?.rounds[index].lensRoundID { Self.onLensMacSend?(record.workID, lensRound) }\n", ""),
 ("hub", "Mac report includes lens sends", C, "lensIDs?.contains(id) ?? true, !macOnly || a.lensSendID == nil else { return nil }", "lensIDs?.contains(id) ?? true else { return nil }"),
 ("hub", "Mac held not reported", P, '.filter { !["pending", "refused"].contains($0.state) }', '.filter { !["pending", "refused", "held"].contains($0.state) }'),
 ("hub", "lens send flagged as a Mac send", C, "        lensDispatching = true; defer { lensDispatching = false }\n", ""),
]
EXPECTED_SURVIVORS = {
    # Defense in depth: a lens send that also fired the Mac-send hook reports nothing, because the Mac report reads only
    # assignments no lens send request sent (macOnly), which "Mac report includes lens sends" proves is checked.
    "lens send flagged as a Mac send",
}

def idle():
    while subprocess.run(["pgrep", "-x", "swift-frontend"], capture_output=True).returncode == 0: time.sleep(15)

def run(work, tier):
    idle()
    script = "Tests/run-work-lens-plans.sh" if tier == "pure" else "Tests/run-work-session-hub.sh"
    r = subprocess.run(["/bin/zsh", str(work / script)], cwd=work, capture_output=True, text=True)
    out = r.stdout + r.stderr
    named = next((l.strip() for l in out.splitlines() if l.startswith("FAIL ") or "Precondition failed" in l or l.startswith("AssertionError") or l.strip().startswith("FAIL work lens plans pins")), "")
    if named.startswith("FAIL work lens plans pins"):
        idx = out.splitlines().index(next(l for l in out.splitlines() if l.strip().startswith("FAIL work lens plans pins")))
        named = "PIN: " + out.splitlines()[idx + 1].strip()
    compile_error = next((l.strip() for l in out.splitlines() if " error: " in l), "")
    return r.returncode, named, compile_error, out

results = {"killed": [], "survived": [], "invalid": [], "missing": [], "expected": []}
for tier in ("pure", "hub"):
    if tier_only and tier != tier_only: continue
    chosen = [m for m in MUTANTS if m[0] == tier and (not only or m[1] in only)]
    if not chosen: continue
    work = pathlib.Path(tempfile.mkdtemp(prefix=f"cos-work-lens-plans-{tier}-", dir="/private/tmp"))
    try:
        for folder in ("Sources", "Tests", "HelperSources", "scripts"): shutil.copytree(root / folder, work / folder, ignore=shutil.ignore_patterns("__pycache__"))
        if tier == "hub":
            hub = work / "Tests/run-work-session-hub.sh"; text = hub.read_text()
            for line in ('zsh "$ROOT/Tests/run-work-lens-plans.sh"\n', 'zsh "$ROOT/Tests/run-work-orchestrator.sh"\n'):
                assert text.count(line) == 1, f"the hub runner must call {line.strip()} exactly once"
                text = text.replace(line, "")
            hub.write_text(text); print("hub tier: lens plans and orchestrator pins taken out of the copy; kills here are execution checks")
        code, named, cerr, out = run(work, tier)
        if code != 0: sys.exit(f"{tier} baseline is not green; refusing to mutate:\n" + out[-3000:])
        print(f"{tier} baseline green")
        for _, name, f, a, b in chosen:
            p = work / f; src = p.read_text()
            if src.count(a) != 1: print(f"MISSING  {name}: target appears {src.count(a)} times"); results["missing"].append(name); continue
            mutated = src.replace(a, b)
            assert mutated != src
            p.write_text(mutated)
            try: code, named, cerr, _ = run(work, tier)
            finally: p.write_text(src)
            assert p.read_text() == src
            if code != 0 and named: print(f"KILLED   [{tier}] {name}  [{named[:160]}]"); results["killed"].append(name)
            elif code != 0: print(f"INVALID  [{tier}] {name}  [{cerr[:160] or 'no named failure'}]"); results["invalid"].append(name)
            elif name in EXPECTED_SURVIVORS: print(f"SURVIVED [{tier}] {name} (expected, documented)"); results["expected"].append(name)
            else: print(f"SURVIVED [{tier}] {name}"); results["survived"].append(name)
    finally:
        shutil.rmtree(work, ignore_errors=True)
print(f"work lens plans mutants: {len(results['killed'])} killed by a named check, {len(results['expected'])} expected survivors, "
      f"{len(results['survived'])} survived, {len(results['invalid'])} invalid, {len(results['missing'])} missing")
if results["survived"] or results["invalid"] or results["missing"]: sys.exit(f"gate failed: {results}")
