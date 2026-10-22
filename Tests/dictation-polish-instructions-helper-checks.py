#!/usr/bin/env python3
"""0.5.335 (server 6.85.0) Your polish instructions: the compiled helper's dictation-polish-instructions against a
loopback fixture, and the instructions flag on dictation-polish. Isolated /tmp home, synthetic text only, never the
live server or token.

What it proves: the words ride on stdin and leave only in a PUT body to the setting's own route; get asks the public
health capability first and never calls the setting on a server that does not advertise it (available false: Control
hides the box); set, clear and rules use exactly their routes with the token header; every HTTP failure is a reason
with no text; bad input never reaches the network; finalize's customInstructions and instructionsHash pass through
only as a JSON true and 8 hex characters; nothing on stderr.
"""
import json, os, pathlib, shutil, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-polish-instructions-', dir='/tmp'))
home = root / 'home'
(home / '.cos-glasses').mkdir(parents=True, mode=0o700)
token = 'q' * 64
(home / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n')
(home / '.cos-glasses/.env').chmod(0o600)
WORDS = 'Use Oxford commas.\nWrite product names as Bottle POS and IT Retail.'
HASH = '0a1b2c3d'
seen = []
CAPABLE = {'ok': True, 'capabilities': {'dictationCleanup': {'models': ['haiku'], 'customInstructions': {'protocol': 1, 'maxChars': 1000}}}}
health = {'status': 200, 'body': CAPABLE}
setting = {'status': 200, 'body': {'customInstructions': WORDS, 'enabled': True, 'instructionsHash': HASH, 'maxChars': 1000}}
RULES = {'version': 'v3', 'defaultVersion': 'v3', 'rolledBack': False, 'systemPrompt': 'You clean dictated text.',
         'rules': 'You are cleaning up a dictated prompt or message before it is sent.', 'userBlock': 'User style preferences: ...', 'maxChars': 1000}
rules = {'status': 200, 'body': RULES}
finalize = {'status': 200, 'body': {'text': 'Send the deck, notes, and plan.', 'surface': 'message', 'polished': True}}
checks = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_PUT(self): self.respond()
    def do_POST(self): self.respond()
    def do_DELETE(self): self.respond()
    def respond(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        seen.append((self.command, self.path, self.headers, data))
        if self.path == '/api/health':
            reply = health
            authenticated = True
        else:
            reply = rules if self.path == '/api/dictation/polish/rules' else finalize if self.path == '/api/dictation/finalize' else setting
            authenticated = self.headers.get('X-COS-Token') == token
        raw = json.dumps(reply['body'] if authenticated else {'error': 'unauthorized'}).encode() if reply['body'] is not None else b'not json'
        self.send_response(reply['status'] if authenticated else 401)
        self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port))


def check(ok, why):
    global checks
    assert ok, why
    checks += 1


def run(request, environment=None, verb='dictation-polish-instructions'):
    data = request if isinstance(request, bytes) else json.dumps(request).encode()
    proc = subprocess.run([helper, verb], input=data, capture_output=True, env=environment or env, timeout=20)
    check(proc.returncode == 0 and not proc.stderr, 'JSON only on stdout; nothing on stderr')
    check(token.encode() not in proc.stdout, 'credential never emitted')
    result = json.loads(proc.stdout)
    if not result['ok']:
        check(b'Oxford' not in proc.stdout and 'customInstructions' not in result['details'], 'a failure carries no text')
        check(isinstance(result['details'].get('reason'), str), 'a failure names its reason')
    return result


try:
    # get on a capable server: the public capability, then the authenticated setting.
    before = len(seen)
    result = run({'operation': 'get'})
    calls = seen[before:]
    check([(c[0], c[1]) for c in calls] == [('GET', '/api/health'), ('GET', '/api/dictation/polish/instructions')], 'get reads the capability, then the setting')
    check(calls[1][2].get('X-COS-Token') == token, 'the setting is read with the token')
    check(result['ok'] and result['details'] == {'available': True, 'customInstructions': WORDS, 'maxChars': 1000, 'instructionsHash': HASH},
          'get answers the saved words, the cap and the hash')

    # An older server: no capability, so the setting is never asked for, and Control hides the box.
    for old in [{'ok': True, 'capabilities': {'dictationCleanup': {'models': ['haiku']}}}, {'ok': True},
                {'capabilities': {'dictationCleanup': {'customInstructions': {'protocol': 0, 'maxChars': 1000}}}},
                {'capabilities': {'dictationCleanup': {'customInstructions': {'protocol': 1}}}}]:
        health.update(body=old)
        before = len(seen)
        result = run({'operation': 'get'})
        check(result['ok'] and result['details'] == {'available': False} and [c[1] for c in seen[before:]] == ['/api/health'],
              f'no capability, no setting call: {str(old)[:60]}')
    health.update(body=CAPABLE)
    # A server that advertises it but answers 404 (a mismatched build) also reads as no box.
    setting.update(status=404, body={'error': 'not found'})
    result = run({'operation': 'get'})
    check(result['ok'] and result['details'] == {'available': False}, 'a 404 from the setting is no box')
    setting.update(status=200, body={'customInstructions': WORDS, 'enabled': True, 'instructionsHash': HASH, 'maxChars': 1000})

    # set: exactly one authenticated PUT whose body is the words and nothing else; no health probe.
    before = len(seen)
    result = run({'operation': 'set', 'customInstructions': WORDS})
    method, path, headers, body = seen[-1]
    check(len(seen) == before + 1 and method == 'PUT' and path == '/api/dictation/polish/instructions', 'set is one PUT to the setting')
    check(headers.get('X-COS-Token') == token and headers.get('Content-Type') == 'application/json' and json.loads(body) == {'customInstructions': WORDS},
          'set sends exactly the words, authenticated')
    check(result['ok'] and result['message'] == 'Saved' and result['details']['customInstructions'] == WORDS, 'set answers what the server saved')

    # clear: one DELETE.
    setting.update(body={'customInstructions': '', 'enabled': False, 'instructionsHash': '', 'maxChars': 1000})
    result = run({'operation': 'clear'})
    method, path, _, body = seen[-1]
    check(method == 'DELETE' and path == '/api/dictation/polish/instructions' and body == b'', 'clear is one DELETE with no body')
    check(result['ok'] and result['message'] == 'Cleared' and result['details'] == {'available': True, 'customInstructions': '', 'maxChars': 1000},
          'clear answers off, with no hash')

    # rules: the version and the text, nothing else of the server's answer.
    result = run({'operation': 'rules'})
    method, path, headers, _ = seen[-1]
    check(method == 'GET' and path == '/api/dictation/polish/rules' and headers.get('X-COS-Token') == token, 'rules is one authenticated GET')
    check(result['ok'] and result['details'] == {'available': True, 'version': 'v3', 'rolledBack': False, 'rules': RULES['rules'], 'userBlock': RULES['userBlock']},
          'rules answers the version, rolled back, the rules and the block')
    rules.update(body=dict(RULES, version='v2', rolledBack=True))
    check(run({'operation': 'rules'})['details']['rolledBack'] is True, 'rolled back passes through')
    for bad in [dict(RULES, version='v3; rm -rf'), dict(RULES, rules=''), dict(RULES, rules='x' * 20001), dict(RULES, rolledBack=None, version=7)]:
        rules.update(body=bad)
        result = run({'operation': 'rules'})
        check(not result['ok'] and result['details']['reason'] == 'bad_answer', f'an unreadable rules answer is refused: {str(bad)[:50]}')
    rules.update(status=404, body={'error': 'x'})
    check(run({'operation': 'rules'})['details'] == {'available': False}, 'rules on an older server is no box')
    rules.update(status=200, body=RULES)

    # Every HTTP failure of set is a reason, never the words.
    for status, reason in [(413, 'too_long'), (400, 'invalid'), (500, 'http_500'), (503, 'http_503')]:
        setting.update(status=status, body={'customInstructions': WORDS, 'error': 'nope'})
        result = run({'operation': 'set', 'customInstructions': WORDS})
        check(not result['ok'] and result['details']['reason'] == reason and result['details']['httpStatus'] == status, f'{status} is {reason}')
    for body in [None, {'customInstructions': 7}, {'customInstructions': 'x' * 1001}, {}]:
        setting.update(status=200, body=body)
        result = run({'operation': 'get'})
        check(not result['ok'] and result['details']['reason'] == 'bad_answer', f'an unreadable setting is refused: {str(body)[:40]}')
    setting.update(status=200, body={'customInstructions': WORDS, 'instructionsHash': 'NOT-HEX', 'maxChars': 1000})
    check('instructionsHash' not in run({'operation': 'get'})['details'], 'a hash that is not 8 hex is dropped')

    # A wrong token is the server's 401.
    wrong = dict(env, COS_CONTROL_TEST_HOME=str(root / 'wrong'))
    (root / 'wrong/.cos-glasses').mkdir(parents=True, mode=0o700)
    (root / 'wrong/.cos-glasses/.env').write_text('COS_API_TOKEN=' + 'w' * 64 + '\n'); (root / 'wrong/.cos-glasses/.env').chmod(0o600)
    result = run({'operation': 'set', 'customInstructions': WORDS}, wrong)
    check(not result['ok'] and result['details']['reason'] == 'unauthorized', 'a refused token is unauthorized')

    # Bad input never reaches the network.
    for bad in [{'operation': 'set'}, {'operation': 'set', 'customInstructions': '   '}, {'operation': 'set', 'customInstructions': 'x' * 8001},
                {'operation': 'set', 'customInstructions': WORDS, 'extra': 1}, {'operation': 'get', 'customInstructions': WORDS},
                {'operation': 'delete'}, {'operation': 'set', 'customInstructions': 7}, {}, b'not json', b'']:
        before = len(seen)
        result = run(bad)
        check(not result['ok'] and result['details']['reason'] == 'invalid_request' and len(seen) == before, f'invalid input refused before the network: {str(bad)[:40]}')

    # No token: nothing sent. No server: unreachable, at once.
    empty = root / 'empty'; empty.mkdir()
    before = len(seen)
    result = run({'operation': 'get'}, dict(env, COS_CONTROL_TEST_HOME=str(empty)))
    check(not result['ok'] and result['details']['reason'] == 'no_token' and len(seen) == before, 'no token, nothing sent')
    probe = socket.socket(); probe.bind(('127.0.0.1', 0)); closed = probe.getsockname()[1]; probe.close()
    for op in [{'operation': 'get'}, {'operation': 'set', 'customInstructions': WORDS}]:
        result = run(op, dict(env, COS_CONTROL_TEST_API_PORT=str(closed)))
        check(not result['ok'] and result['details']['reason'] == 'unreachable', f'no server is unreachable: {op["operation"]}')

    # dictation-polish: the flag passes through only as a JSON true, the hash only as 8 hex; never the words.
    def polish():
        return run({'text': 'send the deck notes and plan', 'model': 'haiku'}, verb='dictation-polish')
    finalize.update(body={'text': 'Send the deck, notes, and plan.', 'polished': True, 'customInstructions': True, 'instructionsHash': HASH})
    result = polish()
    check(result['ok'] and result['details']['customInstructions'] is True and result['details']['instructionsHash'] == HASH, 'finalize: flag and hash pass through')
    for body, why in [({'customInstructions': 1, 'instructionsHash': HASH}, 'a 1 is not true'), ({'customInstructions': False, 'instructionsHash': HASH}, 'false is absent'),
                      ({'customInstructions': 'true'}, 'a string is not true'), ({}, 'an older server says nothing')]:
        finalize.update(body=dict({'text': 'Send it.', 'polished': True}, **body))
        result = polish()
        check(result['ok'] and 'customInstructions' not in result['details'] and 'instructionsHash' not in result['details'], f'finalize: {why}')
    finalize.update(body={'text': 'Send it.', 'polished': True, 'customInstructions': True, 'instructionsHash': 'Oxford commas'})
    result = polish()
    check(result['details']['customInstructions'] is True and 'instructionsHash' not in result['details'], 'finalize: a hash that is not 8 hex is dropped')

    print(f'PASS polish instructions helper: {checks} checks; capability first, set/clear/rules routes, stdin only, every failure a reason without text, finalize flag and hash')
finally:
    server.shutdown(); shutil.rmtree(root)
