#!/usr/bin/env python3
"""Speed plan A1/A5/A9 (2026-10-31): proves the header of Tests/run.sh does what it says, and can fail.

    run-header-selftest.py <checkout>

The header is everything in run.sh before the desktop-safety check. It is run on its own, in a scratch checkout, with a
probe appended, so no lane and no compile starts. Each case runs against the real header (it must pass) and against a
header with one line removed or doubled (the case must then fail), so none of the cases is decoration.
"""
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent).resolve()
lines = (root / "Tests/run.sh").read_text().splitlines()
cut = next(i for i, l in enumerate(lines) if l.startswith('/usr/bin/python3 "$ROOT/Tests/desktop-safety-check.py"'))
HEADER = lines[:cut]
fails = []


def need(ok, message):
    if not ok:
        fails.append(message)


def line_of(header, needle):
    return next(i for i, l in enumerate(header) if needle in l)


def run_probe(header, probe, env_extra=None, sleep_free=True):
    """Runs header + probe as <scratch>/Tests/run.sh; returns (completed process, scratch path, probe's first line number)."""
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="run-header."))
    (scratch / "Tests").mkdir()
    (scratch / "Sources").mkdir()
    (scratch / "home").mkdir()
    (scratch / "Sources/Views.swift").write_text("let a = 1\n")
    script = scratch / "Tests/run.sh"
    script.write_text("\n".join(header + probe) + "\n")
    env = dict(os.environ, HOME=str(scratch / "home"), COS_SUITE_LOG_DIR=str(scratch / "logs"))
    for key in ("COS_TEST_KIT_PERSIST", "COS_TEST_KIT_STORE", "COS_TEST_KIT_LOG", "COS_COMPILE_PROFILE", "COS_TEST_KIT_DIR"):
        env.pop(key, None)
    env.update(env_extra or {})
    done = subprocess.run(["/bin/zsh", str(script)], capture_output=True, text=True, env=env, cwd=str(scratch))
    return done, scratch, len(header) + 1


def checks(header, tag):
    """Every behavior of the header, asserted. Returns nothing; failures are appended to `fails` with the tag."""
    n = len(fails)
    # A1: a failing pin names its own line in run.sh, and a command that handles its failure prints nothing extra.
    done, scratch, first = run_probe(header, ["/usr/bin/grep -q 'let a' \"$ROOT/Sources/Views.swift\"",
                                              "if /usr/bin/false; then :; fi", "/usr/bin/false || true", "! /usr/bin/true",
                                              "print probe-reached-end"])
    need(done.returncode == 0 and "FAIL at" not in done.stderr and "probe-reached-end" in done.stdout,
         f"{tag}: a passing probe must pass silently (rc {done.returncode}, stderr {done.stderr[:120]!r})")
    done, scratch, first = run_probe(header, ["print before", "/usr/bin/grep -q 'NOT_THERE_AT_ALL' \"$ROOT/Sources/Views.swift\"", "print not-reached"])
    need(done.returncode != 0 and f"FAIL at run.sh:{first + 1}" in done.stderr and "not-reached" not in done.stdout,
         f"{tag}: a failing pin must stop the suite and print FAIL at run.sh:{first + 1} (rc {done.returncode}, stderr {done.stderr[:160]!r})")
    # The one EXIT trap still removes $TMP, on a failure too.
    done, scratch, first = run_probe(header, ['print -r -- "TMPDIR=$TMP"', "/usr/bin/false"])
    found = re.search(r"TMPDIR=(\S+)", done.stdout)
    need(bool(found) and not pathlib.Path(found.group(1)).exists(), f"{tag}: $TMP must be removed at exit, even after a failure")
    # A9: the kit log and the lane timing table reach the stable folder after $TMP is gone.
    done, scratch, first = run_probe(header, ['print -r -- \'{"mode": "probe"}\' >> "$COS_TEST_KIT_LOG"', "sleep 1.2", "print end"])
    logs = list((scratch / "logs").glob("*-kit-log.jsonl"))
    times = list((scratch / "logs").glob("*-lane-times.tsv"))
    need(len(logs) == 1 and '"probe"' in logs[0].read_text(), f"{tag}: the kit log must be copied out at exit")
    rows = [r.split("\t") for r in times[0].read_text().splitlines()] if times else []
    need(any(r[0] == str(first + 1) and float(r[1]) >= 1.0 and "sleep" in r[2] for r in rows),
         f"{tag}: the lane table must name the 1.2 s sleep at line {first + 1} (got {rows[:3]})")
    # A5 and B2: exports. The profile is pinned even when the caller asks for another; the store is named by the checkout.
    probe = ['print -r -- "PROFILE=$COS_COMPILE_PROFILE PERSIST=${COS_TEST_KIT_PERSIST-unset} STORE=${COS_TEST_KIT_STORE-unset}"']
    done, scratch, first = run_probe(header, probe, {"COS_COMPILE_PROFILE": "large"})
    digest = hashlib.sha256(str(scratch.resolve()).encode()).hexdigest()[:16]
    need(f"PROFILE=bounded PERSIST=1 STORE={scratch / 'home'}/Library/Caches/COS/kits/{digest}" in done.stdout.replace("/private", ""),
         f"{tag}: bounded profile pinned, persistence on, store named by sha256 of the checkout (got {done.stdout.strip()!r})")
    done, scratch, first = run_probe(header, probe, {"COS_TEST_KIT_PERSIST": "0"})
    need("PERSIST=0 STORE=unset" in done.stdout, f"{tag}: COS_TEST_KIT_PERSIST=0 must switch persistence off and set no store (got {done.stdout.strip()!r})")
    return len(fails) - n


# The real header must pass every case.
real_failures = checks(HEADER, "header")
need(sum(1 for l in HEADER if re.match(r"\s*trap .* EXIT\s*$", l)) == 1, "header: exactly one EXIT trap (a second one replaces the cleanup)")
need(sum(1 for l in HEADER if re.match(r"\s*trap .* ZERR\s*$", l)) == 1, "header: exactly one ZERR trap")
need(sum(1 for l in HEADER if re.match(r"\s*trap .* DEBUG\s*$", l)) == 1, "header: exactly one DEBUG trap")

if not fails:
    # Each mutant of the header must be caught by the cases above (they are run into a separate list).
    mutants = [
        ("no ZERR trap", lambda h: [l for l in h if not re.match(r"\s*trap .* ZERR\s*$", l)]),
        ("ZERR trap prints no line", lambda h: [l.replace("$LINENO", "?") if re.match(r"\s*trap .* ZERR\s*$", l) else l for l in h]),
        ("EXIT trap leaves $TMP", lambda h: [l.replace('; rm -rf "$TMP"', "") if re.match(r"\s*trap .* EXIT\s*$", l) else l for l in h]),
        ("EXIT trap skips the log copy", lambda h: [l.replace("_suite_exit_logs 2>/dev/null || true; ", "") if re.match(r"\s*trap .* EXIT\s*$", l) else l for l in h]),
        ("profile not pinned", lambda h: [l for l in h if l.strip() != "export COS_COMPILE_PROFILE=bounded"]),
        ("persistence ignores the off switch", lambda h: [l.replace('!= 0 ]]', '!= x ]]') if "COS_TEST_KIT_PERSIST:-}" in l else l for l in h]),
        ("no lane table", lambda h: [l for l in h if not re.match(r"\s*trap .* DEBUG\s*$", l)]),
    ]
    for name, mutate in mutants:
        mutated = mutate(HEADER)
        if mutated == HEADER:
            fails.append(f"mutant {name!r} changed nothing")
            continue
        saved = list(fails)
        caught = checks(mutated, "mutant")
        fails[:] = saved
        if not caught:
            fails.append(f"mutant {name!r} survived every case")
        else:
            print(f"KILLED  {name}  ({caught} case(s) failed)")

if fails:
    print("FAIL run header selftest:\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS run header selftest: FAIL at run.sh:N names the line, one EXIT trap cleans up and copies the logs, the lane table names a slow line, the bounded profile is pinned, persistence has its off switch; 7 of 7 header mutants caught")
