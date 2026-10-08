#!/usr/bin/env python3
"""Pins for the permission guide's wiring in the app. The behaviour is in Tests/PermissionGuideChecks.swift; these say
the app calls it where it should. Each failure names what broke: "pin failed [<behaviour>]".

    python3 Tests/permission-guide-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
read = lambda p: (root / p).read_text(encoding="utf-8")
model, views, setup = read("Sources/ControllerModel.swift"), read("Sources/Views.swift"), read("Sources/ControlSetup.swift")
flow, vendored, guide_views = read("Sources/PermissionDragFlow.swift"), read("Sources/PermissionFlowVendored.swift"), read("Sources/PermissionGuideViews.swift")
system, guide = read("Sources/PermissionGuideSystem.swift"), read("Sources/PermissionGuideModel.swift")
failed = []

def pin(ok, behaviour, why):
    if not ok:
        failed.append(f"pin failed [{behaviour}]: {why}")

def body(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i + len(start))]

# The drag source is the running bundle.
make = body(model, "    private func makePermissionGuide() -> PermissionGuide {", "\n    }\n")
pin("let bundleURL = Bundle.main.bundleURL.standardizedFileURL" in make and "appPath: bundleURL.path" in make, "drag source", "the guide is given the RUNNING bundle")
pin("probes: inApp ? .live() : .inert" in make and "&& backgroundWorkEnabled" in make, "live probes", "a model built by a check reads nothing from macOS")
pin("guide.startDragFlow = { [weak self] request in self?.permissionDragFlow.start(request) }" in make, "drag flow wiring", "rows start the drag flow")
pin("permissionDragFlow.guide = guide" in make, "drag flow wiring", "the flow reports grants to the guide")

# Just-in-time hooks.
init = body(model, "    init(startBackgroundWork: Bool = true", "\n    }\n")
pin(init.index("guard startBackgroundWork else { return }") < init.index("startPermissionWatch()"), "background jobs hook", "the watch runs only with background work")
watch = body(model, "    private func startPermissionWatch() {", "\n    }\n")
pin('need(.backgroundJobs, for: "Your scheduled COS jobs", interactive: false)' in watch, "background jobs hook", "exit 78 opens the guide in the panel, never a window")
pin("stopped != self.backgroundJobsNeedSignature" in watch, "background jobs hook", "only a NEW set of stopped jobs reopens the card")
meeting = body(model, "private func loadMeetingAlertPermission() async {", "\n    func ")
pin('permissionGuide.need(.notifications, for: "Meeting alerts", interactive: false)' in meeting, "meeting alerts hook", "a live meeting with alerts off opens the guide on Notifications")
pin(meeting.index("if off != meetingAlertsOff {") < meeting.index('for: "Meeting alerts"'), "meeting alerts hook", "only when alerts turn off, not every check")
work = body(model, "    private func postWorkNotice(", "    func openWorkItem(")
pin('for: "Work updates"' in work and "guard !workNotificationPermissionChecked else { return }" in work, "work notifications hook", "the first Work notice checks Notifications once per launch")
pin(work.index("meetingAudioNotifier.postWork(notice)") < work.index("workNotificationPermissionChecked = true"), "work notifications hook", "the notice is posted first; the check never delays it")

# The pet jump: the gate hands the row to the guide, and the jump that asked runs again after the grant.
opener = body(model, "    private func openAccessibilitySettings() {", "\n    }\n")
pin('permissionGuide.need(.accessibility, for: "Jump to your session", resume: resume)' in opener, "pet jump hook", "opening the Accessibility pane is the guide's drag flow")
pin("let resume = accessibilityResume" in opener and "accessibilityResume = nil" in opener, "pet jump hook", "the waiting jump is handed to the guide once")
pin(opener.index("if permissionGuideLive {") < opener.index("NSWorkspace.shared.open(url)"), "pet jump hook", "a bare link only where the guide cannot run")
for head, call in (("    private func revealClaudeSession(", "await self?.revealClaudeSession("), ("    private func revealCursorAgentsWindow(", "await self?.revealCursorAgentsWindow(")):
    fn = model[model.index(head):]
    fn = fn[:fn.index("guard ensureAccessibilityTrust() else { return }") + 10]
    pin("accessibilityResume = { [weak self] in" in fn and call in fn, "pet jump resume", f"{head.strip()} sets its resume before the gate")
gate = body(model, "    private func ensureAccessibilityTrust() -> Bool {", "\n    }\n")
pin("if !trusted && !permissionGuideLive {" in gate, "pet jump hook", "in the app the guide asks, not a second system prompt")
pin('guide.resetOwnAccessibility = { [weak self] in self?.resetAccessibilityAndAddAgain() }' in make, "repair wiring", "Reset and add again reuses the 0.5.267 repair")

# Entry points.
main_panel = body(views, "    private var mainPanel: some View {", "    private var activityLauncher")
pin("PanelPermissionsRow(guide: model.permissionGuide)" in main_panel, "panel row", "the panel has a Permissions row")
pin("if guide.panelRouteActive {" in guide_views and "PermissionGuideCard(guide: guide)" in guide_views, "panel route", "the card mounts on its own flag")
pin("ready && !model.permissionGuide.onboardingDone" in setup and "OnboardingPermissionsStep(guide: model.permissionGuide)" in setup, "onboarding step", "Welcome shows Permissions after setup")
step = body(guide_views, "struct OnboardingPermissionsStep: View {", "\n}\n")
pin('Button("Not now")' in step and step.count("guide.onboardingDone = true") == 2, "onboarding step", "skippable, and both buttons finish it")
for name, src in (("PermissionGuideViews.swift", guide_views), ("PermissionDragFlow.swift", flow), ("ControlSetup.swift", setup)):
    pin(".sheet(" not in src and ".popover(" not in src, "no new windows", f"{name} opens no sheet or popover")
pin("NSWindow(" not in guide_views + flow and setup.count("NSWindow(") == 1, "no new windows", "the only window is the existing Welcome window; the bar is the vendored panel")

# Detection.
pin("withTimeInterval: 1, repeats: true" in flow, "detection poll", "AXIsProcessTrusted once a second")
pin('NSNotification.Name("com.apple.accessibility.api")' in flow, "detection hint", "the distributed notification is a hint")
pin("AXIsProcessTrusted() && Self.accessibilityReadWorks()" in flow, "detection confirm", "a real AX read before Allowed")
pin('withBundleIdentifier: "com.apple.dock"' in flow and "kAXRoleAttribute" in flow, "detection confirm", "the read crosses processes")
pin("[.borderless, .nonactivatingPanel]" in vendored and "override var canBecomeKey: Bool { false }" in vendored and "level = .floating" in vendored, "floating bar", "non-activating, floating, never key")
pin("onTrackingEnded" in flow and "tick(settingsOpen: false)" in flow, "floating bar", "closing System Settings closes the bar")

# Vendoring and license.
pin("cb96db4b" in vendored and "MIT License" in vendored and "VENDORED CODE" in vendored, "vendored header", "the vendored file names its source, license and commit")
lic = read("Resources/ThirdParty/PermissionFlow/LICENSE")
pin(lic.startswith("MIT License") and "Permission is hereby granted, free of charge" in lic, "license", "the upstream MIT license ships unchanged")
pin("cb96db4b" in read("Resources/ThirdParty/PermissionFlow/ATTRIBUTION.md") and "PermissionFlow" in read("THIRD_PARTY_NOTICES.md"), "license", "attribution and notice")
release = read("scripts/build-release.sh")
pin('cp -R "$ROOT/Resources/ThirdParty/." "$APP/Contents/Resources/ThirdParty/"' in release, "license", "the license ships inside the app")
pin(not re.search(r"URLSession|NWConnection|http[s]?://(?!github\.com/jaywcjlove)", vendored + flow + guide_views + system + guide), "no network", "the guide makes no network calls")

# Every explicit compile list that has the model also has the guide.
files = ["PermissionGuideModel.swift", "PermissionGuideSystem.swift", "PermissionFlowVendored.swift", "PermissionDragFlow.swift", "PermissionGuideViews.swift"]
for script in list((root / "Tests").glob("*.sh")) + list((root / "scripts").glob("*.sh")):
    text = script.read_text(encoding="utf-8")
    for command in re.findall(r"swiftc[^\n]*(?:\\\n[^\n]*)*", text):
        if '"$ROOT/Sources/ControllerModel.swift"' in command:
            for f in files:
                pin(f'"$ROOT/Sources/{f}"' in command, "source lists", f"{script.name} compiles ControllerModel without {f}")

if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print("PASS: permission guide pins")
