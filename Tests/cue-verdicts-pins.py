#!/usr/bin/env python3
"""0.5.327: wiring pins for rating live cues (CueReviewPane, CueRateCard, MeetingSidePanel and MeetingCuesPanel in
Sources/MeetingAsk.swift; the route in Sources/ControllerModel.swift and Sources/ActivityWindow.swift; the Memories page's
two entries in Resources/memories/memories-app.js).

The words, the store, the 15-second floor and the key rule run in Tests/CueVerdictsChecks.swift, the helper's two verbs in
its self-test and Tests/cue-verdicts-helper-checks.py, the page's entries in Tests/MemoriesCuesCanary.cjs. These pin what
a SwiftUI view and the window do, which those cannot execute: the pane mounts on its own route flag that only its opener
and closer write (opener, render condition, Back and a tab switch), the keys are read only on the card and never on an
ancestor of the note field, the note lives in the card (typing never reaches the store or Activity), the Cues view is
offered only once a history read answered, the live list polls only while it shows, nothing opens a sheet, the app
reaches the server only through the helper, and the version is 0.5.327.
Prints "cue verdicts pins: N passed". Usage: cue-verdicts-pins.py <checkout>
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
        print(f"cue verdicts pin FAILED: {what}")
        sys.exit(1)
    passed += 1


def read(rel):
    return (root / rel).read_text()


def body(src, start, end=None):
    i = src.index(start)
    if end is None:
        return src[i:]
    j = src.index(end, i + len(start))
    return src[i:j]


def code(text):
    """The text without its // comments: a comment may name a route, code may not."""
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


ask = read("Sources/MeetingAsk.swift")
core = read("Sources/MeetingAskCore.swift")
model = read("Sources/ControllerModel.swift")
window = read("Sources/ActivityWindow.swift")
meetings = read("Sources/ActivityMeetings.swift")
helper = read("HelperSources/main.swift")
page = read("Resources/memories/memories-app.js")
suite = read("Tests/run.sh")
sources = {p.name: code(p.read_text()) for p in (root / "Sources").glob("*.swift")}

# ── One store.
check("    let cueVerdicts = CueVerdictsStore()\n" in ask and sum(s.count("CueVerdictsStore()") for s in sources.values()) == 1,
      "one store, on MeetingAskStore")

# ── The route: one flag, written by its opener and closer only, mounted, closed by Back and by a tab switch.
check("@Published private(set) var cueReview: CueVerdicts.Review?" in model, "the route flag is private(set) on the model")
check(len(re.findall(r"\bcueReview = ", sources["ControllerModel.swift"])) == 2
      and "func openCueReview(_ view: CueVerdicts.Review) {\n        cueReview = view\n    }" in model
      and "func closeCueReview() {\n        cueReview = nil\n    }" in model, "only openCueReview and closeCueReview write it")
check("var cueReviewRouteActive: Bool {\n        cueReview != nil\n    }" in model, "the render condition is the flag")
mount = "} else if section == .memories, model.cueReviewRouteActive {\n                    CueReviewPane(model: model, store: model.meetingAsk.cueVerdicts, openMemories: openMemoriesView)"
check(window.count(mount) == 1 and sum(s.count("CueReviewPane(") for s in sources.values()) == 1, "the pane mounts on the flag, in one place")
check(window.index(mount) < window.index("} else if section == .memories, selectedLearningID != nil {\n                    if model.learningRouteActive {")
      and window.index(mount) < window.index("} else if let section {\n                    sectionList(section)"), "it mounts ahead of the Memories page")
check("case .memories: selectedContextID != nil || selectedLearningID != nil || selectedGraphEntityID != nil || model.cueReviewRouteActive" in window,
      "the pane is a detail, so Back shows")
check("} else if section == .memories, model.cueReviewRouteActive {\n            model.closeCueReview()" in window, "Back closes it")
clear = body(window, "private func clearDetail() {", "/// From the cue review rail back to the Memories page")
check("model.closeCueReview()" in clear, "a tab switch or Home closes it")
check("private func openMemoriesView(_ view: String) {\n        memoriesOpenView = view\n        model.closeCueReview()" in window,
      "the rail's To review and Recent learning go back to the page on that view")
openers = [m.start() for m in re.finditer(r"model\.openCueReview\(", "".join(sources.values()))]
check(len(openers) == 4, "four openers: the page's cues.open, the rail's two links, the fallback pane's button")

# ── The page's two entries go through the app.
coordinator = body(window, "final class Coordinator: NSObject, WKScriptMessageHandler {", "// MARK: - Held naming review")
check('case "cues.summary":' in coordinator and "await store.loadWeek(CueReviewPane.run(model))" in coordinator
      and "CueVerdicts.summary(available: store.available, counts: store.counts)" in coordinator, "the page's counts are the store's week read")
check('case "cues.open":' in coordinator and "(args[\"view\"] as? String).flatMap(CueVerdicts.Review.init(rawValue:))" in coordinator
      and "model.openCueReview(view)" in coordinator, "the page opens the native route with a known view only")
check('"cues.summary"' not in body(window, "static let helperOps:", "static func timeout(for op: String)"), "the page never reaches the helper verbs directly")
check("call('cues.summary')" in page and "state.cues = d && d.available === true ? d : null" in page, "the page shows its entries only on available: true")
check("call('cues.open', { view: view === 'rated' ? 'rated' : 'rate' })" in page, "the page asks for one of the two views")

# ── The cue card: keys on the card only, the note in the card.
card = body(ask, "struct CueRateCard: View {", "struct CueRatedRow: View {")
check(card.count(".onKeyPress(") == 1 and "cardFocused: focus == .card" in card, "one key handler, and it asks whether the card has focus")
check("let modified = !press.modifiers.isDisjoint(with: [.command, .option, .control])" in card, "Command, Option and Control keys are never taken")
check(card.index(".onKeyPress(") < card.index("TextField(CueVerdicts.notePlaceholder"), "the key handler is on the card, not on an ancestor of the note")
key_block = card[card.rindex("VStack(alignment: .leading, spacing: 12) {", 0, card.index(".onKeyPress(")):card.index(".onKeyPress(")]
check("TextField(" not in key_block, "the note field is not inside the view that reads the keys")
check(".focusable(interactions: .edit)" in card and ".focused($focus, equals: .card)" in card and ".focused($focus, equals: .note)" in card,
      "the card and the note take focus separately")
check("@State private var note = \"\"" in card and "TextField(CueVerdicts.notePlaceholder, text: $note)" in card, "the note is the card's own state")
store = body(core, "final class CueVerdictsStore: ObservableObject {", "// MARK: Transcription switcher")
check(not re.search(r"@Published[^\n]*(draft|noteText|typing)", store), "no published note text: typing never reaches the store")
check(".id(cue.id)" in body(ask, "private var queueView: some View {", "private var ratedView: some View {"), "each cue gets a fresh card (note and focus)")
check(".onExitCommand { focus = .card }" in card and ".onSubmit { focus = .card }" in card, "Return and Escape in the note give the keys back to the card")

check(ask.count("title: CueVerdicts.title(cue, library: model.libraryMeetings)") == 2,
      "both Memories views name a cue's meeting by this Mac's saved title first")
check(ask.count("if !cue.before.isEmpty {") == 2, "no empty box when the server has no excerpt")

# ── Beside the meeting: Cues only once the server answered with the history; Ask stays.
side = body(ask, "struct MeetingSidePanel<Ask: View>: View {", "struct MeetingCuesPanel: View {")
check("private var cuesOffered: Bool { store.available == true && G2MeetingStop.isGlassesSession(session) }" in side,
      "the Cues view needs a server that answered with the history, on a glasses meeting")
check(side.index("if cuesOffered {") < side.index("COSViewSwitch(") and "if cuesOffered && shown == .cues {" in side and "ask()" in side,
      "no switch and only the Ask panel otherwise")
check("force: true" in side and ".task(id: session)" in side, "one read when the panel shows a meeting")
live_pane = body(meetings, "struct LiveTranscriptPane: View {", "struct LiveTurnRow: View {")
check('Button(showAsk ? "Hide Ask" : "Live COS Ask") { showAsk.toggle() }' in live_pane, "Hide Ask still hides the whole panel")
check("MeetingSidePanel(store: model.meetingAsk.cueVerdicts, model: model, session: session,\n                                     live: model.openLiveTranscriptFeed?.ended != true) {\n                        LiveAskPanel(" in live_pane,
      "the live meeting's panel wraps Live COS Ask")
check('MeetingSidePanel(store: model.meetingAsk.cueVerdicts, model: model, session: session, askTitle: "Meeting Ask") {\n                                    LiveAskPanel(state: model.meetingAsk, model: model, session: session, saved: true' in meetings,
      "a saved meeting's capture wraps Meeting Ask")
panel = body(ask, "struct MeetingCuesPanel: View {", "struct MeetingCueCard: View {")
poll = body(panel, '.task(id: "\\(session) \\(polls)") {')
check("guard polls else { return }" in poll and "try? await Task.sleep(for: .seconds(CueVerdicts.pollSeconds))" in poll
      and "await store.loadMeeting(session, days: days, run: run)" in poll and "force" not in poll,
      "the live list polls every 15 seconds only while it shows, through the store's floor")
check(sum(s.count("CueVerdicts.pollSeconds") for s in sources.values()) == 2, "the 15 seconds are named in the floor and the loop, nowhere else")

# ── Inline only, house controls.
views = body(ask, "// MARK: Live cue verdicts (0.5.327, server 6.79.0)")
for banned in (".sheet(", ".alert(", ".confirmationDialog(", ".popover(", "NSAlert", ".tracking(", ".textCase(.uppercase)", "@AppStorage", "UserDefaults"):
    check(banned not in views, f"the cue views have no {banned}")
check(views.count("COSViewSwitch(") == 1, "the one view switch beside the meeting (words with a gold rule, never pill tabs)")

# ── The app reaches the server only through the helper.
cues_core = body(core, "// MARK: Live cue verdicts (server 6.79.0)", "// MARK: Transcription switcher")
check("URLSession" not in cues_core and "URLRequest" not in cues_core and "URLSession" not in views, "no HTTP client in the app")
check(not any("/api/live-cues/history" in s or "/api/live-cues/feedback" in s for s in sources.values()), "no Sources code names the routes")
literals = re.findall(r'"(?:[^"\\]|\\.)*"', code(cues_core) + code(views))
check(literals and not any(("—" in t or "→" in t or "->" in t) for t in literals), "no em dash or arrow in the words")

# ── The helper.
check(helper.count('case "live-cues-history": try emitLiveCuesHistory(args: args)') == 1
      and helper.count('case "live-cues-rate": try emitLiveCuesRate(args: args)') == 1, "the two verbs are dispatched once each")
check(code(helper).count('"/api/live-cues/history"') == 1 and code(helper).count('"/api/live-cues/feedback"') == 1, "each route named once, in its constant")
emit_history = body(helper, "private func emitLiveCuesHistory(args: [String]) throws {", "private func emitLiveCuesRate(")
emit_rate = body(helper, "private func emitLiveCuesRate(args: [String]) throws {", "/// 0.5.321: ask the glasses to stop a live G2 meeting")
for name, emit in (("history", emit_history), ("rate", emit_rate)):
    check('details: ["transport": "unavailable"]' in emit and 'details: ["transport": "no_token"]' in emit, f"{name}: no answer and no token are their own states")
    check("response.body ?? " not in emit and '"body":' not in emit and emit.count("request(") == 1, f"{name}: one request, only whitelisted keys cross")
check("Self.liveCuesHistoryAnswer(status: response.status, body: response.body)" in emit_history, "history: the whitelist")
check("Self.liveCuesRateAnswer(status: response.status, body: response.body)" in emit_rate and 'method: "POST"' in emit_rate, "rate: a POST and the whitelist")

# ── The suite runs it.
check(suite.count('zsh "$ROOT/Tests/run-cue-verdicts.sh"') == 1, "the full suite runs the cue verdicts gate")
check(suite.count('python3 "$ROOT/Tests/cue-verdicts-helper-checks.py" "$TMP/cos-control-helper"') == 1, "the full suite runs the helper checks")
check(suite.count('node "$ROOT/Tests/MemoriesCuesCanary.cjs"') == 1, "the full suite runs the page canary")
release = read("scripts/build-release.sh")
check(all(f'"$ROOT/Sources/{name}"' in release for name in sources), "every Sources file is in scripts/build-release.sh (no new file)")

# ── The version. 0.5.327 introduced cue ratings; later releases keep its history entries intact.
plist = read("Resources/Info.plist")
shipped = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>0\.5\.(\d+)</string>", plist)
check(shipped is not None and int(shipped.group(1)) >= 327, "Info.plist is 0.5.327 or later")
whats = json.loads(read("Resources/WhatsNew.json"))
section = next((s for s in whats["whatsNew"]["sections"] if s["title"] == "0.5.327"), None)
check(section is not None, "What's New keeps its 0.5.327 section")
summary327 = whats["whatsNew"]["summary"].split("Plus everything in 0.5.327: ", 1)[-1].split(" Plus everything in 0.5.326")[0]
check("rate" in summary327.lower(), "the 0.5.327 summary names rating cues")
changelog = read("CHANGELOG.md")
check("\n## 0.5.327 (build " in "\n" + changelog, "CHANGELOG keeps its 0.5.327 entry")
entry = ("\n" + changelog).split("\n## 0.5.327 (build ", 1)[-1].split("\n## 0.5.326", 1)[0]
check("6.79.0" in entry, "CHANGELOG 0.5.327 names server 6.79.0")
for text in [entry] + (section["items"] if section else []) + [summary327]:
    check("—" not in text and "→" not in text, "no em dash or arrow in the release words")

print(f"cue verdicts pins: {passed} passed")
