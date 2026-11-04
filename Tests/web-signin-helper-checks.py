#!/usr/bin/env python3
"""0.5.367 Open COS on your phone (server 6.99.3): the compiled helper's web-handoff and web-device-code against a private
loopback fixture in a /tmp home. No real server, account or credentials.

What a fixture can prove: both verbs are dispatched and answer as JSON, and both run Copy token's managed-server check FIRST.
A /tmp home never holds the canonical LaunchAgent, so that check never passes here, and the pin is that nothing reaches
/api/web-session/* and the answer is ok with transport `not_ready`. What crosses on a real answer (the phone link, its shape,
the code, a 404, a refusal) is WebSignInCore, checked alone in Tests/PairingCoreChecks.swift. The token, a ticket and a code
never reach stdout or stderr. Prints "web sign-in helper checks: N passed". Usage: web-signin-helper-checks.py <helper>"""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

TICKET = 'AbCdEfGhIjKlMnOpQrStUvWxYz012345'

with tempfile.TemporaryDirectory(prefix='cos-web-signin-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir(mode=0o700)
    token = 'w' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token))
            if self.path == '/api/health':
                body = {'ok': True}
            elif self.path.startswith('/api/maintenance/status'):
                body = {'lifecycle': {'state': 'accepting'}, 'contract': 1}
            elif self.path == '/api/web-session/handoff':
                body = {'ok': True, 'ticket': TICKET, 'expiresAt': '2026-11-04T15:02:00.000Z',
                        'url': f'http://127.0.0.1:3141/control?handoff={TICKET}',
                        'phoneUrl': f'http://100.64.0.10:3141/control?handoff={TICKET}', 'tailnet': {'ipUrl': None, 'nameUrl': None}}
            elif self.path == '/api/web-session/device-code':
                body = {'ok': True, 'code': 'K7Q2-M9XD', 'expiresAt': '2026-11-04T15:05:00.000Z'}
            else:
                body = {}
            raw = json.dumps(body).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        do_GET = do_POST = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    checks = 0
    def check(value, name):
        global checks
        if not value:
            print(f'web sign-in helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    def run(verb):
        result = subprocess.run([sys.argv[1], verb], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60)
        out, err = result.stdout.decode(), result.stderr.decode()
        check(token not in out and token not in err, f'{verb}: the token never reaches stdout or stderr')
        check(TICKET not in err and 'K7Q2' not in err, f'{verb}: no ticket or code on stderr')
        check(result.returncode == 0, f'{verb}: exits 0 ({result.returncode}: {err[:300]})')
        try:
            return json.loads(out)
        except ValueError:
            check(False, f'{verb}: prints one JSON answer, got {out[:300]!r}')

    try:
        for verb in ('web-handoff', 'web-device-code'):
            before = len(requests)
            got = run(verb)
            check(not any(path.startswith('/api/web-session/') for _, path, _ in requests[before:]),
                  f'{verb}: Copy token\'s check runs first, so nothing reaches /api/web-session/* ({requests[before:]})')
            check(got['ok'] is True and got['details'] == {'transport': 'not_ready'}, f'{verb}: an unverified server is not_ready, nothing else: {got}')
            check(TICKET not in json.dumps(got) and 'K7Q2' not in json.dumps(got), f'{verb}: nothing of the fixture crosses')
    finally:
        server.shutdown()
    print(f'web sign-in helper checks: {checks} passed')
