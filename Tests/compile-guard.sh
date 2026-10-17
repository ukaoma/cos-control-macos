#!/bin/zsh
# compile-guard.sh <command...>   Run a COS Control compile (or any script that compiles) safely.
#
# 2026-10-07: two kernel panics on a 96 GB Mac. A mutation lane ran 10 full Control compiles at once; one
# compile of Sources + Tests/WorkProgressChecks.swift peaks around 34 GB, so ten of them asked for about 340 GB
# (WindowServer watchdog panic). This guard makes that impossible:
#   1. ONE guarded command machine-wide at a time (lockf on a shared lock file; others wait, up to 30 min).
#   2. It starts only when at least COS_COMPILE_MIN_FREE_GB of memory is free or reclaimable.
#   3. A watchdog kills any swift-frontend above COS_COMPILE_MAX_FRONTEND_GB and the whole run if all
#      swift-frontends together pass COS_COMPILE_MAX_TOTAL_GB.
# Large-profile defaults scale with the Mac (0.5.267, the repo is public): free floor min(40 GB, 60% of RAM), one frontend
# min(48 GB, 75% of RAM), all frontends min(60 GB, 85% of RAM). A 96 GB Mac gets 40 / 48 / 60; a 16 GB Mac gets
# 9 / 12 / 13, so the serial test compiles (about 3 GB each since the tracker checks were split) still run there.
# Exit code: the command's own, or 137 when the watchdog stopped it (the reason is printed on stderr).
set -u
LOCK="${COS_COMPILE_LOCK:-/tmp/cos-control-compile.lock}"
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
scaled() { local cap=$1 pct=$2; local v=$(( RAM_GB * pct / 100 )); (( v < cap )) && echo $v || echo $cap; }
MIN_FREE_GB="${COS_COMPILE_MIN_FREE_GB:-$(scaled 40 60)}"
MAX_FRONTEND_GB="${COS_COMPILE_MAX_FRONTEND_GB:-$(scaled 48 75)}"
MAX_TOTAL_GB="${COS_COMPILE_MAX_TOTAL_GB:-$(scaled 60 85)}"
(( $# > 0 )) || { echo "usage: compile-guard.sh <command...>" >&2; exit 2; }

free_gb() {
  local page=$(sysctl -n hw.pagesize)
  local f=$(sysctl -n vm.page_free_count) s=$(sysctl -n vm.page_speculative_count)
  local i=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  echo $(( (f + s + i) * page / 1073741824 ))
}

# Choose direct Swift jobs from available memory. The bounded profile passed
# watchdog fault tests and helper/full-app compiles on 2026-10-10; it normalizes
# single-frontend work and measures the complete owned descendant tree.
# Both profiles own the same BSD file lock; bounded never sets GUARD_HELD.
# Script wrappers retain the large path; invoke this guard on each swiftc job.
PROFILE="${COS_COMPILE_PROFILE:-auto}"
case "$PROFILE" in
  large|bounded|auto) ;;
  *) echo "compile-guard: unknown compile profile" >&2; exit 2 ;;
esac
# 2026-10-16 (Miles: "Yes, 3 slots"): COS_COMPILE_SLOTS=N (1 to 8, default 1) lets N bounded compiles run at once, each
# under its own 8 GiB cap and a machine-wide total switch that stops only the newest (compile-bounded.py). With N > 1 a
# direct swiftc job always takes the bounded lane (16 GiB start floor). The large profile stays exclusive: it holds
# $LOCK exclusively, which no slotted compile can share, behind a gate so a stream of slotted compiles cannot starve it.
SLOTS="${COS_COMPILE_SLOTS:-1}"
[[ "$SLOTS" =~ '^[1-8]$' ]] || { echo "compile-guard: COS_COMPILE_SLOTS must be a whole number from 1 to 8" >&2; exit 2; }
if [[ "$PROFILE" == bounded && -n "${COS_COMPILE_GUARD_HELD:-}" ]]; then
  echo "compile-guard: bounded profile refuses inherited guard-held state" >&2
  exit 2
fi
if [[ -z "${COS_COMPILE_GUARD_HELD:-}" ]] && \
   { [[ "$PROFILE" == bounded ]] || { [[ "$PROFILE" == auto && "${1:t}" == swiftc ]] && { (( SLOTS > 1 )) || (( $(free_gb) < MIN_FREE_GB )); }; }; }; then
  RECEIPTS="${COS_COMPILE_RECEIPT_DIR:-/tmp/cos-control-compile-receipts-$UID}"
  mkdir -p "$RECEIPTS" || exit 2
  RECEIPT="$(mktemp "$RECEIPTS/compile.XXXXXX")" || exit 2
  exec /usr/bin/python3 "${0:A:h}/compile-bounded.py" --receipt "$RECEIPT" -- "$@"
fi

if [[ -z "${COS_COMPILE_GUARD_HELD:-}" ]]; then
  # Re-enter under the lock (lockf holds it for the life of the child).
  # The gate first: while this waits for $LOCK, no new slotted compile can take $LOCK shared. Uncontended without them.
  exec /usr/bin/lockf -k -t 1800 "$LOCK.gate" /usr/bin/lockf -k -t 1800 "$LOCK" /usr/bin/env COS_COMPILE_GUARD_HELD=1 "$0" "$@"
fi


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
