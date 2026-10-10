#!/usr/bin/env python3
"""Mutation lane for the update-ready badge (2026-10-09). Run by hand, never by a gate. SERIAL: one mutant at a time,
and every compile goes through Tests/compile-guard.sh (two kernel panics on 2026-10-07 came from parallel compiles).

    python3 Tests/mutate-app-update-badge.py <worktree> <scratch dir> [name ...]

It copies the worktree once to <scratch dir>/copy, proves each UNMUTATED lane green first (a red baseline makes every
mutant look killed), then applies one mutant at a time: the target text must appear exactly once, the mutant must make
a check fail, and the failure must name the behaviour the mutant breaks ("check failed [<behaviour>]" or "pin failed
[<behaviour>]"). A mutant that lands and survives is a finding; so is one the compiler refuses (it never ran).
Lanes: "checks" compiles Sources/Models.swift with Tests/AppUpdateBadgeChecks.swift; "pins" runs Python only.
"""
import pathlib, shutil, subprocess, sys, tempfile, time

M = "Sources/Models.swift"
C = "Sources/ControllerModel.swift"
V = "Sources/Views.swift"
A = "Sources/COSControlApp.swift"
# (name, file, original, mutant, words the killing failure must contain, lane)
MUTANTS = [
    # The version rule.
    ("build compare >=", M, "if let latestBuild { return latestBuild > currentBuild }", "if let latestBuild { return latestBuild >= currentBuild }", "[build equal]", "checks"),
    ("build compare inverted", M, "if let latestBuild { return latestBuild > currentBuild }", "if let latestBuild { return latestBuild < currentBuild }", "[build newer]", "checks"),
    ("build ignored, version decides", M, "        if let latestBuild { return latestBuild > currentBuild }\n", "", "[build authoritative]", "checks"),
    ("malformed offer accepted", M, "guard let latestVersion, components(latestVersion) != nil else { return false }", "guard let latestVersion else { return false }", "[offer malformed]", "checks"),
    ("version-only >=", M, "return compare(latestVersion, currentVersion) == .orderedDescending", "return compare(latestVersion, currentVersion) != .orderedAscending", "[version without build]", "checks"),
    ("text compare", M, "            if x != y { return x < y ? .orderedAscending : .orderedDescending }", "            if x != y { return String(x) < String(y) ? .orderedAscending : .orderedDescending }", "[version order]", "checks"),
    ("missing component not zero", M, "            let y = index < b.count ? b[index] : 0", "            let y = index < b.count ? b[index] : 1", "[version order]", "checks"),
    ("non-digits accepted", M, "piece.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),", "", "[version malformed]", "checks"),
    ("long pieces accepted", M, "            guard piece.count <= 9, piece.unicodeScalars", "            guard piece.unicodeScalars", "[version malformed]", "checks"),
    # The schedule.
    ("overlap allowed", M, "        guard !inFlight else { return false }\n        guard let lastStarted else { return true }", "        guard let lastStarted else { return true }", "[schedule no overlap]", "checks"),
    ("finish keeps the slot", M, "    mutating func finish() { inFlight = false }", "    mutating func finish() { }", "[schedule no overlap]", "checks"),
    ("periodic every 6 minutes", M, "    static let periodicInterval: TimeInterval = 6 * 60 * 60", "    static let periodicInterval: TimeInterval = 6 * 60", "[schedule periodic]", "checks"),
    ("panel open always checks", M, "        case .panelOpen: return age >= Self.panelOpenStaleAfter", "        case .panelOpen: return true", "[schedule panel open]", "checks"),
    ("panel open after an hour", M, "    static let panelOpenStaleAfter: TimeInterval = 15 * 60", "    static let panelOpenStaleAfter: TimeInterval = 60 * 60", "[schedule panel open]", "checks"),
    ("periodic strict >", M, "        case .periodic: return age >= Self.periodicInterval", "        case .periodic: return age > Self.periodicInterval", "[schedule periodic]", "checks"),
    ("launch not recorded", M, "        inFlight = true\n        lastStarted = now\n", "        inFlight = true\n", "[schedule", "checks"),
    ("nap uncapped", M, "        return min(Self.maximumNap, max(1, due))", "        return max(1, due)", "[schedule nap]", "checks"),
    ("nap ignores the due time", M, "        return min(Self.maximumNap, max(1, due))", "        return Self.maximumNap", "[schedule nap]", "checks"),
    ("unbounded helper", M, "    static let helperTimeout: TimeInterval = 20", "    static let helperTimeout: TimeInterval = 600", "[schedule timeout]", "checks"),
    # The phases.
    ("install from none", M, "        case .ready, .failed:\n            phase = .staging(nil)", "        case .ready, .failed, .none:\n            phase = .staging(nil)", "[flow install gate]", "checks"),
    ("double install", M, "        case .ready, .failed:\n            phase = .staging(nil)", "        case .ready, .failed, .staging:\n            phase = .staging(nil)", "[flow install gate]", "checks"),
    ("no retry", M, "        case .ready, .failed:\n            phase = .staging(nil)", "        case .ready:\n            phase = .staging(nil)", "[flow", "checks"),
    ("a check interrupts the install", M, "        case .staging, .applying:\n            return\n        case .none, .ready:", "        case .none, .ready, .staging, .applying:", "[flow install owns banner]", "checks"),
    ("failure hidden while offered", M, "        case .failed:\n            if !available { phase = .none }", "        case .failed:\n            phase = available ? .ready : .none", "[flow failed]", "checks"),
    ("stale offer ready", M, "        let available = info.shouldSurface && AppUpdateVersion.isNewer(", "        let available = info.shouldSurface || AppUpdateVersion.isNewer(", "[flow", "checks"),
    ("staged from ready", M, "    mutating func staged() {\n        guard case .staging = phase else { return }", "    mutating func staged() {", "[flow install gate]", "checks"),
    ("fail from ready", M, "        case .staging, .applying:\n            let trimmed", "        case .staging, .applying, .ready:\n            let trimmed", "[flow install gate]", "checks"),
    # The icon.
    ("icon tints only when ready", M, "        phase == .none ? .normal : .updateReady", "        phase == .ready ? .updateReady : .normal", "[icon follows state]", "checks"),
    ("ready icon is a template", M, "        composed.isTemplate = !ready", "        composed.isTemplate = true", "[icon", "checks"),
    ("dot back on the lens", M, "        let canvas = ready ? NSSize(width: glyph.width + dotRoom, height: glyph.height) : glyph\n", "        let canvas = glyph\n", "[icon", "checks"),
    ("no dot", M, "            NSBezierPath(ovalIn: dot).fill()\n", "", "[icon dot]", "checks"),
    ("no gold", M, "            context.compositingOperation = .sourceAtop\n            updateTint.setFill()\n            rect.fill()\n", "", "[icon color]", "checks"),
    ("pale gold on light bars", M, "            : NSColor(red: 0.537, green: 0.400, blue: 0.176, alpha: 1)", "            : NSColor(red: 0.788, green: 0.659, blue: 0.431, alpha: 1)", "[icon", "checks"),
    # Wiring.
    ("banner below the header", V, "                updateBanner\n                if hostedInActivity {", "                if hostedInActivity {", "[banner first]", "pins"),
    ("version card back", V, "                noticeBanner\n", "                updateRow\n                noticeBanner\n", "[version card]", "pins"),
    ("no check on panel open", V, "        .onAppear { model.panelOpenedForUpdates() }\n", "", "[panel open check]", "pins"),
    ("periodic loop bypasses the schedule", C, "                await self?.runScheduledAppUpdateCheck(.periodic)", "                await self?.checkForAppUpdate()", "[background checks]", "pins"),
    ("install without phases", C, "        guard !busy, appUpdateFlow.beginInstall() else { return }", "        guard !busy else { return }", "[install phases]", "pins"),
    ("manual check overlaps", C, "        if !holdsSlot, let running = appUpdateCheckRunning {\n            await running.value\n", "        if false, let running = appUpdateCheckRunning {\n            await running.value\n", "[no overlap]", "wiring"),
    # The code QA found (2026-10-09), both sites at once: the slot freed after the value, and a manual loop on it.
    ("the original spin (both sites)", C, [("""            await self?.checkForAppUpdate()
            self?.appUpdateCheckRunning = nil
            self?.appUpdateSchedule.finish()
        }
        // No suspension between the Task above and this line, so the task cannot have finished yet.
        appUpdateCheckRunning = check
        await check.value
""", """            await self?.checkForAppUpdate()
        }
        appUpdateCheckRunning = check
        await check.value
        appUpdateCheckRunning = nil
        appUpdateSchedule.finish()
"""), ("""        var holdsSlot = appUpdateSchedule.begin(.manual, now: Date())
        if !holdsSlot, let running = appUpdateCheckRunning {
            await running.value
            holdsSlot = appUpdateSchedule.begin(.manual, now: Date())
        }
        defer { if holdsSlot { appUpdateSchedule.finish() } }
""", """        while !appUpdateSchedule.begin(.manual, now: Date()) {
            if let running = appUpdateCheckRunning { await running.value } else { await Task.yield() }
        }
        defer { appUpdateSchedule.finish() }
""")], None, "[manual check spin]", "wiring"),
    ("manual frees a slot it does not hold", C, "        defer { if holdsSlot { appUpdateSchedule.finish() } }", "        defer { appUpdateSchedule.finish() }", "[", "pins"),
    ("dot on the lens, canvas kept", M, "            let dot = NSRect(x: rect.maxX - dotDiameter, y:", "            let dot = NSRect(x: rect.maxX - dotDiameter - dotRoom - 1, y:", "[icon dot", "checks"),  # [icon dot]: drawn in the corner; [icon dot clear]: that corner is clear of the glyph
    ("appUpdate does not move the flow", C, "        didSet { appUpdateFlow.offer(appUpdate, currentVersion: Self.currentVersion, currentBuild: Self.currentBuild) }\n", "", "[model wiring]", "pins"),
    ("label reads the raw result", A, "let variant = MenuBarIcon.variant(for: model.appUpdateFlow.phase)", "let variant: MenuBarIcon.Variant = model.appUpdate.shouldSurface ? .updateReady : .normal", "[icon follows state]", "pins"),
]


def run(lane, copy):
    if lane == "checks":
        out = pathlib.Path(tempfile.mkdtemp(prefix="cos-mut-badge-", dir="/tmp"))
        compile_cmd = ["/bin/zsh", str(copy / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6",
                       "-strict-concurrency=complete", "-parse-as-library", str(copy / M), str(copy / "Tests/AppUpdateBadgeChecks.swift"),
                       "-framework", "AppKit", "-o", str(out / "checks")]
        while True:
            p = subprocess.run(compile_cmd, capture_output=True, text=True)
            if p.returncode != 75:
                break
            time.sleep(30)
        if p.returncode != 0:
            shutil.rmtree(out, ignore_errors=True)
            return p.returncode, p.stdout + p.stderr
        home = out / "home"
        home.mkdir()
        try:
            q = subprocess.run([str(out / "checks")], capture_output=True, text=True, timeout=120,
                               env={"HOME": str(home), "CFFIXED_USER_HOME": str(home), "PATH": "/usr/bin:/bin"})
            return q.returncode, q.stdout + q.stderr
        except subprocess.TimeoutExpired:
            return 124, "the checks did not finish"
        finally:
            shutil.rmtree(out, ignore_errors=True)
    if lane == "wiring":
        while True:
            p = subprocess.run(["/bin/zsh", str(copy / "Tests/run-app-update-badge.sh"), "wiring"], capture_output=True, text=True, timeout=1800)
            if p.returncode != 75:
                return p.returncode, p.stdout + p.stderr
            time.sleep(30)
    p = subprocess.run(["/usr/bin/python3", str(copy / "Tests/app-update-badge-pins.py"), str(copy)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "dist", "*.zip"))
    for lane in ("checks", "wiring", "pins"):
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
