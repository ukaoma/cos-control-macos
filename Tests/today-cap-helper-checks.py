#!/usr/bin/env python3
"""0.5.380 (Miles 2026-11-08, server 7.0.5): the compiled helper's today-brief-cap and the reconnect fallback of today-brief,
against a private loopback fixture. No real server, account, or credentials.

today-brief-cap: GET /api/today/brief/settings/cap with the token; `--set N` PUTs exactly {"dailyCap": N}; only the contract's
keys cross; a 404 is an older server (`available: false`); a value outside 1 to 100 never reaches the server.
today-brief: a body with `reason: "reconnect"` is sent as it is; a server before 7.0.5 that answers 400 invalid_today_brief
is asked again without `reason` (and, if still refused, without `force`); the token never reaches stdout or stderr.
Prints "today cap helper checks: N passed". Usage: today-cap-helper-checks.py <helper>"""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

with tempfile.TemporaryDirectory(prefix='cos-today-cap-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'e' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    state = {'answers': []}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            if self.path == '/api/health':
                raw = b'{"ok":true}'; self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token, json.loads(data) if data else None))
            status, body = state['answers'].pop(0) if state['answers'] else (500, {'error': 'no answer queued'})
            raw = b'<!DOCTYPE html><pre>Cannot GET</pre>' if body is None else json.dumps(body).encode()
            self.send_response(status); self.send_header('Content-Type', 'text/html' if body is None else 'application/json')
            self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_PUT = do_POST = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, stdin=None):
        result = subprocess.run([sys.argv[1], *args], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60)
        out, err = result.stdout.decode(), result.stderr.decode()
        assert token not in out and token not in err, 'token leaked'
        try:
            return json.loads(out)
        except ValueError:
            return {'ok': False, 'message': (out + err)[:300], 'details': {}}

    checks = 0
    def check(value, name):
        global checks
        if not value:
            print(f'today cap helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    try:
        cap = {'dailyCap': 100, 'min': 1, 'max': 100, 'default': 100, 'usedToday': 7, 'extra': 'SECRET'}
        state['answers'] = [(200, cap)]
        got = run('today-brief-cap')
        check(requests[-1][:3] == ('GET', '/api/today/brief/settings/cap', True), 'a read is GET with the token')
        check(got['ok'] and got['details'] == {'available': True, 'dailyCap': 100, 'min': 1, 'max': 100, 'default': 100, 'usedToday': 7},
              'only the contract keys cross')
        state['answers'] = [(200, dict(cap, dailyCap=25))]
        got = run('today-brief-cap', '--set', '25')
        check(requests[-1][:2] == ('PUT', '/api/today/brief/settings/cap') and requests[-1][3] == {'dailyCap': 25}, 'a change PUTs exactly dailyCap')
        check(got['details']['dailyCap'] == 25, 'the saved value comes back')
        before = len(requests)
        for bad in ['0', '101', '-3', 'ten', '2.5', '1000']:
            r = run('today-brief-cap', '--set', bad)
            check(not r['ok'] and len(requests) == before, f'{bad!r} never reaches the server')
        state['answers'] = [(404, None)]
        check(run('today-brief-cap')['details'] == {'available': False}, 'a 404 is an older server: no row')
        state['answers'] = [(400, {'error': {'code': 'invalid_today_brief_cap', 'message': 'Send { dailyCap: a number from 1 to 100 }.'}})]
        r = run('today-brief-cap', '--set', '50')
        check(not r['ok'] and 'from 1 to 100' in r['message'], "a refusal says the server's words")

        rows = {'sessions': [], 'needsYou': []}
        view = {'state': 'fresh', 'text': 'Two things need you.'}
        state['answers'] = [(200, view)]
        got = run('today-brief', stdin=json.dumps(dict(rows, reason='reconnect')).encode())
        check(requests[-1][:2] == ('POST', '/api/today/brief') and requests[-1][3] == dict(rows, reason='reconnect'), 'a reconnect ask says so')
        check(got['details'].get('available') is True and got['details'].get('state') == 'fresh', 'its answer is read as usual')
        refused = {'error': {'code': 'invalid_today_brief', 'message': 'That is not a Today summary request.'}}
        n = len(requests)
        state['answers'] = [(400, refused), (200, view)]
        got = run('today-brief', stdin=json.dumps(dict(rows, reason='reconnect')).encode())
        check(len(requests) == n + 2 and requests[-1][3] == rows, 'an older server is asked again without reason')
        check(got['details'].get('available') is True, 'and its answer is used')
        n = len(requests)
        state['answers'] = [(400, refused), (400, refused), (200, view)]
        run('today-brief', stdin=json.dumps(dict(rows, reason='reconnect', force=True)).encode())
        check(len(requests) == n + 3 and requests[-2][3] == dict(rows, force=True) and requests[-1][3] == rows, 'reason comes off first, then force')
        n = len(requests)
        state['answers'] = [(400, refused)]
        got = run('today-brief', stdin=json.dumps(rows).encode())
        check(len(requests) == n + 1 and got['details'].get('available') is False, 'a plain ask is never retried')
    finally:
        server.shutdown()
    print(f'today cap helper checks: {checks} passed')
