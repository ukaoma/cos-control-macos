#!/usr/bin/env python3
"""0.5.343 Build-up, in place: the mutation gate for the pure half (Sources/Models.swift, the section "Build-up, in place
(0.5.343)", which runs to the end of the file) against Tests/BuildUpChecks.swift.

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). The section is Foundation only, so each mutant compiles that section alone with the checks
(seconds), never the 13K-line Models.swift. Works on a scratch copy, so the checkout is never mutated. A GREEN baseline
is required before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly
once.

A KILL counts only when the mutant compiles, runs, and the check that fails first is the one the mutant names, so every
kill is attributed to the behaviour it breaks. Everything else fails this gate on its own line: SURVIVED (the checks
passed), MISATTRIBUTED (another check failed first), INVALID (did not compile, or timed out), CRASHED (a trap outside
the checks).

Not mutated, on purpose: the progress clamps (bezier() is bounded to [0, 1] in x by its bisection, so dropping a clamp
changes nothing a check can see).

Usage: python3 Tests/mutate-build-up.py <repo root> [--only <name prefix>[|<prefix>...]]
"""
import os
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
MODELS = "Sources/Models.swift"
CHECKS = "Tests/BuildUpChecks.swift"
MARK = "// MARK: - Build-up, in place (0.5.343)"

# (name, old, new, the behaviour whose check must fail first)
MUTANTS = [
    # The grace.
    ("grace: no delay", "static let graceSeconds = 0.15", "static let graceSeconds = 0.0", "grace delay"),
    ("grace: a fast load still builds", "            if !loading { settle(t, landed ? .direct : (failed ? .failed : .empty)) }", "            if !loading { move(.handoff, t) }", "grace skips build"),
    ("grace: a fast empty is not remembered", "            if !loading { settle(t, landed ? .direct : (failed ? .failed : .empty)) }", "            if !loading { settle(t, .direct) }", "grace skips build"),
    ("failed: a fast error counts as empty", "            if !loading { settle(t, landed ? .direct : (failed ? .failed : .empty)) }", "            if !loading { settle(t, landed ? .direct : .empty) }", "failed"),
    ("failed: an error counts as empty", "finish(t, failed ? .failed : .empty) }", "finish(t, .empty) }", "failed"),
    ("grace: never builds", "if reduced { settle(t, .still) } else { move(.building, t); builtAt = t }", "if reduced { settle(t, .still) }", "landing continuous"),
    # Reduce Motion.
    ("reduce motion: draws a wire", "if reduced { settle(t, .still) } else { move(.building, t); builtAt = t }",
     "move(.building, t); builtAt = t", "reduce motion"),
    ("reduce motion: not latched", "        if turnedOn { reduced = true }\n", "", "reduce motion latch"),
    ("reduce motion: no grace", "        if landed || self.count == 0 || quiet { phase = .settled }",
     "        if landed || self.count == 0 || quiet || reduced { phase = .settled }", "reduce motion"),
    ("reduce motion: ignored mid-build", "        if turnedOn, phase == .building || phase == .landing { settle(t, .still) }\n", "", "reduce motion mid-build"),
    # The landing.
    ("land: the data never shows", "if landed { move(.landing, t); landedAt = t; finish(t, .landed) }", "if landed { move(.settled, t); finish(t, .landed) }", "land"),
    ("land: the draw restarts", "    func drawT(at t: Double) -> Double? { builtAt.map { t - $0 } }",
     "    func drawT(at t: Double) -> Double? { (phase == .landing ? landedAt : builtAt).map { t - $0 } }", "landing continuous"),
    ("land: the wire snaps drawn", "        return COSBuildUpLook(outline: progress(outlineStep(i), at: drawT),",
     "        return COSBuildUpLook(outline: landT == nil ? progress(outlineStep(i), at: drawT) : 1,", "landing continuous"),
    ("land: cut short", "(0..<max(1, min(count, staggered))).flatMap(landSteps).map(\\.end).max() ?? 0",
     "(0..<max(1, min(count, staggered))).flatMap(landSteps).map(\\.end).max().map { $0 - 0.1 } ?? 0", "land duration"),
    ("land: a step left out of the settle",
     "        [fillStep(i), solidStep(i), wireFadeStep(i), inkStep(i), outlineFadeStep(i), nodeFadeStep(i), tracesFadeStep]",
     "        [fillStep(i), solidStep(i), wireFadeStep(i), inkStep(i), nodeFadeStep(i), tracesFadeStep]", "land duration"),
    ("land: outline hands over slowly", "outlineFadeLead = 0.10, outlineFade = 0.20", "outlineFadeLead = 0.10, outlineFade = 0.40", "land duration"),
    ("land: never ends", "            if loading || t >= (landedAt ?? since) + COSBuildUpPlan.landDuration(count: count) { move(.settled, t) }",
     "            if loading { move(.settled, t) }", "landing continuous"),
    ("land: a new load mid-landing waits", "            if loading || t >= (landedAt ?? since) + COSBuildUpPlan.landDuration(count: count) { move(.settled, t) }",
     "            if t >= (landedAt ?? since) + COSBuildUpPlan.landDuration(count: count) { move(.settled, t) }", "mid landing"),
    ("land: wire text over the ink", "static func wireFadeStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(lane(i)) * landStagger, duration: wireFade) }",
     "static func wireFadeStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(lane(i)) * landStagger + ink, duration: wireFade) }", "ink order"),
    # The tint.
    ("tint: opaque", "static let curtainAlpha = 0.35", "static let curtainAlpha = 1.0", "curtain light"),
    ("tint: before the data", "    static func curtain(_ look: COSBuildUpLook, landing: Bool) -> Double { landing ? curtainAlpha * (1 - look.ink) : 0 }",
     "    static func curtain(_ look: COSBuildUpLook, landing: Bool) -> Double { curtainAlpha * (1 - look.ink) }", "curtain light"),
    ("tint: never wipes", "    static func curtain(_ look: COSBuildUpLook, landing: Bool) -> Double { landing ? curtainAlpha * (1 - look.ink) : 0 }",
     "    static func curtain(_ look: COSBuildUpLook, landing: Bool) -> Double { landing ? curtainAlpha : 0 }", "curtain light"),
    ("tint: wipes slowly", "landStagger = 0.015, fill = 0.15, solid = 0.05, wireFade = 0.10, ink = 0.18", "landStagger = 0.015, fill = 0.15, solid = 0.05, wireFade = 0.10, ink = 0.40", "ink soon"),
    # The hand-off and the timeout.
    ("handoff: hides the empty view", "        phase == .grace || (phase == .building && !wordsShown)", "        phase == .grace || phase == .handoff || (phase == .building && !wordsShown)",
     "timeout"),
    ("handoff: an error inks an empty layout", "} else { move(.handoff, t); finish(t, failed ? .failed : .empty) }",
     "} else { move(.landing, t); landedAt = t; finish(t, .empty) }", "error handoff"),
    ("handoff: slow fade", "static let handoffSeconds = 0.2", "static let handoffSeconds = 0.5", "timeout"),
    ("handoff: never shows today's view", "            if t >= since + COSBuildUpPlan.handoffSeconds { move(.settled, t) }", "            break", "deadline wakes"),
    ("timeout: a stuck wire", "            } else if t >= start + timeout {\n", "            } else if t >= start + timeout * 1_000 {\n", "deadline wakes"),
    ("timeout: no margin past the helper", "    static let defaultTimeout = 30 + helperMargin", "    static let defaultTimeout = 20.0", "timeout"),
    # Words and the pulse.
    ("words: never", "                if t >= start + COSBuildUpPlan.wordsSeconds { wordsShown = true }\n", "", "words"),
    ("words: at once", "static let wordsSeconds = 3.0", "static let wordsSeconds = 0.0", "words"),
    ("words: the wire text stays over them", "    var textShown: Double { wireText * (1 - wordsFade) * (1 - wireFade) }", "    var textShown: Double { wireText * (1 - wireFade) }", "words"),
    ("deadline: the words moment deleted", "            if !wordsShown { next.append(start + COSBuildUpPlan.wordsSeconds) }\n", "", "deadline wakes"),
    ("deadline: the pulse moment deleted", "            if !pulseDone { next.append(start + COSBuildUpPlan.pulseSeconds) }\n", "", "deadline wakes"),
    ("deadline: the words fade moment deleted", "            if !wordsFaded { next.append(start + COSBuildUpPlan.wordsFadeStep.end) }\n", "", "deadline wakes"),
    ("words: the fade stops in an inactive window", " || (wordsShown && !wordsFaded)", "", "words fade frames"),
    ("deadline: the draw moment deleted", "            if !drawDone { next.append(start + COSBuildUpPlan.drawDuration(count: count)) }\n", "", "deadline wakes"),
    ("pulse: never stops", "                if t >= start + COSBuildUpPlan.pulseSeconds { pulseDone = true }\n", "", "pulse cap"),
    ("pulse: an inactive window pulses", "phase == .building && windowActive && !pulseDone", "phase == .building && !pulseDone", "pulse window"),
    ("pulse: the flow loops forever", "        guard drawT >= flowStart, drawT < pulseSeconds else { return nil }", "        guard drawT >= flowStart else { return nil }",
     "pulse cap"),
    ("loop: frames while standing still", "        case .building: return !drawDone || pulses(windowActive: windowActive) || (wordsShown && !wordsFaded)",
     "        case .building: return true", "loop stops"),
    ("loop: settled keeps waking", "        case .settled: return nil", "        case .settled: return opened", "first open only"),
    # First open only, interruptions and the memory.
    ("first open: a refresh replays the build", "        case .settled:\n            break", "        case .settled:\n            if loading { move(.grace, t) }",
     "first open only"),
    ("first open: cached data builds", "        if landed || self.count == 0 || quiet { phase = .settled }", "        if self.count == 0 || quiet { phase = .settled }",
     "cached open"),
    ("first open: quiet ignored", "        if landed || self.count == 0 || quiet { phase = .settled }", "        if landed || self.count == 0 { phase = .settled }",
     "reopen"),
    ("interrupted: ignored", "        if interrupted, phase == .grace || phase == .building || phase == .landing {",
     "        if interrupted, phase == .landing {", "interrupted"),
    ("interrupted: a load that never started logs", "        if interrupted, phase == .fresh {\n            // The load never started: nothing to log.\n            move(.settled, t)",
     "        if interrupted, phase == .fresh {\n            settle(t, .interrupted)", "interrupted"),
    ("abandoned: never", "        guard phase == .grace || phase == .building else { return false }", "        return false", "abandoned"),
    ("memory: seen views build again", "    func builds(_ key: String) -> Bool { !seen.contains(key) && !empty.contains(key) }",
     "    func builds(_ key: String) -> Bool { !empty.contains(key) }", "memory"),
    ("memory: empty forgotten across launches", "    func builds(_ key: String) -> Bool { !seen.contains(key) && !empty.contains(key) }",
     "    func builds(_ key: String) -> Bool { !seen.contains(key) }", "memory"),
    ("memory: interrupted counts as seen", "        if outcome != .interrupted && outcome != .abandoned { seen.insert(key) }", "        seen.insert(key)", "memory"),
    ("memory: keyed views kept", "        guard persists else { return false }\n", "", "memory"),
    ("memory: unbounded", "            if empty.count > Self.emptyLimit { empty.removeFirst(empty.count - Self.emptyLimit) }\n", "", "memory"),
    ("first open: the fresh window never closes", "            else if t >= opened + COSBuildUpPlan.freshSeconds { move(.settled, t) }", "", "fresh expires"),
    ("first open: a load after open never builds", "            else if loading { move(.grace, t); loadStarted = t }", "", "fresh"),
    # The cap, the fit, the height and the layout.
    ("cap: more than 16", "static let maxItems = 16", "static let maxItems = 24", "cap"),
    ("cap: a limit ignored", "        let cap = min(maxItems, limit ?? maxItems)", "        let cap = maxItems", "cap"),
    ("cap: room ignored", "if layout.fills ? next - item.height >= room : next > room {", "if layout.fills ? next - item.height >= room + 1_000 : next > room + 1_000 {", "fits"),
    ("height: an inline view overflows", "                if fitted.isEmpty, room >= 6 { fitted.append(squeezed(item, to: room)) }",
     "                if fitted.isEmpty, room >= 6 { fitted.append(item) }", "no extra height"),
    ("height: a squeezed row keeps every line", "            if next > room - 2 * out.padV { break }\n", "", "no extra height"),
    ("site: memories at the default height", "    static let memories = COSBuildUpTune(top: 1, spacing: 7, rowHeight: 78)", "    static let memories = COSBuildUpTune(top: 1, spacing: 7)", "site geometry"),
    ("site: the tune ignored", "        if let row = tune.rowHeight { all = all.map { var item = $0; item.height = row; return item } }\n", "", "site geometry"),
    ("fit: ignored", "        count = max(1, min(n, COSBuildUpPlan.maxItems))\n", "", "fit"),
    ("fit: a landing refits", "        guard phase == .building || phase == .grace else { return }", "        guard phase != .settled else { return }", "fit"),
    ("answer: the reservation's lines drawn as one", "let lines = measured.map { max(1, min(widthsCount, Int(($0 / answerPitch).rounded()))) } ?? answerLines",
     "let lines = measured.map { max(1, min(widthsCount, Int(($0 / answerPitch).rounded()))) } ?? 1", "answer size"),
    ("answer: never re-fits", "let lines = measured.map { max(1, min(widthsCount, Int(($0 / answerPitch).rounded()))) } ?? answerLines", "let lines = answerLines", "answer refit"),
    # 0.5.353 The skeleton is the loaded view's geometry.
    ("fill: a pane draws only the rows it asked for", "func n(_ asked: Int) -> Int { max(0, min(filling ? cap : asked, cap)) }",
     "func n(_ asked: Int) -> Int { max(0, min(asked, cap)) }", "fill"),
    ("fill: the last row dropped", "if layout.fills ? next - item.height >= room : next > room {", "if next > room {", "fill"),
    ("fill: a meeting body asks for its turns only", "all = Array(([summaryCard] + (0..<max(0, filling ? cap : turns)).map(turn)).prefix(cap))",
     "all = Array(([summaryCard] + (0..<max(0, turns)).map(turn)).prefix(cap))", "fill"),
    ("column: ignored", "let column = layout.column?.span(in: width) ?? (x: 0, width: width)", "let column = (x: 0.0, width: width)", "column"),
    ("column: never centred", "return (inset + (centered ? (room - w) / 2 : 0), w)", "return (inset, w)", "column"),
    ("column: the gutters ignored", "let room = max(0, width - 2 * inset)", "let room = max(0, width)", "column"),
    ("column: the spine loses its gap", "        return rows(in: width, layout).x - gap\n", "        return layout.spineX\n", "column"),
    ("column: the tune's column dropped", "        base.column = tune.column\n", "", "column"),
    ("stagger: rows past 8 keep staggering", "static func lane(_ i: Int) -> Int { min(max(0, i), staggered - 1) }", "static func lane(_ i: Int) -> Int { max(0, i) }", "stagger cap"),
    ("stagger: 16 rows land later", "        (0..<max(1, min(count, staggered))).flatMap(landSteps).map(\\.end).max() ?? 0", "        (0..<max(1, min(count, maxItems))).flatMap(landSteps).map(\\.end).max() ?? 0", "stagger cap"),
    ("reserve: nothing reserved", "        guard !layout.fills else { return nil }\n        return height(items(shape, tune), layout: layout)", "        guard !layout.fills else { return nil }\n        return 0", "reserve"),
    ("reserve: a pane reserves", "        guard !layout.fills else { return nil }\n        return height(", "        return height(", "reserve"),
    ("reserve: one answer line", "static let answerLines = 4", "static let answerLines = 1", "reserve"),
    ("reserve: Reduce Motion reserves", "        !reduceMotion && (phase == .grace || phase == .building)\n", "        (phase == .grace || phase == .building)\n", "reduce motion size"),
    ("reserve: held after the build", "        !reduceMotion && (phase == .grace || phase == .building)\n", "        !reduceMotion && phase != .settled\n", "reserve"),
    ("site: review meetings at the shape's height", "static let reviewMeetings = COSBuildUpTune(top: 0, leading: 0, trailing: 0, spacing: 1, rowHeight: 76, column: .speakers)",
     "static let reviewMeetings = COSBuildUpTune(top: 0, leading: 0, trailing: 0, spacing: 1, column: .speakers)", "site geometry"),
    ("site: the first component's height ignored", "        if let first = tune.firstHeight, !all.isEmpty { all[0].height = first }\n", "", "site geometry"),
    ("site: Needs you reserves short rows", "static let needsYou = COSBuildUpTune(top: 0, spacing: 0, rowHeight: 150)", "static let needsYou = COSBuildUpTune(top: 0, spacing: 0, rowHeight: 46)", "reserve"),
    ("junction: the middle of a row", "top(index, in: items, layout: layout) + min(18, items[index].height / 2)",
     "top(index, in: items, layout: layout) + items[index].height / 2", "junction"),
    ("stagger: draw 40 ms", "static let drawStagger = 0.05, traceStagger = 0.045", "static let drawStagger = 0.04, traceStagger = 0.045", "stagger"),
    ("stagger: land 30 ms", "static let landStagger = 0.015,", "static let landStagger = 0.03,", "stagger"),
    ("progress: linear", "        return bezier(x, curve)\n", "        return x\n", "progress"),
    ("contrast: one wire everywhere", "        luminance < 0.18 ? (0.79, 0.66, 0.43, 0.72) : (137.0 / 255, 102.0 / 255, 45.0 / 255, 0.62)",
     "        (137.0 / 255, 102.0 / 255, 45.0 / 255, 0.62)", "wire contrast"),
    # What shows, and the breadcrumb.
    ("visibility: the grace flashes today's spinner", "        phase == .grace || (phase == .building && !wordsShown)", "        (phase == .building && !wordsShown)", "grace delay"),
    ("visibility: the landing has no wire", "var drawsWire: Bool { phase == .building || phase == .landing || phase == .handoff }",
     "var drawsWire: Bool { phase == .building || phase == .handoff }", "land"),
    ("breadcrumb: the label in the line", '"build-up \\(shape.kind) outcome=', '"build-up \\(shape) outcome=', "breadcrumb"),
]

CHECK_FAILURE = re.compile(r"BuildUpChecks\.swift:\d+: Fatal error: check failed \[([^\]]+)\]")


def failed_check(output: str) -> "str | None":
    found = CHECK_FAILURE.search(output)
    return found.group(1).strip() if found else None


def classifier_self_test() -> None:
    cases = [
        ("/w/Tests/BuildUpChecks.swift:14: Fatal error: check failed [grace delay] at line 45: x", "grace delay"),
        ("BuildUpChecks.swift:14: Fatal error: check failed [cap] at line 9: ", "cap"),
        ("Sources/BuildUp.swift:88: Fatal error: Index out of range", None),
    ]
    for text, want in cases:
        if failed_check(text) != want:
            sys.exit(f"classifier self-test failed: {text!r} read as {failed_check(text)!r}, expected {want!r}")
    print(f"classifier self-test: {len(cases)} cases")


def compile_once(work: pathlib.Path) -> tuple[bool, str, str]:
    out = work / "checks"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6",
                            "-strict-concurrency=complete", "-parse-as-library", str(work / "Sources/BuildUp.swift"), str(work / CHECKS), "-o", str(out)],
                           capture_output=True, text=True)
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
models = (root / MODELS).read_text()
if models.count(MARK) != 1:
    sys.exit(f"{MODELS} must hold the section mark exactly once")
section = "import Foundation\n\n" + models[models.index(MARK):]
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-build-up-mutants-", dir="/private/tmp"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CHECKS, work / CHECKS)
    for name, old, _, _ in MUTANTS:
        if section.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {section.count(old)} sites; it must land exactly once")
    (work / "Sources/BuildUp.swift").write_text(section)
    verdict, detail = classify(work, None)
    if verdict != "SURVIVED":
        sys.exit(f"baseline is not green ({verdict}: {detail}): fix the checks before reading any mutant")
    print("baseline green", flush=True)
    selected = [m for m in MUTANTS if any(m[0].startswith(prefix) for prefix in only.split("|"))]
    if not selected:
        sys.exit(f"no mutant name starts with {only!r}")
    results: dict[str, list[str]] = {"KILLED": [], "SURVIVED": [], "MISATTRIBUTED": [], "INVALID": [], "CRASHED": []}
    for name, old, new, expected in selected:
        (work / "Sources/BuildUp.swift").write_text(section.replace(old, new))
        verdict, detail = classify(work, expected)
        results[verdict].append(name)
        print(f"{verdict:13} {name}" + (f"  <- {detail}" if detail else ""), flush=True)
        (work / "Sources/BuildUp.swift").write_text(section)
    print(f"{len(results['KILLED'])} killed by their named check, {len(results['SURVIVED'])} survived, {len(results['MISATTRIBUTED'])} misattributed, "
          f"{len(results['INVALID'])} invalid, {len(results['CRASHED'])} crashed outside the checks")
    failing = {k: v for k, v in results.items() if k != "KILLED" and v}
    if failing:
        sys.exit("mutation gate FAILED: " + "; ".join(f"{k.lower()}: {v}" for k, v in failing.items()))
    print(f"PASS build up mutation gate: {len(selected)} mutants" + (f" (of {len(MUTANTS)}, named {only!r})" if only else "")
          + ", each killed by its named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
