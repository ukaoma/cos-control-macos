#!/usr/bin/env python3
"""0.5.318 (2026-10-16: the 0.5.317 signed build failed to compile, and eight lanes before it, because compiles that
list Sources by hand lacked the Work merge's WorkChatQueue.swift and WorkReferences.swift): compile commands that name
Sources/*.swift one by one must not fall behind Sources/.

    python3 Tests/sources-list-check.py <control worktree> [--selftest]

Rule 1: the app compile in scripts/build-release.sh (the swiftc that lists ControllerModel.swift) lists EVERY
Sources/*.swift file, COSControlApp.swift included.
Rule 2: every other hand-listed compile that lists ControllerModel.swift (scripts/*.sh and Tests/*.sh) lists at least
the app-core set: every Sources/*.swift except COSControlApp.swift (each lane brings its own @main), ControlSetup.swift
and ControlInstance.swift (Tests/kit-compile.py's 'app-core'). A compile that takes Sources by glob is not hand-listed.
Each missing file is named with the script it is missing from.
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1]).resolve(); selftest = "--selftest" in sys.argv[2:]
ANCHOR = "ControllerModel.swift"
NOT_CORE = {"COSControlApp.swift", "ControlSetup.swift", "ControlInstance.swift"}


def commands(text: str) -> list[str]:
    """Each swiftc command, its backslash continuations joined into one line."""
    joined = re.sub(r"\\\n", " ", text)
    return [line for line in joined.splitlines() if "swiftc" in line and not line.lstrip().startswith("#")]


def listed(command: str) -> set[str]:
    return set(re.findall(r'Sources/([A-Za-z0-9_+-]+\.swift)', command))


def check(sources: set[str], scripts: dict[str, str]) -> list[str]:
    core = sources - NOT_CORE
    problems, release_seen = [], False
    for name, text in sorted(scripts.items()):
        for command in commands(text):
            files = listed(command)
            if ANCHOR not in files: continue
            if name == "scripts/build-release.sh":
                release_seen = True
                problems += [f"{name}: the app compile does not list Sources/{f}" for f in sorted(sources - files)]
            else:
                problems += [f"{name}: a compile that lists ControllerModel.swift does not list Sources/{f}" for f in sorted(core - files)]
    if not release_seen: problems.append("scripts/build-release.sh: no app compile listing ControllerModel.swift was found")
    return problems


if selftest:
    src = {"Models.swift", "ControllerModel.swift", "WorkChatQueue.swift", "COSControlApp.swift", "ControlSetup.swift", "ControlInstance.swift"}
    full = " ".join(f'"$ROOT/Sources/{f}"' for f in sorted(src))
    lane = " ".join(f'"$ROOT/Sources/{f}"' for f in sorted(src - NOT_CORE))
    good = {"scripts/build-release.sh": f"swiftc \\\n {full} -o app", "Tests/run-x.sh": f"swiftc {lane} -o x", "Tests/run-glob.sh": 'swiftc "${SOURCES[@]}" -o g'}
    assert check(src, good) == [], check(src, good)
    dropped = dict(good, **{"scripts/build-release.sh": good["scripts/build-release.sh"].replace('"$ROOT/Sources/WorkChatQueue.swift"', "")})
    assert check(src, dropped) == ["scripts/build-release.sh: the app compile does not list Sources/WorkChatQueue.swift"], "a file dropped from the release compile is named"
    lane_dropped = dict(good, **{"Tests/run-x.sh": good["Tests/run-x.sh"].replace('"$ROOT/Sources/WorkChatQueue.swift"', "")})
    assert check(src, lane_dropped) == ["Tests/run-x.sh: a compile that lists ControllerModel.swift does not list Sources/WorkChatQueue.swift"], "a file dropped from a lane is named"
    assert check(src | {"New.swift"}, good) == ["Tests/run-x.sh: a compile that lists ControllerModel.swift does not list Sources/New.swift",
                                               "scripts/build-release.sh: the app compile does not list Sources/New.swift"], "a new Sources file must be added to both"
    assert check(src, {"Tests/run-x.sh": good["Tests/run-x.sh"]}) == ["scripts/build-release.sh: no app compile listing ControllerModel.swift was found"]
    assert check(src, dict(good, **{"Tests/run-models.sh": 'swiftc "$ROOT/Sources/Models.swift" -o m'})) == [], "a compile without ControllerModel.swift is not held to the app-core set"
    print("PASS sources list check self-test: release and lane drops named, a new Sources file, a missing release compile, globbed and partial compiles left alone")
    sys.exit(0)

sources = {p.name for p in (root / "Sources").glob("*.swift")}
scripts = {str(p.relative_to(root)): p.read_text() for d in ("scripts", "Tests") for p in sorted((root / d).glob("*.sh"))}
problems = check(sources, scripts)
if problems: sys.exit("sources list check failed:\n  " + "\n  ".join(problems))
held = sum(1 for t in scripts.values() for c in commands(t) if ANCHOR in listed(c))
print(f"PASS sources list check: {len(sources)} Sources files; the release app compile lists all of them, and {held - 1} other hand-listed compiles list the app-core set")
