#!/usr/bin/env python3
"""Fresh canonical Work roundtrip against an authenticated loopback fixture and disposable private journal."""
import concurrent.futures, hashlib, json, os, pathlib, shutil, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

helper = str(pathlib.Path(sys.argv[1]).resolve())
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-roundtrip-', dir='/tmp'))
token = 'c' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n')
(root / '.cos-glasses/.env').chmod(0o600)
identity = 'a' * 12
key = 'task:quilt:' + identity
other_key = 'task:quilt:' + 'b' * 12
sid = 'codex:00000000-0000-4000-8000-000000000001'
state = {'revision': 'd' * 64, 'rowID': 'c' * 12, 'text': 'Fresh task with explicit user intent', 'stage': 'planned', 'writable': True,
         'status': 200, 'duplicate': False, 'metadataError': '', 'race': False, 'auth': True, 'wrongSession': False}
calls = []
guard = threading.Lock()
def row(stable, current, text):
    return {'id': current, 'domain': 'quilt', 'title': text[:20], 'text': text, 'workIdentity': stable, 'workRevision': state['revision'],
            'workStage': state['stage'], 'checked': False, 'doneWhen': 'User reviewed the work', 'source': 'Manual entry',
            'workMetadataError': state['metadataError'], 'meetingRefs': [{'recordId': 'g2:walk', 'domain': 'quilt', 'month': '2026-10', 'filename': 'Walk.md', 'title': 'Queen walk'}]}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, status, body):
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def authenticated(self):
        assert self.headers.get('X-COS-Token') == token
        if not state['auth']:
            self.send(401, {'error': 'authentication_required'}); return False
        return True
    def do_GET(self):
        if not self.authenticated(): return
        with guard: calls.append((self.command, self.path, None))
        if self.path.startswith('/api/agent-sessions/'):
            provider, native = self.path.split('/')[-2:]
            if native.endswith('000000000099'):
                self.send(404, {'error': 'Session not found'}); return
            self.send(200, {'provider': provider, 'session_id': '00000000-0000-4000-8000-000000000098' if state['wrongSession'] else native}); return
        assert self.path == '/api/work-board', 'No fallback or model endpoint may be used' 
        if state['status'] != 200: self.send(state['status'], {}); return
        rows = [row(identity, state['rowID'], state['text']), row('b' * 12, 'e' * 12, 'A separate task')]
        if state['duplicate']: rows.append(dict(rows[0]))
        self.send(200, {'tasks': rows, 'capabilities': {'version': 1, 'writable': state['writable']}})
    def do_POST(self):
        if not self.authenticated(): return
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with guard: calls.append((self.command, self.path, body))
        assert self.path == '/api/work-board/stage'
        if state['race'] or body['expectedRevision'] != state['revision'] or body['id'] != state['rowID'] or body['expectedText'] != state['text']:
            self.send(409, {'error': 'task_revision_changed'}); return
        state['stage'] = body['workStage']; state['rowID'] = 'f' * 12; state['revision'] = hashlib.sha256(json.dumps(body).encode()).hexdigest()
        self.send(200, {'ok': True, 'workStage': state['stage']})
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port), COS_WORK_FIXTURE_TEST='1')
for name in ('CODEX_THREAD_ID', 'CLAUDE_SESSION_ID', 'COS_WORK_CONNECTED_TEST', 'COS_WORK_REVIEW_CANDIDATE_PORT', 'COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE'):
    env.pop(name, None)
def run(args, extra=None, stdin=None):
    result = subprocess.run([helper, *args], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(env, **(extra or {})), timeout=20)
    try: value = json.loads(result.stdout)
    except Exception: raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return value

def context(work=key, session=None):
    return run(['work-context', '--work-id', work] + (['--session-id', session] if session else []))
def link(session=sid, work=key, expected='none'):
    return run(['work-link-session', '--work-id', work, '--session-id', session, '--expected-link', expected])
def stage(expected, stage='qa'):
    return run(['work-set-stage', '--work-id', key, '--stage', stage, '--expected-revision', expected])
links = root / 'work-handoffs/handoffs.session-cards.json'
try:
    first = context()['details']
    assert first['fullText'] == state['text'] and first['rowID'] == state['rowID'] and first['workRevision'] == state['revision']
    assert first['workID'] == key and first['sessionLinkRevision'] == 'none' and first['linkedSessions'] == []
    assert first['task']['meetingRefs'][0]['recordId'] == 'g2:walk' and 'Queen walk' in first['contextText']
    # Fresh reads, current row ID and whole-file CAS remain distinct from stable identity and display snapshot.
    state.update(text='Renamed task after export', rowID='9' * 12, revision='8' * 64)
    newer = context()['details']; assert newer['fullText'] == state['text'] and newer['rowID'] == state['rowID']
    before = len(calls)
    assert not stage(first['workRevision'])['ok'] and not any(c[0] == 'POST' for c in calls[before:])
    assert stage(newer['workRevision'])['ok']
    assert calls[-1][2]['id'] == '9' * 12 and calls[-1][2]['expectedRevision'] == newer['workRevision'] and calls[-1][2]['expectedText'] == newer['fullText']
    after = context()['details']; assert after['rowID'] == 'f' * 12 and after['workRevision'] != newer['workRevision']
    state['race'] = True; assert not stage(after['workRevision'])['ok']; state['race'] = False
    state['writable'] = False; before = len(calls); assert not stage(state['revision'])['ok'] and not any(c[0] == 'POST' for c in calls[before:]); state['writable'] = True
    # Original stdin route remains compatible.
    payload = {'domain': 'quilt', 'id': state['rowID'], 'expectedText': state['text'], 'expectedRevision': state['revision'], 'workStage': 'built'}
    assert run(['work-set-stage'], stdin=json.dumps(payload).encode())['ok']
    before = len(calls)
    for args in (['work-context', '--work-id', key, '--work-id', key], ['work-context', '--work-id', 'task:../quilt:' + identity],
                 ['work-context', '--work-id', 'task:quilt:short'], ['work-link-session', '--work-id', key, '--expected-link', 'none'],
                 ['work-link-session', '--work-id', key, '--session-id', 'latest', '--expected-link', 'none'],
                 ['work-set-stage', '--work-id', key, '--stage', 'qa', '--expected-revision', 'snapshot-revision']):
        assert not run(args)['ok']
    # All invalid option/identity/stage inputs refused before dispatch except missing exact session context.
    assert len(calls) == before
    state['duplicate'] = True; assert not context()['ok']; state['duplicate'] = False
    state['metadataError'] = 'corrupt_metadata'; assert not context()['ok']; state['metadataError'] = ''
    state['status'] = 404; before = len(calls); assert not context()['ok'] and len(calls) == before + 1; state['status'] = 200
    state['auth'] = False; assert not context()['ok']; state['auth'] = True
    # Exact session registration creates only an association, not a handoff, provider call, job or phantom receipt.
    established = link()['details']; digest = established['linkRevision']
    original = links.read_bytes()
    assert not link(session='codex:00000000-0000-4000-8000-000000000099')['ok'] and links.read_bytes() == original
    state['wrongSession'] = True
    assert not link(session='codex:00000000-0000-4000-8000-000000000031')['ok'] and links.read_bytes() == original
    state['wrongSession'] = False
    assert link(expected='0' * 64)['details']['linkRevision'] == digest and links.read_bytes() == original
    current = context(session=sid)['details']; assert current['sessionLinkRevision'] == digest and current['sessionLink']['workID'] == key
    assert current['linkedSessions'][0]['linkRevision'] == digest
    assert not link(work=other_key)['ok'] and links.read_bytes() == original
    other_context = context(other_key, sid)['details']; assert other_context['linkedSessions'] == [] and other_context['sessionLinkRevision'] == digest
    assert link(work=other_key, expected=digest)['ok']
    assert not link(expected=digest)['ok']
    env_link = run(['work-link-session', '--work-id', key, '--expected-link', 'none'], {'CLAUDE_SESSION_ID': '00000000-0000-4000-8000-000000000002'})
    assert env_link['ok'] and env_link['details']['sessionID'].startswith('claude:')
    assert not run(['work-context', '--work-id', key], {'CLAUDE_SESSION_ID': '00000000-0000-4000-8000-000000000002', 'CODEX_THREAD_ID': '00000000-0000-4000-8000-000000000003'})['ok']
    # Independent helper processes serialize a disk merge; all earlier associations survive each new writer.
    ids = [f'codex:00000000-0000-4000-8000-{i:012d}' for i in range(10, 22)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda value: link(session=value), ids))
    assert all(value['ok'] for value in results)
    saved = json.loads(links.read_text()); assert set(ids + [sid, 'claude:00000000-0000-4000-8000-000000000002']) == set(saved)
    contested = 'codex:00000000-0000-4000-8000-000000000040'
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        races = list(pool.map(lambda work: (work, link(session=contested, work=work)), [key, other_key]))
    winners = [(work, result) for work, result in races if result['ok']]
    losers = [(work, result) for work, result in races if not result['ok']]
    assert len(winners) == 1 and len(losers) == 1 and 'changed' in losers[0][1]['message'], races
    saved = json.loads(links.read_text()); assert saved[contested]['workID'] == winners[0][0] and len(saved) == 15
    restarted = context()['details']; assert len(restarted['linkedSessions']) == 13 + int(winners[0][0] == key)
    assert stat.S_IMODE(links.stat().st_mode) == 0o600 and stat.S_IMODE(links.with_suffix('.lock').stat().st_mode) == 0o600
    assert not (links.parent / 'handoffs.json').exists()
    # Corruption, symlinks and special files are refused without replacing the user's association map.
    cursor = 'cursor:abcdefab-0000-4000-8000-000000000044'
    cursor_link = link(session=cursor); assert cursor_link['ok']
    digest = cursor_link['details']['linkRevision']
    assert context(session=cursor.upper().replace('CURSOR:', 'cursor:'))['details']['sessionLinkRevision'] == digest
    before = len(calls)
    assert not run(['work-unlink-session', '--work-id', other_key, '--session-id', cursor, '--expected-link', digest])['ok']
    assert not run(['work-unlink-session', '--work-id', key, '--session-id', cursor, '--expected-link', '0' * 64])['ok']
    assert run(['work-unlink-session', '--work-id', key, '--session-id', cursor, '--expected-link', digest])['ok']
    assert context(session=cursor)['details']['sessionLinkRevision'] == 'none'
    assert all(method == 'GET' for method, _, _ in calls[before:]), 'Link/unlink cannot send or stage work'
    assert not (links.parent / 'handoffs.json').exists()
    print('PASS: Cursor exact context/link/unlink CAS, wrong-task refusal, no native job/receipt/stage mutation')
    good = links.read_bytes(); links.write_text('{broken'); assert not context()['ok'] and not link(session='codex:00000000-0000-4000-8000-000000000030')['ok']; assert links.read_text() == '{broken'
    links.write_bytes(good); links.unlink(); target = root / 'target.json'; target.write_bytes(good); links.symlink_to(target)
    assert not context()['ok'] and target.read_bytes() == good; links.unlink(); os.mkfifo(links)
    assert not context()['ok']; links.unlink(); links.write_bytes(good); links.chmod(0o600)
    lock = links.with_suffix('.lock'); lock.unlink(); lock.symlink_to(target)
    assert not context()['ok'] and target.read_bytes() == good
    assert all(path in ('/api/work-board', '/api/work-board/stage') or (method == 'GET' and path.startswith('/api/agent-sessions/')) for method, path, body in calls)
    print('PASS Work roundtrip: fresh context/current row, whole-file CAS/race/auth/readonly gates, stdin compatibility, exact session environment, association CAS/idempotence/restart, 12 concurrent process merges and conflicting same-session CAS, private files, corrupt/symlink/FIFO refusal; no model calls or phantom handoffs')
finally:
    server.shutdown(); shutil.rmtree(root)
