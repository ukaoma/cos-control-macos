#!/usr/bin/env python3
"""0.5.342 Your edit, confirmed: the mutation gate for the pure rules (Sources/MacDictationCore.swift, the section
"Your edit, confirmed", plus the record fields it adds) against Tests/EditConfirmChecks.swift.

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly once.

A KILL counts only when the mutant compiles, runs, and the check that fails first is the one the mutant names (its
behaviour in "check failed [<behaviour>]"), so every kill is attributed to the behaviour it breaks. Everything else
fails this gate on its own line: SURVIVED (the checks passed), MISATTRIBUTED (another check failed first: the named
check does not cover this guard alone), INVALID (did not compile, or timed out), CRASHED (a trap outside the checks).

Not mutated, on purpose: the window bounds in DictationEditConfirm.captured (start >= 0, start + length <= length).
Removing either makes NSString.substring raise, a crash rather than a named failure; the checks still exercise both
("captured bounds"). `length > 0` is an equivalent mutant (an empty span already reads as no words).

Usage: python3 Tests/mutate-edit-confirm.py <repo root> [--only <name prefix>[|<prefix>...]]
"""
import os
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
CORE = "Sources/MacDictationCore.swift"
CHECKS = "Tests/EditConfirmChecks.swift"

# (name, old, new, the behaviour whose check must fail first)
MUTANTS = [
    # What a watch keeps.
    ("captured: inside not required", "guard learning, readable, inside > 0, keepsAfter.contains(stop), let window else { return nil }",
     "guard learning, readable, keepsAfter.contains(stop), let window else { return nil }", "captured needs inside"),
    ("captured: readable not required", "guard learning, readable, inside > 0, keepsAfter.contains(stop), let window else { return nil }",
     "guard learning, inside > 0, keepsAfter.contains(stop), let window else { return nil }", "captured needs readable"),
    ("captured: probe apps kept", "guard learning, readable, inside > 0, keepsAfter.contains(stop), let window else { return nil }",
     "guard readable, inside > 0, keepsAfter.contains(stop), let window else { return nil }", "captured needs learning"),
    ("captured: lost, unreadable, secure and cancelled kept",
     'static let keepsAfter: Set<String> = ["focusLeft", "cleared", "emptied", "cap", "reads", "appGone"]',
     'static let keepsAfter: Set<String> = ["focusLeft", "cleared", "emptied", "cap", "reads", "appGone", "lost", "unreadable", "secure", "cancelled"]',
     "captured stops"),
    ("captured: a sent message keeps nothing",
     'static let keepsAfter: Set<String> = ["focusLeft", "cleared", "emptied", "cap", "reads", "appGone"]',
     'static let keepsAfter: Set<String> = ["focusLeft", "emptied", "cap", "reads", "appGone"]', "captured keeps"),
    ("captured: an undone edit kept", "guard !words.isEmpty, words != DictationWordDiff.words(typed) else { return nil }",
     "guard !words.isEmpty else { return nil }", "captured reverted"),
    ("captured: a blank span kept", "guard !words.isEmpty, words != DictationWordDiff.words(typed) else { return nil }",
     "guard words != DictationWordDiff.words(typed) else { return nil }", "captured blank"),
    # The edit for the record.
    ("edit: a changed record still edited", "        guard DictationWordDiff.words(typed) == DictationWordDiff.words(recordText) else { return nil }\n", "",
     "record edit mismatch"),
    ("edit: every edit counts one", ".map { DictationWordDiff.regions($0).count } ?? max(1, inside)", ".map { _ in 1 } ?? max(1, inside)",
     "record edit made"),
    # The word diff.
    ("diff: added before removed", "j == m || lcs[i + 1][j] >= lcs[i][j + 1]", "j == m || lcs[i + 1][j] > lcs[i][j + 1]", "diff replacement order"),
    ("diff: no long-text fallback", "        guard a.count <= maximumWords, b.count <= maximumWords else { return nil }\n", "", "diff long fallback"),
    ("diff: removed words lose their spacing", "raw.append((.removed, a[i])); i += 1",
     'raw.append((.removed, Token(word: a[i].word, trailing: ""))); i += 1', "diff removal"),
    ("diff: same words keep what COS typed", "raw.append((.same, b[j])); i += 1; j += 1", "raw.append((.same, a[i])); i += 1; j += 1",
     "diff spacing"),
    ("diff: unchanged words do not end a place", "if part.kind == .same { open = false; continue }", "if part.kind == .same { continue }",
     "diff regions"),
    ("diff: line breaks read as spaces", "if !out.isEmpty { out[out.count - 1].trailing.append(ch) }",
     'if !out.isEmpty { out[out.count - 1].trailing.append(" ") }', "diff tokens"),
    # The pill.
    ("pill: no edit shows EDIT SAVED", "guard let final else { return .silent }", "guard let final else { return .saved }", "pill silent"),
    ("pill: an edit with nothing learned is silent", "guard let last = learned.last else { return .saved }",
     "guard let last = learned.last else { return .silent }", "pill saved"),
    ("pill: learned only and both swapped", "? .learned(last.written) : .savedAndLearned(last.written)",
     "? .savedAndLearned(last.written) : .learned(last.written)", "pill learned only"),
    ("pill: learned only shows twice", "case .saved, .savedAndLearned: true\n        case .silent, .learned: false",
     "case .saved, .savedAndLearned, .learned: true\n        case .silent: false", "pill learned only"),
    ("pill: both loses the word", 'case .savedAndLearned(let word): "✓ EDIT SAVED · LEARNED " + word.uppercased()',
     'case .savedAndLearned(let word): "✓ EDIT SAVED" + String(word.prefix(0))', "pill both"),
    # The record.
    ("record: a bad edit drops the record", "edit = (try? c.decodeIfPresent(DictationUserEdit.self, forKey: .edit)) ?? nil",
     "edit = try c.decodeIfPresent(DictationUserEdit.self, forKey: .edit)", "record bad edit"),
    ("record: the edit is never written", "        try c.encodeIfPresent(edit, forKey: .edit)\n", "", "record round trip"),
    ("record: an edit needs learned keys", "learned = (try? c.decodeIfPresent([String].self, forKey: .learned)) ?? []",
     "learned = try c.decode([String].self, forKey: .learned)", "record edit decodes"),
    # Retargeted 0.5.344: the record carries polishPrompt after polishModel now.
    # 0.5.345: the history transforms carry typed and rawHeard too (A-W7, A-W10).
    ("record: Fix a word keeps a stale edit", "polishStyleHash: $0.polishStyleHash, polishCleaned: $0.polishCleaned,\n                                                 typed: $0.typed, rawHeard: $0.rawHeard) : $0 }",
     "polishStyleHash: $0.polishStyleHash, polishCleaned: $0.polishCleaned, edit: $0.edit,\n                                                 typed: $0.typed, rawHeard: $0.rawHeard) : $0 }", "record correcting drops edit"),
    ("record: editing drops the edit", "polishStyleHash: one.polishStyleHash, polishCleaned: one.polishCleaned, edit: edit,\n",
     "polishStyleHash: one.polishStyleHash, polishCleaned: one.polishCleaned,\n", "record editing"),
    ("record: search ignores what was sent", "[record.text, record.edit?.text].compactMap { $0 }", "[record.text].compactMap { $0 }",
     "record search edited"),
    ("record: meta line drops the edits", '        return line + " · " + DictationEditConfirm.editsLabel(edit.edits)\n',
     '        return line + String(edit.edits.description.prefix(0))\n', "record meta edits"),
    ("record: meta line counts what COS typed", "        let words = finalWordCount\n", "        let words = wordCount\n", "record meta edits"),
    ("record: the edit count can break across lines", 'n == 1 ? "1\\u{00A0}edit" : "\\(n)\\u{00A0}edits"',
     'n == 1 ? "1 edit" : "\\(n) edits"', "record meta edits"),
    ("record: tag keeps the app's case", 'static func tag(app: String) -> String { "EDITED IN " + app.uppercased() }',
     'static func tag(app: String) -> String { "EDITED IN " + app }', "record meta edits"),
    # The reason line.
    ("reason: a removed filler says nothing new", 'return "You removed \\(quoted(region.removed)). " + notEveryday',
     'return "You removed \\(quoted(region.removed)). " + nothingNew', "reason removal"),
    ("reason: learned loses its promise", 'return "Added \\(only) to your dictionary. Next time COS writes it for you."',
     'return "Added \\(only) to your dictionary."', "reason learned"),
    # The chip.
    ("chip: two places offered", "guard regions.count == 1, let region = regions.first, region.addedWords == 0 else { return nil }",
     "guard let region = regions.first, region.addedWords == 0 else { return nil }", "chip one place"),
    ("chip: a replacement offered", "guard regions.count == 1, let region = regions.first, region.addedWords == 0 else { return nil }",
     "guard regions.count == 1, let region = regions.first else { return nil }", "chip removal only"),
    ("chip: long phrases offered", "guard (1...dropMaximumWords).contains(words.count),", "guard (1...9).contains(words.count),",
     "chip three words"),
    ("chip: digits offered", "words.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains) })",
     "words.allSatisfy({ !$0.isEmpty })", "chip letters only"),
    ("chip: a handle's @ trimmed away", "let phrase = region.removed.trimmingCharacters(in: dropEdge)",
     "let phrase = region.removed.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))", "chip letters only"),
    ("chip: dictionary terms offered", "        guard !isTerm(phrase), !words.contains(where: isTerm) else { return nil }\n", "", "chip not a term"),
    ("chip: added twice", "        guard !holds(phrase, in: current) else { return nil }\n", "", "chip idempotent"),
    ("chip: case tells twice apart", "saved.range(of: instruction(phrase), options: [.caseInsensitive]) != nil",
     "saved.range(of: instruction(phrase), options: []) != nil", "chip idempotent"),
    ("chip: past the cap", "return DictationPolishInstructions.isOver(next) ? nil : next", "return next", "chip cap"),
    ("chip: Undo clears everything", ".filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != line }", ".filter { _ in false }",
     "chip undo"),
    ("chip: shown on an older server", "guard let phrase, available, polishOn else { return false }",
     "guard let phrase, polishOn else { return false }", "chip needs instructions"),
    ("chip: shown with polish off", "guard let phrase, available, polishOn else { return false }",
     "guard let phrase, available else { return false }", "chip needs polish"),
    ("chip: shown when already there", "        return adding(phrase, to: saved) != nil\n", "        return !phrase.isEmpty\n", "chip offered"),
    ("chip: instruction words", 'static func instruction(_ phrase: String) -> String { "Remove the filler \\"\\(phrase)\\"." }',
     'static func instruction(_ phrase: String) -> String { "Remove \\"\\(phrase)\\"." }', "chip instruction"),
    # Copy and the canary.
    ("copy: Show original ignored", "showOriginal ? record.text : record.finalText", "record.finalText", "copy follows the toggle"),
    ("canary: edited written on every watch", "    var edited: Bool? = nil\n", "    var edited: Bool? = false\n", "canary edited"),
]

CHECK_FAILURE = re.compile(r"EditConfirmChecks\.swift:\d+: Fatal error: check failed \[([^\]]+)\]")


def failed_check(output: str) -> "str | None":
    found = CHECK_FAILURE.search(output)
    return found.group(1).strip() if found else None


def classifier_self_test() -> None:
    cases = [
        ("/w/Tests/EditConfirmChecks.swift:14: Fatal error: check failed [diff removal] at line 45: x", "diff removal"),
        ("EditConfirmChecks.swift:14: Fatal error: check failed [chip one place] at line 9: ", "chip one place"),
        ("checks/MacDictationCore.swift:88: Fatal error: a trap in the core", None),
        ("Foundation/NSString.swift: Fatal error: NSRangeException", None),
    ]
    for text, want in cases:
        if failed_check(text) != want:
            sys.exit(f"classifier self-test failed: {text!r} read as {failed_check(text)!r}, expected {want!r}")
    print(f"classifier self-test: {len(cases)} cases")


def compile_once(work: pathlib.Path) -> tuple[bool, str, str]:
    out = work / "checks"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc",
                            "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                            str(work / CORE), str(work / CHECKS), "-o", str(out)], capture_output=True, text=True)
    output = build.stderr + build.stdout
    lines = output.splitlines()
    first_error = next((line for line in lines if "error:" in line), "")
    if build.returncode != 0 and not first_error:
        first_error = next((line for line in reversed(lines) if line.strip()), f"exit {build.returncode}")
    return build.returncode == 0, first_error.strip(), output


def compile_checks(work: pathlib.Path) -> tuple[bool, str]:
    # The bounded compile profile stops on a busy shared lock with an infrastructure error. Retry that, and only that.
    for attempt in range(4):
        built, error, output = compile_once(work)
        if built or "shared compile lock busy" not in output:
            return built, error
        print(f"  compile lock busy, attempt {attempt + 1} of 4", flush=True)
    return built, error


def classify(work: pathlib.Path, expected: "str | None") -> tuple[str, str]:
    built, error = compile_checks(work)
    if not built:
        return "INVALID", "did not compile: " + error
    try:
        run = subprocess.run([str(work / "checks")], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return "INVALID", "timed out"
    if run.returncode == 0:
        return "SURVIVED", ""
    message = failed_check(run.stderr + run.stdout)
    if message is None:
        tail = (run.stderr + run.stdout).strip().splitlines()
        return "CRASHED", tail[-1] if tail else f"exit {run.returncode}"
    if expected is not None and message != expected:
        return "MISATTRIBUTED", f"[{message}] failed first, expected [{expected}]"
    return "KILLED", message


classifier_self_test()
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-edit-confirm-mutants-", dir="/private/tmp"))
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / CHECKS, work / CHECKS)
    original = (work / CORE).read_text()
    for name, old, _, _ in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
    verdict, detail = classify(work, None)
    if verdict != "SURVIVED":
        sys.exit(f"baseline is not green ({verdict}: {detail}): fix the checks before reading any mutant")
    print("baseline green", flush=True)
    selected = [m for m in MUTANTS if any(m[0].startswith(prefix) for prefix in only.split("|"))]
    if not selected:
        sys.exit(f"no mutant name starts with {only!r}")
    results: dict[str, list[str]] = {"KILLED": [], "SURVIVED": [], "MISATTRIBUTED": [], "INVALID": [], "CRASHED": []}
    for name, old, new, expected in selected:
        (work / CORE).write_text(original.replace(old, new))
        verdict, detail = classify(work, expected)
        results[verdict].append(name)
        print(f"{verdict:13} {name}" + (f"  <- {detail}" if detail else ""), flush=True)
        (work / CORE).write_text(original)
    print(f"{len(results['KILLED'])} killed by their named check, {len(results['SURVIVED'])} survived, {len(results['MISATTRIBUTED'])} misattributed, "
          f"{len(results['INVALID'])} invalid, {len(results['CRASHED'])} crashed outside the checks")
    failing = {k: v for k, v in results.items() if k != "KILLED" and v}
    if failing:
        sys.exit("mutation gate FAILED: " + "; ".join(f"{k.lower()}: {v}" for k, v in failing.items()))
    print(f"PASS edit confirm mutation gate: {len(selected)} mutants" + (f" (of {len(MUTANTS)}, named {only!r})" if only else "")
          + ", each killed by its named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
