#!/usr/bin/env python3
"""0.5.372 Drop it P2 (server 6.99.11): the compiled helper's P2 drop-it ops against a private loopback fixture. No real server,
account or credentials. Pins: banners, reminders, p2 and p2-set reach exactly their route with the token; the banner cursor is
validated; a P2 settings change crosses only known sections and keys, typed, and anything else is refused before the server; the
answers keep only the contract's keys; the new chat actions (dismiss, reminder_done, snooze_1h, snooze_tomorrow, when:*) are
accepted and anything else refused. Prints "drop it p2 helper checks: N passed". Usage: drop-it-p2-helper-checks.py <helper>"""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

DROP = '1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed'
ITEM = 'fi_' + 'a' * 32
SETTINGS = {
    'pings': {'on': True, 'dailyCap': 6, 'perSource': 2, 'gapMinutes': 45, 'quietStart': '18:00', 'quietEnd': '06:00', 'weekendsQuiet': True,
              'firstBanner': '08:00', 'sources': {'prep': True, 'agent': True, 'followups': True, 'stale': True, 'signals': True}},
    'followUps': {'on': True, 'kinds': {'card': True, 'handoff': True, 'session': True, 'thread': True}},
    'checkin': {'on': True, 'weekday': 1, 'time': '09:00'},
    'reminders': {'defaultTime': '09:00', 'snoozeMinutes': 60, 'banners': True, 'lensPush': True},
    'banners': {'reminder': True, 'resolution': True, 'prep': False, 'agent': False, 'followups': False, 'stale': False, 'checkin': False},
    'steer': {'about': 'JCK, Rain', 'leaveAlone': 'HubDB'},
}
BANNER = {'seq': 3, 'at': '2026-11-05T13:00:00.000Z', 'title': 'Reminder', 'line': 'Call Silas', 'feedIds': [ITEM, 'bad'], 'sources': ['reminder', 'nope'],
          'exempt': True, 'notifyId': 'reminder-' + DROP, 'ledger': 'SECRET'}

with tempfile.TemporaryDirectory(prefix='cos-drop-it-p2-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'e' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    state = {'status': 200, 'body': {}}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token, data.decode() if data else None))
            raw = json.dumps(state['body']).encode()
            self.send_response(state['status']); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_PUT = do_POST = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, stdin=None):
        result = subprocess.run([sys.argv[1], 'drop-it', *args], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=40)
        out, err = result.stdout.decode(), result.stderr.decode()
        assert token not in out and token not in err, 'token leaked'
        try:
            return json.loads(out)
        except ValueError:
            return {'ok': False, 'message': (out + err)[:300], 'details': {}}

    checks = 0
    def check(value, name):
        global checks
        if not value:
            print('drop it p2 helper check FAILED: ' + name); server.shutdown(); sys.exit(1)
        checks += 1
    def body(): return json.loads(requests[-1][3]) if requests[-1][3] else None

    try:
        # ── banners
        state['body'] = {'bootId': 'fc2c37b834ed38cf', 'seq': 3, 'banners': [BANNER, {'seq': 0, 'title': 'bad'}]}
        d = run('--op', 'banners')['details']
        check(requests[-1][:3] == ('GET', '/api/inbox/banners', True), 'banners with no cursor reads the whole outbox')
        check(d['bootId'] == 'fc2c37b834ed38cf' and d['seq'] == 3 and len(d['banners']) == 1, 'banners keeps good rows: ' + json.dumps(d)[:200])
        check(d['banners'][0] == {'seq': 3, 'at': '2026-11-05T13:00:00.000Z', 'title': 'Reminder', 'line': 'Call Silas', 'feedIds': [ITEM],
                                  'sources': ['reminder'], 'exempt': True, 'notifyId': 'reminder-' + DROP}, 'a banner keeps only its contract keys and good ids')
        run('--op', 'banners', '--boot', 'fc2c37b834ed38cf', '--seq', '3')
        check(requests[-1][1] == '/api/inbox/banners?bootId=fc2c37b834ed38cf&seq=3', 'the cursor goes as bootId and seq')
        state['body'] = {'bootId': 'b', 'seq': 1, 'banners': [dict(BANNER, notifyId='work-x')]}
        check('notifyId' not in run('--op', 'banners')['details']['banners'][0], 'a notifyId that is not reminder-<drop> does not cross')
        prior = len(requests)
        for args in [('--boot', 'a b'), ('--boot', 'x', '--seq', '-1'), ('--seq', '1234567890'), ('--boot', 'x' * 65)]:
            check(not run('--op', 'banners', *args)['ok'], f'banners refuses {args}')
        check(len(requests) == prior, 'a refused cursor never reaches the server')

        # ── reminders
        state['body'] = {'reminders': [{'id': DROP, 'at': '2026-11-05T15:00:00.000Z', 'title': 'Reminder: call Silas', 'notifyId': 'reminder-' + DROP, 'x': 1},
                                       {'id': DROP, 'at': '2026-11-05T15:00:00.000Z', 'title': 't', 'notifyId': 'reminder-other'}]}
        d = run('--op', 'reminders')['details']
        check(requests[-1][:3] == ('GET', '/api/drops/reminders', True), 'reminders reads GET /api/drops/reminders')
        check(d['reminders'] == [{'id': DROP, 'at': '2026-11-05T15:00:00.000Z', 'title': 'Reminder: call Silas', 'notifyId': 'reminder-' + DROP}],
              'a reminder keeps its four keys, and its notifyId must be reminder-<its id>')

        # ── p2 settings
        state['body'] = {'protocol': 1, 'settings': dict(SETTINGS, extra={'x': 1}), 'defaults': SETTINGS}
        d = run('--op', 'p2')['details']
        check(requests[-1][:3] == ('GET', '/api/drops/settings/p2', True), 'p2 reads GET /api/drops/settings/p2')
        check(d['protocol'] == 1 and d['settings'] == SETTINGS and set(d) == {'transport', 'httpStatus', 'protocol', 'settings'}, 'p2 carries protocol and the known settings only')
        for change in [{'pings': {'dailyCap': 50}}, {'pings': {'sources': {'prep': False}}}, {'steer': {'leaveAlone': 'HubDB, standup'}},
                       {'checkin': {'weekday': 2, 'time': '10:30'}}, {'reminders': {'banners': False}}, {'banners': {'prep': True}}]:
            run('--op', 'p2-set', stdin=json.dumps(change).encode())
            check(requests[-1][:3] == ('PUT', '/api/drops/settings/p2', True) and body() == change, f'p2-set sends exactly {change}')
        prior = len(requests)
        for bad in [{}, {'nope': {'on': True}}, {'pings': {}}, {'pings': {'on': 'yes'}}, {'pings': {'quietStart': '25:00'}}, {'pings': {'dailyCap': 1.5}},
                    {'pings': {'sources': {'prep': 1}}}, {'pings': {'sources': {'other': True}}}, {'steer': {'about': 'x' * 301}},
                    {'steer': {'about': 'a\u0007b'}}, {'pings': {'extra': True}}, {'pings': 'on'}, []]:
            check(not run('--op', 'p2-set', stdin=json.dumps(bad).encode())['ok'], f'p2-set refuses {str(bad)[:60]}')
        check(not run('--op', 'p2-set', stdin=b'not json')['ok'], 'p2-set refuses a body that is not JSON')
        check(len(requests) == prior, 'a refused change never reaches the server')

        # ── the new chat actions
        state['body'] = {'unread': 0, 'waiting': 1, 'version': 4}
        for action in ['dismiss', 'reminder_done', 'snooze_1h', 'snooze_tomorrow', 'when:tomorrow_9', 'when:monday_9']:
            run('--op', 'action', '--item', ITEM, '--action', action)
            check(requests[-1][:3] == ('POST', '/api/inbox/action', True) and body() == {'itemId': ITEM, 'action': action}, f'action {action} goes')
        prior = len(requests)
        for action in ['snooze', 'when:friday', 'reminder_done ', 'dismiss;x', 'when:2026-11-05T15:00:00Z']:
            check(not run('--op', 'action', '--item', ITEM, '--action', action)['ok'], f'action refuses {action}')
        check(len(requests) == prior, 'a refused action never reaches the server')
    finally:
        server.shutdown()
    print(f'drop it p2 helper checks: {checks} passed')
