#!/bin/zsh
# One frozen production-source compile runs the existing connection suites in isolation.
# No provider execution, live board writes, desktop events, app launching or window activation.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-meeting-link-test.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/home" "$DIR/proof"
cp -R "$ROOT/Tests/fixtures" "$DIR/fixtures"
python3 - "$ROOT" "$DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
for name in ('WorkHandoffTests','WorkProgressChecks','WorkTaskContextChecks','MeetingTaskLinkChecks'):
    text=(root/'Tests'/f'{name}.swift').read_text()
    assert text.count('@main')==1, name
    (out/f'{name}.swift').write_text(text.replace('@main ', '', 1))
PY
# Preserve the existing downgrade canary's actual legacy journal reader.
git -C "$ROOT" show be3bb89:Sources/WorkHandoffStore.swift | \
  awk 'BEGIN { print "import Foundation\nimport SwiftUI\nimport Darwin" }
       /^@MainActor final class WorkHandoffStore/ { found=1 }
       found { gsub(/WorkHandoffStore/, "LegacyWorkHandoffStore"); print }' \
  > "$DIR/LegacyWorkHandoffStore.swift"
cat > "$DIR/ConnectionCandidateChecks.swift" <<'SWIFT'
import Foundation
@main struct ConnectionCandidateChecks {
    @MainActor static func main() async throws {
        // The existing journal-lock fixture relaunches this same binary in a bounded child mode.
        if CommandLine.arguments.dropFirst().first == "--hold-journal" {
            try await WorkHandoffTests.main()
            return
        }
        try await WorkHandoffTests.main()
        try await WorkProgressChecks.main()
        try WorkTaskContextChecks.main()
        try await MeetingTaskLinkChecks.main()
        print("PASS: integrated Control connection candidate — handoff, progress, clipboard and canonical links")
    }
}
SWIFT
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "${SOURCES[@]}" "$DIR"/*.swift \
  -framework SwiftUI -framework AppKit -framework ServiceManagement -framework WebKit -o "$DIR/checks"
cp -R "$ROOT/Resources/Fonts" "$DIR/Fonts"
CFFIXED_USER_HOME="$DIR/home" HOME="$DIR/home" COS_CONTROL_TEST_HOME="$DIR/home" "$DIR/checks" "$DIR/mock-helper" "${1:-$DIR/proof}"
