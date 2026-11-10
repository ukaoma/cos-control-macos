#!/bin/zsh
# 0.5.387 (D4): duplicate ids from the helper or the server never trap (pet completion diff, meeting calendar counts),
# and the usage summary's GROUP BY runs off a covering index instead of a temp B-tree.
set -euo pipefail
ROOT="${0:A:h:h}"
TARGET="arm64-apple-macosx14.0"
TMP="$(mktemp -d /tmp/cos-stability-d4.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target "$TARGET" -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/StabilityD4Checks.swift" -framework AppKit -o "$TMP/stability-d4"
"$TMP/stability-d4"
"$ROOT/Tests/compile-guard.sh" swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Tests/StabilityD4HelperChecks.swift" \
  -o "$TMP/stability-d4-helper"
"$TMP/stability-d4-helper"
# A uniqueKeysWithValues back in either place would trap on a repeated id again.
if /usr/bin/grep -n -F 'Dictionary(uniqueKeysWithValues:' "$ROOT/Sources/ActivityMeetings.swift"; then
  print -u2 "FAIL: ActivityMeetings must not build server-fed dictionaries with uniqueKeysWithValues"; exit 1
fi
if /usr/bin/awk '/static func diff\(/,/^    }$/' "$ROOT/Sources/Models.swift" | /usr/bin/grep -n -F 'Dictionary(uniqueKeysWithValues:'; then
  print -u2 "FAIL: PetCompletionDetector.diff must not use uniqueKeysWithValues"; exit 1
fi
/usr/bin/python3 "$ROOT/Tests/stability-d4-pins.py" "$ROOT"
print "run-stability-d4: PASS"
