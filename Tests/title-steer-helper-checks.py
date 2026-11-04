#!/usr/bin/env python3
"""0.5.366 Title steer (server 6.99.0): the compiled helper's meeting-title-steer against a private loopback fixture, and the
live-transcript read's titleSteer. No real server, account, or credentials. Pins: GET /api/meeting/title-steer?sessionId= with
the token header; PUT with exactly {sessionId, title, expectedRevision} (the title from stdin JSON, never argv); a refused
argument never reaches the server; every answer is ok with transport and httpStatus (409 title_changed with its current view,
409 save_in_progress, 404 session_not_live, 400, 503 included), a 404 that is not JSON is `unsupported`, only the contract's keys
cross and no server text, an unreachable server and a missing token are their own transports, the title never reaches argv or
stderr, the token never reaches stdout or stderr, and a live-transcript read carries the file's titleSteer cleaned (or none).
Prints "title steer helper checks: N passed". Usage: title-steer-helper-checks.py <helper>"""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

SESSION = 'mac_43879e59-3039-4f2c-9cd2-4fcc59486d71'
TITLE = 'Polling accuracy chat with Acme'

with tempfile.TemporaryDirectory(prefix='cos-title-steer-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'f' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    view = {'sessionId': SESSION, 'title': TITLE, 'revision': 4, 'updatedAt': '2026-11-03T21:05:00.000Z'}
    state = {'status': 200, 'body': view}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            if self.path == '/api/health':
                raw = b'{"ok":true}'; self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token, data.decode() if data else None))
            if state['body'] is None:
                raw = b'<!DOCTYPE html><pre>Cannot GET</pre>'; self.send_response(state['status']); self.send_header('Content-Type', 'text/html')
                self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            raw = json.dumps(state['body']).encode()
            self.send_response(state['status']); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_PUT = do_POST = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, port=None, stdin=None, env_over=None):
        e = dict(env, COS_CONTROL_TEST_API_PORT=str(port)) if port else env
        if env_over: e = dict(e, **env_over)
        result = subprocess.run([sys.argv[1], *args], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=30)
        out, err = result.stdout.decode(), result.stderr.decode()
        assert token not in out and token not in err, 'token leaked'
        assert 'Acme' not in err, 'the title reached stderr'
        try:
            return json.loads(out)
        except ValueError:
            return {'ok': False, 'message': (out + err)[:300], 'details': {}}

    checks = 0
    def check(value, name):
        global checks
        if not value:
            print(f'title steer helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    try:
        # ── a read
        got = run('meeting-title-steer', '--session', SESSION)
        check(requests[-1] == ('GET', f'/api/meeting/title-steer?sessionId={SESSION}', True, None), 'a read is GET with the session in the query and the token')
        check(got['ok'] and got['details'] == {'transport': 'answered', 'httpStatus': 200, 'title': TITLE, 'revision': 4, 'updatedAt': '2026-11-03T21:05:00.000Z'},
              'a 200 is the title, the revision and the time, nothing else (no session id)')
        state['body'] = {'sessionId': SESSION, 'title': None, 'revision': 0, 'updatedAt': None, 'serverInstanceId': 'SECRET'}
        got = run('meeting-title-steer', '--session', SESSION)
        check(got['details'] == {'transport': 'answered', 'httpStatus': 200, 'title': None, 'revision': 0, 'updatedAt': None}, 'no steer is a null title at revision 0')
        state['body'] = dict(view, title='  Spaced ​ out  ' + 'x' * 200)
        got = run('meeting-title-steer', '--session', SESSION)
        check(len(got['details']['title']) == 120 and got['details']['title'].startswith('Spaced out x'), 'a long title from the server is cleaned and cut to 120')
        state['body'] = dict(view, title=7)
        check(run('meeting-title-steer', '--session', SESSION)['details'] == {'transport': 'answered', 'httpStatus': 200}, 'a title that is not text carries nothing')

        # ── a write
        state['body'] = dict(view, title='Polling accuracy chat', revision=5)
        got = run('meeting-title-steer', '--session', SESSION, '--revision', '4', '--title-stdin', stdin=json.dumps({'title': '  Polling   accuracy chat '}).encode())
        check(requests[-1][:3] == ('PUT', '/api/meeting/title-steer', True), 'a write is a PUT on the route with the token')
        check(json.loads(requests[-1][3]) == {'sessionId': SESSION, 'title': 'Polling accuracy chat', 'expectedRevision': 4}, 'exactly the session, the cleaned title and the revision')
        check(got['details'] == {'transport': 'answered', 'httpStatus': 200, 'title': 'Polling accuracy chat', 'revision': 5, 'updatedAt': '2026-11-03T21:05:00.000Z'}, 'the answer is the stored view')
        got = run('meeting-title-steer', '--session', SESSION, '--revision', '5', '--title-stdin', stdin=json.dumps({'title': ''}).encode())
        check(json.loads(requests[-1][3]) == {'sessionId': SESSION, 'title': '', 'expectedRevision': 5}, 'clearing sends an empty title')

        prior = len(requests)
        for bad_args, bad_in in ((['--session', 'a b'], b'{}'), (['--session', 'x&y=1'], b'{}'), (['--session', 'phone_abc123', '--revision', '0', '--title-stdin'], b'{"title":"x"}'),
                                 (['--session', SESSION, '--title-stdin'], b'{"title":"x"}'), (['--session', SESSION, '--revision', '-1', '--title-stdin'], b'{"title":"x"}'),
                                 (['--session', SESSION, '--revision', 'x', '--title-stdin'], b'{"title":"x"}'), (['--session', SESSION, '--revision', '0', '--title-stdin'], b'not json'),
                                 (['--session', SESSION, '--revision', '0', '--title-stdin'], b'{"note":"x"}'),
                                 (['--session', SESSION, '--revision', '0', '--title-stdin'], json.dumps({'title': 'a' * 121}).encode()),
                                 (['--session', SESSION, '--revision', '0', '--title-stdin'], json.dumps({'title': '\U0001F1FA\U0001F1F8' * 61}).encode())):
            check(not run('meeting-title-steer', *bad_args, stdin=bad_in)['ok'], f'meeting-title-steer refuses {bad_args}')
        check(len(requests) == prior, 'a refused call never reaches the server')
        check(run('meeting-title-steer', '--session', SESSION, '--revision', '0', '--title-stdin', stdin=json.dumps({'title': 'a' * 120}).encode())['ok'], '120 characters go')
        check(run('meeting-title-steer', '--session', SESSION, '--revision', '0', '--title-stdin', stdin=json.dumps({'title': '\U0001F1FA\U0001F1F8' * 60}).encode())['ok'], '60 flags (120 code points) go')

        # ── every status an answer
        state['status'] = 409; state['body'] = {'error': 'title_changed', 'reason': 'title_changed', 'message': 'SECRET text',
                                                  'current': {'sessionId': SESSION, 'title': 'Renamed on the phone', 'revision': 7, 'updatedAt': None, 'extra': 'SECRET'}}
        got = run('meeting-title-steer', '--session', SESSION, '--revision', '1', '--title-stdin', stdin=b'{"title":"Mine"}')
        check(got['details'] == {'transport': 'answered', 'httpStatus': 409, 'error': 'title_changed', 'current': {'title': 'Renamed on the phone', 'revision': 7, 'updatedAt': None}}
              and 'SECRET' not in json.dumps(got), '409 title_changed keeps its code and the server current view, not its text')
        state['body'] = {'error': 'save_in_progress', 'reason': 'save_in_progress'}
        check(run('meeting-title-steer', '--session', SESSION, '--revision', '1', '--title-stdin', stdin=b'{"title":"Mine"}')['details'] == {'transport': 'answered', 'httpStatus': 409, 'error': 'save_in_progress'}, '409 save_in_progress')
        state['status'] = 404; state['body'] = {'error': 'session_not_live', 'reason': 'session_not_live'}
        check(run('meeting-title-steer', '--session', SESSION, '--revision', '1', '--title-stdin', stdin=b'{"title":"Mine"}')['details'] == {'transport': 'answered', 'httpStatus': 404, 'error': 'session_not_live'}, '404 session_not_live')
        state['status'] = 400; state['body'] = {'error': 'invalid_title', 'reason': 'invalid_title'}
        check(run('meeting-title-steer', '--session', SESSION, '--revision', '1', '--title-stdin', stdin=b'{"title":"Mine"}')['details'] == {'transport': 'answered', 'httpStatus': 400, 'error': 'invalid_title'}, '400 invalid_title')
        state['status'] = 503; state['body'] = {'error': 'steer_persistence_failed', 'reason': 'steer_persistence_failed'}
        check(run('meeting-title-steer', '--session', SESSION)['details'] == {'transport': 'answered', 'httpStatus': 503, 'error': 'steer_persistence_failed'}, '503 steer_persistence_failed')
        state['status'] = 500; state['body'] = {'error': 'SECRET stack', 'reason': 'title_steer_error'}
        check(run('meeting-title-steer', '--session', SESSION)['details'] == {'transport': 'answered', 'httpStatus': 500}, 'a 500 and a code outside the fixed set carry no code and no text')
        state['status'] = 404; state['body'] = None
        check(run('meeting-title-steer', '--session', SESSION)['details'] == {'transport': 'unsupported', 'httpStatus': 404}, 'a 404 page that is not JSON is unsupported (a server from before the route)')

        # ── no server, no token
        sock = socket.socket(); sock.bind(('127.0.0.1', 0)); dead = sock.getsockname()[1]; sock.close()
        check(run('meeting-title-steer', '--session', SESSION, port=dead)['details'] == {'transport': 'unavailable'}, 'nothing listening: unavailable')
        env_file.rename(home / '.cos-glasses/.env.away')
        check(run('meeting-title-steer', '--session', SESSION)['details'] == {'transport': 'no_token'}, 'no pairing token: its own transport')
        (home / '.cos-glasses/.env.away').rename(env_file)

        # ── the capability in status is covered by the helper self-test; the live read's titleSteer is below.
        fixture = json.loads((pathlib.Path(__file__).resolve().parent / 'fixtures/live-transcript/session-6.67.json').read_text())
        live_id = fixture['sessionId']
        data_dir = home / 'data'; live_dir = data_dir / 'active-sessions'; live_dir.mkdir(parents=True)
        def read_live(steer='absent'):
            record = dict(fixture)
            if steer != 'absent': record['titleSteer'] = steer
            (live_dir / f'{live_id}.json').write_text(json.dumps(record))
            got = run('live-transcript', '--data-dir', str(data_dir), '--session', live_id)
            check(got['ok'] and got['details'].get('read'), 'the live-transcript fixture reads')
            return got['details']['read']
        check('titleSteer' not in read_live(), 'a file with no steer carries none')
        steer = read_live('  Polling   accuracy chat ' + 'x' * 200).get('titleSteer', '')
        check(steer.startswith('Polling accuracy chat x') and len(steer) == 120, 'a live read carries the file steer, cleaned and cut to 120')
        check('titleSteer' not in read_live(42) and 'titleSteer' not in read_live('   '), 'a steer that is not text, or blank, is dropped')
        check(read_live('Quarterly numbers').get('titleSteer') == 'Quarterly numbers', 'a plain steer passes as it is')
    finally:
        server.shutdown()
    print(f'title steer helper checks: {checks} passed')
