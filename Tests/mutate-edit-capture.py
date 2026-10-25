#!/usr/bin/env python3
"""0.5.344 Capture every correction (plan r2): the mutation gate for the watch loop and its rules
(Sources/MacDictationCore.swift: DictationEditWatch, the 0.5.344 DictationEditLearning rules, DictationWatchSignal, the
canary's new helpers, the staleness guard in DictationEditConfirm.captured, and the polish "unchanged" mapping) against
Tests/EditCaptureChecks.swift, which runs the real loop against a fake field and a fake clock.

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly once.

A KILL counts only when the mutant compiles, runs, and the check that fails first is the one the mutant names, so every
kill is attributed to the behaviour it breaks. Everything else fails this gate on its own line: SURVIVED, MISATTRIBUTED,
INVALID (did not compile, or timed out), CRASHED (a trap outside the checks).

Not mutated, on purpose: the closed-set filter on polishOutcome (an unknown word matches no branch, so dropping the
filter is an equivalent mutant), the tick path's `tried` flag (a tick-path read that fails has no fixture yet; the poll
path's is mutated), and `.lost` read as inconsistent (no fixture loses the dictation in a tracker read).

Usage: python3 Tests/mutate-edit-capture.py <repo root> [--only <name prefix>[|<prefix>...]]
"""
import os
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
CORE = "Sources/MacDictationCore.swift"
CHECKS = "Tests/EditCaptureChecks.swift"

# (name, old, new, the behaviour whose check must fail first)
MUTANTS = [
    # 0.5.344 part 2: the counts and the gap.
    ("gap: gone after typing kept", "            if DictationEditLearning.goneAfterTyping(read.read, keysSinceRead: clock.keys() - keysAtRead) { unread += 1 }\n", "",
     "gone after typing keeps nothing"),
    ("gap: keys never reset at a read", "            if let seen { last = seen }\n            keysAtRead = clock.keys()\n", "            if let seen { last = seen }\n",
     "typing before the read counts nothing"),
    ("gap rule: a held read counts", "    static func goneAfterTyping(_ read: DictationEditWatch.Read, keysSinceRead: Int) -> Bool { read == .gone && keysSinceRead > 0 }",
     "    static func goneAfterTyping(_ read: DictationEditWatch.Read, keysSinceRead: Int) -> Bool { keysSinceRead > 0 }", "gap rule"),
    ("counts: Return is typing", "        watching && learning && inApp && keyDown && !sendKeyCodes.contains(keyCode)", "        watching && learning && inApp && keyDown",
     "counts typed keys"),
    ("counts: typed keys in any app", "        watching && learning && inApp && keyDown && !sendKeyCodes.contains(keyCode)",
     "        watching && learning && keyDown && !sendKeyCodes.contains(keyCode)", "counts typed keys"),
    ("counts: inputs in any app", "        watching && learning && inApp && (keyDown || pointer)", "        watching && learning && (keyDown || pointer)", "counts in the app"),
    ("counts: a modifier change is input", "        watching && learning && inApp && (keyDown || pointer)", "        watching && learning && inApp", "counts input"),
    ("counts: without a watch", "        watching && learning && inApp && (keyDown || pointer)", "        inApp && (keyDown || pointer)", "counts while watching"),
    ("signal: counts after the watch", "            guard !s.closed else { return }\n            if input { s.inputs += 1 }", "            if input { s.inputs += 1 }",
     "signal counts"),
    ("signal: inputs not counted", "            if input { s.inputs += 1 }\n", "", "signal counts"),
    ("watch: inputs not reported", "            out.inputEvents = clock.inputs()\n", "", "watch counts inputs"),
    ("watch: keys after the read not reported", "                out.keysAfterRead = max(0, clock.keys() - keysAtRead)\n", "", "gone after typing keeps nothing"),
    ("watch: start re-anchor unmarked", "        tail.startReanchor = pending != nil\n", "", "start reanchor marked"),
    # The trigger.
    ("trigger: no watch needed", "        guard watching, learning else { return nil }\n        if pointer { return .mouse }",
     "        guard learning else { return nil }\n        if pointer { return .mouse }", "trigger needs a watch"),
    ("trigger: learning ignored", "        guard watching, learning else { return nil }\n        if pointer { return .mouse }",
     "        guard watching else { return nil }\n        if pointer { return .mouse }", "trigger needs learning"),
    ("trigger: no clicks", "        if pointer { return .mouse }", "        if pointer { return nil }", "trigger click"),
    ("trigger: auto-repeat reads", "        guard keyDown, !isRepeat, sendKeyCodes.contains(keyCode) else { return nil }",
     "        guard keyDown, sendKeyCodes.contains(keyCode) else { return nil }", "trigger repeat"),
    ("trigger: any key reads", "        guard keyDown, !isRepeat, sendKeyCodes.contains(keyCode) else { return nil }",
     "        guard keyDown, !isRepeat else { return nil }", "trigger other keys"),
    ("trigger: a modifier change reads", "        guard keyDown, !isRepeat, sendKeyCodes.contains(keyCode) else { return nil }",
     "        guard !isRepeat, sendKeyCodes.contains(keyCode) else { return nil }", "trigger modifiers"),
    ("trigger: Enter dropped", "    static let sendKeyCodes: Set<UInt16> = [36, 76]", "    static let sendKeyCodes: Set<UInt16> = [36]", "trigger keys"),
    # The cadence rules.
    ("fast: ticks at 500 ms", "    static let fastTickMilliseconds = 175", "    static let fastTickMilliseconds = 500", "fast tick range"),
    ("fast: a second of quiet", "    static let quietSeconds: TimeInterval = 0.4", "    static let quietSeconds: TimeInterval = 1.0", "fast quiet"),
    ("fast mode: ticks while idle", "        unread > 0 && !tried && !backedOff && fastSeconds < fastModeSeconds",
     "        !tried && !backedOff && fastSeconds < fastModeSeconds", "fast mode idle"),
    ("fast mode: retried at speed", "        unread > 0 && !tried && !backedOff && fastSeconds < fastModeSeconds",
     "        unread > 0 && !backedOff && fastSeconds < fastModeSeconds", "fast mode tried"),
    ("fast mode: no backoff", "        unread > 0 && !tried && !backedOff && fastSeconds < fastModeSeconds",
     "        unread > 0 && !tried && fastSeconds < fastModeSeconds", "fast mode backoff"),
    ("fast mode: no cap", "        unread > 0 && !tried && !backedOff && fastSeconds < fastModeSeconds",
     "        unread > 0 && !tried && !backedOff", "fast mode cap"),
    ("final read: no spacing", "        return sinceLast >= finalReadSpacing", "        return true", "final read spacing"),
    ("final read: no cap", "        guard finalReads < maximumFinalReads else { return false }\n", "", "final read cap"),
    ("stop read: not at focus left", "        guard [Stop.focusLeft, .cap, .reads].contains(stop), unread > 0, let fieldCharacters else { return false }",
     "        guard [Stop.cap, .reads].contains(stop), unread > 0, let fieldCharacters else { return false }", "final read at stop"),
    ("stop read: a sent field read", "        return fieldCharacters > 1\n    }\n    /// The canary's word", "        return true\n    }\n    /// The canary's word",
     "final read at stop limits"),
    ("change at stop: the send counted", "    static func changeCounts(at stop: Stop) -> Bool { stop != .cleared && stop != .emptied }",
     "    static func changeCounts(at stop: Stop) -> Bool { stop != .emptied }", "change at stop"),
    ("looks sent: one character is text", "fieldCharacters <= 1 && dictationLength > 1 }", "fieldCharacters < 1 && dictationLength > 1 }", "looks sent"),
    ("unwatched: no target watched", '            if !hasTarget { return "noTarget" }\n', "", "unwatched"),
    ("unwatched: learning off written", "        guard !learnOff else { return nil }\n        switch outcome {", "        switch outcome {", "unwatched"),
    ("captured: stale kept", "        guard unread == 0 else { return nil }\n", "", "captured stale"),
    # The polish mapping.
    ("polish: same words not unchanged", "            if sameWords(text, heard) { return .unchanged }\n", "", "polish unchanged"),
    ("polish: untrimmed compare", "        text.trimmingCharacters(in: .whitespacesAndNewlines) == heard.trimmingCharacters(in: .whitespacesAndNewlines)",
     "        text == heard", "polish unchanged trimmed"),
    ("polish: an unknown skip is unchanged", '            guard skipped == nil, said != "polished", let text,', '            guard said != "polished", let text,', "polish unknown skip"),
    ("polish: polished word over the flag", '            guard skipped == nil, said != "polished", let text,', '            guard skipped == nil, let text,',
     "polish outcome contradiction"),
    ("polish: fillers pasted back", '        if said == "unchanged" { return sameWords(text, heard) ? .unchanged : .fillersOnly("unchanged", text: text) }',
     '        if said == "unchanged" { return .unchanged }', "polish fillers removed, model unchanged"),
    ("polish: unchanged called polished", '        if said == "unchanged" { return sameWords(text, heard) ? .unchanged : .fillersOnly("unchanged", text: text) }\n', "",
     "polish fillers removed, model unchanged"),
    ("polish: guarded believed", ' ?? (said == "guarded" ? "guarded" : nil)', "", "polish guarded"),
    # The polish prompt (contract addition).
    ("prompt: any version", "    static func promptVersion(_ raw: String?) -> String? { raw.flatMap { promptVersions.contains($0) ? $0 : nil } }",
     "    static func promptVersion(_ raw: String?) -> String? { raw }", "polish prompt closed"),
    ("prompt: v4 not a version", '    static let promptVersions: Set<String> = ["v3", "v4"]', '    static let promptVersions: Set<String> = ["v3"]', "polish prompt versions"),
    ("card: v3 labelled", '(polishPrompt == "v4" ? " · v4" : "")', '(polishPrompt.map { " · " + $0 } ?? "")', "card label v3 unlabelled"),
    ("card: v4 unlabelled", '(polishPrompt == "v4" ? " · v4" : "")', '("")', "card label v4"),
    ("record: the prompt not written", "        try c.encodeIfPresent(polishPrompt, forKey: .polishPrompt)\n", "", "record prompt"),
    ("history: Fix a word drops the prompt", "polishModel: $0.polishModel, polishPrompt: $0.polishPrompt,\n", "polishModel: $0.polishModel,\n",
     "history keeps the prompt"),
    ("timing: the prompt not recorded", "        polishPrompt = DictationPolish.promptVersion(run.prompt)\n", "", "timing prompt"),
    # The canary.
    ("canary: whole seconds", "        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]",
     "        formatter.formatOptions = [.withInternetDateTime]", "canary ms stamp"),
    ("canary: learning off written", '    static func recordsSkip(_ reason: String) -> Bool { reason != "off" }', '    static func recordsSkip(_ reason: String) -> Bool { true }',
     "skip row off"),
    # The signal.
    ("signal: a trigger between pauses lost", "            guard let waiter = s.waiter else { s.pending = trigger; return nil }",
     "            guard let waiter = s.waiter else { return nil }", "signal kept"),
    ("signal: a trigger never wakes", "            s.waiter = nil; s.generation += 1\n            return waiter\n        }\n        waiting?.resume(returning: trigger)",
     "            s.pending = trigger\n            return nil\n        }\n        waiting?.resume(returning: trigger)", "signal wakes"),
    ("signal: a closed watch waits", "                    if s.closed { return .now(nil) }\n", "", "signal closed"),
    # The loop.
    ("loop: sent before watch read", "        if DictationEditLearning.looksSent(fieldCharacters: n0, dictationLength: span.length) {",
     "        if false {", "sent before watch"),
    ("loop: no read at the trigger", "                await finalRead(trigger.rawValue)\n", "                _ = trigger\n", "edit then Return under 0.4 s"),
    ("loop: final reads not spaced", "            if let trigger, DictationEditLearning.finalReadAllowed(sinceLast: lastFinal.map { clock.now() - $0 }, finalReads: finalReads) {",
     "            if let trigger {", "final reads: at most one per 300 ms"),
    ("loop: a secure field read", '            guard !(await field.secure()) else { canary.secureInput = "on"; return }\n', "", "secure input is never read"),
    ("loop: the counts not checked twice", "        guard after.characters == n else { return (nil, .inconsistent, after) }\n", "", "an inconsistent read is discarded"),
    ("loop: an edit read but not counted", "        case .inside(_, let l): next.length = l; next.sawInside += 1", "        case .inside(_, let l): next.length = l",
     "edit then Return under 0.4 s"),
    ("loop: the send counted unread", "                if changed, DictationEditLearning.changeCounts(at: why) { unread += 1 }",
     "                if changed { unread += 1 }", "edit then Return under 0.4 s"),
    ("loop: no read when focus leaves", "                if DictationEditLearning.readsAtStop(why, unread: unread, fieldCharacters: now.characters) {",
     "                if false {", "focus left: one last read keeps the edit"),
    ("loop: a read leaves the change unread", "            lastPlaced = clock.now(); unread = 0\n", "            lastPlaced = clock.now()\n", "edit then Return after 1 s"),
    ("loop: a read leaves the marker behind", "            if let seen { last = seen }\n", "", "a final read leaves nothing unread"),
    ("loop: staleness not wired", "                                                  unread: canary.unreadChanges ?? 0)", "                                                  unread: 0)",
     "a change unread at the end keeps nothing"),
    ("loop: fast ticks never", "            let wait = DictationEditLearning.wait(fastMode: fast, sinceFullPoll: clock.now() - lastFull)",
     "            let wait = DictationEditLearning.wait(fastMode: false, sinceFullPoll: clock.now() - lastFull)", "fast: ticks every 175 ms while a change is unread"),
    ("loop: a slow tick ignored", "                if clock.now() - tickStart > DictationEditLearning.slowTickSeconds { backedOff = true; canary.fastBackoff = true }\n", "",
     "fast: a slow tick ends fast ticking"),
    ("loop: fast time not counted", "            if fast { fastSeconds += Double(wait) / 1000 }\n", "", "fast: at most 10 s of fast ticking a watch"),
    ("loop: a failed read retried", "                tried = true; trackerReads += 1\n                let read = await trackerRead(field, from: tracker, windowStart: bounds.location, measured: now,",
     "                trackerReads += 1\n                let read = await trackerRead(field, from: tracker, windowStart: bounds.location, measured: now,",
     "fast ticking stops once its read was tried"),
    # Two states: the learning baseline must not move on a tracker read (plan r2's named mutant), at either site.
    ("two states: a poll's tracker read moves the baseline", "measured: now, calls: &calls)\n                if let next = read.tracker { keep(next, seen: read.seen) }",
     "measured: now, calls: &calls)\n                if let next = read.tracker { keep(next, seen: read.seen); baseline = next.window; start = next.start; length = next.length; baseCount = next.characters }",
     "learning baseline moves only on the 1.5 s read"),
    ("two states: a tick's tracker read moves the baseline", "measured: seen, calls: &calls)\n                    if let next = read.tracker { keep(next, seen: read.seen) }",
     "measured: seen, calls: &calls)\n                    if let next = read.tracker { keep(next, seen: read.seen); baseline = next.window; start = next.start; length = next.length; baseCount = next.characters }",
     "learning baseline moves only on the 1.5 s read (tick)"),
]

CHECK_FAILURE = re.compile(r"EditCaptureChecks\.swift:\d+: Fatal error: check failed \[([^\]]+)\]")


def failed_check(output: str) -> "str | None":
    found = CHECK_FAILURE.search(output)
    return found.group(1).strip() if found else None


def classifier_self_test() -> None:
    cases = [
        ("/w/Tests/EditCaptureChecks.swift:17: Fatal error: check failed [trigger click] at line 45: x", "trigger click"),
        ("EditCaptureChecks.swift:17: Fatal error: check failed [fast: a slow tick ends fast ticking] at line 9: ", "fast: a slow tick ends fast ticking"),
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
        run = subprocess.run([str(work / "checks")], capture_output=True, text=True, timeout=180)
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
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-edit-capture-mutants-", dir="/private/tmp"))
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
    print(f"PASS edit capture mutation gate: {len(selected)} mutants" + (f" (of {len(MUTANTS)}, named {only!r})" if only else "")
          + ", each killed by its named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
