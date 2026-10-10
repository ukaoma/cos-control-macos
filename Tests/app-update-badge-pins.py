#!/usr/bin/env python3
"""2026-10-09 (Miles, like Vorssant): where the update-ready badge is wired. Each failure names its behaviour as
"pin failed [<behaviour>]" for Tests/mutate-app-update-badge.py.

    python3 Tests/app-update-badge-pins.py <root>
"""
import pathlib, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
views = (root / "Sources/Views.swift").read_text(encoding="utf-8")
model = (root / "Sources/ControllerModel.swift").read_text(encoding="utf-8")
app = (root / "Sources/COSControlApp.swift").read_text(encoding="utf-8")


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def code(text):
    return "\n".join(line for line in text.split("\n") if not line.strip().startswith("//"))


panel = code(views[views.index("private var mainPanel"):views.index("private var activityLauncher")])
opening = "VStack(alignment: .leading, spacing: 14) {"
pin(opening in panel and panel.split(opening, 1)[1].lstrip().startswith("updateBanner"), "banner first",
    "the update banner must be the first thing in the panel, above the header")
pin("updateRow" not in views and 'Button("Check for updates"' not in views, "version card",
    "the standing version card is gone (2026-10-09); the header's refresh button checks instead")
banner = views.split("private var updateBanner")[1].split("private var footer")[0]
pin("if model.appUpdateFlow.showsBanner {" in banner and "model.presentWhatsNew()" in banner, "update path",
    "Update and Try again open the What's New window (2026-10-09; it replaced the install confirmation alert)")
pin("onInstall: { model.installAppUpdate() }" in views, "update path",
    "What's New's Download and install runs installAppUpdate (stage-app-update, then apply-app-update)")
pin("model.panelOpenedForUpdates()" in code(views), "panel open check", "opening the panel asks the schedule for a check")
init = model[model.index("updateCheckTask = Task { [weak self] in"):]
init = code(init[:init.index("loadPetDismissals()")])
pin("runScheduledAppUpdateCheck(.launch)" in init and "runScheduledAppUpdateCheck(.periodic)" in init
    and "nextNap(now: Date())" in init, "background checks", "launch and periodic checks go through the schedule")
install = code(model[model.index("func installAppUpdate()"):model.index("func openUpdatePage()")])
for needle, behaviour in (("appUpdateFlow.beginInstall()", "install phases"), ("appUpdateFlow.progress(message)", "install phases"),
                          ("appUpdateFlow.staged()", "install phases"), ("appUpdateFlow.fail(", "install phases"),
                          ('"stage-app-update"', "update path"), ('"apply-app-update"', "update path")):
    pin(needle in install, behaviour, f"installAppUpdate must call {needle}")
pin("didSet { appUpdateFlow.offer(appUpdate," in model, "model wiring", "every write of appUpdate moves the flow")
manual = code(model[model.index("func checkForAppUpdateManually("):model.index("func completeAppUpdateIfNeeded()")])
pin("appUpdateSchedule.begin(.manual" in manual and "if holdsSlot { appUpdateSchedule.finish() }" in manual
    and "while " not in manual.split("var holdsSlot", 1)[-1].split("do {", 1)[0], "no overlap",
    "Check for updates waits once for a running check, holds the slot while it runs, and never loops on it")
scheduled = code(model[model.index("func runScheduledAppUpdateCheck"):model.index("func panelOpenedForUpdates")])
child = scheduled.split("let check = Task", 1)[1].split("appUpdateCheckRunning = check", 1)[0]
pin("self?.appUpdateSchedule.finish()" in child and "self?.appUpdateCheckRunning = nil" in child, "slot freed in task",
    "the background check frees its slot inside its task, before its value resolves")
pin("timeout: AppUpdateCheckSchedule.helperTimeout" in manual, "check timeout", "the manual check is bounded")
background = code(model[model.index("    func checkForAppUpdate() async {"):model.index("func runScheduledAppUpdateCheck")])
pin("timeout: AppUpdateCheckSchedule.helperTimeout" in background, "check timeout", "the background check is bounded")
label = code(app[app.index("} label: {"):app.index(".menuBarExtraStyle")])
ready = label.split("if variant == .updateReady {", 1)[-1].split("} else {", 1)[0]
pin("MenuBarIcon.variant(for: model.appUpdateFlow.phase)" in label and "MenuBarIcon.image(systemName:" in ready
    and ".original" in ready, "icon follows state", "the menu-bar label draws the variant of the flow, as itself when ready")
pin("appUpdate.shouldSurface" not in label, "icon follows state", "the label reads the flow, not the raw check result")
print("PASS: update-ready badge pins")
