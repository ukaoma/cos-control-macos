#!/usr/bin/env python3
"""Transcription switcher (server 6.72.0): the compiled helper's stt-settings, set-stt-settings and install-parakeet
against a private loopback fixture serving the contract's GET shape (Tests/fixtures/stt-settings-6.72.0.json). No real
server, account, or credentials. Pins: GET and PUT on /api/stt-settings and POST on /api/stt-settings/parakeet/install,
each with the token header; only the contract's keys cross (from stdin, never argv); a 404, a 400 and a 409 are answers
(ok with httpStatus) carrying the server's sentence; an answer that is not the contract shape fails; and the token never
reaches stdout."""
import copy, json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
HELPER = sys.argv[1]
FIXTURE = json.loads(pathlib.Path(sys.argv[2]).read_text())
with tempfile.TemporaryDirectory(prefix='cos-stt-settings-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'd' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    state = {'status': 200, 'body': copy.deepcopy(FIXTURE)}
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
        do_GET = do_PUT = do_POST = do_DELETE = answer
    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))
    def run(command, stdin=None):
        result = subprocess.run([HELPER, command], input=(json.dumps(stdin).encode() if stdin is not None else b''),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=15)
        assert token not in result.stdout.decode() and token not in result.stderr.decode(), 'token leaked'
        return json.loads(result.stdout)
    checks = 0
    def check(value, name):
        global checks
        assert value, name
        checks += 1
    try:
        got = run('stt-settings')
        check(requests[-1] == ('GET', '/api/stt-settings', None), 'GET /api/stt-settings, no body')
        s = got['details']['settings']
        check(got['ok'] and got['details']['httpStatus'] == 200, 'a read is an answer')
        check(s['preview']['selected'] == 'turbo' and [o['id'] for o in s['preview']['options']] == ['turbo', 'large-v3', 'nemotron-560', 'parakeet'], 'preview passes through')
        check(s['preview']['options'][2] == {'id': 'nemotron-560', 'label': 'Nemotron 560', 'available': False, 'experimental': True, 'note': 'Not wired on this server yet'}, 'option fields pass through')
        check(s['frontEnd']['options'][0] == {'id': 'highpass', 'label': None, 'available': True, 'experimental': False, 'note': None}, 'a bare option gets defaults, not invented labels')
        check(s['resolver'] == {'enabled': False, 'effective': False}, 'resolver with effective')
        check(s['parakeet'] == {'installed': False, 'installable': True, 'version': '0.6.3', 'bytes': 0, 'note': 'Parakeet is not installed on this Mac.',
                                'progress': {'state': 'idle', 'bytesDone': 0, 'bytesTotal': 0, 'error': None, 'errorCode': None}, 'warm': {'preview': 'cold'}}, 'parakeet with progress, warm and note')
        check(s['preview']['effective'] == 'turbo' and s['secondOpinion']['effective'] == 'off' and s['frontEnd']['effective'] is None, 'effective passes through, null when absent')
        state['body'] = copy.deepcopy(FIXTURE)
        state['body']['parakeet']['progress'] = {'state': 'exploded', 'bytesDone': -5, 'bytesTotal': 'x', 'error': 'E' * 400}
        state['body']['parakeet']['warm'] = {'preview': 'hot'}
        state['body']['preview']['effective'] = 'bad id; rm'
        state['body']['preview']['reason'] = 'R' * 400
        state['body']['hq']['reason'] = 'Selected engine is unavailable.'
        s = run('stt-settings')['details']['settings']
        check(s['parakeet']['progress'] == {'state': None, 'bytesDone': 0, 'bytesTotal': 0, 'error': 'E' * 200, 'errorCode': None} and s['parakeet']['warm'] == {'preview': None}
              and s['preview']['effective'] is None, 'unknown progress and warm states, bad effective ids and long errors are bounded')
        check(s['preview']['reason'] == 'R' * 200 and s['hq']['reason'] == 'Selected engine is unavailable.', 'lane reasons preserved and bounded')
        state['body'] = copy.deepcopy(FIXTURE)
        check(s['appliesTo'] == {'preview': 'next live chunk', 'hq': 'next saved meeting'}, 'appliesTo')
        state['body']['extra'] = 'dropped'; state['body']['hq']['secret'] = 'x'
        got = run('set-stt-settings', {'hq': 'parakeet-ultra', 'sneak': 'x'})
        check(requests[-1] == ('PUT', '/api/stt-settings', {'hq': 'parakeet-ultra'}), 'PUT carries contract keys only')
        check('extra' not in got['details']['settings'] and 'secret' not in got['details']['settings']['hq'], 'whitelisted answer')
        run('set-stt-settings', {'resolver': False})
        check(requests[-1] == ('PUT', '/api/stt-settings', {'resolver': False}), 'resolver crosses as a bool')
        run('set-stt-settings', {'frontEnd': 'full', 'quietGate': 'rms'})
        check(requests[-1] == ('PUT', '/api/stt-settings', {'frontEnd': 'full', 'quietGate': 'rms'}), 'Advanced keys cross')
        prior = len(requests)
        check(not run('set-stt-settings', {'nope': 'x'})['ok'] and not run('set-stt-settings', {'hq': 7})['ok']
              and not run('set-stt-settings', {'hq': 'bad id; rm'})['ok'] and not run('set-stt-settings', {'resolver': 'yes'})['ok']
              and not run('set-stt-settings', {'resolver': 1})['ok'] and not run('set-stt-settings', {'preview': 'a' * 49})['ok']
              and len(requests) == prior, 'malformed changes never reach the server')
        state['status'] = 202; state['body'] = dict(copy.deepcopy(FIXTURE), started=True)
        got = run('install-parakeet')
        # 0.5.317: the install allows the pinned download (6.74.0); still no localSource.
        check(requests[-1] == ('POST', '/api/stt-settings/parakeet/install', {'allowDownload': True}), 'install is a POST to the install route, no localSource')
        check(got['ok'] and got['details']['httpStatus'] == 202 and got['details']['started'] is True and 'settings' in got['details'], '202 started with the GET shape')
        state['status'] = 200; state['body'] = dict(copy.deepcopy(FIXTURE), started=False)
        got = run('install-parakeet')
        check(got['ok'] and got['details']['httpStatus'] == 200 and got['details']['started'] is False, '200 started:false (already installed) passes through')
        state['status'] = 202; state['body'] = {'ok': True}
        got = run('install-parakeet')
        check(got['ok'] and got['details']['httpStatus'] == 202 and 'settings' not in got['details'], 'a 202 receipt is an answer without settings')
        state['status'] = 200; state['body'] = {'ok': True}
        got = run('stt-settings')
        check(not got['ok'], 'a read that is not the contract shape fails')
        state['status'] = 400; state['body'] = {'error': 'That model is not available on this Mac.'}
        got = run('set-stt-settings', {'hq': 'parakeet-ultra'})
        check(got['ok'] and got['details']['httpStatus'] == 400 and got['details']['error'] == 'That model is not available on this Mac.', '400 is an answer with the server sentence')
        state['status'] = 409; state['body'] = {'error': 'A recording is live. Install Parakeet after it is saved.'}
        got = run('install-parakeet')
        check(got['ok'] and got['details']['httpStatus'] == 409 and got['details']['error'].startswith('A recording is live'), '409 is an answer with the server sentence')
        state['status'] = 404; state['body'] = {'error': 'Not found'}
        got = run('stt-settings')
        check(got['ok'] and got['details']['httpStatus'] == 404, '404 is an answer (older server), not a failure')
        state['status'] = 503; state['body'] = {'error': 'SECRET stack'}
        got = run('stt-settings')
        check(not got['ok'] and 'SECRET' not in json.dumps(got), 'unexpected status fails without the server text')
        # 0.5.317 (server 6.74.0): the Dictation engine, the bundled tool, the install's new answers, and Cancel.
        state['status'] = 200; state['body'] = copy.deepcopy(FIXTURE)
        state['body']['dictation'] = {'desktop': {'selected': 'auto', 'effective': 'whisper', 'reason': 'Parakeet Ultra is not installed.', 'reasonCode': 'parakeet_not_installed',
                                                  'note': 'Dictation uses Whisper until Parakeet Ultra is installed.', 'secret': 'x',
                                                  'options': [{'id': 'auto', 'label': 'Automatic'}, {'id': 'parakeet-ultra', 'available': False, 'note': 'Install Parakeet first.'}, {'id': 'bad id; rm'}]}}
        state['body']['parakeet']['progress']['errorCode'] = 'sha_mismatch'
        state['body']['parakeet']['cli'] = {'trust': 'developer-id', 'reason': None, 'path': '/secret/path'}
        s = run('stt-settings')['details']['settings']
        d = s['dictation']
        check(d['selected'] == 'auto' and d['effective'] == 'whisper' and d['reasonCode'] == 'parakeet_not_installed' and d['note'].startswith('Dictation uses Whisper')
              and 'secret' not in d and [o['id'] for o in d['options']] == ['auto', 'parakeet-ultra'], 'dictation.desktop passes through, whitelisted')
        check(s['parakeet']['progress']['errorCode'] == 'sha_mismatch' and s['parakeet']['cli'] == {'trust': 'developer-id', 'reason': None}, 'errorCode and cli trust pass, nothing else')
        state['body']['parakeet']['progress']['errorCode'] = 'rm -rf'; state['body']['parakeet']['cli'] = {'trust': 'anything', 'reason': 'nope'}
        s = run('stt-settings')['details']['settings']
        check(s['parakeet']['progress']['errorCode'] is None and s['parakeet']['cli'] == {'trust': None, 'reason': None}, 'unknown codes are dropped')
        state['body'] = copy.deepcopy(FIXTURE)
        check('dictation' not in run('stt-settings')['details']['settings'], 'a 6.73.14 answer has no dictation and still reads')
        run('set-stt-settings', {'dictation': 'whisper'})
        check(requests[-1] == ('PUT', '/api/stt-settings', {'dictation': 'whisper'}), 'the engine pick crosses as `dictation`')
        app = home / 'COS Control.app/Contents/Helpers'; app.mkdir(parents=True); cli = app / 'fluidaudiocli'; cli.write_text('#!/bin/sh\n'); cli.chmod(0o755)
        state['status'] = 202; state['body'] = dict(copy.deepcopy(FIXTURE), started=True)
        run('install-parakeet', {'cliPath': str(cli)})
        check(requests[-1] == ('POST', '/api/stt-settings/parakeet/install', {'allowDownload': True, 'cliPath': str(cli)}), 'install passes the bundled tool and allows the pinned download')
        prior = len(requests)
        for bad in [{'cliPath': '/tmp/fluidaudiocli'}, {'cliPath': str(home / 'COS Control.app/Contents/Helpers/../Helpers/fluidaudiocli')}, {'cliPath': 7},
                    {'cliPath': str(home / 'Missing.app/Contents/Helpers/fluidaudiocli')}]:
            got = run('install-parakeet', bad)
            check(not got['ok'] and len(requests) == prior, f'a path that is not an app\'s bundled tool never reaches the server: {bad}')
        state['status'] = 507; state['body'] = {'reason': 'insufficient_disk', 'freeBytes': 900_000_000, 'requiredBytes': 1_500_000_000}
        got = run('install-parakeet')
        check(got['ok'] and got['details']['httpStatus'] == 507 and got['details']['freeBytes'] == 900_000_000 and got['details']['requiredBytes'] == 1_500_000_000, '507 is an answer with the free space')
        state['status'] = 422; state['body'] = {'reason': 'cli_untrusted', 'cli': {'reason': 'wrong_team'}, 'error': 'Untrusted.'}
        got = run('install-parakeet')
        check(got['ok'] and got['details']['httpStatus'] == 422 and got['details']['cliReason'] == 'wrong_team' and got['details']['error'] == 'Untrusted.', '422 names the tool problem')
        state['status'] = 422; state['body'] = {'error': 'x'}
        check(not run('set-stt-settings', {'dictation': 'auto'})['ok'], 'a 422 outside the install is not an answer')
        state['status'] = 200; state['body'] = dict(copy.deepcopy(FIXTURE))
        got = run('cancel-parakeet-install')
        check(requests[-1] == ('DELETE', '/api/stt-settings/parakeet/install', None) and got['ok'] and 'settings' in got['details'], 'Cancel is a DELETE of the install route')
        state['status'] = 200; state['body'] = {'trusted': True, 'trust': 'developer-id', 'teamId': 'NV3X46LLCR', 'version': '0.17.4'}
        got = run('register-parakeet-cli', {'cliPath': str(cli)})
        check(requests[-1] == ('POST', '/api/stt-settings/parakeet/cli', {'cliPath': str(cli)}) and got['details']['trusted'] is True and got['details']['version'] == '0.17.4', 'the bundled tool is registered')
        state['status'] = 422; state['body'] = {'trusted': False, 'reason': 'unsigned'}
        got = run('register-parakeet-cli', {'cliPath': str(cli)})
        check(got['ok'] and got['details']['trusted'] is False and got['details']['reason'] == 'unsigned', 'an untrusted tool is an answer with its reason')
        state['status'] = 404; state['body'] = {}
        check(run('register-parakeet-cli', {'cliPath': str(cli)})['details']['httpStatus'] == 404, 'a server before 6.74.0 is an answer')
        prior = len(requests)
        check(not run('register-parakeet-cli', {})['ok'] and len(requests) == prior, 'register needs a path')
        print(f'PASS Transcription settings helper: {checks} checks')
    finally:
        server.shutdown()
