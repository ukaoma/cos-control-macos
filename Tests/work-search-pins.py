#!/usr/bin/env python3
"""0.5.259 Work search and order: the wiring the behaviour checks cannot see.

Tests/run-work-search.sh EXECUTES the rules (words, matches, thresholds, the late answer, Best matches, counts, other
domains, degrade lines, keys, Order and its memory, dates, the journal through the app's stage writes) and
Tests/work-search-helper-checks.py runs the compiled helper. The views are compiled and never run, so what is pinned here
is that they are wired to those rules: the board narrows its columns with the search and orders them with Order; Jev is
asked only from the board's task, never while typing; ⌘F, the arrows, Return and Escape reach the search; Order is a plain
menu remembered per board; the journal is written where the app changes a stage; the helper routes work-search and passes
the row fields. Each pin names what it protects.

    python3 Tests/work-search-pins.py [root]
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
def code(rel): return (root / rel).read_text(encoding="utf-8")
def strip(text): return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))
def fail(msg): sys.exit("0.5.259 pin: " + msg)
def need(cond, msg):
    if not cond: fail(msg)
def body(src, start, end):
    i = src.index(start); return src[i:src.index(end, i)]

board = code("Sources/WorkWorkspaceView.swift")
model = code("Sources/ControllerModel.swift")
window = code("Sources/ActivityWindow.swift")
helper = code("HelperSources/main.swift")
logic = body(board, "// MARK: - Work search and order (0.5.259", "/// Task page width, kept only at the two breaks")

# 1. The board narrows its columns with the search and orders them, from one pass per draw.
dash = body(board, "    private var dashboard: some View {", "    // MARK: Work search and order (0.5.259)")
need("let cards = boardCards" in dash and "let search = boardSearch()" in dash and "let order = boardOrder" in dash,
     "the board works out its cards, its search and its order once per draw")
need("WorkBoardPass(search: search, order: order, dates: order == .board ? [:] : cardDates(cards), now: Date())" in dash,
     "the dates are worked out only while ordering by date")
need("boardColumn(stage, pass: pass)" in dash and "visible.filter" not in dash, "every column draws from the pass; the board never reads the Focus list's query filter")
need("WorkSearch.countLabel(kept: shownCount, of: taskCount, active: search.active) + \" tasks" in dash, "the board line says n of m tasks while searching")
need("if search.active { searchResults(search) }" in dash, "the result line and Best matches show only while searching")
need("private var boardCards: [WorkWorkspaceItem] { board.visible(scope: state.scope, domain: state.domain, query: \"\") }" in board,
     "the board's cards are the view's, before the search")
col = body(board, "    private func boardColumn(", "    private func boardCard(")
need('_ = board.visible(scope: state.scope, domain: state.domain, query: "")' in col and "query: state.query" not in col,
     "a column reads the same cards as the board, never the Focus filter")
need("let kept = pass.search.active ? all.filter { pass.search.shown.contains($0.id) } : all" in col, "a column keeps only what the search shows")
need("let cards = WorkCardDating.sorted(kept, id: \\.id, order: pass.order, dates: pass.dates)" in col, "Order sorts every column")
need("WorkSearch.countLabel(kept: cards.count, of: all.count, active: pass.search.active)" in col, "a column header says n of m while searching")
need('pass.search.active ? "No matches here" : "No tasks here"' in col, "an empty column says No matches here while searching")
need("hit: pass.search.hits[item.id], dateLine: WorkCardDating.line(pass.dates[item.id], order: pass.order, now: pass.now, calendar: .current)" in col,
     "each card gets its match and its date line")
card = body(board, "    private func boardCard(", "    private func canChangeStage(")
need("matched: hit != nil" in card and ": matched ? COSPalette.gold.opacity(0.5) : COSPalette.line" in card, "a matched card gets the gold border, after asking, running and moved")
need("Text(WorkSearch.underlined(inlineTitle(item.title), words: hit?.words ?? []))" in card, "a matched card underlines the found words")
need("if let dateLine {" in card and "cardTapArea(item, handoff: handoff, running: running, hit: hit)" in card,
     "the date line shows only when there is one (ordering by date)")
need(card.index("ForEach(task.meetingRefs.prefix(2))") < card.index("if let dateLine {") < card.index("Divider().overlay(COSPalette.line)"),
     "the date line sits under the card's source, above its footer")
need("why" not in card.lower().replace("cardwhyline", "").replace("whyline", ""), "columns carry no per-card why line (the Best matches band says why)")

dates = body(board, "    private func cardDates(", "    /// ↓ ↑ Return and Escape from the search box")
need("WorkCardDating.lastSessions(handoffStore.receipts)" in dates and "model.workActivity.moves" in dates and "cardFiles.lastAdded(item.sourceID)" in dates
     and "WorkCardDating.dates(task: task, moved: moves[item.sourceID], session: sessions[item.sourceID], file: file, calendar: calendar)" in dates,
     "Recent activity reads the stage-move journal, the handoffs and the card files, each by the card's work id")
need("func lastAdded(_ workID: String) -> Double? { manifests[workID]?.files.map(\\.addedAt).max() }" in code("Sources/WorkCardFiles.swift"),
     "the last file added is the newest addedAt on the card")
need("@Published private(set) var manifests: [String: WorkContextManifest] = [:] { didSet { manifestsEpoch &+= 1 } }" in code("Sources/WorkCardFiles.swift")
     and "filesEpoch: cardFiles.manifestsEpoch" in board, "a file added or renamed reaches the search")

# 2. Jev is asked only from the board's task, after the pause, with the board's request; never while typing.
need(dash.count(".task(id: state.currentSearchKey) {") == 1 and
     "await state.searchMeaning(WorkSearch.request(key: state.currentSearchKey, query: state.query, items: boardCards), isolated: handoffStore.isolated)" in dash,
     "the board asks Jev from one task keyed by the search, so a new search cancels the wait")
need(board.count("searchMeaning(") == 2, "searchMeaning is defined once and called once (the board's task)")
field = body(board, "struct WorkBoardSearchField: View {", "/// Debounce threshold changes while always cancelling")
need("searchMeaning" not in field and "Task.sleep(for: Self.settle)" in field, "typing never waits on the network; the board follows after the settle")
need("guard request.wantsMeaning, let transport = isolated ? previewSearchTransport : searchTransport else { return }" in board,
     "the preview never asks the server")
need("guard !Task.isCancelled, request.key == currentSearchKey else { staleMeaningDrops += 1; return }" in board, "a late answer is dropped")
need("meaning: state.meaning(for: state.currentSearchKey)" in board, "the board reads only the current search's answer")

# 3. Keys: ⌘F focuses, the arrows and Return reach the band, Escape clears first.
need('.keyboardShortcut("f", modifiers: .command)' in dash and "state.searchFocusRequest &+= 1" in dash, "⌘F asks the search box for the focus")
need("focusRequest: state.searchFocusRequest" in dash and ".onChange(of: focusRequest) { _, _ in focused = true }" in field and ".focused($focused)" in field,
     "the search box takes the focus when ⌘F asks")
need(".onKeyPress(keys: [.downArrow, .upArrow, .return, .escape])" in field and
     "handle(press.key == .downArrow ? .down : press.key == .upArrow ? .up : press.key == .return ? .open : .clear)" in field,
     "↓ ↑ Return and Escape reach the search")
keys = body(board, "    private func boardSearchKey(", "    /// The result line, Best matches")
need("switch WorkSearch.key(key, query: state.query, highlighted: state.bandIndex, bandCount: search.band.count)" in keys,
     "the board applies WorkSearch.key's decision")
need("case .highlight(let index): state.bandIndex = index; return true" in keys and "if let item = board.item(id: search.band[index]) { select(item) }" in keys
     and 'case .clear: state.query = ""' in keys and "case .pass: return false" in keys, "each key's action is applied")
need("onKey: { boardSearchKey($0) }" in dash, "the search box's keys go to the board")
esc = body(window, "    private func handleActivityEscape() -> Bool {", "    private func goBack()")
need("if section == .work, workWorkspaceState.escapeClearsSearch() { return true }" in esc, "Escape on Work clears an active search")
need(esc.index("workWorkspaceState.startItemID != nil") < esc.index("escapeClearsSearch()") < esc.index("section == .sessions, showingLinkedSession"),
     "Escape closes Start work first and clears the search before it goes back")

# 4. The result line, Best matches and the degrade line.
res = body(board, "    private func searchResults(", "    /// One Best match:")
need("Text(search.headline)" in res and "if !search.hits.isEmpty { Text(search.kindsText)" in res, "the result line: N matches and the kinds, or No matches on this board")
need("WorkSearch.elsewhereText(" in res and "state.domain = nil; state.scope = .all" in res, "N more in <Domain> switches to All work")
need("bestMatchRow(item, hit: hit, highlighted: index == min(state.bandIndex, search.band.count - 1))" in res, "the walked row is the highlighted one")
need("if let note = search.note { Text(note)" in res, "one muted line when meaning search could not run")
row = body(board, "    private func bestMatchRow(", "    /// Order: the house dropdown")
need("WorkSearch.why(hit)" in row and ".onTapGesture { select(item) }" in row and "WorkSearch.underlined(" in row, "a Best match says why, underlines, and opens on a tap")
need('state.domain == nil && state.scope == .all ? "Search work" : "Search this board"' in dash, "the placeholder names the board")

# 5. Order: the house dropdown (no pills, no segmented control), remembered per board.
menu = body(board, "    private func orderMenu(", "\n    }\n")
need('COSDropdown("Order", selection:' in menu and "options: WorkBoardOrder.allCases.map { COSDropdownOption($0, $0.title) }" in menu,
     "Order is the house dropdown, as the app's other sort menus")
need("pickerStyle" not in menu and "COSViewSwitch" not in menu and "Toggle(" not in menu and "Menu {" not in menu, "Order is not a row of buttons")
need("state.setOrder(choice, domain: state.domain, scope: state.scope, isolated: handoffStore.isolated)" in menu, "a choice is kept for this board")
need("orderMenu(order)" in dash and ".help(order.help)" in menu, "the board shows Order with what each choice means")
need("private var boardOrder: WorkBoardOrder { state.order(domain: state.domain, scope: state.scope, isolated: handoffStore.isolated) }" in board,
     "the board reads its own board's order")
need("static let standard = WorkBoardOrderStore(read: { UserDefaults.standard.string(forKey: $0) }," in logic, "the app remembers Order in its preferences")

# 6. The journal: written where the app changes a stage, after the write is accepted, before the board is read again.
need("workActivity = WorkActivityJournal(url: WorkActivityJournal.defaultURL(background: startBackgroundWork))" in model, "the app keeps the journal")
stage = body(model, "    func setWorkStage(", "    func linkWorkMeeting(")
need("self?.workActivity.recordStageChange(task, to: stage)" in stage, "a board stage change (and the tracker's moves and Undo) is noted")
mutate = body(model, "    private func mutateWorkTask(", "    func loadTasks(")
need(mutate.index("guard response.ok else") < mutate.index("saved?()") < mutate.index("await loadWorkTasks(force: true)"),
     "a move is noted only once the write is accepted, before the board is read again")
change = body(model, "    func changeWorkCard(", "    @Published var workUndoBatch")
success = change[change.index('if await workLoop("batch"'):change.index("return true")]
need('if let stage = fields["workStage"] { workActivity.recordStageChange(current, to: stage) }' in success, "Intake and Waiting on stage changes are noted")
tracker = body(model, "        let tracker = WorkProgressTracker(store: store, board: .init(", "notify:")
need("try await self.setWorkStage(task, stage: stage)" in tracker, "the tracker moves cards through setWorkStage, so its moves are noted")
need('try? Self.encode(moves).write(to: url, options: .atomic)' in logic and "moves = Self.bounded(next, limit: Self.limit)" in logic,
     "the journal is written atomically and bounded")

# 7. The helper: work-search is routed and read-only; the row whitelist carries the date fields; fixture mode never spends Jev.
need('case "work-search": try emitWorkSearch()' in helper, "the helper routes work-search")
ws = body(helper, "    private func emitWorkSearch() throws {", "    static func workSearchBodyValid(")
need('request("/api/work/search", method: "POST"' in ws and "Self.workSearchBodyValid(body)" in ws and "Self.workSearchAnswer(answer)" in ws,
     "work-search checks the body before it goes and the answer after")
allowed = re.search(r'let allowed: Set<String> = \[([^\]]*)\]', helper).group(1)
need('"work-search"' not in allowed, "the disposable-task fixture never spends Jev")
proj = body(helper, "    static func workTaskProjection(", "    private func emitWorkYourMove()")
need("for (key, valid) in workTaskDateFields {" in proj and '("createdOn",' in proj and '("createdFrom",' in proj and '("lineChangedAt",' in proj,
     "the row whitelist passes createdOn, createdFrom and lineChangedAt")
need("WorkCardDating.created(task" not in helper, "dates are worked out in the app, not the helper")

# 8. Copy: no em dash and no eyebrow kicker in what this adds.
added = logic + dash + res + row + menu + field
for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', strip(added)):
    need("—" not in literal, f"an em dash in UI copy: {literal!r}")
need(".textCase(.uppercase)" not in added and "tracking(" not in added, "no mono-caps kicker over the search")

print("COS Control: Work search and order wiring pinned (0.5.259): columns narrowed and ordered from one pass, Jev from the board's task only, ⌘F / arrows / Return / Escape, the result line and band, Order as the house dropdown remembered per board, the journal at every stage write, work-search and the row whitelist, copy")
