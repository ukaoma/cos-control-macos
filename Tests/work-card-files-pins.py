#!/usr/bin/env python3
"""0.5.254 files on a Work card: the wiring the behaviour checks cannot see.

Tests/run-work-card-files.sh EXECUTES the rules (names, sniffing, refusals, the block, Cursor's cut, the delta, cleanup,
the lock, companions, drop routes, the countdown). The views are compiled and never run, so what is pinned here is that
they are wired to those rules: card drags carry only the private type; a card's drop destination takes files only and
sits on the card itself; a file dropped on a column or the session row is refused and never starts, sends or moves
anything; the block the Agent workspace shows is the one the send composes; the countdown asks the files; every compile
list builds the new file. Each pin names what it protects.

    python3 Tests/work-card-files-pins.py [root]
"""
import pathlib, plistlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
def code(rel): return (root / rel).read_text(encoding="utf-8")
def strip(text): return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))
def fail(msg): sys.exit("0.5.254 pin: " + msg)
def need(cond, msg):
    if not cond: fail(msg)
def body(src, start, end):
    i = src.index(start); return src[i:src.index(end, i)]

files = code("Sources/WorkCardFiles.swift")
store = code("Sources/WorkHandoffStore.swift")
view = code("Sources/WorkHandoffView.swift")
board = code("Sources/WorkWorkspaceView.swift")
files_code, board_code = strip(files), strip(board)

# 1. Private type: card drags carry com.gotcos.work-card only, declared in Info.plist.
need('UTType(exportedAs: "com.gotcos.work-card", conformingTo: .data)' in files, "the card type is exported as com.gotcos.work-card")
need("CodableRepresentation(contentType: .workCard)" in files and "ProxyRepresentation" not in files and "DataRepresentation(exportedContentType: .plainText" not in files,
     "a card drag carries the private type and nothing a text field or Finder takes")
card = body(board, "private func boardCard(", "private func canChangeStage(")
need(".draggable(WorkCardDrag(id: item.id))" in card, "board cards drag the private type")
need(re.search(r"\.draggable\(\s*item\.id\s*\)", board_code) is None and ".dropDestination(for: String.self)" not in board_code,
     "no String card drag or String drop is left on the board")
plist = plistlib.loads((root / "Resources/Info.plist").read_bytes())
types = {t.get("UTTypeIdentifier"): t for t in plist.get("UTExportedTypeDeclarations", [])}
need("com.gotcos.work-card" in types and types["com.gotcos.work-card"].get("UTTypeConformsTo") == ["public.data"],
     "Info.plist exports com.gotcos.work-card conforming to public.data only (never public.content, which cards take)")

# 2. A column card face forwards a work-card drag. The Files box still takes files only. The destination sits on the card.
decl = re.search(r"static let fileDropTypes: \[UTType\] = \[([^\]]*)\]", files)
need(decl is not None and ".workCard" not in decl.group(1) and ".text" not in decl.group(1) and ".plainText" not in decl.group(1),
     "a card's file types are files only")
need("static let boardDropTypes: [UTType] = [.workCard] + fileDropTypes" in files, "columns and the session row list the card type")
drop = body(files, "struct WorkCardFileDrop: ViewModifier {", "/// A card face or the Agent workspace's Files box")
need(".onDrop(of: filesOn ? WorkCardFiles.boardDropTypes : [.workCard], delegate: WorkCardFileDropDelegate(" in drop,
     "a column card face registers a work-card drag, and a file drag when the card takes files")
need("target: .card, forwardsColumnMove: forwards" in drop, "the card face forwards a work-card drag only when the column gave it a move")
need("forwardsColumnMove: true" not in files, "nothing forces a card face to forward; the Files box never sets the flag")
need(".onDrop(of: WorkCardFiles.fileDropTypes, delegate: WorkCardFileDropDelegate(target: .filesBox" in files,
     "the Files box still takes files only")
need(drop.index(".onDrop(") < drop.index(".overlay {") and ".allowsHitTesting(false)" in drop,
     "the drop destination is on the card; Add to card is drawn over it and takes no hits (a destination inside .overlay never receives drops)")
mod = ".modifier(WorkCardFileDrop(files: cardFiles, source: item.task.map(WorkSource.taskSnapshot), onColumnCard: acceptColumn, onColumnHover: markColumn, onTake: takeColumn, onFinish: finishColumn))"
mod_at = card.index(mod)
for overlay in re.finditer(r"\.overlay[^\n]*\{", card):
    close = card.find("}", overlay.end())
    need(not (overlay.start() < mod_at < close), "the card's file drop must not sit inside an .overlay closure")
route = body(files, "nonisolated static func dropRoute(", "// MARK: Cleanup")
need("if cardForwardsMove, target == .card, offersCard { return .moveCard }" in route, "a column card face moves a work-card drag")
need("case .card, .filesBox: return offersCard ? .ignore : (offersFiles ? .addFiles : .ignore)" in route, "without that flag, a card or the Files box never takes a card")
delegate = body(files, "@MainActor struct WorkCardFileDropDelegate: DropDelegate {", "/// A column or the session row")
need("guard ColumnDragTrack.claimsDrop(decision), onTake() else { return true }" in delegate and "case .moveCard:" in delegate and "forwardsColumnMove" in delegate,
     "the first destination takes a card move")
card_drop = delegate.split("func performDrop", 1)[1]
added = card_drop.split("case .addFiles:", 1)[1].split("case .moveCard:", 1)[0]
need("onTake()" not in added and "onFiles(" in added, "adding a file does not claim the column drag")

# 3. A file drop never starts, sends or moves anything.
for banned in ("openStart(", ".submit(", "sendWorkHandoff(", "forkToPlatform(", "setWorkStage(", "move(task"):
    need(banned not in files_code, f"the card-files code calls {banned}: a drop must never send, start or move")
board_delegate = body(files, "@MainActor struct WorkBoardDropDelegate: DropDelegate {", "/// The Context counter")
refuse = board_delegate[board_delegate.index("case .refuseFiles:\n            onRefusedFiles()"):]
refuse = refuse[:refuse.index("default:")]
need(refuse.strip() == "case .refuseFiles:\n            onRefusedFiles()\n            return false", "a file on a column or the session row is refused and returns false")
perform = board_delegate.split("func performDrop", 1)[1]
need("onTake()" not in perform.split("switch", 1)[0], "a column drop looks at the route before it claims, so a file refusal does not spend the claim")
need(board_code.count("onRefusedFiles: { cardFiles.flashBoard() }") == 2, "both board drops refuse files with the line, and do nothing else")
row = body(board, "private var sessionsRow: some View {", "private func sessionCard(")
need(".onDrop(of: WorkCardFiles.boardDropTypes, delegate: WorkBoardDropDelegate(target: .sessionRow" in row, "the session row takes the card type")
col = body(board, "private func boardColumn(", "private func boardCard(")
need("WorkBoardDropDelegate(target: .column, onCard: accept, onTargeted: mark, onRefusedFiles: { cardFiles.flashBoard() }, onTake: takeColumn, onFinish: finishColumn)" in col,
     "a column takes the card type through one delegate")
need(col.count(".onDrop(of: WorkCardFiles.boardDropTypes, delegate: columnDrop)") == 2, "the header and the list each take that drop")
need(col.index(".contentShape(Rectangle())") < col.index("ScrollView {") < col.rindex(".onDrop(of: WorkCardFiles.boardDropTypes, delegate: columnDrop)"),
     "the header drop is outside the list, and the list drop is on the scroll view")
need('Text(WorkCardFiles.startTileRefusal)' in board and "if startFileHover {" in body(board, "private func startWorkTarget(", "private func boardColumn("),
     "Start work says where files go while one is over it")

# 4. The block is composed once, and the Agent workspace shows what the send composes.
submit = body(store, "    func submit(source: WorkSource", "    // MARK: - Start it, then open it (0.5.249)")
need("let files = cardFiles.handoff(for: source.id, mode: mode, sessionID: mode == .newSession ? nil : session?.id," in submit, "the send composes the files with the store's one composer")
need("let sent = WorkCardFiles.compose(text: text, block: files.block, instruction: instruction)" in submit, "the block goes between the text and the instruction")
need(submit.index("cardFiles.reload(source.id)") < submit.index("let files = cardFiles.handoff("), "the send reads the card's manifest from disk first")
need("if !files.sending.isEmpty { row.context = files.refs }" in submit, "the receipt records what went")
need("if prefill, !Self.cursorPrefillFits(sent, tag: tag, instruction: instruction) { throw failure(Self.cursorFilesTooLong) }" in submit
     and submit.index("cursorPrefillFits(") < submit.index("let id = UUID().uuidString.lowercased()"), "a file list too long for Cursor is refused before anything is recorded")
need("WorkCardFiles.splitBlock(" in body(store, "    nonisolated static func cursorPrefill(", "    /// Cursor's prompt link"), "Cursor's cut keeps the block")
handoff = body(files, "    func handoff(for workID: String, mode: WorkHandoffMode", "    // MARK: Adding")
need("WorkCardFiles.handoff(files: files(for: workID)" in handoff, "the store's composer is the pure one the checks run")
section = body(files, "struct WorkCardFilesSection: View {", "/// The Start sheet's files row")
need("let plan = files.handoff(for: source.id, mode: mode, sessionID: target, receipts: store.receipts, resendAll: resendAll)" in section
     and "plan.block" in section, "What gets sent shows the block the send composes")
need("WorkCardFilesSection(files: store.cardFiles, store: store, source: source, mode: forkToPlatform ? .newSession : mode," in view,
     "the Files section sits in the composer, under Context to send")
need(view.index("WorkCardFilesSection(") > view.index('Text("Context to send")'), "Files to send comes after Context to send")
need("await sendWorkHandoff(store: store, source: sendingSource, plan: sendingPlan, resendAllFiles: resendAll)" in view, "Send all again reaches the send")
need(files.count("func compose(") == 1 and files.count("static func block(") == 1, "one composer")
need("Transcript: 0.5.255" in files and "transcript.txt" not in files_code, "the video transcript is shown as 0.5.255 and never faked")

# 5. The Start sheet asks the files: the countdown waits, and a call stops it.
sheet = body(view, "struct WorkStartSheet: View {", "struct WorkSessionsView: View {")
need("switch WorkCardFiles.countdown(fileCheck(plan), secondsLeft: secondsLeft) {" in sheet and "case .stop: phase = .confirm(plan, fromAdvice: fromAdvice); return" in sheet
     and "case .wait: continue" in sheet, "the countdown waits for copies and stops for a call")
need("let stops = callLines(start.plan).isEmpty == false" in sheet and "phase = auto != nil && !stops ? .starting(start.plan" in sheet, "files that need a call never start by themselves")
need('Text(calls.isEmpty ? plan.verb : "Send anyway")' in sheet and "WorkStartFilesRow(files: files, store: store, source: source, plan: plan)" in sheet,
     "the confirm says Send anyway, and both phases list the files")

# 6. Cleanup never runs in a preview; the root is one constant and never in iCloud.
cleanup = body(files, "    func cleanup(tasks: [TaskRow]", "    // MARK: Lines on the card")
need("guard let root, !isolated else { return }" in cleanup, "cleanup never runs in a preview")
need(files.count('"cos-data/work-context"') == 1 and "nonisolated static let storeFolder = \"cos-data/work-context\"" in files, "the store's folder is one constant")
need("if let receipts = handoffStore.receiptsOnDisk() {" in board
     and "await cardFiles.cleanup(tasks: model.workTasks, inventoryComplete: model.workTasksComplete, receipts: receipts)" in board
     and board.index("guard !handoffStore.isolated else { return }") < board.index("cardFiles.cleanup("), "the board cleans only when it is live, from the journal on disk")
need("store.cardFiles.start()" in code("Sources/ControllerModel.swift"), "interrupted copies resume with background work")
need("var context: [WorkContextRef]?" in store, "the receipt's optional context field")

# 6b. Fix pass 1 (QA round 1).
# B1: nothing is deleted, opened or written from a manifest name except through the guards.
for line in files_code.split("\n"):
    if "removeItem(at:" in line:
        arg = line.split("removeItem(at:", 1)[1].split(")", 1)[0].strip()
        need(arg in ("target", "staging", "staged", "movedTo", "folder"), "a delete takes a path that is not a guarded target, a generated staging name or a guarded folder: " + line.strip())
        need("appendingPathComponent" not in arg, "a delete joins a name itself: " + line.strip())
dc = body(files, "    nonisolated static func deleteCopies(", "    /// Cleanup over every card's folder")
need("guard !file.isLink, WorkCardFiles.validEntry(file) else { return }" in dc and "try? WorkCardFiles.guardTarget(root: root, folder: folder, name: name)" in dc,
     "deleteCopies goes through the grammar and guardTarget")
upd = body(files, "    nonisolated static func update<T>(", "    // MARK: Snapshots")
need("let folder = try preparedFolder(root: root, workID: workID)" in upd, "every manifest write goes through the guarded folder")
need("try guardFolder(root: root, folder: folder)" in body(files, "    nonisolated static func clean(root: URL", "    // MARK: Snapshots"), "cleanup guards the folder it deletes")
mc = body(files, "    nonisolated static func makeCompanion(", "        switch companion.kind {")
need(mc.count("try? guardTarget(root: root, folder: folder, name:") >= 3 and "validCompanion(companion, of: file)" in mc, "a companion opens and writes only guarded names")
need("guard let root, WorkCardFiles.validEntry(file) else { return }" in files, "a companion with a name Control does not write is never restarted")
# W2 and Q4: Remove only hides.
rm = body(files, "    func remove(_ fileID: String, workID: String) {", "    /// Undo: the file is back on the card, as it was.")
need("removeItem" not in rm and "deleteCopies" not in rm and "setHidden(fileID, workID: workID, at: Date().timeIntervalSince1970)" in rm, "Remove hides and never deletes")
# B2: links with a user or password.
web = body(files, "    nonisolated static func commitWebLink(", "    nonisolated static func commitLinkEntry(")
need("if linkHasCredentials(text) { return .failure(.linkCredentials) }" in web, "a link with a user or password is refused")
# W1 and QA round 2: the identity stamp starts with the drop and the copies start beside it; a file is written after both.
for intake in ("    func intake(urls: [URL], source: WorkSource) async {", "    func intake(providers: [NSItemProvider], source: WorkSource) async {"):
    section_text = body(files, intake, "\n    }\n")
    need("let identity = identityGate(workID)" in section_text and "identity: identity)" in section_text, "every intake writes after the identity gate")
    first_await = section_text.index("await ")
    need(section_text.index("let identity = identityGate(workID)") < first_await and ("Task.detached { await WorkCardFiles.ingest(" in section_text[:section_text.index("for copy in copies")]
         if "for copy in copies" in section_text else "loads.append(Task" in section_text[:section_text.index("for load in loads")]),
         "the copies start before anything waits on the stamp")
gate = body(files, "    private func identityGate(", "    private func begin(")
need("let stamp = Task { await stampIdentity(workID) }" in gate and "return { await stamp.value }" in gate, "the stamp runs beside the copies")
need("unstampedNote" in body(files, "    nonisolated static func commit(staged:", "    /// A folder is never copied") and "refresh" not in files.split('nonisolated static let unstampedNote = "')[1].split('"')[0].lower(),
     "a failed stamp adds the file with a note that never says refresh")
need("store.cardFiles.stampIdentity = { [weak self] workID in await self?.stampWorkIdentity(workID) ?? false }" in code("Sources/ControllerModel.swift"),
     "the app stamps through its Work stage write")
# W6: the board line comes on the drop, never on hover. Anchored on the column delegate, not the card face's dropEntered.
board_entered = board_delegate[board_delegate.index("func dropEntered"):board_delegate.index("func dropExited")]
need("onRefusedFiles" not in board_entered and "onFileHover(true)" in board_entered, "the Files go on a card line shows on drop only")
card_entered = delegate[delegate.index("func dropEntered"):delegate.index("func dropExited")]
need("onRefusedFiles" not in card_entered, "a card face does not flash the board line on hover")

# 7. Every compile list builds the new file.
for rel in ("Tests/run.sh", "scripts/build-release.sh", "scripts/build-foundation-lab.sh", "Tests/run-held-ui.sh", "Tests/run-merge-ui.sh",
            "Tests/run-markdown-ui.sh", "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh"):
    text = code(rel)
    # Compile lines only: run.sh also hands these sources to a python pin, which is not a build.
    lists = sum(1 for line in text.split("\n") if not line.lstrip().startswith("python3")
                and '"$ROOT/Sources/WorkProgress.swift" "$ROOT/Sources/WorkProgressTracker.swift"' in line)
    need(lists == 0, f"{rel} compiles WorkProgress.swift without WorkCardFiles.swift")
    need('"$ROOT/Sources/WorkCardFiles.swift"' in text, f"{rel} must compile WorkCardFiles.swift")
need("WorkProgress WorkCardFiles WorkProgressTracker" in code("Tests/run-work.sh"), "run-work.sh compiles WorkCardFiles")

# 8. Tests never open a panel or Quick Look (the desktop check enforces it; this keeps the rule there).
need("NSOpenPanel|NSSavePanel|QLPreviewPanel" in code("Tests/desktop-safety-check.py"), "the desktop check refuses file panels and Quick Look in tests")
print("COS Control: card files wiring pinned (0.5.254): private card type, a column card face forwards a work-card drag, the Files box stays file-only, refused board drops, one block composer, countdown, cleanup, compile lists")
