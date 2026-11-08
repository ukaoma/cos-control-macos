#!/usr/bin/env python3
"""0.5.380 (Miles 2026-11-08, server 7.0.5): where Summaries per day and the reconnect ask are wired, pinned where
Tests/TodayCapChecks.swift cannot reach (the Today store, the Settings row, the catalog, the helper dispatch, run.sh).
Comments never count. Each failure names its behaviour as "pin failed [<behaviour>]".

    python3 Tests/today-cap-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = 0


def code(rel):
    return "\n".join(re.sub(r"(^|\s)//.*$", "", line) for line in (root / rel).read_text(encoding="utf-8").split("\n"))


def pin(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")
    passed += 1


def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


window = code("Sources/ActivityWindow.swift")
helper = code("HelperSources/main.swift")
catalog = code("Sources/SettingsHubCatalog.swift")
run_sh = code("Tests/run.sh")

# ── Reconnect: observed after every Today tick, before the ask; spent by the automatic ask only.
tick = between(window, "func todayTick() async {", "\n    }\n")
observe = "today.reconnects.observe(failed: model.claudeSessionsError != nil || today.reachable == false || today.tickFailed)"
pin(observe in tick and tick.index("await today.tick(model: model)") < tick.index(observe) < tick.index("today.askSummary("), "observe",
    "each tick records whether the sessions or Today read failed, after the reads and before the ask")
auto = between(window, "private func performAutomaticSummary(model: ControllerModel, body: JSONValue, now: Date) async {", "\n    }\n")
pin("let reconnect = !summary.inflight && reconnects.take(switchedOff: summary.reply?.switchedOff == true)" in auto
    and "guard reconnect || summary.shouldAsk(key: key, now: now) else { return }" in auto, "early ask",
    "a reconnect asks at once, once, never while an ask is in flight or the summary is off")
pin("body: reconnect ? TodaySummary.reconnecting(body) : body" in auto, "reason", "the reconnect ask says reason reconnect")
pin("reconnect" not in between(window, "private func performRefreshedSummary(", "\n    }\n"), "refresh", "Refresh never says reconnect")
perform = between(window, "private func performTick(model: ControllerModel, now: Date, force: Bool) async {", "hosts = await Self.readHosts")
pin(perform.count("tickFailed = false") == 1 and perform.count("tickFailed = true") == 1 and perform.index("tickFailed = false") < perform.index("} catch {") < perform.index("tickFailed = true"),
    "tick failed", "a tick that answers clears tickFailed and one that throws sets it")
pin(window.count("reconnects.take(") == 1 and window.count("reconnects.observe(") == 1, "one site", "one observer and one taker")

# ── Summaries per day: read after the switch, shown only when the server has it, saved through the helper.
store = between(window, "@MainActor final class TodaySummarySettingsStore: ObservableObject {", "\nstruct TodaySummarySettingsBlock")
pin("await loadCap(model: model)" in between(store, "func load(model: ControllerModel) async {", "\n    }\n"), "cap read", "the cap is read with the switch")
pin('guard settings != nil else { cap = nil; return }' in store and 'response.details["available"]?.bool == true else { cap = nil; return }' in store,
    "older server", "no summary or no setting on the server: no row")
pin('model.todayHelper(["today-brief-cap", "--set", String(wanted)], timeout: 12)' in store, "cap save", "a change goes through the helper")
block = between(window, "struct TodaySummarySettingsBlock: View {", "\n}\n")
pin("if let cap = store.cap {" in block and 'anchor: "item.TS-02"' in block and "in: cap.min...cap.max" in block, "cap row", "the row shows only with a cap, 1 to 100")
pin(re.search(r'\.init\("TS-02", "Summaries per day", .*?group: "general\.home",\s*advanced: false', catalog, re.S) is not None, "catalog",
    "Summaries per day is a hub row under Activity home")

# ── The helper and the lanes.
pin('case "today-brief-cap": try emitTodayBriefCap(args: args)' in helper, "dispatch", "the helper dispatches today-brief-cap")
cap = between(helper, "private func emitTodayBriefCap(args: [String]) throws {", "\n    }\n")
pin('if change != nil, value == nil { throw HelperError.message("Choose a number from 1 to 100.") }' in cap, "range", "a bad value never reaches the server")
pin('python3 "$ROOT/Tests/today-cap-helper-checks.py" "$TMP/cos-control-helper"' in run_sh and 'zsh "$ROOT/Tests/run-today-cap.sh"' in run_sh,
    "lanes", "run.sh runs the helper checks and the Swift checks")

print(f"today cap pins: {passed} passed")
