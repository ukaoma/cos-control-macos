#!/usr/bin/env python3
"""0.5.331 paste first, polish in place: where the pure rules (DictationPolishSwap, in MacDictationChecks) are wired.
Each failure names its behaviour as "pin failed [<behaviour>]". Code only: comments never satisfy a pin. Call sites
are pinned, not definitions.

Then a self-test: each in-memory mutant below must land exactly once in the source and must make a named pin fail,
so no pin here is decoration.

    python3 Tests/dictation-swap-pins.py <root>
"""
import pathlib, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")


class PinFailed(Exception):
    pass


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        raise PinFailed(f"pin failed [{behaviour}]: {why}")


def body(src, opener):
    pin(src.count(opener) == 1, "source shape", f"{opener!r} must appear exactly once")
    start = src.index(opener)
    depth, i, seen = 0, start, False
    while i < len(src):
        if src[i] == "{":
            depth += 1; seen = True
        elif src[i] == "}":
            depth -= 1
            if seen and depth == 0:
                return src[start:i + 1]
        i += 1
    return src[start:]


def check(d, core):
    d = code(d); core = code(core)
    transcribe = body(d, "    private func transcribe(_ wav: Data, attempt: UUID) {")
    first = body(d, "    private func deliverThenPolish(_ heard: String, attempt: UUID) async {")
    swap = body(d, "    private func swapPolished(id: UUID, target: DictationInsertTarget?, inserted: Bool, polished: String, budgetMs: Int,")
    replace = body(d, "    static func replace(_ target: DictationInsertTarget, corrected: String, restoreClipboard: Bool, automatic: Bool = false) async -> Replaced {")
    apply = body(d, "    func applyPolished(_ id: UUID) {")
    finish = body(d, "    private func finish(")

    # 1. The toggle decides the order at the one call site; off is today's order, untouched below the branch.
    branch = "if sequence == .deliverThenPolish { await deliverThenPolish(heard, attempt: attempt); return }"
    pin(transcribe.count("DictationPolishSwap.sequence(pasteFirst: pasteThenPolish, polishes: polishBridge != nil && DictationPolish.shouldPolish(text: heard, model: polishModel),") == 1
        and "copyOnly: pendingInterrupted)" in transcribe and transcribe.count(branch) == 1, "toggle",
        "transcribe asks DictationPolishSwap.sequence with the setting, the polish rule and copy-only, and branches once")
    order = [transcribe.find(s) for s in ["DictationProof.record(engine:", branch, "let polished = await polish(heard, attempt: attempt)",
                                          "let text = formatLists ? DictationListFormat.format(said) : said", "await DictationInsertion.deliver(text,"]]
    pin(-1 not in order and order == sorted(order) and transcribe.count("DictationInsertion.deliver(") == 1, "toggle off is today",
        "after the branch: polish, lists, then exactly one delivery, as before 0.5.331")
    pin(d.count('Toggle("Paste right away, then polish in place", isOn: $store.pasteThenPolish)') == 1
        and "DictationPolishSwap.stored(UserDefaults.standard.object(forKey: DictationPolishSwap.defaultsKey))" in d
        and "UserDefaults.standard.set(pasteThenPolish, forKey: DictationPolishSwap.defaultsKey)" in d
        and d.count("pasteThenPolish") == 5, "toggle", "the setting is shown, read with its tested default, stored, and read only at the two call sites")

    # 2. Paste first: the polish starts before the delivery, without its pill, and the delivery is the heard text.
    pin(first.index("let polishing = Task { await self.polish(heard, attempt: attempt, showPill: false) }")
        < first.index("await DictationInsertion.deliver(text, restoreClipboard: restoreClipboard, fieldContext: useFieldContext)")
        < first.index("let run = await polishing.value"), "parallel", "polish runs while what was heard is typed")
    pin("let text = lists ? DictationListFormat.format(heard) : heard" in first and first.count("DictationInsertion.deliver(") == 1, "heard first",
        "the heard text is formatted and delivered once")
    pin("final = DictationInsertion.polishedFinal(polished, formatLists: lists, context: delivered.context)" in first
        and "DictationPolishSwap.want(outcome: run?.outcome, typed: typed, final: final?.text)" in first, "final text",
        "Claude's version gets the same lists and field spellings, and swaps only when it differs (want)")

    # 3. Never activate, never move a window: only Fix a word and Apply polished may.
    gate = "if DictationPolishSwap.mayActivate(automatic: automatic) {"
    pin(replace.count(gate) == 1, "never activate", "replace asks mayActivate with its own automatic flag before any activation")
    guarded = body(replace, gate)
    pin(replace.count("app.activate()") == 1 and "app.activate()" in guarded and "key.orderOut(nil); key.orderFrontRegardless()" in guarded
        and replace.count("orderOut(") == 1, "never activate", "replace activates and reorders only inside the mayActivate guard")
    pin(d.count(".activate(") == 1, "never activate", "the only activate() in dictation is Fix a word's, inside the guard")
    for name, src in (("deliverThenPolish", first), ("swapPolished", swap)):
        pin(not any(bad in src for bad in (".activate(", "orderOut(", "orderFront", "makeKey", "NSApp.activate")), "never activate",
            f"{name} never activates an app or moves a window")
    pin(swap.count("DictationInsertion.replace(target, corrected: polished, restoreClipboard: restoreClipboard, automatic: true)") == 1
        and d.count("automatic: true") == 1, "never activate", "the automatic swap is the one replace called with automatic: true")
    pin("automatic" not in apply and "DictationInsertion.replace(target, corrected: pending.text, restoreClipboard: restoreClipboard)" in apply,
        "apply polished", "Apply polished is the person's own action: Fix a word's full path")

    # 4. The focus rules and the proof, inside replace, before anything is selected or pasted.
    g = "if automatic, let skip = DictationPolishSwap.gate(route: route, frontmost: frontmost, focusedIsTarget: focusedIsTarget, ownWindowKey: NSApp.keyWindow != nil) {"
    pin(replace.count(g) == 1 and replace.index(g) < replace.index("if frontmost, focusedIsTarget, select(element, location: edit.location")
        < replace.index("DictationReplace.pasteProof(") < replace.index("await paste(changeCount: changeCount)"), "paste route focus",
        "the paste route's frontmost, focus and own-window rule runs before the selection, the proof and the paste")
    p = "if automatic, let skip = DictationPolishSwap.placed(plan) {"
    pin(replace.count(p) == 1 and replace.index(p) < replace.index("guard case .edit(let edit, let dictationAt) = plan else {"), "proof",
        "an automatic swap edits only the whole dictation where COS typed it, or found moved within the window")
    pin(replace.count("restoreCaret()") == 3 and "DictationPolishSwap.shifted(location: l, length: len, edit: edit)" in replace
        and "guard automatic," in body(replace, "        func restoreCaret() {"), "caret", "both routes put the person's caret back after an automatic swap, shifted")
    pin("if landed || automatic {" in replace, "clipboard", "an automatic swap puts the person's clipboard back whether or not it read back")

    # 5. Before the swap: the quiet moment, bounded; a delivery and a swap never overlap.
    pin("DictationPolishSwap.ready(inserted: inserted, measured: target != nil, enabled: enabled && !Task.isCancelled," in swap
        and "sinceFieldChangeMs: quiet?.sinceChangeMs," in swap and "budgetMs: budgetMs)" in swap
        and "try? await Task.sleep(for: .milliseconds(DictationPolishSwap.quietPollMilliseconds))" in swap, "typing quiet",
        "the swap waits for a quiet field through the tested rule, bounded by the polish budget")
    pin("DictationInsertion.holdsFocus($0.element, pid: $0.span.pid) } == true\n                ? Int((CGEventSource.secondsSinceLastEventType(" in swap,
        "typing quiet", "a key counts as typing in that field only while the field has the keyboard")
    pin("let quiet = delivered.target.map { DictationFieldQuiet($0) }" in first and "quiet?.stop()" in first, "typing quiet",
        "the field is watched for changes while polish works, then the watch stops")
    pin(d.count("await waitForSwapEdit()") == 2 and "swapEditing = true\n        defer { swapEditing = false }" in swap
        and d.count("deliveryInFlight = true") == 2 and "busy: deliveryInFlight || listRoute == .fix(id)" in swap, "one edit at a time",
        "both deliveries wait for a swap that is editing; a swap waits for a delivery or Fix a word on this dictation")

    # 6. Learn from my edits never sees COS's swap: the watch waits, then starts from what the field now holds.
    pin("if swapPending {\n            editWatcher.stop(\"polish pending\")" in finish and "if !swapPending { if case .refused = outcome" in finish, "learner",
        "a paste-first finish starts no watch and writes no line")
    pin("swapPending: true)" in first and "DictationPolishSwap.watch(span: target.span, typed: typed, polished: polished, result: result, swappedAt: swapped.target?.span.location)" in first
        and first.index("DictationPolishSwap.watch(") < first.index("editWatcher.start(watchTarget, mode: learnMode, context: watchContext)"), "learner",
        "the watch starts after the swap settles, from DictationPolishSwap.watch")
    pin('editWatcher.stop("apply polished")' in apply and apply.index('editWatcher.stop("apply polished")') < apply.index("DictationInsertion.replace("),
        "learner", "Apply polished ends the watch before COS edits the field")

    # 7. Skips keep Claude's version for Apply polished, and say one line; a swap updates the record.
    pin("DictationPolishSwap.keepsPolished(result)" in first and "pendingPolish[id] = DictationPendingPolish(" in first
        and "DictationPolishSwap.notice(result)" in first, "skip", "a skip keeps the polished version and the pill says so")
    pin("recent = DictationHistory.polishing(id, to: polished, heard: heard, model: model.rawValue, in: recent); saveRecent()" in first
        and "if result == .swapped, let model = run?.model {" in first, "record", "a swap makes the dictation read the polished text")
    pin(d.count('Button("Apply polished") { store.applyPolished(record.id) }') == 1 and "if store.pendingPolish[record.id] != nil {" in d,
        "apply polished", "the row in Activity, Dictation offers Apply polished for that dictation")
    pin("pendingPolish[recordID] = nil" in body(d, "    func saveFix(to dictionary: TranscriptionDictionaryStore) {"), "apply polished",
        "Fix a word's save drops a polished version that predates it")

    # 8. The timing line: first text, the swap's outcome, time and route; numbers and codes only.
    pin(all(f"var {f}" in core for f in ("releaseToFirstTextMs: Int?", "swapOutcome: String?", "swapMs: Int?", "swapRoute: String?")), "timing", "the four fields")
    pin("swapOutcome = result.logName; swapMs = ms; swapRoute = route.map(DictationPolishSwap.routeName)" in core, "timing", "settle writes codes only")
    pin(transcribe.count("timing?.releaseToFirstTextMs = firstTextMs()") == 1
        and "timing?.settle(DictationPolishSwap.unswapped(pasteFirst: pasteThenPolish, polished: polished != nil, copyOnly: copyOnly), ms: nil, route: nil)" in transcribe,
        "timing", "the one-delivery path writes first text and off, notPolished or skipped:copyOnly")
    pin(first.count("timing?.releaseToFirstTextMs = firstTextMs()") == 1 and "var line = timing; timing = nil" in first
        and "line?.settle(result, ms: swapMs, route: route)" in first and 'recordTiming("typed", line: line)' in first
        and first.index("line?.settle(") < first.index('recordTiming("typed", line: line)'), "timing",
        "the paste-first line is this dictation's own, settled, then written once")
    pin("releasedAt = mark.uptime" in body(d, "    private func closeMicrophone() {"), "timing", "the release time is the person's stop")
    rec = body(d, "    private func recordTiming(_ outcome: String, line: DictationTiming? = nil) {")
    log = [l for l in rec.split("\n") if "dictationLog" in l]
    pin(len(log) == 1 and all(k in log[0] for k in ("first_text_ms=", "swap=", "swap_ms=", "swap_route=")), "timing", "the log line carries them too")
    swaplog = [l for l in first.split("\n") if "dictationLog" in l]
    pin(len(swaplog) == 1 and "result.logName" in swaplog[0] and not any(w in swaplog[0] for w in ("heard", "polished)", "typed", "text")), "no text logged",
        "one swap log line: outcome, route and time, never words")

    # 9. Prewarm: only this press's token (a paste-first polish runs after the next press may have its own).
    pin("guard let held = prewarm, held.attempt == attempt else { return (nil, nil) }" in body(d, "    private func takePrewarm(_ model: DictationPolishModel, attempt: UUID) async -> (token: String?, ms: Int?) {"),
        "prewarm", "the polish takes only its own press's early process")


MUTANTS = [
    ("toggle ignored", "DictationPolishSwap.sequence(pasteFirst: pasteThenPolish,", "DictationPolishSwap.sequence(pasteFirst: true,"),
    ("activation guard ignores automatic", "if DictationPolishSwap.mayActivate(automatic: automatic) {", "if DictationPolishSwap.mayActivate(automatic: false) {"),
    ("an activation outside the guard", "        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.span.pid\n",
     "        NSRunningApplication(processIdentifier: target.span.pid)?.activate()\n        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.span.pid\n"),
    ("automatic swap runs as Fix a word", "restoreClipboard: restoreClipboard, automatic: true)", "restoreClipboard: restoreClipboard, automatic: false)"),
    ("paste-route focus gate disabled", "if automatic, let skip = DictationPolishSwap.gate(route: route,", "if false, let skip = DictationPolishSwap.gate(route: route,"),
    ("partial plan accepted", "if automatic, let skip = DictationPolishSwap.placed(plan) {", "if false, let skip = DictationPolishSwap.placed(plan) {"),
    ("clipboard kept on an unconfirmed swap", "if landed || automatic {", "if landed {"),
    ("watch starts before the swap", "context: delivered.context, swapPending: true)", "context: delivered.context, swapPending: false)"),
    ("swap outcome never written", "        line?.settle(result, ms: swapMs, route: route)\n", ""),
    ("first text not measured on paste first", "        timing?.releaseToFirstTextMs = firstTextMs()\n        // This dictation's own line", "        // This dictation's own line"),
    ("delivery does not wait for a swap edit", "        await waitForSwapEdit()\n        let delivering", "        let delivering"),
    ("typing ignored", "sinceFieldChangeMs: quiet?.sinceChangeMs,", "sinceFieldChangeMs: nil,"),
    ("Apply polished leaves the watch on", '        editWatcher.stop("apply polished")\n', ""),
    ("another press's token taken", "guard let held = prewarm, held.attempt == attempt else { return (nil, nil) }", "guard let held = prewarm else { return (nil, nil) }"),
]

source = read("Sources/MacDictation.swift"); core_src = read("Sources/MacDictationCore.swift")
try:
    check(source, core_src)
except PinFailed as e:
    sys.exit(str(e))
caught = 0
for name, old, new in MUTANTS:
    if source.count(old) != 1:
        sys.exit(f"pin self-test: mutant '{name}' lands {source.count(old)} times; it must land exactly once")
    try:
        check(source.replace(old, new), core_src)
    except PinFailed as e:
        caught += 1
        print(f"KILLED  {name}  <- {e}")
        continue
    sys.exit(f"pin self-test: mutant '{name}' landed and every pin still passed")
print(f"PASS dictation swap pins: toggle, today's order when off, parallel polish, never activate, paste-route focus, proof, caret, clipboard, "
      f"typing quiet, one edit at a time, learner, skip and apply polished, timing; {caught} of {len(MUTANTS)} in-memory mutants caught")
