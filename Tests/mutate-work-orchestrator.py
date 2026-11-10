#!/usr/bin/env python3
"""0.5.333 mutation gate for the Work orchestrator (0.5.386: the snapshot id filter and clamp, the empty card, Plan again, the Agent workspace default) (server 6.83.0 input, per-card Auto-send, Stop, fork child journal).

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
 ("pure", "Guardian rows reach the server", O, "let rows = usable.filter { !isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }.prefix(maxLive)", "let rows = usable.prefix(maxLive)"),
 ("pure", "Guardian test ignores the title", O, 'id.hasPrefix("codex:") && (title.trimmingCharacters(in: .whitespaces) == "Guardian review"', 'id.hasPrefix("codex:") && (false'),
 ("pure", "receipts oldest first", O, '"receipts": goodReceipts.sorted { $0.createdAt > $1.createdAt }', '"receipts": goodReceipts.sorted { $0.createdAt < $1.createdAt }'),
 ("pure", "missing ids become empty text", O, "        func sid(_ s: String?) -> Any { s.flatMap { validSessionID($0) ? $0.lowercased() : nil } ?? NSNull() }", '        func sid(_ s: String?) -> Any { s.flatMap { validSessionID($0) ? $0.lowercased() : nil } ?? "" }'),
 # pure: 0.5.386 the snapshot leaves out what the server refuses (T5)
 ("pure", "short live ids reach the server", O, "            let usable = live.filter { validSessionID($0.id) }", "            let usable = live"),
 ("pure", "short link ids reach the server", O, "        let goodLinks = links.filter { validSessionID($0.sessionID) && validWorkID($0.workID)", "        let goodLinks = links.filter { validWorkID($0.workID)"),
 ("pure", "bad card ids reach the server", O, "        let goodLinks = links.filter { validSessionID($0.sessionID) && validWorkID($0.workID)", "        let goodLinks = links.filter { validSessionID($0.sessionID)"),
 ("pure", "unknown receipt mode sent", O, "validWorkID($0.workID) && modes.contains($0.mode) && $0.createdAt.isFinite", "validWorkID($0.workID) && $0.createdAt.isFinite"),
 ("pure", "short receipt session ids sent", O, "        func sid(_ s: String?) -> Any { s.flatMap { validSessionID($0) ? $0.lowercased() : nil } ?? NSNull() }", "        func sid(_ s: String?) -> Any { s.map { $0 as Any } ?? NSNull() }"),
 ("pure", "titles clamped by characters", O, '"title": clamp($0.title, 300)', '"title": String($0.title.prefix(300))'),
 ("pure", "control characters kept", O, "        scalars.append(contentsOf: value.unicodeScalars.filter { $0.value >= 0x20 || [0x09, 0x0a, 0x0d].contains($0.value) })", "        scalars.append(contentsOf: value.unicodeScalars)"),
 ("pure", "SID takes any id", O, "        return groups.map(\\.count) == [8, 4, 4, 4, 12] && groups", "        return true || groups"),
 ("pure", "no dropped count", O, "            droppedLive = live.count - usable.count\n", ""),
 # pure: 0.5.386 an empty card
 ("pure", "used-up provider offered", O, "available.contains(p) && usage.first(where: { $0.provider == p })?.state != \"exhausted\"", "available.contains(p)"),
 ("pure", "Claude even when its usage is low", O, '        if offered.contains("claude") && !(claudeLow && offered.contains("codex")) { return "claude" }', '        if offered.contains("claude") { return "claude" }'),
 ("pure", "a forkable row counts as empty", O, "        !rows.contains { automaticIDs.contains($0.id) || ($0.forkable && forkProviders.contains($0.provider)) }", "        !rows.contains { automaticIDs.contains($0.id) }"),
 ("pure", "Opus not preferred", O, '        if provider == "claude", let opus', '        if provider == "never", let opus'),
 ("pure", "two New sessions kept", O, "            return !seen\n", "            return true\n"),
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
 ("pure", "helper drops the capability", H, '"orchestrator": body["orchestrator"] as? Int == 1,', '"orchestrator": false,'),
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
 ("hub", "Stop on rounds waiting for review", C, "sentWithoutReview: round.sentWithoutReview == true || round.sentFromGlasses == true)", "sentWithoutReview: true)"),
 # hub: 0.5.386, by execution against the fixture that refuses a snapshot as server 7.0.12 does
 ("hub", "short-id live row pushed", O, "            let usable = live.filter { validSessionID($0.id) }", "            let usable = live"),
 ("hub", "Plan again appends a round", C, "        if let replan {\n", "        if let replan, replan < 0 {\n"),
 ("hub", "Plan again replans any round", C, "record.rounds.firstIndex { $0.id == id && WorkChatPolicy.canPlanAgain($0) }", "record.rounds.firstIndex { $0.id == id }"),
 ("hub", "Plan again takes the draft", C, "        let question = replan.map { record.rounds[$0].question } ?? record.draft", "        let question = replan.map { _ in record.draft.trimmingCharacters(in: .whitespacesAndNewlines) } ?? record.draft"),
 ("hub", "empty card offers every provider", C, "                    emptyCard = provider; newProviders = [provider]", "                    emptyCard = provider"),
 ("hub", "empty card keeps every New session", C, '                    planned = WorkOrchestrator.oneNewSession(answer.assignments) { $0.mode == "newSession" }', "                    planned = answer.assignments"),
 ("hub", "no one-click offer", C, "                    else if planned.isEmpty { self.record?.rounds[index].offerNewSession = provider }", "                    else if false { self.record?.rounds[index].offerNewSession = provider }"),
 ("hub", "empty card not told", C, "{ self.record?.rounds[index].sessionsNote = WorkOrchestrator.emptyCardNote(provider) }", "{ _ = provider }"),
 ("hub", "one click sends nothing", C, "        await dispatch(roundID: roundID, assignmentIDs: [assignment.receiptID], source: source, handoff: handoff, hold: holdChoice(whenHeld, autoSend: false, handoff: handoff))\n", ""),
 ("hub", "one click on any round", C, "              round.state == \"Answered\", round.assignments.isEmpty, round.orchestrated != nil,", "              round.orchestrated != nil,"),
 ("hub", "one click on a round not Answered", C, "              round.state == \"Answered\", round.assignments.isEmpty, round.orchestrated != nil,", "              round.assignments.isEmpty, round.orchestrated != nil,"),
 ("hub", "one click on a round with an assignment", C, "              round.state == \"Answered\", round.assignments.isEmpty, round.orchestrated != nil,", "              round.state == \"Answered\", round.orchestrated != nil,"),
 ("hub", "New session on the first Claude model", C, "$0.provider == provider && $0.available && $0.id == preferred }", "$0.provider == provider && $0.available }"),
 ("hub", "used-up provider offered (store)", C, "newProviders = WorkOrchestrator.newSessionProviders(available: Set(handoff.models.filter(\\.available).map(\\.provider)), usage: orchestrated!.usage)", "newProviders = [\"claude\", \"codex\"].filter { p in handoff.models.contains { $0.provider == p && $0.available } }"),
 ("hub", "empty card keeps Continue", S, "        draft.mode = .newSession\n", ""),
 ("hub", "every card starts new", S, "        guard !hasSession else { return draft }\n", ""),
 ("hub", "another card's advice applied", S, "        if let id = advice.sessionID, let link = links[id.lowercased()], link.workID != workID { return nil }\n", ""),
 ("hub", "empty card takes advice", S, "        guard hasSession else { return nil }\n", ""),
 ("hub", "Guardian rows are targets", C, "        return handoff.observedSessions().filter { allowed.contains($0.id) && !WorkOrchestrator.isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }", "        return handoff.observedSessions().filter { allowed.contains($0.id) || WorkOrchestrator.isGuardian(id: $0.id, title: $0.title, summary: $0.summary) }"),
 # helper: 0.5.386 the /input failure words, executed by `cos-control-helper self-test-work`
 ("helper", "short-id cause not named", H, '        case "invalid_live_row": cause = "COS could not read the session list on this Mac (one session had an id COS cannot use)."', '        case "invalid_live_row_never": cause = ""'),
 ("helper", "server reason dropped", H, "        let codes = [error, reason].compactMap { $0 }", "        let codes = [error].compactMap { $0 }"),
 ("helper", "server prose echoed", H, '        func code(_ v: String?) -> String? { v.flatMap { $0.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil ? $0 : nil } }', "        func code(_ v: String?) -> String? { v }"),
 ("helper", "link cause not named", H, '        case "invalid_link": cause = "COS could not read this Mac\'s session links (one link had an id COS cannot use)."', '        case "invalid_link_never": cause = ""'),
]
EXPECTED_SURVIVORS = {
    # Defense in depth: the plan's targets come from the server's rows, which never include a Guardian row (the snapshot
    # drops them and the server drops them again), so this filter cannot change a send in a fixture that is honest.
    "Guardian rows are targets",
}

def idle():
    while subprocess.run(["pgrep", "-x", "swift-frontend"], capture_output=True).returncode == 0: time.sleep(15)

def run_helper(work):
    out = work / "helper-bin"
    if out.exists(): out.unlink()
    b = subprocess.run(["/usr/bin/python3", str(work / "Tests/kit-compile.py"), str(work / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
        *[str(work / f) for f in ("HelperSources/main.swift", "HelperSources/ProviderStatusCore.swift", "HelperSources/PairingCore.swift", "HelperSources/SessionUsageCollector.swift", "Sources/SessionUsageCore.swift", "Sources/WorkSessionLinks.swift")],
        "-framework", "Security", "-framework", "AppKit", "-o", str(out)], cwd=work, capture_output=True, text=True)
    if b.returncode: return 2, "", next((l.strip() for l in (b.stdout + b.stderr).splitlines() if " error: " in l), "compile failed"), b.stdout + b.stderr
    home = tempfile.mkdtemp(dir="/private/tmp")
    r = subprocess.run([str(out), "self-test-work"], capture_output=True, text=True, env={"COS_CONTROL_TEST_HOME": home, "PATH": "/usr/bin:/bin"})
    shutil.rmtree(home, ignore_errors=True)
    text = r.stdout + r.stderr
    named = "Work orchestrator input failure copy self-test failed" if "Work orchestrator input failure copy self-test failed" in text else ""
    return (0 if r.returncode == 0 and '"ok":true' in text.replace(" ", "") else 1), named, "", text

def run(work, tier):
    idle()
    if tier == "helper": return run_helper(work)
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
for tier in ("pure", "helper", "hub"):
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
