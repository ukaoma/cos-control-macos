#!/bin/zsh
# 0.5.320 (Queen's Mac, 2026-10-17): the in-app update never quit Control. AppQuit.request() must quit a real
# NSApplication whose quit is deferred, from inside a main-actor Task; terminate(nil) from the same Task must hang, or
# this lane cannot tell the two apart. One small compile through Tests/compile-guard.sh. The probe never shows a window
# and never becomes the active app (activation policy prohibited).
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-app-quit.XXXXXX)"
LPID=0
trap '(( LPID > 0 )) && kill $LPID 2>/dev/null; rm -rf "$DIR"' EXIT
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
# 0.5.373: the update swap's quit request (AppUpdateQuitRequest). The rule first, then a real never-active NSApplication
# listening as Control does, against posts from a second probe. Every post names a bundle under this run's /tmp folder,
# so a real COS Control (0.5.373 or later) that hears it answers otherBundle and stays open.
if ! "$DIR/quit-probe" decide "$DIR" 2> "$DIR/decide.log"; then
  grep "check failed" "$DIR/decide.log" >&2 || cat "$DIR/decide.log" >&2; exit 1
fi
B="$DIR/live/COS Control.app"; OTHER="$DIR/other/COS Control.app"
mkdir -p "$B" "$OTHER"
print -r -- '{"build": 199}' > "$DIR/pending-newer.json"
print -r -- '{"build": 88}' > "$DIR/pending-same.json"
listen() {   # name, pending record, [pending]: starts a listener for $B (build 88) and waits for READY
  "$DIR/quit-probe" listen "$B" "$2" 88 ${3:-none} 2> "$DIR/$1.log" &
  LPID=$!
  for (( i = 0; i < 50; i++ )); do grep -q READY "$DIR/$1.log" 2>/dev/null && break; sleep 0.1; done
  if ! grep -q READY "$DIR/$1.log" 2>/dev/null; then print -u2 "check failed [setup]: the $1 listener never said READY"; exit 1; fi
  sleep 0.3   # the observer's registration reaches distnoted
}
still_up() {   # behaviour, detail: the listener must still be running 1.5 s after a post; then it is stopped
  sleep 1.5
  if ! kill -0 $LPID 2>/dev/null || grep -q "QUIT OK" "$DIR/$3.log"; then print -u2 "check failed [$1]: $2"; exit 1; fi
  kill $LPID 2>/dev/null; wait $LPID 2>/dev/null || true
}
listen other "$DIR/pending-newer.json"; "$DIR/quit-probe" post "$OTHER"
still_up "ignores another bundle" "a request naming another bundle quit this Control" other
listen same "$DIR/pending-same.json"; "$DIR/quit-probe" post "$B"
still_up "nothing newer staged" "a request with the running build staged quit this Control" same
listen none "$DIR/no-pending.json"; "$DIR/quit-probe" post "$B"
still_up "nothing newer staged" "a request with nothing staged quit this Control" none
listen waiting "$DIR/pending-newer.json" pending; "$DIR/quit-probe" post "$B"
still_up "already quitting" "a request while a quit already waits asked to quit again" waiting
# The swap names /tmp/...; Control's own bundle may read /private/tmp/... (or the other way round): one bundle.
listen asked "$DIR/pending-newer.json"; "$DIR/quit-probe" post "/private$B"
for (( i = 0; i < 50; i++ )); do kill -0 $LPID 2>/dev/null || break; sleep 0.1; done
if kill -0 $LPID 2>/dev/null || ! grep -q "QUIT OK" "$DIR/asked.log"; then
  kill $LPID 2>/dev/null; wait $LPID 2>/dev/null || true
  print -u2 "check failed [quits on its own request]: Control did not quit within 5 s of a request for its own bundle with a newer build staged"; cat "$DIR/asked.log" >&2; exit 1
fi
wait $LPID 2>/dev/null || true
/usr/bin/python3 "$ROOT/Tests/app-update-quit-request-pins.py" "$ROOT"
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
# Settings Release A: the Quit buttons ask first while a Mac recording runs (requestQuit), and quit through AppQuit.request() either way.
if 'Button("Quit", systemImage: "power") { requestQuit() }' not in views or views.count("AppQuit.request()") != 2 or "serverConfirm = .quit } else { AppQuit.request() }" not in views:
    fail("quit button", "the menu's Quit goes through requestQuit, which uses AppQuit.request()")
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
print "PASS: app quit (0.5.320): AppQuit.request() from a Task quits with a deferred reply; terminate(nil) from the same Task hangs (probe still running at 3 s); 0.5.373: the update swap's request quits only its own bundle with a newer build staged"
