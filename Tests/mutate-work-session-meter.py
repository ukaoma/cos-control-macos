#!/usr/bin/env python3
"""0.5.312 mutation gate for the Connections meter parsers (Sources/WorkSessionLinks.swift + Tests/WorkSessionMeterChecks.swift).

SERIAL: one small two-file compile at a time through Tests/compile-guard.sh, on a scratch copy (the checkout is never
mutated). A green baseline is required first; each mutant must land exactly once and must make the checks FAIL.
Usage: python3 Tests/mutate-work-session-meter.py <repo root>
"""
import pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
CORE = "Sources/WorkSessionLinks.swift"
MUTANTS = [
    ("cache read not counted", '(int(usage["input_tokens"]) ?? 0) + (int(usage["cache_read_input_tokens"]) ?? 0) + ', '(int(usage["input_tokens"]) ?? 0) + '),
    ("sidechain counted", 'row["type"] as? String == "assistant", row["isSidechain"] as? Bool != true,', 'row["type"] as? String == "assistant",'),
    # Not a mutant: deleting the "<synthetic>" skip is equivalent, because window(provider:model:) returns nil for any
    # model it does not know, so a synthetic turn can never be counted either way (2026-10-15 overnight run). The skip
    # stays as stated intent; the "unknown Claude model guessed" mutant below is what actually guards it.
    ("zero usage shown", "            guard used > 0, let window = window(provider: \"claude\"", "            guard let window = window(provider: \"claude\""),
    ("oldest usage, not newest", "        for line in lines.reversed() where line.contains(\"\\\"usage\\\"\") {", "        for line in lines where line.contains(\"\\\"usage\\\"\") {"),
    ("Codex stated window ignored", 'reported: int(info["model_context_window"]), used: used)', 'reported: nil, used: used)'),
    ("old rule back: 200k unless [1m] or past 200k", 'if ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-haiku-5"].contains(where: { id.hasPrefix($0) }) { return 1_000_000 }\n            guard ["claude-opus-4", "claude-sonnet-4", "claude-haiku-4", "claude-3"].contains(where: { id.hasPrefix($0) }) else { return nil }\n            return id.contains("[1m]") || id.hasSuffix("-1m") || used > 200_000 ? 1_000_000 : 200_000',
     'if id.contains("[1m]") || id.hasSuffix("-1m") || used > 200_000 { return 1_000_000 }\n            return 200_000'),
    ("Fable 5 not 1M", '["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-haiku-5"]', '["claude-opus-5", "claude-sonnet-5", "claude-haiku-5"]'),
    ("unknown Claude model guessed", 'contains(where: { id.hasPrefix($0) }) else { return nil }', 'contains(where: { id.hasPrefix($0) }) else { return 200_000 }'),
    ("1M marker ignored", 'return id.contains("[1m]") || id.hasSuffix("-1m") || used > 200_000 ? 1_000_000 : 200_000', 'return used > 200_000 ? 1_000_000 : 200_000'),
    ("usage past 200k ignored", 'return id.contains("[1m]") || id.hasSuffix("-1m") || used > 200_000 ? 1_000_000 : 200_000', 'return id.contains("[1m]") || id.hasSuffix("-1m") ? 1_000_000 : 200_000'),
    ("unknown Codex guessed", 'return id.hasPrefix("gpt-5") ? 272_000 : nil', 'return 272_000'),
    ("threshold moved", "static let compactingFraction = 0.85", "static let compactingFraction = 0.9"),
    ("outputs before the handoff", 'let at = date(row["timestamp"]), at >= since,\n                  let content', 'let at = date(row["timestamp"]),\n                  let content'),
    ("Read counted as a write", 'static let claudeWriteTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]', 'static let claudeWriteTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit", "Read"]'),
    ("Delete counted", 'for prefix in ["*** Add File: ", "*** Update File: ", "*** Move to: "] where line.hasPrefix(prefix) {', 'for prefix in ["*** Add File: ", "*** Update File: ", "*** Move to: ", "*** Delete File: "] where line.hasPrefix(prefix) {'),
    ("escaped shell arguments not read", '               let inner = try? JSONSerialization.jsonObject(with: data) { collectStrings(inner, into: &out, depth: depth + 1) }', '               let _ = try? JSONSerialization.jsonObject(with: data) { }'),
    ("no de-duplication", '.filter { seen.insert(($0.path as NSString).standardizingPath).inserted }', '.filter { _ in true }'),
    ("oldest first", 'return outputs.sorted { $0.at > $1.at }', 'return outputs.sorted { $0.at < $1.at }'),
    ("partial first line kept", '        if !fromStart, !rows.isEmpty { rows.removeFirst() }\n', ''),
    ("deletions misread", 'deletions: firstNumber(line, before: " deletion") ?? 0)', 'deletions: 0)'),
    ("binary rows dropped", 'parts[0] == "-" || Int(parts[0]) != nil, parts[1] == "-" || Int(parts[1]) != nil', 'Int(parts[0]) != nil, Int(parts[1]) != nil'),
    ("thousands not grouped", 'f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")\n        let n:', 'f.numberStyle = .none; f.locale = Locale(identifier: "en_US")\n        let n:'),
]

def compile_and_run(work):
    out = work / "checks"
    if out.exists(): out.unlink()
    build = subprocess.run(["/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6",
                            "-strict-concurrency=complete", "-parse-as-library", str(work / CORE), str(root / "Tests/WorkSessionMeterChecks.swift"),
                            "-o", str(out)], capture_output=True, text=True)
    if build.returncode != 0: return 2
    return subprocess.run([str(out), str(root)], capture_output=True, text=True).returncode

work = pathlib.Path(tempfile.mkdtemp(prefix="cos-work-meter-mutants-", dir="/private/tmp"))
try:
    (work / "Sources").mkdir()
    shutil.copy(root / CORE, work / CORE)
    original = (work / CORE).read_text()
    if compile_and_run(work) != 0: sys.exit("baseline is not green")
    survivors = []
    for name, old, new in MUTANTS:
        if original.count(old) != 1: sys.exit(f"mutant '{name}' targets {original.count(old)} sites")
        (work / CORE).write_text(original.replace(old, new))
        code = compile_and_run(work)
        print(f"{'KILLED (did not compile)' if code == 2 else 'KILLED' if code else 'SURVIVED':24} {name}")
        if code == 0: survivors.append(name)
        (work / CORE).write_text(original)
    if survivors: sys.exit(f"{len(survivors)} survivor(s): {survivors}")
    print(f"PASS work session meter mutation gate: {len(MUTANTS)} mutants, all killed, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
