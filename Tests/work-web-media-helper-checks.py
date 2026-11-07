#!/usr/bin/env python3
"""Round-scoped helper contract against isolated loopback fixtures. Caller supplies the guarded compiled helper."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    helper = Path(sys.argv[1]).resolve(strict=True)
    server_id = "11111111-2222-4333-8444-555555555555"
    round_id, work_id, media_id = "lr_" + "a" * 16, "task:quilt:" + "b" * 12, "m_" + "c" * 24
    route = f"/api/work/chat/lens-rounds/{round_id}/attachments/{media_id}?workID={work_id}"
    token = "e" * 64
    state = {"cap": True, "protocol": 1, "server": server_id, "status": 200, "headers": {}, "mime": "text/plain",
             "bytes": b"Private fixture evidence", "redirect": False, "oversize": False}
    calls, redirected, paths = [], [], []
    with tempfile.TemporaryDirectory(prefix="cos-work-media-helper-", dir="/tmp") as tmp:
        root = Path(tmp)
        token_file = root / "candidate-token"
        token_file.write_text(token); token_file.chmod(0o600)

        class Sink(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_GET(self):
                redirected.append(self.headers.get("X-COS-Token"))
                self.send_response(200); self.end_headers()

        sink = ThreadingHTTPServer(("127.0.0.1", 0), Sink)

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_GET(self):
                calls.append(self.path)
                assert self.headers.get("X-COS-Token") == token
                if self.path == "/api/work/chat/web-plans":
                    body = {"protocolVersion": 1, "webPlans": 1, "serverInstanceId": state["server"]}
                    if state["cap"]: body["workAttachments"] = {"protocol": state["protocol"]}
                    data = json.dumps(body).encode()
                    self.send_response(200); self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
                    return
                assert self.path == route, "no generic media fallback or arbitrary route"
                if state["redirect"]:
                    self.send_response(302); self.send_header("Location", f"http://127.0.0.1:{sink.server_port}/leak")
                    self.send_header("Content-Length", "0"); self.end_headers(); return
                self.send_response(state["status"])
                headers = {"X-COS-Work-Attachment": "1", "X-COS-Server-Instance": server_id,
                           "X-COS-Work-ID": work_id, "X-COS-Round-ID": round_id, "X-COS-Media-ID": media_id,
                           "Content-Type": state["mime"], "Content-Length": str(len(state["bytes"]))}
                headers.update(state["headers"])
                if state["oversize"]: headers["Content-Length"] = str(100 * 1024 * 1024 + 1)
                for key, value in headers.items():
                    if value is not None: self.send_header(key, value)
                self.end_headers()
                try: self.wfile.write(state["bytes"])
                except (BrokenPipeError, ConnectionResetError): pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        for listener in (server, sink): threading.Thread(target=listener.serve_forever, daemon=True).start()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("COS_", "ANTHROPIC_", "OPENAI_"))}
        env.update(COS_WORK_CONNECTED_TEST="1", COS_WORK_REVIEW_CANDIDATE_PORT=str(server.server_port),
                   COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE=str(token_file), HOME=tmp, TMPDIR=tmp + "/")
        args = [str(helper), "work-lens-media", "--round-id", round_id, "--work-id", work_id,
                "--media-id", media_id, "--server-id", server_id]
        count = 0

        def run(expected, argv=None):
            nonlocal count
            result = subprocess.run(argv or args, env=env, capture_output=True, timeout=35)
            assert token.encode() not in result.stdout + result.stderr
            assert state["bytes"] not in result.stderr
            reply = json.loads(result.stdout)
            assert reply.get("ok") is expected, reply
            count += 1
            if expected:
                detail = reply["details"]
                assert all(detail[k] == v for k, v in {"state": "ready", "serverInstanceId": server_id,
                           "roundId": round_id, "workID": work_id, "mediaId": media_id}.items())
                path = Path(detail["path"])
                assert path.parent.name.startswith("cos-work-media-download-") and not path.is_symlink()
                assert path.read_bytes() == state["bytes"] and stat.S_IMODE(path.stat().st_mode) == 0o600
                assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
                paths.append(path)
            return reply

        try:
            run(True)
            assert calls == ["/api/work/chat/web-plans", route]
            state["cap"] = False; before = len(calls); run(False)
            assert calls[before:] == ["/api/work/chat/web-plans"]
            state["cap"] = True; state["server"] = "another-server"; run(False); state["server"] = server_id
            state["protocol"] = True; run(False); state["protocol"] = 1
            for key in ("X-COS-Work-Attachment", "X-COS-Server-Instance", "X-COS-Work-ID", "X-COS-Round-ID", "X-COS-Media-ID"):
                state["headers"] = {key: "wrong"}; run(False)
            state["headers"] = {}
            for status in (404, 409, 410, 503): state["status"] = status; run(False)
            state["status"] = 200
            state["mime"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"; run(False)
            state["mime"] = "image/jpeg"; run(False); state["mime"] = "text/plain"
            state["oversize"] = True; run(False); state["oversize"] = False
            state["redirect"] = True; run(False); state["redirect"] = False
            assert not redirected, "redirect must not receive request or token"
            bad_args = args.copy(); bad_args[3] = round_id + "\n"
            before = len(calls); run(False, bad_args); assert len(calls) == before
            run(True)
            print(f"PASS Work web media helper: {count} isolated cases; proof, capability, identity, MIME, bounds, redirects, private transfers")
        finally:
            server.shutdown(); sink.shutdown(); server.server_close(); sink.server_close()
            for path in paths:
                if path.parent.name.startswith("cos-work-media-download-"): shutil.rmtree(path.parent)


if __name__ == "__main__": main()
