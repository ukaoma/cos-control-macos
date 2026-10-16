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
    # Block comments first (0.5.310 QA: a /* */ quoting a pinned line satisfied the pin), newlines kept.
    src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
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

# ── 2. Delivery (0.5.310, clipboard 0.5.312): MEASURED. ✓ only for a measured change (Miles 20:07, iTerm2).
deliver = body(dictation, "static func deliver(_ raw: String, restoreClipboard: Bool) async -> DictationDeliveryOutcome {")
# 0.5.312 (Miles 21:23): the clipboard is written only for a posted ⌘V (then restored) or for the card. Accessibility
# insertion never touches it.
ax_at = deliver.index("if route == .accessibility, let target {")
write_at = deliver.index("guard board.writeTranscript(text, markerTypes: DictationClipboard.transientTypes) else { return done(.refused(.clipboardFailed)) }")
need(write_at > ax_at and deliver.count("board.writeTranscript(") == 2 and "NSPasteboard.general.setString" not in deliver
     and "clearContents" not in deliver, "the transcript is written after the Accessibility attempt, only for ⌘V or the card")
need(deliver.index("let saved = DictationClipboard.snapshot(board)") < write_at, "the clipboard is snapshotted before COS writes")
done_fn = deliver[:deliver.index("let ms = Int(")]
need("if DictationClipboard.use(for: outcome) == .keepForCard, !wroteTranscript, outcome != .refused(.clipboardChanged) {" in done_fn
     and "board.writeTranscript(text, markerTypes: [])" in done_fn, "a card keeps the transcript on the clipboard")
need("let changeCount = board.changeCount" in deliver and "await paste(changeCount: changeCount)" in deliver,
     "⌘V must re-check that the clipboard still holds COS's text")
restore = deliver[deliver.index("let postedAt = Date()"):]
need("DictationClipboard.keepWaiting(elapsedMilliseconds:" in restore and "DictationClipboard.decision(enabled: restoreClipboard, pasted: true, snapshot: saved, setChangeCount: changeCount," in restore
     and "currentChangeCount: board.changeCount" in restore and "DictationClipboard.restore($0, to: board)" in restore,
     "after the ⌘V the clipboard is put back only by the tested decision")
need('dictationLog.notice("clipboard not restored: \\(reason, privacy: .public)")' in restore, "every skip is logged with its reason")
need("deliver(text, restoreClipboard: restoreClipboard)" in dictation and 'forKey: "dictation.restoreClipboard") as? Bool ?? true' in dictation
     and 'Toggle("Restore my clipboard after pasting", isOn: $store.restoreClipboard)' in dictation, "the setting is on by default and reaches delivery")
need("DictationInsertPolicy.refusal(" in deliver and "DictationDelivery.decide(" in deliver and "DictationDelivery.route(" in deliver,
     "delivery goes through the tested policy, route and decision")
need("IsSecureEventInputEnabled()" in deliver and "kAXSubroleAttribute" in deliver and "AXIsProcessTrusted()" in deliver,
     "secure input, the secure-field subrole and trust must all feed the policy")
need("NSApp.keyWindow is PetPanel" in deliver and "NSApp.keyWindow is DictationOverlayPanel" in deliver,
     "COS's own pet and dictation panels must never be an insertion target")
need("NSWorkspace.shared.frontmostApplication" in deliver and "capture()" not in dictation,
     "the target is the app focused when transcription FINISHES, not one captured at start")
need(deliver.count("AXUIElementSetMessagingTimeout(") == 2 and "0.25" in deliver, "AX calls are bounded at 0.25 s on the app and the element")
need("KnownApps.isTerminal(bundle)" in deliver and "DictationDelivery.terminalText(raw)" in deliver, "terminals get ⌘V and no line breaks")
need('"AXManualAccessibility" as CFString, kCFBooleanTrue' in deliver and "isChromiumFamily(app)" in deliver,
     "Electron/Chromium get their accessibility tree switched on before refusing")
need("for (index, ms) in DictationDelivery.pollMilliseconds.enumerated()" in deliver and "try? await Task.sleep(for: .milliseconds(ms - elapsed))" in deliver,
     "the AX result is polled asynchronously, never spun on the main thread")
need("let beforePaste = snapshot(target)" in deliver and "pasted: true, afterPaste: after" in deliver, "a ⌘V is measured too")
after_paste = deliver[deliver.index("let beforePaste = snapshot(target)"):]
need("if case .done(.inserted) = decision { break }" in after_paste and after_paste.count("await paste(") == 1 and "PRESS ⌘V" not in dictation + core,
     "after ⌘V COS only watches: one paste, and never a press-⌘V card (double paste)")
need("dictationLog.notice(\"delivery \\(facts, privacy: .public)" in deliver, "every delivery leaves one durable log line")
snap = body(dictation, "nonisolated private static func snapshot(_ element: AXUIElement?) -> DictationFieldSnapshot {")
need("kAXNumberOfCharactersAttribute" in snap and "kAXSelectedTextRangeAttribute" in snap and "kAXValueAttribute" not in snap,
     "the field is measured by counts only; its text (AXValue) is never read")
need("kAXValueAttribute" not in dictation.replace("isSettable(element, kAXValueAttribute)", ""), "AXValue is only ever asked whether it is settable")
settable = body(dictation, "nonisolated private static func textSettable(_ element: AXUIElement) -> Bool {")
need("kAXSelectedTextAttribute" in settable and "kAXValueAttribute" in settable, "a role alone is not a text box")
paste = body(dictation, "private static func paste(changeCount: Int) async -> DictationInsertPolicy.Refusal? {")
need("DictationDelivery.modifiersHeld(isDown: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) })" in paste and "flagsState" not in paste and "return .keysHeld" in paste
     and "NSPasteboard.general.changeCount == changeCount" in paste and "CGKeyCode(vKeyCode())" in paste,
     "⌘V waits for released modifiers, refuses a changed clipboard, and uses the layout's V")
need(re.findall(r"virtualKey: (\w+)", dictation) == ["key", "key"] and "kVK_Return" not in dictation
     and "kVK_ANSI_KeypadEnter" not in dictation and "virtualKey: 36" not in dictation,
     "the only key COS may post is ⌘V; it never presses Return or Send")
need("UCKeyTranslate(" in dictation and "DictationDelivery.keyCode(for: \"v\")" in dictation, "V is found on the current layout")
own_window = body(dictation, "private static func ownWindow(_ text: String, app: String) -> DictationDeliveryOutcome {")
need("NSApp.keyWindow?.firstResponder" in own_window and "insertText(" in own_window and "NSSecureTextField" in own_window,
     "COS's own windows insert through their first responder, never AX on this process")
need("mayInsert" not in core, "the old same-field-and-caret rule is gone; one insertion rule, not two")
models = (root / "Sources/Models.swift").read_text(encoding="utf-8")
hosts = re.search(r"static let terminalHostBundleIds: Set<String> = \[(.*?)\]", models, re.S)
terminals = re.search(r"static let terminals: Set<String> = \[(.*?)\]", core, re.S)
need(hosts is not None and terminals is not None and set(re.findall(r'"([^"]+)"', hosts.group(1))) <= set(re.findall(r'"([^"]+)"', terminals.group(1))),
     "every terminal the session jump knows must also get ⌘V (KnownApps.terminals)")

# ── 3. Store flow: the pill, the flash, the card; text stays private.
transcribe = body(dictation, "private func transcribe(_ wav: Data, attempt: UUID) {")
need("let outcome = await DictationInsertion.deliver(text, restoreClipboard: restoreClipboard)" in transcribe and "finish(text, outcome: outcome)" in transcribe,
     "a finished transcript must be delivered and recorded")
finish = body(dictation, "private func finish(_ text: String, outcome: DictationDeliveryOutcome) {")
need("remember(record)" in finish and "showCard(" in finish and "DictationPill.flashSeconds" in finish
     and "delivery: outcome.delivery" in finish and "outcome.flash" in finish,
     "finish must record the honest outcome, flash only what the outcome allows, and card when refused")
need('let noSpeech = response.details["noSpeech"]?.bool == true' in transcribe and "fail(response.message, retry: !noSpeech)" in transcribe,
     "no speech offers no Retry")
card = body(dictation, "struct DictationCardView: View {")
need('Button("Allow…") { store.requestInsertionPermission() }' in card and "if refusal == .notTrusted {" in card,
     "the Accessibility card carries Allow…")
need('Button("Open Settings") { store.openMicrophoneSettings() }' in card and "} else if retry, store.canRetry {" in card,
     "the microphone card opens Settings; Retry only when worth it")
need("loadOrQuarantine(from: $0, now: Date())" in dictation and "historyURL = loaded?.writable == false ? nil : history" in dictation,
     "an unreadable history is moved aside, and never overwritten when it could not be")
need("func deleteRecord(_ id: UUID)" in dictation and "func clearRecent()" in dictation
     and 'Button("Clear recent dictations' in dictation and "onDelete: { dictation.deleteRecord(record.id) }" in pet,
     "dictations can be deleted one at a time on the pet and all at once in Settings")
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
    need(not re.search(r"\\\((?:text|raw|record|transcript|heard|written|fixDraft|card)\b", log),
         "a dictation log line interpolates dictated text; it is private")
need("completeFileProtectionUnlessOpen" not in dictation + core and ".completeUnlessOpen" not in dictation + core,
     "class-B protection locks minutes after the screen does; history must stay class C")
need('"Library/Application Support/COS Control/dictation-history.json"' in dictation
     and "static let limit = 50" in core and "posixPermissions: 0o600" in core and "rename(temp.path, url.path)" in core,
     "Recent dictations: last 50, private 0600 file, written by rename")
meter = body(dictation, "    func start() {")
need("let rms = next.level" in meter and "meter.push(levelMeter.update(rms: rms))" in meter and "DictationBars.heights(levels)" in dictation and ".milliseconds(50)" in meter,
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
need("missionRow(" not in lst and "petSections(" not in lst, "Recent dictations shows dictations only, no RUNNING sessions under it (Miles 2026-10-15)")
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
emit_dictionary = body(helper, "private func emitDictionary(token: String, ok: Bool, message: String, unchanged: Bool = false) {")
paths = set(re.findall(r'"(/api/[^"?]*)', verb + emit_dictionary))
need(paths == {"/api/transcription-glossary", "/api/transcription-glossary/correction", "/api/transcription-glossary/correction/undo",
               "/api/transcription-glossary/recent", "/api/transcription-glossary/vocabulary/add", "/api/transcription-glossary/vocabulary/remove",
               "/api/transcription-glossary/correction/remove"}, f"the dictionary verb reaches only the glossary routes, got {sorted(paths)}")
# 0.5.310: single items go to the server's atomic routes. The ONE whole-dictionary write left is the hand-added
# correction on a server older than 6.73.11, so a Fix a word can never be lost to a read-then-write.
need(verb.count("put([") == 1 and 'if response?.status == 404, source == "manual" {' in verb,
     "the only PUT is the old-server fallback for a hand-added correction")
need("value.utf16.count <= Self.dictionaryMaxTermUTF16" in verb and "value.count <=" not in verb,
     "the helper counts UTF-16 units, as the server's MAX_TERM_LEN does")
need('if ok { emit(ok: true, message: message, details: ["stale": true, "unchanged": unchanged]) }' in emit_dictionary,
     "a change that worked stays a success when the read-back fails")
need('details: ["noSpeech": true]' in body(helper, "private func emitMacDictation() throws {"), "the helper marks no speech")
need('model.runHelper(["transcription-dictionary"], timeout: 20, stdinData: request)' in app,
     "Control must send the request as stdinData with an argument list of exactly the verb")

print(f"PASS dictation-wispr pins: {checks} checks; HUD gone, copy-then-insert-at-focus, private history, overlay focus, pet slot and lists, Dictionary route, helper stdin")
