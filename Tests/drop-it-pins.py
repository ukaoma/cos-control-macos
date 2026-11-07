#!/usr/bin/env python3
"""0.5.371 Drop it: the wiring pins. Messages' existing Recent list, its rows and File to Work are byte-for-byte as in 0.5.368
(hashed); the pinned row mounts above the list only on Recent and only while the server has Drop it on; the chat and History
mount on their own flags that only their openers write, inline and never as a sheet; Back, a tab switch and the server turning
it off close them; ⌘K's row stays File to Work exactly unless Drop it is on; the Settings switch shows only for a server that has
it; the words reach the helper only on stdin and no Drop it file logs; the capability is read; every app compile lists the two new
files; the version touchpoints; the lanes are wired. Comments are stripped before a code pin.
Prints "drop it pins: N passed". Each failure names its behaviour in brackets, which Tests/mutate-drop-it.py matches."""
import hashlib, json, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
def read(rel): return (root / rel).read_text(encoding="utf-8")
def code(rel):
    out = []
    for line in read(rel).splitlines():
        stripped = line.lstrip()
        out.append("" if stripped.startswith("//") or stripped.startswith("///") else line)
    return "\n".join(out)
passed = 0
def need(cond, tag, what):
    global passed
    if not cond:
        print(f"drop it pin FAILED [{tag}]: {what}"); sys.exit(1)
    passed += 1
def between(s, a, b):
    i = s.index(a); j = s.index(b, i); return s[i:j]
def sha(s): return hashlib.sha256(s.encode()).hexdigest()

window_raw = read("Sources/ActivityWindow.swift")
window = code("Sources/ActivityWindow.swift")
model = code("Sources/ControllerModel.swift")
models = code("Sources/Models.swift")
views = code("Sources/Views.swift")
setup = code("Sources/SetupAssistant.swift")
catalog = read("Sources/SettingsHubCatalog.swift")
core = code("Sources/DropIt.swift")
drop_views = code("Sources/DropItViews.swift")
helper = code("HelperSources/main.swift")
run_sh = read("Tests/run.sh")

# ── Messages as it was: the Recent list, its rows and the filter, hashed from 0.5.368 (cbdae28).
# 0.5.374 re-hashed the recent list and the message row on purpose (Messages cleanup: no legend, no per-row glyph, the
# facts line). Drop it still must not touch them; any other change to these blocks fails here.
UNCHANGED = {
    "recent list": ("            // 0.5.343: the turns build in place on first load", "    private var speakersList: some View {",
                    "67b5a888d8df1d1fddcd65e756bc67b4762b30d451aa61c3324ec5413831ea66"),
    "message row": ("    private func messageRow(", "\n    }\n", "78fdf5a1a9c2218dbc89219e5bfdb44fff096abce7302aa0f8e61113b3d0bcf1"),
    "visible recent": ("    private var visibleRecentMessages: [GlassesTurn] {", "\n    }\n", "20d627041c6cdb5dc1baae9e560eec74efa42154da1fb42cc3859e8fb20bee3d"),
    "file to work": ("    func todaySubmitAsk(_ words: String) {", "\n    }\n", "02a481d5b6cebebc15f8a89af5f8e51a335f4f5cba68d697dd165fe2866f4581"),
}
for name, (a, b, digest) in UNCHANGED.items():
    need(a in window_raw and sha(between(window_raw, a, b)) == digest, "messages unchanged", f"{name} is byte-for-byte as in 0.5.374")

# ── The pinned row: above the list, Recent only, only while Drop it is on.
mount = '            if messagesSubview == .recent, model.status.dropIt.available {\n                DropItPinnedRow(store: model.dropIt, open: openDropItChat)'
need(window.count(mount) == 1, "pinned row gate", "the pinned row mounts once, on Recent, while the server has Drop it on")
need(window.index(mount) < window.index("COSBuildUp(.list(6), tune: .messages"), "pinned row gate", "the pinned row sits above the Recent list, outside it")
need(window.count("DropItPinnedRow(") == 1, "pinned row gate", "nothing else draws the pinned row")

# ── The routes: own flags, written only by their openers.
need("@Published private(set) var dropItChatOpen = false" in model and "@Published private(set) var dropItHistoryOpen = false" in model,
     "route flags", "the chat and History each have their own flag, private to the model")
need(len(re.findall(r"(?<!var )dropItChatOpen = (true|false)", model)) == 3 and len(re.findall(r"(?<!var )dropItHistoryOpen = (true|false)", model)) == 4,
     "route flags", "the flags are written only in openDropItChat, closeDropItChat, openDropItHistory and closeDropItHistory")
need("var dropItChatRouteActive: Bool {\n        dropItChatOpen && status.dropIt.available\n    }" in model
     and "var dropItHistoryRouteActive: Bool {\n        dropItHistoryOpen && status.dropIt.available\n    }" in model, "route gate", "a route is its flag and the server having Drop it on")
need("    func openDropItChat() {\n        guard status.dropIt.available else { return }" in model and "    func openDropItHistory() {\n        guard status.dropIt.available else { return }" in model,
     "route gate", "the openers do nothing while Drop it is off")
need('} else if section == .messages, model.dropItHistoryRouteActive {\n                    DropItHistoryPane(store: model.dropIt' in window
     and '} else if section == .messages, model.dropItChatRouteActive {\n                    DropItChatPane(store: model.dropIt' in window, "chat route", "the panes render on their own route flags")
need(window.index("} else if section == .messages, model.dropItHistoryRouteActive {") < window.index("} else if section == .messages, model.dropItChatRouteActive {"),
     "history route", "History is checked before the chat, so it wins while both flags are up")
need("} else if section == .messages, model.dropItHistoryRouteActive {\n            model.closeDropItHistory()\n        } else if section == .messages, model.dropItChatRouteActive {\n            model.closeDropItChat()" in window,
     "back", "Back closes History to the chat, then the chat to the list")
need("|| model.dropItChatRouteActive || model.dropItHistoryRouteActive" in window, "back", "the chat counts as a Messages detail, so Back shows")
need("\n        model.closeDropItChat()\n" in between(window, "    private func clearDetail() {", "\n    }\n") + "\n", "tab switch", "a tab switch closes the chat like any detail")
need("    func setDropItEnabled(_ on: Bool) async {" in model and "if !now { closeDropItChat() }" in model, "settings off", "turning it off in Settings closes the chat")

# ── The Messages rail mark (plan section 12): on the Today rail only for Messages, gated inside the mark, read on the rail's clock.
need('if key == "messages" { DropItRailMark(store: model.dropIt, available: model.status.dropIt.available) }' in window
     and 'if key == "messages" { DropItRailMark(store: model.dropIt, available: model.status.dropIt.available, compact: true).padding(3) }' in window
     and window.count("DropItRailMark(") == 2, "rail mark", "Messages carries the mark in both rail modes, gated on the capability")
need(".task(id: model.status.dropIt.available ? Int(now.timeIntervalSince1970 / 30) : -1) {\n            if model.status.dropIt.available { await model.dropIt.refreshSummary() }" in window,
     "rail mark", "the summary is read on the rail's 30-second clock, never while Drop it is off")
need("        guard available else { return .none }" in core and "if let waiting = summary.waiting, waiting > 0 { return .count(waiting) }" in core,
     "rail mark", "a number only for waiting, nothing while unavailable")

# ── Inline only, scroll in place, no logging.
for name, text in (("Sources/DropItViews.swift", drop_views), ("Sources/DropIt.swift", core)):
    for banned in (".sheet(", ".popover(", "confirmationDialog", ".alert("):
        need(banned not in text, "inline", f"{name} has no {banned}")
    for banned in ("Logger(", "print(", "NSLog", "os_log", "debugPrint"):
        need(banned not in text, "no logs", f"{name} never logs ({banned})")
need("import SwiftUI" not in core and "import AppKit" not in core, "pure core", "Sources/DropIt.swift is Foundation only")
need(drop_views.count("ScrollView") >= 2, "scroll in place", "the chat and History scroll in place")
need('COSViewSwitch("Kind", selection: $kind' in drop_views, "no pills", "History's kinds use the underlined view switch, not a pill row")
need("try? await Task.sleep(nanoseconds: 30_000_000_000)" in drop_views and "try? await Task.sleep(nanoseconds: 10_000_000_000)" in drop_views
     and drop_views.count("guard polls else { return }") == 2, "polls", "the row reads every 30 s and the open chat every 10 s, both off in the renders")

# ── The words only on stdin.
need('static func call(_ op: String, _ extra: [String] = []) -> [String] { ["drop-it", "--op", op] + extra }' in core, "stdin", "every call is the drop-it verb and its op")
need('return (call("submit"), data)' in core and 'return (call("history"), data)' in core and 'return (call("move", ["--drop", dropId]), data)' in core,
     "stdin", "a drop's words, History's search and Move's target go on stdin, never in the arguments")
need('let takesStdin: Set<String> = ["submit", "history", "move", "upload", "p2-set", "thread-turn"]' in helper and "case \"drop-it\": try emitDropIt(args: args)" in helper,
     "stdin", "the helper reads the words on stdin (0.5.374 adds the thread turn) and dispatches the verb")
helper_drop = between(helper, "    private func emitDropIt(args: [String]) throws {", "\n    }\n")
need("progress(" not in helper_drop and "print(" not in helper_drop, "no logs", "the helper's verb writes nothing but its answer")

# ── 0.5.371 option A: Ask and Drop, and files on the composer.
meeting_ask = code("Sources/MeetingAsk.swift")
need("MeetingAskComposer(text: $draft, placeholder: DropIt.placeholder, onSubmit: ask," in drop_views and "onOptionSubmit: drop, fontSize: 14)" in drop_views,
     "composer keys", "the box is the meeting Ask composer: Return asks, Option-Return drops")
need("if flags.contains(.option), !flags.contains(.shift), let drop = parent.onOptionSubmit { drop(); return true }" in meeting_ask
     and "var onOptionSubmit: (() -> Void)? = nil" in meeting_ask, "composer keys", "Option-Return calls Drop only where a caller sets it; the meeting keeps its new line")
need("TextField(DropIt.placeholder" not in drop_views and "onAttach: { attachment in Task { await DropItIntake.take(attachment, store: store) } }" in drop_views,
     "file never text", "a file dropped or pasted on the words is an attachment, never its path as text")
need(drop_views.count(".modifier(MeetingFilesDrop(enabled: true, targeted: $dropTargeted)") == 1, "drop zone", "the whole box is the drop target, the meeting Files box's own drop")
comp = between(drop_views, "    private var composer: some View {", "    private func ask() {")
need("if !store.attachments.isEmpty" in comp and "Button { addFiles() }" in comp and "DropItIntake.paste(NSPasteboard.general" in comp
     and comp.index("Button { addFiles() }") > comp.index(".modifier(MeetingFilesDrop("), "drop zone", "Add and Paste always show under the box; only the chips row is conditional")
need("await WorkCardFileStore.stage(provider, policy: .meeting" in drop_views and "WorkCardFileStore.meetingPastePayload(pasteboard)" in drop_views
     and "WorkCardFileStore.pngData(data)" in drop_views, "reuse meeting files", "drops, pastes and images are read with the meeting Files code")
need("static func stage(_ provider: NSItemProvider, policy: ContextFilePolicy" in code("Sources/WorkCardFiles.swift")
     and "await Self.stage(provider, policy: policy, ordinal: ordinal, count: count, at: date) {" in code("Sources/WorkCardFiles.swift"), "reuse meeting files", "one staging implementation, used by cards, meetings and the composer")
need('let accepted = await today.startRun(target: target, title: String(prompt.prefix(60)), prompt: prompt,' in window
     and 'handoff: handoffStore, attachmentIds: files)' in window and "query-jobs" not in core, "ask path", "Ask is Control's existing Today Work run, with the files' ids; no new query path")
need('if !attachmentIds.isEmpty { job["attachmentIds"] = Array(attachmentIds.prefix(5)) }' in code("Sources/WorkHandoffStore.swift")
     and 'if !files.isEmpty { payload["attachmentIds"] = files }' in helper, "ask path", "the media ids reach POST /api/query-jobs")
need(window.count("        wireDropItComposer()\n") == 2 and "model.dropIt.dropTakes = model.status.dropIt.attachments" in window
     and "model.dropIt.isSecret = { WorkCardFiles.looksSecret(name: $0) }" in window, "composer wiring", "the chat and ⌘K both wire Ask, the drop file limit and the secrets rule")
need('"dropItAttachments": files.map { $0 as Any } ?? NSNull()' in helper and 'attachments: details["dropItAttachments"]?.int' in models, "capability files", "capabilities.dropIt.attachments is read")
need('if op == "upload" { try emitDropItUpload(input); return }' in helper and "progress(" not in between(helper, "    private func emitDropItUpload(_ input: Data) throws {", "\n    }\n"),
     "uploads", "the upload is its own op and writes nothing but its answer")

# ── The capability.
need("details.merge(Self.dropItStatusFields(health?[\"capabilities\"])) { _, new in new }" in helper, "capability", "status reads capabilities.dropIt")
need("dropIt = DropItCapability(statusDetails: details)" in models and "var available: Bool { supported && enabled }" in models
     and "var supported: Bool { protocolVersion == 1 }" in models, "capability", "available is protocol 1 and on")

# ── ⌘K: File to Work exactly, unless Drop it is on.
old_row = '            rows.append(Row(id: "file", kind: .file, group: .asking, title: "File to Work", detail: "Saves your words to the Work inbox. No run.", trailing: "Option-Return"))\n'
need(setup.count(old_row) == 1, "command row off", "the File to Work row is as it was")
need(old_row + '\n            if s.dropIt, let index = rows.lastIndex(where: { $0.id == "file" }) { rows[index] = dropRow }\n' in setup,
     "command row on", "with Drop it on, the same row is swapped for Drop it, nothing else")
need("s.dropIt = model.status.dropIt.available" in window, "command row on", "⌘K's snapshot reads the capability")
need("        case .file:\n            todayFileOrDrop(listing.words)" in window and "submit: { words in todayFileOrDrop(words) }" in window,
     "command action", "the row and Option-Return go through todayFileOrDrop")
need("guard model.status.dropIt.available else { todaySubmitAsk(words); return }" in window, "command action", "with Drop it off they file exactly as before")

# ── Settings.
need("if model.status.dropIt.supported { DropItSettingRow(model: model, store: model.dropIt) }" in views, "settings row", "the switch shows only for a server that has Drop it")
need('($0 != "DROP-01" || model.status.dropIt.supported)' in views, "settings search", "search lists it only when it is drawn")
need(catalog.count('.init("DROP-01", "Drop it",') == 1 and '"DROP-01"' not in catalog.replace('.init("DROP-01", "Drop it",', ""), "settings row", "one DROP-01 row in the catalog")
need('Toggle(isOn: Binding(get: { model.status.dropIt.enabled }, set: { on in Task { await model.setDropItEnabled(on) } }))' in drop_views,
     "settings row", "the switch is the server's value and PUTs through the model")

# ── Deep links reuse the existing navigation, each with the way back.
follow = between(window, "    func dropItFollow(_ action: String, link: DropIt.Link?) {", "\n    }\n\n")
need('openHandoffWork("task:\\(domain):\\(link.id)")' in follow and "dropItCameBack = DropIt.cameBackCard" in follow, "deep links", "Open card opens the Work card, selected")
need("select(.threads)" in follow and "model.openContextRecord(record, kind: \"thread\")" in follow, "deep links", "Open thread opens Threads on that thread")
need('commandOpenMemories("review", native: .toReview)' in follow, "deep links", "Open memory opens Memories, To review")
need("openHandoffSession(link.id)" in follow, "deep links", "Open session opens that session")
need("if let line = dropItCameBack, !showingSettings, !(section == .messages && model.dropItChatRouteActive) {\n                DropItCameBackStrip(line: line, back: dropItBackToChat)" in window,
     "deep links", "the pane a deep link opened shows Back to the chat")
need("        dropItCameBack = nil\n" in between(window, "    private func select(_ requested: ActivitySection) {", "\n    }\n") and "        dropItCameBack = nil\n" in between(window, "    private func goHome() {", "\n    }\n"),
     "deep links", "going anywhere else drops the strip")

# ── Copy: no em dash, en dash or arrow in the chat's words or the catalog row.
literals = re.findall(r'"((?:[^"\\\n]|\\.)*)"', core + drop_views)
for text in literals:
    need(not re.search("[—–→]|->", text), "copy", f"no em dash, en dash or arrow: {text[:60]}")
row = re.search(r'\.init\("DROP-01", "Drop it", "([^"]*)"', catalog)
need(row is not None and not re.search("[—–→]|->", row.group(1)), "copy", "the Settings row's words")

# ── Every app compile lists the two new files.
for script in list((root / "Tests").glob("*.sh")) + list((root / "scripts").glob("*.sh")) + list((root / "Tests").glob("*.py")):
    if script.name == "drop-it-pins.py":
        continue
    text = script.read_text(encoding="utf-8")
    for command in [line for line in text.replace("\\\n", " ").splitlines() if "swiftc" in line]:
        if '"$ROOT/Sources/ControllerModel.swift"' in command:
            for f in ("DropIt.swift", "DropItViews.swift"):
                need(f'"$ROOT/Sources/{f}"' in command, "source lists", f"{script.name} compiles ControllerModel without {f}")

# ── Version touchpoints and the lanes.
plist = read("Resources/Info.plist")
need(re.search(r"<key>CFBundleShortVersionString</key>\s*<string>0\.5\.377</string>", plist) and re.search(r"<key>CFBundleVersion</key>\s*<string>431</string>", plist),
     "version", "Info.plist is 0.5.377 (build 431), pet session counts on top of Meeting Prep, Ask Work review, the Messages cleanup, quit fix, P2 and Drop it")
whats = json.loads(read("Resources/WhatsNew.json"))
sec = [s for s in whats["whatsNew"]["sections"] if s["title"] == "0.5.371"]
need(whats.get("version") == "0.5.377" and len(sec) == 1 and any("Drop it" in i for i in sec[0]["items"]), "version", "What's New has one 0.5.371 section naming Drop it")
need("\n## 0.5.371 (build 425)" in "\n" + read("CHANGELOG.md"), "version", "the changelog has its 0.5.371 (build 425) entry")
need('python3 "$ROOT/Tests/drop-it-helper-checks.py" "$TMP/cos-control-helper"' in run_sh, "lanes wired", "Tests/run.sh runs the helper checks")
for lane in ("pins", "models", "wiring"):
    need(f'COS_DROP_IT_LANE={lane} zsh "$ROOT/Tests/run-drop-it.sh"' in run_sh, "lanes wired", f"Tests/run.sh runs the {lane} lane")

print("drop it pins: %d passed" % passed)
