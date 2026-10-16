#!/usr/bin/env python3
"""0.5.313 idle CPU pins (2026-10-15 22:30 sample of Control 0.5.311: an idle Work tab used a third of the main thread).
Each failure names its behaviour as "pin failed [<behaviour>]".

    python3 Tests/idle-cpu-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
store = (root / "Sources/WorkHandoffStore.swift").read_text(encoding="utf-8")
models = (root / "Sources/Models.swift").read_text(encoding="utf-8")
dictation = (root / "Sources/MacDictation.swift").read_text(encoding="utf-8")
handoff = (root / "Sources/WorkHandoffView.swift").read_text(encoding="utf-8")
workspace = (root / "Sources/WorkWorkspaceView.swift").read_text(encoding="utf-8")


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


recs = between(store, "    func recommendations(for source: WorkSource) -> [WorkSession] {", "    private var recommendationCache:")
pin("if let cached = recommendationCache, cached.key == key { return cached.value }" in recs, "recommendations cached",
    "a redraw with the same card, sessions and receipts must not score every session again")
pin("sessions: sessionsEpoch, receipts: receiptsEpoch" in recs, "recommendations cached", "the cache key must change with the sessions and receipts")
pin(re.search(r"sorted\s*\{[^}]*score\(", recs) is None, "scored once", "no score() inside a sort comparator")
short = between(store, "    nonisolated static func shortlist(", "    func draft(for source:")
pin(re.search(r"sorted\s*\{[^}]*updatedDate", short) is None, "dates read once", "no date parse inside the shortlist comparator")
new_items = between(models, "    func newItems(now: Date = Date()) -> [WorkIntakeItem] {", "    var newCount: Int")
pin("ISO8601DateFormatter()" not in new_items and "row.producedDate" in new_items, "intake dates at decode",
    "newItems must use the date parsed when the row was decoded")
pin("producedDate = Self.stamp(producedAt)" in models, "intake dates at decode", "the row parses its date once")
player = between(dictation, "@MainActor final class DictationSoundPlayer {", "/// A chosen file, decoded to mono")
pin("scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack)" in player and "Task { @MainActor in self?.finished(id) }" in player,
    "sound engine stops", "the player must learn when its sound has played")
pin("node.stop(); engine.stop()" in between(player, "    private func finished(_ id: Int) {", "    nonisolated static func stopsAfter"),
    "sound engine stops", "the output engine must stop after the newest sound (no audio IO while idle)")
pin("scheduleFile(file, at: nil)\n" not in player, "sound engine stops", "no sound is scheduled without its completion")
pin("let _ = WorkBoardMetrics.countHandoffBody()" in handoff and "performanceLog.notice(" in workspace, "rebuild rate logged",
    "the Agent workspace's rebuilds are counted and logged once a minute")
print("PASS idle CPU pins: cached recommendations, dates read once, intake dates at decode, sound engine stops, rebuild rate logged")
