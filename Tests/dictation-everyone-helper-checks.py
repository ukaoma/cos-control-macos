#!/usr/bin/env python3
"""0.5.317 dictation for everyone: the compiled helper's mac-dictation, dictation-check and dictation-benchmark
against a loopback fixture that plays server 6.74.0 and 6.73.14. Synthetic audio, isolated home, no real server.

    python3 Tests/dictation-everyone-helper-checks.py <cos-control-helper> <repo root>

The helper runs from a scratch folder beside a copy of whisper-runtime.json and VoiceBenchmark/, as it does from its
stable install, so the pinned sample and reference are the real ones.
"""
import json, os, pathlib, shutil, struct, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

source_helper, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-dictation-everyone-', dir='/tmp'))
bin_dir = root / 'bin'; bin_dir.mkdir()
helper = bin_dir / 'cos-control-helper'
shutil.copy(source_helper, helper)
shutil.copy(repo / 'Resources/whisper-runtime.json', bin_dir / 'whisper-runtime.json')
shutil.copytree(repo / 'Resources/VoiceBenchmark', bin_dir / 'VoiceBenchmark')
sample = (repo / 'Resources/VoiceBenchmark/speech-30s.wav').read_bytes()
home = root / 'home'
(home / '.cos-glasses').mkdir(parents=True, mode=0o700)
token = 'e' * 64
(home / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n'); (home / '.cos-glasses/.env').chmod(0o600)
V2 = {'desktopDictationVersion': 1, 'desktopDictationVersions': [1, 2], 'requiredEngines': ['parakeet-ultra', 'local'], 'localOnly': True, 'dictionary': 'cos', 'benchmark': 1}
V1 = {'desktopDictationVersion': 1, 'requiredEngines': ['parakeet-ultra'], 'localOnly': True, 'dictionary': 'cos'}
REFERENCE = ' '.join(['And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country.'] * 2) + ' And so my fellow Americans, ask not what your country can do for you,'
state = {'capabilities': V2, 'transcribe': (200, {'text': 'Ask not.', 'engine': 'whisper', 'fallbackReason': 'parakeet_not_installed', 'dictationSetting': 'auto'}),
         'benchmark': (200, {'audioSeconds': 30, 'results': []})}
seen = []
checks = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()

    def respond(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/api/health':
            status, body = 200, {'ok': True, 'server_version': '6.74.0'}
        else:
            seen.append((self.command, self.path, data))
            if self.path == '/api/transcribe/capabilities': status, body = 200, state['capabilities']
            elif self.path.startswith('/api/transcribe/benchmark'): status, body = state['benchmark']
            else: status, body = state['transcribe']
        if self.path != '/api/health' and self.headers.get('X-COS-Token') != token:
            status, body = 401, {'error': 'unauthorized'}
        raw = b'' if status == 204 else json.dumps(body).encode()
        self.send_response(status); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)


server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port))
pcm = b'\x01\x00' * 1600
wav = b'RIFF' + struct.pack('<I', len(pcm) + 36) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16) + b'data' + struct.pack('<I', len(pcm)) + pcm


def check(ok, why):
    global checks
    assert ok, why
    checks += 1


def run(verb, audio=b''):
    proc = subprocess.run([str(helper), verb], input=audio, capture_output=True, env=env, timeout=60)
    check(proc.returncode == 0, f'{verb} exits cleanly: {proc.stderr[-300:]!r}')
    check(token.encode() not in proc.stdout and token.encode() not in proc.stderr, 'credential never emitted')
    return json.loads(proc.stdout)


support = home / 'Library/Application Support/COS Control'
try:
    # mac-dictation on 6.74.0: the local route, any local engine, the fallback reason and the setting.
    got = run('mac-dictation', wav)
    check(seen[-2][1] == '/api/transcribe/capabilities' and seen[-1][1] == '/api/transcribe?mode=fast&requiredEngine=local', 'a 6.74.0 server gets requiredEngine=local')
    check(seen[-1][2] == wav, 'the audio crosses as sent')
    check(got['ok'] and got['details']['engine'] == 'whisper' and got['details']['fallbackReason'] == 'parakeet_not_installed'
          and got['details']['dictationSetting'] == 'auto' and got['details']['localRoute'] is True, 'Whisper dictation works, and says why it was Whisper')
    state['transcribe'] = (503, {'error': 'Parakeet Ultra is not installed.', 'reason': 'parakeet_unavailable', 'retryable': False, 'action': 'install_parakeet'})
    got = run('mac-dictation', wav)
    check(not got['ok'] and got['message'] == 'Parakeet Ultra is not installed.' and got['details']['action'] == 'install_parakeet' and got['details']['retryable'] is False,
          'a refusal carries its sentence and its one action')
    state['transcribe'] = (503, {'error': 'Whisper is starting.', 'reason': 'no_local_engine', 'retryable': False, 'action': 'retry_when_warm', 'detail': 'whisper_starting'})
    got = run('mac-dictation', wav)
    check(got['details']['action'] == 'open_transcription_settings', 'a retry the server says cannot succeed is never offered')
    # mac-dictation on 6.73.14: exactly the 0.5.316 route and words.
    state['capabilities'] = V1
    state['transcribe'] = (200, {'text': 'Ask not.', 'engine': 'whisper'})
    got = run('mac-dictation', wav)
    check(seen[-1][1] == '/api/transcribe?mode=fast&requiredEngine=parakeet-ultra' and not got['ok']
          and got['message'] == 'Dictation needs the matched server with Parakeet support. No text was inserted.', 'an older server keeps the Parakeet-only route and words')
    state['transcribe'] = (200, {'text': 'Ask not.', 'engine': 'parakeet-ultra'})
    got = run('mac-dictation', wav)
    check(got['ok'] and got['details']['engine'] == 'parakeet-ultra' and got['details']['localRoute'] is False, 'Parakeet on an older server works as before')
    before = len(seen)
    state['capabilities'] = {'desktopDictationVersion': 2, 'desktopDictationVersions': [2], 'localOnly': True}
    check(not run('mac-dictation', wav)['ok'] and len(seen) == before + 1, 'a server without version 1 gets no audio')

    # dictation-check: the pinned sample through the same round trip; the record keeps results, never text.
    state['capabilities'] = V2
    state['transcribe'] = (200, {'text': REFERENCE, 'engine': 'whisper'})
    got = run('dictation-check')
    check(seen[-1][1] == '/api/transcribe?mode=fast&requiredEngine=local' and seen[-1][2] == sample, 'the check posts the pinned 30 s sample on the dictation route')
    check(got['ok'] and got['message'] == 'Dictation works on this Mac.' and got['details']['engine'] == 'whisper' and got['details']['wer'] == 0, 'a working round trip, scored')
    record = json.loads((support / 'dictation-check.json').read_text())
    check(record['ok'] and record['serverVersion'] == '6.74.0' and 'text' not in record and 'Americans' not in json.dumps(record), 'the record keeps the version and never the text')
    check(oct((support / 'dictation-check.json').stat().st_mode & 0o777) == '0o600', 'the record is private')
    status = run('voice-status')
    check(status['details']['dictationCheck']['ok'] is True and status['details']['dictationCheck']['engine'] == 'whisper', 'voice-status carries the check')
    state['transcribe'] = (503, {'reason': 'no_local_engine', 'retryable': False, 'action': 'open_transcription_settings', 'detail': 'whisper_unavailable'})
    got = run('dictation-check')
    record = json.loads((support / 'dictation-check.json').read_text())
    check(not got['ok'] and not record['ok'] and record['action'] == 'open_transcription_settings' and record['message'].startswith('No speech engine'), 'a failed check says why')

    # dictation-benchmark: both engines, whitelisted, scored on the raw text, Whisper memory never invented.
    state['benchmark'] = (200, {'audioSeconds': 30, 'results': [
        {'engine': 'whisper', 'model': 'large-v3-turbo', 'ran': True, 'elapsedMs': 2400, 'rtf': 0.08, 'peakRssBytes': None, 'text': REFERENCE},
        {'engine': 'parakeet-ultra', 'model': 'ultra', 'ran': True, 'elapsedMs': 600, 'rtf': 0.02, 'peakRssBytes': 1200000000, 'warmupMs': 14000, 'text': REFERENCE.replace('fellow', 'yellow')},
        {'engine': 'cloud', 'ran': True, 'text': 'x'}]})
    got = run('dictation-benchmark')
    check(seen[-1][1] == '/api/transcribe/benchmark?engines=whisper,parakeet-ultra' and seen[-1][2] == sample, 'the test posts the pinned sample to the benchmark route')
    rows = got['details']['results']
    check(got['ok'] and [r['engine'] for r in rows] == ['whisper', 'parakeet-ultra'], 'only local engines are kept')
    check(rows[0]['wer'] == 0 and rows[0]['peakRssBytes'] is None and abs(rows[1]['wer'] - 3 / 58) < 1e-9 and rows[1]['warmupMs'] == 14000, 'scored on the raw text; no Whisper memory figure')
    check('text' not in json.dumps(rows) or 'Americans' not in json.dumps(rows), 'no transcript text is kept')
    saved = json.loads((support / 'dictation-benchmark.json').read_text())
    check(saved['scope'] == 'one 30 s sample; a sanity check, not a benchmark' and 'Americans' not in json.dumps(saved), 'the stored test says what it is and keeps no text')
    check(run('voice-status')['details']['dictationBenchmark']['results'][1]['engine'] == 'parakeet-ultra', 'voice-status carries the test')
    state['benchmark'] = (409, {'reason': 'recording_live'})
    got = run('dictation-benchmark')
    check(got['ok'] and got['details']['httpStatus'] == 409 and got['message'] == 'Test the engines after the recording ends.', 'a live recording holds the test')
    state['capabilities'] = V1
    before = len(seen)
    got = run('dictation-benchmark')
    check(got['ok'] and got['details']['httpStatus'] == 404 and len(seen) == before + 1, 'an older server is asked nothing beyond its capabilities')
    print(f'PASS dictation for everyone helper: {checks} checks; local route on 6.74.0, the old route kept, one action per refusal, the real-path check, the engine test')
finally:
    server.shutdown(); shutil.rmtree(root)
