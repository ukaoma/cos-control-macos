#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/dist/work-session-hub-checks"
mkdir -p "$OUT"
sed 's/@main struct WorkTaskContextChecks/struct WorkTaskContextChecks/' "$ROOT/Tests/WorkTaskContextChecks.swift" > "$OUT/ContextChecks.swift"
# 0.5.310: a high-effort Work chat plan may run 180 s on server 6.73.12 (WORK_CHAT_DEADLINE_MS). The helper's wait
# (its timeout plus 2 s) must outlast that, and Control's wait for the helper must outlast the helper.
python3 - "$ROOT/HelperSources/main.swift" "$ROOT/Sources/WorkHandoffStore.swift" <<'PY'
import re, sys
helper, store = (open(p).read() for p in sys.argv[1:3])
chat = helper[helper.index("    private func emitWorkChat() throws {"):helper.index("    private func emitWorkChatCapabilities() throws {")]
h = int(re.search(r'request\("/api/work/chat", method: "POST".*?timeout: (\d+)\)', chat, re.S).group(1))
c = int(re.search(r'args\.first == "work-chat" \? (\d+)', store).group(1))
assert h >= 185, f"helper waits {h}s for a plan the server may run for 180s"
assert c >= h + 2 + 5, f"Control waits {c}s for a helper that may wait {h + 2}s"
print(f"PASS Work chat timeouts: server 180s < helper {h}s (+2) < Control {c}s")
PY
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/COSControlApp.swift}")
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
 "${SOURCES[@]}" "$ROOT/Tests/WorkInputChecks.swift" "$ROOT/Tests/WorkSessionHubChecks.swift" "$ROOT/Tests/WorkActivityChecks.swift" "$ROOT/Tests/WorkOrchestrationChecks.swift" "$ROOT/Tests/WorkBoardCacheChecks.swift" "$OUT/ContextChecks.swift" -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$OUT/hub-checks"
"$OUT/hub-checks" --render "$OUT/renders"
