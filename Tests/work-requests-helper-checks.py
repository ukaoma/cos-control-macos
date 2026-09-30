#!/usr/bin/env python3
"""0.5.252: exercise the compiled helper's glasses request commands against a loopback fixture; never the live service.

Usage: work-requests-helper-checks.py <compiled cos-control-helper>
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-requests-helper-', dir='/tmp'))
token = 'b' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)
RID = '11111111-1111-4111-8111-111111111111'
CLAIM = 'c' * 32
REQUEST = {'clientRequestId': RID, 'domain': 'Quilt', 'workIdentity': '0123456789ab', 'expectedTaskRevision': 'a' * 64,
           'intent': 'start', 'mode': 'newSession', 'model': 'opus', 'destinationSource': 'user', 'state': 'pending',
           'createdAt': '2026-09-30T13:00:00.000Z', 'expiresAt': '2026-09-30T13:10:00.000Z'}
calls, state = [], {'list': (200, None), 'claim': (200, None), 'result': (200, None)}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def failure(self, status, code):
        # A missing route (an older server) answers without a request code.
        return self.reply(status, {'error': {'code': code, 'message': 'fixture'}} if code else {'error': 'Not found'})
    def do_GET(self):
        assert self.headers.get('X-COS-Token') == token
        calls.append(('GET', self.path, None))
        status, code = state['list']
        if status != 200: return self.failure(status, code)
        self.reply(200, {'version': 1, 'requests': [REQUEST], 'quarantined': 2})
    def do_POST(self):
        assert self.headers.get('X-COS-Token') == token
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append(('POST', self.path, body))
        kind = 'claim' if self.path.endswith('/claim') else 'result'
        status, code = state[kind]
        if status != 200: return self.failure(status, code)
        if kind == 'claim':
            return self.reply(200, {'request': dict(REQUEST, state='claimed', claimedAt='2026-09-30T13:01:00.000Z',
                                                    claimExpiresAt='2026-09-30T13:11:00.000Z'), 'claimToken': CLAIM})
        self.reply(200, {'request': dict(REQUEST, state=body['state'], receiptId=body.get('receiptId'))})

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
for key in ('COS_WORK_CONNECTED_TEST', 'COS_WORK_REVIEW_CANDIDATE_PORT', 'COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE'): env.pop(key, None)
def run(args, data=None):
    out = subprocess.run([helper, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=20)
    return json.loads(out.stdout)
try:
    # The list: the pending requests, from the loopback route Control alone may call.
    listed = run(['work-requests'])
    assert listed['ok'] and listed['details']['available'] is True and listed['details']['requests'] == [REQUEST], listed
    # COS Control shows no quarantine count, so the helper does not pass one on.
    assert 'quarantined' not in listed['details'] and calls[-1] == ('GET', '/api/work-board/handoff-requests?state=pending', None), calls[-1]
    # An older server has no route (404 with no request code): server_too_old, never an error. Anything else: unavailable.
    state['list'] = (404, None)
    old = run(['work-requests'])
    assert old['ok'] and old['details'] == {'available': False, 'reason': 'server_too_old', 'httpStatus': 404, 'requests': []}, old
    for status, code, reason in ((403, 'local_only', 'local_only'), (503, 'handoff_requests_unavailable', 'handoff_requests_unavailable'),
                                 (502, None, 'http_502')):
        state['list'] = (status, code)
        down = run(['work-requests'])
        assert down['ok'] and down['details']['available'] is False and down['details']['reason'] == reason, (status, down)
    state['list'] = (200, None)

    # The claim: an empty body, the token back, the request with its claim deadline.
    claimed = run(['work-request-claim', '--id', RID.upper()])
    assert claimed['ok'] and claimed['details']['claimed'] is True and claimed['details']['claimToken'] == CLAIM, claimed
    assert claimed['details']['request']['claimExpiresAt'] == '2026-09-30T13:11:00.000Z'
    assert calls[-1] == ('POST', f'/api/work-board/handoff-requests/{RID}/claim', {}), calls[-1]
    again = run(['work-request-claim', '--id', RID, '--claim-token', CLAIM])
    assert again['details']['claimed'] is True and calls[-1][2] == {'claimToken': CLAIM}, 'the same token claims again'
    for status, code, reason in ((409, 'already_claimed', 'already_claimed'), (410, 'request_expired', 'request_expired'),
                                 (404, 'request_not_found', 'request_not_found'), (404, None, 'server_too_old')):
        state['claim'] = (status, code)
        lost = run(['work-request-claim', '--id', RID])
        assert lost['ok'] and lost['details'] == {'claimed': False, 'httpStatus': status, 'reason': reason}, (status, lost)
    state['claim'] = (200, None)

    # The result: exactly the body Control posts, under the claim token.
    sent = {'state': 'sent', 'receiptId': 'r-1', 'claimToken': CLAIM}
    posted = run(['work-request-result', '--id', RID], json.dumps(sent).encode())
    assert posted['ok'] and posted['details']['accepted'] is True and calls[-1] == ('POST', f'/api/work-board/handoff-requests/{RID}/result', sent), calls[-1]
    refused = {'state': 'refused', 'reason': 'This task changed\nafter the glasses read it.', 'claimToken': CLAIM}
    run(['work-request-result', '--id', RID], json.dumps(refused).encode())
    assert calls[-1][2] == dict(refused, reason='This task changed after the glasses read it.'), calls[-1]
    for status, code, reason in ((409, 'claim_token_mismatch', 'claim_token_mismatch'), (410, 'request_expired', 'request_expired'),
                                 (503, 'handoff_requests_unavailable', 'handoff_requests_unavailable')):
        state['result'] = (status, code)
        taken = run(['work-request-result', '--id', RID], json.dumps(sent).encode())
        assert taken['ok'] and taken['details'] == {'accepted': False, 'httpStatus': status, 'reason': reason}, (status, taken)
    state['result'] = (200, None)

    # Nothing malformed reaches the server.
    before = len(calls)
    for bad in ({'state': 'sent', 'claimToken': CLAIM}, {'state': 'unresolved', 'claimToken': CLAIM}, {'state': 'refused', 'claimToken': CLAIM},
                {'state': 'sent', 'receiptId': 'r-1'}, dict(sent, claimToken='C' * 32), dict(sent, state='done'), dict(sent, extra=1),
                dict(sent, receiptId='r 1')):
        assert not run(['work-request-result', '--id', RID], json.dumps(bad).encode())['ok'], bad
    assert not run(['work-request-result', '--id', RID], b'not json')['ok']
    assert not run(['work-request-result', '--id', RID], b' ' * 4097)['ok']
    for bad_id in ('../' + RID, RID[:-1], '11111111-1111-3111-8111-111111111111'):
        assert not run(['work-request-claim', '--id', bad_id])['ok'], bad_id
        assert not run(['work-request-result', '--id', bad_id], json.dumps(sent).encode())['ok'], bad_id
    assert not run(['work-request-claim', '--id', RID, '--claim-token', 'x'])['ok']
    assert len(calls) == before, 'No malformed claim or result reaches the server'
    print('PASS compiled helper: glasses requests list, 404 server_too_old, claim and re-claim, claim refusals, exact result body, refusals, no malformed dispatch')
finally:
    server.shutdown()
    shutil.rmtree(root)
