#!/usr/bin/env python3
"""0.5.333 mutation gate for the Work orchestrator (server 6.83.0 input, per-card Auto-send, Stop, fork child journal).

    python3 Tests/mutate-work-orchestrator.py <control worktree> [--tier pure|hub] [name ...]   (run by hand, never by a gate)

Two tiers, each on a scratch copy of Sources/, Tests/ and HelperSources/ (an interrupted run never leaves the checkout
mutated), each with a GREEN baseline before its first mutant:
  pure  Tests/run-work-orchestrator.sh: WorkOrchestrator.swift and its checks (a two-file compile) and the wiring pins.
  hub   Tests/run-work-session-hub.sh with the orchestrator pins taken out of the copy, so a kill there is the real store
        failing an execution check (WorkOrchestratorStoreChecks), not a text pin. One full compile at a time: each run
        waits until no other swift-frontend runs on this Mac (2026-10-07 kernel panics).
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
O = "Sources/WorkOrchestrator.swift"; C = "Sources/WorkTaskChat.swift"; S = "Sources/WorkHandoffStore.swift"; H = "HelperSources/main.swift"
MUTANTS = [
 # pure: the snapshot
 ("pure", "Guardian rows reach the server", O, "let rows = live.filter { !isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }.prefix(maxLive)", "let rows = live.prefix(maxLive)"),
 ("pure", "Guardian test ignores the title", O, 'id.hasPrefix("codex:") && (title.trimmingCharacters(in: .whitespaces) == "Guardian review"', 'id.hasPrefix("codex:") && (false'),
 ("pure", "receipts oldest first", O, '"receipts": receipts.sorted { $0.createdAt > $1.createdAt }', '"receipts": receipts.sorted { $0.createdAt < $1.createdAt }'),
 ("pure", "missing ids become empty text", O, "        func opt(_ s: String?) -> Any { s ?? NSNull() }", '        func opt(_ s: String?) -> Any { s ?? "" }'),
 ("pure", "unread list sent as empty", O, '        if let live, let checked = liveCheckedAt {', '        if true { let live = live ?? [], checked = liveCheckedAt ?? now'),
 # pure: Continue gate and rows
 ("pure", "Continue ignores the list", O, '["claude", "codex"].contains(row.provider) && row.live && row.reason == nil && controlAllows', '["claude", "codex"].contains(row.provider) && row.reason == nil && controlAllows'),
 ("pure", "Continue ignores the reason", O, '["claude", "codex"].contains(row.provider) && row.live && row.reason == nil && controlAllows', '["claude", "codex"].contains(row.provider) && row.live && controlAllows'),
 ("pure", "Continue ignores Control's rule", O, '["claude", "codex"].contains(row.provider) && row.live && row.reason == nil && controlAllows', '["claude", "codex"].contains(row.provider) && row.live && row.reason == nil'),
 ("pure", "openWork always sent", O, '            if let openWork { row["openWork"] = openWork(r.id) }', '            row["openWork"] = openWork?(r.id) ?? false'),
 # pure: never silent
 ("pure", "explains when a session can continue", O, "        if rows.contains(where: { automaticIDs.contains($0.id) }) { return nil }\n", ""),
 ("pure", "list failure not said", O, '        let list = listFailed ? " The session list could not be read just now." : ""', '        let list = ""'),
 ("pure", "older server silent", O, "        guard inList == 0 else { return nil }\n        if listFailed", "        guard inList == 99 else { return nil }\n        if listFailed"),
 # pure: kinds and the plan's targets
 ("pure", "New session on any provider", O, '        case "newSession": return ["claude", "codex"].contains(provider ?? "") ? .newSession(provider!) : nil', '        case "newSession": return .newSession(provider ?? "cursor")'),
 ("pure", "unknown mode is a Continue", O, '        case "fork": return .fork\n', '        case "fork": return .fork\n        case "teleport": return .continueSession\n'),
 ("pure", "Continue target unchecked", O, "            case .continueSession?: return continueTargets.contains(target)", "            case .continueSession?: return true"),
 ("pure", "Fork target unchecked", O, "            case .fork?: return forkTargets.contains(target)", "            case .fork?: return true"),
 ("pure", "New session may name a session", O, "            case .newSession(let p)?: return newProviders.contains(p) && isNewSessionID(target)", "            case .newSession(let p)?: return newProviders.contains(p)"),
 ("pure", "targets need not be distinct", O, "        guard kinds.count <= 3, Set(kinds.map(\\.1)).count == kinds.count else { return false }", "        guard kinds.count <= 3 else { return false }"),
 ("pure", "prompts unchecked", O, "            guard validPrompt(prompt) else { return false }\n", ""),
 # pure: Auto-send per card
 ("pure", "Auto-send on by default", O, "    static func autoSend(workID: String, raw: String, settingDefault: Bool) -> Bool { overrides(raw)[workID] ?? settingDefault }", "    static func autoSend(workID: String, raw: String, settingDefault: Bool) -> Bool { overrides(raw)[workID] ?? true }"),
 ("pure", "card choice for every card", O, "    static func autoSend(workID: String, raw: String, settingDefault: Bool) -> Bool { overrides(raw)[workID] ?? settingDefault }", "    static func autoSend(workID: String, raw: String, settingDefault: Bool) -> Bool { overrides(raw).values.first ?? settingDefault }"),
 ("pure", "default never clears the override", O, "        if on == settingDefault { v.removeValue(forKey: workID) } else { v[workID] = on }", "        v[workID] = on"),
 # pure: Stop
 ("pure", "queued cannot stop", O, '        if state == queuedState || state == "Not sent" { return .unqueue }', '        if state == "Not sent" { return .unqueue }'),
 ("pure", "job stop unavailable", O, '        case "job": return jobID.map { .cancelJob($0) } ?? .unavailable("The job has no id yet. Try again in a moment.")', '        case "job": return .unavailable("The job has no id yet. Try again in a moment.")'),
 ("pure", "turn stop unavailable", O, '            return .cancelTurn(provider: String(id[..<colon]), threadID: String(id[id.index(after: colon)...]))', '            return .unavailable(String(id[..<colon]))'),
 ("pure", "a finished handoff shows Stop", O, '        guard let status = receiptStatus, ["running", "queued", "sending"].contains(status) else { return .none }', '        guard let status = receiptStatus else { return .none }'),
 # pure tier also runs the wiring pins
 ("pure", "helper drops the capability", H, '"orchestrator": body["orchestrator"] as? Int == 1])', '"orchestrator": false])'),
 ("pure", "helper waves any row through", H, 'if orchestrator, row["linked"] as? Bool != true, let found = row["discoveredBy"] as? [String], !found.isEmpty { return true }', 'if orchestrator { return true }'),
 ("pure", "Control gives up before the helper", S, '(args.first == "work-orchestrator-input" ? 60 : 45)', '(args.first == "work-orchestrator-input" ? 45 : 45)'),
 ("pure", "no refresh before the input", C, "                await handoff.refreshActivity()\n                orchestrated = try await orchestratorInput(", "                orchestrated = try await orchestratorInput("),
 # hub: the real stores against the fake transport (execution checks only)
 ("hub", "orchestrator input never used", C, "            if !handoff.isolated, orchestratorOffered {\n                phase = \"Finding this task's sessions…\"", "            if false {\n                phase = \"Finding this task's sessions…\""),
 ("hub", "plan ignores the server's rows", C, "        let rows: [[String: Any]] = orchestrated.map { o in", "        let rows: [[String: Any]] = Optional<(input: WorkOrchestrator.Input, newProviders: [String])>.none.map { o in"),
 ("hub", "list read missing from the snapshot", C, "        let fresh = handoff.activityFresh()\n", "        let fresh = false\n"),
 ("hub", "fork child not journaled", S, "                row.sessionID = child.id; row.sessionTitle = child.title; row.forkChildID = child.id", "                row.sessionID = child.id; row.sessionTitle = child.title"),
 ("hub", "fork sent as a Continue", C, "                    session = found; sendMode = .fork", "                    session = found"),
 ("hub", "New session never started", C, "                    model = found; sendMode = .newSession", "                    model = found"),
 ("hub", "empty plan silent", C, "                self.record?.rounds[index].sessionsNote = WorkOrchestrator.emptyExplanation(", "                _ = WorkOrchestrator.emptyExplanation("),
 ("hub", "Stop never reaches the server", C, '            await requestStop(assignmentID: assignmentID, args: ["work-job-cancel", "--job-id", job], handoff: handoff)', '            _ = job'),
 ("hub", "Stop on rounds waiting for review", C, "        guard let round = record?.rounds.first(where: { $0.id == roundID }), round.sentWithoutReview == true || round.sentFromGlasses == true,", "        guard let round = record?.rounds.first(where: { $0.id == roundID }),"),
 ("hub", "Guardian rows are targets", C, "        return handoff.observedSessions().filter { allowed.contains($0.id) && !WorkOrchestrator.isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }", "        return handoff.observedSessions().filter { allowed.contains($0.id) || WorkOrchestrator.isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }"),
]
EXPECTED_SURVIVORS = {
    # Defense in depth: the plan's targets come from the server's rows, which never include a Guardian row (the snapshot
    # drops them and the server drops them again), so this filter cannot change a send in a fixture that is honest.
    "Guardian rows are targets",
}

def idle():
    while subprocess.run(["pgrep", "-x", "swift-frontend"], capture_output=True).returncode == 0: time.sleep(15)

def run(work, tier):
    idle()
    script = "Tests/run-work-orchestrator.sh" if tier == "pure" else "Tests/run-work-session-hub.sh"
    r = subprocess.run(["/bin/zsh", str(work / script)], cwd=work, capture_output=True, text=True)
    out = r.stdout + r.stderr
    named = next((l.strip() for l in out.splitlines() if l.startswith("FAIL ") or "Precondition failed" in l or l.startswith("AssertionError") or l.strip().startswith("FAIL work orchestrator pins")), "")
    if named.startswith("FAIL work orchestrator pins"):
        idx = out.splitlines().index(next(l for l in out.splitlines() if l.strip().startswith("FAIL work orchestrator pins")))
        named = "PIN: " + out.splitlines()[idx + 1].strip()
    compile_error = next((l.strip() for l in out.splitlines() if " error: " in l), "")
    return r.returncode, named, compile_error, out

results = {"killed": [], "survived": [], "invalid": [], "missing": [], "expected": []}
for tier in ("pure", "hub"):
    if tier_only and tier != tier_only: continue
    chosen = [m for m in MUTANTS if m[0] == tier and (not only or m[1] in only)]
    if not chosen: continue
    work = pathlib.Path(tempfile.mkdtemp(prefix=f"cos-work-orchestrator-{tier}-", dir="/private/tmp"))
    try:
        for folder in ("Sources", "Tests", "HelperSources", "scripts"): shutil.copytree(root / folder, work / folder, ignore=shutil.ignore_patterns("__pycache__"))
        if tier == "hub":
            hub = work / "Tests/run-work-session-hub.sh"; text = hub.read_text()
            line = 'zsh "$ROOT/Tests/run-work-orchestrator.sh"\n'
            assert text.count(line) == 1, "the hub runner must call the orchestrator runner exactly once"
            hub.write_text(text.replace(line, "")); print("hub tier: orchestrator pins taken out of the copy; kills here are execution checks")
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
print(f"work orchestrator mutants: {len(results['killed'])} killed by a named check, {len(results['expected'])} expected survivors, "
      f"{len(results['survived'])} survived, {len(results['invalid'])} invalid, {len(results['missing'])} missing")
if results["survived"] or results["invalid"] or results["missing"]: sys.exit(f"gate failed: {results}")
