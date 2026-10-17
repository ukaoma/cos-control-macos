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

def ordered(src, *parts):
    """Every part present, in this order. A missing part is a failed pin, never a crash."""
    at = -1
    for part in parts:
        at = src.find(part, at + 1)
        if at < 0:
            return False
    return True

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
pin('for: "Meeting alerts"' in meeting and meeting.index("if off != meetingAlertsOff {") < meeting.index('for: "Meeting alerts"'), "meeting alerts hook", "only when alerts turn off, not every check")
work = body(model, "    private func postWorkNotice(", "    func openWorkItem(")
pin('for: "Work updates"' in work and "guard !workNotificationPermissionChecked else { return }" in work, "work notifications hook", "the first Work notice checks Notifications once per launch")
pin(work.index("meetingAudioNotifier.postWork(notice)") < work.index("workNotificationPermissionChecked = true"), "work notifications hook", "the notice is posted first; the check never delays it")

# The pet jump: the gate hands the row to the guide, and the jump that asked runs again after the grant.
opener = body(model, "    private func openAccessibilitySettings() {", "\n    }\n")
pin('permissionGuide.need(.accessibility, for: feature, resume: resume)' in opener and 'let feature = accessibilityFeature ?? "Jump to your session"' in opener, "pet jump hook", "opening the Accessibility pane is the guide's drag flow, named for the jump unless another feature waits")
pin("accessibilityFeature = nil" in opener, "pet jump hook", "a waiting feature's name is used once")
pin("let resume = accessibilityResume" in opener and "accessibilityResume = nil" in opener, "pet jump hook", "the waiting jump is handed to the guide once")
pin(opener.index("if permissionGuideLive {") < opener.index("NSWorkspace.shared.open(url)"), "pet jump hook", "a bare link only where the guide cannot run")
for head, call in (("    private func revealClaudeSession(", "await self?.revealClaudeSession("), ("    private func revealCursorAgentsWindow(", "await self?.revealCursorAgentsWindow(")):
    fn = model[model.index(head):]
    fn = fn[:fn.index("guard ensureAccessibilityTrust() else { return }") + 10]
    pin("accessibilityResume = { [weak self] in" in fn and call in fn, "pet jump resume", f"{head.strip()} sets its resume before the gate")
gate = body(model, "    private func ensureAccessibilityTrust() -> Bool {", "\n    }\n")
pin("if !trusted && !permissionGuideLive {" in gate, "pet jump hook", "in the app the guide asks, not a second system prompt")
pin('guide.resetOwnAccessibility = { [weak self] in self?.resetAccessibilityAndAddAgain() }' in make, "repair wiring", "Reset and add again reuses the 0.5.267 repair")

# 0.5.318: a feature's own Allow goes through the guide (the dictation card, System Audio Recording).
dictation, recording, app, core = read("Sources/MacDictation.swift"), read("Sources/MacRecording.swift"), read("Sources/COSControlApp.swift"), read("Sources/MacDictationCore.swift")
insert = body(dictation, "    func requestInsertionPermission() {", "\n    }\n")
pin(ordered(insert, "guard let ask = requestAccessibility else {", "AXTrustedCheckOptionPrompt")
    and "ask { [weak self] in self?.insertionAllowed() }" in insert, "dictation allow route", "Allow… is the guide whenever the app wired it; the prompt only without it")
allowed = body(dictation, "    private func insertionAllowed() {", "\n    }\n")
pin("if case .copied(.notTrusted) = card?.kind { dismissCard() }" in allowed, "dictation allow resume", "the Accessibility card goes once the grant is seen")
card = body(dictation, "struct DictationCardView: View {", "\n}\n")
i, j = card.find("if refusal == .notTrusted {"), card.find('Button("Fix a word")')
notrust = card[i:j] if 0 <= i < j else ""
pin('Button("Allow…") { store.requestInsertionPermission() }' in notrust and 'Button("Reset") { store.resetInsertionPermission() }' in notrust, "dictation reset", "the card offers Reset and add again beside Allow…")
pin('case .notTrusted: "Allow COS Control in Accessibility to drop text in for you. Already on? Reset and add again.' in core, "dictation reset", "the card says what to do when the row is already on")
reset = body(dictation, "    func resetInsertionPermission() {", "\n    }\n")
pin("reset { [weak self] in self?.insertionAllowed() }" in reset, "dictation reset", "Reset resumes the card too")
ask_ax = body(model, "    func requestDictationAccessibility(resume: @escaping @MainActor () -> Void) {", "\n    }\n")
pin("PermissionAskRoute.decide(allowed: AXIsProcessTrusted(), guideLive: permissionGuideLive)" in ask_ax
    and "if permissionGuide.need(.accessibility, for: Self.dictationAccessibilityFeature, resume: resume) { resume() }" in ask_ax, "dictation allow route", "the card's Allow is the guide's need, as the pet jump")
reset_ax = body(model, "    func resetDictationAccessibility(resume: @escaping @MainActor () -> Void) {", "\n    }\n")
pin("accessibilityResume = { waiting?(); resume() }" in reset_ax and "accessibilityFeature = Self.dictationAccessibilityFeature" in reset_ax
    and ordered(reset_ax, "accessibilityFeature =", "resetAccessibilityAndAddAgain()"), "dictation reset", "Reset is the 0.5.267 repair, and keeps a waiting jump")
audio = body(model, "    func requestSystemAudio(for feature: String, wantsPane: Bool = false, resume: (@MainActor () -> Void)? = nil) async -> Bool {", "\n    }\n")
pin(ordered(audio, "if step == .prompt {", "await SystemAudioPermission.request()", "step = SystemAudioAsk.step(fact, asked: true"),
    "system audio request", "macOS's prompt first, then the step again as asked")
pin("permissionGuide.drag(.systemAudio, for: feature, resume: resume)" in audio, "system audio drag fallback", "not allowed after asking: the drag flow")
pin('dlsym(handle, "TCCAccessRequest")' in dictation and 'private static let service = "kTCCServiceAudioCapture"' in dictation and "try? await Task.sleep(for: timeout)" in dictation,
    "system audio request", "TCCAccessRequest for kTCCServiceAudioCapture, bounded")
pin("nonisolated static var tapPermitted: Bool { SystemAudioPermission.fact == .allowed }" in dictation, "system audio fact", "one preflight for the mute and the request")
quiet = body(dictation, "private struct DictationQuietSettings: View {", "\n}\n")
pin(quiet.count("store.requestSystemAudioPermission(") == 2 and "Privacy_ScreenCapture" not in quiet, "system audio settings", "Mute other apps and the fallback note use the one request, never a bare link")
pin("case .systemAudio: SystemAudioPermission.fact == .allowed" in flow, "system audio detection", "the bar watches TCC's answer for System Audio Recording")
start = body(recording, "    private func start() async {", "\n    }\n")
pin("if !DictationQuietController.tapPermitted, let ask = requestSystemAudio {" in start
    and ordered(start, "let allowed = await ask()", 'phase = "starting"', "try await engine.start(source: source)"),
    "recording asks", "a Mac recording asks for System Audio Recording before the capture starts")
pin("guard !askingSystemAudio else { return }" in start and "guard noticeAcknowledged, canStart, available else { return }" in start, "recording asks", "one ask at a time, and the gates read again after it")
pin("model.dictation.requestAccessibility = { [weak model] resume in model?.requestDictationAccessibility(resume: resume) }" in app
    and "model.dictation.resetAccessibility = { [weak model] resume in model?.resetDictationAccessibility(resume: resume) }" in app
    and 'await model?.requestSystemAudio(for: "Mute other apps", wantsPane: wantsPane)' in app
    and 'model.macRecording.requestSystemAudio = { [weak model] in await model?.requestSystemAudio(for: "All Mac audio") ?? false }' in app,
    "feature ask wiring", "the app hands dictation and recording the guide's requests")

# Entry points.
main_panel = body(views, "    private var mainPanel: some View {", "    private var activityLauncher")
pin("PanelPermissionsRow(guide: model.permissionGuide)" in main_panel, "panel row", "the panel has a Permissions row")
pin("if guide.panelRouteActive {" in guide_views and "PermissionGuideCard(guide: guide)" in guide_views, "panel route", "the card mounts on its own flag")
pin("permissionsDone: permissions.onboardingDone" in setup and "OnboardingPermissionsStep(guide: model.permissionGuide)" in body(setup, "case .permissions:", "case .glasses:"), "onboarding step", "The journey reads real permission completion and mounts the existing permission step")
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
    # Join continuation lines first: a greedy [^\n]* swallowed the trailing backslash, so the old pattern saw only the
    # first line of each command and this pin could never fail (found by a surviving mutant, 2026-10-08).
    for command in [line for line in text.replace("\\\n", " ").splitlines() if "swiftc" in line]:
        if '"$ROOT/Sources/ControllerModel.swift"' in command:
            for f in files:
                pin(f'"$ROOT/Sources/{f}"' in command, "source lists", f"{script.name} compiles ControllerModel without {f}")

if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print("PASS: permission guide pins")
