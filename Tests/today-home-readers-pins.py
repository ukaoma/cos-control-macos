#!/usr/bin/env python3
"""Lane D1 (0.5.387): every reader of the Today home key goes through the one rule (the person's value, else on for a new
install only), so no surface disagrees with the Activity window on a new install. Allowed:
- `@CohortDefault(TodayHome.enabledKey, ...)` in a View;
- `TodayHome.enabled(defaults)`, the only raw `forKey: enabledKey` read, inside Models.swift;
- the key's own definition `static let enabledKey = "activityTodayHomeEnabled"`.
Anything else in Sources/ or HelperSources/ (an @AppStorage, a bool/object/string(forKey:) read, the string literal) fails.
Comment lines are ignored. Tests/ is out of scope (fixtures write the key on purpose).
Prints "today home readers pins: N passed".
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
failed, passed, readers = [], 0, 0


def pin(ok, what):
    global passed
    if ok:
        passed += 1
    else:
        failed.append("FAIL " + what)


models_lines = (root / "Sources/Models.swift").read_text(encoding="utf-8").splitlines()
start = next(i for i, l in enumerate(models_lines, 1) if l.startswith("enum TodayHome {"))
end = next(i for i, l in enumerate(models_lines, 1) if i > start and l == "}")
today_block = range(start, end + 1)

for folder in ("Sources", "HelperSources"):
    for source in sorted((root / folder).glob("*.swift")):
        for number, raw in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
            line = raw.strip()
            if line.startswith("//"):
                continue
            where = f"{folder}/{source.name}:{number}"
            if "TodayHome.enabledKey" in line:
                readers += 1
                pin(line.startswith("@CohortDefault(TodayHome.enabledKey, newInstall: true)"), f"{where} reads the Today key raw: {line}")
            if '"activityTodayHomeEnabled"' in line:
                pin(source.name == "Models.swift" and line == 'static let enabledKey = "activityTodayHomeEnabled"', f"{where} spells the Today key: {line}")
            if source.name == "Models.swift" and number in today_block and re.search(r"forKey: enabledKey\b", line) and "quietHours" not in line and "workRuns" not in line:
                pin(line == 'defaults.object(forKey: enabledKey) as? Bool ?? (defaults.string(forKey: installCohortKey) == "new")',
                    f"{where} reads enabledKey outside TodayHome.enabled: {line}")
pin(readers >= 4, f"found only {readers} @CohortDefault readers of the Today key (expected Activity, Views, Settings hub, Work)")

if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print(f"today home readers pins: {passed} passed")
