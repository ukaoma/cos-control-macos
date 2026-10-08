#!/bin/zsh
# compile-guard.sh <command...>   Run a COS Control compile (or any script that compiles) safely.
#
# 2026-10-07: two kernel panics on a 96 GB Mac. A mutation lane ran 10 full Control compiles at once; one
# compile of Sources + Tests/WorkProgressChecks.swift peaks around 34 GB, so ten of them asked for about 340 GB
# (WindowServer watchdog panic). This guard makes that impossible:
#   1. ONE guarded command machine-wide at a time (lockf on a shared lock file; others wait, up to 30 min).
#   2. It starts only when at least COS_COMPILE_MIN_FREE_GB (default 40) of memory is free or reclaimable.
#   3. A watchdog kills any swift-frontend above COS_COMPILE_MAX_FRONTEND_GB (default 48) and the whole run if
#      all swift-frontends together pass COS_COMPILE_MAX_TOTAL_GB (default 60).
# Exit code: the command's own, or 137 when the watchdog stopped it (the reason is printed on stderr).
set -u
LOCK="${COS_COMPILE_LOCK:-/tmp/cos-control-compile.lock}"
MIN_FREE_GB="${COS_COMPILE_MIN_FREE_GB:-40}"
MAX_FRONTEND_GB="${COS_COMPILE_MAX_FRONTEND_GB:-48}"
MAX_TOTAL_GB="${COS_COMPILE_MAX_TOTAL_GB:-60}"
(( $# > 0 )) || { echo "usage: compile-guard.sh <command...>" >&2; exit 2; }

if [[ -z "${COS_COMPILE_GUARD_HELD:-}" ]]; then
  # Re-enter under the lock (lockf holds it for the life of the child).
  exec /usr/bin/lockf -t 1800 "$LOCK" /usr/bin/env COS_COMPILE_GUARD_HELD=1 "$0" "$@"
fi

free_gb() {
  local page=$(sysctl -n hw.pagesize)
  local f=$(sysctl -n vm.page_free_count) s=$(sysctl -n vm.page_speculative_count)
  local i=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  echo $(( (f + s + i) * page / 1073741824 ))
}
waited=0
while (( $(free_gb) < MIN_FREE_GB )); do
  (( waited >= 600 )) && { echo "compile-guard: only $(free_gb) GB free after 10 min (need $MIN_FREE_GB); not starting" >&2; exit 75; }
  sleep 5; (( waited += 5 ))
done

"$@" &
CMD=$!
REASON=""
while kill -0 $CMD 2>/dev/null; do
  stats=$(ps -Ao pid=,rss=,comm= | awk -v max=$(( MAX_FRONTEND_GB * 1048576 )) '
    $3 ~ /swift-frontend$/ { total += $2; if ($2 > max) big = big " " $1 }
    END { printf "%d|%s", total, big }')
  total_kb=${stats%%|*}; big=${stats#*|}
  if [[ -n "${big// /}" ]]; then REASON="a swift-frontend passed ${MAX_FRONTEND_GB} GB"; fi
  if (( total_kb > MAX_TOTAL_GB * 1048576 )); then REASON="all swift-frontends passed ${MAX_TOTAL_GB} GB together"; fi
  if [[ -n "$REASON" ]]; then
    pkill -9 -f swift-frontend; pkill -9 -P $CMD 2>/dev/null; kill -9 $CMD 2>/dev/null
    echo "compile-guard: STOPPED: $REASON" >&2
    wait $CMD 2>/dev/null
    exit 137
  fi
  sleep 1
done
wait $CMD
