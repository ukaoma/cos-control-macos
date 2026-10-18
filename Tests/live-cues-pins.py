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
check('.task(id: "\\(model.status.running) \\(model.status.version ?? "")") { await store.load(Self.run(model)) }' in row,
      "read on appear and whenever the server starts, stops or changes version")
check("{ arguments, input in try await model.runHelper(arguments, timeout: 20, stdinData: input) }" in row, "the helper bridge, nothing else")
check("Button(LiveCues.addKeyLabel) { model.panelScrollTarget = LiveCues.decisionKeysAnchor }" in row, "Add a Jev or SubQ key jumps to the key fields")
check("Button(LiveCues.checkAgainLabel) { Task { await store.load(Self.run(model)) } }" in row and ".disabled(store.busy)" in row,
      "Check again reads again, once at a time")
for banned in (".sheet(", ".alert(", ".confirmationDialog(", ".popover(", "NSAlert", "COSViewSwitch(", ".tracking(", ".textCase(.uppercase)"):
    check(banned not in row, f"the row has no {banned} (inline only; no pill tabs or caps kicker)")

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
check(emit.count("request(Self.liveCuesSettingsPath, method: plan.method") == 1, "one request, the planned method")
check('"/api/live-cues/v2/settings"' not in emit, "the verb reaches the route only through the constant")

# The suite runs it.
check(suite.count('zsh "$ROOT/Tests/run-live-cues.sh"') == 1, "the full suite runs the live cues gate")
check(suite.count('python3 "$ROOT/Tests/live-cues-helper-checks.py" "$TMP/cos-control-helper"') == 1, "the full suite runs the helper checks")

# No new Swift source file: every one is in the release build's explicit list.
release = read("scripts/build-release.sh")
check(all(f'"$ROOT/Sources/{name}"' in release for name in sources), "every Sources file is in scripts/build-release.sh")

# The version.
plist = read("Resources/Info.plist")
check(re.search(r"<key>CFBundleShortVersionString</key>\s*<string>0\.5\.322</string>", plist) is not None, "Info.plist 0.5.322")
check(re.search(r"<key>CFBundleVersion</key>\s*<string>375</string>", plist) is not None, "Info.plist build 375")
whats = json.loads(read("Resources/WhatsNew.json"))
check(whats["version"] == "0.5.322" and whats["whatsNew"]["sections"][0]["title"] == "0.5.322", "What's New 0.5.322 first")
check(whats["whatsNew"]["summary"].startswith("A Live cues switch in Settings"), "the summary leads with the new switch")
changelog = read("CHANGELOG.md")
first = changelog.split("\n## ", 1)[0] if not changelog.startswith("## ") else "## " + changelog[3:].split("\n## ", 1)[0]
check(first.startswith("## 0.5.322 (build 375)") and "6.76.2" in first and "6.10.644" in first, "CHANGELOG 0.5.322 pairs with server 6.76.2 and glasses 6.10.644")
for text in [first] + whats["whatsNew"]["sections"][0]["items"] + [whats["whatsNew"]["summary"].split(" Plus everything in 0.5.321")[0]]:
    check("—" not in text and "→" not in text, "no em dash or arrow in the release words")

print(f"live cues pins: {passed} passed")
