#!/bin/zsh
# Future matched release only. Do not invoke while another native lane owns compilation.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-phone-meeting.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home"
/usr/bin/python3 "$ROOT/Tests/phone-meeting-pins.py" "$ROOT"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "$ROOT/Sources/MeetingAskCore.swift" "$ROOT/Sources/LiveTranscript.swift" "$ROOT/Sources/Models.swift" "$ROOT/Tests/PhoneMeetingChecks.swift" -framework AppKit -o "$DIR/checks"
env HOME="$DIR/home" CFFIXED_USER_HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/checks"
