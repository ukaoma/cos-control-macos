#!/usr/bin/env python3
"""0.5.322: the detached update swap can no longer strand Control on Installing. The REAL helper, dummy signed apps and
a disposable COS_CONTROL_TEST_HOME per case (the click-to-update block's style). The live app is a stand-in process
(Tests/fixtures/app-update/live-app.c) that never quits by itself, so only the swap's signals can end it.

    python3 Tests/app-update-escalation-checks.py <cos-control-helper> <live-app binary>

Each failure names its behaviour as "check failed [<behaviour>]" for Tests/mutate-app-update-escalation.py. Short
timings come from COS_CONTROL_TEST_QUIT_TIMINGS (a /tmp/ test home only; the helper self-test pins production's
20, 10, 5, 60 and 10 s). Every process this script starts is killed at exit, and the helper may only ever signal the
live bundle's own process: every other process is asserted alive and unsignalled by PID.
"""
import hashlib, json, os, pathlib, plistlib, shutil, signal, subprocess, sys, tempfile, time

HELPER, LIVE_BIN = sys.argv[1], sys.argv[2]
# The gaps are wide on purpose: each timing check must separate the right wait from a mutant that skips it by
# seconds, not by lsof's own jitter (a 0.1 s margin let a linger-removal mutant pass by luck).
QUIT, TERM, KILL, UNKNOWN, LINGER = 2.0, 2.0, 1.0, 6.0, 3.0
TIMINGS = f"{QUIT},{TERM},{KILL},{UNKNOWN},{LINGER}"
passed = 0
started = []      # every process this script started
roots = []        # every scratch root


def cleanup():
    for p in started:
        if p.poll() is None:
            try:
                p.kill()
                p.wait(timeout=5)
            except Exception:
                pass
    for root in roots:
        shutil.rmtree(root, ignore_errors=True)


def fail(behaviour, detail):
    print(f"check failed [{behaviour}]: {detail}", flush=True)
    cleanup()
    sys.exit(1)


def check(ok, behaviour, detail=""):
    global passed
    if not ok:
        fail(behaviour, detail)
    passed += 1


def make_app(parent, version, build):
    app = parent / "COS Control.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy2(LIVE_BIN, app / "Contents/MacOS/COS Control")
    with open(app / "Contents/Info.plist", "wb") as f:
        plistlib.dump({"CFBundleIdentifier": "com.gotcos.control", "CFBundleName": "COS Control", "CFBundleExecutable": "COS Control",
                       "CFBundleShortVersionString": version, "CFBundleVersion": build}, f)
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def last_json(text):
    lines = [l for l in text.split("\n") if l.strip().startswith("{")]
    try:
        return json.loads(lines[-1]) if lines else {}
    except ValueError:
        return {}


class Case:
    """A staged update of 0.5.50 (build 88) to 0.5.99 (build 199) in its own home."""

    def __init__(self, name):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix=f"cos-escalate-{name}-", dir="/tmp"))
        roots.append(self.root)
        self.home = self.root / "home"
        self.home.mkdir()
        self.live = make_app(self.root / "live", "0.5.50", "88")
        new = make_app(self.root / "new", "0.5.99", "199")
        zip_path = self.root / "new.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", str(new), str(zip_path)], check=True)
        sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        appcast = self.root / "appcast.json"
        appcast.write_text(json.dumps({"schemaVersion": 1, "killSwitch": {"disableAutoUpdate": False}, "channels": {"stable": {
            "version": "0.5.99", "build": 199, "url": zip_path.as_uri(), "sha256": sha, "minMacOS": "14.0"}}}))
        self.env = {"COS_CONTROL_TEST_HOME": str(self.home), "COS_CONTROL_TEST_QUIT_TIMINGS": TIMINGS, "HOME": str(self.home),
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        self.support = self.home / "Library/Application Support/COS Control"
        self.updates = self.support / "updates"
        out = self.helper(["stage-app-update", "--current-version", "0.5.50", "--current-build", "88",
                           "--appcast-url", appcast.as_uri(), "--live-bundle", str(self.live)])
        check(out[0] == 0 and out[1].get("details", {}).get("reason") == "staged", "setup", f"{name}: the update must stage: {out}")

    def helper(self, args, timeout=90):
        p = subprocess.run([HELPER, *args], env=self.env, capture_output=True, text=True, timeout=timeout)
        return p.returncode, last_json(p.stdout), p.stderr

    def start(self, mode, marker_name, app=None, hold=None):
        exe = (app or self.live) / "Contents/MacOS/COS Control"
        marker = self.root / marker_name
        args = [str(exe), mode, str(marker)] + ([str(hold)] if hold else [])
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        started.append(p)
        deadline = time.time() + 10
        while time.time() < deadline and not (marker.exists() and f"READY {p.pid} " in marker.read_text()):
            time.sleep(0.05)
        check(marker.exists() and f"READY {p.pid} " in marker.read_text(), "setup", f"the stand-in {exe} did not start")
        p.marker = marker
        return p

    def state(self, phase, pid):
        self.support.mkdir(parents=True, exist_ok=True)
        (self.support / "mac-capture-state.json").write_text(json.dumps({"schema": 1, "phase": phase, "pid": pid, "at": "2026-10-17T22:00:00Z"}))

    def swap(self, timeout=90):
        self.swap_started = time.time()
        code, value, err = self.helper(["apply-app-update", "--swap", "--live-bundle", str(self.live), "--expected-build", "199"], timeout)
        self.swap_ended = time.time()
        return code, value, err, self.swap_ended - self.swap_started

    def swap_in_background(self):
        p = subprocess.Popen([HELPER, "apply-app-update", "--swap", "--live-bundle", str(self.live), "--expected-build", "199"],
                             env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        started.append(p)
        return p

    def live_build(self):
        with open(self.live / "Contents/Info.plist", "rb") as f:
            return plistlib.load(f)["CFBundleVersion"]

    def record(self, name):
        path = self.updates / name
        return json.loads(path.read_text()) if path.exists() else None

    def safety(self):
        code, value, _ = self.helper(["app-update-quit-safety", "--live-bundle", str(self.live)])
        check(code == 0, "quit safety verb", f"app-update-quit-safety failed: {value}")
        return value.get("details", {})


def terms(p):
    return sum(1 for line in p.marker.read_text().split("\n") if line.startswith(f"TERM {p.pid} "))


def term_at(p):
    """When SIGTERM arrived (wall clock, seconds), from the stand-in's own line."""
    line = next((l for l in p.marker.read_text().split("\n") if l.startswith(f"TERM {p.pid} ")), "")
    return int(line.split()[2]) / 1000 if line else None


def alive(p):
    return p.poll() is None


try:
    # 1. A live Control that ignores its quit AND SIGTERM: SIGTERM first, SIGKILL after the term grace, then installed.
    #    Unrelated processes: a copy of the same binary at another path, a process holding the live executable open
    #    without running it, and a plain sleep. None may be signalled.
    c = Case("kill")
    live = c.start("ignore", "live.log")
    other_app = make_app(c.root / "other", "0.5.50", "88")
    other = c.start("ignore", "other.log", app=other_app)
    holder = c.start("ignore", "holder.log", app=other_app, hold=c.live / "Contents/MacOS/COS Control")
    sleeper = subprocess.Popen(["/bin/sleep", "300"], start_new_session=True)
    started.append(sleeper)
    c.state("idle", live.pid)
    s = c.safety()
    check(s.get("verdict") == "safe" and s.get("pids") == [live.pid] and s.get("phase") == "idle", "identity filter",
          f"only the process running the live executable counts (the holder only has it open): {s}")
    code, value, err, took = c.swap()
    check(code == 0 and value.get("ok") is True, "forced quit installs", f"the swap must install after forcing the quit: {value} {err[-600:]}")
    check(c.live_build() == "199", "forced quit installs", f"live build is {c.live_build()}")
    try:
        live.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fail("forced quit installs", "the live stand-in is still running after the swap")
    check(live.returncode == -signal.SIGKILL, "sigkill after sigterm", f"a process that ignores SIGTERM ends by SIGKILL, got {live.returncode}")
    check(terms(live) == 1, "sigterm first", f"SIGTERM came first, exactly once: {live.marker.read_text()!r}")
    sent = term_at(live)
    check(sent is not None and sent - c.swap_started >= QUIT - 0.3, "waits for a normal quit",
          f"SIGTERM only after the normal-quit grace ({QUIT} s): it came {((sent or 0) - c.swap_started):.1f} s in")
    check(sent is not None and c.swap_ended - sent >= TERM - 0.3, "sigterm grace",
          f"SIGKILL only after the SIGTERM grace ({TERM} s): the swap ended {(c.swap_ended - (sent or 0)):.1f} s after SIGTERM")
    success = c.record("success.json") or {}
    check(success.get("forcedQuit") is True and success.get("forcedSignals") == ["SIGTERM", "SIGKILL"] and success.get("forcedPids") == [live.pid],
          "success records forced quit", f"success.json: {success}")
    check(value.get("details", {}).get("forcedQuit") is True, "success records forced quit", f"the swap says so too: {value}")
    check(c.record("last-failure.json") is None, "forced quit installs", "a forced install records no failure")
    for name, p in (("same binary at another path", other), ("holds the live executable open", holder)):
        check(alive(p) and terms(p) == 0, "unrelated never signalled", f"{name} (PID {p.pid}) was signalled: alive={alive(p)} {p.marker.read_text()!r}")
    check(alive(sleeper), "unrelated never signalled", f"an unrelated sleep (PID {sleeper.pid}) was signalled")
    with open(c.updates / "previous/COS Control.app/Contents/Info.plist", "rb") as f:
        check(plistlib.load(f)["CFBundleVersion"] == "88", "forced quit installs", "the previous build is kept for rollback")

    # 2. A live Control that dies on SIGTERM: replaced without SIGKILL.
    c = Case("term")
    live = c.start("die", "live.log")
    c.state("saved", live.pid)
    code, value, err, took = c.swap()
    check(code == 0 and c.live_build() == "199", "sigterm is enough", f"the swap must install: {value} {err[-600:]}")
    live.wait(timeout=5)
    check(live.returncode == -signal.SIGTERM and terms(live) == 1, "sigterm is enough", f"ended by SIGTERM, never SIGKILL: {live.returncode}")
    success = c.record("success.json") or {}
    check(success.get("forcedQuit") is True and success.get("forcedSignals") == ["SIGTERM"] and success.get("forcedPids") == [live.pid],
          "sigterm is enough", f"no SIGKILL was sent: {success}")

    # 3. A Mac recording that is starting, recording or stopping is never signalled: reason recording, nothing reopened.
    for phase in ("starting", "recording", "stopping"):
        c = Case(f"rec-{phase}")
        live = c.start("ignore", "live.log")
        c.state(phase, live.pid)
        s = c.safety()
        check(s.get("verdict") == "recording" and s.get("phase") == phase, "recording blocks the kill", f"{phase}: {s}")
        code, value, err, took = c.swap()
        check(code != 0 and "A Mac recording is running" in value.get("message", ""), "recording blocks the kill",
              f"{phase}: the swap must refuse: {value}")
        check(alive(live) and terms(live) == 0, "recording blocks the kill", f"{phase}: the live process was signalled: {live.marker.read_text()!r}")
        check(c.live_build() == "88" and c.record("success.json") is None, "recording blocks the kill", f"{phase}: nothing may be installed")
        failure = c.record("last-failure.json") or {}
        check(failure.get("reason") == "recording" and failure.get("at"), "recording reason", f"{phase}: last-failure.json: {failure}")
        check(took >= QUIT + LINGER - 0.3, "recording reason", f"{phase}: gave up after a normal-quit wait and the linger, took {took:.1f} s")
        live.kill()

    # 4. A state that cannot be read signals nothing: no file, another process's record, two live processes.
    for label in ("no state file", "another process", "two live processes"):
        c = Case("unknown")
        live = c.start("ignore", "live.log")
        second = None
        if label == "another process":
            c.state("idle", sleeper.pid)
        elif label == "two live processes":
            second = c.start("ignore", "second.log")
            c.state("idle", live.pid)
        s = c.safety()
        check(s.get("verdict") == "unknown", "unknown signals nothing", f"{label}: {s}")
        code, value, err, took = c.swap()
        check(code != 0 and "did not quit in time" in value.get("message", ""), "unknown signals nothing", f"{label}: {value}")
        check(alive(live) and terms(live) == 0 and (second is None or (alive(second) and terms(second) == 0)), "unknown signals nothing",
              f"{label}: a process was signalled")
        failure = c.record("last-failure.json") or {}
        check(failure.get("reason") == "quitTimeout" and c.live_build() == "88", "unknown signals nothing", f"{label}: {failure}")
        check(took >= UNKNOWN + LINGER - 0.3, "unknown waits the minute", f"{label}: waited only {took:.1f} s")
        live.kill()
        if second:
            second.kill()
    check(alive(sleeper), "unrelated never signalled", "the sleep named by another record was signalled")

    # 5. Control quits by itself after the swap gave up (inside the linger): installed, never left closed.
    c = Case("linger")
    live = c.start("ignore", "live.log")
    c.state("recording", live.pid)
    swapper = c.swap_in_background()
    deadline = time.time() + QUIT + 10
    while time.time() < deadline and c.record("last-failure.json") is None:
        time.sleep(0.05)
    check(c.record("last-failure.json") is not None, "linger installs", "the swap never recorded that it gave up")
    live.kill()   # Control's own quit finishing late
    live.wait(timeout=5)
    out, err = swapper.communicate(timeout=30)
    check(swapper.returncode == 0 and c.live_build() == "199", "linger installs", f"a late quit inside the linger installs: {out[-400:]} {err[-400:]}")
    check(((c.record("success.json") or {}).get("forcedQuit")) is False and terms(live) == 0, "linger installs", "and nothing was signalled")

    # 6. A normal quit inside the grace: installed, not forced.
    c = Case("normal")
    live = c.start("ignore", "live.log")
    c.state("idle", live.pid)
    swapper = c.swap_in_background()
    time.sleep(0.6)
    live.kill()   # Control quitting normally
    live.wait(timeout=5)
    out, err = swapper.communicate(timeout=30)
    check(swapper.returncode == 0 and c.live_build() == "199", "normal quit", f"{out[-400:]} {err[-400:]}")
    check(((c.record("success.json") or {}).get("forcedQuit")) is False and terms(live) == 0, "normal quit", "a normal quit is not forced")

    # 7. staged-app-update, read only: the launch offer's facts.
    c = Case("staged")
    def staged(current="88"):
        code, value, _ = c.helper(["staged-app-update", "--current-version", "0.5.50", "--current-build", current, "--failure-window", "1800"])
        check(code == 0, "staged verb", f"staged-app-update failed: {value}")
        return value.get("details", {})
    def snapshot():
        return sorted((str(p), p.stat().st_size, p.stat().st_mtime_ns) for p in c.home.rglob("*") if p.is_file())
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    old = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7200))
    check(staged().get("reason") == "noFailedQuit", "staged verb", "no failure record: not offered")
    c.updates.joinpath("last-failure.json").write_text(json.dumps({"reason": "quitTimeout", "at": now}))
    before = snapshot()
    d = staged()
    check(d.get("reason") == "staged" and d.get("version") == "0.5.99" and d.get("build") == 199 and d.get("failureReason") == "quitTimeout"
          and d.get("failureAt") == now, "staged verb", f"a checked stage after a quit timeout: {d}")
    check(snapshot() == before, "staged verb read only", "staged-app-update changed a file")
    c.updates.joinpath("last-failure.json").write_text(json.dumps({"reason": "recording", "at": now}))
    check(staged().get("reason") == "staged", "staged verb", "after a recording refusal too")
    check(staged(current="199").get("reason") == "notNewer", "staged verb", "not newer than the running build")
    c.updates.joinpath("last-failure.json").write_text(json.dumps({"reason": "busy", "at": now}))
    check(staged().get("reason") == "noFailedQuit", "staged verb", "a busy refusal is not a failed quit")
    c.updates.joinpath("last-failure.json").write_text(json.dumps({"reason": "quitTimeout", "at": old}))
    check(staged().get("reason") == "noFailedQuit", "staged verb", "a failure two hours old is not offered")
    c.updates.joinpath("last-failure.json").write_text(json.dumps({"reason": "quitTimeout", "at": now}))
    c.updates.joinpath("success.json").write_text(json.dumps({"version": "0.5.99", "build": 199, "appliedAt": now}))
    check(staged().get("reason") == "noFailedQuit", "staged verb", "an install that succeeded since is not offered again")
    c.updates.joinpath("success.json").unlink()
    pending = json.loads(c.updates.joinpath("pending.json").read_text())
    staged_app = pathlib.Path(pending["stagedAppPath"])
    plist = staged_app / "Contents/Info.plist"
    original = plist.read_bytes()
    plist.write_bytes(original.replace(b"0.5.99", b"0.5.98"))
    before = snapshot()
    d = staged()
    check(d.get("reason") == "unverified", "staged verb verifies", f"a staged app that fails its checks is never offered: {d}")
    check(snapshot() == before, "staged verb read only", "the unverified path changed a file")
    plist.write_bytes(original)
    check(staged().get("reason") == "staged", "staged verb verifies", "restored, it is offered again")
    shutil.move(str(staged_app), str(c.root / "moved.app"))
    check(staged().get("reason") == "missing", "staged verb", "a staged app that is gone")
    c.updates.joinpath("pending.json").unlink()
    check(staged().get("reason") == "none", "staged verb", "nothing staged")
finally:
    pass

cleanup()
print(f"app update escalation checks: {passed} passed (forced quit by PID, SIGTERM then SIGKILL, recording never killed, unknown signals nothing, linger, staged offer)")
