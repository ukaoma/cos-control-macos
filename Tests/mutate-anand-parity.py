#!/usr/bin/env python3
"""Anand parity (D4, 2026-11-12): the mutation gate for Back by path, the Speakers copy buttons and Meetings on today.

    python3 -u Tests/mutate-anand-parity.py [--targets] [mutant-name ...]

Runs each kind unmutated first and refuses unless it passes (a gate over a red suite proves nothing); then for each mutant
asserts its target appears EXACTLY ONCE, applies it, reruns its kind, and requires a failure carrying the named message.
Files are restored in `finally`. The words kind compiles Models.swift alone through Tests/compile-guard.sh, under the
swift-slot lease; the pins kind compiles nothing.
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
M, W, V, C, A = "Sources/Models.swift", "Sources/ActivityWindow.swift", "Sources/Views.swift", "Sources/ControllerModel.swift", "Sources/ActivityMeetings.swift"
KINDS = {"words": ["zsh", "Tests/run-anand-parity.sh"], "pins": ["python3", "Tests/anand-parity-pins.py", "."]}
MUTANTS = [
    # Item 1, the path logic (words) and its wiring (pins).
    ("every-move-a-step", "words", M, "        guard !goingBack, crossed || itemToItem else { return (path, pick) }", "        guard !goingBack else { return (path, pick) }",
     "check failed [closing an item to its list is not a step]"),
    ("back-records", "words", M, "        guard !goingBack, crossed || itemToItem else { return (path, pick) }", "        guard crossed || itemToItem else { return (path, pick) }",
     "check failed [Back's own move is not a step]"),
    ("item-to-item-off", "words", M, "        let itemToItem = !crossed && old.item != nil && new.item != nil && old.item != new.item", "        let itemToItem = false",
     "check failed [an item from an item in one section is a step]"),
    ("pick-ignored", "words", M, "        if let pick, new.section == pick.section { return ([], nil) }\n", "",
     "check failed [a sidebar pick clears the path and is spent on arrival]"),
    ("always-step", "words", M, "        return current == top.to || !hasDetail ? top : nil", "        return top",
     "check failed [elsewhere in the section, Back keeps the parent chain]"),
    ("settle-anything", "words", M, "        guard before != after, let top = path.last, top.to.section == before, top.from.section == after else { return path }",
     "        guard before != after, path.last != nil else { return path }", "check failed [a parent-chain move across sections drops only the step it undid]"),
    ("no-limit", "words", M, "        return (Array((path + [ActivityBackStep(from: old, to: new)]).suffix(limit)), pick)", "        return (path + [ActivityBackStep(from: old, to: new)], pick)",
     "check failed [the path keeps its last 30 steps]"),
    ("stack-flat", "words", M, "        return (Array((path + [ActivityBackStep(from: old, to: new)]).suffix(limit)), pick)", "        return ([ActivityBackStep(from: old, to: new)], pick)",
     "check failed [two jumps stack: the second Back returns home]"),
    ("speaker-return-removed", "pins", W, "            else if let sessionId = meetingReturnSpeakerSessionID { returnFromMeetingToSpeakers(sessionId) }\n", "",
     "[back] Speakers, a review, Open meeting, Back lands on the review"),
    ("trail-everything", "words", M, "        guard step(path, current: current, hasDetail: hasDetail) != nil else { return [] }\n", "",
     "check failed [no trail where Back keeps the parent chain]"),
    ("never-shortened", "words", M, "        guard count > room, room >= 3 else {", "        guard true else {",
     "check failed [a short trail shows every place]"),
    ("middle-kept", "words", M, "        return [0, nil] + Array((count - (room - 2))..<count).map { Optional($0) }", "        return Array(0..<count).map { Optional($0) }",
     "check failed [a long trail keeps the first and the last two, shortened in the middle]"),
    ("trail-hidden", "pins", W, "        if trail.isEmpty { locationCrumb } else { trailRow(trail) }", "        locationCrumb",
     "[trail] the trail shows only while Back goes along the path"),
    ("trail-link-dead", "pins", W, "Button(word) { goBackAlongPath(to: index) }", "Button(word) { }", "[trail] earlier places are links"),
    ("back-flag-sticks", "pins", W, "            // Back's own move has landed (one change per move): the next change is a step again.\n            backMoving = false\n", "",
     "[back] Back's own moves are not steps"),
    ("sides-off", "pins", W, "side: .you, caption: MessageSides.youCaption(time: turn.timeLabel))", "side: .card, caption: MessageSides.youCaption(time: turn.timeLabel))",
     "[sides] his words right, COS left"),
    ("bubble-left", "pins", W, "        .frame(maxWidth: 560, alignment: .trailing)\n        .frame(maxWidth: .infinity, alignment: .trailing)\n        .accessibilityElement(children: .combine)",
     "        .frame(maxWidth: 560, alignment: .leading)\n        .frame(maxWidth: .infinity, alignment: .leading)\n        .accessibilityElement(children: .combine)",
     "[sides] his words in the COS chat's own bubble, on the right"),
    ("edge-faint", "pins", "Sources/DropItViews.swift", "static let youEdgeReader = pair(0xab8436, 0x56422c)", "static let youEdgeReader = pair(0xe3cfa6, 0x56422c)",
     "[sides] the reader's bubble edge is 3 to 1 in light"),
    ("reply-row-card", "pins", "Sources/MessageReplyView.swift", "ActivityMessageCard(label: \"You\", text: reply.words, tint: ActivitySection.messages.tint, side: .you,",
     "ActivityMessageCard(label: \"You\", text: reply.words, tint: ActivitySection.messages.tint, side: .card,", "[sides] this Mac's replies sit on the same sides"),
    ("word-home-only", "words", M, "        step.from.section.flatMap(titles) ?? home", "        home", "check failed [Back names where it goes]"),
    ("path-ignored", "pins", W, "        if let step = backStep {\n            tookStep = true\n            backPath.removeLast()\n            returnTo(step.from)\n            return\n        }\n", "",
     "[back] Back goes back along the path first"),
    ("not-recorded", "pins", W, "            backPath = recorded.path\n", "", "[back] every change of section is a step"),
    ("rail-not-pick", "pins", W, "                    if reduceMotion { pickSection(item) }", "                    if reduceMotion { select(item) }",
     "[back] the rail, the home cards, Home and the shortcuts are picks"),
    ("pick-keeps-path", "pins", W, "        backPath = []\n        // Already there", "        // Already there", "[back] a pick clears the path"),
    ("linked-unguarded", "pins", W, "!isolatedWorkPreview, !showingLinkedSession, !meetingReturnToWork,", "!isolatedWorkPreview, !meetingReturnToWork,",
     "[back] the Work preview, the linked session and the meeting returns keep their own Back"),
    ("label-silent-voiceover", "pins", W, '.accessibilityLabel(backWord == nil ? "Back" : backLabel)', '.accessibilityLabel("Back")', "[back] Back says where it goes"),
    ("label-silent", "pins", W, ".help(backLabel)", '.help("Go back one step")', "[back] Back says where it goes"),
    ("review-not-reopened", "pins", W, "                if model.openReview?.sessionId != id { model.openSpeakerReview(sessionId: id) }\n", "",
     "[back] the item that was open comes back"),
    # Item 3.
    ("copied-on-both", "words", M, "        if copied == kind { return Self.copied }", "        if copied != nil { return Self.copied }",
     "check failed [copied shows only on the tapped one]"),
    ("old-summary-word", "words", M, ': "Copy summary"', ': "Summary"', "check failed [copy words]"),
    ("copied-stays", "pins", C, "            self?.copiedMeetingKind = nil\n", "", "[copy] Copied lasts copiedSeconds"),
    ("copy-silent", "pins", C, "        if let note = copyNote {\n            NSAccessibility.post(", "        if let note = copyNote, false {\n            NSAccessibility.post(",
     "[copy] VoiceOver hears what was copied"),
    # Item 4.
    ("jump-to-oldest", "words", M, '        days.filter { $0.count > 0 && $0.date < today }.map(\\.date).max()', '        days.filter { $0.count > 0 && $0.date < today }.map(\\.date).min()',
     "check failed [jump to the latest earlier day with meetings]"),
    ("plain-day-iso", "words", M, '        if day == today { return "Today" }', '        if day == today { return day }', "check failed [plain day as the web]"),
    ("today-needs-meetings", "pins", C, "                libraryDay = Self.currentMeetingDay()\n",
     "                if libraryDays.contains(where: { $0.date == Self.currentMeetingDay() && $0.count > 0 }) { libraryDay = Self.currentMeetingDay() }\n",
     "[today] Meetings opens on today, with or without meetings"),
    ("no-ring", "pins", A, ".stroke(cell.date == today ? tint : Color.clear, lineWidth: 1.2)", ".stroke(Color.clear, lineWidth: 1.2)", "[today] today is ringed"),
    ("empty-today-locked", "pins", A, ".disabled(count == 0 && cell.date != today)", ".disabled(count == 0)",
     "[today] an empty today can be picked, and VoiceOver says today"),
]


def run(kind):
    r = subprocess.run(KINDS[kind], cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, r.stdout + r.stderr


def main():
    want = set(sys.argv[1:]); targets_only = "--targets" in want; want.discard("--targets")
    chosen = [m for m in MUTANTS if not want or m[0] in want]
    bad = [m[0] for m in chosen if open(os.path.join(ROOT, m[2])).read().count(m[3]) != 1]
    if bad:
        print("targets not found exactly once:", ", ".join(bad)); sys.exit(2)
    if targets_only:
        print(f"targets: {len(chosen)} found exactly once"); return
    for kind in sorted({m[1] for m in chosen}):
        ok, out = run(kind)
        if not ok:
            print(f"REFUSED: baseline {kind} is not green:", out[-400:]); sys.exit(2)
        print(f"baseline {kind}: pass")
    killed = survived = 0
    for name, kind, rel, target, replacement, expect in chosen:
        path = os.path.join(ROOT, rel); source = open(path).read()
        try:
            open(path, "w").write(source.replace(target, replacement, 1))
            ok, out = run(kind)
        finally:
            open(path, "w").write(source)
        assert open(path).read() == source, "source not restored"
        if not ok and expect in out:
            killed += 1; print(f"KILLED   {name}: failed with '{expect}'")
        else:
            survived += 1; print(f"SURVIVED {name}: {'passed' if ok else 'failed for another reason: ' + out[-200:]}")
    print(f"mutants: {killed} killed, {survived} survived")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
