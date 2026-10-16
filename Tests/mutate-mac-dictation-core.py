#!/usr/bin/env python3
"""0.5.309/0.5.310 mutation gate for the pure dictation rules (Sources/MacDictationCore.swift + Tests/MacDictationChecks.swift).

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
    # 0.5.310 measured delivery: each of these is a way to show ✓ when nothing landed, or to paste twice.
    ("verification deleted: an unchanged field counts as landed", "        if after == baseline { return .unchanged }\n", ""),
    ("iTerm2 bug back: a final unchanged poll reports inserted", "            return route == .ownWindow ? .done(.refused(.noTextBox)) : .paste",
     "            return .done(.inserted(app: app, viaPaste: false))"),
    ("inserted and pasted swapped", "            case .landed, .changed: return .done(.inserted(app: app, viaPaste: true))",
     "            case .landed, .changed: return .done(.inserted(app: app, viaPaste: false))"),
    ("an unmoved or unverifiable ⌘V earns the ✓", "            case .unchanged, .unreadable: return .done(.unconfirmed(app: app, viaPaste: true))",
     "            case .unchanged, .unreadable: return .done(.inserted(app: app, viaPaste: true))"),
    ("an unmoved ⌘V tells you to press ⌘V again (double paste)", "            case .unchanged, .unreadable: return .done(.unconfirmed(app: app, viaPaste: true))",
     "            case .unchanged: return .done(.refused(.noTextBox))\n            case .unreadable: return .done(.unconfirmed(app: app, viaPaste: true))"),
    ("a changed field is pasted over (double insert)", "        case .landed, .changed:\n            return .done(.inserted(app: app, viaPaste: false))",
     "        case .landed:\n            return .done(.inserted(app: app, viaPaste: false))\n        case .changed:\n            return .paste"),
    ("no wait for a slow field", "            guard !setterSucceeded || finalPoll else { return .wait }\n", ""),
    ("unreadable baseline still tries AX", "        guard baseline.readable else { return route == .ownWindow ? .done(.unconfirmed(app: app, viaPaste: false)) : .paste }\n", ""),
    ("landed-by-count dropped", "n == n0 - length0 + count { return .landed }", "n == n0 + count + 1 { return .landed }"),
    ("landed-by-caret dropped", "after.length == 0, location == location0 + count { return .landed }", "after.length == 0, location == location0 + count + 1 { return .landed }"),
    ("terminals take the AX route", "        if terminal || !baselineReadable { return .paste }", "        if !baselineReadable { return .paste }"),
    ("unreadable baseline takes the AX route", "        if terminal || !baselineReadable { return .paste }", "        if terminal { return .paste }"),
    ("line breaks reach a terminal", 'for breakSequence in ["\\r\\n", "\\r", "\\n", "\\u{2028}", "\\u{2029}"]', 'for breakSequence in ["\\u{2028}", "\\u{2029}"]'),
    ("unconfirmed ⌘V shows a ✓", 'case .unconfirmed(_, true): .flash(label: "PASTED · ⌘V SENT", confirmed: false)', 'case .unconfirmed(_, true): .flash(label: "✓ PASTED · ⌘V SENT", confirmed: true)'),
    ("Warp prefix forgotten", 'terminals.contains(bundleID) || bundleID.hasPrefix("dev.warp.")', "terminals.contains(bundleID)"),
    ("Electron not detected", 'name == "Electron Framework.framework" || ', ""),
    ("layout ignored", "for code in UInt16(0)..<128 where translate(code)?.lowercased() == character { return code }", "return 9"),
    ("Shift no longer blocks the paste", "0x100000 | 0x80000 | 0x40000 | 0x20000 | 0x800000", "0x100000 | 0x80000 | 0x40000 | 0x800000"),
    # Policy: a role alone is not a text box; distinct refusals stay distinct.
    ("trust ignored", "        guard trusted else { return .notTrusted }\n", ""),
    ("password field reads as secure input", "        if subrole == secureSubrole { return .secureField }\n", ""),
    ("secure input ignored", "        if secureInput { return .secureInput }\n", ""),
    ("own panel allowed", "        if ownOverlay { return .ownOverlay }\n", ""),
    ("read-only field accepted", "        if focused, textSettable || editableAncestor { return nil }", "        if focused { return nil }"),
    ("web editor ignored", "        if focused, textSettable || editableAncestor { return nil }", "        if focused, textSettable { return nil }"),
    ("terminal/Electron refused", "        return pasteApp ? nil : .noTextBox", "        return .noTextBox"),
    # History, meter, card, fix-a-word.
    ("legacy inserted trusted as inserted", "            delivery = .unconfirmed(app: app, viaPaste: try c.decodeIfPresent(Bool.self, forKey: .pasted) ?? false)",
     "            delivery = .inserted(app: app)"),
    ("corrupt history overwritten", "        guard rename(url.path, aside.path) == 0 else { return ([], nil, false) }\n        return ([], aside, true)", "        return ([], nil, true)"),
    ("delete removes nothing", "list.filter { $0.id != id } }", "list }"),
    ("meter floor moved", "static let floorDB = -50.0, ceilingDB = -10.0", "static let floorDB = -60.0, ceilingDB = -10.0"),
    ("slow attack", "level = target >= level ? target : level * Self.release + target * (1 - Self.release)", "level = level * Self.release + target * (1 - Self.release)"),
    ("history unbounded", "Array(([record] + list.filter { $0.id != record.id }).prefix(limit))", "[record] + list.filter { $0.id != record.id }"),
    ("history world-readable", "attributes: [.posixPermissions: 0o600]", "attributes: [.posixPermissions: 0o644]"),
    ("temp file left behind", "        guard rename(temp.path, url.path) == 0 else {", "        guard link(temp.path, url.path) == 0 else {"),
    ("hover does not pause", "mutating func pause(at now: Date) { guard let since = runningSince else { return }; spent += max(0, now.timeIntervalSince(since)); runningSince = nil }",
     "mutating func pause(at now: Date) { }"),
    ("tap never clears", "        if current == index...index { return nil }\n", ""),
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
