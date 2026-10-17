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
import os
import pathlib, shutil, subprocess, sys, time

M = "Sources/PermissionGuideModel.swift"
C = "Sources/ControllerModel.swift"
V = "Sources/Views.swift"
F = "Sources/PermissionDragFlow.swift"
R = "scripts/build-release.sh"
D = "Sources/MacDictation.swift"
DC = "Sources/MacDictationCore.swift"
MR = "Sources/MacRecording.swift"
A = "Sources/COSControlApp.swift"
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
    ("reset keeps the old build", M, "        defaults.removeObject(forKey: Self.lastTrustedBuildKey)\n        if let reset = resetOwnAccessibility {", "        if let reset = resetOwnAccessibility {", "[reset and add again]", "logic"),
    ("drag source hardcoded", M, "        let source = PermissionDragSource(path: appPath, name: appName)\n        var row = PermissionRow(\n            id: \"accessibility\"",
     "        let source = PermissionDragSource(path: \"/Applications/COS Control.app\", name: appName)\n        var row = PermissionRow(\n            id: \"accessibility\"", "[drag source]", "logic"),
    # Wiring.
    ("jump resume dropped", C, "            let resume = accessibilityResume\n            accessibilityResume = nil\n", "            let resume: (@MainActor () -> Void)? = nil\n", "[pet jump hook]", "pins"),
    ("no panel row", V, "                PanelPermissionsRow(guide: model.permissionGuide)\n", "", "[panel row]", "pins"),
    ("live probes in checks", C, "probes: inApp ? .live() : .inert", "probes: .live()", "[live probes]", "pins"),
    ("meeting hook gone", C, '                permissionGuide.need(.notifications, for: "Meeting alerts", interactive: false)\n', "", "[meeting alerts hook]", "pins"),
    ("background hook opens a window", C, 'need(.backgroundJobs, for: "Your scheduled COS jobs", interactive: false)', 'need(.backgroundJobs, for: "Your scheduled COS jobs", interactive: true)', "[background jobs hook]", "pins"),
    ("poll every five seconds", F, "withTimeInterval: 1, repeats: true", "withTimeInterval: 5, repeats: true", "[detection poll]", "pins"),
    ("the API alone says Allowed", F, "AXIsProcessTrusted() && Self.accessibilityReadWorks()", "AXIsProcessTrusted()", "[detection confirm]", "pins"),
    ("license left out of the app", R, 'cp -R "$ROOT/Resources/ThirdParty/." "$APP/Contents/Resources/ThirdParty/"\n', "", "[license]", "pins"),
    # 0.5.318: a feature's own Allow (the dictation card, System Audio Recording). Logic.
    ("ask route never uses the guide", M, "return guideLive ? .guide : .promptThenPane", "return .promptThenPane", "[ask route]", "logic"),
    ("ask route flows when allowed", M, "        if allowed { return .alreadyAllowed }\n", "", "[ask route]", "logic"),
    ("preflight 1 not denied", M, "case 1: self = .denied", "case 1: self = .notAsked", "[system audio fact]", "logic"),
    ("preflight 0 not allowed", M, "case 0: self = .allowed\n        case 1: self = .denied", "case 0: self = .notAsked\n        case 1: self = .denied", "[system audio fact]", "logic"),
    ("a denied app prompted again", M, "if fact == .notAsked, !asked { return .prompt }", "if fact != .allowed, !asked { return .prompt }", "[system audio drag fallback]", "logic"),
    ("a second prompt after asking", M, "if fact == .notAsked, !asked { return .prompt }", "if fact == .notAsked { return .prompt }", "[system audio drag fallback]", "logic"),
    ("allowed ignores the pane asked for", M, "if fact == .allowed { return wantsPane ? .openPane : .done }", "if fact == .allowed { return .done }", "[system audio pane wanted]", "logic"),
    ("no drag fallback", M, "return guideLive ? .guide : .openPane", "return .openPane", "[system audio drag fallback]", "logic"),
    ("audio anchor on 15", M, "macOSMajor >= 26", "macOSMajor >= 15", "[system audio pane]", "logic"),
    ("system audio pane takes no drag", M, " || self == .systemAudio }", " }", "[system audio pane]", "logic"),
    ("system audio resume dropped", M, "        if let resume { resumes[request.rowID, default: []].append(resume) }\n", "", "[system audio drag resume]", "logic"),
    ("system audio drag holds another copy", M, "source: PermissionDragSource(path: appPath, name: appName), feature: feature)",
     'source: PermissionDragSource(path: "/Applications/COS Control.app", name: appName), feature: feature)', "[system audio drag]", "logic"),
    ("system audio bar names nothing", M, "        waitingFeature[request.rowID] = feature\n", "", "[system audio drag]", "logic"),
    # Wiring.
    ("card Allow skips the guide", D, "        ask { [weak self] in self?.insertionAllowed() }\n", "        _ = ask\n", "[dictation allow route]", "pins"),
    ("card stays after the grant", D, "        if case .copied(.notTrusted) = card?.kind { dismissCard() }\n", "", "[dictation allow resume]", "pins"),
    ("card has no Reset", D, '                        Button("Reset") { store.resetInsertionPermission() }\n', "", "[dictation reset]", "pins"),
    ("card note says nothing about an ON row", DC, "Already on? Reset and add again. For now", "For now", "[dictation reset]", "pins"),
    ("card Allow is the bare prompt", C, "            if permissionGuide.need(.accessibility, for: Self.dictationAccessibilityFeature, resume: resume) { resume() }\n",
     '            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)\n', "[dictation allow route]", "pins"),
    ("Reset drops a waiting jump", C, "accessibilityResume = { waiting?(); resume() }", "accessibilityResume = resume", "[dictation reset]", "pins"),
    ("system audio never prompts", C, "            let granted = await SystemAudioPermission.request()\n", "            let granted = false\n", "[system audio request]", "pins"),
    ("system audio denied opens a bare link", C, "            permissionGuide.drag(.systemAudio, for: feature, resume: resume)\n",
     "            NSWorkspace.shared.open(PermissionPane.systemAudio.settingsURL())\n", "[system audio drag fallback]", "pins"),
    ("system audio request unbounded", D, "try? await Task.sleep(for: timeout)", "try? await Task.sleep(for: .seconds(100_000))", "[system audio request]", "pins"),
    ("bar never sees the audio grant", F, "case .systemAudio: SystemAudioPermission.fact == .allowed", "case .systemAudio: grantedByCheck", "[system audio detection]", "pins"),
    ("Mute setting back to a bare link", D, "                Task { permitted = await store.requestSystemAudioPermission() }\n",
     '                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }\n',
     "[system audio settings]", "pins"),
    ("recording never asks", MR, "if !DictationQuietController.tapPermitted, let ask = requestSystemAudio {", "if false, let ask = requestSystemAudio {", "[recording asks]", "pins"),
    ("recording asks twice at once", MR, "            guard !askingSystemAudio else { return }\n", "", "[recording asks]", "pins"),
    ("recording not wired", A, '        model.macRecording.requestSystemAudio = { [weak model] in await model?.requestSystemAudio(for: "All Mac audio") ?? false }\n', "",
     "[feature ask wiring]", "pins"),
    ("a waiting feature's name kept forever", C, "            accessibilityFeature = nil\n", "", "[pet jump hook]", "pins"),
]


def run(lane, copy):
    if lane == "logic":
        cmd = ["/bin/zsh", str(copy / "Tests/run-permission-guide.sh")]  # its one compile goes through the guard
    else:
        cmd = ["/usr/bin/python3", str(copy / "Tests/permission-guide-pins.py"), str(copy)]
    while True:
        p = subprocess.run(cmd, capture_output=True, text=True)
        # 75: the guard's lock wait timed out (another agent compiling). Contention, not a verdict: wait and retry.
        if p.returncode == 75:
            time.sleep(30)
            continue
        return p.returncode, p.stdout + p.stderr


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    # Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
    os.environ.setdefault("COS_TEST_KIT_DIR", str(scratch / "kits"))
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
