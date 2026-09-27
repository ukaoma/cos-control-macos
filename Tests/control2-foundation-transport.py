#!/usr/bin/env python3
"""Exercise the built helper against a disposable loopback server; no live API."""
import http.server, json, os, pathlib, subprocess, sys, tempfile, threading
helper = sys.argv[1]
seen = []
mode = 'ok'
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def respond(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        seen.append((self.command, self.path, self.headers.get('X-COS-Token'), body))
        if mode in ('approved-error', 'private-error'):
            code = 'draft_process_turn_budget_exhausted' if mode == 'approved-error' else 'secret-token /private/path'
            data = json.dumps({'error': {'code': code, 'message': 'private-server-detail'}}).encode()
            self.send_response(409); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if mode == 'redirect':
            self.send_response(302); self.send_header('Location', '/unexpected'); self.end_headers(); return
        if mode == 'large':
            self.send_response(200); self.send_header('Content-Length', '3000000'); self.end_headers(); return
        data = json.dumps({'schemaVersion': 1, 'enabled': True, 'mode': 'foundation', 'capabilities': {'publication': False, 'automaticExecution': False}, 'work': [], 'gates': []}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='cos-control2-native-', dir='/tmp') as root:
        tokenfile = pathlib.Path(root, '.cos-glasses', '.env'); tokenfile.parent.mkdir()
        tokenfile.write_text('COS_API_TOKEN=disposable-foundation-token\n'); tokenfile.chmod(0o600)
        env = dict(os.environ, COS_CONTROL_TEST_HOME=root, COS_CONTROL_TEST_API_PORT=str(server.server_port), COS_CONTROL2_FOUNDATION='1')
        def run(command='foundation-status', overrides=None, payload=None, arguments=None):
            r = subprocess.run([helper, command, *(arguments or [])], env=dict(env, **(overrides or {})), input=payload, capture_output=True, text=True, timeout=22)
            return r, json.loads(r.stdout)
        _, result = run(); assert result['ok'] and result['details']['mode'] == 'foundation'
        _, result = run('foundation-replay', payload='{"meetingId":"fixture"}'); assert result['ok']
        assert seen[-1][0:3] == ('POST', '/api/control2/foundation/replay', 'disposable-foundation-token')
        _, result = run('foundation-draft', arguments=['--work-id', 'fixture-work']); assert result['ok']
        assert seen[-1][1] == '/api/control2/foundation/draft' and json.loads(seen[-1][3]) == {'workId':'fixture-work'}
        before = len(seen)
        for override in [{'COS_CONTROL2_FOUNDATION':'0'}, {'COS_CONTROL_TEST_API_PORT':'3141'}, {'COS_CONTROL_TEST_API_PORT':'3143'}, {'COS_CONTROL_TEST_HOME':'/tmp/../Users'}]:
            _, result = run(overrides=override); assert not result['ok']
        assert len(seen) == before, 'Invalid environment made a network request'
        with tempfile.TemporaryDirectory(prefix='outside-token-', dir='/tmp') as outside:
            outside_token = pathlib.Path(outside, '.env'); outside_token.write_text('COS_API_TOKEN=outside-private-token\n'); outside_token.chmod(0o600)
            tokenfile.unlink(); tokenfile.parent.rmdir(); tokenfile.parent.symlink_to(outside, target_is_directory=True)
            _, result = run(); assert not result['ok']
            assert len(seen) == before, 'Symlinked token directory made a network request'
            tokenfile.parent.unlink(); tokenfile.parent.mkdir(); tokenfile.write_text('COS_API_TOKEN=disposable-foundation-token\n'); tokenfile.chmod(0o600)
        _, result = run('foundation-draft', overrides=None, payload=None) # no ID: refused before request
        assert not result['ok'] and len(seen) == before
        mode = 'approved-error'; _, result = run(); assert not result['ok'] and 'draft_process_turn_budget_exhausted' in result['message']
        mode = 'private-error'; _, result = run(); assert not result['ok'] and 'secret-token' not in result['message'] and 'private-server-detail' not in result['message']
        mode = 'redirect'; _, result = run(); assert not result['ok']; assert seen[-1][1] != '/unexpected'
        mode = 'large'; _, result = run(); assert not result['ok']
        mode = 'ok'; _, result = run('foundation-replay', payload='x' * 65537); assert not result['ok']
        print('PASS: authenticated GET/replay/draft, opt-in, production-port/path/token-symlink refusal, no redirects, bounded payload/response')
finally:
    server.shutdown(); server.server_close()
