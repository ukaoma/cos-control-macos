#!/usr/bin/env python3
"""0.5.344 Capture every correction (plan r2): where the pure rules and the watch loop (DictationEditWatch, executed by
Tests/EditCaptureChecks.swift) are wired into the app and the helper. Each failure names its behaviour as
"pin failed [<behaviour>]". Code only: comments never satisfy a pin. Call sites are pinned, not definitions.

Then a self-test: each in-memory mutant below must land exactly once in its file and must make a named pin fail, so no
pin here is decoration. Text only (no compile).

    python3 Tests/edit-capture-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")
FILES = {"d": "Sources/MacDictation.swift", "core": "Sources/MacDictationCore.swift", "helper": "HelperSources/main.swift",
         "hcore": "HelperSources/ProviderStatusCore.swift"}


class PinFailed(Exception):
    pass


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//") and not l.strip().startswith("///"))


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


def check(src):
    d, core, helper, hcore = (code(src[k]) for k in ("d", "core", "helper", "hcore"))
    hot = body(d, "    func registerHotKeys() {")
    handle = body(hot, "            let handle: (NSEvent) -> Void = { [weak self] event in")
    trigger = body(d, "    private func editTrigger(keyDown: Bool, keyCode: UInt16, isRepeat: Bool, pointer: Bool) {")
    watcher = body(d, "@MainActor final class DictationEditWatcher {")
    run = body(watcher, "    private func run(_ field: DictationEditWatch.Field,")
    stop = body(watcher, "    func stop(_ why: String) {")
    skipped = body(watcher, "    nonisolated static func skipped(_ reason: String, bundle: String?) {")
    finish = body(d, "    private func finish(_ text: String, outcome: DictationDeliveryOutcome")
    deliver = body(d, "    private func deliverThenPolish(_ heard: String, attempt: UUID) async {")
    polish = body(d, "    private func polish(_ heard: String, attempt: UUID, showPill: Bool = true) async -> DictationPolishRun? {")
    loop = body(core, "enum DictationEditWatch {")
    watch = body(loop, "    static func watch(")

    # 1. The trigger: the existing listen-only monitor, observed only, before the shortcut trackers see the event.
    pin("let down = event.type == .keyDown, again = down && event.isARepeat" in handle
        and "self?.editTrigger(keyDown: down, keyCode: key, isRepeat: again, pointer: !isKey)" in handle
        and handle.index("self?.editTrigger(") < handle.index("self?.keyEvent("), "trigger wired",
        "the shortcut monitor hands Return, Enter and clicks to the watch first, isARepeat read from key-downs only")
    pin("handler: { handle($0); return $0 })" in hot and d.count("addGlobalMonitorForEvents") == 1, "observe only",
        "the local monitor returns every event unchanged, and no new global monitor exists")
    pin("editWatcher.monitor = false" in hot and "editWatcher.monitor = !keyMonitors.isEmpty" in hot
        and hot.index("editWatcher.monitor = false") < hot.index("editWatcher.monitor = !keyMonitors.isEmpty"), "monitor named",
        "the canary says present only while the monitors are installed")
    pin("guard editWatcher.isWatching, learnMode != .off else { return }" in trigger and "watching: true, learning: true, inApp: inApp) else { return }" in trigger
        and "editWatcher.trigger(trigger)" in trigger
        and "DictationInsertion." not in trigger and "Task" not in trigger, "trigger on main is a signal only",
        "the tested rule decides; the main thread only fires the signal, never reads the field")
    pin("func trigger(_ trigger: DictationEditLearning.Trigger) { signal?.fire(trigger) }" in watcher
        and "signal?.close(); signal = nil" in stop, "signal", "a trigger reaches only the running watch, and a stopped watch hears nothing")

    # 2. The watch: the core loop, off the main thread, with its own signal, sink and the tracker's capture.
    pin("let signal = DictationWatchSignal()" in run and "pause: { await signal.pause($0) }" in run and "task = Task.detached(priority: .utility)" in run,
        "watch off main", "each watch races its own trigger stream against its poll, inside a detached task")
    pin("await DictationEditWatch.run(field, span: span, typed: typed, facts: facts, bundle: bundle, learning: learning, monitor: monitor," in run
        and "sink: { Self.record($0) })" in run, "watch is the core loop", "the app keeps only the field closures; the loop and the canary are the tested ones")
    pin("finalText: ending.final" in run and "inside: ending.tail.sawInside" in run, "ending from the tracker",
        "the store gets what the capture tracker kept")
    # 0.5.344 QA (QA4 N13): all five field closures, not two.
    pin("let measure: @Sendable () async -> DictationFieldSnapshot" in loop and "let text: @Sendable (Int, Int) async -> String?" in loop
        and "let secure: @Sendable () async -> Bool" in loop and "let focus: @Sendable (Int) async -> (verdict: DictationEditLearning.Focus, characters: Int?)" in loop
        and "let running: @Sendable () async -> Bool" in loop, "field closures sendable", "no field closure inherits the main actor from the method that built it")
    pin("Task.sleep" not in loop and watch.count("await clock.pause(") == 1, "injected sleep", "the loop sleeps only through the injected clock")
    pin(watch.count("baseline = current; baseCount = n") == 1 and len(re.findall(r"(?<!var )\bbaseline = ", watch)) == 1, "two states",
        "the learning baseline moves only on the learning read")
    pin("let after = await field.measure()" in body(loop, "    static func trackerRead(") and "guard after.characters == n else { return (nil, .inconsistent, after) }" in loop,
        "consistent read", "measure, text, measure; a read whose counts disagree is discarded")
    pin("unread: canary.unreadChanges ?? 0)" in body(loop, "    static func run(") and "inside: tail.sawInside" in body(loop, "    static func run("),
        "staleness wired", "the capture rule hears the unread changes and reads the tracker")
    for line in re.findall(r'log\("((?:[^"\\]|\\.)*)"\)', watch):
        for word in (r"\(typed", r"\(baseline", r"\(current", r"\(window", r"\(edit.original)", r"\(edit.replacement)", r"\(tracker.window"):
            pin(word not in line, "privacy", f"no words in the watch's log: {line[:80]!r}")

    # 3. Every typed dictation that got no watch writes its line (QA W3).
    pin(watcher.count("Self.skipped(reason, bundle: target.bundle)") == 1 and watcher.count('Self.skipped(reason, bundle: "com.gotcos.control")') == 1,
        "skip rows", "an eligibility skip writes its line, COS's own views too")
    pin("DictationEditLearning.unwatched(learnOff: learnMode == .off, outcome: outcome, hasTarget: false)" in finish
        and "DictationEditWatcher.skipped(reason, bundle: target?.bundle)" in finish, "skip rows", "a typed dictation finish could not watch")
    pin("} else if let reason = DictationEditLearning.unwatched(learnOff: learnMode == .off, outcome: delivered.outcome, hasTarget: watchTarget != nil," in deliver
        and "newer: generation != attempt, swapWatches: DictationPolishSwap.watches(result)) {" in deliver
        and "DictationEditWatcher.skipped(reason, bundle: delivered.target?.bundle)" in deliver, "skip rows", "the swap's mismatch, a newer dictation, no target")
    pin("guard DictationLearnCanary.recordsSkip(reason) else { return }" in skipped and "Task.detached(priority: .utility) { Self.record(row) }" in skipped,
        "skip rows off main", "learning off writes nothing; the line is written off the main thread")

    # 4. Polish: the server's polishOutcome reaches the tested mapping.
    pin('polishOutcome: response.details["polishOutcome"]?.string)' in polish, "polish outcome", "the tested choose hears polishOutcome")
    # 4b. Contract addition: polishPrompt (v3 or v4) on the timing line and the record, labelled on the card only for v4.
    pin('prompt = DictationPolish.promptVersion(response.details["polishPrompt"]?.string)' in polish and "instructionsHash: instructions.hash).with(prompt: prompt)" in polish,
        "polish prompt", "the polish run carries the tested prompt version")
    pin('polish_prompt=\\(finished.polishPrompt ?? "-", privacy: .public)' in d, "polish prompt timing", "the log's timing line names the prompt")
    pin("heard: lastPolish?.heard, polishModel: lastPolish?.model.rawValue, polishPrompt: lastPolishPrompt," in finish
        and "lastPolishPrompt = lastPolish == nil || lastPolishCleaned != nil ? nil : polished?.prompt" in d, "polish prompt record",
        "a polished-first dictation keeps its prompt (never for cleaned text)")
    pin("model: model.rawValue, prompt: run?.prompt, styleHash: run?.learnedStyleHash,\n                                                    cleaned: cleaned, in: recent); saveRecent()" in deliver
        and "applies: DictationPolishSwap.offersApply(result), prompt: run?.prompt," in deliver
        and "model: pending.model.rawValue, prompt: pending.prompt, styleHash: pending.styleHash,\n                                                    cleaned: pending.cleaned, in: recent); saveRecent()" in d,
        "polish prompt record",
        "the swap and Apply polished keep the prompt")

    # 5. The dictionary source stays "dictation" on the wire (plan r2 cut the split: 6.90.0 answers 400 to anything else).
    pin(d.count('source: "dictation")') == 3 and '"fix-a-word"' not in d + core + helper + hcore, "source unchanged",
        "Fix a word, learning and Add keep the dictation source")
    pin('if let source = fields["source"], !["dictation", "meeting", "g2", "manual"].contains(source) {' in helper
        and '"learn": ["heard", "written", "source"]' in helper, "source unchanged", "the helper's learn keys and sources are as before")

    # 6. The helper passes the new finalize fields on only from closed sets, and the stdin allowlist is unchanged.
    answer = body(hcore, "    static func answer(status: Int?, body: [String: Any]?, model: String, elapsedMs: Int, timedOut: Bool) -> DictationBridge.Answer {")
    pin('if let outcome = body["polishOutcome"] as? String, polishOutcomes.contains(outcome) { details["polishOutcome"] = outcome }' in answer,
        "helper polishOutcome", "only polished, unchanged, guarded")
    pin('if let kind = body["guard"] as? String, guardKinds.contains(kind) { details["guard"] = kind }' in answer, "helper guard", "only the six kinds")
    pin('if let register = body["polishRegister"] as? String, registers.contains(register) { details["polishRegister"] = register }' in answer,
        "helper register", "only literal and default")
    pin('if let prompt = body["polishPrompt"] as? String, prompts.contains(prompt) { details["polishPrompt"] = prompt }' in answer
        and 'static let prompts: Set<String> = ["v3", "v4"]' in hcore, "helper prompt", "only v3 and v4")
    pin('if let hash = body["learnedStyleHash"] as? String, DictationPolishInstructionsBridge.isHash(hash) { details["learnedStyleHash"] = hash }' in answer
        and 'if let flag = body["learnedStyle"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { details["learnedStyle"] = flag.boolValue }' in answer,
        "helper learned style", "a JSON boolean and 8 hex characters")
    pin('Set(object.keys).isSubset(of: ["text", "model", "app", "prewarmToken"])' in hcore, "stdin allowlist", "the polish request keys are unchanged")

    # 7. The two new routes, with the polish-instructions verb pattern (health first on get).
    pin('case "dictation-learned-style": try emitDictationLearnedStyle()' in helper and 'case "dictation-polish-options": try emitDictationPolishOptions()' in helper,
        "helper verbs", "both verbs are reachable")
    style = body(helper, "    private func emitDictationLearnedStyle() throws {")
    pin('let health = request("/api/health", timeout: 5)' in style and "DictationLearnedStyleBridge.advertised(health.body)" in style
        and 'request(route, method: "DELETE", token: token, timeout: 10)' in style and 'request(route, method: "PUT", token: token, body: body, timeout: 10)' in style
        and "let body = DictationLearnedStyleBridge.body(rules: rules, enabled: enabled, baseRevision: baseRevision)" in style,
        "helper learned-style route", "get asks the capability first; set PUTs and clear DELETEs the one route")
    options = body(helper, "    private func emitDictationPolishOptions() throws {")
    pin("DictationPolishOptionsBridge.advertised(health.body)" in options and 'request(route, method: "PUT", token: token, body: DictationPolishOptionsBridge.body(version), timeout: 10)' in options,
        "helper polish-options route", "get asks the capability first; set PUTs default or v3")
    pin('static let route = "/api/dictation/learned-style"' in hcore and 'static let route = "/api/dictation/polish/options"' in hcore
        and '["learnedStyle"] as? [String: Any]' in hcore and '["polishOptions"] as? [String: Any]' in hcore, "helper capability",
        "the routes and the capability blocks are the contract's")


MUTANTS = [
    ("trigger never sent", "d", "                    self?.editTrigger(keyDown: down, keyCode: key, isRepeat: again, pointer: !isKey)\n", ""),
    ("repeat not read", "d", "let down = event.type == .keyDown, again = down && event.isARepeat", "let down = event.type == .keyDown, again = false"),
    ("trigger after the trackers", "d",
     "                    self?.editTrigger(keyDown: down, keyCode: key, isRepeat: again, pointer: !isKey)\n                    self?.keyEvent(flags: flags, pointer: !isKey, keyCode: key, raw: raw, at: time)\n",
     "                    self?.keyEvent(flags: flags, pointer: !isKey, keyCode: key, raw: raw, at: time)\n                    self?.editTrigger(keyDown: down, keyCode: key, isRepeat: again, pointer: !isKey)\n"),
    ("local monitor swallows", "d", "handler: { handle($0); return $0 })", "handler: { handle($0); return nil })"),
    ("monitor always present", "d", "            editWatcher.monitor = !keyMonitors.isEmpty\n", ""),
    ("trigger ignores learning", "d", "        guard editWatcher.isWatching, learnMode != .off else { return }\n",
     "watching: editWatcher.isWatching, learning: true) else { return }"),
    ("trigger reads on main", "d", "        editWatcher.trigger(trigger)\n", "        editWatcher.trigger(trigger); _ = Task { }\n"),
    ("signal outlives the watch", "d", "        signal?.close(); signal = nil; watchedPID = nil\n", "        watchedPID = nil\n"),
    ("watch on main", "d", "        task = Task.detached(priority: .utility) { [weak self] in\n            let started = Date()\n            let ending = await DictationEditWatch.run(",
     "        task = Task { [weak self] in\n            let started = Date()\n            let ending = await DictationEditWatch.run("),
    ("ending ignores the tracker", "d", "inside: ending.tail.sawInside, started: started", "inside: ending.canary.inside, started: started"),
    ("field closures main", "core", "        let measure: @Sendable () async -> DictationFieldSnapshot\n", "        let measure: () async -> DictationFieldSnapshot\n"),
    ("secure closure main", "core", "        let secure: @Sendable () async -> Bool\n", "        let secure: () async -> Bool\n"),
    ("focus closure main", "core", "        let focus: @Sendable (Int) async -> (verdict:", "        let focus: (Int) async -> (verdict:"),
    ("running closure main", "core", "        let running: @Sendable () async -> Bool\n", "        let running: () async -> Bool\n"),
    ("loop sleeps itself", "core", "            let trigger = await clock.pause(wait)\n", "            try? await Task.sleep(for: .milliseconds(wait)); let trigger = await clock.pause(0)\n"),
    ("fast read moves the baseline", "core", "                    tried = true; trackerReads += 1\n                    let read = await trackerRead(field, from: tracker, windowStart: bounds.location, measured: seen, calls: &calls)\n                    if let next = read.tracker { keep(next, seen: read.seen) }\n",
     "                    tried = true; trackerReads += 1\n                    let read = await trackerRead(field, from: tracker, windowStart: bounds.location, measured: seen, calls: &calls)\n                    if let next = read.tracker { keep(next, seen: read.seen); baseline = next.window }\n"),
    ("read not checked twice", "core", "        guard after.characters == n else { return (nil, .inconsistent, after) }\n", ""),
    ("staleness not wired", "core", "                                                  unread: canary.unreadChanges ?? 0)", "                                                  unread: 0)"),
    ("words in the watch log", "core", 'log("learn fast read=\\(read.read.rawValue)")\n            }\n            guard let since',
     'log("learn fast read=\\(read.read.rawValue) \\(tracker.window)")\n            }\n            guard let since'),
    ("eligibility skip silent", "d", "            Self.skipped(reason, bundle: target.bundle)\n", ""),
    ("own skip silent", "d", '            Self.skipped(reason, bundle: "com.gotcos.control")\n', ""),
    ("finish skip silent", "d", "                DictationEditWatcher.skipped(reason, bundle: target?.bundle)\n", ""),
    ("swap skip silent", "d", "            DictationEditWatcher.skipped(reason, bundle: delivered.target?.bundle)\n", ""),
    ("skip row when off", "d", "        guard DictationLearnCanary.recordsSkip(reason) else { return }\n", ""),
    ("polish outcome dropped", "d", 'polishOutcome: response.details["polishOutcome"]?.string)', "polishOutcome: nil)"),
    ("source split", "d", 'let saved = await dictionary.learn(heard: heard, written: written, source: "dictation")',
     'let saved = await dictionary.learn(heard: heard, written: written, source: "fix-a-word")'),
    ("helper source widened", "helper", '!["dictation", "meeting", "g2", "manual"].contains(source)', '!["dictation", "meeting", "g2", "manual", "edit"].contains(source)'),
    ("helper polishOutcome open", "hcore", 'if let outcome = body["polishOutcome"] as? String, polishOutcomes.contains(outcome) {',
     'if let outcome = body["polishOutcome"] as? String, !outcome.isEmpty {'),
    ("helper guard open", "hcore", 'if let kind = body["guard"] as? String, guardKinds.contains(kind) {', 'if let kind = body["guard"] as? String {'),
    ("helper register open", "hcore", 'if let register = body["polishRegister"] as? String, registers.contains(register) {', 'if let register = body["polishRegister"] as? String {'),
    ("helper prompt open", "hcore", 'if let prompt = body["polishPrompt"] as? String, prompts.contains(prompt) {', 'if let prompt = body["polishPrompt"] as? String {'),
    ("polish prompt dropped", "d", "instructionsHash: instructions.hash).with(prompt: prompt)", "instructionsHash: instructions.hash)"),
    ("timing names no prompt", "d", ' polish_prompt=\\(finished.polishPrompt ?? "-", privacy: .public)', ""),
    ("record forgets the prompt", "d", "polishModel: lastPolish?.model.rawValue, polishPrompt: lastPolishPrompt,", "polishModel: lastPolish?.model.rawValue,"),
    ("swap forgets the prompt", "d", "model: model.rawValue, prompt: run?.prompt, styleHash: run?.learnedStyleHash,\n                                                    cleaned: cleaned, in: recent); saveRecent()", "model: model.rawValue, styleHash: run?.learnedStyleHash, in: recent); saveRecent()"),
    ("helper hash open", "hcore", 'if let hash = body["learnedStyleHash"] as? String, DictationPolishInstructionsBridge.isHash(hash) {',
     'if let hash = body["learnedStyleHash"] as? String {'),
    ("stdin widened", "hcore", 'Set(object.keys).isSubset(of: ["text", "model", "app", "prewarmToken"])', 'Set(object.keys).isSubset(of: ["text", "model", "app", "prewarmToken", "style"])'),
    ("learned-style verb unreachable", "helper", '        case "dictation-learned-style": try emitDictationLearnedStyle()\n', ""),
    ("learned-style get skips health", "helper",
     "            guard let capability = DictationLearnedStyleBridge.advertised(health.body) else { answer = DictationLearnedStyleBridge.unavailable(); break }\n",
     "            let capability = DictationLearnedStyleBridge.Capability(maxChars: 1500, maxRules: 20, enabled: true)\n"),
    ("options get skips health", "helper",
     "            guard DictationPolishOptionsBridge.advertised(health.body) else { answer = DictationPolishOptionsBridge.unavailable(); break }\n", ""),
]

sources = {k: read(v) for k, v in FILES.items()}
try:
    check(sources)
except PinFailed as e:
    sys.exit(str(e))
caught = 0
for name, key, old, new in MUTANTS:
    if sources[key].count(old) != 1:
        sys.exit(f"pin self-test: mutant '{name}' lands {sources[key].count(old)} times in {FILES[key]}; it must land exactly once")
    try:
        check(dict(sources, **{key: sources[key].replace(old, new)}))
    except PinFailed as e:
        caught += 1
        print(f"KILLED  {name}  <- {e}")
        continue
    sys.exit(f"pin self-test: mutant '{name}' landed and every pin still passed")
print(f"PASS edit capture pins: the trigger (observed only), the signal, the core loop off main, two states, the consistent read, "
      f"staleness, skip rows, polishOutcome, the dictionary source, the helper's closed sets and routes; {caught} of {len(MUTANTS)} in-memory mutants caught")
