#!/bin/zsh
# Local qualification of the shipped review runtime without replacing installed services.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
umask 077
HERE="${0:A:h}"
APP="${COS_FOUNDATION_APP_PATH:-$HOME/Library/Caches/COS Control Work Preview 0.1.6 Final/COS Control Foundation Lab.app}"
SERVER="${COS_WORK_REVIEW_SERVER_ROOT:-$HERE/../../cos-glasses-server}"
if [[ -d "$HERE/COS Control Foundation Lab.app" ]]; then APP="$HERE/COS Control Foundation Lab.app"; fi
[[ -z "${COS_CONTROL_TEST_HOME:-}" ]] || { print -u2 'Use a fresh Terminal for connected Work.'; exit 64; }
[[ -x "$APP/Contents/MacOS/COS Control Foundation Lab" ]] || { print -u2 'Build the Work candidate first.'; exit 66; }
[[ -f "$SERVER/server/scripts/work-review-candidate.ts" && -d "$SERVER/node_modules/tsx" ]] || { print -u2 'Set COS_WORK_REVIEW_SERVER_ROOT to the qualified server checkout.'; exit 66; }
CANDIDATE_ROOT="${COS_WORK_REVIEW_CANDIDATE_HOME:-$HOME/Library/Application Support/COS Control/candidates/work-redesign-review}"
if [[ -n "${COS_WORK_REVIEW_CANDIDATE_HOME:-}" ]]; then
  [[ -d "$CANDIDATE_ROOT" && ! -L "$CANDIDATE_ROOT" && -O "$CANDIDATE_ROOT" ]] || { print -u2 'Provide an existing private candidate directory.'; exit 64; }
else
  mkdir -p "$CANDIDATE_ROOT"
fi
JOURNAL="$HOME/Library/Application Support/COS Control/work-handoffs/handoffs.json"
if [[ -f "$JOURNAL" && ! -f "$CANDIDATE_ROOT/handoffs-before-redesign.json" ]]; then
  cp -p "$JOURNAL" "$CANDIDATE_ROOT/handoffs-before-redesign.json"
  chmod 600 "$CANDIDATE_ROOT/handoffs-before-redesign.json"
fi
# This backup is evidence only. Never restore it automatically after new sends:
# doing so could remove delivery receipts and allow duplicate handoffs.
export COS_WORK_REVIEW_CANDIDATE_HOME="$CANDIDATE_ROOT"
export COS_WORK_REVIEW_CANDIDATE_PORT="${COS_WORK_REVIEW_CANDIDATE_PORT:-3157}"
export COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE="$CANDIDATE_ROOT/candidate-token"
export COS_WORK_CONNECTED_TEST=1 COS_CONTROL2_FOUNDATION=1
unset COS_CONTROL_TEST_API_PORT
node --import "$SERVER/node_modules/tsx/dist/esm/index.mjs" "$SERVER/server/scripts/work-review-candidate.ts" > "$CANDIDATE_ROOT/service.log" 2>&1 &
REVIEW_PID=$!
trap 'kill "$REVIEW_PID" 2>/dev/null || true' EXIT INT TERM
READY=0
for i in {1..100}; do
  kill -0 "$REVIEW_PID" 2>/dev/null || { print -u2 "Review service stopped. See $CANDIDATE_ROOT/service.log"; exit 70; }
  if /usr/bin/grep -q '"ready":true' "$CANDIDATE_ROOT/service.log"; then READY=1; break; fi
  sleep 0.1
done
[[ "$READY" == 1 ]] || { print -u2 'Review service did not become ready.'; exit 70; }
print 'Connected Work: real tasks and saved meetings. Local Ollama review starts only when you click Review.'
"$APP/Contents/MacOS/COS Control Foundation Lab"
