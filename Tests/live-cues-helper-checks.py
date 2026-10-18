#!/usr/bin/env python3
"""0.5.322 Live cues (server 6.76.2): the compiled helper's live-cues-settings against a private loopback fixture.
No real server, account, or credentials. Pins: GET and POST on /api/live-cues/v2/settings with the token header; --set on
and --set off post exactly {"enabled": true|false} and any other --set never reaches the server; every answer is ok with
transport and httpStatus (a 404, a 409 env_forced and a 401 included), only the contract's keys cross, an unreachable
server and a missing token are their own transports, and the token never reaches stdout or stderr.
Prints "live cues helper checks: N passed". Usage: live-cues-helper-checks.py <helper>"""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

with tempfile.TemporaryDirectory(prefix='cos-live-cues-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'd' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    shape = {'enabled': False, 'source': 'default',
             'capability': {'available': False, 'reason': 'master_flag_off', 'protocol': 2, 'model': 'claude-sonnet-5-5', 'memory': 'notes',
                            'decisionProvider': 'jev'}}
    state = {'status': 200, 'body': shape}
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
        result = subprocess.run([sys.argv[1], 'live-cues-settings', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=30)
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
            print(f'live cues helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    try:
        got = run()
        check(requests[-1] == ('GET', '/api/live-cues/v2/settings', True, None), 'a read is GET on the v2 settings route with the token, no body')
        d = got['details']
        check(got['ok'] and d['transport'] == 'answered' and d['httpStatus'] == 200, 'a 200 is answered')
        check(d['enabled'] is False and d['source'] == 'default' and d['capability'] == shape['capability'], 'the contract passes through')

        state['body'] = dict(shape, enabled=True, source='setting', extra='SECRET',
                             capability=dict(shape['capability'], available=True, reason=None, token='SECRET', decisionProvider='subq'))
        got = run('--set', 'on')
        check(requests[-1] == ('POST', '/api/live-cues/v2/settings', True, '{"enabled":true}'), '--set on posts exactly {"enabled":true}')
        check(got['ok'] and got['details']['enabled'] is True and 'SECRET' not in json.dumps(got), 'only the contract crosses back')
        check(got['details']['capability'].get('decisionProvider') == 'subq' and 'reason' not in got['details']['capability'],
              'decisionProvider passes; a null reason is dropped')
        run('--set', 'off')
        check(requests[-1] == ('POST', '/api/live-cues/v2/settings', True, '{"enabled":false}'), '--set off posts exactly {"enabled":false}')

        prior = len(requests)
        for bad in (['--set'], ['--set', 'true'], ['--set', 'ON'], ['--set', ''], ['--set', 'on;off']):
            check(not run(*bad)['ok'], f'--set {bad[1:]} is refused')
        check(len(requests) == prior, 'a refused --set never reaches the server')

        state['status'] = 409; state['body'] = {'error': 'env_forced', 'message': 'SECRET env says'}
        got = run('--set', 'off')
        check(got['ok'] and got['details']['httpStatus'] == 409 and got['details']['error'] == 'env_forced' and 'SECRET' not in json.dumps(got),
              '409 env_forced is an answer with its code')
        state['status'] = 404; state['body'] = {'error': 'Not found'}
        got = run()
        check(got['ok'] and got['details'] == {'transport': 'answered', 'httpStatus': 404}, '404 is an answer (older server), nothing else')
        state['status'] = 401; state['body'] = {'error': 'unauthorized'}
        got = run()
        check(got['ok'] and got['details']['httpStatus'] == 401, '401 is an answer')
        state['status'] = 500; state['body'] = {'error': 'SECRET stack', 'enabled': 'yes'}
        got = run()
        check(got['ok'] and got['details']['httpStatus'] == 500 and 'SECRET' not in json.dumps(got) and 'enabled' not in got['details'],
              'a 500 carries no server text')

        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); closed = s.getsockname()[1]
        prior = len(requests)
        got = run(port=closed)
        check(got['ok'] and got['details'] == {'transport': 'unavailable'}, 'nothing answering is unavailable, never a state')
        env_file.unlink()
        got = run('--set', 'on')
        check(got['ok'] and got['details'] == {'transport': 'no_token'} and len(requests) == prior, 'no pairing token: no_token, nothing sent')
        print(f'live cues helper checks: {checks} passed')
    finally:
        server.shutdown()
