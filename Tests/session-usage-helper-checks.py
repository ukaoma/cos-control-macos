#!/usr/bin/env python3
"""The compiled helper's `session-usage` reading a real .jsonl.zst from a temporary home, through the two places it finds
Node: the app's own BundledNode beside the helper, and the managed runtime's receipt. Each is a stand-in that notes it ran
and then runs a real Node, so the check sees which one the helper chose. Never the live service, ~/.codex or ~/.cos-glasses.
COS_USAGE_TEST_NODE names the real Node to use, such as the bundled 22.23.3.
Prints "session usage helper checks: N passed". Usage: session-usage-helper-checks.py <helper>"""
import json, os, pathlib, shutil, subprocess, sys, tempfile

checks = 0


def check(value, name):
    global checks
    if not value:
        sys.exit(f"Fatal error: {name}")
    checks += 1


PROBE = "process.exit(typeof require('zlib').createZstdDecompress==='function'?0:69)"
named = os.environ.get("COS_USAGE_TEST_NODE")
real = next((n for n in ([named] if named else [shutil.which("node"), "/opt/homebrew/bin/node", "/usr/local/bin/node"])
             if n and os.access(n, os.X_OK) and subprocess.run([n, "-e", PROBE]).returncode == 0), None)
if not real:
    print("SKIPPED, NOT A PASS: no Node here can read zstd (22.15 or later), so the helper's compressed log path did not run.", file=sys.stderr)
    sys.exit(0 if os.environ.get("COS_USAGE_ALLOW_ZSTD_SKIP") == "1" else 3)
rows = [{"type": "session_meta", "payload": {"id": "helper-zst", "model_provider": "openai"}}, {"type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}]
for step in range(1, 6):
    rows.append({"type": "response_item", "payload": {"text": "SECRET_PROMPT_NEVER_STORE"}})
    rows.append({"type": "event_msg", "timestamp": f"2026-10-{step:02d}T12:00:00Z", "payload": {"type": "token_count", "info": {
        "total_token_usage": {"input_tokens": step * 100, "output_tokens": step * 10, "cached_input_tokens": 0},
        "last_token_usage": {"input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 0}}}})
text = "".join(json.dumps(row) + "\n" for row in rows).encode()


def scenario(name, place_node):
    with tempfile.TemporaryDirectory(prefix="cos-usage-helper-", dir="/tmp") as tmp:
        root = pathlib.Path(tmp)
        home = root / "home"; sessions = home / ".codex/sessions/2026/10"; sessions.mkdir(parents=True)
        plain = sessions / "rollout.jsonl"; plain.write_bytes(text)
        subprocess.run([real, "-e", "const f=require('fs'),z=require('zlib');f.writeFileSync(process.argv[1]+'.zst',z.zstdCompressSync(f.readFileSync(process.argv[1])));f.unlinkSync(process.argv[1])", str(plain)], check=True)
        app = root / "app"; app.mkdir()
        helper = app / "cos-control-helper"; shutil.copy(sys.argv[1], helper)
        marker = root / "ran"
        node = place_node(app, home)
        node.parent.mkdir(parents=True, exist_ok=True)
        node.write_text(f'#!/bin/sh\necho x >> "{marker}"\nexec "{real}" "$@"\n'); node.chmod(0o755)
        env = {"PATH": "/usr/bin:/bin", "COS_CONTROL_TEST_HOME": str(home), "HOME": str(home), "CFFIXED_USER_HOME": str(home)}

        def run(*args):
            done = subprocess.run([str(helper), "session-usage", *args], capture_output=True, text=True, env=env, timeout=120)
            check("SECRET_PROMPT" not in done.stdout + done.stderr, f"{name}: no log text reaches the helper's output")
            try:
                return json.loads(done.stdout.strip().splitlines()[-1])
            except (ValueError, IndexError):
                sys.exit(f"Fatal error: {name}: session-usage gave no JSON: {(done.stdout + done.stderr)[:400]}")

        paused = run("--read-only")
        check(paused["ok"] and paused["details"]["buckets"] == [] and paused["details"]["pendingFiles"] == 1, f"{name}: a read-only pass reads nothing and leaves the log waiting")
        check(not marker.exists(), f"{name}: a read-only pass starts no Node")
        read = run()
        check(read["ok"] and sum(b["events"] for b in read["details"]["buckets"]) == 5 and read["details"]["unreadableFiles"] == 0, f"{name}: the compressed log is read")
        check(all(b["provider"] == "OpenAI" and b["model"] == "gpt-6.1-sol" for b in read["details"]["buckets"]), f"{name}: its provider and model arrive")
        check(marker.exists(), f"{name}: the helper chose this Node")
        marker.unlink()
        again = run()
        check(sum(b["events"] for b in again["details"]["buckets"]) == 5 and again["details"]["pendingFiles"] == 0 and not marker.exists(), f"{name}: a finished log starts no Node and counts once")


def bundled(app, home):
    return app / "BundledNode/bin/node"


def managed(app, home):
    runtime = home / "Library/Application Support/COS Control/runtime"; runtime.mkdir(parents=True)
    (runtime / "node-runtime.json").write_text(json.dumps({"version": "22.23.3"}))
    return runtime / "node/22.23.3/bin/node"


scenario("the app's BundledNode", bundled)
scenario("the managed runtime", managed)
print(f"session usage helper checks: {checks} passed (real Node {subprocess.run([real, '--version'], capture_output=True, text=True).stdout.strip()})")
