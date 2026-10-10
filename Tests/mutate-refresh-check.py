#!/usr/bin/env python3
"""Mutation lane for the header refresh-and-check and the version stamp (2026-10-09). Run by hand, never by a gate.
SERIAL: one mutant at a time, and every compile goes through Tests/compile-guard.sh (two kernel panics on 2026-10-07
came from parallel compiles).

    python3 Tests/mutate-refresh-check.py <worktree> <scratch dir> [name ...]

It copies the worktree once to <scratch dir>/copy, proves each UNMUTATED lane green first (a red baseline makes every
mutant look killed), then applies one mutant at a time: each target must appear exactly once, the mutant must make a
check fail, and the failure must name the behaviour the mutant breaks ("check failed [<behaviour>]" or "pin failed
[<behaviour>]"). A mutant that lands and survives is a finding; so is one the compiler refuses (it never ran).
Lanes (Tests/run-refresh-check.sh): "pins" Python only; "models" Models.swift with Tests/RefreshCheckChecks.swift;
"wiring" the whole app with Tests/RefreshCheckRender.swift against a stand-in helper.
"""
import os, pathlib, shutil, subprocess, sys, time

M = "Sources/Models.swift"
C = "Sources/ControllerModel.swift"
V = "Sources/Views.swift"
# (name, file, original or [(original, mutant)...], mutant, words the killing failure must contain, lane)
MUTANTS = [
    # The subtitle state machine.
    ("checking words", M, 'static let checkingText = "Checking for updates…"', 'static let checkingText = "Checking…"', "[checking words]", "models"),
    ("up to date words keep the version", M, 'static let upToDateText = "Up to date"', 'static let upToDateText = "Up to date · COS Control"', "[up to date words]", "models"),
    ("failed words", M, 'static let failedText = "Couldn\'t check for updates"', 'static let failedText = "Update check failed"', "[failed words]", "models"),
    ("up to date holds 10 s", M, "static let upToDateHold: Duration = .seconds(4)", "static let upToDateHold: Duration = .seconds(10)", "[up to date hold]", "models"),
    ("failed holds 4 s", M, "static let failedHold: Duration = .seconds(6)", "static let failedHold: Duration = .seconds(4)", "[failed hold]", "models"),
    ("up to date never resets", M, "        case .upToDate: Self.upToDateHold\n", "        case .upToDate: nil\n", "[up to date hold]", "models"),
    ("failure gives idle", M, "        case .failed: .failed\n        case .updateFound, .skipped: .idle", "        case .failed: .idle\n        case .updateFound, .skipped: .idle", "[outcome failed]", "models"),
    ("up to date gives idle", M, "        case .upToDate: .upToDate\n        case .failed: .failed", "        case .upToDate: .idle\n        case .failed: .failed", "[outcome up to date]", "models"),
    ("update found says up to date", M, "        case .updateFound, .skipped: .idle", "        case .updateFound: .upToDate\n        case .skipped: .idle", "[outcome update found]", "models"),
    ("in flight ignored", M, "        inFlight ? .checking : status", "        status", "[shown in flight]", "models"),
    # The model, executed against a stand-in helper.
    ("button skips the check", C, "        await checkForUpdatesFromHeader()\n        await status.value", "        await status.value", "[both actions]", "wiring"),
    ("button skips the refresh", C, "        let status = Task { await self.refresh() }", "        let status = Task { }", "[both actions]", "wiring"),
    ("second manual check allowed", C, "        guard !updateCheckInFlight else { return .skipped }\n", "", "[no second check]", "wiring"),
    ("header guard gone", C, "        guard !updateCheckInFlight else { return }\n        headerUpdateStatusReset?.cancel()", "        headerUpdateStatusReset?.cancel()", "[no stuck checking]", "wiring"),
    ("timers never cancelled", C, [("        guard !updateCheckInFlight else { return }\n        headerUpdateStatusReset?.cancel()\n", "        guard !updateCheckInFlight else { return }\n"),
                                   ("    private func showHeaderUpdateStatus(_ next: HeaderUpdateStatus) {\n        headerUpdateStatusReset?.cancel()\n", "    private func showHeaderUpdateStatus(_ next: HeaderUpdateStatus) {\n")], None, "[no stacked timers]", "wiring"),
    ("cancelled reset still fires", C, "            guard !Task.isCancelled else { return }\n            self?.headerUpdateStatus = .idle", "            self?.headerUpdateStatus = .idle", "[no stacked timers]", "wiring"),
    ("header check raises the alert", C, "checkForAppUpdateManually(reportsInHeader: true)", "checkForAppUpdateManually()", "[reports in header]", "wiring"),
    ("unreachable reads up to date", C, "                return .failed\n            }\n            appUpdate = incoming", "                return .upToDate\n            }\n            appUpdate = incoming", "[outcome failed]", "wiring"),
    ("refusal reads up to date", C, "            return .failed\n        }\n    }\n\n    /// The panel header's refresh button", "            return .upToDate\n        }\n    }\n\n    /// The panel header's refresh button", "[outcome failed]", "wiring"),
    # The view (pins).
    ("button only refreshes", V, "            Task { await model.refreshAndCheckForUpdates() }", "            Task { await model.refresh() }", "[both actions]", "pins"),
    ("button help unchanged", V, '            .help("Refresh status and check for updates")', '            .help("Refresh status")', "[button help]", "pins"),
    ("button unlabelled", V, '            .accessibilityLabel("Refresh status and check for updates")\n', "", "[button help]", "pins"),
    ("subtitle not wired", V, 'updateStatusLine(idle: "Your local glasses server").lineLimit(1)', 'Text("Your local glasses server").font(COSType.body(11)).foregroundStyle(.secondary)', "[subtitle words]", "pins"),
    ("subtitle ignores in flight", V, "HeaderUpdateStatus.shown(inFlight: model.updateCheckInFlight, status: model.headerUpdateStatus)", "HeaderUpdateStatus.shown(inFlight: false, status: model.headerUpdateStatus)", "[subtitle words]", "pins"),
    ("motion under Reduce Motion", V, ".animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: shown)", ".animation(.easeOut(duration: 0.15), value: shown)", "[reduce motion]", "pins"),
    ("version card back", V, "                noticeBanner\n", "                updateRow\n                noticeBanner\n", "[card gone]", "pins"),
    ("Settings loses its check", V, "                        refreshAndCheckButton\n                    }\n                } else { header }", "                    }\n                } else { header }", "[settings entry]", "pins"),
    ("stamp hard-coded", V, 'Text("v\\(ControllerModel.currentVersion)")', 'Text("v0.5.276")', "[stamp live version]", "pins"),
    ("stamp gone from under the lockup", V, "                if !versionStampInline { versionStamp }\n", "", "[stamp placement]", "pins"),
    ("variant B shipped", V, "    var versionStampInline = false", "    var versionStampInline = true", "[stamp placement]", "pins"),
    ("stamp unlabelled", V, '            .accessibilityLabel("COS Control version \\(ControllerModel.currentVersion)")\n', "", "[stamp label]", "pins"),
    ("stamp in a chip", V, "            .foregroundStyle(.tertiary)\n            .lineLimit(1)", "            .foregroundStyle(.tertiary)\n            .background(COSPalette.card, in: Capsule())\n            .lineLimit(1)", "[stamp type]", "pins"),
    ("stamp at 11 pt", V, '            .font(COSType.mono(9))\n            .foregroundStyle(.tertiary)', '            .font(COSType.mono(11))\n            .foregroundStyle(.tertiary)', "[stamp type]", "pins"),
]


def run(lane, copy):
    env = dict(os.environ, COS_REFRESH_CHECK_LANE=lane, COS_COMPILE_MIN_FREE_GB=os.environ.get("COS_COMPILE_MIN_FREE_GB", "20"))
    while True:
        p = subprocess.run(["/bin/zsh", str(copy / "Tests/run-refresh-check.sh")], capture_output=True, text=True, timeout=1800, env=env)
        if p.returncode != 75:
            return p.returncode, p.stdout + p.stderr
        time.sleep(30)


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "dist", "*.zip"))
    lanes = {lane for name, _, _, _, _, lane in MUTANTS if not only or name in only}
    for lane in ("pins", "models", "wiring"):
        if lane not in lanes:
            continue
        code, out = run(lane, copy)
        if code != 0:
            sys.exit(f"baseline {lane} lane is RED; no mutant can be judged:\n{out[-3000:]}")
        print(f"baseline {lane}: green ({out.strip().splitlines()[-1] if out.strip() else ''})", flush=True)
    survived, results = [], []
    for name, rel, original, mutant, words, lane in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        edits = original if isinstance(original, list) else [(original, mutant)]
        missed = [text.count(o) for o, _ in edits if text.count(o) != 1]
        if missed:
            results.append(f"MISSED TARGET ({missed}x) {name}")
            survived.append(name)
            print(results[-1], flush=True)
            continue
        mutated = text
        for o, m in edits:
            mutated = mutated.replace(o, m)
        path.write_text(mutated, encoding="utf-8")
        started = time.time()
        try:
            code, out = run(lane, copy)
        finally:
            path.write_text(text, encoding="utf-8")
        took = time.time() - started
        if code == 137:
            sys.exit(f"compile guard stopped the run at mutant {name}; stopping the lane")
        if code == 0:
            results.append(f"SURVIVED {name}")
            survived.append(name)
        elif words in out:
            line = next((l for l in out.splitlines() if "failed [" in l), "")
            results.append(f"killed  {name}  ({took:.0f}s) {line[:140]}")
        elif "error:" in out:
            results.append(f"WEAK (compile error) {name}")
            survived.append(name)
        else:
            results.append(f"WEAK (another check) {name}: {out.strip().splitlines()[-1][:160] if out.strip() else ''}")
            survived.append(name)
        print(results[-1], flush=True)
    print(f"{len(results) - len(survived)} of {len(results)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
