#!/usr/bin/env python3
"""Exercise the compiled helper's Work intake commands with a loopback fixture; never the live service.

Usage: work-intake-helper-checks.py <compiled cos-control-helper>
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-intake-helper-', dir='/tmp'))
token = 'a' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)
calls, state = [], {'list': 200, 'resolve': (200, None)}
ITEM = {'id': 'wi_' + '0' * 31 + '1', 'kind': 'ask', 'status': 'ask', 'confidence': 0.9, 'model': 'jev-1.13.0', 'text': 'Fix the H1',
        'meeting': {'recordId': 'ops:quilt:2026-09:m.md', 'domain': 'quilt', 'month': '2026-09', 'filename': 'm.md', 'title': 'M'},
        'reason': 'outside_window'}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        assert self.headers.get('X-COS-Token') == token
        calls.append(('GET', self.path, None))
        if state['list'] != 200: return self.reply(state['list'], {'error': {'code': 'work_intake_unavailable'}})
        self.reply(200, {'schemaVersion': 1, 'capabilities': {'linkWrites': True, 'cardCreation': True}, 'counts': {'ask': 1}, 'items': [ITEM], 'quarantined': 0})
    def do_POST(self):
        assert self.headers.get('X-COS-Token') == token
        calls.append(('POST', self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
        status, code = state['resolve']
        self.reply(status, {'ok': True, 'item': dict(ITEM, status='accepted')} if status == 200 else {'error': {'code': code}})

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
for key in ('COS_WORK_CONNECTED_TEST', 'COS_WORK_REVIEW_CANDIDATE_PORT', 'COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE'): env.pop(key, None)
def run(args, data=None):
    out = subprocess.run([helper, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=20)
    return json.loads(out.stdout)
try:
    listed = run(['work-intake'])
    assert listed['ok'] and listed['details']['available'] is True and listed['details']['items'][0]['reason'] == 'outside_window', listed
    assert listed['details']['capabilities'] == {'linkWrites': True, 'cardCreation': True}
    for status in (404, 503):  # an older server or a store that is down: unavailable, never an error that blanks Work
        state['list'] = status
        old = run(['work-intake'])
        assert old['ok'] and old['details']['available'] is False and old['details']['items'] == [], old
        assert old['details']['capabilities'] == {'cardCreation': False, 'linkWrites': False}
        assert old['details']['storeUnavailable'] is (status == 503), 'Only a store that is down is shown; an older server is hidden'
    state['list'] = 500
    assert not run(['work-intake'])['ok'], 'Any other failure is an error, not an empty Intake'
    state['list'] = 200

    good = {'id': ITEM['id'], 'action': 'accept'}
    done = run(['work-intake-resolve'], json.dumps(good).encode())
    assert done['ok'] and done['message'] == 'Added to Work' and calls[-1] == ('POST', f"/api/work-intake/{ITEM['id']}/resolve", {'action': 'accept'}), (done, calls[-1])
    assert run(['work-intake-resolve'], json.dumps(dict(good, action='dismiss')).encode())['message'] == 'Dismissed'
    state['resolve'] = (409, 'intake_text_collision')
    refused = run(['work-intake-resolve'], json.dumps(good).encode())
    assert not refused['ok'] and refused['message'] == 'The same words are on closed or archived work. Reopen that task instead, or dismiss this item.', refused
    for code in ('meeting_unavailable', 'meeting_identity_changed', 'intake_task_changed'):  # retrying never helps: say dismiss
        state['resolve'] = (409, code)
        assert 'Dismiss' in run(['work-intake-resolve'], json.dumps(good).encode())['message'], code
    state['resolve'] = (503, 'task_bridge_unavailable')
    assert run(['work-intake-resolve'], json.dumps(good).encode())['message'] == "The task bridge didn't answer. Try again in a moment."
    state['resolve'] = (409, 'something_new')
    assert 'HTTP 409' in run(['work-intake-resolve'], json.dumps(good).encode())['message'], 'An unmapped code still says what happened'
    state['resolve'] = (200, None)

    before = len(calls)
    for bad in ({'id': 'wi_x', 'action': 'accept'}, {'id': ITEM['id'], 'action': 'publish'}, {'id': ITEM['id']},
                dict(good, extra=1), {'id': '../' + ITEM['id'], 'action': 'accept'}):
        assert not run(['work-intake-resolve'], json.dumps(bad).encode())['ok']
    assert not run(['work-intake-resolve'], b' ' * 4097)['ok']
    assert not run(['work-intake-resolve'], b'not json')['ok']
    assert len(calls) == before, 'No invalid resolve reaches the server'
    print('PASS compiled helper: intake list, 404/503 unavailable, 500 error, exact resolve route and body, mapped refusals, no invalid dispatch, bounded input')
finally:
    server.shutdown()
    shutil.rmtree(root)
