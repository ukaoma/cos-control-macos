#!/usr/bin/env python3
"""0.5.368 mutation gate for the native Windu Motion V13 checks: WinduMotionChecks (through the pet rotation runner) and the
Motion V2 to V13 case of IllustratedPetUpgrade. Never run by Tests/run.sh.

A scratch root holds copies of the Swift files and the JSON, and hard links to every PNG, so the binaries' #filePath and argv
roots point at it and no mutant can touch the repository's pack (a changed PNG is unlinked first). Two compiles, serial,
through Tests/compile-guard.sh, plus one more for the product mutant. GREEN baseline first. Each mutant must land exactly once
and fail with the message that NAMES the behaviour; a crash or another message is not a kill.

Usage: python3 Tests/mutate-windu-v13-native.py <repo root>
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
PACK = "Resources/BundledCharacters/jedi-miles-windu"
MAP = f"{PACK}/session-pet-states.json"
HISTORY = f"{PACK}/stock-state-history.json"
SWIFT = ["Sources/Models.swift", "Tests/PetRotationChecks.swift", "Tests/WinduMotionChecks.swift",
         "Tests/PetRotationRecoveryChecks.swift", "Tests/IllustratedPetUpgrade.swift", "Sources/ControllerModel.swift"]
FLAGS = ["-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library"]
GUARD = str(root / "Tests/compile-guard.sh")

base = pathlib.Path(tempfile.mkdtemp(prefix="cos-windu-v13-native-", dir="/private/tmp"))
work = base / "root"


def build_root():
    for relative in SWIFT + ["Tests/windu-motion-retime.json"]:
        (work / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, work / relative)
    for folder in (root / "Resources/BundledCharacters").iterdir():
        if folder.is_dir():
            for item in folder.iterdir():
                target = work / "Resources/BundledCharacters" / folder.name / item.name
                target.parent.mkdir(parents=True, exist_ok=True)
                (os.link if item.suffix == ".png" else shutil.copy2)(item, target)
    for item in (root / "Resources/DefaultPet").iterdir():
        target = work / "Resources/DefaultPet" / item.name
        target.parent.mkdir(parents=True, exist_ok=True)
        if item.is_file():
            (os.link if item.suffix == ".png" else shutil.copy2)(item, target)


def compile_rotation():
    subprocess.run([sys.executable, str(root / "Tests/extract-pet-rotation-controller.py"), str(work), str(base / "Controller.swift")], check=True)
    out = base / "rotation"
    subprocess.run([GUARD, "swiftc", *FLAGS, str(work / "Sources/Models.swift"), str(work / "Tests/PetRotationChecks.swift"),
                    str(work / "Tests/WinduMotionChecks.swift"), str(work / "Tests/PetRotationRecoveryChecks.swift"),
                    str(base / "Controller.swift"), "-framework", "AppKit", "-o", str(out)], check=True, stdout=subprocess.DEVNULL)
    return out


def compile_upgrade(name="upgrade"):
    out = base / name
    subprocess.run([GUARD, "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                    str(work / "Sources/Models.swift"), str(work / "Tests/IllustratedPetUpgrade.swift"), "-framework", "AppKit",
                    "-o", str(out)], check=True, stdout=subprocess.DEVNULL)
    return out


def run(binary, *args):
    done = subprocess.run([str(binary), *args], capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr


def json_edit(relative, change):
    path = work / relative
    original = path.read_text()
    data = json.loads(original)
    change(data)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    if path.read_text() == original:
        sys.exit(f"mutant on {relative} did not land")
    return lambda: path.write_text(original)


def working_variant(data, index):
    return data["poses"]["working"]["rotation"]["variants"][index]


def retina_variant(data, index):
    return data["poses"]["working"]["retina"]["variants"][index]


ROTATION = [
    ("a cast's tail body is another cast's body", lambda d: working_variant(d, 1).update(bodyFile="windu-motion-v13b-working-c-body-1x.png"),
     "the tail body is not the full frame at 1/144, 1.0x"),
    ("the body strip draws before the handoff", lambda d: working_variant(d, 0).update(bodyFile="windu-motion-v13b-working-a-full-1x.png"),
     "the body strip draws before the handoff at 0/0, 1.0x"),
    ("the fourth cast at 2x is the first cast", lambda d: retina_variant(d, 3).update(file=list(retina_variant(d, 0)["file"])),
     "cast 3 shares the run-in and is its own strike after it at 2.0x"),
    ("the 2x strips are gone, so 2x decodes 1x", lambda d: d["poses"]["working"].pop("retina"),
     "2.0x must decode the 2.0x strips"),
]


def drop_v2_retained(data):
    for entry in data["maps"]:
        if entry["name"] == "Windu Motion V2 · Control 0.5.360":
            entry.pop("retainedSource")


try:
    build_root()
    rotation = compile_rotation()
    upgrade = compile_upgrade()
    code, out = run(rotation)
    if code != 0 or "Motion V13 at 1x and 2x" not in out:
        sys.exit(f"rotation baseline is not green:\n{out[-2000:]}")
    code, out = run(upgrade, str(work))
    if code != 0 or "motion-v2 (to Motion V13)" not in out:
        sys.exit(f"upgrade baseline is not green:\n{out[-2000:]}")
    print("baseline GREEN: rotation and upgrade", flush=True)
    results = []
    for name, change, wanted in ROTATION:
        restore = json_edit(MAP, change)
        code, out = run(rotation)
        restore()
        verdict = "SURVIVED" if code == 0 else ("KILLED" if wanted in out else "CRASHED")
        results.append((verdict, name))
        print(f"{verdict:9} {name}" + ("" if verdict == "KILLED" else f"\n{out[-1200:]}"), flush=True)
    restore = json_edit(HISTORY, drop_v2_retained)
    code, out = run(upgrade, str(work))
    restore()
    wanted = "motion-v2 stock must receive Motion V13"
    verdict = "SURVIVED" if code == 0 else ("KILLED" if wanted in out else "CRASHED")
    results.append((verdict, "the Motion V2 history entry loses retainedSource (product looks in DefaultPet)"))
    print(f"{verdict:9} {results[-1][1]}" + ("" if verdict == "KILLED" else f"\n{out[-1200:]}"), flush=True)
    # Product mutant: stock recognition stops reading Retina lists, so a customized 2x layer no longer protects the install.
    models = work / "Sources/Models.swift"
    source = models.read_text()
    old = "                if let list = value as? [Any] {\n                    return list.reduce(into: Set<String>()) { $0.formUnion(referencedPNGs($1)) }\n                }\n"
    if source.count(old) != 1:
        sys.exit(f"product mutant targets {source.count(old)} sites; it must land exactly once")
    models.write_text(source.replace(old, ""))
    mutant = compile_upgrade("upgrade-mutant")
    models.write_text(source)
    code, out = run(mutant, str(work))
    wanted = "a custom motion-v2 layer must survive: windu-illustrated-v1-trio-b-body-2x-s3.png"
    verdict = "SURVIVED" if code == 0 else ("KILLED" if wanted in out else "CRASHED")
    results.append((verdict, "stock recognition ignores Retina lists"))
    print(f"{verdict:9} {results[-1][1]}" + ("" if verdict == "KILLED" else f"\n{out[-1200:]}"), flush=True)
    bad = [name for verdict, name in results if verdict != "KILLED"]
    print("repository pack untouched:", (root / MAP).read_bytes() == (work / MAP).read_bytes())
    if bad:
        sys.exit(f"{len(bad)} mutant(s) not killed by the check that names them: {bad}")
    print(f"PASS Windu V13 native mutation gate: {len(results)} mutants, each killed by the named check, green baseline")
finally:
    shutil.rmtree(base, ignore_errors=True)
