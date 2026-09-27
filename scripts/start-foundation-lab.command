#!/bin/zsh
# This-Mac source-checkout launcher. Starts only a disposable lab, never launchd.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
SERVER_ROOT="${COS_FOUNDATION_SERVER_ROOT:-/Users/ukaoma/Documents/GitHub/cos-glasses-server}"
HERE="${0:A:h}"
DEFAULT_APP="$HOME/Library/Caches/COS Control Work Preview/COS Control Foundation Lab.app"
if [[ -d "$HERE/COS Control Foundation Lab.app" ]]; then DEFAULT_APP="$HERE/COS Control Foundation Lab.app"; fi
APP="${COS_FOUNDATION_APP_PATH:-$DEFAULT_APP}"
PORT="${COS_FOUNDATION_PORT:-3147}"
if [[ "$PORT" != <-> ]] || (( PORT < 1024 || PORT > 65535 || PORT == 3141 || PORT == 3143 )); then
  print -u2 'Choose a nonproduction port from 1024–65535 (not 3141 or 3143).'; exit 64
fi
if [[ ! -f "$SERVER_ROOT/bin/control2-foundation.cjs" || ! -x "$APP/Contents/MacOS/COS Control Foundation Lab" ]]; then
  print -u2 'Build the Foundation Lab first, or set COS_FOUNDATION_SERVER_ROOT and COS_FOUNDATION_APP_PATH.'; exit 66
fi
if /usr/sbin/lsof -n -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  print -u2 "Port $PORT is already occupied. No process was stopped. Quit the other lab or choose COS_FOUNDATION_PORT."; exit 69
fi
NODE="$(command -v node)"
if [[ -n "${COS_FOUNDATION_TEST_HOME:-}" ]]; then
  # The backend validates ownership, permissions and canonical containment before
  # any write. Never chmod an existing directory supplied by the operator.
  export COS_CONTROL_TEST_HOME="$COS_FOUNDATION_TEST_HOME"
else
  export COS_CONTROL_TEST_HOME="$(mktemp -d /tmp/cos-control2-lab.XXXXXX)"
  chmod 700 "$COS_CONTROL_TEST_HOME"
fi
export COS_CONTROL2_FOUNDATION=1
export COS_CONTROL_TEST_API_PORT="$PORT"
export COS_CONTROL2_DRAFT_ENABLED="${COS_CONTROL2_DRAFT_ENABLED:-1}"
# The operator-supplied resume home has not yet been validated. Keep logs in
# independently created private files, never a redirection beneath that path.
LAB_LOG="$(mktemp /tmp/cos-control2-backend.XXXXXX)"
NATIVE_LOG="$(mktemp /tmp/cos-control2-native.XXXXXX)"
chmod 600 "$LAB_LOG" "$NATIVE_LOG"
BACKEND_PID=''
APP_PID=''
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then kill -TERM "$APP_PID" 2>/dev/null || true; fi
  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill -TERM "$BACKEND_PID" 2>/dev/null || true
    wait "$BACKEND_PID" 2>/dev/null || true
  fi
  print "Lab stopped. Disposable evidence retained at $COS_CONTROL_TEST_HOME"
  print "Logs retained at $LAB_LOG and $NATIVE_LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$NODE" "$SERVER_ROOT/bin/control2-foundation.cjs" >"$LAB_LOG" 2>&1 &
BACKEND_PID=$!
READY=0
for attempt in {1..120}; do
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    print -u2 "Lab backend could not start. See $LAB_LOG"; exit 70
  fi
  if /usr/bin/grep -q '"ready":true' "$LAB_LOG"; then READY=1; break; fi
  sleep 0.25
done
if (( READY == 0 )); then print -u2 "Lab readiness timed out. See $LAB_LOG"; exit 70; fi
print "COS Control Work Preview ready on localhost:$PORT. Quit the lab app to stop its backend."
if [[ "$COS_CONTROL2_DRAFT_ENABLED" == '1' ]]; then
  print 'One manual no-tool text draft is enabled per backend process. Publication stays unavailable.'
else
  print 'Manual drafting is disabled. Publication stays unavailable.'
fi
"$APP/Contents/MacOS/COS Control Foundation Lab" >"$NATIVE_LOG" 2>&1 &
APP_PID=$!
wait "$APP_PID"
APP_PID=''
