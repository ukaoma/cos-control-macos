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
    fake_node = root / "fake-node"
    grand_file = root / "grandchild.pid"
    script = "\n".join([
        'case "$*" in *"--transcription-tier balanced"*) ;; *) echo "wrong tier: $*"; exit 3;; esac',
        'echo "    Downloading ggml-large-v3 (~3.1 GB)."',
        'sleep 0.3; printf "####     12.5%%\\r"; sleep 0.3; printf "########   48.0%%\\r"; sleep 0.3',
        f'if [ -n "$SLOW" ]; then sleep 30 & echo $! > "{grand_file}"; wait; fi',
        'printf "##########  100.0%%\\n"',
        'echo "  Transcription setup complete"',
        "",
    ])
    stand_in(fake_node, script)
    runtime = root / "Library/Application Support/COS Control/runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    (runtime / "active.json").write_text(json.dumps({"version": "6.65.0", "generationPath": str(gen), "installedAt": "2026-10-08T00:00:00Z",
                                                     "previousVersions": [], "nodePath": str(fake_node)}))
    bins = root / "whisperbin"
    stand_in(bins / "whisper-cli", "exit 0\n"); stand_in(bins / "whisper-server", "exit 0\n")
    venv = {"PATH": f"{bins}:/usr/bin:/bin", "HOME": str(root), "COS_CONTROL_TEST_HOME": str(root)}
    proc = subprocess.run([helper, "voice-setup", "balanced"], capture_output=True, text=True, timeout=60, env=venv)
    out = json.loads(proc.stdout or "{}")
    check(proc.returncode == 0 and out.get("ok"), f"voice-setup runs the installed server's setup: {proc.stdout[:300]} {proc.stderr[:300]}")
    check("Downloading Large-v3 (3.1 GB): 48%" in proc.stderr and "Downloading Large-v3 (3.1 GB): 100%" in proc.stderr, f"progress streams per model and percent: {proc.stderr[:400]}")
    bad = subprocess.run([helper, "voice-setup", "turbo"], capture_output=True, text=True, timeout=60, env=venv)
    check(bad.returncode != 0 and "Balanced or Max" in bad.stdout, "an unknown tier is refused")
    slow = subprocess.Popen([helper, "voice-setup", "balanced"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(venv, SLOW="1"))
    for _ in range(100):
        if grand_file.exists() and grand_file.read_text().strip():
            break
        time.sleep(0.1)
    slow.send_signal(signal.SIGTERM)
    slow.wait(timeout=20)
    time.sleep(0.5)
    grand = int(grand_file.read_text().strip()) if grand_file.exists() else 0
    alive = grand > 0 and subprocess.run(["/bin/kill", "-0", str(grand)], capture_output=True).returncode == 0
    check(slow.returncode == 143 and grand > 0 and not alive, f"Cancel stops the whole setup, the download included: exit {slow.returncode}, grandchild {grand} alive {alive}")
    if alive:
        os.kill(grand, signal.SIGKILL)
finally:
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)

if failed:
    sys.exit("provider-status helper checks FAILED:\n  " + "\n  ".join(failed))
print("provider-status helper checks: passed (cursor identity and sign-in, no email, --only, COS_OLLAMA_HOST, voice-status, voice-setup progress and Cancel)")
