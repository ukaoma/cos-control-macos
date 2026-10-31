#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
[[ $# == 2 && "$1" == --helper && -x "$2" ]] || { print -u2 'usage: run-interval-word-naming.sh --helper compiled-helper'; exit 2; }
HELPER="$2"
DIR="$(mktemp -d /tmp/cos-interval-word-checks.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -m 700 "$DIR/home"
export COS_LIVE_CUES_V2=0 COS_SPEAKER_SHADOW=0 COS_MAC_SPEAKER_LIVE=0 COS_MAC_ACOUSTIC_VOICES=0
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "$ROOT/Sources/Models.swift" "$ROOT/Tests/IntervalWordNamingChecks.swift" -framework AppKit -o "$DIR/model-checks"
HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/model-checks"
/usr/bin/python3 "$ROOT/Tests/interval-word-helper-checks.py" "$HELPER"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "${SOURCES[@]}" "$ROOT/Tests/IntervalWordNamingControllerChecks.swift" \
 -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/controller-checks"
HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/controller-checks" "$DIR"
/usr/bin/python3 "$ROOT/Tests/interval-word-ui-source-checks.py" "$ROOT"
