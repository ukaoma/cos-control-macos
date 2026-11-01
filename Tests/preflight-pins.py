#!/usr/bin/env python3
"""Static checks for Tests/preflight.sh (speed plan A3/A4, 2026-10-31). No Swift compile, no lane artifact.

    preflight-pins.py version    <checkout>   Info.plist and the CHANGELOG top entry agree (the check in run.sh, copied)
    preflight-pins.py duplicates <checkout>   no iCloud conflict copy ("Views 2.swift", "Fonts 3") under the build inputs
    preflight-pins.py negated    <checkout>   no `! command` line in run.sh (errexit never fails on one; speed plan A2)
    preflight-pins.py greps      <checkout>   every one-line `grep -q 'text' "$ROOT/<repo file>"` pin of run.sh, replayed
    preflight-pins.py --selftest <checkout>   each of the four above, run against a scratch copy with one defect planted

Each command prints every offender and exits 1; none excludes a path silently. `greps` reads only files that are in the
repository (Sources, HelperSources, Resources, Tests, scripts), never anything a lane builds, so a clean checkout passes it
before a single compile has run; that is how its lines were chosen.
"""
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

# Directories whose files are build or test inputs. A conflict copy in any of them can be compiled or run by mistake.
INPUT_DIRS = ("Sources", "HelperSources", "Tests", "scripts", "Resources")
# iCloud's conflict suffix: "name 2.ext", "name 3", "name 2.tar.gz". The base name before it never ends the check early.
CONFLICT = re.compile(r" [0-9]+(\.[^/ ]*)?$")
# A pin that needs only repository files: one single-quoted pattern, then repository paths, nothing else on the line.
REPO_PATH = r'"\$ROOT/(?:Sources|HelperSources|Resources|Tests|scripts)/[A-Za-z0-9_./+-]+"'
GREP_PIN = re.compile(r"^(?:/usr/bin/)?grep -q((?: -[FEeiwx])*) ('[^']*') ((?:" + REPO_PATH + r")(?: " + REPO_PATH + r")*)$")
# The same pin written as a ban (speed plan A2): `if grep -q 'forbidden text' "$ROOT/<file>"; then print -u2 '...'; exit 1; fi`.
BAN_PIN = re.compile(r"^if (?:/usr/bin/)?grep -q((?: -[FEeiwx])*) ('[^']*') ((?:" + REPO_PATH + r")(?: " + REPO_PATH + r")*); then print -u2 (?:'[^']*'|\"[^\"]*\"); exit 1; fi$")
HEREDOC = re.compile(r"<<-?\s*(?:'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"|([A-Za-z_][A-Za-z0-9_]*))")


def code_lines(text):
    """(line number, line) for every line of a shell script that is not the body of a here-document."""
    ending = None
    for number, line in enumerate(text.splitlines(), 1):
        if ending is not None:
            if line.strip() == ending:
                ending = None
            continue
        found = HEREDOC.search(line)
        if found:
            ending = next(g for g in found.groups() if g)
        yield number, line


def duplicates(root):
    bad = []
    for name in INPUT_DIRS:
        base = root / name
        if not base.exists():
            bad.append(f"{name}: the directory is missing, so it cannot be checked")
            continue
        for current, dirs, files in os.walk(base):
            for entry in dirs + files:
                if CONFLICT.search(entry):
                    bad.append(str((pathlib.Path(current) / entry).relative_to(root)))
    return bad


def version(root):
    info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    ver, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    head = (root / "CHANGELOG.md").read_text().splitlines()
    # An "## Unreleased" entry above the release headings is notes for the next build, not a version.
    entry = next((l for l in head if l.startswith("## ") and l.strip() != "## Unreleased"), "")
    m = re.match(r"## (\d+\.\d+\.\d+) \(build (\d+)\)", entry)
    if not m:
        return [f"CHANGELOG top entry is not '## X.Y.Z (build N)': {entry!r}"]
    if (m.group(1), m.group(2)) != (ver, build):
        return [f"version touchpoints disagree: Info.plist {ver} (build {build}) vs CHANGELOG {m.group(1)} (build {m.group(2)})"]
    return []


def negated(root):
    text = (root / "Tests/run.sh").read_text()
    return [f"Tests/run.sh:{n}: {l.strip()[:110]}" for n, l in code_lines(text) if re.match(r"\s*!\s", l)]


def greps(root):
    """Replay the one-line source pins of run.sh in one shell; returns the line numbers that no longer match."""
    text = (root / "Tests/run.sh").read_text()
    pins = [(n, l) for n, l in code_lines(text) if GREP_PIN.match(l) or BAN_PIN.match(l)]
    if len(pins) < 100:
        return [f"only {len(pins)} one-line source pins found in Tests/run.sh (about 400 expected): the pattern or the file changed"]
    script = ['ROOT=%s' % shell_quote(str(root)), 'FAILS=0']
    for n, l in pins:
        # A subshell, so the `exit 1` of a ban cannot end the replay; either shape fails the pin by a non-zero status.
        script.append(f'( {l} ) 2>/dev/null || {{ print -u2 -r -- "Tests/run.sh:{n}: this pin no longer holds: "{shell_quote(l[:140])}; FAILS=$((FAILS+1)); }}')
    script.append('exit $(( FAILS > 0 ))')
    run = subprocess.run(["/bin/zsh", "-f", "-c", "\n".join(script)], capture_output=True, text=True)
    if run.returncode == 0:
        print(f"preflight greps: {len(pins)} one-line source pins of Tests/run.sh still match")
        return []
    return [l for l in run.stderr.splitlines() if l.strip()] or [f"the replay shell exited {run.returncode}"]


def shell_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


COMMANDS = {"version": version, "duplicates": duplicates, "negated": negated, "greps": greps}


def farm(root, scratch, copies):
    """A scratch checkout: every file under INPUT_DIRS and CHANGELOG.md is a symlink to the real one, except `copies`
    (relative paths), which are real copies that a self-test may change."""
    for name in INPUT_DIRS:
        shutil.rmtree(scratch / name, ignore_errors=True)
    wanted = {pathlib.PurePosixPath(c) for c in copies}
    def walk(rel):
        src, dst = root / rel, scratch / rel
        dst.mkdir(parents=True, exist_ok=True)
        for entry in sorted(src.iterdir()):
            child = rel / entry.name
            if entry.is_dir() and not entry.is_symlink():
                if any(w == child or child in w.parents for w in wanted):
                    walk(child)
                else:
                    (scratch / child).symlink_to(entry)
            elif child in wanted:
                shutil.copy2(entry, scratch / child)
            else:
                (scratch / child).symlink_to(entry)
    for name in INPUT_DIRS:
        walk(pathlib.PurePosixPath(name))
    for extra in ("CHANGELOG.md",):
        (scratch / extra).unlink(missing_ok=True) if sys.version_info >= (3, 8) else None
        if (root / extra).exists():
            if pathlib.PurePosixPath(extra) in wanted:
                shutil.copy2(root / extra, scratch / extra)
            else:
                (scratch / extra).symlink_to(root / extra)


def plant(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"selftest: the mutation target lands {text.count(old)} times in {path.name}, not exactly once")
    path.write_text(text.replace(old, new))


def selftest(root):
    problems = []
    with tempfile.TemporaryDirectory(prefix="preflight-pins.") as tmp:
        scratch = pathlib.Path(tmp)
        # 1. each command is green on the real checkout first (a gate that cannot start green proves nothing)
        for command, function in COMMANDS.items():
            found = function(root)
            if found:
                problems.append(f"baseline: {command} is not green on the checkout: {found[:2]}")
        if problems:
            return problems

        def expect_fail(label, command, word, copies, mutate):
            farm(root, scratch, copies)
            mutate(scratch)
            found = COMMANDS[command](scratch)
            if not found or not any(word in f for f in found):
                problems.append(f"{label}: {command} did not fail naming {word!r} (got {found[:2]})")

        # duplicates: a conflict copy of a source file, and of a directory
        def add_dup(s):
            (s / "Sources").mkdir(exist_ok=True)
            (s / "Sources/Views 2.swift").write_text("// iCloud conflict copy\n")
        expect_fail("plant Sources/Views 2.swift", "duplicates", "Views 2.swift", ["Sources/Models.swift"], add_dup)
        expect_fail("plant Resources/Fonts 3", "duplicates", "Fonts 3", ["Resources/Info.plist"], lambda s: (s / "Resources/Fonts 3").mkdir())
        # version: the Info.plist build disagrees with the CHANGELOG
        def skew(s):
            info = plistlib.loads((s / "Resources/Info.plist").read_bytes())
            info["CFBundleVersion"] = str(int(info["CFBundleVersion"].split(".")[0]) + 1)
            (s / "Resources/Info.plist").write_bytes(plistlib.dumps(info))
        expect_fail("skew the build number", "version", "disagree", ["Resources/Info.plist"], skew)
        # negated: a `! grep -q` line in run.sh
        expect_fail("plant a negated pin", "negated", "Tests/run.sh:", ["Tests/run.sh"],
                    lambda s: (s / "Tests/run.sh").write_text((s / "Tests/run.sh").read_text() + "\n! /usr/bin/grep -q 'x' \"$ROOT/Sources/Views.swift\"\n"))
        # greps: a pinned source text is gone
        def break_grep(s):
            line = next(l for n, l in code_lines((s / "Tests/run.sh").read_text()) if GREP_PIN.match(l))
            target = GREP_PIN.match(line)
            pattern = target.group(2).strip("'")
            rel = re.findall(r'\$ROOT/([^"]+)', target.group(3))[0]
            # change the pinned text in run.sh itself, so the pin asks for something that is not in the source file
            plant(s / "Tests/run.sh", line, line.replace(pattern, pattern + "⁣absent"))
        expect_fail("pin a text that is not there", "greps", "no longer holds", ["Tests/run.sh"], break_grep)
        # greps, ban form: the forbidden text is back in the source file
        def plant_forbidden(s):
            line = next(l for n, l in code_lines((s / "Tests/run.sh").read_text()) if BAN_PIN.match(l))
            target = BAN_PIN.match(line)
            rel = re.findall(r'\$ROOT/([^"]+)', target.group(3))[0]
            pattern = target.group(2).strip("'")
            if "\\" in pattern or any(c in pattern for c in "[]*^$"):
                pattern = pattern.replace("\\*", "*")
            with open(s / rel, "a") as stream:
                stream.write("\n" + pattern + "\n")
        expect_fail("plant the forbidden text of a ban", "greps", "no longer holds", ["Tests/run.sh", "Sources/Views.swift", "Sources/ControlInstance.swift", "Sources/COSControlApp.swift", "Sources/ControllerModel.swift", "Sources/Models.swift", "Sources/ActivityWindow.swift"], plant_forbidden)
        # a heredoc body is not a pin: a negated-looking line inside one must not be reported
        farm(root, scratch, ["Tests/run.sh"])
        (scratch / "Tests/run.sh").write_text((scratch / "Tests/run.sh").read_text() + "\n/usr/bin/python3 - <<'PY'\n! not a shell line\nPY\n")
        if negated(scratch):
            problems.append("negated: a line inside a here-document was reported")
    return problems


def main(argv):
    if len(argv) != 3 or (argv[1] not in COMMANDS and argv[1] != "--selftest"):
        print(__doc__, file=sys.stderr)
        return 64
    root = pathlib.Path(argv[2]).resolve()
    if argv[1] == "--selftest":
        problems = selftest(root)
        if problems:
            print("FAIL preflight-pins selftest:\n  " + "\n  ".join(problems))
            return 1
        print("PASS preflight-pins selftest: duplicates (file and folder), version, negated (and not inside a here-document) and greps each fail when one defect is planted")
        return 0
    found = COMMANDS[argv[1]](root)
    if found:
        print(f"FAIL preflight {argv[1]}:\n  " + "\n  ".join(found))
        return 1
    if argv[1] != "greps":
        print(f"PASS preflight {argv[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
