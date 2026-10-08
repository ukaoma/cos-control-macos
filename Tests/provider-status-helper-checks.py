#!/usr/bin/env python3
"""provider-status through the compiled helper (onboarding P1), in a disposable /tmp home with stand-in CLIs and a
loopback Ollama fixture. Proves the wiring the fixture checks cannot see: the verb, --only, raw output reaching the
Cursor parser (a stripped email once read as signed out), no email in the answer, and COS_OLLAMA_HOST.

Usage: provider-status-helper-checks.py <compiled cos-control-helper>. Never runs a real CLI's login; never the live
service.
"""
import json, os, pathlib, shutil, signal, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix="cos-provider-status-", dir="/tmp"))
failed = []

def check(ok, what):
    if not ok:
        failed.append(what)

class Tags(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        body = json.dumps({"models": [{"name": "qwen3:4b"}]}).encode() if self.path == "/api/tags" else b"{}"
        self.send_response(200 if self.path == "/api/tags" else 404); self.end_headers(); self.wfile.write(body)

server = HTTPServer(("127.0.0.1", 0), Tags)
threading.Thread(target=server.serve_forever, daemon=True).start()

def stand_in(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + text)
    path.chmod(0o755)

def run(*args, **extra):
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "COS_CONTROL_TEST_HOME": str(root)}
    env.update(extra)
    proc = subprocess.run([helper, "provider-status", "--json", *args], capture_output=True, text=True, env=env, timeout=60)
    return proc, (json.loads(proc.stdout) if proc.stdout.strip().startswith("{") else {})

try:
    local = root / ".local/bin"
    cbin = root / "cursorbin"
    about_in = 'if [ "$1" = about ]; then printf "About Cursor CLI\\n\\nCLI Version         2026.10.01-fixture\\nUser Email          someone@example.com\\n"; fi\n'
    # Cursor: a foreign `agent` first in line (~/.local/bin), Cursor's own `agent` later on PATH, signed in.
    stand_in(local / "agent", 'echo "agent: unknown command $1"\n')
    stand_in(cbin / "agent", about_in)
    proc, out = run("--only", "cursor", PATH=f"{cbin}:/usr/bin:/bin")
    rows = out.get("details", {}).get("providers", [])
    check(proc.returncode == 0 and out.get("ok") and [r["provider"] for r in rows] == ["cursor"], f"--only cursor answers one row: {proc.stdout[:300]} {proc.stderr[:300]}")
    cursor = rows[0] if rows else {}
    check(cursor.get("binaryPath") == str(cbin / "agent"), f"the foreign agent is skipped: {cursor.get('binaryPath')}")
    check(cursor.get("signIn") == "signedIn" and cursor.get("version") == "2026.10.01-fixture", f"raw output reaches the parser: {cursor.get('signIn')} {cursor.get('version')}")
    check("@" not in proc.stdout and "someone" not in proc.stdout, "no email in the answer")
    # Signed out, and an `about` with no CLI Version line: `status --format json` proves it is Cursor.
    stand_in(cbin / "agent", 'case "$1" in status) printf "{\\"status\\":\\"unauthenticated\\",\\"isAuthenticated\\":false}\\n";; --version) echo 2026.10.01-e373342;; *) echo "Not logged in";; esac\n')
    _, out = run("--only", "cursor", PATH=f"{cbin}:/usr/bin:/bin")
    row = out["details"]["providers"][0]
    check(row["installed"] and row["signIn"] == "signInRequired", f"a signed-out Cursor without CLI Version reads installed, sign in: {row['installed']} {row['signIn']}")
    # Only cursor-agent: Cursor's, but the server runs `agent`, so it is not ready and the row says why.
    (local / "agent").unlink(); shutil.rmtree(cbin)
    stand_in(local / "cursor-agent", about_in)
    _, out = run("--only", "cursor")
    row = out["details"]["providers"][0]
    check(not row["installed"] and "cursor-agent" in (row["detail"] or ""), f"cursor-agent only is not ready: {row}")
    (local / "cursor-agent").unlink()

    # The deadline: three hung Cursor candidates (each command waits for its 6 s timeout) cannot hold the report past
    # about 25 s, the other rows still answer, and no probe outlives the helper.
    hang = 'exec /bin/sleep 117.25\n'
    stand_in(root / "hang1/agent", hang); stand_in(local / "agent", hang); stand_in(root / "hang2/agent", hang)
    started = time.time()
    proc, out = run("--only", "cursor,ollama", PATH=f"{root / 'hang2'}:/usr/bin:/bin", COS_CURSOR_AGENT_BIN=str(root / "hang1/agent"),
                    COS_OLLAMA_HOST=f"127.0.0.1:{server.server_port}")
    took = time.time() - started
    rows = {r["provider"]: r for r in out.get("details", {}).get("providers", [])}
    check(out.get("details", {}).get("complete") is False and rows.get("cursor", {}).get("timedOut") is True, f"a hung CLI answers 'did not answer in time': {out.get('details', {}).get('complete')} {rows.get('cursor')}")
    check(rows.get("ollama", {}).get("daemon") == "running", "the other rows still answer")
    check(took < 32, f"the report stops at its deadline: {took:.1f} s")
    time.sleep(1.5)
    left = subprocess.run(["/usr/bin/pgrep", "-f", "sleep 117.25"], capture_output=True, text=True).stdout.split()
    check(not left, f"no probe outlives the helper: {left}")
    for pid in left:
        os.kill(int(pid), signal.SIGKILL)
    for f in (root / "hang1/agent", local / "agent", root / "hang2/agent"):
        f.unlink()

    # Ollama through COS_OLLAMA_HOST, then a dead port.
    _, out = run("--only", "ollama", COS_OLLAMA_HOST=f"127.0.0.1:{server.server_port}")
    ollama = out["details"]["providers"][0]
    check(ollama["daemon"] == "running" and ollama["models"] == ["qwen3:4b"] and ollama["host"] == f"http://127.0.0.1:{server.server_port}", f"COS_OLLAMA_HOST is honoured: {ollama}")
    _, out = run("--only", "ollama", COS_OLLAMA_HOST="127.0.0.1:9")
    check(out["details"]["providers"][0]["daemon"] == "down", "a dead port is daemon down")

    # A bad --only is refused, never ignored.
    proc, out = run("--only", "claude,bogus")
    check(proc.returncode != 0 and out.get("ok") is False, "an unknown provider is refused")

    # Voice (local Whisper): read-only facts in an empty home, then the in-app setup against a stand-in "node" that
    # prints the server's own download lines (never the real server, never a real download), then Cancel.
    proc = subprocess.run([helper, "voice-status"], capture_output=True, text=True, timeout=60,
                          env={"PATH": "/usr/bin:/bin", "HOME": str(root), "COS_CONTROL_TEST_HOME": str(root)})
    facts = json.loads(proc.stdout)["details"]
    want = {"balanced": 1_624_555_275 + 487_614_201 + 3_095_033_483 + 26_485_263, "max": 1_624_555_275 + 3_095_033_483 + 26_485_263}
    check(facts["missingBytes"] == want, f"voice-status counts every missing model per tier: {facts['missingBytes']}")
    check(facts["setupAvailable"] is False, "no installed server: in-app setup is not offered")
    gen = root / "gen"
    (gen / "node_modules/@gotcos/glasses-server/bin").mkdir(parents=True)
    (gen / "node_modules/@gotcos/glasses-server/bin/cli.cjs").write_text("// stand-in\n")
    # The new phase refuses an older CLI before it can write tier keys. The signed-runtime
    # canary covers success/progress, cancellation, and recovery of a legacy snapshot.
    runtime = root / "Library/Application Support/COS Control/runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    (runtime / "active.json").write_text(json.dumps({"version": "6.65.0", "generationPath": str(gen),
        "installedAt": "2026-10-08T00:00:00Z", "previousVersions": [], "nodePath": "/usr/bin/false"}))
    env_file = root / ".cos-glasses/.env"
    env_file.parent.mkdir(exist_ok=True)
    settings = "COS_WHISPER_TRANSCRIPTION_TIER=max\nOTHER=kept\n"
    env_file.write_text(settings)
    venv = {"PATH": "/usr/bin:/bin", "HOME": str(root), "COS_CONTROL_TEST_HOME": str(root)}
    proc = subprocess.run([helper, "voice-setup", "balanced"], capture_output=True, text=True, timeout=60, env=venv)
    check(proc.returncode != 0 and "Update the COS server" in proc.stdout, "older server is refused before setup")
    check(env_file.read_text() == settings, "older server refusal preserves the existing tier")
    facts = json.loads(subprocess.run([helper, "voice-status"], capture_output=True, text=True, timeout=60, env=venv).stdout)["details"]
    check(facts["terminalCommand"].get("balanced", "").endswith("voice-setup balanced"), "Terminal fallback uses this helper")
    bad = subprocess.run([helper, "voice-setup", "turbo"], capture_output=True, text=True, timeout=60, env=venv)
    check(bad.returncode != 0 and "Balanced or Max" in bad.stdout, "unknown tier is refused")

finally:
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)

if failed:
    sys.exit("provider-status helper checks FAILED:\n  " + "\n  ".join(failed))
print("provider-status helper checks: passed (provider identity, fallback, privacy, deadline, orphan cleanup, Ollama, voice-status, old-server refusal, and tier preservation)")
