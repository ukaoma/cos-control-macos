#!/usr/bin/env python3
"""0.5.259 mutation lane for the Activity home guards. Run by hand, never by a gate.

    python3 Tests/mutate-activity-home.py <worktree> <scratch dir> [name ...]

It copies the worktree to <scratch dir>/copy, proves the UNMUTATED lane is green first (Tests/activity-home-pins.py, then
Tests/run-activity-home.sh), then applies one mutant at a time: the target text must appear exactly once, the mutant must
make a check fail, and the failure must name the behaviour the mutant breaks ("check failed [<behaviour>]" from the Swift
checks, or "[<behaviour>]" in the pin's words). The copy is restored and compared byte for byte after every mutant. A
mutant that lands and survives is a finding. One suite at a time.
"""
import filecmp, pathlib, shutil, subprocess, sys, time

M = "Sources/Models.swift"
W = "Sources/ActivityWindow.swift"
V = "Sources/Views.swift"
# (name, file, original, mutant, words the killing failure must contain)
MUTANTS = [
    # Desks (Sources/Models.swift, ActivityHome).
    ("may need you: the 15 minute threshold", M, "now.timeIntervalSince(updated) >= quietAfter", "now.timeIntervalSince(updated) > quietAfter", "[may need you]"),
    ("may need you: a scheduled job can be quiet", M, "if !session.heldByServer, let updated", "if let updated", "[may need you]"),
    ("live list: a row the live list lacks keeps its stale state", M, "deskState(row, live: false, now: now, calendar: calendar)",
     "deskState(row, live: true, now: now, calendar: calendar)", "[live list]"),
    ("live list: a session seen twice gets two seats", M, "guard !liveSeen.contains(where: { ClaudeSession.sameSession($0.id, row.id) }) else { continue }", "", "[live list]"),
    ("desk selection: scheduled jobs get desks", M, "guard let state = seat.state, !seat.row.isScheduledJob else { return nil }",
     "guard let state = seat.state else { return nil }", "[desk selection]"),
    ("desk selection: finished means any day", M, "calendar.isDate(updated, inSameDayAs: now) { return .finished }",
     "now.timeIntervalSince(updated) >= 0 { return .finished }", "[desk selection]"),
    ("desk order: the waits newest first", M, "if x != y { return a.state.rank <= DeskState.maybe.rank ? x < y : x > y }",
     "if x != y { return a.state.rank <= DeskState.maybe.rank ? x > y : x < y }", "[desk order]"),
    ("desk order: an ask dates from its last write", M, "let since = state == .asked ? (stamp(seat.row.stateSince) ?? seat.row.updatedDate) : seat.row.updatedDate",
     "let since = seat.row.updatedDate", "[desk order]"),
    ("desk cap: 13 desks", M, "(Array(desks.prefix(deskCap)), max(0, desks.count - deskCap))", "(Array(desks.prefix(deskCap + 1)), max(0, desks.count - deskCap - 1))", "[desk cap]"),
    ("sessions tally: a quiet desk counts as working", M, "            case .maybe: break", "            case .maybe: tally.working += 1", "[sessions tally]"),
    ("reduce motion: a working desk glows under Reduce Motion", M, "func glows(reduceMotion: Bool) -> Bool { self == .working && !reduceMotion }",
     "func glows(reduceMotion: Bool) -> Bool { self == .working }", "[reduce motion]"),
    # Needs you.
    ("may need you: stated as fact (filled dot)", M, "var isFact: Bool { kind != .maybe }", "var isFact: Bool { true }", "[may need you]"),
    ("may need you: said to have asked", M, 'out.append(Need(kind: .maybe, what: desk.session.title, why: "quiet, may need you", since: desk.since, desk: desk))',
     'out.append(Need(kind: .maybe, what: desk.session.title, why: "asked you a question", since: desk.since, desk: desk))', "[may need you]"),
    ("oldest first: newest first", M, "case let (x?, y?) where x != y: return x < y", "case let (x?, y?) where x != y: return x > y", "[oldest first]"),
    ("oldest first: an undated item leads", M, "case (.some, .none): return true", "case (.some, .none): return false", "[oldest first]"),
    ("missing source: no meetings reads as zero voices", M, "guard !meetings.isEmpty else { return nil }", "", "[missing source]"),
    ("missing source: 0 work items is an item", M, "if let count = sources.workAttention, count > 0 {", "if let count = sources.workAttention {", "[missing source]"),
    ("quiet line: claimed before any source answers", M, "return available ? .quiet : .hidden", "return .quiet", "[quiet line]"),
    ("next: opens the newest", M, "static func nextTarget(_ items: [Need]) -> Need? { items.first }", "static func nextTarget(_ items: [Need]) -> Need? { items.last }", "[next]"),
    ("next: one item still reads Next", M, 'items.count == 1 ? "Open" : "Next"', '"Next"', "[next]"),
    # Cards.
    ("lead never repeats footer: Work's lead is its footer", M, 'body.lead = [Span(text: "\\(n(fresh)) new to sort", waits: true)]',
     'body.lead = [Span(text: body.footer ?? "", waits: true)]', "[lead never repeats footer]"),
    ("no fake zero: 0 voices to name", M, "if let voices = input.voices, voices.voices > 0 {", "if let voices = input.voices {", "[no fake zero]"),
    ("no fake zero: an unloaded status reads Setup needed", M, "} else if input.memorySetupNeeded {", "} else {", "[no fake zero]"),
    # Wiring (pins).
    ("⌘] routing: Next loses ⌘]", W, '                .keyboardShortcut("]", modifiers: .command)\n                .help("Open the oldest thing waiting on you (⌘])")',
     '                .help("Open the oldest thing waiting on you (⌘])")', "[⌘] routing]"),
    ("⌘] routing: Next opens the newest", W, "if let next = ActivityHome.nextTarget(needs) { openNeed(next) }", "if let next = needs.last { openNeed(next) }", "[⌘] routing]"),
    ("⌘] routing: a second ⌘] in the window", W, '.keyboardShortcut("h", modifiers: [.command, .shift])', '.keyboardShortcut("]", modifiers: .command)', "[⌘] routing]"),
    ("⌘] routing: the line mounted beside every route", W, "            lensRail\n            Divider()", "            lensRail\n            needsYouLine([], available: false, now: Date())\n            Divider()", "[⌘] routing]"),
    ("⌘] routing: the review shares the home's route", W, "} else if section == .speakers, selectedSpeakerSessionID != nil {\n                    if model.reviewRouteActive {",
     "} else if section == .speakers || section == nil, selectedSpeakerSessionID != nil {\n                    if model.reviewRouteActive {", "[⌘] routing]"),
    ("⌘] routing: Next to name without a next", V, "                if onNextUnnamed != nil {", "                if true {", "[⌘] routing]"),
    ("reduce motion: the glow starts unguarded", W, "guard desk.state.glows(reduceMotion: reduceMotion) else {", "guard true else {", "[reduce motion]"),
    ("reduce motion: desks ignore the setting", W, "ActivityDeskMark(desk: desk, now: now, reduceMotion: reduceMotion)", "ActivityDeskMark(desk: desk, now: now, reduceMotion: false)", "[reduce motion]"),
    ("open routes: a desk opens the live short id", W, "selectedSessionID = desk.openRow.id", "selectedSessionID = desk.session.id", "[open routes]"),
    ("open routes: Work opens on everything", W, "workWorkspaceState.scope = .attention", "workWorkspaceState.scope = .all", "[open routes]"),
    ("one source: the pet's live list ignored", W, "model.petEnabled ? model.petSessions : nil", "nil", "[one source]"),
    ("desk click: the card stops opening its tab", W, ".onTapGesture { select(item) }", ".onTapGesture { }", "[desk click]"),
    ("captions: the description is lost", W, "                            .help(item.summary)\n", "", "[captions]"),
    ("card copy: every sub line drawn", W, "ForEach(Array(body.subs.prefix(2).enumerated()), id: \\.offset)", "ForEach(Array(body.subs.enumerated()), id: \\.offset)", "[card copy]"),
    ("loads: Intake not loaded", W, "            await model.loadWorkIntake()\n", "", "[loads]"),
    ("loads: the review list not loaded", W, "        if (model.status.learningToReview ?? 0) > 0, model.toReviewEvents.isEmpty { await model.loadToReviewEvents() }\n", "", "[loads]"),
]


def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started

def suite(copy):
    code, out, seconds = run(["/usr/bin/python3", "Tests/activity-home-pins.py", "."], copy)
    if code != 0:
        return code, out, seconds
    code2, out2, seconds2 = run(["zsh", "Tests/run-activity-home.sh"], copy)
    return code2, out + out2, seconds + seconds2

def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests"):
        shutil.copytree(src / part, copy / part)
    code, out, seconds = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS:") or "wiring pinned" in l]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(p[:140] for p in passed) or '(no PASS line)'}", flush=True)
    if code != 0 or len(passed) != 2:
        print(out[-3000:])
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed, survived = 0, 0
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        mutated = text.replace(old, new)
        path.write_text(mutated, encoding="utf-8")
        try:
            code, out, seconds = suite(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        if not filecmp.cmp(path, src / rel, shallow=False):
            sys.exit(f"RESTORE FAILED for {name}: {rel} differs from the worktree")
        lines = [l for l in out.splitlines() if "check failed [" in l or "0.5.259 pin:" in l or "error:" in l]
        reason = lines[0].strip() if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:240]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:240]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 else 1)

if __name__ == "__main__":
    main()
