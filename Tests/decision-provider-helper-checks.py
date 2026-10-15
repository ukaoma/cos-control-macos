#!/usr/bin/env python3
"""Compiled helper against loopback fixtures only; no provider/model calls or real keys."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix="cos-decision-helper-", dir="/tmp"))
token = "a" * 64
key = "synthetic-subq-key-" + "k" * 32
(root / ".cos-glasses").mkdir(mode=0o700)
(root / ".cos-glasses/.env").write_text("COS_API_TOKEN=" + token + "\n")
(root / ".cos-glasses/.env").chmod(0o600)
settings = {
    "schema": 1, "revision": "b" * 64, "provider": "jev", "overrides": {},
    "saved": {"provider": None, "overrides": {}, "key": key},
    "effective": {"session": "jev", "completion": "jev", "search": "jev"},
    "sources": {"session": "default", "completion": "default", "search": "default"},
    "configured": {"jev": True, "subq": False},
    "models": {"jev": "jev-1.13.0", "subq": "subq-snap-preview"},
    "key": key, "keyStatus": {"subq": {"key": key}},
}
status = {"configured": True, "source": "config", "savedAt": "2026-10-14T00:00:00.000Z", "validatedAt": "2026-10-14T00:00:00.000Z", "key": key}
state = {"get": 200, "patch": 200, "key_set": 200, "key_get": 200, "clear": 200}
calls = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def record(self):
        assert self.headers.get("X-COS-Token") == token
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        calls.append((self.command, self.path, body))
        return body

    def do_GET(self):
        self.record()
        code = state["get" if self.path == "/api/decision-provider" else "key_get"]
        body = settings if self.path == "/api/decision-provider" else status
        self.reply(code, body if code == 200 else {"key": key})

    def do_PATCH(self):
        self.record()
        code = state["patch"]
        self.reply(code, settings if code == 200 else {"error": {"code": "decision_settings_conflict", "message": key}, "key": key})

    def do_POST(self):
        self.record()
        if self.path == "/api/work/search":
            return self.reply(200, {"available": True, "provider": state.get("search_provider", "subq"),
                                    "results": state.get("search_results", [{"id": "a" * 12, "p": 0.8}])})
        code = state["key_set"]
        self.reply(code, status if code == 200 else {"error": {"code": "subq_key_not_accepted", "message": key}, "key": key})

    def do_DELETE(self):
        self.record()
        code = state["clear"]
        self.reply(code, dict(status, source="env") if code == 200 else {"key": key})

server = HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
for name in ("COS_WORK_CONNECTED_TEST", "COS_WORK_REVIEW_CANDIDATE_PORT", "COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE"):
    env.pop(name, None)

def run(command, body=None):
    result = subprocess.run([helper, command], input=json.dumps(body).encode() if body is not None else None,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=25)
    assert key.encode() not in result.stdout and key.encode() not in result.stderr, "Key must never appear in helper output"
    return json.loads(result.stdout)

try:
    answer = run("decision-provider-status")
    assert answer["ok"] and answer["details"]["provider"] == "jev" and "key" not in answer["details"]
    assert "key" not in answer["details"]["saved"] and calls[-1][:2] == ("GET", "/api/decision-provider")
    good = {"expectedRevision": "b" * 64, "provider": "subq", "overrides": {"completion": None}}
    assert run("decision-provider-set", good)["ok"] and calls[-1] == ("PATCH", "/api/decision-provider", good)
    before = len(calls)
    for bad in ({"provider": "subq"}, dict(good, expectedRevision="bad"), dict(good, provider="unknown"),
                dict(good, overrides={"intake": "subq"}), dict(good, key=key), dict(good, overrides={"search": False}),
                {"expectedRevision": "b" * 64}):
        assert not run("decision-provider-set", bad)["ok"]
    assert len(calls) == before, "Malformed settings never reach the API"
    state["patch"] = 409
    conflict = run("decision-provider-set", good)
    assert conflict["ok"] and conflict["details"]["reason"] == "decision_settings_conflict", "Model needs a structured conflict, not an opaque helper error"
    for code in (401, 503):
        state["patch"] = code
        assert not run("decision-provider-set", good)["ok"]
    state["get"] = 404
    assert run("decision-provider-status")["details"] == {"available": False}
    state["get"] = 503
    assert not run("decision-provider-status")["ok"]
    state["get"] = 200
    assert run("subq-status")["details"]["configured"] is True
    assert calls[-1][:2] == ("GET", "/api/subq-key/status")
    before = len(calls)
    saved = run("subq-key-set", {"key": key})
    assert saved["ok"] and len(calls) == before + 1 and calls[-1] == ("POST", "/api/subq-key/set", {"key": key})
    assert saved["details"]["source"] == "config", "Saving a key must not PATCH provider choices"
    state["key_set"] = 400
    assert not run("subq-key-set", {"key": key})["ok"]
    state["key_set"] = 404
    assert run("subq-key-set", {"key": key})["details"] == {"available": False}
    before = len(calls)
    for bad in ({}, {"key": ""}, {"key": key, "provider": "subq"}, {"key": "x" * 2049}):
        assert not run("subq-key-set", bad)["ok"]
    assert len(calls) == before
    removed = run("subq-key-clear")
    assert removed["ok"] and removed["details"]["source"] == "env" and removed["details"]["configured"] is True
    assert calls[-1][:2] == ("DELETE", "/api/subq-key")
    state["clear"] = 500
    assert not run("subq-key-clear")["ok"]
    search = run("work-search", {"query": "draft", "scope": "all"})
    assert search["details"]["provider"] == "subq" and search["details"]["results"][0]["p"] == 0.8
    for unknown in ("arbitrary", False):
        state["search_provider"] = unknown
        assert run("work-search", {"query": "draft", "scope": "all"})["details"]["reason"] == "invalid_decision_provider"
    state["search_provider"], state["search_results"] = "none", []
    assert run("work-search", {"query": "draft", "scope": "all"})["details"]["provider"] == "none"
    print("PASS decision helper: authenticated GET/PATCH, strict bounded inputs, null clear, structured 409, older/unavailable servers, secure key save/refusal/remove, no key echo or implicit selection")
finally:
    server.shutdown()
    shutil.rmtree(root)
