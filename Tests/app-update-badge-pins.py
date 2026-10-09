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
row = views.split("private var updateRow")[1].split("private var updateBanner")[0]
pin("if !model.appUpdateFlow.showsBanner {" in row and 'Button("Check for updates"' in row, "version card",
    "the version card (Check for updates) shows exactly when the banner does not")
banner = views.split("private var updateBanner")[1].split("private var footer")[0]
pin("if model.appUpdateFlow.showsBanner {" in banner and "confirmInstallAppUpdate = true" in banner, "update path",
    "Update and Try again open the existing install confirmation")
pin(".normal(\"Install and reopen\") { model.installAppUpdate() }" in views, "update path",
    "the confirmation runs installAppUpdate (stage-app-update, then apply-app-update)")
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
manual = code(model[model.index("func checkForAppUpdateManually()"):model.index("func completeAppUpdateIfNeeded()")])
pin("appUpdateSchedule.begin(.manual" in manual and "appUpdateSchedule.finish()" in manual, "no overlap",
    "Check for updates waits for a running check and holds the slot while it runs")
pin("timeout: AppUpdateCheckSchedule.helperTimeout" in manual, "check timeout", "the manual check is bounded")
background = code(model[model.index("    func checkForAppUpdate() async {"):model.index("func runScheduledAppUpdateCheck")])
pin("timeout: AppUpdateCheckSchedule.helperTimeout" in background, "check timeout", "the background check is bounded")
label = code(app[app.index("} label: {"):app.index(".menuBarExtraStyle")])
ready = label.split("if variant == .updateReady {", 1)[-1].split("} else {", 1)[0]
pin("MenuBarIcon.variant(for: model.appUpdateFlow.phase)" in label and "MenuBarIcon.image(systemName:" in ready
    and ".original" in ready, "icon follows state", "the menu-bar label draws the variant of the flow, as itself when ready")
pin("appUpdate.shouldSurface" not in label, "icon follows state", "the label reads the flow, not the raw check result")
print("PASS: update-ready badge pins")
