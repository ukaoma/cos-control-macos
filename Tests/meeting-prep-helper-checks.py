#!/usr/bin/env python3
"""Compiled Prep transport against private loopback fixtures; no live COS or providers.

Usage: python3 Tests/meeting-prep-helper-checks.py /absolute/path/to/cos-control-helper
The caller builds the helper under the shared compile lane. This fixture never compiles it.
"""
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER_ID = "9e277c0f-101a-4035-af03-631f8601de49"
DRAFT_ID = "prep_" + "a" * 26
FILE_ID = "pf_" + "b" * 16
MEDIA_ID = "m_" + "c" * 24
REQUEST_ID = "3e977750-1cdc-450d-85dc-e34e874ef520"
SESSION_ID = "meeting_prep_fixture"
WORDS = "Private résumé context — fixture only"
ORIGINAL = b"%PDF-1.4\nPrivate fixture original\n"
DIGEST = hashlib.sha256(ORIGINAL).hexdigest()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: meeting-prep-helper-checks.py /absolute/path/to/helper")
    helper = Path(sys.argv[1]).resolve(strict=True)
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise SystemExit("an executable, externally built helper is required")
    failures, checks, calls, redirect_calls = [], [0], [], []
    state = {"protocol": 1, "server": SERVER_ID, "capability": True,
             "health_status": 200, "status": 200, "body": {"draft": {"id": DRAFT_ID, "revision": 4}},
             "raw": ORIGINAL, "announced": None, "redirect": None, "disconnect": False,
             "response_identity": SERVER_ID}
    with tempfile.TemporaryDirectory(prefix="cos-prep-helper-", dir="/tmp") as tmp:
        root = Path(tmp)
        token = "d" * 64
        token_file = root / "candidate-token"
        token_file.write_text(token)
        token_file.chmod(0o600)
        downloads = []
        # Foundation uses the per-user Darwin temp directory even with a supplied TMPDIR.
        # Accept only this OS-owned location or our fixture root, never arbitrary returned paths.
        darwin_temp = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"],
                                    capture_output=True, text=True, check=True, timeout=5).stdout.strip()
        allowed_download_roots = {root.resolve(), Path(darwin_temp).resolve()}

        def private_download_directory(directory):
            if re.fullmatch(r"cos-prep-download-[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", directory.name) is None or directory.is_symlink():
                return False
            if directory.resolve().parent not in allowed_download_roots:
                return False
            info = directory.stat()
            return info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700

        def candidate_downloads():
            return {path for parent in allowed_download_roots
                    for path in parent.glob("cos-prep-download-*/*.bin")}

        def check(condition, name):
            checks[0] += 1
            if not condition:
                failures.append(name)

        class Sink(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def answer(self):
                redirect_calls.append((self.command, self.path, self.headers.get("X-COS-Token")))
                self.send_response(200)
                self.send_header("Content-Length", str(len(ORIGINAL)))
                self.end_headers()
                self.wfile.write(ORIGINAL)
            do_GET = do_POST = do_PATCH = do_DELETE = answer

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def answer(self):
                length = int(self.headers.get("Content-Length", "0"))
                if length > 2_000_000:
                    self.send_error(413)
                    return
                raw = self.rfile.read(length)
                calls.append({"method": self.command, "path": self.path, "raw": raw,
                              "token": self.headers.get("X-COS-Token"),
                              "host": self.headers.get("Host"),
                              "type": self.headers.get("Content-Type"),
                              "filename": self.headers.get("X-COS-Filename"),
                              "expected_instance": self.headers.get("X-COS-Expected-Server-Instance")})
                category = "health" if self.path == "/api/health" else "download" if self.path == f"/api/prep/drafts/{DRAFT_ID}/files/{FILE_ID}" and self.command == "GET" else "route"
                if state["redirect"] == category:
                    self.send_response(307)
                    self.send_header("Location", f"http://127.0.0.1:{sink.server_port}/redirect-target")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if state["disconnect"] and category != "health":
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                if category == "health":
                    status = state["health_status"]
                    body = {"serverInstanceId": state["server"], "capabilities": {}}
                    if state["capability"]:
                        body["capabilities"]["prep"] = {"protocol": state["protocol"], "bind": True, "serverInstanceId": state["server"]}
                    data = json.dumps(body).encode()
                elif category == "download":
                    status, data = state["status"], state["raw"]
                else:
                    status = state["status"]
                    body = state["body"]
                    if isinstance(body, dict) and self.path.startswith("/api/prep/"):
                        body = dict(body)
                        if state["response_identity"] is not None:
                            body.setdefault("serverInstanceId", state["response_identity"])
                    data = body if isinstance(body, bytes) else json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/octet-stream" if category == "download" else "application/json")
                if category == "download" and state["response_identity"] is not None:
                    self.send_header("X-COS-Server-Instance", str(state["response_identity"]))
                self.send_header("Content-Length", str(state["announced"] if category == "download" and state["announced"] is not None else len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            do_GET = do_POST = do_PATCH = do_DELETE = answer

        sink = ThreadingHTTPServer(("127.0.0.1", 0), Sink)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (server, sink)]
        for thread in threads:
            thread.start()
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("COS_", "OPENAI_", "ANTHROPIC_"))}
        env.update(COS_WORK_CONNECTED_TEST="1", COS_WORK_REVIEW_CANDIDATE_PORT=str(server.server_port),
                   COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE=str(token_file), TMPDIR=tmp + "/", HOME=tmp)

        def envelope(**changes):
            return dict(serverInstanceId=SERVER_ID, **changes)

        def run(op, data=None, overrides=None):
            payload = data if isinstance(data, bytes) else json.dumps(data).encode() if data is not None else None
            argv = [str(helper), "meeting-prep", "--op", op]
            check(WORDS not in " ".join(argv), "private request stays off argv")
            result = subprocess.run(argv, input=payload, capture_output=True,
                                    env=dict(env, **(overrides or {})), timeout=25)
            text = result.stdout.decode("utf-8", "replace")
            error = result.stderr.decode("utf-8", "replace")
            check(token not in text + error, f"{op}: token never reaches output")
            check(WORDS not in error, f"{op}: private words never reach stderr")
            try:
                reply = json.loads(text)
            except ValueError:
                raise AssertionError(f"{op}: helper did not emit its JSON envelope (exit {result.returncode})") from None
            check(isinstance(reply, dict), f"{op}: JSON object envelope")
            return reply

        def expect_route(op, data, method, path, expected_body=None):
            before = len(calls)
            reply = run(op, data)
            sent = calls[before:]
            if reply.get("ok") is not True:
                print("DIAG", op, json.dumps(reply), "routes=", [(c["method"], c["path"]) for c in sent])
            check(reply.get("ok") is True, f"{op}: answered transport")
            check(len(sent) == 2 and sent[0]["path"] == "/api/health", f"{op}: discovers once before exact route")
            check(bool(sent) and (sent[-1]["method"], sent[-1]["path"]) == (method, path), f"{op}: fixed route grammar")
            if expected_body is not None:
                check(json.loads(sent[-1]["raw"]) == expected_body, f"{op}: exact JSON payload")
            if path.startswith("/api/prep/") and op != "download":
                check(reply.get("details", {}).get("serverInstanceId") == SERVER_ID, f"{op}: authoritative response server identity")
            if path.startswith("/api/prep/") and method in ("POST", "PATCH", "DELETE"):
                check(bool(sent) and sent[-1]["expected_instance"] == SERVER_ID, f"{op}: mutation pinned to expected server at write time")
            return reply

        def refused(op, data, label):
            before = len(calls)
            reply = run(op, data)
            check(reply.get("ok") is False, label)
            check(all(c["path"] == "/api/health" for c in calls[before:]), label + ": no dependent route")

        try:
            before = len(calls)
            check(run("delete-all").get("ok") is False and len(calls) == before, "unknown operation refuses before network")
            reply = run("capabilities")
            check(reply.get("details", {}).get("available") is True, "protocol1 available")
            for protocol in (True, "1", 2, None):
                state["protocol"] = protocol
                check(run("capabilities").get("details", {}).get("available") is False, "incompatible protocol unavailable")
                refused("list", envelope(), "incompatible protocol refuses draft route")
            state["protocol"] = 1
            state["capability"] = False
            check(run("capabilities").get("details", {}).get("available") is False, "older server capability absent")
            refused("create", envelope(payload={"clientDraftId": REQUEST_ID}), "older server never falls through to generic Ask")
            state["capability"] = True
            for identity in ("", None):
                state["server"] = identity
                check(run("capabilities").get("ok") is False, "missing server identity refuses discovery")
            state["server"] = SERVER_ID
            state["health_status"] = 503
            refused("list", envelope(), "unavailable health refuses dependent route")
            state["health_status"] = 200
            refused("list", {"serverInstanceId": "another-server"}, "stale server identity rejected")
            state["body"] = {"serverInstanceId": "replaced-after-discovery", "draft": {"id": DRAFT_ID}}
            check(run("get", envelope(draftId=DRAFT_ID)).get("ok") is False, "explicit route identity change is not overwritten by discovery identity")
            state["body"] = {"draft": {"id": DRAFT_ID, "revision": 4}}
            for identity in (None, "", 42):
                state["response_identity"] = identity
                for status in (200, 409, 503):
                    state["status"] = status
                    reply = run("get", envelope(draftId=DRAFT_ID))
                    check(reply.get("ok") is False, "missing/malformed response identity refuses success and error without synthesizing proof")
                    check(reply.get("details", {}).get("serverInstanceId") != SERVER_ID, "preflight identity is not returned as response proof")
            state.update(response_identity=SERVER_ID, status=200)

            expect_route("list", envelope(), "GET", "/api/prep/drafts?state=active&limit=20")
            create = {"clientDraftId": REQUEST_ID, "title": WORDS, "startsAt": None, "occurrence": None}
            expect_route("create", envelope(payload=create), "POST", "/api/prep/drafts", create)
            expect_route("get", envelope(draftId=DRAFT_ID), "GET", f"/api/prep/drafts/{DRAFT_ID}")
            update = {"revision": 3, "steer": WORDS}
            expect_route("update", envelope(draftId=DRAFT_ID, payload=update), "PATCH", f"/api/prep/drafts/{DRAFT_ID}", update)
            run_body = {"clientRequestId": REQUEST_ID, "revision": 4, "model": "sonnet", "effort": "high", "continue": True}
            expect_route("run", envelope(draftId=DRAFT_ID, payload=run_body), "POST", f"/api/prep/drafts/{DRAFT_ID}/run", run_body)
            state["body"] = {"run": {"clientRequestId": REQUEST_ID, "jobId": "job_fixture", "state": "accepted"}, "job": {"id": "job_fixture", "status": "running"}}
            reply = expect_route("run-status", envelope(draftId=DRAFT_ID, clientRequestId=REQUEST_ID), "GET", f"/api/prep/drafts/{DRAFT_ID}/runs/{REQUEST_ID}")
            check(reply.get("details", {}).get("run") == state["body"]["run"], "run can be recovered from persisted client request before job ID is known")
            state.update(status=404, body={"error": "run_not_accepted"})
            reply = expect_route("run-status", envelope(draftId=DRAFT_ID, clientRequestId=REQUEST_ID), "GET", f"/api/prep/drafts/{DRAFT_ID}/runs/{REQUEST_ID}")
            check(reply.get("details", {}).get("httpStatus") == 404 and reply.get("details", {}).get("error") == "run_not_accepted", "authoritative absent-run recovery is distinct from transport uncertainty")
            state.update(status=200, body={"job": {"id": "job_fixture", "status": "running"}})
            before = len(calls)
            check(run("job", envelope(jobId="job_fixture")).get("ok") is False and len(calls) == before, "generic query-job operation is unavailable; Prep recovery uses bound run-status")
            snapshot = {"draftId": DRAFT_ID, "draftRevision": 2, "sessionId": SESSION_ID,
                        "surface": "control", "state": "applied", "boundAt": "2026-11-06T17:00:00.000Z",
                        "title": "Frozen meeting preparation", "startsAt": None, "steer": WORDS,
                        "files": [{"id": FILE_ID, "name": "Fixture.pdf", "revision": "adopted-revision-2", "sha256": DIGEST}]}
            state["body"] = {"snapshots": [snapshot]}
            reply = expect_route("session", envelope(sessionId=SESSION_ID), "GET", "/api/prep/by-session/" + SESSION_ID)
            check(reply.get("details", {}).get("snapshots") == [snapshot], "by-session preserves frozen adopted context/files/revision rather than substituting current draft")
            state["body"] = {"draft": {"id": DRAFT_ID, "revision": 4}}
            expect_route("suggest", envelope(sessionId=SESSION_ID, startedAt=1793980000000), "GET", f"/api/prep/suggest?sessionId={SESSION_ID}&startedAt=1793980000000")
            bind = {"sessionId": SESSION_ID, "serverInstanceId": SERVER_ID, "surface": "control", "revision": 4}
            expect_route("bind", envelope(draftId=DRAFT_ID, payload=bind), "POST", f"/api/prep/drafts/{DRAFT_ID}/bind", bind)
            expect_route("unbind", envelope(draftId=DRAFT_ID, sessionId=SESSION_ID), "DELETE", f"/api/prep/drafts/{DRAFT_ID}/bind/{SESSION_ID}")
            expect_route("remove-file", envelope(draftId=DRAFT_ID, fileId=FILE_ID, payload={"revision": 4}), "DELETE", f"/api/prep/drafts/{DRAFT_ID}/files/{FILE_ID}?revision=4")

            for bad in (b"not json", b"[]", b" " * 128001, envelope(extra="route injection")):
                refused("list", bad, "bounded valid stdin required")
            for op, key in (("get", "draftId"), ("session", "sessionId"), ("job", "jobId")):
                for value in ("../health", "https://example.invalid/x", "abc?send=1", "abc%2fdef", "abc\n"):
                    refused(op, envelope(**{key: value}), "path traversal/URL/query injection rejected")
            for identity in ("../run", "bad", REQUEST_ID.upper(), "00000000-0000-0000-0000-000000000000"):
                refused("run-status", envelope(draftId=DRAFT_ID, clientRequestId=identity), "run recovery requires exact lowercase UUIDv4 identity")
            refused("get", envelope(draftId=DRAFT_ID, payload=[]), "non-object payload rejected")
            refused("update", envelope(draftId=DRAFT_ID, payload={"revision": True, "steer": WORDS}), "boolean revision rejected")
            refused("update", envelope(draftId=DRAFT_ID, payload={"revision": -1}), "negative revision rejected")
            refused("update", envelope(draftId=DRAFT_ID, payload={"revision": 1, "steer": "x" * 4001}), "oversized notes rejected")
            refused("run", envelope(draftId=DRAFT_ID, payload=dict(run_body, send=True)), "run cannot smuggle dispatch flags")
            refused("run", envelope(draftId=DRAFT_ID, payload=dict(run_body, clientRequestId="bad")), "stable request identity required")
            for patch in ({"model": 42}, {"effort": []}, {"continue": "true"}):
                refused("run", envelope(draftId=DRAFT_ID, payload=dict(run_body, **patch)), "invalid run option type rejected")
            refused("bind", envelope(draftId=DRAFT_ID, payload=dict(bind, serverInstanceId="wrong")), "inner bind identity checked")
            refused("bind", envelope(draftId=DRAFT_ID, payload=dict(bind, surface="g2")), "native bind origin cannot be forged")
            refused("bind", envelope(draftId=DRAFT_ID, payload={k: v for k, v in bind.items() if k != "revision"}), "bind requires reviewed revision")
            refused("suggest", envelope(sessionId=SESSION_ID, startedAt=0), "invalid capture start rejected")

            # Original upload and durable attach are separate steps; no path enters the attach payload.
            document = root / "fixture résumé.pdf"
            document.write_bytes(ORIGINAL)
            state["body"] = {"attachment": {"id": MEDIA_ID, "path": "/private/server-only"}}
            reply = expect_route("upload", envelope(payload={"path": str(document), "name": document.name, "kind": "doc", "mime": "application/pdf"}), "POST", "/api/media/file")
            check(calls[-1]["raw"] == ORIGINAL and calls[-1]["type"] == "application/pdf", "upload sends exact original bytes/type")
            check(str(root).encode() not in calls[-1]["raw"], "local source path not uploaded")
            check(reply.get("details", {}).get("mediaId") == MEDIA_ID and "/private/server-only" not in json.dumps(reply), "upload exposes usable media ID only")
            state["body"] = {"serverInstanceId": "replaced-after-discovery", "attachment": {"id": MEDIA_ID}}
            check(run("upload", envelope(payload={"path": str(document), "name": document.name, "kind": "doc", "mime": "application/pdf"})).get("ok") is False, "upload refuses explicit changed server identity")
            photo = root / "fixture.jpg"
            photo.write_bytes(b"\xff\xd8\xff" + b"p" * 100)
            state["body"] = {"attachments": [{"id": MEDIA_ID}]}
            expect_route("upload", envelope(payload={"path": str(photo), "name": photo.name, "kind": "photo", "mime": "image/jpeg"}), "POST", "/api/media")
            uploaded = json.loads(calls[-1]["raw"])
            check(uploaded.get("kind") == "user_photo" and base64.b64decode(uploaded["images"][0]["data"]) == photo.read_bytes(), "photo preserves bytes in existing upload grammar")
            state["body"] = {"draft": {"id": DRAFT_ID, "files": [{"id": FILE_ID, "sha256": DIGEST, "sourceRef": "local-opaque-1"}]}}
            files = {"revision": 4, "operationId": REQUEST_ID, "media": [{"id": MEDIA_ID, "name": "Fixture.pdf", "sourceRef": "local-opaque-1", "sha256": DIGEST}]}
            reply = expect_route("files", envelope(draftId=DRAFT_ID, payload=files), "POST", f"/api/prep/drafts/{DRAFT_ID}/files", files)
            check(reply.get("details", {}).get("draft", {}).get("files", [{}])[0].get("id") == FILE_ID, "durable Prep file identity returned separately from staged upload")
            media_ref = {"id": MEDIA_ID, "sha256": DIGEST}
            for media in ([], [media_ref] * 11, [media_ref] * 2, [dict(media_ref, id="../bad")],
                          [dict(media_ref, name=42)], [dict(media_ref, sourceRef=[])], [dict(media_ref, path="/etc/passwd")],
                          [{"id": MEDIA_ID}], [dict(media_ref, sha256="bad")], [dict(media_ref, sha256=42)]):
                refused("files", envelope(draftId=DRAFT_ID, payload={"revision": 4, "operationId": REQUEST_ID, "media": media}), "invalid media batch/hash rejected before mutation")
            refused("files", envelope(draftId=DRAFT_ID, payload={"revision": 4, "media": [media_ref]}), "durable file adoption requires stable operationId")
            refused("upload", envelope(payload={"path": str(root / "missing"), "name": "x", "kind": "doc", "mime": "text/plain"}), "missing upload rejected")
            refused("upload", envelope(payload={"path": str(document), "name": "x", "kind": "doc", "mime": "text/plain", "route": "/api/query"}), "upload cannot choose route")

            metadata = envelope(draftId=DRAFT_ID, fileId=FILE_ID, sha256=DIGEST, bytes=len(ORIGINAL))
            state["status"] = 200
            reply = expect_route("download", metadata, "GET", f"/api/prep/drafts/{DRAFT_ID}/files/{FILE_ID}")
            destination = Path(reply.get("details", {}).get("path", "/nonexistent"))
            if destination.is_file():
                downloads.append(destination.parent)
                check(private_download_directory(destination.parent), "candidate download stays in a unique owned private OS/fixture temp directory")
                check(destination.read_bytes() == ORIGINAL, "download verifies saved original bytes")
                check(stat.S_IMODE(destination.stat().st_mode) == 0o600 and stat.S_IMODE(destination.parent.stat().st_mode) == 0o700, "download private file/directory modes")
                check(destination.suffix == ".bin", "server filename cannot control output path")
            else:
                check(False, "verified download materialized")
            check(reply.get("details", {}).get("serverInstanceId") == SERVER_ID, "download identity comes from authoritative binary response header")
            for identity in (None, "", "replaced-after-discovery"):
                state["response_identity"] = identity
                before_files = candidate_downloads()
                reply = run("download", metadata)
                check(reply.get("ok") is False and "path" not in reply.get("details", {}), "missing/mismatched binary identity opens nothing despite matching hash/size")
                check(candidate_downloads() == before_files, "unbound original is not materialized")
            state["response_identity"] = SERVER_ID
            for patch in ({"sha256": "0" * 64}, {"bytes": len(ORIGINAL) + 1}):
                reply = run("download", dict(metadata, **patch))
                check(reply.get("ok") is False and "path" not in reply.get("details", {}), "hash/size mismatch opens nothing")
            state["announced"] = 100 * 1024 * 1024 + 1
            check(run("download", metadata).get("ok") is False, "oversized declared response refused without allocating it")
            state["announced"] = None
            for category, op, payload in (("health", "capabilities", None), ("route", "list", envelope()), ("download", "download", metadata)):
                state["redirect"] = category
                before = len(redirect_calls)
                reply = run(op, payload)
                check(len(redirect_calls) == before, f"{category}: authenticated request never follows redirect to another origin")
                if op == "download":
                    check(reply.get("ok") is False, "redirected original never opens")
                    path = reply.get("details", {}).get("path")
                    if path:
                        downloads.append(Path(path).parent)
            state["redirect"] = None

            for status, code in ((400, "invalid_request"), (409, "revision_conflict"), (413, "prep_file_limit"), (503, "maintenance")):
                state.update(status=status, body={"error": code})
                reply = run("get", envelope(draftId=DRAFT_ID))
                check(reply.get("ok") is True and reply.get("details", {}).get("httpStatus") == status and reply.get("details", {}).get("error") == code, "answered rejection preserves HTTP status/code for native handling")
            state.update(status=409, body={"error": "server_instance_mismatch"})
            reply = expect_route("update", envelope(draftId=DRAFT_ID, payload=update), "PATCH", f"/api/prep/drafts/{DRAFT_ID}", update)
            check(reply.get("details", {}).get("httpStatus") == 409 and reply.get("details", {}).get("error") == "server_instance_mismatch", "write-time identity rejection remains an authoritative answered error")
            state.update(status=404, body=b"<html>older route</html>")
            reply = run("get", envelope(draftId=DRAFT_ID))
            check(reply.get("ok") is False and reply.get("details", {}).get("serverInstanceId") != SERVER_ID, "non-JSON error lacks authoritative identity and cannot become response proof")
            state.update(status=200, body={}, disconnect=True)
            reply = run("run", envelope(draftId=DRAFT_ID, payload=run_body))
            check(reply.get("ok") is False and "Check its status" in reply.get("message", ""), "lost POST outcome remains uncertain, never claims no job ran")
            state["disconnect"] = False

            for overrides in ({"COS_CONTROL_TEST_HOME": tmp}, {"COS_WORK_REVIEW_CANDIDATE_PORT": "3141"}, {"COS_WORK_REVIEW_CANDIDATE_PORT": "3143"}):
                before = len(calls)
                check(run("capabilities", overrides=overrides).get("ok") is False and len(calls) == before, "preview/live production ports refused before network")
            token_file.chmod(0o644)
            before = len(calls)
            check(run("capabilities").get("ok") is False and len(calls) == before, "public candidate token file refused")
            token_file.chmod(0o600)
            link = root / "token-link"
            link.symlink_to(token_file)
            check(run("capabilities", overrides={"COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE": str(link)}).get("ok") is False and len(calls) == before, "symlink candidate token refused")
            check(all(c["token"] == token and c["host"] == f"127.0.0.1:{server.server_port}" for c in calls), "all requests authenticate only to explicit private fixture origin")
            check(all(c["path"] == "/api/health" or c["path"].startswith(("/api/prep/", "/api/media")) for c in calls), "no generic Ask, dispatch, settings or recording route used")
            check(all(c["expected_instance"] == SERVER_ID for c in calls if c["path"].startswith("/api/prep/") and c["method"] in ("POST", "PATCH", "DELETE")), "all Prep mutations carry expected-instance header, including retries and errors")
            check(not redirect_calls, "no token/request crossed redirected origin")
            if failures:
                for failure in failures:
                    print("FAIL Prep helper: " + failure)
                raise SystemExit(f"FAILED {len(failures)} of {checks[0]} Prep helper checks")
            print(f"PASS {checks[0]} Prep helper checks: fixed authenticated routes, identity/capability, bounded stdin, original upload/durable ref, verified private downloads, failures and redirect refusal")
        finally:
            for s in (server, sink):
                s.shutdown()
                s.server_close()
            for thread in threads:
                thread.join(timeout=5)
            for directory in downloads:
                # Remove only returned helper-created private temp directories from this run.
                if directory.exists() and private_download_directory(directory):
                    shutil.rmtree(directory, ignore_errors=True)


if __name__ == "__main__":
    main()
