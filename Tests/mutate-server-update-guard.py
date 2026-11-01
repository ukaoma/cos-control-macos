#!/usr/bin/env python3
"""Update Server's forward-only rule, mutation gate. SERIAL: one full helper compile at a time through Tests/compile-guard.sh
on a scratch copy (the checkout is never mutated), against Tests/server-update-guard-checks.py. A green baseline comes
first; each mutant must land exactly once, must fail, and must fail on the check named for it. Hand-run.
Usage: python3 Tests/mutate-server-update-guard.py <repo root>"""
import pathlib, shutil, subprocess, sys, tempfile, time

sys.stdout.reconfigure(line_buffering=True)
root = pathlib.Path(sys.argv[1]).resolve()
MAIN = "HelperSources/main.swift"
CORE = "HelperSources/ProviderStatusCore.swift"
FILES = [MAIN, CORE, "HelperSources/PairingCore.swift", "HelperSources/SessionUsageCollector.swift", "Sources/SessionUsageCore.swift", "Sources/WorkSessionLinks.swift"]
MUTANTS = [
    ("a named version is refused too", CORE, 'guard requested == "latest", let ahead', "guard let ahead", "a named older version still installs"),
    ("the same version counts as older", CORE, "return left.lexicographicallyPrecedes(right)", "return left.lexicographicallyPrecedes(right) || left == right", "the same version reinstalls"),
    ("versions compare as text", CORE, "return left.lexicographicallyPrecedes(right)", "return version < other", "a higher number in any place is newer"),
    ("newer latest refused", CORE, "isOlder(resolved, than: $0)", "isOlder($0, than: resolved)", "a stopped managed server newer than latest is refused"),
    ("the running server is ignored", MAIN, '[request("/api/health", timeout: 8)?.body?["server_version"] as? String, loadManifest()?.version].compactMap { $0 }', "[loadManifest()?.version].compactMap { $0 }", "a running server newer than latest is refused"),
    ("the manifest is ignored", MAIN, '[request("/api/health", timeout: 8)?.body?["server_version"] as? String, loadManifest()?.version].compactMap { $0 }', '[request("/api/health", timeout: 8)?.body?["server_version"] as? String].compactMap { $0 }', "a stopped managed server newer than latest is refused"),
    ("a legacy package is ignored", MAIN, "            versions.append(version)\n", "            _ = version\n", "a stopped legacy server package newer than latest is refused"),
    ("any package counts as the server", MAIN, 'package["name"] as? String == packageName, let version = package["version"] as? String {\n            versions.append', 'let version = package["version"] as? String {\n            versions.append', "a folder that is not the server package proves nothing"),
    ("a rollback hint with no managed server", MAIN, "canRollBack: ServerUpdateGuard.canRollBack(hasManifest: manifest != nil, retained: retained)) {", "canRollBack: true) {", "no rollback hint without a managed server"),
    ("a rollback hint with nothing retained", MAIN, "canRollBack: ServerUpdateGuard.canRollBack(hasManifest: manifest != nil, retained: retained)) {", "canRollBack: manifest != nil) {", "no rollback hint when the manifest retains nothing to roll back to"),
]


def build_and_check(work):
    out = work / "helper"
    for _ in range(60):
        if out.exists(): out.unlink()
        build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0",
                                "-swift-version", "6", "-strict-concurrency=complete", *[str(work / f) for f in FILES], "-framework", "Security", "-framework", "AppKit", "-o", str(out)],
                               capture_output=True, text=True)
        if build.returncode in (70, 75):
            time.sleep(30); continue
        if build.returncode != 0: return 2, (build.stdout + build.stderr)[-1500:]
        run = subprocess.run([sys.executable, str(root / "Tests/server-update-guard-checks.py"), str(out)], capture_output=True, text=True)
        return (0 if run.returncode == 0 else 1), run.stdout + run.stderr
    sys.exit("shared compile lock stayed busy for 30 minutes")


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-update-guard-mutants-", dir="/private/tmp"))
try:
    for name in FILES:
        (work / name).parent.mkdir(parents=True, exist_ok=True); shutil.copy(root / name, work / name)
    originals = {name: (work / name).read_text() for name in (MAIN, CORE)}
    code, output = build_and_check(work)
    if code != 0: sys.exit("baseline is not green:\n" + output[-2000:])
    print("GREEN BASELINE: the update guard checks pass unmutated")
    survivors, misattributed = [], []
    for name, target, old, new, label in MUTANTS:
        if originals[target].count(old) != 1: sys.exit(f"mutant '{name}' targets {originals[target].count(old)} sites")
        (work / target).write_text(originals[target].replace(old, new))
        code, output = build_and_check(work)
        if code == 2: verdict = "KILLED (did not compile)"
        elif code == 0: verdict = "SURVIVED"; survivors.append(name)
        elif f"Fatal error: {label}" in output: verdict = "KILLED"
        else: verdict = "MISATTRIBUTED"; misattributed.append(f"{name}: {output.strip()[-200:]}")
        print(f"{verdict:24} {name}")
        (work / target).write_text(originals[target])
    if survivors or misattributed: sys.exit(f"survivors: {survivors}; misattributed: {misattributed}")
    print(f"PASS update guard mutation gate: {len(MUTANTS)} mutants, all killed by their named checks, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
