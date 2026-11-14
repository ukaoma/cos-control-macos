#!/usr/bin/env python3
"""0.5.394 plan ruler (U1; Q1 13:47): the compiled helper's `usage-plan` verb against a private loopback fixture.
No live COS, no plan endpoint: the fixture listens on 127.0.0.1 at a port that is never 3141 or 3143, and the helper
reaches it only through the explicit connected test candidate (COS_WORK_CONNECTED_TEST + a 0600 64-hex token file).

Checked: the path and the Refresh query; the token is sent only as X-COS-Token and never printed; a good answer is
passed through whole; the 404 words; a plain machine code is echoed and a code with spaces or a path is not; an answer
without lines, or another protocol, is refused; the isolated preview refuses before any request.
Usage: python3 Tests/usage-plan-helper-checks.py /absolute/path/to/cos-control-helper (built by the caller)."""
import json, os, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PANE = {"protocolVersion": 1, "now": "2026-11-14T16:03:55.000Z", "readAt": "2026-11-14T16:03:55.000Z", "closest": "codex",
        "others": "Claude read failed. Cursor no plan reading.",
        "lines": [{"provider": "codex", "name": "Codex", "state": "fresh", "usedPct": 96, "gonePct": 92.6, "windowWords": "w",
                   "short": "s", "shortLong": "sl", "long": "l", "quiet": "q", "readAt": None, "estimate": None}]}


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: usage-plan-helper-checks.py /absolute/path/to/helper")
    helper = Path(sys.argv[1]).resolve(strict=True)
    passed = [0]

    def check(ok, label):
        if not ok:
            raise SystemExit(f"FAIL usage-plan helper: {label}")
        passed[0] += 1

    calls, state = [], {"status": 200, "body": PANE}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            calls.append({"path": self.path, "token": self.headers.get("X-COS-Token"), "auth": self.headers.get("Authorization")})
            data = json.dumps(state["body"]).encode()
            self.send_response(state["status"])
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    with tempfile.TemporaryDirectory(prefix="cos-plan-helper-", dir="/tmp") as tmp:
        token = "e" * 64
        token_file = Path(tmp) / "candidate-token"
        token_file.write_text(token)
        token_file.chmod(0o600)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        check(server.server_port not in (3141, 3143), "the fixture is never the live server's port")
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("COS_", "OPENAI_", "ANTHROPIC_"))}
        env.update(COS_WORK_CONNECTED_TEST="1", COS_WORK_REVIEW_CANDIDATE_PORT=str(server.server_port),
                   COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE=str(token_file), TMPDIR=tmp + "/", HOME=tmp)

        def run(*args, overrides=None):
            r = subprocess.run([str(helper), "usage-plan", *args], capture_output=True, env=dict(env, **(overrides or {})), timeout=30)
            out, err = r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
            check(token not in out + err, "the token never reaches output")
            return json.loads(out.strip().splitlines()[-1])

        def answer(status, body, *args):
            state.update(status=status, body=body)
            before = len(calls)
            reply = run(*args)
            check(len(calls) == before + 1, f"one request for HTTP {status}")
            return reply, calls[-1]

        reply, call = answer(200, PANE)
        check(reply == {"ok": True, "message": "Plan use", "details": PANE}, "a good answer is passed through whole")
        check(call["path"] == "/api/usage/plan" and call["token"] == token and call["auth"] is None, "opening asks plainly, token as X-COS-Token only")
        _, call = answer(200, PANE, "--refresh")
        check(call["path"] == "/api/usage/plan?refresh=1", "Refresh asks for a fresh read")
        reply, _ = answer(404, {"error": "not_found"})
        check(reply["ok"] is False and reply["message"] == "This server does not report plan use yet (HTTP 404). Update the COS server to read it.", "the 404 words")
        reply, _ = answer(503, {"error": "usage_plan_unavailable"})
        check(reply["message"] == "Plan use could not be read (HTTP 503, usage_plan_unavailable).", "a plain machine code is echoed")
        reply, _ = answer(500, {"error": "spawn /Users/someone/x ENOENT"})
        check(reply["message"] == "Plan use could not be read (HTTP 500).", "an error with spaces or a path gives no code")
        reply, _ = answer(200, {"protocolVersion": 1, "closest": None})
        check(reply["ok"] is False and reply["message"] == "Plan use could not be read (HTTP 200).", "an answer without lines is refused")
        reply, _ = answer(200, dict(PANE, protocolVersion=2))
        check(reply["ok"] is False, "another protocol is refused")
        before = len(calls)
        reply = run("--refresh", overrides={"COS_CONTROL_TEST_HOME": tmp})
        check(reply == {"ok": False, "message": "Plan use is not read in the isolated preview", "details": {}} and len(calls) == before,
              "the isolated preview refuses before any request")
        server.shutdown()
    print(f"usage-plan helper checks: {passed[0]} passed")


if __name__ == "__main__":
    main()
