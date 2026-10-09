#!/usr/bin/env python3
"""Glasses pairing verbs through the COMPILED helper (contract 2026-10-09), never the live service or the real Tailscale.

Usage: pairing-helper-checks.py <compiled cos-control-helper>.
- tailscale-status / tailscale-whois run a stand-in Tailscale.app in a /tmp home. The stand-in behaves like the real
  1.102.2 bundle binary: WITHOUT SHLVL in its environment it prints the GUI failure and exits 0. The helper is run with
  no SHLVL of its own, so only the child environment the helper builds can make it answer.
- pairing-code / pairing-status / pairing-decision go to a loopback fixture with the /tmp home's token.
"""
import json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

helper = sys.argv[1]
here = pathlib.Path(__file__).resolve().parent
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-pairing-helper-', dir='/tmp'))
token = 'p' * 64
(root / '.cos-glasses').mkdir(mode=0o700)
(root / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (root / '.cos-glasses/.env').chmod(0o600)

app = root / 'Tailscale.app'
(app / 'Contents/MacOS').mkdir(parents=True)
shutil.copy(here / 'fixtures/pairing/tailscale-status-running.json', app / 'Contents/MacOS/status.json')
shutil.copy(here / 'fixtures/pairing/tailscale-whois-iphone.json', app / 'Contents/MacOS/whois.json')
binary = app / 'Contents/MacOS/Tailscale'
binary.write_text('''#!/usr/bin/python3 -I
import json, os, sys
d = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(d, "env.log"), "a") as f: f.write(json.dumps(dict(os.environ)) + "\\n")
if not os.environ.get("SHLVL"):
    print("The Tailscale GUI failed to start: The operation couldn\\u2019t be completed. (Tailscale.CLIError error 3.)"); sys.exit(0)
if sys.argv[1:3] == ["status", "--json"]:
    sys.stdout.write(open(os.path.join(d, "status.json")).read()); sys.exit(0)
if sys.argv[1:3] == ["whois", "--json"] and len(sys.argv) == 4:
    if sys.argv[3] == "100.64.0.11": sys.stdout.write(open(os.path.join(d, "whois.json")).read()); sys.exit(0)
    sys.stderr.write("2026/10/09 07:31:15 peer not found\\n"); sys.exit(1)
sys.exit(2)
''')
binary.chmod(0o755)
def set_bundle(identifier):
    with open(app / 'Contents/Info.plist', 'wb') as f: plistlib.dump({'CFBundleIdentifier': identifier}, f)
set_bundle('io.tailscale.ipn.macos')  # the App Store build, at the same path

calls, state = [], {'code': (200, None), 'status': (200, None), 'decision': (200, None)}
CODE = {'code': 'K7Q2M9XD', 'display': 'K7Q2-M9XD', 'qr': 'COS1/MAC/K7Q2M9XD/100.64.0.10:3141/T3ABCD', 'expiresAt': '2026-10-09T12:40:00.000Z',
        'bootId': 'boot-1', 'hosts': [{'host': '100.64.0.10', 'port': 3141, 'kind': 'tailscale'}], 'lanArmedUntil': None}
STATUS = {'code': {'display': 'K7Q2-M9XD', 'expiresAt': '2026-10-09T12:40:00.000Z', 'state': 'active'},
          'pending': {'nonce': 'nonce-abcdefghijklmnop', 'ip': '100.64.0.11', 'at': '2026-10-09T12:36:00.000Z'},
          'lastClaim': None, 'firstAuthAfterClaimAt': None, 'lanArmedUntil': None, 'bootId': 'boot-1'}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, body):
        self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def answer(self, key, ok_body):
        status, body = state[key]
        self.reply(status, ok_body if body is None else body)
    def do_GET(self):
        assert self.headers.get('X-COS-Token') == token
        calls.append(('GET', self.path, None))
        if self.path == '/api/pairing/status': return self.answer('status', STATUS)
        self.reply(404, {})
    def do_POST(self):
        assert self.headers.get('X-COS-Token') == token
        n = int(self.headers.get('Content-Length') or 0)
        data = json.loads(self.rfile.read(n)) if n else None
        calls.append(('POST', self.path, data))
        if self.path == '/api/pairing/code': return self.answer('code', CODE)
        if self.path == '/api/pairing/decision': return self.answer('decision', {'ok': True})
        self.reply(404, {})

server = HTTPServer(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
env = {k: v for k, v in os.environ.items() if k != 'SHLVL'}
env.update(COS_CONTROL_TEST_HOME=str(root), COS_CONTROL_TEST_API_PORT=str(server.server_port), COS_CONTROL_TEST_TAILSCALE_APP=str(app),
           COS_API_TOKEN='helper-env-secret')
passed = 0
def run(args):
    out = subprocess.run([helper, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=30)
    for secret in (token.encode(), b'nonce-abcdefghijklmnop' if args[:1] != ['pairing-status'] else b'\0'):
        assert secret not in out.stderr, 'nothing secret on stderr'
    assert b'K7Q2M9XD' not in out.stderr, 'the code is never logged'
    return out.returncode, json.loads(out.stdout)
def ok(cond, what):
    global passed
    assert cond, what
    passed += 1

try:
    # tailscale-status: the stand-in answers only because the helper set SHLVL=1 in the child.
    code, r = run(['tailscale-status'])
    d = r['details']
    ok(code == 0 and r['ok'] and d['installed'] and d['running'] and d['backendState'] == 'Running', f'status running {r}')
    ok(d['selfIPv4'] == '100.64.0.10' and d['selfDNS'] == 'example-mac.tail00000a.ts.net' and d['bundle'] == 'appStore', f'self {d}')
    phone = [p for p in d['peers'] if p['os'] == 'iOS']
    ok(phone == [{'os': 'iOS', 'dns': 'example-iphone.tail00000a.ts.net', 'ipv4': '100.64.0.11', 'online': True, 'sameUser': True}], f'phone {phone}')
    ok(not any('localhost' in json.dumps(p) for p in d['peers']), 'never HostName')
    child = json.loads((app / 'Contents/MacOS/env.log').read_text().splitlines()[-1])
    ok(child.get('SHLVL') == '1', f'the child got SHLVL=1: {sorted(child)}')
    ok('COS_API_TOKEN' not in child and 'COS_CONTROL_TEST_HOME' not in child and child.get('PATH') == '/usr/bin:/bin:/usr/sbin:/sbin', f'child env is the fixed set: {sorted(child)}')
    ok('SHLVL' not in env, 'the helper itself ran without SHLVL')
    set_bundle('io.tailscale.ipn.macsys')
    ok(run(['tailscale-status'])[1]['details']['bundle'] == 'standalone', 'standalone build')
    # The app missing: an answer, not an error.
    binary.rename(app / 'Contents/MacOS/Tailscale.off')
    code, r = run(['tailscale-status'])
    ok(code == 0 and r['ok'] and r['details']['installed'] is False and r['details']['running'] is False, f'not installed {r}')
    code, r = run(['tailscale-whois', '100.64.0.11'])
    ok(r['ok'] and r['details'] == {'found': False, 'sameUser': False}, f'whois with no app {r}')
    (app / 'Contents/MacOS/Tailscale.off').rename(binary)
    # tailscale-whois.
    code, r = run(['tailscale-whois', '100.64.0.11'])
    ok(r['ok'] and r['details'] == {'found': True, 'node': 'example-iphone', 'os': 'iOS', 'user': 'Alex Example', 'sameUser': True}, f'whois {r}')
    # Another account: the stand-in's whois answers with a different UserProfile.ID.
    w = json.loads((app / 'Contents/MacOS/whois.json').read_text()); w['UserProfile']['ID'] = 2002
    (app / 'Contents/MacOS/whois.json').write_text(json.dumps(w))
    code, r = run(['tailscale-whois', '100.64.0.11'])
    ok(r['ok'] and r['details']['sameUser'] is False and r['details']['found'] is True, f'whois another account {r}')
    shutil.copy(here / 'fixtures/pairing/tailscale-whois-iphone.json', app / 'Contents/MacOS/whois.json')
    code, r = run(['tailscale-whois', '100.70.0.9'])
    ok(r['ok'] and r['details'] == {'found': False, 'sameUser': False}, f'peer not found {r}')
    for bad in ('100.64.0.11; rm -rf /', 'fd7a::1', '', 'localhost'):
        code, r = run(['tailscale-whois', bad])
        ok(not r['ok'], f'whois refuses {bad!r}')
    # pairing-code: loopback, the token, the body; the server's answer comes through.
    code, r = run(['pairing-code'])
    ok(r['ok'] and r['details']['display'] == 'K7Q2-M9XD' and r['details']['qr'].startswith('COS1/MAC/') and r['details']['reason'] is None, f'code {r}')
    ok(calls[-1] == ('POST', '/api/pairing/code', {'allowLan': False}), f'code body {calls[-1]}')
    run(['pairing-code', '--allow-lan'])
    ok(calls[-1] == ('POST', '/api/pairing/code', {'allowLan': True}), f'lan body {calls[-1]}')
    code, r = run(['pairing-status'])
    ok(r['ok'] and r['details']['pending']['ip'] == '100.64.0.11' and r['details']['bootId'] == 'boot-1' and calls[-1][:2] == ('GET', '/api/pairing/status'), f'status {r}')
    # pairing-decision.
    code, r = run(['pairing-decision', 'nonce-abcdefghijklmnop', 'allow'])
    ok(r['ok'] and r['details']['reason'] is None and calls[-1] == ('POST', '/api/pairing/decision', {'nonce': 'nonce-abcdefghijklmnop', 'allow': True}), f'allow {calls[-1]}')
    run(['pairing-decision', 'nonce-abcdefghijklmnop', 'deny'])
    ok(calls[-1] == ('POST', '/api/pairing/decision', {'nonce': 'nonce-abcdefghijklmnop', 'allow': False}), f'deny {calls[-1]}')
    before = len(calls)
    for bad in (['pairing-decision', 'short', 'allow'], ['pairing-decision', 'nonce-abcdefghijklmnop', 'yes'], ['pairing-decision', 'nonce-abcdefghijklmnop'],
                ['pairing-decision', 'nonce-abcdefghijk","allow":true,"x":"', 'deny']):
        ok(not run(bad)[1]['ok'], f'refused {bad}')
    ok(len(calls) == before, 'no malformed decision reaches the server')
    # Every refusal is data with its reason (the app shows it), never a thrown error.
    for key, status, body, reason in (('code', 503, {'reason': 'draining', 'message': 'Shutting down'}, 'draining'),
                                      ('code', 429, {'reason': 'rate_limited'}, 'rate_limited'),
                                      ('decision', 410, {'reason': 'expired'}, 'expired'),
                                      ('decision', 409, {'reason': 'used'}, 'used'),
                                      ('decision', 404, {'reason': 'unknown_code'}, 'unknown_code'),
                                      ('status', 404, {}, 'server_too_old'),
                                      ('status', 403, {'reason': 'not_loopback'}, 'not_loopback'),
                                      ('status', 401, {'reason': 'pairing_token_rejected'}, 'token_rejected'),
                                      ('code', 500, {'reason': 'nonsense'}, 'http_500')):
        state[key] = (status, body)
        verb = {'code': ['pairing-code'], 'status': ['pairing-status'], 'decision': ['pairing-decision', 'nonce-abcdefghijklmnop', 'allow']}[key]
        code, r = run(verb)
        ok(code == 0 and r['ok'] and r['details']['reason'] == reason and r['details']['httpStatus'] == status and 'display' not in r['details'], f'{key} {status} {r}')
        state[key] = (200, None)
    # No server at all: a free high port nothing listens on (a port below 1024 would fall back to the live 3141).
    import socket
    probe = socket.socket(); probe.bind(('127.0.0.1', 0)); dead = probe.getsockname()[1]; probe.close()
    env['COS_CONTROL_TEST_API_PORT'] = str(dead)
    code, r = run(['pairing-status'])
    ok(r['ok'] and r['details']['reason'] == 'unreachable', f'unreachable {r}')
    # No token: an error, and nothing is sent.
    env['COS_CONTROL_TEST_API_PORT'] = str(server.server_port)
    (root / '.cos-glasses/.env').unlink()
    before = len(calls)
    ok(not run(['pairing-code'])[1]['ok'] and len(calls) == before, 'no token, no call')
    print(f'PASS: pairing helper checks ({passed} checks)')
finally:
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)
