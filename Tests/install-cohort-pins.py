#!/usr/bin/env python3
"""Lane D1 (0.5.387): InstallCohort wiring pins. Python only, no compile.

- The keys InstallCohort spells for itself equal the ones their owners write (WhatsNewAfterUpdate, KeyLanes).
- Every app compile (a swiftc command with ControllerModel.swift) also compiles Sources/InstallCohort.swift.
- The launch decision is called from SetupWindowPresenter's init (ControlSetup.swift), before any window or status read.
Prints "install cohort pins: N passed".
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
failed, passed = [], 0


def pin(ok, area, what):
    global passed
    if ok:
        passed += 1
    else:
        failed.append(f"FAIL [{area}] {what}")


def read(rel):
    return (root / rel).read_text(encoding="utf-8")


cohort = read("Sources/InstallCohort.swift")
models = read("Sources/Models.swift")
lanes = read("Sources/KeyLanes.swift")

# Mirrored keys.
seen = re.search(r'static let defaultsKey = "([^"]+)"', models[models.index("enum WhatsNewAfterUpdate"):])
pin(seen and f'static let lastSeenBuildKey = "{seen.group(1)}"' in cohort, "keys", "lastSeenBuildKey equals WhatsNewAfterUpdate.defaultsKey")
prior = re.search(r"static let priorSetupKeys = (\[[^\]]+\])", lanes)
pin(prior and f"static let priorSetupKeys = {prior.group(1)}" in cohort, "keys", "priorSetupKeys equals KeyLanes.priorSetupKeys")
install = re.search(r'static let installKey = "([^"]+)"', lanes)
pin(install and f'static let keyLanesInstallKey = "{install.group(1)}"' in cohort, "keys", "keyLanesInstallKey equals KeyLanes.installKey")
pin('static let key = "cos.install.cohort"' in cohort, "keys", "the cohort key is cos.install.cohort")

# The file compiles alone: Foundation only, nothing from the app.
pin(re.findall(r"^import (\w+)", cohort, re.M) == ["Foundation"], "standalone", "InstallCohort.swift imports Foundation only")

# Every app compile carries the file.
commands = 0
for script in list((root / "Tests").glob("*.sh")) + list((root / "scripts").glob("*.sh")):
    text = script.read_text(encoding="utf-8")
    for command in [line for line in text.replace("\\\n", " ").splitlines() if "swiftc" in line]:
        if '"$ROOT/Sources/ControllerModel.swift"' in command:
            commands += 1
            pin('"$ROOT/Sources/InstallCohort.swift"' in command, "source lists", f"{script.name} compiles ControllerModel without InstallCohort.swift")
pin(commands >= 10, "source lists", f"found only {commands} app compiles (expected at least 10)")

# The launch hook.
setup = read("Sources/ControlSetup.swift")
presenter = setup[setup.index("final class SetupWindowPresenter"):setup.index("func show(model: ControllerModel)")]
pin("InstallCohort.decideAtLaunch()" in presenter, "launch", "SetupWindowPresenter's init decides the cohort")

if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print(f"install cohort pins: {passed} passed")
