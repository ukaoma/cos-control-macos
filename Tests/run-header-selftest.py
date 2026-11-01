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
    # B1: the background full-app compile. Its status is read from its own PID; a failure stops the suite with its code.
    done, scratch, first = run_probe(header, ["( sleep 0.3; exit 7 ) &", "APP_BUILD_PID=$!", "print before-wait", "_app_build_wait", "print not-reached"])
    need(done.returncode == 7 and "full-app compile" in done.stderr and "before-wait" in done.stdout and "not-reached" not in done.stdout,
         f"{tag}: a failing background compile must fail the suite with its own exit code (rc {done.returncode}, stderr {done.stderr[:120]!r})")
    done, scratch, first = run_probe(header, ["( sleep 0.2 ) &", "APP_BUILD_PID=$!", "_app_build_wait", "print reached", "_app_build_wait", "print reached-twice"])
    need(done.returncode == 0 and "reached-twice" in done.stdout, f"{tag}: a passing background compile must not stop the suite, and waiting twice is harmless")
    # B1: a suite that fails while the compile runs stops it and its children (this run's PIDs only), and still cleans up.
    done, scratch, first = run_probe(header, ["( sleep 60; true ) >/dev/null 2>&1 &", "APP_BUILD_PID=$!", "sleep 0.4",
                                              'print -r -- "BG=$APP_BUILD_PID KIDS=$(/usr/bin/pgrep -P $APP_BUILD_PID | /usr/bin/tr "\\n" " ")"', "/usr/bin/false"])
    found = re.search(r"BG=(\d+) KIDS=([\d ]*)", done.stdout)
    pids = ([int(found.group(1))] + [int(x) for x in found.group(2).split()]) if found else []
    time_left = 20
    import time
    while time_left and any(alive(x) for x in pids):
        time.sleep(0.1); time_left -= 1
    leftover = [x for x in pids if alive(x)]
    for x in leftover:
        os.kill(x, 9)  # a PID this probe started; a surviving mutant must not leave a 60 s sleep behind
    need(len(pids) >= 2 and not leftover, f"{tag}: the EXIT trap must stop the background compile and its children (pids {pids}, still alive {leftover})")
    # B1: off by default; on, the second compile slot is available unless the caller chose a number.
    done, scratch, first = run_probe(header, ['print -r -- "SLOTS=${COS_COMPILE_SLOTS-unset}"'])
    need("SLOTS=unset" in done.stdout, f"{tag}: concurrent compiles must be off by default (got {done.stdout.strip()!r})")
    done, scratch, first = run_probe(header, ['print -r -- "SLOTS=${COS_COMPILE_SLOTS-unset}"'], {"COS_SUITE_CONCURRENT_COMPILES": "1"})
    need("SLOTS=2" in done.stdout, f"{tag}: COS_SUITE_CONCURRENT_COMPILES=1 must open a second compile slot (got {done.stdout.strip()!r})")
    done, scratch, first = run_probe(header, ['print -r -- "SLOTS=${COS_COMPILE_SLOTS-unset}"'], {"COS_SUITE_CONCURRENT_COMPILES": "1", "COS_COMPILE_SLOTS": "3"})
    need("SLOTS=3" in done.stdout, f"{tag}: a slot count the caller chose must stand (got {done.stdout.strip()!r})")
    return len(fails) - n


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


# The real header must pass every case.
real_failures = checks(HEADER, "header")
need(sum(1 for l in HEADER if re.match(r"\s*trap .* EXIT\s*$", l)) == 1, "header: exactly one EXIT trap (a second one replaces the cleanup)")
need(sum(1 for l in HEADER if re.match(r"\s*trap .* ZERR\s*$", l)) == 1, "header: exactly one ZERR trap")
need(sum(1 for l in HEADER if re.match(r"\s*trap .* DEBUG\s*$", l)) == 1, "header: exactly one DEBUG trap")
# B1 call sites in the body of run.sh (not the header): the first full-app compile starts in the background and is waited for
# at once unless the flag is on; the second, which reuses it, waits first. Nothing else in run.sh touches the build PID.
body = lines[cut:]
reuse = [i for i, l in enumerate(body) if l.startswith('python3 "$ROOT/Tests/reuse-compile.py"')]
need(len(reuse) == 2, f"run.sh: two full-app compiles expected, found {len(reuse)}")
if len(reuse) == 2:
    end = next(i for i in range(reuse[0], len(body)) if body[i].startswith('  -o "$TMP/COS Control"'))
    need(body[end].endswith(" &") and body[end + 1] == "APP_BUILD_PID=$!"
         and body[end + 2] == '[[ "${COS_SUITE_CONCURRENT_COMPILES:-0}" == 1 ]] || _app_build_wait',
         "run.sh: the first full-app compile must be backgrounded, its PID kept, and waited for at once when the flag is off")
    need(body[reuse[1] - 1] == "_app_build_wait", "run.sh: the second full-app compile must wait for the first")
    need(sum(1 for l in body if "APP_BUILD_PID" in l) == 1 and sum(1 for l in body if l.strip().startswith("_app_build_wait") or "|| _app_build_wait" in l) == 2,
         "run.sh: the build PID is set once, and waited for in exactly two places")

if not fails:
    # Each mutant of the header must be caught by the cases above (they are run into a separate list).
    mutants = [
        ("no ZERR trap", lambda h: [l for l in h if not re.match(r"\s*trap .* ZERR\s*$", l)]),
        ("ZERR trap prints no line", lambda h: [l.replace("$LINENO", "?") if re.match(r"\s*trap .* ZERR\s*$", l) else l for l in h]),
        ("EXIT trap leaves $TMP", lambda h: [l.replace('; rm -rf "$TMP"', "") if re.match(r"\s*trap .* EXIT\s*$", l) else l for l in h]),
        ("EXIT trap skips the log copy", lambda h: [l.replace("_suite_exit_logs 2>/dev/null || true; ", "") if re.match(r"\s*trap .* EXIT\s*$", l) else l for l in h]),
        ("profile not pinned", lambda h: [l for l in h if l.strip() != "export COS_COMPILE_PROFILE=bounded"]),
        ("persistence ignores the off switch", lambda h: [l.replace('!= 0 ]]', '!= x ]]') if "COS_TEST_KIT_PERSIST:-}" in l else l for l in h]),
        ("a failed background compile is not read", lambda h: [l.replace("(( code == 0 )) ||", "true ||") if "code == 0" in l else l for l in h]),
        ("the EXIT trap leaves the background compile", lambda h: [l.replace("_app_build_stop 2>/dev/null || true; ", "") if re.match(r"\s*trap .* EXIT\s*$", l) else l for l in h]),
        ("a stopped compile leaves its children", lambda h: [l.replace('for child in $(/usr/bin/pgrep -P "$pid" 2>/dev/null); do kill "$child" 2>/dev/null || true; done', ":") if "pgrep -P" in l else l for l in h]),
        ("slots opened by default", lambda h: [l.replace('if [[ "${COS_SUITE_CONCURRENT_COMPILES:-0}" == 1 ]]; then', "if true; then") if l.startswith('if [[ "${COS_SUITE_CONCURRENT_COMPILES') else l for l in h]),
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
print("PASS run header selftest: FAIL at run.sh:N names the line, one EXIT trap cleans up and copies the logs, the lane table names a slow line, the bounded profile is pinned, persistence has its off switch; 11 of 11 header mutants caught")
