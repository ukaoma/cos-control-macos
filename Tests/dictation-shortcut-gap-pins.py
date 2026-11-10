#!/usr/bin/env python3
"""Lane D1 (0.5.387): the dictation no-shortcut warning is wired where the switch is, and nothing invents a shortcut.
Prints "dictation shortcut gap pins: N passed"."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
src = (root / "Sources/MacDictation.swift").read_text(encoding="utf-8")
core = (root / "Sources/MacDictationCore.swift").read_text(encoding="utf-8")
failed, passed = [], 0


def pin(ok, what):
    global passed
    if ok:
        passed += 1
    else:
        failed.append("FAIL " + what)


pin(src.count("enum DictationShortcutGap {") == 1, "one DictationShortcutGap")
pin("var needsShortcut: Bool { DictationShortcutGap.needsShortcut(enabled: enabled, hold: holdTrigger != nil, toggle: toggleTrigger != nil) }" in src,
    "the store asks the gate with its own two start shortcuts")
settings = src[src.index("struct MacDictationSettings: View {"):src.index("enum DictationShortcutGap {")]
switch_at = settings.index('Toggle("Dictate into Mac apps", isOn: $store.enabled)')
warning_at = settings.find("DictationNoShortcutWarning(store: store, activityShortcut: activityShortcut)")
mic_at = settings.index("if shows(.microphone) {")
pin(switch_at < warning_at < mic_at, "the warning sits right under the switch, before the Microphone group")
dictation_section = settings[settings.index("if shows(.dictation) {"):mic_at]
pin("DictationNoShortcutWarning(" in dictation_section, "the warning is in the Dictation section (the hub's Dictation card draws it)")
shortcuts = settings[settings.index("if shows(.shortcuts) {"):settings.index("if shows(.sounds) {")]
pin(re.search(r"if !store\.needsShortcut \{\s*DictationShortcutRow\(store: store, slot: \.hold", shortcuts) is not None,
    "while the warning shows, the Shortcuts list does not draw a second Push to talk recorder")
view = src[src.index("struct DictationNoShortcutWarning: View {"):src.index("private struct DictationShortcutRow: View {")]
pin("if store.needsShortcut {" in view and "Text(DictationShortcutGap.warning)" in view
    and "DictationShortcutRow(store: store, slot: .hold, activityShortcut: activityShortcut)" in view,
    "the warning view: the words and the Push to talk recorder, only when needed")
# No default start shortcut is invented: Fix keeps its default, Push to talk and Start and stop have none.
defaults = set(re.findall(r"static let default(\w+)\s*[:=]", core))
pin("Hold" not in defaults and "Toggle" not in defaults and "Fix" in defaults, f"no default Push to talk or Start and stop shortcut ({sorted(defaults)})")

if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print(f"dictation shortcut gap pins: {passed} passed")
