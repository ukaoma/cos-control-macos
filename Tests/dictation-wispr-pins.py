#!/usr/bin/env python3
"""0.5.309 Wispr-style dictation: wiring pins the executable checks cannot see.

Text only (no compile). Every assertion reads COMMENT-STRIPPED code, so a comment naming a symbol can neither satisfy
nor trip it. Tests/MacDictationChecks.swift executes the pure rules (insert-target policy, meter, history, countdown,
fix-a-word selection); this pins that the app actually routes through them, and the approved mock's shape (moments
01-07, Miles picked A/A/A on 2026-10-15).
"""
import hashlib
import json
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
deliver = body(dictation, "static func deliver(_ raw: String, restoreClipboard: Bool, fieldContext: Bool = false) async -> DictationDelivered {")
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
need("deliver(text, restoreClipboard: restoreClipboard, fieldContext: useFieldContext)" in dictation and 'forKey: "dictation.restoreClipboard") as? Bool ?? true' in dictation
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
need(dictation.count("private static func paste(changeCount: Int, recheck: () -> DictationPolishSwap.Skip? = { nil }) async -> PasteStop? {") == 1, "one ⌘V function")
paste = body(dictation, ") async -> PasteStop? {")  # after the default closure's own braces
need("DictationDelivery.modifiersHeld(isDown: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) })" in paste and "flagsState" not in paste and "return .refused(.keysHeld)" in paste
     and "NSPasteboard.general.changeCount == changeCount" in paste and "CGKeyCode(vKeyCode())" in paste,
     "⌘V waits for released modifiers, refuses a changed clipboard, and uses the layout's V")
# 0.5.332: the re-proof runs last, after the held-key wait and the clipboard check, immediately before the key is made.
need(paste.index("return .refused(.clipboardChanged)") < paste.index("if let moved = recheck() { return .moved(moved) }") < paste.index("let key = CGKeyCode(vKeyCode())"),
     "an automatic swap's re-proof runs immediately before the ⌘V is posted")
need(re.findall(r"virtualKey: (\w+)", dictation) == ["key", "key"] and "kVK_Return" not in dictation
     and "kVK_ANSI_KeypadEnter" not in dictation and "virtualKey: 36" not in dictation,
     "the only key COS may post is ⌘V; it never presses Return or Send")
need("UCKeyTranslate(" in dictation and "DictationDelivery.keyCode(for: \"v\")" in dictation, "V is found on the current layout")
own_window = body(dictation, "private static func ownWindow(_ text: String, app: String) -> (DictationDeliveryOutcome, DictationOwnTarget?) {")
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
need("let delivered = copyOnly ? DictationInsertion.copyOnly(text, clipboardMoved: clipboardMoved)\n                    : await DictationInsertion.deliver(text, restoreClipboard: restoreClipboard, fieldContext: useFieldContext)" in transcribe
     and "finish(delivered.context?.text ?? text, outcome: delivered.outcome, target: delivered.target, context: delivered.context, own: delivered.own)" in transcribe,
     "a finished transcript must be delivered and recorded")
# 0.5.313 (Miles 2026-10-15): an interrupted dictation is transcribed and copied, never thrown away and never typed.
need("let copyOnly = pendingInterrupted\n                let clipboardMoved = interruptedChangeCount.map { $0 != NSPasteboard.general.changeCount } ?? false\n                pendingAudio = nil" in transcribe,
     "the copy-only flag and the interrupt's clipboard stamp must be read before pendingAudio is cleared (clearing it resets both)")
need("if pointer, held { pointerDuringHold = true }" in body(dictation, "    private func keyEvent(")
     and "card: !(noSpeech && pointerDuringHold), action: action); return" in transcribe
     and 'phase = "Starting"; pointerDuringHold = false' in dictation,
     "a slow modifier-click with no speech ends quietly, and the flag resets each dictation (QA 2026-10-15)")
need("quiet.end()" in body(dictation, "    func recordingStarted() {") and "if count > 0, lastRecordingCount == 0 { dictation.recordingStarted() }" in model
     and "didSet { recordingCountChanged(); statusDetailsBytes = nil }" in model and "self.recordingCountChanged()" in model
     and "model.dictation.macRecordingActive = { [weak model] in (model?.recordingCount ?? 0) > 0 }" in app,
     "a recording (Mac or glasses) that starts mid-dictation restores other apps' sound, and any live COS recording counts (QA 2026-10-15)")
interrupt = body(dictation, "    func interrupt() {")
need("MacDictationPolicy.salvages(pcmBytes: pcm.count)" in interrupt and "pendingAudio = wav; pendingInterrupted = true" in interrupt
     and "transcribe(wav, attempt: attempt)" in interrupt and "quiet.end()" in interrupt,
     "interrupt must transcribe a salvageable capture as copy-only and give other apps their sound back")
need('if phase == "Transcribing" {\n            pendingInterrupted = pendingAudio != nil\n' in interrupt
     and "            if pendingInterrupted { interruptedChangeCount = NSPasteboard.general.changeCount }\n            return\n        }" in interrupt,
     "sleep while transcribing must copy, not type after wake")
key = body(dictation, "    private func keyEvent(")
need("case .chord?: if held { recordPressEvent(.interruptedChord); if fnConflictNow { fnCardPending = true }; interrupt() }" in key and "cancel()" not in key, "a chord while talking must salvage, not cancel")
need(dictation.count("Task { @MainActor in self?.interrupt() }") == 1 and "Task { @MainActor in self?.cancel() }" not in dictation,
     "sleep and session switch must salvage, not cancel")
copy_only = body(dictation, "    static func copyOnly(_ text: String, clipboardMoved: Bool) -> DictationDelivered {")
need("writeTranscript(text, markerTypes: [])" in copy_only and ".refused(wrote ? .interrupted : .clipboardFailed)" in copy_only
     and "AXUIElement" not in copy_only and "postPaste" not in copy_only and "CGEvent" not in copy_only,
     "copy-only writes a durable clipboard item and never types or pastes")
finish = body(dictation, "private func finish(_ text: String, outcome: DictationDeliveryOutcome, target: DictationInsertTarget?, context: DictationFieldContext.Applied? = nil,\n                        swapPending: Bool = false, own: DictationOwnTarget? = nil) -> UUID {")
need("remember(record)" in finish and "showCard(" in finish and "DictationPill.flashSeconds" in finish
     and "delivery: outcome.delivery" in finish and "outcome.flash" in finish,
     "finish must record the honest outcome, flash only what the outcome allows, and card when refused")
# 0.5.317: the card's one action comes from DictationFailureAction.resolve, which offers nothing for no speech
# (MacDictationChecks "no speech offers nothing").
need('let noSpeech = response.details["noSpeech"]?.bool == true' in transcribe
     and 'retryable: response.details["retryable"]?.bool,\n                                                                noSpeech: noSpeech, audioHeld: pendingAudio != nil)' in transcribe,
     "no speech offers no Retry")
card = body(dictation, "struct DictationCardView: View {")
need('Button("Allow…") { store.requestInsertionPermission() }' in card and "if refusal == .notTrusted {" in card,
     "the Accessibility card carries Allow…")
need('fail("Allow Microphone for COS Control in System Settings → Privacy & Security.", code: DictationFailReason.microphoneDenied.code(), action: .openMicrophoneSettings)' in dictation
     and "if let title = action.title, action != .retry || store.canRetry {" in card and "store.performFailureAction(action)" in card
     and "case .openMicrophoneSettings: openMicrophoneSettings()" in dictation,
     "the microphone card opens Settings; Retry only when worth it")
need("loadOrQuarantine(from: $0, now: Date())" in dictation and "historyURL = loaded?.writable == false ? nil : history" in dictation,
     "an unreadable history is moved aside, and never overwritten when it could not be")
need("func deleteRecord(_ id: UUID)" in dictation and "func clearRecent()" in dictation
     and "onDelete: { dictation.deleteRecord(record.id) }" in pet,
     "dictations can be deleted one at a time on the pet")
# 0.5.312: history is cleared only through a confirm, in Settings and in the history pane. Every UI call of
# clearRecent / stopKeepingHistory sits inside a .destructive confirm action (the store calls itself are not UI).
ui = dictation[dictation.index("struct MacDictationSettings: View {"):]
for call in ("store.clearRecent()", "store.stopKeepingHistory()"):
    hits = [m.start() for m in re.finditer(re.escape(call), ui)]
    need(hits and all(re.search(r'\.destructive\("[^"]+"\) \{ $', ui[ui.rfind("\n", 0, h) + 1:h]) for h in hits),
         f"{call} runs only from a confirm's destructive action, never straight off a button")
settings = body(dictation, "struct MacDictationSettings: View {")
need('Button("Clear dictation history") { confirmingClear = true }' in settings and "isPresented: $confirmingClear," in settings,
     "Settings → Clear dictation history asks first")
need('COSDropdown("Keep dictations for", selection: retentionChoice,' in settings
     and "if next.writesToDisk { store.setRetention(next) } else if store.retention.writesToDisk { confirmingDontKeep = true }" in settings
     and "isPresented: $confirmingDontKeep," in settings,
     "Keep dictations for: Don't keep goes through a confirm; the others apply at once")
need('DictationRetention(rawValue: d.string(forKey: "dictation.history.retention") ?? "") ?? .default' in dictation
     and "static let `default` = DictationRetention.month" in core,
     "retention defaults to 30 days when nothing (or something unreadable) is stored")
need("DictationHistory.pruned(loaded?.records ?? [], retention: keep, now: Date())" in dictation
     and "recent = keep.writesToDisk ? kept : []" in dictation,
     "launch prunes the loaded history (and migrates 0.5.309-0.5.311 files) under the retention")
need("DictationHistory.adding(record, to: recent, retention: retention, now: Date())" in dictation,
     "each save prunes under the retention")
save = body(dictation, "    private func saveRecent() {")
need(save.index("guard retention.writesToDisk else {") < save.index("DictationHistory.save(recent, to: historyURL)")
     and "removeItem(at: historyURL)" in save,
     "Don't keep writes nothing and removes the file")
# 0.5.326: the stop that closes the microphone (after the release tail) is closeMicrophone; stop() starts the tail.
need("pill = .transcribing" in body(dictation, "    private func closeMicrophone() {"), "release must show TRANSCRIBING")
need("pill = .listening(since: Date())" in body(dictation, "    func start() {"), "the shortcut must show the listening pill")
start_fn = body(dictation, "    func start() {")
# 0.5.328: the focused window is read off the main thread (Tests/dictation-smooth-pins.py); the rule is the same.
need("let placement = DictationPlacement.choose(petFrame: petNow, focusedWindow: window, screens: screens, mainScreen: mainScreen)" in start_fn
     and "if case .floating(let screen)? = placement { self.surface = .floating; self.floatingScreen = screen } else { self.surface = .pet; self.floatingScreen = nil }" in start_fn,
     "the pill goes on the pet only when the pet is on the focused screen; else on that screen (0.5.312)")
need("playSound(.start)" in start_fn and "playSound(.stop)" in body(dictation, "    private func closeMicrophone() {")
     and start_fn.index("pill = .listening(since: Date())") < start_fn.index("playSound(.start)"), "start and stop sounds")
stop_fn = body(dictation, "    private func closeMicrophone() {")
need(stop_fn.index("let pcm = try capture.stop()") < stop_fn.index("playSound(.stop)"), "the stop sound plays only after the microphone closed")
need("playSound(" not in body(dictation, "    func cancel() {"), "a cancel (a chord) is silent")
need('forKey: "dictation.sound.start") ?? "pet"' in dictation and 'forKey: "dictation.sound.stop") ?? "pet"' in dictation
     and 'forKey: "dictation.sound.volume") as? Double ?? DictationSoundLibrary.defaultVolume' in dictation and "static let defaultVolume = 0.6" in core,
     "sound defaults: the pet's sound for start and stop, volume 60%")
need("macRecording: macRecordingActive?() ?? false" in dictation and "model.dictation.macRecordingActive = { [weak model] in (model?.recordingCount ?? 0) > 0 }" in read("Sources/COSControlApp.swift"),
     "sounds and quiet know about any live COS recording (Mac or glasses)")
need('forKey: "dictation.sound.pitch") as? Double ?? 0' in dictation and "Slider(value: $store.soundPitch, in: DictationSoundLibrary.pitchRange, step: 1)" in dictation
     and "let player = soundPlayer, pitch = soundPitch" in dictation and "player.play(url, volume: volume, semitones: pitch)" in dictation
     and "AVAudioUnitTimePitch()" in dictation and "pitch.pitch = Float(DictationSoundLibrary.cents(semitones))" in dictation
     and "static let pitchRange = -12.0...6.0" in core, "Pitch: -12 to +6 st, default 0, applied at playback to every sound")
need("laptop speakers reproduce little of it" in dictation, "the caption says the saber is mostly bass")
need('"high-pass' not in (root / "scripts/render-dictation-sounds.py").read_text() and '"highpass"' not in (root / "scripts/render-dictation-sounds.py").read_text().split("def unstable_v2(")[1].split("def master(")[0].split("# sparse spits")[0],
     "v2's growl is never high-passed (only its spits are)")
need('Button("Preview") { store.previewSound(edge) }' in dictation and 'COSDropdownOption("import", "Your own file…")' in dictation
     and "Slider(value: $store.soundVolume, in: 0...1)" in dictation and "DictationSoundSettings(store: store)" in dictation, "Settings: choice, your own file, volume, preview")
save = body(dictation, "    func saveImport() {")
choose = body(dictation, "    func importCustomSound(_ edge: DictationSoundEdge) {")
need("attributes: [.posixPermissions: 0o600]" in save and "contents: pending.trimmedWAV" in save
     and "pending.window.length <= DictationSoundLibrary.maximumStoredSeconds" in save and "createFile" not in choose,
     "your own file: only the trimmed result is stored, 0600, and only on Save")
need("DictationSoundLibrary.customRefusal(byteCount: bytes, duration: duration)" in choose and "DictationSoundTrim.onset(levels)" in choose
     and "useEnd: edge == .stop" in choose, "the source is validated, measured, and Stop offers the end of the file")
need('Toggle("Use the end of this file"' in dictation and 'Button("Save") { store.saveImport() }' in dictation and "Text(pending.summary)" in dictation
     and 'Button("Preview") { store.previewImport() }' in dictation, "the resulting length and a Preview before saving")
ids = re.findall(r'\("([a-z0-9-]+)", "[^"]+"\)', core[core.index("static let sounds:"):core.index("static let defaultVolume")])
for sound_id in ids:
    for edge in ("start", "stop"):
        f = root / "Resources/Sounds" / f"{sound_id}-{edge}.wav"
        need(f.exists() and 1_000 < f.stat().st_size < 200_000, f"{f.name} is rendered and small")
# 0.5.315: Miles Windu saber is Miles's own design, bundled byte-identical to his saved custom sounds; every other
# library sound is rendered by the committed script.
recorded = {"windu-saber": {"start": "eb1f22a5ecc3d630c282d395318366a9074d54b5f779a4f871f8248ad31fed8f",
                            "stop": "47875897bc904fd27f7e529d4c05acd09e410d11634702ffc0f8ea935b91cdd9"}}
script = (root / "scripts/render-dictation-sounds.py").read_text(encoding="utf-8")
rendered = set(re.findall(r'^    "([a-z0-9-]+)": \(', script[script.index("SOUNDS = {"):], flags=re.M))
need(len(ids) == 9 and ids[0] == "windu-saber" and set(ids) == rendered | set(recorded) and not (rendered & set(recorded)),
     "every library sound is rendered by the committed script, except Miles's recorded saber, which is first")
for sound_id, edges in recorded.items():
    for edge, digest in edges.items():
        need(hashlib.sha256((root / "Resources/Sounds" / f"{sound_id}-{edge}.wav").read_bytes()).hexdigest() == digest,
             f"{sound_id}-{edge}.wav is Miles's file, byte for byte")
need('case .jedi: "windu-saber"' in core and 'static let winduPackID = "jedi-miles-windu"' in core
     and 'id: "jedi-miles-windu",' in read("Sources/Models.swift"), "the Windu pack id is the shipped one")
need("DictationSoundLibrary.installedPack(" in app and "PetSpriteStore.bundledCharacters.compactMap" in app and "model.dictation.petPack = {" in app
     and "pack: petPack?()" in dictation and dictation.count("petPack?()") == 2, "the app tells dictation which pack is installed, for both the sound and its name")
# The checks' pack file sets must be the shipped state maps', or the Windu test proves nothing about the real packs.
checks_src = read("Tests/MacDictationChecks.swift")
for folder, pack_id in (("DefaultPet", "jedi-miles-windu"), ("BundledCharacters/jedi-nia-solari", "jedi-nia-solari"),
                        ("BundledCharacters/jedi-elara-vale", "jedi-elara-vale"), ("BundledCharacters/jedi-rowan-vale", "jedi-rowan-vale")):
    shipped = sorted({v["file"] for v in json.loads((root / "Resources" / folder / "session-pet-states.json").read_text())["poses"].values()})
    need(f'(id: "{pack_id}", files: ["' + '", "'.join(shipped) + '"])' in checks_src, f"the checks list {pack_id}'s shipped pose files")
need('cp "$ROOT/Resources/Sounds/"*.wav "$APP/Contents/Resources/Sounds/"' in (root / "scripts/build-release.sh").read_text(), "the sounds ship in the app")
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
     and "static let cap = 5_000" in core and "posixPermissions: 0o600" in core and "rename(temp.path, url.path)" in core,
     "Dictation history: at most 5,000, private 0600 file, written by rename")
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
# 0.5.337: through DictationOverlayFrame.place (bottom centre with no caret, always inside the screen; Hardening337Checks).
need("DictationOverlayFrame.place(size: size, caret: nil, screen: screen)" in overlay and "store?.floatingScreen.flatMap" in overlay,
     "bottom center, above the Dock, on the chosen screen")
sinks = re.findall(r"\.sink \{ \[weak self\] _ in Task \{ @MainActor in self\?\.sync\(\) \} \}", overlay)
need(len(sinks) == 8 and overlay.count(".sink") == 8,
     "every overlay sink hops to the main actor before reading the new state (reviewed 0.5.309; 0.5.313 added fixOfferID and replaceOffer; 0.5.338 learnedUndoID); a new sink needs the same review")

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
dictated = pills[pills.index("label: DictationHistory.pillLabel") - 400:]
need("if !dictation.recent.isEmpty {" in dictated and "dictation.toggleRecent()" in dictated and "COSPalette.gold" in dictated,
     "the DICTATIONS pill (gold) shows only once something was dictated, and opens the latest dictations")
need("label: DictationHistory.pillLabel, count: nil," in dictated and "recent.count" not in dictated and '"DICTATED' not in pet,
     "the DICTATIONS pill never counts (Miles 21:40: a count can become arbitrarily large)")
need("dictation.recent.isEmpty" in pet[pet.index("private var revealArmed"):pet.index("private var showPills")],
     "a pet whose only history is dictations must still reveal its pills")
root_body = pet[pet.index("var body: some View"):pet.index("private var ledgerSlot")]
need("dictationList(route)" in root_body and "if dictation.surface == .pet, let card = dictation.card {" in root_body,
     "Recent dictations and the no-text-box card must mount above the figure")
lst = body(pet, "func dictationList(_ route: DictationListRoute) -> some View {")
need("ScrollView" in lst and ".frame(height: size.length(176))" in lst and "maxHeight" not in lst,
     "the dictations list must scroll in a FIXED frame; maxHeight collapses under sizeThatFits")
need("DictationFixEditor(" in lst and "model.openDictionaryInActivity()" in lst, "Fix a word and its doorway to the Dictionary pane")
rows = body(pet, "private var dictationRows: some View {")
need("dictationRows" in lst and "ForEach(dictation.petRecent)" in rows and "dictation.recent" not in lst + rows
     and "var petRecent: [DictationRecord] { Array(recent.prefix(DictationHistory.petCount)) }" in dictation,
     "the pet lists the latest 10, not the whole history")
need(re.search(r"dictation\.closeList\(\)\s*model\.openDictationHistoryInActivity\(\)", lst) is not None and '"All dictations"' in lst,
     "the pet list ends in All dictations, which opens the history pane")
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

# ── 6b. COS Activity → Meetings → Dictation history (0.5.312), the same route-flag shape.
need(re.search(r"else if section == \.meetings, model\.dictationHistoryRouteActive \{\s*DictationHistoryPane\(model: model\)", activity) is not None,
     "the history pane must sit on its own else-if whose condition is exactly model.dictationHistoryRouteActive")
route = re.search(r"var dictationHistoryRouteActive: Bool \{[^}]*\}", model, re.S)
need(route is not None and re.search(r"\bdictationHistoryOpen\b", route.group(0)) is not None,
     "dictationHistoryRouteActive must read dictationHistoryOpen, the var its opener writes")
opener = body(model, "func openDictationHistory() {")
need(re.search(r"\bdictationHistoryOpen = true\b", opener) is not None and "meetingImportOpen = false" in opener
     and "meetingSuggestionsOpen = false" in opener and "dictionaryOpen = false" in opener and "closeLibraryDetail()" in opener,
     "openDictationHistory must set its flag and close the other panes and the detail")
for other, closes in (("func openMeetingImport() {", "dictationHistoryOpen = false"), ("func openMeetingSuggestions() {", "dictationHistoryOpen = false"),
                      ("func openDictionary() {", "dictationHistoryOpen = false"), ("func openLiveTranscript(_ sessionId: String) {", "closeDictationHistory()")):
    need(closes in body(model, other), f"{other} must close the history pane, or two panes claim the route")
need(re.search(r"section == \.meetings, model\.dictationHistoryRouteActive \{\s*model\.closeDictationHistory\(\)", body(activity, "private func goBack() {")) is not None,
     "Back must leave the history pane")
need("model.dictionaryRouteActive || model.dictationHistoryRouteActive" in activity, "hasDetail must count the history pane")
need(launch.index("if let next { select(next) }") < launch.index("if openDictationHistory, section == .meetings { model.openDictationHistory() }"),
     "All dictations opens the pane AFTER the section is selected, or select's reset hides it")
need("activityOpenDictationHistory = true" in body(model, "func openDictationHistoryInActivity() {"), "the history doorway must set the launch flag")
need('Button("History") { model.openDictationHistory() }' in body(dictation, "struct TranscriptionDictionaryPane: View {"),
     "the Dictionary pane header carries History")
need('Button("History…") { model.openDictationHistoryInActivity() }' in app, "the Dictation menu carries History…")
pane = body(dictation, "struct DictationHistoryPane: View {")
need("LazyVStack" in pane and "DictationHistory.days(DictationHistory.search(store.recent, search))" in pane
     and 'Button("Clear history…") { confirmingClear = true }' in pane and "isPresented: $confirmingClear," in pane
     and "store.openFixFromHistory(record.id)" in pane and "store.deleteRecord(record.id)" in pane and "store.copy(record.text)" in pane,
     "the history pane: lazy, grouped by day, searched locally; Copy, Fix a word, Delete; Clear history… asks first")
need(".frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)" in pane and ".clipped()" in pane,
     "the history pane clamps itself so a long list never pushes the toolbar off")

# ── 7. The helper verb: words on stdin, fixed routes only.
need('case "transcription-dictionary": try emitTranscriptionDictionary()' in helper, "the helper verb is not dispatched")
verb = body(helper, "private func emitTranscriptionDictionary() throws {")
need("FileHandle.standardInput" in verb and 'option("--' not in verb and "args" not in verb,
     "dictionary words ride on stdin; a word in argv is published to every process on this Mac")
emit_dictionary = body(helper, "private func emitDictionary(token: String, ok: Bool, message: String, unchanged: Bool = false, extra: [String: Any] = [:]) {")
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
need('if ok { emit(ok: true, message: message, details: (["stale": true, "unchanged": unchanged] as [String: Any]).merging(extra) { current, _ in current }) }' in emit_dictionary,
     "a change that worked stays a success when the read-back fails")
# 0.5.317: the answer's meaning moved to DictationBridge.answer (ProviderStatusCore), shared with dictation-check.
need("let answer = try dictate(audio)" in body(helper, "private func emitMacDictation() throws {")
     and 'details: ["noSpeech": true, "action": "none"]' in read("HelperSources/ProviderStatusCore.swift"), "the helper marks no speech")
need('model.runHelper(["transcription-dictionary"], timeout: 20, stdinData: request)' in app,
     "Control must send the request as stdinData with an argument list of exactly the verb")

# ── 8. 0.5.313: fix from the moment it lands, replace the pasted text, quiet while dictating.
sources = {path.name: strip_comments(path.read_text(encoding="utf-8")) for path in (root / "Sources").glob("*.swift")}
start_fn = body(dictation, "    func start() {")
stop_fn = body(dictation, "    private func closeMicrophone() {")
# 0.5.327: both now wait for the microphone's first buffer, inside the start task (Tests/dictation-start-pins.py).
need(start_fn.index("task = Task {") < start_fn.index("playSound(.start)") < start_fn.index("quiet.begin(mode: quietMode, macRecording: macRecordingActive?() ?? false)"),
     "quiet begins after the start sound is scheduled and knows about a Mac recording")
need(stop_fn.index("let pcm = try capture.stop()") < stop_fn.index("quiet.end()") < stop_fn.index("playSound(.stop)"),
     "other apps come back after the microphone closes and before the stop sound")
need(body(dictation, "    private func fail(").count("quiet.end()") == 1 and body(dictation, "    func cancel() {").count("quiet.end()") == 1,
     "every other way listening ends restores: fail and cancel")
need("COSAppDelegate.onTerminate = { model.dictation.cancel(); model.dictation.flushAudio();" in app and "Task { @MainActor in self?.interrupt() }" in dictation,
     "quit reaches cancel; sleep and a session switch reach interrupt, so they restore too")
# interrupt restores on every branch: its cancel fallbacks (cancel restores) and the salvage, which restores itself.
_int = body(dictation, "    func interrupt() {")
need(_int.count("cancel(); message = nil; return") == 3 and _int.count("quiet.end()") == 1,
     "every interrupt branch that was listening gives other apps their sound back")
need("quiet.restoreAfterInterruptedRun()" in dictation, "a volume lowered before a crash goes back at the next launch")
# 0.5.328: the controller lives on DictationAudioQueues.output (Tests/dictation-smooth-pins.py).
quiet = body(dictation, "final class DictationQuietController: @unchecked Sendable {")
begin = body(quiet, "    func begin(mode: DictationQuietMode, macRecording: Bool) {")
need(begin.index("UserDefaults.standard.set(data, forKey: Self.pendingKey)") < begin.index("Self.setVolume(device, target)"),
     "the volume to put back is on disk before COS lowers it")
end = body(quiet, "    func end() {")
need("let report = Self.tearDown(session)" in end and "DictationQuiet.restoreVolume(" in end and "removeObject(forKey: Self.pendingKey)" in end,
     "end tears the mute down, restores the volume and clears the pending record")
# 0.5.315: 0.5.313 created the muting tap and never read it (Spotify played on while the log said muted). The mute is
# tap, UID, private aggregate, IOProc, IO running, through the tested DictationMuteTap; "muted" is logged only after.
mute = body(quiet, "    private func muteOtherApps() -> Bool {")
teardown = body(quiet, "    private static func tearDown(_ session: Mute) -> String {")
need(mute.count("DictationMuteTap.build {") == 1 and "if let failure = result.failure {" in mute
     and mute.index("DictationMuteTap.build {") < mute.index("if let failure = result.failure {") < mute.index('"quiet: other apps muted'),
     "other apps muted is logged only after every step, including AudioDeviceStart, succeeded")
need(mute.count("AudioHardwareCreateProcessTap(description, &session.tap)") == 1 and mute.count("AudioHardwareCreateAggregateDevice(composition as CFDictionary, &session.aggregate)") == 1
     and mute.count("AudioDeviceCreateIOProcIDWithBlock(&session.ioProc, session.aggregate, nil, DictationMuteIO.silence(session.meter))") == 1
     and mute.count("AudioDeviceStart(session.aggregate, session.ioProc)") == 1, "each Core Audio step runs once, inside the tested build")
need("kAudioAggregateDeviceIsPrivateKey: true" in mute and "kAudioAggregateDeviceTapAutoStartKey: false" in mute
     and "kAudioAggregateDeviceMainSubDeviceKey: outputUID" in mute and "kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID" in mute,
     "a private aggregate on the default output lists the tap; no auto-start (AudioDeviceStart would wait for a tapped process)")
_fail = body(mute, "        if let failure = result.failure {")
need("let report = Self.tearDown(session)" in _fail and "return false" in _fail and "failure.step.rawValue" in _fail and "failure.status" in _fail,
     "a failed step tears down what exists, logs the step and its status, and falls back to lowering")
need("DictationMuteTap.teardown(session.built)" in teardown and all(c in teardown for c in (
     "AudioDeviceStop(session.aggregate, session.ioProc)", "AudioDeviceDestroyIOProcID(session.aggregate, $0)",
     "AudioHardwareDestroyAggregateDevice(session.aggregate)", "AudioHardwareDestroyProcessTap(session.tap)")),
     "teardown follows the tested reverse order and covers every object")
_order = ("mute = nil", "AudioObjectRemovePropertyListenerBlock(", "let report = Self.tearDown(session)")
need(all(m in end for m in _order) and end.index(_order[0]) < end.index(_order[1]) < end.index(_order[2]),
     "end forgets the session first (idempotent) and removes the output listener before tearing down")
need("guard !DictationMuteTap.keepOnOutputChange(mutedOn: session.outputUID, now: now) else { return }" in quiet
     and "nonisolated private static func outputListener(" in quiet and "dispatchPrecondition(condition: .onQueue(DictationAudioQueues.output))\n            controller?.defaultOutputChanged()" in quiet,
     "a new default output ends the mute, through a listener built outside any actor, on the controller's own queue")
need("self?.quietNote = note" in start_fn and "let note = controller.fallbackNote, times = controller.lastTimes" in dictation and "let note = store.quietNote" in dictation,
     "a mute that fell back says so in Settings' While dictating")
need("description.muteBehavior = .muted" in quiet and "let own = Self.ownProcessObject()" in quiet and "stereoGlobalTapButExcludeProcesses: own)" in quiet
     and "description.isPrivate = true" in quiet, "the mute is a private global tap that excludes COS")
need("DictationQuiet.plan(mode: mode, macRecording: macRecording," in begin, "the tested plan decides mute, lower or leave")
need('forKey: "dictation.quiet") ?? "") ?? .default' in dictation and "DictationQuietSettings(store: store)" in dictation,
     "While dictating defaults to Mute other apps and is in Settings")
media = ("NX_KEYTYPE", "systemDefined", "MRMediaRemote", "MediaRemote.framework", "MPRemoteCommand", "keyCode: 16, keyDown")
need(not any(m in src for src in sources.values() for m in media),
     "no media key and no MediaRemote: a blind play/pause can START playback (0.5.313 finding)")
replace = body(dictation, "    static func replace(_ target: DictationInsertTarget, corrected: String, restoreClipboard: Bool, automatic: Bool = false) async -> Replaced {")
need("CGEvent" not in replace and ".post(" not in replace and "kAXValueAttribute" not in replace,
     "Replace posts no key of its own (only paste's ⌘V, below) and never reads the field's whole value")
need("DictationReplace.plan(" in replace and "DictationReplace.route(setterWorked: target.setterWorked)" in replace
     and replace.count("DictationReplace.confirmed(") == 2 and "DictationReplace.window(span: target.span," in replace,
     "Replace reads a bounded window, plans through the tested rules, takes the route delivery proved, and measures both routes")
need("kAXStringForRangeParameterizedAttribute" in dictation, "the span is read with AXStringForRange")
# 0.5.318 (Miles 13:02, Claude): the Accessibility set is a no-op in Electron, so a replace there pastes, and only after
# the tested proof that the selection is exactly the misheard words in the app's own focused field.
need(replace.count("await paste(changeCount: changeCount, recheck: reproof)") == 1
     and replace.index("DictationReplace.pasteProof(") < replace.index("if let proof {") < replace.index("await paste(changeCount: changeCount, recheck: reproof)"),
     "the replace ⌘V is posted once, only after pasteProof passed")
need(replace.index("key.orderOut(nil); key.orderFrontRegardless()") < replace.index("DictationReplace.pasteProof("),
     "COS's own panel gives the keyboard back before focus is proved")
need("setterWorked: true" in deliver and "setterWorked: false" in deliver and deliver.count("text: text,") == 2,
     "delivery records which route moved the field and what it typed, for the replace")
need('dictationLog.notice("replace \\(facts, privacy: .public) result=' in replace and "selectedMatch=" in replace and "focused=" in replace and "readback=" in replace,
     "one replace log line carries the discriminating facts (route, found, focus, selection, read-back), never text")
save_fn = body(dictation, "    func saveFix(to dictionary: TranscriptionDictionaryStore) {")
need(save_fn.index("recent = DictationHistory.correcting(recordID, to: corrected, in: recent)") < save_fn.index("saveRecent()")
     < save_fn.index("replaceOffer = DictationReplaceOffer("),
     "Save corrects the stored dictation (Heard, history) before offering Replace (Miles: Heard still read the mishearing)")
need("recent = recent.map" not in body(dictation, "    func replaceCorrected() {"), "Replace no longer owns the record update; Save does")
# 0.5.318 spoken lists: on by default, applied once to the transcript before it is delivered and recorded. 0.5.325: to
# what AI polish answered, or what was heard (`said`).
need('forKey: "dictation.formatLists") as? Bool ?? true' in dictation
     and 'Toggle("Format spoken lists", isOn: $store.formatLists)' in dictation, "Format spoken lists is a setting, on by default")
need(transcribe.count("DictationListFormat.format(") == 1
     and transcribe.index("let text = formatLists ? DictationListFormat.format(said) : said") < transcribe.index("let delivered = copyOnly"),
     "the list format runs before delivery, so what is typed and what is kept match")
replace_ui = body(dictation, "    func replaceCorrected() {")
need(replace_ui.count("copy(offer.corrected)") == 4 and 'fixNote = "Copied the corrected text."' in replace_ui,
     "every path that does not replace copies the corrected text and says so")
need("DictationReplace.span(pid: app.processIdentifier, baseline: baseline, after: after, count: count)" in deliver
     and "baseline: beforePaste, after: measuredAfterPaste, count: count)" in deliver,
     "the inserted range is recorded from the measurement, on the Accessibility and ⌘V routes")
need("if case .inserted = outcome { return DictationDelivered(outcome: outcome, target: landed, context: context) }" in deliver,
     "only a measured insertion carries a target")
finish = body(dictation, "    private func finish(")
need("fixOfferID = offer ? record.id : nil" in finish and "DictationQuickFix.offerSeconds" in finish, "the flash carries Fix for 5 s")
need(dictation.count("onFix: store.fixOfferID == nil ? nil : { store.quickFix() }") == 1
     and pet.count("onFix: dictation.fixOfferID == nil ? nil : { dictation.quickFix() }") == 1,
     "both pills (floating and the pet) wire Fix to quickFix")
need("panel.ignoresMouseEvents = store.card == nil && !fixing && store.fixOfferID == nil" in dictation,
     "the floating pill takes the click on Fix")
need("} else if id == 3, down {\n            quickFix()" in dictation and "if feed(&fixTracker) == .released { hotKey(3, down: true) }" in dictation,
     "the Fix last dictation shortcut, keys or a lone modifier, opens Fix a word")
need("DictationShortcutRow(store: store, slot: .fix, activityShortcut: activityShortcut)" in dictation
     and "DictationShortcuts.conflicts(trigger, slot: slot, assigned: assignedShortcuts, activity: activityTrigger)" in dictation,
     "Fix last dictation is settable like the others and conflict-checked")
need('d.object(forKey: "dictation.fix.enabled") == nil' in dictation and "DictationShortcuts.defaultFix" in dictation,
     "⌃⌥F unless the person set or turned it off")
need("DictationFixGuess.guess(tokens: tokens, tapped: index, vocabulary: TranscriptionDictionaryStore.shared.vocabulary," in body(dictation, "    func selectFixWord(_ index: Int) {"),
     "the first tap guesses the span and the dictionary suggestion")
need('Button(offer.app.map { "Replace it in \\($0)" } ?? "Copy the corrected text") { store.replaceCorrected() }' in dictation,
     "Fix a word offers Replace it in <App> after Save")

# ── 9a. 0.5.338 Learn from my edits in every app: the field, not the element; re-anchor; the canary; Undo on the pill.
watcher = body(dictation, "@MainActor final class DictationEditWatcher {")
need(watcher.count("let verdict = DictationEditLearning.focus(frontmost: seen.frontmost, sameElement: seen.sameElement, watched: box.identity,") == 1
     and "if verdict == .rebound, let next = seen.element { box.element = next; box.identity = seen.identity }" in watcher
     and "DictationInsertion.focusedField(pid: pid, watched: box.element)" in watcher
     and "let seen = await field.focus(canary.rebinds)" in watcher
     and "focused: focused, fieldCharacters: now.characters, dictationLength: length)" in watcher
     and "measure: { DictationInsertion.measure(box.element) }" in watcher,
     "every poll asks the tested focus rule; a rebound field is read through the new element; the stop rule hears focus and the dictation's length")
need("DictationEditLearning.reanchor(typed, in: baseline)" in watcher and "case .reanchored(let s, let l, let edit):" in watcher
     and "case .cleared:" in watcher and "Self.record(canary)" in watcher and watcher.count("bundle: \"com.gotcos.control\"") == 1,
     "the start finds a moved dictation again, a read re-anchors or ends cleared, and every watch (COS's own views too) writes its canary line")
need("kAXValueAttribute" not in body(dictation, "    nonisolated static func fieldIdentity(") and "kAXValueAttribute" not in body(dictation, "    nonisolated static func focusedField("),
     "the field's identity is attributes only, never its text")
need("learnedUndoID = item.id; learnedUndoPill = flash" in body(dictation, "    private func editLearned(") and "Task { await undoLearned(id) }" in body(dictation, "    func undoLearnedFromPill() {")
     and "guard let id = pillUndoID else { return }" in body(dictation, "    func undoLearnedFromPill() {")
     and "var pillUndoID: UUID? { pill == learnedUndoPill ? learnedUndoID : nil }" in dictation
     and "onUndo: store.pillUndoID == nil ? nil : { store.undoLearnedFromPill() })" in dictation
     and "onUndo: dictation.pillUndoID == nil ? nil : { dictation.undoLearnedFromPill() })" in pet
     and "panel.ignoresMouseEvents = store.card == nil && !fixing && store.fixOfferID == nil && store.pillUndoID == nil" in dictation,
     "\"LEARNED\" on the pill offers Undo on both pills, the floating pill takes the click, and Undo is the Learned list's Undo")

# ── 9. 0.5.318 Learn from my edits (Miles 13:31): Save automatically by default, native first, never secure, Undo.
need('UserDefaults.standard.string(forKey: "dictation.learnMode") ?? "") ?? .default' in dictation
     and 'COSDropdown("Learn from my edits", selection: $store.learnMode,' in dictation, "Learn from my edits is a Setting with the tested default")
need("Never in terminals or password fields." in dictation and "Text(DictationEditLearning.settingNote)" in dictation
     and "Electron apps are being measured first" not in dictation,
     "the Settings footnote is the tested line that names where learning works and where it is only measured (0.5.338)")
finish = body(dictation, "    private func finish(")
need("if let target, case .inserted = outcome {\n            editWatcher.start(target, mode: learnMode, context: context)" in finish and 'editWatcher.stop("not inserted")' in finish,
     "only a measured insertion starts a watch; anything else ends the last one")
need('editWatcher.stop("new dictation")' in body(dictation, "    func start() {") and 'editWatcher.stop("fix a word")' in body(dictation, "    func openFix(_ id: UUID?) {"),
     "a new dictation or Fix a word (whose Replace edits the field) ends the watch")
need('if learnMode == .off { editWatcher.stop("learning off") }' in dictation, "turning learning off ends a watch at once")
watcher = body(dictation, "@MainActor final class DictationEditWatcher {")
need(watcher.count("DictationEditLearning.eligibility(mode: mode, secure: DictationInsertion.secure(element)") == 1
     and "if case .skip(let reason) = eligibility {" in watcher and watcher.count("learning: eligibility == .learn") == 2
     and "let candidate = learning && DictationEditLearning.allowsAnother(learned: learnedHere)\n                        ? await Self.consider(edit, window: baseline, start: start, length: length, context: context) : nil" in watcher
     and "guard let candidate = await MainActor.run(body: { DictationEditWatcher.candidate(edit, outside: outside) }) else { return nil }" in watcher
     and "bundle: target.bundle)" in watcher,
     "the tested gate decides learn, probe or skip, and only .learn produces a candidate (Electron is probed only)")
need("DictationEditLearning.stop(elapsed: Date().timeIntervalSince(started), reads: reads, appRunning: running,\n                                                        secure: await field.secure()," in watcher
     and "secure: { DictationInsertion.secure(box.element) }," in watcher,
     "every poll asks the tested stop rule, secure input and password fields included")
need("DictationReplace.holds(baseline, at: span.location - bounds.location, typed)" in watcher
     and "DictationEditLearning.readLength(" in watcher and "DictationEditLearning.follow(" in watcher,
     "a watch starts only from proof of what COS typed, and reads the bounded window it planned")
need("kAXValueAttribute" not in watcher and "AXObserver" not in watcher and "DictationInsertion.text(box.element, location: $0, length: $1)" in watcher
     and "await field.text(bounds.location, bounds.length)" in watcher,
     "the watch reads only the bounded window, never AXValue")
learned_fn = body(dictation, "    private func editLearned(")
need(learned_fn.index("DictationSuggestions.isQuiet(") < learned_fn.index("if learnMode == .suggest {") < learned_fn.index("TranscriptionDictionaryStore.shared.learn(")
     and "DictationSuggestions.suggesting(item, in: suggestions, now: now)" in learned_fn and "DictationSuggestions.learning(item, in: suggestions, now: Date())" in learned_fn,
     "a dismissed or undone pair stays quiet; Suggest only suggests; Save automatically saves, then lists it for Undo")
undo = body(dictation, "    func undoLearned(_ id: UUID) async {")
need("DictationSuggestions.recentID(for: item, in: rows)" in undo and "await dictionary.undo(entry)" in undo
     and "DictationSuggestions.dismissing(id, in: suggestions, now: Date())" in undo,
     "Undo reverses the dictionary entry COS made and keeps the pair from coming back")
pane = body(dictation, "struct DictationActivityPane: View {")
need("store.applySuggestions(Set(items.map(\\.id)))" in pane and "store.dismissSuggestion(item.id)" in pane and "store.undoLearned(item.id)" in pane
     and "DictionaryLearnedRow(" in pane and 'Button("History") { model.openDictationHistory() }' in pane and 'Button("Dictionary") { model.openDictionary() }' in pane,
     "Activity → Dictation: Add all, Add, Dismiss, Undo, Recent corrections, and the history and dictionary panes")
need("Picker(" not in pane and ".pickerStyle(.segmented)" not in pane, "no pill-row tabs in the Dictation tab")
need("case .dictation: DictationActivityPane(model: model)" in activity
     and re.search(r"else if section == \.dictation, model\.dictionaryRouteActive \{\s*TranscriptionDictionaryPane\(model: model\)", activity) is not None
     and re.search(r"else if section == \.dictation, model\.dictationHistoryRouteActive \{\s*DictationHistoryPane\(model: model\)", activity) is not None
     and re.search(r"section == \.dictation, model\.dictionaryRouteActive \{\s*model\.closeDictionary\(\)", body(activity, "private func goBack() {")) is not None
     and "case .dictation: model.dictionaryRouteActive || model.dictationHistoryRouteActive" in activity,
     "the Dictation tab mounts its pane and both sub-panes on their own flags, with Back and hasDetail")
need(launch.index("if let next { select(next) }") < launch.index("if openDictionary, section == .dictation { model.openDictionary() }"),
     "the pet's Dictionary… opens in the Dictation tab after the section is selected")
need("openActivity?(.dictation)" in body(model, "func openDictionaryInActivity() {") and "openActivity?(.dictation)" in body(model, "func openDictationInActivity() {"),
     "the pet's doorways open the Dictation tab")
need("onReview: { dictation.closeList(); model.openDictationInActivity() }" in pet and "dictation.suggestions.suggestions.isEmpty" in lst,
     "the pet shows suggestions where Fix a word lives, and a row into Activity → Dictation")

# QA 0.5.313 pass 2: a refused press never latches the hold key; only the hold tracker gets the click window; an
# interrupted dictation never overwrites a clipboard the person changed while it transcribed.
hot = body(dictation, "    func hotKey(_ id: UInt32, down: Bool) {")
need('if !["Starting", "Listening"].contains(phase) { held = false; holdPending = false }' in hot
     and hot.index("start()") < hot.index('if !["Starting", "Listening"].contains(phase)'),
     "a press refused while the last dictation transcribes never latches the hold key")
events = body(dictation, "    private func keyEvent(")
need("pointer && clickWindow ? current.pointerDown(at: time) : current.keyDown()" in events
     and events.count("feed(&holdTracker, clickWindow: true)") == 1 and "feed(&toggleTracker)" in events and "feed(&fixTracker)" in events
     and "clickWindow: true" not in events.split("feed(&holdTracker, clickWindow: true)")[1],
     "only the hold key keeps listening through a click; a toggle or Fix modifier chords on any click")
need("if clipboardMoved {" in body(dictation, "    static func copyOnly(_ text: String, clipboardMoved: Bool) -> DictationDelivered {")
     and "DictationInsertion.copyOnly(text, clipboardMoved: clipboardMoved)" in dictation
     and dictation.count("interruptedChangeCount = NSPasteboard.general.changeCount") == 2,
     "a salvage leaves a clipboard changed since the interrupt alone, from either interrupt path")

# ── 10. 0.5.323 (Miles 2026-10-17): the text around a dictation. Read before typing, bounded, memory only; evidence for
# Learn from my edits; a reverted context fix is never learned. The pure rules run in MacDictationChecks.
read_ctx = body(dictation, "    private static func readContext(_ target: AXUIElement, enabled: Bool, terminal: Bool, baseline: DictationFieldSnapshot, dictation: String,")
steps = ("let baseline = snapshot(target)", "context = readContext(target, enabled: fieldContext, terminal: terminal, baseline: baseline, dictation: text, facts: &facts)",
         "if let context { text = context.text; count = text.utf16.count }", "if route == .accessibility, let target {")
need(deliver.count("readContext(") == 1 and all(step in deliver for step in steps)
     and deliver.index("let baseline = snapshot(target)") < deliver.index("context = readContext(target, enabled: fieldContext, terminal: terminal, baseline: baseline, dictation: text, facts: &facts)")
     < deliver.index("if let context { text = context.text; count = text.utf16.count }") < deliver.index("if route == .accessibility, let target {"),
     "the field is read after it is measured and before anything is typed, and what is typed (and counted) is the respelled text")
need("var text = terminal ? DictationDelivery.terminalText(raw) : raw" in deliver and "var count = text.utf16.count" in deliver
     and deliver.index("var context: DictationFieldContext.Applied?") < deliver.index("func done(_ outcome: DictationDeliveryOutcome) -> DictationDelivered {")
     and "return DictationDelivered(outcome: outcome, target: nil, context: context)" in deliver,
     "every outcome after the read carries it, so the record keeps what was typed")
need("DictationFieldContext.plan(enabled: enabled, secure: secure(target), terminal: terminal," in read_ctx
     and "guard case .read(let before, let after) = plan else {" in read_ctx,
     "the tested plan decides the read, password fields, secure input and terminals included")
need("string(target, location: before.location, length: before.length)" in read_ctx and "string(target, location: after.location, length: after.length)" in read_ctx
     and read_ctx.count("string(target, location:") == 2 and "kAXValueAttribute" not in read_ctx and "kAXSelectedTextAttribute" not in read_ctx,
     "two bounded AXStringForRange reads, never the field's whole value")
need("AXUIElementSetMessagingTimeout(target, DictationFieldContext.readTimeoutSeconds)" in read_ctx and "defer { AXUIElementSetMessagingTimeout(target, 0.25) }" in read_ctx
     and read_ctx.count("DictationFieldContext.inBudget(elapsed: Date().timeIntervalSince(started))") == 2,
     "each read has a short timeout, the second runs only inside the budget, and a slow read is dropped")
need("DictationFieldContext.terms(in: read, known: known)" in read_ctx and "DictationFieldContext.corrected(dictation, terms: terms, known: known)" in read_ctx
     and "NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound" in read_ctx,
     "the tested terms and corrections, with the system spell checker as the English test")
facts_lines = [line for line in read_ctx.splitlines() if "facts +=" in line]
need(len(facts_lines) == 4 and not any(bad in line for line in facts_lines for bad in ("read.before", "read.after", "result.text", "dictation", "\\(terms)", "terms.map", "fixes)"))
     and "dictationLog" not in read_ctx and "FileManager" not in read_ctx and "UserDefaults" not in read_ctx and "request(" not in read_ctx,
     "the read logs counts only and writes nothing: the field's text stays in memory")
# 0.5.331: the second Applied is the paste-first swap's: the same outside text, handed only to the watch that follows it.
need(dictation.count("DictationFieldContext.Applied(") == 2 and dictation.count("context?.outside") == 1 and dictation.count("context?.fixes") == 1
     and dictation.count("watchContext = delivered.context.map { DictationFieldContext.Applied(text: polished, fixes: final?.fixes ?? [], outside: $0.outside, terms: $0.terms) }") == 1
     and dictation.count("editWatcher.start(watchTarget, mode: learnMode, context: watchContext)") == 1,
     "the field's text reaches only the watch that follows")
need('forKey: "dictation.fieldContext") as? Bool ?? true' in dictation
     and 'Toggle("Spell words the way the text box has them", isOn: $store.useFieldContext)' in dictation
     and "never saves or sends it" in dictation and "Never in terminals or password fields." in dictation,
     "a setting, on by default, says what is read and that it is kept for that dictation only")
need("editWatcher.start(target, mode: learnMode, context: context)" in finish, "the watch gets the read")
consider = body(dictation, "    nonisolated private static func consider(")
need("let outside = DictationEditLearning.outside(window: window, start: start, length: length) + (context?.outside ?? [])" in consider
     and "return DictationEditLearning.undoesContextFix(candidate, fixes: context?.fixes ?? []) ? nil : candidate" in consider
     and watcher.index("? await Self.consider(edit, window: baseline, start: start, length: length, context: context) : nil") < watcher.index("if let candidate { learnedHere += 1; canary.learned += 1; await found(candidate) }")
     and "evidence=\\(candidate?.evidence != nil) learned=\\(learnedHere)" in watcher,
     "the window around the dictation and the read before it are evidence; putting back what was heard is never learned")
need("}, outside: outside)" in body(dictation, "    static func candidate(_ edit: DictationReplace.Edit, outside: [String]) -> DictationEditLearning.Candidate? {"),
     "the tested candidate rule sees the evidence")
need("evidence: candidate.evidence)" in learned_fn, "the suggestion carries the evidence")
row = body(dictation, "struct DictationSuggestionRow: View {")
need("if let evidence = item.evidence {" in row and "Text(evidence.words)" in row and row.index("pair") < row.index("Text(evidence.words)"),
     "the evidence line sits under the pair, in the Dictation tab and in Fix a word")
need("DictationSuggestionRow(item: item, fontSize: 11, busy: applying || dictionary.busy," in pane, "the Dictation tab lists suggestions with that row")
# The server's dictionary suggestions (6.77.0): a dormant seam. Nothing in Control calls it, and it sends nothing.
need(helper.count('case "dictionary-suggestions": try emitDictionarySuggestions()') == 1, "the seam verb is dispatched once")
seam = body(helper, "private func emitDictionarySuggestions() throws {")
need("FileHandle.standardInput" in seam and "request(" not in seam and "/api/" not in seam and "speakerReviewToken" not in seam
     and '"dormant": true' in seam, "the seam reads stdin, reads no token and sends nothing")
need(not any('"dictionary-suggestions"' in src for src in sources.values()) and "transcript-cleanup" not in "".join(sources.values()).replace(core, ""),
     "Control does not call the seam or the server's routes yet")

# 0.5.334 (server 6.84.0): a correction-only learn ("/pricing") carries the server's note from the helper to the store,
# through the tested DictionaryLearnNote rule, and Fix a word shows the store's message.
learn_verb = body(helper, "private func emitTranscriptionDictionary() throws {")
need('if response?.body?["correctionOnly"] as? Bool == true, let note = response?.body?["note"] as? String {' in learn_verb
     and 'extra = ["correctionOnly": true, "note": note]' in learn_verb
     and "emitDictionary(token: token, ok: true, message: message, unchanged: unchanged, extra: extra)" in learn_verb,
     "the helper's learn case passes correctionOnly and note on")
emit_dict = body(helper, "private func emitDictionary(token: String, ok: Bool, message: String, unchanged: Bool = false, extra: [String: Any] = [:]) {")
need(emit_dict.count(".merging(extra) { current, _ in current }") == 2, "both dictionary answers (read back and stale) carry the extra fields")
store = body(dictation, "@MainActor final class TranscriptionDictionaryStore: ObservableObject {")
need('let note = DictionaryLearnNote.line(correctionOnly: response.details["correctionOnly"]?.bool,' in store
     and 'note: response.details["note"]?.string) {' in store and "message = note" in store,
     "the dictionary store shows the note through the tested rule")
_order = [store.find('response.details["unchanged"]?.bool == true'), store.find("DictionaryLearnNote.line("), store.find("message = response.ok ? nil : response.message")]
need(-1 not in _order and _order == sorted(_order),
     "unchanged still wins, and a plain save still clears the message")
save_fix = body(dictation, "func saveFix(to dictionary: TranscriptionDictionaryStore) {")
need('fixNote = (dictionary.message.map { $0 + " " } ?? "Saved. ")' in save_fix, "Fix a word shows the store message before its own line")

print(f"PASS dictation-wispr pins: {checks} checks; HUD gone, copy-then-insert-at-focus, private history, overlay focus, pet slot and lists, Dictionary route, helper stdin, quick fix, replace, quiet restore on every exit")
