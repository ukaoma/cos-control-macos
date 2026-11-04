#!/usr/bin/env python3
"""Settings Release A (Miles, 2026-11-03, "go a"): the wiring pins the compiled rules cannot see.

    python3 Tests/settings-a-pins.py <root>

  - Destructive confirms: Stop, Roll back (the panel's), Repair and Quit during a Mac recording run only from the one confirm;
    Return runs no destructive action; a shorter dictation history asks first.
  - The nine restart rows: Apply is live only for a change, never while work runs, checked again at the click; a failed Apply
    reseeds the choice from the server after the status re-read.
  - The right control per value, from the server's bounds: a typed stepper for cues per meeting, menus for the gap and the daily
    writer calls, presets plus Other amount for the daily cap.
  - The microphone list follows the Mac, with Check again kept.
  - Options hidden until their switch is on, found by search, landing on the switch.
  - The renames: the catalog names what the page draws; old names stay searchable.
  - The Versions line never claims npm latest. Up and Down move in the sidebar. The new file is in every full-app compile list.
Prints "settings A pins: N passed". Exits 1 on the first failure, naming it.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = 0


def pin(ok, what):
    global passed
    if not ok:
        print(f"settings A pin FAILED: {what}")
        sys.exit(1)
    passed += 1


def read(rel):
    return (root / rel).read_text(encoding="utf-8")


def code(text):
    """The text without // comments: a comment may name a thing, code must do it."""
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


def body(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i + len(start))]


views = code(read("Sources/Views.swift"))
model = code(read("Sources/ControllerModel.swift"))
confirm = code(read("Sources/COSConfirm.swift"))
dictation = code(read("Sources/MacDictation.swift"))
ask = code(read("Sources/MeetingAsk.swift"))
lanes = code(read("Sources/KeyLanesViews.swift"))
catalog = read("Sources/SettingsHubCatalog.swift")
shell = code(read("Sources/SettingsHubViews.swift"))
brand = code(read("Sources/COSBrand.swift"))
rules = read("Sources/SettingsRules.swift")
setup = code(read("Sources/SetupAssistant.swift"))

# 1. Destructive confirms.
pin("static func destructive(_ label: String, _ run: @escaping @MainActor () -> Void) -> COSConfirmAction {\n        COSConfirmAction(label: label, kind: .destructive, takesReturn: false, run: run)" in confirm,
    "a destructive action is built without Return")
pin("COSConfirmAction.returnDefault(in: actions)?.id" in confirm and "actions.first(where: { $0.kind == .normal && $0.takesReturn })" in confirm
    and ".kind == .destructive && $0.takesReturn" not in confirm, "the Return default is a normal action only")
chain = body(views, "    private var panelWithServerConfirm: some View {", "    var body: some View {")
pin(chain.count(".cosConfirm(") == 1 and "panelWithSecondaryConfirms" in chain and "serverConfirmActions" in chain,
    "one confirm for the four server actions, in a stage of its own after the secondary one (the type-checker's limit)")
pin("panelWithServerConfirm\n        .cosConfirm(\n            pendingOpenPetsRow" in views, "the body continues from the new stage")
actions = body(views, "    private var serverConfirmActions: [COSConfirmAction] {", "    private func requestQuit() {")
pin(".destructive(SettingsConfirmCopy.action(pending))" in actions and actions.count("model.perform(") == 3 and "AppQuit.request()" in actions,
    "Stop, Roll back and Repair run, and Quit happens, only inside the confirm's destructive action")
pin(views.count('model.perform("stop")') == 1 and views.count('model.perform("repair")') == 1, "Stop and Repair have one caller: the confirm")
pin(views.count('model.perform("rollback")') == 2 and "Button(\"Roll back\") { confirmHubRollback = false; model.perform(\"rollback\") }" in views,
    "Roll back has two callers: the confirm, and the hub's own inline card that already asked")
pin(views.count("serverConfirm = .stop") == 1 and views.count("serverConfirm = .repair") == 2 and views.count("serverConfirm = .rollback") == 1,
    "the Stop button, both Repair buttons and the panel's Roll back open the confirm")
pin(views.count("AppQuit.request()") == 2 and views.count("requestQuit()") == 3, "both Quit buttons go through requestQuit; AppQuit.request has the confirm and the unconfirmed quit")
pin("SettingsConfirmCopy.quitNeedsConfirm(macRecordingActive: model.macRecordingActive)" in views, "Quit asks while a Mac recording runs")
pin("Stop is off until running work finishes. Stuck? Use Repair in Troubleshooting." in views, "Stop says how to get unstuck while it waits")
pin(".disabled(serverRestartHeld || (model.status.runtimeState == \"managedInPlace\" && !model.status.safeToRestart))" in views
    and views.count(".disabled(serverRestartHeld)") == 1, "Stop waits for running work like Restart")
hub_escape = body(views, "    func hubEscape() -> Bool {", "\n    }\n")
pin("if COSEscape.closeTop() { return true }" in hub_escape and hub_escape.index("COSEscape.closeTop()") < hub_escape.index("hubSearching") and "serverConfirm" not in hub_escape,
    "Escape closes an open dialog or a typed field first, before a search, and only then leaves Settings")
pin("COSEscape.register(escapeID) { isPresented = false }" in confirm and "COSEscape.unregister(escapeID)" in confirm and confirm.count("COSEscape.") == 3,
    "every confirm, whichever view owns it, registers while it is on screen and forgets when it goes")
pin("COSEscape.register(escapeID) { cancelTyping() }" in brand and ".onExitCommand { cancelTyping() }" in brand and ".onDisappear { COSEscape.unregister(escapeID) }" in brand
    and "if escaped { escaped = false; draft = valueText ?? \"\"; return }" in brand
    and brand.index("if escaped { escaped = false; draft = valueText ?? \"\"; return }") < brand.index("if text != (valueText ?? \"\") { onTypedValue?(text) }"),
    "a typed stepper in focus is closed by Escape, which puts the value back and sends nothing, even though losing focus commits")
settings = body(dictation, "struct MacDictationSettings: View {", "private struct DictationQuietSettings: View {")
pin("DictationHistory.deleted(store.recent, retention: next, now: Date())" in settings and "shorteningTo = next" in settings
    and ".destructive(SettingsConfirmCopy.shortenAction(count: shortenCount, days: target.days)) { store.setRetention(target) }" in settings,
    "a shorter dictation history asks first, with the count")

# 2. The nine restart rows.
section = body(views, "    private var serverSettingsLocked: Bool {", "    @ViewBuilder private var noticeBanner: some View {")
for rid in ("UT-04", "UT-05", "UT-06", "UT-07", "UT-11", "UT-12"):
    pin(re.search(rf'applySwitch\(hub, id: "{rid}",[^{{]*?server: model\.status\.\w+\) \{{', section) is not None, f"{rid} compares with the server's value")
for rid in ("UT-03", "UT-08", "UT-09"):
    pin(f'restartState("{rid}", selected:' in section and f'restartApply("{rid}", selected:' in section, f"{rid} compares with the server's value and checks again at the click")
pin("waitsForWork" not in section and "applyBlocked" not in section, "no row keeps its own gate: all nine use RestartApply")
pin(section.count(".disabled(!state.enabled)") == 8 and section.count("Button(\"Apply\"") == 8, "every Apply is disabled by RestartApply (eight sites draw the nine rows)")
pin(section.count("Apply \" +") + section.count('accessibilityLabel("Apply ') >= 8, "every Apply says which setting it applies, for VoiceOver")
pin("RestartApply.applyEnabled(selected: selected, server: server, locked: serverSettingsLocked, work: restartWork) else {" in section,
    "the click checks the work running now, not the work when the row drew")
work = body(section, "    private var restartWork: RestartApply.Work {", "    private struct RestartRowState {")
for field in ("model.status.activeJobs", "model.status.activeTranscriptionSessions", "model.recordingCount", "model.dictation.busy", "videoUploadV2Receiving",
              "videoUploadV2Finalizing", "meetingWorkBlockingRestart", "transactionPending"):
    pin(field in work, f"restart work counts {field}")
pin("restartOthersReset = restartRowsUnapplied(except: failure?.command) > 0\n                reseedRestartDrafts()" in views, "a failed Apply counts other unapplied choices, then reseeds them")
pin("restartHeldRow = id\n            return" in views and "held: restartHeldRow == id" in views and "if !active { restartHeldRow = nil }" in views,
    "a click that finds running work draws the row again with its note, and the note goes with the work")
pin(views.count("hubFailureNote(state)") == 4 and "state.failed ? \"\" : state.note" in views and "SettingsHubNote(text: note, tone: .warning)" in views,
    "a failed Apply is its own amber line in the hub, under each of the four hub row shapes")
perform = body(model, "    func perform(_ command: String, arguments: [String] = []) {", "    func installCurrentRelease()")
pin("restartApplyFailure = nil" in perform.split("Task {")[0] and perform.rindex("await refresh(quiet: true)") < perform.index("self.restartApplyFailure = RestartApplyFailure"),
    "a failure is recorded after the status re-read, and cleared when the next command starts")
pin("RestartApply.row(forCommand: command) != nil" in perform, "only the nine rows' commands record a failure")

# 3. The right control per value.
limits = body(ask, "struct LiveCuesLimitsRows: View {", "struct TranscriptionSettingsCard: View {")
pin("LiveCues.range(key, limit)" in limits and "TypedCount.parse(text, low: low, high: high)" in limits and "onTypedValue:" in limits,
    "cues per meeting is a stepper you can type into, inside the server's bounds")
pin("ValueMenu.choices(stops: LiveCues.ladder(key, limit), current: shown" in limits and "COSDropdown(title(key)" in limits,
    "the gap and the daily writer calls are menus from the server's bounds, with the saved value on them")
pin(limits.count("store.propose(") == 2, "the bar and one move function are the only ways to a limit")
pin("var onTypedValue: ((String) -> Void)?" in brand and ".onExitCommand { cancelTyping() }" in brand
    and "if text != (valueText ?? \"\") { onTypedValue?(text) }" in brand, "the typed stepper sends on Return or blur, and Esc puts the value back")
key_row = body(lanes, "    private func keyRow(_ key: KeyLanesKey) -> some View {", "    private func capControls(_ key: KeyLanesKey) -> some View {")
pin("DailyCap.note(draft: draft, saved: key.capUsd, parse: KeyLanes.parseCap)" in lanes, "a picked cap says it is not set yet")
pin("capControls(key)" in key_row and "TextField(KeyLanes.capLabel" not in key_row, "a key's cap is the preset menu, not a bare field")
caps = body(lanes, "    private func capControls(_ key: KeyLanesKey) -> some View {", "    private var addKey: some View {")
pin("DailyCap.choices(saved: key.capUsd)" in caps and "DailyCap.face(draft: draft, saved: key.capUsd" in caps and "DailyCap.canSet(draft: draft, saved: key.capUsd, parse: KeyLanes.parseCap)" in caps
    and "store.setCap(cap" in caps and caps.count("store.setCap(") == 1, "presets, the saved cap, Other amount; Set cap sends the draft and nothing sends on pick")
pin("newKeyCap" in lanes and 'Text("Cap $")' not in lanes, "the new key's cap is the same menu")

# 4. Microphones.
pin("micWatcher.start { [store] in store.refreshMicrophonesOffMain() }" in dictation and "await DictationAudioDevices.inputsOffMain()" in dictation.split("func refreshMicrophonesOffMain()")[1].split("\n    }\n")[0],
    "a plug or unplug lists devices off the main actor")
pin("micWatcher.start { [store] in store.refreshMicrophonesOffMain() }" in dictation and ".onDisappear { micWatcher.stop() }" in dictation
    and dictation.count("Button(\"Check again\") { store.refreshMicrophones() }") == 2 and "Refresh microphones\") {" not in dictation,
    "the microphone list follows the Mac and keeps Check again")

# 5. Hidden options.
hub_home = body(views, '        hubCard("general.home") {', '        hubCard("general.guide")')
pin(re.search(r'if todayHomeEnabled \{\s*hubSwitch\("WK-07", isOn: \$todayQuietHours\)\s*hubSwitch\("WK-08", isOn: \$todayWorkRuns\)\s*\}', hub_home) is not None,
    "Quiet hours and Work runs are drawn only while Today home is on")
polish = body(dictation, '                .settingsHubRow().settingsHubAnchor("DI-23")', 'DictationPolishInstructionsCard(store:')
pin("if store.polishModel != .off {" in polish and "if store.pasteThenPolish {" in polish and polish.index("if store.polishModel != .off {") < polish.index("DI-24") < polish.index("if store.pasteThenPolish {") < polish.index("DI-25"),
    "Paste then polish needs a model; Wait for held keys needs Paste then polish")
card_lines = [l for l in dictation.split("\n") if "DictationPolishInstructionsCard(store:" in l]
pin(len(card_lines) == 1 and card_lines[0].strip().startswith("DictationPolishInstructionsCard(") and "DictationStyleCard(" in dictation
    and "if store.polishModel != .off {" not in dictation.split("DictationPolishInstructionsCard(")[1].split("DictationStyleCard(")[0],
    "Your polish instructions and Your style stay drawn: the glasses use them with AI polish off")
pin('"WK-07": Gate(parent: "WK-06"' in catalog and '"DI-25": Gate(parent: "DI-24"' in catalog, "every hidden option names the switch that holds it")
hidden_fn = body(views, "    func hubOptionHidden(_ id: String) -> Bool {", "\n    }\n")
pin('case "WK-07", "WK-08": return !todayHomeEnabled' in hidden_fn and 'case "DI-24":' in hidden_fn and 'case "DI-25":' in hidden_fn, "the page's test for a hidden option covers all four")
pin("SettingsHubCatalog.landing(item.id, hidden: hubOptionHidden)" in views and 'reader.scrollTo("item." + landing, anchor: .center)' in views
    and "SettingsHubCatalog.gateLine($0.id, hidden: hubOptionHidden)" in views, "a result for a hidden option opens its switch and says what to turn on")
pin("gateLine(item)" in shell, "the result row shows that sentence")

# 6. Renames: what the catalog says is what the page draws.
pin('SettingsHubRow(label: "Saved meetings"' in ask and 'picker("Saved meetings", .hq' in ask and '"HQ model"' not in ask, "the page draws Saved meetings")
pin('"TR-03", "Saved meetings"' in catalog and '"TR-06", "Refine with second opinion"' in catalog, "the catalog names Saved meetings and Refine with second opinion")
pin('SettingsHubRow(label: "Refine with second opinion"' in ask and 'Toggle("Refine with second opinion"' in ask, "the page draws Refine with second opinion")
pin('Text("Task folders").font(.headline)' in views and 'title: "Task folders"' in catalog and 'title: "Task folders"' in setup and '"DM-01", "Task folders"' in catalog,
    "the page, the catalog and the Setup assistant call Domains Task folders")
pin('case .pet: "Pet"' in catalog and 'parent: "Pet and appearance"' not in setup and 'Pet and appearance' not in views, "Pet and appearance is Pet")
pin('"work.domains": ["Domains"]' in setup, "typing Domains in the Setup assistant still finds Task folders")
pin('"DI-03", "Check again"' in catalog, "the catalog names Check again")

# 7. The Versions line.
pin("running: model.status.running, selfManaged:" in views, "the Versions line takes running from the server's status, not from a missing version")
pin("VersionsLine.text(controller: ControllerModel.currentVersion" in views and "npm latest" not in views, "the Versions line never says npm latest")

# 8. Sidebar keys.
pin(".onKeyPress(.upArrow) { select(SettingsHubSidebarKeys.next(from: selected, .up)); return .handled }" in shell
    and ".onKeyPress(.downArrow) { select(SettingsHubSidebarKeys.next(from: selected, .down)); return .handled }" in shell
    and "sidebarFocused = true" in shell, "Up and Down move in the sidebar")

# 9. The new file is in every full-app compile list that has the hub's catalog.
lists = 0
for path in sorted(list(root.glob("scripts/*.sh")) + list(root.glob("Tests/*.sh"))):
    text = path.read_text(encoding="utf-8")
    for line in text.split("\n"):
        if "Sources/SettingsHubViews.swift" in line:
            lists += 1
            pin('"$ROOT/Sources/SettingsRules.swift"' in line, f"{path.relative_to(root)}: a full-app compile list leaves out SettingsRules.swift")
pin(lists >= 10, f"the compile lists were found ({lists})")
pin("import CoreAudio" in code(rules) and "import SwiftUI" not in code(rules) and "import AppKit" not in code(rules), "the rules file stays free of views")
tests = read("Tests/run.sh")
pin(tests.count('zsh "$ROOT/Tests/run-settings-a.sh"') == 1 and tests.count('/usr/bin/python3 "$ROOT/Tests/settings-a-pins.py" "$ROOT"') == 1,
    "the full suite runs these checks and pins once")

strings = re.findall(r'"((?:[^"\\]|\\.)*)"', code(rules))
bad = [s for s in strings if "—" in s or "→" in s or "->" in s]
pin(not bad, f"no em dash or arrow in the new words: {bad[:3]}")

print(f"settings A pins: {passed} passed")
