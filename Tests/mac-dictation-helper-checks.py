#!/usr/bin/env python3
"""Dictation bridge contract. Synthetic bytes, loopback fixture, isolated home only."""
import json, os, pathlib, shutil, socket, struct, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-dictation-bridge-', dir='/tmp'))
home = root / 'home'
(home / '.cos-glasses').mkdir(parents=True, mode=0o700)
token = 'd' * 64
(home / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n')
(home / '.cos-glasses/.env').chmod(0o600)
seen = []
health = []
capability = {'status': 200, 'body': {'desktopDictationVersion': 1, 'localOnly': True}}
answer = {'status': 200, 'body': {'text': 'Niala reviews Parakeet.', 'engine': 'parakeet-ultra'}}
checks = 0
pcm = b'\x01\x00' * 1600
wav = b'RIFF' + struct.pack('<I', len(pcm)+36) + b'WAVEfmt ' + struct.pack('<IHHIIHH',16,1,1,16000,32000,2,16) + b'data' + struct.pack('<I',len(pcm)) + pcm
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def respond(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/api/health':
            health.append(self.path); result = {'status': 200, 'body': {'ok': True}}
        else:
            seen.append((self.command, self.path, self.headers, data))
            result = capability if self.path == '/api/transcribe/capabilities' else answer
        authenticated = self.headers.get('X-COS-Token') == token or self.path == '/api/health'
        raw = json.dumps(result['body'] if authenticated else {'error': 'unauthorized'}).encode()
        self.send_response(result['status'] if authenticated else 401)
        self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port))
def check(ok, why):
    global checks
    assert ok, why
    checks += 1
def run(audio=wav, environment=None):
    proc = subprocess.run([helper, 'mac-dictation'], input=audio, capture_output=True, env=environment or env, timeout=15)
    check(proc.returncode == 0 and not proc.stderr, 'JSON only; no audio or transcript diagnostics')
    check(token.encode() not in proc.stdout, 'credential never emitted')
    return json.loads(proc.stdout)
try:
    result = run()
    check(result['ok'] and result['details']['engine'] == 'parakeet-ultra', 'strict local engine returned')
    check(result['details']['text'] == answer['body']['text'], 'dictionary-corrected server text retained')
    check(seen[-2][1] == '/api/transcribe/capabilities', 'capability checked before upload')
    check(seen[-1][1] == '/api/transcribe?mode=fast&requiredEngine=parakeet-ultra', 'no caller-controlled route or fallback')
    check(seen[-1][3] == wav and seen[-1][2]['Content-Type'] == 'audio/wav', 'raw WAV through stdin')
    # 0.5.345 (A-W0d, plan r3): dictate() reads the token file itself; no /api/health round trip before the capability gate.
    check(health == [], 'mac-dictation asks no /api/health (one round trip less per dictation)')
    check(isinstance(result['details'].get('preUploadMs'), int) and 0 <= result['details']['preUploadMs'] < 15_000, 'preUploadMs stamped before the upload')
    for status, message, action in [(401, 'Unauthorized', 'none'), (403, 'Unauthorized', 'none'), (404, 'Update to the matched COS server', 'none'), (500, 'Update to the matched COS server', 'none')]:
        capability['status'] = status; before = len(seen)
        result = run()
        check(not result['ok'] and result['message'].startswith(message) and result['details'].get('action') == action and len(seen) == before + 1,
              f'capabilities {status}: {message}, no audio sent')
    capability['status'] = 200
    closed = socket.socket(); closed.bind(('127.0.0.1', 0)); port = closed.getsockname()[1]; closed.close()
    result = run(environment=dict(env, COS_CONTROL_TEST_API_PORT=str(port)))
    check(not result['ok'] and result['message'] == 'Server stopped' and result['details'].get('action') == 'retry' and result['details'].get('retryable') is True,
          'a stopped server (no answer) says Server stopped and keeps the dictation\'s Retry')
    check(health == [], 'no /api/health on any refusal either')
    source = (pathlib.Path(__file__).resolve().parents[1] / 'HelperSources/main.swift').read_text()
    body = source[source.index('private func dictate(_ audio: Data) throws -> DictationBridge.Answer {'):]
    body = body[:body.index('\n    }\n') + 6]
    check('speakerReviewToken' not in body and '/api/health' not in body and 'try readToken()' in body, 'dictate() reads the token directly (speakerReviewToken unchanged for its other callers)')
    check(source.count('try dictate(') == 2 and 'let answer = try dictate(utterance)' in source, 'dictation-check takes the same dictate() path')
    for body in [{}, {'desktopDictationVersion': 1}, {'desktopDictationVersion': 1, 'localOnly': False}]:
        capability['body'] = body; before = len(seen)
        check(not run()['ok'] and len(seen) == before + 1, 'unmatched server gets no audio')
    capability['body'] = {'desktopDictationVersion': 1, 'localOnly': True}
    answer.update(status=204, body={}); result = run()
    check(not result['ok'] and result['details'].get('noSpeech') is True, 'no speech is marked, so Control offers no Retry of the same audio')
    answer.update(status=503, body={'error': 'busy'}); result = run()
    check(not result['ok'] and not result['details'].get('noSpeech'), 'only the 204 is no speech')
    for status, body in [(204, {}), (503, {'error': 'private content ' + token}), (200, {'text': 'wrong engine', 'engine': 'whisper'}), (200, {'text': '', 'engine': 'parakeet-ultra'})]:
        answer.update(status=status, body=body); result = run()
        check(not result['ok'] and 'private content' not in json.dumps(result), 'silence, unavailable, wrong-engine and empty text refused safely')
    for audio in [b'', b'not wav' * 700, wav + bytes(3_840_045)]:
        before = len(seen)
        check(not run(audio)['ok'] and len(seen) == before, 'invalid/oversized bytes refused before network')
    print(f'PASS Mac dictation helper: {checks} checks; authenticated fixed routes, local capability gate, bounds, no fallback or credential output')
finally:
    server.shutdown(); shutil.rmtree(root)
