#!/usr/bin/env python3
"""0.5.357 (server 6.96.3): the compiled helper against a private loopback server, never the live one. Proves voiceDisplay reaches
Control through meeting-speakers, and how meeting-voice-suggestions answers every server shape.

    python3 Tests/voice-display-helper-checks.py <compiled helper>
"""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

checks = 0


def check(ok, behaviour, detail=""):
    global checks
    checks += 1
    if not ok:
        sys.exit(f"check failed [{behaviour}]: {detail}")


SID = "mac_11111111-1111-4111-8111-111111111111"
DISPLAY = {"source": "speaker-shadow", "recordedAt": "2026-10-30T16:09:00Z", "foldUnderSeconds": 15,
           "groups": [{"id": "g1", "labels": ["Voice 5", "Voice 12"], "seconds": 212.5}, {"id": "g2", "labels": ["Voice 7", "Voice 9"], "seconds": None}],
           "singles": [{"label": "Voice 3", "seconds": None}], "short": [{"label": "Voice 8", "seconds": 4.25}]}
JOB = {"state": "done", "progress": {"done": 753, "total": 753}, "rule": {"floor": 0.7, "margin": 0.05}, "modelSpace": "192d", "sourceRevision": "a" * 64,
       "suggestions": [{"labels": ["Voice 5", "Voice 12"], "name": "Dana Reyes", "score": 0.82, "margin": 0.11, "units": 12, "kept": 10, "requiresConfirmation": True}],
       "unmatched": [{"labels": ["Voice 3"], "gate": "below_rule"}]}

with tempfile.TemporaryDirectory(prefix="cos-voice-display-helper-", dir="/tmp") as tmp:
    home = pathlib.Path(tmp)
    (home / ".cos-glasses").mkdir()
    token = "fixture-" + "b" * 64
    (home / ".cos-glasses/.env").write_text("COS_API_TOKEN=" + token + "\n")
    state = {"status": 200, "body": JOB, "raw": None}
    requests = []
    BATCH_LIST = {"batches": [{"batchId": "b1", "at": "2026-10-30T20:00:00Z", "state": "applied", "named": [], "undoAvailable": True}]}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def answer(self, status, payload, raw=None):
            self.send_response(status)
            self.end_headers()
            self.wfile.write(raw if raw is not None else json.dumps(payload).encode())

        def do_GET(self):
            if self.path == "/api/health":
                self.answer(200, {"ok": True})
                return
            check(self.headers.get("X-COS-Token") == token, "private authentication")
            requests.append(("GET", self.path, None))
            if self.path.endswith("/speakers"):
                self.answer(200, {"sessionId": SID, "voices": [], "voiceDisplay": DISPLAY, "futureField": {"kept": True}})
            else:
                self.answer(state["status"], state["body"], state["raw"])

        def do_POST(self):
            check(self.headers.get("X-COS-Token") == token, "private authentication")
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            requests.append(("POST", self.path, body))
            self.answer(state["status"], state["body"], state["raw"])

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {**os.environ, "HOME": tmp, "COS_CONTROL_TEST_HOME": tmp, "COS_CONTROL_TEST_API_PORT": str(server.server_port),
           "COS_LIVE_CUES_V2": "0", "COS_SPEAKER_SHADOW": "0", "COS_MAC_SPEAKER_LIVE": "0", "COS_MAC_ACOUSTIC_VOICES": "0"}

    def run(*args):
        p = subprocess.run([sys.argv[1], *args], capture_output=True, env=env, timeout=20)
        check(not p.stderr, "no stderr", p.stderr[:200])
        check(token.encode() not in p.stdout, "token never disclosed")
        return json.loads(p.stdout)

    try:
        # meeting-speakers passes the field through, verbatim, nulls included.
        r = run("meeting-speakers", "--session", SID)
        check(r["ok"] and r["details"]["review"].get("voiceDisplay") == DISPLAY, "voiceDisplay arrives verbatim", json.dumps(r)[:400])
        check(r["details"]["review"]["voiceDisplay"]["groups"][1]["seconds"] is None, "voiceDisplay arrives verbatim")
        check(r["details"]["review"]["futureField"] == {"kept": True}, "voiceDisplay arrives verbatim")

        # A read is a GET. It starts nothing.
        requests.clear()
        r = run("meeting-voice-suggestions", "--session", SID)
        check(r["ok"] and r["details"]["job"] == JOB, "job arrives verbatim", json.dumps(r)[:400])
        check(requests == [("GET", f"/api/meeting/{SID}/voice-suggestions", None)], "read is a GET", str(requests))

        # A start is a POST on the same path, with an empty body: no name, no label, no flag travels.
        requests.clear()
        r = run("meeting-voice-suggestions", "--session", SID, "--start")
        check(r["ok"] and r["details"]["job"] == JOB, "job arrives verbatim")
        check(requests == [("POST", f"/api/meeting/{SID}/voice-suggestions", b"{}")], "start is a POST", str(requests))

        # A refusal is an answer, at any status.
        for status in (200, 202, 409, 423, 503):
            state.update(status=status, body={"state": "refused", "reason": "recording_active"}, raw=None)
            r = run("meeting-voice-suggestions", "--session", SID, "--start")
            check(r["ok"] and r["details"]["job"]["reason"] == "recording_active", "refusal is an answer", f"{status}: {json.dumps(r)}")

        # 404 is an older server: a structured answer the panel hides on, HTML or JSON alike.
        for raw in (b"<!DOCTYPE html><html><body>Cannot GET</body></html>", None):
            state.update(status=404, body={"error": "Not found"}, raw=raw)
            for args in ([], ["--start"]):
                r = run("meeting-voice-suggestions", "--session", SID, *args)
                check(r["ok"] and r["details"].get("unavailable") == "route_absent" and "job" not in r["details"], "404 is route absent", json.dumps(r))

        # A body with no state, or none at all, is not a job.
        for status, body, raw in ((500, {"error": "boom"}, None), (200, {"nope": 1}, None), (502, {}, b"<html>bad gateway</html>")):
            state.update(status=status, body=body, raw=raw)
            r = run("meeting-voice-suggestions", "--session", SID)
            check(r["ok"] and r["details"].get("unavailable") == "error" and "job" not in r["details"], "failure is not a job", json.dumps(r))

        # Unauthorized fails and says nothing of the server's text.
        state.update(status=401, body={"error": "SECRET fixture failure"}, raw=None)
        r = run("meeting-voice-suggestions", "--session", SID)
        check(not r["ok"] and "SECRET" not in json.dumps(r), "unauthorized is refused")

        # Only a saved Mac session is ever asked about.
        state.update(status=200, body=JOB, raw=None)
        for bad in ("meeting_g2_fixture", "phone_fixture", "../../etc", ""):
            before = len(requests)
            r = run("meeting-voice-suggestions", "--session", bad)
            check(not r["ok"] and len(requests) == before, "mac sessions only", bad)
        before = len(requests)
        r = run("meeting-voice-suggestions")
        check(not r["ok"] and len(requests) == before, "mac sessions only")
        # The batch. The list is a GET and starts nothing.
        state.update(status=200, body=BATCH_LIST, raw=None)
        requests.clear()
        r = run("meeting-voice-batch", "--session", SID)
        check(r["ok"] and r["details"]["batches"] == BATCH_LIST["batches"], "batch list verbatim", json.dumps(r)[:300])
        check(requests == [("GET", f"/api/meeting/{SID}/voice-naming-batch", None)], "batch list is a GET", str(requests))
        for raw in (b"<html>Cannot GET</html>", None):
            state.update(status=404, body={"error": "x"}, raw=raw)
            r = run("meeting-voice-batch", "--session", SID)
            check(r["ok"] and r["details"].get("unavailable") == "route_absent", "batch 404 is route absent", json.dumps(r))
        state.update(status=500, body={"error": "boom"}, raw=None)
        r = run("meeting-voice-batch", "--session", SID)
        check(r["ok"] and r["details"].get("unavailable") == "error" and "batches" not in r["details"], "batch failure is not a list", json.dumps(r))

        def apply(body):
            p = subprocess.run([sys.argv[1], "meeting-voice-batch-apply"], input=json.dumps(body).encode(), capture_output=True, env=env, timeout=20)
            check(not p.stderr, "no stderr", p.stderr[:200])
            return json.loads(p.stdout)

        good = {"sessionId": SID, "sourceRevision": "a" * 64, "confirm": True, "items": [{"labels": ["Voice 5", "Voice 12"], "name": "Dana Reyes"}, {"labels": ["Voice 7"], "name": "Avery Stone"}]}
        answer = {"batchId": "b1", "state": "partial", "reason": "x", "named": [{"labels": ["Voice 5", "Voice 12"], "name": "Dana Reyes", "samplesAdded": 3}],
                  "notNamed": [{"labels": ["Voice 7"], "name": "Avery Stone", "reason": "y"}], "sourceRevision": "b" * 64, "undoAvailable": True}
        state.update(status=200, body=answer, raw=None)
        requests.clear()
        r = apply(good)
        check(r["ok"] and r["details"]["result"] == answer, "apply answer verbatim", json.dumps(r)[:300])
        method, path, sent = requests[-1]
        check(method == "POST" and path == f"/api/meeting/{SID}/voice-naming-batch", "apply is a POST", str(requests))
        check(json.loads(sent) == {"sourceRevision": "a" * 64, "confirm": True, "items": good["items"]}, "apply body exact", sent[:300])
        # A refusal is an answer at any status; a 404 with no state is an older server.
        for status in (200, 409, 422):
            state.update(status=status, body={"state": "refused", "reason": "recording_active"}, raw=None)
            r = apply(good)
            check(r["ok"] and r["details"]["result"]["state"] == "refused", "batch refusal is an answer", f"{status} {json.dumps(r)}")
        state.update(status=404, body={"error": "x"}, raw=None)
        r = apply(good)
        check(r["ok"] and r["details"].get("unavailable") == "route_absent" and "result" not in r["details"], "apply 404 is route absent", json.dumps(r))
        state.update(status=500, body={"error": "boom"}, raw=None)
        r = apply(good)
        check(r["ok"] and r["details"].get("unavailable") == "error" and "result" not in r["details"], "apply failure is not an answer", json.dumps(r))
        # Bad bodies never reach the server.
        def variant(**changes):
            bad = json.loads(json.dumps(good)); bad.update(changes); return bad
        bads = [variant(confirm=False), variant(confirm=1), variant(sourceRevision="short"), variant(sourceRevision="A" * 64), variant(items=[]), variant(sessionId="meeting_g2_fixture"),
                variant(extra=1), variant(items=[{"labels": ["Ext"], "name": "Dana Reyes"}]), variant(items=[{"labels": [], "name": "Dana Reyes"}]),
                variant(items=[{"labels": ["Voice 1"], "name": "Ext"}]), variant(items=[{"labels": ["Voice 1"], "name": "Voice 2"}]), variant(items=[{"labels": ["Voice 1"], "name": " Dana"}]),
                variant(items=[{"labels": ["Voice 1"], "name": "bad\nname"}]), variant(items=[{"labels": ["Voice 1"], "name": "Dana Reyes", "force": True}]),
                variant(items=[{"labels": ["Voice 1"], "name": "A"}, {"labels": ["Voice 1"], "name": "Blake Moss"}]), variant(items=[{"labels": ["Voice 1", "Voice 1"], "name": "Dana Reyes"}])]
        before = len(requests)
        for bad in bads:
            r = apply(bad)
            check(not r["ok"] and len(requests) == before, "bad batch never sent", json.dumps(bad)[:200])
        # Undo posts confirm to the batch's own path.
        undo = {"state": "partial", "reverted": [{"labels": ["Voice 5"], "name": "Dana Reyes"}], "left": [{"labels": ["Voice 7"], "name": "Avery Stone", "reason": "z"}], "samplesRemoved": 3, "sourceRevision": "c" * 64}
        state.update(status=200, body=undo, raw=None)
        requests.clear()
        r = run("meeting-voice-batch-undo", "--session", SID, "--batch", "b1")
        check(r["ok"] and r["details"]["result"] == undo, "undo answer verbatim", json.dumps(r)[:300])
        check(requests == [("POST", f"/api/meeting/{SID}/voice-naming-batch/b1/undo", b'{"confirm":true}')], "undo is a confirmed POST", str(requests))
        before = len(requests)
        for bad in ("../../x", "", "b b", "x" * 129):
            r = run("meeting-voice-batch-undo", "--session", SID, "--batch", bad)
            check(not r["ok"] and len(requests) == before, "bad batch id never sent", bad)
        r = run("meeting-voice-batch-undo", "--session", "meeting_g2_fixture", "--batch", "b1")
        check(not r["ok"] and len(requests) == before, "mac sessions only")
        state.update(status=401, body={"error": "SECRET fixture failure"}, raw=None)
        r = run("meeting-voice-batch", "--session", SID)
        check(not r["ok"] and "SECRET" not in json.dumps(r), "unauthorized is refused")
        print(f"PASS voice display compiled helper: {checks} checks; voiceDisplay passes through verbatim; suggestions and batch GET, POST, refusal, 404 and failure shapes")
    finally:
        server.shutdown()
        server.server_close()
