#!/bin/zsh
# 0.5.320 (Queen's Mac, 2026-10-17): the in-app update never quit Control. AppQuit.request() must quit a real
# NSApplication whose quit is deferred, from inside a main-actor Task; terminate(nil) from the same Task must hang, or
# this lane cannot tell the two apart. One small compile through Tests/compile-guard.sh. The probe never shows a window
# and never becomes the active app (activation policy prohibited).
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-app-quit.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
COS_COMPILE_PROFILE=bounded "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/AppQuit.swift" "$ROOT/Tests/AppQuitRuntime.swift" -framework AppKit -o "$DIR/quit-probe"

# Waits up to $2 tenths of a second for the probe to exit; prints "exited" or "running" and stops a probe still running.
probe() {
  local mode=$1 tenths=$2
  "$DIR/quit-probe" "$mode" 2> "$DIR/$mode.log" &
  local pid=$!
  for (( i = 0; i < tenths; i++ )); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  if kill -0 $pid 2>/dev/null; then kill $pid 2>/dev/null; wait $pid 2>/dev/null || true; print running
  else wait $pid 2>/dev/null || true; print exited; fi
}
scheduled="$(probe scheduled 50)"
if [[ "$scheduled" != exited ]] || ! grep -q "QUIT OK" "$DIR/scheduled.log"; then
  print -u2 "check failed [scheduled quit]: AppQuit.request() from a Task did not quit within 5 s"; cat "$DIR/scheduled.log" >&2; exit 1
fi
direct="$(probe direct 30)"
if [[ "$direct" != running ]] || grep -q "reply task ran" "$DIR/direct.log"; then
  print -u2 "check failed [probe reproduces the hang]: terminate(nil) from a Task quit, so this probe no longer shows the deadlock"; cat "$DIR/direct.log" >&2; exit 1
fi
# The wiring the probe cannot see: every app-initiated quit is scheduled, and a quit defers only while a recording captures.
/usr/bin/python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def code(t): return "\n".join(l for l in t.split("\n") if not l.strip().startswith("//") and not l.strip().startswith("///"))
def fail(behaviour, why): sys.exit(f"pin failed [{behaviour}]: {why}")
for path in sorted((root / "Sources").glob("*.swift")):
    if path.name == "AppQuit.swift": continue
    if re.search(r"\b(NSApplication\.shared|NSApp)\.terminate\(", code(path.read_text(encoding="utf-8"))):
        fail("no direct quit", f"{path.name} calls terminate directly; use AppQuit.request() (a quit inside a Task deadlocks)")
model = code((root / "Sources/ControllerModel.swift").read_text(encoding="utf-8"))
install = model[model.index("func installAppUpdate()"):model.index("private func watchAppUpdateApply")]
if "AppQuit.request()" not in install: fail("update quits", "installAppUpdate must quit with AppQuit.request()")
views = code((root / "Sources/Views.swift").read_text(encoding="utf-8"))
if 'Button("Quit", systemImage: "power") { AppQuit.request() }' not in views: fail("quit button", "the menu's Quit uses AppQuit.request()")
rec = code((root / "Sources/MacRecording.swift").read_text(encoding="utf-8"))
handler = rec[rec.index("func applicationShouldTerminate"):rec.index("return .terminateLater\n    }")]
if "MacRecordingTermination.pending || MacRecordingTermination.needsPrepare?() ?? true else { return .terminateNow }" not in handler:
    fail("defer only while capturing", "applicationShouldTerminate quits at once unless a quit is pending or a recording needs teardown")
if 'var needsQuitTeardown: Bool { ["starting", "recording", "stopping"].contains(phase) }' not in rec:
    fail("defer only while capturing", "needsQuitTeardown covers exactly the phases prepareToQuit acts on")
app = code((root / "Sources/COSControlApp.swift").read_text(encoding="utf-8"))
if "MacRecordingTermination.needsPrepare = { model.macRecording.needsQuitTeardown }" not in app:
    fail("defer only while capturing", "COSControlApp wires needsPrepare to the recording store")
quit = code((root / "Sources/AppQuit.swift").read_text(encoding="utf-8"))
if "perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)" not in quit:
    fail("scheduled quit", "AppQuit.request() runs terminate from a zero-delay perform")
PY
print "PASS: app quit (0.5.320): AppQuit.request() from a Task quits with a deferred reply; terminate(nil) from the same Task hangs (probe still running at 3 s)"
