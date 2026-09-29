#!/usr/bin/env python3
"""Exercise the compiled helper's Jev key and session-recommendation commands against a loopback fixture.

Usage: work-jev-helper-checks.py <compiled cos-control-helper>. Never the live service; the key never leaves stdin.
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-jev-helper-', dir='/tmp'))
token, KEY = 'a' * 64, 'ts_live_' + 'k' * 32
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)
calls, state = [], {'status': 200, 'rec': 200, 'set': (200, None)}
STATUS = {'configured': True, 'source': 'config', 'usedToday': 12000, 'dailyCap': 1000000, 'breakerOpenUntil': None, 'lastError': None}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n)) if n else None
    def do_GET(self):
        assert self.headers.get('X-COS-Token') == token
        calls.append(('GET', self.path, None))
        self.reply(state['status'], STATUS if state['status'] == 200 else {})
    def do_POST(self):
        assert self.headers.get('X-COS-Token') == token
        data = self.body(); calls.append(('POST', self.path, data))
        if self.path == '/api/work-board/session-recommendation':
            return self.reply(state['rec'], {'provider': 'jev', 'action': 'continue', 'sessionId': 'claude:b', 'confidence': 0.91} if state['rec'] == 200
                              else state.get('recBody', {}))
        status, message = state['set']
        self.reply(status, STATUS | {'ok': True} if status == 200 else {'error': {'code': 'jev_key_not_accepted', 'message': message}})
    def do_DELETE(self):
        assert self.headers.get('X-COS-Token') == token
        calls.append(('DELETE', self.path, None)); self.reply(200, STATUS | {'configured': False, 'source': 'none', 'ok': True})

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
for k in ('COS_WORK_CONNECTED_TEST', 'COS_WORK_REVIEW_CANDIDATE_PORT', 'COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE'): env.pop(k, None)
def run(args, data=None):
    out = subprocess.run([helper, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=20)
    assert KEY.encode() not in out.stdout and KEY.encode() not in out.stderr, 'The key must never be printed'
    return json.loads(out.stdout)
try:
    good = {'domain': 'quilt', 'id': 'a' * 12, 'sessions': [{'id': 'claude:b', 'provider': 'claude', 'title': 'Server work'}]}
    r = run(['work-session-recommend'], json.dumps(good).encode())
    assert r['ok'] and r['details']['action'] == 'continue' and calls[-1] == ('POST', '/api/work-board/session-recommendation', good), (r, calls[-1])
    for status, reason in ((404, 'server_too_old'), (500, 'http_500')):  # advice only: never an error
        state['rec'] = status
        r = run(['work-session-recommend'], json.dumps(good).encode())
        assert r['ok'] and r['details'] == {'provider': 'none', 'reason': reason}, r
    # 0.5.243: the server's own code comes through (a renamed task is not an old server); a bare 404 still is.
    for status, body, reason in ((404, {'error': {'code': 'task_not_found'}}, 'task_not_found'), (404, {'error': {'code': 'review_not_found'}}, 'review_not_found'),
                                 (400, {'error': {'code': 'invalid_recommendation_request'}}, 'invalid_recommendation_request'),
                                 (404, {'error': {'code': 'NOT A CODE; rm -rf'}}, 'server_too_old'), (404, {}, 'server_too_old')):
        state['rec'], state['recBody'] = status, body
        r = run(['work-session-recommend'], json.dumps(good).encode())
        assert r['ok'] and r['details'] == {'provider': 'none', 'reason': reason}, (status, body, r)
    state['rec'], state['recBody'] = 200, {}
    # A meeting review is named by its id alone (server 6.57.1), passed through unchanged.
    review = {'reviewId': 'wr_' + 'a' * 32, 'sessions': good['sessions']}
    r = run(['work-session-recommend'], json.dumps(review).encode())
    assert r['ok'] and r['details']['action'] == 'continue' and calls[-1] == ('POST', '/api/work-board/session-recommendation', review), (r, calls[-1])
    before = len(calls)
    for bad in (dict(review, reviewId='wr_x'), dict(review, reviewId='wr_' + 'A' * 32), dict(review, domain='quilt'), dict(review, id='a' * 12),
                dict(review, text='inject'), {'reviewId': review['reviewId']}):
        assert not run(['work-session-recommend'], json.dumps(bad).encode())['ok'], bad
    assert len(calls) == before, 'No malformed review request reaches the server'
    # A 6.57.0 server refuses the review body as invalid: that reads as an old server, for reviews only.
    state['rec'], state['recBody'] = 400, {'error': {'code': 'invalid_recommendation_request'}}
    assert run(['work-session-recommend'], json.dumps(review).encode())['details'] == {'provider': 'none', 'reason': 'server_too_old'}
    assert run(['work-session-recommend'], json.dumps(good).encode())['details'] == {'provider': 'none', 'reason': 'invalid_recommendation_request'}
    state['rec'], state['recBody'] = 200, {}
    before = len(calls)
    for bad in (dict(good, text='inject'), dict(good, id='nope'), dict(good, domain='../x'),
                dict(good, sessions=[{'id': str(i), 'title': 't'} for i in range(81)]), {'domain': 'quilt', 'id': 'a' * 12}):
        assert not run(['work-session-recommend'], json.dumps(bad).encode())['ok']
    assert not run(['work-session-recommend'], b' ' * 65537)['ok'] and len(calls) == before, 'No invalid request reaches the server'

    s = run(['jev-status'])
    assert s['ok'] and s['details']['available'] is True and s['details']['usedToday'] == 12000 and calls[-1][:2] == ('GET', '/api/jev-key/status')
    state['status'] = 404
    assert run(['jev-status'])['details'] == {'available': False}
    state['status'] = 200

    saved = run(['jev-key-set'], json.dumps({'key': KEY}).encode())
    assert saved['ok'] and calls[-1] == ('POST', '/api/jev-key/set', {'key': KEY})
    state['set'] = (400, 'TypeSafe did not accept this key.')
    refused = run(['jev-key-set'], json.dumps({'key': KEY}).encode())
    assert not refused['ok'] and refused['message'] == 'TypeSafe did not accept this key.', refused
    state['set'] = (404, None)
    assert 'needs server 6.57.0' in run(['jev-key-set'], json.dumps({'key': KEY}).encode())['message']
    before = len(calls)
    for bad in ({}, {'key': ''}, {'key': KEY, 'extra': 1}):
        assert not run(['jev-key-set'], json.dumps(bad).encode())['ok']
    assert not run(['jev-key-set'], b' ' * 2049)['ok'] and len(calls) == before

    cleared = run(['jev-key-clear'])
    assert cleared['ok'] and calls[-1][:2] == ('DELETE', '/api/jev-key') and cleared['details']['configured'] is False
    print('PASS compiled helper: session recommendation passthrough and advice-only failures, bounded input, Jev status (404 = older server), key set/refusal/older server, key never printed, key clear')
finally:
    server.shutdown(); shutil.rmtree(root)
