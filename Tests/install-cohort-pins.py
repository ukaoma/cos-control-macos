#!/usr/bin/env python3
"""Lane D1 (0.5.387): InstallCohort wiring pins. Python only, no compile.

- The keys InstallCohort spells for itself equal the ones their owners write (WhatsNewAfterUpdate, KeyLanes, TodayHome).
- Every app compile (a swiftc command with ControllerModel.swift) also compiles Sources/InstallCohort.swift.
- Decided at launch in SetupWindowPresenter's init; KeyLanes' answer adopted in ControlSetupView beside the latch.
- Defaults are read lazily and never written (COORD 2026-11-09 19:12): no writer of the Today key, and the readers this
  lane owns go through CohortDefault / TodayHome.enabled.
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


def code(text):
    return "\n".join(line for line in text.splitlines() if not line.strip().startswith("//"))


cohort = read("Sources/InstallCohort.swift")
models = read("Sources/Models.swift")
lanes = read("Sources/KeyLanes.swift")
today = models[models.index("enum TodayHome {"):]

# Mirrored keys.
seen = re.search(r'static let defaultsKey = "([^"]+)"', models[models.index("enum WhatsNewAfterUpdate"):])
pin(seen and f'static let lastSeenBuildKey = "{seen.group(1)}"' in cohort, "keys", "lastSeenBuildKey equals WhatsNewAfterUpdate.defaultsKey")
prior = re.search(r"static let priorSetupKeys = (\[[^\]]+\])", lanes)
pin(prior and f"static let priorSetupKeys = {prior.group(1)}" in cohort, "keys", "priorSetupKeys equals KeyLanes.priorSetupKeys")
install = re.search(r'static let installKey = "([^"]+)"', lanes)
pin(install and f'static let keyLanesInstallKey = "{install.group(1)}"' in cohort, "keys", "keyLanesInstallKey equals KeyLanes.installKey")
pin('static let key = "cos.install.cohort"' in cohort, "keys", "the cohort key is cos.install.cohort")
pin('static let installCohortKey = "cos.install.cohort"' in today, "keys", "TodayHome.installCohortKey equals InstallCohort.key")
pin(re.search(r"enum Install: String, Equatable \{ case new, existing \}", lanes) is not None, "keys", "KeyLanes.Install's raw values are new and existing")

# Every app compile carries the file.
commands = 0
for script in list((root / "Tests").glob("*.sh")) + list((root / "scripts").glob("*.sh")):
    text = script.read_text(encoding="utf-8")
    for command in [line for line in text.replace("\\\n", " ").splitlines() if "swiftc" in line]:
        if '"$ROOT/Sources/ControllerModel.swift"' in command:
            commands += 1
            pin('"$ROOT/Sources/InstallCohort.swift"' in command, "source lists", f"{script.name} compiles ControllerModel without InstallCohort.swift")
pin(commands >= 10, "source lists", f"found only {commands} app compiles (expected at least 10)")

# Launch and adoption hooks.
setup = read("Sources/ControlSetup.swift")
presenter = setup[setup.index("final class SetupWindowPresenter"):setup.index("func show(model: ControllerModel)")]
pin("InstallCohort.decideAtLaunch()" in presenter, "launch", "SetupWindowPresenter's init decides the cohort")
view = setup[setup.index("struct ControlSetupView: View {"):]
pin(re.search(r"\.background\(KeyLanesInstallLatch\(model: model\)\)\s*(//[^\n]*\n\s*)*\.onReceive\(KeyLanesStore\.shared\.\$install\) \{ InstallCohort\.adoptKeyLanes\(\$0\?\.rawValue\) \}", view)
    is not None, "adopt", "ControlSetupView adopts KeyLanes' answer right beside the latch that decides it")

# The writers: only cos.install.cohort, only in the shipped app.
writer_lines = [l for l in code(cohort).splitlines() if ".set(" in l]
pin(len(writer_lines) == 2 and all("forKey: key)" in l for l in writer_lines), "writes", f"InstallCohort writes only cos.install.cohort: {writer_lines}")
pin(code(cohort).count("guard isShippedApp") == 2, "writes", "both writers run only in the shipped app")

# Lazy defaults: nothing writes the Today key's default; the readers this lane owns read the cohort.
for source in sorted((root / "Sources").glob("*.swift")):
    for number, line in enumerate(code(source.read_text(encoding="utf-8")).splitlines(), 1):
        if re.search(r"\.set\((true|false), forKey: (TodayHome\.enabledKey|\"activityTodayHomeEnabled\")\)", line):
            pin(False, "lazy", f"{source.name}:{number} writes the Today home key: {line.strip()}")
pin("defaults.object(forKey: enabledKey) as? Bool ?? (defaults.string(forKey: installCohortKey) == \"new\")" in today,
    "lazy", "TodayHome.enabled: the stored value, else on only for a new install")
activity = read("Sources/ActivityWindow.swift")
pin("@CohortDefault(TodayHome.enabledKey, newInstall: true) private var todayEnabled" in activity
    and "@AppStorage(TodayHome.enabledKey)" not in activity, "lazy", "the Today frame reads through CohortDefault")
pin("stored ?? (cohort == InstallCohort.Cohort.new.rawValue ? newInstall : existing)" in cohort, "lazy", "CohortDefault: the stored value first")

if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print(f"install cohort pins: {passed} passed")
