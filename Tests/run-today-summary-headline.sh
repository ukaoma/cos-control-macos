#!/bin/zsh
# T1 (2026-11-09): the Today headline holds its height (Sources/TodaySummaryHeadline.swift). Executes the
# TodayHeadlineHeight rules and an off-screen layout that records, in points, where the element under the headline sits
# across text swaps, before (the plain Text) and after. Compiled with Models.swift and the one new source file, through the shared
# compile guard. Optional first argument: a folder for the PNGs. Nothing is shown on screen, clicked or typed.
set -euo pipefail
ROOT="${0:A:h:h}"
BIN="$(mktemp /tmp/cos-today-headline.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/TodaySummaryHeadline.swift" "$ROOT/Tests/TodaySummaryHeadlineChecks.swift" -framework AppKit -framework SwiftUI -o "$BIN"
"$BIN" "$ROOT/Resources/Fonts/Fraunces.ttf" "$@"
