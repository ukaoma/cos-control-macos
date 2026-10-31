#!/bin/zsh
# 0.5.357 (server 6.96.3): merged Speakers rows, the Short voices fold and Suggest names. The rules alone (Models.swift), the compiled
# helper against a private loopback server, the real ControllerModel against a stand-in helper, then the wiring pins. No view is
# created, no window exists and the live server is never called. Every compile goes through the guard, one at a time.
set -euo pipefail
ROOT="${0:A:h:h}"
HELPER=""
if (( $# )); then
  [[ $# == 2 && "$1" == --helper && -x "$2" ]] || { print -u2 'usage: run-voice-display.sh [--helper compiled-helper]'; exit 2; }
  HELPER="$2"
fi
DIR="$(mktemp -d /tmp/cos-voice-display-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -m 700 "$DIR/home"
export COS_LIVE_CUES_V2=0 COS_SPEAKER_SHADOW=0 COS_MAC_SPEAKER_LIVE=0 COS_MAC_ACOUSTIC_VOICES=0
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Tests/VoiceDisplayChecks.swift" -framework AppKit -o "$DIR/model-checks"
HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/model-checks"
if [[ -z "$HELPER" ]]; then
  /usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
    "$ROOT/HelperSources/main.swift" "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/HelperSources/SessionUsageCollector.swift" "$ROOT/Sources/SessionUsageCore.swift" "$ROOT/Sources/WorkSessionLinks.swift" \
    -framework Security -framework AppKit -o "$DIR/cos-control-helper"
  HELPER="$DIR/cos-control-helper"
fi
/usr/bin/python3 "$ROOT/Tests/voice-display-helper-checks.py" "$HELPER"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/VoiceDisplayControllerChecks.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/controller-checks"
HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/controller-checks" "$DIR"
/usr/bin/python3 "$ROOT/Tests/voice-display-pins.py" "$ROOT"
print 'PASS: voice display rules, compiled helper, controller and wiring'
