#!/usr/bin/env python3
"""Settings Release A mutation lane. Run by hand, never by a gate.

    python3 Tests/mutate-settings-a.py <worktree> <scratch dir> [name ...]

Copies the worktree to <scratch dir>/copy, proves each lane GREEN unmutated first (the rules and confirm checks, the hub
catalog checks, the dictation core checks, the wiring pins), then applies one mutant at a time: the target must appear exactly
once, the mutant must make its lane fail, and the failure must name the behaviour it breaks. The copy is restored and compared
byte for byte after every mutant. A mutant that lands and survives is a finding. Compiles go through the guard, one at a time.
"""
import pathlib, shutil, sys, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mutate_bounded as bounded

LIMIT = 900
R = "Sources/SettingsRules.swift"
CF = "Sources/COSConfirm.swift"
C = "Sources/SettingsHubCatalog.swift"
D = "Sources/MacDictationCore.swift"
V = "Sources/Views.swift"
M = "Sources/ControllerModel.swift"
DS = "Sources/MacDictation.swift"
SH = "Sources/SettingsHubViews.swift"
ASK = "Sources/MeetingAsk.swift"
KL = "Sources/KeyLanesViews.swift"
B = "Sources/COSBrand.swift"

LANES = {
    "rules": ["zsh", "Tests/run-settings-a.sh"],
    "hub": ["zsh", "Tests/run-settings-hub.sh"],
    "dict": ["zsh", "-c", 'BIN=$(mktemp /tmp/cos-md.XXXXXX); trap "rm -f $BIN" EXIT; R=$PWD; /usr/bin/python3 $R/Tests/kit-compile.py $R/Tests/compile-guard.sh swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library $R/Sources/MacDictationCore.swift $R/Tests/MacDictationChecks.swift -o $BIN && $BIN'],
    "pins": ["/usr/bin/python3", "Tests/settings-a-pins.py", "."],
}
GREEN = {"rules": ["settings rules checks:", "confirm return checks:"], "hub": ["settings hub checks:"], "dict": ["PASS Mac dictation:"], "pins": ["settings A pins:"]}

# (name, lane, file, target, replacement, words the failure must name)
MUTANTS = [
    # The nine restart rows
    ("apply: ignores running work", "rules", R, "        !locked && !work.active && differs(selected: selected, server: server)\n",
     "        !locked && differs(selected: selected, server: server)\n", "waits for a job"),
    ("apply: live with no change", "rules", R, "        guard let server else { return true }\n        return selected != server\n", "        return true\n",
     "off when the selection equals"),
    ("apply: live while the page is locked", "rules", R, "        !locked && !work.active && differs(", "        !work.active && differs(", "off while the page is locked"),
    ("work: a dictation is not running work", "rules", R, " || dictating || meetingBlocksRestart", " || meetingBlocksRestart", "a dictation counts"),
    ("work: an upload is not running work", "rules", R, "jobs + transcriptionSessions + macRecordings + uploads > 0", "jobs + transcriptionSessions + macRecordings > 0", "an upload counts"),
    ("work: a Mac recording is not running work", "rules", R, "jobs + transcriptionSessions + macRecordings + uploads > 0", "jobs + transcriptionSessions + uploads > 0", "a Mac recording counts"),
    ("work: the server's own block is ignored", "rules", R, " || meetingBlocksRestart || transactionPending\n", " || transactionPending\n", "meeting-work block"),
    ("work: a change in progress is ignored", "rules", R, " || meetingBlocksRestart || transactionPending\n", " || meetingBlocksRestart\n", "already in progress"),
    ("note: never says it waits", "rules", R, "        return notApplied + \" \" + waitsForWork + (work.uploads > 0 ? \" \" + uploadOpen : \"\")\n", "        return notApplied\n", "says it waits"),
    ("note: says Not applied for no change", "rules", R, "        guard differs else { return nil }\n        guard work.active || held", "        guard work.active || held", "no note when the row matches"),
    ("failure: keeps the refused choice", "rules", R, "static func reseeded<Value>(current: Value, server: Value?) -> Value { server ?? current }",
     "static func reseeded<Value>(current: Value, server: Value?) -> Value { current }", "shows the server's value"),
    # Confirms
    ("confirm: Return runs Delete", "rules", CF, "COSConfirmAction(label: label, kind: .destructive, takesReturn: false, run: run)",
     "COSConfirmAction(label: label, kind: .destructive, takesReturn: true, run: run)", "does not take Return"),
    ("confirm: the default may be destructive", "rules", CF, "actions.first(where: { $0.kind == .normal && $0.takesReturn })",
     "actions.first(where: { $0.takesReturn })", "still not the Return default"),
    ("quit: never asks", "rules", R, "static func quitNeedsConfirm(macRecordingActive: Bool) -> Bool { macRecordingActive }",
     "static func quitNeedsConfirm(macRecordingActive: Bool) -> Bool { false }", "quit asks while a Mac recording runs"),
    ("quit: always asks", "rules", R, "static func quitNeedsConfirm(macRecordingActive: Bool) -> Bool { macRecordingActive }",
     "static func quitNeedsConfirm(macRecordingActive: Bool) -> Bool { true }", "does not ask when nothing is recording"),
    ("rollback: silent about running work", "rules", R, "You can update again later.\" + (workRunning ? busy : \"\")", "You can update again later.\"",
     "rolling back while work runs says what happens"),
    ("repair: silent about a timeout", "rules", R, "Use it when the server is not working.\" + (workRunning ? repairBusy : \"\")", "Use it when the server is not working.\"",
     "what to do if it fails"),
    ("history: no count in the title", "rules", R, "\"Delete \\(count) older \\(count == 1 ? \"dictation\" : \"dictations\")?\"", "\"Delete older dictations?\"", "the count is in the title"),
    ("history: the cap is not counted", "dict", D, "        max(0, list.count - pruned(list, retention: retention, now: now).count)\n", "        max(0, list.count - list.count)\n",
     "the count a shorter time would delete"),
    # Typing, menus, caps
    ("typed: above the most is accepted", "rules", R, "        if number > high { return .clamped(high, note: \"The most is \\(high).\") }\n", "",
     "above the server's most"),
    ("typed: below the least is accepted", "rules", R, "        if number < low { return .clamped(low, note: \"The least is \\(low).\") }\n", "", "below the server's least"),
        ("menu: a saved value off the list vanishes", "rules", R, "        values.insert(current)\n", "", "off the list is added"),
    ("menu: the off-list value is not marked", "rules", R, "value == current && offList ? title(value) + \" (your setting)\" : title(value)", "title(value)",
     "says it is the person's own"),
    ("cap: the saved cap has no line", "rules", R, "        if let saved, !presets.contains(where: { abs($0 - saved) < 0.005 }) {\n", "        if false, let saved {\n", "its own line"),
    ("cap: Other amount does not stay open", "rules", R, "        if otherOpen { return other }\n", "", "Other amount stays picked"),
    ("cap: Set cap live for the saved amount", "rules", R, "        return abs(value - saved) >= 0.005\n", "        return true\n", "off for the saved amount"),
    ("cap: a typed amount reads as a preset", "rules", R, "        if let preset = presets.first(where: { abs($0 - value) < 0.005 }) { return presetID(preset) }\n", "", "the face is a real choice"),
    # Versions
    # The microphone listener
    ("mics: a second start registers again", "rules", R, "        guard stopListening == nil else { return }\n", "", "does not register again"),
    ("mics: every change refreshes", "rules", R, "        pending?.cancel()\n        pending = Task { [weak self] in", "        pending = Task { [weak self] in", "refresh once"),
    ("mics: stop leaves the listener", "rules", R, "        stopListening?()\n        stopListening = nil\n", "        stopListening = nil\n", "stop removes the listener"),
    ("mics: stop neither cancels nor forgets the callback", "rules", R, "        pending?.cancel(); pending = nil\n        stopListening?()\n        stopListening = nil\n        refresh = nil\n", "        stopListening?()\n        stopListening = nil\n", "stop cancels a refresh that was waiting"),
    ("mics: the page callback never reaches the refresh", "rules", R, "            self.refresh?()\n", "", "reaches the refresh"),
    # Hub catalog
    ("gates: a hidden option opens itself", "hub", C, "            current = gate.parent\n            steps += 1\n        }\n        return current\n", "            current = id\n            steps += 1\n        }\n        return current\n", "opens the Today home switch"),
    ("gates: a chain stops after one", "hub", C, "steps < 8 {\n            current = gate.parent", "steps < 1 {\n            current = gate.parent",
     "climbs past Paste then polish"),
    ("gates: a drawn row climbs", "hub", C, "        while hidden(current), let gate = gatedBy[current], steps < 8 {\n            current = gate.parent", "        while let gate = gatedBy[current], steps < 8 {\n            current = gate.parent", "a drawn row opens itself"),
    ("gates: a gate line for a drawn row", "hub", C, "        guard hidden(id) else { return nil }\n        var current = id\n", "        var current = id\n", "only for a hidden gated row"),
    ("gates: the option leaves the catalog", "hub", C, '        "WK-07": Gate(parent: "WK-06", line: "Turn on Today home to change this."),\n', "", "Quiet hours"),
    ("sidebar: Up wraps", "hub", C, "case .up: return all[max(0, index - 1)]", "case .up: return all[(index + all.count - 1) % all.count]", "Up stops at the first"),
    ("sidebar: Down wraps", "hub", C, "case .down: return all[min(all.count - 1, index + 1)]", "case .down: return all[(index + 1) % all.count]", "Down stops at the last"),
    ("sidebar: Down moves two", "hub", C, "case .down: return all[min(all.count - 1, index + 1)]", "case .down: return all[min(all.count - 1, index + 2)]", "move one category"),
    ("rename: Saved meetings back to Final model", "hub", C, '.init("TR-03", "Saved meetings"', '.init("TR-03", "Final model"', "as the page draws it"),
    ("rename: Refine with second", "hub", C, '.init("TR-06", "Refine with second opinion"', '.init("TR-06", "Refine with second"', "Refine with second opinion"),
    ("rename: Domains back", "hub", C, '.init("DM-01", "Task folders"', '.init("DM-01", "Domains"', "Domains is Task folders"),
    ("rename: Save domains not searchable", "hub", C, 'keywords: ["save domains"]', 'keywords: []', "save domains"),
    ("rename: Pet and appearance back", "hub", C, '        case .pet: "Pet"\n', '        case .pet: "Pet and appearance"\n', "Pet and appearance is Pet"),
    ("rename: appearance not found", "hub", C, 'keywords: ["session pet", "sprite", "character", "appearance"]', 'keywords: ["session pet", "sprite", "character"]', "still finds the pet rows"),
    # Review round (Opus review of claude/control-settings-a)
    ("escape: the stack is first in, first out", "rules", B, "        guard let top = entries.popLast() else { return false }\n", "        guard !entries.isEmpty else { return false }\n        let top = entries.removeFirst()\n", "the field opened last closes first"),
    ("escape: a closed thing stays registered", "rules", B, "    static func unregister(_ id: UUID) { entries.removeAll { $0.id == id } }\n", "    static func unregister(_ id: UUID) { }\n", "a thing that closed on its own is forgotten"),
    ("escape: registering twice keeps both", "rules", B, "        unregister(id)\n        entries.append((id, close))\n", "        entries.append((id, close))\n", "registering twice keeps one"),
    ("escape: closing uses nothing up", "rules", B, "        guard let top = entries.popLast() else { return false }\n        top.close()\n        return true\n", "        guard let top = entries.last else { return false }\n        top.close()\n        return true\n", "then Escape is free"),
    ("wire: Escape ignores dialogs and typed fields", "pins", V, "        if COSEscape.closeTop() { return true }\n", "", "closes an open dialog or a typed field first"),
    ("wire: a confirm never registers", "pins", CF, "            if now { COSEscape.register(escapeID) { isPresented = false } } else { COSEscape.unregister(escapeID) }\n", "", "registers while it is on screen"),
    ("wire: a focused typed field never registers", "pins", B, "if now { COSEscape.register(escapeID) { cancelTyping() } } else { COSEscape.unregister(escapeID); commitTyped() }", "if now { } else { COSEscape.unregister(escapeID); commitTyped() }", "a typed stepper in focus is closed by Escape"),
    ("wire: Escape in the field still sends the number", "pins", B, "        if escaped { escaped = false; draft = valueText ?? \"\"; return }\n", "", "puts the value back and sends nothing"),
    ("repair: points at itself", "rules", R, "If it fails, run Repair again once the work has finished.", "leaves the server closed until you run Repair.", "the repair dialog never sends you to repair"),
    ("stop: no way out", "pins", V, "Stop is off until running work finishes. Stuck? Use Repair in Troubleshooting.", "Stop is off until running work finishes.", "Stop says how to get unstuck"),
    ("wire: a tripped click leaves the row quiet", "pins", V, "            restartHeldRow = id\n            return\n", "            return\n", "draws the row again with its note"),
    ("wire: the held note outlives the work", "pins", V, "            if !active { restartHeldRow = nil }\n", "", "the note goes with the work"),
    ("held: a click that found work says nothing", "rules", R, "guard work.active || held else { return notApplied }", "guard work.active else { return notApplied }", "before the work is drawn"),
    ("uploads: not named", "rules", R, "(work.uploads > 0 ? \" \" + uploadOpen : \"\")", "\"\"", "an open upload is named"),
    ("uploads: named for every kind of work", "rules", R, "(work.uploads > 0 ? \" \" + uploadOpen : \"\")", "\" \" + uploadOpen", "other work does not mention uploads"),
    ("cap: no not-set-yet note", "rules", R, "        canSet(draft: draft, saved: saved, parse: parse) ? notSet : nil\n", "        nil\n", "a picked amount says it is not set yet"),
    ("cap: the note for the saved cap", "rules", R, "        canSet(draft: draft, saved: saved, parse: parse) ? notSet : nil\n", "        notSet\n", "no note while the face is the saved cap"),
    ("wire: the cap note is not drawn", "pins", KL, "            if let note = DailyCap.note(draft: draft, saved: key.capUsd, parse: KeyLanes.parseCap) {\n", "            if let note = Optional<String>.none {\n", "a picked cap says it is not set yet"),
    ("failure: forgets other choices were reset", "rules", R, "        return othersReset ? base + \" Other choices not applied yet were reset too.\" : base\n", "        return base\n", "other unapplied choices were reset"),
    ("failure: always says others were reset", "rules", R, "        return othersReset ? base + \" Other choices not applied yet were reset too.\" : base\n", "        return base + \" Other choices not applied yet were reset too.\"\n", "a failure that reset nothing else says nothing"),
    ("wire: others reset never counted", "pins", V, "                restartOthersReset = restartRowsUnapplied(except: failure?.command) > 0\n", "                restartOthersReset = false\n", "counts other unapplied choices"),
    ("wire: the hub failure is plain text again", "pins", V, "(state.failed ? \"\" : state.note.map { \" \" + $0 } ?? \"\")", "(state.note.map { \" \" + $0 } ?? \"\")", "its own amber line in the hub"),
    ("versions: a missing version means stopped", "rules", R, "return running ? \"Controller \\(controller)  •  Server \\(shown)\" : \"Controller \\(controller)  •  Server \\(shown) (not running)\"", "return version != nil ? \"Controller \\(controller)  •  Server \\(shown)\" : \"Controller \\(controller)  •  Server \\(shown) (not running)\"", "a running server whose version has not come back"),
    ("versions: a stopped server with a version reads as running", "rules", R, "return running ? \"Controller \\(controller)  •  Server \\(shown)\" : \"Controller \\(controller)  •  Server \\(shown) (not running)\"", "return \"Controller \\(controller)  •  Server \\(shown)\"", "still reports a version says it is not running"),
    ("wire: the footer ignores the server's running state", "pins", V, "running: model.status.running, selfManaged:", "running: true, selfManaged:", "takes running from the server's status"),
    ("gates: the nearest step is named", "hub", C, "            first = gate\n            current = gate.parent\n", "            current = gate.parent\n", "names the first missing step"),
    ("mics: a plug lists devices on the main actor", "pins", DS, "            let list = await DictationAudioDevices.inputsOffMain()\n            self?.microphones = list\n        }\n    }\n    /// The cached list", "            let list = DictationAudioDevices.inputs()\n            self?.microphones = list\n        }\n    }\n    /// The cached list", "lists devices off the main actor"),
    # Wiring
    ("wire: Stop runs on one click", "pins", V, 'Button("Stop", systemImage: "stop.fill", role: .destructive) { serverConfirm = .stop }', 'Button("Stop", systemImage: "stop.fill", role: .destructive) { model.perform("stop") }', "Stop and Repair have one caller"),
    ("wire: Stop ignores running work", "pins", V, "                    .disabled(serverRestartHeld || (model.status.runtimeState == \"managedInPlace\" && !model.status.safeToRestart))\n",
     "                    .disabled(model.status.runtimeState == \"managedInPlace\" && !model.status.safeToRestart)\n", "Stop waits for running work"),
    ("wire: Repair runs on one click", "pins", V, 'Button("Repair server", systemImage: "wrench.and.screwdriver") { serverConfirm = .repair }', 'Button("Repair server", systemImage: "wrench.and.screwdriver") { model.perform("repair") }', "Stop and Repair have one caller"),
    ("wire: the panel's Roll back runs on one click", "pins", V, 'Button("Roll back server") { serverConfirm = .rollback }', 'Button("Roll back server") { model.perform("rollback") }', "Roll back has two callers"),
    ("wire: Quit skips the question", "pins", V, 'Button("Quit", systemImage: "power") { requestQuit() }', 'Button("Quit", systemImage: "power") { AppQuit.request() }', "both Quit buttons go through requestQuit"),
    ("wire: the confirm's action is not destructive", "pins", V, "            .destructive(SettingsConfirmCopy.action(pending)) {\n", "            .normal(SettingsConfirmCopy.action(pending)) {\n", "only inside the confirm's destructive action"),
    ("wire: the click does not check the work", "pins", V, "        guard RestartApply.applyEnabled(selected: selected, server: server, locked: serverSettingsLocked, work: restartWork) else {\n            restartHeldRow = id\n            return\n        }\n", "", "checks the work running now"),
    ("wire: a row keeps no server comparison", "pins", V, "isOn: $selectedThreadAttach, server: model.status.threadAttachEnabled) {", "isOn: $selectedThreadAttach, server: nil) {", "UT-07 compares"),
    ("wire: Quality tier ignores running work", "pins", V, 'let state = restartState("UT-03", selected: selectedTranscriptionTier, server: server)', 'let state = RestartRowState(enabled: true, note: nil, failed: false)', "UT-03 compares"),
    ("wire: video uploads never count", "pins", V, "                          uploads: model.status.videoUploadV2Receiving + model.status.videoUploadV2Finalizing,\n", "                          uploads: 0,\n", "videoUploadV2Receiving"),
    ("wire: a Mac recording never counts", "pins", V, "macRecordings: model.recordingCount, ", "macRecordings: 0, ", "model.recordingCount"),
    ("wire: a failed Apply keeps the refused choice", "pins", V, "                reseedRestartDrafts()\n", "", "then reseeds them"),
    ("wire: the failure is recorded before the re-read", "pins", M, "                await refresh(quiet: true)\n                // After the re-read, so a row that reseeds from the status shows the server's value, not the refused one.\n                if RestartApply.row(forCommand: command) != nil {\n                    self.restartApplyFailure = RestartApplyFailure(command: command, message: error.localizedDescription)\n                }\n",
     "                if RestartApply.row(forCommand: command) != nil {\n                    self.restartApplyFailure = RestartApplyFailure(command: command, message: error.localizedDescription)\n                }\n                await refresh(quiet: true)\n", "after the status re-read"),
    ("wire: any command records a failure", "pins", M, "                if RestartApply.row(forCommand: command) != nil {\n", "                if true {\n", "only the nine rows"),
    ("wire: the typed stepper clamps nothing", "pins", ASK, "let result = TypedCount.parse(text, low: low, high: high)", "let result = TypedCount.Result.value(Int(text) ?? low)", "inside the server's bounds"),
    ("wire: the gap is a stepper again", "pins", ASK, "            let choices = ValueMenu.choices(stops: LiveCues.ladder(key, limit), current: shown, title: { LiveCues.countText(key, $0) })\n", "            let choices: [ValueMenu.Choice] = []\n", "menus from the server's bounds"),
    ("wire: the cap is a bare field again", "pins", KL, "            capControls(key)\n", '            TextField(KeyLanes.capLabel, text: .constant(""))\n', "not a bare field"),
    ("wire: picking a cap sends it", "pins", KL, "                        capEdits[key.ref] = KeyLanes.capArgument(amount); capOtherOpen.remove(key.ref)\n", "                        Task { await store.setCap(amount, keyRef: key.ref, run: keyLanesRun(model)) }\n", "nothing sends on pick"),
    ("wire: the microphone list never follows the Mac", "pins", DS, "                micWatcher.start { [store] in store.refreshMicrophonesOffMain() }\n", "", "follows the Mac"),
    ("wire: the listener is never removed", "pins", DS, "        .onDisappear { micWatcher.stop() }\n", "", "follows the Mac"),
    ("wire: Quiet hours always drawn", "pins", V, "                if todayHomeEnabled {\n                    hubSwitch(\"WK-07\", isOn: $todayQuietHours)", "                if true {\n                    hubSwitch(\"WK-07\", isOn: $todayQuietHours)", "drawn only while Today home is on"),
    ("wire: Wait for held keys always drawn", "pins", DS, "                if store.pasteThenPolish {\n", "                if true {\n", "Wait for held keys needs Paste then polish"),
    ("wire: polish instructions hidden with polish off", "pins", DS, "                DictationPolishInstructionsCard(store: DictationPolishInstructionsStore.shared, polishOn: store.polishModel != .off, model: store.polishModel)\n",
     "                if store.polishModel != .off { DictationPolishInstructionsCard(store: DictationPolishInstructionsStore.shared, polishOn: store.polishModel != .off, model: store.polishModel) }\n", "stay drawn"),
    ("wire: a result for a hidden option lands nowhere", "pins", V, 'reader.scrollTo("item." + landing, anchor: .center)', 'reader.scrollTo("item." + item.id, anchor: .center)', "opens its switch"),
    ("wire: search does not say what to turn on", "pins", SH, "                if let gate = gateLine(item) {\n", "                if let gate = Optional<String>.none {\n", "shows that sentence"),
    ("wire: the page draws HQ model", "pins", ASK, 'SettingsHubRow(label: "Saved meetings"', 'SettingsHubRow(label: "HQ model"', "draws Saved meetings"),
    ("wire: the footer claims npm latest", "pins", V, "        VersionsLine.text(controller: ControllerModel.currentVersion, version: model.status.version, installed: model.status.installedVersion,\n", "        \"npm latest\" + VersionsLine.text(controller: ControllerModel.currentVersion, version: model.status.version, installed: model.status.installedVersion,\n", "never says npm latest"),
    ("wire: Up does nothing", "pins", SH, "        .onKeyPress(.upArrow) { select(SettingsHubSidebarKeys.next(from: selected, .up)); return .handled }\n", "", "Up and Down move in the sidebar"),
    ("wire: Domains unreachable in Setup", "pins", "Sources/SetupAssistant.swift", '["work.domains": ["Domains"]]', '[:]', "typing Domains"),
    ("wire: a compile list leaves out the rules", "pins", "scripts/build-release.sh", '"$ROOT/Sources/SettingsRules.swift" ', "", "leaves out SettingsRules.swift"),
    ("wire: the stepper field cannot be escaped", "pins", B, "                        .onExitCommand { cancelTyping() }\n", "", "closed by Escape"),
    ("wire: the history change applies at once", "pins", DS, "if count > 0 { shortenCount = count; shorteningTo = next } else { store.setRetention(next) }", "store.setRetention(next)", "a shorter dictation history asks first"),
]


def run_lane(copy, lane):
    started = time.time()
    for _ in range(20):
        result = bounded.run(LANES[lane], LIMIT, cwd=copy)
        out = result.stdout + result.stderr
        if "infrastructure-error" not in out:
            break
        time.sleep(15)
    if "compile-guard: STOPPED" in out:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + out[-400:])
    return result.returncode, out, time.time() - started, result.timed_out


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "HelperSources", "scripts", "docs"):
        shutil.copytree(src / part, copy / part)
    wanted = {m[1] for m in MUTANTS if not only or m[0] in only}
    for lane in LANES:
        if lane not in wanted:
            continue
        code, out, seconds, _ = run_lane(copy, lane)
        passed = [l for l in out.splitlines() if any(l.startswith(g) for g in GREEN[lane])]
        print(f"BASELINE {lane} (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(passed) or '(no PASS line)'}", flush=True)
        if code != 0 or len(passed) != len(GREEN[lane]) or "FAILED" in " ".join(passed):
            print(out[-3000:])
            sys.exit(f"baseline {lane} is not green; no mutant may be judged against a red lane")
    killed = survived = 0
    for name, lane, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out, seconds, timed_out = run_lane(copy, lane)
        finally:
            path.write_text(text, encoding="utf-8")
        if path.read_text(encoding="utf-8") != text:
            sys.exit(f"RESTORE FAILED for {name}: {rel} differs from its unmutated text")
        lines = [l for l in out.splitlines() if l.startswith("FAIL: ") or "pin FAILED" in l or ": error:" in l]
        reason = " | ".join(l.strip() for l in lines[:6]) if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if timed_out:
            killed += 1; print(f"killed  {name}: TIMEOUT after {LIMIT} s (no named check)", flush=True)
        elif code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:200]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:300]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 else 1)


if __name__ == "__main__":
    main()
