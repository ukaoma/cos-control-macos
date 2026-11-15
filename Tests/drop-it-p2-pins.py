#!/usr/bin/env python3
"""0.5.372 Drop it P2 wiring pins: the source text that ties the Mac half together. Usage: drop-it-p2-pins.py <repo>.
Prints "drop it p2 pins: N passed"."""
import plistlib, re, sys
from pathlib import Path
root = Path(sys.argv[1])
def read(p): return (root / p).read_text(encoding="utf-8")
views, model, catalog, p2, release = read("Sources/Views.swift"), read("Sources/ControllerModel.swift"), read("Sources/SettingsHubCatalog.swift"), read("Sources/DropItP2.swift"), read("scripts/build-release.sh")
drop, chat, helper = read("Sources/DropIt.swift"), read("Sources/DropItViews.swift"), read("HelperSources/main.swift")
passed = 0
def need(ok, what):
    global passed
    if not ok: print("drop it p2 pin FAILED: " + what); sys.exit(1)
    passed += 1
need(views.count('if hubGroupShown("work.reach") {') == 1 and views.count("DropItReachRows(store: model.dropItP2)") == 1, "[settings card] the card mounts once, behind its gate")
need('case "work.reach": return model.status.dropIt.available && model.dropItP2.settings != nil' in views, "[settings gate] only while Drop it is on and the settings answered")
need(catalog.count('group: "work.reach"') == 17 and catalog.count('.init(id: "work.reach"') == 1, "[settings rows] seventeen rows in one group")
need(len(set(re.findall(r'\.init\("(REACH-\d\d)"', catalog))) == 17, "[settings rows] REACH-01 to REACH-17 once each")
need(model.count("dropItP2.start()") == 1, "[pump] the banner pump starts once")
need(model.count("meetingAudioNotifier.onOpenDropIt = ") == 1 and "func openDropItFromNotice()" in model, "[click] a COS chat notification opens the chat")
i, j = model.index('if response.notification.request.content.userInfo["cosChat"] != nil {'), model.index('guard let workID = response.notification.request.content.userInfo["workID"]')
need(i < j, "[click] a COS chat notification is routed before the Work one")
need("guard available() else { tick = 0; return }" in p2, "[off] nothing runs while Drop it is off")
need('"$ROOT/Sources/DropItP2.swift" "$ROOT/Sources/DropItP2Views.swift"' in release, "[source lists] the release build has both new files")
need('else if action.isServerAction { Task { await store.serverAction(item, action) } }' in chat, "[chat actions] reminder buttons reach the server")
need(chat.count("if dropTargeted { DropItDropSlot().id(DropItDropSlot.anchor) }") == 1 and chat.count("DropIt.dropZoneTarget") == 2
     and "Label(DropIt.dropZoneTarget" not in chat.split("struct DropItDropSlot")[0], "[drag over] the drop slot ends the chip row and no overlay label covers a chip")
need('"banners", "reminders", "p2", "p2-set"' in helper and 'case "p2-set":' in helper, "[helper] the four P2 ops")
# Keep the jump control outside the measured scroll viewport: it must never obscure an answer.
thread = chat[chat.index('    private var thread: some View {'):chat.index('\n    @ViewBuilder\n    private func rowView')]
need(thread.startswith('    private var thread: some View {\n        VStack(spacing: 0) {\n            GeometryReader { viewport in\n'), "[jump layout] an outer stack owns the measured scroll viewport")
need('\n            }\n            HStack {\n                Spacer()\n                Button { jumpRequest += 1 }' in thread
     and '.overlay(' not in thread and '.safeAreaInset(' not in thread,
     "[jump layout] an unconditional sibling row reserves space outside the scroll viewport")
need(thread.count('.onChange(of: jumpRequest)') == 1
     and '.onChange(of: jumpRequest) { _, _ in\n                        followsLatest = true; proxy.scrollTo("drop-it-bottom", anchor: .bottom)\n                    }' in thread,
     "[jump action] one state change follows and scrolls to the bottom marker")
need('if positioned { followsLatest = bottom <= viewport.size.height + 50 }' in thread
     and 'if let anchor { proxy.scrollTo(anchor, anchor: .top) }' in thread,
     "[jump follow] keep the measured tolerance and older-history top anchor")
need(thread.endswith('        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)\n    }\n')
     and thread.count('maxHeight: .infinity') == 1,
     "[jump sizing] only the outer stack fills height; the button row stays natural height")
for text in re.findall(r'\.init\("REACH-\d\d", "([^"]*)", "([^"]*)"', catalog):
    need(not re.search("[—–→]|->", text[0] + text[1]), "[copy] no em dash, en dash or arrow: " + text[0])
import json
whats = json.loads(read("Resources/WhatsNew.json")); plist = read("Resources/Info.plist"); log = read("CHANGELOG.md")
# The bundled What's New is sanitized through AppUpdateWhatsNew.sectionLimit (8) before Views renders it.
# P2's older notes were already outside that visible window; the old <=17 bound was a historical-file position,
# not a display limit. Pin actual release identity and chronological retention, not an arbitrary growing cutoff.
meta = plistlib.loads(plist.encode())
sections = whats["whatsNew"]["sections"]
titles = [s["title"] for s in sections]
p2 = [s for s in sections if s["title"] == "0.5.372"]
need(meta.get("CFBundleShortVersionString") == "0.5.396" and meta.get("CFBundleVersion") == "450"
     and whats.get("version") == "0.5.396" and titles[:3] == ["0.5.396", "0.5.395", "0.5.393"],
     "[version] Info.plist and What's New identify 0.5.396 build 450, carrying the 0.5.395 and 0.5.393 notes")
need(len(p2) == 1 and any("COS reaching out" in i for i in p2[0]["items"]),
     "[version] What's New retains one 0.5.372 section naming COS reaching out")
releases = [tuple(map(int, title.split("."))) for title in titles if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", title)]
need(releases == sorted(releases, reverse=True) and titles.count("0.5.373") == 1 and titles.count("0.5.371") == 1
     and titles.index("0.5.373") + 1 == titles.index("0.5.372")
     and titles.index("0.5.372") + 1 == titles.index("0.5.371"),
     "[version] the retained release notes descend, with 0.5.373 then P2 0.5.372 then Drop it 0.5.371")
need("\n## 0.5.372 (build 426)" in "\n" + log and log.index("## 0.5.372 (build 426)") < log.index("\n## 0.5.371 (build 425)"), "[version] the changelog's 0.5.372 entry sits above 0.5.371's")
print(f"drop it p2 pins: {passed} passed")
