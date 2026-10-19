#!/usr/bin/env python3
"""0.5.327 Cue verdicts (server 6.79.0): the compiled helper's live-cues-history and live-cues-rate against a private
loopback fixture. No real server, account, or credentials. Pins: GET /api/live-cues/history with days, limit 200, the
meeting and unrated in the query and the token header; POST /api/live-cues/feedback with exactly {sessionId, cueId,
verdict, note?}; a refused argument never reaches the server; every answer is ok with transport and httpStatus (404,
404 unknown_cue, 401 and 500 included), only the contract's keys cross, an unreachable server and a missing token are
their own transports, and the token never reaches stdout or stderr.
Prints "cue verdicts helper checks: N passed". Usage: cue-verdicts-helper-checks.py <helper>"""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

CUE = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
SESSION = 'meeting_1791635349988_67d6pj'

with tempfile.TemporaryDirectory(prefix='cos-cue-verdicts-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'e' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    row = {'v': 1, 'cueId': CUE, 'sessionId': SESSION, 'meetingTitle': 'HC Monday standup', 'createdAt': 1791636000000, 'kind': 'challenge',
           'headline': 'Settle the archive date', 'detail': 'Settle the date and what the archive keeps.', 'gate': 0.97,
           'sources': [], 'model': 'claude-sonnet-5-5', 'before': 'MU: we just move them into an old hub DB table.', 'verdict': None}
    history = {'v': 1, 'cues': [row], 'counts': {'total': 31, 'rated': 3, 'unrated': 28,
                                                  'byVerdict': {'useful': 2, 'late': 1, 'repeat': 0, 'wrong': 0, 'obvious': 0}}}
    state = {'status': 200, 'body': history}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            if self.path == '/api/health':
                raw = b'{"ok":true}'; self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token, data.decode() if data else None))
            raw = json.dumps(state['body']).encode()
            self.send_response(state['status']); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_PUT = do_POST = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, port=None):
        e = dict(env, COS_CONTROL_TEST_API_PORT=str(port)) if port else env
        result = subprocess.run([sys.argv[1], *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=30)
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
            print(f'cue verdicts helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    try:
        # ── live-cues-history
        got = run('live-cues-history')
        check(requests[-1] == ('GET', '/api/live-cues/history?days=7&limit=200', True, None), 'a read is GET for seven days, 200 at most, with the token')
        d = got['details']
        check(got['ok'] and d['transport'] == 'answered' and d['httpStatus'] == 200 and d['v'] == 1, 'a 200 is answered with its version')
        check(d['counts'] == history['counts'], 'the counts pass through')
        cue = d['cues'][0]
        check(cue['cueId'] == CUE and cue['gate'] == 0.97 and cue['before'] == row['before'] and cue['sources'] == [] and cue['verdict'] is None
              and cue['meetingTitle'] == 'HC Monday standup', 'a row passes through, an unrated one with a null verdict')
        run('live-cues-history', '--days', '30', '--session', SESSION, '--unrated')
        check(requests[-1][1] == f'/api/live-cues/history?days=30&limit=200&sessionId={SESSION}&unrated=1', 'days, the meeting and unrated reach the query')

        rated = dict(row, verdict={'verdict': 'repeat', 'note': 'same ask as 7:49', 'vote': 'down', 'at': 1791636100000, 'extra': 'SECRET'},
                     token='SECRET')
        state['body'] = dict(history, cues=[rated, dict(row, cueId='bad id'), dict(row, kind='advice')], extra='SECRET')
        got = run('live-cues-history')
        cues = got['details']['cues']
        check(len(cues) == 1 and cues[0]['verdict'] == {'verdict': 'repeat', 'note': 'same ask as 7:49', 'vote': 'down', 'at': 1791636100000}
              and 'SECRET' not in json.dumps(got), 'only the contract crosses; a row without its required fields is dropped')

        prior = len(requests)
        for bad in (['--days', '0'], ['--days', '31'], ['--days', 'week'], ['--session', 'a b'], ['--session', 'x&unrated=1']):
            check(not run('live-cues-history', *bad)['ok'], f'live-cues-history refuses {bad}')
        check(len(requests) == prior, 'a refused read never reaches the server')

        state['status'] = 404; state['body'] = {'error': 'Not found'}
        got = run('live-cues-history')
        check(got['ok'] and got['details'] == {'transport': 'answered', 'httpStatus': 404}, '404 is an answer (an older server), nothing else')
        state['status'] = 500; state['body'] = dict(history, error='SECRET stack')
        got = run('live-cues-history')
        check(got['ok'] and got['details'] == {'transport': 'answered', 'httpStatus': 500}, 'a 500 carries no rows and no server text')

        # ── live-cues-rate
        state['status'] = 200; state['body'] = {'ok': True, 'cueId': CUE, 'verdict': 'useful', 'vote': None, 'extra': 'SECRET'}
        got = run('live-cues-rate', '--session', SESSION, '--cue', CUE, '--verdict', 'useful', '--note', '  more\n than  that ')
        check(requests[-1][:3] == ('POST', '/api/live-cues/feedback', True), 'a rating is a POST on the feedback route with the token')
        check(json.loads(requests[-1][3]) == {'sessionId': SESSION, 'cueId': CUE, 'verdict': 'useful', 'note': 'more than that'},
              'exactly the session, the cue, the verdict and the collapsed note')
        check(got['ok'] and got['details'] == {'transport': 'answered', 'httpStatus': 200, 'ok': True, 'cueId': CUE, 'verdict': 'useful'},
              'the answer: ok and the stored verdict, nothing else')
        state['body'] = {'ok': True, 'cueId': CUE, 'verdict': None, 'vote': 'up'}
        got = run('live-cues-rate', '--session', SESSION, '--cue', CUE, '--verdict', 'clear')
        check(json.loads(requests[-1][3]) == {'sessionId': SESSION, 'cueId': CUE, 'verdict': 'clear'}, 'clear sends no note')
        check(got['details']['verdict'] is None and got['details']['vote'] == 'up', 'a cleared verdict is null; the lens vote stays')
        long_note = 'x' * 260
        run('live-cues-rate', '--session', SESSION, '--cue', CUE, '--verdict', 'late', '--note', long_note)
        check(json.loads(requests[-1][3])['note'] == 'x' * 200, 'a note is cut to the server\'s 200')

        prior = len(requests)
        for bad in (['--verdict', 'up'], ['--verdict', 'Useful'], ['--verdict', 'clear', '--note', 'x'], ['--cue', 'short'], ['--session', '../x']):
            args = {'--session': SESSION, '--cue': CUE, '--verdict': 'useful'}
            extra = []
            for i in range(0, len(bad), 2):
                if bad[i] in args: args[bad[i]] = bad[i + 1]
                else: extra += bad[i:i + 2]
            flat = [x for kv in args.items() for x in kv] + extra
            check(not run('live-cues-rate', *flat)['ok'], f'live-cues-rate refuses {bad}')
        check(not run('live-cues-rate', '--cue', CUE, '--verdict', 'useful')['ok'], 'live-cues-rate refuses a missing session')
        check(len(requests) == prior, 'a refused rating never reaches the server')

        state['status'] = 404; state['body'] = {'error': 'Unknown cue', 'reason': 'unknown_cue'}
        got = run('live-cues-rate', '--session', SESSION, '--cue', CUE, '--verdict', 'wrong')
        check(got['ok'] and got['details'] == {'transport': 'answered', 'httpStatus': 404, 'error': 'unknown_cue'}, '404 unknown_cue keeps its code')
        state['status'] = 401; state['body'] = {'error': 'unauthorized'}
        got = run('live-cues-rate', '--session', SESSION, '--cue', CUE, '--verdict', 'wrong')
        check(got['ok'] and got['details']['httpStatus'] == 401, '401 is an answer')

        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); closed = s.getsockname()[1]
        prior = len(requests)
        check(run('live-cues-history', port=closed)['details'] == {'transport': 'unavailable'}, 'nothing answering a read is unavailable')
        check(run('live-cues-rate', '--session', SESSION, '--cue', CUE, '--verdict', 'late', port=closed)['details'] == {'transport': 'unavailable'},
              'nothing answering a rating is unavailable')
        env_file.unlink()
        check(run('live-cues-history')['details'] == {'transport': 'no_token'}, 'no pairing token: a read is no_token')
        check(run('live-cues-rate', '--session', SESSION, '--cue', CUE, '--verdict', 'late')['details'] == {'transport': 'no_token'}
              and len(requests) == prior, 'no pairing token: a rating is no_token, nothing sent')
        print(f'cue verdicts helper checks: {checks} passed')
    finally:
        server.shutdown()
