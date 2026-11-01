#!/usr/bin/env python3
"""Mutation lane for the ⌘K local session search and its open path (Tests/local-session-search-checks.py). Run by hand, never by a gate.

    python3 Tests/mutate-local-session-search.py <worktree> <scratch dir> [name ...]

Builds the helper from the unmutated sources first and proves the checks green (a red baseline would "kill" every mutant). Then, for each
mutant: the target must appear exactly once in HelperSources/main.swift, the helper is rebuilt through the compile guard, and the checks
must fail with a line that names the behaviour. A mutant that lands and survives is a finding. One compile at a time.
"""
import pathlib, shutil, subprocess, sys, os

H = "HelperSources/main.swift"
MUTANTS = [
    ("a Desktop row keeps the record's own id", "        let sessionId = UUID(uuidString: head.cliSessionId) != nil ? head.cliSessionId : id\n", "        let sessionId = id\n",
     "found once, under its cliSessionId"),
    ("the record rows come back from the Sessions scan", "            newest: transcriptNewest,\n            desktopOnlyRows: false\n", "            newest: transcriptNewest\n",
     "found once, under its cliSessionId"),
    # QA 0.5.361 item 12: the same words give the same rows, a named row takes its dated row's date and project, an untitled hit says what it is
    ("equal scores are left to the dictionary", "            if sa != sb { return sa > sb }\n            let da = a[\"updatedAt\"] as? String ?? \"\", db = b[\"updatedAt\"] as? String ?? \"\"\n            if da != db { return da > db }\n            return (a[\"id\"] as? String ?? \"\") < (b[\"id\"] as? String ?? \"\")\n", "            return sa > sb\n",
     "equal scores order newest first"),
    ("a named row keeps its blanks", "                for field in [\"workspace\", \"createdAt\", \"updatedAt\"] where (rows[at][field] as? String ?? \"\").isEmpty {\n                    if let value = row[field] as? String, !value.isEmpty { rows[at][field] = value }\n                }\n", "",
     "a named Codex row takes the project and date"),
    ("a transcript has no project of its own", "                    \"workspace\": project,\n", "                    \"workspace\": workspaceLabel(desktop?.cwd ?? \"\"),\n",
     "has its project from its folder"),
    ("a hit with no title stays untitled", "            if let title = lastCustomTitle(in: file) ?? firstClaudeUserTitle(in: file), !title.isEmpty { shown[at][\"name\"] = title }\n", "",
     "has a title, not Claude session"),
    ("a hit keeps its 8 characters", "            if (hit[\"provider\"] as? String ?? \"claude\") == \"claude\", let id = hit[\"id\"] as? String, id.count == 8, let full = fullClaudeId[id.lowercased()] { hit[\"id\"] = full }\n", "",
     "found under its full id"),
    ("reveal does not resolve a short id", "                sessionId: fullId,\n                records: Self.claudeDesktopRecords(for: fullId, sessionsRoot: desktopRoot),", "                sessionId: sessionId,\n                records: Self.claudeDesktopRecords(for: fullId, sessionsRoot: desktopRoot),",
     "by the transcript's short id"),
    ("reveal reads the real home", "        let home = self.home\n        let app = Self.desktopApp(for: provider)", "        let home = FileManager.default.homeDirectoryForCurrentUser\n        let app = Self.desktopApp(for: provider)",
     "open resolves"),
    ("the local scan reads the real home", "        let rows = Self.localSessionKeywordHits(query: query, limit: limit, home: home,\n", "        let rows = Self.localSessionKeywordHits(query: query, limit: limit, home: FileManager.default.homeDirectoryForCurrentUser,\n",
     "finds its session once"),
]


def build(copy, binary):
    files = [copy / "HelperSources/main.swift", copy / "HelperSources/ProviderStatusCore.swift", copy / "HelperSources/PairingCore.swift", copy / "HelperSources/SessionUsageCollector.swift",
             copy / "Sources/SessionUsageCore.swift", copy / "Sources/WorkSessionLinks.swift"]
    env = dict(os.environ, COS_COMPILE_SLOTS="3")
    result = subprocess.run([str(copy / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete"]
                            + [str(f) for f in files] + ["-framework", "Security", "-framework", "AppKit", "-o", str(binary)], capture_output=True, text=True, env=env)
    return result.returncode, (result.stdout + result.stderr)[-600:]


def checks(copy, binary):
    result = subprocess.run(["python3", str(copy / "Tests/local-session-search-checks.py"), str(binary)], capture_output=True, text=True, timeout=300)
    return result.returncode, result.stdout + result.stderr


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("HelperSources", "Sources", "Tests"):
        shutil.copytree(src / part, copy / part)
    binary = scratch / "helper"
    code, out = build(copy, binary)
    if code != 0:
        sys.exit("baseline does not compile:\n" + out)
    code, out = checks(copy, binary)
    print("BASELINE:", out.strip().splitlines()[-1] if out.strip() else "(no output)", flush=True)
    if code != 0:
        sys.exit("baseline is not green; no mutant may be judged against a red suite:\n" + out)
    killed = survived = 0
    path = copy / H
    original = path.read_text(encoding="utf-8")
    for name, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        if original.count(old) != 1:
            print(f"MISS  {name}: the target appears {original.count(old)} times", flush=True); survived += 1; continue
        path.write_text(original.replace(old, new), encoding="utf-8")
        try:
            code, out = build(copy, binary)
            if code != 0:
                print(f"BUILD FAILED  {name}: {out[-300:]}", flush=True); survived += 1; continue
            code, out = checks(copy, binary)
        finally:
            path.write_text(original, encoding="utf-8")
        lines = [l for l in out.splitlines() if "check FAILED:" in l]
        if code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif any(words.lower() in l.lower() for l in lines):
            killed += 1; print(f"killed  {name}: {lines[0][:200]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {(lines or [out[-200:]])[0][:240]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour", flush=True)
    sys.exit(0 if survived == 0 else 1)


if __name__ == "__main__":
    main()
