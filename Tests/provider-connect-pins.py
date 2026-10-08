#!/usr/bin/env python3
"""Pins for Connect your AI's wiring (onboarding P1). The behaviour is in Tests/ProviderStatusChecks.swift and
Tests/ProviderConnectChecks.swift; these say the app and the helper call it where they should. Each failure names what
broke: "pin failed [<behaviour>]".

    python3 Tests/provider-connect-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
read = lambda p: (root / p).read_text(encoding="utf-8")
model, views, setup, app = read("Sources/ControllerModel.swift"), read("Sources/Views.swift"), read("Sources/ControlSetup.swift"), read("Sources/COSControlApp.swift")
connect, connect_views = read("Sources/ProviderConnectModel.swift"), read("Sources/ProviderConnectViews.swift")
core, helper, handoff = read("HelperSources/ProviderStatusCore.swift"), read("HelperSources/main.swift"), read("Sources/WorkHandoffStore.swift")
failed = []

def pin(ok, behaviour, why):
    if not ok:
        failed.append(f"pin failed [{behaviour}]: {why}")

def body(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i + len(start))]

# The strict link encoder and Cursor's link are the Work handoff's, byte for byte.
allowed = lambda src: re.search(r'linkQueryAllowed = CharacterSet\(charactersIn: "([^"]+)"\)', src).group(1)
pin(allowed(connect) == allowed(handoff), "link encoder", "ProviderPass.linkQueryAllowed must equal WorkHandoffStore.linkQueryAllowed")
pin('cursor://anysphere.cursor-deeplink/prompt?text=\\(text)&mode=agent' in connect
    and 'cursor://anysphere.cursor-deeplink/prompt?text=\\(encoded)&mode=agent' in handoff, "cursor link", "the same Cursor prompt link as Work")
pin('claude://code/new?folder=\\(path)&q=\\(text)' in connect and 'codex://threads/new?path=\\(path)&prompt=\\(text)' in connect, "links", "the canaried Claude and Codex new-thread links")

# The model file performs no effect itself: every opener is injected.
pin(not re.search(r"NSWorkspace|NSPasteboard|Process\(|osascript|import AppKit|import SwiftUI", connect), "injected effects", "ProviderConnectModel.swift opens nothing itself")
pin(not re.search(r"Process\(|NSWorkspace|URLSession|FileManager", core), "pure core", "ProviderStatusCore.swift spawns, reads and fetches nothing")

# Route flag: the card renders exactly under its own flag, and only the opener and Done write it.
row = body(connect_views, "struct PanelConnectAIRow: View {", "\n/// F5")
pin(re.search(r"if guide\.panelRouteActive \{\s*ProviderConnectCard\(guide: guide, model: model\)", row) is not None, "route flag", "the card mounts on `if guide.panelRouteActive` alone")
pin("guide.openInPanel()" in row, "route flag", "the row's click is the opener")
writes = re.findall(r"(?<!var )panelRouteActive = (true|false)", connect + connect_views + model + views + setup)
pin(writes.count("true") == 1 and writes.count("false") == 1, "route flag", f"one opener and one closer write the flag: {writes}")
pin("panelRouteActive = true" in body(connect, "    func openInPanel() {", "\n    }\n"), "route flag", "openInPanel writes it")
main_panel = body(views, "    private var mainPanel: some View {", "\n    }\n")
pin("PanelConnectAIRow(guide: model.providerGuide, model: model)" in main_panel, "panel row", "the panel shows Connect your AI")
pin(not re.search(r"\.(sheet|popover|fullScreenCover)\s*\(", connect_views), "inline", "never a sheet or popover (MenuBarExtra dismisses itself)")

# Polling only while visible: only the visible card and step poll; the collapsed row reads once.
pin(connect_views.count("await guide.poll()") == 1 and "func providerPolling" in connect_views, "polling", "one polling site, a view task")
pin(connect_views.count(".providerPolling(") == 2 and ".providerPolling(guide)" in body(connect_views, "struct ConnectYourAIStep: View {", "\n/// The card the menu-bar panel")
    and ".providerPolling(provider)" in body(connect_views, "struct SetupGuideView: View {", "\n/// \"Finish setup"), "polling", "the Welcome step and the setup guide, nothing else")
pin("await guide.poll" not in row.split("ProviderConnectCard(guide: guide, model: model)")[1], "polling", "the collapsed row never polls")

# Welcome: Connect your AI before Get started, which still runs setup behind the 0.5.267 gate.
first_run = body(setup, "} else if model.status.needsFirstRun {", "} else if !model.busy {")
pin("ConnectYourAIStep(guide: model.providerGuide," in first_run and 'getStarted: { model.perform("setup") }' in first_run, "welcome", "the step owns Get started")
step = body(connect_views, "struct ConnectYourAIStep: View {", "\n/// The card the menu-bar panel")
pin(step.count("ProviderGate.getStartedEnabled(setupProviderInstalled: setupProviderInstalled, busy: busy)") == 2
    and ".disabled(" in step and "signInStepDone)" not in step.replace("guide.signInStepDone {", ""), "gate unchanged", "only installed and busy disable Get started")
pin("static func getStartedEnabled(setupProviderInstalled: Bool, busy: Bool) -> Bool { setupProviderInstalled && !busy }" in connect, "gate unchanged", "the hard gate is installed")
pin('guard !detectedManagedProviders().isEmpty || resolveAgentBinary() != nil else {' in helper, "gate unchanged", "the helper still refuses setup without a CLI")
pin('"setupProviderInstalled": !detectedManagedProviders().isEmpty || resolveAgentBinary() != nil,' in helper, "gate unchanged", "the gate field is computed as in 0.5.267")
pin("Skip for now" in connect_views and "guide.skip(provider)" in connect_views, "skip", "each row can be skipped")

# Helper: the verb, read-only commands only.
pin('case "provider-status": try emitProviderStatus(args: args)' in helper, "helper verb", "provider-status is dispatched")
verb = body(helper, "    private func emitProviderStatus(args: [String]) throws {", "\n    // MARK: Voice (local Whisper) setup")
pin("withMutationLock" not in verb and "request(" not in verb, "helper verb", "no lifecycle lock, no server request")
runs = re.findall(r"probes\.run\([^,]+, (\[[^\]]*\])\)", core)
allowed_runs = {'["about"]', '["--version"]', '["auth", "status", "--json"]', '["login", "status"]'}
pin(runs and set(runs) <= allowed_runs, "read-only probes", f"only status and version commands run: {sorted(set(runs))}")
pin("result.output)" in verb and "stripEmails" not in verb, "cursor sign-in", "the parser gets raw output (a stripped email read as signed out)")
pin('"email"' not in core and "userEmail" not in core, "no email", "no email field is read or kept")

# The guide is inert outside the app bundle, so checks and renders open nothing.
factory = body(model, "    private func makeProviderGuide() -> ProviderGuide {", "\n    /// F4")
pin("guard inApp else { return guide }" in factory and factory.index("guard inApp else { return guide }") < factory.index("guide.runInTerminal ="), "inert in checks", "no Terminal or link opener outside the app")

# The label fix: no more "Not signed in" for a failed server --version.
pin('return "Not signed in: " + missing' not in views and "AgentCliDetailLine(guide: model.providerGuide, model: model, allReady: agentCliAllReady)" in views, "label fix", "the Agent CLIs line comes from provider-status")

# F3 Dock.
pin("@NSApplicationDelegateAdaptor(COSAppDelegate.self)" in app and "DockPresence.reopenTarget(" in app, "dock", "the Dock click is handled")
pin("func applicationShouldHandleReopen" in connect_views and "DockPresence.apply(DockPresence.mode(stored:" in connect_views, "dock", "the setting is applied at launch")
pin('Toggle("Show in menu bar only"' in views and "model.setShowInDock(" in views, "dock", "Settings has the switch")
pin("<key>LSUIElement</key>\n\t<true/>" in read("Resources/Info.plist"), "dock", "menu-bar-only users never flash in the Dock at launch")

# F4 pet intro, F5 glasses, F6 Jev.
pin("PetIntroLine(model: model)" in main_panel and "PetIntroLine(model: model)" in setup, "pet intro", "panel and Welcome")
init = body(model, "    init(startBackgroundWork: Bool = true", "\n    }\n")
pin(init.index("guard startBackgroundWork else { return }") < init.index("evaluatePetIntro()"), "pet intro", "evaluated only in the running app")
pin("case .addJevKey: model.showSettings?()" in connect_views and 'rows.append(SetupRow(id: .jev' in connect, "jev row", "the guide shows Jev and sends the key to Settings")
pin("jevKey" not in connect_views, "jev row", "the guide never touches the key")
pin("GlassesGuideRow(" in connect_views and "gotcos.com/wizard/#glasses-setup" in connect, "glasses row", "links the existing wizard steps")

# The setup guide (Miles 2026-10-08 10:52): prominent, skippable, reachable from everywhere.
pet = read("Sources/SessionPet.swift"); activity = read("Sources/ActivityWindow.swift")
pin(main_panel.index("FinishSetupCard(") < main_panel.index("updateRow"), "finish card", "Finish setup sits at the top of the panel")
pin("FinishSetupCard(" in body(activity, "    private var activityHome: some View {", "homeGrid("), "finish card", "and at the top of Activity home")
pin('Button("Hide") { guide.hide() }' in connect_views and 'Button("Hide setup guide") { guide.hide() }' in connect_views, "finish card", "Hide setup guide from the card and the guide")
pin('static let dockMenuTitles = ["Open Activity", "Setup guide…", "Settings…"]' in connect_views and "func applicationDockMenu(" in connect_views, "dock menu", "the Dock menu")
pin(app.count('Button("Setup guide…")') == 2 and "CommandGroup(replacing: .help)" in app and "CommandGroup(replacing: .appSettings)" in app, "app menu", "Setup guide in the app menu and Help")
sprite = body(pet, "    @ViewBuilder private var spriteMenu: some View {", "\n    }\n")
pin('Button("Settings…") { model.showSettings?() }' in sprite and 'Button("Setup guide…") { model.showSetupGuide?() }' in sprite and 'Button("Hide pet")' in sprite and "PetMotion.allCases" in sprite, "pet menu", "Settings and Setup guide, Hide and the motion items kept")
pin('.id("settings")' in main_panel and "model.panelScrollTarget = nil" in views, "settings opener", "Settings… scrolls the panel to its settings, then clears the target")
pin("if !MenuBarPanelOpener.open() { setupWindow.show(model: model) }" in app, "settings opener", "no panel to open: the setup guide window")
pin("SetupGuideView(model: model" in setup, "welcome guide", "the Welcome window is the setup guide once COS is set up")
# Voice in the app: the installed server's own setup, COS Control's Node, never Homebrew.
vs = body(helper, "    private func runVoiceSetup(args: [String]) throws {", "\n    /// posix_spawn")
pin('"--setup-transcription", "--transcription-tier", tier, "--prepare-only"' in vs and "bin/cli.cjs" in vs and "nodeToolEnvironment(node: node)" in vs, "voice setup", "runs the installed server's setup with COS Control's Node")
pin("brew\"" not in vs and not re.search(r'execute\([^)]*brew', helper), "voice setup", "never runs Homebrew")
pin("POSIX_SPAWN_SETPGROUP" in helper and "killpg(voiceSetupChildGroup, SIGTERM)" in helper, "voice cancel", "Cancel stops the whole child group")
guided = body(model, "    func runGuidedSetup(tier: String) {", "\n    }\n")
pin(guided.index("setupGuide.voice?.terminalCommand[normalized]") < guided.index('"npx --yes'), "guided setup", "Terminal uses COS Control's npx by path; bare npx only as the last resort")
pin('case "voice-status": emitVoiceStatus()' in helper and "withMutationLock" not in body(helper, "    private func voiceSetupFacts() -> [String: Any] {", "\n    private func emitVoiceStatus"), "voice status", "read-only")

# Source lists: every app compile has the new files; every helper compile has the core.
for script in list((root / "Tests").glob("*.sh")) + list((root / "scripts").glob("*.sh")) + list((root / "Tests").glob("*.py")):
    if script.name == "provider-connect-pins.py":
        continue
    text = script.read_text(encoding="utf-8")
    # Join continuation lines first: a greedy [^\n]* swallowed the trailing backslash, so the old pattern saw only the
    # first line of each command and this pin could never fail (found by a surviving mutant, 2026-10-08).
    for command in [line for line in text.replace("\\\n", " ").splitlines() if "swiftc" in line]:
        if '"$ROOT/Sources/ControllerModel.swift"' in command:
            for f in ("ProviderConnectModel.swift", "ProviderConnectViews.swift"):
                pin(f'"$ROOT/Sources/{f}"' in command, "source lists", f"{script.name} compiles ControllerModel without {f}")
    for line in text.splitlines():
        if "HelperSources/main.swift" in line and ("swiftc" in line or line.strip().startswith('"$ROOT/HelperSources/main.swift"') or '"HelperSources/main.swift", "-framework"' in line or '"HelperSources/main.swift", "HelperSources' in line):
            pin("ProviderStatusCore.swift" in line, "source lists", f"{script.name} compiles the helper without ProviderStatusCore.swift")

if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print("PASS: Connect your AI pins")
