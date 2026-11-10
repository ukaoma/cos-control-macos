#!/bin/zsh
# Lane D1 (0.5.387): the install cohort (Sources/InstallCohort.swift).
#   run-install-cohort.sh                          pins (Tests/install-cohort-pins.py), then the decision table, the KeyLanes
#                                                  adoption, the lazy defaults and the live probes, compiled with
#                                                  InstallCohort.swift and Models.swift (Tests/InstallCohortChecks.swift)
#   COS_INSTALL_COHORT_LANE=pins|checks ...        one lane alone (Tests/mutate-install-cohort.py)
# Fixtures only: a throwaway home and defaults suite, no window, no server.
set -euo pipefail
ROOT="${0:A:h:h}"
LANE="${COS_INSTALL_COHORT_LANE:-all}"
DIR="$(mktemp -d /tmp/cos-install-cohort.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"

if [[ "$LANE" == "all" || "$LANE" == "pins" ]]; then
  OUT="$(/usr/bin/python3 "$ROOT/Tests/install-cohort-pins.py" "$ROOT")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*pins: }%% passed*}"
  (( COUNT >= 24 )) || { print -u2 "install cohort pins ran only $COUNT (expected at least 24)"; exit 1; }
fi

if [[ "$LANE" == "all" || "$LANE" == "checks" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 \
    -strict-concurrency=complete -parse-as-library "$ROOT/Sources/Models.swift" "$ROOT/Sources/InstallCohort.swift" "$ROOT/Tests/InstallCohortChecks.swift" \
    -framework AppKit -framework SwiftUI -o "$DIR/install-cohort-checks"
  OUT="$(env CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" "$DIR/install-cohort-checks")" || { print -r -- "$OUT"; exit 1; }
  print -r -- "$OUT"
  COUNT="${${OUT##*checks: }%% passed*}"
  (( COUNT >= 94 )) || { print -u2 "install cohort checks ran only $COUNT (expected at least 94)"; exit 1; }
fi
