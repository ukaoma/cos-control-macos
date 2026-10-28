#!/bin/zsh
# Build-up geometry, by hand only (never a gate): every build-up site's skeleton against its loaded view, measured in points
# on the real call sites at a 760 pt and a 1280 pt window, light and dark (Tests/BuildUpGeometry.swift). Writes PNGs,
# geometry.md and geometry.json to <folder>. A scratch home: no server, no helper. No window is ordered in and nothing is
# clicked, typed or activated. Optional second argument: a comma list of site names.
#   COS_CONTROL_WORK_DISABLED=1 also measures the classic Tasks list (Work replaces it by default).
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: run-build-up-geometry.sh <folder> [site,site]}"
OUT="${OUT:A}"
ONLY="${2:-}"
DIR="$(mktemp -d /tmp/cos-build-up-geometry.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/BuildUpGeometry.swift" "$ROOT/Tests/BuildUpSites.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/build-up-geometry"
HOME_DIR="$DIR/cos-build-up-geometry home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/build-up-geometry" "$OUT" ${ONLY:+"$ONLY"} 2>"$DIR/stderr.log" || { cat "$DIR/stderr.log" >&2; exit 1; }
