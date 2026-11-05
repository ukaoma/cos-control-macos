#!/usr/bin/env python3
"""0.5.371 Drop it (server Drop it P1): the compiled helper's drop-it verb against a private loopback fixture. No real server,
account, or credentials. Pins: every op's method, path and body exactly, with the token header; the words only on stdin (never
argv) and never on stderr; a refused argument never reaches the server; every answer is ok with transport and httpStatus; a 404
drop_it_off is `off`, a 404 that is not JSON `unsupported`; a refusal is the server's code and its plain line and nothing else;
only the contract's keys cross on a 200 (no feed `key`, no `route`, no `sourceId`, no stray field); an unreachable server and a
missing token are their own transports. Prints "drop it helper checks: N passed". Usage: drop-it-helper-checks.py <helper>"""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

DROP = '1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed'
JOB = '6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b'
ITEM = 'fi_' + 'a' * 32
WORDS = 'send Gina the Zanzibar numbers'

LINK = {'kind': 'card', 'id': 'wid_123', 'label': 'Quilt', 'domain': 'quilt', 'created': True, 'sourceId': 'SECRET'}
FEED_ITEM = {'id': ITEM, 'kind': 'receipt', 'threadId': DROP, 'createdAt': '2026-11-04T19:12:00.000Z', 'readAt': '2026-11-04T19:12:00.000Z',
             'source': 'cos', 'title': 'Filed to Work, Quilt', 'line': 'New card in the Inbox.', 'links': [LINK],
             'actions': [{'id': 'open_card', 'label': 'Open card'}, {'id': 'undo', 'label': 'Undo'}, {'id': 'move', 'label': 'Move'}],
             'state': 'live', 'undoUntil': '2026-11-05T19:12:00.000Z', 'key': 'SECRET:receipt:1'}
VIEW = {'id': DROP, 'text': WORDS, 'source': 'mac', 'createdAt': '2026-11-04T19:12:00.000Z', 'updatedAt': '2026-11-04T19:12:01.000Z',
        'state': 'filed', 'dest': 'new_card', 'kind': 'task', 'status': 'open', 'links': [LINK], 'route': {'by': 'jev', 'p': 0.9, 'provider': 'SECRET'},
        'undoUntil': '2026-11-05T19:12:00.000Z', 'canUndo': True, 'timeline': ['SECRET']}
ANSWER = {'drop': VIEW, 'items': [FEED_ITEM], 'replayed': False}

with tempfile.TemporaryDirectory(prefix='cos-drop-it-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'e' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    state = {'status': 200, 'body': ANSWER}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def answer(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token, data.decode('utf-8', 'replace') if data else None,
                             {'type': self.headers.get('Content-Type'), 'name': self.headers.get('X-COS-Filename'), 'raw': data}))
            if state['body'] is None:
                raw = b'<!DOCTYPE html><pre>Cannot GET</pre>'; self.send_response(state['status']); self.send_header('Content-Type', 'text/html')
                self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            raw = json.dumps(state['body']).encode()
            self.send_response(state['status']); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET = do_PUT = do_POST = answer

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, port=None, stdin=None):
        e = dict(env, COS_CONTROL_TEST_API_PORT=str(port)) if port else env
        assert not any('Zanzibar' in a for a in args), 'the words reached argv'
        result = subprocess.run([sys.argv[1], 'drop-it', *args], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=40)
        out, err = result.stdout.decode(), result.stderr.decode()
        assert token not in out and token not in err, 'token leaked'
        assert 'Zanzibar' not in err, 'the words reached stderr'
        try:
            return json.loads(out)
        except ValueError:
            return {'ok': False, 'message': (out + err)[:300], 'details': {}}

    checks = 0
    def check(value, name):
        global checks
        if not value:
            print(f'drop it helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    def body(): return json.loads(requests[-1][3]) if requests[-1][3] else None

    try:
        # ── submit: the words on stdin, cleaned, the source this Mac
        got = run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': '  ' + WORDS + '\r\n'}).encode())
        check(requests[-1][:3] == ('POST', '/api/drops', True) and body() == {'dropId': DROP, 'text': WORDS, 'source': 'mac'}, 'submit posts exactly the id, the trimmed words and source mac')
        d = got['details']
        check(got['ok'] and d['transport'] == 'answered' and d['httpStatus'] == 200, 'a 200 is answered')
        check(set(d) == {'transport', 'httpStatus', 'drop', 'items', 'replayed'}, 'a DropAnswer carries drop, items, replayed: ' + str(sorted(d)))
        check(set(d['drop']) == {'id', 'text', 'source', 'createdAt', 'updatedAt', 'state', 'dest', 'kind', 'status', 'links', 'undoUntil', 'canUndo'}, 'the drop keeps only the contract keys (no route, no timeline)')
        check(d['drop']['links'] == [{'kind': 'card', 'id': 'wid_123', 'label': 'Quilt', 'domain': 'quilt', 'created': True}], 'a link drops sourceId')
        check(set(d['items'][0]) == {'id', 'kind', 'threadId', 'createdAt', 'readAt', 'source', 'title', 'line', 'links', 'actions', 'state', 'undoUntil'}, 'a feed item drops its key')
        check('SECRET' not in json.dumps(got), 'no stray server field crosses')
        run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': WORDS, 'hint': {'sessionId': 'claude:abc-123', 'label': 'Kickoff deck'}}).encode())
        check(body() == {'dropId': DROP, 'text': WORDS, 'source': 'mac', 'hint': {'sessionId': 'claude:abc-123', 'label': 'Kickoff deck'}}, 'a session hint goes as given')
        state['body'] = dict(ANSWER, next={'kind': 'ask', 'prompt': 'what did Jeremy say?'}, drop=dict(VIEW, dest='ask', kind='ask', state='asked'))
        check(run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': 'what did Jeremy say?'}).encode())['details']['next'] == {'kind': 'ask', 'prompt': 'what did Jeremy say?'}, 'next ask crosses')
        state['body'] = ANSWER

        prior = len(requests)
        for bad in ({'dropId': DROP.upper(), 'text': 'x'}, {'dropId': DROP, 'text': '   '}, {'dropId': DROP, 'text': 'a\u0007b'}, {'dropId': DROP, 'text': 'x', 'source': 'web'},
                    {'dropId': DROP, 'text': 'a' * 2001}, {'dropId': DROP, 'text': 'x', 'hint': {'sessionId': 'a b'}}, {'dropId': DROP, 'text': 'x', 'extra': 1}):
            check(not run('--op', 'submit', stdin=json.dumps(bad).encode())['ok'], f'submit refuses {str(bad)[:60]}')
        check(not run('--op', 'submit', stdin=b'not json')['ok'], 'submit refuses a body that is not JSON')
        check(run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': 'a' * 2000}).encode())['ok'], '2,000 characters go')
        check(len(requests) == prior + 1, 'a refused submit never reaches the server')

        # ── 0.5.371: a drop's files (server 6.99.13), and the composer's uploads
        MA, MB = 'm_' + 'a' * 24, 'm_' + 'b' * 24
        run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': WORDS, 'attachmentIds': [MA, MB]}).encode())
        check(body() == {'dropId': DROP, 'text': WORDS, 'source': 'mac', 'attachmentIds': [MA, MB]}, 'submit carries the files ids as given')
        prior = len(requests)
        for bad in ([], [MA, MA], ['m_x'], [MA] * 6, 'm_' + 'a' * 24, [MA, 'm_' + 'c' * 23, MB, 'm_d', 'm_e', 'm_f']):
            check(not run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': 'x', 'attachmentIds': bad}).encode())['ok'], f'submit refuses attachmentIds {str(bad)[:40]}')
        check(len(requests) == prior, 'a refused file list never reaches the server')
        state['body'] = dict(ANSWER, next={'kind': 'ask', 'prompt': 'what is in this?', 'attachmentIds': [MA, 'bad']}, drop=dict(VIEW, dest='ask', kind='ask', state='asked'))
        check(run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': 'what is in this?'}).encode())['details']['next'] == {'kind': 'ask', 'prompt': 'what is in this?'},
              'next ask with a bad id list carries no files')
        state['body'] = dict(ANSWER, next={'kind': 'ask', 'prompt': 'what is in this?', 'attachmentIds': [MA]}, drop=dict(VIEW, dest='ask', kind='ask', state='asked'))
        check(run('--op', 'submit', stdin=json.dumps({'dropId': DROP, 'text': 'what is in this?'}).encode())['details']['next'] == {'kind': 'ask', 'prompt': 'what is in this?', 'attachmentIds': [MA]},
              'next ask carries its files ids')
        files = home / 'Zanzibar files'; files.mkdir()
        photo = files / 'Zanzibar store.jpg'; photo.write_bytes(b'\xff\xd8\xff' + b'p' * 500)
        pdf = files / 'Zanzibar Q4 deck.pdf'; pdf.write_bytes(b'%PDF-1.4\n' + b'd' * 900)
        state['body'] = {'attachments': [{'id': MA, 'kind': 'user_photo', 'path': 'SECRET'}]}
        got = run('--op', 'upload', stdin=json.dumps({'path': str(photo), 'name': 'Zanzibar store.jpg', 'kind': 'photo', 'mime': 'image/jpeg', 'capturedAt': '2026-11-05T12:00:00Z'}).encode())
        sent = body()
        import base64
        check(requests[-1][:3] == ('POST', '/api/media', True) and sent['kind'] == 'user_photo' and len(sent['images']) == 1
              and base64.b64decode(sent['images'][0]['data']) == photo.read_bytes() and sent['images'][0]['label'] == 'Zanzibar store.jpg'
              and sent['images'][0]['capturedAt'] == '2026-11-05T12:00:00Z', 'a photo goes base64 to /api/media as a user photo')
        check(got['details'] == {'transport': 'answered', 'httpStatus': 200, 'mediaId': MA}, 'the photo answer is its media id only')
        state['body'] = {'attachment': {'id': MB, 'kind': 'user_document', 'mime': 'application/pdf'}}
        got = run('--op', 'upload', stdin=json.dumps({'path': str(pdf), 'name': 'Zanzibar Q4 deck.pdf', 'kind': 'doc', 'mime': 'application/pdf', 'capturedAt': '2026-11-05T12:00:00Z'}).encode())
        check(requests[-1][:3] == ('POST', '/api/media/file', True) and requests[-1][4]['raw'] == pdf.read_bytes() and requests[-1][4]['type'] == 'application/pdf'
              and requests[-1][4]['name'] == 'Zanzibar%20Q4%20deck.pdf', 'a document goes raw to /api/media/file with its type and encoded name')
        check(got['details'] == {'transport': 'answered', 'httpStatus': 200, 'mediaId': MB}, 'the file answer is its media id only')
        state['status'] = 413; state['body'] = {'error': 'file_too_large', 'maxBytes': 1}
        check(run('--op', 'upload', stdin=json.dumps({'path': str(pdf), 'name': 'd.pdf', 'kind': 'doc', 'mime': 'application/pdf'}).encode())['details']
              == {'transport': 'answered', 'httpStatus': 413, 'error': 'file_too_large'}, 'an upload refusal is its code')
        state['status'] = 200; state['body'] = ANSWER
        big = files / 'big.jpg'; big.write_bytes(b'x' * (2 * 1024 * 1024 + 1))
        prior = len(requests)
        for bad in ({'path': 'relative.pdf', 'name': 'a.pdf', 'kind': 'doc', 'mime': 'application/pdf'},
                    {'path': str(files / 'missing.pdf'), 'name': 'a.pdf', 'kind': 'doc', 'mime': 'application/pdf'},
                    {'path': str(files), 'name': 'a.pdf', 'kind': 'doc', 'mime': 'application/pdf'},
                    {'path': str(pdf), 'name': 'a.pdf', 'kind': 'doc', 'mime': 'application/x-msdownload'},
                    {'path': str(pdf), 'name': 'a.pdf', 'kind': 'exe', 'mime': 'application/pdf'},
                    {'path': str(photo), 'name': 'a.jpg', 'kind': 'photo', 'mime': 'image/png'},
                    {'path': str(big), 'name': 'big.jpg', 'kind': 'photo', 'mime': 'image/jpeg'},
                    {'path': str(pdf), 'name': 'a\u0007.pdf', 'kind': 'doc', 'mime': 'application/pdf'},
                    {'path': str(pdf), 'name': 'a.pdf', 'kind': 'doc', 'mime': 'application/pdf', 'extra': 1}):
            check(not run('--op', 'upload', stdin=json.dumps(bad).encode())['ok'], f'upload refuses {str(bad)[-60:]}')
        check(len(requests) == prior, 'a refused upload never reaches the server')
        state['body'] = dict(ANSWER, drop=dict(VIEW, attachments=[{'id': MA, 'name': 'Q4 deck.pdf', 'mime': 'application/pdf', 'kind': 'user_document', 'bytes': 9}]),
                             items=[dict(FEED_ITEM, links=[{'kind': 'file', 'id': MA, 'label': 'Q4 deck.pdf'}])])
        d = run('--op', 'get', '--drop', DROP)['details']
        check(d['drop'] and 'attachments' not in d['drop'] and d['items'][0]['links'] == [{'kind': 'file', 'id': MA, 'label': 'Q4 deck.pdf'}], 'a drop with attachments decodes and its file links cross')
        state['body'] = {'protocol': 1, 'enabled': True, 'source': 'settings', 'attachments': 5, 'p2Settings': 1}
        check(run('--op', 'settings')['details'] == {'transport': 'answered', 'httpStatus': 200, 'protocol': 1, 'enabled': True, 'source': 'settings', 'attachments': 5}, 'settings carries attachments when sent')
        state['body'] = ANSWER

        # ── the other ops' requests
        cases = [
            (['--op', 'settings'], None, ('GET', '/api/drops/settings'), None),
            (['--op', 'settings-set', '--enabled', 'true'], None, ('PUT', '/api/drops/settings'), {'enabled': True}),
            (['--op', 'settings-set', '--enabled', 'false'], None, ('PUT', '/api/drops/settings'), {'enabled': False}),
            (['--op', 'get', '--drop', DROP], None, ('GET', '/api/drops/' + DROP), None),
            (['--op', 'undo', '--drop', DROP], None, ('POST', f'/api/drops/{DROP}/undo'), {}),
            (['--op', 'sent', '--drop', DROP], None, ('POST', f'/api/drops/{DROP}/sent'), {}),
            (['--op', 'move', '--drop', DROP], {'dest': 'thread', 'target': {'id': 'thr_9', 'label': 'Kickoff 2027 Planning'}}, ('POST', f'/api/drops/{DROP}/move'), {'dest': 'thread', 'target': {'id': 'thr_9', 'label': 'Kickoff 2027 Planning'}}),
            (['--op', 'move', '--drop', DROP], {'dest': 'new_card', 'target': {'id': 'quilt', 'label': 'Quilt', 'domain': 'quilt'}}, ('POST', f'/api/drops/{DROP}/move'), {'dest': 'new_card', 'target': {'id': 'quilt', 'label': 'Quilt', 'domain': 'quilt'}}),
            (['--op', 'ask', '--drop', DROP, '--job', JOB, '--generation', '1'], None, ('POST', f'/api/drops/{DROP}/ask'), {'clientJobId': JOB, 'generation': 1}),
            (['--op', 'summary'], None, ('GET', '/api/inbox/summary'), None),
            (['--op', 'feed'], None, ('GET', '/api/inbox/feed'), None),
            (['--op', 'feed', '--after', ITEM, '--limit', '50'], None, ('GET', f'/api/inbox/feed?after={ITEM}&limit=50'), None),
            (['--op', 'read', '--through', ITEM], None, ('POST', '/api/inbox/read'), {'through': ITEM}),
            (['--op', 'action', '--item', ITEM, '--action', 'choose:o1'], None, ('POST', '/api/inbox/action'), {'itemId': ITEM, 'action': 'choose:o1'}),
            (['--op', 'action', '--item', ITEM, '--action', 'undo'], None, ('POST', '/api/inbox/action'), {'itemId': ITEM, 'action': 'undo'}),
            (['--op', 'history'], {'q': 'Zanzibar numbers', 'kind': 'task', 'status': 'done', 'limit': 50}, ('GET', '/api/drops?q=Zanzibar%20numbers&kind=task&status=done&limit=50'), None),
            (['--op', 'history'], {}, ('GET', '/api/drops'), None),
        ]
        for args, stdin, route, sent in cases:
            run(*args, stdin=json.dumps(stdin).encode() if stdin is not None else None)
            check(requests[-1][:2] == route and requests[-1][2], f'{" ".join(args[:2])} is {route}')
            check(body() == sent, f'{" ".join(args[:2])} sends {sent}')

        prior = len(requests)
        for args, stdin in ((['--op', 'nope'], None), (['--op', 'get', '--drop', 'x'], None), (['--op', 'undo'], None), (['--op', 'settings-set', '--enabled', 'yes'], None),
                            (['--op', 'move', '--drop', DROP], {'dest': 'ask'}), (['--op', 'move', '--drop', DROP], {'dest': 'thread', 'target': {'id': 'a b', 'label': 'x'}}),
                            (['--op', 'ask', '--drop', DROP, '--job', 'nope', '--generation', '1'], None), (['--op', 'ask', '--drop', DROP, '--job', JOB, '--generation', '0'], None),
                            (['--op', 'feed', '--after', 'fi_x'], None), (['--op', 'feed', '--limit', '500'], None), (['--op', 'read', '--through', DROP], None),
                            (['--op', 'action', '--item', ITEM, '--action', 'move'], None), (['--op', 'history'], {'kind': 'ping'}), (['--op', 'history'], {'status': 'any'}),
                            (['--op', 'history'], {'q': 'x' * 201}), (['--op', 'history'], {'limit': 0})):
            check(not run(*args, stdin=json.dumps(stdin).encode() if stdin is not None else None)['ok'], f'refuses {args} {stdin}')
        check(len(requests) == prior, 'a refused call never reaches the server')

        # ── 200 shapes
        state['body'] = {'protocol': 1, 'enabled': True, 'source': 'settings', 'router': {'on': True, 'dailyCap': 300000}}
        check(run('--op', 'settings')['details'] == {'transport': 'answered', 'httpStatus': 200, 'protocol': 1, 'enabled': True, 'source': 'settings'}, 'settings carries protocol, enabled and source only')
        state['body'] = {'protocol': 1, 'enabled': False, 'source': 'env', 'savedButEnvWins': True}
        check(run('--op', 'settings-set', '--enabled', 'true')['details'] == {'transport': 'answered', 'httpStatus': 200, 'protocol': 1, 'enabled': False, 'source': 'env', 'savedButEnvWins': True}, 'an environment value that wins says so')
        state['body'] = {'unread': 2, 'lastLine': 'Heads up. Kickoff at 3:00.', 'lastAt': '2026-11-04T20:00:00.000Z', 'version': 7, 'extra': 'SECRET'}
        check(run('--op', 'summary')['details'] == {'transport': 'answered', 'httpStatus': 200, 'unread': 2, 'lastLine': 'Heads up. Kickoff at 3:00.', 'lastAt': '2026-11-04T20:00:00.000Z', 'version': 7}, 'summary carries its four keys')
        state['body'] = {'unread': 1, 'lastLine': 'x', 'lastAt': None, 'version': 7, 'waiting': 3}
        check(run('--op', 'summary')['details'] == {'transport': 'answered', 'httpStatus': 200, 'unread': 1, 'lastLine': 'x', 'lastAt': None, 'version': 7, 'waiting': 3}, 'summary carries waiting when the server sends it')
        state['body'] = {'unread': 1, 'lastLine': 'x', 'lastAt': None, 'version': 7, 'waiting': 'many'}
        check('waiting' not in run('--op', 'summary')['details'], 'a waiting that is not a number does not cross')
        state['body'] = {'items': [FEED_ITEM, {'id': 'bad'}, dict(FEED_ITEM, kind='broadcast')], 'version': 3, 'more': False}
        d = run('--op', 'feed')['details']
        check(len(d['items']) == 1 and d['version'] == 3 and d['more'] is False and 'key' not in d['items'][0], 'feed keeps good rows only, without their key')
        state['body'] = {'drops': [VIEW, {'id': 'nope'}], 'more': True, 'cardStates': 'read'}
        d = run('--op', 'history', stdin=b'{}')['details']
        check(len(d['drops']) == 1 and d['more'] is True and d['cardStates'] == 'read' and 'route' not in d['drops'][0], 'history keeps good drops, without route')
        state['body'] = {'unread': 0, 'version': 8}
        check(run('--op', 'read', '--through', ITEM)['details'] == {'transport': 'answered', 'httpStatus': 200, 'unread': 0, 'version': 8}, 'read answers unread and version')
        state['body'] = dict(ANSWER, drop=dict(VIEW, state='asking', dest=None, choices=[{'id': 'o1', 'dest': 'new_card', 'label': 'A task', 'detail': 'In Quilt', 'target': {'id': 'quilt', 'label': 'Quilt', 'domain': 'quilt', 'x': 'SECRET'}}, {'id': 'note', 'dest': 'note', 'label': 'Just a note', 'detail': ''}]))
        d = run('--op', 'get', '--drop', DROP)['details']
        check(d['drop']['dest'] is None and d['drop']['choices'][0] == {'id': 'o1', 'dest': 'new_card', 'label': 'A task', 'detail': 'In Quilt', 'target': {'id': 'quilt', 'label': 'Quilt', 'domain': 'quilt'}} and len(d['drop']['choices']) == 2, 'choices cross with their targets')

        # ── every status an answer, off and unsupported
        state['status'] = 404; state['body'] = {'error': {'code': 'drop_it_off', 'message': 'Drop it is off on this server.'}}
        check(run('--op', 'summary')['details'] == {'transport': 'off', 'httpStatus': 404, 'error': 'drop_it_off', 'message': 'Drop it is off on this server.'}, 'drop_it_off is off')
        state['body'] = None
        check(run('--op', 'summary')['details'] == {'transport': 'unsupported', 'httpStatus': 404}, 'a 404 page that is not JSON is unsupported (a server from before the routes)')
        state['status'] = 409; state['body'] = {'error': {'code': 'edited', 'message': 'The card was changed since, so Undo leaves it alone.'}, 'stack': 'SECRET'}
        check(run('--op', 'undo', '--drop', DROP)['details'] == {'transport': 'answered', 'httpStatus': 409, 'error': 'edited', 'message': 'The card was changed since, so Undo leaves it alone.'}, 'a refusal is its code and plain line')
        state['status'] = 400; state['body'] = {'error': {'code': 'some_new_code', 'message': 'A label is too long.'}}
        check(run('--op', 'move', '--drop', DROP, stdin=b'{"dest":"memory"}')['details'] == {'transport': 'answered', 'httpStatus': 400, 'error': 'some_new_code', 'message': 'A label is too long.'}, 'an unknown code still carries its plain line')
        state['status'] = 500; state['body'] = {'error': {'code': 'Not A Code', 'message': 'line one\nline two'}}
        check(run('--op', 'summary')['details'] == {'transport': 'answered', 'httpStatus': 500}, 'a code outside the grammar and a multi-line message carry nothing')
        state['status'] = 200; state['body'] = ANSWER

        # ── no server, no token
        sock = socket.socket(); sock.bind(('127.0.0.1', 0)); dead = sock.getsockname()[1]; sock.close()
        check(run('--op', 'summary', port=dead)['details'] == {'transport': 'unavailable'}, 'nothing listening: unavailable')
        env_file.rename(home / '.cos-glasses/.env.away')
        check(run('--op', 'summary')['details'] == {'transport': 'no_token'}, 'no pairing token: its own transport')
        (home / '.cos-glasses/.env.away').rename(env_file)
    finally:
        server.shutdown()
    print(f'drop it helper checks: {checks} passed')
