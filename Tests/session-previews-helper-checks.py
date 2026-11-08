#!/usr/bin/env python3
"""0.5.380 (preview engine phase 1, plan item 6): the compiled helper's session-previews and session-preview-fetch against a
private loopback fixture. No real server, account, or credentials.

session-previews: GET /api/agent-sessions/:provider/:id?turns=40 with the token; only the contract's keys cross, each
checked (the id's prefix matches its source, base names only, known kinds and reasons, no path, no notice); a name marked
secret_file or blocked_name is never available whatever its state; a message marked previewsOff carries nothing; no
recent_turns is `absent`; 404 is `missing`; an unreachable server and a missing token are their own states.

session-preview-fetch (stdin): the route each id prefix uses (Control Web's), a refused request never reaches the server,
403 previews_off / secret_file_denied / blocked_name, a 404 that is not JSON (`absent`), a JSON 404 (`missing`), 413 and a
non-picture on a picture route each answer their state and write nothing; a ready copy lands in
Library/Caches/com.gotcos.COSControl/SessionPreviews/<uuid>/<base name> with folder 0700 and file 0600, and the token never
reaches stdout or stderr.
Prints "session previews helper checks: N passed". Usage: session-previews-helper-checks.py <helper>"""
import json, os, pathlib, socket, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

SESSION = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
A, B, C, D = 'a' * 64, 'b' * 64, 'c' * 64, 'd' * 64
JPEG = b'\xff\xd8\xff\xe0' + b'\x00' * 60
PNG = b'\x89PNG\r\n\x1a\n' + b'\x00' * 60

# A home with a space, like the real one ("Ukaoma Chief Of Staff" sits in Miles's paths), under /tmp as the helper requires.
with tempfile.TemporaryDirectory(prefix='cos session-previews-', dir='/tmp') as tmp:
    home = pathlib.Path(tmp); (home / '.cos-glasses').mkdir()
    token = 'f' * 64
    env_file = home / '.cos-glasses/.env'; env_file.write_text('COS_API_TOKEN=' + token + '\n'); env_file.chmod(0o600)
    root = home / 'Library/Caches/com.gotcos.COSControl/SessionPreviews'

    detail = {'session_id': SESSION, 'recent_turns': [
        {'role': 'user', 'text': 'look', 'at': '2026-11-08T10:00:00.000Z',
         'toolImages': [{'id': 'ti_' + A, 'tool': 'Attached', 'index': 1, 'total': 2, 'state': 'available'},
                        {'id': 'ti_' + B, 'tool': 'Hacker', 'index': 9, 'total': 2, 'state': 'available', 'path': '/Users/x/shot.png'}],
         'toolImagesMore': 3},
        {'role': 'assistant', 'text': 'see [plan](cos-file:0)', 'at': '2026-11-08T10:01:00.000Z',
         'outputImages': [{'id': 'ai_' + A, 'label': 'shot.png', 'state': 'available'},
                          {'id': 'af_' + A, 'label': 'wrong-prefix.png', 'state': 'available'}],
         'outputFiles': [{'id': 'af_' + A, 'name': '/Users/ukaoma/secret dir/Q3 plan.pdf', 'kind': 'pdf', 'type': 'PDF', 'size': 1234, 'state': 'available'},
                         {'id': 'af_' + B, 'name': '.env', 'kind': 'text', 'type': 'Text', 'state': 'available', 'reason': 'secret_file',
                          'notice': 'server words'},
                         {'id': 'af_' + C, 'name': 'gone.md', 'kind': 'text', 'type': 'Markdown', 'state': 'unavailable', 'reason': 'missing'},
                         {'id': 'af_' + D, 'name': 'odd.md', 'kind': 'weird', 'type': 'Markdown', 'state': 'unavailable', 'reason': 'made_up'}],
         'outputLinks': [{'id': 'al_' + A, 'label': 'the plan', 'name': 'PLAN.md', 'kind': 'markdown', 'type': 'Markdown', 'size': 4210, 'line': 42,
                          'state': 'available'},
                         {'id': 'al_' + B, 'label': 'key', 'name': 'x-key.json', 'kind': 'code', 'type': 'JSON', 'state': 'unavailable',
                          'reason': 'blocked_name'},
                         {'id': 'al_' + 'A' * 64, 'label': 'upper', 'name': 'u.md', 'kind': 'markdown', 'type': 'Markdown', 'state': 'available'}]},
        {'role': 'assistant', 'text': 'nothing', 'at': '2026-11-08T10:02:00.000Z'},
        {'role': 'assistant', 'text': 'off', 'at': '2026-11-08T10:03:00.000Z', 'previewsOff': True,
         'outputFiles': [{'id': 'af_' + C, 'name': 'leak.md', 'kind': 'text', 'type': 'Markdown', 'state': 'available'}]},
    ]}
    state = {'status': 200, 'body': detail, 'raw': None, 'type': 'application/json'}
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            requests.append((self.command, self.path, self.headers.get('X-COS-Token') == token))
            if state['raw'] is not None:
                raw = state['raw']; kind = state['type']
            elif state['body'] is None:
                raw = b'<!DOCTYPE html><pre>Cannot GET</pre>'; kind = 'text/html'
            else:
                raw = json.dumps(state['body']).encode(); kind = 'application/json'
            self.send_response(state['status']); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(raw)))
            self.end_headers(); self.wfile.write(raw)

    server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, COS_CONTROL_TEST_HOME=tmp, COS_CONTROL_TEST_API_PORT=str(server.server_port))

    def run(*args, stdin=None, port=None, e=None):
        e = dict(e or env)
        if port: e['COS_CONTROL_TEST_API_PORT'] = str(port)
        result = subprocess.run([sys.argv[1], *args], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=60)
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
            print(f'session previews helper check FAILED: {name}'); sys.exit(1)
        checks += 1

    def fetch(id, part='raw', name='Q3 plan.pdf', extra=None):
        req = {'provider': 'claude', 'session': SESSION, 'id': id, 'part': part, 'name': name}
        if extra: req.update(extra)
        return run('session-preview-fetch', stdin=json.dumps(req).encode())

    def copies():
        return sorted(p for p in root.rglob('*') if p.is_file()) if root.exists() else []

    try:
        # ── session-previews
        got = run('session-previews', '--provider', 'claude', '--session-id', SESSION.upper())
        check(requests[-1] == ('GET', f'/api/agent-sessions/claude/{SESSION}?turns=40', True), 'the detail is read with turns=40 and the token')
        d = got['details']
        check(got['ok'] and d['state'] == 'ready' and d['previewsOff'] is True, 'a ready answer, and the off message is noticed')
        turns = d['turns']
        check([t['at'] for t in turns] == ['2026-11-08T10:00:00.000Z', '2026-11-08T10:01:00.000Z', '2026-11-08T10:03:00.000Z'],
              'a message with no cards is left out; the off message stays as a mark')
        tool = turns[0]['items']
        check([i['id'] for i in tool] == ['ti_' + A, 'ti_' + B], 'tool images cross by id')
        check(tool[0] == {'id': 'ti_' + A, 'source': 'tool', 'name': 'Attached', 'kind': 'image', 'type': 'Image', 'available': True, 'index': 1, 'total': 2},
              'a tool image crosses with only the contract keys')
        check(tool[1]['name'] == 'Image' and 'index' not in tool[1] and 'path' not in tool[1], 'an unknown tool label and a bad index are dropped, a path never crosses')
        check(turns[0]['more'] == 3, 'the count past the cap crosses')
        items = {i['id']: i for i in turns[1]['items']}
        check(set(items) == {'ai_' + A, 'af_' + A, 'af_' + B, 'af_' + C, 'af_' + D, 'al_' + A, 'al_' + B},
              'a wrong prefix, an upper-case id and a duplicate never cross')
        check(items['ai_' + A] == {'id': 'ai_' + A, 'source': 'image', 'name': 'shot.png', 'kind': 'image', 'type': 'Image', 'available': True},
              'an output image crosses with its base name')
        pdf = items['af_' + A]
        check(pdf['name'] == 'Q3 plan.pdf' and pdf['size'] == 1234 and pdf['kind'] == 'pdf' and pdf['available'] is True, 'a sent file keeps its base name only')
        secret = items['af_' + B]
        check(secret['available'] is False and secret['reason'] == 'secret_file' and 'notice' not in secret, 'secret_file is never available; no server notice crosses')
        check(items['al_' + B]['available'] is False and items['al_' + B]['reason'] == 'blocked_name', 'blocked_name is never available')
        check(items['af_' + C]['reason'] == 'missing' and items['af_' + D]['reason'] == 'unavailable' and items['af_' + D]['kind'] == 'file',
              'an unknown reason reads unavailable and an unknown kind reads file')
        link = items['al_' + A]
        check(link == {'id': 'al_' + A, 'source': 'link', 'name': 'PLAN.md', 'label': 'the plan', 'kind': 'markdown', 'type': 'Markdown',
                       'size': 4210, 'line': 42, 'available': True}, 'a link card crosses with its words, name, size and line')
        check(turns[2]['previewsOff'] is True and turns[2]['items'] == [] and turns[2]['more'] == 0, 'an off message carries nothing it was sent')
        check('/Users/' not in json.dumps(d), 'no Mac path in the answer')

        state.update(body={'session_id': SESSION})
        check(run('session-previews', '--provider', 'codex', '--session-id', SESSION)['details'] == {'state': 'absent', 'turns': [], 'previewsOff': False},
              'no recent_turns is an older server: absent, no cards')
        state.update(status=404, body={'error': 'Session not found'})
        check(run('session-previews', '--provider', 'claude', '--session-id', SESSION)['details']['state'] == 'missing', '404 is missing')
        state.update(status=500, body={'error': 'x'})
        check(run('session-previews', '--provider', 'claude', '--session-id', SESSION)['details']['state'] == 'unavailable', '500 is unavailable')
        before = len(requests)
        bad = run('session-previews', '--provider', 'claude', '--session-id', '../../etc')
        check(not bad['ok'] and len(requests) == before, 'a bad session id never reaches the server')
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); dead = s.getsockname()[1]
        check(run('session-previews', '--provider', 'claude', '--session-id', SESSION, port=dead)['details']['state'] == 'unreachable', 'no server is unreachable')

        # ── session-preview-fetch: routes
        state.update(status=200, body=None, raw=b'%PDF-1.7 bytes', type='application/octet-stream')
        got = fetch('af_' + A)
        check(requests[-1] == ('GET', f'/api/agent-sessions/claude/{SESSION}/output-files/af_{A}/content', True), 'a sent file uses output-files')
        d = got['details']
        path = pathlib.Path(d['path'])
        check(d['state'] == 'ready' and d['name'] == 'Q3 plan.pdf' and d['bytes'] == 14 and path.read_bytes() == b'%PDF-1.7 bytes', 'a ready copy holds the bytes')
        check(path.parent.parent == root and path.name == 'Q3 plan.pdf', 'the copy is SessionPreviews/<uuid>/<name>')
        check(stat.S_IMODE(path.parent.stat().st_mode) == 0o700 and stat.S_IMODE(root.stat().st_mode) == 0o700, 'the folders are 0700')
        check(stat.S_IMODE(path.stat().st_mode) == 0o600, 'the copy is 0600')
        got = fetch('al_' + A, name='PLAN.md')
        check(requests[-1][1] == f'/api/preview/agent-sessions/claude/{SESSION}/al_{A}/content?part=raw', 'a link uses the preview route, part raw')
        state.update(raw=JPEG)
        got = fetch('ai_' + A, name='shot.png')
        check(requests[-1][1] == f'/api/agent-sessions/claude/{SESSION}/output-images/ai_{A}/content?variant=phone', 'an output image uses its phone JPEG')
        check(got['details']['name'] == 'shot.jpg', 'a normalized picture is named for what it is')
        fetch('ai_' + A, part='thumb', name='shot.png')
        check(requests[-1][1].endswith('/output-images/ai_' + A + '/content?variant=thumb'), 'a thumbnail asks for the thumb variant')
        state.update(raw=PNG)
        got = fetch('ti_' + A, name='Read')
        check(requests[-1][1] == f'/api/agent-sessions/claude/{SESSION}/tool-images/ti_{A}/content' and got['details']['name'] == 'Read.png',
              'a tool image uses tool-images and its sniffed type')
        fetch('al_' + A, part='thumb', name='p.png')
        check(requests[-1][1].endswith('/al_' + A + '/content?part=thumb'), 'a picture link thumbnail uses part thumb')
        got = fetch('af_' + A, name='../../.ssh/id_rsa')
        check(pathlib.Path(got['details']['path']).name == 'id_rsa' and pathlib.Path(got['details']['path']).parent.parent == root,
              'a name with directories keeps its base name only, inside the root')

        # ── refused before the server
        before = len(requests)
        for bad, why in [({'id': 'af_' + A, 'part': 'thumb'}, 'a sent file has no thumbnail route'),
                         ({'id': 'xx_' + A}, 'an unknown prefix'), ({'id': 'af_' + A[:-1]}, 'a short id'),
                         ({'part': 'html'}, 'an unknown part'), ({'session': '../x'}, 'a bad session'),
                         ({'provider': 'gemini'}, 'an unknown provider'), ({'path': '/etc/passwd'}, 'an unknown key')]:
            req = {'provider': 'claude', 'session': SESSION, 'id': 'af_' + A, 'part': 'raw', 'name': 'x.md'}; req.update(bad)
            r = run('session-preview-fetch', stdin=json.dumps(req).encode())
            check(not r['ok'] and len(requests) == before, f'{why} never reaches the server')

        # ── refusals write nothing
        n = len(copies())
        for status, body, raw, expected in [(403, {'error': 'previews_off'}, None, 'off'), (403, {'error': 'secret_file_denied'}, None, 'secret'),
                                            (403, {'error': 'blocked_name'}, None, 'secret'), (404, None, None, 'absent'),
                                            (404, {'error': 'preview_not_found'}, None, 'missing'), (413, {'error': 'preview_too_large'}, None, 'too_large'),
                                            (401, {'error': 'unauthorized'}, None, 'unauthorized'), (503, {'error': 'preview_busy'}, None, 'unavailable')]:
            state.update(status=status, body=body, raw=raw)
            r = fetch('al_' + A, name='PLAN.md')
            check(r['ok'] and r['details']['state'] == expected and 'path' not in r['details'], f'{status} {body} answers {expected}')
        state.update(status=200, body=None, raw=b'<html>not a picture</html>')
        r = fetch('ai_' + A, name='shot.png')
        check(r['details']['state'] == 'invalid', 'a picture route that sends no picture is refused')
        check(len(copies()) == n, 'no refusal writes a copy')
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); dead = s.getsockname()[1]
        r = run('session-preview-fetch', stdin=json.dumps({'provider': 'claude', 'session': SESSION, 'id': 'af_' + A, 'part': 'raw', 'name': 'a'}).encode(), port=dead)
        check(r['details']['state'] == 'offline', 'no server is offline')
        env_file.unlink()
        r = fetch('af_' + A)
        check(r['details']['state'] == 'unauthorized', 'no token is unauthorized')
    finally:
        server.shutdown()
    print(f'session previews helper checks: {checks} passed')
