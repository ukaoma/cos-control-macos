#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d /tmp/cos-control-instance.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/ControlInstance.swift" "$ROOT/Tests/ControlInstanceChecks.swift" \
  -framework AppKit -framework Security -framework CoreServices -o "$TMP/checks"
"$TMP/checks"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
app = (root/'Sources/COSControlApp.swift').read_text()
assert app.index('ControlInstance.shared.claimOrExit()') < app.index('let model = ControllerModel()')
source = (root/'Sources/ControlInstance.swift').read_text()
assert 'COS_CONTROL_TEST_HOME' in source and 'SecStaticCodeCheckValidity' in source
assert 'kill(' not in source and 'forceTerminate' not in source
helper = (root/'HelperSources/main.swift').read_text()
start = helper.index('private func emitStageAppUpdate')
end = helper.index('/// Read-only Memory and Threads browsing on the desktop.')
update = helper[start:end]
for forbidden in ['withMutationLock', 'launchctl', 'com.cos.glasses-server', '/api/maintenance/', 'configDir']:
    assert forbidden not in update, forbidden
assert 'unregisterRollbackApp(previousApp)' in update
assert '["-f", live.path]' in update
print('Pre-model exclusion, signed-peer boundary, isolated-test and server-independence gates passed')
PY
