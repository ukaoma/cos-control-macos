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
    ("known wait: an inferred wait is a fact", M, "                if knownWait(session) { return .asked }\n", "                return .asked\n", "[may need you]"),
    ("known wait: the hooks are not believed", M, 'session.stateSource == "hook" || session.stateSource == "registry" ||', 'session.stateSource == "registry" ||', "[known wait]"),
    ("known wait: the transcript's open question ignored", M,
     "|| !session.waitingFor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.waitingOnUser",
     "|| !session.waitingFor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", "[known wait]"),
    ("may need you: a scheduled job can be quiet", M, "return session.heldByServer ? .working : .maybe", "return .maybe", "[may need you]"),
    ("working: a long run reads quiet again", M, "            if session.isPetWorking { return .working }\n",
     "            if session.isPetWorking, let updated, now.timeIntervalSince(updated) >= 15 * 60 { return .maybe }\n            if session.isPetWorking { return .working }\n", "[working]"),
    ("live list: a row the live list lacks keeps its stale state", M, "seats.append(seat(row, open: row, live: false, inList: true))",
     "seats.append(seat(row, open: row, live: true, inList: true))", "[live list]"),
    ("live list: a session seen twice gets two seats", M, "guard !liveSeen.contains(where: { ClaudeSession.sameSession($0.id, row.id) }) else { continue }", "", "[live list]"),
    ("desk selection: scheduled jobs get desks", M, "guard let state = seat.state, !seat.row.isScheduledJob else { return nil }",
     "guard let state = seat.state else { return nil }", "[desk selection]"),
    ("desk selection: finished means any day", M, "calendar.isDate(updated, inSameDayAs: now) { return .finished }",
     "now.timeIntervalSince(updated) >= 0 { return .finished }", "[desk selection]"),
    ("desk order: the waits newest first", M, "if x != y { return a.state.rank <= DeskState.maybe.rank ? x < y : x > y }",
     "if x != y { return a.state.rank <= DeskState.maybe.rank ? x > y : x < y }", "[desk order]"),
    ("desk order: an ask dates from its last write", M, "let since = state == .asked ? (stamp(seat.row.stateSince) ?? seat.updated) : seat.updated",
     "let since = seat.updated", "[desk order]"),
    ("desk strip: no cap of 12", M, "        var shown = min(count, deskCap)\n", "        var shown = count\n", "[desk strip]"),
    ("desk strip: +N takes no room", M, "(more ? (n > 0 ? deskGap : 0) + deskMoreWidth : 0)", "0", "[desk strip]"),
    ("desk strip: a short list is never measured", M, "if count <= deskCap, span(count, more: false) <= width { return (count, 0) }",
     "if count <= deskCap { return (count, 0) }", "[desk strip]"),
    ("sessions tally: a quiet desk counts as working", M, "            case .maybe: break", "            case .maybe: tally.working += 1", "[sessions tally]"),
    ("reduce motion: a working desk glows under Reduce Motion", M, "func glows(reduceMotion: Bool) -> Bool { self == .working && !reduceMotion }",
     "func glows(reduceMotion: Bool) -> Bool { self == .working }", "[reduce motion]"),
    # Needs you: facts, words, order, the backlog, the cap, the quiet line, Next.
    ("may need you: stated as fact (filled dot)", M, "var isFact: Bool { kind != .maybe }", "var isFact: Bool { true }", "[may need you]"),
    ("may need you: said to have asked", M, 'out.append(Need(kind: .maybe, what: desk.session.title, why: "quiet, may need you", since: desk.since, desk: desk))',
     'out.append(Need(kind: .maybe, what: desk.session.title, why: "asked you a question", since: desk.since, desk: desk))', "[may need you]"),
    ("waiting kind: a permission reads as a question", M, 'case "permission": return "wants your permission"\n', 'case "permission": return "asked you a question"\n', "[waiting kind]"),
    ("waiting kind: a plan reads as a question", M, 'case "plan": return "has a plan to approve"\n', 'case "plan": return "asked you a question"\n', "[waiting kind]"),
    ("waiting kind: input reads as a question", M, 'case "mcp_input": return "needs your input"\n', 'case "mcp_input": return "asked you a question"\n', "[waiting kind]"),
    ("one item detail: never shown", M, "why: waiting.count == 1 ? askedDetail(desk.session) : askedWords(desk.session),", "why: askedWords(desk.session),", "[one item detail]"),
    ("one item detail: not cut", M, "let detail = clip(session.waitingDetail.trimmingCharacters(in: .whitespacesAndNewlines), detailLimit)",
     "let detail = session.waitingDetail.trimmingCharacters(in: .whitespacesAndNewlines)", "[one item detail]"),
    ("one item detail: a plan's text shown", M, 'guard session.state == "waiting", !detail.isEmpty, session.waitingKind != "plan" else',
     'guard session.state == "waiting", !detail.isEmpty else', "[one item detail]"),
    ("oldest first: newest first within a group", M, "case let (p?, q?) where p != q: return p < q", "case let (p?, q?) where p != q: return p > q", "[oldest first]"),
    ("oldest first: an undated item leads", M, "case (.some, .none): return true", "case (.some, .none): return false", "[oldest first]"),
    ("sessions first: order by date alone", M, "            if x != y { return x < y }\n            switch (a.element.since", "            switch (a.element.since", "[sessions first]"),
    ("sessions first: quiet ranks with asked", M, "                case .maybe: 1\n", "                case .maybe: 0\n", "[sessions first]"),
    ("backlog order: voices rank with memories", M, "                case .voices: 2\n", "                case .voices: 3\n", "[backlog order]"),
    ("compact backlog: Also without sessions", M, "var alsoPrefix: Bool { !sessions.isEmpty && !backlog.isEmpty }", "var alsoPrefix: Bool { !backlog.isEmpty }", "[compact backlog]"),
    ("compact backlog: the meeting name comes back", M, "            case .count(let need): need.what\n", '            case .count(let need): need.what + " " + need.why\n', "[compact backlog]"),
    ("compact backlog: no dot between parts", M, "            if !pieces.isEmpty { pieces.append(.dot(index)) }\n", "", "[compact backlog]"),
    ("compact backlog: sessions counted as backlog", M, "LineParts(sessions: items.filter(\\.isSession), backlog: items.filter { !$0.isSession })",
     "LineParts(sessions: items.filter(\\.isSession), backlog: items)", "[compact backlog]"),
    ("session cap: every session drawn", M, "var shown: [Need] { Array(sessions.prefix(sessionCap)) }", "var shown: [Need] { sessions }", "[session cap]"),
    ("session cap: one session reads as many", M, 'count == 1 ? "+1 session" : "+\\(count) sessions"', '"+\\(count) sessions"', "[session cap]"),
    ("compact line: a session item may lose any share", M, "static let flowMinShare: CGFloat = 0.75", "static let flowMinShare: CGFloat = 0", "[compact line]"),
    ("compact line: the backlog shrinks too", M, "} else if index < shrinks.count, shrinks[index], room >= want * flowMinShare {",
     "} else if room >= want * flowMinShare {", "[compact line]"),
    ("compact line: an item that fits still wraps", M, "            if x == 0 || want <= room {", "            if x == 0 {", "[compact line]"),
    ("missing source: no meetings reads as zero voices", M, "guard !meetings.isEmpty else { return nil }", "", "[missing source]"),
    ("missing source: 0 work items is an item", M, "if let count = sources.workAttention, count > 0 {", "if let count = sources.workAttention {", "[missing source]"),
    ("quiet line: one answer is enough", M, "return !counted.isEmpty && counted.allSatisfy { $0 == .answered } ? .quiet : .hidden",
     "return counted.contains { $0 == .answered } ? .quiet : .hidden", "[quiet line]"),
    ("quiet line: Work not connected is waited for", M, "let counted = Source.allCases.map { states[$0] ?? .pending }.filter { $0 != .off }",
     "let counted = Source.allCases.map { states[$0] ?? .pending }", "[quiet line]"),
    ("source state: older rows hide a failed load", M, "        case .failed: return .failed\n", "        case .failed: return hasData ? .answered : .failed\n", "[source state]"),
    ("source state: rows in hand are not an answer", M, "        case .pending, nil: return hasData ? .answered : .pending\n", "        case .pending, nil: return .pending\n", "[source state]"),
    ("next: it never advances", M, "if let index = items.firstIndex(where: { $0.id == cursor.id }) { return items[(index + 1) % items.count] }",
     "if let index = items.firstIndex(where: { $0.id == cursor.id }) { return items[index] }", "[next]"),
    ("next: it stops at the end", M, "{ return items[(index + 1) % items.count] }", "{ return items[min(index + 1, items.count - 1)] }", "[next]"),
    ("next: a gone item starts over", M, "return cursor.index < items.count ? items[cursor.index] : items.first", "return items.first", "[next]"),
    ("next: one item still reads Next", M, 'items.count == 1 ? "Open" : "Next"', '"Next"', "[next]"),
    # Cards.
    ("lead never repeats footer: Work's lead is its footer", M, 'body.lead = [Span(text: "\\(n(fresh)) new to sort", waits: true)]',
     'body.lead = [Span(text: body.footer ?? "", waits: true)]', "[lead never repeats footer]"),
    ("memories card: nothing to review goes unsaid", M, '                    body.lead = [Span(text: "Nothing to review")]\n', "", "[memories card]"),
    ("no fake zero: 0 voices to name", M, "if let voices = input.voices, voices.voices > 0 {", "if let voices = input.voices {", "[no fake zero]"),
    ("no fake zero: an unloaded status reads Setup needed", M, "} else if input.memories == nil, input.memorySetupNeeded {", "} else if input.memories == nil {", "[no fake zero]"),
    ("no fake zero: a dash for an unloaded number", M, "        var count: String?\n", '        var count: String? = "—"\n', "no dash for a missing number"),
    # Wiring (pins).
    ("⌘] routing: Next loses ⌘]", W, '                .keyboardShortcut("]", modifiers: .command)\n                .help("Open the first thing waiting on you (⌘]). Press again for the next.")',
     '                .help("Open the first thing waiting on you (⌘]). Press again for the next.")', "[⌘] routing]"),
    ("⌘] routing: a second ⌘] in the window", W, '.keyboardShortcut("h", modifiers: [.command, .shift])', '.keyboardShortcut("]", modifiers: .command)', "[⌘] routing]"),
    ("⌘] routing: the line mounted beside every route", W, "            lensRail\n            Divider()", "            lensRail\n            needsYouLine([], states: [:], now: Date())\n            Divider()", "[⌘] routing]"),
    ("⌘] routing: the review shares the home's route", W, "} else if section == .speakers, selectedSpeakerSessionID != nil {\n                    if model.reviewRouteActive {",
     "} else if section == .speakers || section == nil, selectedSpeakerSessionID != nil {\n                    if model.reviewRouteActive {", "[⌘] routing]"),
    ("⌘] routing: Next to name without a next", V, "                if onNextUnnamed != nil {", "                if true {", "[⌘] routing]"),
    ("next: Next ignores what it opened", W, "ActivityHome.nextTarget(needs, after: homeNextCursor)", "ActivityHome.nextTarget(needs, after: nil)", "[next]"),
    ("next: opening an item does not move Next", W, "        homeNextCursor = ActivityHome.NextCursor(id: need.id, index: needs.firstIndex { $0.id == need.id } ?? 0)\n", "", "[next]"),
    ("next: the old help text", W, '.help("Open the first thing waiting on you (⌘]). Press again for the next.")', '.help("Open the oldest thing waiting on you (⌘])")', "[next]"),
    ("may need you: the dot always filled", W, "                    if need.isFact {\n                        Circle().fill(COSPalette.amber)",
     "                    if true {\n                        Circle().fill(COSPalette.amber)", "[may need you]"),
    ("may need you: the dot drawn from the kind", W, "                    if need.isFact {\n", "                    if need.kind != .maybe {\n", "[may need you]"),
    ("session cap: the view draws every session", W, "                    ForEach(parts.shown) { need in\n", "                    ForEach(parts.sessions) { need in\n", "[session cap]"),
    ("session cap: +N sessions opens nothing", W, "                        Button { select(.sessions) } label: {\n                            Text(ActivityHome.moreSessionsLabel",
     "                        Button { } label: {\n                            Text(ActivityHome.moreSessionsLabel", "[session cap]"),
    ("compact backlog: the view shows the meeting name", W, "Text(piece.text).foregroundStyle(.primary)", 'Text(need.what + " " + need.why).foregroundStyle(.primary)', "[compact backlog]"),
    ("compact line: session items cannot shrink", W, "                            .layoutValue(key: NeedsFlowShrinks.self, value: true)\n", "", "[compact line]"),
    ("compact line: the backlog may shrink", W, "                        backlogSegment(parts, in: needs)\n", "                        backlogSegment(parts, in: needs).layoutValue(key: NeedsFlowShrinks.self, value: true)\n", "[compact line]"),
    ("compact line: placed at the ideal width", W, "subview.place(at: CGPoint(x: bounds.minX + place.x, y: y), proposal: ProposedViewSize(width: place.width, height: nil))",
     "subview.place(at: CGPoint(x: bounds.minX + place.x, y: y), proposal: .unspecified)", "[compact line]"),
    ("reduce motion: the glow starts unguarded", W, "guard desk.state.glows(reduceMotion: reduceMotion) else {", "guard true else {", "[reduce motion]"),
    ("reduce motion: desks ignore the setting", W, "ActivityDeskMark(desk: desk, now: now, reduceMotion: reduceMotion)", "ActivityDeskMark(desk: desk, now: now, reduceMotion: false)", "[reduce motion]"),
    ("desk strip: the view shows every desk", W, "ForEach(desks.prefix(fit.shown))", "ForEach(desks)", "[desk strip]"),
    ("desk strip: the row goes when no desk", W, "                if let desks {\n                    deskStrip(desks, now: now)", "                if let desks, !desks.isEmpty {\n                    deskStrip(desks, now: now)", "[desk strip]"),
    ("open routes: a desk opens the live short id", W, "selectedSessionID = desk.openRow.id", "selectedSessionID = desk.session.id", "[open routes]"),
    ("open routes: Work opens on everything", W, "workWorkspaceState.scope = .attention", "workWorkspaceState.scope = .all", "[open routes]"),
    ("open routes: memories open All memories", W, '            memoriesSubview = .toReview\n            memoriesOpenView = "review"\n', "", "[open routes]"),
    ("open routes: the page is not told its view", W,
     "            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))\n", "", "[open routes]"),
    ("open routes: a tab keeps the view an item asked for", W, "        memoriesOpenView = nil\n", "", "[open routes]"),
    ("one source: the pet's live list ignored", W, "model.petEnabled ? model.petSessions : nil", "nil", "[one source]"),
    ("pet off: the home refreshes with the pet on too", W, "section == nil, !model.petEnabled else { continue }", "section == nil else { continue }", "[pet off]"),
    ("quiet line: Work left out of the claim", W,
     "            .work: ActivityHome.sourceState(enabled: workConnectionsEnabled && !isolatedWorkPreview, loaded: homeLoads[.work], hasData: homeWorkItems != nil),\n", "", "[quiet line]"),
    ("loads: Work loads last again", W, "        async let work: Void = loadHomeWork()\n", "", "[loads]"),
    ("loads: the Work load records nothing", W, "        homeLoads[.work] = model.workTasksError == nil ? .answered : .failed", "        _ = model.workTasksError", "[loads]"),
    ("loads: Intake not loaded", W, "            await model.loadWorkIntake()\n", "", "[loads]"),
    ("loads: the review list not loaded", W, "        if (model.status.learningToReview ?? 0) > 0, model.toReviewEvents.isEmpty { await model.loadToReviewEvents() }\n", "", "[loads]"),
    ("desk click: the card stops opening its tab", W, ".onTapGesture { select(item) }", ".onTapGesture { }", "[desk click]"),
    ("captions: the description is lost", W, "                            .help(item.summary)\n", "", "[captions]"),
    ("card copy: every sub line drawn", W, "ForEach(Array(body.subs.prefix(2).enumerated()), id: \\.offset)", "ForEach(Array(body.subs.enumerated()), id: \\.offset)", "[card copy]"),
    ("no fake zero: the view draws a dash", W, 'let metric = Text(body.count ?? "")', 'let metric = Text(body.count ?? "—")', "[no fake zero]"),
]


def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    # 0.5.267: every compile in the lane runs through Tests/compile-guard.sh; a guard stop ends the lane (it is not a kill).
    if "compile-guard: STOPPED" in proc.stdout + proc.stderr:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + (proc.stderr or "")[-400:])
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
