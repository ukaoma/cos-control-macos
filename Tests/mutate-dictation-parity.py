#!/usr/bin/env python3
"""0.5.345 Wave A (plan r3): the mutation gate for the pure rules in Sources/MacDictationCore.swift (DictationFillers and
its language gate, DictationCasing, DictationUndoPolish, DictationPolishMatch, DictationNextTime, DictationPolishPicker,
DictationSwapWait, DictationClipboard.restoresOver, DictationAudioBreaker, DictationSoundGate, DictationMicFallback and the
history's new fields) against Tests/DictationParityChecks.swift, which runs them on fictional fixtures and the canonical
fillers fixture.

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly once.

A KILL counts only when the mutant compiles, runs, and the check that fails first is the one the mutant names, so every
kill is attributed to the behaviour it breaks. Everything else fails this gate on its own line: SURVIVED, MISATTRIBUTED,
INVALID (did not compile, or timed out), CRASHED (a trap outside the checks).

Usage: python3 Tests/mutate-dictation-parity.py <repo root> [--only <name prefix>[|<prefix>...]]
"""
import os
import pathlib, re, shutil, subprocess, sys, tempfile, time

root = pathlib.Path(sys.argv[1]).resolve()
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
CORE = "Sources/MacDictationCore.swift"
CHECKS = "Tests/DictationParityChecks.swift"

# (name, old, new, the behaviour whose check must fail first)
MUTANTS = [
    # A-W10 the filler strip, its exemptions and the language gate
    ("fillers: no touch before", "static func touches(before: String, after: String) -> Bool { test(touchBefore, before) || test(touchAfter, after) }",
     "static func touches(before: String, after: String) -> Bool { test(touchAfter, after) }", "fillers touch before"),
    ("fillers: no touch after", "static func touches(before: String, after: String) -> Bool { test(touchBefore, before) || test(touchAfter, after) }",
     "static func touches(before: String, after: String) -> Bool { test(touchBefore, before) }", "fillers touch after"),
    ("fillers: a quoted mention removed", "                || (test(quoteOpen, out + before) && test(quoteClose, after))\n", "", "fillers fixture both"),
    ("fillers: capital never handed on", "                    after = a.replacingCharacters(in: m.range, with: open + utf16Upper(ch))", "                    _ = (open, ch)", "fillers fixture both"),
    ("fillers: long text at 0.5", "            return top?.key == \"en\" && (top?.value ?? 0) >= 0.8", "            return top?.key == \"en\" && (top?.value ?? 0) >= 0.5", "fillers long text needs 0.8"),
    ("fillers: short text never gated", "        return top.key == \"en\" || top.value < shortSignal", "        return true", "fillers gate parity"),
    ("fillers: accents ignored", "        if gate.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && !$0.isASCII }) { return false }\n", "", "fillers short text non-ascii"),
    ("fillers: short replies ignored", "        if words.contains(where: { shortReplies.contains($0.lowercased()) }) { return true }\n", "", "fillers short replies"),
    ("fillers: gate reads the fillers", "        let gate = gateText(text)\n", "        let gate = text\n", "fillers english strips"),
    ("fillers: setting ignored", "        guard enabled, test(filler, text, [.caseInsensitive]), englishEnough(text, hypotheses: hypotheses) else { return (text, false) }",
     "        guard test(filler, text, [.caseInsensitive]), englishEnough(text, hypotheses: hypotheses) else { return (text, false) }", "fillers off"),
    ("fillers: removed always false", "        return (stripped, stripped != text)", "        return (stripped, false)", "fillers removed flag"),
    ("fillers: built-in set empty", "        return regex(#\"\\A(?:um+|uhm|uh+|erm?|ah+|hm+|mm+|mhm)\\z\"#)", "        return regex(#\"\\A(?:zzz)\\z\"#)", "fillers built-in tokens"),
    # A-W9a casing
    ("casing: inner capital", "        if word.dropFirst().contains(where: { $0.isUppercase }) { return \"innerCapital\" }\n", "", "casing inner capital"),
    ("casing: marks", "        if word.contains(where: { \"/.@_:\".contains($0) }) { return \"mark\" }\n", "", "casing mark"),
    ("casing: commands", "        if commands.contains(bare) { return \"command\" }\n", "", "casing command"),
    ("casing: terms", "        if isTerm(bare) || isTerm(String(word)) { return \"term\" }\n", "", "casing term"),
    ("casing: abbreviations", "        if test(DictationFillers.abbreviation, trimmed, [.caseInsensitive]) { return false }\n", "", "casing abbreviation"),
    ("casing: initials", "        if test(DictationFillers.initial, trimmed) { return false }\n", "", "casing initial"),
    ("casing: ellipsis", "        if test(ellipsisEnd, trimmed) { return false }\n", "", "casing ellipsis"),
    ("casing: code fence", "        if test(#\"(?:^|\\n)[ \\t]*```[^\\n]*\\n\\z\"#, trimmed) { return false }\n", "", "casing code fence"),
    ("casing: terminals", "        guard !terminal, !secure, let before, !lowercaseAsked(instructions), startsSentence(before),", "        guard !secure, let before, !lowercaseAsked(instructions), startsSentence(before),", "casing terminal"),
    ("casing: password fields", "        guard !terminal, !secure, let before, !lowercaseAsked(instructions), startsSentence(before),", "        guard !terminal, let before, !lowercaseAsked(instructions), startsSentence(before),", "casing secure"),
    ("casing: lowercase asked ignored", "        guard !terminal, !secure, let before, !lowercaseAsked(instructions), startsSentence(before),", "        guard !terminal, !secure, let before, startsSentence(before),", "casing lowercase asked"),
    ("casing: any script", "        guard first.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic && $0.value < 0x0250 }) else { return \"script\" }\n", "", "casing script"),
    ("casing: mid sentence", "        guard test(#\"[.?!][\"”’)]*\\z\"#, trimmed) else { return false }", "        guard true else { return false }", "casing mid sentence"),
    ("casing: field start assumed", "        if trimmed.isEmpty { return before.reachesStart }", "        if trimmed.isEmpty { return true }", "casing needs a read"),
    # A-W7 Undo polish
    ("undo: a moved span replaced", "        case .edit(_, let at): at == span.location ? nil : .textMoved", "        case .edit: nil", "undo moved span refuses"),
    ("undo: heard instead of typed", "        return record.typed ?? record.heard", "        return record.heard", "undo restores typed"),
    ("undo: span not required", "        if swapped, tracked, restoreText(record) != nil { return [.undoPolish, .showOriginal] }", "        if swapped, restoreText(record) != nil { return [.undoPolish, .showOriginal] }", "undo needs the span"),
    ("undo: heard lost", "        let raw = record.rawHeard ?? (record.heard != restored ? record.heard : nil)", "        let raw = record.rawHeard", "undo record"),
    # A-W11 polish already fixed this
    ("match: any deletion", "        guard user.deleted.isSubset(of: polish.deleted) else { return false }\n", "", "match deletion not made by polish"),
    ("match: any insertion", "            guard let theirs = polish.inserted[anchor], isSubsequence(added, of: theirs) else { return false }", "            _ = anchor", "match different is not"),
    ("match: no change matches", "        guard let user = ops(t, words(final)), let polish = ops(t, words(polished)), !user.isEmpty else { return false }",
     "        guard let user = ops(t, words(final)), let polish = ops(t, words(polished)) else { return false }", "match no change is not"),
    ("match: baseline keeps both-deleted", "            if index < normal.count, !(user.deleted.contains(index) && polish.deleted.contains(index)) { out.append(raw[index]) }",
     "            if index < normal.count { out.append(raw[index]) }", "match style baseline"),
    # A-W12 next time
    ("next: learned dropped", "        var out = learned.map(learnedLine)", "        var out: [String] = []", "next learned"),
    ("next: changes never listed", "            out.append(!changes.isEmpty && changes.count <= 3", "            out.append(false", "next polish had it"),
    ("next: active reads seen", "        if style.active { return \"Style rule now active: \\(rule).\" }\n", "", "next style active"),
    ("next: seen off by one", "        let seen = min(style.support, DictationStyle.promoteAfter - 1)", "        let seen = style.support + 1", "next style counted"),
    ("next: filler note without the setting", "        if fillersOn, !matchedPolish, regions.contains(where: fillerOnly) { out.append(fillerLine) }",
     "        if !matchedPolish, regions.contains(where: fillerOnly) { out.append(fillerLine) }", "next filler note"),
    ("next: nothing line gone", "        if out.isEmpty { return ([nothingLine], 0) }", "        if out.isEmpty { return ([], 0) }", "next filler note"),
    ("next: no limit", "        return (Array(out.prefix(limit)), max(0, out.count - limit))", "        return (out, 0)", "next at most three"),
    # A-W2 the picker
    ("picker: guard flag ignored", "            let base = server.meaningGuard ?? true ? newest : newestNoGuard", "            let base = newest", "picker sonnet v4 guard off"),
    ("picker: Haiku on v4 called newest", "            guard model == .sonnet else { return otherModelNewest }\n", "", "picker haiku v4"),
    ("picker: Previous polish unnamed", "        if server.promptVersion == \"v3\", !server.envOverride { return previous }\n", "", "picker previous polish"),
    ("picker: style suffix always", "    static func styleSuffix(_ rules: Int) -> String? { rules > 0 ?", "    static func styleSuffix(_ rules: Int) -> String? { rules >= 0 ?", "picker sonnet v4 guard on"),
    ("picker: Off forgets the strip", "    static func off(fillers: Bool) -> String { \"Pastes what was heard\" + (fillers ? \", without um and uh.\" : \".\") }",
     "    static func off(fillers: Bool) -> String { \"Pastes what was heard.\" }", "picker off fillers"),
    ("picker: no reload on a change", "    static func reloads(versionChanged: Bool, needsReload: Bool, enabledDiffers: Bool) -> Bool { versionChanged || needsReload || enabledDiffers }",
     "    static func reloads(versionChanged: Bool, needsReload: Bool, enabledDiffers: Bool) -> Bool { needsReload || enabledDiffers }", "picker reload on change"),
    # A-W3b the wait
    ("wait: Shift waits", "            if held.contains(.shift) || held.contains(.opt) || !enabled { return .skip(.keysHeld) }", "            if !enabled { return .skip(.keysHeld) }", "wait shift skips"),
    ("wait: no bound", "            return waitedMs >= releaseMilliseconds ? .skip(.keysHeld) : .wait", "            return .wait", "wait cmd bound"),
    ("wait: no quiet moment", "        if sinceKeyDownMs >= quietMilliseconds { return .go }", "        return .go", "wait quiet after release"),
    ("wait: its own 300 ms quiet", "    static let quietMilliseconds = DictationPolishSwap.quietMilliseconds", "    static let quietMilliseconds = 300", "wait quiet after release"),
    ("wait: quiet unbounded after release", "        return waitedMs - since >= quietMilliseconds ? .skip(.typing) : .wait", "        return waitedMs - since >= releaseMilliseconds ? .skip(.typing) : .wait", "wait quiet bound"),
    ("wait: toggle ignored", "            if held.contains(.shift) || held.contains(.opt) || !enabled { return .skip(.keysHeld) }", "            if held.contains(.shift) || held.contains(.opt) { return .skip(.keysHeld) }", "wait toggle off"),
    ("wait: newer clipboard overwritten", "    static func restoresOver(setChangeCount: Int, currentChangeCount: Int) -> Bool { currentChangeCount == setChangeCount }",
     "    static func restoresOver(setChangeCount: Int, currentChangeCount: Int) -> Bool { true }", "wait newer clipboard kept"),
    ("wait: delivery cap without the reads", "        + DictationDelivery.modifierWaitMilliseconds + (landingPollMilliseconds.last ?? 0) + accessibilityReadAllowanceMilliseconds",
     "        + DictationDelivery.modifierWaitMilliseconds", "wait delivery cap covers the swap"),
    # A-W1 audio
    ("audio: a zero status trips", "        guard status != 0 else { return }\n        until = now + Self.pauseSeconds", "        until = now + Self.pauseSeconds", "audio breaker error status only"),
    ("audio: a minute", "    static let pauseSeconds: TimeInterval = 600", "    static let pauseSeconds: TimeInterval = 60", "audio breaker ten minutes"),
    ("audio: reset keeps it open", "    mutating func reset() { until = nil; lastStatus = nil }", "    mutating func reset() { lastStatus = nil }", "audio breaker reset"),
    ("sound: plays over a start", "        return outstanding ? .dropBusy : .play", "        return .play", "sound drop while starting"),
    ("sound: late plays", "        return (now - askedAt) * 1000 > Double(lateMilliseconds) ? .dropLate : .play", "        return .play", "sound drop late"),
    ("audio: what is permission", "    static func isPermission(status: Int32) -> Bool { status == 560_492_391", "    static func isPermission(status: Int32) -> Bool { status == 2_003_329_396 || status == 560_492_391", "audio what is not permission"),
    ("fallback: Continuity allowed", "    static let excludedTransports: Set<String> = [\"blue\", \"btle\", \"virt\", \"grup\", \"ccwd\", \"ccwl\", \"airp\", \"cntn\", \"\"]",
     "    static let excludedTransports: Set<String> = [\"blue\", \"btle\", \"virt\", \"grup\", \"ccwl\", \"airp\", \"cntn\", \"\"]", "fallback exclusions"),
    ("fallback: the failed device again", "            .filter { eligible($0) && $0.uid != failedUID && !(lidClosed && $0.transport == \"bltn\") }",
     "            .filter { eligible($0) && !(lidClosed && $0.transport == \"bltn\") }", "fallback never the failed device"),
    ("fallback: lid ignored", "            .filter { eligible($0) && $0.uid != failedUID && !(lidClosed && $0.transport == \"bltn\") }",
     "            .filter { eligible($0) && $0.uid != failedUID }", "fallback lid closed"),
    ("fallback: silent remembered", "        guard nonSilent, eligible(device) else { return good }", "        guard eligible(device) else { return good }", "fallback non-silent memory"),
    ("fallback: Bluetooth remembered", "        guard nonSilent, eligible(device) else { return good }", "        guard nonSilent else { return good }", "fallback no bluetooth memory"),
    ("fallback: timeout triggers", "        engineStartThrew || firstAudio == .failed", "        engineStartThrew || firstAudio == .failed || firstAudio == .timedOut", "fallback triggers"),
    ("fallback: slow first attempt retried", "    static func mayRetry(firstAttemptMs: Int) -> Bool { firstAttemptMs < retryUnderMilliseconds }", "    static func mayRetry(firstAttemptMs: Int) -> Bool { true }", "fallback retry bound"),
    ("fallback: raw error words", "            : \"macOS audio isn't responding. Try again, or restart the Mac.\"", "            : \"The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 2003329396.)\"", "fallback messages"),
    # history
    ("history: typed dropped by polishing", "                                                     typed: (typed ?? r.typed ?? r.text) == heard ? nil : (typed ?? r.typed ?? r.text), rawHeard: nil) : r }",
     "                                                     typed: nil, rawHeard: nil) : r }", "history polishing keeps typed"),
    ("history: typed not decoded", "        typed = (try? c.decodeIfPresent(String.self, forKey: .typed)) ?? nil", "        typed = nil", "history round trip"),
]

CHECK_FAILURE = re.compile(r"DictationParityChecks\.swift:\d+: Fatal error: check failed \[([^\]]+)\]")


def failed_check(output: str) -> "str | None":
    found = CHECK_FAILURE.search(output)
    return found.group(1).strip() if found else None


def classifier_self_test() -> None:
    cases = [
        ("/w/Tests/DictationParityChecks.swift:17: Fatal error: check failed [pill once] at line 45: x", "pill once"),
        ("DictationParityChecks.swift:17: Fatal error: check failed [sync 409 merge] at line 9: ", "sync 409 merge"),
        ("checks/MacDictationCore.swift:88: Fatal error: a trap in the core", None),
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
    # The bounded guard refuses to start below its memory floor (another agent's compile): wait, then try again.
    for attempt in range(10):
        built, error, output = compile_once(work)
        if built or not ("shared compile lock busy" in output or "compile-bounded: refused" in output):
            return built, error
        print(f"  compile guard busy or refused (memory floor), attempt {attempt + 1} of 10", flush=True)
        time.sleep(30)
    return built, error


def classify(work: pathlib.Path, expected: "str | None") -> tuple[str, str]:
    built, error = compile_checks(work)
    if not built:
        return "INVALID", "did not compile: " + error
    try:
        run = subprocess.run([str(work / "checks"), str(work)], capture_output=True, text=True, timeout=180)
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
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-dictation-parity-mutants-", dir="/private/tmp"))
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / CHECKS, work / CHECKS)
    (work / "Tests/fixtures").mkdir(parents=True)
    shutil.copy(root / "Tests/fixtures/dictation-fillers.json", work / "Tests/fixtures/dictation-fillers.json")
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
    print(f"PASS dictation parity mutation gate: {len(selected)} mutants" + (f" (of {len(MUTANTS)}, named {only!r})" if only else "")
          + ", each killed by its named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
