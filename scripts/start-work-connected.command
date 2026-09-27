#!/bin/zsh
# Explicit operator test window. Uses existing server/config; starts no services.
set -euo pipefail
HERE="${0:A:h}"
APP="${COS_FOUNDATION_APP_PATH:-$HOME/Library/Caches/COS Control Work Preview 0.1.6 Final/COS Control Foundation Lab.app}"
if [[ -d "$HERE/COS Control Foundation Lab.app" ]]; then APP="$HERE/COS Control Foundation Lab.app"; fi
if [[ -n "${COS_CONTROL_TEST_HOME:-}" ]]; then
  print -u2 'A test-home environment cannot open connected Work. Use a fresh Terminal window.'; exit 64
fi
[[ -x "$APP/Contents/MacOS/COS Control Foundation Lab" ]] || { print -u2 'Build the Work candidate first.'; exit 66; }
export COS_WORK_CONNECTED_TEST=1
export COS_CONTROL2_FOUNDATION=1
unset COS_CONTROL_TEST_API_PORT
print 'Connected Work candidate: real tasks and sessions; sending requires your explicit button click.'
exec "$APP/Contents/MacOS/COS Control Foundation Lab"
