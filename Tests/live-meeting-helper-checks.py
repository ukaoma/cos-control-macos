#!/usr/bin/env python3
"""0.5.336 live meeting view (server 6.86.0): the compiled helper's live-provisional against a private loopback fixture.
No real server, account, or credentials; every word is invented. Pins: GET /api/transcribe-stream/provisional?sessionId=
with the token header and no body; every answer is ok with transport and httpStatus; only `live` and the line's chunk,
generation and newest 600 characters cross (never the server's instance id, model or timestamps); a refused session id
never reaches the server; an older server's 404 page is `unsupported`; an unreachable server and a missing token are
their own transports; the token never reaches stdout or stderr, and the grey text never reaches stderr.
Prints "live meeting helper checks: N passed". Usage: live-meeting-helper-checks.py <helper>"""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

SESSION = 'meeting_1791635349988_fx67ab'
WORDS = 'fixture words the room is still saying'

with tempfile.TemporaryDirectory(prefix='cos-live-meeting-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'e' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    line = {'chunkIndex': 7, 'previewGen': 3, 'text': WORDS, 'model': 'large-v3-turbo', 'at': 1791635400000}
    state = {'status': 200, 'body': {'v': 1, 'sessionId': SESSION, 'live': True, 'provisional': line, 'serverInstanceId': 'SECRET-instance'}, 'raw': None}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            if self.path == '/api/health':
                raw = b'{"ok":true}'; self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token, data.decode() if data else None))
            raw = state['raw'] if state['raw'] is not None else json.dumps(state['body']).encode()
            self.send_response(state['status']); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_POST = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, port=None, environment=None):
        e = environment or (dict(env, COS_CONTROL_TEST_API_PORT=str(port)) if port else env)
        result = subprocess.run([sys.argv[1], 'live-provisional', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=30)
        out, err = result.stdout.decode(), result.stderr.decode()
        assert token not in out and token not in err, 'token leaked'
        assert WORDS not in err and 'fixture words' not in err, 'the grey text reached stderr'
        try:
            return json.loads(out)
        except ValueError:
            return {'ok': False, 'message': (out + err)[:300], 'details': {}}

    checks = 0
    def check(value, name):
        global checks
        if not value:
            print(f'live meeting helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    try:
        got = run('--session', SESSION)
        check(requests[-1] == ('GET', '/api/transcribe-stream/provisional?sessionId=' + SESSION, True, None),
              'a read is GET on the provisional route with the session id and the token, no body')
        d = got['details']
        check(got['ok'] and d['transport'] == 'answered' and d['httpStatus'] == 200, 'a 200 is answered')
        check(d['live'] is True and d['provisional'] == {'chunkIndex': 7, 'previewGen': 3, 'text': WORDS}, 'the line crosses: chunk, generation, text')
        check('SECRET' not in json.dumps(got) and 'model' not in d['provisional'] and 'at' not in d['provisional'] and 'sessionId' not in d,
              'nothing else crosses: no instance id, model or timestamp')

        state['body'] = dict(state['body'], provisional=dict(line, text='w' * 900 + ' newest'))
        text = run('--session', SESSION)['details']['provisional']['text']
        check(len(text) == 600 and text.endswith(' newest'), 'only the newest 600 characters cross')

        state['body'] = {'v': 1, 'sessionId': SESSION, 'live': True, 'provisional': None}
        d = run('--session', SESSION)['details']
        check(d['live'] is True and d['provisional'] is None, 'nothing grey is a null line')
        state['body'] = {'v': 1, 'sessionId': SESSION, 'live': False, 'provisional': None}
        check(run('--session', SESSION)['details']['live'] is False, 'a meeting the server no longer holds reads live false')
        state['body'] = {'v': 1, 'live': 'yes', 'provisional': line}
        d = run('--session', SESSION)['details']
        check('live' not in d and 'provisional' not in d and d['transport'] == 'answered', 'an answer outside the contract carries no line')
        state['body'] = {'v': 1, 'live': True, 'provisional': dict(line, chunkIndex=True)}
        check(run('--session', SESSION)['details']['provisional'] is None, 'a bool is not a chunk index')

        prior = len(requests)
        for bad in (['--session', 'a b'], ['--session', 'x&live=1'], ['--session', 'ab'], []):
            check(not run(*bad)['ok'], f'live-provisional refuses {bad}')
        check(len(requests) == prior, 'a refused read never reaches the server')

        state['status'] = 404; state['raw'] = b'Cannot GET /api/transcribe-stream/provisional'
        d = run('--session', SESSION)['details']
        check(d == {'transport': 'unsupported', 'httpStatus': 404}, 'an older server without the route is unsupported')
        state['raw'] = None
        state['status'] = 400; state['body'] = {'error': 'SECRET words', 'reason': 'invalid_session_id'}
        got = run('--session', SESSION)
        check(got['ok'] and got['details'] == {'transport': 'answered', 'httpStatus': 400} and 'SECRET' not in json.dumps(got), 'a refusal carries no server text')
        state['status'] = 401; state['body'] = {'error': 'unauthorized'}
        check(run('--session', SESSION)['details'] == {'transport': 'answered', 'httpStatus': 401}, 'a 401 is its status')

        sock = socket.socket(); sock.bind(('127.0.0.1', 0)); dead = sock.getsockname()[1]; sock.close()
        check(run('--session', SESSION, port=dead)['details'] == {'transport': 'unavailable'}, 'nothing listening is unavailable')
        empty = pathlib.Path(tmp) / 'no-token'; (empty / '.cos-glasses').mkdir(parents=True)
        got = run('--session', SESSION, environment=dict(env, COS_CONTROL_TEST_HOME=str(empty)))
        check(got['ok'] and got['details'] == {'transport': 'no_token'}, 'no pairing token is its own transport')
        print(f'live meeting helper checks: {checks} passed')
    finally:
        server.shutdown()
