#!/usr/bin/env python3
"""0.5.373: the update swap asks COS Control to quit (Miles's Mac, 2026-11-05: 0.5.366 to 0.5.371 were each SIGTERMed
after the swap's 20 s wait, because an install driven from a shell never asked Control to quit). The source text that
ties the three halves together: the helper posts the request, Control listens for it, and the escalation stand-in hears
the same name. Usage: app-update-quit-request-pins.py <repo>. Each failure names its behaviour as "pin failed [...]".

What these pins cannot see is proven by execution: Tests/run-app-quit.sh (the listener on a real NSApplication) and
Tests/app-update-escalation-checks.py case 8 (the real helper asks, a stand-in quits by itself, nothing is signalled).
"""
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
passed = 0


def read(rel):
    return (root / rel).read_text(encoding="utf-8")


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//") and not l.strip().startswith("///"))


def need(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")
    passed += 1


NAME = "com.gotcos.control.appUpdate.quitRequest"
helper = code(read("HelperSources/main.swift"))
quit = code(read("Sources/AppQuit.swift"))
app = code(read("Sources/COSControlApp.swift"))
fixture = read("Tests/fixtures/app-update/live-app.c")

# One name in all three places.
need(f'static let appUpdateQuitRequestName = "{NAME}"' in helper, "one name", "the helper posts " + NAME)
need(f'nonisolated static let name = Notification.Name("{NAME}")' in quit, "one name", "Control listens for " + NAME)
need(f'#define QUIT_REQUEST_NAME "{NAME}"' in fixture, "one name", "the escalation stand-in listens for " + NAME)
need(len(re.findall(r'"com\.gotcos\.control\.appUpdate\.[A-Za-z]+"', helper + quit)) == 2, "one name",
     "no second spelling of the request name in the helper or Control")

# The helper asks, naming the live bundle, delivered immediately, before the normal-quit wait and after the blockers.
post = helper[helper.index("private func requestLiveQuit(_ live: URL) {"):]
post = post[:post.index("\n    }\n")]
need("object: live.path, userInfo: nil, deliverImmediately: true)" in post, "request names the live bundle",
     "requestLiveQuit posts the live bundle's path, delivered immediately (an inactive Control still gets it)")
need(helper.count("requestLiveQuit(live)") == 1, "asks before the wait", "the swap asks exactly once")
swap = helper[helper.index("private func swapStagedApp(live: URL, expectedBuild: Int?) throws {"):]
need(swap.index("let blockers = appUpdateWorkBlockers()") < swap.index("requestLiveQuit(live)") < swap.index("switch quitLiveForSwap(live, timings: timings)"),
     "asks before the wait", "the request comes after the busy check (a refused swap never quits Control) and before the 20 s wait")
need('"quitRequested": true,' in swap and '"quitSeconds": quitSeconds,' in swap, "success records the request",
     "success.json says the swap asked and how long the quit took")

# Control listens for the life of the app, and quits only through AppQuit.request() on a .quit verdict.
need("AppUpdateQuitRequest.install(ownBundle: Bundle.main.bundleURL.path, currentBuild: ControllerModel.currentBuild)" in app,
     "app listens", "COSControlApp installs the listener with its own bundle and build")
need("AppUpdateQuitRequest.quitPending = { MacRecordingTermination.pending }" in app, "app listens",
     "a quit already waiting on the recording's save is not asked again")
need('AppUpdateQuitRequest.pendingRecord = { model.updateFailureRecord.deletingLastPathComponent().appendingPathComponent("pending.json") }' in app,
     "app listens", "the staged build is read from the helper's updates/pending.json")
need(quit.count('AppQuit.request("update swap")') == 1 and 'if decided == .quit { AppQuit.request("update swap") }' in quit,
     "quits through AppQuit", "the listener quits only on a .quit verdict, through AppQuit.request() (never terminate in a job)")
need("addObserver(forName: name, object: nil, queue: .main)" in quit, "app listens", "the observer runs on the main queue")
need("DistributedNotificationCenter.default().postNotificationName(name, object: liveBundle, userInfo: nil, deliverImmediately: true)" in quit,
     "request names the live bundle", "the probe's post matches the helper's")

# The lanes that execute it.
run_sh = read("Tests/run.sh")
need('/usr/bin/cc -O1 -Wall -o "$TMP/live-app" "$ROOT/Tests/fixtures/app-update/live-app.c" -framework CoreFoundation' in run_sh,
     "lanes wired", "Tests/run.sh builds the stand-in with CoreFoundation (its listen mode)")
need('"$ROOT/Tests/run-app-quit.sh"' in run_sh, "lanes wired", "Tests/run.sh runs run-app-quit.sh")
need('/usr/bin/python3 "$ROOT/Tests/app-update-quit-request-pins.py" "$ROOT"' in read("Tests/run-app-quit.sh"), "lanes wired",
     "run-app-quit.sh runs these pins")
need('c = Case("asked")' in read("Tests/app-update-escalation-checks.py"), "lanes wired", "the escalation checks have the asked case")

# Version touchpoints.
plist = read("Resources/Info.plist")
need(re.search(r"<key>CFBundleShortVersionString</key>\s*<string>0\.5\.378</string>", plist) is not None
     and re.search(r"<key>CFBundleVersion</key>\s*<string>432</string>", plist) is not None, "version", "Info.plist is 0.5.378 (build 432), calendars on top of 0.5.377: pet session counts and Meeting Prep on top of Ask Work review, the Messages cleanup and quit fix")
whats = json.loads(read("Resources/WhatsNew.json"))
need(whats.get("version") == "0.5.378" and [s["title"] for s in whats["whatsNew"]["sections"][:6]] == ["0.5.378", "0.5.377", "0.5.376", "0.5.375", "0.5.374", "0.5.373"], "version",
     "What's New is 0.5.377 and retains Meeting Prep, Ask Work review, the Messages cleanup and quit-fix sections in order")
log = read("CHANGELOG.md")
need(log.startswith("## 0.5.378 (build 432)") and log.index("\n## 0.5.373 (build 427)") < log.index("\n## 0.5.372 (build 426)"), "version",
     "the changelog's 0.5.373 entry sits above 0.5.372's")

print(f"app update quit request pins: {passed} passed")
