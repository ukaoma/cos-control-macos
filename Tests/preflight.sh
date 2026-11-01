#!/bin/zsh
# Speed plan A3 (2026-10-31): the static checks of the suite, run first and in about a minute with no Swift compile.
#
# Five of ten recent Control suite failures came from a text pin that only ran 25 to 50 minutes in (the What's New summary
# cap, the Jedi pack pins, label alignment, a stale grep). This runs those checks before any compile. It DUPLICATES them:
# Tests/run.sh still runs every one of them where it always did, so removing this file removes nothing from the suite.
#
# Every check runs even after one fails, so a single rerun fixes everything. It exits 1 and names each failure.
# A check is here only if it reads repository files and nothing a lane builds: each passes on a checkout where no lane has
# run. COS_PREFLIGHT_ONLY=<id> runs one check (Tests/mutate-preflight.py uses it).
#
#   whats-new, label-alignment, label-alignment-selftest, jedi-v15-pack, illustrated-pack, build-number
#                        the pin scripts, unchanged
#   version              Info.plist and the CHANGELOG top entry agree (the check in run.sh, copied)
#   duplicates           no iCloud conflict copy ("Views 2.swift") under Sources, HelperSources, Tests, scripts, Resources
#   negated-pins         no `! command` pin in run.sh (errexit never fails on one)
#   source-greps         the one-line `grep -q 'text' "$ROOT/<file>"` pins of run.sh, replayed
#   preflight-selftest   the three checks above that are ours, each against a scratch copy with one defect planted
#   run-header           the top of run.sh run alone: a failing pin prints FAIL at run.sh:N, one EXIT trap, the pinned
#                        compile profile, the kit store and its off switch, the logs, the background full-app compile
#                        (status read, stopped on failure, off by default); 11 header mutants must be caught
#   scrub-list           every `export COS_*` in the top of run.sh is in GUARD_SCRUB below
#   run-env              this file run the way run.sh runs it (the top of run.sh executed first, so its exports are
#                        set), for compile-slots and kit-compile; it must pass. Standalone runs missed the failure that
#                        run.sh's COS_COMPILE_PROFILE=bounded caused in compile-slots.
#   compile-bounded, compile-slots, kit-compile, reuse-compile
#                        the compile-guard self-tests, which run stand-in compilers and never ran in the suite; each runs
#                        under GUARD_SCRUB, an environment without the suite's COS_COMPILE_* and COS_TEST_KIT_* variables
set -uo pipefail
# The unittest-based self-tests print Python 3.9 ResourceWarnings about their own helper processes; they are not failures.
export PYTHONWARNINGS=ignore::ResourceWarning
ROOT="${0:A:h:h}"
PY=/usr/bin/python3
# The compile-guard self-tests build the guard's environment themselves, so they must not inherit the suite's. Tests/run.sh
# exports COS_COMPILE_PROFILE=bounded and the kit variables before it calls this file, and test-compile-slots.py then failed
# (70 != 0), which would have stopped every full suite in its first minute. Standalone runs hid it. The list below is every
# COS variable run.sh exports plus the guard's own knobs; the scrub-list check keeps it complete.
GUARD_SCRUB=(/usr/bin/env -u COS_COMPILE_PROFILE -u COS_COMPILE_SLOTS -u COS_COMPILE_GUARD_HELD -u COS_COMPILE_LOCK -u COS_COMPILE_MIN_FREE_GB -u COS_COMPILE_MAX_FRONTEND_GB -u COS_COMPILE_MAX_TOTAL_GB -u COS_TEST_KIT -u COS_TEST_KIT_PERSIST -u COS_TEST_KIT_STORE -u COS_TEST_KIT_DIR -u COS_TEST_KIT_LOG)
ONLY="${COS_PREFLIGHT_ONLY:-}"
FAILED=()
RAN=0
typeset -F SECONDS=0

# check <id> <command...>: runs it unless COS_PREFLIGHT_ONLY names another; records a failure and carries on.
check() {
  local id=$1 began=$SECONDS
  shift
  [[ -z "$ONLY" || "$ONLY" == "$id" ]] || return 0
  RAN=$(( RAN + 1 ))
  if "$@"; then
    printf 'preflight ok    %-26s %5.1fs\n' "$id" $(( SECONDS - began ))
  else
    printf 'PREFLIGHT FAIL: %s (%.1fs; the output above says why)\n' "$id" $(( SECONDS - began )) >&2
    FAILED+=("$id")
  fi
}

check whats-new                "$PY" "$ROOT/Tests/whats-new-pins.py" "$ROOT"
check label-alignment          "$PY" "$ROOT/Tests/label-alignment-guard.py" "$ROOT"
check label-alignment-selftest "$PY" "$ROOT/Tests/label-alignment-guard.py" "$ROOT" --selftest
check jedi-v15-pack            "$PY" "$ROOT/Tests/jedi-v15-pack-pins.py" "$ROOT"
check illustrated-pack         "$PY" "$ROOT/Tests/illustrated-pack-pins.py" "$ROOT"
check build-number             "$PY" "$ROOT/Tests/build-number-pins.py" "$ROOT"
check version                  "$PY" "$ROOT/Tests/preflight-pins.py" version "$ROOT"
check duplicates               "$PY" "$ROOT/Tests/preflight-pins.py" duplicates "$ROOT"
check negated-pins             "$PY" "$ROOT/Tests/preflight-pins.py" negated "$ROOT"
check source-greps             "$PY" "$ROOT/Tests/preflight-pins.py" greps "$ROOT"
check preflight-selftest       "$PY" "$ROOT/Tests/preflight-pins.py" --selftest "$ROOT"
check run-header               "$PY" "$ROOT/Tests/run-header-selftest.py" "$ROOT"
check scrub-list               "$PY" "$ROOT/Tests/preflight-pins.py" scrub "$ROOT"
check run-env                  "$PY" "$ROOT/Tests/preflight-pins.py" runenv "$ROOT"
check compile-bounded          "${GUARD_SCRUB[@]}" "$PY" "$ROOT/Tests/test-compile-bounded.py"
check compile-slots            "${GUARD_SCRUB[@]}" "$PY" "$ROOT/Tests/test-compile-slots.py"
check kit-compile              "${GUARD_SCRUB[@]}" "$PY" "$ROOT/Tests/test-kit-compile.py"
check reuse-compile            "${GUARD_SCRUB[@]}" "$PY" "$ROOT/Tests/test-reuse-compile.py"

if (( RAN == 0 )); then
  print -u2 "PREFLIGHT FAIL: COS_PREFLIGHT_ONLY=$ONLY names no check"
  exit 2
fi
if (( ${#FAILED} > 0 )); then
  print -u2 "PREFLIGHT FAILED (${#FAILED} of $RAN): ${(j:, :)FAILED}"
  exit 1
fi
printf 'PREFLIGHT PASS: %d checks, %.0fs, no Swift compile\n' "$RAN" "$SECONDS"
