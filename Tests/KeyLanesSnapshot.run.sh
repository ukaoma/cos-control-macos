#!/bin/zsh
# K0-G G-control (plan v4 3.3): record or replay the key-lanes snapshot of this checkout.
#   Tests/KeyLanesSnapshot.run.sh <out.json> [--compare <golden.json>] [--png <folder>]
# Two compiles, one after the other, each through Tests/kit-compile.py and Tests/compile-guard.sh (one compile
# machine-wide): provider-status alone (Foundation), then the app Sources with the render harness. No window is ordered
# in, no helper or server runs, nothing opens an app. The JSON written is canonical; nothing in it is normalized.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:?usage: KeyLanesSnapshot.run.sh <out.json> [--compare <golden.json>] [--png <folder>]}"
OUT="${OUT:A}"
shift
COMPARE=""; PNG=""
while (( $# )); do
  case "$1" in
    --compare) COMPARE="${2:A}"; shift 2 ;;
    --png) PNG="${2:A}"; shift 2 ;;
    *) print -u2 "unknown argument $1"; exit 2 ;;
  esac
done
DIR="$(mktemp -d /tmp/cos-home-render.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/HelperSources/ProviderStatusCore.swift" "$ROOT/Tests/KeyLanesSnapshotStatus.swift" -o "$DIR/key-lanes-status"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Tests/KeyLanesSnapshotRender.swift" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/key-lanes-render"
HOME_DIR="$DIR/cos-home-render home.ü"
mkdir -p "$DIR/Fonts" "$HOME_DIR"
cp "$ROOT/Resources/Fonts/"*.ttf "$DIR/Fonts/"
cp "$ROOT/Resources/"*.svg "$DIR/"
STATUS_JSON="$("$DIR/key-lanes-status")"
RENDER_JSON="$(CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" COS_CONTROL_TEST_HOME="$HOME_DIR" "$DIR/key-lanes-render" ${PNG:+"$PNG"} 2>"$DIR/stderr.log")" || { cat "$DIR/stderr.log" >&2; exit 1; }
SHA="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
/usr/bin/python3 - "$OUT" "$SHA" "$STATUS_JSON" "$RENDER_JSON" <<'PY'
import json, sys
out, sha, status, render = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
doc = {"schema": "key-lanes-control-off/1", "golden": "G-control (plan v4 3.3)", "sourceSha": sha,
       "normalizations": [], "providerStatus": status, "render": render}
open(out, "w").write(json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
PY
if [[ -n "$COMPARE" ]]; then
  # The build identity (sourceSha) is expected to change on a candidate; every other byte must match.
  if /usr/bin/python3 -c 'import json,sys
a,b=(json.load(open(p)) for p in sys.argv[1:3])
[d.pop("sourceSha",None) for d in (a,b)]
sys.exit(0 if a==b else 1)' "$COMPARE" "$OUT"; then print "REPLAY OK: identical to $COMPARE (sourceSha excluded)"
  else print "REPLAY DIFF"; diff "$COMPARE" "$OUT" | head -60; exit 1; fi
fi
