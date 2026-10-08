#!/usr/bin/env python3
"""provider-status through the compiled helper (onboarding P1), in a disposable /tmp home with stand-in CLIs and a
loopback Ollama fixture. Proves the wiring the fixture checks cannot see: the verb, --only, raw output reaching the
Cursor parser (a stripped email once read as signed out), no email in the answer, and COS_OLLAMA_HOST.

Usage: provider-status-helper-checks.py <compiled cos-control-helper>. Never runs a real CLI's login; never the live
service.
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
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
    # Cursor: a foreign `agent` first in line, Cursor's own CLI as cursor-agent, signed in.
    stand_in(local / "agent", 'echo "agent: unknown command $1"\n')
    stand_in(local / "cursor-agent", 'if [ "$1" = about ]; then printf "About Cursor CLI\\n\\nCLI Version         2026.10.01-fixture\\nUser Email          someone@example.com\\n"; fi\n')
    proc, out = run("--only", "cursor")
    rows = out.get("details", {}).get("providers", [])
    check(proc.returncode == 0 and out.get("ok") and [r["provider"] for r in rows] == ["cursor"], f"--only cursor answers one row: {proc.stdout[:300]} {proc.stderr[:300]}")
    cursor = rows[0] if rows else {}
    check(cursor.get("binaryPath", "").endswith("/.local/bin/cursor-agent"), f"the foreign agent is skipped: {cursor.get('binaryPath')}")
    check(cursor.get("signIn") == "signedIn" and cursor.get("version") == "2026.10.01-fixture", f"raw output reaches the parser: {cursor.get('signIn')} {cursor.get('version')}")
    check("@" not in proc.stdout and "someone" not in proc.stdout, "no email in the answer")

    # Signed out.
    stand_in(local / "cursor-agent", 'printf "About Cursor CLI\\nCLI Version 1.2.3\\nUser Email          Not logged in\\n"\n')
    _, out = run("--only", "cursor")
    check(out["details"]["providers"][0]["signIn"] == "signInRequired", "a signed-out Cursor reads sign-in required")

    # Ollama through COS_OLLAMA_HOST, then a dead port.
    _, out = run("--only", "ollama", COS_OLLAMA_HOST=f"127.0.0.1:{server.server_port}")
    ollama = out["details"]["providers"][0]
    check(ollama["daemon"] == "running" and ollama["models"] == ["qwen3:4b"] and ollama["host"] == f"http://127.0.0.1:{server.server_port}", f"COS_OLLAMA_HOST is honoured: {ollama}")
    _, out = run("--only", "ollama", COS_OLLAMA_HOST="127.0.0.1:9")
    check(out["details"]["providers"][0]["daemon"] == "down", "a dead port is daemon down")

    # A bad --only is refused, never ignored.
    proc, out = run("--only", "claude,bogus")
    check(proc.returncode != 0 and out.get("ok") is False, "an unknown provider is refused")
finally:
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)

if failed:
    sys.exit("provider-status helper checks FAILED:\n  " + "\n  ".join(failed))
print("provider-status helper checks: passed (cursor identity and sign-in, no email, --only, COS_OLLAMA_HOST)")
