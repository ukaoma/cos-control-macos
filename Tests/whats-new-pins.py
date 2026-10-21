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
manual = code(between(model, "func checkForAppUpdateManually(", "func completeAppUpdateIfNeeded()"))
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
# 0.5.334: 0.5.333's first build shipped a What's New whose version still said 0.5.332, so the after-update window (which
# shows the bundled copy only when its version is the running one) fell back to the appcast words. The notes must name
# the build they ship in.
import json, plistlib
notes_version = json.loads((root / "Resources/WhatsNew.json").read_text(encoding="utf-8")).get("version")
bundle_version = plistlib.loads((root / "Resources/Info.plist").read_bytes()).get("CFBundleShortVersionString")
pin(isinstance(notes_version, str) and notes_version == bundle_version, "notes version",
    f"Resources/WhatsNew.json version {notes_version!r} must equal Info.plist CFBundleShortVersionString {bundle_version!r}")

# The helper never says a stage staged when it did not, and apply proves the stage before Control quits.
stage_verb = code(between(helper, "private func emitStageAppUpdate(args: [String]) throws {", "private func bundleHasRunningProcess"))
pin(stage_verb.count("emit(ok: true") == 1 and 'details["reason"] = "staged"' in stage_verb, "stage refuses",
    "stage-app-update answers ok only after it staged")
apply_verb = code(between(helper, "private func emitApplyAppUpdate(args: [String]) throws {", "private func swapStagedApp"))
detach = apply_verb.split('guard args.contains("--detach")', 1)[1]
pin("_ = try requireStagedUpdate(expectedBuild: expectedBuild)" in detach
    and detach.index("requireStagedUpdate") < detach.index("spawnDetached"), "apply needs a stage", "apply --detach proves the stage before it spawns")
pin('childArgs += ["--expected-build", String(expectedBuild)]' in detach, "apply expected build", "the detached swap gets the build too")

# QA round 2: a swap that refuses waits for the old Control to quit before reopening it.
swap = code(between(helper, "private func swapStagedApp(live: URL, expectedBuild: Int?) throws {", "private func emitCompleteAppUpdate"))
for marker in ('"reason": "notStaged"', '"reason": "busy"'):
    part = swap.split(marker, 1)[1]
    pin("waitForLiveToQuit(live)" in part and part.index("waitForLiveToQuit(live)") < part.index('"/usr/bin/open"'), "swap waits",
        f"after {marker}, wait for the old Control to quit, then reopen it")
begin = code(between(model, "func beginPostUpdateWhatsNew() {", "func considerPostUpdateWhatsNew()"))
pin("WhatsNewAfterUpdate.updaterBuild(try? Data(contentsOf: updateSuccessRecord))" in begin and "installedByUpdater: updater" in begin,
    "after update updater", "the launch decision reads the updater's success record")

# The helper passes whatsNew through check-app-update only after cleaning it.
check_verb = code(between(helper, "private func emitAppUpdateCheck(args: [String]) throws {", "static func macOSAtLeast"))
pin('if let whatsNew = Self.sanitizedWhatsNew(stable["whatsNew"]) { details["whatsNew"] = whatsNew }' in check_verb, "helper whatsNew",
    "check-app-update passes the stable channel's whatsNew, cleaned")
pin('stable["whatsNew"]' not in check_verb.replace('Self.sanitizedWhatsNew(stable["whatsNew"])', ""), "helper whatsNew",
    "whatsNew never reaches details uncleaned")

# 0.5.283 (the polish round's Mac What's New board): COS styling, light and dark, never a white slab. Every color in the
# window is an adaptive palette token, so it follows the system appearance live.
styled = code(between(views, "struct WhatsNewView: View {", "struct ControlPanel: View {"))
for banned in (".white", "NSColor.white", "Color(red:", "Color(nsColor:", "Color(hex", ".preferredColorScheme(", ".colorScheme(", "NSAppearance"):
    pin(banned not in styled, "palette tokens", f"the What's New window must not use {banned}; colors come from COSPalette")
pin("window.backgroundColor = COSInk.panelNS" in presenter and "COSInk.cardNS" not in presenter and "appearance" not in presenter,
    "palette tokens", "the window backing is the adaptive cream panel, and it never forces an appearance")
pin(".background(COSPalette.panel)" in window_view.split("private func footerBar", 1)[0], "palette tokens", "the window body is the panel")
section_view = code(between(views, "private struct WhatsNewSection", "private struct WhatsNewBullet"))
pin(".background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))" in section_view, "palette tokens",
    "each section sits on a card (white light, raised espresso dark)")
pin("COSType.display(" in section_view and "COSType.display(" in window_view.split("ScrollView", 1)[0], "brand type",
    "headings and the title are Fraunces")
pin("COSType.mono(" in window_view.split("ScrollView", 1)[0] and "if let byline = presentation.byline" in window_view, "brand type",
    "the version line is JetBrains Mono")
button_view = code(between(views, "private struct WhatsNewButtonStyle", "struct ControlPanel: View {"))
pin("prominent ? COSPalette.onAccent" in button_view and "prominent ? COSPalette.accent" in button_view, "accent button",
    "the primary button is the accent gold with onAccent words")
pin("COSPalette.border" in button_view and "Color.clear" in button_view, "accent button", "the secondary button is bordered, no fill")
# Text contrast >= 4.5:1, computed from the token values themselves (WCAG 2 relative luminance), light and dark.
ink_block = between(views, "private enum COSInk {", "\n}\n")
def token(name):
    m = re.search(name + r"NS = adaptiveNSColor\(\s*light:\s*NSColor\(red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), alpha: 1\),[^\n]*\n\s*dark:\s*NSColor\(red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), alpha: 1\)", ink_block)
    pin(m is not None, "contrast", f"cannot read the {name} token")
    v = [float(x) for x in m.groups()]
    return {"light": v[:3], "dark": v[3:]}
def luminance(rgb):
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
def ratio(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)
panel, card, subtle, accent, on_accent, raised = (token(n) for n in ("panel", "card", "subtle", "accent", "onAccent", "raised"))
for mode in ("light", "dark"):
    for words, ground, what in ((subtle, panel, "the build line and footer note on the panel"), (on_accent, accent, "the primary button's words"),
                                (accent, card, "the bullet dots and hover words on a card"), (subtle, raised, "secondary words on a raised strip")):
        r = ratio(words[mode], ground[mode])
        pin(r >= 4.5, "contrast", f"{what} in {mode} is {r:.2f}:1, under 4.5:1")

# The gate runs it.
pin('"$ROOT/Tests/run-whats-new.sh"' in run_sh, "gate", "Tests/run.sh runs the What's New gate")
print("PASS: What's New pins")
