#!/usr/bin/env python3
"""Usage slicing mutation gate (Sources/SessionUsageCore.swift + Tests/SessionUsageChecks.swift).

SERIAL: one small three-file compile at a time through Tests/compile-guard.sh, on a scratch copy (the checkout is
never mutated). A green baseline is required first; each mutant must land exactly once, must make the checks FAIL,
and must fail on the check named for it. A failure on any other check is MISATTRIBUTED: the rule is not the thing
its own test pins. A busy shared compile lock (exit 70) or a memory headroom refusal (75) waits and retries; it is
never counted as a kill.
Usage: python3 Tests/mutate-session-usage.py <repo root>
"""
import pathlib, shutil, subprocess, sys, tempfile, time

sys.stdout.reconfigure(line_buffering=True)  # progress reaches a log file as each mutant finishes
root = pathlib.Path(sys.argv[1]).resolve()
CORE = "Sources/SessionUsageCore.swift"
# (name, old, new, the check label that must fail, or a tuple when one primitive feeds several checks)
MUTANTS = [
    ("inspection cleared on a scale change",
     "if inspection.scale == scale { return keys.contains(inspection.key) ? inspection : nil }",
     "if inspection.scale == scale { return nil }",
     "inspection set together with a switch to Daily survives the scale change"),
    ("inspected day not carried into its week",
     "return keys.contains(carried) ? SessionUsageInspection(key: carried, scale: scale) : nil",
     "return nil",
     "an inspected day carries into its week"),
    ("partially priced bucket split",
     "guard row.events > 0, row.pricedEvents == row.events, row.estimatedUSD > 0,",
     "guard row.events > 0, row.pricedEvents > 0, row.estimatedUSD > 0,",
     "partial and unpriced buckets are never split"),
    # Not a mutant: deleting the Haiku 5.5 exclusion is equivalent while the 1-hour cap holds. Its long-prompt tier
    # multiplies every rate by 5, so its remainder always lands above the cap and scales anyway (2026-10-28 run).
    ("1-hour premium uncapped",
     "if remainder >= write5USD * 0.999, remainder <= cap * 1.001 {",
     "if remainder >= write5USD * 0.999 {",
     "a remainder above the 1-hour cap scales instead of loading cache write"),
    ("unpriced models not last",
     "            if sort == .cost, (left.pricedEvents > 0) != (right.pricedEvents > 0) { return left.pricedEvents > 0 }\n            if sort == .model {",
     "            if sort == .model {",
     "API value ascending, unpriced still last"),
    ("unpriced days not last",
     "            if sort == .cost, (left.pricedEvents > 0) != (right.pricedEvents > 0) { return left.pricedEvents > 0 }\n            let a: Double, b: Double\n            switch sort {\n            case .tokens:\n                a = Double(tokenCount(left.counts, excludingCacheReads: excludingCacheReads))\n                b = Double(tokenCount(right.counts, excludingCacheReads: excludingCacheReads))\n            case .cost: a = left.estimatedUSD; b = right.estimatedUSD\n            case .records: a = Double(left.events); b = Double(right.events)\n            case .date:",
     "            let a: Double, b: Double\n            switch sort {\n            case .tokens:\n                a = Double(tokenCount(left.counts, excludingCacheReads: excludingCacheReads))\n                b = Double(tokenCount(right.counts, excludingCacheReads: excludingCacheReads))\n            case .cost: a = left.estimatedUSD; b = right.estimatedUSD\n            case .records: a = Double(left.events); b = Double(right.events)\n            case .date:",
     "unpriced days sort last on API value both ways"),
    ("model ties flip with direction",
     "if a == b { return name(left) < name(right) }",
     "if a == b { return ascending ? name(left) > name(right) : name(left) < name(right) }",
     "ties break on provider|model in both directions"),
    ("aggregate keeps an arbitrary day",
     'return SessionUsageBucket(day: "", provider: first.provider',
     "return SessionUsageBucket(day: first.day, provider: first.provider",
     "aggregate spans days without an arbitrary day id"),
    ("month in progress vs whole previous month",
     "return (first.key...today.key, previous.key...min(previous.adding(elapsed), previous.monthEnd).key)",
     "return (first.key...today.key, previous.key...previous.monthEnd.key)",
     "month in progress is not compared with a whole month"),
    ("month-to-date not clamped to a shorter month",
     "previous.key...min(previous.adding(elapsed), previous.monthEnd).key)",
     "previous.key...previous.adding(elapsed).key)",
     "month to date compares the same elapsed dates, clamped to a shorter month"),
    ("today not flagged",
     "includesToday: windows.current.contains(today),",
     "includesToday: false,",
     "prior 7-day window aligned; current window flags today"),
    ("API value delta never partial",
     "costDeltaPartial: curPriced < curEvents || pPriced < pEvents,",
     "costDeltaPartial: false,",
     "API value delta marked partial when a window has unpriced records; prior dollars kept"),
    ("peak by API value ranks tokens",
     "            case .cost: return s.estimatedUSD\n",
     "            case .cost: return Double(tokenCount(s.counts, excludingCacheReads: excludingCacheReads))\n",
     "peak day ranks by tokens, API value or records"),
    ("peak by records ranks tokens",
     "            case .records: return Double(s.events)\n",
     "            case .records: return Double(tokenCount(s.counts, excludingCacheReads: excludingCacheReads))\n",
     "peak day ranks by tokens, API value or records"),
    ("CSV formula not neutralized",
     '        if let c = s.first, "=+-@\\t\\r".contains(c) { s = "\'" + s }\n',
     "",
     "CSV neutralizes formula-leading characters only"),
    ("CSV carriage return not quoted",
     '$0 == "\\n" || $0 == "\\r" })',
     '$0 == "\\n" })',
     "CSV quotes commas, quotes, newlines and carriage returns"),
    ("model clear strands the provider",
     "            provider = providerBeforeModel ?? provider\n",
     "",
     "second model click restores All providers"),
    ("model switch forgets the original provider",
     "if providerBeforeModel == nil { providerBeforeModel = provider }",
     "providerBeforeModel = provider",
     "switching models keeps the original provider to restore"),
    ("export ignores the inspected period",
     "return selected.filter { periodKey(for: $0.day, scale: inspection.scale) == inspection.key }",
     "return selected",
     "export narrows to the inspected day"),
    ("JSON drops the inspected period",
     '"inspectedPeriod": context.inspection?.key ?? NSNull(),',
     '"inspectedPeriod": NSNull(),',
     "JSON names the period, dates, scale, inspection and filters"),
    ("JSON drops bucket pricing status",
     '                    "pricingStatus": pricingStatus(r),\n',
     "",
     "JSON buckets carry pricing status and null unknown cost"),
    ("leaving All history keeps Monthly",
     "return (remembered ?? current, nil)",
     "return (current, nil)",
     "leaving All history restores the remembered scale"),
    ("Records offers Categories",
     "measure == .records ? SessionUsageSeries.allCases.filter { $0 != .categories } : SessionUsageSeries.allCases",
     "SessionUsageSeries.allCases",
     "Records hides Categories"),
    ("mix bar overflows",
     "let remaining = available - floor * Double(small.count)",
     "let remaining = available",
     "slivers get the minimum and the bar never overflows"),
    ("hover card width ignores its padding",
     "let rightFits = right + cardWidth <= containerWidth - margin",
     "let rightFits = right <= containerWidth - margin",
     "card never runs past the right edge"),
    ("week starts on Sunday",
     "var weekdayFromMonday: Int { ((serial + 3) % 7 + 7) % 7 }",
     "var weekdayFromMonday: Int { ((serial + 4) % 7 + 7) % 7 }",
     # The weekday primitive also sets Last weekend, which is checked earlier: either check pins it.
     ("Saturday maps to Monday of its week", "last completed weekend boundaries")),
    ("boundary week title not clamped",
     "let (start, end) = clamp(first, sunday)",
     "let (start, end) = (first, sunday)",
     "boundary week title clamps to the selection"),
]


def compile_and_run(work):
    """0 green, 1 checks failed (stderr returned), 2 did not compile."""
    out = work / "checks"
    for attempt in range(60):
        if out.exists(): out.unlink()
        build = subprocess.run(["/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
                                "-parse-as-library", str(work / CORE), str(root / "HelperSources/SessionUsageCollector.swift"),
                                str(root / "Tests/SessionUsageChecks.swift"), "-o", str(out)], capture_output=True, text=True)
        if build.returncode in (70, 75):
            time.sleep(30)
            continue
        if build.returncode != 0: return 2, build.stdout + build.stderr
        run = subprocess.run([str(out)], capture_output=True, text=True)
        return (0 if run.returncode == 0 else 1), run.stdout + run.stderr
    sys.exit("shared compile lock stayed busy for 30 minutes")


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-usage-mutants-", dir="/private/tmp"))
try:
    (work / "Sources").mkdir()
    shutil.copy(root / CORE, work / CORE)
    original = (work / CORE).read_text()
    code, output = compile_and_run(work)
    if code != 0: sys.exit("baseline is not green:\n" + output[-2000:])
    print("GREEN BASELINE: unmutated usage checks pass")
    survivors, misattributed = [], []
    for name, old, new, label in MUTANTS:
        if original.count(old) != 1: sys.exit(f"mutant '{name}' targets {original.count(old)} sites")
        (work / CORE).write_text(original.replace(old, new))
        code, output = compile_and_run(work)
        if code == 2: verdict = "KILLED (did not compile)"
        elif code == 0: verdict = "SURVIVED"; survivors.append(name)
        elif any(f"Fatal error: {one}" in output for one in ((label,) if isinstance(label, str) else label)): verdict = "KILLED"
        else:
            verdict = "MISATTRIBUTED"; misattributed.append(name)
            failed = [line for line in output.splitlines() if "Fatal error:" in line]
            name += f" (failed: {failed[0].split('Fatal error:', 1)[1].strip() if failed else 'no check label'})"
        print(f"{verdict:24} {name}")
        (work / CORE).write_text(original)
    killed = len(MUTANTS) - len(survivors) - len(misattributed)
    print(f"SUMMARY: {killed} killed, {len(survivors)} survived, {len(misattributed)} misattributed of {len(MUTANTS)} mutants")
    if survivors or misattributed: sys.exit(f"survivors: {survivors}; misattributed: {misattributed}")
    print(f"PASS usage slicing mutation gate: {len(MUTANTS)} mutants, all killed by their named checks, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
