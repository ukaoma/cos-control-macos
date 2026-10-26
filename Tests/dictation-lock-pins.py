#!/usr/bin/env python3
"""0.5.330 hold to dictate "lock" (Miles 2026-10-19) and dictation settings in the Activity Dictation tab. Each failure
names its behaviour as "pin failed [<behaviour>]". Code only: comments never satisfy a pin. The rules (the hold watch,
the event line, the STILL FINISHING pill) run in MacDictationChecks.

    python3 Tests/dictation-lock-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


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


def order(src, needles, behaviour, why):
    pin(all(n in src for n in needles), behaviour, why)
    found = [src.index(n) for n in needles]
    pin(found == sorted(found), behaviour, why)


d = code(read("Sources/MacDictation.swift"))
model = code(read("Sources/ControllerModel.swift"))
window = code(read("Sources/ActivityWindow.swift"))
views = code(read("Sources/Views.swift"))
app = code(read("Sources/COSControlApp.swift"))

# A. Every press that does not become a dictation writes a line.
start = body(d, "    func start() {")
guard = start[:start.index("let pressed = ProcessInfo.processInfo.systemUptime")]
order(guard, ["guard MacDictationPolicy.mayStart(enabled: enabled, busy: busy) else {", "if enabled, busy { recordPressEvent(.refusedBusy); noteStillFinishing() }", "return"],
      "refused busy", "a press refused because the last dictation is still going is written and shown, never silent")
stop = body(d, "    func stop(ending: DictationReleaseTail.Ending) {")
starting = stop[:stop.index('guard phase == "Listening", let capture else { return }')] if 'guard phase == "Listening", let capture else { return }' in stop else ""
order(starting, ['if phase == "Starting" {', "recordPressEvent(.canceledStarting, msSincePress: since, firstBufferArrived: capture?.firstAudioUptime != nil)", "cancel(); return"],
      "canceled starting", "a release before COS could hear is written (with the time and whether the first buffer had arrived), then canceled")
key = body(d, "    private func keyEvent(flags: Bool, pointer: Bool, keyCode: UInt16, raw: UInt64, at time: TimeInterval) {")
pin("case .chord?: if held { recordPressEvent(.interruptedChord); if fnConflictNow { fnCardPending = true }; interrupt() }" in key, "chord",
    "a chord mid-hold is written before the copy-only interrupt")
event = body(d, "    private func recordPressEvent(_ event: DictationPressEvent, msSincePress: Int? = nil, firstBufferArrived: Bool? = nil, reconcileSource: String? = nil) {")
pin("DictationTiming.event(event, at: Date())" in event and "line.appVersion = Self.appVersion" in event
    and "line.held = held; line.holdTrackerDown = holdTracker?.down; line.holdHardwareDown = holdKeyHardwareDown()" in event
    and "DictationTimingLog.append(line, to: url)" in event, "event line", "the event line carries the version and the hold key's state, in the timing file")
logs = [l for l in event.split("\n") if "dictationLog" in l]
pin(len(logs) == 1 and not re.search(r"\\\((text|heard|said|pcm|wav)\b", logs[0]), "event line", "the event's log line carries no text")
pin(d.count("recordPressEvent(.") == 4 and "line.reconcileSource = reconcileSource" in event, "event line", "exactly the four events are written: refused_busy, canceled_starting, interrupted_chord, release_reconciled")

# B. The missed release: watch the keyboard while the hold key is believed down, release on two up reads.
watch = body(d, "    private func ensureHoldWatch() {")
pin("guard holdWatch == nil, holdTrigger != nil," in watch and "DictationHoldWatch.watches(phase: phase, held: held, trackerDown: holdTracker?.down == true)" in watch
    and "var reads = DictationHoldWatch.Reads()" in watch and "let down = self.holdKeyHardwareDown()" in watch
    and "if down { self.holdSeenDown = true }" in watch and "if reads.read(down: down) { self.reconcileRelease(source: \"poll\"); break }" in watch
    and "try? await Task.sleep(for: .milliseconds(DictationHoldWatch.pollMilliseconds))" in watch, "hold watch",
    "one watch at a time, only while there is something to watch, every 150 ms, released by the tested rule")
pin(watch.index("if reads.read(down: down)") < watch.index("Task.sleep"), "hold watch", "the first read is at the press, so the key is seen down before any up counts")
hot = body(d, "    func hotKey(_ id: UInt32, down: Bool) {")
pin("ensureHoldWatch()" in hot and hot.index("held = true; holdPending = true; start()") < hot.index("ensureHoldWatch()"), "hold watch",
    "a hold press starts the watch")
pin("if holdTracker?.down == true { ensureHoldWatch() }" in key, "hold watch", "a tracker latched down is watched too")
recon = body(d, "    private func reconcileRelease(source: String) {")
order(recon, ["let wasHeld = held", "recordPressEvent(.releaseReconciled, reconcileSource: source)", "holdTracker?.reset(); holdSeenDown = false",
              "if wasHeld { hotKey(1, down: false) }"], "reconcile",
      "the reconciled release is written, the tracker forgets the press, and a held dictation takes the same path as a real key-up")
hw = body(d, "    private func holdKeyHardwareDown() -> Bool? {")
pin("CGEventSource.flagsState(.hidSystemState).rawValue" in hw and "DictationHoldWatch.modifierDown(" in hw
    and "CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))" in hw, "keyboard state",
    "the keyboard's own state: the trigger's device bit for a lone modifier, the key for a shortcut")

# B2. A key typed long after the press while the keyboard says the hold key is up is the missed release, not a chord.
order(key, ["if !flags, !pointer, let tracker = holdTracker, tracker.down,",
            "DictationHoldWatch.keyDownIsMissedRelease(trackerDown: true, hardwareDown: holdKeyHardwareDown(), seenDown: holdSeenDown,",
            "sincePress: time - tracker.pressedAt)", 'reconcileRelease(source: "key")', "switch feed(&holdTracker, clickWindow: true) {"],
      "key is release", "the missed-release rule runs before the hold tracker can call the key a chord")
pin("holdSeenDown = false; checkFnUsage()" in hot and hot.index("holdSeenDown = false; checkFnUsage()") < hot.index("held = true; holdPending = true; start()"),
    "key is release", "each hold press starts unseen, and checks macOS's 🌐 key setting")
recon_release = body(d, "    private func reconcileRelease(source: String) {")
pin("interrupt()" not in recon_release and "pendingInterrupted" not in recon_release, "key is release",
    "a reconciled release types the dictation: it never interrupts or copies")
# The reconciled release is the person's own stop: hotKey's release, then stop(), which is stop(ending: .released) (the
# release tail, transcription, then the insert). Never interrupt(), which only copies.
release_branch = hot[hot.index("else if !down { held = false; if holdPending { holdPending = false; stop() } }"):] if "else if !down { held = false; if holdPending { holdPending = false; stop() } }" in hot else ""
pin(release_branch != "" and "    func stop() { stop(ending: .released) }" in d and "if wasHeld { hotKey(1, down: false) }" in recon_release,
    "reconcile inserts", "a reconciled release goes through hotKey's release to stop(ending: .released), the path that inserts")
pin(not re.search(r"\binterrupt\(\)", recon_release) and "copyOnly" not in recon_release, "reconcile inserts", "it never calls interrupt() or copies")
press_fn = body(d, "    private func warnFnAtPress() {")
pin("guard holdTrigger?.isFn == true, fnConflictNow else { return }" in press_fn and "dictationLog.notice(" in press_fn
    and "guard !fnWarnedThisRun, card == nil else { return }" in press_fn and "showFnCardIfPending()" in press_fn, "fn at press",
    "an Fn press with the 🌐 key setting in the way is logged every time and shows the card once per run")
pin(hot.index("held = true; holdPending = true; start()") < hot.index("warnFnAtPress()"), "fn at press", "the warning comes after start(), which clears cards")

# F. The 🌐 key's own job in macOS: read at launch and on each Fn press, logged, and the card at the moment it matters.
fn = body(d, "    private func checkFnUsage() {")
pin('CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)' in fn and "dictationLog.notice(" in fn
    and "guard fnIsDictationKey else { return }" in fn, "fn usage", "only while Fn is a dictation key, read from HIToolbox and logged when it changes")
reg = body(d, "    func registerHotKeys() {")
pin("checkFnUsage()\n        if fnConflictNow, message == nil { message = DictationFnUsage.note }" in reg, "fn usage", "launch (and every shortcut change) checks it and says so")
card = body(d, "    private func showFnCardIfPending() {")
pin("DictationCard(kind: .failed(DictationFnUsage.note, action: .openKeyboardSettings)" in card and "guard fnConflictNow, card == nil else { return }" in card,
    "fn card", "the card names the fix and opens Keyboard settings, never over another card")
pin("showFnCardIfPending()" in body(d, "    private func finish(") and "if fnConflictNow { fnCardPending = true }" in recon_release, "fn card",
    "a dictation whose release was reconciled ends with the card")
pin("if let url = URL(string: DictationFnUsage.keyboardSettingsURL) { NSWorkspace.shared.open(url) }" in d, "fn card", "the card's button opens Keyboard settings")
pin("→" not in "".join(re.findall(r'"[^"\n]*"', fn + card)) and "→" not in read("Sources/MacDictationCore.swift").split("enum DictationFnUsage {")[1].split("\n}")[0],
    "fn usage", "no arrow in the new copy")

# C. A press while transcribing or polishing is never swallowed, and nothing is queued.
note = body(d, "    private func noteStillFinishing() {")
pin('message = "Still finishing the last dictation."' in note and "pill = .finishing" in note
    and "try? await Task.sleep(for: .seconds(DictationPill.finishingSeconds))" in note
    and "guard let self, !Task.isCancelled, self.pill == .finishing else { return }" in note and "self.pill = previous" in note
    and "start()" not in note, "still finishing", "the pill says STILL FINISHING for a moment, then shows what it replaced; no second dictation is queued")
pin("case .transcribing, .polishing, .finishing:" in d, "still finishing", "STILL FINISHING shows the working bars")

# D. Settings in the Dictation tab.
pane = body(d, "struct DictationActivityPane: View {")
pin('Button("Settings") { model.openDictationSettings() }' in pane, "settings in tab", "the Dictation tab's header has Settings beside History and Dictionary")
settings = body(d, "struct DictationSettingsPane: View {")
pin("MacDictationSettings(store: model.dictation, activityShortcut: model.activityHotKey)" in settings
    and 'Button("Close") { model.closeDictationSettings() }' in settings, "settings in tab", "the tab shows the same settings the panel shows")
pin("MacDictationSettings(store: model.dictation, activityShortcut: model.activityHotKey)" in views, "settings in panel", "the menu-bar panel keeps its copy")
pin("Settings → Dictation" not in d + views + window + model, "no dead sentence", "no sentence sends people to Settings → Dictation; a button opens it")
pin(pane.count("model.openDictationSettings()") == 2 and d.count("model.openDictationSettingsInActivity()") == 2, "no dead sentence",
    "the tab's header, its learn-off line and the history pane's two places each open the settings")
opener = body(model, "    func openDictationSettings() {")
pin("dictationSettingsOpen = true" in opener and "dictionaryOpen = false" in opener and "dictationHistoryOpen = false" in opener, "settings route",
    "the opener writes the route flag and closes the tab's other panes")
pin(len(re.findall(r"^\s+dictationSettingsOpen = false$", model, re.M)) == 5, "settings route",
    "every other pane's opener (import, suggestions, dictionary, history) and the close clear the settings route")
pin("var dictationSettingsRouteActive: Bool {\n        dictationSettingsOpen\n    }" in model, "settings route", "the route is the flag the opener writes")
pin("case .dictation: model.dictionaryRouteActive || model.dictationHistoryRouteActive || model.dictationSettingsRouteActive" in window,
    "settings back", "hasDetail knows the settings route, so Back works")
pin("} else if section == .dictation, model.dictationSettingsRouteActive {\n                    DictationSettingsPane(model: model)" in window, "settings route",
    "the Dictation tab renders the settings pane on that flag")
pin("} else if section == .dictation, model.dictationSettingsRouteActive {\n            model.closeDictationSettings()" in window, "settings back",
    "Back closes the settings pane")
pin("if openDictationSettings, section == .dictation { model.openDictationSettings() }" in window
    and "activityOpenDictationSettings = true\n        openActivity?(.dictation)" in model, "settings route",
    "opening the settings from anywhere opens Activity on Dictation, then the settings")
pin('Button("Settings…") { model.openDictationSettingsInActivity() }' in app, "settings route", "the Dictation menu's Settings opens them in the tab")
# The menu-bar panel's Dictation chip opens the Dictation tab, which shows the pane: opener tied to render condition.
pin("+ [.dictation]" in window and "static var allCases: [ActivitySection] { visibleSections(environment: ProcessInfo.processInfo.environment) }" in window,
    "dictation chip", "Dictation is one of the sections the panel's chips come from")
pin("ForEach(ActivitySection.allCases) { item in\n                        activityChip(item)" in views and "openActivity(item)" in body(views, "    private func activityChip(_ item: ActivitySection) -> some View {"),
    "dictation chip", "every chip, Dictation's included, opens its own tab")
pin("case .dictation: DictationActivityPane(model: model)" in window, "dictation chip", "the Dictation tab renders the Dictation pane")
# G. 0.5.329: the shortcut recorder finishes a lone modifier from the keyboard's state when its release never arrives.
rec = body(d, "private struct DictationShortcutRow: View {")
wp = body(rec, "    private func watchPending(_ key: UInt16) {")
pin("if pendingModifier == key { watchPending(key) }" in rec and "var reads = DictationHoldWatch.Reads()" in wp
    and "DictationHoldWatch.modifierDown(flags: CGEventSource.flagsState(.hidSystemState).rawValue, keyCode: key)" in wp
    and "if reads.read(down: down) { finishModifier(key); break }" in wp and "monitor != nil, pendingModifier == key," in wp
    and "try? await Task.sleep(for: .milliseconds(DictationHoldWatch.pollMilliseconds))" in wp
    and "recorderWatch?.cancel(); recorderWatch = nil" in body(rec, "    private func stop() {"), "recorder release",
    "a pending lone modifier is finished by the hold watch's rule on the keyboard state, and the watch stops with the recorder")
# H. 0.5.329 crash (Studio Display Microphone, 2026-10-19 21:51): the tap uses the device's own format, read after the
# switch, never the node's stale outputFormat; one tap per bus; a spare only for the same device.
cap_start = body(d, "    func start(deviceID: AudioDeviceID?) throws {")
order(cap_start, ["try select(deviceID)", "let format = input.inputFormat(forBus: 0)", "guard format.sampleRate > 0, format.channelCount > 0,",
                  "input.removeTap(onBus: 0)", "input.installTap(onBus: 0, bufferSize: 2048, format: format)"], "tap format",
      "the tap format is the hardware format read after the device switch, checked, and the bus is cleared before the tap")
pin("outputFormat(" not in cap_start and 'throw error("The microphone format is unavailable.")' in cap_start, "tap format",
    "no stale outputFormat in start(), and an unusable format is the existing error, never a tap")
pin("_ = engine.inputNode.inputFormat(forBus: 0)" in body(d, "    func warm(deviceID: AudioDeviceID?) throws {"), "tap format", "the spare primes the same hardware format")
# 0.5.345 (A-W1): the check runs in vetSpare, on the input queue, with the selection read on the main actor first.
take_spare = body(d, "    private nonisolated static func vetSpare(")
pin("DictationSpare.check(held.warmed, selectedUID: selectedUID, device: device," in take_spare and "if case .discard" in take_spare
    and "let held = takeSpare(), selected = microphoneUID" in d, "spare device",
    "a spare is used only when the device it was built for is the device this press opens")
print("PASS dictation lock pins: refused, canceled, chord and reconciled presses written; the keyboard watched while held; STILL FINISHING; settings in the Dictation tab; the recorder finishes a swallowed release; the tap uses the device\'s own format")
