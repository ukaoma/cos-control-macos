#!/usr/bin/env python3
"""0.5.342 Your edit, confirmed: where the pure rules (DictationEditConfirm, DictationWordDiff, in
Tests/EditConfirmChecks.swift) are wired. Each failure names its behaviour as "pin failed [<behaviour>]". Code only:
comments never satisfy a pin. Call sites are pinned, not definitions.

Then a self-test: each in-memory mutant below must land exactly once in its file and must make a named pin fail, so no
pin here is decoration. Text only: SwiftUI layout is compiled by the full app build, not here.

    python3 Tests/edit-confirm-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")
FILES = {"d": "Sources/MacDictation.swift", "pet": "Sources/SessionPet.swift", "app": "Sources/COSControlApp.swift"}


class PinFailed(Exception):
    pass


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        raise PinFailed(f"pin failed [{behaviour}]: {why}")


def body(src, opener):
    pin(src.count(opener) == 1, "source shape", f"{opener!r} must appear exactly once")
    start = src.index(opener)
    depth, i, seen = 0, start, False
    while i < len(src):
        if src[i] == "{":
            depth += 1; seen = True
        elif src[i] == "}":
            depth -= 1
            if seen and depth == 0:
                return src[start:i + 1]
        i += 1
    return src[start:]


def check(src):
    d, pet, app = code(src["d"]), code(src["pet"]), code(src["app"])
    watcher = body(d, "@MainActor final class DictationEditWatcher {")
    run = body(d, "    private func run(_ field: WatchField,")
    watch = body(d, "    nonisolated private static func watch(")
    finish = body(d, "    private func finish(_ text: String, outcome: DictationDeliveryOutcome")
    ended = body(d, "    private func editWatchEnded(_ end: DictationWatchEnd) async {")
    view = body(d, "    func viewEditFromPill() {")
    learned = body(d, "    private func editLearned(")
    detail = body(d, "@MainActor struct DictationRecordDetail: View {")
    tag = body(d, "struct DictationEditedTag: View {")
    pane = body(d, "struct DictationHistoryPane: View {")
    row = body(d, "private struct DictationHistoryRow: View {")

    # 1. The watch keeps where its last good read placed the dictation, and reports how it ended to its own dictation.
    pin("while !Task.isCancelled {\n                tail.window = baseline; tail.start = start; tail.length = length" in watch,
        "tail", "the loop records the last good read before anything can end the watch")
    pin(watch.count("if let candidate { tail.candidates.append(candidate) }") == 1, "tail", "the pairs handed on are reported")
    pin(watcher.count("nextOwner = (pendingRecord, target.app); pendingRecord = nil") == 2, "owner",
        "start and startOwn each take the dictation the store named")
    pin(run.count("let owner = nextOwner, finished = self.finished") == 1 and run.count("tail: &tail, found: found)") == 1, "owner",
        "each run captures its owner when it starts")
    rule = "DictationEditConfirm.captured(typed: typed, window: tail.window, start: tail.start, length: tail.length,"
    pin(run.count(rule) == 1 and "inside: canary.inside, readable: canary.readable, learning: learning, stop: canary.stop)" in run,
        "captured", "the tested rule decides what is kept, from the watch's own counts")
    pin(run.count("await finished(DictationWatchEnd(") == 1 and run.index("Self.record(canary)") < run.index("await finished(DictationWatchEnd("),
        "ending", "every watch with an owner reports its ending, after its canary line")
    pin("if canary.inside > 0 { canary.edited = final != nil }" in run, "canary", "the canary carries the verdict, never the words")

    # 2. The store names the dictation, and the ending is wired once.
    pin("editWatcher.pendingRecord = record.id" in finish and finish.index("editWatcher.pendingRecord = record.id") < finish.index("if swapPending {"),
        "record", "finish names its dictation before any watch starts")
    pin(d.count("editWatcher.pendingRecord = id\n            editWatcher.start(watchTarget, mode: learnMode, context: watchContext)") == 1,
        "record", "the watch after a swap names its dictation too")
    pin(d.count("editWatcher.finished = { [weak self] end in await self?.editWatchEnded(end) }") == 1, "ending wired", "the store hears every ending")
    pin(learned.count("learnSaves.append(Task {") == 1, "learn awaited", "a learn save is kept for the ending to wait on")

    # 3. The ending: waits for learn saves, the tested edit, the history's own save, the pill once and never over another.
    pin("for save in saves { await save.value }" in ended and ended.index("for save in saves { await save.value }") < ended.index("DictationEditConfirm.edit("),
        "learn awaited", "the ending knows what was learned before it decides")
    pin(ended.count("recent = DictationHistory.editing(id, edit: edit, in: recent); saveRecent()") == 1, "saved", "the edit goes on the record and is saved")
    pin("DictationEditConfirm.showsAtEnd(shown)" in ended and "DictationEditConfirm.label(shown)" in ended, "pill", "the tested pill and label")
    pin("pill == .hidden || (learnedUndoPill != nil && pill == learnedUndoPill)" in ended and "!busy" in ended, "pill once",
        "never over a newer dictation's pill")
    pin(ended.index("editViewID = id; editViewPill = flash") < ended.index("        pill = flash"), "pill view",
        "View is set before the pill, so the overlay's pill sink reads it")
    for line in re.findall(r"dictationLog\.\w+\((.*)\)", ended):
        for word in ("final)", "finalText)", ".text", "typed", "phrase", "heard", "written", "record)", "edit)"):
            pin(word not in line, "privacy", f"no words in the log: {line[:80]!r}")

    # 4. View on the pill, both pills, and the floating panel takes the click.
    pin(d.count("onView: store.pillViewID == nil ? nil : { store.viewEditFromPill() },") == 1, "view", "the floating pill offers View")
    pin(pet.count("onView: dictation.pillViewID == nil ? nil : { dictation.viewEditFromPill() },") == 1, "view", "the pet's pill offers View")
    pin("store.pillUndoID == nil && store.pillViewID == nil" in d, "view", "the floating pill takes the View click")
    pin("var pillViewID: UUID? { pill == editViewPill ? editViewID : nil }" in d, "view", "View only on its own flash")
    pin("openDetail(id)" in view and "openHistory?()" in view, "view", "View opens the card on the pet, else Activity history")
    pin(app.count("model.dictation.openHistory = { [weak model] in model?.openDictationHistoryInActivity() }") == 1, "view", "the app wires history")

    # 5. The card.
    pin(detail.count("store.copy(DictationEditConfirm.copyText(record, showOriginal: showOriginal))") == 1, "copy", "Copy follows Show original")
    pin(detail.count('Button("Fix a word") { store.openFix(record.id) }') == 1, "fix a word", "Fix a word stays on the card")
    pin('if !learnedLive.isEmpty {' in detail and detail.index('if !learnedLive.isEmpty {') < detail.index('Button("Undo learn")'), "undo learn",
        "Undo learn only while a learned word is still learned")
    pin('Button(showOriginal ? "Show edit" : "Show original") { showOriginal.toggle() }' in detail, "show original", "the toggle")
    pin("if let edit = record.edit, !showOriginal { Text(Self.marked(parts, final: edit.text)) } else { Text(record.text) }" in detail,
        "diff", "the marked final text, or exactly what COS typed")
    pin("Text(DictationEditConfirm.reason(parts: parts, learned: learnedLive))" in detail, "reason", "the tested reason line")
    pin("DictationEditConfirm.offersDrop(phrase: dropPhrase, available: instructions.available," in detail
        and "polishOn: store.polishModel != .off, saved: instructions.saved)" in detail, "chip", "the chip only where it can work")
    pin(detail.count("instructions.save(") == 2 and detail.count("DictationEditConfirm.adding(phrase, to: instructions.saved)") == 1
        and detail.count("DictationEditConfirm.removing(phrase, from: instructions.saved)") == 1, "chip", "add and Undo through the setting")
    task = body(detail, "        .task(id: record.edit != nil) {")
    pin("save(" not in task and "clear(" not in task, "chip tap only", "opening the card never changes the instructions")
    pin(pet.count("if let edit = record?.edit { DictationEditedTag(app: edit.app, size: size) }") == 1, "tag", "EDITED IN <APP> in the header row")
    # Miles 10:26 (the mock card narrow): one row when it fits, else two rows, same actions, same order; no label ever
    # wraps inside its control, and the chip stays one line.
    row_view = body(detail, "    private var actionRow: some View {")
    pin(row_view.count("ViewThatFits(in: .horizontal) {") == 1 and row_view.count("copyButton; learnOrFixButton") == 2
        and row_view.count("deleteButton; backButton") == 2 and row_view.count("if record.edit != nil { originalLink }") == 2,
        "action row fits", "one row as designed, else two rows with every action")
    pin(detail.count("            actionRow\n") == 1, "action row fits", "the card uses the row")
    for opener, labels in (("    private var copyButton: some View {", 1), ("    @ViewBuilder private var learnOrFixButton: some View {", 2),
                           ("    private var deleteButton: some View {", 1), ("    private var backButton: some View {", 1),
                           ("    private var originalLink: some View {", 1)):
        part = body(detail, opener)
        pin(part.count(".lineLimit(1)") == labels and part.count(".fixedSize(horizontal: true, vertical: false)") == labels,
            "labels one line", f"{opener.strip()} keeps every label on one line at its own width")
    chip = body(detail, "    @ViewBuilder private func dropChip(_ phrase: String) -> some View {")
    pin(chip.count(".lineLimit(1)") == 3 and chip.count(".truncationMode(.middle)") == 2, "chip one line",
        "the chip and its added line are one line, truncated in the middle only when they cannot fit")
    pin("Text(record.finalFirstLine)" in row and "store.copy(record.finalText)" in pane, "history row", "Activity reads and copies what was sent")
    for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', detail + tag):
        pin("—" not in literal and "→" not in literal and " -> " not in literal, "copy", f"no em dash or arrow: {literal[:80]!r}")


MUTANTS = [
    ("tail never written", "d", "                tail.window = baseline; tail.start = start; tail.length = length\n", ""),
    ("no ending reported", "d", "await finished(DictationWatchEnd(", "_ = (DictationWatchEnd("),
    ("owner not taken for COS's own views", "d",
     "        nextOwner = (pendingRecord, target.app); pendingRecord = nil\n        let eligibility = DictationEditLearning.eligibility(mode: mode, secure: IsSecureEventInputEnabled()",
     "        let eligibility = DictationEditLearning.eligibility(mode: mode, secure: IsSecureEventInputEnabled()"),
    ("captured rule bypassed", "d", "DictationEditConfirm.captured(typed: typed, window: tail.window,", "Optional(tail.window).map { _ in typed } ?? (typed: typed, window: tail.window,"),
    ("record not handed to the watch", "d", "        editWatcher.pendingRecord = record.id\n", ""),
    ("swap watch has no record", "d", "            editWatcher.pendingRecord = id\n", ""),
    ("ending not wired", "d", "        editWatcher.finished = { [weak self] end in await self?.editWatchEnded(end) }\n", ""),
    ("learn save not kept", "d", "        learnSaves.append(Task {", "        _ = (Task {"),
    ("learn not awaited", "d", "        for save in saves { await save.value }\n", ""),
    ("edit not saved", "d", "        recent = DictationHistory.editing(id, edit: edit, in: recent); saveRecent()\n", "        _ = edit\n"),
    ("pill over a newer dictation", "d", "pill == .hidden || (learnedUndoPill != nil && pill == learnedUndoPill)", "true"),
    ("words in the log", "d", 'dictationLog.notice("learn edit saved=true edits=', 'dictationLog.notice("learn edit saved=true \\(edit.text) edits='),
    ("View not on the floating pill", "d", "                                       onView: store.pillViewID == nil ? nil : { store.viewEditFromPill() },",
     "                                       onView: nil,"),
    ("View not on the pet pill", "pet", "onView: dictation.pillViewID == nil ? nil : { dictation.viewEditFromPill() },", "onView: nil,"),
    ("floating pill ignores View", "d", " && store.pillViewID == nil\n", "\n"),
    ("View has no fallback", "d", "            openHistory?()\n", ""),
    ("history not wired", "app", "        model.dictation.openHistory = { [weak model] in model?.openDictationHistoryInActivity() }\n", ""),
    ("Copy ignores the toggle", "d", "store.copy(DictationEditConfirm.copyText(record, showOriginal: showOriginal))", "store.copy(record.text)"),
    ("Fix a word lost", "d", 'Button("Fix a word") { store.openFix(record.id) }', 'Button("Fix") { store.openFix(record.id) }'),
    ("Undo learn always", "d", "        if !learnedLive.isEmpty {\n", "        if true {\n"),
    ("no diff marks", "d", "Text(Self.marked(parts, final: edit.text))", "Text(edit.text)"),
    ("chip ignores polish off", "d", "polishOn: store.polishModel != .off, saved: instructions.saved)", "polishOn: true, saved: instructions.saved)"),
    ("chip added on open", "d", "if record.edit != nil, !instructions.loaded, !instructions.busy { await instructions.load() }",
     'if record.edit != nil, !instructions.loaded, !instructions.busy { await instructions.load(); _ = await instructions.save("x") }'),
    ("tag missing", "pet", "            if let edit = record?.edit { DictationEditedTag(app: edit.app, size: size) }\n", ""),
    ("action row never falls back", "d", "        ViewThatFits(in: .horizontal) {\n            HStack(spacing: size.length(7)) {\n                copyButton; learnOrFixButton",
     "        Group {\n            HStack(spacing: size.length(7)) {\n                copyButton; learnOrFixButton"),
    ("fallback hides Delete and Back", "d", "                    Spacer(minLength: 0)\n                    deleteButton; backButton\n", "                    Spacer(minLength: 0)\n"),
    ("Copy wraps", "d", ".buttonStyle(DictationButtonStyle(primary: true, size: size))\n            .lineLimit(1)\n", ".buttonStyle(DictationButtonStyle(primary: true, size: size))\n"),
    ("Undo learn wraps", "d", '.help("Remove what COS learned from this edit from your dictionary")\n                .lineLimit(1)\n',
     '.help("Remove what COS learned from this edit from your dictionary")\n'),
    ("Fix a word wraps", "d", 'Button("Fix a word") { store.openFix(record.id) }\n                .buttonStyle(DictationButtonStyle(size: size))\n                .lineLimit(1)\n',
     'Button("Fix a word") { store.openFix(record.id) }\n                .buttonStyle(DictationButtonStyle(size: size))\n'),
    ("Fix a word squeezed", "d", 'Button("Fix a word") { store.openFix(record.id) }\n                .buttonStyle(DictationButtonStyle(size: size))\n                .lineLimit(1)\n                .fixedSize(horizontal: true, vertical: false)\n',
     'Button("Fix a word") { store.openFix(record.id) }\n                .buttonStyle(DictationButtonStyle(size: size))\n                .lineLimit(1)\n'),
    ("Delete wraps", "d", ".buttonStyle(COSTextButtonStyle(tone: .destructive))\n            .font(COSType.body(size.typeSize(10)))\n            .lineLimit(1)\n",
     ".buttonStyle(COSTextButtonStyle(tone: .destructive))\n            .font(COSType.body(size.typeSize(10)))\n"),
    ("Back wraps", "d", "Button(\"Back\") { store.backToRecent() }\n            .buttonStyle(COSTextButtonStyle())\n            .font(COSType.body(size.typeSize(10)))\n            .lineLimit(1)\n",
     "Button(\"Back\") { store.backToRecent() }\n            .buttonStyle(COSTextButtonStyle())\n            .font(COSType.body(size.typeSize(10)))\n"),
    ("Show original wraps", "d", '.help(showOriginal ? "Show the text with your edit" : "Show exactly what COS typed")\n            .lineLimit(1)\n',
     '.help(showOriginal ? "Show the text with your edit" : "Show exactly what COS typed")\n'),
    ("chip wraps", "d", 'Text(" from my dictation"))\n                    .font(COSType.body(size.typeSize(9)))\n                    .foregroundStyle(.secondary)\n                    .lineLimit(1)\n',
     'Text(" from my dictation"))\n                    .font(COSType.body(size.typeSize(9)))\n                    .foregroundStyle(.secondary)\n'),
    ("an em dash on the card", "d", '"Show the text with your edit"', '"Show the text — with your edit"'),
]

sources = {k: read(v) for k, v in FILES.items()}
try:
    check(sources)
except PinFailed as e:
    sys.exit(str(e))
caught = 0
for name, key, old, new in MUTANTS:
    if sources[key].count(old) != 1:
        sys.exit(f"pin self-test: mutant '{name}' lands {sources[key].count(old)} times in {FILES[key]}; it must land exactly once")
    try:
        check(dict(sources, **{key: sources[key].replace(old, new)}))
    except PinFailed as e:
        caught += 1
        print(f"KILLED  {name}  <- {e}")
        continue
    sys.exit(f"pin self-test: mutant '{name}' landed and every pin still passed")
print(f"PASS edit confirm pins: the tail, the owner, the tested capture, the ending, the record, the pill once, View, "
      f"the card, the chip on tap only, privacy; {caught} of {len(MUTANTS)} in-memory mutants caught")
