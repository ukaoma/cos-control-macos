#!/usr/bin/env python3
"""Speed plan A3 (2026-10-31): proves every check in Tests/preflight.sh can fail.

    mutate-preflight.py <checkout>        hand-run, serial, no Swift compile

The green baseline comes first: the whole preflight must pass on a scratch checkout (symlinks to the real files, so the 1.2 GB
Resources folder is not copied). Then, for each check, ONE defect is planted in a scratch copy of the files that check reads
(the mutation must land exactly once) and only that check is run (COS_PREFLIGHT_ONLY=<id>): it must fail by name. A mutant that
the check does not catch is a finding, and the exit status says so.
"""
import importlib.util
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent).resolve()
spec = importlib.util.spec_from_file_location("preflight_pins", root / "Tests/preflight-pins.py")
pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pins)


def edit(path, old, new, count=1):
    text = path.read_text()
    if text.count(old) != count:
        raise SystemExit(f"mutation target lands {text.count(old)} times in {path.name}, not {count}: {old[:70]!r}")
    path.write_text(text.replace(old, new))


def append(path, text):
    with open(path, "a") as stream:
        stream.write(text)


def bump_build(scratch):
    path = scratch / "Resources/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info["CFBundleVersion"] = str(int(info["CFBundleVersion"].split(".")[0]) + 1)
    path.write_bytes(plistlib.dumps(info))


def first_png():
    return str(sorted((root / "Resources/BundledCharacters/jedi-miles-windu").glob("*.png"))[0].relative_to(root))


# id, files the check reads that the mutation touches (copied, not linked), the mutation
MUTANTS = [
    ("whats-new", ["Tests/run.sh"], lambda s: edit(s / "Tests/run.sh", '"$ROOT/Tests/run-whats-new.sh"\n', "")),
    ("label-alignment", ["Sources/Views.swift"], lambda s: append(s / "Sources/Views.swift", '\nHStack(alignment: .top) {\n    Image(systemName: "x")\n    Text("y")\n}\n')),
    ("label-alignment-selftest", ["Tests/label-alignment-guard.py"], lambda s: edit(s / "Tests/label-alignment-guard.py", r"\.(top|firstTextBaseline|lastTextBaseline)\b[^{]*\{", r"\.(firstTextBaseline|lastTextBaseline)\b[^{]*\{")),
    ("jedi-v15-pack", ["Resources/DefaultPet/session-pet-states.json"], lambda s: append(s / "Resources/DefaultPet/session-pet-states.json", " ")),
    ("illustrated-pack", [first_png()], lambda s: open(s / first_png(), "ab").write(b"\0")),
    ("build-number", ["Sources/ControllerModel.swift"], lambda s: edit(s / "Sources/ControllerModel.swift",
        'static var currentBuild: Int { parseBuild(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) }',
        'static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }')),
    ("version", ["Resources/Info.plist"], bump_build),
    ("duplicates", ["Sources/Models.swift"], lambda s: (s / "Sources/Models 2.swift").write_text("// conflict copy\n")),
    ("negated-pins", ["Tests/run.sh"], lambda s: append(s / "Tests/run.sh", '\n! /usr/bin/grep -q \'x\' "$ROOT/Sources/Views.swift"\n')),
    ("source-greps", ["Sources/Models.swift"], lambda s: append(s / "Sources/Models.swift", '\n        case "recent": "Today"\n')),
    ("preflight-selftest", ["Tests/preflight-pins.py"], lambda s: edit(s / "Tests/preflight-pins.py", 'CONFLICT = re.compile(r" [0-9]+(\\.[^/ ]*)?$")', 'CONFLICT = re.compile(r" [0-9]+NEVER$")')),
    ("run-header", ["Tests/run.sh"], lambda s: edit(s / "Tests/run.sh", """trap 'print -u2 "FAIL at run.sh:$LINENO"' ZERR\n""", "")),
    ("compile-bounded", ["Tests/compile-bounded.py"], lambda s: edit(s / "Tests/compile-bounded.py", "RSS_CAP = 8 * GIB", "RSS_CAP = 80 * GIB")),
    ("compile-slots", ["Tests/compile-bounded.py", "Tests/test-compile-slots.py"], lambda s: edit(s / "Tests/compile-bounded.py",
        "max(live, key=lambda o: (o['acquiredNs'], o['pid']))['pid'] != me", "min(live, key=lambda o: (o['acquiredNs'], o['pid']))['pid'] != me")),
    ("kit-compile", ["Tests/kit-compile.py"], lambda s: edit(s / "Tests/kit-compile.py", "if source_digests(files) != digests:", "if False:")),
    ("reuse-compile", ["Tests/reuse-compile.py"], lambda s: edit(s / "Tests/reuse-compile.py", "if fingerprint(root, command, toolchain) != before:", "if False:")),
]


def run_preflight(scratch, only=None):
    env = dict(os.environ)
    env.pop("COS_PREFLIGHT_ONLY", None)
    if only:
        env["COS_PREFLIGHT_ONLY"] = only
    began = time.time()
    done = subprocess.run(["/bin/zsh", str(scratch / "Tests/preflight.sh")], capture_output=True, text=True, env=env)
    return done, time.time() - began


def main():
    survived, killed = [], 0
    ids = [m[0] for m in MUTANTS]
    text = (root / "Tests/preflight.sh").read_text()
    declared = re.findall(r"^check (\S+)", text, re.M)
    if sorted(declared) != sorted(ids):
        print(f"FAIL: preflight.sh checks {sorted(declared)} and the mutants {sorted(ids)} differ: every check needs a mutant")
        return 1
    with tempfile.TemporaryDirectory(prefix="mutate-preflight.") as tmp:
        scratch = pathlib.Path(tmp)
        pins.farm(root, scratch, ["Tests/preflight.sh"])
        done, secs = run_preflight(scratch)
        if done.returncode != 0:
            print("FAIL: the unmutated scratch checkout is not green, so no mutant means anything:\n" + done.stderr[-1500:])
            return 1
        print(f"baseline green: {done.stdout.strip().splitlines()[-1]}")
        for check_id, copies, mutate in MUTANTS:
            pins.farm(root, scratch, ["Tests/preflight.sh", *copies])
            mutate(scratch)
            done, secs = run_preflight(scratch, check_id)
            named = f"PREFLIGHT FAIL: {check_id}" in done.stderr
            if done.returncode == 1 and named:
                killed += 1
                print(f"KILLED  {check_id:26} rc=1  \"PREFLIGHT FAIL: {check_id}\"  {secs:.0f}s")
            else:
                survived.append(check_id)
                print(f"SURVIVED {check_id:25} rc={done.returncode} named={named}  stderr tail: {done.stderr[-200:]!r}")
    if survived:
        print(f"FAIL: {len(survived)} mutant(s) survived: {', '.join(survived)}")
        return 1
    print(f"PASS preflight mutants: {killed} of {len(MUTANTS)} checks failed by name when one defect was planted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
