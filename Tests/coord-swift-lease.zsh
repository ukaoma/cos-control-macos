# Sourced by run.sh only when COS_COORD_LEASES is explicitly enabled. This is a
# suite admission lease, not a replacement for compile-guard's machine-wide lock.
# No private workspace path is assumed; coord.py remains shadow-by-default itself.
# Enabled suites require COS_COORD_PY or COS_SCRIPTS_DIR. The 120 minute lease is
# renewed every 60 seconds while this exact owning shell remains alive. Defaults
# stay off, with no CLI/shadow writes; each compiler still uses compile-guard.
_coord_lease_run() { "${_coord_command[@]}" "$@"; }

_coord_owner_matches() {
  [[ "$(/bin/ps -o lstart= -p "$_coord_owner_pid" 2>/dev/null)" == "$_coord_owner_start" ]]
}

_coord_lease_heartbeat() {
  trap - EXIT ZERR DEBUG
  trap 'exit 0' TERM INT HUP
  while true; do
    # zselect waits in this shell: stopping it leaves no orphaned sleep process.
    zselect -t "$_coord_renew_centiseconds" || true
    _coord_owner_matches || return 0
    if ! _coord_lease_run lease renew swift-slot --lane "$_coord_suite_lane" --ttl "$_coord_ttl_minutes"; then
      # This PID/start pair is the shell which started this heartbeat, never a peer.
      _coord_owner_matches && kill -USR1 "$_coord_owner_pid"
      return 0
    fi
  done
}

_coord_lease_acquire() {
  local coord_py="${COS_COORD_PY:-${COS_SCRIPTS_DIR:+$COS_SCRIPTS_DIR/coord.py}}"
  local prefix="${COS_COORD_LANE:-control-tests}" nonce
  local ttl="${COS_COORD_LEASE_TTL_MIN:-120}" interval="${COS_COORD_LEASE_RENEW_SECONDS:-60}"
  if [[ -z "$coord_py" || ! -r "$coord_py" ]]; then
    print -u2 'run.sh: COS_COORD_LEASES is on; set COS_COORD_PY to coord.py or set COS_SCRIPTS_DIR'
    return 2
  fi
  if [[ ! "$prefix" =~ '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,79}$' ||
        ! "$ttl" =~ '^([0-9]+([.][0-9]*)?|[.][0-9]+)$' ||
        ! "$interval" =~ '^([0-9]+([.][0-9]*)?|[.][0-9]+)$' ]]; then
    print -u2 'run.sh: invalid COORD lane prefix or lease timing'
    return 2
  fi
  if ! (( ttl > 0 && interval > 0 && interval < ttl * 60 )); then
    print -u2 'run.sh: COORD renewal interval must be positive and shorter than its lease TTL'
    return 2
  fi
  zmodload zsh/zselect || return 2
  nonce="$(/usr/bin/uuidgen)" || return 2
  _coord_owner_pid=$$
  _coord_owner_start="$(/bin/ps -o lstart= -p "$_coord_owner_pid")" || return 2
  [[ -n "$_coord_owner_start" ]] || return 2
  # A caller may reuse a readable prefix, but two suites must never reacquire the
  # same lane: coord.py intentionally permits a lane to renew its own lease.
  _coord_suite_lane="$prefix:$nonce"
  _coord_ttl_minutes=$ttl
  typeset -gi _coord_renew_centiseconds
  (( _coord_renew_centiseconds = interval * 100 )) || true
  (( _coord_renew_centiseconds >= 1 )) || _coord_renew_centiseconds=1
  typeset -ga _coord_command
  _coord_command=("${COS_COORD_PYTHON:-/usr/bin/python3}" "$coord_py")
  [[ -z "${COS_COORD_STATE_DIR:-}" ]] || _coord_command+=(--state-dir "$COS_COORD_STATE_DIR")
  [[ -z "${COS_COORD_FILE:-}" ]] || _coord_command+=(--coord-file "$COS_COORD_FILE")
  local code=0
  _coord_lease_run lease acquire swift-slot --lane "$_coord_suite_lane" --ttl "$ttl" --pid "$_coord_owner_pid" || code=$?
  if (( code != 0 )); then
    print -u2 "run.sh: refusing to compile without the swift-slot lease (coord.py exit $code)"
    return $code
  fi
  _coord_lease_held=1
  trap 'print -u2 "run.sh: COORD lease renewal failed; stopping this suite"; exit 70' USR1
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  _coord_lease_heartbeat &
  _coord_heartbeat_pid=$!
  _coord_heartbeat_start="$(/bin/ps -o lstart= -p "$_coord_heartbeat_pid" 2>/dev/null)" || true
}

_coord_lease_release() {
  local pid="${_coord_heartbeat_pid:-}" parent started
  if [[ -n "$pid" ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      parent="$(/bin/ps -o ppid= -p "$pid" 2>/dev/null)"
      started="$(/bin/ps -o lstart= -p "$pid" 2>/dev/null)"
      if [[ "${parent//[[:space:]]/}" != "$_coord_owner_pid" || -z "$_coord_heartbeat_start" || "$started" != "$_coord_heartbeat_start" ]]; then
        print -u2 'run.sh: cannot prove heartbeat ownership; retaining the COORD lease'
        return 1
      fi
      kill -TERM "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    _coord_heartbeat_pid=""
  fi
  if (( ${_coord_lease_held:-0} )); then
    if _coord_lease_run lease release swift-slot --lane "$_coord_suite_lane"; then
      _coord_lease_held=0
    else
      print -u2 'run.sh: COORD lease release failed; follow the recorded holder before starting another suite'
      return 1
    fi
  fi
}
