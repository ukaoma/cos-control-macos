#!/usr/bin/env python3
"""0.5.259: the compiled helper's work-search command and the Work task-row whitelist, against a loopback fixture.

Usage: work-search-helper-checks.py <compiled cos-control-helper>. Never the live service.

work-search carries the query and the view (a domain and scope, or card ids) to POST /api/work/search (server 6.65.0)
unchanged, and brings back only the answer's own shape (12-hex ids, p from 0 to 1, at most 20, or a short reason).
Every failure is an answer, never an error: a server without the route reads server_too_old (K7), a server that does not
answer reads unreachable. A body the server would refuse never leaves the helper. work-tasks passes createdOn,
createdFrom and lineChangedAt through the row whitelist, each in its own shape only (K8); an older server's rows read null.
"""
import json, os, pathlib, shutil, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-search-helper-', dir='/tmp'))
token = 'b' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)
calls = []
state = {'status': 200, 'body': {'available': True, 'results': [{'id': 'a' * 12, 'p': 0.62}], 'none': 0.1, 'cached': False, 'tokens': 5000}}
REV = 'c' * 64
ROWS = [
    {'id': 'a' * 12, 'domain': 'quilt', 'title': 'Launch', 'text': 'Launch the site', 'checked': False, 'workStage': 'planned', 'workRevision': REV,
     'createdOn': '2026-10-06', 'createdFrom': 'source', 'lineChangedAt': '2026-10-06T22:58:01.123Z', 'secretField': 'never passed'},
    {'id': 'b' * 12, 'domain': 'quilt', 'title': 'Old', 'text': 'An older server row', 'checked': False, 'workStage': 'planned', 'workRevision': REV},
    {'id': 'd' * 12, 'domain': 'quilt', 'title': 'Odd', 'text': 'Odd shapes', 'checked': False, 'workStage': 'planned', 'workRevision': REV,
     'createdOn': '2026-10-06T00:00:00Z', 'createdFrom': 'guess', 'lineChangedAt': 'yesterday'},
    {'id': 'e' * 12, 'domain': 'quilt', 'title': 'Git', 'text': 'A git day', 'checked': False, 'workStage': 'planned', 'workRevision': REV,
     'createdOn': '2026-09-02', 'createdFrom': 'git', 'lineChangedAt': '2026-10-01T09:00:00-05:00'},
    {'id': 'f' * 12, 'domain': 'quilt', 'title': 'Types', 'text': 'Wrong types', 'checked': False, 'workStage': 'planned', 'workRevision': REV,
     'createdOn': 20261006, 'createdFrom': None, 'lineChangedAt': ['2026-10-01T09:00:00Z']},
]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        assert self.headers.get('X-COS-Token') == token
        calls.append(('GET', self.path, None))
        if self.path == '/api/work-board' and not state.get('legacy'):
            return self.reply(200, {'tasks': ROWS, 'capabilities': {'version': 1, 'writable': True}, 'complete': True})
        if self.path == '/api/tasks' and state.get('legacy'):
            return self.reply(200, {'tasks': ROWS})
        self.reply(404, {})
    def do_POST(self):
        assert self.headers.get('X-COS-Token') == token
        n = int(self.headers.get('Content-Length') or 0)
        data = json.loads(self.rfile.read(n)) if n else None
        calls.append(('POST', self.path, data))
        if self.path != '/api/work/search':
            return self.reply(404, {})
        self.reply(state['status'], state['body'])

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
for k in ('COS_WORK_CONNECTED_TEST', 'COS_WORK_REVIEW_CANDIDATE_PORT', 'COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE', 'COS_WORK_FIXTURE_TEST'): env.pop(k, None)
def run(args, data=None, port=None):
    e = dict(env, COS_CONTROL_TEST_API_PORT=str(port)) if port else env
    out = subprocess.run([helper, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=30)
    return json.loads(out.stdout)
def search(body, **kw): return run(['work-search'], json.dumps(body).encode(), **kw)
try:
    # Pass-through: the body reaches the route unchanged; the answer comes back in its own shape.
    for body in ({'query': 'website launch', 'scope': 'all', 'domain': 'quilt'}, {'query': 'website launch', 'scope': 'all'},
                 {'query': 'done things', 'scope': 'completed'}, {'query': 'needs me', 'ids': ['a' * 12, 'b' * 12]}, {'query': 'ab'}):
        r = search(body)
        assert r['ok'] and calls and calls[-1] == ('POST', '/api/work/search', body), (r, calls[-1:])
        assert r['details'] == {'available': True, 'results': [{'id': 'a' * 12, 'p': 0.62}], 'cached': False}, r
    # The answer's own shape only: a bad id, a p outside 0 to 1, a boolean p, and past 20.
    state['body'] = {'available': True, 'cached': True, 'results': [{'id': 'a' * 12, 'p': 0.5}, {'id': 'nope', 'p': 0.4}, {'id': 'b' * 12, 'p': 1.2},
                     {'id': 'c' * 12, 'p': True}, {'id': 'd' * 12, 'p': -0.1}, {'id': 'e' * 12, 'p': '0.3'}] + [{'id': '%012x' % i, 'p': 0.02} for i in range(30)]}
    r = search({'query': 'website', 'scope': 'all'})
    kept = r['details']['results']
    assert r['details']['available'] is True and r['details']['cached'] is True and kept[0] == {'id': 'a' * 12, 'p': 0.5}, r
    assert len(kept) == 15 and all(len(x['id']) == 12 and 0 <= x['p'] <= 1 for x in kept), (len(kept), kept[:3])
    state['body'] = {'available': True, 'results': [], 'none': 1.0, 'cached': False, 'tokens': 5000}
    assert search({'query': 'zebra pancake recipe', 'scope': 'all'})['details'] == {'available': True, 'results': [], 'cached': False}, 'an empty answer stays empty'
    # Every reason the server gives comes through; anything that is not a short code reads jev_unavailable.
    for reason in ('jev_not_configured', 'jev_cap_reached', 'jev_breaker_open', 'jev_unavailable', 'search_off', 'too_many_candidates'):
        state['body'] = {'available': False, 'reason': reason, 'message': 'x'}
        assert search({'query': 'website', 'scope': 'all'})['details'] == {'available': False, 'reason': reason}, reason
    for body in ({'available': False, 'reason': 'NOT A CODE; rm -rf'}, {'available': False}, {'results': []}, {'available': True}, {'available': 'yes'}):
        state['body'] = body
        assert search({'query': 'website', 'scope': 'all'})['details'] == {'available': False, 'reason': 'jev_unavailable'}, body
    # K7: a server without the route (6.64.0) answers a bare 404: server_too_old. Its own codes come through.
    for status, body, reason in ((404, {}, 'server_too_old'), (404, {'error': {'code': 'not_here; x'}}, 'server_too_old'),
                                 (503, {'error': {'code': 'work_board_unavailable'}}, 'work_board_unavailable'),
                                 (400, {'error': {'code': 'invalid_search_request'}}, 'invalid_search_request'), (500, {}, 'http_500')):
        state['status'], state['body'] = status, body
        r = search({'query': 'website', 'scope': 'all'})
        assert r['ok'] and r['details'] == {'available': False, 'reason': reason}, (status, body, r)
    state['status'] = 200
    # A server that does not answer: an answer, not an error.
    closed = socket.socket(); closed.bind(('127.0.0.1', 0)); dead = closed.getsockname()[1]; closed.close()
    r = search({'query': 'website', 'scope': 'all'}, port=dead)
    assert r['ok'] and r['details'] == {'available': False, 'reason': 'unreachable'}, r
    # A body the server would refuse never leaves the helper.
    before = len(calls)
    for bad in ({}, {'query': 'x'}, {'query': '   x   '}, {'query': 'y' * 201}, {'query': 'website', 'text': 'inject'}, {'query': 'website', 'scope': 'open'},
                {'query': 'website', 'domain': '../x'}, {'query': 'website', 'domain': '.hidden'}, {'query': 'website', 'domain': ''}, {'query': 'website', 'domain': 'a/b'},
                {'query': 'website', 'ids': ['A' * 12]}, {'query': 'website', 'ids': ['a' * 11]}, {'query': 'website', 'ids': 'a' * 12},
                {'query': 'website', 'ids': ['%012x' % i for i in range(255)]}, {'query': 5}):
        r = search(bad)
        assert not r['ok'], bad
    assert not run(['work-search'], b' ' * 16385)['ok'] and not run(['work-search'], b'not json')['ok']
    assert len(calls) == before, 'no refused body reaches the server'
    assert search({'query': 'needs me', 'ids': ['%012x' % i for i in range(254)]})['ok'] and len(calls) == before + 1, '254 ids is a full Choice'
    # Counted in code points, as the server counts: "\U0001F44D\U0001F3FD" is one character and two code points.
    thumb = '\U0001F44D\U0001F3FD'
    before = len(calls)
    assert not search({'query': thumb * 100 + 'a'})['ok'] and len(calls) == before, 'a query of 201 code points (101 characters) is refused'
    assert search({'query': thumb * 100})['ok'] and len(calls) == before + 1, 'a query of 200 code points is sent'

    # K8: the row whitelist passes the three date fields, each in its own shape; the rest of a row is unchanged.
    r = run(['work-tasks'])
    assert r['ok'], r
    rows = {row['id']: row for row in r['details']['tasks']}
    assert (rows['a' * 12]['createdOn'], rows['a' * 12]['createdFrom'], rows['a' * 12]['lineChangedAt']) == ('2026-10-06', 'source', '2026-10-06T22:58:01.123Z'), rows['a' * 12]
    assert (rows['e' * 12]['createdOn'], rows['e' * 12]['createdFrom'], rows['e' * 12]['lineChangedAt']) == ('2026-09-02', 'git', '2026-10-01T09:00:00-05:00'), rows['e' * 12]
    for old in ('b' * 12, 'd' * 12, 'f' * 12):
        assert all(k in rows[old] and rows[old][k] is None for k in ('createdOn', 'createdFrom', 'lineChangedAt')), rows[old]
    assert 'secretField' not in rows['a' * 12] and rows['a' * 12]['text'] == 'Launch the site' and rows['a' * 12]['workRevision'] == REV, 'only whitelisted fields pass'
    assert calls[-1][:2] == ('GET', '/api/work-board'), 'the board came from /api/work-board (server 6.65.0 adds the fields there)'
    # A server without /api/work-board: the legacy /api/tasks read passes the same fields through the same whitelist.
    state['legacy'] = True
    r = run(['work-tasks'])
    legacy = {row['id']: row for row in r['details']['tasks']}
    assert r['ok'] and [c[1] for c in calls[-2:]] == ['/api/work-board', '/api/tasks'], calls[-2:]
    assert (legacy['a' * 12]['createdOn'], legacy['a' * 12]['createdFrom'], legacy['a' * 12]['lineChangedAt']) == ('2026-10-06', 'source', '2026-10-06T22:58:01.123Z'), legacy['a' * 12]
    assert legacy['b' * 12]['createdOn'] is None and 'secretField' not in legacy['a' * 12], 'the legacy read uses the same whitelist'
    print('PASS compiled helper: work-search passes the view through and only the answer\'s own shape back (ids, p 0 to 1, at most 20, short reasons), '
          'every failure an answer (server_too_old for a server without the route, unreachable, codes), refused bodies never sent; '
          'work-tasks passes createdOn, createdFrom and lineChangedAt in their own shapes, null otherwise (K7, K8)')
finally:
    server.shutdown(); shutil.rmtree(root)
