#!/bin/zsh
# 0.5.317: FluidAudio's command line tool, built from its pinned source tag, for COS Control to bundle in
# Contents/Helpers. FluidAudio (github.com/FluidInference/FluidAudio, Apache-2.0) publishes no binary for v0.17.4, and
# the glasses server's Parakeet install needs exactly this tool, so COS builds it, and build-release.sh signs it with
# the Control Developer ID (hardened runtime) inside the notarized app.
#
# Release machine only. One Swift compile: it runs under Tests/compile-guard.sh like every other compile here.
# The output is unsigned; build-release.sh signs it. Resources/fluidaudio-cli.json pins the source commit, and the
# release refuses a binary whose SHA-256 does not match the pinned build (COS_FLUIDAUDIO_CLI points at it).
#
#   scripts/build-fluidaudio-cli.sh            build into dist/fluidaudio-cli/ and print its SHA-256
#   scripts/build-fluidaudio-cli.sh --check    compare a new build with the pinned SHA-256 (exit 65 on a mismatch)
set -euo pipefail
ROOT="${0:A:h:h}"
PIN="$ROOT/Resources/fluidaudio-cli.json"
read_pin() { /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$PIN" "$1"; }
VERSION="$(read_pin version)"
COMMIT="$(read_pin sourceCommit)"
REPO="$(read_pin sourceRepository)"
# Under /private/tmp, never a home folder: SwiftPM embeds the build path in the binary (its resource bundle lookup).
WORK="${COS_FLUIDAUDIO_WORK:-/private/tmp/cos-fluidaudio-$VERSION}"
SOURCE="$WORK/source"
OUT="${COS_FLUIDAUDIO_DIST:-$ROOT/dist/fluidaudio-cli}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if [[ ! -d "$SOURCE/.git" ]]; then
  /bin/mkdir -p "$WORK"
  /usr/bin/git clone --quiet --no-checkout "$REPO" "$SOURCE"
fi
/usr/bin/git -C "$SOURCE" fetch --quiet origin "refs/tags/v$VERSION:refs/tags/v$VERSION"
# The tag must still name the pinned commit, and the tree must be exactly that commit.
[[ "$(/usr/bin/git -C "$SOURCE" rev-parse "v$VERSION^{commit}")" == "$COMMIT" ]] || { print -u2 "FluidAudio v$VERSION no longer points at $COMMIT"; exit 65; }
/usr/bin/git -C "$SOURCE" -c advice.detachedHead=false checkout --quiet --force "$COMMIT"
/usr/bin/git -C "$SOURCE" clean -fdxq
[[ -z "$(/usr/bin/git -C "$SOURCE" status --porcelain)" ]] || { print -u2 "FluidAudio source tree is not clean"; exit 65; }

# Version facts the server can read without running the tool (0.17.4 has no --version): an Info.plist linked into
# __TEXT,__info_plist. codesign -dv shows it, and build-release.sh signs with the same identifier.
PLIST="$WORK/fluidaudiocli-Info.plist"
/bin/cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$(read_pin identifier)</string>
<key>CFBundleName</key><string>fluidaudiocli</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>FluidAudioSourceCommit</key><string>$COMMIT</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$PLIST" >/dev/null

cd "$SOURCE"
"$ROOT/Tests/compile-guard.sh" /usr/bin/swift build -c release --product fluidaudiocli --arch arm64 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"
BIN="$(/usr/bin/swift build -c release --product fluidaudiocli --arch arm64 --show-bin-path)/fluidaudiocli"
[[ -x "$BIN" ]] || { print -u2 "swift build produced no fluidaudiocli"; exit 66; }
# Only system libraries: the tool must run from Contents/Helpers on a Mac with nothing else installed.
/usr/bin/otool -L "$BIN" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}' | while read -r dependency; do
  case "$dependency" in /System/Library/*|/usr/lib/*) ;; *) print -u2 "External dependency: $dependency"; exit 66 ;; esac
done
/usr/bin/vtool -show-build "$BIN" | /usr/bin/grep -q 'minos 14.0' || { print -u2 "fluidaudiocli must target macOS 14.0"; exit 66; }
# The embedded Info.plist is how the server proves the version: read it back from the Mach-O.
/usr/bin/python3 -I "$ROOT/Tests/check-fluidaudio-cli.py" "$PIN" "$BIN"

/bin/mkdir -p "$OUT"
STAGED="$OUT/fluidaudiocli-$VERSION.new"
/bin/cp "$BIN" "$STAGED"
/bin/chmod 755 "$STAGED"
SHA="$(/usr/bin/shasum -a 256 "$STAGED" | /usr/bin/awk '{print $1}')"
PINNED="$(read_pin builtSHA256)"
if (( CHECK )); then
  /bin/rm -f "$STAGED"
  [[ "$SHA" == "$PINNED" ]] || { print -u2 "Rebuilt fluidaudiocli $SHA differs from the pinned $PINNED"; exit 65; }
  print "PASS fluidaudiocli $VERSION rebuilt byte for byte ($SHA)"
  exit 0
fi
/bin/mv -f "$STAGED" "$OUT/fluidaudiocli-$VERSION"
print "$SHA  fluidaudiocli-$VERSION" | /usr/bin/tee "$OUT/fluidaudiocli-$VERSION.sha256"
print "Built $OUT/fluidaudiocli-$VERSION from $REPO $COMMIT. Record builtSHA256 $SHA in Resources/fluidaudio-cli.json."
