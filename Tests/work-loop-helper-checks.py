#!/usr/bin/env python3
"""0.5.337 (loop audit W1): the compiled helper's `work-loop` against a loopback fixture; never the live service.

The shipped server has only the four Intake routes (meeting-ask, GET, items, :id/resolve), so every other work-loop action
answers 404 there. A 404 is `unsupported` for EVERY action (it was only dismiss), never an error; a 409 is still the
server's refusal with its message; a 200 passes the body through.

Usage: work-loop-helper-checks.py <compiled cos-control-helper>
"""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-loop-helper-', dir='/tmp'))
token = 'c' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)
state = {'status': 404}
calls = []
ROUTES = {"dismiss": ("POST", "/api/work-intake/resolve-batch"), "undo": ("POST", "/api/work-intake/undo"),
          "seen": ("POST", "/api/work-intake/seen"), "decisions": ("GET", "/api/work-intake/decisions"),
          "expired": ("GET", "/api/work-intake/expired"), "restore": ("POST", "/api/work-intake/restore"),
          "settings": ("GET", "/api/work-intake/settings"), "set-settings": ("POST", "/api/work-intake/settings"),
          "dropped": ("GET", "/api/work-board/dropped"), "waiting": ("GET", "/api/work-board/waiting"), "batch": ("POST", "/api/work-board/batch")}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def handle_any(self, method):
        length = int(self.headers.get('Content-Length') or 0)
        if length: self.rfile.read(length)
        calls.append((method, self.path))
        assert self.headers.get('X-COS-Token') == token, self.path
        if state['status'] == 200: return self.reply(200, {'ok': True, 'changed': 1, 'decisions': []})
        if state['status'] == 409: return self.reply(409, {'error': {'code': 'undo_unavailable', 'message': 'That decision cannot be undone.'}})
        return self.reply(404, {'error': 'Not found'})
    def do_GET(self): self.handle_any('GET')
    def do_POST(self): self.handle_any('POST')

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
fails = []
def check(ok, label):
    if not ok: fails.append(label)
def run(action, body=None):
    data = json.dumps(body if body is not None else {"batchId": "b"}).encode() if ROUTES[action][0] == "POST" else b""
    out = subprocess.run([helper, 'work-loop', '--action', action], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=30)
    return json.loads(out.stdout)
try:
    for action, (method, path) in ROUTES.items():
        state['status'] = 404; calls.clear()
        r = run(action)
        check(r.get('ok') is True and r.get('details', {}).get('unsupported') is True, f"[404 unsupported] {action}: a 404 is unsupported, not an error ({r})")
        check(calls == [(method, path)], f"[route] {action} calls {method} {path} once ({calls})")
        state['status'] = 409
        r = run(action)
        check(r.get('ok') is False and 'cannot be undone' in (r.get('message') or ''), f"[409 refused] {action}: the server's refusal keeps its message ({r})")
        state['status'] = 200
        r = run(action)
        check(r.get('ok') is True and r.get('details', {}).get('changed') == 1 and 'unsupported' not in r.get('details', {}), f"[200 passes] {action} ({r})")
finally:
    server.shutdown()
if fails:
    print("\n".join("work-loop helper: " + f for f in fails)); sys.exit(1)
print(f"PASS: work-loop helper: {len(ROUTES) * 3} checks (every action: 404 unsupported, 409 refused with its message, 200 passed through)")
