#!/usr/bin/env python3
"""Mutation lane for the ⌘K meaning search verb (0.5.362), by hand. Never a gate.

    python3 Tests/mutate-session-find-helper.py <worktree> <scratch dir> [name ...]

Copies the worktree's Sources, HelperSources, Tests and scripts to <scratch dir>/copy, proves the UNMUTATED lane green first
(Tests/run-session-find-helper.sh: the helper compiled through the guard, then Tests/session-find-helper-checks.py against a stand-in
server), then applies one mutant at a time. The target must appear exactly once, and the lane must fail on a check that names the
behaviour. Each compile goes through the compile guard, one at a time. A mutant that lands and survives is a finding.
"""
import filecmp, pathlib, shutil, subprocess, sys

H = "HelperSources/main.swift"
MUTANTS = [
    ("helper: the stage is not checked", H, '''["jev", "subq"].contains(provider), ["first", "full"].contains(stage) else { return false }''', '''["jev", "subq"].contains(provider) else { return false }''', "malformed body is refused"),
    ("helper: the provider is not checked", H, '''["jev", "subq"].contains(provider), ["first", "full"].contains(stage) else { return false }''', '''["first", "full"].contains(stage) else { return false }''', "malformed body is refused"),
    ("helper: a key may ride along", H, '''guard Set(body.keys) == ["query", "consentedProvider", "stage"],''', '''guard Set(body.keys).isSuperset(of: ["query", "consentedProvider", "stage"]),''', "malformed body is refused"),
    ("helper: a two character query goes through", H, "return (3...200).contains(query.trimmingCharacters", "return (1...200).contains(query.trimmingCharacters", "malformed body is refused"),
    ("helper: a long query goes through", H, "return (3...200).contains(query.trimmingCharacters", "return (3...2_000).contains(query.trimmingCharacters", "malformed body is refused"),
    ("helper: the words are counted in bytes", H, ".unicodeScalars.count)\n    }\n\n    /// A refusal as one fixed word.", ".utf8.count)\n    }\n\n    /// A refusal as one fixed word.", "200 code points"),
    ("helper: a missing token is an error", H, '''guard let token = try? (candidate?.token ?? readToken()) else {
            emit(ok: true, message: "Meaning search unavailable", details: ["available": false, "reason": "no_token"]); return
        }''', '''let token = try candidate?.token ?? readToken()''', "missing token is an answer"),
    ("helper: the deadline is 20 seconds", H, "static let sessionFindSeconds: TimeInterval = 7\n", "static let sessionFindSeconds: TimeInterval = 20\n", "inside 8 seconds"),
    ("helper: a late answer is unreachable", H, 'details: ["available": false, "reason": late ? "timed_out" : "unreachable"]', 'details: ["available": false, "reason": "unreachable"]', "timed_out inside 8 seconds"),
    ("helper: a 404 is failed", H, "case 404: return \"server_too_old\"", "case 404: return \"failed\"", "HTTP 404"),
    ("helper: a 503 is failed", H, "case 503: return \"try_later\"", "case 503: return \"failed\"", "HTTP 503"),
    ("helper: the server's words are forwarded", H, '''out["reason"] = reason ?? "failed"''', '''out["reason"] = reason ?? "failed"; out["message"] = body["message"]''', "an answer with its reason only"),
    ("helper: any reason text passes", H, '''$0.range(of: "^[a-z_]{3,48}$", options: .regularExpression) != nil ? $0 : nil }
            out["reason"]''', '''$0 }
            out["reason"]''', "not a code reads as failed"),
    ("helper: an unknown strength passes", H, '''projected["strength"] = ["strong", "likely", "possible"].contains(strength) ? strength : "possible"''', '''projected["strength"] = strength''', "strength is one of three words"),
    ("helper: an unknown strength reads strong", H, '''contains(strength) ? strength : "possible"''', '''contains(strength) ? strength : "strong"''', "unknown strength reads as possible"),
    ("helper: a row without a probability is kept", H, "case let probability = number.doubleValue, probability.isFinite, probability >= 0, probability <= 1 else { return nil }", "case let probability = number.doubleValue, probability.isFinite else { return nil }", "usable probability"),
    ("helper: a boolean is a probability", H, "let number = row[\"probability\"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),\n                  case let probability", "let number = row[\"probability\"] as? NSNumber,\n                  case let probability", "usable probability"),
    ("helper: rows are uncapped", H, "out[\"rows\"] = Array(projectedRows.prefix(8))", "out[\"rows\"] = Array(projectedRows)", "at most 8 rows"),
    ("helper: judged text is uncut", H, 'projected["judgedText"] = String((row["judged_text"] as? String ?? "").prefix(400))', 'projected["judgedText"] = row["judged_text"] as? String ?? ""', "judged text is cut"),
    ("helper: a title is uncut", H, 'projected["name"] = String((projected["name"] as? String ?? "").prefix(300))', '', "title and a project are bounded"),
    ("helper: a big answer is read", H, "guard (response.data?.count ?? 0) <= Self.sessionFindAnswerBytes else {", "guard true else {", "far bigger"),
    ("helper: the last activity is not the date", H, 'projected["lastActivityAt"] = last; projected["updatedAt"] = last', 'projected["lastActivityAt"] = last', "last activity, not the file time"),
    ("helper: a keyword snippet rides along", H, 'projected["snippet"] = nil\n            return projected', 'return projected', "no keyword snippet"),
    ("helper: the capability is any value", H, "let find = capabilities[\"sessionFind\"] as? NSNumber, CFGetTypeID(find) == CFBooleanGetTypeID() {", "let find = capabilities[\"sessionFind\"] as? NSNumber {", "real boolean"),
    ("helper: every capability passes", H, 'result["capabilities"] = ["sessionFind": find.boolValue]', 'result["capabilities"] = capabilities', "one boolean and nothing else"),
    ("helper: a provider that is not Jev or SubQ passes", H, 'if let provider = body["provider"] as? String, ["jev", "subq"].contains(provider) { out["provider"] = provider }', 'if let provider = body["provider"] as? String { out["provider"] = provider }', "not Jev or SubQ is dropped"),
    ("helper: a reset time of any shape passes", H, 'text.range(of: "^[0-9TZ:.+-]+$", options: .regularExpression) != nil else { return nil }', 'true else { return nil }', "not a date is dropped"),
]


def run(copy):
    r = subprocess.run(["zsh", "Tests/run-session-find-helper.sh"], cwd=copy, capture_output=True, text=True, timeout=1500)
    return r.returncode, r.stdout + r.stderr


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    names = sys.argv[3:]
    unknown = [n for n in names if n not in {m[0] for m in MUTANTS}]
    if unknown:
        sys.exit(f"no such mutant: {unknown}")
    for name, rel, old, _, _ in MUTANTS:
        count = (src / rel).read_text(encoding="utf-8").count(old)
        if count != 1:
            print(f"MISS  {name}: the target appears {count} times", flush=True)
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "HelperSources", "scripts"):
        shutil.copytree(src / part, copy / part)
    code, out = run(copy)
    print(f"BASELINE (unmutated): exit {code}: {out.strip().splitlines()[-1][:100] if out.strip() else ''}", flush=True)
    if code != 0:
        print(out[-2000:])
        sys.exit("baseline is not green; no mutant may be judged against a red lane")
    killed = survived = 0
    for name, rel, old, new, words in [m for m in MUTANTS if not names or m[0] in names]:
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}", flush=True); survived += 1; continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out = run(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        if not filecmp.cmp(path, src / rel, shallow=False):
            sys.exit(f"RESTORE FAILED for {name}")
        failed = [l for l in out.splitlines() if "session find helper check failed" in l or "error:" in l]
        reason = failed[0].strip() if failed else (out.strip().splitlines()[-1] if out.strip() else "")
        if code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif "error:" in reason and "check failed" not in reason:
            survived += 1; print(f"COMPILE ERROR (not a kill)  {name}: {reason[:200]}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name}: {reason[:200]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:240]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 else 1)


if __name__ == "__main__":
    main()
