#!/usr/bin/env python3
"""0.5.309 Wispr-style dictation: wiring pins the executable checks cannot see.

Text only (no compile). Every assertion reads COMMENT-STRIPPED code, so a comment naming a symbol can neither satisfy
nor trip it. Tests/MacDictationChecks.swift executes the pure rules (insert-target policy, meter, history, countdown,
fix-a-word selection); this pins that the app actually routes through them, and the approved mock's shape (moments
01-07, Miles picked A/A/A on 2026-10-15).
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
checks = 0


def strip_comments(src: str) -> str:
    out = []
    for line in src.splitlines():
        cut, quoted, i = None, False, 0
        while i < len(line) - 1:
            ch = line[i]
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                quoted = not quoted
            elif ch == "/" and line[i + 1] == "/" and not quoted:
                cut = i
                break
            i += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


def read(name: str) -> str:
    return strip_comments((root / name).read_text(encoding="utf-8"))


def need(condition: bool, message: str) -> None:
    global checks
    if not condition:
        sys.exit(f"dictation-wispr: {message}")
    checks += 1


def body(src: str, opener: str) -> str:
    """From `opener` to the close of its brace block."""
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


dictation = read("Sources/MacDictation.swift")
core = read("Sources/MacDictationCore.swift")
pet = read("Sources/SessionPet.swift")
model = read("Sources/ControllerModel.swift")
activity = read("Sources/ActivityWindow.swift")
meetings = read("Sources/ActivityMeetings.swift")
app = read("Sources/COSControlApp.swift")
helper = read("HelperSources/main.swift")

# ── 1. The persistent "COS Dictation" window is gone (Miles: "we don't want the COS dictation to be persistent").
need('"COS Dictation"' not in dictation and "DictationHUD" not in dictation and "showHUD" not in dictation,
     "the persistent COS Dictation panel came back")
need("styleMask: [.borderless, .nonactivatingPanel]" in dictation and ".titled" not in dictation,
     "the only dictation window is the borderless nonactivating overlay")

# ── 2. Delivery: always copied, then the focused text box NOW, through the tested policy. Never Return.
deliver = body(dictation, "static func deliver(_ text: String) -> Outcome {")
copy_at = deliver.find("NSPasteboard.general.setString(text, forType: .string)")
refuse_at = deliver.find("if let refusal { return .refused(refusal) }")
need(copy_at >= 0 and refuse_at > copy_at, "the text must be on the clipboard BEFORE any refusal returns")
need(deliver.count("NSPasteboard.general") == 2, "deliver must set the clipboard once and never restore it")
need("DictationInsertPolicy.refusal(" in deliver, "insertion no longer goes through the tested DictationInsertPolicy")
need("IsSecureEventInputEnabled()" in deliver and "kAXSubroleAttribute" in deliver and "AXIsProcessTrusted()" in deliver,
     "secure input, the secure-field subrole and trust must all feed the policy")
need("NSApp.keyWindow is PetPanel" in deliver and "NSApp.keyWindow is DictationOverlayPanel" in deliver,
     "COS's own pet and dictation panels must never be an insertion target")
need("NSWorkspace.shared.frontmostApplication" in deliver and "capture()" not in dictation,
     "the target is the app focused when transcription FINISHES, not one captured at start")
need(re.findall(r"virtualKey: (\d+)", dictation) == ["9", "9"] and "kVK_Return" not in dictation
     and "kVK_ANSI_KeypadEnter" not in dictation,
     "the only key COS may post is ⌘V; it never presses Return or Send")
need("mayInsert" not in core, "the old same-field-and-caret rule is gone; one insertion rule, not two")

# ── 3. Store flow: the pill, the flash, the card; text stays private.
transcribe = body(dictation, "private func transcribe(_ wav: Data, attempt: UUID) {")
need("finish(text, outcome: DictationInsertion.deliver(text))" in transcribe,
     "a finished transcript must be delivered and recorded")
finish = body(dictation, "private func finish(_ text: String, outcome: DictationInsertion.Outcome) {")
need("remember(record)" in finish and "showCard(" in finish and "DictationPill.flashSeconds" in finish,
     "finish must record every dictation, flash when inserted and card when refused")
need("pill = .transcribing" in body(dictation, "    func stop() {"), "release must show TRANSCRIBING")
need("pill = .listening(since: Date())" in body(dictation, "    func start() {"), "the shortcut must show the listening pill")
need("surface = petFrame?() != nil ? .pet : .floating" in body(dictation, "    func start() {"),
     "with the pet hidden the pill must float above the Dock")
for field in ("pill", "surface", "card", "recent", "listRoute", "fixSelection", "fixNote", "fixSaving"):
    decl = re.search(rf"@Published private\(set\) var {field}\b[^\n]*", dictation)
    need(decl is not None, f"{field} is not a published, store-owned field")
    rest = dictation.replace(decl.group(0), "")
    need(len(re.findall(rf"(?<![\w.]){field}\s*=(?!=)", rest)) >= 1, f"{field} has no writer: a field nobody assigns is a feature that does not exist")
for log in re.findall(r"dictationLog\.\w+\(([^\n]*)\)", dictation):
    need(not re.search(r"\\\((?:text|record|transcript|heard|written|fixDraft|card)\b", log),
         "a dictation log line interpolates dictated text; it is private")
need("completeFileProtectionUnlessOpen" not in dictation + core and ".completeUnlessOpen" not in dictation + core,
     "class-B protection locks minutes after the screen does; history must stay class C")
need('"Library/Application Support/COS Control/dictation-history.json"' in dictation
     and "static let limit = 50" in core and "posixPermissions: 0o600" in core and "rename(temp.path, url.path)" in core,
     "Recent dictations: last 50, private 0600 file, written by rename")
meter = body(dictation, "    func start() {")
need("meter.push(levelMeter.update(rms: next.level))" in meter and ".milliseconds(50)" in meter,
     "the bars must go through the tested dB meter at its tuned 50 ms tick")
need("let meter = DictationMeterFeed()" in dictation, "levels must live in their own object so the pet never redraws at 20 Hz")

# ── 4. The overlay (pet hidden): never takes focus by showing.
overlay = body(dictation, "@MainActor final class DictationOverlayPresenter {")
need("panel.ignoresMouseEvents = store.card == nil && !fixing" in overlay, "the bare pill must ignore clicks")
need("panel.allowsKey = fixing" in overlay and "override var canBecomeKey: Bool { allowsKey }" in dictation,
     "the overlay may take the keyboard only for Fix a word")
need("if fixing { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }" in overlay,
     "showing the pill or card must never make the overlay key")
need("screen.minY + 8" in overlay and "screen.midX - size.width / 2" in overlay, "bottom center, above the Dock")
sinks = re.findall(r"\.sink \{ \[weak self\] _ in Task \{ @MainActor in self\?\.sync\(\) \} \}", overlay)
need(len(sinks) == 5 and overlay.count(".sink") == 5,
     "every overlay sink hops to the main actor before reading the new state (reviewed 0.5.309); a new sink needs the same review")

# ── 5. The pet: the pill takes the ledger's slot, a DICTATED pill, the lists, the card.
slot = pet[pet.index("private var ledgerSlot"):pet.index("private func ledgerBar")]
need("let listening = dictation.surface == .pet && dictation.pill.replacesLedger" in slot,
     "the listening pill must key on the pill state and the pet surface")
need(".opacity(showPills || listening ? 0 : 1)" in slot and ".opacity(showPills && !listening ? 1 : 0)" in slot
     and ".allowsHitTesting(showPills && !listening)" in slot,
     "while listening the bar and the pills must both give the slot up, and hand it back after (Miles picked A)")
need("DictationListeningPill(pill: dictation.pill, meter: dictation.meter, floating: false" in slot,
     "the pet's slot must mount the inline listening pill")
pills = pet[pet.index("private func pillsRow("):pet.index("private func ledgerPill(")]
dictated = pills[pills.index('label: "DICTATED"') - 400:]
need("if !dictation.recent.isEmpty {" in dictated and "dictation.toggleRecent()" in dictated and "COSPalette.gold" in dictated,
     "the DICTATED pill (gold) shows only once something was dictated, and opens Recent dictations")
need("dictation.recent.isEmpty" in pet[pet.index("private var revealArmed"):pet.index("private var showPills")],
     "a pet whose only history is dictations must still reveal its pills")
root_body = pet[pet.index("var body: some View"):pet.index("private var ledgerSlot")]
need("dictationList(route)" in root_body and "if dictation.surface == .pet, let card = dictation.card {" in root_body,
     "Recent dictations and the no-text-box card must mount above the figure")
lst = body(pet, "func dictationList(_ route: DictationListRoute) -> some View {")
need("ScrollView" in lst and ".frame(height: size.length(176))" in lst and "maxHeight" not in lst,
     "the dictations list must scroll in a FIXED frame; maxHeight collapses under sizeThatFits")
need("DictationFixEditor(" in lst and "model.openDictionaryInActivity()" in lst, "Fix a word and its doorway to the Dictionary pane")
need("missionRow(session, tint: COSPalette.green)" in lst, "the RUNNING section sits under Recent dictations, as in the mock")
route_changed = body(pet, "private func dictationRouteChanged() {")
need("panel.makeKeyAndOrderFront(nil)" in route_changed and "panel.orderFrontRegardless()" in route_changed,
     "Fix a word's field must take the keyboard on the pet and give it back")
need("model?.dictation.listRoute != nil" in pet[pet.index("private func syncLists()"):pet.index("private func syncOutsideClickMonitor")],
     "an outside click must be able to close the dictations list")
need("self?.model?.dictation.closeListOnOutsideClick()" in body(pet, "private func syncOutsideClickMonitor("),
     "the outside-click monitor must close the dictations list")
card = body(dictation, "struct DictationCardView: View {")
need(".background(HoverSensor { store.setCardHover($0) })" in card, "hover must pause the card's fold-away")
need('Button(copied ? "Copied" : "Copy")' in card and "DictationButtonStyle(primary: true" in card,
     "Copy is the card's primary button")

# ── 6. COS Activity → Meetings → Dictionary, on its own route flag (the 0.5.17 dead-button lesson).
need(re.search(r"else if section == \.meetings, model\.dictionaryRouteActive \{\s*TranscriptionDictionaryPane\(model: model\)", activity) is not None,
     "the Dictionary pane must sit on its own else-if whose condition is exactly model.dictionaryRouteActive")
route = re.search(r"var dictionaryRouteActive: Bool \{[^}]*\}", model, re.S)
need(route is not None and re.search(r"\bdictionaryOpen\b", route.group(0)) is not None,
     "dictionaryRouteActive must read dictionaryOpen, the var its opener writes")
opener = body(model, "func openDictionary() {")
need(re.search(r"\bdictionaryOpen = true\b", opener) is not None and "meetingImportOpen = false" in opener
     and "meetingSuggestionsOpen = false" in opener and "closeLibraryDetail()" in opener and "dictionary.load()" in opener,
     "openDictionary must set its flag, close the other panes and the detail, and fire the load")
for other, closes in (("func openMeetingImport() {", "dictionaryOpen = false"), ("func openMeetingSuggestions() {", "dictionaryOpen = false"),
                      ("func openLiveTranscript(_ sessionId: String) {", "closeDictionary()")):
    need(closes in body(model, other), f"{other} must close the Dictionary pane, or two panes claim the route")
need('Button("Dictionary") { model.openDictionary() }' in body(meetings, "private var toolbar: some View {"),
     "Meetings must carry the Dictionary doorway")
need(re.search(r"section == \.meetings, model\.dictionaryRouteActive \{\s*model\.closeDictionary\(\)", body(activity, "private func goBack() {")) is not None,
     "Back must leave the Dictionary pane")
need("model.liveTranscriptRouteActive || model.dictionaryRouteActive" in activity, "hasDetail must count the Dictionary pane")
launch = body(activity, "private func applyLaunchSection() {")
need(launch.index("if let next { select(next) }") < launch.index("if openDictionary, section == .meetings { model.openDictionary() }"),
     "the pet's Dictionary… opens the pane AFTER the section is selected, or select's reset hides it")
need("activityOpenDictionary = true" in body(model, "func openDictionaryInActivity() {"), "the pet's doorway must set the launch flag")

# ── 7. The helper verb: words on stdin, fixed routes only.
need('case "transcription-dictionary": try emitTranscriptionDictionary()' in helper, "the helper verb is not dispatched")
verb = body(helper, "private func emitTranscriptionDictionary() throws {")
need("FileHandle.standardInput" in verb and 'option("--' not in verb and "args" not in verb,
     "dictionary words ride on stdin; a word in argv is published to every process on this Mac")
paths = set(re.findall(r'"(/api/[^"?]*)', verb + body(helper, "private func emitDictionary(token: String, ok: Bool, message: String) {")))
need(paths == {"/api/transcription-glossary", "/api/transcription-glossary/correction", "/api/transcription-glossary/correction/undo",
               "/api/transcription-glossary/recent"}, f"the dictionary verb reaches only the glossary routes, got {sorted(paths)}")
need('model.runHelper(["transcription-dictionary"], timeout: 20, stdinData: request)' in app,
     "Control must send the request as stdinData with an argument list of exactly the verb")

print(f"PASS dictation-wispr pins: {checks} checks; HUD gone, copy-then-insert-at-focus, private history, overlay focus, pet slot and lists, Dictionary route, helper stdin")
