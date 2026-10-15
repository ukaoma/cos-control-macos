#!/usr/bin/env python3
"""0.5.309 mutation gate for the pure dictation rules (Sources/MacDictationCore.swift + Tests/MacDictationChecks.swift).

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly once and
must make the checks FAIL; a mutant that compiles, runs and passes is a SURVIVOR and fails this gate.

Usage: python3 Tests/mutate-mac-dictation-core.py <repo root>
"""
import pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
CORE = "Sources/MacDictationCore.swift"
MUTANTS = [
    ("trust ignored", "        guard trusted else { return .notTrusted }\n", ""),
    ("secure input ignored", "        guard !secureInput else { return .secureInput }\n", ""),
    ("password field allowed", "        if subrole == secureSubrole { return .secureField }\n", ""),
    ("own panel allowed", "        if ownOverlay { return .ownOverlay }\n", ""),
    ("no focus treated as a text box", "        guard let role else { return .noTextBox }\n", "        guard let role else { return nil }\n"),
    ("search-field subrole ignored", "editableRoles.contains(role) || subrole.map({ editableRoles.contains($0) }) == true", "editableRoles.contains(role)"),
    ("settable range ignored", "return rangeSettable || editableAncestor ? nil : .noTextBox", "return editableAncestor ? nil : .noTextBox"),
    ("web editor ignored", "return rangeSettable || editableAncestor ? nil : .noTextBox", "return rangeSettable ? nil : .noTextBox"),
    ("any element accepted", "return rangeSettable || editableAncestor ? nil : .noTextBox", "return nil"),
    ("meter floor moved", "static let floorDB = -50.0, ceilingDB = -10.0", "static let floorDB = -60.0, ceilingDB = -10.0"),
    ("meter not clamped", "min(1, max(0, (dBFS - floorDB) / (ceilingDB - floorDB)))", "(dBFS - floorDB) / (ceilingDB - floorDB)"),
    ("slow attack", "level = target >= level ? target : level * Self.release + target * (1 - Self.release)", "level = level * Self.release + target * (1 - Self.release)"),
    ("instant release", "level = target >= level ? target : level * Self.release + target * (1 - Self.release)", "level = target"),
    ("history unbounded", "Array(([record] + list.filter { $0.id != record.id }).prefix(limit))", "[record] + list.filter { $0.id != record.id }"),
    ("history duplicates", "Array(([record] + list.filter { $0.id != record.id }).prefix(limit))", "Array(([record] + list).prefix(limit))"),
    ("history oldest first", "list.sorted { $0.createdAt > $1.createdAt }", "list.sorted { $0.createdAt < $1.createdAt }"),
    ("history world-readable", "attributes: [.posixPermissions: 0o600]", "attributes: [.posixPermissions: 0o644]"),
    ("temp file left behind", "        guard rename(temp.path, url.path) == 0 else {", "        guard link(temp.path, url.path) == 0 else {"),
    ("hover does not pause", "mutating func pause(at now: Date) { guard let since = runningSince else { return }; spent += max(0, now.timeIntervalSince(since)); runningSince = nil }",
     "mutating func pause(at now: Date) { }"),
    ("resume restarts the clock", "mutating func resume(at now: Date) { if runningSince == nil { runningSince = now } }", "mutating func resume(at now: Date) { spent = 0; runningSince = now }"),
    ("heard keeps punctuation", "return tokens[range].joined(separator: \" \").trimmingCharacters(in: edge)", "return tokens[range].joined(separator: \" \")"),
    ("tap never clears", "        if current == index...index { return nil }\n", ""),
    ("tap inside never restarts", "        if current.contains(index) { return index...index }\n", ""),
    ("pill never hands the ledger back", "var replacesLedger: Bool { self != .hidden }", "var replacesLedger: Bool { true }"),
    ("RMS becomes peak", "return (sum / Double(samples)).squareRoot()", "return sum > 0 ? 1 : 0"),
]


def compile_and_run(work: pathlib.Path) -> int:
    out = work / "checks"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0",
                            "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                            str(work / CORE), str(work / "Tests/MacDictationChecks.swift"), "-o", str(out)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        return 2
    return subprocess.run([str(out)], capture_output=True, text=True).returncode


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-dictation-mutants-", dir="/private/tmp"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / "Tests/MacDictationChecks.swift", work / "Tests/MacDictationChecks.swift")
    original = (work / CORE).read_text()
    if compile_and_run(work) != 0:
        sys.exit("baseline is not green: fix the checks before reading any mutant")
    survivors = []
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
        (work / CORE).write_text(original.replace(old, new))
        code = compile_and_run(work)
        verdict = "KILLED (did not compile)" if code == 2 else ("KILLED" if code != 0 else "SURVIVED")
        print(f"{verdict:24} {name}")
        if code == 0:
            survivors.append(name)
        (work / CORE).write_text(original)
    if survivors:
        sys.exit(f"{len(survivors)} survivor(s): {survivors}")
    print(f"PASS dictation core mutation gate: {len(MUTANTS)} mutants, all killed, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
