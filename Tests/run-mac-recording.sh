#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /private/tmp/cos-mac-recording-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/MacRecordingCore.swift" "$ROOT/Tests/MacRecordingChecks.swift" -o "$DIR/checks"
"$DIR/checks"
# 0.5.310: the Meetings row reads the store's paused state (the label rule itself is checked above). Source pins only:
# the store needs the full app to run, so these prove the wiring exists, not its runtime behaviour.
python3 - "$ROOT/Sources/MacRecording.swift" "$ROOT/Sources/ControllerModel.swift" <<'PY'
import sys
store, model = (open(p).read() for p in sys.argv[1:3])
catch = store[store.index("    func deliverPending() {"):store.index("protocol MacCaptureSession")]
assert "} catch { failed = true; self.deliveryPaused = true;" in catch, "a failed delivery must mark the row paused"
assert catch.index("self.deliveryPaused = false") < catch.index("do {"), "a new delivery attempt must clear the paused state first"
assert "paused: macRecording.deliveryPaused)" in model, "the Meetings row must pass the store's paused state to its label"
print("PASS Mac recording paused-delivery wiring")
PY
