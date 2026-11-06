#!/usr/bin/env python3
"""Compiled Ask helper contract against private loopback fixtures, never live COS."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

root = Path(tempfile.mkdtemp(prefix="cos-ask-helper-", dir="/tmp"))
token = "a" * 64
token_file = root / "candidate-token"
token_file.write_text(token)
token_file.chmod(0o600)
identity = "a" * 12
work_id = "task:personal:" + identity
revision = "b" * 64
server_id = "9e277c0f-101a-4035-af03-631f8601de49"
calls = []
mode = "good"
row = {"id": identity, "domain": "personal", "text": "Fixture task",
       "workIdentity": identity, "workRevision": revision, "checked": False}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        calls.append((self.command, self.path, None, self.headers.get("X-COS-Token")))
        if self.path == "/api/work-board":
            rows = [] if mode == "missing" else [row, row] if mode == "duplicate" else [row]
            self.respond(200, {"tasks": rows, "capabilities": {"writable": True, "version": 1}})
        elif self.path == "/api/ask/work-plan":
            self.respond(404 if mode == "unavailable" else 200,
                         {"protocolVersion": 1, "planOnly": True,
                          "dispatch": mode == "incompatible", "requiresExistingWork": True})
        else:
            self.respond(500, {"error": "unexpected_route"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        calls.append((self.command, self.path, body, self.headers.get("X-COS-Token")))
        if self.path == "/api/ask/work-plan":
            self.respond(409 if mode == "stale" else 200,
                         {"protocolVersion": 1, "planOnly": True,
                          "workID": "task:personal:" + "c" * 12 if mode == "wrong-work" else work_id,
                          "revision": revision, "question": body["question"], "answer": "Review first.",
                          "assignments": []})
        elif self.path == "/api/work/orchestrator/snapshot":
            self.respond(200, {"protocolVersion": 1, "accepted": True, "workID": work_id,
                               "revision": revision,
                               "serverInstanceId": "wrong-server" if mode == "wrong-server" else server_id})
        else:
            self.respond(500, {"error": "unexpected_route"})


server = HTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
env = {key: value for key, value in os.environ.items() if not key.startswith("COS_")}
env.update(COS_WORK_CONNECTED_TEST="1", COS_WORK_REVIEW_CANDIDATE_PORT=str(server.server_port),
           COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE=str(token_file))


def run(command, body=None, environment=None):
    payload = body if isinstance(body, bytes) else None if body is None else json.dumps(body).encode()
    result = subprocess.run([sys.argv[1], command], input=payload, capture_output=True,
                            env=environment or env, timeout=25)
    return json.loads(result.stdout)


try:
    assert run("ask-work-plan-capabilities")["ok"]
    mode = "unavailable"
    assert run("ask-work-plan-capabilities")["details"]["available"] is False
    mode = "incompatible"
    assert not run("ask-work-plan-capabilities")["ok"]
    mode = "good"
    plan = {"workID": work_id, "revision": revision, "question": "Plan résumé review",
            "planner": "opus", "effort": "high"}
    assert run("ask-work-plan", plan)["ok"]
    assert calls[-2][1] == "/api/work-board" and calls[-1][2] == plan
    for patch in ({"revision": "c" * 64}, {"workID": "task:personal:" + "d" * 12}):
        start = len(calls)
        assert not run("ask-work-plan", dict(plan, **patch))["ok"]
        assert all(call[0] == "GET" for call in calls[start:])
    for mode in ("missing", "duplicate"):
        start = len(calls)
        assert not run("ask-work-plan", plan)["ok"]
        assert all(call[0] == "GET" for call in calls[start:])
    for mode in ("stale", "wrong-work"):
        assert not run("ask-work-plan", plan)["ok"]
    mode = "good"
    for invalid in (dict(plan, send=True), dict(plan, question=" "),
                    dict(plan, question="😀" * 1001), b" " * 12001):
        start = len(calls)
        assert not run("ask-work-plan", invalid)["ok"] and len(calls) == start
    snapshot = {"workID": work_id, "revision": revision, "serverInstanceId": server_id,
                "snapshot": {"sessions": [], "fixture": "snapshot-only"}}
    assert run("ask-work-snapshot", snapshot)["ok"] and calls[-1][2] == snapshot
    mode = "wrong-server"
    assert not run("ask-work-snapshot", snapshot)["ok"]
    mode = "good"
    for invalid in (dict(snapshot, dispatch=True), dict(snapshot, snapshot=[])):
        start = len(calls)
        assert not run("ask-work-snapshot", invalid)["ok"] and len(calls) == start
    for command, body in (("ask-work-plan-capabilities", None), ("ask-work-plan", plan),
                          ("ask-work-snapshot", snapshot)):
        start = len(calls)
        assert not run(command, body, dict(env, COS_CONTROL_TEST_HOME=str(root)))["ok"]
        assert len(calls) == start
    start = len(calls)
    token_file.chmod(0o644)
    assert not run("ask-work-plan-capabilities")["ok"] and len(calls) == start
    token_file.chmod(0o600)
    for port in ("3141", "3143"):
        assert not run("ask-work-plan-capabilities", environment=dict(env, COS_WORK_REVIEW_CANDIDATE_PORT=port))["ok"]
        assert len(calls) == start
    link = root / "token-link"
    link.symlink_to(token_file)
    assert not run("ask-work-plan-capabilities", environment=dict(env, COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE=str(link)))["ok"]
    assert len(calls) == start
    assert all(call[3] == token for call in calls)
    assert all(call[1] in ("/api/work-board", "/api/ask/work-plan", "/api/work/orchestrator/snapshot") for call in calls)
    print("PASS compiled Ask helper: exact plan/snapshot transport, canonical CAS, incompatible/stale refusal, bounded input, private token, preview refusal, no send or usage-probe route")
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
    shutil.rmtree(root)
