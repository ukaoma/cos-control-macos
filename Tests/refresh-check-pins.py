#!/usr/bin/env python3
"""2026-10-09 (Miles, after the 0.5.276 gold banner): the version card is gone; the panel header's refresh button
refreshes AND checks for updates, the subtitle line answers, and a small version stamp sits after the title. Each
failure names its behaviour as "pin failed [<behaviour>]" for Tests/mutate-refresh-check.py.

    python3 Tests/refresh-check-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
views = (root / "Sources/Views.swift").read_text(encoding="utf-8")
model = (root / "Sources/ControllerModel.swift").read_text(encoding="utf-8")
models = (root / "Sources/Models.swift").read_text(encoding="utf-8")


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def code(text):
    return "\n".join(line for line in text.split("\n") if not line.strip().startswith("//") and not line.strip().startswith("///"))


def body(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i + len(start))]


# The version card is gone, and nothing renders a Check for updates button in the panel any more.
pin("updateRow" not in views, "card gone", "updateRow (the standing version card) no longer exists")
pin('Button("Check for updates"' not in views, "card gone", "no Check for updates button is left in the panel")

# The header's refresh button runs both the status refresh and the manual check.
header = code(body(views, "    private var header: some View {", "\n    }\n"))
pin("refreshAndCheckButton" in header, "header button", "the header renders the refresh-and-check button")
button = code(body(views, "    private var refreshAndCheckButton: some View {", "\n    }\n"))
pin("model.refreshAndCheckForUpdates()" in button, "both actions", "the refresh button runs refreshAndCheckForUpdates")
pin('Image(systemName: "arrow.clockwise")' in button, "header button", "it is the arrow.clockwise refresh button")
pin('.help("Refresh status and check for updates")' in button, "button help", "help text")
pin('.accessibilityLabel("Refresh status and check for updates")' in button, "button help", "a matching accessibility label")
both = code(body(model, "    func refreshAndCheckForUpdates() async {", "\n    }\n"))
pin("self.refresh()" in both and "checkForUpdatesFromHeader()" in both, "both actions",
    "refreshAndCheckForUpdates runs refresh() AND the header's update check")
fromHeader = code(body(model, "    func checkForUpdatesFromHeader() async {", "\n    }\n"))
pin("checkForAppUpdateManually(reportsInHeader: true)" in fromHeader, "both actions",
    "the header's check is the manual check (its waiting logic for a running background check included)")
pin("guard !updateCheckInFlight else { return }" in fromHeader, "no second check",
    "a click while a check runs starts nothing and leaves the line alone")
manual = code(body(model, "    func checkForAppUpdateManually(", "\n    /// Close the handshake"))
pin("guard !updateCheckInFlight else { return .skipped }" in manual, "no second check", "never two manual checks at once")
show = code(body(model, "    private func showHeaderUpdateStatus(", "\n    }\n"))
pin(show.index("headerUpdateStatusReset?.cancel()") < show.index("headerUpdateStatus = next"), "no stacked timers",
    "a new result cancels the previous reset before it shows")
pin("Task.isCancelled" in show and "Task.sleep(for: hold)" in show, "no stacked timers", "the reset is a cancellable task")

# The subtitle shows the three transient strings, through the line both titles use.
for words in ('static let checkingText = "Checking for updates…"', 'static let upToDateText = "Up to date"',
              'static let failedText = "Couldn\'t check for updates"'):
    pin(models.count(words) == 1, "subtitle words", f"Models.swift names {words} once (HeaderUpdateStatus)")
line = code(body(views, "    private func updateStatusLine(", "\n    }\n"))
pin("HeaderUpdateStatus.shown(inFlight: model.updateCheckInFlight, status: model.headerUpdateStatus)" in line, "subtitle words",
    "the line reads Checking while any manual check runs, else the header's last result")
pin("reduceMotion ? nil :" in line, "reduce motion", "no animation under Reduce Motion")
pin('updateStatusLine(idle: "Your local glasses server")' in header, "subtitle words", "the header's subtitle is the status line")
pin('"Up to date · ' not in models and "COS Control \\(" not in body(models, "enum HeaderUpdateStatus", "\n}\n"), "subtitle words",
    "Up to date stands alone: the version is the stamp's")
# Settings in Activity had the version card as its only manual check: it keeps one.
main_panel = code(body(views, "    private var mainPanel: some View {", "\n    }\n"))
settings = main_panel.split("if hostedInActivity {", 1)[1].split("} else { header }", 1)[0]
pin("refreshAndCheckButton" in settings and "updateStatusLine(idle:" in settings, "settings entry",
    "Settings in Activity keeps the refresh-and-check button and its status line")

# The version stamp: inline after the title, live currentVersion, no literal, mono 9, labelled.
stamp = code(body(views, "    private var versionStamp: some View {", "\n    }\n"))
pin('Text("v\\(ControllerModel.currentVersion)")' in stamp, "stamp live version", "the stamp reads ControllerModel.currentVersion")
pin(re.search(r'\d+\.\d+\.\d+', stamp) is None, "stamp live version", "no hard-coded version literal in the stamp")
pin("COSType.mono(9)" in stamp, "stamp type", "mono 9")
pin('.help("COS Control \\(ControllerModel.currentVersion)")' in stamp, "stamp label", "help tooltip")
pin('.accessibilityLabel("COS Control version \\(ControllerModel.currentVersion)")' in stamp, "stamp label", "accessibility label")
pin("background(" not in stamp and "overlay(" not in stamp and "Capsule" not in stamp and "stroke" not in stamp,
    "stamp type", "no chip, pill, border or background")
# Miles 2026-10-09 22:55 ("Lets go with B"): inline after the title, on its baseline. One layout, no flag.
title = re.search(r'HStack\(alignment: \.firstTextBaseline, spacing: 6\) \{\s*Text\("Control"\)\.font\(COSType\.display\(18, weight: \.semibold\)\)\s*versionStamp\s*\}', header)
pin(title is not None, "stamp placement", "the stamp sits inline after the Control title, on its first-text baseline")
pin(header.count("versionStamp") == 1, "stamp placement", "the header renders the stamp exactly once")
pin("versionStampInline" not in views, "stamp placement", "no second layout and no flag")
lockup_at = header.index("COSLockupView(height: 17)")
pin("VStack" not in header[:lockup_at], "stamp placement", "the lockup stands alone, nothing stacked under it")

# The footer still names the Control version.
footer = code(body(views, "    private var footerLabel: String {", "\n    }\n"))
pin("ControllerModel.currentVersion" in footer and '"Controller \\(controller)' in footer, "footer version",
    "the footer label still names the Control version")
print("PASS: refresh-check pins")
