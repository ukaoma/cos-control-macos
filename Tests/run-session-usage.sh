#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-usage-checks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
"$ROOT/Tests/compile-guard.sh" swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Tests/SessionUsageChecks.swift" -o "$TMP/checks"
"$TMP/checks"
# The COS cost reader builds a path under the server's data folder, which holds API keys, in exactly one place: the
# allow-listed door. A second site, or any listing of that folder, fails here.
COLLECTOR="$ROOT/HelperSources/SessionUsageCollector.swift"
[[ "$(grep -c 'data.appendingPathComponent(' "$COLLECTOR")" == "1" ]] || { echo "FAIL: cos-usage must open the data folder only through cosDataFile" >&2; exit 1; }
if grep -E 'contentsOfDirectory\(at(Path)?: *data|enumerator\(at: *data' "$COLLECTOR"; then echo "FAIL: cos-usage must never list the data folder" >&2; exit 1; fi
python3 "$ROOT/Tests/session-usage-pins.py" "$ROOT"
