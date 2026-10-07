#!/usr/bin/env python3
"""Exercise the compiled helper's Work tracking commands (0.5.247) against a loopback fixture.

session-recent-replies reads a session's recent replies (read-only); work-completion-check asks the server's Jev check
with names only. Usage: work-progress-helper-checks.py <compiled cos-control-helper>. Never the live service.
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-progress-helper-', dir='/tmp'))
token = 'b' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)
SESSION = '0f3c9a2e-1111-4222-8333-944455556666'
calls, state = [], {'detail': 200, 'turns': True, 'check': 200, 'checkBody': {}}
DETAIL = {'latest_reply': 'Newest reply', 'running_active': True, 'last_activity_at': '2026-09-29T15:00:00.000Z', 'agent_state': 'idle',
          'recent_turns': [{'role': 'user', 'text': 'Do the thing', 'at': '2026-09-29T14:58:00.000Z'},
                           {'role': 'assistant', 'text': 'COS-WORK 0123456789ab: done: shipped it', 'at': '2026-09-29T14:59:00.000Z'},
                           {'role': 'assistant', 'text': 'Cursor reply without a time'},
                           {'role': 'assistant', 'text': ''}]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        if self.path == '/api/health': return self.reply(200, {'ok': True})  # unauthenticated, as on the server
        assert self.headers.get('X-COS-Token') == token
        calls.append(('GET', self.path, None))
        body = dict(DETAIL)
        if not state['turns']: body.pop('recent_turns')
        self.reply(state['detail'], body if state['detail'] == 200 else {'reason': 'session_not_found'})
    def do_POST(self):
        assert self.headers.get('X-COS-Token') == token
        n = int(self.headers.get('Content-Length') or 0)
        data = json.loads(self.rfile.read(n)) if n else None
        calls.append(('POST', self.path, data))
        self.reply(state['check'], {'provider': 'jev', 'verdict': 'done', 'confidence': 0.91, 'model': 'jev', 'cached': False}
                   if state['check'] == 200 else state['checkBody'])

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
for k in ('COS_WORK_CONNECTED_TEST', 'COS_WORK_REVIEW_CANDIDATE_PORT', 'COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE'): env.pop(k, None)
def run(args, data=None):
    out = subprocess.run([helper, *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=20)
    return json.loads(out.stdout)
try:
    # Recent messages: assistant replies whole, user messages by their opening, with times; read-only GET with ?turns.
    DETAIL['recent_turns'][1:1] = [{'role': 'user', 'text': 'Draft the CTA. ' + 'x' * 900, 'at': '2026-09-29T14:58:30.000Z'}]
    r = run(['session-recent-replies', '--provider', 'claude', '--session-id', SESSION, '--turns', '16'])
    assert r['ok'] and calls[-1] == ('GET', f'/api/agent-sessions/claude/{SESSION}?turns=16', None), (r, calls[-1])
    d = r['details']
    assert d['state'] == 'turns' and d['runningActive'] is True and d['agentState'] == 'idle' and d['lastActivityAt'] == '2026-09-29T15:00:00.000Z'
    assert d['replies'] == [{'text': 'COS-WORK 0123456789ab: done: shipped it', 'at': '2026-09-29T14:59:00.000Z'},
                            {'text': 'Cursor reply without a time'}], d['replies']
    assert [p['at'] for p in d['prompts']] == ['2026-09-29T14:58:00.000Z', '2026-09-29T14:58:30.000Z']
    assert all(len(p['text']) <= 400 for p in d['prompts']) and d['prompts'][1]['text'].startswith('Draft the CTA.'), 'user messages are kept by their opening only'
    SESSION_TURNS_MAX = 40
    assert run(['session-recent-replies', '--provider', 'claude', '--session-id', SESSION, '--turns', '999'])['ok']
    assert calls[-1][1].endswith(f'?turns={SESSION_TURNS_MAX}'), 'turns is capped at the server maximum'
    assert run(['session-recent-replies', '--provider', 'claude', '--session-id', SESSION])['ok'] and calls[-1][1].endswith('?turns=24')
    # No recent_turns (an older server, or its read failed): no history, and the newest reply is NOT passed off as one.
    state['turns'] = False
    r = run(['session-recent-replies', '--provider', 'codex', '--session-id', SESSION])
    assert r['details']['state'] == 'no_history' and r['details']['replies'] == [] and r['details']['prompts'] == [], r
    state['turns'] = True
    # A session the server does not know is an answer, not an error.
    state['detail'] = 404
    r = run(['session-recent-replies', '--provider', 'claude', '--session-id', SESSION])
    assert r['ok'] and r['details']['state'] == 'missing' and r['details']['replies'] == [] and r['details']['prompts'] == [], r
    state['detail'] = 200
    before = len(calls)
    for bad in (['--provider', 'ollama', '--session-id', SESSION], ['--provider', 'claude', '--session-id', '../../etc'], ['--provider', 'claude']):
        assert not run(['session-recent-replies', *bad])['ok'], bad
    assert len(calls) == before, 'No invalid read reaches the server'

    # Completion check: names only, passed through; failures are answers with a reason.
    good = {'domain': 'quilt', 'id': '0123456789ab', 'provider': 'claude', 'sessionId': SESSION}
    r = run(['work-completion-check'], json.dumps(good).encode())
    assert r['ok'] and r['details']['verdict'] == 'done' and calls[-1] == ('POST', '/api/work-board/completion-check', good), (r, calls[-1])
    for status, body, reason in ((404, {}, 'server_too_old'), (404, {'error': {'code': 'session_not_found'}}, 'session_not_found'),
                                 (404, {'error': {'code': 'task_not_found'}}, 'task_not_found'), (500, {}, 'http_500')):
        state['check'], state['checkBody'] = status, body
        r = run(['work-completion-check'], json.dumps(good).encode())
        assert r['ok'] and r['details'] == {'provider': 'none', 'reason': reason}, (status, body, r)
    state['check'] = 200
    timed = dict(good, after='2026-09-29T15:01:00.000Z')
    r = run(['work-completion-check'], json.dumps(timed).encode())
    assert r['ok'] and calls[-1] == ('POST', '/api/work-board/completion-check', timed), 'after passes through'
    before = len(calls)
    for bad in (dict(good, reply='I finished it'), dict(good, id='nope'), dict(good, domain='../x'), dict(good, provider='ollama'),
                dict(good, sessionId='../../etc'), {k: v for k, v in good.items() if k != 'sessionId'},
                dict(good, after='yesterday'), dict(good, after=12), dict(good, after='2026-09-29T15:01:00.000Z' + '0' * 30)):
        assert not run(['work-completion-check'], json.dumps(bad).encode())['ok'], bad
    assert not run(['work-completion-check'], b' ' * 4097)['ok'] and len(calls) == before, 'No invalid check reaches the server'
    # 0.5.262: the evidence check (contract 2026-10-07): exactly the contract's keys pass through to the route, every
    # failure is an answer with a reason, and the body is bounded at 16 KB, not the completion check's 4 KB.
    ev = {'domain': 'quilt', 'id': '5755b516df8f', 'since': '2026-10-02T23:52:00.000Z',
          'follows': [{'provider': 'claude', 'sessionId': SESSION, 'cursor': None},
                      {'provider': 'codex', 'sessionId': '1a2b3c4d-1111-4222-8333-944455556666', 'cursor': 'b:120|t:2026-10-07'}],
          'clauses': ['https://bottlepos.com/october-switch-offer page is live', 'Facebook ads are running against it']}
    r = run(['work-evidence-check'], json.dumps(ev).encode())
    assert r['ok'] and r['details']['provider'] == 'jev' and calls[-1] == ('POST', '/api/work-board/evidence-check', ev), (r, calls[-1])
    big = dict(ev, clauses=['x' * 300] * 6, follows=[{'provider': 'claude', 'sessionId': f'0f3c9a2e-1111-4222-8333-94445555666{n}', 'cursor': 'c' * 2048} for n in range(4)])
    rb = run(['work-evidence-check'], json.dumps(big).encode()); assert len(json.dumps(big)) > 4096 and rb['ok'], ('a full body is over 4 KB and still goes', rb)
    for status, body, reason in ((404, {}, 'server_too_old'), (404, {'error': {'code': 'task_not_found'}}, 'task_not_found'), (500, {}, 'http_500')):
        state['check'], state['checkBody'] = status, body
        r = run(['work-evidence-check'], json.dumps(ev).encode())
        assert r['ok'] and r['details'] == {'provider': 'none', 'reason': reason}, (status, body, r)
    state['check'] = 200
    before = len(calls)
    for bad in (dict(ev, extra=1), {k: v for k, v in ev.items() if k != 'since'}, dict(ev, clauses=['a'] * 7), dict(ev, clauses=['x' * 301]),
                dict(ev, clauses=['']), dict(ev, follows=[dict(ev['follows'][0], sessionId=f'0f3c9a2e-1111-4222-8333-94445555666{n}') for n in range(5)]), dict(ev, follows=[ev['follows'][0]] * 2), dict(ev, follows=[dict(ev['follows'][0], sessionId='../../etc')]),
                dict(ev, follows=[{'provider': 'claude', 'sessionId': SESSION}]), dict(ev, follows=[dict(ev['follows'][0], cursor=7)]),
                dict(ev, id='nope'), dict(ev, since='yesterday'), dict(ev, domain='../x')):
        assert not run(['work-evidence-check'], json.dumps(bad).encode())['ok'], bad
    assert not run(['work-evidence-check'], b' ' * 16385)['ok'] and len(calls) == before, 'No invalid evidence check reaches the server'
    # 0.5.253: Cursor runs nothing in the background, so the 0.5.249 Cursor chat finder is gone: the command is unknown, and
    # nothing reaches the server.
    before = len(calls)
    gone = run(['work-cursor-chat', '--tag', '0123456789ab', '--since', '1790723000'])
    assert not gone['ok'] and len(calls) == before, gone
    print('PASS compiled helper: recent messages (replies with times, user openings, capped turns, no history without recent_turns, unknown session, refused inputs), completion check (names and time only, reasons for failures, refused inputs), evidence check (only the contract keys, 16 KB, reasons, refused inputs), no Cursor chat finder (0.5.253)')
finally:
    server.shutdown(); shutil.rmtree(root)
