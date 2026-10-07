#!/usr/bin/env python3
"""0.5.259 Activity home: the wiring the behaviour checks cannot see.

Tests/run-activity-home.sh EXECUTES the rules (which sessions get a desk and which only "may need you", the Needs you items
and their order, the quiet line, where Next goes, the desk fit, the card copy). The views are compiled and never run, so
what is pinned here is that they are wired to those rules: ⌘] has one owner on each route and the home's never meets
Speakers' Next to name; Next advances from the item it opened last; the dot is drawn from the fact flag; each item opens
its own section (memories on To review); the line, the cards and the desks read one set of seats; the quiet line waits for
every source; Work loads beside the sessions; the desk strip is one row; a working desk's glow starts only when
ActivityHome says it glows; the captions are gone and the descriptions are help text; the card list matches
ActivitySection. Each pin names what it protects in brackets.

    python3 Tests/activity-home-pins.py [root]
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
def code(rel): return (root / rel).read_text(encoding="utf-8")
def strip(text): return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))
def fail(msg): sys.exit("0.5.259 pin: " + msg)
def need(cond, msg):
    if not cond: fail(msg)
def in_order(src, *parts):
    """True when every part is present and each starts after the one before."""
    at = -1
    for part in parts:
        found = src.find(part, at + 1)
        if found == -1: return False
        at = found
    return True
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
#    so the two are never in the window at once. Next advances from the item it opened last.
need(win.count('.keyboardShortcut("]"') == 1, "[⌘] routing] Activity has exactly one ⌘], the home's Next")
need(views.count('.keyboardShortcut("]"') == 1, "[⌘] routing] Speakers' Next to name is the only other ⌘]")
line = body(win, "private func needsYouLine(", "\n    private var needsRule")
need('.keyboardShortcut("]", modifiers: .command)' in line, "[⌘] routing] the home's ⌘] is on the Next button")
need("if let next = ActivityHome.nextTarget(needs, after: homeNextCursor) { openNeed(next, in: needs) }" in line,
     "[next] Next opens ActivityHome.nextTarget after the item it opened last")
need('.help("Open the first thing waiting on you (⌘]). Press again for the next.")' in line,
     "[next] the help says Next opens the first thing waiting, then the next")
need(len(re.findall(r"\bneedsYouLine\(", win)) == 2, "[⌘] routing] the Needs you line is drawn by the home alone")
# The line: up to three session items in full, "+N sessions", then the backlog as one segment, in the order Next uses.
need("let parts = ActivityHome.parts(needs)" in line and "ForEach(parts.shown) { need in" in line and "backlogSegment(parts, in: needs)" in line
     and "ForEach(needs)" not in line and "ForEach(parts.sessions)" not in line
     and in_order(line, "ForEach(parts.shown)", "ActivityHome.moreSessionsLabel(parts.moreSessions)", "backlogSegment(parts, in: needs)"),
     "[session cap] three session items at most, then +N sessions, then the backlog segment")
more = body(line, "if parts.moreSessions > 0 {", "backlogSegment(parts, in: needs)")
need("Button { select(.sessions) }" in more, "[session cap] +N sessions opens Sessions")
need("NeedsFlowLayout(spacing: 18, lineSpacing: 7) {" in line and line.count("NeedsFlowShrinks") == 1
     and re.search(r"needRow\(need, in: needs, single: parts\.sessions\.count == 1, now: now\)\n\s*\.layoutValue\(key: NeedsFlowShrinks\.self, value: true\)", line),
     "[compact line] session items may shrink in the line; the backlog segment never does")
flow_layout = body(win, "private struct NeedsFlowLayout: Layout {", "\n}\n")
need("ActivityHome.flow(ideal:" in flow_layout and "shrinks: subviews.map { $0[NeedsFlowShrinks.self] }" in flow_layout
     and "proposal: ProposedViewSize(width: place.width, height: nil)" in flow_layout,
     "[compact line] the line is placed by ActivityHome.flow, at the widths it gives")
segment = body(win, "private func backlogSegment(", "private func openNeed(")
need("ForEach(ActivityHome.backlogPieces(parts)) { piece in" in segment and segment.count("Text(piece.text)") == 3,
     "[compact backlog] the segment draws ActivityHome.backlogPieces, piece by piece")
need("Text(need.why" not in segment and "Text(need.what" not in segment and "needRow(" not in segment and 'Text("Also")' not in segment,
     "[compact backlog] no meeting name or description in the segment (help text only)")
home = body(win, "private var activityHome: some View {", "private func needsYouLine(")
need("needsYouLine(needs, states: homeSourceStates(desks: desks), now: now)" in home, "[⌘] routing] the home draws the Needs you line")
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

# 2. The dot is the fact flag: filled only when need.isFact, open otherwise ("may need you" is never drawn as fact).
row = body(win, "private func needRow(", "private func backlogSegment(")
need(re.search(r"if need\.isFact \{\n\s*Circle\(\)\.fill\(COSPalette\.amber\)\n\s*\} else \{\n\s*Circle\(\)\.strokeBorder\(COSPalette\.amber", row)
     and "kind == .maybe" not in row and "isSession {" not in row,
     "[may need you] the dot is filled only from need.isFact")

# 3. Every item opens in its own section, and becomes where Next carries on from.
opener = body(win, "private func openNeed(", "\n    private func openDesk(")
need(in_order(opener, "homeNextCursor = ActivityHome.NextCursor(id: need.id", "switch need.kind"),
     "[next] opening an item moves Next past it")
need("case .asked, .maybe:" in opener and "openDesk(desk)" in opener, "[open routes] a session item opens its session")
need("select(.speakers)" in opener and "model.openSpeakerReview(meeting)" in opener and "selectedSpeakerSessionID = meeting.sessionId" in opener,
     "[open routes] voices to name opens that meeting's review in Speakers")
memories = body(opener, "case .memories:", "case .work:")
need("select(.memories)" in memories and "memoriesSubview = .toReview" in memories and 'memoriesOpenView = "review"' in memories
     and in_order(memories, "select(.memories)", 'memoriesOpenView = "review"'),
     "[open routes] memories open on To review")
need("MemoriesWebView(model: model, initialView: memoriesOpenView," in win, "[open routes] the Memories page is told its view")
web = body(win, "struct MemoriesWebView: NSViewRepresentable {", "func updateNSView(")
need("window.cosBridge && window.cosBridge.show(" in web and "WKUserScript(source: script, injectionTime: .atDocumentEnd" in web
     and '["recent", "applied", "memories", "review", "knowledge"].contains(view)' in web,
     "[open routes] the page opens on that view through its own cosBridge.show, named views only")
select = body(win, "private func select(_ requested: ActivitySection) {", "\n    }\n")
need("memoriesOpenView = nil" in select, "[open routes] choosing a tab clears the view an item asked for")
need("select(.work)" in opener and "workWorkspaceState.scope = .attention" in opener and "workWorkspaceState.focusOverride = true" in opener,
     "[open routes] Work opens on what needs attention")
desk_open = body(win, "private func openDesk(", "\n    }\n")
need("select(.sessions)" in desk_open and "selectedSessionID = desk.openRow.id" in desk_open and "model.openClaudeSession(desk.openRow)" in desk_open,
     "[open routes] a desk opens its session the way a Sessions row does")
session_row = body(win, "private func sessionRow(", "} label: {")
need("selectedSessionID = session.id" in session_row and "model.openClaudeSession(session)" in session_row, "[open routes] the Sessions row still opens this way")

# 4. One set of seats for the line, the cards and the desks, from the pet's live list when the pet is on; with the pet
#    off, the home reads the sessions list again once a minute while it shows.
need("let seats = homeSeats(now: now)" in home and "let desks = seats.map(ActivityHome.desks)" in home, "[one source] one set of seats per tick")
need("homeNeedSources(desks: desks)" in home and "homeGrid(homeInputs(now: now, seats: seats), desks: desks, now: now)" in home,
     "[one source] the line, the cards and the desks read those seats")
need("TimelineView(.periodic(from: .now, by: 60))" in home and "let now = timeline.date" in home, "[one source] one clock for the line, cards and desks")
need(".task { await refreshHomeSessions() }" in home, "[pet off] the home refreshes its sessions while it shows")
refresh = body(win, "private func refreshHomeSessions() async {", "\n    }\n")
need("try? await Task.sleep(for: .seconds(60))" in refresh and "section == nil, !model.petEnabled else { continue }" in refresh
     and "await model.loadClaudeSessions()" in refresh, "[pet off] once a minute, only with the pet off and the home showing")
seats_fn = body(win, "private func homeSeats(", "\n    }\n")
need("model.petEnabled ? model.petSessions : nil" in seats_fn and "ActivityHome.seats(list: model.claudeSessions, live: live, now: now)" in seats_fn,
     "[one source] the pet's live list decides what runs and waits, as on the pet")
inputs = body(win, "private func homeInputs(", "private func sectionList(")
need("status.memoryCount" in inputs and "status.threadCount" in inputs and "prefix(while:" not in inputs,
     "[one source] the counts read structured fields, never a sentence")

# 5. The quiet line waits for every source: each source's state comes from its load on opening or rows in hand.
need("switch ActivityHome.line(needs, states: states) {" in line, "[quiet line] the line asks ActivityHome with every source's state")
states = body(win, "private func homeSourceStates(", "\n    }\n")
for source in ("sessions", "voices", "memories", "work"):
    need(f".{source}: ActivityHome.sourceState(enabled:" in states and f"loaded: homeLoads[.{source}]" in states, f"[quiet line] {source} is a source")
need("enabled: workConnectionsEnabled && !isolatedWorkPreview" in states, "[quiet line] Work is waited for only when connected")
overview = body(win, "private func loadOverviewIfNeeded() async {", "private func loadHomeWork() async {")
need(in_order(overview, "async let sessions: Void = model.loadClaudeSessions()", "async let work: Void = loadHomeWork()", "if model.recentMessages.isEmpty")
     and "await work" in overview, "[loads] Work loads beside the sessions, not last")
for source in ("memories", "voices", "sessions"):
    need(f"homeLoads[.{source}] =" in overview, f"[quiet line] the {source} load records how it came back")
work_load = body(win, "private func loadHomeWork() async {", "\n    private func load(_ item: ActivitySection) async {")
need("await model.loadWorkTasks()" in work_load and "await reviewStore.refresh()" in work_load and "await model.loadWorkIntake()" in work_load
     and "homeLoads[.work] = model.workTasksError == nil ? .answered : .failed" in work_load and "homeLoads[.work] = .off" in work_load,
     "[loads] the home loads Work's board, reviews and Intake, and records how it came back")
need("await model.loadToReviewEvents()" in overview, "[loads] the home loads the review list for the oldest wait")

# 6. Desks: one row sized to the card; a working desk's glow starts only when ActivityHome says it glows; no sound.
strip_view = body(win, "private func deskStrip(", "private func formatted(")
need("GeometryReader { geometry in" in strip_view and "ActivityHome.deskFit(count: desks.count, width: geometry.size.width)" in strip_view
     and "ForEach(desks.prefix(fit.shown))" in strip_view and ".frame(height: ActivityHome.deskHeight)" in strip_view
     and "ChipFlowLayout" not in strip_view, "[desk strip] one row sized to the card, the rest in +N")
mark = body(win, "private struct ActivityDeskMark: View {", "\n}\n")
need(".frame(width: ActivityHome.deskWidth, height: ActivityHome.deskHeight)" in mark, "[desk strip] a desk is the size deskFit counts")
need(mark.count("repeatForever") == 1, "[reduce motion] one glow animation")
guard_at = mark.find("guard desk.state.glows(reduceMotion: reduceMotion) else {")
need(guard_at != -1 and guard_at < mark.index("repeatForever"), "[reduce motion] the glow starts only behind ActivityHome's Reduce Motion rule")
need("@Environment(\\.accessibilityReduceMotion)" in win and "reduceMotion: reduceMotion" in strip_view,
     "[reduce motion] the desks read the window's Reduce Motion")
need(not re.search(r"NSSound|NSBeep|AudioServices|playCompletion|beginPetCompletion", mark + line), "[no sound] the home plays nothing")

# 7. Cards: a tap opens the section; desks are Buttons inside (a Button card would swallow them); captions are gone; the
#    descriptions are the cards' help text; at most two sub lines; no number until it loads; the strip keeps its row.
grid = body(win, "private func homeGrid(", "private func activityHomeCard(")
need(".onTapGesture { select(item) }" in grid and "Button { select(item) }" not in grid, "[desk click] the card is a tap, so its desks take their own clicks")
need(".help(item.summary)" in grid, "[captions] the description is the card's help text")
card = body(win, "private func activityHomeCard(", "private func leadLine(")
need(".uppercased()" not in card and "tracking(" not in card, "[captions] no mono caps caption on a card")
need("Text(item.summary)" not in card, "[captions] the description is no longer drawn on the card")
need("body.subs.prefix(2)" in card, "[card copy] at most two sub lines")
need('let metric = Text(body.count ?? "")' in card, "[no fake zero] no number, and no placeholder, until it loads")
need(re.search(r"if let desks \{\n\s*deskStrip\(desks, now: now\)", card), "[desk strip] the Sessions card keeps its strip row, desks or not")
for caption in ("RECENT", "ENROLLED", "TO REVIEW", "TRACKED", "ON DISK", "REFRESH", "YOUR MOVE", "SETUP NEEDED", "BY DAY", "STORED", "OPEN"):
    need(f'"{caption}"' not in inputs and f'"{caption}"' not in home_logic, f"[captions] {caption} is gone from the home")
need("—" not in home_logic, "[copy] no em dash in the home's words, and no dash for a missing number")
flow = body(views, "struct ChipFlowLayout: Layout {", "\n}\n")
need("lineSpacing" not in flow, "[cleanup] ChipFlowLayout carries no uncalled lineSpacing")

# 8. The card list matches ActivitySection, so every tab has its card rules.
cards = re.search(r"enum Card: String, CaseIterable \{ case ([a-z, ]+) \}", home_logic)
sections = body(win, "enum ActivitySection: String, CaseIterable, Identifiable {", "\n\n")
need(cards and set(cards.group(1).replace(" ", "").split(",")) == set(re.findall(r"case (\w+)", sections)),
     "[card list] ActivityHome.Card and ActivitySection list the same cards")
need("ActivityHome.Card(rawValue: item.rawValue)" in win, "[card list] a card finds its rules by the section's raw value")

print("COS Control: Activity home wiring pinned (0.5.259): one ⌘] per route and Next advancing, the dot from the fact flag, three sessions then one backlog segment, items open their sections, one set of seats, the quiet line waits for every source, the one-row strip, Reduce Motion, cards and loads")
