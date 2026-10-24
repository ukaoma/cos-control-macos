#!/usr/bin/env python3
"""Motion tokens, phase 1: the shared `Motion` scale in COSMotion.swift and the three animations that used to run under
Reduce Motion (a transcript fold, the setup-guide scroll, the chat match scroll). Pinned on code with comments
stripped. Each failure names its fix in brackets.

    python3 Tests/motion-gate-pins.py <worktree>
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
fails = []
count = 0
def need(ok, label):
    global count
    count += 1
    if not ok:
        fails.append(label)

def strip(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//") and not l.strip().startswith("///"))

def body(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i + len(start))]

def read(name):
    return strip((root / name).read_text())

mot = read("Sources/COSMotion.swift")
md = read("Sources/COSMarkdown.swift")
views = read("Sources/Views.swift")
win = read("Sources/ActivityWindow.swift")

motion = body(mot, "enum Motion {", "extension COSPalette {")
need("static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation?" in motion, "[Motion] gated(_:reduceMotion:) exists")
need("reduceMotion ? nil : animation" in motion, "[Motion] gated returns nil under Reduce Motion, so the change lands with no animation")
need("static let quick = 0.15" in motion and "static let fast = 0.25" in motion, "[Motion] quick 0.15 s and fast 0.25 s, the values gotcos and the companion use")
for unused in ("micro", "medium", "slow", "verySlow", "stagger", "distance", "smoothOut", "bounce"):
    need(unused not in motion, f"[Motion] no unused token: {unused}")

fold = body(md, "private struct COSMarkdownDetails: View {", "var body: some View")
need("@Environment(\\.accessibilityReduceMotion) private var reduceMotion" in fold, "[fold] the transcript fold reads Reduce Motion")
need("withAnimation(Motion.gated(.easeInOut(duration: Motion.quick), reduceMotion: reduceMotion)) { expanded.toggle() }" in md,
     "[fold] the transcript fold toggles through Motion.gated")

need('withAnimation(Motion.gated(.default, reduceMotion: reduceMotion)) { reader.scrollTo("setup-guide", anchor: .top) }' in views,
     "[setup] Finish setup scrolls to the guide through Motion.gated")
need('withAnimation { reader.scrollTo("setup-guide"' not in views, "[setup] no ungated scroll to the setup guide is left")

jump = body(win, "private func jumpToMatch(", "private func messageDetail(")
need("withAnimation(Motion.gated(.easeInOut(duration: Motion.fast), reduceMotion: reduceMotion))" in jump,
     "[chat] the chat match scroll goes through Motion.gated")

if fails:
    for f in fails:
        print("motion gate pin: " + f)
    sys.exit(1)
print(f"PASS: motion gate pins: {count} passed")
