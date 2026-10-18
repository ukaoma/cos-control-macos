#!/usr/bin/env python3
"""0.5.322: the update wiring a check cannot click or launch. Each failure names its behaviour as
"pin failed [<behaviour>]" for Tests/mutate-app-update-escalation.py. Comments are stripped, so an explanatory comment
can never satisfy a pin.

    python3 Tests/app-update-finish-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")


def code(path):
    return "\n".join(l for l in (root / path).read_text(encoding="utf-8").split("\n")
                     if not l.strip().startswith("//") and not l.strip().startswith("///"))


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


views, model, store, helper = code("Sources/Views.swift"), code("Sources/ControllerModel.swift"), code("Sources/MacRecording.swift"), code("HelperSources/main.swift")

# The real app writes its Mac recording state at launch (a test model never does), before anything else can run.
init = model[model.index("    init(startBackgroundWork: Bool = true"):]
after_guard = init.split("        guard startBackgroundWork else { return }\n", 1)
pin(len(after_guard) == 2 and after_guard[1].lstrip().startswith("recordMacCaptureState(to: MacCaptureStateFile.url())"),
    "launch writes capture state", "the app records the Mac recording state first thing after the test-model guard")
pin("recordMacCaptureState" not in after_guard[0], "launch writes capture state", "a test model (no background work) never writes it")
# The launch reads the staged build after closing the last handshake and before the first check.
task = init[init.index("updateCheckTask = Task { [weak self] in"):]
task = task[:task.index("while !Task.isCancelled")]
order = [task.find("completeAppUpdateIfNeeded()"), task.find("checkStagedAppUpdate()"), task.find("runScheduledAppUpdateCheck(.launch)")]
pin(all(i >= 0 for i in order) and order == sorted(order), "launch offer order",
    "complete-app-update, then staged-app-update, then the launch check")
# The banner's button installs a staged build in one click, and opens What's New for any other offer.
banner = views[views.index("@ViewBuilder private var updateBanner"):views.index("private var footer")]
pin("if model.appUpdateFlow.finishesStaged { model.finishStagedAppUpdate() } else { model.presentWhatsNew() }" in banner,
    "banner finishes in one click", "Install on a staged offer runs finishStagedAppUpdate, Update opens What's New")
pin("Button(words.action ?? \"Install\", action: onUpdate)" in views and "case .ready where flow.finishesStaged:" in views,
    "banner finishes in one click", "the staged offer has its own Install button")
# Every phase change reaches the recorder (Tests/AppUpdateFinishWiring.swift executes it through Recover).
did = store[store.index('    @Published private(set) var phase = "idle" {'):store.index("    @Published private(set) var message")]
pin("if oldValue != phase { phaseRecorder?(phase) }" in did, "phase recorder", "the phase's didSet records every change")
# The swap forces a quit only through quitLiveForSwap, after the work blockers, and records it.
swap = helper[helper.index("    private func swapStagedApp(live: URL, expectedBuild: Int?) throws {"):helper.index("    private static let launchServicesRegister")]
pin("let blockers = appUpdateWorkBlockers()" in swap and "quitLiveForSwap(live, timings: timings)" in swap
    and swap.index("let blockers = appUpdateWorkBlockers()") < swap.index("quitLiveForSwap(live, timings: timings)"), "swap order",
    "the server's work blockers are checked before any quit is forced")
pin("        waitForLiveToQuit(live)\n        if bundleHasRunningProcess(live) {" not in swap, "swap order", "the old 60 s wait and give-up is gone")
update = helper[helper.index("    private func emitStageAppUpdate(args: [String]) throws {"):helper.index("    private func contextBrowseResponse(")]
pin(len(re.findall(r"\bkill\(", update)) == 1 and "return Darwin.kill(process.pid, signal) == 0" in update, "one signal site",
    "the update path sends a signal from exactly one place, signalLiveProcess, which re-checks the process first")
print("PASS: app update finish pins")
