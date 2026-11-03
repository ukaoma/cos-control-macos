#!/usr/bin/env python3
"""0.5.322: wiring pins for the Live cues switch in Settings (LiveCuesSettingsRow in Sources/MeetingAsk.swift).

The words and the store run in Tests/LiveCuesChecks.swift, and the helper's live-cues-settings in its self-test and
Tests/live-cues-helper-checks.py. These pin what a SwiftUI view, the panel and the release files do, which those
cannot execute: the row sits in the Meeting assistant card, the switch is drawn only for a server that answered and
moves only through the store, the key button lands on Decision models opened (where the Jev and SubQ key fields are),
nothing opens a sheet or an alert, the app reaches the server only through the helper, and the version is 0.5.322.
Prints "live cues pins: N passed". Usage: live-cues-pins.py <checkout>
"""
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
passed = 0


def check(condition, what):
    global passed
    if not condition:
        print(f"live cues pin FAILED: {what}")
        sys.exit(1)
    passed += 1


def read(rel):
    return (root / rel).read_text()


def body(src, start, end):
    i = src.index(start)
    j = src.index(end, i + len(start))
    return src[i:j]


ask = read("Sources/MeetingAsk.swift")
core = read("Sources/MeetingAskCore.swift")
views = read("Sources/Views.swift")
helper = read("HelperSources/main.swift")
suite = read("Tests/run.sh")
sources = {p.name: p.read_text() for p in (root / "Sources").glob("*.swift")}

# Where it is: the Meeting assistant card, below Home city, one store.
card = body(ask, "struct MeetingAskSettings: View {", "struct HomeCitySettings: View {")
check(card.count("LiveCuesSettingsRow(store: store.liveCues, model: model)") == 1, "the row is in the Meeting assistant card")
check(card.index("HomeCitySettings(store: store.homeArea, model: model)") < card.index("LiveCuesSettingsRow("), "the row sits below Home city")
check(sum(s.count("LiveCuesSettingsRow(") for s in sources.values()) == 1, "the row is drawn in one place")
check("    let liveCues = LiveCuesStore()\n" in ask and sum(s.count("LiveCuesStore()") for s in sources.values()) == 1, "one store, on MeetingAskStore")
check("MeetingAskSettings(store: model.meetingAsk, model: model)" in views, "the card is in Settings")

# The row: the switch only for a server that answered, moving only through the store.
row = body(ask, "struct LiveCuesSettingsRow: View {", "/// Transcription (server 6.72.0): its own Settings card.")
check("if let settings = store.settings {" in row and row.index("if let settings = store.settings {") < row.index("Toggle(LiveCues.title"),
      "the switch is drawn only once the server answered")
check(row.count("Toggle(") == 1 and ".toggleStyle(COSSwitchStyle())" in row, "one switch, the COS switch")
check("set: { on in Task { await store.set(on, run: Self.run(model)) } }" in row, "the switch changes only through the store")
check(".disabled(!store.switchEnabled)" in row, "the switch is held while a call runs, on an env-set switch and without an answer")
check("get: { store.pending ?? settings.enabled }" in row, "the switch shows the server's value, or the change being asked for")
check("Text(store.line)" in row and row.count("Text(LiveCues.glassesLine)") == 1, "the status line and the glasses app line")
check("if let note = store.note {" in row, "the 409 sentence shows")
check('.task(id: "\\(model.status.running) \\(model.status.version ?? "")") { if !hosted { await store.load(Self.run(model)) } }' in row,
      "read on appear and whenever the server starts, stops or changes version")
check("{ arguments, input in try await model.runHelper(arguments, timeout: 20, stdinData: input) }" in row, "the helper bridge, nothing else")
check("Button(LiveCues.addKeyLabel) { model.panelScrollTarget = LiveCues.decisionKeysAnchor }" in row, "Add a Jev or SubQ key jumps to the key fields")
check("Button(LiveCues.checkAgainLabel) { Task { await store.load(Self.run(model)) } }" in row and ".disabled(store.busy)" in row,
      "Check again reads again, once at a time")
for banned in (".sheet(", ".alert(", ".confirmationDialog(", ".popover(", "NSAlert", "COSViewSwitch(", ".tracking(", ".textCase(.uppercase)"):
    check(banned not in row, f"the row has no {banned} (inline only; no pill tabs or caps kicker)")

# 0.5.329: the spend limits, under the switch, only from a server that reports them, moved only through the store.
check("if let limits = store.settings?.limits {\n                LiveCuesLimitsRows(store: store, limits: limits, run: Self.run(model))" in row
      and sum(s.count("LiveCuesLimitsRows(") for s in sources.values()) == 1, "the limits draw only when the server sends them, in one place")
check(row.index("Toggle(LiveCues.title") < row.index("LiveCuesLimitsRows(") < row.index("Text(LiveCues.glassesLine)"), "the limits sit under the switch")
limits_view = body(ask, "struct LiveCuesLimitsRows: View {", "/// Transcription (server 6.72.0): its own Settings card.")
check(limits_view.count("store.propose(") == 2 and "runHelper" not in limits_view, "the bar and the steppers move only through the store")
check(limits_view.count("if limit.locked {") == 2 and "LiveCues.envNote" in limits_view, "a limit set in .env shows read-only with Set in .env")
check("store.limitValue(" in limits_view and ".value" in limits_view, "the controls show the waiting move, else the server's value")
check("if !store.pendingLimits.isEmpty {\n                Text(LiveCues.savingLine)" in limits_view, "Saving until the server answers")
check("LiveCues.usageLine(usage)" in limits_view and "LiveCues.moreCues" in limits_view and "LiveCues.fewerCues" in limits_view, "usage and the bar's words")
check("COSStepper(" in limits_view and "Stepper(" not in limits_view.replace("COSStepper(", ""), "the house stepper")
for banned in (".sheet(", ".alert(", ".popover(", "@AppStorage", "UserDefaults", "Task.sleep"):
    check(banned not in limits_view, f"the limits have no {banned} (the store owns timing; the server owns the values)")
store_src = body(core, "final class LiveCuesStore: ObservableObject {", "// MARK: Live cue verdicts")
check("guard let limit = settings?.limits?.values[key], !limit.locked else { return }" in store_src, "a locked or unreported limit never moves")
check("try? await self?.limitsSleep(wait)" in store_src and "limitsFlush?.cancel()" in store_src, "moves are debounced: each cancels the one before")
check("state = LiveCues.state(answer?.details)" in body(store_src, "func flushLimits(", "func set("), "what shows after a change is the server's echo")

# 0.5.362 (server API v3, live cues modes): the cue mode, Grounded cues and the general limits. Only from a server that answered v 3,
# moved only through the store, a menu (never a row of pill buttons), the web mode's state in words.
check("if let v3 = store.settings?.v3 {\n                LiveCuesModeRows(store: store, v3: v3, run: Self.run(model))" in row
      and sum(s.count("LiveCuesModeRows(") for s in sources.values()) == 1, "the cue mode and Grounded cues draw only when the server answered v 3, in one place")
check("if let v3 = store.settings?.v3, LiveCues.searchesWeb(v3.mode.value), let limits = store.settings?.limits {\n                LiveCuesGeneralRows(" in row
      and sum(s.count("LiveCuesGeneralRows(") for s in sources.values()) == 1, "the general limits draw only for a v 3 server whose mode searches the web, in one place")
check(row.index("Toggle(LiveCues.title") < row.index("LiveCuesModeRows(") < row.index("LiveCuesLimitsRows(") < row.index("LiveCuesGeneralRows(") < row.index("Text(LiveCues.glassesLine)"),
      "the mode sits under the switch, the general limits under the v 2 limits")
modes_view = body(ask, "struct LiveCuesModeRows: View {", "struct LiveCuesGeneralRows: View {")
check("COSDropdown(LiveCues.cueModeTitle, selection: modeBinding," in modes_view and "LiveCueMode.allCases.map { COSDropdownOption($0, LiveCues.modeTitle($0)) }" in modes_view,
      "the cue mode is one menu with the three modes")
check("Button(" not in modes_view and "ForEach(" not in modes_view and "COSViewSwitch(" not in modes_view, "no row of pill buttons or tabs for the mode")
check("Task { await store.setMode(mode, run: run) }" in modes_view and "Task { await store.setGrounding(on ? .grounded : .classic, run: run) }" in modes_view
      and "runHelper" not in modes_view, "the mode and grounding change only through the store")
check(modes_view.count(".disabled(v3.mode.locked || store.busy)") == 1 and modes_view.count(".disabled(v3.grounding.locked || store.busy)") == 2,
      "a mode or grounding the server's environment holds, or a call in flight, holds the control")
check("LiveCues.modeHelp(shownMode)" in modes_view and modes_view.count("LiveCues.publicTopicsLine(v3)") == 2 and "tone: .warning" in modes_view,
      "one sentence for the mode on screen, and Public topics off shown as a warning in both layouts")
check(modes_view.count("Toggle(") == 1 and ".toggleStyle(COSSwitchStyle())" in modes_view, "Grounded cues is one COS switch in the panel")
general_view = body(ask, "struct LiveCuesGeneralRows: View {", "/// 0.5.322 (Miles, 2026-10-17): Live cues on or off")
check(general_view.count("store.propose(") == 2 and "runHelper" not in general_view and "if limit.locked {" in general_view, "the general limits move only through the store; a locked one is read-only")
check("COSStepper(" in general_view and "Stepper(" not in general_view.replace("COSStepper(", ""), "the house stepper")
for banned in (".sheet(", ".alert(", ".confirmationDialog(", ".popover(", "NSAlert", "COSViewSwitch(", ".tracking(", ".textCase(.uppercase)"):
    check(banned not in modes_view and banned not in general_view, f"the v3 rows have no {banned}")
v3_store = body(store_src, "func loadIfNeeded(", "func flushLimits(")
check("guard !busy, let v3 = settings?.v3, !v3.mode.locked, v3.mode.value != mode else { return }" in v3_store
      and "guard !busy, let v3 = settings?.v3, !v3.grounding.locked, v3.grounding.value != grounding else { return }" in v3_store, "a locked, unchanged or v 2 setting sends nothing")
check(store_src.count("await keepV3(before, run)") == 2 and 'run(["live-cues-settings", "--mode", mode.rawValue], nil)' in v3_store
      and 'run(["live-cues-settings", "--grounding", grounding.rawValue], nil)' in v3_store, "the v 2 writes read again so the v3 controls stay; the two v3 calls")
check(row.count(".task(id:") == 1, "the v3 rows add no loader of their own")

# The jump: Decision models opens and the panel scrolls to it.
scroll = body(views, "private func scrollToTarget(_ reader: ScrollViewProxy) {", "DispatchQueue.main.async {")
check("if target == LiveCues.decisionKeysAnchor { jevExpanded = true }" in scroll, "the jump opens Decision models before it scrolls")
check("            jevSettings\n                .id(LiveCues.decisionKeysAnchor)\n" in views, "Decision models carries the anchor")
check(views.count(".id(LiveCues.decisionKeysAnchor)") == 1, "one anchor")
jev = body(views, "private var jevSettings: some View {", "@ViewBuilder private var decisionProviderControls: some View {")
decision = body(views, "@ViewBuilder private var decisionProviderControls: some View {", "private func decisionProviderPicker(")
check("DisclosureGroup(isExpanded: $jevExpanded)" in jev and "decisionProviderControls" in jev, "Decision models holds the provider controls")
check('"TypeSafe API key"' in jev and '"SubQ API key"' in decision, "the Jev key field and the SubQ key field are both there")
check(".onChange(of: model.panelScrollTarget) { _, _ in scrollToTarget(reader) }" in views, "the panel follows the scroll target")

# The app reaches the server only through the helper.
def code(text):
    """The text without its // comments: a comment may name the route, code may not."""
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


check(not any("/api/live-cues" in code(s) for s in sources.values()), "no Sources code names the server route")
live = body(core, "// MARK: Live cues (server 6.76.2)", "// MARK: Transcription switcher (server 6.72.0)")
check("URLSession" not in live and "URLRequest" not in live, "no HTTP client in the app")
check('run(["live-cues-settings"], nil)' in live and 'run(["live-cues-settings", "--set", enabled ? "on" : "off"], nil)' in live,
      "the store's two helper calls")
check(not re.search(r"AppStorage|UserDefaults", live) and "LiveCues" not in "".join(l for l in views.splitlines() if "@AppStorage" in l),
      "the switch is never kept on this Mac: the server owns it")
literals = re.findall(r'"(?:[^"\\]|\\.)*"', live)
check(literals and not any(("—" in t or "→" in t or "->" in t) for t in literals), "no em dash or arrow in the words")

# The helper.
check(helper.count('case "live-cues-settings": try emitLiveCuesSettings(args: args)') == 1, "the helper verb is dispatched once")
check('static let liveCuesSettingsPath = "/api/live-cues/v2/settings"' in helper and code(helper).count('"/api/live-cues/v2/settings"') == 2,
      "the helper names the route in its constant and the constant's self-test only")
emit = body(helper, "private func emitLiveCuesSettings(args: [String]) throws {", "/// 0.5.321: ask the glasses to stop a live G2 meeting")
check('Self.liveCuesSettingsRequest(hasSet: args.contains("--set"), value: option("--set", in: args))' in emit, "a --set without on or off is refused")
check('details: ["transport": "unavailable"]' in emit and 'details: ["transport": "no_token"]' in emit, "no answer and no token are their own states")
check("var details = Self.liveCuesSettingsAnswer(response.body)" in emit and "response.body ?? " not in emit and '"body":' not in emit,
      "only the whitelisted keys cross")
check(emit.count('request(Self.liveCuesSettingsPath + (reading ? "?v=3" : ""), method: plan.method') == 1
      and emit.count('request(Self.liveCuesSettingsPath + "?v=2", method: "GET"') == 1,
      "one planned request: a read asks for v 3 (server API v3 sends the cue mode), and asks again for v 2 only after the 400 below")
check('if reading, response.status == 400, Self.liveCueErrorCode(response.body) == "unsupported_version" {' in emit,
      "the v 2 read is the fallback for 400 unsupported_version and nothing else")
check('if response.status == 200 { details["apiVersion"] = Self.liveCueCount(response.body?["v"]) == 3 ? 3 : 2 }' in emit,
      "the answer says which version answered: 3 only from a 200 body that says v 3")
check('"/api/live-cues/v2/settings"' not in emit, "the verb reaches the route only through the constant")

# 0.5.362: live-cues-status is the one new verb, read-only, named once.
check(helper.count('case "live-cues-status": try emitLiveCuesStatus(args: args)') == 1, "the status verb is dispatched once")
check('static let liveCuesStatusRoute = "/api/live-cues/status"' in helper and code(helper).count('"/api/live-cues/status"') == 1, "the helper names the status route in its constant only")
status_emit = body(helper, "private func emitLiveCuesStatus(args: [String]) throws {", "private func emitMeetingStrandedSave(")
check("request(path, token: token, timeout: 6)" in status_emit and 'method: "POST"' not in status_emit and "Self.liveCuesStatusAnswer(status: response.status, body: response.body)" in status_emit,
      "the status verb is one read, and only its whitelist crosses")
check('details: ["transport": "unavailable"]' in status_emit and 'details: ["transport": "no_token"]' in status_emit, "status: no answer and no token are their own states")

# The suite runs it.
check(suite.count('zsh "$ROOT/Tests/run-live-cues.sh"') == 1, "the full suite runs the live cues gate")
check(suite.count('python3 "$ROOT/Tests/live-cues-helper-checks.py" "$TMP/cos-control-helper"') == 1, "the full suite runs the helper checks")

# No new Swift source file: every one is in the release build's explicit list.
release = read("scripts/build-release.sh")
check(all(f'"$ROOT/Sources/{name}"' in release for name in sources), "every Sources file is in scripts/build-release.sh")

# The version.
plist = read("Resources/Info.plist")
# 0.5.323 on: the switch shipped in 0.5.322; pin its history, not the current version (run.sh pins Info.plist to the CHANGELOG).
whats = json.loads(read("Resources/WhatsNew.json"))
sec322 = next((s for s in whats["whatsNew"]["sections"] if s["title"] == "0.5.322"), None)
check(sec322 is not None, "What's New keeps the 0.5.322 section")
# 0.5.345 (plan r3): the capped summary no longer chains back to 0.5.322; its own section names the switch.
check(sec322 is not None and any("a live cues switch in settings" in item.lower() for item in sec322["items"]),
      "the 0.5.322 section names the new switch")
check(sec322 is not None and any("Live cues switch" in item for item in sec322["items"]), "the 0.5.322 items describe the switch")
changelog = read("CHANGELOG.md")
entry = changelog[changelog.index("## 0.5.322 (build 375)"):] if "## 0.5.322 (build 375)" in changelog else ""
entry = entry.split("\n## 0.5.321", 1)[0]
check(bool(entry) and "6.76.2" in entry and "6.10.644" in entry, "CHANGELOG 0.5.322 pairs with server 6.76.2 and glasses 6.10.644")
# 0.5.364: the newest section is read as one text, so the count does not move with how many items a release has.
for text in [entry] + (sec322["items"] if sec322 else []) + [" ".join(whats["whatsNew"]["sections"][0]["items"])] + [whats["whatsNew"]["summary"]]:
    check("—" not in text and "→" not in text, "no em dash or arrow in the release words")

print(f"live cues pins: {passed} passed")
