#!/bin/zsh
# The shipping workspace with local synthetic data; no server or provider starts.
set -euo pipefail
HERE="${0:A:h}"
APP="${COS_FOUNDATION_APP_PATH:-$HOME/Library/Caches/COS Control Work Preview 0.1.7 Final/COS Control Foundation Lab.app}"
if [[ -d "$HERE/COS Control Foundation Lab.app" ]]; then APP="$HERE/COS Control Foundation Lab.app"; fi
[[ -x "$APP/Contents/MacOS/COS Control Foundation Lab" ]] || { print -u2 'Build or unpack the Work candidate first.'; exit 66; }
export COS_CONTROL_TEST_HOME="$(mktemp -d /tmp/cos-work-preview.XXXXXX)"
export COS_CONTROL2_FOUNDATION=1
unset COS_WORK_CONNECTED_TEST COS_WORK_REVIEW_CANDIDATE_PORT COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE COS_CONTROL_TEST_API_PORT
print 'Isolated Work preview: synthetic tasks, reviews, sessions and results. No agent or production task writes.'
exec "$APP/Contents/MacOS/COS Control Foundation Lab"
