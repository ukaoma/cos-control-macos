#!/usr/bin/env python3
"""0.5.344 part 2, Your style (plan r2 section 2): where the pure rules (DictationStyle, DictationStyleClassifier and
DictationStyleCopy, executed by Tests/VoiceStyleChecks.swift) are wired into the app. Each failure names its behaviour
as "pin failed [<behaviour>]". Code only: comments never satisfy a pin. Call sites are pinned, not definitions.

Then a self-test: each in-memory mutant below must land exactly once in its file and must make a named pin fail, so no
pin here is decoration. Text only (no compile).

    python3 Tests/voice-style-pins.py <root>
"""
import pathlib, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")
FILES = {"d": "Sources/MacDictation.swift", "app": "Sources/COSControlApp.swift", "core": "Sources/MacDictationCore.swift"}


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
    d, app, core = (code(src[k]) for k in ("d", "app", "core"))
    ended = body(d, "    private func editWatchEnded(_ end: DictationWatchEnd) async {")
    pending = body(d, "    private func showPendingStylePill() {")
    undo = body(d, "    func undoLearnedFromPill() {")
    clear = body(d, "    func clearRecent() {")
    trigger = body(d, "    private func editTrigger(keyDown: Bool, keyCode: UInt16, isRepeat: Bool, pointer: Bool) {")
    watcher = body(d, "@MainActor final class DictationEditWatcher {")
    polish = body(d, "    private func polish(_ heard: String, attempt: UUID, showPill: Bool = true) async -> DictationPolishRun? {")
    deliver = body(d, "    private func deliverThenPolish(_ heard: String, attempt: UUID) async {")
    finish = body(d, "    private func finish(_ text: String, outcome: DictationDeliveryOutcome")
    store = body(d, "@MainActor final class DictationStyleStore: ObservableObject {")
    observe = body(store, "    func observe(_ evidence: DictationStyleClassifier.Evidence, polishOn: Bool, learnMode: DictationLearnMode, instructions: String) -> [String] {")
    announce = body(store, "    func announce(_ id: String) -> DictationStyle.Key? {")
    sync = body(store, "    func sync() async {")
    apply = body(store, "    private func apply(_ answer: Answer) {")
    enabled = body(store, "    func setEnabled(_ on: Bool) async {")
    reset = body(store, "    func reset() async {")
    card = body(d, "struct DictationStyleCard: View {")
    settings = body(d, "struct MacDictationSettings: View {")

    # Evidence: only a saved edit, with the watch's own facts; the classifier decides.
    saved = "        recent = DictationHistory.editing(id, edit: edit, in: recent); saveRecent()\n"
    pin(saved in ended and "DictationStyleStore.shared.observe(" in ended and ended.index(saved) < ended.index("DictationStyleStore.shared.observe("),
        "evidence is a saved edit", "the style observation follows the saved edit, never before it")
    for fact in ("complete: !end.partial", "inputEvents: end.inputEvents", "startReanchor: end.startReanchor", "appliedHash: record.polishStyleHash",
                 "baselinePolished: record.heard != nil && record.polishModel != nil", "polishOn: polishModel != .off, learnMode: learnMode",
                 "instructions: DictationPolishInstructionsStore.shared.saved"):
        pin(fact in ended, "evidence facts", f"editWatchEnded passes {fact!r}")
    pin("enabled: ledger.enabled, polishOn: polishOn, learnMode: learnMode, registers: registers,\n" in observe
        and "registersEnabled: registersEnabled, allowlist: allowlist, instructions: instructions)" in observe,
        "evidence settings", "the store hands the classifier the switch, registers and the server's allowlist")
    pin("guard result.reason == nil else { return [] }" in observe and "ledger = next; save()" in observe
        and observe.index("guard result.reason == nil") < observe.index("ledger = next; save()"), "refused evidence leaves the ledger",
        "a refused edit is never saved")
    pin("evidence.typed" not in observe and "evidence.final" not in observe and 'dictationLog.notice("style observe reason=' in observe,
        "no words in the log", "the observe log line has the reason and counts only")
    pin("if self.available { await self.sync() } else { await self.load() }" in observe, "push after learning",
        "a learned rule is pushed, or the capability is read again")

    # The pill: after the edit pill, over a hidden pill only, once per rule id ever, with Undo.
    pin("else { showPendingStylePill(); return }" in ended and "            if !Task.isCancelled { showPendingStylePill() }\n" in ended,
        "pill after the edit pill", "the style pill waits for EDIT SAVED and LEARNED to finish")
    pin("        guard !busy, pill == .hidden else { return }" in pending, "pill ranks below", "never over another pill")
    pin("guard let key = DictationStyleStore.shared.announce(rule) else { continue }" in pending, "pill once ever", "every pill goes through announce")
    pin("guard let key = key(id), DictationStyle.announce(&ledger, newlyActive: [id]) != nil else { return nil }" in announce and "save()" in announce,
        "pill once ever", "announce marks the rule shown and saves it")
    pin("label: DictationStyle.pillLabel(key)" in pending and "styleUndoRule = rule; styleUndoToken = UUID(); styleUndoPill = flash" in pending,
        "pill undo", "the style pill carries its rule for Undo")
    pin("    var pillUndoID: UUID? { pill == learnedUndoPill ? learnedUndoID : pill == styleUndoPill ? styleUndoToken : nil }" in d,
        "pill undo", "both Undo surfaces (floating pill and pet) read pillUndoID")
    pin("if pill == styleUndoPill, let rule = styleUndoRule {" in undo and "Task { await DictationStyleStore.shared.remove(rule) }" in undo,
        "pill undo", "the style pill's Undo removes that rule")

    # Clear history clears the evidence.
    pin("DictationStyleStore.shared.clearHistory()" in clear, "clear history", "Clear dictation history clears the style evidence")

    # Counts from the monitor, in the watched app only.
    pin("if editWatcher.isWatching, learnMode != .off {" in trigger
        and "let inApp = editWatcher.watchedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier" in trigger
        and "editWatcher.count(input: DictationEditLearning.countsAsInput(keyDown: keyDown, pointer: pointer, watching: true, learning: true, inApp: inApp)," in trigger
        and "typedKey: DictationEditLearning.countsAsTypedKey(keyDown: keyDown, keyCode: keyCode, watching: true, learning: true, inApp: inApp))" in trigger,
        "monitor counts", "key-downs and clicks are counted in the watched app, while a watch runs")
    pin("inputs: { signal.inputs }, keys: { signal.keys })" in watcher, "monitor counts", "the watch's clock reads the counts")
    pin("partial: ending.canary.partial == 1, inputEvents: ending.canary.inputEvents ?? 0," in watcher
        and "startReanchor: ending.tail.startReanchor))" in watcher, "watch end facts", "the store hears partial, the count and the re-anchor")
    pin("        signal?.close(); signal = nil; watchedPID = nil\n" in watcher, "watched app", "a stopped watch watches no app")

    # The polish answer's codes reach the run, the record and the timing line.
    pin('server = DictationPolishRun.Server(guarded: response.details["polishOutcome"]?.string == "guarded",' in polish
        and 'guardKind: response.details["guard"]?.string, register: response.details["polishRegister"]?.string,' in polish
        and 'learnedStyle: response.details["learnedStyle"]?.bool == true,' in polish
        and 'learnedStyleHash: response.details["learnedStyleHash"]?.string)' in polish and ".with(server: server)" in polish,
        "polish codes", "the guard, register and learned-style hash reach the run")
    pin("if let run, run.guarded, record(id) != nil {" in deliver
        and "recent = DictationHistory.guarding(id, guard: run.guardKind, styleHash: run.learnedStyleHash, in: recent); saveRecent()" in deliver,
        "guarded record", "paste first: a guarded answer marks the record Kept as heard")
    pin("polishGuard: lastPolishGuard, polishStyleHash: lastPolishStyleHash)" in finish, "guarded record", "polish first: the record keeps the codes")
    for field in (' polish_register=\\(finished.polishRegister ?? "-", privacy: .public)', ' polish_style=\\(finished.polishLearnedStyle.map { $0 ? "1" : "0" } ?? "-", privacy: .public)',
                  ' polish_guard=\\(finished.polishGuard ?? "-", privacy: .public)'):
        pin(field in d, "timing codes", f"the timing line carries {field.split('=')[0].strip()}")

    # The server: only when it advertises learned style; Off sends only the switch.
    pin("        guard available, let current = server else { return }" in sync, "capability gate", "nothing is pushed to an older server")
    pin("        available = state.available != false\n        guard available else { return }" in apply, "capability gate",
        "an answer without the capability keeps the ledger local")
    pin("        registersEnabled = state.registersEnabled ?? false\n" in apply and apply.count("registersEnabled =") == 1, "registers flag only",
        "literal apps are excluded only when the GET says registersEnabled, never inferred from the always-published map")
    pin("        guard available else { return }" in enabled and 'var request: [String: Any] = ["operation": "set", "enabled": on]' in enabled
        and '"rules"' not in enabled, "switch sends only enabled", "Off PUTs {enabled:false} and keeps the server's rules")
    pin('if available, let answer = await send(["operation": "clear"]) { apply(answer) }' in reset, "capability gate", "Reset clears the server only when it has the setting")
    pin('"rules": rules.map(Self.object)]' in sync and '"baseHash": base,' in sync, "push with base hash", "every PUT carries the hash it was based on")

    # The card: under AI polish in Settings, which the 390 pt panel and the Settings pane both show.
    instructions = "DictationPolishInstructionsCard(store: DictationPolishInstructionsStore.shared, polishOn: store.polishModel != .off)"
    pin(instructions in settings and "DictationStyleCard(style: DictationStyleStore.shared, dictation: store)" in settings
        and settings.index(instructions) < settings.index("DictationStyleCard(style:"), "card placement", "Your style sits under the polish instructions")
    for line in ("DictationStyleCopy.disclosureRules", "DictationStyleCopy.disclosureKeys", "DictationStyleCopy.switchTitle", "DictationStyleCopy.status(available:",
                 "DictationStyleCopy.templates(allowlist: style.allowlist)", "DictationStyleCopy.previousPolish", "DictationStyleCopy.reset"):
        pin(line in card, "card copy", f"the card shows {line}")
    pin("await style.setPreviousPolish(on)" in card and "if let version = style.promptVersion {" in card, "previous polish",
        "Previous polish (v3) shows only on a server with the option")
    pin("Task { await style.setEnabled(next) }" in card, "card switch", "the switch goes through setEnabled")
    pin("learnMode: dictation.learnMode, monitor: dictation.editMonitor)" in card and "    var editMonitor: Bool { editWatcher.monitor }" in d,
        "card shortcut line", "the card knows whether the shortcut monitor can count typing")
    pin(card.count("styleRules") == 0 and d.count("styleRules: DictationStyleStore.shared.ruleCount(record.polishStyleHash)") == 4,
        "card style rules", "every dictation line counts the rules its hash names")

    # The bridges: answers come back even when the server refuses (409, 413).
    pin('model.runHelper(["dictation-learned-style"], timeout: 20, stdinData: request, answers: true)' in app, "bridges",
        "the learned-style verb returns refusals as answers")
    pin('model.runHelper(["dictation-polish-options"], timeout: 20, stdinData: request, answers: true)' in app, "bridges",
        "the polish options verb returns refusals as answers")
    pin("DictationStyleStore.shared.suggestOnly = { [weak model] in model?.dictation.learnMode == .suggest }" in app, "suggest only",
        "Suggest only reaches the store")
    pin("Task { await DictationStyleStore.shared.load() }" in app, "push on launch", "launch reads the server and pushes a difference")


MUTANTS = [
    ("observe before the save", "d",
     "        recent = DictationHistory.editing(id, edit: edit, in: recent); saveRecent()\n        // 0.5.344 part 2: the saved edit as style evidence",
     "        // 0.5.344 part 2: the saved edit as style evidence"),
    ("partial counts", "d", "complete: !end.partial,", "complete: true,"),
    ("no input count", "d", "inputEvents: end.inputEvents, startReanchor: end.startReanchor, app: end.app,", "inputEvents: 1, startReanchor: end.startReanchor, app: end.app,"),
    ("hash dropped", "d", "appliedHash: record.polishStyleHash),", "appliedHash: nil),"),
    ("polish ignored", "d", "polishOn: polishModel != .off, learnMode: learnMode, instructions:", "polishOn: true, learnMode: learnMode, instructions:"),
    ("switch ignored", "d", "enabled: ledger.enabled, polishOn: polishOn, learnMode: learnMode, registers: registers,", "enabled: true, polishOn: polishOn, learnMode: learnMode, registers: registers,"),
    ("refused saved", "d", "        guard result.reason == nil else { return [] }\n", ""),
    ("words logged", "d", 'dictationLog.notice("style observe reason=\\(result.reason ?? "learned", privacy: .public) active=\\(result.newlyActive.count)")',
     'dictationLog.notice("style observe reason=\\(result.reason ?? "learned", privacy: .public) final=\\(evidence.final, privacy: .public)")'),
    ("no push", "d", "        Task { if self.available { await self.sync() } else { await self.load() } }\n", ""),
    ("pill over another", "d", "        guard !busy, pill == .hidden else { return }\n        while let rule = pendingStyleRules.first {",
     "        guard !busy else { return }\n        while let rule = pendingStyleRules.first {"),
    ("pill skips announce", "d", "            guard let key = DictationStyleStore.shared.announce(rule) else { continue }",
     "            guard let key = DictationStyleStore.shared.key(rule) else { continue }"),
    ("announce unsaved", "d", "        guard let key = key(id), DictationStyle.announce(&ledger, newlyActive: [id]) != nil else { return nil }\n        save()\n",
     "        guard let key = key(id), DictationStyle.announce(&ledger, newlyActive: [id]) != nil else { return nil }\n"),
    ("pill never after edit", "d", "            if !Task.isCancelled { showPendingStylePill() }\n", ""),
    ("undo on the pet only", "d", "pill == styleUndoPill ? styleUndoToken : nil }", "nil }"),
    ("undo keeps the rule", "d", "            Task { await DictationStyleStore.shared.remove(rule) }\n", ""),
    ("clear keeps evidence", "d", "        DictationStyleStore.shared.clearHistory()\n", ""),
    ("counts outside the app", "d", "            let inApp = editWatcher.watchedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier",
     "            let inApp = true"),
    ("counts while learning off", "d", "        if editWatcher.isWatching, learnMode != .off {", "        if editWatcher.isWatching {"),
    ("clock blind", "d", "inputs: { signal.inputs }, keys: { signal.keys })", "inputs: { 0 }, keys: { signal.keys })"),
    ("end loses the count", "d", "inputEvents: ending.canary.inputEvents ?? 0,", "inputEvents: 0,"),
    ("app kept after stop", "d", "        signal?.close(); signal = nil; watchedPID = nil\n", "        signal?.close(); signal = nil\n"),
    ("guard kind dropped", "d", 'guardKind: response.details["guard"]?.string, register:', "guardKind: nil, register:"),
    ("server codes dropped", "d", ".with(prompt: prompt).with(server: server)", ".with(prompt: prompt)"),
    ("guarded not recorded", "d", "            recent = DictationHistory.guarding(id, guard: run.guardKind, styleHash: run.learnedStyleHash, in: recent); saveRecent()\n", ""),
    ("record loses the guard", "d", "polishGuard: lastPolishGuard, polishStyleHash: lastPolishStyleHash)", "polishStyleHash: lastPolishStyleHash)"),
    ("timing loses the guard", "d", ' polish_guard=\\(finished.polishGuard ?? "-", privacy: .public)', ""),
    ("push to an older server", "d", "        guard available, let current = server else { return }", "        guard let current = server else { return }"),
    ("unavailable counts as available", "d", "        available = state.available != false\n", "        available = true\n"),
    ("registers inferred from the map", "d", "        registersEnabled = state.registersEnabled ?? false\n",
     "        registersEnabled = !(state.registers ?? [:]).isEmpty\n"),
    ("registers on by default", "d", "        registersEnabled = state.registersEnabled ?? false\n", "        registersEnabled = state.registersEnabled ?? true\n"),
    ("switch sends rules", "d", 'var request: [String: Any] = ["operation": "set", "enabled": on]', 'var request: [String: Any] = ["operation": "set", "enabled": on, "rules": []]'),
    ("push without base", "d", '"enabled": enabled, "baseHash": base,', '"enabled": enabled,'),
    ("card missing", "d", "                DictationStyleCard(style: DictationStyleStore.shared, dictation: store)\n", ""),
    ("key disclosure missing", "d", "            Text(DictationStyleCopy.disclosureKeys)", "            Text(DictationStyleCopy.disclosureRules)"),
    ("card blind to the monitor", "d", "learnMode: dictation.learnMode, monitor: dictation.editMonitor)", "learnMode: dictation.learnMode)"),
    ("previous polish always", "d", "            if let version = style.promptVersion {", "            if let version = Optional(style.promptVersion ?? \"default\") {"),
    ("card line without rules", "d", "            Text(record.metaLine(time: DictionaryLabels.when(record.createdAt, now: Date()), styleRules: DictationStyleStore.shared.ruleCount(record.polishStyleHash)))\n                .font(COSType.mono(size.typeSize(8)",
     "            Text(record.metaLine(time: DictionaryLabels.when(record.createdAt, now: Date())))\n                .font(COSType.mono(size.typeSize(8)"),
    ("refusals thrown", "app", 'model.runHelper(["dictation-learned-style"], timeout: 20, stdinData: request, answers: true)', 'model.runHelper(["dictation-learned-style"], timeout: 20, stdinData: request)'),
    ("options refusals thrown", "app", 'model.runHelper(["dictation-polish-options"], timeout: 20, stdinData: request, answers: true)', 'model.runHelper(["dictation-polish-options"], timeout: 20, stdinData: request)'),
    ("suggest lost", "app", "        DictationStyleStore.shared.suggestOnly = { [weak model] in model?.dictation.learnMode == .suggest }\n", ""),
    ("no launch read", "app", "        Task { await DictationStyleStore.shared.load() }\n", ""),
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
print(f"PASS voice style pins: saved-edit evidence and its facts, refused evidence unsaved, no words logged, the pill once ever after "
      f"the edit pill with Undo on both surfaces, clear history, counts in the watched app, the polish codes on the run, record and "
      f"timing line, the capability gate, the enabled-only switch, the card and its copy, the bridges; {caught} of {len(MUTANTS)} in-memory mutants caught")
