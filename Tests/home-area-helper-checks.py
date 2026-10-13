#!/usr/bin/env python3
"""Home city (server 6.71.13): the compiled helper's home-area and set-home-area against a private loopback fixture.
No real server, account, or credentials. Pins: GET and PUT on /api/home-area with the token header, only homeCity
crosses (from stdin, never argv), a 404 and a 400 are answers (ok with httpStatus) and a 400 carries the server's
sentence, a blank clears with "", and the token never reaches stdout."""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
with tempfile.TemporaryDirectory(prefix='cos-home-area-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'c' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    state = {'status': 200, 'body': {'homeCity': None, 'effective': {'text': 'Tulsa', 'source': 'phone_area'}}}
    requests = []
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            if self.path == '/api/health':
                raw = b'{"ok":true}'; self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            assert self.headers.get('X-COS-Token') == token, 'token header'
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, json.loads(data) if data else None))
            raw = json.dumps(state['body']).encode()
            self.send_response(state['status']); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_PUT = do_POST = answer
    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))
    def run(command, stdin=None):
        result = subprocess.run([sys.argv[1], command], input=(json.dumps(stdin).encode() if stdin is not None else b''),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=15)
        assert token not in result.stdout.decode() and token not in result.stderr.decode(), 'token leaked'
        return json.loads(result.stdout)
    checks = 0
    def check(value, name):
        global checks
        assert value, name
        checks += 1
    try:
        got = run('home-area')
        check(requests[-1] == ('GET', '/api/home-area', None), 'GET /api/home-area, no body')
        check(got['ok'] and got['details']['httpStatus'] == 200 and got['details']['homeCity'] is None, 'unset city reads as null')
        check(got['details']['effective'] == {'text': 'Tulsa', 'source': 'phone_area'}, 'effective passes through')
        state['body'] = {'homeCity': 'Austin, TX', 'effective': {'text': 'Austin, TX', 'source': 'profile'}, 'extra': 'dropped'}
        got = run('set-home-area', {'homeCity': 'Austin, TX', 'sneak': 'x'})
        check(requests[-1] == ('PUT', '/api/home-area', {'homeCity': 'Austin, TX'}), 'PUT carries homeCity only')
        check(got['ok'] and got['details']['homeCity'] == 'Austin, TX' and 'extra' not in got['details'], 'saved city, whitelisted answer')
        run('set-home-area', {'homeCity': ''})
        check(requests[-1] == ('PUT', '/api/home-area', {'homeCity': ''}), 'blank clears with ""')
        run('set-home-area', {'homeCity': None})
        check(requests[-1] == ('PUT', '/api/home-area', {'homeCity': None}), 'null clears')
        prior = len(requests)
        check(not run('set-home-area', {'city': 'Austin'})['ok'] and not run('set-home-area', {'homeCity': 7})['ok']
              and not run('set-home-area', {'homeCity': 'A' * 201})['ok'] and len(requests) == prior, 'malformed changes never reach the server')
        state['status'] = 400; state['body'] = {'error': 'Use a city and state, like Austin, TX. Letters only, no street address.'}
        got = run('set-home-area', {'homeCity': '123 Main St'})
        check(got['ok'] and got['details']['httpStatus'] == 400 and got['details']['error'].startswith('Use a city and state'), '400 is an answer with the server sentence')
        state['status'] = 404; state['body'] = {'error': 'Not found'}
        got = run('home-area')
        check(got['ok'] and got['details']['httpStatus'] == 404, '404 is an answer (older server), not a failure')
        state['status'] = 503; state['body'] = {'error': 'SECRET stack'}
        got = run('home-area')
        check(not got['ok'] and 'SECRET' not in json.dumps(got), 'unexpected status fails without the server text')
        print(f'PASS Home city helper: {checks} checks')
    finally:
        server.shutdown()
