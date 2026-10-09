#!/usr/bin/env python3
"""2026-10-09 (Miles, 13:09, like Vorssant): where the What's New window is wired. Each failure names its behaviour as
"pin failed [<behaviour>]" for Tests/mutate-whats-new.py.

    python3 Tests/whats-new-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
views = (root / "Sources/Views.swift").read_text(encoding="utf-8")
model = (root / "Sources/ControllerModel.swift").read_text(encoding="utf-8")
app = (root / "Sources/COSControlApp.swift").read_text(encoding="utf-8")
helper = (root / "HelperSources/main.swift").read_text(encoding="utf-8")
run_sh = (root / "Tests/run.sh").read_text(encoding="utf-8")


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def code(text):
    return "\n".join(line for line in text.split("\n") if not line.strip().startswith("//") and not line.strip().startswith("///"))


def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


# The banner's Update and Try again open What's New; the small confirmation alert is gone.
banner = code(between(views, "@ViewBuilder private var updateBanner", "private var footer"))
pin("model.presentWhatsNew()" in banner, "banner opens", "the banner's Update (and Try again) opens the What's New window")
pin("confirmInstallAppUpdate" not in views and "Install and reopen" not in views and 'Install COS Control \\(' not in views,
    "confirm alert gone", "the small Install COS Control alert is replaced by the window")
pin("installAppUpdate" not in banner, "confirm alert gone", "Update never installs without the window's confirmation")

# The window: one presenter, one window, built once, ordered in only by show.
presenter = code(between(views, "final class WhatsNewWindowPresenter", "struct WhatsNewWindowRoot"))
prepare = presenter.split("func prepare(model: ControllerModel) -> NSWindow {", 1)[-1].split("func show(", 1)[0]
pin(prepare.lstrip().startswith("if let window = controller?.window { return window }"), "single window",
    "a second open hands back the window already made")
pin("window.isReleasedWhenClosed = false" in prepare and "makeKeyAndOrderFront" not in prepare, "single window",
    "the window is kept after Close, and prepare never orders it in")
show = presenter.split("func show(model: ControllerModel) {", 1)[-1].split("func close()", 1)[0]
pin("prepare(model: model)" in show and "makeKeyAndOrderFront" in show, "single window", "show reuses prepare, then brings it forward")
close = presenter.split("func close()", 1)[-1]
pin("installAppUpdate" not in close and "appUpdateFlow" not in close and "busy" not in close, "close does not cancel",
    "closing the window touches nothing of the install")
pin("NSHostingController(rootView: WhatsNewWindowRoot(model: model)" in prepare and "self?.close()" in prepare, "window root",
    "the window hosts WhatsNewWindowRoot, whose Cancel closes it")

# Download and install is the confirmation and runs the existing path.
root_view = code(between(views, "struct WhatsNewWindowRoot: View {", "struct WhatsNewView: View {"))
pin("onInstall: { model.installAppUpdate() }" in root_view, "install path", "Download and install runs installAppUpdate")
pin("flow: model.appUpdateFlow" in root_view and "busy: model.busy" in root_view and "WhatsNewContent(model.appUpdate)" in root_view,
    "window follows the model", "the window shows the model's offer, flow and busy")
window_view = code(between(views, "struct WhatsNewView: View {", "private struct WhatsNewButtonStyle"))
pin("Button(title, action: onInstall)" in window_view and ".disabled(!footer.primaryEnabled)" in window_view, "footer buttons",
    "the primary button installs and disables while it cannot")
pin("Button(footer.cancelTitle, action: onCancel)" in window_view and ".disabled(!footer.cancelEnabled)" in window_view, "footer buttons",
    "Cancel closes and disables while an install runs")
pin("WhatsNewFooter(flow.phase, busy: busy)" in window_view, "footer buttons", "the footer follows the flow's phase")
pin("WhatsNewFooter.reassurance" in window_view and "WhatsNewFooter.closeNote" in window_view, "footer copy",
    "the line under the buttons, and the close note while installing")
pin("ScrollView" in window_view and window_view.index("ScrollView") < window_view.index("footerBar(footer)"), "layout",
    "the body scrolls and the footer is pinned under it")
# No eyebrow kickers: headings are sentence case, never tracked caps.
for banned in (".tracking(", ".kerning(", ".textCase(", "uppercased()"):
    pin(banned not in window_view, "no eyebrow kickers", f"the What's New view must not use {banned}")
for literal in re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', window_view):
    pin("—" not in literal and "→" not in literal and "->" not in literal, "no em dashes", f"copy: {literal}")

# Who opens it: the app wires the presenter; Check for updates opens it when it finds an update; background checks never.
pin("model.showWhatsNew = { whatsNewWindow.show(model: model) }" in code(app), "app wires window", "COSControlApp gives the model its window")
present = code(between(model, "func presentWhatsNew() {", "func installAppUpdate()"))
pin("showWhatsNew?()" in present, "banner opens", "presentWhatsNew opens the window")
manual = code(between(model, "func checkForAppUpdateManually()", "func completeAppUpdateIfNeeded()"))
pin("if appUpdateFlow.phase == .ready { presentWhatsNew() }" in manual, "check for updates opens",
    "Check for updates that finds an update opens What's New")
background = code(between(model, "    func checkForAppUpdate() async {", "func panelOpenedForUpdates"))
pin("presentWhatsNew" not in background and "showWhatsNew" not in background, "background check", "a background check never opens a window")

# The helper passes whatsNew through check-app-update only after cleaning it.
check_verb = code(between(helper, "private func emitAppUpdateCheck(args: [String]) throws {", "static func macOSAtLeast"))
pin('if let whatsNew = Self.sanitizedWhatsNew(stable["whatsNew"]) { details["whatsNew"] = whatsNew }' in check_verb, "helper whatsNew",
    "check-app-update passes the stable channel's whatsNew, cleaned")
pin('stable["whatsNew"]' not in check_verb.replace('Self.sanitizedWhatsNew(stable["whatsNew"])', ""), "helper whatsNew",
    "whatsNew never reaches details uncleaned")

# The gate runs it.
pin('"$ROOT/Tests/run-whats-new.sh"' in run_sh, "gate", "Tests/run.sh runs the What's New gate")
print("PASS: What's New pins")
