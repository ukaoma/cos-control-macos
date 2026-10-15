#!/usr/bin/env python3
"""0.5.309 dictionary bridge contract. Synthetic words, loopback fixture, isolated home only."""
import copy, json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-dictionary-bridge-', dir='/tmp'))
home = root / 'home'
(home / '.cos-glasses').mkdir(parents=True, mode=0o700)
token = 'e' * 64
(home / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n')
(home / '.cos-glasses/.env').chmod(0o600)
seen = []
state = {'vocabulary': ['Parakeet', 'Wispr'], 'corrections': {'Myles': 'Miles', 'carrot iq': 'CaratIQ'}, 'negative_rules': []}
entry = {'id': 'c1', 'heard': 'Whisper', 'written': 'Wispr', 'source': 'dictation', 'at': '2026-10-15T23:05:00.000Z',
         'replacedKey': None, 'previous': None, 'addedVocabulary': True}
routes = {'recent': (200, {'entries': [entry, {'id': 7}]}), 'learn': (200, {'unchanged': False, 'entry': entry}), 'undo': (200, {'undone': entry})}
checks = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_PUT(self): self.respond()
    def do_POST(self): self.respond()
    def respond(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/api/health':
            status, body = 200, {'ok': True}
        else:
            seen.append((self.command, self.path, json.loads(data) if data else None))
            if self.headers.get('X-COS-Token') != token:
                status, body = 401, {'error': 'unauthorized'}
            elif self.path == '/api/transcription-glossary' and self.command == 'GET':
                status, body = 200, state
            elif self.path == '/api/transcription-glossary' and self.command == 'PUT':
                patch = json.loads(data)
                state.update({k: v for k, v in patch.items() if k in ('vocabulary', 'corrections')})
                status, body = 200, state
            elif self.path == '/api/transcription-glossary/recent':
                status, body = routes['recent']
            elif self.path == '/api/transcription-glossary/correction':
                status, body = routes['learn']
            elif self.path == '/api/transcription-glossary/correction/undo':
                status, body = routes['undo']
            else:
                status, body = 404, {'error': 'no route'}
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)


server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port))


def check(ok, why):
    global checks
    assert ok, why
    checks += 1


def run(envelope, raw=None):
    data = raw if raw is not None else json.dumps(envelope).encode()
    proc = subprocess.run([helper, 'transcription-dictionary'], input=data, capture_output=True, env=env, timeout=15)
    check(proc.returncode == 0 and not proc.stderr, 'JSON only on stdout; nothing on stderr')
    check(token.encode() not in proc.stdout, 'credential never emitted')
    return json.loads(proc.stdout)


try:
    result = run({'operation': 'get', 'payload': {}})
    details = result['details']
    check(result['ok'] and details['vocabulary'] == ['Parakeet', 'Wispr'], 'vocabulary returned in order')
    check(details['corrections'] == [{'heard': 'carrot iq', 'written': 'CaratIQ'}, {'heard': 'Myles', 'written': 'Miles'}],
          'corrections as heard/written rows, sorted case-insensitively')
    check(details['recent'] == [{k: entry[k] for k in ('id', 'heard', 'written', 'source', 'at')}], 'recent projected; malformed rows dropped')
    check(details['learnAvailable'] is True, 'a 6.73.11 server can learn')
    check(run({'operation': 'get'})['ok'], 'a get may omit the payload')

    before = len(seen)
    result = run({'operation': 'learn', 'payload': {'heard': ' Whisper ', 'written': 'Wispr', 'source': 'dictation'}})
    posts = [s for s in seen[before:] if s[0] == 'POST']
    check(result['ok'] and result['message'] == 'Saved to the dictionary', 'learn reports the save')
    check(posts == [('POST', '/api/transcription-glossary/correction', {'heard': 'Whisper', 'written': 'Wispr', 'source': 'dictation'})],
          'exactly one correction POST, trimmed, with the source')
    routes['learn'] = (200, {'unchanged': True, 'entry': None})
    check(run({'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b', 'source': 'manual'}})['message'] == 'Already in the dictionary', 'unchanged is said plainly')

    routes['learn'] = (400, {'error': 'the written spelling cannot be a URL'})
    result = run({'operation': 'learn', 'payload': {'heard': 'x', 'written': 'y', 'source': 'g2'}})
    check(not result['ok'] and 'cannot be a URL' in result['message'] and result['details']['vocabulary'], 'a refusal says why and keeps the dictionary')
    routes['learn'] = (404, {'error': 'Cannot POST'}); routes['recent'] = (404, {'error': 'Cannot GET'})
    result = run({'operation': 'learn', 'payload': {'heard': 'x', 'written': 'y', 'source': 'meeting'}})
    check(not result['ok'] and '6.73.11' in result['message'] and result['details']['learnAvailable'] is False, 'an older server names the version')
    check(run({'operation': 'get', 'payload': {}})['details']['learnAvailable'] is False, 'no recent log means no Fix a word')
    routes['recent'] = (200, {'entries': [entry]})

    before = len(seen)
    check(run({'operation': 'undo', 'payload': {'id': 'c1'}})['ok'], 'undo succeeds')
    check([s for s in seen[before:] if s[0] == 'POST'] == [('POST', '/api/transcription-glossary/correction/undo', {'id': 'c1'})], 'undo posts only the id')
    routes['undo'] = (409, {'error': 'a newer correction changed "Whisper"'})
    result = run({'operation': 'undo', 'payload': {'id': 'c1'}})
    check(not result['ok'] and 'newer correction' in result['message'], 'a refused undo says why')

    check(run({'operation': 'add-vocabulary', 'payload': {'term': 'Jewel360'}})['details']['vocabulary'] == ['Parakeet', 'Wispr', 'Jewel360'], 'a word is appended')
    run({'operation': 'add-vocabulary', 'payload': {'term': 'wispr'}})
    check(state['vocabulary'] == ['Parakeet', 'Wispr', 'Jewel360'], 'a case variant is not added twice')
    run({'operation': 'remove-vocabulary', 'payload': {'term': 'Parakeet'}})
    check(state['vocabulary'] == ['Wispr', 'Jewel360'], 'a word is removed exactly')
    before = len(seen)
    run({'operation': 'remove-correction', 'payload': {'heard': 'Myles'}})
    puts = [s for s in seen[before:] if s[0] == 'PUT']
    check(puts == [('PUT', '/api/transcription-glossary', {'corrections': {'carrot iq': 'CaratIQ'}})], 'remove-correction PUTs only the corrections map')

    for envelope in [{'operation': 'delete-everything', 'payload': {}},
                     {'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b'}},
                     {'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b', 'source': 'email'}},
                     {'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b', 'source': 'manual', 'path': '/api/x'}},
                     {'operation': 'learn', 'payload': {'heard': 'a' * 101, 'written': 'b', 'source': 'manual'}},
                     {'operation': 'learn', 'payload': {'heard': 'a\nb', 'written': 'b', 'source': 'manual'}},
                     {'operation': 'undo', 'payload': {'id': 5}},
                     {'operation': 'get', 'payload': {}, 'route': '/api/health'}]:
        before = len(seen)
        result = run(envelope)
        check(not result['ok'] and len(seen) == before, 'invalid request refused before any network call')
    before = len(seen)
    check(not run(None, raw=b'{' + b' ' * 5000 + b'}')['ok'] and len(seen) == before, 'oversized stdin refused before network')
    check(not run(None, raw=b'not json')['ok'] and len(seen) == before, 'non-JSON refused before network')
    print(f'PASS dictionary helper: {checks} checks; stdin only, fixed glossary routes, bounded words, version-aware refusals, no credential output')
finally:
    server.shutdown(); shutil.rmtree(root)
