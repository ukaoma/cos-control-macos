#!/usr/bin/env python3
"""0.5.380 (preview engine phase 1, plan item 6): where the Sessions pane's file and image cards are wired, pinned where
Tests/SessionPreviewsChecks.swift cannot reach (the model, the pane, the helper dispatch, the compile lists, the copy).
Comments never count. Each failure names its behaviour as "pin failed [<behaviour>]" for Tests/mutate-session-previews.py.

    python3 Tests/session-previews-pins.py <root>
"""
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = 0


def code(rel):
    text = (root / rel).read_text(encoding="utf-8")
    return "\n".join(re.sub(r"(^|\s)//.*$", "", line) for line in text.split("\n"))


def pin(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")
    passed += 1


def body(text, start, end_marker="\n    }\n"):
    pin(start in text, "source shape", f"cannot find {start!r}")
    tail = text.split(start, 1)[1]
    return tail.split(end_marker, 1)[0]


model = code("Sources/ControllerModel.swift")
window = code("Sources/ActivityWindow.swift")
store = code("Sources/SessionPreviews.swift")
helper = code("HelperSources/main.swift")
run_sh = code("Tests/run.sh")

# ── The model: one store, loaded on open, told the local turns, cleared on close, swept at launch.
pin("    let sessionPreviews: SessionPreviewStore\n" in model and "sessionPreviews = SessionPreviewStore { arguments, stdin in" in model and 'helper.run(arguments, timeout: 45, stdinData: stdin).details' in model,
    "model store", "ControllerModel owns one SessionPreviewStore that runs the helper")
opening = body(model, "func openClaudeSession(_ session: ClaudeSession) {")
pin("sessionPreviews.load(provider: session.provider, sessionID: session.sessionId)" in opening, "load on open",
    "opening a session loads its cards")
pin(opening.index("guard !session.isScheduledJob") < opening.index("sessionPreviews.load(") and "sessionPreviews.clear()" in opening.split("guard !session.isScheduledJob", 1)[1].split("}", 1)[0],
    "scheduled job", "a scheduled job loads no cards and clears the last session's")
pin("sessionPreviews.clear()" in body(model, "func closeClaudeSession() {"), "clear on close", "closing the session clears its cards and deletes an open copy")
pin("sessionPreviews.noteLocalTurns(detail.turns.map" in body(model, "private func fetchClaudeSessionDetail(_ session: ClaudeSession) async {"),
    "placement", "the local turns reach the store so cards sit under their reply")
pin("sessionPreviews.reload()" in body(model, "func refreshChatTranscript() {"), "reload", "a refreshed transcript reads the cards again")
launch = model.split("guard startBackgroundWork else { return }", 1)
pin(len(launch) == 2 and "SessionPreviewStore.sweep()" in launch[1].split("refreshTask = Task", 1)[0], "launch sweep",
    "launch sweeps the copies a quit or crash left behind, only in the real app (after the startBackgroundWork guard)")
pin(model.count("SessionPreviewStore.sweep(") == 1, "launch sweep", "one sweep, at launch")

# ── The pane: cards under each turn, the closing group, Quick Look hosted once and closed on disappear.
pane = body(window, "struct ClaudeSessionDetailPane: View {", "\n}\n")
turns = pane.split("ForEach(detail.turns) { turn in", 1)
pin(len(turns) == 2 and "SessionPreviewTurnCards(store: model.sessionPreviews, turnID: turn.id)" in turns[1].split(".frame(maxWidth: .infinity, alignment: .leading)", 1)[0],
    "turn cards", "each turn draws its cards inside its own card")
pin("SessionPreviewUnplacedCards(store: model.sessionPreviews)" in pane, "unplaced", "cards with no turn on screen close the conversation")
pin(pane.count(".background(SessionPreviewQuickLook(store: model.sessionPreviews))") == 1, "quick look host", "Quick Look is hosted once on the pane")
host = body(window, "struct SessionPreviewQuickLook: View {", "\n}\n")
pin(".quickLookPreview($store.quickLookURL)" in host and ".onDisappear { store.quickLookURL = nil }" in host, "quick look host",
    "Quick Look shows the store's copy, and leaving the pane closes it (which deletes the copy)")
for name in ("struct SessionPreviewPictureCard: View {", "struct SessionPreviewFileCard: View {"):
    card = body(window, name, "\n}\n")
    pin("store.open(item)" in card and ".disabled(!item.opens)" in card, "card opens", f"{name} opens through the store and only when the card opens")
pin("await store.loadThumbnail(item)" in body(window, "struct SessionPreviewPictureCard: View {", "\n}\n"), "thumbnail", "a picture card loads its thumbnail when it appears")
pin(window.count("quickLookURL = ") == 1, "one writer", "the pane writes the Quick Look copy only to close it; the store opens it")

# ── The store: the guards the checks execute, present once each.
pin("didSet { if let old = oldValue, old != quickLookURL { discard(old) } }" in store, "delete on close", "changing or closing Quick Look deletes the old copy")
pin(re.search(r"func open\(_ item: SessionPreviewItem\) -> Task<Void, Never>\? \{\n\s+guard !previewsOff, item\.opens", store) is not None, "off guard",
    "open refuses first when previews are off or the card does not open")
pin("guard !previewsOff, item.hasThumbnail" in store, "off guard", "thumbnails refuse first when previews are off")
pin('["session-preview-fetch"]' in store and '"session-previews", "--provider"' in store, "verbs", "the store uses the two helper verbs")

# ── The helper: both verbs dispatched, bounded reads, copies only under SessionPreviews.
pin('case "session-previews": try emitSessionPreviews(args: args)' in helper and 'case "session-preview-fetch": try emitSessionPreviewFetch()' in helper,
    "dispatch", "the helper dispatches both verbs")
fetch = body(helper, "private func emitSessionPreviewFetch() throws {")
pin("boundedMediaRequest(route, token: token, timeout: 30, maximumBytes: maximum)" in fetch, "bounded", "the fetch is bounded (32 MiB raw, 8 MiB thumbnail)")
pin("sessionPreviewRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)" in fetch and "permissions: 0o600" in fetch,
    "private copy", "each copy gets its own 0700 folder and a 0600 file")
pin('controlCache.appendingPathComponent("SessionPreviews", isDirectory: true)' in helper, "private copy", "the helper's root is Control's own cache")
pin('let secret = reason.map { sessionPreviewSecretReasons.contains($0) } ?? false' in helper and 'let available = state == "available" && !secret' in helper,
    "secret", "the helper never marks a secret name available")
pin('if turn["previewsOff"] as? Bool == true {' in helper, "off", "an off message is read as a mark only")

# ── Every app compile list carries the new file, and run.sh runs the lanes.
for rel in ("Tests/run.sh", "scripts/build-release.sh", "scripts/build-foundation-lab.sh", "Tests/run-held-ui.sh", "Tests/run-merge-ui.sh",
            "Tests/run-markdown-ui.sh", "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh"):
    text = code(rel)
    pin(text.count('"$ROOT/Sources/ActivityWindow.swift"') <= text.count('"$ROOT/Sources/SessionPreviews.swift"') or rel == "Tests/run.sh",
        "compile lists", f"{rel} compiles SessionPreviews.swift wherever it compiles the app")
    pin('"$ROOT/Sources/SessionPreviews.swift"' in text, "compile lists", f"{rel} compiles SessionPreviews.swift")
pin(run_sh.count('"$ROOT/Sources/SessionLiveFeed.swift" "$ROOT/Sources/SessionPreviews.swift"') == 3, "compile lists", "run.sh's three app lists compile it")
pin('python3 "$ROOT/Tests/session-previews-helper-checks.py" "$TMP/cos-control-helper"' in run_sh and 'zsh "$ROOT/Tests/run-session-previews.sh"' in run_sh,
    "lanes", "run.sh runs the helper checks and the Swift checks")

cards_src = body(window, "struct SessionPreviewTurnCards: View {", "struct ScheduledJobFacts: View {")
# ── Copy: no em dash, no arrow, no all-caps eyebrow in the new words.
words = re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', store) + re.findall(r'Text\("([^"]*)"\)', cards_src)
notes = json.loads((root / "Resources/WhatsNew.json").read_text(encoding="utf-8"))
section = [s for s in notes["whatsNew"]["sections"] if s["title"] == "0.5.380"]
pin(len(section) == 1 and any("Quick Look" in i for i in section[0]["items"]), "whats new", "What's New has one 0.5.380 section naming Quick Look")
entry = (root / "CHANGELOG.md").read_text(encoding="utf-8").split("\n## 0.5.379", 1)[0]
pin("**Default on:**" in entry, "changelog", "the changelog entry lists what is on by default")
for text in words + section[0]["items"] + [notes["whatsNew"]["summary"], entry]:
    pin("—" not in text and "→" not in text and "->" not in text, "copy", f"no em dash or arrow: {text[:80]!r}")
for text in re.findall(r'Text\("([^"]*)"\)', cards_src):
    pin(not (text.isupper() and len(text) > 3), "copy", f"no all-caps eyebrow label: {text!r}")

print(f"session previews pins: {passed} passed")
