#!/usr/bin/env python3
"""0.5.259 Activity home: the wiring the behaviour checks cannot see.

Tests/run-activity-home.sh EXECUTES the rules (which sessions get a desk, the Needs you items and their order, the quiet
line, what Next opens, the card copy). The views are compiled and never run, so what is pinned here is that they are wired
to those rules: ⌘] has one owner on each route and the home's never meets Speakers' Next to name; Next and each item open
their own section; the line, the cards and the desks read one set of seats; a working desk's glow starts only when
ActivityHome says it glows; a desk opens its session the way Sessions does; the captions are gone and the descriptions are
help text; the card list matches ActivitySection. Each pin names what it protects in brackets.

    python3 Tests/activity-home-pins.py [root]
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
def code(rel): return (root / rel).read_text(encoding="utf-8")
def strip(text): return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))
def fail(msg): sys.exit("0.5.259 pin: " + msg)
def need(cond, msg):
    if not cond: fail(msg)
def body(src, start, end):
    if start not in src: fail(f"missing {start!r}")
    i = src.index(start)
    if end not in src[i:]: fail(f"missing {end!r} after {start!r}")
    return src[i:src.index(end, i)]

win = strip(code("Sources/ActivityWindow.swift"))
views = strip(code("Sources/Views.swift"))
models = strip(code("Sources/Models.swift"))
home_logic = models[models.index("enum ActivityHome {"):]   # the last type in Models.swift

# 1. ⌘] routing: one owner per route. The home's Next is the only ⌘] in Activity; Speakers' Next to name is the only one in
#    the review pane; the home is the content chain's final else, and the review sits on its own route of the same chain,
#    so the two are never in the window at once.
need(win.count('.keyboardShortcut("]"') == 1, "[⌘] routing] Activity has exactly one ⌘], the home's Next")
need(views.count('.keyboardShortcut("]"') == 1, "[⌘] routing] Speakers' Next to name is the only other ⌘]")
line = body(win, "private func needsYouLine(", "\n    private var needsRule")
need('.keyboardShortcut("]", modifiers: .command)' in line, "[⌘] routing] the home's ⌘] is on the Next button")
need("if let next = ActivityHome.nextTarget(needs) { openNeed(next) }" in line, "[⌘] routing] Next opens ActivityHome.nextTarget, the oldest item")
need(len(re.findall(r"\bneedsYouLine\(", win)) == 2, "[⌘] routing] the Needs you line is drawn by the home alone")
home = body(win, "private var activityHome: some View {", "private func needsYouLine(")
need("needsYouLine(" in home, "[⌘] routing] the home draws the Needs you line")
frame = body(win, "private var activityFrame: some View {", "\n    var body: some View {")
need(len(re.findall(r"\bactivityHome\b", frame)) == 1 and re.search(r"\} else \{\n\s*activityHome\n", frame),
     "[⌘] routing] the home is the content chain's final else, and nowhere else in the window")
need(len(re.findall(r"\bactivityHome\b", win)) == 2, "[⌘] routing] the home is mounted once")
need(re.search(r"\} else if section == \.speakers, selectedSpeakerSessionID != nil \{\n\s*if model\.reviewRouteActive \{\n\s*SpeakerReviewPane\(", frame),
     "[⌘] routing] the speaker review mounts on its own route of the same chain")
need(win.count("SpeakerReviewPane(") == 1, "[⌘] routing] one speaker review in Activity")
pane = body(views, "struct SpeakerReviewPane", "\nstruct ")
need(re.search(r"if onNextUnnamed != nil \{\n\s*Button \{\n\s*onNextUnnamed\?\(\)", pane) and '.keyboardShortcut("]", modifiers: .command)' in pane,
     "[⌘] routing] Speakers' ⌘] is Next to name, and only when the pane is given one")

# 2. Every item opens in its own section, and a desk opens its session the way Sessions does.
opener = body(win, "private func openNeed(", "\n    private func openDesk(")
need("case .asked, .maybe:" in opener and "openDesk(desk)" in opener, "[open routes] a session item opens its session")
need("select(.speakers)" in opener and "model.openSpeakerReview(meeting)" in opener and "selectedSpeakerSessionID = meeting.sessionId" in opener,
     "[open routes] voices to name opens that meeting's review in Speakers")
need("case .memories: select(.memories)" in opener, "[open routes] memories open Memories")
need("select(.work)" in opener and "workWorkspaceState.scope = .attention" in opener and "workWorkspaceState.focusOverride = true" in opener,
     "[open routes] Work opens on what needs attention")
desk_open = body(win, "private func openDesk(", "\n    }\n")
need("select(.sessions)" in desk_open and "selectedSessionID = desk.openRow.id" in desk_open and "model.openClaudeSession(desk.openRow)" in desk_open,
     "[open routes] a desk opens its session the way a Sessions row does")
row = body(win, "private func sessionRow(", "} label: {")
need("selectedSessionID = session.id" in row and "model.openClaudeSession(session)" in row, "[open routes] the Sessions row still opens this way")

# 3. One set of seats for the line, the cards and the desks, from the pet's live list when the pet is on.
need("let seats = homeSeats(now: now)" in home and "let desks = seats.map(ActivityHome.desks)" in home, "[one source] one set of seats per tick")
need("homeNeedSources(desks: desks)" in home and "homeInputs(now: now, seats: seats)" in home and "desks: desks ?? []" in home,
     "[one source] the line, the cards and the desks read those seats")
need("TimelineView(.periodic(from: .now, by: 60))" in home and "let now = timeline.date" in home, "[one source] one clock for the line, cards and desks")
seats_fn = body(win, "private func homeSeats(", "\n    }\n")
need("model.petEnabled ? model.petSessions : nil" in seats_fn and "ActivityHome.seats(list: model.claudeSessions, live: live, now: now)" in seats_fn,
     "[one source] the pet's live list decides what runs and waits, as on the pet")
inputs = body(win, "private func homeInputs(", "private func sectionList(")
need("status.memoryCount" in inputs and "status.threadCount" in inputs and "prefix(while:" not in inputs,
     "[one source] the counts read structured fields, never a sentence")

# 4. Reduce Motion: a working desk's glow starts only when ActivityHome says it glows.
mark = body(win, "private struct ActivityDeskMark: View {", "\n}\n")
need(mark.count("repeatForever") == 1, "[reduce motion] one glow animation")
guard_at = mark.find("guard desk.state.glows(reduceMotion: reduceMotion) else {")
need(guard_at != -1 and guard_at < mark.index("repeatForever"), "[reduce motion] the glow starts only behind ActivityHome's Reduce Motion rule")
need("@Environment(\\.accessibilityReduceMotion)" in win and "reduceMotion: reduceMotion" in body(win, "private func deskStrip(", "\n    }\n"),
     "[reduce motion] the desks read the window's Reduce Motion")
need(not re.search(r"NSSound|NSBeep|AudioServices|playCompletion|beginPetCompletion", mark + line), "[no sound] the home plays nothing")

# 5. Cards: a tap opens the section; desks are Buttons inside (a Button card would swallow them); captions are gone; the
#    descriptions are the cards' help text; at most two sub lines.
grid = body(win, "private func homeGrid(", "private func activityHomeCard(")
need(".onTapGesture { select(item) }" in grid and "Button { select(item) }" not in grid, "[desk click] the card is a tap, so its desks take their own clicks")
need(".help(item.summary)" in grid, "[captions] the description is the card's help text")
card = body(win, "private func activityHomeCard(", "private func formatted(")
need(".uppercased()" not in card and "tracking(" not in card, "[captions] no mono caps caption on a card")
need("Text(item.summary)" not in card, "[captions] the description is no longer drawn on the card")
need("body.subs.prefix(2)" in card, "[card copy] at most two sub lines")
need("deskStrip(desks, now: now)" in card, "[desk click] the Sessions card draws its desks")
for caption in ("RECENT", "ENROLLED", "TO REVIEW", "TRACKED", "ON DISK", "REFRESH", "YOUR MOVE", "SETUP NEEDED", "BY DAY", "STORED", "OPEN"):
    need(f'"{caption}"' not in inputs and f'"{caption}"' not in home_logic, f"[captions] {caption} is gone from the home")
need("—" not in home_logic.replace('var count = "—"', ""), "[copy] no em dash in the home's words (the empty count keeps its dash)")

# 6. The card list matches ActivitySection, so every tab has its card rules.
cards = re.search(r"enum Card: String, CaseIterable \{ case ([a-z, ]+) \}", home_logic)
sections = body(win, "enum ActivitySection: String, CaseIterable, Identifiable {", "\n\n")
need(cards and set(cards.group(1).replace(" ", "").split(",")) == set(re.findall(r"case (\w+)", sections)),
     "[card list] ActivityHome.Card and ActivitySection list the same cards")
need("ActivityHome.Card(rawValue: item.rawValue)" in win, "[card list] a card finds its rules by the section's raw value")

# 7. The home loads what it reads, with the loaders the tabs already use.
overview = body(win, "private func loadOverviewIfNeeded() async {", "\n    private func load(_ item: ActivitySection) async {")
need("await model.loadWorkTasks()" in overview and "await reviewStore.refresh()" in overview and "await model.loadWorkIntake()" in overview,
     "[loads] the home loads Work's board, reviews and Intake")
need("await model.loadToReviewEvents()" in overview, "[loads] the home loads the review list for the oldest wait")

print("COS Control: Activity home wiring pinned (0.5.259): one ⌘] per route, items open their sections, one set of seats, Reduce Motion, cards and loads")
