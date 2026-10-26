#!/usr/bin/env python3
"""0.5.313 idle CPU pins (2026-10-15 22:30 sample of Control 0.5.311: an idle Work tab used a third of the main thread).
Each failure names its behaviour as "pin failed [<behaviour>]".

    python3 Tests/idle-cpu-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")


def code(rel):
    """Source with comment lines removed (QA 2026-10-15): a commented-out statement never satisfies a pin."""
    return "\n".join(l for l in (root / rel).read_text(encoding="utf-8").splitlines() if not l.lstrip().startswith("//"))


store = code("Sources/WorkHandoffStore.swift")
models = code("Sources/Models.swift")
dictation = code("Sources/MacDictation.swift")
handoff = code("Sources/WorkHandoffView.swift")
workspace = code("Sources/WorkWorkspaceView.swift")


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
# 0.5.328: the player lives on a dictation audio queue (0.5.345: its own, DictationAudioQueues.sound), not the main actor.
player = between(dictation, "final class DictationSoundPlayer: @unchecked Sendable {", "struct DictationSoundImport {")
# 0.5.314: the completion is built by the nonisolated playedBack (a closure formed inside the @MainActor player trapped
# on AVAudioPlayerNode's queue in 0.5.313), so the pin follows the signal through it: every sound is scheduled with
# playedBack as its .dataPlayedBack completion, and playedBack hops to the output queue and reports finished(id).
played_back = between(player, "    private nonisolated static func playedBack(_ owner: DictationSoundPlayer, id: Int)", "    var isRunning: Bool")
pin(player.count("scheduleFile(") == 1
    and player.count("node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: Self.playedBack(self, id: id))") == 1
    and "DictationAudioQueues.sound.async { owner.finished(id) }" in played_back,
    "sound engine stops", "the player must learn when its sound has played (scheduleFile's completion is playedBack, which reports finished(id))")
pin("node.stop(); engine.stop()" in between(player, "    private func finished(_ id: Int) {", "    nonisolated static func stopsAfter"),
    "sound engine stops", "the output engine must stop after the newest sound (no audio IO while idle)")
pin("scheduleFile(file, at: nil)\n" not in player, "sound engine stops", "no sound is scheduled without its completion")
pin("let _ = WorkBoardMetrics.countHandoffBody()" in handoff and "performanceLog.notice(" in workspace, "rebuild rate logged",
    "the Agent workspace's rebuilds are counted and logged once a minute")
print("PASS idle CPU pins: cached recommendations, dates read once, intake dates at decode, sound engine stops, rebuild rate logged")
