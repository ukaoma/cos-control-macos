#!/usr/bin/env python3
"""Mutation lane for the permission guide's guards. Run by hand, never by a gate. SERIAL: one mutant at a time, and every
compile goes through Tests/compile-guard.sh (two kernel panics on 2026-10-07 came from parallel compiles).

    python3 Tests/mutate-permission-guide.py <worktree> <scratch dir> [name ...]

It copies the worktree once to <scratch dir>/copy, proves the UNMUTATED copy green first (a red baseline makes every
mutant look killed), then applies one mutant at a time: the target text must appear exactly once, the mutant must make
a check fail, and the failure must name the behaviour the mutant breaks ("check failed [<behaviour>]" from
Tests/PermissionGuideChecks.swift or "pin failed [<behaviour>]" from Tests/permission-guide-pins.py). A mutant that
lands and survives is a finding. The "logic" lane compiles the model with its checks (small); "pins" runs Python only.
"""
import pathlib, shutil, subprocess, sys, time

M = "Sources/PermissionGuideModel.swift"
C = "Sources/ControllerModel.swift"
V = "Sources/Views.swift"
F = "Sources/PermissionDragFlow.swift"
R = "scripts/build-release.sh"
# (name, file, original, mutant, words the killing failure must contain, lane)
MUTANTS = [
    ("exit 78 not read", M, "if jobs.contains(where: { $0.lastExit == 78 }) { return .needsYou }", "if jobs.contains(where: { $0.lastExit == 77 }) { return .needsYou }", "[job status]", "logic"),
    ("a job that never ran counts as allowed", M, "$0.running || (($0.runs ?? 0) > 0 && $0.lastExit != nil)", "$0.running || $0.lastExit != nil || $0.runs != nil", "[job status]", "logic"),
    ("a wanted feature ignored", M, "row.status = facts.accessibilityWanted || facts.staleGrantSuspected ? .needsYou : .notNeededYet", "row.status = facts.staleGrantSuspected ? .needsYou : .notNeededYet", "[accessibility status]", "logic"),
    ("denied notifications read as not needed", M, "        case .denied:\n            row.status = .needsYou\n            row.action = .openSettings(.notifications)", "        case .denied:\n            row.status = .notNeededYet\n            row.action = .openSettings(.notifications)", "[notifications status]", "logic"),
    ("summary grammar", M, 'case 1: return "1 needs you"', 'case 1: return "1 need you"', "[panel summary]", "logic"),
    ("background rows for unprotected jobs", M, "for job in jobs where job.readsProtectedFolder {", "for job in jobs {", "[row relevance]", "logic"),
    ("bar closes at once", M, "guard let at = allowedAt, now - at >= Self.closeAfterAllowed else { return [] }", "guard let at = allowedAt, now - at >= 0 else { return [] }", "[bar close delay]", "logic"),
    ("no launch grace", M, "if !settingsOpen, now - startedAt >= Self.launchGrace {", "if !settingsOpen {", "[bar launch grace]", "logic"),
    ("trouble after one minute", M, "static let troubleAfter: TimeInterval = 120", "static let troubleAfter: TimeInterval = 60", "[bar trouble]", "logic"),
    ("a grant never lands", M, "            if granted {\n", "            if granted && false {\n", "[bar grant]", "logic"),
    ("need picks an allowed row", M, "guard let row = rows.first(where: { $0.kind == kind && $0.status != .allowed }) else { return true }", "guard let row = rows.first(where: { $0.kind == kind }) else { return true }\n        if row.status == .allowed { return true }", "[just in time]", "logic"),
    ("a background need opens a flow", M, "        if interactive {\n            perform(row, feature: feature)", "        if true {\n            perform(row, feature: feature)", "[just in time background]", "logic"),
    ("a resume runs twice", M, "let pending = resumes.removeValue(forKey: rowID) ?? []", "let pending = resumes[rowID] ?? []", "[just in time resume]", "logic"),
    ("the running build listed as stale", M, "guard prefixes.contains(where: { id.hasPrefix($0) }), id != runningID,", "guard prefixes.contains(where: { id.hasPrefix($0) }),", "[stale discovery]", "logic"),
    ("an unlisted build reset", M, "guard staleBuilds?.contains(where: { $0.bundleID == id }) == true, id != bundleID else { return }", "guard id != bundleID else { return }", "[stale reset]", "logic"),
    ("any old trusted build means stale", M, "return last != 0 && last != currentBuild", "return last != 0", "[stale grant]", "logic"),
    ("exec read as the interpreter", M, 'shellWords(arguments[flag + 1]).first(where: { $0 != "exec" && !isAssignment($0) }) ?? first', "shellWords(arguments[flag + 1]).first(where: { !isAssignment($0) }) ?? first", "[interpreter]", "logic"),
    ("plist backups read as jobs", M, 'name.hasPrefix("com.cos.") && name.hasSuffix(".plist")', 'name.hasPrefix("com.cos.") && name.contains(".plist")', "[agent files]", "logic"),
    ("nested launchd state read", M, 'guard raw.hasPrefix("\\t"), !raw.hasPrefix("\\t\\t") else { continue }', 'guard raw.hasPrefix("\\t") else { continue }', "[launchctl print]", "logic"),
    ("a calendar refusal skipped", M, 'case "swift_permission_or_calendar_error": return .denied', 'case "swift_permission_or_calendar_error": continue', "[calendar log]", "logic"),
    ("reset keeps the old build", M, "        defaults.removeObject(forKey: Self.lastTrustedBuildKey)\n        startDragFlow?(request)", "        startDragFlow?(request)", "[reset and add again]", "logic"),
    ("drag source hardcoded", M, "        let source = PermissionDragSource(path: appPath, name: appName)\n        var row = PermissionRow(\n            id: \"accessibility\"",
     "        let source = PermissionDragSource(path: \"/Applications/COS Control.app\", name: appName)\n        var row = PermissionRow(\n            id: \"accessibility\"", "[drag source]", "logic"),
    # Wiring.
    ("jump resume dropped", C, "            let resume = accessibilityResume\n            accessibilityResume = nil\n", "            let resume: (@MainActor () -> Void)? = nil\n", "[pet jump hook]", "pins"),
    ("no panel row", V, "                PanelPermissionsRow(guide: model.permissionGuide)\n", "", "[panel row]", "pins"),
    ("live probes in checks", C, "probes: inApp ? .live() : .inert", "probes: .live()", "[live probes]", "pins"),
    ("meeting hook gone", C, '                permissionGuide.need(.notifications, for: "Meeting alerts", interactive: false)\n', "", "[meeting alerts hook]", "pins"),
    ("background hook opens a window", C, 'need(.backgroundJobs, for: "Background jobs", interactive: false)', 'need(.backgroundJobs, for: "Background jobs", interactive: true)', "[background jobs hook]", "pins"),
    ("poll every five seconds", F, "withTimeInterval: 1, repeats: true", "withTimeInterval: 5, repeats: true", "[detection poll]", "pins"),
    ("the API alone says Allowed", F, "AXIsProcessTrusted() && Self.accessibilityReadWorks()", "AXIsProcessTrusted()", "[detection confirm]", "pins"),
    ("license left out of the app", R, 'cp -R "$ROOT/Resources/ThirdParty/." "$APP/Contents/Resources/ThirdParty/"\n', "", "[license]", "pins"),
]


def run(lane, copy):
    if lane == "logic":
        cmd = [str(copy / "Tests/compile-guard.sh"), str(copy / "Tests/run-permission-guide.sh")]
    else:
        cmd = ["/usr/bin/python3", str(copy / "Tests/permission-guide-pins.py"), str(copy)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "dist", "*.zip"))
    for lane in ("logic", "pins"):
        code, out = run(lane, copy)
        if code != 0:
            sys.exit(f"baseline {lane} lane is RED; no mutant can be judged:\n{out[-3000:]}")
        print(f"baseline {lane}: green")
    survived, results = [], []
    for name, rel, original, mutant, words, lane in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        n = text.count(original)
        if n != 1:
            results.append(f"MISSED TARGET ({n}x) {name}")
            survived.append(name)
            continue
        path.write_text(text.replace(original, mutant), encoding="utf-8")
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
            results.append(f"killed  {name}  ({words}, {took:.0f}s)")
        elif "error:" in out:
            results.append(f"killed by the compiler  {name}")
        else:
            results.append(f"killed by another check  {name}: {out.strip().splitlines()[-1][:160]}")
    print("\n".join(results))
    print(f"{len(results) - len(survived)} of {len(results)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
