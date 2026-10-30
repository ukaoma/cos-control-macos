#!/usr/bin/env python3
"""Usage slicing and Cursor feed mutation gate (SessionUsageCore, SessionUsageCollector, Tests/SessionUsageChecks.swift).

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
COLLECTOR = "HelperSources/SessionUsageCollector.swift"
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
    ("prior window judged by the earliest date of any tool",
     "allRows.filter { $0.provider == name }.map(\\.day).min()",
     "allRows.map(\\.day).min()",
     "old Cursor history cannot vouch for Claude Code's prior window"),
    ("90 days opens on Daily",
     'period == "Last 90 days" ? .weekly : .daily',
     ".daily",
     "each period opens on a readable scale"),
    ("New tokens sort counts cache reads",
     "a = Double(tokenCount(left.counts, excludingCacheReads: true))\n                b = Double(tokenCount(right.counts, excludingCacheReads: true))",
     "a = Double(tokenCount(left.counts, excludingCacheReads: false))\n                b = Double(tokenCount(right.counts, excludingCacheReads: false))",
     "New tokens sort ignores cache reads"),
    ("feed ignores its quiet interval",
     "guard force || clock >= state.nextAllowedAt else { return }",
     "guard force || clock >= 0 else { return }",
     "a failed sign-in read backs off until forced", COLLECTOR),
    ("all feed rows share one identity",
     'digest("cursor|" + identity)',
     'digest("cursor|")',
     "the event id is the identity", COLLECTOR),
    ("reported cost dropped",
     "let cost = event.reportedUSD ?? SessionUsagePricing.estimate(",
     "let cost = SessionUsagePricing.estimate(",
     "reported cost is stored as priced value", COLLECTOR),
    ("cents stored as dollars",
     "$0.isFinite && $0 >= 0 ? $0 / 100 : nil",
     "$0.isFinite && $0 >= 0 ? $0 : nil",
     "feed cost is its reported cents as dollars", COLLECTOR),
    ("every pass opens a new run",
     "if state.runEndMs == 0 {",
     "if state.runEndMs >= 0 {",
     "the backfill resumes at the next page", COLLECTOR),
    ("a run forgets its page",
     "state.nextPage += 1",
     "state.nextPage += 0",
     ("the backfill resumes at the next page", "pages until the reported total is read", "a short page does not end a run the total says is unfinished"), COLLECTOR),
    ("short page ends a run the total says is unfinished",
     "if state.runSeen >= state.runTotal { drained = true; break }",
     "if state.runSeen >= state.runTotal || rows.count < Self.cursorPageSize { drained = true; break }",
     "a short page does not end a run the total says is unfinished", COLLECTOR),
    ("total ignored",
     "if state.runSeen >= state.runTotal { drained = true; break }",
     "_ = state.runTotal",
     ("pages until the reported total is read", "the total ends a run even if pages repeat"), COLLECTOR),
    ("no page limit",
     "guard state.nextPage <= Self.cursorPageLimit else {",
     "guard state.nextPage > 0 else {",
     "a list that never ends stops at the page limit", COLLECTOR),
    ("empty answer treated as a changed feed",
     'drained = true; break\n            }\n            let events',
     'state.state = .changed; try saveCursorFeedState(state); return\n            }\n            let events',
     "an empty answer is a quiet window, not a changed feed", COLLECTOR),
    ("live sync without overlap",
     "state.watermarkMs - 2*86_400_000",
     "state.watermarkMs",
     "a live sync rereads two days past its watermark", COLLECTOR),
    ("unreadable rows treated as no usage",
     "if events.isEmpty {",
     "if events.isEmpty && rows.isEmpty {",
     "rows the feed can no longer read are reported, not treated as no usage", COLLECTOR),
    ("rejected sign-in treated as an outage",
     "if reply.status == 401 || reply.status == 403 {",
     "if reply.status == 999 {",
     "a rejected sign-in asks for a new one", COLLECTOR),
    ("failure retries every pass",
     "state.nextAllowedAt = clock + min(6*3600, 1800 * pow(2, Double(min(state.failures, 8) - 1)))",
     "state.nextAllowedAt = clock",
     "a failure backs off instead of retrying every pass", COLLECTOR),
    ("empty page before the total ends a run",
     "if state.runSeen < state.runTotal {",
     "if state.runSeen < 0 {",
     "an empty page before the total is reported, and the run stays open", COLLECTOR),
    ("a failing page holds its run forever",
     "if state.failures >= 4 { state.runEndMs = 0 }",
     "",
     "a page that keeps failing closes the run and starts again at the newest page", COLLECTOR),
    ("an open run stops waiting for Keychain",
     "switch readToken(force || state.runEndMs != 0) {",
     "switch readToken(force) {",
     "a run in progress and a manual Refresh wait patiently for Keychain", COLLECTOR),
    ("Keychain prompt repeats",
     "state.nextAllowedAt = clock + 30*86_400",
     "state.nextAllowedAt = clock + 3600",
     "an unanswered Keychain prompt is not repeated by automatic passes", COLLECTOR),
    ("a thrown sync reads as fine",
     "if syncFailed { state.state = .failed }",
     "",
     "a sync that threw is reported, so the loop stops hurrying", COLLECTOR),
    ("expired sign-in still sent",
     "return expiry <= now.timeIntervalSince1970",
     "return false",
     "an expired sign-in is not sent", COLLECTOR),
    ("feed reports on while turned off",
     "guard enabled else { return SessionUsageCursorFeedStatus(state: .off) }",
     "",
     "the feed is off until turned on", COLLECTOR),
]


def compile_and_run(work):
    """0 green, 1 checks failed (stderr returned), 2 did not compile."""
    out = work / "checks"
    for attempt in range(60):
        if out.exists(): out.unlink()
        build = subprocess.run(["/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
                                "-parse-as-library", str(work / CORE), str(work / COLLECTOR),
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
    (work / "HelperSources").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / COLLECTOR, work / COLLECTOR)
    originals = {CORE: (work / CORE).read_text(), COLLECTOR: (work / COLLECTOR).read_text()}
    code, output = compile_and_run(work)
    if code != 0: sys.exit("baseline is not green:\n" + output[-2000:])
    print("GREEN BASELINE: unmutated usage checks pass")
    survivors, misattributed = [], []
    for mutant in MUTANTS:
        name, old, new, label = mutant[:4]
        target = mutant[4] if len(mutant) > 4 else CORE
        original = originals[target]
        if original.count(old) != 1: sys.exit(f"mutant '{name}' targets {original.count(old)} sites")
        (work / target).write_text(original.replace(old, new))
        code, output = compile_and_run(work)
        if code == 2: verdict = "KILLED (did not compile)"
        elif code == 0: verdict = "SURVIVED"; survivors.append(name)
        elif any(f"Fatal error: {one}" in output for one in ((label,) if isinstance(label, str) else label)): verdict = "KILLED"
        else:
            verdict = "MISATTRIBUTED"; misattributed.append(name)
            failed = [line for line in output.splitlines() if "Fatal error:" in line]
            name += f" (failed: {failed[0].split('Fatal error:', 1)[1].strip() if failed else 'no check label'})"
        print(f"{verdict:24} {name}")
        (work / target).write_text(original)
    killed = len(MUTANTS) - len(survivors) - len(misattributed)
    print(f"SUMMARY: {killed} killed, {len(survivors)} survived, {len(misattributed)} misattributed of {len(MUTANTS)} mutants")
    if survivors or misattributed: sys.exit(f"survivors: {survivors}; misattributed: {misattributed}")
    print(f"PASS usage slicing mutation gate: {len(MUTANTS)} mutants, all killed by their named checks, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
