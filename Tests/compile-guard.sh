#!/bin/zsh
# compile-guard.sh <command...>   Run a COS Control compile (or any script that compiles) safely.
#
# 2026-10-07: two kernel panics on a 96 GB Mac. A mutation lane ran 10 full Control compiles at once; one
# compile of Sources + Tests/WorkProgressChecks.swift peaks around 34 GB, so ten of them asked for about 340 GB
# (WindowServer watchdog panic). This guard makes that impossible:
#   1. ONE guarded command machine-wide at a time (lockf on a shared lock file; others wait, up to 30 min).
#   2. It starts only when at least COS_COMPILE_MIN_FREE_GB of memory is free or reclaimable.
#   3. A watchdog stops the run (its own process tree only, never another session's compile) when any swift-frontend
#      passes COS_COMPILE_MAX_FRONTEND_GB or all swift-frontends together pass COS_COMPILE_MAX_TOTAL_GB.
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

# 2026-10-31 (build-speed A5 + review 1): what the large-profile watchdog may count and stop is THIS run's own processes, never a
# name match across the machine (`pkill -9 -f swift-frontend` also killed every other session's compile). scan() takes ONE ps
# snapshot and refreshes $OWNED, the run's processes as "pid|start;pid|start..." (start = ps lstart, so a reused pid is never
# mistaken for ours). $OWNED is a running union across samples, like ProcessTree in compile-bounded.py: a process seen as our
# descendant stays ours after its parent exits and launchd adopts it, and anything it forks later joins through its parent.
# Also sets OWN_FE_KB (our swift-frontends' RSS), OWN_BIG (ours over the per-frontend cap), ALL_FE_KB (every swift-frontend on
# the machine) and FOREIGN_BIG (swift-frontends over the cap that are NOT ours, "pid:kb"). A failed snapshot changes nothing.
OWNED=""; OWN_FE_KB=0; OWN_BIG=""; ALL_FE_KB=0; FOREIGN_BIG=""
scan() {
  local out line
  out=$(ps -Ao pid=,ppid=,rss=,lstart=,comm= 2>/dev/null | awk -v root=$CMD -v prev="$OWNED" -v max=$(( MAX_FRONTEND_GB * 1048576 )) '
    { p = $1; ppid[p] = $2; rss[p] = $3; st[p] = $4 " " $5 " " $6 " " $7 " " $8; alive[p] = 1
      c = ""; for (i = 9; i <= NF; i++) c = c (i > 9 ? " " : "") $i
      fe[p] = (c ~ /swift-frontend$/) }
    END {
      n = split(prev, held, ";")
      for (i = 1; i <= n; i++) { split(held[i], kv, "|"); if ((kv[1] in alive) && st[kv[1]] == kv[2]) own[kv[1]] = 1 }
      if (root in alive) own[root] = 1
      do { grew = 0
           for (p in alive) if (!(p in own) && (ppid[p] in own)) { own[p] = 1; grew = 1 } }
      while (grew)
      state = ""; ownfe = 0; allfe = 0; ownbig = ""; forbig = ""
      for (p in alive) {
        if (fe[p]) {
          allfe += rss[p]
          if (p in own) { ownfe += rss[p]; if (rss[p] > max) ownbig = ownbig " " p }
          else if (rss[p] > max) forbig = forbig " " p ":" rss[p]
        }
        if (p in own) state = state (state == "" ? "" : ";") p "|" st[p]
      }
      print "STATE|" state; print "OWNFE|" ownfe; print "OWNBIG|" ownbig; print "ALLFE|" allfe; print "FORBIG|" forbig
    }')
  [[ "$out" == *STATE\|* ]] || return 1
  for line in ${(f)out}; do
    case $line in
      STATE\|*)  OWNED=${line#STATE\|} ;;
      OWNFE\|*)  OWN_FE_KB=${line#OWNFE\|} ;;
      OWNBIG\|*) OWN_BIG=${line#OWNBIG\|} ;;
      ALLFE\|*)  ALL_FE_KB=${line#ALLFE\|} ;;
      FORBIG\|*) FOREIGN_BIG=${line#FORBIG\|} ;;
    esac
  done
}

# A swift-frontend over the cap that is not in this run's tree is named, once, and left alone: it is not ours to stop, and
# stopping our own innocent compile would not help. (The old pkill stopped it, and every other session's frontends with it.)
typeset -A WARNED
note_foreign() {
  local item pid
  for item in ${=FOREIGN_BIG}; do
    pid=${item%%:*}
    [[ -n "${WARNED[$pid]:-}" ]] && continue
    WARNED[$pid]=1
    echo "compile-guard: NOTE: swift-frontend pid $pid holds $(( ${item#*:} / 1048576 )) GB, over the ${MAX_FRONTEND_GB} GB cap, but it is not part of this run (not a descendant of the guarded command). It was NOT stopped and this run continues." >&2
  done
  if (( ALL_FE_KB > MAX_TOTAL_GB * 1048576 && OWN_FE_KB <= MAX_TOTAL_GB * 1048576 )) && [[ -z "${WARNED[total]:-}" ]]; then
    WARNED[total]=1
    echo "compile-guard: NOTE: swift-frontends on this Mac total $(( ALL_FE_KB / 1048576 )) GB, over the ${MAX_TOTAL_GB} GB cap, but this run's own are $(( OWN_FE_KB / 1048576 )) GB. Nothing was stopped." >&2
  fi
}

# Stop this run: freeze the whole owned tree first (SIGSTOP), re-scan until no new process appears, then SIGKILL the set. A frozen
# parent cannot fork another child or exit and orphan one, so the set cannot move between the last scan and the kill.
stop_owned() {
  local -a pids; local key last="" i
  pids=( ${(s:;:)OWNED} ); pids=( ${pids%%|*} )
  for i in {1..20}; do
    scan || break
    pids=( ${(s:;:)OWNED} ); pids=( ${pids%%|*} )
    kill -STOP "${pids[@]}" 2>/dev/null
    key="${(j: :)${(on)pids}}"
    [[ "$key" == "$last" ]] && break
    last=$key
  done
  kill -9 "${pids[@]}" $CMD 2>/dev/null
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
  if scan; then
    if [[ -n "${OWN_BIG// /}" ]]; then REASON="a swift-frontend passed ${MAX_FRONTEND_GB} GB"; fi
    if (( OWN_FE_KB > MAX_TOTAL_GB * 1048576 )); then REASON="all of this run's swift-frontends passed ${MAX_TOTAL_GB} GB together"; fi
    note_foreign
  fi
  if [[ -n "$REASON" ]]; then
    stop_owned
    echo "compile-guard: STOPPED: $REASON" >&2
    wait $CMD 2>/dev/null
    exit 137
  fi
  sleep 1
done
wait $CMD
