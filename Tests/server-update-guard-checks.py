#!/usr/bin/env python3
"""Update Server, and every install that asks for latest, only moves forward. The compiled helper's real resolve and refusal
path against a stand-in npm, a private loopback server and a temporary home: never the live service, npm or ~/.cos-glasses.
install() itself cannot be driven here, because on a Mac whose own server holds the ports its ownership check stops first,
so `self-test-update-guard` runs the two steps install() runs (Tests/session-usage-pins.py pins that install() and
adoptLegacy() call them, ahead of anything that stages or stops). Prints "server update guard checks: N passed".
Usage: server-update-guard-checks.py <helper>"""
import json, os, pathlib, plistlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

checks = 0


def check(value, name):
    global checks
    if not value:
        sys.exit(f"Fatal error: {name}")
    checks += 1


with tempfile.TemporaryDirectory(prefix="cos-update-guard-", dir="/tmp") as tmp:
    home = pathlib.Path(tmp)
    bin_dir = home / "fake-bin"; bin_dir.mkdir()
    state = {"server": None}

    class Health(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            if self.path != "/api/health" or state["server"] is None:
                self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
            raw = json.dumps({"server_version": state["server"]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)

    server = HTTPServer(("127.0.0.1", 0), Health)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "COS_CONTROL_TEST_HOME": tmp, "COS_CONTROL_TEST_API_PORT": str(server.server_port), "HOME": tmp, "CFFIXED_USER_HOME": tmp}
    runtime = home / "Library/Application Support/COS Control/runtime"; runtime.mkdir(parents=True)
    manifest_file = runtime / "active.json"
    agents = home / "Library/LaunchAgents"; agents.mkdir(parents=True)
    plist_file = agents / "com.cos.glasses-server.plist"

    def stand_ins(latest):
        node = bin_dir / "node"; node.write_text('#!/bin/sh\nprintf "v22.0.0\\n"\n'); node.chmod(0o755)
        npm = bin_dir / "npm"
        npm.write_text('#!/bin/sh\ncase "$3" in\n  *@[0-9]*) v="${3##*@}" ;;\n  *) v="' + latest + '" ;;\nesac\n'
                       'printf \'{"version":"%s","dist.integrity":"sha512-fake"}\' "$v"\n')
        npm.chmod(0o755)

    def scenario(latest, manifest=None, running=None, legacy=None, version=None, previous=("6.90.0",)):
        stand_ins(latest)
        state["server"] = running
        manifest_file.unlink(missing_ok=True); plist_file.unlink(missing_ok=True)
        if manifest:
            manifest_file.write_text(json.dumps({"version": manifest, "generationPath": str(home / "gen"), "installedAt": "2026-10-31T00:00:00Z", "previousVersions": list(previous)}))
        if legacy:
            app = home / "legacy-app"; app.mkdir(exist_ok=True)
            (app / "package.json").write_text(json.dumps({"name": legacy[0], "version": legacy[1]}))
            plist_file.write_bytes(plistlib.dumps({"Label": "com.cos.glasses-server", "ProgramArguments": ["/bin/bash", str(app / "cos-glasses-app/start-server.sh")], "EnvironmentVariables": {"COS_GLASSES_APP_DIR": str(app)}}))
        args = ["self-test-update-guard"] + (["--version", version] if version else [])
        done = subprocess.run([sys.argv[1], *args], capture_output=True, text=True, env=env, timeout=60)
        try:
            return json.loads(done.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            sys.exit(f"Fatal error: the probe gave no JSON: {(done.stdout + done.stderr)[:400]}")

    newer = scenario("6.94.2", manifest="6.96.3")
    check(newer["ok"] is False and "6.96.3" in newer["message"] and "6.94.2" in newer["message"] and "nothing changed" in newer["message"], "a stopped managed server newer than latest is refused")
    check("Roll back server" in newer["message"], "the refusal names the way back on purpose")
    check("--" not in newer["message"] and "—" not in newer["message"], "the refusal is plain words")
    check(scenario("6.94.2", manifest="6.96.3", version="6.90.0")["ok"] is True, "a named older version still installs")
    check(scenario("6.94.2", manifest="6.94.2")["ok"] is True, "the same version reinstalls")
    check(scenario("6.96.3", manifest="6.94.2")["ok"] is True, "a newer latest updates")
    check(scenario("6.100.0", manifest="6.96.3")["ok"] is True, "a higher number in any place is newer")
    check(scenario("6.94.2")["ok"] is True, "a fresh Mac has nothing to protect")
    running = scenario("6.94.2", running="6.96.3")
    check(running["ok"] is False and "6.96.3" in running["message"], "a running server newer than latest is refused")
    check("Roll back" not in running["message"], "no rollback hint without a managed server")
    bare = scenario("6.94.2", manifest="6.96.3", previous=())
    check(bare["ok"] is False and "Roll back" not in bare["message"] and bare["message"].endswith("nothing changed."), "no rollback hint when the manifest retains nothing to roll back to")
    check(scenario("6.94.2", manifest="6.90.0", running="6.96.3")["ok"] is False, "a running server newer than the manifest is refused")
    check(scenario("6.94.2", manifest="6.96.3", running="6.90.0")["ok"] is False, "a manifest newer than the running server is refused")
    check(scenario("6.94.2", running="6.94.2")["ok"] is True, "a running server on latest reinstalls")
    check(scenario("6.94.2", legacy=("@gotcos/glasses-server", "6.96.3"))["ok"] is False, "a stopped legacy server package newer than latest is refused")
    check(scenario("6.94.2", legacy=("cos-glasses-app", "6.96.3"))["ok"] is True, "a folder that is not the server package proves nothing")
    server.shutdown()
print(f"server update guard checks: {checks} passed")
