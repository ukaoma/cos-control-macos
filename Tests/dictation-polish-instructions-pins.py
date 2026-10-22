#!/usr/bin/env python3
"""0.5.335 (server 6.85.0) Your polish instructions: where the pure rules (DictationPolishInstructions, in
MacDictationChecks; DictationPolishInstructionsBridge, in the helper checks) are wired. Each failure names its behaviour
as "pin failed [<behaviour>]". Code only: comments never satisfy a pin. Call sites are pinned, not definitions.

Then a self-test: each in-memory mutant below must land exactly once in its file and must make a named pin fail, so no
pin here is decoration. Text only: SwiftUI layout is compiled by the full app build, not here.

    python3 Tests/dictation-polish-instructions-pins.py <root>
"""
import pathlib, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")
FILES = {"d": "Sources/MacDictation.swift", "app": "Sources/COSControlApp.swift", "helper": "HelperSources/main.swift"}


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


def check(src):
    d, app, helper = code(src["d"]), code(src["app"]), code(src["helper"])
    settings = body(d, "struct MacDictationSettings: View {")
    card = body(d, "struct DictationPolishInstructionsCard: View {")
    store = body(d, "@MainActor final class DictationPolishInstructionsStore: ObservableObject {")
    polish = body(d, "    private func polish(_ heard: String, attempt: UUID, showPill: Bool = true) async -> DictationPolishRun? {")
    verb = body(helper, "    private func emitDictationPolishInstructions() throws {")

    # 1. The card sits under AI polish, inside the dictation settings, before the history retention row.
    place = "DictationPolishInstructionsCard(store: DictationPolishInstructionsStore.shared, polishOn: store.polishModel != .off)"
    pin(settings.count(place) == 1, "placement", "Settings, Dictation shows the card once, with the shared store and whether polish is on")
    pin(settings.index('COSDropdown("AI polish"') < settings.index(place) < settings.index('COSDropdown("Keep dictations for"'),
        "placement", "the card is under the AI polish setting")
    # 2. Hidden unless the server advertises the setting.
    pin(card.count("if DictationPolishInstructions.visible(available: store.available) {") == 1, "hidden on an older server",
        "the card renders only when the store says the server has the setting")
    pin(store.count("available = state.available") == 1 and "@Published private(set) var available = false" in store, "hidden on an older server",
        "the store starts hidden and takes availability only from the helper's answer")
    # 3. The box: counter, Save and Clear by the pure rules, placeholder only when empty.
    pin(card.count("Text(DictationPolishInstructions.counter(draft))") == 1, "counter", "the counter reads the draft")
    pin(card.count(".disabled(!DictationPolishInstructions.canSave(draft: draft, saved: store.saved, busy: store.busy))") == 1, "save", "Save follows canSave")
    pin(card.count(".disabled(!DictationPolishInstructions.canClear(draft: draft, saved: store.saved, busy: store.busy))") == 1, "clear", "Clear follows canClear")
    pin(card.count("if await store.save(draft) {") == 1 and card.count("if await store.clear() {") == 1, "save", "Save and Clear call the store")
    pin(card.count("if draft.isEmpty {") == 1 and card.count("Text(DictationPolishInstructions.placeholder)") == 1, "placeholder", "examples show only in an empty box")
    # 4. The built-in rules, read-only, loaded when the disclosure opens.
    pin(card.count('DisclosureGroup("See the built-in rules", isExpanded: $rulesOpen) {') == 1
        and card.count("if open, store.rules == nil { Task { await store.loadRules() } }") == 1, "rules", "the rules load when the disclosure opens")
    pin("TextEditor(text: Binding(get: { rules" not in card and card.count("Text(rules.text)") == 1, "rules", "the rules are shown as text, not an editor")
    # 5. The words go only through the helper's stdin, built by the pure request.
    pin(store.count("DictationPolishInstructions.request(operation, text: text)") == 1 and store.count('DictationPolishInstructions.request("rules")') == 1,
        "stdin only", "every call is built by DictationPolishInstructions.request")
    wiring = 'DictationPolishInstructionsStore.shared.bridge = { [weak model] request in'
    pin(app.count(wiring) == 1 and app.count('return try await model.runHelper(["dictation-polish-instructions"], timeout: 20, stdinData: request)') == 1,
        "helper wiring", "the app hands the store the helper verb, the request on stdin")
    pin(helper.count('case "dictation-polish-instructions": try emitDictationPolishInstructions()') == 1, "helper verb", "the helper dispatches the verb")
    # 6. get asks the capability first, and never the setting on a server without it.
    adv = "guard DictationPolishInstructionsBridge.advertised(health.body) else { answer = DictationPolishInstructionsBridge.unavailable(); break }"
    pin(verb.count(adv) == 1 and verb.index(adv) < verb.index("let response = request(route, token: token, timeout: 5)"), "capability first",
        "get reads the public capability before the setting")
    pin(verb.count('request(route, method: "PUT", token: token, body: DictationPolishInstructionsBridge.body(text), timeout: 10)') == 1
        and verb.count('request(route, method: "DELETE", token: token, timeout: 10)') == 1, "routes", "set is a PUT of the words, clear a DELETE")
    pin("print(" not in verb and "dictationLog" not in verb and "NSLog" not in verb, "never logged", "the verb writes only its JSON answer")
    # 7. The timing line learns whether they went, by hash.
    pin(polish.count('instructions = DictationPolishInstructions.used(flag: response.details["customInstructions"]?.bool,') == 1
        and polish.count("customInstructions: instructions.on, instructionsHash: instructions.hash)") == 1, "timing",
        "polish() reads the finalize flag and hash into the run the timing line writes")
    # 8. Plain copy in the card.
    for mark in ["—", "→", "->"]:
        pin(mark not in card, "copy", f"no {mark!r} in the card")


MUTANTS = [
    ("card not placed", "d", "                DictationPolishInstructionsCard(store: DictationPolishInstructionsStore.shared, polishOn: store.polishModel != .off)\n", ""),
    ("card shown on an older server", "d", "if DictationPolishInstructions.visible(available: store.available) {", "if true {"),
    ("store starts visible", "d", "@Published private(set) var available = false", "@Published private(set) var available = true"),
    ("availability not read", "d", "            available = state.available\n", ""),
    ("no counter", "d", "Text(DictationPolishInstructions.counter(draft))", 'Text("")'),
    ("save always on", "d", ".disabled(!DictationPolishInstructions.canSave(draft: draft, saved: store.saved, busy: store.busy))", ".disabled(false)"),
    ("clear always on", "d", ".disabled(!DictationPolishInstructions.canClear(draft: draft, saved: store.saved, busy: store.busy))", ".disabled(false)"),
    ("placeholder over typed text", "d", "                        if draft.isEmpty {\n", "                        if true {\n"),
    ("rules never load", "d", "if open, store.rules == nil { Task { await store.loadRules() } }", "if open, store.rules == nil { }"),
    ("bridge not wired", "app", "        DictationPolishInstructionsStore.shared.bridge = { [weak model] request in", "        _ = { [weak model] (request: Data) in"),
    ("verb not dispatched", "helper", '        case "dictation-polish-instructions": try emitDictationPolishInstructions()\n', ""),
    ("setting asked without the capability", "helper",
     "            guard DictationPolishInstructionsBridge.advertised(health.body) else { answer = DictationPolishInstructionsBridge.unavailable(); break }\n", ""),
    ("set not a PUT", "helper", 'request(route, method: "PUT", token: token, body: DictationPolishInstructionsBridge.body(text), timeout: 10)',
     'request(route, method: "POST", token: token, body: DictationPolishInstructionsBridge.body(text), timeout: 10)'),
    ("timing never learns", "d", "                                  customInstructions: instructions.on, instructionsHash: instructions.hash)", "                                  customInstructions: false, instructionsHash: nil)"),
    ("an em dash in the card", "d", 'Text("Your instructions go after the rules, in this block:")', 'Text("Your instructions go after the rules — in this block:")'),
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
print(f"PASS polish instructions pins: placement under AI polish, hidden on an older server, counter, Save and Clear, rules on open, "
      f"stdin only, capability first, routes, timing; {caught} of {len(MUTANTS)} in-memory mutants caught")
