#!/usr/bin/env python3
"""0.5.325 AI polish: the compiled helper's dictation-polish against a loopback finalize fixture. Isolated /tmp home,
synthetic text only, never the live server or token.

What it proves: text rides on stdin and leaves only in a successful answer; the request is the finalize contract with
the token header; the deadline ends a slow model as reason timeout before Control's budget; every failure (bad input,
no token, no server, an HTTP error, a bad answer) is ok:false with a short reason and no text; nothing on stderr.
"""
import json, os, pathlib, shutil, socket, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-dictation-polish-', dir='/tmp'))
home = root / 'home'
(home / '.cos-glasses').mkdir(parents=True, mode=0o700)
token = 'p' * 64
(home / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n')
(home / '.cos-glasses/.env').chmod(0o600)
SECRET = 'Um so the the quarterly plan is ready Niala'
seen = []
answer = {'status': 200, 'body': {'text': 'So the quarterly plan is ready, Niala.', 'surface': 'message', 'polished': True}, 'delay': 0}
# 0.5.329: the prewarm route's own answer (POST start, DELETE discard).
WARM = '0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d'
warm_answer = {'status': 200, 'body': {'token': WARM, 'expiresMs': 150000}, 'delay': 0}
checks = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def do_DELETE(self): self.respond()
    def respond(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        seen.append((self.command, self.path, self.headers, data))
        if self.path == '/api/health':
            # Healthy, as the live server is: a health probe must be caught by the count below, not by a 401 here.
            raw = b'{"ok": true}'
            self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
            return
        reply = warm_answer if self.path.startswith('/api/dictation/polish/prewarm') else answer
        if reply['delay']:
            time.sleep(reply['delay'])
        authenticated = self.headers.get('X-COS-Token') == token
        raw = json.dumps(reply['body'] if authenticated else {'error': 'unauthorized'}).encode() if reply['body'] is not None else b'not json'
        try:
            self.send_response(reply['status'] if authenticated else 401)
            self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port))


def check(ok, why):
    global checks
    assert ok, why
    checks += 1


def run(request, environment=None, timeout=15, verb='dictation-polish'):
    data = request if isinstance(request, bytes) else json.dumps(request).encode()
    started = time.monotonic()
    proc = subprocess.run([helper, verb], input=data, capture_output=True, env=environment or env, timeout=timeout)
    elapsed = time.monotonic() - started
    check(proc.returncode == 0 and not proc.stderr, 'JSON only on stdout; nothing on stderr')
    check(token.encode() not in proc.stdout, 'credential never emitted')
    result = json.loads(proc.stdout)
    if not result['ok']:
        check(SECRET.encode() not in proc.stdout and 'text' not in result['details'], 'a failure carries no text')
        check(isinstance(result['details'].get('reason'), str), 'a failure names its reason')
    return result, elapsed


try:
    # Success: the finalize contract, the token header, the answer and its time.
    result, _ = run({'text': SECRET, 'model': 'haiku', 'app': 'iTerm2'})
    check(result['ok'] and result['details']['text'] == answer['body']['text'] and result['details']['polished'] is True, 'polished text returned')
    check(result['details']['model'] == 'haiku' and isinstance(result['details']['elapsedMs'], int), 'model and elapsed time reported')
    method, path, headers, body = seen[-1]
    check(method == 'POST' and path == '/api/dictation/finalize', 'the fixed finalize route only')
    check(headers.get('X-COS-Token') == token and headers.get('Content-Type') == 'application/json', 'authenticated JSON request')
    check(json.loads(body) == {'text': SECRET, 'surface': 'message', 'autocleanModel': 'haiku', 'context': {'app': 'iTerm2'}}, 'exactly the finalize body')
    check(len([s for s in seen if s[1] == '/api/health']) == 0, 'no health probe spends the budget')

    result, _ = run({'text': SECRET, 'model': 'sonnet'})
    check(json.loads(seen[-1][3]) == {'text': SECRET, 'surface': 'message', 'autocleanModel': 'sonnet'}, 'no context without an app')

    # The server's dictionary-only fallback passes through as polished false; Control decides not to call it polished.
    answer.update(body={'text': SECRET, 'surface': 'message', 'polished': False})
    result, _ = run({'text': SECRET, 'model': 'haiku'})
    check(result['ok'] and result['details']['polished'] is False, 'polished false passes through')

    # Every HTTP failure is a reason, never text.
    for status, reason in [(404, 'needs_server_update'), (413, 'too_long'), (429, 'busy'), (500, 'http_500'), (400, 'http_400')]:
        answer.update(status=status, body={'text': SECRET, 'polished': True, 'error': 'nope'})
        result, _ = run({'text': SECRET, 'model': 'haiku'})
        check(not result['ok'] and result['details']['reason'] == reason and result['details']['httpStatus'] == status, f'{status} is {reason}')
    answer.update(status=200, body=None)
    result, _ = run({'text': SECRET, 'model': 'haiku'})
    check(not result['ok'] and result['details']['reason'] == 'bad_answer', 'unreadable 200 is bad_answer')
    for body in [{'text': SECRET}, {'text': SECRET, 'polished': 1}, {'text': '', 'polished': True}]:
        answer.update(status=200, body=body)
        result, _ = run({'text': SECRET, 'model': 'haiku'})
        check(not result['ok'] and result['details']['reason'] == 'bad_answer', f'malformed 200 refused: {body}')

    # A wrong token is the server's 401.
    wrong = dict(env, COS_CONTROL_TEST_HOME=str(root / 'wrong'))
    (root / 'wrong/.cos-glasses').mkdir(parents=True, mode=0o700)
    (root / 'wrong/.cos-glasses/.env').write_text('COS_API_TOKEN=' + 'w' * 64 + '\n'); (root / 'wrong/.cos-glasses/.env').chmod(0o600)
    answer.update(status=200, body={'text': 'So.', 'polished': True})
    result, _ = run({'text': SECRET, 'model': 'haiku'}, wrong)
    check(not result['ok'] and result['details']['reason'] == 'unauthorized', 'a refused token is unauthorized')

    # The deadline: a model slower than 4.5 s (Haiku) ends as the helper's timeout, inside Control's 5 s budget.
    answer.update(status=200, body={'text': 'So.', 'polished': True}, delay=6)
    result, elapsed = run({'text': SECRET, 'model': 'haiku'})
    check(not result['ok'] and result['details']['reason'] == 'timeout', 'a slow model is a timeout')
    check(4.3 <= elapsed < 5.0, f'the helper answers before the 5 s budget ({elapsed:.2f} s)')
    answer.update(delay=0)

    # Bad input never reaches the network.
    for bad in [{'text': '', 'model': 'haiku'}, {'text': '   ', 'model': 'haiku'}, {'text': 'x' * 8001, 'model': 'haiku'},
                {'text': SECRET, 'model': 'opus'}, {'text': SECRET, 'model': 'haiku', 'surface': 'email'}, {'model': 'haiku'}, b'not json', b'']:
        before = len(seen)
        result, _ = run(bad)
        check(not result['ok'] and result['details']['reason'] == 'invalid_request' and len(seen) == before, f'invalid input refused before the network: {str(bad)[:40]}')
    before = len(seen)
    result, _ = run({'text': 'x' * 8000, 'model': 'haiku'})
    check(result['ok'] and len(seen) == before + 1, '8,000 characters is allowed')

    # No token: no request.
    empty = root / 'empty'; empty.mkdir()
    before = len(seen)
    result, _ = run({'text': SECRET, 'model': 'haiku'}, dict(env, COS_CONTROL_TEST_HOME=str(empty)))
    check(not result['ok'] and result['details']['reason'] == 'no_token' and len(seen) == before, 'no token, nothing sent')

    # No server: a closed port answers quickly as unreachable.
    probe = socket.socket(); probe.bind(('127.0.0.1', 0)); closed = probe.getsockname()[1]; probe.close()
    result, elapsed = run({'text': SECRET, 'model': 'sonnet'}, dict(env, COS_CONTROL_TEST_API_PORT=str(closed)))
    check(not result['ok'] and result['details']['reason'] == 'unreachable' and elapsed < 3, 'no server is unreachable, at once')

    # 0.5.329 (server 6.79.2): the token rides on finalize; a malformed one is dropped; what became of it comes back.
    answer.update(status=200, body={'text': 'So.', 'polished': True, 'prewarm': 'used'}, delay=0)
    result, _ = run({'text': SECRET, 'model': 'haiku', 'prewarmToken': WARM})
    check(json.loads(seen[-1][3]) == {'text': SECRET, 'surface': 'message', 'autocleanModel': 'haiku', 'prewarmToken': WARM}, 'the token rides on finalize')
    check(result['ok'] and result['details']['prewarm'] == 'used', 'prewarm used comes back')
    result, _ = run({'text': SECRET, 'model': 'haiku', 'prewarmToken': '../../api/x'})
    check(result['ok'] and 'prewarmToken' not in json.loads(seen[-1][3]), 'a malformed token is dropped, the polish still runs')

    # dictation-polish-prewarm: start (POST, the model and the message surface only) and discard (DELETE that token).
    def prewarm(request, environment=None):
        return run(request, environment, verb='dictation-polish-prewarm')
    before = len(seen)
    result, elapsed = prewarm({'model': 'haiku'})
    method, path, headers, body = seen[-1]
    check(result['ok'] and result['details']['prewarmToken'] == WARM and result['details']['expiresMs'] == 150000, 'a started process answers its token')
    check(method == 'POST' and path == '/api/dictation/polish/prewarm' and json.loads(body) == {'model': 'haiku', 'surface': 'message'}
          and headers.get('X-COS-Token') == token and len(seen) == before + 1, 'one authenticated start with the model only, no health probe')
    for status, body, reason in [(409, {'error': 'prewarm_unavailable', 'reason': 'breaker_open'}, 'breaker_open'),
                                 (409, {'error': 'prewarm_unavailable', 'reason': 'daily_cap'}, 'daily_cap'),
                                 (409, {'error': 'x', 'reason': 'something else'}, 'refused'),
                                 (404, {'error': 'not found'}, 'unsupported'), (500, {'error': 'x'}, 'http_500'),
                                 (200, {'token': 'nope', 'expiresMs': 1}, 'bad_answer')]:
        warm_answer.update(status=status, body=body)
        result, _ = prewarm({'model': 'sonnet'})
        check(not result['ok'] and result['details']['reason'] == reason and 'prewarmToken' not in result['details'], f'prewarm {status} is {reason}')
    warm_answer.update(status=200, body={'token': WARM, 'expiresMs': 150000}, delay=4)
    result, elapsed = prewarm({'model': 'haiku'})
    check(not result['ok'] and result['details']['reason'] == 'timeout' and 1.8 <= elapsed < 2.5, f'a slow start ends at the 2 s deadline ({elapsed:.2f} s)')
    warm_answer.update(status=200, body={'discarded': True}, delay=0)
    result, _ = prewarm({'discard': WARM})
    method, path, _, _ = seen[-1]
    check(result['ok'] and result['details']['discarded'] is True and method == 'DELETE' and path == '/api/dictation/polish/prewarm/' + WARM,
          'a discard deletes exactly that token')
    for bad in [{'model': 'opus'}, {'model': 'haiku', 'text': SECRET}, {'discard': '../../api/health'}, {}, b'not json']:
        before = len(seen)
        result, _ = prewarm(bad)
        check(not result['ok'] and result['details']['reason'] == 'invalid_request' and len(seen) == before, f'prewarm input refused before the network: {str(bad)[:40]}')
    before = len(seen)
    result, _ = prewarm({'model': 'haiku'}, dict(env, COS_CONTROL_TEST_HOME=str(empty)))
    check(not result['ok'] and result['details']['reason'] == 'no_token' and len(seen) == before, 'prewarm: no token, nothing sent')
    result, elapsed = prewarm({'model': 'haiku'}, dict(env, COS_CONTROL_TEST_API_PORT=str(closed)))
    check(not result['ok'] and result['details']['reason'] == 'unreachable' and elapsed < 2.5, 'prewarm: no server is unreachable, at once')

    print(f'PASS dictation polish helper: {checks} checks; finalize contract, stdin only, deadline inside the budget, every failure a reason without text, early polish start and discard')
finally:
    server.shutdown(); shutil.rmtree(root)
