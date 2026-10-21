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
routes = {'recent': (200, {'entries': [entry, {'id': 7}]}), 'learn': (200, {'unchanged': False, 'entry': entry}), 'undo': (200, {'undone': entry}),
          'single': 200, 'glossary': 200}
# The server's MAX_TERM_LEN (server/lib/glossary-learn.ts) in UTF-16 units; the helper's dictionaryMaxTermUTF16 must match.
MAX_TERM_LEN = 100
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
                status, body = (200, state) if routes['glossary'] == 200 else (routes['glossary'], {'error': 'down'})
            elif self.path in ('/api/transcription-glossary/vocabulary/add', '/api/transcription-glossary/vocabulary/remove',
                               '/api/transcription-glossary/correction/remove'):
                patch = json.loads(data)
                if routes['single'] != 200:
                    status, body = routes['single'], {'error': 'Cannot POST'}
                else:
                    before = copy.deepcopy(state)
                    if self.path.endswith('/vocabulary/add'):
                        if not any(t.lower() == patch['term'].lower() for t in state['vocabulary']): state['vocabulary'].append(patch['term'])
                    elif self.path.endswith('/vocabulary/remove'):
                        state['vocabulary'] = [t for t in state['vocabulary'] if t != patch['term']]
                    else:
                        state['corrections'].pop(patch['heard'], None)
                    status, body = 200, {'unchanged': before == state, 'glossary': state}
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
    check('note' not in result['details'] and 'correctionOnly' not in result['details'], 'a plain learn carries no correction-only note')
    # 0.5.334 (server 6.83.1): a link, email or path is kept as a correction only; the server's note reaches Control.
    note = 'Saved as a correction. Links, emails and paths are never added to the words that guide transcription, so COS rewrites what it hears instead.'
    routes['learn'] = (200, {'unchanged': False, 'entry': entry, 'correctionOnly': True, 'note': note})
    result = run({'operation': 'learn', 'payload': {'heard': 'forward slash pricing', 'written': '/pricing', 'source': 'dictation'}})
    check(result['ok'] and result['details'].get('correctionOnly') is True and result['details'].get('note') == note and result['details']['vocabulary'],
          'a correction-only learn passes the server note on with the dictionary')
    routes['glossary'] = 503
    result = run({'operation': 'learn', 'payload': {'heard': 'forward slash pricing', 'written': '/pricing', 'source': 'dictation'}})
    check(result['ok'] and result['details'].get('stale') is True and result['details'].get('note') == note, 'the note survives a failed read-back')
    routes['glossary'] = 200
    routes['learn'] = (200, {'unchanged': False, 'entry': entry, 'correctionOnly': False, 'note': note})
    check('note' not in run({'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b', 'source': 'manual'}})['details'], 'a note without correctionOnly is not passed on')
    routes['learn'] = (200, {'unchanged': True, 'entry': None})
    check(run({'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b', 'source': 'manual'}})['message'] == 'Already in the dictionary', 'unchanged is said plainly')

    routes['learn'] = (400, {'error': 'the written spelling cannot be a URL'})
    result = run({'operation': 'learn', 'payload': {'heard': 'x', 'written': 'y', 'source': 'g2'}})
    check(not result['ok'] and 'cannot be a URL' in result['message'] and result['details']['vocabulary'], 'a refusal says why and keeps the dictionary')
    routes['learn'] = (404, {'error': 'Cannot POST'}); routes['recent'] = (404, {'error': 'Cannot GET'})
    result = run({'operation': 'learn', 'payload': {'heard': 'x', 'written': 'y', 'source': 'meeting'}})
    check(not result['ok'] and '6.73.12' in result['message'] and result['details']['learnAvailable'] is False, 'an older server names the version it needs (6.73.12, the helper\'s one update line)')
    check(run({'operation': 'get', 'payload': {}})['details']['learnAvailable'] is False, 'no recent log means no Fix a word')
    routes['recent'] = (200, {'entries': [entry]})

    before = len(seen)
    check(run({'operation': 'undo', 'payload': {'id': 'c1'}})['ok'], 'undo succeeds')
    check([s for s in seen[before:] if s[0] == 'POST'] == [('POST', '/api/transcription-glossary/correction/undo', {'id': 'c1'})], 'undo posts only the id')
    routes['undo'] = (409, {'error': 'a newer correction changed "Whisper"'})
    result = run({'operation': 'undo', 'payload': {'id': 'c1'}})
    check(not result['ok'] and 'newer correction' in result['message'], 'a refused undo says why')

    # 6.73.12: single items go to their own atomic routes; the helper never reads the map and writes it back.
    before = len(seen)
    result = run({'operation': 'add-vocabulary', 'payload': {'term': 'Jewel360'}})
    check(result['details']['vocabulary'] == ['Parakeet', 'Wispr', 'Jewel360'] and result['message'] == 'Word added', 'a word is added')
    check([s for s in seen[before:] if s[0] != 'GET'] == [('POST', '/api/transcription-glossary/vocabulary/add', {'term': 'Jewel360'})],
          'exactly one atomic add, no PUT of the whole dictionary')
    result = run({'operation': 'add-vocabulary', 'payload': {'term': 'wispr'}})
    check(state['vocabulary'] == ['Parakeet', 'Wispr', 'Jewel360'] and result['message'] == 'Already in the dictionary'
          and result['details']['unchanged'] is True, 'a case variant is not added twice, and says so')
    run({'operation': 'remove-vocabulary', 'payload': {'term': 'Parakeet'}})
    check(state['vocabulary'] == ['Wispr', 'Jewel360'], 'a word is removed exactly')
    before = len(seen)
    run({'operation': 'remove-correction', 'payload': {'heard': 'Myles'}})
    check([s for s in seen[before:] if s[0] != 'GET'] == [('POST', '/api/transcription-glossary/correction/remove', {'heard': 'Myles'})],
          'remove-correction is one atomic POST')
    check(state['corrections'] == {'carrot iq': 'CaratIQ'}, 'only that correction went')

    # An older server: single edits say which version; a hand-added correction still saves the old way.
    routes['single'] = 404; routes['learn'] = (404, {'error': 'Cannot POST'})
    before = len(seen)
    result = run({'operation': 'add-vocabulary', 'payload': {'term': 'Bottle POS'}})
    check(not result['ok'] and '6.73.12' in result['message'] and not [s for s in seen[before:] if s[0] == 'PUT'], 'no PUT fallback for single edits')
    before = len(seen)
    result = run({'operation': 'learn', 'payload': {'heard': 'Santi', 'written': 'Sante HQ', 'source': 'manual'}})
    puts = [s for s in seen[before:] if s[0] == 'PUT']
    check(result['ok'] and len(puts) == 1 and puts[0][2]['corrections']['Santi'] == 'Sante HQ' and 'Sante HQ' in puts[0][2]['vocabulary'],
          'a hand-added correction falls back to the whole-dictionary write on an older server')
    before = len(seen)
    result = run({'operation': 'learn', 'payload': {'heard': 'x', 'written': 'y', 'source': 'dictation'}})
    check(not result['ok'] and '6.73.12' in result['message'] and not [s for s in seen[before:] if s[0] == 'PUT'], 'Fix a word never falls back')
    routes['single'] = 200; routes['learn'] = (200, {'unchanged': False, 'entry': entry})

    # A save that worked stays a success when the read-back fails.
    routes['glossary'] = 503
    result = run({'operation': 'learn', 'payload': {'heard': 'Whisper', 'written': 'Wispr', 'source': 'dictation'}})
    check(result['ok'] and result['details'].get('stale') is True and 'vocabulary' not in result['details'], 'stale, not failed')
    routes['glossary'] = 200

    # Length is UTF-16 units, as on the server: 50 emoji are exactly MAX_TERM_LEN; 51 are refused before the network.
    check(run({'operation': 'add-vocabulary', 'payload': {'term': '\U0001F600' * (MAX_TERM_LEN // 2)}})['ok'], 'exactly MAX_TERM_LEN UTF-16 units accepted')
    before = len(seen)
    check(not run({'operation': 'add-vocabulary', 'payload': {'term': '\U0001F600' * (MAX_TERM_LEN // 2 + 1)}})['ok'] and len(seen) == before,
          'one UTF-16 unit over is refused before the network')

    for envelope in [{'operation': 'delete-everything', 'payload': {}},
                     {'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b'}},
                     {'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b', 'source': 'email'}},
                     {'operation': 'learn', 'payload': {'heard': 'a', 'written': 'b', 'source': 'manual', 'path': '/api/x'}},
                     {'operation': 'learn', 'payload': {'heard': 'a' * (MAX_TERM_LEN + 1), 'written': 'b', 'source': 'manual'}},
                     {'operation': 'learn', 'payload': {'heard': 'a\nb', 'written': 'b', 'source': 'manual'}},
                     {'operation': 'undo', 'payload': {'id': 5}},
                     {'operation': 'get', 'payload': {}, 'route': '/api/health'}]:
        before = len(seen)
        result = run(envelope)
        check(not result['ok'] and len(seen) == before, 'invalid request refused before any network call')
    before = len(seen)
    check(not run(None, raw=b'{' + b' ' * 5000 + b'}')['ok'] and len(seen) == before, 'oversized stdin refused before network')
    check(not run(None, raw=b'not json')['ok'] and len(seen) == before, 'non-JSON refused before network')
    # 0.5.323 seam: dictionary suggestions from the server (6.77.0) answer dormant and send nothing, valid or not.
    def suggestions(envelope, raw=None):
        data = raw if raw is not None else json.dumps(envelope).encode()
        proc = subprocess.run([helper, 'dictionary-suggestions'], input=data, capture_output=True, env=env, timeout=15)
        check(proc.returncode == 0 and not proc.stderr and token.encode() not in proc.stdout, 'suggestions: JSON only, no credential')
        return json.loads(proc.stdout)
    for envelope in [{'operation': 'list', 'payload': {}}, {'operation': 'list'}, {'operation': 'accept', 'payload': {'id': 'sug_0123456789abcdef'}},
                     {'operation': 'dismiss', 'payload': {'id': 'sug_fedcba9876543210'}}]:
        before = len(seen)
        result = suggestions(envelope)
        check(not result['ok'] and result['details'].get('dormant') is True and '6.77.0' in result['message'] and len(seen) == before,
              f'the suggestions seam is dormant and sends nothing: {envelope}')
    for envelope in [{'operation': 'accept', 'payload': {'id': 'sug_../../../x/abcde'}}, {'operation': 'accept', 'payload': {}},
                     {'operation': 'dismiss', 'payload': {'id': 'sug_0123456789ABCDEF'}}, {'operation': 'dismiss', 'payload': {'id': 'sug_0123'}},
                     {'operation': 'accept', 'payload': {'id': 'abc_0123456789abcdef'}}, {'operation': 'list', 'payload': {'status': 'all'}},
                     {'operation': 'purge', 'payload': {}}]:
        before = len(seen)
        result = suggestions(envelope)
        check(not result['ok'] and 'dormant' not in result.get('details', {}) and result['message'] == 'Dictionary suggestion request is invalid.'
              and len(seen) == before, f'an invalid suggestions request is refused: {envelope}')
    check(not suggestions(None, raw=b'{' + b' ' * 2000 + b'}')['ok'], 'oversized suggestions stdin refused')
    print(f'PASS dictionary helper: {checks} checks; stdin only, fixed glossary routes, bounded words, version-aware refusals, no credential output, dormant suggestions seam')
finally:
    server.shutdown(); shutil.rmtree(root)
