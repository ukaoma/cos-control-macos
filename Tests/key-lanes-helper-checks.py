#!/usr/bin/env python3
"""K1 P10 key lanes: the compiled helper's `key-lanes` verbs against a private loopback fixture. No real server, key or
account: the key is a fake. Pins: each action's method, path and body with the token and no Origin header (the server's
Mac-only rule); save-key reads the key from stdin and sends it only in the request body; a key in argv is refused before
any request; the key never reaches stdout or stderr, even when the server echoes it; every answer is ok with transport and
httpStatus; a 404 page is `unsupported` (lanes off, or an older server); only the contract's keys cross; unreachable and
a missing token are their own transports. Prints "key lanes helper checks: N passed". Usage: key-lanes-helper-checks.py <helper>"""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = 'sk-or-v1-' + '0123456789abcdef' * 2 + 'f00d9f3c'
REF = 'key_0123456789ab'

with tempfile.TemporaryDirectory(prefix='cos-key-lanes-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'f' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    state = {'status': 200, 'body': {}}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token, self.headers.get('Origin'),
                             data.decode() if data else None))
            if state['body'] is None:
                raw = b'<!DOCTYPE html><pre>Cannot GET</pre>'; self.send_response(state['status']); self.send_header('Content-Type', 'text/html')
                self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            raw = json.dumps(state['body']).encode()
            self.send_response(state['status']); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_POST = do_DELETE = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, port=None, stdin=None):
        e = dict(env, COS_CONTROL_TEST_API_PORT=str(port)) if port else env
        result = subprocess.run([sys.argv[1], 'key-lanes', *args], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=40)
        out, err = result.stdout.decode(), result.stderr.decode()
        if token in out or token in err:
            print('key lanes helper check FAILED: the token leaked to the helper output'); sys.exit(1)
        if SECRET in out or SECRET in err:
            print('key lanes helper check FAILED: the key leaked to the helper output'); sys.exit(1)
        try:
            return json.loads(out)
        except ValueError:
            return {'ok': False, 'message': (out + err)[:300], 'details': {}}

    checks = 0
    def check(value, name):
        global checks
        if not value:
            print(f'key lanes helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    status_body = {'enabled': True, 'active': True, 'keys': [{'ref': REF, 'kind': 'openrouter', 'last4': '9f3c', 'capUsd': 1, 'spentTodayUsd': 0.2,
                   'breaker': {'open': False, 'failures': 0}, 'secret': SECRET}], 'profiles': [], 'keyedSessionIds': ['0f1e2d3c-4b5a'], 'extra': 'X'}
    try:
        state['body'] = status_body
        got = run('status')
        check(requests[-1][:4] == ('GET', '/api/key-lanes/status', True, None), 'status is a GET with the token and no Origin')
        d = got['details']
        check(got['ok'] and d['transport'] == 'answered' and d['httpStatus'] == 200 and d['enabled'] is True and 'extra' not in d, 'status answered, contract fields only')
        check(d['keys'] == [{'ref': REF, 'kind': 'openrouter', 'last4': '9f3c', 'capUsd': 1, 'spentTodayUsd': 0.2, 'breaker': {'open': False, 'failures': 0}}],
              'a key crosses as ref, kind, last 4, cap, spend and breaker')
        check(d['keyedSessionIds'] == ['0f1e2d3c-4b5a'], 'keyed sessions cross')

        state['body'] = {'enabled': True, 'active': False}
        got = run('enable')
        check(requests[-1][:4] == ('POST', '/api/key-lanes/enable', True, None) and json.loads(requests[-1][4]) == {}, 'enable posts {} with the token and no Origin')
        check(got['details'] == {'transport': 'answered', 'httpStatus': 200, 'enabled': True, 'active': False}, 'enable answer')

        state['body'] = {'key': {'ref': REF, 'kind': 'openrouter', 'last4': '9f3c', 'capUsd': 1, 'savedAt': '2026-10-19'}, 'credit': {'remainingUsd': 4.5}}
        got = run('save-key', stdin=json.dumps({'kind': 'openrouter', 'key': SECRET, 'capUsd': 1}).encode())
        check(requests[-1][:2] == ('POST', '/api/key-lanes/keys') and json.loads(requests[-1][4]) == {'kind': 'openrouter', 'key': SECRET, 'capUsd': 1},
              'save-key posts the stdin key in the body only')
        check(SECRET not in requests[-1][1], 'the key is never in the URL')
        check(got['details'] == {'transport': 'answered', 'httpStatus': 200, 'key': {'ref': REF, 'kind': 'openrouter', 'last4': '9f3c', 'capUsd': 1},
                                 'credit': {'remainingUsd': 4.5}}, 'a saved key answers with its public record and credit')

        state['status'] = 422; state['body'] = {'error': 'key_rejected', 'message': 'OpenRouter rejected ' + SECRET}
        got = run('save-key', stdin=json.dumps({'kind': 'openrouter', 'key': SECRET}).encode())
        check(got['ok'] and got['details']['error'] == 'redacted', 'a server answer that repeats the key is dropped, never printed')
        state['status'] = 422; state['body'] = {'error': 'no_credit_limit', 'message': 'Set a credit limit on this key at openrouter.ai first.'}
        got = run('save-key', stdin=json.dumps({'kind': 'openrouter', 'key': SECRET}).encode())
        check(got['details'] == {'transport': 'answered', 'httpStatus': 422, 'error': 'no_credit_limit', 'message': 'Set a credit limit on this key at openrouter.ai first.'},
              'a refusal carries its code and the server sentence')

        prior = len(requests)
        for bad in (['save-key', SECRET], ['save-key', '--key', SECRET], ['status', SECRET]):
            check(not run(*bad, stdin=b'{}')['ok'], f'a key passed in argv is refused ({bad[0]})')
        check(not run('save-key', stdin=b'not json')['ok'], 'save-key refuses stdin that is not JSON')
        check(not run('save-key', stdin=json.dumps({'kind': 'openrouter', 'key': SECRET, 'note': 1}).encode())['ok'], 'save-key refuses an extra field')
        check(not run('save-key', stdin=json.dumps({'kind': 'openrouter', 'key': 'x' * 5000}).encode())['ok'], 'stdin past 4 KB is refused')
        check(not run('remove-key', '--ref', '../status')['ok'] and not run('set-cap', '--ref', REF, '--cap', '0')['ok'], 'bad refs and caps are refused')
        check(len(requests) == prior, 'a refused call never reaches the server')

        state['status'] = 200; state['body'] = {'key': {'ref': REF, 'kind': 'openrouter', 'last4': '9f3c', 'capUsd': 2.5}}
        run('set-cap', '--ref', REF, '--cap', '2.5')
        check(requests[-1][:2] == ('POST', '/api/key-lanes/keys') and json.loads(requests[-1][4]) == {'ref': REF, 'capUsd': 2.5}, 'set-cap posts ref and cap')
        state['body'] = {'removed': True, 'disabledProfiles': ['k-0123456789ab'], 'active': False}
        got = run('remove-key', '--ref', REF, '--force')
        check(requests[-1][:3] == ('DELETE', f'/api/key-lanes/keys/{REF}?force=1', True) and requests[-1][4] is None, 'remove-key is DELETE /keys/:ref?force=1')
        check(got['details']['disabledProfiles'] == ['k-0123456789ab'], 'remove-key names the profiles it turned off')
        state['status'] = 409; state['body'] = {'error': 'key_in_use', 'message': 'Turn off the profiles that use this key first: Sonnet.', 'profiles': ['k-0123456789ab']}
        got = run('remove-key', '--ref', REF)
        check(requests[-1][1] == f'/api/key-lanes/keys/{REF}' and got['details']['error'] == 'key_in_use' and got['details']['profiles'] == ['k-0123456789ab'],
              'a key in use answers 409 with its profiles')
        state['status'] = 200; state['body'] = {'removed': ['keys', 'profiles'], 'enabled': False, 'active': False, 'ledgerExportedTo': '/tmp/x/cos-key-ledger-2026-10-19.jsonl'}
        got = run('remove-all', '--export-ledger')
        check(requests[-1][:2] == ('POST', '/api/key-lanes/remove-all') and json.loads(requests[-1][4]) == {'exportLedger': True}, 'remove-all with export')
        check(got['details']['removed'] == ['keys', 'profiles'] and got['details']['enabled'] is False, 'remove-all answer')
        run('remove-all')
        check(json.loads(requests[-1][4]) == {'exportLedger': False}, 'remove-all without export')
        state['body'] = {'profile': {'id': 'k-0123456789ab', 'label': 'Sonnet 5.5', 'keyRef': REF, 'engine': 'claude', 'model': 'anthropic/claude-sonnet-5.5', 'enabled': True}, 'active': True}
        profile = {'id': 'k-0123456789ab', 'label': 'Sonnet 5.5', 'keyRef': REF, 'engine': 'claude', 'model': 'anthropic/claude-sonnet-5.5', 'enabled': True, 'timeoutTier': 'sonnet'}
        got = run('save-profile', stdin=json.dumps(profile).encode())
        check(requests[-1][:2] == ('POST', '/api/key-lanes/profiles') and json.loads(requests[-1][4]) == profile, 'save-profile posts the stdin profile')
        check(got['details']['active'] is True and got['details']['profile']['model'] == 'anthropic/claude-sonnet-5.5', 'save-profile answer')
        run('delete-profile', '--id', 'k-0123456789ab')
        check(requests[-1][:2] == ('DELETE', '/api/key-lanes/profiles/k-0123456789ab'), 'delete-profile')
        state['body'] = {'curated': [{'id': 'anthropic/claude-sonnet-5.5', 'name': 'Claude Sonnet 5.5', 'inUsdPerM': 2, 'outUsdPerM': 10, 'role': 'default'}], 'pricesFrom': 'built-in'}
        got = run('catalog')
        check(requests[-1][:2] == ('GET', '/api/key-lanes/catalog') and got['details']['curated'][0]['role'] == 'default', 'catalog')

        state['status'] = 404; state['body'] = None
        got = run('status')
        check(got['ok'] and got['details'] == {'transport': 'unsupported', 'httpStatus': 404}, 'lanes off (the 404 page) is unsupported')
        got = run('enable')
        check(got['details'] == {'transport': 'unsupported', 'httpStatus': 404}, 'a refused enable door is unsupported')

        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); closed = s.getsockname()[1]
        prior = len(requests)
        check(run('status', port=closed)['details'] == {'transport': 'unavailable'}, 'nothing answering is unavailable')
        env_file.unlink()
        check(run('status')['details'] == {'transport': 'no_token'} and len(requests) == prior, 'no pairing token: no_token, nothing sent')
        check(run('save-key', stdin=json.dumps({'kind': 'openrouter', 'key': SECRET}).encode())['details'] == {'transport': 'no_token'},
              'no pairing token: the key is not sent anywhere')
        print(f'key lanes helper checks: {checks} passed')
    finally:
        server.shutdown()
