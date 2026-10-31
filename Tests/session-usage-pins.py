#!/usr/bin/env python3
"""Usage and Update Server wiring that the Usage checks and the helper fixture cannot see. Each pin carries the edit that
breaks it, and this script proves each one fails on that edit (on the text in memory; nothing is written).
Run by Tests/run-session-usage.sh. Prints "usage wiring pins: N passed, N proved". Usage: session-usage-pins.py <root>"""
import pathlib, sys

root = pathlib.Path(sys.argv[1])
VIEW, CORE, ACTIVITY, HELPER = "Sources/SessionUsageView.swift", "Sources/SessionUsageCore.swift", "Sources/ActivityWindow.swift", "HelperSources/main.swift"
CONNECT, CONTROLLER, HUB = "Sources/ProviderConnectModel.swift", "Sources/ControllerModel.swift", "Sources/SettingsHubViews.swift"
texts = {name: (root / name).read_text(encoding="utf-8") for name in (VIEW, CORE, ACTIVITY, HELPER, CONNECT, CONTROLLER, HUB)}


def once(text, needle):
    return text.count(needle) == 1


def before(text, first, second):
    return once(text, first) and second in text and text.index(first) < text.index(second)


def between(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


INSTALL_GUARD = "try requireLatestMovesForward(requested: requestedVersion, resolved: release.version)"
ADOPT_GUARD = "try requireLatestMovesForward(requested: requestedVersion, resolved: resolveVersion(requestedVersion).version)"
HEADER = "await model.sessionUsage.refresh(importNew: model.sessionUsage.enabled, cursorNow: true)"
INSTALL_COMMAND = 'static let cursorInstallCommand = "curl https://cursor.com/install -fsS | bash"'
# (name, check over the texts, the file its mutation edits, old, new)
PINS = [
    ("the header Refresh imports only while tracking",
     lambda t: once(t[ACTIVITY], HEADER), ACTIVITY, "refresh(importNew: model.sessionUsage.enabled, cursorNow: true)", "refresh(importNew: true, cursorNow: true)"),
    ("every helper call goes through helperArguments",
     lambda t: once(t[VIEW], "SessionUsagePresentation.helperArguments(importNew: importNew, tracking: enabled,") and '"session-usage"' not in t[VIEW],
     VIEW, "let arguments = SessionUsagePresentation.helperArguments(importNew: importNew, tracking: enabled, cursorEnabled: cursorEnabled, cursorNow: cursorNow)",
     'let arguments = importNew ? ["session-usage"] : ["session-usage", "--read-only"]'),
    ("Update Server cannot go backward (install asks before anything is staged)",
     lambda t: before(t[HELPER], INSTALL_GUARD, "let generation = try stageGeneration(version: release.version"), HELPER, INSTALL_GUARD + "\n", "\n"),
    ("Adopt asks before the legacy server stops",
     lambda t: before(between(t[HELPER], "private func adoptLegacy(requestedVersion: String) throws {", "private func adoptLegacyInPlace"), ADOPT_GUARD, "try unloadService()"),
     HELPER, ADOPT_GUARD + "\n", "\n"),
    ("the panel's install and adopt still ask for latest, which the guard covers",
     lambda t: once(t[CONTROLLER], 'static let managedServerInstallVersion = "latest"'), CONTROLLER, 'managedServerInstallVersion = "latest"', 'managedServerInstallVersion = "6.94.2"'),
    ("a paused pass tells the collector it is paused",
     lambda t: "cursorSyncFailed: cursorSyncFailed, readOnly: readOnly)" in t[HELPER], HELPER, "cursorSyncFailed: cursorSyncFailed, readOnly: readOnly)", "cursorSyncFailed: cursorSyncFailed)"),
    ("the Cursor install command matches the provider screen",
     lambda t: once(t[CORE], INSTALL_COMMAND) and 'case .cursor: "curl https://cursor.com/install -fsS | bash"' in t[CONNECT],
     CORE, "curl https://cursor.com/install -fsS | bash", "curl https://example.invalid | bash"),
    ("turning Cursor on while paused only saves the choice",
     lambda t: "cursorEnabled = true\n        guard enabled else { return }\n        readWhileWaiting()" in t[VIEW], VIEW, "cursorEnabled = true\n        guard enabled else { return }\n", "cursorEnabled = true\n"),
    ("pausing part way stops the first read",
     lambda t: once(t[VIEW], "guard enabled else { break }"), VIEW, "                guard enabled else { break }\n", ""),
    ("Resume and the settings menu read at once",
     lambda t: "enabled = true\n        readWhileWaiting()" in t[VIEW] and once(t[VIEW], "if on { store.resume() } else { store.enabled = false }") and once(t[HUB], "if on { store.resume() } else { store.enabled = false }") and once(t[VIEW], 'Button("Resume tracking") { store.resume() }'),
     VIEW, 'Button("Resume tracking") { store.resume() }', 'Button("Resume tracking") { store.enabled = true }'),
    ("the paused bar shows whenever tracking is off",
     lambda t: once(t[VIEW], "if !store.enabled { pausedBar.padding(.top, 12) }"), VIEW, "if !store.enabled { pausedBar.padding(.top, 12) }", ""),
    ("the page's freshness comes from the paused rule",
     lambda t: once(t[VIEW], "P.freshnessLabel(tracking: store.enabled, updatedTime: updatedTime)") and 'Text("Updated' not in t[VIEW],
     VIEW, "P.freshnessLabel(tracking: store.enabled, updatedTime: updatedTime)", "P.freshnessLabel(tracking: true, updatedTime: updatedTime)"),
    ("both pending lines and the empty page follow the paused rule",
     lambda t: t[VIEW].count("P.pendingNotes(tracking: store.enabled,") == 2 and once(t[VIEW], "P.emptyWords(tracking: store.enabled,") and "Totals will grow" not in t[VIEW],
     VIEW, "P.emptyWords(tracking: store.enabled,", "P.emptyWords(tracking: true,"),
    ("the month estimate follows the paused rule",
     lambda t: once(t[VIEW], "P.monthPace(matching, now: Date(), timeZone: reportingZone, tracking: store.enabled)"), VIEW, ", tracking: store.enabled)\n        var list", ")\n        var list"),
    ("the Cursor row and footer use the same words",
     lambda t: once(t[VIEW], "P.cursorWords(on: on, tracking: store.enabled, feed: feed, commandLine: store.cursorCommandLine)")
               and once(t[VIEW], "P.cursorProblem(feed, commandLine: store.cursorCommandLine, tracking: store.enabled)"),
     VIEW, "P.cursorProblem(feed, commandLine: store.cursorCommandLine, tracking: store.enabled)", "feed.message"),
    ("the copy button copies what the file check found",
     lambda t: once(t[VIEW], "path.map(P.cursorSignInCommand) ?? P.cursorInstallCommand") and '"cursor-agent login"' not in t[VIEW],
     VIEW, "path.map(P.cursorSignInCommand) ?? P.cursorInstallCommand", '"cursor-agent login"'),
    ("the chart and its legend share one average",
     lambda t: t[VIEW].count("chartAverage(") == 2 and once(t[VIEW], "P.partialBarsNote(scaleWord: scaleWord, averageDrawn: drawsAverage)") and "periodAverage(" not in t[VIEW],
     VIEW, "P.partialBarsNote(scaleWord: scaleWord, averageDrawn: drawsAverage)", "P.partialBarsNote(scaleWord: scaleWord, averageDrawn: periodKeys.count - partialPeriods.count >= 4)"),
    ("never $0 is decided in Core, not the view",
     lambda t: "pricedEvents > 0" not in t[VIEW].replace("point.pricedEvents > 0 ?", "").replace("row.pricedEvents > 0 &&", "") and once(t[VIEW], "P.dayCounted(summary, measure: measure)") and once(t[VIEW], "P.hasFigure(measure, pricedEvents: $0.pricedEvents)"),
     VIEW, "P.hasFigure(measure, pricedEvents: $0.pricedEvents)", "measure != .cost || $0.pricedEvents > 0"),
    ("the helper tries the app's Node first for compressed logs, and never a zstd binary",
     lambda t: once(t[HELPER], 'collector.compressedLogNodes = ([bundledNode] + executableCandidates("node")).filter { fm.isExecutableFile(atPath: $0) }'),
     HELPER, '([bundledNode] + executableCandidates("node"))', '(executableCandidates("node"))'),
    ("COS cost's Refresh imports only while tracking",
     lambda t: once(t[ACTIVITY], "if sessionsPane == .cost { await CosCostStore.shared.refresh(importSessions: model.sessionUsage.enabled) }"),
     ACTIVITY, "CosCostStore.shared.refresh(importSessions: model.sessionUsage.enabled)", "CosCostStore.shared.refresh(importSessions: true)"),
    ("Usage's Refresh keeps its own branch beside COS cost's",
     lambda t: "else if showingSessionUsage { await model.sessionUsage.refresh(importNew: model.sessionUsage.enabled, cursorNow: true) }" in t[ACTIVITY],
     ACTIVITY, "else if showingSessionUsage { await model.sessionUsage.refresh(", "else if false { await model.sessionUsage.refresh("),
    ("COS cost's helper call reads only while tracking",
     lambda t: once(t[VIEW], 'importSessions ? ["cos-usage"] : ["cos-usage", "--read-only"]') and t[VIEW].count("refresh(importSessions: usage.enabled)") >= 3,
     VIEW, 'importSessions ? ["cos-usage"] : ["cos-usage", "--read-only"]', '["cos-usage"]'),
    ("COS cost's way back is Usage's own Resume",
     lambda t: once(t[VIEW], 'Button("Resume tracking") { usage.resume() }') and "usage.enabled = true" not in t[VIEW] and once(t[VIEW], ".task(id: usage.enabled) { await store.keepFresh(usage: usage) }"),
     VIEW, 'Button("Resume tracking") { usage.resume() }', 'Button("Resume tracking") { usage.enabled = true }'),
    ("COS cost reads Usage's state from the one rule",
     lambda t: once(t[VIEW], "P.usageState(tracking: usage.enabled, report: usage.report)"), VIEW, "P.usageState(tracking: usage.enabled, report: usage.report)", "P.UsageState.ready"),
    ("the denominator asks whether Usage holds Cursor, not just the switch",
     lambda t: once(t[VIEW], "cursorFeedOn: P.usageHoldsCursor(feedOn: usage.cursorEnabled, usage: usage.report, report: report)"),
     VIEW, "cursorFeedOn: P.usageHoldsCursor(feedOn: usage.cursorEnabled, usage: usage.report, report: report)", "cursorFeedOn: usage.cursorEnabled"),
    ("a paused page does not say it is still reading",
     lambda t: once(t[VIEW], "if usage.enabled && report.sessions.stillReading > 0 {"), VIEW, "if usage.enabled && report.sessions.stillReading > 0 {", "if report.sessions.stillReading > 0 {"),
    ("the COS cost command finds Node the same way",
     lambda t: t[HELPER].count("findCompressedLogNode(for: collector)") == 2, HELPER, "            findCompressedLogNode(for: collector)\n            let environment = serverEnvironment()", "            let environment = serverEnvironment()"),
    ("the calendar draws what fits",
     lambda t: once(t[VIEW], "P.calendarFit(weeks, width: Double(gridWidth))") and t[VIEW].count("ForEach(fit.weeks)") == 2 and "ForEach(weeks)" not in t[VIEW],
     VIEW, "ForEach(fit.weeks) { week in\n                        Color.clear", "ForEach(weeks) { week in\n                        Color.clear"),
]

failed = [name for name, check, *_ in PINS if not check(texts)]
if failed:
    sys.exit("usage wiring pin FAILED: " + "; ".join(failed))
proved = 0
for name, check, target, old, new in PINS:
    if texts[target].count(old) != 1:
        sys.exit(f"usage wiring pin '{name}': its mutation targets {texts[target].count(old)} sites")
    if check({**texts, target: texts[target].replace(old, new)}):
        sys.exit(f"usage wiring pin '{name}' still passes after its own mutation")
    proved += 1
print(f"usage wiring pins: {len(PINS)} passed, {proved} proved")
