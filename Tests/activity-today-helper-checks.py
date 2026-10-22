#!/usr/bin/env python3
"""Exercise the compiled helper's `activity-today` verb against a loopback fixture; never the live service.

The capability probe reads /api/health `features.activeQueryJobs` (protocol 1); a status code alone never decides it. Only the
listed job fields leave the helper; routine runs are only the ones still going; the calendar part is welcome-context's one
event and never the weather. An older server (404 or a job error on /query-jobs/active) is `available` false, not an error.

Usage: activity-today-helper-checks.py <compiled cos-control-helper>
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-activity-today-helper-', dir='/tmp'))
token = 'b' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)
calls = []
state = {'features': {'activeQueryJobs': True, 'activeQueryJobsProtocol': 1}, 'active': 200, 'runs': 200, 'welcome': 200}
JOB = {'jobId': 'qj_1', 'generation': 1, 'origin': 'person', 'state': 'running', 'status': 'running', 'acceptedAt': '2026-10-21T19:46:20Z',
       'elapsedMs': 40000, 'provider': 'claude', 'model': 'opus', 'messageNo': 3120, 'title': 'What did Dana say about renewal timing?',
       'response': 'SECRET ANSWER', 'query': 'SECRET PROMPT', 'trail': ['x']}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        calls.append(self.path)
        if self.path == '/api/health':
            return self.reply(200, {'ok': True, 'features': state['features']})
        assert self.headers.get('X-COS-Token') == token, self.path
        if self.path == '/api/query-jobs/active':
            if state['active'] == 400:  # an older server: the path falls into /query-jobs/:jobId
                return self.reply(400, {'error': {'code': 'invalid_job_id'}})
            return self.reply(state['active'], {'protocolVersion': 1, 'enabled': True, 'count': 1, 'items': [JOB]})
        if self.path.startswith('/api/routines/runs'):
            if state['runs'] != 200: return self.reply(state['runs'], {'error': {'code': 'not_found'}})
            return self.reply(200, {'runs': [
                {'id': 'rr_1', 'routineId': 'brief', 'status': 'running', 'firedAt': '2026-10-21T19:40:00Z', 'jobId': 'qj_9', 'globalMsgNum': 3100, 'preview': 'SECRET'},
                {'id': 'rr_2', 'routineId': 'brief', 'status': 'completed', 'firedAt': '2026-10-21T12:04:00Z'},
            ]})
        if self.path == '/api/routines':
            return self.reply(200, {'routines': [{'id': 'brief', 'name': 'Morning brief', 'instruction': 'SECRET'}]})
        if self.path == '/api/welcome-context':
            if state['welcome'] != 200: return self.reply(state['welcome'], {})
            return self.reply(200, {'weather': {'temp': 71}, 'nextEvent': {'title': 'Northwind renewal', 'time': '2026-10-21T20:30:00Z', 'inMinutes': 43}})
        self.reply(404, {})

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port))
def run(args):
    out = subprocess.run([helper, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=30)
    return json.loads(out.stdout)
try:
    probe = run(['activity-today', '--probe'])
    assert probe['ok'] and probe['details']['activeQueryJobs'] is True, probe
    assert '/api/query-jobs/active' not in calls and '/api/welcome-context' not in calls, 'a probe alone reads health and routines, never the jobs or the calendar'
    for features in ({}, {'activeQueryJobs': True}, {'activeQueryJobs': True, 'activeQueryJobsProtocol': 2}, {'activeQueryJobs': 'yes', 'activeQueryJobsProtocol': 1}):
        state['features'] = features
        assert run(['activity-today', '--probe'])['details']['activeQueryJobs'] is False, features
    state['features'] = {'activeQueryJobs': True, 'activeQueryJobsProtocol': 1}

    calls.clear()
    full = run(['activity-today', '--jobs', '--calendar'])
    assert full['ok'], full
    jobs = full['details']['queryJobs']
    assert jobs['available'] is True and jobs['count'] == 1 and jobs['items'][0]['jobId'] == 'qj_1' and jobs['items'][0]['messageNo'] == 3120, jobs
    text = json.dumps(full)
    assert 'SECRET' not in text, 'never an answer, a prompt, a trail, a preview or a routine instruction'
    assert 'temp' not in text and 'weather' not in text, 'never the weather'
    runs = full['details']['routines']
    assert runs['available'] and [r['id'] for r in runs['runs']] == ['rr_1'] and runs['runs'][0]['label'] == 'Morning brief' and runs['runs'][0]['messageNo'] == 3100, runs
    assert full['details']['calendar'] == {'available': True, 'nextEvent': {'title': 'Northwind renewal', 'time': '2026-10-21T20:30:00Z', 'inMinutes': 43}}
    assert calls == ['/api/query-jobs/active', '/api/routines/runs?limit=20', '/api/routines', '/api/welcome-context'], ('serial reads, in order', calls)

    state['active'] = 400
    old = run(['activity-today', '--jobs'])
    assert old['ok'] and old['details']['queryJobs'] == {'available': False}, 'an older server is unavailable, never an error'
    state['active'] = 200
    state['runs'] = 404; state['welcome'] = 404
    older = run(['activity-today', '--calendar'])
    assert older['ok'] and older['details']['routines'] == {'available': False} and older['details']['calendar'] == {'available': False}, older
    state['runs'] = 200; state['welcome'] = 200
    calls.clear()
    run(['activity-today'])
    assert '/api/welcome-context' not in calls and '/api/query-jobs/active' not in calls, 'the calendar and the jobs only when asked'
    server.shutdown(); server.server_close()
    down = run(['activity-today', '--jobs'])
    assert not down['ok'] and down['message'] == 'Server not reachable', down
    print('PASS compiled helper: activity-today probe by capability, listed job fields only, running routine runs with names, one calendar event, older server unavailable, unreachable reported')
finally:
    try: server.shutdown()
    except Exception: pass
    shutil.rmtree(root)
