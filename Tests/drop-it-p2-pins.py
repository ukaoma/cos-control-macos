#!/usr/bin/env python3
"""0.5.372 Drop it P2 wiring pins: the source text that ties the Mac half together. Usage: drop-it-p2-pins.py <repo>.
Prints "drop it p2 pins: N passed"."""
import re, sys
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
for text in re.findall(r'\.init\("REACH-\d\d", "([^"]*)", "([^"]*)"', catalog):
    need(not re.search("[—–→]|->", text[0] + text[1]), "[copy] no em dash, en dash or arrow: " + text[0])
import json
whats = json.loads(read("Resources/WhatsNew.json")); plist = read("Resources/Info.plist"); log = read("CHANGELOG.md")
# 0.5.373 (the quit fix) sits on top: P2's own section, entry and order still hold; app-update-quit-request-pins pins the bump.
p2 = [s for s in whats["whatsNew"]["sections"] if s["title"] == "0.5.372"]
need(re.search(r"<key>CFBundleShortVersionString</key>\s*<string>0\.5\.37[2-9]</string>", plist) is not None and whats.get("version", "").startswith("0.5.37"), "[version] Info.plist and What's New are 0.5.372 or a later 0.5.37x")
need(len(p2) == 1 and any("COS reaching out" in i for i in p2[0]["items"]) and whats["whatsNew"]["sections"].index(p2[0]) <= 5, "[version] What's New has its 0.5.372 section naming COS reaching out, within the first six (0.5.377 through 0.5.373 sit above it)")
need("\n## 0.5.372 (build 426)" in "\n" + log and log.index("## 0.5.372 (build 426)") < log.index("\n## 0.5.371 (build 425)"), "[version] the changelog's 0.5.372 entry sits above 0.5.371's")
print(f"drop it p2 pins: {passed} passed")
