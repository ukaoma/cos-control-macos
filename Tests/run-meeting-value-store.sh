#!/bin/zsh
# Actual saved-Ask Store canary. No app/window activation or production home reads.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-meeting-value-store.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
import pathlib, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
(tmp/'COSControlApp.swift').write_text((root/'Sources/COSControlApp.swift').read_text().replace('@main\n','',1))
PY
sources=("$ROOT"/Sources/*.swift)
sources=("${(@)sources:#*/COSControlApp.swift}")
"$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "$sources[@]" "$TMP/COSControlApp.swift" "$ROOT/Tests/MeetingValueStoreCanary.swift" \
 -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$TMP/canary"
COS_CONTROL_TEST_HOME="$TMP/home" "$TMP/canary"
