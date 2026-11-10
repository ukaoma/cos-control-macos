#!/usr/bin/env python3
"""Lane D1 (0.5.387) mutation gate: every new guard has a check that fails when the guard is broken.

    python3 Tests/mutate-d1-first-run.py [lane ...]      lanes: cohort connect permission gap dictcore (default: all)

Works on a scratch copy of the checkout (Sources, Tests, HelperSources, scripts, Resources), never the checkout itself.
First runs every chosen lane UNMUTATED and refuses to go on unless each is green (a red baseline would kill every mutant).
Then, per mutant: asserts the target text appears EXACTLY once, applies it, runs that mutant's lane, restores the file.
A mutant that the lane does not fail SURVIVES, and the run exits 1. Each compile goes through Tests/compile-guard.sh.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FLAGS = ["-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library"]


def lane_command(lane, copy, out):
    kit = ["/usr/bin/python3", str(copy / "Tests/kit-compile.py"), "/bin/zsh", str(copy / "Tests/compile-guard.sh"), "swiftc", *FLAGS]
    if lane == "cohort":
        return ["/bin/zsh", "-c", f'COS_INSTALL_COHORT_LANE=checks zsh "{copy}/Tests/run-install-cohort.sh"']
    if lane == "connect":
        build = kit + [str(copy / "Sources/ProviderConnectModel.swift"), str(copy / "Tests/ProviderConnectChecks.swift"), "-o", str(out / "connect")]
        home = out / "connect home.ü"
        home.mkdir(exist_ok=True)
        return ["/bin/zsh", "-c", " ".join(f"'{a}'" for a in build) + f' && CFFIXED_USER_HOME="{home}" HOME="{home}" "{out}/connect"']
    if lane == "permission":
        return ["/bin/zsh", str(copy / "Tests/run-permission-guide.sh")]
    if lane == "dictcore":
        build = kit + [str(copy / "HelperSources/ProviderStatusCore.swift"), str(copy / "Tests/DictationEveryoneChecks.swift"), "-o", str(out / "dictcore")]
        return ["/bin/zsh", "-c", " ".join(f"'{a}'" for a in build) + f' && "{out}/dictcore" "{copy}/Resources/VoiceBenchmark/speech-30s.txt"']
    if lane == "gap":
        return ["/bin/zsh", str(copy / "Tests/run-dictation-shortcut-gap.sh")]
    raise SystemExit(f"unknown lane {lane}")


PS = "HelperSources/ProviderStatusCore.swift"
IC, PC, PG, MD, MO = ("Sources/InstallCohort.swift", "Sources/ProviderConnectModel.swift", "Sources/PermissionGuideModel.swift",
                      "Sources/MacDictation.swift", "Sources/Models.swift")
MUTANTS = [
    # (name, lane, file, old, new)
    ("cohort: key lanes stored at launch is not existing", "cohort", IC,
     "        if evidence.keyLanesInstall != nil { return .existing }\n", ""),
    ("cohort: any last-seen build counts, this build's own too", "cohort", IC,
     "        if let seen = evidence.lastSeenBuild, seen != running { return .existing }\n",
     "        if evidence.lastSeenBuild != nil { return .existing }\n"),
    ("cohort: adoption overwrites a kept answer", "cohort", IC,
     "        if let stored, Cohort(rawValue: stored) != nil { return nil }\n", ""),
    ("cohort: adoption writes in a test host", "cohort", IC,
     "        guard isShippedApp, let cohort = adopt(", "        guard let cohort = adopt("),
    ("cohort: CohortDefault ignores the person's value", "cohort", IC,
     "        stored ?? (cohort == InstallCohort.Cohort.new.rawValue ? newInstall : existing)",
     "        (cohort == InstallCohort.Cohort.new.rawValue ? newInstall : existing)"),
    ("today: TodayHome.enabled ignores the cohort", "cohort", MO,
     '?? (defaults.string(forKey: installCohortKey) == "new")', "?? false"),
    ("install: the wait does not end when the CLI appears", "connect", PC,
     "            installing.remove(provider)\n            waiting[provider] = nil\n            notice = ProviderInstall.installedNotice(provider)",
     "            installing.remove(provider)\n            notice = ProviderInstall.installedNotice(provider)"),
    ("install: waits when Terminal never opened", "connect", PC,
     "            if opened { installing.insert(provider); waiting[provider] = Date() }",
     "            installing.insert(provider); waiting[provider] = Date()"),
    ("install: every agent installs with one click", "connect", PC,
     "static func oneClick(_ provider: AIProvider) -> Bool { provider == .claude }",
     "static func oneClick(_ provider: AIProvider) -> Bool { provider != .ollama }"),
    ("install: no Installing row", "connect", PC,
     "            if installing {\n                return ProviderRowModel(provider: provider, status: \"Installing…\",",
     "            if false {\n                return ProviderRowModel(provider: provider, status: \"Installing…\","),
    ("dictation: a capabilities timeout has no reason", "dictcore", PS,
     'details: ["action": "retry", "retryable": true, "reason": "server_no_answer"])\n        }\n        if status == 401',
     'details: ["action": "retry", "retryable": true])\n        }\n        if status == 401'),
    ("dictation: the timeout card says Server stopped again", "dictcore", PS,
     'static let noAnswerMessage = "The COS server did not answer in time. Try again."', 'static let noAnswerMessage = "Server stopped"'),
    ("dictation: an HTTP refusal has no reason", "dictcore", PS,
     '"retryable": passing,\n                                "reason": "http_\\(status)"])', '"retryable": passing])'),
    ("dictation: every 200 without text is empty_text", "dictcore", PS,
     '        return "engine_refused"\n', '        return "empty_text"\n'),
    ("gap: Start and stop alone does not count", "gap", MD,
     "enabled && !hold && !toggle }", "enabled && !hold }"),
    ("permission: a Microphone no is always Needs you", "permission", PG,
     "            row.status = facts.microphoneWanted ? .needsYou : .notNeededYet\n            row.detail = \"Turned off for COS Control in System Settings.\"\n            row.action = .openSettings(.microphone)",
     "            row.status = .needsYou\n            row.detail = \"Turned off for COS Control in System Settings.\"\n            row.action = .openSettings(.microphone)"),
    ("permission: unreadable System Audio guesses not asked", "permission", PG,
     "            row.detail = \"This Mac does not let COS read this setting. \" + systemAudioAsks",
     "            row.detail = systemAudioAsks"),
    ("permission: add-only Calendars reads as allowed", "permission", PG,
     '        case "writeOnly": self = .writeOnly', '        case "writeOnly": self = .allowed'),
    ("permission: the guide never reads the Microphone", "permission", PG,
     "        next.microphone = probes.microphone()\n", ""),
    ("permission: facts equality misses the Microphone", "permission", PG,
     "            && a.microphone == b.microphone && a.microphoneWanted == b.microphoneWanted\n",
     "            && a.microphoneWanted == b.microphoneWanted\n"),
]


def run(lane, copy, out):
    p = subprocess.run(lane_command(lane, copy, out), capture_output=True, text=True, cwd=copy)
    return p.returncode, (p.stdout + p.stderr)[-1500:]


def main():
    lanes = sys.argv[1:] or ["cohort", "connect", "permission", "gap", "dictcore"]
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="cos-d1-mutants-", dir="/tmp"))
    copy, out = scratch / "repo", scratch / "out"
    out.mkdir()
    for part in ("Sources", "Tests", "HelperSources", "scripts", "Resources", "docs"):
        if (ROOT / part).exists():
            shutil.copytree(ROOT / part, copy / part, symlinks=True)
    for top in ROOT.iterdir():   # the pins read some top-level files (THIRD_PARTY_NOTICES.md, LICENSE)
        if top.is_file():
            shutil.copy2(top, copy / top.name)
    try:
        for lane in lanes:
            code, tail = run(lane, copy, out)
            print(f"baseline {lane}: {'GREEN' if code == 0 else 'RED'}", flush=True)
            if code != 0:
                print(tail)
                print(f"REFUSED: the {lane} lane is red before any mutant")
                return 2
        survived, killed = [], 0
        for name, lane, rel, old, new in MUTANTS:
            if lane not in lanes:
                continue
            path = copy / rel
            original = path.read_text(encoding="utf-8")
            hits = original.count(old)
            if hits != 1:
                print(f"BROKEN MUTANT {name}: target found {hits} times in {rel}")
                return 3
            path.write_text(original.replace(old, new, 1), encoding="utf-8")
            try:
                code, tail = run(lane, copy, out)
            finally:
                path.write_text(original, encoding="utf-8")
            if code == 0:
                survived.append(name)
                print(f"SURVIVED {name}", flush=True)
            else:
                killed += 1
                last = [l for l in tail.splitlines() if "FAIL" in l or "failed" in l][-1:] or tail.splitlines()[-1:]
                print(f"killed   {name}: {last[0][:180] if last else ''}", flush=True)
        total = killed + len(survived)
        print(f"d1 mutants: {killed}/{total} killed")
        return 1 if survived else 0
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
