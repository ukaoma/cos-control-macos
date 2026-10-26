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
FILES = {"d": "Sources/MacDictation.swift", "app": "Sources/COSControlApp.swift", "core": "Sources/MacDictationCore.swift",
         "model": "Sources/ControllerModel.swift"}


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
    d, app, core, model = (code(src[k]) for k in ("d", "app", "core", "model"))
    ended = body(d, "    private func editWatchEnded(_ end: DictationWatchEnd) async {")
    pending = body(d, "    private func showPendingStylePill() {")
    undo = body(d, "    func undoLearnedFromPill() {")
    clear = body(d, "    func clearRecent() {")
    trigger = body(d, "    private func editTrigger(keyDown: Bool, keyCode: UInt16, isRepeat: Bool, pointer: Bool) {")
    watcher = body(d, "@MainActor final class DictationEditWatcher {")
    polish = body(d, "    private func polish(_ heard: String, attempt: UUID, showPill: Bool = true) async -> DictationPolishRun? {")
    deliver = body(d, "    private func deliverThenPolish(_ heard: String, typing: String, attempt: UUID) async {")
    finish = body(d, "    private func finish(_ text: String, outcome: DictationDeliveryOutcome")
    store = body(d, "@MainActor final class DictationStyleStore: ObservableObject {")
    card = body(d, "struct DictationStyleCard: View {")
    settings = body(d, "struct MacDictationSettings: View {")
    ctl = body(core, "@MainActor final class DictationStyleController {")
    observe = body(ctl, "    func observe(_ evidence: DictationStyleClassifier.Evidence, model: DictationPolishModel, learnMode: DictationLearnMode, instructions: String) -> [String] {")
    announce = body(ctl, "    func announce(_ id: String, model: DictationPolishModel) -> DictationStyle.Key? {")
    sync_once = body(ctl, "    private func syncOnce() async {")
    take = body(ctl, "    private func take(_ state: DictationStyle.Server) {")
    reset = body(ctl, "    func reset() async {")
    request = body(store, "    nonisolated static func request(_ call: DictationStyleController.Call) -> [String: Any] {")

    # Evidence: only a saved edit, with the watch's own facts; the classifier decides, behind the not-used gate.
    saved = "        recent = DictationHistory.editing(id, edit: edit, in: recent); saveRecent()\n"
    pin(saved in ended and "DictationStyleStore.shared.observe(" in ended and ended.index(saved) < ended.index("DictationStyleStore.shared.observe("),
        "evidence is a saved edit", "the style observation follows the saved edit, never before it")
    # 0.5.345 (A-W11): with Claude's unswapped version still held, the baseline is the pending polish (typed with the
    # changes the person and polish both made applied, DictationPolishMatch.baseline); otherwise the record's, as before.
    for fact in ("complete: !end.partial", "inputEvents: end.inputEvents", "startReanchor: end.startReanchor",
                 "appliedHash: baseline != nil ? pending?.styleHash : record.polishStyleHash",
                 "baselinePolished: baseline != nil || record.polishedByClaude", "typed: baseline ?? end.typed, final: final,",
                 "model: polishModel, learnMode: learnMode", "instructions: DictationPolishInstructionsStore.shared.saved",
                 "let pending = pendingPolish[id].flatMap { $0.cleaned == nil ? $0 : nil }", "if !matched {"):
        pin(fact in ended, "evidence facts", f"editWatchEnded passes {fact!r}")
    pin("DictationStyleClassifier.Settings(enabled: ledger.enabled, learnMode: learnMode, notUsed: notUsed(model: model), registers: registers," in observe
        and "registersEnabled: registersEnabled, allowlist: allowlist, instructions: instructions)" in observe,
        "evidence settings", "the controller hands the classifier the switch, the not-used gate, registers and the server's allowlist")
    pin("guard result.reason == nil else { lastObserved = []; return [] }" in observe and "ledger = next; save()" in observe
        and observe.index("guard result.reason == nil") < observe.index("ledger = next; save()"), "refused evidence leaves the ledger",
        "a refused edit is never saved")
    pin("evidence.typed" not in observe and "evidence.final" not in observe and 'log?("style observe reason=' in observe,
        "no words in the log", "the observe log line has the reason and counts only")
    pin("Task { await self.sync() }" in observe, "push after learning", "a learned rule is pushed")

    # The pill: after the edit pill, over a hidden pill only, once per rule id ever, only where the rules apply, with Undo.
    pin("else { showPendingStylePill(); return }" in ended and "            if !Task.isCancelled { showPendingStylePill() }\n" in ended,
        "pill after the edit pill", "the style pill waits for EDIT SAVED and LEARNED to finish")
    pin("        guard !busy, pill == .hidden else { return }" in pending, "pill ranks below", "never over another pill")
    pin("guard let key = DictationStyleStore.shared.announce(rule, model: polishModel) else { continue }" in pending, "pill once ever",
        "every pill goes through announce, with the polish model")
    pin("guard notUsed(model: model) == nil, let key = key(id), DictationStyle.announce(&ledger, newlyActive: [id]) != nil else { return nil }" in announce
        and "save()" in announce, "pill gated", "no pill where the rules are not used; announce marks it shown and saves it")
    pin("label: DictationStyle.pillLabel(key)" in pending and "styleUndoRule = rule; styleUndoToken = UUID(); styleUndoPill = flash" in pending,
        "pill undo", "the style pill carries its rule for Undo")
    pin("    var pillUndoID: UUID? { pill == learnedUndoPill ? learnedUndoID : pill == styleUndoPill ? styleUndoToken : nil }" in d,
        "pill undo", "both Undo surfaces (floating pill and pet) read pillUndoID")
    pin("if pill == styleUndoPill, let rule = styleUndoRule {" in undo and "Task { await DictationStyleStore.shared.remove(rule) }" in undo,
        "pill undo", "the style pill's Undo removes that rule")
    pin(".help(styleUndo ? DictationStyleCopy.undoHelp : " in d and "return DictationStyle.isPillLabel(label)" in d, "pill undo label",
        "the style pill's Undo says Remove this style rule")

    # Clear history clears the evidence.
    pin("Task { await DictationStyleStore.shared.clearHistory() }" in clear, "clear history", "Clear dictation history clears the style evidence")

    # Counts from the monitor: typed keys in the watched app only; triggers in that app only.
    pin("guard editWatcher.isWatching, learnMode != .off else { return }" in trigger
        and "let inApp = editWatcher.watchedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier" in trigger
        and "let typed = DictationEditLearning.countsAsTypedKey(keyDown: keyDown, keyCode: keyCode, watching: true, learning: true, inApp: inApp)" in trigger
        and "editWatcher.count(input: typed, typedKey: typed)" in trigger and "watching: true, learning: true, inApp: inApp) else { return }" in trigger,
        "monitor counts", "typed keys and triggers in the watched app, while a watch runs")
    pin("inputs: { signal.inputs }, keys: { signal.keys }," in watcher
        and "sinceLastKey: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) })" in watcher,
        "monitor counts", "the watch's clock reads the counts, and the system's last key-down for a watch without the monitor")
    pin("partial: ending.canary.partial == 1, inputEvents: ending.canary.inputEvents ?? 0," in watcher
        and "startReanchor: ending.tail.startReanchor))" in watcher, "watch end facts", "the store hears partial, the count and the re-anchor")
    pin("        signal?.close(); signal = nil; watchedPID = nil\n" in watcher, "watched app", "a stopped watch watches no app")

    # The polish answer's codes reach the run, the record and the timing line; cleaned text swaps in as cleaned.
    pin('server = DictationPolishRun.Server(guarded: response.details["polishOutcome"]?.string == "guarded",' in polish
        and 'guardKind: response.details["guard"]?.string, register: response.details["polishRegister"]?.string,' in polish
        and 'learnedStyle: response.details["learnedStyle"]?.bool == true,' in polish
        and 'learnedStyleHash: response.details["learnedStyleHash"]?.string)' in polish and ".with(server: server)" in polish,
        "polish codes", "the guard, register and learned-style hash reach the run")
    pin("if let run, run.guarded, record(id) != nil {" in deliver
        and "recent = DictationHistory.guarding(id, guard: run.guardKind, styleHash: run.learnedStyleHash, in: recent); saveRecent()" in deliver,
        "guarded record", "paste first: a guarded answer marks the record (Kept COS's cleaned text)")
    pin("polishGuard: lastPolishGuard, polishStyleHash: lastPolishStyleHash, polishCleaned: lastPolishCleaned," in finish, "guarded record",
        "polish first: the record keeps the codes")
    pin("if let polished = DictationPolishSwap.swapText(run?.outcome) {\n            final = DictationInsertion.polishedFinal(" in deliver
        and "let cleaned = DictationPolish.cleaned(run?.outcome)" in deliver and "styleHash: run?.learnedStyleHash, cleaned: cleaned)" in deliver,
        "cleaned swap", "paste first swaps the server's cleaned text in (0.5.343 parity) and Apply polished keeps it")
    for field in (' polish_register=\\(finished.polishRegister ?? "-", privacy: .public)', ' polish_style=\\(finished.polishLearnedStyle.map { $0 ? "1" : "0" } ?? "-", privacy: .public)',
                  ' polish_guard=\\(finished.polishGuard ?? "-", privacy: .public)'):
        pin(field in d, "timing codes", f"the timing line carries {field.split('=')[0].strip()}")

    # The server: only when it advertises learned style; the base is the revision; registers only from the flag.
    pin("        guard available, var current = server else { return }" in sync_once, "capability gate", "nothing is pushed to an older server")
    pin("        available = state.available != false\n        guard available else { server = nil; changed(); return }" in take, "capability gate",
        "an answer without the capability keeps the ledger local")
    pin("        registersEnabled = state.registersEnabled ?? false\n" in take and ctl.count("        registersEnabled = ") == 1 and "var registersEnabled = false" in ctl, "registers flag only",
        "literal apps are excluded only when the GET says registersEnabled, never inferred from the always-published map")
    pin("baseRevision: current.revision))" in sync_once and 'if let baseRevision { out["baseRevision"] = baseRevision }' in request
        and '"baseHash"' not in request, "push with base", "every PUT carries the revision it was based on, never baseHash (bcdf083)")
    pin('if let rules { out["rules"] = rules.map(object) }' in request and 'if let enabled { out["enabled"] = enabled }' in request,
        "switch sends only enabled", "a PUT carries only what changed")
    pin("        if available {\n            let reply = await transport?(.clear)" in reset, "capability gate", "Reset clears the server only when it has the setting")
    pin("allowlist: allowlist)" in sync_once and "DictationStyle.ranked(ledger, suggestOnly: suggestOnly(), now: now(), allowlist: allowlist)" in sync_once,
        "allowlist filter", "a rule the server no longer takes is never sent")
    # 0.5.345 (QA4 15): a changed version or runtime generation always reloads (serverCameBack(changed:)).
    pin("if newValue.running, !status.running || changed { DictationStyleStore.shared.serverCameBack(changed: changed) }" in model
        and "let changed = status.version != newValue.version || status.activeWorkDirectory != newValue.activeWorkDirectory" in model,
        "reload on return", "the server's return or a newer server (or generation) reads Your style and the options again")
    pin("let loaded = url.map { DictationStyle.load(from: $0, now: Date()) }" in store and "controller = DictationStyleController(ledger: loaded.ledger, loaded: loaded.result)" in store,
        "ledger load", "the store loads with the quarantine and tells the controller how")

    # The card: under AI polish in Settings, which the 390 pt panel and the Settings pane both show.
    instructions = "DictationPolishInstructionsCard(store: DictationPolishInstructionsStore.shared, polishOn: store.polishModel != .off, model: store.polishModel)"
    pin(instructions in settings and "DictationStyleCard(style: DictationStyleStore.shared, dictation: store)" in settings
        and settings.index(instructions) < settings.index("DictationStyleCard(style:"), "card placement", "Your style sits under the polish instructions")
    for line in ("DictationStyleCopy.disclosureRules", "DictationStyleCopy.disclosureKeys", "DictationStyleCopy.switchTitle", "DictationStyleCopy.status(learnMode:",
                 "DictationStyleCopy.templates(allowlist: style.allowlist)", "DictationStyleCopy.previousPolish", "DictationStyleCopy.reset",
                 "DictationStyleCopy.rulesHeading(enabled: style.ledger.enabled, notUsed: notUsed)", "DictationStyleCopy.detail($0)"):
        pin(line in card, "card copy", f"the card shows {line}")
    pin("let notUsed = style.notUsed(model: dictation.polishModel)" in card and "section(heading.heading, line: heading.line, active)" in card,
        "card not used", "the rules sit under Paused or Not used with why, or Active")
    pin("await style.setPreviousPolish(on)" in card and "if let version = style.options.promptVersion {" in card
        and ".disabled(style.options.envOverride)" in card and "DictationStyleCopy.setOnServer" in card, "previous polish",
        "Previous polish shows only on a server with the option, and is set on the server when the environment decides")
    pin("Task { await style.setEnabled(next) }" in card, "card switch", "the switch goes through setEnabled")
    pin("learnMode: dictation.learnMode, monitor: dictation.editMonitor" in card and "    var editMonitor: Bool { editWatcher.monitor }" in d,
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
    pin("Task { await DictationStyleStore.shared.load(); await DictationStyleStore.shared.loadOptions() }" in app, "push on launch",
        "launch reads the server and its options, and pushes a difference")


MUTANTS = [
    ("observe before the save", "d",
     "        recent = DictationHistory.editing(id, edit: edit, in: recent); saveRecent()\n        // 0.5.344 part 2: the saved edit as style evidence",
     "        // 0.5.344 part 2: the saved edit as style evidence"),
    ("partial counts", "d", "complete: !end.partial,", "complete: true,"),
    ("no input count", "d", "inputEvents: end.inputEvents, startReanchor: end.startReanchor, app: end.app,", "inputEvents: 1, startReanchor: end.startReanchor, app: end.app,"),
    ("hash dropped", "d", "appliedHash: baseline != nil ? pending?.styleHash : record.polishStyleHash),", "appliedHash: nil),"),
    ("any baseline", "d", "baselinePolished: baseline != nil || record.polishedByClaude,", "baselinePolished: record.heard != nil,"),
    ("model not passed", "d", "            model: polishModel, learnMode: learnMode, instructions:", "            model: .sonnet, learnMode: learnMode, instructions:"),
    ("gate dropped", "core", "learnMode: learnMode, notUsed: notUsed(model: model), registers: registers,", "learnMode: learnMode, notUsed: nil, registers: registers,"),
    ("switch ignored", "core", "DictationStyleClassifier.Settings(enabled: ledger.enabled, learnMode:", "DictationStyleClassifier.Settings(enabled: true, learnMode:"),
    ("refused saved", "core", "        guard result.reason == nil else { lastObserved = []; return [] }\n", ""),
    ("words logged", "core", 'log?("style observe reason=\\(result.reason ?? "learned") active=\\(result.newlyActive.count)")',
     'log?("style observe reason=\\(result.reason ?? "learned") final=\\(evidence.final)")'),
    ("no push", "core", "        Task { await self.sync() }\n        return result.newlyActive", "        return result.newlyActive"),
    ("pill over another", "d", "        guard !busy, pill == .hidden else { return }\n        while let rule = pendingStyleRules.first {",
     "        guard !busy else { return }\n        while let rule = pendingStyleRules.first {"),
    ("pill skips announce", "d", "            guard let key = DictationStyleStore.shared.announce(rule, model: polishModel) else { continue }",
     "            guard let key = DictationStyle.Key?.none ?? DictationStyle.Key(kind: .contractions, param: rule) as DictationStyle.Key? else { continue }"),
    ("pill where not used", "core", "        guard notUsed(model: model) == nil, let key = key(id),", "        guard let key = key(id),"),
    ("announce unsaved", "core", "DictationStyle.announce(&ledger, newlyActive: [id]) != nil else { return nil }\n        save()\n",
     "DictationStyle.announce(&ledger, newlyActive: [id]) != nil else { return nil }\n"),
    ("pill never after edit", "d", "            if !Task.isCancelled { showPendingStylePill() }\n", ""),
    ("undo on the pet only", "d", "pill == styleUndoPill ? styleUndoToken : nil }", "nil }"),
    ("undo keeps the rule", "d", "            Task { await DictationStyleStore.shared.remove(rule) }\n", ""),
    ("undo says dictionary", "d", ".help(styleUndo ? DictationStyleCopy.undoHelp : ", ".help(styleUndo ? \"Remove this word from the dictionary\" : "),
    ("clear keeps evidence", "d", "        Task { await DictationStyleStore.shared.clearHistory() }\n", ""),
    ("counts outside the app", "d", "        let inApp = editWatcher.watchedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier",
     "        let inApp = true"),
    ("counts clicks", "d", "        editWatcher.count(input: typed, typedKey: typed)", "        editWatcher.count(input: typed || pointer, typedKey: typed)"),
    ("triggers in any app", "d", "watching: true, learning: true, inApp: inApp) else { return }", "watching: true, learning: true, inApp: true) else { return }"),
    ("counts while learning off", "d", "        guard editWatcher.isWatching, learnMode != .off else { return }", "        guard editWatcher.isWatching else { return }"),
    ("clock blind", "d", "inputs: { signal.inputs }, keys: { signal.keys },", "inputs: { 0 }, keys: { signal.keys },"),
    ("no last key", "d", "sinceLastKey: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) })", "sinceLastKey: { nil })"),
    ("end loses the count", "d", "inputEvents: ending.canary.inputEvents ?? 0,", "inputEvents: 0,"),
    ("app kept after stop", "d", "        signal?.close(); signal = nil; watchedPID = nil\n", "        signal?.close(); signal = nil\n"),
    ("guard kind dropped", "d", 'guardKind: response.details["guard"]?.string, register:', "guardKind: nil, register:"),
    ("server codes dropped", "d", ".with(prompt: prompt).with(server: server)", ".with(prompt: prompt)"),
    ("guarded not recorded", "d", "            recent = DictationHistory.guarding(id, guard: run.guardKind, styleHash: run.learnedStyleHash, in: recent); saveRecent()\n", ""),
    ("record loses the guard", "d", "polishGuard: lastPolishGuard, polishStyleHash: lastPolishStyleHash, polishCleaned: lastPolishCleaned,",
     "polishStyleHash: lastPolishStyleHash, polishCleaned: lastPolishCleaned,"),
    ("record loses cleaned", "d", "polishStyleHash: lastPolishStyleHash, polishCleaned: lastPolishCleaned,", "polishStyleHash: lastPolishStyleHash,"),
    ("cleaned never swapped", "d", "if let polished = DictationPolishSwap.swapText(run?.outcome) {\n            final = DictationInsertion.polishedFinal(",
     "if case .applied(let polished)? = run?.outcome {\n            final = DictationInsertion.polishedFinal("),
    ("pending loses cleaned", "d", "styleHash: run?.learnedStyleHash, cleaned: cleaned)", "styleHash: run?.learnedStyleHash)"),
    ("timing loses the guard", "d", ' polish_guard=\\(finished.polishGuard ?? "-", privacy: .public)', ""),
    ("push to an older server", "core", "        guard available, var current = server else { return }", "        guard var current = server else { return }"),
    ("unavailable counts as available", "core", "        available = state.available != false\n", "        available = true\n"),
    ("registers inferred from the map", "core", "        registersEnabled = state.registersEnabled ?? false\n",
     "        registersEnabled = !(state.registers ?? [:]).isEmpty\n"),
    ("registers on by default", "core", "        registersEnabled = state.registersEnabled ?? false\n", "        registersEnabled = state.registersEnabled ?? true\n"),
    ("base never the revision", "core", "baseRevision: current.revision))", "baseRevision: nil))"),
    ("revision not sent", "d", '            if let baseRevision { out["baseRevision"] = baseRevision }\n', ""),
    ("baseHash sent", "d", '            if let baseRevision { out["baseRevision"] = baseRevision }\n', '            if let baseRevision { out["baseRevision"] = baseRevision; out["baseHash"] = baseRevision }\n'),
    ("rules always sent", "d", 'if let rules { out["rules"] = rules.map(object) }', 'out["rules"] = (rules ?? []).map(object)'),
    ("reset deletes on an older server", "core", "        if available {\n            let reply = await transport?(.clear)", "        if true {\n            let reply = await transport?(.clear)"),
    ("no reload on return", "model", "if newValue.running, !status.running || changed { DictationStyleStore.shared.serverCameBack(changed: changed) }", "if false { }"),
    ("load without quarantine", "d", "let loaded = url.map { DictationStyle.load(from: $0, now: Date()) }", "let loaded = url.map { _ in (DictationStyle.Ledger(), DictationStyle.LoadResult.read) }"),
    ("card missing", "d", "                DictationStyleCard(style: DictationStyleStore.shared, dictation: store)\n", ""),
    ("key disclosure missing", "d", "            Text(DictationStyleCopy.disclosureKeys)", "            Text(DictationStyleCopy.disclosureRules)"),
    ("rules always active", "d", "section(heading.heading, line: heading.line, active)", "section(DictationStyleCopy.active, line: nil, active)"),
    ("previous polish always", "d", "            if let version = style.options.promptVersion {", "            if let version = Optional(style.options.promptVersion ?? \"default\") {"),
    ("env override ignored", "d", "                    .disabled(style.options.envOverride)\n", ""),
    ("card blind to the monitor", "d", "learnMode: dictation.learnMode, monitor: dictation.editMonitor", "learnMode: dictation.learnMode, monitor: true"),
    ("card line without rules", "d", "            Text(record.metaLine(time: DictionaryLabels.when(record.createdAt, now: Date()), styleRules: DictationStyleStore.shared.ruleCount(record.polishStyleHash)))\n                .font(COSType.mono(size.typeSize(8)",
     "            Text(record.metaLine(time: DictionaryLabels.when(record.createdAt, now: Date())))\n                .font(COSType.mono(size.typeSize(8)"),
    ("refusals thrown", "app", 'model.runHelper(["dictation-learned-style"], timeout: 20, stdinData: request, answers: true)', 'model.runHelper(["dictation-learned-style"], timeout: 20, stdinData: request)'),
    ("options refusals thrown", "app", 'model.runHelper(["dictation-polish-options"], timeout: 20, stdinData: request, answers: true)', 'model.runHelper(["dictation-polish-options"], timeout: 20, stdinData: request)'),
    ("suggest lost", "app", "        DictationStyleStore.shared.suggestOnly = { [weak model] in model?.dictation.learnMode == .suggest }\n", ""),
    ("no launch read", "app", "        Task { await DictationStyleStore.shared.load(); await DictationStyleStore.shared.loadOptions() }\n", ""),
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
print(f"PASS voice style pins: saved-edit evidence and its facts behind the not-used gate, refused evidence unsaved, no words logged, the pill once "
      f"ever after the edit pill, only where rules apply, with Undo on both surfaces, clear history, typed keys and triggers in the watched app, the "
      f"polish codes and cleaned swap, the capability gate, the revision base, registers from the flag, reload on return, the quarantined load, "
      f"the card and its copy, the bridges; {caught} of {len(MUTANTS)} in-memory mutants caught")
