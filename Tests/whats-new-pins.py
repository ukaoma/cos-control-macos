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
release = (root / "scripts/build-release.sh").read_text(encoding="utf-8")


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
pin("if !window.isVisible { window.center() }" in show and show.index("window.center()") < show.index("makeKeyAndOrderFront"), "recenter",
    "a reopen is centered again when the window is not on screen")
close = presenter.split("func close()", 1)[-1]
pin("installAppUpdate" not in close and "appUpdateFlow" not in close and "busy" not in close, "close does not cancel",
    "closing the window touches nothing of the install")
pin("NSHostingController(rootView: WhatsNewWindowRoot(model: model)" in prepare and "self?.close()" in prepare, "window root",
    "the window hosts WhatsNewWindowRoot, whose Cancel closes it")

# Download and install is the confirmation and runs the existing path.
root_view = code(between(views, "struct WhatsNewWindowRoot: View {", "struct WhatsNewView: View {"))
pin("onInstall: { model.installAppUpdate() }" in root_view, "install path", "Download and install runs installAppUpdate")
pin("WhatsNewPresentation.present(model.whatsNewMode, info: model.appUpdate, flow: model.appUpdateFlow," in root_view
    and "frozen: model.whatsNewFrozen, busy: model.busy)" in root_view,
    "window follows the model", "the window shows the model's mode, offer, flow, frozen words and busy")
window_view = code(between(views, "struct WhatsNewView: View {", "private struct WhatsNewButtonStyle"))
pin("Button(title, action: onInstall)" in window_view and ".disabled(!footer.primaryEnabled)" in window_view, "footer buttons",
    "the primary button installs and disables while it cannot")
pin("Button(footer.cancelTitle, action: onCancel)" in window_view and ".disabled(!footer.cancelEnabled)" in window_view, "footer buttons",
    "Cancel and Close follow the footer's enabled state")
pin("let footer = presentation.footer" in window_view, "footer buttons", "the footer is the presentation's")
pin("WhatsNewFooter.reassurance" in window_view and "WhatsNewFooter.closeNote" in window_view and "if footer.showsReassurance {" in window_view,
    "footer copy", "the line under the buttons, and the close note while installing")
pin("Text(verbatim: presentation.title)" in window_view and "Text(verbatim: presentation.byline" not in window_view
    and "if let byline = presentation.byline" in window_view, "title names the release",
    "the version is in the title and the build is a byline, not an accent line above Summary")
pin("releaseLine" not in views and "releaseLine" not in (root / "Sources/Models.swift").read_text(encoding="utf-8"), "title names the release",
    "the old accent version line is gone")
# Return never installs; every string is drawn verbatim (no Markdown, no links).
pin(".keyboardShortcut(.defaultAction)" not in window_view, "return never installs", "Download and install is never the default action")
for banned in ("LocalizedStringKey", "Text(.init(", "AttributedString(markdown", "Link("):
    pin(banned not in window_view, "verbatim text", f"the What's New view must not use {banned}")
for needle in ("Text(verbatim: content.summaryText)", "Text(verbatim: status)", "Text(verbatim: title)", "Text(verbatim: text)"):
    pin(needle in window_view, "verbatim text", f"appcast and helper words are drawn verbatim: {needle}")
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
background = code(between(model, "    func checkForAppUpdate() async {", "private func noteCheckReached"))
scheduled = code(between(model, "func runScheduledAppUpdateCheck", "func panelOpenedForUpdates"))
pin("presentWhatsNew" not in background + scheduled and "showWhatsNew" not in background + scheduled, "background check",
    "a background check never opens the offer window")
after = code(between(model, "func considerPostUpdateWhatsNew() {", "func runScheduledAppUpdateCheck"))
pin("presentWhatsNew" not in after and "whatsNewMode = .installed(" in after, "after update show",
    "the after-update window is the installed one, never an offer")

banner_struct = code(between(views, "struct AppUpdateBanner: View {", "var body: some View"))
pin("notes" not in banner_struct, "dead param", "AppUpdateBanner has no unused notes parameter")

# QA 2026-10-09 (live in 0.5.274): nothing is applied unless the stage proves it staged the offered build.
install = code(between(model, "func installAppUpdate() {", "func openUpdatePage()"))
gate = install.index("if let refusal = AppUpdateStageCheck.refusal(staged.details, offeredBuild: offeredBuild) {")
pin(gate < install.index("appUpdateFlow.staged()") < install.index('"apply-app-update"'), "stage check",
    "the stage check runs before applying")
refused = install[gate:install.index("appUpdateFlow.staged()")]
pin("appUpdateFlow.fail(refusal)" in refused and "return" in refused and "terminate" not in refused, "stage check",
    "a refused stage fails in words and returns, never applies or quits")
pin('apply += ["--expected-build", String(stagedBuild)]' in install, "stage check build", "apply names the staged build")
pin("whatsNewFrozen = WhatsNewContent(appUpdate)" in install, "presentation frozen", "the words are frozen when an install starts")
# The after-update window.
init_block = code(between(model, "        guard startBackgroundWork else { return }", "try? Self.pruneMediaHandoffs()"))
pin("whatsNewSeen = WhatsNewSeenStore(defaults: .standard)" in init_block and "beginPostUpdateWhatsNew()" in init_block, "after update launch",
    "the app remembers builds in UserDefaults and decides at launch (never in a test model)")
refresh = code(between(model, "func refresh(quiet: Bool = false) async {", "func "))
pin("considerPostUpdateWhatsNew()" in refresh, "after update meeting", "every status refresh asks again, so a window held for a meeting shows after it")
pin("noteCheckReached(incoming)" in background and "noteCheckReached(incoming)" in manual, "after update show",
    "both checks tell the after-update window the feed answered")
pin('cp "$ROOT/Resources/WhatsNew.json" "$APP/Contents/Resources/"' in release, "bundled notes", "the release ships this build's own What's New")

# The helper never says a stage staged when it did not, and apply proves the stage before Control quits.
stage_verb = code(between(helper, "private func emitStageAppUpdate(args: [String]) throws {", "private func bundleHasRunningProcess"))
pin(stage_verb.count("emit(ok: true") == 1 and 'details["reason"] = "staged"' in stage_verb, "stage refuses",
    "stage-app-update answers ok only after it staged")
apply_verb = code(between(helper, "private func emitApplyAppUpdate(args: [String]) throws {", "private func swapStagedApp"))
detach = apply_verb.split('guard args.contains("--detach")', 1)[1]
pin("_ = try requireStagedUpdate(expectedBuild: expectedBuild)" in detach
    and detach.index("requireStagedUpdate") < detach.index("spawnDetached"), "apply needs a stage", "apply --detach proves the stage before it spawns")
pin('childArgs += ["--expected-build", String(expectedBuild)]' in detach, "apply expected build", "the detached swap gets the build too")

# The helper passes whatsNew through check-app-update only after cleaning it.
check_verb = code(between(helper, "private func emitAppUpdateCheck(args: [String]) throws {", "static func macOSAtLeast"))
pin('if let whatsNew = Self.sanitizedWhatsNew(stable["whatsNew"]) { details["whatsNew"] = whatsNew }' in check_verb, "helper whatsNew",
    "check-app-update passes the stable channel's whatsNew, cleaned")
pin('stable["whatsNew"]' not in check_verb.replace('Self.sanitizedWhatsNew(stable["whatsNew"])', ""), "helper whatsNew",
    "whatsNew never reaches details uncleaned")

# The gate runs it.
pin('"$ROOT/Tests/run-whats-new.sh"' in run_sh, "gate", "Tests/run.sh runs the What's New gate")
print("PASS: What's New pins")
